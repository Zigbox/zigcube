//! The mesh plan (C4, docs/briefs/c4.md "Grants and their compilation"): from the grants, the
//! services and their replicas to one node's mesh rules. A pure function over plain inputs, so the
//! agent (from its watch), the simulator and `zcube why grant` (from a snapshot, `input_of`) all
//! compile the same rules.
//!
//! For a grant `S -> D:P` (an entry `{from = S, port = P}` in D's `allow`) the plan gives:
//!
//! - **listeners**: each replica of S on the node listens on `<D's mesh address>:P` inside its
//!   container, with D's endpoints to forward to;
//! - **accepts**: each replica of D on the node takes connections from S on P, and new ones only
//!   while it is ready and not draining.
//!
//! **Endpoints** are D's replicas that are ready, not draining and have published a mesh endpoint
//! (`/observed`'s `endpoint`). A listener tries those on its own node first, then the others; in
//! each group the order starts at a hash of the source replica's id, so load spreads without state
//! shared between replicas (`Destination.pick`).
//!
//! **No mesh without an address** (docs/decisions/2026-11-13-mesh-address-allocation.md): a grant
//! whose source or destination has no `mesh_address` (written before C4 and not applied since) is
//! not compiled, nor is a grant whose source does not exist (ZC-W0704: kept, so that services can
//! be applied in any order, and compiled once the source is created). `check` says why for one
//! grant, which is what `zcube why grant` shows.
//!
//! **Ready** is the C3 brief's readiness without its `min_ready_ms` timer, which C3's readiness
//! slice adds (docs/decisions/2026-11-13-c4-mesh-plan.md): reported running by the node it is
//! assigned to, at its generation, and, with a health check, last reported healthy.

const std = @import("std");
const assert = std.debug.assert;
const controller = @import("controller.zig");
const records = @import("records.zig");
const mesh_address = @import("mesh_address.zig");

const Allocator = std.mem.Allocator;

pub const Service = struct {
    name: []const u8,
    mesh_address: ?[]const u8 = null,
    allow: []const records.Grant = &.{},
};

/// Whether a replica is ready, and if not, the first reason it is not.
pub const Readiness = enum {
    ready,
    /// No node holds its assignment.
    not_assigned,
    /// The node it is assigned to has not reported it, at its generation.
    not_reported,
    starting,
    stopped,
    /// It declares a health check that has not last reported healthy.
    not_healthy,
};

pub const Replica = struct {
    id: []const u8,
    service: []const u8,
    /// The node it is assigned to, or (when draining) observed on; null while unassigned.
    node: ?[]const u8,
    /// Where its supervisor takes mesh connections, `<host>:<port>`; null until published.
    endpoint: ?[]const u8 = null,
    readiness: Readiness,
    /// Being stopped: it takes no new connections, and its open ones finish.
    draining: bool = false,
};

/// What `plan` and `check` read. `services` are in ascending order of name and `replicas` of
/// (id, node), each pair once; every replica's service is in `services`.
pub const Input = struct {
    services: []const Service,
    replicas: []const Replica,
};

/// Why a replica of a destination is not one of its endpoints.
pub const Exclusion = enum { not_ready, draining, no_endpoint };

pub fn exclusion_of(replica: *const Replica) ?Exclusion {
    if (replica.draining) return .draining;
    if (replica.readiness != .ready) return .not_ready;
    if (replica.endpoint == null) return .no_endpoint;
    assert(replica.node != null);
    return null;
}

pub const Endpoint = struct {
    replica: []const u8,
    node: []const u8,
    endpoint: []const u8,
};

/// A destination service the node's listeners forward to, with its endpoints.
pub const Destination = struct {
    service: []const u8,
    address: []const u8,
    /// Endpoints on the planning node, by replica id.
    local: []const Endpoint,
    /// Endpoints on other nodes, by replica id.
    remote: []const Endpoint,

    pub fn count(destination: *const Destination) u32 {
        return @intCast(destination.local.len + destination.remote.len);
    }

    /// The endpoint a listener tries at `attempt` (0 first), or null past the last: the local
    /// ones, then the remote ones, each group rotated to start at `hash`.
    pub fn pick(destination: *const Destination, hash: u64, attempt: u32) ?Endpoint {
        const local: u32 = @intCast(destination.local.len);
        const remote: u32 = @intCast(destination.remote.len);
        if (attempt < local) {
            const index = (hash % local + attempt) % local;
            return destination.local[@intCast(index)];
        }
        if (attempt < local + remote) {
            const index = (hash % remote + (attempt - local)) % remote;
            return destination.remote[@intCast(index)];
        }
        assert(attempt >= destination.count());
        return null;
    }
};

