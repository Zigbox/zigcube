//! A seeded fuzzer for the mesh plan (`mesh_plan.zig`): random services (some without a mesh
//! address), random grants (some from services that do not exist), and random replicas across
//! three nodes in the states `input_of` produces: desired replicas, never draining, with an
//! endpoint only behind an admitted report, and draining copies of moved or removed ones. Each
//! node's plan, and `check` for every grant asked, is held against a plain restatement of the
//! brief's rules:
//!
//! - a listener for each local replica of S per compiled grant S -> D:P, and nothing else;
//! - D's endpoints are exactly its ready, non-draining replicas with an endpoint (M4's plan side),
//!   and `pick` tries each once, the planning node's first;
//! - an accept for each local replica of D per compiled grant, open iff ready and not draining;
//! - `check`'s verdict is the first of no_grant, no_source, destination_has_no_address,
//!   source_has_no_address, no_endpoint that applies, else granted.
//!
//! Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const assert = std.debug.assert;
const records = @import("records.zig");
const mesh_plan = @import("mesh_plan.zig");
const seeds = @import("fuzz_seeds.zig");

const iterations_default = 400;

const service_names = [_][]const u8{ "api", "batch", "db", "web", "worker" };
/// A grant may name these too: no service has the name (ZC-W0704).
const ghost_names = [_][]const u8{ "cache", "zeta" };
const addresses = [_][]const u8{ "fd00::1", "fd00::2", "fd00::3", "fd00::4", "fd00::5" };
const ports = [_]u16{ 80, 443, 5432 };
const node_names = [_][]const u8{ "n1", "n2", "n3" };
const replica_ids = [_][]const u8{
    "r00", "r01", "r02", "r03", "r04", "r05", "r06", "r07", "r08", "r09", "r10", "r11",
};
const endpoint_texts = [_][]const u8{
    "10.0.0.1:7000", "10.0.0.2:7000", "10.0.0.3:7000", "10.0.0.4:7000",
    "10.0.0.5:7000", "10.0.0.6:7000", "10.0.0.7:7000", "10.0.0.8:7000",
    "10.0.0.9:7000", "10.0.1.0:7000", "10.0.1.1:7000", "10.0.1.2:7000",
};
const grants_max = service_names.len + ghost_names.len;
const replicas_max = 2 * replica_ids.len;

const World = struct {
    services: [service_names.len]mesh_plan.Service,
    allow: [service_names.len][grants_max * ports.len]records.Grant,
    replicas: [replicas_max]mesh_plan.Replica,
    replica_count: u32,

    fn input(world: *const World) mesh_plan.Input {
        return .{ .services = &world.services, .replicas = world.replicas[0..world.replica_count] };
    }
};

fn world_make(random: std.Random, world: *World) void {
    for (&world.services, 0..) |*service, index| {
        var count: usize = 0;
        for (service_names ++ ghost_names) |from| {
            if (std.mem.eql(u8, from, service_names[index])) continue;
            for (ports) |port| {
                if (random.uintLessThan(u8, 6) != 0) continue;
                world.allow[index][count] = .{ .from = from, .port = port };
                count += 1;
            }
        }
        service.* = .{
            .name = service_names[index],
            .mesh_address = if (random.uintLessThan(u8, 6) == 0) null else addresses[index],
            .allow = world.allow[index][0..count],
        };
    }
    world.replica_count = 0;
    for (replica_ids, 0..) |id, index| {
        const service = service_names[random.uintLessThan(usize, service_names.len)];
        // Sometimes the replica is no longer desired (scaled down, or its service re-applied with
        // fewer replicas) and only a copy still running somewhere is left.
        const desired = random.uintLessThan(u8, 6) != 0;
        var node: ?[]const u8 = null;
        if (desired) {
            const replica = replica_make(random, id, service, endpoint_texts[index]);
            world.replicas[world.replica_count] = replica;
            world.replica_count += 1;
            node = replica.node;
            // Sometimes a draining copy of the same replica on another node (it moved).
            if (random.uintLessThan(u8, 4) != 0) continue;
        }
        const copy_node = if (node) |assigned|
            node_other(random, assigned)
        else
            node_names[random.uintLessThan(usize, node_names.len)];
        world.replicas[world.replica_count] = .{
            .id = id,
            .service = service,
            .node = copy_node,
            .endpoint = if (random.uintLessThan(u8, 5) == 0) null else endpoint_texts[index],
            .readiness = if (random.boolean()) .ready else .starting,
            .draining = true,
        };
        world.replica_count += 1;
    }
    const replicas = world.replicas[0..world.replica_count];
    std.mem.sort(mesh_plan.Replica, replicas, {}, mesh_plan.replica_less);
}

