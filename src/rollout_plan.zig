//! The rollout plan of C3 (docs/briefs/c3.md, "Controller design"): how many replicas of a
//! service's new generation the replica controller may start now and how many of the old it may
//! retire, and the phases a rollout moves through. Pure: no store, no clock (the caller passes
//! `now_ms`), no allocation. The rollout controller (slice 7) runs it on its view of a service and
//! writes the result into `/rollouts/<service>`; the replica controller obeys the budget.
//!
//! **The budget** (`budget`), for a rolling update:
//!
//!     ready_min      = desired - max_unavailable                    (never below 0)
//!     live_max       = desired + max_surge
//!     start          = min(live_max - live, desired - new_live)     (never below 0)
//!     retire         = min(old_ready, ready_now - ready_min)        (never below 0)
//!     retire_unready = old replicas neither ready nor being retired (they cost nothing)
//!
//! `live` counts every replica not yet observed stopped, the ones being retired included, so the
//! surge bound holds while a stop drains (R2). `ready_now` counts ready replicas that are not being
//! retired, so a retirement already ordered is not counted twice and `ready_now - retire` never
//! falls below `ready_min` (R1). A `recreate` rollout retires every old replica first and starts
//! the new ones only when none is live: it gives up availability by design, so R1 does not hold
//! for it, and R2 does.
//!
//! **The phases** (`pass`, `pause_rollout`, `resume_rollout`, `begin`):
//!
//!     begin(apply)    ──► progressing          begin(rollback) ──► rolling_back
//!     progressing  ── done ──► complete        rolling_back ── done ──► complete
//!     progressing  ── failure, on_failure rollback ──► failed   (a rollback is owed)
//!     progressing  ── failure, on_failure pause    ──► paused
//!     rolling_back ── failure ──► paused       (a failed rollback is never rolled back again)
//!     failed       ── on_failure pause (a policy changed since) ──► paused
//!     progressing, rolling_back ── pause ──► paused ── resume ──► progressing
//!
//! A rollout leaves `failed` only by `begin`: the automatic rollback lands as a new generation
//! (`begin(rollback)`), or a newer user apply does (`begin(apply)`). `begin` from any phase starts
//! a rollout from the current mix of replicas. `paused` and `failed` start and retire nothing;
//! replacing a replica that failed on its own is the replica controller's, outside the budget.
//!
//! Done means no old replica is live and `desired` new ones are ready. Done wins over a failure
//! seen on the same pass: the work it guards is finished.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const Code = @import("diag/codes.zig").Code;

pub const Policy = records.RolloutPolicy;
pub const Phase = records.RolloutPhase;

/// The replicas of one service as the rollout controller sees them on one pass. "New" runs the
/// rollout's target generation, "old" anything else. A replica is live until it is observed
/// stopped; it is ready as `ready` says.
pub const Mix = struct {
    /// New replicas not yet observed stopped.
    new_live: u32 = 0,
    /// Of `new_live`, the ready ones.
    new_ready: u32 = 0,
    /// Old replicas not yet observed stopped, the ones being retired included.
    old_live: u32 = 0,
    /// Of `old_live`, the ready ones that are not being retired.
    old_ready: u32 = 0,
    /// Of `old_live`, the ones whose retirement is ordered (stop asked, not observed stopped).
    old_stopping: u32 = 0,

    pub fn assert_valid(mix: *const Mix) void {
        assert(mix.new_ready <= mix.new_live);
        assert(mix.old_stopping <= mix.old_live);
        assert(mix.old_ready <= mix.old_live - mix.old_stopping);
        assert(mix.new_live <= constants.replicas_max);
        assert(mix.old_live <= constants.replicas_max);
    }

    pub fn live(mix: *const Mix) u32 {
        return mix.new_live + mix.old_live;
    }

    /// Ready replicas that will stay: the new ready and the old ready not being retired.
    pub fn ready_now(mix: *const Mix) u32 {
        return mix.new_ready + mix.old_ready;
    }

    /// Old replicas neither ready nor being retired.
    pub fn old_unready(mix: *const Mix) u32 {
        return mix.old_live - mix.old_stopping - mix.old_ready;
    }
};

