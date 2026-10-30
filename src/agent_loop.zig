//! The node agent's loop policy as a state machine: step, wait, back off, report a failure once,
//! stop. Core code, so the cluster simulation runs the policy production runs. It never reads a
//! clock, sleeps or prints: the caller passes the time in and does what each answer says, and
//! the process (`agent_run.zig`) or the simulator (`sim_cluster.zig`) supplies the real or virtual
//! step, watch and pause.
//!
//! **The cycle.** `next` says what to do: run a step, pause (after a failed step), watch (the
//! wait after a step that found nothing to do), or stop. The caller reports what happened with
//! `step_done` or `watch_done`.
//!
//! **The wait.** After a step the agent waits until the core's `Wakeup.at_ms`, or a replica
//! changes (a long poll of the server, `agent_watch_slice_ms` at a time), or a container of this
//! node changes state (the runtime's events). A step that acted runs again at once, and the
//! second finds nothing to do: that is how the level-triggered core converges.
//!
//! **Failure shows once.** A failed step is a report when its diagnostic code changes, and again
//! every `server_report_ms`; the agent backs off from `server_retry_ms_min`, doubling to
//! `server_retry_ms_max`, and a step that works resets it and says so once.

const std = @import("std");
const assert = std.debug.assert;
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const store = @import("store.zig");

pub const Action = union(enum) {
    /// Run `Agent.reconcile` once and report with `step_done`.
    step,
    /// Do nothing for this long (a failed step's back-off), then ask again.
    pause_ms: u32,
    /// Wait up to this long for a change in the server's replicas or in the runtime's events, and
    /// report with `watch_done`.
    watch_ms: u32,
    stop,
};

pub const Outcome = union(enum) {
    ok: controller.Wakeup,
    /// The step failed; the code is the diagnostic's, null if it left none.
    failed: ?codes.Code,
};

/// What the person running the agent should be told.
pub const Report = enum {
    none,
    /// The step failed in a way not reported just now.
    failure,
    /// The first step that worked after a failure.
    recovered,
};

/// What a change of lease is, for `lease_news`.
pub const LeaseNews = enum { none, registered, replaced };

pub const Loop = struct {
    state: State,
    retry_ms: u32,
    /// The deadline of the wait in progress (the core's `Wakeup.at_ms`).
    wake_at_ms: u64,
    last_code: ?codes.Code,
    last_report_ms: u64,
    stop_requested: bool,

    const State = enum { stepping, pausing, waiting };

    pub fn init() Loop {
        return .{
            .state = .stepping,
            .retry_ms = constants.server_retry_ms_min,
            .wake_at_ms = 0,
            .last_code = null,
            .last_report_ms = 0,
            .stop_requested = false,
        };
    }

    /// A signal arrived. The loop ends at its next question; containers are left running.
    pub fn request_stop(loop: *Loop) void {
        loop.stop_requested = true;
    }

    pub fn next(loop: *Loop, now_ms: u64) Action {
        assert(loop.retry_ms >= constants.server_retry_ms_min);
        assert(loop.retry_ms <= constants.server_retry_ms_max);
        if (loop.stop_requested) return .stop;
        switch (loop.state) {
            .stepping => return .step,
            .pausing => {
                loop.state = .stepping;
                return .{ .pause_ms = loop.retry_ms_before_doubling() };
            },
            .waiting => {
                if (now_ms >= loop.wake_at_ms) {
                    loop.state = .stepping;
                    return .step;
                }
                const left = loop.wake_at_ms - now_ms;
                return .{ .watch_ms = @intCast(@min(left, constants.agent_watch_slice_ms)) };
            },
        }
    }

    /// The pause that was asked for; the next failure waits twice as long, up to the maximum.
    fn retry_ms_before_doubling(loop: *Loop) u32 {
        const pause = loop.retry_ms;
        loop.retry_ms = @min(loop.retry_ms * 2, constants.server_retry_ms_max);
        return pause;
    }

    pub fn step_done(loop: *Loop, now_ms: u64, outcome: Outcome) Report {
        assert(loop.state == .stepping);
        switch (outcome) {
            .failed => |code| {
                loop.state = .pausing;
                return loop.failure_report(now_ms, code);
            },
            .ok => |wake| {
                loop.retry_ms = constants.server_retry_ms_min;
                loop.wake_at_ms = wake.at_ms;
                loop.state = if (wake.acted > 0) .stepping else .waiting;
                if (loop.last_code == null) return .none;
                loop.last_code = null;
                return .recovered;
            },
        }
    }

    fn failure_report(loop: *Loop, now_ms: u64, code: ?codes.Code) Report {
        const failed = code orelse return .none;
        if (loop.last_code == failed) {
            if (now_ms -| loop.last_report_ms < constants.server_report_ms) return .none;
        }
        loop.last_code = failed;
        loop.last_report_ms = now_ms;
        return .failure;
    }

    /// A slice of the wait ended. `ended` is true if a replica changed, a container event came, or
    /// the watch itself failed (the next step reports and retries); false if the slice just ran
    /// out.
    pub fn watch_done(loop: *Loop, ended: bool) void {
        assert(loop.state == .waiting);
        if (ended) loop.state = .stepping;
    }
};

