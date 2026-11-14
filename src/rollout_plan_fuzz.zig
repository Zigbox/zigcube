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
//! - **The phases** on a random walk of passes, pauses, resumes, begins and policy changes, some
//!   of them in the same millisecond: each operation is applied to the module and to `Model`, a
//!   phase machine written here from the brief, and the two states, failures, rollbacks, budgets
//!   and next looks must be equal. The model knows which operation it applied, so nothing it
//!   checks is read back from the module.
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
    var state = plan_mod.begin(&policy, .apply, random.boolean(), t0);
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

/// The phase oracle: the rollout as the brief and the module's header describe it, kept apart
/// from the module. Every operation is applied to both, and the states must be equal. The model
/// knows which operation it applied, so a `begin` is recognised as one whatever the clock says.
const Model = struct {
    phase: Phase,
    reason: plan_mod.Reason,
    /// The service ran a generation before the target: a failed apply has one to roll back to.
    earlier: bool,
    started_at_ms: u64,
    deadline_at_ms: u64,
    evidence_from_ms: u64,
    paused_at_ms: ?u64 = null,
    paused_by: ?plan_mod.PauseCause = null,

    fn begun(policy: *const Policy, reason: plan_mod.Reason, earlier: bool, now: u64) Model {
        return .{
            .phase = if (reason == .apply) .progressing else .rolling_back,
            .reason = reason,
            .earlier = earlier,
            .started_at_ms = now,
            .deadline_at_ms = now + policy.progress_deadline_ms,
            .evidence_from_ms = now,
        };
    }

    fn state(model: *const Model) State {
        return .{
            .phase = model.phase,
            .reason = model.reason,
            .earlier = model.earlier,
            .started_at_ms = model.started_at_ms,
            .deadline_at_ms = model.deadline_at_ms,
            .evidence_from_ms = model.evidence_from_ms,
            .paused_at_ms = model.paused_at_ms,
            .paused_by = model.paused_by,
        };
    }

    /// A failed rollout owes a rollback only if it was an apply over an earlier generation.
    fn owes(model: *const Model) bool {
        return model.reason == .apply and model.earlier;
    }

    fn running(model: *const Model) bool {
        return model.phase == .progressing or model.phase == .rolling_back;
    }

    fn hold(model: *Model, now: u64, cause: plan_mod.PauseCause) void {
        model.phase = .paused;
        model.paused_at_ms = @max(now, model.evidence_from_ms);
        model.paused_by = cause;
    }

    /// Whether a pause is refused; else the model is paused.
    fn pause(model: *Model, now: u64) bool {
        switch (model.phase) {
            .complete => return true,
            .paused => {},
            .failed => model.hold(now, .failure),
            .progressing, .rolling_back => model.hold(now, .user),
        }
        return false;
    }

    /// Whether a resume is refused; else the model runs again.
    fn @"resume"(model: *Model, policy: *const Policy, now: u64) bool {
        if (model.phase == .complete or model.phase == .failed) return true;
        if (model.phase != .paused) return false;
        const at = @max(now, model.paused_at_ms.?);
        if (model.paused_by.? == .user) {
            model.deadline_at_ms += at - model.paused_at_ms.?;
        } else {
            model.deadline_at_ms = at + policy.progress_deadline_ms;
        }
        model.evidence_from_ms = at;
        model.phase = if (model.reason == .apply) .progressing else .rolling_back;
        model.paused_at_ms = null;
        model.paused_by = null;
        return false;
    }
};

/// What the model expects of one pass.
const Expected = struct { failure: ?plan_mod.Failure = null, rollback: bool = false };

