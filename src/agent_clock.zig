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

/// CLOCK_BOOTTIME in milliseconds: monotonic, and it counts the time the host is suspended, which
/// the server's lease clock does too. The agent's fence deadline (`fencing.zig`) is on it. Its
/// origin is the host's boot, so a send time kept in a file is meaningless after a reboot, and
/// the agent treats a time in the future as that.
pub const BootClock = struct {
    io: std.Io,

    pub fn clock(boot: *BootClock) Clock {
        return .{ .context = boot, .now_ms_fn = now_ms_impl };
    }

    fn now_ms_impl(context: *anyopaque) u64 {
        const boot: *BootClock = @ptrCast(@alignCast(context));
        const ms = std.Io.Clock.boot.now(boot.io).toMilliseconds();
        assert(ms >= 0);
        return @intCast(ms);
    }
};