/// One listener inside a local replica of the source service.
pub const Listener = struct {
    /// The local replica it listens in.
    source: []const u8,
    /// Index into `Plan.destinations`.
    destination: u32,
    port: u16,
    /// The endpoint order (`Destination.pick`): a hash of `source`.
    hash: u64,
};

/// What one local replica of a destination takes.
pub const Accept = struct {
    replica: []const u8,
    from: []const u8,
    port: u16,
    /// Whether it takes new connections now: ready and not draining. Open ones stay either way;
    /// they are closed only when the grant goes.
    open: bool,
};

pub const Plan = struct {
    /// In ascending order of service name, those with a listener on the node.
    destinations: []const Destination,
    /// In ascending order of (source, destination, port).
    listeners: []const Listener,
    /// In ascending order of (replica, from, port).
    accepts: []const Accept,
};

/// The hash a listener's endpoint order starts at. Wyhash is the same on every target, so a
/// replica keeps its order across agents, the simulator and WASM.
pub fn order_hash(source: []const u8) u64 {
    assert(source.len > 0);
    return std.hash.Wyhash.hash(0, source);
}

/// Test-only faults, each of which a check of the plan must catch (`mesh_plan_fuzz.zig`).
pub const Faults = struct {
    /// Endpoints include replicas that are not ready (the M4 tooth's plan side).
    route_unready: bool = false,
};

/// The rules of `node`.
pub fn plan(arena: Allocator, input: *const Input, node: []const u8) Allocator.Error!Plan {
    return plan_with(arena, input, node, .{});
}

pub fn plan_with(
    arena: Allocator,
    input: *const Input,
    node: []const u8,
    faults: Faults,
) Allocator.Error!Plan {
    assert(node.len > 0);
    assert_input(input);
    var destinations: std.ArrayList(Destination) = .empty;
    var listeners: std.ArrayList(Listener) = .empty;
    var accepts: std.ArrayList(Accept) = .empty;
    for (input.services) |*destination| {
        const address = destination.mesh_address orelse continue;
        const index: u32 = @intCast(destinations.items.len);
        const before = listeners.items.len;
        for (destination.allow) |grant| {
            const source = compiled_source(input, destination, grant) orelse continue;
            const port = port_of(grant);
            try add_listeners(arena, &listeners, input, source, node, index, port);
            try add_accepts(arena, &accepts, input, destination.name, node, grant);
        }
        if (listeners.items.len > before) {
            try destinations.append(arena, try endpoints_of(arena, input, .{
                .service = destination.name,
                .address = address,
                .node = node,
                .faults = faults,
            }));
        }
    }
    std.mem.sort(Listener, listeners.items, destinations.items, listener_less);
    std.mem.sort(Accept, accepts.items, {}, accept_less);
    const result: Plan = .{
        .destinations = destinations.items,
        .listeners = listeners.items,
        .accepts = accepts.items,
    };
    assert_plan(&result);
    return result;
}

/// The source service of `grant` on `destination`, if the grant compiles: the source exists and
/// both have a mesh address.
fn compiled_source(
    input: *const Input,
    destination: *const Service,
    grant: records.Grant,
) ?*const Service {
    assert(destination.mesh_address != null);
    assert(!std.mem.eql(u8, grant.from, destination.name));
    const source = find_service(input, grant.from) orelse return null;
    if (source.mesh_address == null) return null;
    return source;
}

fn port_of(grant: records.Grant) u16 {
    assert(grant.port > 0);
    assert(grant.port <= std.math.maxInt(u16));
    return @intCast(grant.port);
}

fn add_listeners(
    arena: Allocator,
    listeners: *std.ArrayList(Listener),
    input: *const Input,
    source: *const Service,
    node: []const u8,
    destination: u32,
    port: u16,
) Allocator.Error!void {
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, source.name)) continue;
        const replica_node = replica.node orelse continue;
        if (!std.mem.eql(u8, replica_node, node)) continue;
        try listeners.append(arena, .{
            .source = replica.id,
            .destination = destination,
            .port = port,
            .hash = order_hash(replica.id),
        });
    }
}

