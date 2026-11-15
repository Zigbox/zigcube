//! C4 slice 5: connections between services in the cluster simulation (docs/briefs/c4.md,
//! "Simulation and fault checks"). In a mesh world (`sim_cluster --mesh`, `--c4`, `auto`) each
//! agent gives its replicas mesh ports and rules (`agent_mesh.zig`), and this model stands for
//! their supervisors' data path: a replica with listeners opens requests to a destination's
//! endpoints in the order its rules give (at most `attempts_max` tries), the destination's
//! supervisor checks its accepts, and an open connection is cut when either end receives rules
//! without its grant. Services grant each other on `ports`, redrawn at each apply (grant churn);
//! the `mesh` profile adds cuts between supervisors.
//!
//! The rules a supervisor holds come to it through the runtime seam (`SimRuntime.on_mesh`), and
//! with each delivery the model keeps the node's view of the mesh that the agent's step planned
//! from (`mesh_plan.Input`). The checks read that view's records, never `mesh_plan`, so they judge
//! the compiler and the supervisors rather than the rule by the rule:
//! - M1, at each accept: the destination's view at its last delivery holds the grant
//!   `S -> D:P` (`mesh_no_dst_check`, a destination that skips its accept check, breaks it).
//! - M2, at each tick: a connection whose grant is missing from either end's view is closed
//!   within `constants.mesh_revoke_ms` of that view's delivery (`mesh_revoke_late`, supervisors
//!   that leave open connections open, breaks it). A new connection on a grant the destination
//!   no longer holds is M1's.
//! - M4, at each attempt that reaches a destination supervisor: the replica was ready and not
//!   draining in the source's view, and, if accepted, in the destination's own
//!   (`mesh_route_unready`, endpoints that include unready replicas, breaks it). It is judged at
//!   the attempt, not only at the accept: the destination's own check refuses what the source
//!   should not have tried, and the brief's "reaches" is the source's choice.
//!
//! M5 (no failed request during a rollout) moved to slice 6 with the drain it needs
//! (docs/decisions/2026-11-15-c4-m5-to-slice-6.md). The model draws from its own generator, so a
//! mesh world's other draws are the ones a world without the mesh makes; the agent's mesh calls
//! do change the world (they go over the simulated network).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const mesh_plan = @import("mesh_plan.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const sim_certs = @import("sim_certs.zig");

/// The services of the simulated workload, which grant each other; `sim_cluster.service_names`.
pub const services = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
/// The ports grants name.
pub const ports = [_]u32{ 8080, 5432 };
/// A listener tries at most this many endpoints for one request.
pub const attempts_max: u32 = 3;
/// Open connections at most; a request past it is not made.
const conns_max = 256;
/// The supervisors whose rules the model holds at most (running mesh replicas over all nodes).
const held_max = 512;
/// Nodes the model knows (`sim_cluster.nodes_max`).
pub const nodes_max = 16;

comptime {
    assert(services.len <= std.math.maxInt(u8));
    assert(constants.mesh_revoke_ms >= 2 * 100); // Two ticks at least.
}

/// A grant as a view holds it, by service index.
const Grant = struct { from: u8, to: u8, port: u32 };

/// A replica as a view holds it.
const Peer = struct {
    id: []const u8,
    service: []const u8,
    endpoint: ?[]const u8,
    ready: bool,
    draining: bool,
};

/// What one supervisor holds: its last rules and the view they were planned from.
const Held = struct {
    arena: std.heap.ArenaAllocator,
    node: u32,
    name: []const u8,
    /// Its replica's service, by index; null when the view did not name it.
    service: ?u8,
    rules: runtime.MeshRules,
    grants: []const Grant,
    peers: []const Peer,
    /// The true time of the delivery.
    at_ms: u64,

    fn grants_hold(held: *const Held, grant: Grant) bool {
        for (held.grants) |known| {
            if (known.from == grant.from and known.to == grant.to and known.port == grant.port) {
                return true;
            }
        }
        return false;
    }

    fn peer(held: *const Held, id: []const u8) ?*const Peer {
        for (held.peers) |*known| {
            if (std.mem.eql(u8, known.id, id)) return known;
        }
        return null;
    }
};

