//! The back-off between fetches on one node after a fetch failed (ZC-E0601). The controller
//! replaces a replica whose fetch failed at once (a fetch fault is not the user's), so with the
//! registry and every peer unreachable a node would churn through replicas as fast as the
//! fetches are refused. The supervisor of each new replica therefore waits before it starts its
//! fetch: `backoff_ms(failures)`, counted from the last failure, doubling from
//! `fetch_backoff_base_ms` to `fetch_backoff_cap_ms`, and gone after one fetch that succeeds.
//!
//! The streak is a process fact kept in `<state-dir>/fetch-streak.json`: for each digest (at most
//! `fetch_streak_digests_max`) how often fetches of it failed in a row on this node and when, on
//! `CLOCK_BOOTTIME`, so a tree that cannot be had delays only fetches of that tree; intent never
//! lives on a node. It is best effort: an unreadable file is no streak, and a time after the
//! present (a reboot reset the clock) counts as the present, so the wait is never longer than the
//! cap. Shell code.

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

/// A digest's streak as kept in the file.
const Entry = struct { digest: []const u8, failures: u32, at_ms: u64 };

/// The file: one streak per digest, at most `fetch_streak_digests_max` (the oldest is dropped for
/// a new one), so one tree that cannot be had does not delay the fetch of another.
const Table = struct { entries: []const Entry = &.{} };

fn table_read(io: std.Io, dir: Dir, arena: std.mem.Allocator) Table {
    return files.read_json(Table, io, dir, file_streak, arena) catch .{};
}

/// The streak of `digest`: none if the file is unreadable, has no entry for it, or is of the
/// older form (one streak for the node).
pub fn read(io: std.Io, dir: Dir, arena: std.mem.Allocator, digest: []const u8) Streak {
    for (table_read(io, dir, arena).entries) |entry| {
        if (std.mem.eql(u8, entry.digest, digest)) {
            return .{ .failures = entry.failures, .at_ms = entry.at_ms };
        }
    }
    return .{};
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

pub fn record_failure(
    io: std.Io,
    dir: Dir,
    arena: std.mem.Allocator,
    digest: []const u8,
    now_ms: u64,
) void {
    const before = table_read(io, dir, arena);
    var kept: [constants.fetch_streak_digests_max]Entry = undefined;
    var count: usize = 0;
    var failures: u32 = 1;
    for (before.entries) |entry| {
        if (std.mem.eql(u8, entry.digest, digest)) {
            failures = entry.failures +| 1;
        } else if (count < kept.len) {
            kept[count] = entry;
            count += 1;
        }
    }
    if (count == kept.len) { // Full: the oldest streak makes room.
        var oldest: usize = 0;
        for (kept[0..count], 0..) |entry, at| {
            if (entry.at_ms < kept[oldest].at_ms) oldest = at;
        }
        kept[oldest] = kept[count - 1];
        count -= 1;
    }
    kept[count] = .{ .digest = digest, .failures = failures, .at_ms = now_ms };
    count += 1;
    const next: Table = .{ .entries = kept[0..count] };
    files.write_json(io, dir, file_streak, next) catch {}; // Best effort: no streak, no wait.
}

/// A fetch of `digest` succeeded: its streak is gone, the others stay.
pub fn clear(io: std.Io, dir: Dir, arena: std.mem.Allocator, digest: []const u8) void {
    const before = table_read(io, dir, arena);
    var kept: [constants.fetch_streak_digests_max]Entry = undefined;
    var count: usize = 0;
    for (before.entries) |entry| {
        if (std.mem.eql(u8, entry.digest, digest)) continue;
        if (count < kept.len) {
            kept[count] = entry;
            count += 1;
        }
    }
    if (count == before.entries.len) return; // No streak of that digest.
    if (count == 0) {
        dir.deleteFile(io, file_streak) catch {}; // Unremovable: the wait is only best effort.
        return;
    }
    const next: Table = .{ .entries = kept[0..count] };
    files.write_json(io, dir, file_streak, next) catch {}; // Best effort.
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

test "a streak is kept per digest, and one digest's failures do not delay another" {
    // Goal: S2 of the final re-review. Method: fail A twice and B once; A waits 2 s, B 1 s and a
    // digest never tried 0; a success of A clears A and leaves B; the table stays bounded.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "b3:" ++ @as([64]u8, @splat('a'));
    const b = "b3:" ++ @as([64]u8, @splat('b'));
    record_failure(io, tmp.dir, arena, a, 1000);
    record_failure(io, tmp.dir, arena, a, 2000);
    record_failure(io, tmp.dir, arena, b, 3000);
    try std.testing.expectEqual(@as(u32, 2), read(io, tmp.dir, arena, a).failures);
    try std.testing.expectEqual(@as(u32, 1), read(io, tmp.dir, arena, b).failures);
    const other = "b3:" ++ @as([64]u8, @splat('c'));
    const now = 3000;
    const wait_a = wait_remaining_ms(read(io, tmp.dir, arena, a), now, 1000, 300_000);
    try std.testing.expectEqual(@as(u32, 1000), wait_a); // 2 s from 2000.
    const wait_b = wait_remaining_ms(read(io, tmp.dir, arena, b), now, 1000, 300_000);
    try std.testing.expectEqual(@as(u32, 1000), wait_b);
    try std.testing.expectEqual(@as(u32, 0), read(io, tmp.dir, arena, other).failures);
    clear(io, tmp.dir, arena, a);
    try std.testing.expectEqual(@as(u32, 0), read(io, tmp.dir, arena, a).failures);
    try std.testing.expectEqual(@as(u32, 1), read(io, tmp.dir, arena, b).failures);
    clear(io, tmp.dir, arena, b);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, file_streak, .{}));
    // Bounded: more digests than the table holds drop the oldest, never the newest.
    var name: [67]u8 = undefined;
    for (0..constants.fetch_streak_digests_max + 5) |at| {
        _ = std.fmt.bufPrint(&name, "b3:{x:0>64}", .{at}) catch unreachable; // Sized above.
        record_failure(io, tmp.dir, arena, &name, 10_000 + at);
    }
    const table = table_read(io, tmp.dir, arena);
    try std.testing.expectEqual(@as(usize, constants.fetch_streak_digests_max), table.entries.len);
    try std.testing.expectEqual(@as(u32, 1), read(io, tmp.dir, arena, &name).failures);
}

test "a streak file of the older form, one streak for the node, is no streak" {
    // Goal: an agent upgraded with a file on disk starts with no wait rather than a wrong one.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_streak, .data = "{\"failures\":3,\"at_ms\":5}" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const old = read(io, tmp.dir, arena_state.allocator(), "b3:" ++ @as([64]u8, @splat('a')));
    try std.testing.expectEqual(@as(u32, 0), old.failures);
}
