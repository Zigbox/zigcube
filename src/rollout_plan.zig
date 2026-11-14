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
//!     progressing, rolling_back ── done ──► complete
//!     progressing  ── failure, on_failure rollback ──► failed   (a rollback is owed, if the
//!                                                                  service ran an earlier
//!                                                                  generation)
//!     rolling_back ── failure, on_failure rollback ──► failed   (nothing owed: not rolled back)
//!     progressing, rolling_back ── failure, on_failure pause ──► paused (by the failure)
//!     failed       ── on_failure pause (a policy changed since) ──► paused (by the failure)
//!     progressing, rolling_back ── pause ──► paused (by the user)
//!     failed       ── pause ──► paused (by the failure)
//!     paused       ── resume ──► progressing or rolling_back, as the rollout's reason says
//!
//! A failed rollout that owes nothing (a failed rollback, or a failed first generation: there is
//! nothing to roll back to) has ended (R7); it waits for the user's next apply.
//! A rollout leaves `failed` only by `begin` or a pause: the automatic rollback lands as a new
//! generation (`begin(rollback)`), or a newer user apply does (`begin(apply)`). `begin` from any
//! phase starts a rollout from the current mix of replicas. `paused` and `failed` start and retire
//! nothing; replacing a replica that failed on its own is the replica controller's, outside the
//! budget. A resumed rollout is judged only on failures seen after the resume
//! (`State.evidence_from_ms`), except a new replica still held, which fails it again at once.
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

    /// The budget as `/rollouts` stores it, the two retire counts apart: R1 limits `retire`
    /// alone, so a replica that turns ready between the plan and the act is never retired on the
    /// unready count.
    pub fn stored(plan: *const Plan) records.RolloutBudget {
        return .{
            .start = plan.start,
            .retire = plan.retire,
            .retire_unready = plan.retire_unready,
        };
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

/// What a rollout is for: a new generation applied by the user (`apply`), or the automatic or
/// user rollback that landed as one (`rollback`). It names the active phase (`active_phase`).
pub const Reason = enum {
    apply,
    rollback,

    pub fn active_phase(reason: Reason) Phase {
        return switch (reason) {
            .apply => .progressing,
            .rollback => .rolling_back,
        };
    }
};

/// Why a rollout is paused: the user paused it (`pause_rollout`), or it stopped for a failure
/// (`on_failure pause`, or a pause of a `failed` rollout). Resume treats them apart.
pub const PauseCause = enum { user, failure };

/// A rollout's state as the controller keeps it between passes.
pub const State = struct {
    phase: Phase,
    reason: Reason,
    /// The service ran a generation before this rollout's target (the `/rollouts` record's
    /// `from` is not 0), so a failure has something to roll back to. A rollback always has one.
    earlier: bool,
    started_at_ms: u64,
    deadline_at_ms: u64,
    /// Failures the controller saw before this moment do not count: the start, or the last
    /// resume. A resumed rollout is judged on what happens after the resume only.
    evidence_from_ms: u64,
    /// When the current pause began: set exactly while `phase` is `paused`.
    paused_at_ms: ?u64 = null,
    /// Why: set exactly while `phase` is `paused`.
    paused_by: ?PauseCause = null,

    pub fn assert_valid(state: *const State) void {
        assert(state.deadline_at_ms >= state.started_at_ms);
        assert(state.evidence_from_ms >= state.started_at_ms);
        if (state.phase == .paused) {
            assert(state.paused_at_ms != null);
            assert(state.paused_by != null);
        } else {
            assert(state.paused_at_ms == null);
            assert(state.paused_by == null);
        }
        if (active(state.phase)) assert(state.phase == state.reason.active_phase());
        if (state.reason == .rollback) assert(state.earlier);
        if (state.paused_at_ms) |paused_at| assert(paused_at >= state.evidence_from_ms);
    }
};

/// A rollout starting at `now_ms` for `reason`. From any phase: a newer generation replaces the
/// rollout's target. `earlier` says whether the service ran a generation before the target (false
/// for its first generation, whose failure owes no rollback).
pub fn begin(policy: *const Policy, reason: Reason, earlier: bool, now_ms: u64) State {
    assert(policy_valid(policy));
    if (reason == .rollback) assert(earlier);
    const state: State = .{
        .phase = reason.active_phase(),
        .reason = reason,
        .earlier = earlier,
        .started_at_ms = now_ms,
        .deadline_at_ms = now_ms + policy.progress_deadline_ms,
        .evidence_from_ms = now_ms,
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
    /// The rollout passed `progress_deadline_ms` while new replicas could not be placed: the
    /// cluster is at fault, not the release (ZC-E0305, blame environment).
    stalled,
    /// The rollout passed `progress_deadline_ms`.
    deadline,

    pub fn code(failure: Failure) Code {
        return switch (failure) {
            .held, .restarts, .ready_timeout => .E0304,
            .stalled => .E0305,
            .deadline => .E0306,
        };
    }
};

/// What one pass of the controller sees besides the mix. Counting restarts against a bound and
/// placing replicas are the controller's; the plan takes their verdicts, with the moment each
/// was first seen so that a resumed rollout is not failed again on what it was paused for (a held
/// replica excepted: it is still there).
pub const Facts = struct {
    desired: u32,
    mix: Mix,
    now_ms: u64,
    /// When the controller saw the most recently held new replica become held; null if none is.
    new_held_at_ms: ?u64 = null,
    /// When the controller saw the most recent new replica pass the restart bound (slice 7's
    /// `rollout_restarts_max`); null if none has.
    new_restarts_exceeded_at_ms: ?u64 = null,
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
    /// goes on once one can be, and the progress deadline ends it (`Failure.stalled`) if none
    /// ever can.
    stalled: bool = false,
    /// When the controller should look again without a store change: the deadline, a ready
    /// timeout or a replica becoming ready. Null outside the active phases.
    next_at_ms: ?u64 = null,
};

/// Whether a rollout in `state` owes a rollback under `policy`: it failed, its policy says
/// `rollback`, it was not itself a rollback (a failed rollback is not rolled back again), and the
/// service ran an earlier generation (a failed first generation has nothing to roll back to, so it
/// ends `failed`: docs/decisions/2026-11-14-c3-first-generation-failure.md).
pub fn rollback_owed(policy: *const Policy, state: *const State) bool {
    if (state.phase != .failed) return false;
    if (policy.on_failure != .rollback) return false;
    if (!state.earlier) return false;
    return state.reason == .apply;
}

/// One pass: the phase that follows `state` on what `facts` shows, and the budget in it.
pub fn pass(policy: *const Policy, state: *const State, facts: *const Facts) Pass {
    assert(policy_valid(policy));
    state.assert_valid();
    facts.mix.assert_valid();
    var result: Pass = .{ .state = state.*, .plan = .{} };
    switch (state.phase) {
        .complete, .paused => {},
        .failed => switch (policy.on_failure) {
            .rollback => result.rollback = rollback_owed(policy, state),
            .pause => result.state = paused(state, facts.now_ms, .failure),
        },
        .progressing, .rolling_back => pass_active(policy, state, facts, &result),
    }
    result.state.assert_valid();
    assert(result.rollback == rollback_owed(policy, &result.state));
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
    const plan = budget(policy, facts.desired, &facts.mix, state.phase);
    const stalled = facts.unplaceable and plan.start > 0;
    if (failure_of(policy, state, facts, stalled)) |failure| {
        out.failure = failure;
        switch (policy.on_failure) {
            .pause => out.state = paused(state, facts.now_ms, .failure),
            .rollback => {
                out.state = finished(state, .failed);
                out.rollback = rollback_owed(policy, &out.state);
            },
        }
        return;
    }
    out.plan = plan;
    out.stalled = stalled;
    out.next_at_ms = next_at(policy, state, facts);
    assert(out.state.phase == state.phase);
}

fn failure_of(
    policy: *const Policy,
    state: *const State,
    facts: *const Facts,
    stalled: bool,
) ?Failure {
    assert(active(state.phase));
    const from = state.evidence_from_ms;
    // A held replica is not a past event but a present one: it is never replaced within its
    // generation and holds its slot, so a rollout resumed with one still held could only end at
    // its deadline. It fails again at once (C3 slice 7, sim-c3 seed 63).
    if (facts.new_held_at_ms != null) return .held;
    if (facts.new_restarts_exceeded_at_ms) |at| {
        if (at >= from) return .restarts;
    }
    if (facts.new_unready_since_ms) |since| {
        assert(facts.mix.new_ready < facts.mix.new_live);
        if (facts.now_ms -| @max(since, from) >= policy.ready_timeout_ms) return .ready_timeout;
    }
    if (facts.now_ms >= state.deadline_at_ms) return if (stalled) .stalled else .deadline;
    return null;
}

/// The earliest moment after `now_ms` at which a pass could decide something new without a
/// store change.
fn next_at(policy: *const Policy, state: *const State, facts: *const Facts) u64 {
    assert(facts.now_ms < state.deadline_at_ms);
    var at = state.deadline_at_ms;
    if (facts.new_unready_since_ms) |since| {
        at = @min(at, @max(since, state.evidence_from_ms) + policy.ready_timeout_ms);
    }
    if (facts.ready_pending_at_ms) |pending| {
        if (pending > facts.now_ms) at = @min(at, pending);
    }
    assert(at > facts.now_ms);
    return at;
}

fn finished(state: *const State, phase: Phase) State {
    assert(active(state.phase));
    assert(!active(phase));
    assert(phase != .paused);
    var next = state.*;
    next.phase = phase;
    return next;
}

fn paused(state: *const State, now_ms: u64, cause: PauseCause) State {
    assert(state.phase != .paused);
    assert(state.phase != .complete);
    var next = state.*;
    next.phase = .paused;
    next.paused_at_ms = @max(now_ms, state.evidence_from_ms);
    next.paused_by = cause;
    return next;
}

pub const Refusal = error{
    /// Nothing to pause or resume (ZC-E0129): the rollout is complete, or (for resume) failed.
    NoRollout,
};

/// A user's pause: the rollout starts and retires nothing until `resume_rollout`. Pausing a paused
/// rollout changes nothing. A `failed` rollout may be paused: that stops a rollback it owes (a
/// failed first generation owes none: it has ended), and a resume gives it a fresh deadline. Its
/// pause counts as a failure's.
pub fn pause_rollout(state: *const State, now_ms: u64) Refusal!State {
    state.assert_valid();
    const next = switch (state.phase) {
        .paused => state.*,
        .progressing, .rolling_back => paused(state, now_ms, .user),
        .failed => paused(state, now_ms, .failure),
        .complete => return error.NoRollout,
    };
    next.assert_valid();
    assert(next.phase == .paused);
    return next;
}

/// A user's resume: the rollout goes on in the phase its reason names, so a paused rollback
/// stays a rollback. Failures seen before the resume no longer count. After a user's pause the
/// deadline moves by the time it was paused; after a failure's it starts again from the resume,
/// so a rollout paused for passing its deadline is not failed again at once. Resuming a running
/// rollout changes nothing.
pub fn resume_rollout(policy: *const Policy, state: *const State, now_ms: u64) Refusal!State {
    assert(policy_valid(policy));
    state.assert_valid();
    const next: State = switch (state.phase) {
        .progressing, .rolling_back => state.*,
        .paused => resumed(policy, state, now_ms),
        .complete, .failed => return error.NoRollout,
    };
    next.assert_valid();
    assert(active(next.phase));
    assert(next.reason == state.reason);
    assert(next.evidence_from_ms >= state.evidence_from_ms);
    return next;
}

fn resumed(policy: *const Policy, state: *const State, now_ms: u64) State {
    assert(state.phase == .paused);
    const paused_at = state.paused_at_ms.?;
    const at = @max(now_ms, paused_at);
    const deadline_at_ms = switch (state.paused_by.?) {
        .user => state.deadline_at_ms + (at - paused_at),
        .failure => at + policy.progress_deadline_ms,
    };
    return .{
        .phase = state.reason.active_phase(),
        .reason = state.reason,
        .earlier = state.earlier,
        .started_at_ms = state.started_at_ms,
        .deadline_at_ms = deadline_at_ms,
        .evidence_from_ms = at,
    };
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
    const stored: records.RolloutBudget = .{ .start = 0, .retire = 0, .retire_unready = 1 };
    try testing.expectEqualDeep(stored, plan.stored());
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
        .reason = if (phase == .rolling_back) .rollback else .apply,
        .earlier = true,
        .started_at_ms = t0,
        .deadline_at_ms = t0 + 600_000,
        .evidence_from_ms = t0,
        .paused_at_ms = if (phase == .paused) t0 + 1_000 else null,
        .paused_by = if (phase == .paused) .user else null,
    };
}

fn state_of(phase: Phase, reason: Reason) State {
    var state = state_in(phase);
    state.reason = reason;
    state.assert_valid();
    return state;
}

test "rollout plan: every edge of a pass" {
    // Goal: each phase moves where the module's header says on a pass, and nowhere else. Method:
    // a table of (phase, reason, on_failure, facts) with the phase, failure and rollback each
    // must give.
    const Case = struct {
        from: Phase,
        reason: Reason = .apply,
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
    held.new_held_at_ms = now;
    const f: ?Failure = .held;
    const back: Reason = .rollback;
    const cases = [_]Case{
        .{ .from = .progressing, .facts = plain, .to = .progressing },
        .{ .from = .progressing, .facts = finished_facts, .to = .complete },
        .{ .from = .progressing, .facts = held, .to = .failed, .failure = .held, .rollback = true },
        .{ .from = .progressing, .on_failure = .pause, .facts = held, .to = .paused, .failure = f },
        .{ .from = .rolling_back, .reason = back, .facts = plain, .to = .rolling_back },
        .{ .from = .rolling_back, .reason = back, .facts = finished_facts, .to = .complete },
        // A failed rollback ends `failed`, owing nothing (R7): it is not rolled back again.
        .{ .from = .rolling_back, .reason = back, .facts = held, .to = .failed, .failure = f },
        .{
            .from = .rolling_back,
            .reason = back,
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
        .{ .from = .failed, .reason = back, .facts = plain, .to = .failed },
        .{ .from = .failed, .on_failure = .pause, .facts = plain, .to = .paused },
    };
    for (cases, 0..) |case, index| {
        const policy: Policy = .{ .on_failure = case.on_failure };
        const state = state_of(case.from, case.reason);
        const result = pass(&policy, &state, &case.facts);
        errdefer std.debug.print("case {d}\n", .{index});
        try testing.expectEqual(case.to, result.state.phase);
        try testing.expectEqual(case.failure, result.failure);
        try testing.expectEqual(case.rollback, result.rollback);
        try testing.expectEqual(state.reason, result.state.reason);
        try testing.expectEqual(state.earlier, result.state.earlier);
        try testing.expectEqual(state.started_at_ms, result.state.started_at_ms);
        try testing.expectEqual(state.deadline_at_ms, result.state.deadline_at_ms);
        if (case.to == .paused and case.from != .paused) {
            try testing.expectEqual(@as(?u64, now), result.state.paused_at_ms);
            try testing.expectEqual(@as(?PauseCause, .failure), result.state.paused_by);
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
    facts.new_restarts_exceeded_at_ms = late;
    try testing.expectEqual(@as(?Failure, .restarts), pass(&policy, &state, &facts).failure);
    facts.new_held_at_ms = late;
    try testing.expectEqual(@as(?Failure, .held), pass(&policy, &state, &facts).failure);
    try testing.expectEqual(Code.E0304, Failure.held.code());
    try testing.expectEqual(Code.E0305, Failure.stalled.code());
    try testing.expectEqual(Code.E0306, Failure.deadline.code());

    const finished_facts: Facts = .{
        .desired = 3,
        .mix = done_mix,
        .now_ms = late,
        .new_held_at_ms = late,
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

test "rollout plan: a stall is reported, and at the deadline it is the cluster's failure" {
    // Goal: new replicas that cannot be placed set `stalled` (ZC-E0305) while the budget allows
    // a start, and leave the phase alone; with nothing to start there is no stall. A stall at the
    // deadline fails as `stalled` (E0305, blame environment), not as the release's deadline.
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
    facts.now_ms = state.deadline_at_ms;
    const failed = pass(&policy, &state, &facts);
    try testing.expectEqual(@as(?Failure, .stalled), failed.failure);
    try testing.expectEqual(Phase.failed, failed.state.phase);
    facts.unplaceable = false;
    try testing.expectEqual(@as(?Failure, .deadline), pass(&policy, &state, &facts).failure);
    facts.now_ms = t0 + 10;
    facts.unplaceable = true;
    facts.mix = rolling_mix;
    try testing.expect(!pass(&policy, &state, &facts).stalled);
}

test "rollout plan: every edge of pause, resume and begin" {
    // Goal: pause and resume move between the phases the header names and refuse the rest
    // (ZC-E0129); resume returns to the rollout's own phase and moves a user pause's deadline by
    // the paused time; begin starts from any phase.
    const policy: Policy = .{};
    const now = t0 + 50_000;
    for ([_]Phase{ .progressing, .rolling_back }) |phase| {
        const state = state_in(phase);
        const held = try pause_rollout(&state, now);
        try testing.expectEqual(Phase.paused, held.phase);
        try testing.expectEqual(@as(?u64, now), held.paused_at_ms);
        try testing.expectEqual(@as(?PauseCause, .user), held.paused_by);
        try testing.expectEqualDeep(state, try resume_rollout(&policy, &state, now));
        // A paused rollback resumes as a rollback.
        const later = now + 7_000;
        const resumed_state = try resume_rollout(&policy, &held, later);
        try testing.expectEqual(phase, resumed_state.phase);
        try testing.expectEqual(state.deadline_at_ms + 7_000, resumed_state.deadline_at_ms);
        try testing.expectEqual(later, resumed_state.evidence_from_ms);
    }
    const paused_state = state_in(.paused);
    try testing.expectEqualDeep(paused_state, try pause_rollout(&paused_state, now));
    const resumed_state = try resume_rollout(&policy, &paused_state, now);
    try testing.expectEqual(Phase.progressing, resumed_state.phase);
    try testing.expectEqual(@as(?u64, null), resumed_state.paused_at_ms);
    const paused_ms = now - paused_state.paused_at_ms.?;
    try testing.expectEqual(paused_state.deadline_at_ms + paused_ms, resumed_state.deadline_at_ms);
    // A failed rollout may be paused (its rollback, if owed, stops); it may not be resumed.
    const failed_state = state_in(.failed);
    const held_failed = try pause_rollout(&failed_state, now);
    try testing.expectEqual(@as(?PauseCause, .failure), held_failed.paused_by);
    try testing.expectError(error.NoRollout, resume_rollout(&policy, &failed_state, now));
    const complete_state = state_in(.complete);
    try testing.expectError(error.NoRollout, pause_rollout(&complete_state, now));
    try testing.expectError(error.NoRollout, resume_rollout(&policy, &complete_state, now));
    const short: Policy = .{ .progress_deadline_ms = 300_000 };
    const applied = begin(&short, .apply, true, now);
    try testing.expectEqual(Phase.progressing, applied.phase);
    try testing.expectEqual(now + 300_000, applied.deadline_at_ms);
    try testing.expectEqual(Phase.rolling_back, begin(&short, .rollback, true, now).phase);
}

test "rollout plan: a resumed failure is judged on new evidence only" {
    // Goal: a rollout paused for a failure (on_failure pause) and resumed goes on, and is not
    // failed again on the evidence it was paused for: a passed restart bound, a ready timeout or
    // the deadline. A replica still held fails it again at once (it blocks the rollout for good).
    // New evidence after the resume fails it again. Method: each failure pauses a rollout;
    // resume; the same facts a moment later; then fresh ones.
    const policy: Policy = .{ .on_failure = .pause };
    const Kind = enum { held, restarts, ready_timeout, deadline };
    for ([_]Reason{ .apply, .rollback }) |reason| {
        for (std.enums.values(Kind)) |kind| {
            const state = begin(&policy, reason, true, t0);
            const at = state.deadline_at_ms;
            var facts: Facts = .{ .desired = 3, .mix = rolling_mix, .now_ms = at };
            switch (kind) {
                .held => facts.new_held_at_ms = at - 1,
                .restarts => facts.new_restarts_exceeded_at_ms = at - 1,
                .ready_timeout => facts.new_unready_since_ms = at - policy.ready_timeout_ms,
                .deadline => {},
            }
            const stopped = pass(&policy, &state, &facts);
            try testing.expect(stopped.failure != null);
            try testing.expectEqual(Phase.paused, stopped.state.phase);
            const resume_at = at + 60_000;
            const resumed_state = try resume_rollout(&policy, &stopped.state, resume_at);
            try testing.expectEqual(reason.active_phase(), resumed_state.phase);
            const fresh_deadline = resume_at + policy.progress_deadline_ms;
            try testing.expectEqual(fresh_deadline, resumed_state.deadline_at_ms);
            facts.now_ms = resume_at + 1;
            const again = pass(&policy, &resumed_state, &facts);
            if (kind == .held) {
                try testing.expectEqual(@as(?Failure, .held), again.failure);
                try testing.expectEqual(Phase.paused, again.state.phase);
                continue;
            }
            try testing.expectEqual(@as(?Failure, null), again.failure);
            try testing.expectEqual(reason.active_phase(), again.state.phase);
            // Fresh evidence counts.
            facts.new_held_at_ms = resume_at + 1;
            const fresh = pass(&policy, &resumed_state, &facts);
            try testing.expectEqual(@as(?Failure, .held), fresh.failure);
        }
    }
}

test "rollout plan: a failed first generation under on_failure rollback ends" {
    // Goal: R7 for a service's first generation. The TLA+ model found it never ending (Rollout.tla,
    // FINDINGS.md item 8): it failed owing a rollback to generation 0, which does not exist, so the
    // controller would call the rollback handler forever. Now it ends `failed`, owing nothing.
    // Method: begin a first generation, fail it on each failure, then pass it again long after: it
    // stays `failed`, owes no rollback, plans nothing and asks for no look.
    const policy: Policy = .{};
    assert(policy.on_failure == .rollback);
    const Kind = enum { held, restarts, ready_timeout, deadline };
    for (std.enums.values(Kind)) |kind| {
        const state = begin(&policy, .apply, false, t0);
        const at = state.deadline_at_ms;
        var facts: Facts = .{ .desired = 3, .mix = .{ .new_live = 3 }, .now_ms = at };
        switch (kind) {
            .held => facts.new_held_at_ms = at,
            .restarts => facts.new_restarts_exceeded_at_ms = at,
            .ready_timeout => facts.new_unready_since_ms = at - policy.ready_timeout_ms,
            .deadline => {},
        }
        const failed = pass(&policy, &state, &facts);
        try testing.expectEqual(Phase.failed, failed.state.phase);
        try testing.expect(failed.failure != null);
        try testing.expect(!failed.rollback);
        try testing.expect(!rollback_owed(&policy, &failed.state));
        var later = facts;
        later.now_ms = at + 10 * policy.progress_deadline_ms;
        const again = pass(&policy, &failed.state, &later);
        try testing.expectEqualDeep(failed.state, again.state);
        try testing.expect(!again.rollback);
        try testing.expectEqual(@as(?Failure, null), again.failure);
        try testing.expect(again.plan.zero());
        try testing.expectEqual(@as(?u64, null), again.next_at_ms);
    }
    // Under on_failure pause it pauses, as any failed rollout does.
    var first = state_in(.failed);
    first.earlier = false;
    const pause_policy: Policy = .{ .on_failure = .pause };
    const plain: Facts = .{ .desired = 3, .mix = .{ .new_live = 3 }, .now_ms = t0 + 1 };
    try testing.expectEqual(Phase.paused, pass(&pause_policy, &first, &plain).state.phase);
    // The same rollout of a later generation owes its rollback.
    const later_state = begin(&policy, .apply, true, t0);
    const facts: Facts = .{
        .desired = 3,
        .mix = .{ .new_live = 3 },
        .now_ms = t0,
        .new_held_at_ms = t0,
    };
    try testing.expect(pass(&policy, &later_state, &facts).rollback);
}

test "rollout plan: a first generation keeps owing nothing across pause and resume" {
    // Goal: `earlier` survives a user's pause, a resume, a failure, a pause of the failed rollout
    // and its resume, so the rollout still ends `failed` owing no rollback (the mutation "`resumed`
    // sets `.earlier = true`" fails here); and an apply over it takes `from` from the last
    // generation that ran to completion (docs/decisions/2026-11-14-c3-rollout-from-rule.md).
    // Method: walk one first generation through each step; then two later applies.
    const policy: Policy = .{};
    assert(policy.on_failure == .rollback);
    const state = begin(&policy, .apply, false, t0);
    const stopped_by_user = try pause_rollout(&state, t0 + 1_000);
    try testing.expectEqual(@as(?PauseCause, .user), stopped_by_user.paused_by);
    const resume_at = t0 + 6_000;
    const running = try resume_rollout(&policy, &stopped_by_user, resume_at);
    try testing.expect(!running.earlier);
    const held: Facts = .{
        .desired = 3,
        .mix = .{ .new_live = 3 },
        .now_ms = resume_at + 1,
        .new_held_at_ms = resume_at + 1,
    };
    const failed = pass(&policy, &running, &held);
    try testing.expectEqual(Phase.failed, failed.state.phase);
    try testing.expectEqual(@as(?Failure, .held), failed.failure);
    try testing.expect(!failed.rollback);
    // Paused once failed, then resumed: a fresh deadline.
    const stopped = try pause_rollout(&failed.state, resume_at + 2_000);
    try testing.expectEqual(@as(?PauseCause, .failure), stopped.paused_by);
    const again_at = resume_at + 5_000;
    const again = try resume_rollout(&policy, &stopped, again_at);
    try testing.expectEqual(again_at + policy.progress_deadline_ms, again.deadline_at_ms);
    // A replica still held fails the resumed rollout again at once (slice 7, decision item 4).
    var still_held = held;
    still_held.now_ms = again_at + 1;
    const failed_again = pass(&policy, &again, &still_held);
    try testing.expectEqual(@as(?Failure, .held), failed_again.failure);
    try testing.expect(!failed_again.rollback);
    // With none held, the fresh deadline is what ends it.
    var late = held;
    late.new_held_at_ms = null;
    late.now_ms = again.deadline_at_ms;
    const timed_out = pass(&policy, &again, &late);
    try testing.expectEqual(Phase.failed, timed_out.state.phase);
    try testing.expectEqual(@as(?Failure, .deadline), timed_out.failure);
    try testing.expect(!timed_out.rollback);
    late.now_ms += 10 * policy.progress_deadline_ms;
    const ended = pass(&policy, &timed_out.state, &late);
    try testing.expect(!ended.rollback);
    try testing.expectEqualDeep(timed_out.state, ended.state);
    // An apply over it: no generation ran to completion, so `from` is 0 and its failure ends it.
    const t1 = late.now_ms + 1;
    const next = begin(&policy, .apply, false, t1);
    var next_held = held;
    next_held.now_ms = t1;
    next_held.new_held_at_ms = t1;
    const next_failed = pass(&policy, &next, &next_held);
    try testing.expectEqual(Phase.failed, next_failed.state.phase);
    try testing.expect(!next_failed.rollback);
    // Had an earlier generation run to completion, `from` would name it and a rollback is owed.
    const over_done = begin(&policy, .apply, true, t1);
    try testing.expect(pass(&policy, &over_done, &next_held).rollback);
}
