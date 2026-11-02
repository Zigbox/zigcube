//! The simulation fleet's state file: which failures it has filed (so a restart does not file
//! them again) and how many seeds it ran each UTC day (so it can say so). Plain lines:
//!
//!     version 1
//!     filed <fingerprint> <issue number> <commit>
//!     day <YYYY-MM-DD> <seeds> <failed seeds> <batches> <last commit>
//!     reported <YYYY-MM-DD>
//!
//! If the file is lost, the markers on the issues rebuild the `filed` lines
//! (`sim_fleet_github.zig`); the day counts start over.

const std = @import("std");
const assert = std.debug.assert;

/// The state file's format; a file without a `version` line is version 1.
const version = 1;

pub const ymd_bytes = 10;
pub const Ymd = [ymd_bytes]u8;

pub const Filed = struct {
    fingerprint: []const u8,
    /// 0 in a dry run: nothing was really filed.
    issue: u32,
    commit: []const u8,
};

pub const Day = struct {
    ymd: Ymd,
    seeds: u64,
    failed: u64,
    batches: u32,
    commit: []const u8,
};

pub const State = struct {
    filed: std.ArrayList(Filed) = .empty,
    days: std.ArrayList(Day) = .empty,
    /// The latest day whose totals were posted, "" if none.
    reported: []const u8 = "",

    pub fn find(state: *const State, fingerprint: []const u8) ?Filed {
        for (state.filed.items) |item| {
            if (std.mem.eql(u8, item.fingerprint, fingerprint)) return item;
        }
        return null;
    }

    /// Adds `seeds` and `failed` to day `ymd`, opening it if need be.
    pub fn count(
        state: *State,
        arena: std.mem.Allocator,
        ymd: Ymd,
        seeds: u64,
        failed: u64,
        commit: []const u8,
    ) error{OutOfMemory}!void {
        assert(failed <= seeds);
        for (state.days.items) |*day| {
            if (!std.mem.eql(u8, &day.ymd, &ymd)) continue;
            day.seeds += seeds;
            day.failed += failed;
            day.batches += 1;
            day.commit = commit;
            return;
        }
        try state.days.append(arena, .{
            .ymd = ymd,
            .seeds = seeds,
            .failed = failed,
            .batches = 1,
            .commit = commit,
        });
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
        for (state.filed.items) |item| {
            try out.print("filed {s} {d} {s}\n", .{ item.fingerprint, item.issue, item.commit });
        }
        for (state.days.items) |day| {
            try out.print("day {s} {d} {d} {d} {s}\n", .{
                &day.ymd, day.seeds, day.failed, day.batches, day.commit,
            });
        }
        if (state.reported.len > 0) try out.print("reported {s}\n", .{state.reported});
    }
};

fn older(_: void, a: Day, b: Day) bool {
    return std.mem.order(u8, &a.ymd, &b.ymd) == .lt;
}

pub const ParseError = error{ BadState, OutOfMemory };

/// Reads a state file. A line it does not understand is an error, not skipped: a state file
/// that quietly loses lines files the same failure twice.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!State {
    var state: State = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = words.next() orelse continue;
        if (std.mem.eql(u8, kind, "version")) {
            const text_version = words.next() orelse return error.BadState;
            // A file from a later release is refused, not half read.
            if (!std.mem.eql(u8, text_version, "1")) return error.BadState;
        } else if (std.mem.eql(u8, kind, "filed")) {
            try state.filed.append(arena, try parse_filed(&words));
        } else if (std.mem.eql(u8, kind, "day")) {
            try state.days.append(arena, try parse_day(&words));
        } else if (std.mem.eql(u8, kind, "reported")) {
            state.reported = words.next() orelse return error.BadState;
        } else {
            return error.BadState;
        }
    }
    return state;
}

fn parse_filed(words: *std.mem.TokenIterator(u8, .scalar)) ParseError!Filed {
    const fingerprint = words.next() orelse return error.BadState;
    const issue_text = words.next() orelse return error.BadState;
    return .{
        .fingerprint = fingerprint,
        .issue = std.fmt.parseInt(u32, issue_text, 10) catch return error.BadState,
        .commit = words.next() orelse return error.BadState,
    };
}

fn parse_day(words: *std.mem.TokenIterator(u8, .scalar)) ParseError!Day {
    const ymd_text = words.next() orelse return error.BadState;
    if (ymd_text.len != ymd_bytes) return error.BadState;
    const seeds = words.next() orelse return error.BadState;
    const failed = words.next() orelse return error.BadState;
    const batches = words.next() orelse return error.BadState;
    const day: Day = .{
        .ymd = ymd_text[0..ymd_bytes].*,
        .seeds = std.fmt.parseInt(u64, seeds, 10) catch return error.BadState,
        .failed = std.fmt.parseInt(u64, failed, 10) catch return error.BadState,
        .batches = std.fmt.parseInt(u32, batches, 10) catch return error.BadState,
        .commit = words.next() orelse return error.BadState,
    };
    if (day.failed > day.seeds) return error.BadState;
    return day;
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
    var state: State = .{};
    try state.filed.append(arena, .{
        .fingerprint = "0123456789abcdef",
        .issue = 12,
        .commit = "c1",
    });
    try state.count(arena, ymd_of(1_793_581_200), 40, 3, "c1");
    try state.count(arena, ymd_of(1_793_581_200), 10, 0, "c2");
    state.reported = "2026-10-31";
    var out: std.Io.Writer.Allocating = .init(arena);
    try state.render(&out.writer);
    const again = try parse(arena, out.written());
    try std.testing.expectEqual(@as(usize, 1), again.filed.items.len);
    try std.testing.expectEqual(@as(u32, 12), again.find("0123456789abcdef").?.issue);
    try std.testing.expectEqual(@as(u64, 50), again.days.items[0].seeds);
    try std.testing.expectEqual(@as(u32, 2), again.days.items[0].batches);
    try std.testing.expectEqualStrings("c2", again.days.items[0].commit);
    try std.testing.expectEqualStrings("2026-10-31", again.reported);
    try std.testing.expect(again.find("nope") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "version 1\n"));
    try std.testing.expectError(error.BadState, parse(arena, "version 2\n"));
    try std.testing.expectError(error.BadState, parse(arena, "surprise 1\n"));
    try std.testing.expectError(error.BadState, parse(arena, "day 2026-11-02 1 2 1 c\n"));
}

test "only finished, unreported days are due, oldest first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: State = .{};
    try state.count(arena, "2026-11-02".*, 5, 0, "c");
    try state.count(arena, "2026-10-30".*, 7, 1, "c");
    try state.count(arena, "2026-11-01".*, 9, 0, "c");
    state.reported = "2026-10-30";
    const due = try state.unreported(arena, "2026-11-02".*);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("2026-11-01", &due[0].ymd);
    state.reported = "";
    const all = try state.unreported(arena, "2026-11-02".*);
    try std.testing.expectEqualStrings("2026-10-30", &all[0].ymd);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}