const name_bytes_max = 64;

const Key = struct {
    node: u32,
    name_buf: [name_bytes_max]u8,
    name_len: u8,

    fn of(node: u32, text: []const u8) Key {
        assert(text.len <= name_bytes_max);
        var key: Key = .{ .node = node, .name_buf = undefined, .name_len = @intCast(text.len) };
        @memcpy(key.name_buf[0..text.len], text);
        return key;
    }

    fn name(key: *const Key) []const u8 {
        return key.name_buf[0..key.name_len];
    }
};

const Conn = struct {
    source: Key,
    destination: Key,
    grant: Grant,
    end_ms: u64,
    /// The true time an end received a view without the grant; null while both hold it.
    revoked_ms: ?u64 = null,
};

pub const State = struct {
    gpa: Allocator,
    prng: std.Random.DefaultPrng,
    /// The `mesh` profile: cuts between supervisors, and more grant churn.
    profile_mesh: bool,
    held: std.ArrayList(*Held) = .empty,
    conns: std.ArrayList(Conn) = .empty,
    /// The supervisor link between two nodes is cut until this true time (0: not cut).
    cut_until_ms: [nodes_max][nodes_max]u64 = @splat(@splat(0)),
    /// The report's tallies.
    requests: u32 = 0,
    accepted: u32 = 0,
    refused: u32 = 0,
    unreached: u32 = 0,
    failed: u32 = 0,
    revoked: u32 = 0,
    finished: u32 = 0,
    broken: u32 = 0,
    cuts: u32 = 0,
    grant_draws: u32 = 0,
    /// Direct dials that skipped the source's listeners, and those a destination accepted (each
    /// with a grant in its view, else M1 fails).
    rogues: u32 = 0,
    rogues_accepted: u32 = 0,
    /// The longest an open connection outlived the revocation of its grant, in ms.
    revoke_max_ms: u64 = 0,
    /// Endpoints delivered to a source whose view held the replica not ready or draining: M4's
    /// openings (none without the `mesh_route_unready` tooth).
    unready_routes: u64 = 0,
    /// The first of M1, M2 and M4 to fail; the cluster's safety check reports it.
    violation: ?[]const u8 = null,

    pub fn init(gpa: Allocator, seed: u64, profile_mesh: bool) State {
        return .{
            .gpa = gpa,
            .prng = .init(seed ^ 0xc4_c0_00_0000_0005),
            .profile_mesh = profile_mesh,
        };
    }

    pub fn deinit(state: *State) void {
        for (state.held.items) |held| {
            held.arena.deinit();
            state.gpa.destroy(held);
        }
        state.held.deinit(state.gpa);
        state.conns.deinit(state.gpa);
    }

    fn fail(state: *State, found: []const u8) void {
        if (state.violation == null) state.violation = found;
    }

    fn find(state: *State, node: u32, name: []const u8) ?*Held {
        for (state.held.items) |held| {
            if (held.node == node and std.mem.eql(u8, held.name, name)) return held;
        }
        return null;
    }
};

pub fn service_index(name: []const u8) ?u8 {
    for (services, 0..) |known, index| {
        if (std.mem.eql(u8, known, name)) return @intCast(index);
    }
    return null;
}

/// The grants a service holds after an apply, drawn afresh each time (grant churn): from each
/// other service, port 8080 one time in two and 5432 one time in four (in the `mesh` profile,
/// two in three and one in two). `buffer` holds the result.
pub fn draw_allow(state: *State, service: []const u8, buffer: []records.Grant) []records.Grant {
    assert(buffer.len >= (services.len - 1) * ports.len);
    const random = state.prng.random();
    state.grant_draws += 1;
    const per_mille: [ports.len]u32 = if (state.profile_mesh) .{ 667, 500 } else .{ 500, 250 };
    var count: usize = 0;
    for (services) |from| {
        if (std.mem.eql(u8, from, service)) continue;
        for (ports, per_mille) |port, chance| {
            if (random.uintLessThan(u32, 1000) >= chance) continue;
            buffer[count] = .{ .from = from, .port = port };
            count += 1;
        }
    }
    return buffer[0..count];
}