/// A desired replica, in a state `input_of` produces: unassigned with nothing else; assigned
/// with no admitted report (no endpoint); or assigned with an admitted report, whose endpoint may
/// or may not be published yet. Never draining.
fn replica_make(
    random: std.Random,
    id: []const u8,
    service: []const u8,
    endpoint: []const u8,
) mesh_plan.Replica {
    const node_index = random.uintLessThan(usize, node_names.len + 1);
    if (node_index == node_names.len) {
        return .{ .id = id, .service = service, .node = null, .readiness = .not_assigned };
    }
    var readiness = random.enumValue(mesh_plan.Readiness);
    if (readiness == .not_assigned) readiness = .ready;
    const reported = switch (readiness) {
        .not_assigned, .not_reported, .stale_report, .node_not_ready => false,
        .ready, .starting, .stopped, .not_healthy => true,
    };
    const published = reported and random.uintLessThan(u8, 5) != 0;
    return .{
        .id = id,
        .service = service,
        .node = node_names[node_index],
        .endpoint = if (published) endpoint else null,
        .readiness = readiness,
        .draining = false,
    };
}

fn node_other(random: std.Random, node: []const u8) []const u8 {
    while (true) {
        const other = node_names[random.uintLessThan(usize, node_names.len)];
        if (!std.mem.eql(u8, other, node)) return other;
    }
}

// ---- The rules, restated plainly ----

fn service_named(input: *const mesh_plan.Input, name: []const u8) ?*const mesh_plan.Service {
    for (input.services) |*service| {
        if (std.mem.eql(u8, service.name, name)) return service;
    }
    return null;
}

fn compiles(input: *const mesh_plan.Input, to: *const mesh_plan.Service, from: []const u8) bool {
    if (to.mesh_address == null) return false;
    const source = service_named(input, from) orelse return false;
    return source.mesh_address != null;
}

fn on(replica: *const mesh_plan.Replica, node: []const u8) bool {
    const replica_node = replica.node orelse return false;
    return std.mem.eql(u8, replica_node, node);
}

fn is_endpoint(replica: *const mesh_plan.Replica) bool {
    return replica.readiness == .ready and !replica.draining and replica.endpoint != null;
}

// ---- The checks ----

fn listeners_hold(
    input: *const mesh_plan.Input,
    plan: *const mesh_plan.Plan,
    node: []const u8,
) !void {
    var expected: usize = 0;
    for (input.services) |*to| {
        for (to.allow) |grant| {
            if (!compiles(input, to, grant.from)) continue;
            for (input.replicas) |*replica| {
                if (!std.mem.eql(u8, replica.service, grant.from) or !on(replica, node)) continue;
                expected += 1;
                if (!listener_found(plan, replica.id, to.name, grant.port)) {
                    return error.ListenerMissing;
                }
            }
        }
    }
    if (plan.listeners.len != expected) return error.ListenerExtra;
    for (plan.listeners) |listener| {
        if (listener.hash != mesh_plan.order_hash(listener.source)) return error.WrongHash;
        try endpoints_hold(input, &plan.destinations[listener.destination], node, listener.hash);
    }
}

fn listener_found(plan: *const mesh_plan.Plan, source: []const u8, to: []const u8, port: u32) bool {
    for (plan.listeners) |listener| {
        const destination = plan.destinations[listener.destination];
        if (listener.port != port) continue;
        if (!std.mem.eql(u8, listener.source, source)) continue;
        if (std.mem.eql(u8, destination.service, to)) return true;
    }
    return false;
}

fn endpoints_hold(
    input: *const mesh_plan.Input,
    destination: *const mesh_plan.Destination,
    node: []const u8,
    hash: u64,
) !void {
    var expected: usize = 0;
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, destination.service)) continue;
        if (is_endpoint(replica)) expected += 1;
    }
    if (destination.count() != expected) return error.WrongEndpointCount;
    var tried: [replicas_max]bool = @splat(false);
    var attempt: u32 = 0;
    while (destination.pick(hash, attempt)) |endpoint| : (attempt += 1) {
        const index = replica_index(input, endpoint.replica, endpoint.node) orelse
            return error.EndpointUnknown;
        const replica = &input.replicas[index];
        if (!is_endpoint(replica)) return error.EndpointNotReady;
        if (!std.mem.eql(u8, replica.service, destination.service)) return error.WrongService;
        if (tried[index]) return error.EndpointTwice;
        tried[index] = true;
        // The planning node's endpoints come first.
        const local = std.mem.eql(u8, endpoint.node, node);
        if (local != (attempt < destination.local.len)) return error.LocalNotFirst;
    }
    if (attempt != expected) return error.EndpointSkipped;
}

