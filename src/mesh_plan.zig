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
//! **Ready** is the C3 brief's readiness without its `min_ready_ms` dwell, which C3's readiness
//! slice adds (docs/decisions/2026-11-13-c4-mesh-plan.md): reported running by the node it is
//! assigned to, at its generation, in a report the controllers may act on (the node's tenure and
//! the placement's epoch, the node `ready`: `controller.Snapshot.admission`, the replica
//! controller's own rule) and, with a health check, last reported healthy.

const std = @import("std");
const builtin = @import("builtin");
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
    /// Its node's report is from another tenure of the node (it has registered again since) or
    /// names another placement: the controllers do not act on it, nor does the plan.
    stale_report,
    /// The node controller has not judged its node `ready` (lost, or not judged yet).
    node_not_ready,
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
    return compile(arena, input, node, .{});
}

/// `plan` with test-only faults on (the fuzzer's teeth). It exists only in a test build: in any
/// other it is `void`, so no production caller can reach the faults.
pub const plan_with = if (builtin.is_test) compile else {};

fn compile(
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

/// The plan's input as the store holds it at `snapshot`'s revision.
///
/// - A desired replica (`/replicas/`) is listed once, on the node it is assigned to (or none),
///   with its readiness (`replica_of_snapshot`). One whose service is gone is left out: deleting
///   a service leaves its replicas until the replica controller's next pass, and the plan knows
///   only the services that exist.
/// - A copy that is not stopped and that its node still reports (`/observed/<node>/`), where the
///   replica is not desired (the replica controller removed it) or is assigned to another node
///   (it moved), is draining: listed once per (replica, node), never an endpoint, and its
///   accepts take no new connection. A report on the assigned node at another generation is the
///   replica itself being replaced in place, not a copy.
///
/// So no (id, node) pair repeats.
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
        if (snapshot.service_of(entry.rec.service) == null) continue; // An orphan.
        try desired.put(arena, entry.rec.id, {});
        try replicas.append(arena, replica_of_snapshot(snapshot, &entry.rec));
    }
    for (snapshot.observed) |*entry| {
        if (entry.rec.status == .stopped) continue;
        if (desired.contains(entry.rec.replica)) {
            const assigned = snapshot.node_of(entry.rec.replica);
            if (assigned != null and std.mem.eql(u8, assigned.?, entry.rec.node)) continue;
        }
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
    var result: Replica = .{
        .id = replica.id,
        .service = replica.service,
        .node = node,
        .readiness = .not_reported,
    };
    // The record on the assigned node, if the controllers may act on it, for this generation.
    const entry = snapshot.observed_of(replica) orelse return result;
    assert(std.mem.eql(u8, entry.rec.node, node));
    switch (snapshot.admission(entry)) {
        .admitted => {},
        .stale_tenure, .stale_epoch => {
            result.readiness = .stale_report;
            return result;
        },
        .node_not_ready => {
            result.readiness = .node_not_ready;
            return result;
        },
    }
    if (entry.rec.generation != replica.generation) return result;
    result.endpoint = entry.rec.endpoint;
    // TODO(C3 readiness): `min_ready_ms`'s dwell; this switches to C3's readiness function then
    // (docs/decisions/2026-11-13-c4-mesh-plan.md).
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

// ---- Tests of `input_of`, over a snapshot built by hand ----

const store = @import("store.zig");

/// A `controller.Snapshot` built record by record, each list sorted by key as the store lists it.
const SnapshotFixture = struct {
    arena: Allocator,
    services: std.ArrayList(controller.Entry(records.Service)) = .empty,
    replicas: std.ArrayList(controller.Entry(records.Replica)) = .empty,
    observed: std.ArrayList(controller.Entry(records.Observed)) = .empty,
    nodes: std.ArrayList(controller.Entry(records.Node)) = .empty,
    assigned: std.ArrayList(controller.Entry(records.Assigned)) = .empty,
    statuses: std.ArrayList(controller.Entry(records.NodeStatus)) = .empty,
    by_replica: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn kv(fixture: *SnapshotFixture, key: records.Key, revision: u64) !store.KeyValue {
        return .{
            .key = try fixture.arena.dupe(u8, key.slice()),
            .value = "",
            .create_revision = revision,
            .mod_revision = revision,
        };
    }

    fn service(fixture: *SnapshotFixture, rec: records.Service) !void {
        const kv_made = try fixture.kv(records.service_key(rec.name), 1);
        try fixture.services.append(fixture.arena, .{ .kv = kv_made, .rec = rec });
    }

    /// A node registered at `revision` (its tenure), judged `state` for that tenure.
    fn node(
        fixture: *SnapshotFixture,
        name: []const u8,
        revision: u64,
        state: records.NodeState,
    ) !void {
        try fixture.nodes.append(fixture.arena, .{
            .kv = try fixture.kv(records.node_key(name), revision),
            .rec = .{ .name = name, .capacity = .{ .cpu_millis = 1000, .memory_bytes = 1 << 30 } },
        });
        try fixture.statuses.append(fixture.arena, .{
            .kv = try fixture.kv(records.node_status_key(name), revision + 1),
            .rec = .{ .state = state, .tenure = revision, .at_ms = 0, .decision = "d" },
        });
    }

    fn replica(fixture: *SnapshotFixture, rec: records.Replica) !void {
        try fixture.replicas.append(fixture.arena, .{
            .kv = try fixture.kv(records.replica_key(rec.service, rec.id), 2),
            .rec = rec,
        });
    }

    fn assign(
        fixture: *SnapshotFixture,
        node_name: []const u8,
        id: []const u8,
        revision: u64,
    ) !void {
        try fixture.assigned.append(fixture.arena, .{
            .kv = try fixture.kv(records.assigned_key(node_name, id), revision),
            .rec = .{
                .replica = id,
                .requests = .{ .cpu_millis = 1, .memory_bytes = 1 },
                .reason = "r",
            },
        });
        try fixture.by_replica.put(fixture.arena, id, node_name);
    }

    fn observe(fixture: *SnapshotFixture, rec: records.Observed) !void {
        try fixture.observed.append(fixture.arena, .{
            .kv = try fixture.kv(records.observed_key(rec.node, rec.replica), 40),
            .rec = rec,
        });
    }

    fn snapshot(fixture: *SnapshotFixture) controller.Snapshot {
        sort(records.Service, fixture.services.items);
        sort(records.Replica, fixture.replicas.items);
        sort(records.Observed, fixture.observed.items);
        sort(records.Node, fixture.nodes.items);
        sort(records.Assigned, fixture.assigned.items);
        sort(records.NodeStatus, fixture.statuses.items);
        return .{
            .revision = 50,
            .services = fixture.services.items,
            .replicas = fixture.replicas.items,
            .observed = fixture.observed.items,
            .nodes = fixture.nodes.items,
            .assigned = fixture.assigned.items,
            .statuses = fixture.statuses.items,
            .node_by_replica = fixture.by_replica,
        };
    }

    fn sort(comptime T: type, items: []controller.Entry(T)) void {
        const Order = struct {
            fn less(_: void, first: controller.Entry(T), second: controller.Entry(T)) bool {
                return std.mem.order(u8, first.kv.key, second.kv.key) == .lt;
            }
        };
        std.mem.sort(controller.Entry(T), items, {}, Order.less);
    }
};

const health_check: records.Health = .{
    .command = &.{"true"},
    .interval_ms = 1000,
    .timeout_ms = 1000,
    .failure_threshold = 3,
    .success_threshold = 1,
};

fn service_record(
    name: []const u8,
    address: []const u8,
    allow: []const records.Grant,
) records.Service {
    return .{
        .name = name,
        .image = "b3:51aa9c03",
        .replicas = 1,
        .command = &.{"sh"},
        .generation = 2,
        .mesh_address = address,
        .allow = allow,
    };
}

fn replica_record(id: []const u8, service: []const u8) records.Replica {
    return .{
        .id = id,
        .service = service,
        .generation = 2,
        .image = "b3:51aa9c03",
        .command = &.{"sh"},
    };
}

/// db-1's report on n1 (tenure 10, placement 30), running and healthy at generation 2.
fn report(replica: []const u8, node: []const u8) records.Observed {
    return .{
        .replica = replica,
        .node = node,
        .generation = 2,
        .status = .running,
        .reported_at_ms = 1,
        .tenure = 10,
        .assignment = 30,
        .health = .healthy,
        .endpoint = "10.0.0.1:30000",
    };
}

test "mesh plan: input_of's readiness, one rule per case" {
    // Goal: each rule of a replica's readiness from a snapshot (generation, the node's tenure and
    // the placement epoch, the node `ready`, the health check, the status, the assignment), and
    // that only a ready replica is an endpoint. Method: one replica of db, assigned to n1 (tenure
    // 10) at revision 30; each case changes one fact of the base, which is ready.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct {
        generation: u64 = 2,
        tenure: ?u64 = 10,
        assignment: ?u64 = 30,
        node_state: records.NodeState = .ready,
        status: records.ObservedStatus = .running,
        health: ?records.HealthState = .healthy,
        check: bool = true,
        assigned: bool = true,
        reported: bool = true,
        readiness: Readiness,
    };
    const cases = [_]Case{
        .{ .readiness = .ready },
        .{ .generation = 1, .readiness = .not_reported },
        .{ .assignment = 29, .readiness = .stale_report },
        .{ .tenure = 9, .readiness = .stale_report },
        .{ .node_state = .lost, .readiness = .node_not_ready },
        .{ .node_state = .fenced, .readiness = .node_not_ready },
        .{ .health = .unhealthy, .readiness = .not_healthy },
        .{ .health = .unknown, .readiness = .not_healthy },
        .{ .health = null, .readiness = .not_healthy },
        .{ .check = false, .health = null, .readiness = .ready },
        .{ .status = .starting, .readiness = .starting },
        .{ .status = .stopped, .readiness = .stopped },
        .{ .assigned = false, .reported = false, .readiness = .not_assigned },
        .{ .reported = false, .readiness = .not_reported },
        // A C0 report names no tenure nor epoch, and is taken as it is.
        .{ .tenure = null, .assignment = null, .node_state = .lost, .readiness = .ready },
    };
    const allow = [_]records.Grant{.{ .from = "web", .port = 5432 }};
    for (cases) |case| {
        var fixture: SnapshotFixture = .{ .arena = arena };
        var db = service_record("db", "127.77.0.2", &allow);
        if (case.check) db.health = health_check;
        try fixture.service(db);
        try fixture.service(service_record("web", "127.77.0.1", &.{}));
        try fixture.node("n1", 10, case.node_state);
        var replica = replica_record("db-1", "db");
        replica.health = db.health;
        try fixture.replica(replica);
        if (case.assigned) try fixture.assign("n1", "db-1", 30);
        if (case.reported) {
            var observed = report("db-1", "n1");
            observed.generation = case.generation;
            observed.tenure = case.tenure;
            observed.assignment = case.assignment;
            observed.status = case.status;
            observed.health = case.health;
            try fixture.observe(observed);
        }
        const snapshot = fixture.snapshot();
        const input = try input_of(arena, &snapshot);
        try testing.expectEqual(@as(usize, 1), input.replicas.len);
        const got = input.replicas[0];
        try testing.expectEqual(case.readiness, got.readiness);
        try testing.expect(!got.draining);
        const found = try check(arena, &input, .{ .from = "web", .to = "db", .port = 5432 });
        const verdict: Verdict = if (case.readiness == .ready) .granted else .no_endpoint;
        try testing.expectEqual(verdict, found.verdict);
    }
}