/// `SimRuntime.on_mesh`'s body: the supervisor of `name` on `node` now holds `rules`, planned
/// from `view` (null when the agent's step read none). Null `rules`: it holds none any more.
pub fn deliver(
    state: *State,
    node: u32,
    name: []const u8,
    labels: []const runtime.Label,
    rules: ?*const runtime.MeshRules,
    view: ?*const mesh_plan.Input,
    true_ms: u64,
) void {
    const found = state.find(node, name);
    const known = rules orelse {
        if (found) |held| forget(state, held);
        return;
    };
    const held = found orelse made: {
        if (state.held.items.len == held_max) return; // Beyond the model: not judged.
        const made = state.gpa.create(Held) catch return;
        made.* = .{
            .arena = .init(state.gpa),
            .node = node,
            .name = "",
            .service = null,
            .rules = .{},
            .grants = &.{},
            .peers = &.{},
            .at_ms = 0,
        };
        state.held.append(state.gpa, made) catch {
            state.gpa.destroy(made);
            return;
        };
        break :made made;
    };
    _ = held.arena.reset(.retain_capacity);
    held.at_ms = true_ms;
    copy(held, name, labels, known, view) catch {
        // Out of memory: the supervisor's rules are unknown, so it is left out of the model.
        forget(state, held);
        return;
    };
    for (held.rules.destinations) |destination| {
        for (destination.endpoints) |endpoint| {
            const peer = held.peer(endpoint.replica) orelse continue;
            if (!peer.ready or peer.draining) state.unready_routes += 1;
        }
    }
}

fn forget(state: *State, held: *Held) void {
    for (state.held.items, 0..) |known, index| {
        if (known != held) continue;
        _ = state.held.swapRemove(index);
        break;
    }
    held.arena.deinit();
    state.gpa.destroy(held);
}

fn copy(
    held: *Held,
    name: []const u8,
    labels: []const runtime.Label,
    rules: *const runtime.MeshRules,
    view: ?*const mesh_plan.Input,
) Allocator.Error!void {
    const arena = held.arena.allocator();
    held.name = try arena.dupe(u8, name);
    held.rules = try copy_rules(arena, rules);
    held.service = null;
    held.grants = &.{};
    held.peers = &.{};
    const input = view orelse return;
    var grants: std.ArrayList(Grant) = .empty;
    for (input.services) |service| {
        const to = service_index(service.name) orelse continue;
        for (service.allow) |grant| {
            const from = service_index(grant.from) orelse continue;
            try grants.append(arena, .{ .from = from, .to = to, .port = grant.port });
        }
    }
    const replica = sim_certs.label_of(labels, runtime.label_replica);
    var peers: std.ArrayList(Peer) = .empty;
    for (input.replicas) |known| {
        if (replica != null and std.mem.eql(u8, known.id, replica.?)) {
            held.service = service_index(known.service);
        }
        try peers.append(arena, .{
            .id = try arena.dupe(u8, known.id),
            .service = try arena.dupe(u8, known.service),
            .endpoint = if (known.endpoint) |text| try arena.dupe(u8, text) else null,
            .ready = known.readiness == .ready,
            .draining = known.draining,
        });
    }
    held.grants = grants.items;
    held.peers = peers.items;
}