/// What the replica controller may do now. `retire` counts ready old replicas; `retire_unready`
/// the old replicas that are not ready, which may go at once because they serve nothing. The
/// stored budget (`records.RolloutBudget`) is `stored`.
pub const Plan = struct {
    start: u32 = 0,
    retire: u32 = 0,
    retire_unready: u32 = 0,

    pub fn zero(plan: *const Plan) bool {
        if (plan.start != 0) return false;
        if (plan.retire != 0) return false;
        return plan.retire_unready == 0;
    }

    /// The budget as `/rollouts` stores it: the unready old replicas are part of `retire`, and
    /// the replica controller retires them before any ready one.
    pub fn stored(plan: *const Plan) records.RolloutBudget {
        return .{ .start = plan.start, .retire = plan.retire + plan.retire_unready };
    }
};

/// Whether a policy is one `apply` admits (docs/decisions/2026-11-13-c3-slice5-keys-drift.md,
/// decision 10). The plan asserts it: it is never handed a policy the API refused.
pub fn policy_valid(policy: *const Policy) bool {
    if (policy.max_surge > constants.replicas_per_service_max) return false;
    if (policy.max_unavailable > constants.replicas_per_service_max) return false;
    if (policy.strategy == .rolling) {
        if (policy.max_surge == 0) {
            if (policy.max_unavailable == 0) return false;
        }
    }
    if (policy.min_ready_ms >= policy.ready_timeout_ms) return false;
    return policy.ready_timeout_ms <= policy.progress_deadline_ms;
}

/// Whether the phase starts and retires replicas.
pub fn active(phase: Phase) bool {
    return switch (phase) {
        .progressing, .rolling_back => true,
        .paused, .complete, .failed => false,
    };
}

/// The budget for a service of `desired` replicas in `phase`, on the view `mix`.
pub fn budget(policy: *const Policy, desired: u32, mix: *const Mix, phase: Phase) Plan {
    assert(policy_valid(policy));
    assert(desired <= constants.replicas_per_service_max);
    mix.assert_valid();
    if (!active(phase)) return .{};
    const plan = switch (policy.strategy) {
        .rolling => budget_rolling(policy, desired, mix),
        .recreate => budget_recreate(desired, mix),
    };
    assert(plan.retire <= mix.old_ready);
    assert(plan.retire_unready == mix.old_unready());
    assert(mix.new_live + plan.start <= @max(desired, mix.new_live));
    return plan;
}

fn budget_rolling(policy: *const Policy, desired: u32, mix: *const Mix) Plan {
    const ready_min = desired -| policy.max_unavailable;
    const live_max = desired + policy.max_surge;
    const start = @min(live_max -| mix.live(), desired -| mix.new_live);
    const retire = @min(mix.old_ready, mix.ready_now() -| ready_min);
    // R2: a start never takes the live replicas past the surge bound.
    if (start > 0) assert(mix.live() + start <= live_max);
    // R1: a retirement never takes the ready replicas below the minimum.
    if (retire > 0) assert(mix.ready_now() - retire >= ready_min);
    return .{ .start = start, .retire = retire, .retire_unready = mix.old_unready() };
}

fn budget_recreate(desired: u32, mix: *const Mix) Plan {
    const start = if (mix.old_live == 0) desired -| mix.new_live else 0;
    if (start > 0) assert(mix.old_live == 0);
    if (start > 0) assert(mix.new_live + start == desired);
    return .{ .start = start, .retire = mix.old_ready, .retire_unready = mix.old_unready() };
}

/// Whether the rollout's work is finished: no old replica is live and `desired` new ones are
/// ready.
pub fn done(desired: u32, mix: *const Mix) bool {
    mix.assert_valid();
    if (mix.old_live != 0) return false;
    return mix.new_ready >= desired;
}

/// A replica is ready once the controller has seen it healthy (or, with no health check,
/// running) for `min_ready_ms` on its own clock: `since_ms` is when it saw that, null if it has
/// not. No clock of another machine enters it (the C1 lease-clock rule).
pub fn ready(since_ms: ?u64, now_ms: u64, min_ready_ms: u32) bool {
    const at = ready_at(since_ms, min_ready_ms) orelse return false;
    return at <= now_ms;
}

