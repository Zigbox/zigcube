//! A seeded fuzzer for the rollout plan (`rollout_plan.zig`, docs/briefs/c3.md slice 6). Each
//! iteration checks three things against oracles written here, not borrowed from the plan:
//!
//! - **The budget** over a random (policy, desired, mix): the start and retire counts are the
//!   formula's, R1 (a retirement never takes the ready replicas below `desired -
//!   max_unavailable`) and R2 (a start never takes the live replicas past `desired + max_surge`)
//!   hold, and a settled mix that is not done always gets a budget, so a rollout cannot deadlock.
//! - **A rollout to the end** in a small model world: the replica controller does all or part of
//!   each budget, new replicas become ready and retired ones stop in a random order, and the
//!   rollout must reach `complete` within a bound, with R1 and R2 at every step.
//! - **The phases** on a random walk of passes, pauses, resumes and begins: every move is an edge
//!   of the module's table, the state stays valid, and a rollout moves no replica outside the
//!   active phases.
//!
//! Seeds and replay are in `fuzz_seeds.zig`: a failure prints the master seed and the iteration
//! seed, each with its replay.

const std = @import("std");
const plan_mod = @import("rollout_plan.zig");
const records = @import("records.zig");
const constants = @import("constants.zig");
const seeds = @import("fuzz_seeds.zig");

const assert = std.debug.assert;
const testing = std.testing;
const Mix = plan_mod.Mix;
const Plan = plan_mod.Plan;
const Policy = plan_mod.Policy;
const Phase = plan_mod.Phase;
const State = plan_mod.State;

const iterations_default = 2_000;
/// The model world's services stay small, so a run explores many shapes quickly.
const world_replicas_max: u32 = 12;
const t0: u64 = 1_000_000;

fn random_policy(random: std.Random) Policy {
    const strategy: records.RolloutStrategy = if (random.uintLessThan(u8, 5) == 0)
        .recreate
    else
        .rolling;
    var policy: Policy = .{
        .strategy = strategy,
        .max_surge = random.uintAtMost(u32, 4),
        .max_unavailable = random.uintAtMost(u32, 4),
        .on_failure = if (random.boolean()) .rollback else .pause,
    };
    if (random.uintLessThan(u8, 20) == 0) policy.max_surge = constants.replicas_per_service_max;
    if (strategy == .rolling and policy.max_surge == 0 and policy.max_unavailable == 0) {
        policy.max_surge = 1;
    }
    assert(plan_mod.policy_valid(&policy));
    return policy;
}

fn random_mix(random: std.Random, limit: u32) Mix {
    const new_live = random.uintAtMost(u32, limit);
    const old_live = random.uintAtMost(u32, limit);
    const old_stopping = random.uintAtMost(u32, old_live);
    const mix: Mix = .{
        .new_live = new_live,
        .new_ready = random.uintAtMost(u32, new_live),
        .old_live = old_live,
        .old_stopping = old_stopping,
        .old_ready = random.uintAtMost(u32, old_live - old_stopping),
    };
    mix.assert_valid();
    return mix;
}

/// The oracle: the budget as the brief's formula states it, computed in signed arithmetic.
fn oracle(policy: *const Policy, desired: u32, mix: *const Mix) Plan {
    const d: i64 = desired;
    const live: i64 = @as(i64, mix.new_live) + mix.old_live;
    const ready_now: i64 = @as(i64, mix.new_ready) + mix.old_ready;
    const unready: u32 = mix.old_live - mix.old_stopping - mix.old_ready;
    if (policy.strategy == .recreate) {
        const start: i64 = if (mix.old_live == 0) @max(0, d - mix.new_live) else 0;
        return .{ .start = @intCast(start), .retire = mix.old_ready, .retire_unready = unready };
    }
    const ready_min = @max(0, d - policy.max_unavailable);
    const room = d + policy.max_surge - live;
    const start = @max(0, @min(room, d - mix.new_live));
    const retire = @max(0, @min(@as(i64, mix.old_ready), ready_now - ready_min));
    return .{ .start = @intCast(start), .retire = @intCast(retire), .retire_unready = unready };
}