fn copy_rules(arena: Allocator, rules: *const runtime.MeshRules) Allocator.Error!runtime.MeshRules {
    const destinations = try arena.alloc(runtime.MeshDestination, rules.destinations.len);
    for (destinations, rules.destinations) |*into, from| {
        const endpoints = try arena.alloc(runtime.MeshEndpoint, from.endpoints.len);
        for (endpoints, from.endpoints) |*endpoint, known| {
            endpoint.* = .{
                .replica = try arena.dupe(u8, known.replica),
                .endpoint = try arena.dupe(u8, known.endpoint),
            };
        }
        into.* = .{
            .service = try arena.dupe(u8, from.service),
            .address = try arena.dupe(u8, from.address),
            .endpoints = endpoints,
        };
    }
    const accepts_copy = try arena.alloc(runtime.MeshAccept, rules.accepts.len);
    for (accepts_copy, rules.accepts) |*into, from| {
        into.* = .{ .from = try arena.dupe(u8, from.from), .port = from.port, .open = from.open };
    }
    return .{
        .destinations = destinations,
        .listeners = try arena.dupe(runtime.MeshListener, rules.listeners),
        .accepts = accepts_copy,
    };
}

/// The host a node's supervisors listen on (`agent_mesh.Config.host`), `10.1.0.<index + 1>`.
pub fn host_of(index: u32, buffer: []u8) []const u8 {
    assert(index < nodes_max);
    return std.fmt.bufPrint(buffer, "10.1.0.{d}", .{index + 1}) catch unreachable; // 9 bytes.
}

const Address = struct { node: u32, port: u16 };

fn address_of(endpoint: []const u8) ?Address {
    const prefix = "10.1.0.";
    if (!std.mem.startsWith(u8, endpoint, prefix)) return null;
    const colon = std.mem.indexOfScalar(u8, endpoint, ':') orelse return null;
    const host = std.fmt.parseInt(u32, endpoint[prefix.len..colon], 10) catch return null;
    const port = std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10) catch return null;
    if (host == 0 or host > nodes_max) return null;
    return .{ .node = host - 1, .port = port };
}

/// One tick of every supervisor: cuts between supervisors (the `mesh` profile), revocation and
/// the end of connections (M2), then new requests (M1, M4). `nodes` are the cluster's.
pub fn tick(state: *State, nodes: anytype, true_ms: u64) void {
    if (state.profile_mesh) cut_maybe(state, @intCast(nodes.len), true_ms);
    tend(state, nodes, true_ms);
    for (state.held.items) |held| {
        if (held.rules.listeners.len == 0) continue;
        if (state.conns.items.len == conns_max) break;
        if (state.prng.random().uintLessThan(u32, 10) != 0) continue;
        const source = running(nodes, held.node, held.name) orelse continue;
        if (source.mesh_down) continue;
        request(state, nodes, held, true_ms);
    }
}

fn cut_maybe(state: *State, nodes: u32, true_ms: u64) void {
    if (nodes < 2) return;
    const random = state.prng.random();
    if (random.uintLessThan(u32, 200) != 0) return;
    const first = random.uintLessThan(u32, nodes);
    const second = random.uintLessThan(u32, nodes);
    if (first == second) return;
    const until = true_ms + 1000 + random.uintLessThan(u32, 9000);
    state.cut_until_ms[first][second] = until;
    state.cut_until_ms[second][first] = until;
    state.cuts += 1;
}

fn cut(state: *const State, first: u32, second: u32, true_ms: u64) bool {
    return state.cut_until_ms[first][second] > true_ms;
}

/// The container `name` on node `index` if it is running.
fn running(
    nodes: anytype,
    index: u32,
    name: []const u8,
) ?@TypeOf(&nodes[0].sim.containers.containers.items[0]) {
    if (index >= nodes.len) return null;
    for (nodes[index].sim.containers.containers.items) |*container| {
        if (container.phase != .running) continue;
        if (std.mem.eql(u8, container.name, name)) return container;
    }
    return null;
}

/// M2 and the end of connections: one whose end stopped, or whose time is up, is closed; one
/// whose grant an end's view lost is closed (unless `mesh_revoke_late`), and must not stay open
/// `mesh_revoke_ms` past that view's delivery.
fn tend(state: *State, nodes: anytype, true_ms: u64) void {
    var index: usize = 0;
    while (index < state.conns.items.len) {
        const conn = &state.conns.items[index];
        const closed = close_why(state, nodes, conn, true_ms);
        if (closed) {
            _ = state.conns.swapRemove(index);
        } else {
            index += 1;
        }
    }
}