/// When a replica seen healthy since `since_ms` becomes ready; null if it has not been seen so.
pub fn ready_at(since_ms: ?u64, min_ready_ms: u32) ?u64 {
    const since = since_ms orelse return null;
    const at = since + min_ready_ms;
    assert(at >= since);
    return at;
}

/// A rollout's state as the controller keeps it between passes.
pub const State = struct {
    phase: Phase,
    started_at_ms: u64,
    deadline_at_ms: u64,
    /// When the current pause began: set exactly while `phase` is `paused`.
    paused_at_ms: ?u64 = null,

    pub fn assert_valid(state: *const State) void {
        assert(state.deadline_at_ms >= state.started_at_ms);
        if (state.phase == .paused) {
            assert(state.paused_at_ms != null);
        } else {
            assert(state.paused_at_ms == null);
        }
        if (state.paused_at_ms) |paused_at| assert(paused_at >= state.started_at_ms);
    }
};

pub const Reason = enum { apply, rollback };

/// A rollout starting at `now_ms`: a new generation was applied (`apply`), or the automatic
/// rollback landed (`rollback`). From any phase: a newer generation replaces the rollout's target.
pub fn begin(policy: *const Policy, reason: Reason, now_ms: u64) State {
    assert(policy_valid(policy));
    const state: State = .{
        .phase = switch (reason) {
            .apply => .progressing,
            .rollback => .rolling_back,
        },
        .started_at_ms = now_ms,
        .deadline_at_ms = now_ms + policy.progress_deadline_ms,
    };
    state.assert_valid();
    assert(active(state.phase));
    return state;
}

/// Why a rollout failed, most pressing first: `pass` reports the first that holds.
pub const Failure = enum {
    /// A new replica is held (`hold_failed_replica`): it will not start again by itself.
    held,
    /// A new replica restarted more than the rollout allows.
    restarts,
    /// A new replica was not ready within `ready_timeout_ms`.
    ready_timeout,
    /// The rollout passed `progress_deadline_ms`.
    deadline,

    pub fn code(failure: Failure) Code {
        return switch (failure) {
            .held, .restarts, .ready_timeout => .E0304,
            .deadline => .E0306,
        };
    }
};

/// What one pass of the controller sees besides the mix. Counting restarts against a bound and
/// placing replicas are the controller's; the plan takes their verdicts.
pub const Facts = struct {
    desired: u32,
    mix: Mix,
    now_ms: u64,
    /// A new replica is held.
    new_held: bool = false,
    /// A new replica restarted more often than the rollout allows.
    new_restarts_exceeded: bool = false,
    /// When the controller first saw the longest-waiting new replica that is live and not ready;
    /// null if every live new replica is ready.
    new_unready_since_ms: ?u64 = null,
    /// The earliest moment a replica the controller has seen healthy becomes ready
    /// (`ready_at`); null if none is waiting for `min_ready_ms`.
    ready_pending_at_ms: ?u64 = null,
    /// The scheduler could place none of the new replicas the budget allowed last pass.
    unplaceable: bool = false,
};

/// What a pass of the rollout controller decides.
pub const Pass = struct {
    state: State,
    plan: Plan,
    /// Set on the pass whose failure moved the rollout to `failed` or `paused`.
    failure: ?Failure = null,
    /// A rollback is owed: the controller calls the API's rollback handler (`auto_rollback`),
    /// on every pass until a new generation begins a rollout.
    rollback: bool = false,
    /// New replicas the budget allows cannot be placed (ZC-E0305). Not a failure: the rollout
    /// goes on once one can be, and the progress deadline ends it if none ever can.
    stalled: bool = false,
    /// When the controller should look again without a store change: the deadline, a ready
    /// timeout or a replica becoming ready. Null outside the active phases.
    next_at_ms: ?u64 = null,
};

/// One pass: the phase that follows `state` on what `facts` shows, and the budget in it.
pub fn pass(policy: *const Policy, state: *const State, facts: *const Facts) Pass {
    assert(policy_valid(policy));
    state.assert_valid();
    facts.mix.assert_valid();
    var result: Pass = .{ .state = state.*, .plan = .{} };
    switch (state.phase) {
        .complete, .paused => {},
        .failed => switch (policy.on_failure) {
            .rollback => result.rollback = true,
            .pause => result.state = paused(state, facts.now_ms),
        },
        .progressing, .rolling_back => pass_active(policy, state, facts, &result),
    }
    result.state.assert_valid();
    if (result.rollback) assert(result.state.phase == .failed);
    if (!active(result.state.phase)) assert(result.plan.zero());
    return result;
}

