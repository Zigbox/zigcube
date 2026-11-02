//! Tests of the agent's lease and self-fencing (docs/authority.md §3) against the simulation
//! world: a store that goes away, a restart that must find the lease again, and a tenure that
//! has been replaced.

const std = @import("std");
const testing = std.testing;
const agent_mod = @import("agent.zig");
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
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

/// Moves the world's clock to `at_ms` (no further if it is already there).
fn advance_to(world: *sim_world.World, at_ms: u64) void {
    if (world.now_ms() < at_ms) world.advance(at_ms - world.now_ms());
}

test "a node cut off from the store fences at its deadline and registers again, empty" {
    // Goal: the fence comes at s + ttl - margin and not before, every container is dead by the
    // worst case, and the node comes back under a new tenure. Method: one container ignores the
    // polite stop, so only the kill at the deadline ends it; count the runtime's containers on
    // both sides of the fence, the kill and the worst case.
    const world = try start(11);
    defer world.destroy();
    const first = world.agent.tenure;
    const ttl = world.agent.lease_ttl_ms;
    try testing.expect(first != 0);
    try testing.expect(ttl != 0);
    try world.sim.inject("hello-1", .slow_stop);

    world.set_store_down(true);
    const sent = world.agent.sent_ms;
    const fence_at = fencing.fence_at_ms(sent, ttl);
    const kill_at = fencing.kill_at_ms(fence_at);
    const tick = sim_world.tick_ms;
    advance_to(world, fence_at - tick);
    try testing.expectEqual(sent, world.agent.sent_ms);
    try testing.expect(!world.agent.fence.active);
    try testing.expectEqual(@as(u32, 2), world.sim.running_count());

    advance_to(world, fence_at + tick);
    try testing.expect(world.agent.fence.active);
    try testing.expectEqual(@as(u32, 1), world.sim.running_count());
    advance_to(world, kill_at - tick);
    try testing.expectEqual(@as(u32, 1), world.sim.running_count());
    try testing.expectEqual(@as(u32, 0), world.agent.fences);

    advance_to(world, fencing.worst_case_dead_ms(sent, ttl));
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    try testing.expectEqual(@as(u32, 1), world.agent.fences);
    // All of that by the time the lease the store held can end, not after.
    try testing.expect(world.now_ms() <= sent + ttl);

    world.set_store_down(false);
    world.advance(ttl + 4_000);
    try testing.expect(world.agent.tenure > first);
}

/// Long enough for a fence that needs no kill: a step that stops everything, and the poll after
/// it that finds nothing left running.
const fence_steps_ms = sim_world.tick_ms + constants.fence_poll_ms;

/// Restarts the agent with the store down, so that whatever it does next needs no server.
fn restart_cut_off(world: *sim_world.World) void {
    world.set_store_down(true);
    world.restart_agent();
}

test "a restarted agent whose kept lease has run out fences at once" {
    const world = try start(14);
    defer world.destroy();
    const ttl = world.agent.lease_ttl_ms;
    restart_cut_off(world);
    world.manual.advance(ttl + 1_000);
    world.advance(fence_steps_ms);
    try testing.expectEqual(@as(u32, 1), world.agent.fences);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
}

test "a restarted agent fences on a kept lease it cannot trust" {
    // Goal: a lease file that cannot be read, a send time in the future and another boot each
    // fence. Method: one world per case, the store down so nothing else can happen.
    for (0..3) |case| {
        const world = try start(15 + case);
        defer world.destroy();
        const tenure = world.agent.tenure;
        const lease = world.agent.lease;
        const ttl = world.agent.lease_ttl_ms;
        restart_cut_off(world);
        const files = world.files.interface();
        var buffer: [160]u8 = undefined;
        switch (case) {
            0 => try files.put_atomic(agent_mod.lease_file, "{not json"),
            1 => try files.put_atomic(agent_mod.lease_file, try std.fmt.bufPrint(
                &buffer,
                "{{\"lease\":{d},\"ttl_ms\":{d},\"sent_ms\":{d},\"tenure\":{d}}}",
                .{ lease, ttl, world.now_ms() + 60_000, tenure },
            )),
            else => world.boot_id = "another-boot",
        }
        world.advance(fence_steps_ms);
        try testing.expectEqual(@as(u32, 1), world.agent.fences);
        try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    }
}

test "an agent that restarts mid-fence finishes the fence by the first deadline" {
    // Goal: the fencing flag. Method: the tenure is replaced while the lease is still fresh, so
    // only the kept flag says to fence; one container ignores the polite stop; restart the agent,
    // cut off, once the fence has begun: it fences at once, and kills by the first kill time.
    const world = try start(18);
    defer world.destroy();
    try world.sim.inject("hello-1", .slow_stop);
    replace_tenure(world);
    try world.kill("hello-2");
    var waited: u32 = 0;
    while (!world.agent.fence.active and waited < 3_000) : (waited += sim_world.tick_ms) {
        world.advance(sim_world.tick_ms);
    }
    try testing.expect(world.agent.fence.active);
    const kill_at = world.agent.fence.kill_at_ms;
    try testing.expect(world.now_ms() < kill_at);
    try testing.expectEqual(@as(u32, 1), world.sim.running_count());

    restart_cut_off(world);
    try testing.expect(!world.agent.fence.active);
    world.advance(sim_world.tick_ms);
    try testing.expect(world.agent.fence.active);
    try testing.expect(world.agent.fence.kill_at_ms <= kill_at);
    advance_to(world, kill_at + fence_steps_ms);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    try testing.expectEqual(@as(u32, 1), world.agent.fences);
}

/// Someone else rewrites the node's registration: the agent's tenure is over.
fn replace_tenure(world: *sim_world.World) void {
    var diag: @import("diag.zig").Diag = undefined;
    diag.reset();
    const key = records.node_key(sim_world.node_name);
    const put: store.Op = .{ .put = .{ .key = key.slice(), .value = "{}" } };
    // Cannot fail: the store is up and in memory.
    _ = world.store_handle().txn(.{ .on_success = &.{put} }, &diag) catch unreachable;
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
    replace_tenure(world);
    try world.kill("hello-1");
    world.advance(3_000);
    try testing.expect(world.agent.fences >= 1);
    world.advance(world.agent.lease_ttl_ms);
    try testing.expect(world.agent.tenure > first);
}

test "the shipped constants satisfy the inequality" {
    try testing.expectEqual(
        @as(?fencing.Problem, null),
        fencing.inequality_problem(constants.lease_ttl_ms),
    );
}