fn close_why(state: *State, nodes: anytype, conn: *Conn, true_ms: u64) bool {
    const ends = [_]*const Key{ &conn.source, &conn.destination };
    for (ends) |end| {
        if (running(nodes, end.node, end.name()) == null) {
            state.broken += 1;
            return true;
        }
        const held = state.find(end.node, end.name()) orelse {
            state.broken += 1;
            return true;
        };
        if (conn.revoked_ms == null and !held.grants_hold(conn.grant)) {
            conn.revoked_ms = held.at_ms;
        }
    }
    if (cut(state, conn.source.node, conn.destination.node, true_ms)) {
        state.broken += 1;
        return true;
    }
    if (conn.revoked_ms) |since| {
        if (!c1_teeth.mesh_revoke_late) {
            state.revoked += 1;
            return true;
        }
        const late = true_ms -| since;
        state.revoke_max_ms = @max(state.revoke_max_ms, late);
        if (late > constants.mesh_revoke_ms) {
            state.fail("M2: a connection outlived its grant's revocation by more than " ++
                "mesh_revoke_ms");
        }
    }
    if (true_ms >= conn.end_ms) {
        state.finished += 1;
        return true;
    }
    return false;
}

/// One request from `source` on a listener drawn from its rules.
fn request(state: *State, nodes: anytype, source: *const Held, true_ms: u64) void {
    // Every draw is over u32, never usize: WASM's usize is 32 bits and would draw otherwise.
    const random = state.prng.random();
    if (random.uintLessThan(u32, 4) == 0) return rogue(state, nodes, source, true_ms);
    const rules = &source.rules;
    const listener = rules.listeners[random.uintLessThan(u32, @intCast(rules.listeners.len))];
    const destination = &rules.destinations[listener.destination];
    const from = source.service orelse return;
    const to = service_index(destination.service) orelse return;
    const grant: Grant = .{ .from = from, .to = to, .port = listener.port };
    state.requests += 1;
    var attempt: u32 = 0;
    for (destination.endpoints) |endpoint| {
        if (attempt == attempts_max) break;
        attempt += 1;
        const reached = reach(state, nodes, source, endpoint, true_ms) orelse continue;
        if (!accept(state, reached, grant, endpoint.replica)) continue;
        const long = random.uintLessThan(u32, 4) == 0;
        const span: u64 = if (long)
            2000 + random.uintLessThan(u32, 8000)
        else
            10 + random.uintLessThan(u32, 390);
        state.conns.append(state.gpa, .{
            .source = .of(source.node, source.name),
            .destination = .of(reached.node, reached.name),
            .grant = grant,
            .end_ms = true_ms + span,
        }) catch return;
        state.accepted += 1;
        return;
    }
    state.failed += 1;
}

/// A workload that skips its own supervisor's listeners and dials a peer's mesh port directly,
/// with a drawn port (M1's teeth: only the destination's grant check can refuse it). It picks a
/// replica of another service its view holds ready, so that M4's source side is not at issue.
fn rogue(state: *State, nodes: anytype, source: *const Held, true_ms: u64) void {
    const random = state.prng.random();
    const from = source.service orelse return;
    if (source.peers.len == 0) return;
    const peer = &source.peers[random.uintLessThan(u32, @intCast(source.peers.len))];
    const to = service_index(peer.service) orelse return;
    if (to == from or !peer.ready or peer.draining) return;
    const endpoint_text = peer.endpoint orelse return;
    const port = ports[random.uintLessThan(u32, ports.len)];
    const grant: Grant = .{ .from = from, .to = to, .port = port };
    state.rogues += 1;
    const endpoint: runtime.MeshEndpoint = .{ .replica = peer.id, .endpoint = endpoint_text };
    const reached = reach(state, nodes, source, endpoint, true_ms) orelse return;
    // An accepted dial is counted, not kept: the source's supervisor never held it, so M2 (judged
    // on both ends' views) does not apply to it.
    if (accept(state, reached, grant, peer.id)) state.rogues_accepted += 1;
}

