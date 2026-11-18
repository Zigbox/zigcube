//! The arithmetic of self-fencing (docs/authority.md §3, docs/briefs/c1.md "Settled here"). Pure
//! functions on milliseconds, so the agent, the server's config check and the tests agree.
//!
//! An agent whose last acknowledged keepalive was sent at `s` (its own CLOCK_BOOTTIME) stops its
//! containers at `s + ttl - fence_margin` and kills what is left `fence_stop_ms` later. The
//! server declares the node lost once the lease has run out and places replacements
//! `lost_grace_ms` after that. Two conditions (docs/decisions/2026-11-18-fencing-dispatch-and-
//! clock-step.md):
//!
//! - the margin alone covers the stop, the clock-rate difference of the two hosts over one ttl
//!   and the kernel's delivery of SIGKILL (the agent's own check: a grant carries no grace);
//! - the margin and the grace together also cover the agent's late dispatch of SIGKILL (one
//!   fence poll) and a forward step of the store's clock (`clock_step_max_ms`), which ends a
//!   lease early. The server checks this one, against its own grace, at start.

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

/// What the margin must at least be for a lease of `ttl_ms`.
pub fn margin_needed_ms(ttl_ms: u32) u32 {
    return constants.fence_stop_ms + skew_ms(ttl_ms) + constants.fence_kill_latency_ms;
}

/// What the margin and the lost grace must together at least be for a lease of `ttl_ms`.
pub fn cover_needed_ms(ttl_ms: u32) u32 {
    return margin_needed_ms(ttl_ms) + constants.kill_dispatch_ms + constants.clock_step_max_ms;
}

/// The shortest lost grace a lease of `ttl_ms` admits; 600 ms at the default ttl.
pub fn grace_min_ms(ttl_ms: u32) u32 {
    return cover_needed_ms(ttl_ms) -| constants.fence_margin_ms;
}

pub const Problem = enum {
    /// `fence_margin_ms` is less than the stop, the skew and the kill delivery need.
    margin_too_small,
    /// The margin leaves too little time before the fence for a renewal
    /// (`ttl < margin + fence_window_min_ms`).
    ttl_too_short,
    /// The margin and the lost grace together are less than the stop, the skew, the kill's
    /// delivery and dispatch and the store's clock step need.
    grace_too_small,
};

/// Null if a lease of `ttl_ms` can fence an agent in time, whatever the server's grace: what an
/// agent can check of a grant.
pub fn inequality_problem(ttl_ms: u32) ?Problem {
    // The old-rule negative test lifts the bound to see the old rule fail below it.
    const window_min = if (c1_teeth.old_renewal_rule) 1 else constants.fence_window_min_ms;
    if (ttl_ms < constants.fence_margin_ms + window_min) return .ttl_too_short;
    if (constants.fence_margin_ms < margin_needed_ms(ttl_ms)) return .margin_too_small;
    return null;
}

/// Null if a lease of `ttl_ms` with a lost grace of `grace_ms` meets the whole contract: what the
/// server checks of its configuration.
pub fn contract_problem(ttl_ms: u32, grace_ms: u32) ?Problem {
    if (inequality_problem(ttl_ms)) |problem| return problem;
    if (grace_ms < grace_min_ms(ttl_ms)) return .grace_too_small;
    return null;
}

/// ZC-E0121 for a ttl that `inequality_problem` refused, wherever it came from: the server's
/// configuration, or a grant an agent was handed. The fix points the way the problem does: a
/// ttl below the bound is lengthened, one the margin cannot cover is shortened.
pub fn raise_problem(diag: *Diag, ttl_ms: u32, problem: Problem) void {
    assert(problem != .grace_too_small); // An agent knows no grace: `raise_contract_problem`.
    raise_contract_problem(diag, ttl_ms, 0, problem);
}

/// ZC-E0121 for a configuration `contract_problem` refused; `grace_ms` is the server's grace.
pub fn raise_contract_problem(diag: *Diag, ttl_ms: u32, grace_ms: u32, problem: Problem) void {
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
        .grace_too_small => {
            diag.cause(
                "a lease ttl of {d} ms needs a lost grace of at least {d} ms; it is {d} ms (the " ++
                    "{d} ms fence margin and the grace must cover the stop, the clock skew, the " ++
                    "kill's delivery and dispatch and a {d} ms store clock step: {d} ms)",
                .{
                    ttl_ms,                      grace_min_ms(ttl_ms),
                    grace_ms,                    constants.fence_margin_ms,
                    constants.clock_step_max_ms, cover_needed_ms(ttl_ms),
                },
            );
            diag.fix(.{ .sentence = "lengthen the lost grace to at least the shortest, " ++
                "or use the default of 1000" });
        },
    }
}