/// A lease that was replaced is news (`ZC-W0501`), and a first one is a line of news.
pub fn lease_news(before: store.LeaseId, now: store.LeaseId) LeaseNews {
    if (now == before) return .none;
    assert(now != store.lease_none);
    if (before == store.lease_none) return .registered;
    return .replaced;
}

const testing = std.testing;

test "a failed step backs off by doubling to the maximum, and a good step resets it" {
    // Goal: the back-off of agent_run.zig. Method: fail until the cap, check each pause, succeed,
    // fail again and see the first pause.
    var loop = Loop.init();
    var now: u64 = 0;
    var want: u32 = constants.server_retry_ms_min;
    for (0..10) |_| {
        try testing.expectEqual(Action.step, loop.next(now));
        _ = loop.step_done(now, .{ .failed = .E0503 });
        try testing.expectEqual(Action{ .pause_ms = want }, loop.next(now));
        now += want;
        want = @min(want * 2, constants.server_retry_ms_max);
    }
    try testing.expectEqual(constants.server_retry_ms_max, loop.retry_ms);
    try testing.expectEqual(Action.step, loop.next(now));
    const wake: controller.Wakeup = .{ .at_ms = now + 1000, .prefixes = &.{}, .acted = 0 };
    try testing.expectEqual(Report.recovered, loop.step_done(now, .{ .ok = wake }));
    try testing.expectEqual(constants.server_retry_ms_min, loop.retry_ms);
}

test "a failure is reported once, again after the interval, and again when the code changes" {
    // Goal: "failure shows once". Method: repeat one code inside and past the interval, then
    // change it, then fail with no diagnostic.
    var loop = Loop.init();
    try testing.expectEqual(Action.step, loop.next(0));
    try testing.expectEqual(Report.failure, loop.step_done(0, .{ .failed = .E0503 }));
    _ = loop.next(0);
    _ = loop.next(0);
    try testing.expectEqual(Report.none, loop.step_done(1_000, .{ .failed = .E0503 }));
    const late = constants.server_report_ms;
    _ = loop.next(1_000);
    try testing.expectEqual(Report.failure, loop.step_done(late, .{ .failed = .E0503 }));
    _ = loop.next(late);
    try testing.expectEqual(Report.failure, loop.step_done(late + 1, .{ .failed = .E0504 }));
    _ = loop.next(late);
    try testing.expectEqual(Report.none, loop.step_done(late + 2, .{ .failed = null }));
    _ = loop.next(late);
    const wake: controller.Wakeup = .{ .at_ms = late + 50, .prefixes = &.{}, .acted = 1 };
    try testing.expectEqual(Report.recovered, loop.step_done(late + 3, .{ .ok = wake }));
    _ = loop.next(late);
    try testing.expectEqual(Report.none, loop.step_done(late + 4, .{ .ok = wake }));
}

test "a step that acted runs again at once, and one that did not waits in slices to its deadline" {
    // Goal: the wait. Method: acted -> step; idle -> watch slices of at most the slice maximum,
    // a change ends the wait early, the deadline ends it too.
    var loop = Loop.init();
    _ = loop.next(0);
    const busy: controller.Wakeup = .{ .at_ms = 5_000, .prefixes = &.{}, .acted = 2 };
    _ = loop.step_done(0, .{ .ok = busy });
    try testing.expectEqual(Action.step, loop.next(0));
    const idle: controller.Wakeup = .{ .at_ms = 1_000, .prefixes = &.{}, .acted = 0 };
    _ = loop.step_done(0, .{ .ok = idle });
    const slice = constants.agent_watch_slice_ms;
    try testing.expectEqual(Action{ .watch_ms = slice }, loop.next(0));
    loop.watch_done(false);
    try testing.expectEqual(Action{ .watch_ms = 100 }, loop.next(900));
    loop.watch_done(true);
    try testing.expectEqual(Action.step, loop.next(950));
    _ = loop.step_done(950, .{ .ok = idle });
    try testing.expectEqual(Action.step, loop.next(1_000));
}

test "a stop request ends the loop from every state, and a lease is news only when it changes" {
    // Goal: stop and the lease notices. Method: stop while stepping, pausing and waiting.
    var loop = Loop.init();
    loop.request_stop();
    try testing.expectEqual(Action.stop, loop.next(0));
    var other = Loop.init();
    _ = other.next(0);
    _ = other.step_done(0, .{ .failed = .E0503 });
    other.request_stop();
    try testing.expectEqual(Action.stop, other.next(0));
    try testing.expectEqual(LeaseNews.none, lease_news(5, 5));
    try testing.expectEqual(LeaseNews.registered, lease_news(store.lease_none, 5));
    try testing.expectEqual(LeaseNews.replaced, lease_news(5, 6));
}