/// The destination supervisor an attempt reaches: running, on the endpoint's port, for the
/// endpoint's replica, with no cut between the two nodes. M4's source side is judged here.
fn reach(
    state: *State,
    nodes: anytype,
    source: *const Held,
    endpoint: runtime.MeshEndpoint,
    true_ms: u64,
) ?*const Held {
    const address = address_of(endpoint.endpoint) orelse {
        state.unreached += 1;
        return null;
    };
    if (address.node >= nodes.len or cut(state, source.node, address.node, true_ms)) {
        state.unreached += 1;
        return null;
    }
    for (nodes[address.node].sim.containers.containers.items) |*container| {
        if (container.phase != .running) continue;
        if (container.mesh_port != address.port) continue;
        const replica = sim_certs.label_of(container.labels, runtime.label_replica) orelse
            continue;
        if (!std.mem.eql(u8, replica, endpoint.replica)) continue;
        if (container.mesh_down) break;
        const held = state.find(address.node, container.name) orelse break;
        const seen = source.peer(endpoint.replica);
        const ready = if (seen) |peer| peer.ready and !peer.draining else false;
        if (!ready) state.fail("M4: a connection reached a replica the source's view held " ++
            "not ready or draining");
        return held;
    }
    state.unreached += 1;
    return null;
}

/// The destination's check, then M1 and M4's destination side for what it accepts.
fn accept(state: *State, destination: *const Held, grant: Grant, replica: []const u8) bool {
    if (destination.service != grant.to) {
        state.refused += 1;
        return false;
    }
    const own = destination.peer(replica);
    const ready = if (own) |peer| peer.ready and !peer.draining else false;
    if (c1_teeth.mesh_no_dst_check) {
        // The M1 tooth skips the grant lookup only: a replica that is not open still refuses.
        if (!ready) {
            state.refused += 1;
            return false;
        }
    } else if (!accepts(destination, grant)) {
        state.refused += 1;
        return false;
    }
    if (!destination.grants_hold(grant)) {
        state.fail("M1: a connection was accepted without a grant in the destination's view");
    }
    if (!ready) state.fail("M4: a connection was accepted by a replica its own view held " ++
        "not ready or draining");
    return true;
}

fn accepts(destination: *const Held, grant: Grant) bool {
    const from = services[grant.from];
    for (destination.rules.accepts) |known| {
        if (known.port != grant.port) continue;
        if (!std.mem.eql(u8, known.from, from)) continue;
        return known.open;
    }
    return false;
}

const testing = std.testing;

test "draw_allow never grants a service to itself, and a seed draws the same grants" {
    // Goal: grant churn stays within the model's services and ports, and is a function of the
    // seed. Method: draw many times for one service from two states of one seed.
    var one: State = .init(testing.allocator, 7, true);
    defer one.deinit();
    var two: State = .init(testing.allocator, 7, true);
    defer two.deinit();
    var buffer_one: [(services.len - 1) * ports.len]records.Grant = undefined;
    var buffer_two: [(services.len - 1) * ports.len]records.Grant = undefined;
    for (0..100) |_| {
        const drawn = draw_allow(&one, "beta", &buffer_one);
        const again = draw_allow(&two, "beta", &buffer_two);
        try testing.expectEqual(drawn.len, again.len);
        for (drawn, again) |grant, same| {
            try testing.expect(!std.mem.eql(u8, grant.from, "beta"));
            try testing.expect(service_index(grant.from) != null);
            try testing.expect(grant.port == ports[0] or grant.port == ports[1]);
            try testing.expectEqualStrings(grant.from, same.from);
            try testing.expectEqual(grant.port, same.port);
        }
    }
    try testing.expectEqual(@as(u32, 100), one.grant_draws);
}