test "mesh plan: input_of drains removed and moved copies, drops stopped ones and orphans" {
    // Goal: the copies input_of lists besides the desired replicas: a replica the controller
    // removed and one that moved drain (never endpoints, accepts closed); a stopped copy and the
    // replicas of a deleted service (left until the controller's next pass) are not listed, so
    // nothing reaches `assert_input` with a service it does not know. Method: db-1 moved from n1
    // to n2, db-2 removed, db-3 removed and stopped, gone-1 and gone-2 of a deleted service.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const allow = [_]records.Grant{.{ .from = "web", .port = 5432 }};
    var fixture: SnapshotFixture = .{ .arena = arena };
    try fixture.service(service_record("db", "127.77.0.2", &allow));
    try fixture.service(service_record("web", "127.77.0.1", &.{}));
    try fixture.node("n1", 10, .ready);
    try fixture.node("n2", 20, .ready);
    try fixture.replica(replica_record("db-1", "db"));
    try fixture.assign("n2", "db-1", 30);
    var moved_to = report("db-1", "n2");
    moved_to.tenure = 20;
    moved_to.endpoint = "10.0.0.2:30000";
    try fixture.observe(moved_to);
    try fixture.observe(report("db-1", "n1"));
    try fixture.observe(report("db-2", "n1"));
    var stopped = report("db-3", "n1");
    stopped.status = .stopped;
    try fixture.observe(stopped);
    try fixture.replica(replica_record("gone-1", "gone"));
    try fixture.assign("n1", "gone-1", 31);
    try fixture.observe(report("gone-1", "n1"));
    try fixture.observe(report("gone-2", "n1"));
    const snapshot = fixture.snapshot();
    const input = try input_of(arena, &snapshot);

    const Want = struct { id: []const u8, node: []const u8, draining: bool };
    const wanted = [_]Want{
        .{ .id = "db-1", .node = "n1", .draining = true },
        .{ .id = "db-1", .node = "n2", .draining = false },
        .{ .id = "db-2", .node = "n1", .draining = true },
    };
    try testing.expectEqual(wanted.len, input.replicas.len);
    for (input.replicas, wanted) |got, want| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqualStrings(want.node, got.node.?);
        try testing.expectEqual(want.draining, got.draining);
    }
    const one = try plan(arena, &input, "n1");
    try testing.expectEqual(@as(usize, 2), one.accepts.len);
    for (one.accepts) |accept| try testing.expect(!accept.open);
    const found = try check(arena, &input, .{ .from = "web", .to = "db", .port = 5432 });
    try testing.expectEqual(Verdict.granted, found.verdict);
    try testing.expectEqual(@as(usize, 1), found.endpoints.len);
    try testing.expectEqualStrings("n2", found.endpoints[0].node);
    try testing.expectEqual(@as(usize, 2), found.excluded.len);
    for (found.excluded) |item| try testing.expectEqual(Exclusion.draining, item.exclusion);
}