fn pass_active(policy: *const Policy, state: *const State, facts: *const Facts, out: *Pass) void {
    assert(active(state.phase));
    assert(out.plan.zero());
    if (done(facts.desired, &facts.mix)) {
        out.state = finished(state, .complete);
        return;
    }
    if (failure_of(policy, state, facts)) |failure| {
        out.failure = failure;
        out.state = paused(state, facts.now_ms);
        if (state.phase == .progressing) {
            if (policy.on_failure == .rollback) {
                out.state = finished(state, .failed);
                out.rollback = true;
            }
        }
        return;
    }
    out.plan = budget(policy, facts.desired, &facts.mix, state.phase);
    out.stalled = facts.unplaceable and out.plan.start > 0;
    out.next_at_ms = next_at(policy, state, facts);
    assert(out.state.phase == state.phase);
}

fn failure_of(policy: *const Policy, state: *const State, facts: *const Facts) ?Failure {
    assert(active(state.phase));
    if (facts.new_held) return .held;
    if (facts.new_restarts_exceeded) return .restarts;
    if (facts.new_unready_since_ms) |since| {
        assert(facts.mix.new_ready < facts.mix.new_live);
        if (facts.now_ms -| since >= policy.ready_timeout_ms) return .ready_timeout;
    }
    if (facts.now_ms >= state.deadline_at_ms) return .deadline;
    return null;
}

/// The earliest moment after `now_ms` at which a pass could decide something new without a
/// store change.
fn next_at(policy: *const Policy, state: *const State, facts: *const Facts) u64 {
    assert(facts.now_ms < state.deadline_at_ms);
    var at = state.deadline_at_ms;
    if (facts.new_unready_since_ms) |since| {
        at = @min(at, since + policy.ready_timeout_ms);
    }
    if (facts.ready_pending_at_ms) |pending| {
        if (pending > facts.now_ms) at = @min(at, pending);
    }
    assert(at > facts.now_ms);
    return at;
}

fn finished(state: *const State, phase: Phase) State {
    assert(!active(phase));
    assert(phase != .paused);
    assert(state.paused_at_ms == null);
    var next = state.*;
    next.phase = phase;
    return next;
}

fn paused(state: *const State, now_ms: u64) State {
    assert(state.phase != .paused);
    assert(state.phase != .complete);
    var next = state.*;
    next.phase = .paused;
    next.paused_at_ms = @max(now_ms, state.started_at_ms);
    return next;
}

pub const Refusal = error{
    /// Nothing to pause or resume (ZC-E0129): the rollout is complete, failed, or (for resume)
    /// not paused.
    NoRollout,
};

/// A user's pause: the rollout starts and retires nothing until `resume_rollout`. Pausing a paused
/// rollout changes nothing.
pub fn pause_rollout(state: *const State, now_ms: u64) Refusal!State {
    state.assert_valid();
    const next = switch (state.phase) {
        .paused => state.*,
        .progressing, .rolling_back => paused(state, now_ms),
        .complete, .failed => return error.NoRollout,
    };
    next.assert_valid();
    assert(next.phase == .paused);
    return next;
}

/// A user's resume: the rollout goes on, its deadline moved by the time it was paused. Resuming
/// a rollout that is not paused changes nothing. A resumed rollback is `progressing`: it is an
/// ordinary rollout from then on, and its failure follows `on_failure`.
pub fn resume_rollout(state: *const State, now_ms: u64) Refusal!State {
    state.assert_valid();
    const next: State = switch (state.phase) {
        .progressing, .rolling_back => state.*,
        .paused => .{
            .phase = .progressing,
            .started_at_ms = state.started_at_ms,
            .deadline_at_ms = state.deadline_at_ms + (now_ms -| state.paused_at_ms.?),
        },
        .complete, .failed => return error.NoRollout,
    };
    next.assert_valid();
    assert(next.deadline_at_ms >= state.deadline_at_ms);
    return next;
}