fn check_budget(random: std.Random) !void {
    const policy = random_policy(random);
    const limit: u32 = if (random.boolean()) world_replicas_max else constants.replicas_max;
    const desired = random.uintAtMost(u32, @min(limit, constants.replicas_per_service_max));
    const mix = random_mix(random, limit);
    const phase = random.enumValue(Phase);
    const plan = plan_mod.budget(&policy, desired, &mix, phase);
    if (!plan_mod.active(phase)) return testing.expect(plan.zero());
    try testing.expectEqualDeep(oracle(&policy, desired, &mix), plan);

    const live = mix.new_live + mix.old_live;
    if (plan.start > 0) {
        try testing.expect(mix.new_live + plan.start <= desired);
        try testing.expect(live + plan.start <= desired + policy.max_surge);
    }
    if (policy.strategy == .rolling and plan.retire > 0) {
        const ready_min = desired -| policy.max_unavailable;
        try testing.expect(mix.new_ready + mix.old_ready - plan.retire >= ready_min);
    }
    // A settled mix (nothing stopping, every live replica ready) that is not done must move.
    const settled = mix.old_stopping == 0 and mix.new_ready == mix.new_live and
        mix.old_ready == mix.old_live;
    if (settled and !plan_mod.done(desired, &mix) and mix.new_live <= desired) {
        try testing.expect(!plan.zero());
    }
}

/// A replica of the model world.
const Replica = struct { new: bool, ready: bool, stopping: bool };

const World = struct {
    replicas: [3 * world_replicas_max + 8]Replica = undefined,
    count: u32 = 0,

    fn mix(world: *const World) Mix {
        var result: Mix = .{};
        for (world.replicas[0..world.count]) |replica| {
            if (replica.new) {
                assert(!replica.stopping);
                result.new_live += 1;
                if (replica.ready) result.new_ready += 1;
            } else {
                result.old_live += 1;
                if (replica.stopping) result.old_stopping += 1;
                if (replica.ready and !replica.stopping) result.old_ready += 1;
            }
        }
        result.assert_valid();
        return result;
    }

    fn add(world: *World, replica: Replica) void {
        assert(world.count < world.replicas.len);
        world.replicas[world.count] = replica;
        world.count += 1;
    }

    fn remove(world: *World, index: u32) void {
        assert(index < world.count);
        world.count -= 1;
        world.replicas[index] = world.replicas[world.count];
    }

    /// Retires up to `count` old replicas that are `ready` (and not already stopping).
    fn retire(world: *World, count: u32, ready: bool) u32 {
        var done: u32 = 0;
        for (world.replicas[0..world.count]) |*replica| {
            if (done == count) break;
            if (replica.new or replica.stopping or replica.ready != ready) continue;
            replica.stopping = true;
            done += 1;
        }
        return done;
    }
};

/// Some of `count`: all of it half the time, so a rollout always progresses, else a random part.
fn part(random: std.Random, count: u32) u32 {
    if (random.boolean()) return count;
    return random.uintAtMost(u32, count);
}

/// The model world settles: each replica that can change does so with even odds.
fn settle(random: std.Random, world: *World) void {
    var index: u32 = 0;
    while (index < world.count) {
        const replica = &world.replicas[index];
        if (replica.stopping and random.boolean()) {
            world.remove(index);
            continue;
        }
        if (replica.new and !replica.ready and random.boolean()) replica.ready = true;
        index += 1;
    }
}

fn check_rollout(random: std.Random) !void {
    const policy = random_policy(random);
    const desired = random.uintAtMost(u32, world_replicas_max);
    var world: World = .{};
    for (0..random.uintAtMost(u32, world_replicas_max)) |_| {
        world.add(.{ .new = false, .ready = random.uintLessThan(u8, 4) != 0, .stopping = false });
    }
    const live_max = @max(desired + policy.max_surge, world.count);
    var state = plan_mod.begin(&policy, .apply, t0);
    const steps_max = 16 * (world_replicas_max + 2);
    for (0..steps_max) |_| {
        const facts: plan_mod.Facts = .{ .desired = desired, .mix = world.mix(), .now_ms = t0 };
        const result = plan_mod.pass(&policy, &state, &facts);
        try testing.expect(result.failure == null);
        state = result.state;
        if (state.phase == .complete) return testing.expect(plan_mod.done(desired, &world.mix()));
        try testing.expectEqual(Phase.progressing, state.phase);
        try apply(random, &policy, desired, &world, &result.plan);
        try testing.expect(world.count <= live_max);
        settle(random, &world);
    }
    std.debug.print("rollout did not finish: desired {d} mix {any} policy {any}\n", .{
        desired, world.mix(), policy,
    });
    return error.RolloutDidNotFinish;
}