fn add_accepts(
    arena: Allocator,
    accepts: *std.ArrayList(Accept),
    input: *const Input,
    destination: []const u8,
    node: []const u8,
    grant: records.Grant,
) Allocator.Error!void {
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, destination)) continue;
        const replica_node = replica.node orelse continue;
        if (!std.mem.eql(u8, replica_node, node)) continue;
        const open = replica.readiness == .ready and !replica.draining;
        try accepts.append(arena, .{
            .replica = replica.id,
            .from = grant.from,
            .port = port_of(grant),
            .open = open,
        });
    }
}

const EndpointsOptions = struct {
    service: []const u8,
    address: []const u8,
    node: []const u8,
    faults: Faults = .{},
};

fn endpoints_of(
    arena: Allocator,
    input: *const Input,
    options: EndpointsOptions,
) Allocator.Error!Destination {
    var local: std.ArrayList(Endpoint) = .empty;
    var remote: std.ArrayList(Endpoint) = .empty;
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, options.service)) continue;
        if (!eligible(replica, options.faults)) continue;
        const endpoint: Endpoint = .{
            .replica = replica.id,
            .node = replica.node.?,
            .endpoint = replica.endpoint.?,
        };
        const list = if (std.mem.eql(u8, endpoint.node, options.node)) &local else &remote;
        try list.append(arena, endpoint);
    }
    return .{
        .service = options.service,
        .address = options.address,
        .local = local.items,
        .remote = remote.items,
    };
}

fn eligible(replica: *const Replica, faults: Faults) bool {
    if (faults.route_unready) {
        // The tooth: readiness is ignored, draining and the endpoint are still required.
        if (replica.draining) return false;
        if (replica.node == null) return false;
        return replica.endpoint != null;
    }
    return exclusion_of(replica) == null;
}

fn listener_less(destinations: []const Destination, first: Listener, second: Listener) bool {
    switch (std.mem.order(u8, first.source, second.source)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const first_name = destinations[first.destination].service;
    const second_name = destinations[second.destination].service;
    switch (std.mem.order(u8, first_name, second_name)) {
        .lt => return true,
        .gt => return false,
        .eq => return first.port < second.port,
    }
}

fn accept_less(_: void, first: Accept, second: Accept) bool {
    switch (std.mem.order(u8, first.replica, second.replica)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, first.from, second.from)) {
        .lt => return true,
        .gt => return false,
        .eq => return first.port < second.port,
    }
}

pub fn find_service(input: *const Input, name: []const u8) ?*const Service {
    const Order = struct {
        fn compare(wanted: []const u8, item: Service) std.math.Order {
            return std.mem.order(u8, wanted, item.name);
        }
    };
    const index = std.sort.binarySearch(Service, input.services, name, Order.compare) orelse
        return null;
    return &input.services[index];
}

fn assert_input(input: *const Input) void {
    for (input.services, 0..) |service, index| {
        assert(service.name.len > 0);
        if (index > 0) {
            assert(std.mem.order(u8, input.services[index - 1].name, service.name) == .lt);
        }
    }
    for (input.replicas, 0..) |replica, index| {
        assert(find_service(input, replica.service) != null);
        if (replica.node == null) assert(replica.readiness == .not_assigned);
        if (index > 0) assert(replica_less({}, input.replicas[index - 1], replica));
    }
}