test "an endpoint's host names its node, and a foreign host names none" {
    var buffer: [16]u8 = undefined;
    const host = host_of(3, &buffer);
    try testing.expectEqualStrings("10.1.0.4", host);
    const address = address_of("10.1.0.4:30017").?;
    try testing.expectEqual(@as(u32, 3), address.node);
    try testing.expectEqual(@as(u16, 30017), address.port);
    try testing.expect(address_of("10.2.0.4:30017") == null);
    try testing.expect(address_of("10.1.0.4") == null);
}

test "a destination accepts only what a grant in its rules opens, and forgets on null rules" {
    // Goal: M1's destination check and the bookkeeping of what a supervisor holds. Method: deliver
    // alpha-1's rules and view (beta may reach it on 8080), try beta on 8080 and on 5432, then
    // deliver null rules.
    var state: State = .init(testing.allocator, 1, false);
    defer state.deinit();
    const grants = [_]records.Grant{.{ .from = "beta", .port = 8080 }};
    const view_services = [_]mesh_plan.Service{
        .{ .name = "alpha", .allow = &grants },
        .{ .name = "beta" },
    };
    const view_replicas = [_]mesh_plan.Replica{
        .{
            .id = "alpha-1",
            .service = "alpha",
            .node = "n1",
            .endpoint = "10.1.0.1:30000",
            .readiness = .ready,
        },
        .{
            .id = "beta-1",
            .service = "beta",
            .node = "n2",
            .endpoint = "10.1.0.2:30000",
            .readiness = .starting,
        },
    };
    const view: mesh_plan.Input = .{ .services = &view_services, .replicas = &view_replicas };
    const accepts_alpha = [_]runtime.MeshAccept{.{ .from = "beta", .port = 8080, .open = true }};
    const rules: runtime.MeshRules = .{ .accepts = &accepts_alpha };
    const labels = [_]runtime.Label{.{ .key = runtime.label_replica, .value = "alpha-1" }};
    deliver(&state, 0, "c-alpha-1", &labels, &rules, &view, 5);
    const held = state.find(0, "c-alpha-1").?;
    try testing.expectEqual(@as(?u8, 0), held.service);
    try testing.expectEqual(@as(usize, 1), held.grants.len);
    try testing.expect(!held.peer("beta-1").?.ready);
    const beta = service_index("beta").?;
    try testing.expect(accept(&state, held, .{ .from = beta, .to = 0, .port = 8080 }, "alpha-1"));
    try testing.expect(!accept(&state, held, .{ .from = beta, .to = 0, .port = 5432 }, "alpha-1"));
    try testing.expectEqual(@as(u32, 1), state.refused);
    try testing.expect(state.violation == null);
    deliver(&state, 0, "c-alpha-1", &labels, null, null, 6);
    try testing.expect(state.find(0, "c-alpha-1") == null);
}

test "an endpoint routed to a replica the view holds not ready is counted" {
    // Goal: the tally behind M4's tooth. Method: deliver rules whose destination lists beta-1,
    // which the view holds starting.
    var state: State = .init(testing.allocator, 1, false);
    defer state.deinit();
    const view_services = [_]mesh_plan.Service{ .{ .name = "alpha" }, .{ .name = "beta" } };
    const view_replicas = [_]mesh_plan.Replica{
        .{
            .id = "beta-1",
            .service = "beta",
            .node = "n2",
            .endpoint = "10.1.0.2:30000",
            .readiness = .starting,
        },
    };
    const view: mesh_plan.Input = .{ .services = &view_services, .replicas = &view_replicas };
    const endpoints = [_]runtime.MeshEndpoint{
        .{ .replica = "beta-1", .endpoint = "10.1.0.2:30000" },
    };
    const destinations = [_]runtime.MeshDestination{
        .{ .service = "beta", .address = "127.77.0.2", .endpoints = &endpoints },
    };
    const rules: runtime.MeshRules = .{ .destinations = &destinations };
    deliver(&state, 0, "c-alpha-1", &.{}, &rules, &view, 5);
    try testing.expectEqual(@as(u64, 1), state.unready_routes);
}
