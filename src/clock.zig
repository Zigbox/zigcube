//! The clock seam (docs/STYLE.md, "Simulation"). Code that needs the time takes a `Clock`, so
//! tests and the simulator advance it by hand and never sleep.

const std = @import("std");
const assert = std.debug.assert;

pub const Clock = struct {
    context: *anyopaque,
    now_ms_fn: *const fn (context: *anyopaque) u64,

    /// Milliseconds on a monotonic scale whose zero means nothing; only differences matter.
    pub fn now_ms(clock: Clock) u64 {
        return clock.now_ms_fn(clock.context);
    }
};

/// A clock that moves only when told to.
pub const ManualClock = struct {
    ms: u64 = 0,

    pub fn clock(manual: *ManualClock) Clock {
        return .{ .context = manual, .now_ms_fn = now_ms_impl };
    }

    pub fn advance(manual: *ManualClock, delta_ms: u64) void {
        assert(manual.ms <= std.math.maxInt(u64) - delta_ms);
        manual.ms += delta_ms;
    }

    fn now_ms_impl(context: *anyopaque) u64 {
        const manual: *ManualClock = @ptrCast(@alignCast(context));
        return manual.ms;
    }
};

test "a manual clock moves only when advanced" {
    // Goal: the seam works end to end. Method: read, advance, read again through `Clock`.
    var manual: ManualClock = .{};
    const clock = manual.clock();
    try std.testing.expectEqual(@as(u64, 0), clock.now_ms());
    manual.advance(250);
    try std.testing.expectEqual(@as(u64, 250), clock.now_ms());
}
