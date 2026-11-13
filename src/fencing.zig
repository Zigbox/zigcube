//! The arithmetic of self-fencing (docs/authority.md §3, docs/briefs/c1.md "Settled here"). Pure
//! functions on milliseconds, so the agent, the server's config check and the tests agree.
//!
//! An agent whose last acknowledged keepalive was sent at `s` (its own CLOCK_BOOTTIME) stops its
//! containers at `s + ttl - fence_margin` and kills what is left `fence_stop_ms` later. The
//! server declares the node lost once the lease has run out and places replacements
//! `lost_grace_ms` after that. The margin must cover the stop, the clock-rate difference between
//! the two hosts over one ttl, the kernel's delivery of SIGKILL, how late an agent's step may be
//! (`agent_step_lag_max_ms`, which the agent enforces by fencing at once past it) and how far
//! the store's clock may step forward (`store_clock_step_max_ms`, an assumption about the host).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const c1_teeth = @import("c1_teeth.zig");
const Diag = @import("diag.zig").Diag;

/// The difference of two hosts' clocks over `ttl_ms`, rounded up.
pub fn skew_ms(ttl_ms: u32) u32 {
    const product = @as(u64, ttl_ms) * constants.clock_skew_per_mille;
    return @intCast((product + 999) / 1000);
}

/// What the margin must at least be for a lease of `ttl_ms` (authority.md §3, the inequality).
pub fn margin_needed_ms(ttl_ms: u32) u32 {
    return constants.fence_stop_ms + skew_ms(ttl_ms) + constants.fence_kill_latency_ms +
        constants.agent_step_lag_max_ms + constants.store_clock_step_max_ms;
}

pub const Problem = enum {
    /// `fence_margin_ms` is less than the stop, the skew, the kill latency, the step lag and the
    /// clock step need.
    margin_too_small,
    /// The margin leaves too little time before the fence for a renewal
    /// (`ttl < margin + fence_window_min_ms`).
    ttl_too_short,
};

/// Null if a lease of `ttl_ms` can fence an agent in time.
pub fn inequality_problem(ttl_ms: u32) ?Problem {
    // The old-rule negative test lifts the bound to see the old rule fail below it.
    const window_min = if (c1_teeth.old_renewal_rule) 1 else constants.fence_window_min_ms;
    if (ttl_ms < constants.fence_margin_ms + window_min) return .ttl_too_short;
    if (constants.fence_margin_ms < margin_needed_ms(ttl_ms)) return .margin_too_small;
    return null;
}

/// ZC-E0121 for a ttl that `inequality_problem` refused, wherever it came from: the server's
/// configuration, or a grant an agent was handed. The fix points the way the problem does: a
/// ttl below the bound is lengthened, one the margin cannot cover is shortened.
pub fn raise_problem(diag: *Diag, ttl_ms: u32, problem: Problem) void {
    diag.raise(.E0121);
    switch (problem) {
        .ttl_too_short => {
            const bound = constants.fence_margin_ms + constants.fence_window_min_ms;
            diag.cause(
                "a lease ttl of {d} ms leaves under {d} ms past the {d} ms fence margin for a " ++
                    "renewal; the shortest ttl is {d} ms",
                .{ ttl_ms, constants.fence_window_min_ms, constants.fence_margin_ms, bound },
            );
            diag.fix(.{ .sentence = "lengthen the lease ttl to at least the shortest, " ++
                "or use the default of 10000" });
        },
        .margin_too_small => {
            diag.cause(
                "a lease ttl of {d} ms needs a fence margin of {d} ms; it is {d} ms",
                .{ ttl_ms, margin_needed_ms(ttl_ms), constants.fence_margin_ms },
            );
            diag.fix(.{ .sentence = "shorten the lease ttl until the fence margin covers it, " ++
                "such as the default of 10000" });
        },
    }
}