/// Ascending (id, node), the order `Input.replicas` is in; an unassigned replica comes first.
pub fn replica_less(_: void, first: Replica, second: Replica) bool {
    switch (std.mem.order(u8, first.id, second.id)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const second_node = second.node orelse return false;
    const first_node = first.node orelse return true;
    return std.mem.order(u8, first_node, second_node) == .lt;
}

fn assert_plan(result: *const Plan) void {
    for (result.listeners, 0..) |listener, index| {
        assert(listener.destination < result.destinations.len);
        assert(listener.port > 0);
        if (index > 0) {
            assert(listener_less(result.destinations, result.listeners[index - 1], listener));
        }
    }
    for (result.accepts, 1..) |accept, index| {
        if (index < result.accepts.len) {
            assert(accept_less({}, accept, result.accepts[index]));
        }
    }
    for (result.destinations) |destination| {
        for (destination.local) |endpoint| assert(endpoint.endpoint.len > 0);
        for (destination.remote) |endpoint| assert(endpoint.endpoint.len > 0);
    }
}

// ---- One grant: what `zcube why grant` shows ----

/// What `check` found, in the order it looks: the first that applies.
pub const Verdict = enum {
    /// Connections from the source to the destination's port are forwarded.
    granted,
    /// No service has the destination's name.
    no_destination,
    /// The destination's `allow` has no such grant (ZC-E0707).
    no_grant,
    /// The grant names a source that does not exist (ZC-W0704).
    no_source,
    /// The destination has no mesh address yet.
    destination_has_no_address,
    /// The source has no mesh address yet.
    source_has_no_address,
    /// The grant compiles, and the destination has no endpoint (ZC-E0709).
    no_endpoint,
};

pub const Excluded = struct {
    replica: []const u8,
    node: ?[]const u8,
    exclusion: Exclusion,
    readiness: Readiness,
};

pub const Check = struct {
    verdict: Verdict,
    /// The destination's endpoints, by replica id, on any node.
    endpoints: []const Endpoint = &.{},
    /// Its other replicas, by replica id, and why each is not an endpoint.
    excluded: []const Excluded = &.{},
};

pub const GrantQuery = struct {
    from: []const u8,
    to: []const u8,
    port: u16,
};

/// Whether `query.from` may connect to `query.to` on `query.port` now, and the destination's
/// endpoints.
pub fn check(arena: Allocator, input: *const Input, query: GrantQuery) Allocator.Error!Check {
    assert(query.port > 0);
    assert_input(input);
    const destination = find_service(input, query.to) orelse return .{ .verdict = .no_destination };
    var endpoints: std.ArrayList(Endpoint) = .empty;
    var excluded: std.ArrayList(Excluded) = .empty;
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, destination.name)) continue;
        if (exclusion_of(replica)) |exclusion| {
            try excluded.append(arena, .{
                .replica = replica.id,
                .node = replica.node,
                .exclusion = exclusion,
                .readiness = replica.readiness,
            });
        } else {
            try endpoints.append(arena, .{
                .replica = replica.id,
                .node = replica.node.?,
                .endpoint = replica.endpoint.?,
            });
        }
    }
    const result: Check = .{
        .verdict = verdict_of(input, destination, query, endpoints.items.len),
        .endpoints = endpoints.items,
        .excluded = excluded.items,
    };
    if (result.verdict == .granted) assert(result.endpoints.len > 0);
    return result;
}

fn verdict_of(
    input: *const Input,
    destination: *const Service,
    query: GrantQuery,
    endpoints: usize,
) Verdict {
    assert(std.mem.eql(u8, destination.name, query.to));
    const grant: records.Grant = .{ .from = query.from, .port = query.port };
    if (!records.grants_contain(destination.allow, grant)) return .no_grant;
    const source = find_service(input, query.from) orelse return .no_source;
    if (destination.mesh_address == null) return .destination_has_no_address;
    if (source.mesh_address == null) return .source_has_no_address;
    if (endpoints == 0) return .no_endpoint;
    return .granted;
}

// ---- From a snapshot ----

/// The plan's input as the store holds it at `snapshot`'s revision. A replica whose
/// `/replicas/` record is gone while its node still reports it running is draining: the replica
/// controller has stopped it and its node has not finished. No (id, node) pair repeats: a desired
/// replica is listed once, and a draining one once per `/observed/<node>/` record.
pub fn input_of(arena: Allocator, snapshot: *const controller.Snapshot) Allocator.Error!Input {
    const services = try arena.alloc(Service, snapshot.services.len);
    for (snapshot.services, services) |entry, *service| {
        service.* = .{
            .name = entry.rec.name,
            .mesh_address = entry.rec.mesh_address,
            .allow = entry.rec.allow,
        };
    }
    var replicas: std.ArrayList(Replica) = .empty;
    var desired: std.StringHashMapUnmanaged(void) = .empty;
    for (snapshot.replicas) |*entry| {
        try desired.put(arena, entry.rec.id, {});
        try replicas.append(arena, replica_of_snapshot(snapshot, &entry.rec));
    }
    for (snapshot.observed) |*entry| {
        if (desired.contains(entry.rec.replica)) continue;
        if (entry.rec.status == .stopped) continue;
        const service = service_of_replica(services, entry.rec.replica) orelse continue;
        try replicas.append(arena, .{
            .id = entry.rec.replica,
            .service = service,
            .node = entry.rec.node,
            .endpoint = entry.rec.endpoint,
            .readiness = if (entry.rec.status == .running) .ready else .starting,
            .draining = true,
        });
    }
    std.mem.sort(Replica, replicas.items, {}, replica_less);
    const result: Input = .{
        .services = services,
        .replicas = replicas.items,
    };
    assert_input(&result);
    return result;
}

