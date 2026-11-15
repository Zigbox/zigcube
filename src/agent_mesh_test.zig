//! Tests of the agent's mesh view (C4 slice 4, `agent_mesh.zig`) against the simulation world:
//! a replica that starts is given a port of the node's range, keeps it in a label, publishes its
//! endpoint and holds the rules of the node's view; new rules reach a running replica through
//! `Runtime.mesh_update` once, and a spent range is a start failure (ZC-E0710).

const std = @import("std");
const testing = std.testing;
const agent_mesh = @import("agent_mesh.zig");
const apply_mod = @import("apply.zig");
const diag_mod = @import("diag.zig");
const mesh_plan = @import("mesh_plan.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 2,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0000001",
};

const api_grants = [_]records.Grant{.{ .from = "hello", .port = 8080 }};
const services = [_]mesh_plan.Service{
    .{ .name = "api", .mesh_address = "127.77.0.1", .allow = &api_grants },
    .{ .name = "hello", .mesh_address = "127.77.0.2" },
};
const api_1: mesh_plan.Replica = .{
    .id = "api-1",
    .service = "api",
    .node = "node2",
    .endpoint = "10.0.0.2:30000",
    .readiness = .ready,
};
const one_api = [_]mesh_plan.Replica{
    api_1,
    .{ .id = "hello-1", .service = "hello", .node = "node1", .readiness = .ready },
    .{ .id = "hello-2", .service = "hello", .node = "node1", .readiness = .ready },
};
const two_api = [_]mesh_plan.Replica{
    api_1,
    .{
        .id = "api-2",
        .service = "api",
        .node = "node3",
        .endpoint = "10.0.0.3:30000",
        .readiness = .ready,
    },
    .{ .id = "hello-1", .service = "hello", .node = "node1", .readiness = .ready },
    .{ .id = "hello-2", .service = "hello", .node = "node1", .readiness = .ready },
};

/// The node's view the agent reads, as the test sets it; `down` fails the read.
const Feed = struct {
    input: mesh_plan.Input = .{ .services = &services, .replicas = &one_api },
    down: bool = false,
    reads: u32 = 0,

    fn source(feed: *Feed) agent_mesh.Source {
        return .{ .context = feed, .fetch_fn = fetch };
    }

    fn fetch(context: *anyopaque, arena: Allocator, diag: *Diag) store.Error!mesh_plan.Input {
        _ = arena;
        const feed: *Feed = @ptrCast(@alignCast(context));
        feed.reads += 1;
        if (feed.down) {
            diag.raise(.E0213);
            diag.cause("the test's view is down", .{});
            return error.BackendFailed;
        }
        return feed.input;
    }
};

fn start(feed: *Feed, last: u16) !*sim_world.World {
    const fixtures = &sim_runtime.default_fixtures;
    const world = try sim_world.World.create(testing.allocator, 7, fixtures);
    errdefer world.destroy();
    world.agent.config.mesh = .{ .host = "10.0.0.1", .ports_first = 30_000, .ports_last = last };
    world.mesh_source = feed.source();
    _ = try world.apply(hello);
    world.advance(5_000);
    return world;
}

fn observed(world: *sim_world.World, replica: []const u8) !?records.Observed {
    const arena = world.fresh_arena();
    const key = records.observed_key(sim_world.node_name, replica);
    const got = try world.store_handle().get(arena, key.slice(), null, &world.diag);
    const kv = got.kv orelse return null;
    return try records.read(records.Observed, arena, kv, &world.diag);
}

/// The rules hash `replica` should hold under `input`.
fn hash_under(input: *const mesh_plan.Input, replica: []const u8) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = try mesh_plan.plan(arena, input, sim_world.node_name);
    const rules = try mesh_plan.rules_of(arena, &plan, replica);
    return runtime.mesh_rules_hash(&rules);
}