/// How long after a keepalive was sent the next is due: a third of the ttl, but never later than
/// `renew_slack_min_ms` before the fence (`ttl - fence_margin`), so the renewal has that long to
/// be sent, answered and recorded. The slack, `ttl - margin - renew_after_ms`, never shrinks as
/// the ttl grows. Within the admitted range (9,000 ms and up) the minimum never binds, so this is
/// `ttl / 3` with 2,000 ms or more of slack; it is kept so a smaller `fence_window_min_ms` cannot
/// bring back issue #78 (with the 4,000 ms margin the old `ttl / 3` alone leaves 667 ms at
/// 7,000 ms and falls after the fence at 6,000 ms and below).
pub fn renew_after_ms(ttl_ms: u32) u32 {
    assert(ttl_ms > constants.fence_margin_ms);
    if (c1_teeth.old_renewal_rule) return old_rule(ttl_ms);
    const window = ttl_ms - constants.fence_margin_ms;
    assert(window > constants.renew_slack_min_ms);
    return @min(ttl_ms / 3, window - constants.renew_slack_min_ms);
}

/// The renewal interval before the fix of #78; the negative test switches it on, the tests
/// show that it fails.
fn old_rule(ttl_ms: u32) u32 {
    return ttl_ms / 3;
}

/// When the agent starts stopping its containers, on its own clock.
pub fn fence_at_ms(sent_ms: u64, ttl_ms: u32) u64 {
    assert(ttl_ms > constants.fence_margin_ms);
    return sent_ms + (ttl_ms - constants.fence_margin_ms);
}

/// When it kills what has not stopped.
pub fn kill_at_ms(fence_at: u64) u64 {
    return fence_at + constants.fence_stop_ms;
}

/// The latest the server's lease can have ended, as the agent's clock reads when the lease
/// ends, if the agent's clock runs slow by the skew bound: not before this the server may
/// declare the node lost. Used by the tests: every container is dead before it.
pub fn worst_case_dead_ms(sent_ms: u64, ttl_ms: u32) u64 {
    return kill_at_ms(fence_at_ms(sent_ms, ttl_ms)) + constants.agent_step_lag_max_ms +
        constants.fence_kill_latency_ms + skew_ms(ttl_ms);
}

const testing = std.testing;

test "the shipped constants satisfy the inequality, and every ttl in range that can fence does" {
    // Goal: the arithmetic of §3. Method: the constants, then the extremes.
    try testing.expectEqual(@as(?Problem, null), inequality_problem(constants.lease_ttl_ms));
    try testing.expectEqual(@as(u32, 100), skew_ms(10_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(3_001));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(5_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(8_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(8_999));
    try testing.expectEqual(@as(?Problem, null), inequality_problem(9_000));
    // A longer ttl widens the skew term until the fixed margin no longer covers it: the default
    // is also the longest (#238 left no slack above it).
    try testing.expectEqual(@as(?Problem, null), inequality_problem(10_000));
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(10_001));
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(30_000));
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(20_000));
}

test "the margin has the step lag and the clock step in it, and is used up at the default" {
    // Goal: #238 findings 3 and 4, the two terms are in the inequality. Method: the margin less
    // either term would not cover a 10,000 ms ttl's other needs plus that term.
    try testing.expectEqual(@as(u32, 4_000), margin_needed_ms(10_000));
    try testing.expectEqual(constants.fence_margin_ms, margin_needed_ms(constants.lease_ttl_ms));
    const without = constants.fence_stop_ms + skew_ms(10_000) + constants.fence_kill_latency_ms;
    try testing.expectEqual(
        without + constants.agent_step_lag_max_ms + constants.store_clock_step_max_ms,
        margin_needed_ms(10_000),
    );
}

/// When the last container is dead, in real time after `s`, if the agent's clock runs slow by
/// `per_mille`: the agent's own elapsed time, the kill step's lag included, stretches by that
/// much, then SIGKILL takes its latency; the store's clock step is added on the lease's side.
fn real_dead_ms(ttl_ms: u32, per_mille: u32) u64 {
    const agent_ms = kill_at_ms(fence_at_ms(0, ttl_ms));
    const late_ms = agent_ms + constants.agent_step_lag_max_ms;
    return (late_ms * (1000 + per_mille) + 999) / 1000 + constants.fence_kill_latency_ms +
        constants.store_clock_step_max_ms;
}