fn model_pass(model: *Model, policy: *const Policy, facts: *const plan_mod.Facts) Expected {
    switch (model.phase) {
        .complete, .paused => return .{},
        .failed => {
            if (policy.on_failure == .pause) {
                model.hold(facts.now_ms, .failure);
                return .{};
            }
            return .{ .rollback = model.owes() };
        },
        .progressing, .rolling_back => {},
    }
    const mix = &facts.mix;
    if (mix.old_live == 0 and mix.new_ready >= facts.desired) {
        model.phase = .complete;
        return .{};
    }
    const failure = model_failure(model, policy, facts) orelse return .{};
    if (policy.on_failure == .pause) {
        model.hold(facts.now_ms, .failure);
        return .{ .failure = failure };
    }
    model.phase = .failed;
    return .{ .failure = failure, .rollback = model.owes() };
}

fn model_failure(
    model: *const Model,
    policy: *const Policy,
    facts: *const plan_mod.Facts,
) ?plan_mod.Failure {
    const from = model.evidence_from_ms;
    // A replica still held fails the rollout whenever it was first seen (C3 slice 7).
    if (facts.new_held_at_ms != null) return .held;
    const restarts = facts.new_restarts_exceeded_at_ms;
    if (restarts != null and restarts.? >= from) return .restarts;
    if (facts.new_unready_since_ms) |since| {
        const counted_from = @max(since, from);
        if (facts.now_ms >= counted_from + policy.ready_timeout_ms) return .ready_timeout;
    }
    if (facts.now_ms < model.deadline_at_ms) return null;
    const start = oracle(policy, facts.desired, &facts.mix).start;
    return if (facts.unplaceable and start > 0) .stalled else .deadline;
}

/// The next look the model expects of a pass that leaves a rollout running.
fn model_next_at(model: *const Model, policy: *const Policy, facts: *const plan_mod.Facts) u64 {
    var at = model.deadline_at_ms;
    if (facts.new_unready_since_ms) |since| {
        at = @min(at, @max(since, model.evidence_from_ms) + policy.ready_timeout_ms);
    }
    if (facts.ready_pending_at_ms) |pending| {
        if (pending > facts.now_ms) at = @min(at, pending);
    }
    return at;
}

const Op = enum { begin_apply, begin_rollback, pause, @"resume", policy, pass };

fn random_op(random: std.Random) Op {
    return switch (random.uintLessThan(u8, 12)) {
        0 => .begin_apply,
        1 => .begin_rollback,
        2 => .pause,
        3 => .@"resume",
        4 => .policy,
        else => .pass,
    };
}

/// One operation on both the module and the model, compared after it.
fn step(
    random: std.Random,
    op: Op,
    policy: *Policy,
    state: *State,
    model: *Model,
    now: u64,
) !void {
    switch (op) {
        .begin_apply, .begin_rollback => {
            const reason: plan_mod.Reason = if (op == .begin_apply) .apply else .rollback;
            // One apply in four is of a first generation; a rollback always restores an earlier.
            const earlier = reason == .rollback or random.uintLessThan(u8, 4) != 0;
            state.* = plan_mod.begin(policy, reason, earlier, now);
            model.* = Model.begun(policy, reason, earlier, now);
        },
        .pause => {
            const refused = model.pause(now);
            if (plan_mod.pause_rollout(state, now)) |next| {
                try testing.expect(!refused);
                state.* = next;
            } else |_| try testing.expect(refused);
        },
        .@"resume" => {
            const refused = model.@"resume"(policy, now);
            if (plan_mod.resume_rollout(policy, state, now)) |next| {
                try testing.expect(!refused);
                state.* = next;
            } else |_| try testing.expect(refused);
        },
        .policy => policy.on_failure = if (random.boolean()) .rollback else .pause,
        .pass => state.* = try check_pass(random, policy, state, model, now),
    }
    state.assert_valid();
    try testing.expectEqualDeep(model.state(), state.*);
}

fn check_phases(random: std.Random) !void {
    var policy = random_policy(random);
    var now: u64 = t0;
    const earlier = random.boolean();
    var state = plan_mod.begin(&policy, .apply, earlier, now);
    var model = Model.begun(&policy, .apply, earlier, now);
    for (0..64) |_| {
        // One step in eight takes no time: a begin, pause or resume in the same millisecond as
        // the step before must be told apart by what it did, not by the clock.
        if (random.uintLessThan(u8, 8) != 0) now += 1 + random.uintAtMost(u64, 200_000);
        try step(random, random_op(random), &policy, &state, &model, now);
    }
}