test "agent mesh: replicas get ports, endpoints and rules, and new rules are sent once" {
    // Goal: each replica is given its own port of the range, publishes `<host>:<port>`, holds
    // the rules of the view, and is sent the view's new rules exactly once. Method: two replicas
    // over a view with one endpoint of `api`, then a second endpoint, then steps that change
    // nothing.
    var feed: Feed = .{};
    const world = try start(&feed, 30_009);
    defer world.destroy();
    try testing.expectEqual(@as(u32, 2), world.running_count("hello"));
    try testing.expect(feed.reads > 0);
    const first = world.sim.mesh_of("hello-1").?;
    const second = world.sim.mesh_of("hello-2").?;
    try testing.expect(first.port != second.port);
    for ([_]sim_runtime.SimRuntime.MeshView{ first, second }) |view| {
        try testing.expect(view.port >= 30_000 and view.port <= 30_001);
    }
    try testing.expectEqual(try hash_under(&feed.input, "hello-1"), first.hash);
    const seen = (try observed(world, "hello-1")).?;
    var buffer: [32]u8 = undefined;
    const want = try std.fmt.bufPrint(&buffer, "10.0.0.1:{d}", .{first.port});
    try testing.expectEqualStrings(want, seen.endpoint.?);

    feed.input.replicas = &two_api;
    world.advance(5_000);
    const moved = world.sim.mesh_of("hello-1").?;
    try testing.expectEqual(try hash_under(&feed.input, "hello-1"), moved.hash);
    try testing.expect(moved.hash != first.hash);
    try testing.expectEqual(first.port, moved.port);
    try testing.expectEqual(first.updates + 1, moved.updates);
    const empty: runtime.MeshRules = .{};
    try testing.expect(first.hash != runtime.mesh_rules_hash(&empty));
    world.advance(5_000);
    try testing.expectEqual(moved.updates, world.sim.mesh_of("hello-1").?.updates);
}

test "agent mesh: a view that cannot be read holds no replica back" {
    // Goal: with the view unreadable, replicas still start (with empty rules) and get their
    // rules once it is readable again. Method: start with the feed down, then bring it up.
    var feed: Feed = .{ .down = true };
    const world = try start(&feed, 30_009);
    defer world.destroy();
    try testing.expectEqual(@as(u32, 2), world.running_count("hello"));
    const empty: runtime.MeshRules = .{};
    try testing.expectEqual(runtime.mesh_rules_hash(&empty), world.sim.mesh_of("hello-1").?.hash);
    feed.down = false;
    world.advance(5_000);
    const want = try hash_under(&feed.input, "hello-1");
    try testing.expectEqual(want, world.sim.mesh_of("hello-1").?.hash);
}

test "agent mesh: a replica the range has no port for fails to start with ZC-E0710" {
    // Goal: a spent range is a start failure with the mesh's code, not a silent replica.
    // Method: a range of one port and two replicas; step until a report carries the code (the
    // replica controller replaces a replica whose start failed through no fault of the user, so
    // the record does not stay).
    var feed: Feed = .{};
    const fixtures = &sim_runtime.default_fixtures;
    const world = try sim_world.World.create(testing.allocator, 7, fixtures);
    defer world.destroy();
    world.agent.config.mesh = .{ .host = "10.0.0.1", .ports_first = 30_000, .ports_last = 30_000 };
    world.mesh_source = feed.source();
    _ = try world.apply(hello);
    var seen_code = false;
    var ticks: u32 = 0;
    while (!seen_code and ticks < 200) : (ticks += 1) {
        world.advance(sim_world.tick_ms);
        const arena = world.fresh_arena();
        const listed = try world.store_handle().list(
            arena,
            .{ .prefix = records.prefix_observed, .limit = 100 },
            &world.diag,
        );
        for (listed.kvs) |kv| {
            if (std.mem.indexOf(u8, kv.value, "E0710") != null) seen_code = true;
        }
    }
    try testing.expect(seen_code);
    try testing.expect(world.sim.running_count() <= 1);
}
