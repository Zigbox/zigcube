//! The arithmetic of self-fencing (docs/authority.md §3, docs/briefs/c1.md "Settled here"). Pure
//! functions on milliseconds, so the agent, the server's config check and the tests agree.
//!
//! An agent whose last acknowledged keepalive was sent at `s` (its own CLOCK_BOOTTIME) stops its
//! containers at `s + ttl - fence_margin` and kills what is left `fence_stop_ms` later. The
//! server declares the node lost once the lease has run out and places replacements
//! `lost_grace_ms` after that. The margin must cover the stop, the clock-rate difference between
//! the two hosts over one ttl, and the kernel's delivery of SIGKILL.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// The difference of two hosts' clocks over `ttl_ms`, rounded up.
pub fn skew_ms(ttl_ms: u32) u32 {
    const product = @as(u64, ttl_ms) * constants.clock_skew_per_mille;
    return @intCast((product + 999) / 1000);
}

/// What the margin must at least be for a lease of `ttl_ms`.
pub fn margin_needed_ms(ttl_ms: u32) u32 {
    return constants.fence_stop_ms + skew_ms(ttl_ms) + constants.fence_kill_latency_ms;
}

pub const Problem = enum {
    /// `fence_margin_ms` is less than the stop, the skew and the kill latency need.
    margin_too_small,
    /// The margin leaves too little time before the fence for a renewal
    /// (`ttl < margin + fence_window_min_ms`).
    ttl_too_short,
};

/// Null if a lease of `ttl_ms` can fence an agent in time.
pub fn inequality_problem(ttl_ms: u32) ?Problem {
    if (ttl_ms < constants.fence_margin_ms + constants.fence_window_min_ms) return .ttl_too_short;
    if (constants.fence_margin_ms < margin_needed_ms(ttl_ms)) return .margin_too_small;
    return null;
}

/// How long after a keepalive was sent the next is due. A third of the ttl, but at most half
/// the time before the fence (`ttl - fence_margin`): the old `ttl / 3` alone fell after the fence
/// for any ttl up to 4,500 ms (issue #78), so a healthy agent fenced before every renewal.
/// Unchanged for ttls above 6,000 ms, including the shipped one.
pub fn renew_after_ms(ttl_ms: u32) u32 {
    assert(ttl_ms > constants.fence_margin_ms);
    return @min(ttl_ms / 3, (ttl_ms - constants.fence_margin_ms) / 2);
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
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(3_000));
    try testing.expectEqual(@as(?Problem, .ttl_too_short), inequality_problem(3_499));
    try testing.expectEqual(@as(?Problem, null), inequality_problem(3_500));
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

test "renewal always falls before the fence, at every ttl the inequality admits" {
    // Goal: #78. Method: every ttl from just above the margin to the shipped one and beyond.
    var ttl: u32 = constants.fence_margin_ms + constants.fence_window_min_ms;
    while (ttl <= constants.lease_ttl_ms * 2) : (ttl += 1) {
        if (inequality_problem(ttl) != null) continue;
        const renew = renew_after_ms(ttl);
        try testing.expect(renew <= ttl / 3);
        try testing.expect(renew <= (fence_at_ms(0, ttl)) / 2);
    }
    try testing.expectEqual(constants.lease_ttl_ms / 3, renew_after_ms(constants.lease_ttl_ms));
    try testing.expectEqual(@as(u32, 500), renew_after_ms(4_000));
    // The old interval missed the fence at 4,500 and below, and not above 4,501.
    try testing.expect(4_500 / 3 >= 4_500 - constants.fence_margin_ms);
    try testing.expect(renew_after_ms(4_500) < fence_at_ms(0, 4_500));
}