/// A moment of evidence: none, or one up to 200 s before `now`.
fn random_seen(random: std.Random, now: u64, odds: u8) ?u64 {
    if (random.uintLessThan(u8, odds) != 0) return null;
    return now -| random.uintAtMost(u64, 200_000);
}

fn check_pass(
    random: std.Random,
    policy: *const Policy,
    state: *const State,
    model: *Model,
    now: u64,
) !State {
    const mix = random_mix(random, world_replicas_max);
    const facts: plan_mod.Facts = .{
        .desired = random.uintAtMost(u32, world_replicas_max),
        .mix = mix,
        .now_ms = now,
        .new_held_at_ms = random_seen(random, now, 8),
        .new_restarts_exceeded_at_ms = random_seen(random, now, 8),
        .new_unready_since_ms = if (mix.new_ready < mix.new_live)
            random_seen(random, now, 2)
        else
            null,
        .ready_pending_at_ms = if (random.boolean())
            now -| 1_000 + random.uintAtMost(u64, 9_000)
        else
            null,
        .unplaceable = random.boolean(),
    };
    const running = model.running();
    const expected = model_pass(model, policy, &facts);
    const result = plan_mod.pass(policy, state, &facts);
    try testing.expectEqual(expected.failure, result.failure);
    try testing.expectEqual(expected.rollback, result.rollback);
    if (model.running()) {
        assert(running);
        const plan = oracle(policy, facts.desired, &mix);
        try testing.expectEqualDeep(plan, result.plan);
        try testing.expectEqual(facts.unplaceable and plan.start > 0, result.stalled);
        try testing.expectEqual(@as(?u64, model_next_at(model, policy, &facts)), result.next_at_ms);
        try testing.expect(result.next_at_ms.? > now);
    } else {
        try testing.expect(result.plan.zero());
        try testing.expect(result.next_at_ms == null);
        try testing.expect(!result.stalled);
    }
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
    // and moves as the phase model does. Method: `fuzz_once` per iteration seed (header).
    try seeds.run("rollout plan fuzz", iterations_default, fuzz_once);
}

test "rollout plan fuzz: iteration seeds that once failed" {
    // Goal: the seeds review found pass. 15358748992189162208 drew a time step of 0, and
    // 16187094404926879864 a begin in the same millisecond as the step before: the old phase
    // oracle took a begin for a pass and failed. The draws have changed since, so the next test
    // replays the shape of both by hand.
    for ([_]u64{ 15358748992189162208, 16187094404926879864 }) |seed| try fuzz_once(seed);
}

test "rollout plan fuzz: a begin, pause and resume in the same millisecond" {
    // Goal: operations that take no time are checked against the model like any other. Method:
    // a rollout that fails (rollback owed), is begun again, paused, resumed and begun again, all
    // at one moment, then a pass.
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var policy: Policy = .{};
    const now = t0 + 700_000;
    var state = plan_mod.begin(&policy, .apply, true, t0);
    var model = Model.begun(&policy, .apply, true, t0);
    const all_old: Mix = .{ .old_live = 3, .old_ready = 3 };
    const facts: plan_mod.Facts = .{ .desired = 3, .mix = all_old, .now_ms = now };
    const failed = plan_mod.pass(&policy, &state, &facts);
    _ = model_pass(&model, &policy, &facts);
    try testing.expectEqual(Phase.failed, failed.state.phase);
    state = failed.state;
    try testing.expectEqualDeep(model.state(), state);
    const ops = [_]Op{ .begin_rollback, .pause, .@"resume", .begin_apply, .pause, .begin_apply };
    for (ops) |op| try step(random, op, &policy, &state, &model, now);
    try step(random, .pass, &policy, &state, &model, now);
}