test "the fence and the kill come at the margin and the stop time, and beat the lease's end" {
    // Goal: the deadline arithmetic, skew included. Method: send at s; the agent's clock may
    // run slow by the bound, so real time elapsed is (agent elapsed) * 1.01; the server's lease
    // runs out at s + ttl in real time at the earliest.
    const ttl = constants.lease_ttl_ms;
    const sent: u64 = 123_000;
    const fence = fence_at_ms(sent, ttl);
    try testing.expectEqual(sent + ttl - constants.fence_margin_ms, fence);
    try testing.expectEqual(fence + constants.fence_stop_ms, kill_at_ms(fence));
    // The worst case the tests use is the kill, the step's lag, the latency and the skew after
    // it; the store's clock may step forward and end the lease early by its bound.
    try testing.expectEqual(
        kill_at_ms(fence) + constants.agent_step_lag_max_ms + constants.fence_kill_latency_ms +
            skew_ms(ttl),
        worst_case_dead_ms(sent, ttl),
    );
    try testing.expect(worst_case_dead_ms(sent, ttl) - sent + constants.store_clock_step_max_ms <=
        ttl);
    // With the clock a full bound slow the last container still dies by the lease's end.
    try testing.expect(real_dead_ms(ttl, constants.clock_skew_per_mille) <= ttl);
    try testing.expect(real_dead_ms(ttl, 0) <= ttl);
}

test "a clock that runs slower than the bound kills after the lease has ended" {
    // Goal: the check has teeth: a skew well past the bound breaks the guarantee. Method: twice
    // the bound. (The skew term is charged over the whole ttl while the kill comes earlier, so
    // the bound plus one per mille still fits; that is slack, not a hole.)
    const ttl = constants.lease_ttl_ms;
    try testing.expect(real_dead_ms(ttl, 2 * constants.clock_skew_per_mille) > ttl);
    // A ttl whose skew outgrows the margin is refused, so that cannot be configured.
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(2 * ttl));
}

test "renewal leaves at least the slack before the fence, and the slack never shrinks" {
    // Goal: #78 and its review. Method: every ttl from the shortest admitted to twice the
    // shipped one (the admitted ones among them), the slack compared with the last ttl's.
    var ttl: u32 = constants.fence_margin_ms + constants.fence_window_min_ms;
    try testing.expectEqual(@as(u32, 9_000), ttl);
    var last_slack: u64 = 0;
    while (ttl <= constants.lease_ttl_ms * 2) : (ttl += 1) {
        const renew = renew_after_ms(ttl);
        const slack = fence_at_ms(0, ttl) - renew;
        try testing.expect(renew <= ttl / 3);
        try testing.expect(slack >= constants.renew_slack_min_ms);
        try testing.expect(slack >= last_slack);
        last_slack = slack;
    }
    try testing.expectEqual(constants.lease_ttl_ms / 3, renew_after_ms(constants.lease_ttl_ms));
    try testing.expectEqual(@as(u32, 3_000), renew_after_ms(9_000));
    try testing.expect(fence_at_ms(0, 9_000) - renew_after_ms(9_000) >= 2_000);
}

test "the old ttl / 3 rule fails where the new one holds" {
    // Goal: the loop above has teeth. Method: with the 4,000 ms margin old_rule leaves under the
    // slack at 7,000 ms and falls after the fence up to 6,000 (it falls at 6,000: 2000 is not
    // before 2000); ttls below 9,000 are refused now, so the old rule is not reachable there.
    try testing.expect(fence_at_ms(0, 7_000) - old_rule(7_000) < constants.renew_slack_min_ms);
    try testing.expect(old_rule(6_000) >= fence_at_ms(0, 6_000));
    try testing.expect(old_rule(6_001) < fence_at_ms(0, 6_001));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(8_999));
}
