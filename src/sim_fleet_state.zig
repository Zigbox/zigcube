//! The simulation fleet's state file: which failures it has filed (so a restart does not file
//! them again), when it last commented on each (so a persistent failure is not commented on every
//! round), how many seeds it ran each UTC day and which failures it saw (so it can say so), and
//! how long GitHub asked it to wait. Plain lines:
//!
//!     version 2
//!     hold <unix seconds until GitHub writes may resume>
//!     filed <fingerprint> <issue number> <commit filed at> <commit last commented at>
//!     day <YYYY-MM-DD> <seeds> <failed seeds> <batches> <last commit> <crashes> <infra>
//!     seen <YYYY-MM-DD> <fingerprint> <issue number> <seeds> <comments that day>
//!     reported <YYYY-MM-DD>
//!
//! Version 1 (the first release) had no `hold` or `seen` lines, three fields after `filed` and
//! five after `day`; it is still read. If the file is lost, the markers on the issues rebuild
//! the `filed` lines (`sim_fleet_github.zig`); the day counts start over.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// The state file's format; a file without a `version` line is version 1.
const version = 2;

pub const ymd_bytes = 10;
pub const Ymd = [ymd_bytes]u8;

pub const Filed = struct {
    fingerprint: []const u8,
    /// 0 in a dry run, or while unknown: nothing was really filed.
    issue: u32,
    commit: []const u8,
    /// The commit of the last comment (or of the filing): never two comments for one commit.
    last_commit: []const u8,
};

pub const Day = struct {
    ymd: Ymd,
    seeds: u64,
    failed: u64,
    batches: u32,
    commit: []const u8,
    crashes: u64 = 0,
    infra: u64 = 0,
};

/// One failure's seeds on one day, for the tracker comment, and the comments it got that day.
pub const Seen = struct {
    ymd: Ymd,
    fingerprint: []const u8,
    issue: u32,
    seeds: u64,
    comments: u32,
};

/// What one round adds to its day.
pub const Counts = struct {
    seeds: u64,
    failed: u64,
    crashes: u64 = 0,
    infra: u64 = 0,
};