fn replica_of_snapshot(
    snapshot: *const controller.Snapshot,
    replica: *const records.Replica,
) Replica {
    const node = snapshot.node_of(replica.id) orelse return .{
        .id = replica.id,
        .service = replica.service,
        .node = null,
        .readiness = .not_assigned,
    };
    const assigned = snapshot.assigned_of(replica.id).?;
    const observed = snapshot.observed_of(replica);
    var result: Replica = .{
        .id = replica.id,
        .service = replica.service,
        .node = node,
        .readiness = .not_reported,
    };
    // The record on the assigned node, for this generation. A replica's report names no epoch
    // (only a job's does), so one that does must name this placement's.
    const entry = observed orelse return result;
    if (entry.rec.generation != replica.generation) return result;
    if (entry.rec.assignment) |epoch| {
        if (epoch != assigned.kv.mod_revision) return result;
    }
    result.endpoint = entry.rec.endpoint;
    result.readiness = switch (entry.rec.status) {
        .starting => .starting,
        .stopped => .stopped,
        .running => if (replica.health == null or entry.rec.health == .healthy)
            .ready
        else
            .not_healthy,
    };
    return result;
}

/// The service a replica id belongs to (`<service>-<n>`): at most one name matches, since the
/// part after the service's name is digits only.
fn service_of_replica(services: []const Service, replica: []const u8) ?[]const u8 {
    for (services) |service| {
        if (mesh_address.replica_of(replica, service.name)) return service.name;
    }
    return null;
}

// ---- Tests ----

const testing = std.testing;

const web_to_db = [_]records.Grant{.{ .from = "web", .port = 5432 }};

fn ready(id: []const u8, service: []const u8, node: []const u8, endpoint: []const u8) Replica {
    return .{
        .id = id,
        .service = service,
        .node = node,
        .endpoint = endpoint,
        .readiness = .ready,
    };
}

/// `web` and `batch` on n1 and n2, `db` granted to `web` on 5432, with one replica on n2.
fn demo_services() [3]Service {
    return .{
        .{ .name = "batch", .mesh_address = "127.77.0.3" },
        .{ .name = "db", .mesh_address = "127.77.0.2", .allow = &web_to_db },
        .{ .name = "web", .mesh_address = "127.77.0.1" },
    };
}

test "mesh plan: a grant gives the source's local replicas listeners, the destination accepts" {
    // Goal: the two halves of `web -> db:5432` land on the nodes that hold each end, and
    // nothing else is planned (default deny: batch has no listener). Method: plan n1 and n2 of
    // the demo's layout and compare every member.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const services = demo_services();
    const replicas = [_]Replica{
        ready("batch-1", "batch", "n1", "10.0.0.1:30001"),
        ready("db-1", "db", "n2", "10.0.0.2:30000"),
        ready("web-1", "web", "n1", "10.0.0.1:30000"),
        ready("web-2", "web", "n2", "10.0.0.2:30001"),
    };
    const input: Input = .{ .services = &services, .replicas = &replicas };
    const one = try plan(arena, &input, "n1");
    try testing.expectEqual(@as(usize, 1), one.destinations.len);
    try testing.expectEqualStrings("127.77.0.2", one.destinations[0].address);
    try testing.expectEqual(@as(usize, 0), one.destinations[0].local.len);
    try testing.expectEqualStrings("db-1", one.destinations[0].remote[0].replica);
    try testing.expectEqual(@as(usize, 1), one.listeners.len);
    try testing.expectEqualStrings("web-1", one.listeners[0].source);
    try testing.expectEqual(@as(u16, 5432), one.listeners[0].port);
    try testing.expectEqual(@as(usize, 0), one.accepts.len);
    const two = try plan(arena, &input, "n2");
    try testing.expectEqual(@as(usize, 1), two.listeners.len);
    try testing.expectEqualStrings("web-2", two.listeners[0].source);
    try testing.expectEqualStrings("db-1", two.destinations[0].local[0].replica);
    try testing.expectEqual(@as(usize, 1), two.accepts.len);
    try testing.expectEqualStrings("db-1", two.accepts[0].replica);
    try testing.expectEqualStrings("web", two.accepts[0].from);
    try testing.expect(two.accepts[0].open);
    const three = try plan(arena, &input, "n3");
    try testing.expectEqual(@as(usize, 0), three.listeners.len);
    try testing.expectEqual(@as(usize, 0), three.accepts.len);
}