/// How long after a keepalive was sent the next is due: a third of the ttl, but never later than
/// `renew_slack_min_ms` before the fence (`ttl - fence_margin`), so the renewal has that long to
/// be sent, answered and recorded. The slack, `ttl - margin - renew_after_ms`, never shrinks as
/// the ttl grows. Within the admitted range (8,000 ms and up) the minimum never binds, so this is
/// `ttl / 3` with 2,334 ms or more of slack; it is kept so a smaller `fence_window_min_ms` cannot
/// bring back issue #78 (the old `ttl / 3` alone left 334 ms at 5,000 ms and fell after the
/// fence below 4,500 ms).
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
    return kill_at_ms(fence_at_ms(sent_ms, ttl_ms)) + constants.fence_kill_latency_ms +
        skew_ms(ttl_ms);
}

const testing = std.testing;

test "the shipped constants satisfy the inequality, and every ttl in range that can fence does" {
    // Goal: the arithmetic of §3. Method: the constants, then the extremes.
    try testing.expectEqual(@as(?Problem, null), inequality_problem(constants.lease_ttl_ms));
    try testing.expectEqual(@as(u32, 100), skew_ms(10_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(3_001));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(5_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(7_999));
    try testing.expectEqual(@as(?Problem, null), inequality_problem(8_000));
    // A longer ttl widens the skew term until the fixed margin no longer covers it.
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(30_000));
    try testing.expectEqual(@as(?Problem, .margin_too_small), inequality_problem(20_000));
}

/// When the last container is dead, in real time after `s`, if the agent's clock runs slow by
/// `per_mille`: the agent's own elapsed time stretches by that much, then SIGKILL takes its
/// latency.
fn real_dead_ms(ttl_ms: u32, per_mille: u32) u64 {
    const agent_ms = kill_at_ms(fence_at_ms(0, ttl_ms));
    return (agent_ms * (1000 + per_mille) + 999) / 1000 + constants.fence_kill_latency_ms;
}

test "the margin and the grace cover the dispatch and the clock step, with 400 ms to spare" {
    // Goal: the bound of docs/decisions/2026-11-18-fencing-dispatch-and-clock-step.md. Method:
    // the arithmetic at the default ttl and grace, then the shortest grace at both ends of the
    // admitted ttls, one under it refused, and a ttl the margin alone refuses whatever the grace.
    const ttl = constants.lease_ttl_ms;
    try testing.expectEqual(@as(u32, 3_600), cover_needed_ms(ttl));
    try testing.expectEqual(@as(u32, 400), constants.fence_margin_ms + constants.lost_grace_ms -
        cover_needed_ms(ttl));
    try testing.expectEqual(@as(?Problem, null), contract_problem(ttl, constants.lost_grace_ms));
    try testing.expectEqual(@as(u32, 600), grace_min_ms(ttl));
    try testing.expectEqual(@as(?Problem, null), contract_problem(ttl, 600));
    try testing.expectEqual(@as(?Problem, .grace_too_small), contract_problem(ttl, 599));
    try testing.expectEqual(@as(?Problem, .grace_too_small), contract_problem(ttl, 0));
    try testing.expectEqual(@as(u32, 580), grace_min_ms(8_000));
    try testing.expectEqual(@as(?Problem, .grace_too_small), contract_problem(8_000, 579));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), contract_problem(7_999, 60_000));
    const long = constants.lost_grace_ms_max;
    try testing.expectEqual(@as(?Problem, .margin_too_small), contract_problem(ttl + 1, long));
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
    // The worst case the tests use is the kill, the latency and the skew after it.
    try testing.expectEqual(
        kill_at_ms(fence) + constants.fence_kill_latency_ms + skew_ms(ttl),
        worst_case_dead_ms(sent, ttl),
    );
    try testing.expect(worst_case_dead_ms(sent, ttl) - sent <= ttl);
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
    try testing.expectEqual(@as(u32, 8_000), ttl);
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
    try testing.expectEqual(@as(u32, 2_666), renew_after_ms(8_000));
    try testing.expect(fence_at_ms(0, 8_000) - renew_after_ms(8_000) >= 2_334);
}

test "the old ttl / 3 rule fails where the new one holds" {
    // Goal: the loop above has teeth. Method: old_rule leaves under the slack at 5,000 ms and
    // falls after the fence from 3,500 ms up to 4,500 (it falls at 4,500: 1500 is not before
    // 1500); ttls below 8,000 are refused now, so the old rule is not reachable there.
    try testing.expect(fence_at_ms(0, 5_000) - old_rule(5_000) < constants.renew_slack_min_ms);
    try testing.expect(old_rule(4_500) >= fence_at_ms(0, 4_500));
    try testing.expect(old_rule(4_501) < fence_at_ms(0, 4_501));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(7_999));
}
