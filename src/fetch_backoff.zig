//! The back-off between fetches on one node after a fetch failed (ZC-E0601). The controller
//! replaces a replica whose fetch failed at once (a fetch fault is not the user's), so with the
//! registry and every peer unreachable a node would churn through replicas as fast as the
//! fetches are refused. The supervisor of each new replica therefore waits before it starts its
//! fetch: `backoff_ms(failures)`, counted from the last failure, doubling from
//! `fetch_backoff_base_ms` to `fetch_backoff_cap_ms`, and gone after one fetch that succeeds.
//!
//! The streak is a process fact kept in `<state-dir>/fetch-streak.json` (how often fetches failed
//! in a row on this node and when, on `CLOCK_BOOTTIME`); intent never lives on a node. It is
//! best effort: an unreadable file is no streak, and a time after the present (a reboot reset
//! the clock) counts as the present, so the wait is never longer than the cap. Shell code.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const files = @import("fake_files.zig");

const Dir = std.Io.Dir;

pub const file_streak = "fetch-streak.json";

/// How long a fetch waits after `failures` failures in a row: none after zero, `base_ms` after
/// one, doubling, never above `cap_ms`.
pub fn backoff_ms(failures: u32, base_ms: u32, cap_ms: u32) u32 {
    assert(base_ms > 0);
    assert(base_ms <= cap_ms);
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 31));
    const doubled = @as(u64, base_ms) << shift;
    const wait: u32 = @intCast(@min(doubled, cap_ms));
    assert(wait >= base_ms);
    assert(wait <= cap_ms);
    return wait;
}

pub const Streak = struct {
    failures: u32 = 0,
    /// `CLOCK_BOOTTIME` milliseconds of the last failure.
    at_ms: u64 = 0,
};

pub fn read(io: std.Io, dir: Dir, arena: std.mem.Allocator) Streak {
    return files.read_json(Streak, io, dir, file_streak, arena) catch .{};
}

/// How long to wait now: the back-off for the streak minus the time since its last failure.
pub fn wait_remaining_ms(streak: Streak, now_ms: u64, base_ms: u32, cap_ms: u32) u32 {
    const wait = backoff_ms(streak.failures, base_ms, cap_ms);
    if (wait == 0) return 0;
    // A last failure after now is from before a reboot: wait the full time at most.
    const since = if (now_ms >= streak.at_ms) now_ms - streak.at_ms else 0;
    if (since >= wait) return 0;
    return @intCast(wait - since);
}

pub fn record_failure(io: std.Io, dir: Dir, arena: std.mem.Allocator, now_ms: u64) void {
    const before = read(io, dir, arena);
    const next: Streak = .{ .failures = before.failures +| 1, .at_ms = now_ms };
    files.write_json(io, dir, file_streak, next) catch {}; // Best effort: no streak, no wait.
}

pub fn clear(io: std.Io, dir: Dir) void {
    dir.deleteFile(io, file_streak) catch {}; // Absent or unremovable: either way no wait is kept.
}

test "the back-off doubles from the base and stops at the cap" {
    // Goal: the schedule. Method: the first values, the cap, and a count far past the shift.
    try std.testing.expectEqual(@as(u32, 0), backoff_ms(0, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 1000), backoff_ms(1, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 2000), backoff_ms(2, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 256_000), backoff_ms(9, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 300_000), backoff_ms(10, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 300_000), backoff_ms(4_000_000_000, 1000, 300_000));
}

test "the wait left counts from the last failure and never exceeds the back-off" {
    // Goal: elapsed time is subtracted, and a clock that went back is not trusted.
    const streak: Streak = .{ .failures = 2, .at_ms = 10_000 };
    try std.testing.expectEqual(@as(u32, 2000), wait_remaining_ms(streak, 10_000, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 500), wait_remaining_ms(streak, 11_500, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 0), wait_remaining_ms(streak, 12_000, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 2000), wait_remaining_ms(streak, 5_000, 1000, 300_000));
    try std.testing.expectEqual(@as(u32, 0), wait_remaining_ms(.{}, 0, 1000, 300_000));
}