comptime {
    // The default policy is one `apply` admits: a service with no `rollout` can always roll.
    const default: Policy = .{};
    assert(policy_valid(&default));
}

const testing = std.testing;

/// A mix in one line for the tables: new live, new ready, old live, old ready, old stopping.
fn mix_of(new_live: u32, new_ready: u32, old_live: u32, old_ready: u32, old_stopping: u32) Mix {
    const mix: Mix = .{
        .new_live = new_live,
        .new_ready = new_ready,
        .old_live = old_live,
        .old_ready = old_ready,
        .old_stopping = old_stopping,
    };
    mix.assert_valid();
    return mix;
}

test "rollout plan: the rolling budget, case by case" {
    // Goal: the budget formula gives the expected start and retire counts in the cases a rolling
    // update passes through. Method: a table of (policy, desired, mix) with the plan each must
    // give, read off the formula by hand.
    const surge: Policy = .{};
    const unavailable: Policy = .{ .max_surge = 0, .max_unavailable = 1 };
    const Case = struct { policy: Policy, desired: u32, mix: Mix, plan: Plan };
    const cases = [_]Case{
        // Three old and ready: one new may start, nothing may go yet.
        .{ .policy = surge, .desired = 3, .mix = mix_of(0, 0, 3, 3, 0), .plan = .{ .start = 1 } },
        // The surge replica is not ready yet: wait.
        .{ .policy = surge, .desired = 3, .mix = mix_of(1, 0, 3, 3, 0), .plan = .{} },
        // It is ready: one old may go.
        .{ .policy = surge, .desired = 3, .mix = mix_of(1, 1, 3, 3, 0), .plan = .{ .retire = 1 } },
        // That one is stopping: it still counts as live, and not as ready.
        .{ .policy = surge, .desired = 3, .mix = mix_of(1, 1, 3, 2, 1), .plan = .{} },
        // Observed stopped: the next new one may start.
        .{ .policy = surge, .desired = 3, .mix = mix_of(1, 1, 2, 2, 0), .plan = .{ .start = 1 } },
        // No surge, one unavailable: retire first, then start.
        .{ .policy = unavailable, .desired = 3, .mix = mix_of(0, 0, 3, 3, 0), .plan = .{
            .retire = 1,
        } },
        .{ .policy = unavailable, .desired = 3, .mix = mix_of(0, 0, 2, 2, 0), .plan = .{
            .start = 1,
        } },
        // An old replica that is not ready costs nothing to retire.
        .{ .policy = surge, .desired = 3, .mix = mix_of(0, 0, 3, 2, 0), .plan = .{
            .start = 1,
            .retire_unready = 1,
        } },
        // A node was lost: two old remain, below the minimum. Start two, retire none.
        .{ .policy = surge, .desired = 3, .mix = mix_of(0, 0, 2, 2, 0), .plan = .{ .start = 2 } },
        // Scaled to zero mid-rollout: every old ready replica may go, nothing starts.
        .{ .policy = surge, .desired = 0, .mix = mix_of(0, 0, 2, 2, 0), .plan = .{ .retire = 2 } },
        // All new are ready: every old may go at once.
        .{ .policy = surge, .desired = 3, .mix = mix_of(3, 3, 2, 2, 0), .plan = .{ .retire = 2 } },
    };
    for (cases, 0..) |case, index| {
        const plan = budget(&case.policy, case.desired, &case.mix, .progressing);
        testing.expectEqualDeep(case.plan, plan) catch |err| {
            std.debug.print("case {d}\n", .{index});
            return err;
        };
        // The same mix in a rollback rolls the same way.
        const back = budget(&case.policy, case.desired, &case.mix, .rolling_back);
        try testing.expectEqualDeep(plan, back);
    }
}