test "mesh plan: only ready replicas that are not draining and have an endpoint are endpoints" {
    // Goal: each exclusion rule, and that a destination replica that is not ready or draining
    // still accepts its grants but takes no new connection. Method: db with one replica per
    // state on n2; compare the endpoint list, the accepts and `check`'s exclusions.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const services = demo_services();
    var draining = ready("db-2", "db", "n2", "10.0.0.2:30002");
    draining.draining = true;
    var starting = ready("db-3", "db", "n2", "10.0.0.2:30003");
    starting.readiness = .starting;
    var silent = ready("db-4", "db", "n2", "");
    silent.endpoint = null;
    const unassigned: Replica = .{
        .id = "db-5",
        .service = "db",
        .node = null,
        .readiness = .not_assigned,
    };
    const replicas = [_]Replica{
        ready("db-1", "db", "n2", "10.0.0.2:30001"), draining,   starting,
        silent,                                      unassigned, ready("web-1", "web", "n1", "x:1"),
    };
    const input: Input = .{ .services = &services, .replicas = &replicas };
    const one = try plan(arena, &input, "n1");
    try testing.expectEqual(@as(u32, 1), one.destinations[0].count());
    try testing.expectEqualStrings("db-1", one.destinations[0].remote[0].replica);
    const two = try plan(arena, &input, "n2");
    try testing.expectEqual(@as(usize, 4), two.accepts.len);
    const open = [_]bool{ true, false, false, true };
    for (two.accepts, open) |accept, want| try testing.expectEqual(want, accept.open);
    const found = try check(arena, &input, .{ .from = "web", .to = "db", .port = 5432 });
    try testing.expectEqual(Verdict.granted, found.verdict);
    try testing.expectEqual(@as(usize, 1), found.endpoints.len);
    const exclusions = [_]Exclusion{ .draining, .not_ready, .no_endpoint, .not_ready };
    try testing.expectEqual(exclusions.len, found.excluded.len);
    for (found.excluded, exclusions) |item, want| try testing.expectEqual(want, item.exclusion);
}

test "mesh plan: a service with no address, or a grant from no service, compiles to nothing" {
    // Goal: the no-mesh rules (docs/decisions/2026-11-13-mesh-address-allocation.md) and W0704's
    // case, at both ends: no listener, no accept, and `check` names the first that applies.
    // Method: four layouts of the same grant, each planned on the node that holds both ends.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const replicas = [_]Replica{
        ready("db-1", "db", "n1", "10.0.0.1:30001"),
        ready("web-1", "web", "n1", "10.0.0.1:30000"),
    };
    const Case = struct { db: ?[]const u8, web: ?[]const u8, verdict: Verdict };
    const cases = [_]Case{
        .{ .db = null, .web = "127.77.0.1", .verdict = .destination_has_no_address },
        .{ .db = "127.77.0.2", .web = null, .verdict = .source_has_no_address },
        .{ .db = null, .web = null, .verdict = .destination_has_no_address },
        .{ .db = "127.77.0.2", .web = "127.77.0.1", .verdict = .granted },
    };
    for (cases) |case| {
        const services = [_]Service{
            .{ .name = "db", .mesh_address = case.db, .allow = &web_to_db },
            .{ .name = "web", .mesh_address = case.web },
        };
        const input: Input = .{ .services = &services, .replicas = &replicas };
        const result = try plan(arena, &input, "n1");
        const compiled: usize = if (case.verdict == .granted) 1 else 0;
        try testing.expectEqual(compiled, result.listeners.len);
        try testing.expectEqual(compiled, result.accepts.len);
        const found = try check(arena, &input, .{ .from = "web", .to = "db", .port = 5432 });
        try testing.expectEqual(case.verdict, found.verdict);
    }
    const lonely = [_]Service{.{ .name = "db", .mesh_address = "127.77.0.2", .allow = &web_to_db }};
    const alone = [_]Replica{replicas[0]};
    const input: Input = .{ .services = &lonely, .replicas = &alone };
    const result = try plan(arena, &input, "n1");
    try testing.expectEqual(@as(usize, 0), result.accepts.len);
    const found = try check(arena, &input, .{ .from = "web", .to = "db", .port = 5432 });
    try testing.expectEqual(Verdict.no_source, found.verdict);
}

