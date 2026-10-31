//! A node's own clock in the cluster simulation. Core code: it reads a source `Clock` (the
//! simulation's true time) and answers on a scale of its own, as a real node's monotonic clock
//! differs from the server's.
//!
//! * **An offset.** The zero of a node's scale means nothing, and no two nodes agree on it.
//! * **A rate error**, bounded by `rate_ppm_max` parts per million and changeable while it runs
//!   (a drifting oscillator). The default bound is the 1 % `skew` of docs/briefs/c1.md; slice 5's
//!   negative tests build a clock with a larger bound on purpose, which is why the bound is a
//!   parameter and the rate is asserted against it, not against a constant.
//! * **Never backwards.** The reading only grows: a rate is never negative, and a jump is forward.
//! * **A jump forward.** `CLOCK_BOOTTIME` keeps counting while a machine is suspended, so a node
//!   that comes back reads a later time than the agent's last step saw. `jump_forward` is that
//!   (and a clock step); how long the agent did not run is the simulation's business.

const std = @import("std");
const assert = std.debug.assert;
const Clock = @import("clock.zig").Clock;

/// The `skew` of docs/briefs/c1.md, 1 %, in parts per million.
pub const rate_ppm_max_default: u32 = 10_000;
const million: u64 = 1_000_000;

pub const NodeClock = struct {
    source: Clock,
    rate_ppm_max: u32,
    /// The error now: the clock gains `rate_ppm` ms per million (loses, if negative).
    rate_ppm: i32,
    /// A point on both scales; the reading is this plus the true time since, at the current rate.
    anchor_true_ms: u64,
    anchor_reading_ms: u64,
    last_reading_ms: u64,

    pub fn init(source: Clock, offset_ms: u64, rate_ppm: i32, rate_ppm_max: u32) NodeClock {
        assert(rate_ppm_max < million);
        assert(@abs(rate_ppm) <= rate_ppm_max);
        const true_ms = source.now_ms();
        return .{
            .source = source,
            .rate_ppm_max = rate_ppm_max,
            .rate_ppm = rate_ppm,
            .anchor_true_ms = true_ms,
            .anchor_reading_ms = offset_ms,
            .last_reading_ms = offset_ms,
        };
    }

    pub fn clock(node: *NodeClock) Clock {
        return .{ .context = node, .now_ms_fn = now_ms_impl };
    }

    fn now_ms_impl(context: *anyopaque) u64 {
        const node: *NodeClock = @ptrCast(@alignCast(context));
        return node.read();
    }

    fn read(node: *NodeClock) u64 {
        const true_ms = node.source.now_ms();
        assert(true_ms >= node.anchor_true_ms); // The source is monotonic.
        const elapsed = true_ms - node.anchor_true_ms;
        const scale: u64 = @intCast(@as(i64, @intCast(million)) + node.rate_ppm);
        const reading = node.anchor_reading_ms + @divFloor(elapsed * scale, million);
        assert(reading >= node.last_reading_ms);
        node.last_reading_ms = reading;
        return reading;
    }

    /// Changes the rate error from now on; the reading stays continuous.
    pub fn set_rate(node: *NodeClock, rate_ppm: i32) void {
        assert(@abs(rate_ppm) <= node.rate_ppm_max);
        node.reanchor(0);
        node.rate_ppm = rate_ppm;
    }

    /// The node reads `ms` later than it would have, from now on.
    pub fn jump_forward(node: *NodeClock, ms: u64) void {
        node.reanchor(ms);
    }

    fn reanchor(node: *NodeClock, extra_ms: u64) void {
        const reading = node.read();
        node.anchor_true_ms = node.source.now_ms();
        node.anchor_reading_ms = reading + extra_ms;
        node.last_reading_ms = node.anchor_reading_ms;
    }
};

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;

test "a node's clock has its own zero, and its rate error stays within the bound" {
    // Goal: offset and bounded rate error. Method: a fast (+1 %) and a slow (-1 %) clock over an
    // hour of true time; the difference from true elapsed time is at most the bound.
    var truth: ManualClock = .{};
    truth.advance(5_000);
    var fast = NodeClock.init(truth.clock(), 1_000_000, 10_000, rate_ppm_max_default);
    var slow = NodeClock.init(truth.clock(), 7, -10_000, rate_ppm_max_default);
    try testing.expectEqual(@as(u64, 1_000_000), fast.clock().now_ms());
    try testing.expectEqual(@as(u64, 7), slow.clock().now_ms());
    truth.advance(3_600_000);
    try testing.expectEqual(@as(u64, 1_000_000 + 3_636_000), fast.clock().now_ms());
    try testing.expectEqual(@as(u64, 7 + 3_564_000), slow.clock().now_ms());
}

test "a rate change keeps the reading continuous, and a jump only goes forward" {
    // Goal: never backwards. Method: change the rate from +1 % to -1 % mid-run and read every
    // step; then jump forward and see the jump added once.
    var truth: ManualClock = .{};
    var node = NodeClock.init(truth.clock(), 100, 10_000, rate_ppm_max_default);
    var last = node.clock().now_ms();
    for (0..2_000) |step| {
        truth.advance(37);
        if (step == 1_000) node.set_rate(-10_000);
        const now = node.clock().now_ms();
        try testing.expect(now >= last);
        last = now;
    }
    const before = node.clock().now_ms();
    node.jump_forward(60_000);
    try testing.expectEqual(before + 60_000, node.clock().now_ms());
    truth.advance(1_000);
    try testing.expectEqual(before + 60_000 + 990, node.clock().now_ms());
}