test "rollout plan: recreate retires every old replica before it starts" {
    // Goal: `recreate` starts nothing while an old replica is live, and then starts them all.
    // Method: the three moments of a recreate rollout.
    const policy: Policy = .{ .strategy = .recreate, .max_surge = 0 };
    const all_old: Mix = .{ .old_live = 3, .old_ready = 2 };
    const first = budget(&policy, 3, &all_old, .progressing);
    try testing.expectEqualDeep(Plan{ .retire = 2, .retire_unready = 1 }, first);
    const draining: Mix = .{ .old_live = 3, .old_stopping = 3 };
    try testing.expectEqualDeep(Plan{}, budget(&policy, 3, &draining, .progressing));
    const empty: Mix = .{ .new_live = 1 };
    try testing.expectEqualDeep(Plan{ .start = 2 }, budget(&policy, 3, &empty, .progressing));
}

test "rollout plan: only progressing and rolling_back move replicas" {
    // Goal: a paused, complete or failed rollout starts and retires nothing (R4). Method: a mix
    // that would get a budget in every phase.
    const policy: Policy = .{};
    const mix: Mix = .{ .new_live = 1, .new_ready = 1, .old_live = 3, .old_ready = 2 };
    for ([_]Phase{ .paused, .complete, .failed }) |phase| {
        try testing.expect(budget(&policy, 3, &mix, phase).zero());
    }
    for ([_]Phase{ .progressing, .rolling_back }) |phase| {
        try testing.expect(!budget(&policy, 3, &mix, phase).zero());
    }
    // Ready is 3 = desired, so no ready old replica may go (R1); the unready one may.
    const plan = budget(&policy, 3, &mix, .progressing);
    try testing.expectEqualDeep(Plan{ .retire_unready = 1 }, plan);
    try testing.expectEqualDeep(records.RolloutBudget{ .start = 0, .retire = 1 }, plan.stored());
}

test "rollout plan: policies the API refuses are not valid" {
    // Goal: `policy_valid` is decision 10's bounds. Method: the boundary on each side.
    try testing.expect(policy_valid(&.{}));
    try testing.expect(!policy_valid(&.{ .max_surge = 0, .max_unavailable = 0 }));
    try testing.expect(policy_valid(&.{ .strategy = .recreate, .max_surge = 0 }));
    try testing.expect(policy_valid(&.{ .max_surge = constants.replicas_per_service_max }));
    try testing.expect(!policy_valid(&.{ .max_surge = constants.replicas_per_service_max + 1 }));
    const too_many = constants.replicas_per_service_max + 1;
    try testing.expect(!policy_valid(&.{ .max_unavailable = too_many }));
    try testing.expect(!policy_valid(&.{ .min_ready_ms = 120_000 }));
    try testing.expect(policy_valid(&.{ .ready_timeout_ms = 600_000 }));
    try testing.expect(!policy_valid(&.{ .ready_timeout_ms = 600_001 }));
}

test "rollout plan: readiness is timed on the controller's clock" {
    // Goal: a replica is ready exactly `min_ready_ms` after the controller saw it healthy.
    try testing.expect(!ready(null, 1_000_000, 5_000));
    try testing.expect(!ready(10_000, 14_999, 5_000));
    try testing.expect(ready(10_000, 15_000, 5_000));
    try testing.expect(ready(10_000, 10_000, 0));
    try testing.expectEqual(@as(?u64, 15_000), ready_at(10_000, 5_000));
    try testing.expectEqual(@as(?u64, null), ready_at(null, 5_000));
}

const t0: u64 = 1_000_000;
const rolling_mix: Mix = .{ .new_live = 1, .old_live = 3, .old_ready = 3 };
const done_mix: Mix = .{ .new_live = 3, .new_ready = 3 };

fn state_in(phase: Phase) State {
    return .{
        .phase = phase,
        .started_at_ms = t0,
        .deadline_at_ms = t0 + 600_000,
        .paused_at_ms = if (phase == .paused) t0 + 1_000 else null,
    };
}

