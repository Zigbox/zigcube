//! Tests of the agent's lease and self-fencing (docs/authority.md §3) against the simulation
//! world: a store that goes away, a restart that must find the lease again, and a tenure that
//! has been replaced.

const std = @import("std");
const testing = std.testing;
const apply_mod = @import("apply.zig");
const fencing = @import("fencing.zig");
const records = @import("records.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 2,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0000001",
};

fn start(seed: u64) !*sim_world.World {
    const fixtures = &sim_runtime.default_fixtures;
    const world = try sim_world.World.create(testing.allocator, seed, fixtures);
    errdefer world.destroy();
    _ = try world.apply(hello);
    world.advance(5_000);
    try testing.expectEqual(@as(u32, 2), world.running_count("hello"));
    return world;
}

test "a node cut off from the store fences at its deadline and registers again, empty" {
    const world = try start(11);
    defer world.destroy();
    const first = world.agent.tenure;
    try testing.expect(first != 0);
    try testing.expect(world.agent.lease_ttl_ms != 0);

    world.set_store_down(true);
    // Well before the deadline the containers still run.
    world.advance(fencing.fence_at_ms(0, world.agent.lease_ttl_ms) / 2);
    try testing.expect(world.agent.fences == 0);
    world.advance(world.agent.lease_ttl_ms + 4_000);
    try testing.expectEqual(@as(u32, 1), world.agent.fences);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());

    world.set_store_down(false);
    world.advance(world.agent.lease_ttl_ms + 4_000);
    try testing.expect(world.agent.tenure > first);
}

test "a restarted agent finds its lease and tenure again" {
    const world = try start(12);
    defer world.destroy();
    const lease = world.agent.lease;
    const tenure = world.agent.tenure;
    world.restart_agent();
    try testing.expectEqual(store.lease_none, world.agent.lease);
    world.advance(1_000);
    try testing.expectEqual(lease, world.agent.lease);
    try testing.expectEqual(tenure, world.agent.tenure);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
}

test "an observed write under a replaced tenure is refused and the agent fences" {
    const world = try start(13);
    defer world.destroy();
    const first = world.agent.tenure;
    var diag: @import("diag.zig").Diag = undefined;
    diag.reset();
    const key = records.node_key(sim_world.node_name);
    // Someone else rewrites the node's registration: the agent's tenure is over.
    const put: store.Op = .{ .put = .{ .key = key.slice(), .value = "{}" } };
    _ = try world.store_handle().txn(.{ .on_success = &.{put} }, &diag);
    try world.kill("hello-1");
    world.advance(3_000);
    try testing.expect(world.agent.fences >= 1);
    world.advance(world.agent.lease_ttl_ms);
    try testing.expect(world.agent.tenure > first);
}

test "the shipped constants satisfy the inequality" {
    try testing.expectEqual(
        @as(?fencing.Problem, null),
        fencing.inequality_problem(@import("constants.zig").lease_ttl_ms),
    );
}