/// The replica controller's part: some of the budget, unready old replicas first. R1 is checked
/// on the view the budget was made from.
fn apply(
    random: std.Random,
    policy: *const Policy,
    desired: u32,
    world: *World,
    plan: *const Plan,
) !void {
    const before = world.mix();
    _ = world.retire(part(random, plan.retire_unready), false);
    const retired = world.retire(part(random, plan.retire), true);
    if (policy.strategy == .rolling and retired > 0) {
        const ready_min = desired -| policy.max_unavailable;
        try testing.expect(before.new_ready + before.old_ready - retired >= ready_min);
    }
    const fresh: Replica = .{ .new = true, .ready = false, .stopping = false };
    for (0..part(random, plan.start)) |_| world.add(fresh);
}

/// The edges the module's header allows, as (from, to) pairs; `begin` may go from anywhere to an
/// active phase.
fn edge_allowed(from: Phase, to: Phase) bool {
    if (from == to) return true;
    return switch (from) {
        .progressing => to == .complete or to == .failed or to == .paused,
        .rolling_back => to == .complete or to == .paused,
        .failed => to == .paused,
        .paused => to == .progressing,
        .complete => false,
    };
}

fn check_phases(random: std.Random) !void {
    var policy = random_policy(random);
    var now: u64 = t0;
    var state = plan_mod.begin(&policy, .apply, now);
    for (0..64) |_| {
        now += random.uintAtMost(u64, 200_000);
        const before = state;
        switch (random.uintLessThan(u8, 10)) {
            0 => state = plan_mod.begin(&policy, if (random.boolean()) .apply else .rollback, now),
            1 => state = plan_mod.pause_rollout(&state, now) catch state,
            2 => state = plan_mod.resume_rollout(&state, now) catch state,
            3 => policy.on_failure = if (random.boolean()) .rollback else .pause,
            else => state = try check_pass(random, &policy, &state, now),
        }
        state.assert_valid();
        if (state.started_at_ms == before.started_at_ms) {
            try testing.expect(edge_allowed(before.phase, state.phase));
            try testing.expect(state.deadline_at_ms >= before.deadline_at_ms);
        } else {
            try testing.expect(plan_mod.active(state.phase));
        }
    }
}

fn check_pass(random: std.Random, policy: *const Policy, state: *const State, now: u64) !State {
    const mix = random_mix(random, world_replicas_max);
    const facts: plan_mod.Facts = .{
        .desired = random.uintAtMost(u32, world_replicas_max),
        .mix = mix,
        .now_ms = now,
        .new_held = random.uintLessThan(u8, 8) == 0,
        .new_restarts_exceeded = random.uintLessThan(u8, 8) == 0,
        .new_unready_since_ms = if (mix.new_ready < mix.new_live and random.boolean())
            now -| random.uintAtMost(u64, 200_000)
        else
            null,
        .ready_pending_at_ms = if (random.boolean())
            now -| 1_000 + random.uintAtMost(u64, 9_000)
        else
            null,
        .unplaceable = random.boolean(),
    };
    const result = plan_mod.pass(policy, state, &facts);
    if (!plan_mod.active(result.state.phase)) {
        try testing.expect(result.plan.zero());
        try testing.expect(result.next_at_ms == null);
    }
    if (result.rollback) try testing.expectEqual(Phase.failed, result.state.phase);
    if (result.next_at_ms) |at| try testing.expect(at > now);
    if (result.failure != null) try testing.expect(plan_mod.active(state.phase));
    if (result.stalled) try testing.expect(result.plan.start > 0);
    return result.state;
}

fn fuzz_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..8) |_| try check_budget(random);
    try check_rollout(random);
    try check_phases(random);
}

test "rollout plan fuzz: the budget, a rollout to the end, and the phases" {
    // Goal: the plan keeps R1 and R2, never deadlocks, finishes every rollout in a model world,
    // and moves only along its edges. Method: `fuzz_once` per iteration seed (header).
    try seeds.run("rollout plan fuzz", iterations_default, fuzz_once);
}