test "rollout plan: every edge of a pass" {
    // Goal: each phase moves where the module's header says on a pass, and nowhere else. Method:
    // a table of (phase, on_failure, facts) with the phase, failure and rollback each must give.
    const Case = struct {
        from: Phase,
        on_failure: records.RolloutOnFailure = .rollback,
        facts: Facts,
        to: Phase,
        failure: ?Failure = null,
        rollback: bool = false,
    };
    const now = t0 + 10_000;
    const plain: Facts = .{ .desired = 3, .mix = rolling_mix, .now_ms = now };
    const finished_facts: Facts = .{ .desired = 3, .mix = done_mix, .now_ms = now };
    var held = plain;
    held.new_held = true;
    const f: ?Failure = .held;
    const cases = [_]Case{
        .{ .from = .progressing, .facts = plain, .to = .progressing },
        .{ .from = .progressing, .facts = finished_facts, .to = .complete },
        .{ .from = .progressing, .facts = held, .to = .failed, .failure = .held, .rollback = true },
        .{ .from = .progressing, .on_failure = .pause, .facts = held, .to = .paused, .failure = f },
        .{ .from = .rolling_back, .facts = plain, .to = .rolling_back },
        .{ .from = .rolling_back, .facts = finished_facts, .to = .complete },
        .{ .from = .rolling_back, .facts = held, .to = .paused, .failure = .held },
        .{
            .from = .rolling_back,
            .on_failure = .pause,
            .facts = held,
            .to = .paused,
            .failure = f,
        },
        .{ .from = .paused, .facts = plain, .to = .paused },
        .{ .from = .paused, .facts = finished_facts, .to = .paused },
        .{ .from = .paused, .facts = held, .to = .paused },
        .{ .from = .complete, .facts = plain, .to = .complete },
        .{ .from = .complete, .facts = held, .to = .complete },
        .{ .from = .failed, .facts = plain, .to = .failed, .rollback = true },
        .{ .from = .failed, .facts = finished_facts, .to = .failed, .rollback = true },
        .{ .from = .failed, .on_failure = .pause, .facts = plain, .to = .paused },
    };
    for (cases, 0..) |case, index| {
        const policy: Policy = .{ .on_failure = case.on_failure };
        const state = state_in(case.from);
        const result = pass(&policy, &state, &case.facts);
        errdefer std.debug.print("case {d}\n", .{index});
        try testing.expectEqual(case.to, result.state.phase);
        try testing.expectEqual(case.failure, result.failure);
        try testing.expectEqual(case.rollback, result.rollback);
        try testing.expectEqual(state.started_at_ms, result.state.started_at_ms);
        try testing.expectEqual(state.deadline_at_ms, result.state.deadline_at_ms);
        if (case.to == .paused) {
            const paused_at = result.state.paused_at_ms;
            if (case.from != .paused) try testing.expectEqual(@as(?u64, now), paused_at);
        }
        if (!active(case.to)) try testing.expect(result.plan.zero());
        if (!active(case.to)) try testing.expectEqual(@as(?u64, null), result.next_at_ms);
    }
}

test "rollout plan: failures in order, and done before any" {
    // Goal: when several failures hold, the most pressing is reported; a finished rollout is
    // complete even past its deadline. Method: facts with failures added one by one.
    const policy: Policy = .{};
    const state = state_in(.progressing);
    const late = state.deadline_at_ms;
    var facts: Facts = .{ .desired = 3, .mix = rolling_mix, .now_ms = late };
    try testing.expectEqual(@as(?Failure, .deadline), pass(&policy, &state, &facts).failure);
    facts.new_unready_since_ms = late - policy.ready_timeout_ms;
    try testing.expectEqual(@as(?Failure, .ready_timeout), pass(&policy, &state, &facts).failure);
    facts.new_restarts_exceeded = true;
    try testing.expectEqual(@as(?Failure, .restarts), pass(&policy, &state, &facts).failure);
    facts.new_held = true;
    try testing.expectEqual(@as(?Failure, .held), pass(&policy, &state, &facts).failure);
    try testing.expectEqual(Code.E0304, Failure.held.code());
    try testing.expectEqual(Code.E0306, Failure.deadline.code());

    const finished_facts: Facts = .{
        .desired = 3,
        .mix = done_mix,
        .now_ms = late,
        .new_held = true,
    };
    const result = pass(&policy, &state, &finished_facts);
    try testing.expectEqual(Phase.complete, result.state.phase);
    try testing.expectEqual(@as(?Failure, null), result.failure);
}

