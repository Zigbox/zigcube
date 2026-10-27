//! The agent's clock: Unix milliseconds, the real one. Shell code. (`server_store.RealClock` is the
//! same thing, but lives in a file that links the store backends, which the agent does not.)

const std = @import("std");
const assert = std.debug.assert;
const Clock = @import("clock.zig").Clock;

pub const RealClock = struct {
    io: std.Io,

    pub fn clock(real: *RealClock) Clock {
        return .{ .context = real, .now_ms_fn = now_ms_impl };
    }

    fn now_ms_impl(context: *anyopaque) u64 {
        const real: *RealClock = @ptrCast(@alignCast(context));
        const ms = std.Io.Clock.real.now(real.io).toMilliseconds();
        assert(ms > 0); // The machine's clock is after 1970.
        return @intCast(ms);
    }
};