test "mesh plan: check's verdicts, in the order it looks" {
    // Goal: no destination, no grant (another port, another source), no endpoint, granted.
    // Method: the demo's services with db's one replica present or not.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const services = demo_services();
    const with = [_]Replica{ready("db-1", "db", "n2", "10.0.0.2:30000")};
    const input: Input = .{ .services = &services, .replicas = &with };
    const empty: Input = .{ .services = &services, .replicas = &.{} };
    const Case = struct {
        input: *const Input,
        from: []const u8,
        to: []const u8,
        port: u16,
        verdict: Verdict,
    };
    const cases = [_]Case{
        .{ .input = &input, .from = "web", .to = "cache", .port = 1, .verdict = .no_destination },
        .{ .input = &input, .from = "batch", .to = "db", .port = 5432, .verdict = .no_grant },
        .{ .input = &input, .from = "web", .to = "db", .port = 5433, .verdict = .no_grant },
        .{ .input = &empty, .from = "web", .to = "db", .port = 5432, .verdict = .no_endpoint },
        .{ .input = &input, .from = "web", .to = "db", .port = 5432, .verdict = .granted },
    };
    for (cases) |case| {
        const query: GrantQuery = .{ .from = case.from, .to = case.to, .port = case.port };
        const found = try check(arena, case.input, query);
        try testing.expectEqual(case.verdict, found.verdict);
    }
}

test "mesh plan: pick tries local endpoints first, then remote, each once, from the hash" {
    // Goal: the endpoint order: every endpoint exactly once, the local group before the remote
    // one, and the start of each group moved by the hash. Method: two local and three remote
    // endpoints under several hashes; null past the last.
    const local = [_]Endpoint{
        .{ .replica = "db-1", .node = "n1", .endpoint = "a:1" },
        .{ .replica = "db-2", .node = "n1", .endpoint = "a:2" },
    };
    const remote = [_]Endpoint{
        .{ .replica = "db-3", .node = "n2", .endpoint = "b:1" },
        .{ .replica = "db-4", .node = "n3", .endpoint = "c:1" },
        .{ .replica = "db-5", .node = "n3", .endpoint = "c:2" },
    };
    const destination: Destination = .{
        .service = "db",
        .address = "127.77.0.2",
        .local = &local,
        .remote = &remote,
    };
    for ([_]u64{ 0, 1, 2, 7, std.math.maxInt(u64) }) |hash| {
        var seen: [5]bool = @splat(false);
        for (0..5) |attempt| {
            const endpoint = destination.pick(hash, @intCast(attempt)).?;
            const index = endpoint.replica[3] - '1';
            try testing.expect(!seen[index]);
            seen[index] = true;
            try testing.expectEqual(attempt < 2, std.mem.eql(u8, endpoint.node, "n1"));
        }
        try testing.expectEqual(@as(?Endpoint, null), destination.pick(hash, 5));
    }
    try testing.expectEqualStrings("db-2", destination.pick(1, 0).?.replica);
    try testing.expectEqualStrings("db-4", destination.pick(1, 2).?.replica);
    try testing.expectEqualStrings("db-3", destination.pick(3, 2).?.replica);
    const none: Destination = .{ .service = "db", .address = "x", .local = &.{}, .remote = &.{} };
    try testing.expectEqual(@as(?Endpoint, null), none.pick(9, 0));
}