test "rollout plan: a ready timeout fires at its boundary, not before" {
    // Goal: `ready_timeout_ms` counts from when the controller first saw the replica unready.
    const policy: Policy = .{};
    const state = state_in(.progressing);
    const since = t0 + 1_000;
    var facts: Facts = .{
        .desired = 3,
        .mix = rolling_mix,
        .now_ms = since + policy.ready_timeout_ms - 1,
        .new_unready_since_ms = since,
    };
    const waiting = pass(&policy, &state, &facts);
    try testing.expectEqual(@as(?Failure, null), waiting.failure);
    try testing.expectEqual(@as(?u64, since + policy.ready_timeout_ms), waiting.next_at_ms);
    facts.now_ms += 1;
    try testing.expectEqual(@as(?Failure, .ready_timeout), pass(&policy, &state, &facts).failure);
}

test "rollout plan: the next look is the earliest timer" {
    // Goal: `next_at_ms` is the deadline, a ready timeout or a replica becoming ready, whichever
    // comes first, and never a moment already past.
    const policy: Policy = .{};
    const state = state_in(.progressing);
    var facts: Facts = .{ .desired = 3, .mix = rolling_mix, .now_ms = t0 + 10 };
    const deadline: ?u64 = state.deadline_at_ms;
    try testing.expectEqual(deadline, pass(&policy, &state, &facts).next_at_ms);
    facts.new_unready_since_ms = t0;
    try testing.expectEqual(@as(?u64, t0 + 120_000), pass(&policy, &state, &facts).next_at_ms);
    facts.ready_pending_at_ms = t0 + 5_000;
    try testing.expectEqual(@as(?u64, t0 + 5_000), pass(&policy, &state, &facts).next_at_ms);
    facts.ready_pending_at_ms = t0 + 10;
    try testing.expectEqual(@as(?u64, t0 + 120_000), pass(&policy, &state, &facts).next_at_ms);
}

test "rollout plan: a stall is reported and is not a failure" {
    // Goal: new replicas that cannot be placed set `stalled` (ZC-E0305) while the budget allows
    // a start, and leave the phase alone; with nothing to start there is no stall.
    const policy: Policy = .{};
    const state = state_in(.progressing);
    var facts: Facts = .{
        .desired = 3,
        .mix = .{ .old_live = 3, .old_ready = 3 },
        .now_ms = t0 + 10,
        .unplaceable = true,
    };
    const stalled = pass(&policy, &state, &facts);
    try testing.expect(stalled.stalled);
    try testing.expectEqual(Phase.progressing, stalled.state.phase);
    facts.mix = rolling_mix;
    try testing.expect(!pass(&policy, &state, &facts).stalled);
}

test "rollout plan: every edge of pause, resume and begin" {
    // Goal: pause and resume move between the phases the header names and refuse the rest
    // (ZC-E0129); resume moves the deadline by the paused time; begin starts from any phase.
    const now = t0 + 50_000;
    for ([_]Phase{ .progressing, .rolling_back }) |phase| {
        const state = state_in(phase);
        const held = try pause_rollout(&state, now);
        try testing.expectEqual(Phase.paused, held.phase);
        try testing.expectEqual(@as(?u64, now), held.paused_at_ms);
        try testing.expectEqualDeep(state, try resume_rollout(&state, now));
    }
    const paused_state = state_in(.paused);
    try testing.expectEqualDeep(paused_state, try pause_rollout(&paused_state, now));
    const resumed = try resume_rollout(&paused_state, now);
    try testing.expectEqual(Phase.progressing, resumed.phase);
    try testing.expectEqual(@as(?u64, null), resumed.paused_at_ms);
    const paused_ms = now - paused_state.paused_at_ms.?;
    try testing.expectEqual(paused_state.deadline_at_ms + paused_ms, resumed.deadline_at_ms);
    for ([_]Phase{ .complete, .failed }) |phase| {
        const state = state_in(phase);
        try testing.expectError(error.NoRollout, pause_rollout(&state, now));
        try testing.expectError(error.NoRollout, resume_rollout(&state, now));
    }
    const policy: Policy = .{ .progress_deadline_ms = 300_000 };
    const applied = begin(&policy, .apply, now);
    try testing.expectEqual(Phase.progressing, applied.phase);
    try testing.expectEqual(now + 300_000, applied.deadline_at_ms);
    try testing.expectEqual(Phase.rolling_back, begin(&policy, .rollback, now).phase);
}