fn replica_index(input: *const mesh_plan.Input, id: []const u8, node: []const u8) ?usize {
    for (input.replicas, 0..) |*replica, index| {
        if (std.mem.eql(u8, replica.id, id) and on(replica, node)) return index;
    }
    return null;
}

fn accepts_hold(
    input: *const mesh_plan.Input,
    plan: *const mesh_plan.Plan,
    node: []const u8,
) !void {
    var expected: usize = 0;
    for (input.services) |*to| {
        for (to.allow) |grant| {
            if (!compiles(input, to, grant.from)) continue;
            for (input.replicas) |*replica| {
                if (!std.mem.eql(u8, replica.service, to.name) or !on(replica, node)) continue;
                expected += 1;
                const open = replica.readiness == .ready and !replica.draining;
                if (!accept_found(plan, replica.id, grant, open)) return error.AcceptMissing;
            }
        }
    }
    if (plan.accepts.len != expected) return error.AcceptExtra;
}

fn accept_found(
    plan: *const mesh_plan.Plan,
    id: []const u8,
    grant: records.Grant,
    open: bool,
) bool {
    for (plan.accepts) |accept| {
        if (!std.mem.eql(u8, accept.replica, id)) continue;
        if (!std.mem.eql(u8, accept.from, grant.from) or accept.port != grant.port) continue;
        return accept.open == open;
    }
    return false;
}

fn checks_hold(arena: std.mem.Allocator, input: *const mesh_plan.Input) !void {
    for (service_names) |to_name| {
        for (service_names ++ ghost_names) |from| {
            if (std.mem.eql(u8, from, to_name)) continue;
            for (ports) |port| {
                const query: mesh_plan.GrantQuery = .{ .from = from, .to = to_name, .port = port };
                const result = try mesh_plan.check(arena, input, query);
                try check_holds(input, query, &result);
            }
        }
    }
}

fn check_holds(
    input: *const mesh_plan.Input,
    query: mesh_plan.GrantQuery,
    result: *const mesh_plan.Check,
) !void {
    const to = service_named(input, query.to).?;
    var endpoints: usize = 0;
    var others: usize = 0;
    for (input.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.service, to.name)) continue;
        if (is_endpoint(replica)) endpoints += 1 else others += 1;
    }
    if (result.endpoints.len != endpoints) return error.CheckEndpoints;
    if (result.excluded.len != others) return error.CheckExcluded;
    if (result.verdict != verdict_expected(input, to, query, endpoints)) {
        return error.CheckVerdict;
    }
}

/// The finer verdicts, in the order the brief gives them: the first that applies is the answer.
fn verdict_expected(
    input: *const mesh_plan.Input,
    to: *const mesh_plan.Service,
    query: mesh_plan.GrantQuery,
    endpoints: usize,
) mesh_plan.Verdict {
    const grant: records.Grant = .{ .from = query.from, .port = query.port };
    if (!records.grants_contain(to.allow, grant)) return .no_grant;
    const source = service_named(input, query.from) orelse return .no_source;
    if (to.mesh_address == null) return .destination_has_no_address;
    if (source.mesh_address == null) return .source_has_no_address;
    if (endpoints == 0) return .no_endpoint;
    return .granted;
}

fn plan_once(faults: mesh_plan.Faults, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    var world: World = undefined;
    world_make(prng.random(), &world);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = world.input();
    for (node_names) |node| {
        const plan = try mesh_plan.plan_with(arena, &input, node, faults);
        try listeners_hold(&input, &plan, node);
        try accepts_hold(&input, &plan, node);
    }
    try checks_hold(arena, &input);
}

fn plan_sound(seed: u64) !void {
    return plan_once(.{}, seed);
}

test "fuzz: the mesh plan routes only to ready endpoints and compiles exactly the grants" {
    // Goal: the brief's rules (listeners, endpoint choice and order, accepts, check's verdict)
    // hold over random grants, replicas, readiness and draining. Method: random worlds of five
    // services on three nodes; every node's plan and every grant's check against the rules
    // restated plainly; seeds as in fuzz_seeds.zig.
    try seeds.run("mesh plan fuzz", iterations_default, plan_sound);
}

fn plan_route_unready(seed: u64) !void {
    return plan_once(.{ .route_unready = true }, seed);
}

test "the mesh plan fuzzer has teeth: endpoints that are not ready fail it" {
    // The plan is built with `route_unready`; the fuzzer must see it.
    const failure = seeds.first_failure(1, 400, plan_route_unready) orelse
        return error.FuzzerHasNoTeeth;
    assert(failure.index < 400);
    try std.testing.expect(failure.err == error.WrongEndpointCount or
        failure.err == error.EndpointNotReady);
}