pub const State = struct {
    filed: std.ArrayList(Filed) = .empty,
    days: std.ArrayList(Day) = .empty,
    seen: std.ArrayList(Seen) = .empty,
    /// The latest day whose totals were posted, "" if none.
    reported: []const u8 = "",
    /// Unix seconds before which nothing is written to GitHub (it asked to wait); 0 if none.
    hold_until: i64 = 0,

    pub fn find(state: *const State, fingerprint: []const u8) ?*Filed {
        for (state.filed.items) |*item| {
            if (std.mem.eql(u8, item.fingerprint, fingerprint)) return item;
        }
        return null;
    }

    pub fn remember(state: *State, arena: std.mem.Allocator, filed: Filed) error{
        OutOfMemory,
        StateFull,
    }!void {
        assert(state.find(filed.fingerprint) == null);
        assert(filed.fingerprint.len > 0);
        if (state.filed.items.len >= constants.fleet_filed_max) return error.StateFull;
        try state.filed.append(arena, filed);
    }

    /// Drops a filed failure whose issue is gone, so the next sighting files it again.
    pub fn forget(state: *State, fingerprint: []const u8) void {
        for (state.filed.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.fingerprint, fingerprint)) continue;
            _ = state.filed.orderedRemove(index);
            assert(state.find(fingerprint) == null);
            return;
        }
    }

    /// Adds a round to day `ymd`, opening it if need be; past the days kept, the oldest day goes
    /// (and what was seen on it), reported or not.
    pub fn count(
        state: *State,
        arena: std.mem.Allocator,
        ymd: Ymd,
        counts: Counts,
        commit: []const u8,
    ) error{OutOfMemory}!void {
        assert(counts.failed <= counts.seeds);
        assert(counts.crashes + counts.infra <= counts.failed);
        for (state.days.items) |*day| {
            if (!std.mem.eql(u8, &day.ymd, &ymd)) continue;
            day.seeds += counts.seeds;
            day.failed += counts.failed;
            day.crashes += counts.crashes;
            day.infra += counts.infra;
            day.batches += 1;
            day.commit = commit;
            return;
        }
        try state.days.append(arena, .{
            .ymd = ymd,
            .seeds = counts.seeds,
            .failed = counts.failed,
            .crashes = counts.crashes,
            .infra = counts.infra,
            .batches = 1,
            .commit = commit,
        });
        std.mem.sort(Day, state.days.items, {}, older);
        while (state.days.items.len > constants.fleet_days_kept) {
            const dropped = state.days.orderedRemove(0);
            state.drop_seen(&dropped.ymd);
        }
        assert(state.days.items.len <= constants.fleet_days_kept);
    }

    /// The count of `fingerprint` on day `ymd`, opened with `issue` if need be; null once the
    /// day already counts its most distinct failures (they are in the day's total only).
    pub fn see(
        state: *State,
        arena: std.mem.Allocator,
        ymd: Ymd,
        fingerprint: []const u8,
        issue: u32,
    ) error{OutOfMemory}!?*Seen {
        var on_day: u32 = 0;
        for (state.seen.items) |*item| {
            if (!std.mem.eql(u8, &item.ymd, &ymd)) continue;
            if (std.mem.eql(u8, item.fingerprint, fingerprint)) return item;
            on_day += 1;
        }
        if (on_day >= constants.fleet_seen_per_day_max) return null;
        const item = try state.seen.addOne(arena);
        item.* = .{
            .ymd = ymd,
            .fingerprint = fingerprint,
            .issue = issue,
            .seeds = 0,
            .comments = 0,
        };
        return item;
    }

    /// What was seen on day `ymd`, most seeds first.
    pub fn seen_on(
        state: *const State,
        arena: std.mem.Allocator,
        ymd: Ymd,
    ) error{OutOfMemory}![]const Seen {
        var out: std.ArrayList(Seen) = .empty;
        for (state.seen.items) |item| {
            if (std.mem.eql(u8, &item.ymd, &ymd)) try out.append(arena, item);
        }
        std.mem.sort(Seen, out.items, {}, more_seeds);
        return out.items;
    }

    /// Marks day `ymd` posted and drops what was seen on it and before.
    pub fn mark_reported(
        state: *State,
        arena: std.mem.Allocator,
        ymd: Ymd,
    ) error{OutOfMemory}!void {
        assert(std.mem.order(u8, &ymd, state.reported) == .gt);
        state.reported = try arena.dupe(u8, &ymd);
        var index: usize = 0;
        while (index < state.seen.items.len) {
            if (std.mem.order(u8, &state.seen.items[index].ymd, &ymd) != .gt) {
                _ = state.seen.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn drop_seen(state: *State, ymd: *const Ymd) void {
        var index: usize = 0;
        while (index < state.seen.items.len) {
            if (std.mem.eql(u8, &state.seen.items[index].ymd, ymd)) {
                _ = state.seen.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    /// Days before `today` whose totals nobody has posted yet, oldest first (ISO dates sort as
    /// text).
    pub fn unreported(
        state: *const State,
        arena: std.mem.Allocator,
        today: Ymd,
    ) error{OutOfMemory}![]const Day {
        var out: std.ArrayList(Day) = .empty;
        for (state.days.items) |day| {
            if (std.mem.order(u8, &day.ymd, &today) != .lt) continue;
            if (std.mem.order(u8, &day.ymd, state.reported) != .gt) continue;
            try out.append(arena, day);
        }
        std.mem.sort(Day, out.items, {}, older);
        return out.items;
    }

    pub fn render(state: *const State, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("version {d}\n", .{version});
        if (state.hold_until > 0) try out.print("hold {d}\n", .{state.hold_until});
        for (state.filed.items) |item| {
            try out.print("filed {s} {d} {s} {s}\n", .{
                item.fingerprint, item.issue, item.commit, item.last_commit,
            });
        }
        for (state.days.items) |day| {
            try out.print("day {s} {d} {d} {d} {s} {d} {d}\n", .{
                &day.ymd, day.seeds, day.failed, day.batches, day.commit, day.crashes, day.infra,
            });
        }
        for (state.seen.items) |item| {
            try out.print("seen {s} {s} {d} {d} {d}\n", .{
                &item.ymd, item.fingerprint, item.issue, item.seeds, item.comments,
            });
        }
        if (state.reported.len > 0) try out.print("reported {s}\n", .{state.reported});
    }
};

fn older(_: void, a: Day, b: Day) bool {
    return std.mem.order(u8, &a.ymd, &b.ymd) == .lt;
}

fn more_seeds(_: void, a: Seen, b: Seen) bool {
    return a.seeds > b.seeds;
}

pub const ParseError = error{ BadState, OutOfMemory };

const Words = std.mem.TokenIterator(u8, .scalar);

/// Reads a state file. A line it does not understand is an error, not skipped: a state file
/// that quietly loses lines files the same failure twice.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!State {
    var state: State = .{};
    var format: u32 = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = words.next() orelse continue;
        if (std.mem.eql(u8, kind, "version")) {
            const text_version = words.next() orelse return error.BadState;
            // A file from a later release is refused, not half read.
            format = std.fmt.parseInt(u32, text_version, 10) catch return error.BadState;
            if (format < 1) return error.BadState;
            if (format > version) return error.BadState;
        } else if (std.mem.eql(u8, kind, "filed")) {
            if (state.filed.items.len >= constants.fleet_filed_max) return error.BadState;
            try state.filed.append(arena, try parse_filed(&words, format));
        } else if (std.mem.eql(u8, kind, "day")) {
            try state.days.append(arena, try parse_day(&words, format));
        } else if (std.mem.eql(u8, kind, "seen") and format >= 2) {
            try state.seen.append(arena, try parse_seen(&words));
        } else if (std.mem.eql(u8, kind, "hold") and format >= 2) {
            const until = words.next() orelse return error.BadState;
            state.hold_until = std.fmt.parseInt(i64, until, 10) catch return error.BadState;
            if (state.hold_until < 0) return error.BadState;
        } else if (std.mem.eql(u8, kind, "reported")) {
            state.reported = words.next() orelse return error.BadState;
        } else {
            return error.BadState;
        }
        // Version 2 lines have exactly their fields; version 1 never wrote more.
        if (words.next() != null) return error.BadState;
    }
    return state;
}

fn parse_filed(words: *Words, format: u32) ParseError!Filed {
    const fingerprint = words.next() orelse return error.BadState;
    const issue_text = words.next() orelse return error.BadState;
    const commit = words.next() orelse return error.BadState;
    const last_commit = if (format >= 2) words.next() orelse return error.BadState else commit;
    return .{
        .fingerprint = fingerprint,
        .issue = std.fmt.parseInt(u32, issue_text, 10) catch return error.BadState,
        .commit = commit,
        .last_commit = last_commit,
    };
}

fn parse_ymd(words: *Words) ParseError!Ymd {
    const ymd_text = words.next() orelse return error.BadState;
    if (ymd_text.len != ymd_bytes) return error.BadState;
    return ymd_text[0..ymd_bytes].*;
}

fn parse_number(comptime T: type, words: *Words) ParseError!T {
    const text = words.next() orelse return error.BadState;
    return std.fmt.parseInt(T, text, 10) catch return error.BadState;
}

fn parse_day(words: *Words, format: u32) ParseError!Day {
    var day: Day = .{
        .ymd = try parse_ymd(words),
        .seeds = try parse_number(u64, words),
        .failed = try parse_number(u64, words),
        .batches = try parse_number(u32, words),
        .commit = words.next() orelse return error.BadState,
    };
    if (format >= 2) {
        day.crashes = try parse_number(u64, words);
        day.infra = try parse_number(u64, words);
    }
    if (day.failed > day.seeds) return error.BadState;
    if (day.crashes + day.infra > day.failed) return error.BadState;
    return day;
}

fn parse_seen(words: *Words) ParseError!Seen {
    return .{
        .ymd = try parse_ymd(words),
        .fingerprint = words.next() orelse return error.BadState,
        .issue = try parse_number(u32, words),
        .seeds = try parse_number(u64, words),
        .comments = try parse_number(u32, words),
    };
}

/// The UTC date of a Unix time, "YYYY-MM-DD".
pub fn ymd_of(unix_seconds: i64) Ymd {
    assert(unix_seconds >= 0);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var out: Ymd = undefined;
    const printed = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
    }) catch unreachable; // Four, two and two digits always fit in ten bytes.
    assert(printed.len == ymd_bytes);
    return out;
}

test "ymd_of gives the UTC date" {
    try std.testing.expectEqualStrings("1970-01-01", &ymd_of(0));
    try std.testing.expectEqualStrings("2026-11-02", &ymd_of(1_793_581_200));
    try std.testing.expectEqualStrings("2024-02-29", &ymd_of(1_709_251_199));
}

test "state round trips through its text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: State = .{ .hold_until = 1_793_590_000 };
    try state.remember(arena, .{
        .fingerprint = "0123456789abcdef",
        .issue = 12,
        .commit = "c1",
        .last_commit = "c2",
    });
    const today = ymd_of(1_793_581_200);
    try state.count(arena, today, .{ .seeds = 40, .failed = 3, .crashes = 1 }, "c1");
    try state.count(arena, today, .{ .seeds = 10, .failed = 1, .infra = 1 }, "c2");
    const seen = (try state.see(arena, today, "0123456789abcdef", 12)).?;
    seen.seeds += 3;
    seen.comments += 1;
    state.reported = "2026-10-31";
    var out: std.Io.Writer.Allocating = .init(arena);
    try state.render(&out.writer);
    const again = try parse(arena, out.written());
    try std.testing.expectEqual(@as(usize, 1), again.filed.items.len);
    try std.testing.expectEqual(@as(u32, 12), again.find("0123456789abcdef").?.issue);
    try std.testing.expectEqualStrings("c2", again.find("0123456789abcdef").?.last_commit);
    try std.testing.expectEqual(@as(u64, 50), again.days.items[0].seeds);
    try std.testing.expectEqual(@as(u32, 2), again.days.items[0].batches);
    try std.testing.expectEqual(@as(u64, 1), again.days.items[0].crashes);
    try std.testing.expectEqual(@as(u64, 1), again.days.items[0].infra);
    try std.testing.expectEqualStrings("c2", again.days.items[0].commit);
    try std.testing.expectEqual(@as(u64, 3), again.seen.items[0].seeds);
    try std.testing.expectEqual(@as(u32, 1), again.seen.items[0].comments);
    try std.testing.expectEqualStrings("2026-10-31", again.reported);
    try std.testing.expectEqual(@as(i64, 1_793_590_000), again.hold_until);
    try std.testing.expect(again.find("nope") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "version 2\n"));
    try std.testing.expectError(error.BadState, parse(arena, "version 3\n"));
    try std.testing.expectError(error.BadState, parse(arena, "surprise 1\n"));
    try std.testing.expectError(error.BadState, parse(arena, "day 2026-11-02 1 2 1 c\n"));
    try std.testing.expectError(error.BadState, parse(arena, "version 2\nfiled f 1 c\n"));
    try std.testing.expectError(error.BadState, parse(arena, "version 2\nfiled f 1 c d e\n"));
    // `seen` and `hold` are version 2 lines.
    try std.testing.expectError(error.BadState, parse(arena, "version 1\nhold 5\n"));
}

test "a version 1 state file, as the first release wrote it, is read" {
    // Goal: a stored value is read by the next release. Method: the text below is what the
    // first release (commit f502dbe) wrote after one dry-run ingest; it is read and written
    // back as version 2 with nothing lost.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const written_by_v1 =
        \\version 1
        \\filed 83f4a12f59e06092 0 abc
        \\day 2026-11-02 2 1 1 abc
        \\
    ;
    const state = try parse(arena, written_by_v1);
    const filed = state.find("83f4a12f59e06092").?;
    try std.testing.expectEqualStrings("abc", filed.last_commit);
    try std.testing.expectEqual(@as(u64, 2), state.days.items[0].seeds);
    try std.testing.expectEqual(@as(u64, 0), state.days.items[0].crashes);
    var out: std.Io.Writer.Allocating = .init(arena);
    try state.render(&out.writer);
    try std.testing.expectEqualStrings(
        "version 2\nfiled 83f4a12f59e06092 0 abc abc\nday 2026-11-02 2 1 1 abc 0 0\n",
        out.written(),
    );
}

test "the days kept are bounded, and a reported day drops what was seen on it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: State = .{};
    const first: i64 = 1_793_581_200;
    for (0..constants.fleet_days_kept + 3) |index| {
        const ymd = ymd_of(first + @as(i64, @intCast(index)) * 86_400);
        try state.count(arena, ymd, .{ .seeds = 1, .failed = 0 }, "c");
        _ = (try state.see(arena, ymd, "f", 1)).?;
    }
    try std.testing.expectEqual(@as(usize, constants.fleet_days_kept), state.days.items.len);
    try std.testing.expectEqual(@as(usize, constants.fleet_days_kept), state.seen.items.len);
    // The oldest days went first, and their seen lines with them.
    try std.testing.expectEqualStrings(&ymd_of(first + 3 * 86_400), &state.days.items[0].ymd);
    try std.testing.expectEqualStrings(&ymd_of(first + 3 * 86_400), &state.seen.items[0].ymd);
    try state.mark_reported(arena, ymd_of(first + 10 * 86_400));
    try std.testing.expectEqual(@as(usize, constants.fleet_days_kept - 8), state.seen.items.len);
    try std.testing.expectEqualStrings(&ymd_of(first + 11 * 86_400), &state.seen.items[0].ymd);
}

test "only finished, unreported days are due, oldest first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: State = .{};
    try state.count(arena, "2026-11-02".*, .{ .seeds = 5, .failed = 0 }, "c");
    try state.count(arena, "2026-10-30".*, .{ .seeds = 7, .failed = 1 }, "c");
    try state.count(arena, "2026-11-01".*, .{ .seeds = 9, .failed = 0 }, "c");
    state.reported = "2026-10-30";
    const due = try state.unreported(arena, "2026-11-02".*);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("2026-11-01", &due[0].ymd);
    state.reported = "";
    const all = try state.unreported(arena, "2026-11-02".*);
    try std.testing.expectEqualStrings("2026-10-30", &all[0].ymd);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}
