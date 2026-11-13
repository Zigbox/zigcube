//! The simulation fleet's coverage book and its bias (docs/briefs/c3.md, slice 3;
//! c3-sim-fleet.md, item 5; docs/decisions/2026-11-13-coverage-feedback.md).
//!
//!     sim_fleet coverage --kind sim-cluster|sim-c1 --commit SHA --file FILE < round output
//!     sim_fleet bias --kind sim-cluster|sim-c1 --commit SHA --file FILE
//!
//! `coverage` adds up the `coverage: profile=P seeds=N name=reached ...` lines a round's
//! `sim_cluster --seeds` runs printed (how many seeds of each fault profile reached each
//! coverage name) into FILE, which holds one commit's totals: a new commit starts it over. It
//! touches nothing the tracker counts (`ingest` and its state file count the seeds run).
//!
//! `bias` prints the fault profile the fleet's next biased round should run, and why on stderr:
//! a profile that has run fewer than `seeds_min` seeds of the commit first (fewest first), so
//! every rate below rests on enough seeds; then the profile that reached the least reached name
//! (fewest seeds over all profiles, among names some seed reached) in the largest share of its
//! seeds. A name no seed of the commit reached is left out: nothing says which profile could.
//!
//! The book's lines, sorted, after `coverage 1 <commit>`:
//!     seeds <kind> <profile> <n>
//!     reach <kind> <profile> <name> <n>

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const sim_shape = @import("sim_shape.zig");
const issue = @import("sim_fleet_issue.zig");

const Profile = sim_shape.ClusterProfile;
const profiles = @typeInfo(Profile).@"enum".field_names.len;

/// Seeds of the commit a profile runs before `bias` judges it by its rates.
pub const seeds_min: u64 = 100;
const book_version = "coverage 1 ";

pub const Error = error{ BadLine, BadBook, OutOfMemory };

/// One commit's totals: `seeds <kind> <profile>` and `reach <kind> <profile> <name>`, each with
/// its count.
pub const Book = struct {
    commit: []const u8,
    counts: std.StringArrayHashMapUnmanaged(u64) = .empty,

    fn add(book: *Book, arena: std.mem.Allocator, key: []const u8, n: u64) Error!void {
        const slot = try book.counts.getOrPut(arena, key);
        if (!slot.found_existing) {
            slot.key_ptr.* = try arena.dupe(u8, key);
            slot.value_ptr.* = 0;
        }
        slot.value_ptr.* +|= n;
    }

    pub fn get(book: *const Book, key: []const u8) u64 {
        return book.counts.get(key) orelse 0;
    }

    pub fn render(book: *const Book, arena: std.mem.Allocator, out: *std.Io.Writer) !void {
        const keys = try arena.dupe([]const u8, book.counts.keys());
        std.mem.sortUnstable([]const u8, keys, {}, less);
        try out.print("{s}{s}\n", .{ book_version, book.commit });
        for (keys) |key| try out.print("{s} {d}\n", .{ key, book.get(key) });
    }

    fn less(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// The book in `text` if it is of `commit`, else an empty one of `commit`.
pub fn parse_book(arena: std.mem.Allocator, text: []const u8, commit: []const u8) Error!Book {
    var book: Book = .{ .commit = commit };
    if (text.len == 0) return book;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.first();
    if (!std.mem.startsWith(u8, header, book_version)) return error.BadBook;
    if (!std.mem.eql(u8, header[book_version.len..], commit)) return book;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.BadBook;
        const n = std.fmt.parseInt(u64, line[space + 1 ..], 10) catch return error.BadBook;
        const key = line[0..space];
        if (!std.mem.startsWith(u8, key, "seeds ") and !std.mem.startsWith(u8, key, "reach ")) {
            return error.BadBook;
        }
        try book.add(arena, key, n);
    }
    return book;
}

/// Adds every `coverage: profile=` line of `input` (one kind's output of a round) to `book`;
/// returns the seeds added. Other lines are the tracker's and are skipped.
pub fn merge(arena: std.mem.Allocator, book: *Book, kind: []const u8, input: []const u8) Error!u64 {
    assert(kind_covered(kind));
    var seeds: u64 = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "coverage: profile=")) continue;
        var words = std.mem.tokenizeScalar(u8, line["coverage: ".len..], ' ');
        const profile = Profile.parse(value_of(words.next(), "profile") orelse
            return error.BadLine) orelse return error.BadLine;
        const n = std.fmt.parseInt(u64, value_of(words.next(), "seeds") orelse
            return error.BadLine, 10) catch return error.BadLine;
        try book.add(arena, try key_of(arena, "seeds", kind, profile, null), n);
        seeds += n;
        while (words.next()) |word| {
            const equals = std.mem.indexOfScalar(u8, word, '=') orelse return error.BadLine;
            const name = word[0..equals];
            const reached = std.fmt.parseInt(u64, word[equals + 1 ..], 10) catch
                return error.BadLine;
            if (reached > n or name.len == 0) return error.BadLine;
            // How many names a run dropped is no name to aim at.
            if (std.mem.eql(u8, name, "dropped")) continue;
            try book.add(arena, try key_of(arena, "reach", kind, profile, name), reached);
        }
    }
    return seeds;
}

fn value_of(word: ?[]const u8, comptime name: []const u8) ?[]const u8 {
    const text = word orelse return null;
    if (!std.mem.startsWith(u8, text, name ++ "=")) return null;
    return text[name.len + 1 ..];
}

fn key_of(
    arena: std.mem.Allocator,
    what: []const u8,
    kind: []const u8,
    profile: Profile,
    name: ?[]const u8,
) error{OutOfMemory}![]const u8 {
    if (name) |n| return std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{
        what, kind, profile.name(), n,
    });
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ what, kind, profile.name() });
}

/// The kinds with coverage: the cluster simulation's (`sim_swarm` has none yet).
pub fn kind_covered(kind: []const u8) bool {
    return std.mem.eql(u8, kind, issue.kind_sim_cluster) or
        std.mem.eql(u8, kind, issue.kind_sim_c1);
}

pub const Choice = struct {
    profile: Profile,
    /// Why: `few seeds`, or the name aimed at.
    name: ?[]const u8,
    seeds: u64,
    reached: u64,
};

/// The profile the next biased round of `kind` runs.
pub fn choose(book: *const Book, kind: []const u8) Choice {
    assert(kind_covered(kind));
    var fewest: Choice = .{ .profile = profile_at(0), .name = null, .seeds = 0, .reached = 0 };
    for (0..profiles) |index| {
        const n = seeds_of(book, kind, profile_at(index));
        if (index == 0 or n < fewest.seeds) fewest = .{
            .profile = profile_at(index),
            .name = null,
            .seeds = n,
            .reached = 0,
        };
    }
    if (fewest.seeds < seeds_min) return fewest;
    const name = least_reached(book, kind) orelse return fewest;
    var best: Choice = .{ .profile = profile_at(0), .name = name, .seeds = 1, .reached = 0 };
    for (0..profiles) |index| {
        const profile = profile_at(index);
        const n = seeds_of(book, kind, profile);
        const reached = reach_of(book, kind, profile, name);
        // reached / n above best.reached / best.seeds, without division.
        if (reached * best.seeds > best.reached * n) {
            best = .{ .profile = profile, .name = name, .seeds = n, .reached = reached };
        }
    }
    return best;
}

fn profile_at(index: usize) Profile {
    return @fromBackingInt(@intCast(index));
}

fn seeds_of(book: *const Book, kind: []const u8, profile: Profile) u64 {
    var buffer: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "seeds {s} {s}", .{ kind, profile.name() }) catch
        return 0;
    return book.get(key);
}

fn reach_of(book: *const Book, kind: []const u8, profile: Profile, name: []const u8) u64 {
    var buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, "reach {s} {s} {s}", .{
        kind, profile.name(), name,
    }) catch return 0;
    return book.get(key);
}

/// The name of `kind` that the fewest seeds reached, over every profile, among the names some
/// seed reached; ties go to the first by name.
fn least_reached(book: *const Book, kind: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_total: u64 = 0;
    for (book.counts.keys()) |key| {
        const name = name_in(key, kind) orelse continue;
        var total: u64 = 0;
        for (0..profiles) |index| total += reach_of(book, kind, profile_at(index), name);
        if (total == 0) continue;
        const better = if (best) |b|
            total < best_total or (total == best_total and std.mem.order(u8, name, b) == .lt)
        else
            true;
        if (better) {
            best = name;
            best_total = total;
        }
    }
    return best;
}

/// The name in `reach <kind> <profile> <name>`, if the key is one of `kind`.
fn name_in(key: []const u8, kind: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, key, "reach ")) return null;
    const rest = key["reach ".len..];
    if (!std.mem.startsWith(u8, rest, kind) or rest.len <= kind.len or rest[kind.len] != ' ') {
        return null;
    }
    const after = rest[kind.len + 1 ..];
    const space = std.mem.indexOfScalar(u8, after, ' ') orelse return null;
    return after[space + 1 ..];
}

// ---- The command --------------------------------------------------------------------------------

pub const Args = struct {
    bias: bool,
    kind: []const u8 = "",
    commit: []const u8 = "",
    file: []const u8 = "",
};

/// `coverage ...` or `bias ...`; null if `args` is neither or is not whole.
pub fn parse_args(args: []const []const u8) ?Args {
    if (args.len < 2) return null;
    var parsed: Args = .{ .bias = std.mem.eql(u8, args[1], "bias") };
    if (!parsed.bias and !std.mem.eql(u8, args[1], "coverage")) return null;
    var index: usize = 2;
    while (index + 1 < args.len) : (index += 2) {
        const value = args[index + 1];
        if (std.mem.eql(u8, args[index], "--kind")) {
            parsed.kind = value;
        } else if (std.mem.eql(u8, args[index], "--commit")) {
            parsed.commit = value;
        } else if (std.mem.eql(u8, args[index], "--file")) {
            parsed.file = value;
        } else {
            return null;
        }
    }
    if (index != args.len) return null;
    if (!kind_covered(parsed.kind) or parsed.file.len == 0 or parsed.commit.len == 0) return null;
    if (std.mem.indexOfAny(u8, parsed.commit, " \t\r\n") != null) return null;
    return parsed;
}

pub const RunError = Error || error{ BookUnreadable, BookUnwritable, InputUnreadable } ||
    std.Io.Writer.Error;

pub fn run(
    init: std.process.Init,
    args: Args,
    out: *std.Io.Writer,
    log: *std.Io.Writer,
) RunError!void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(constants.fleet_state_bytes_max);
    const text = cwd.readFileAlloc(io, args.file, arena, limit) catch |err| switch (err) {
        error.FileNotFound => "",
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.print("sim-fleet: {s}: {s}\n", .{ args.file, @errorName(err) }) catch {};
            return error.BookUnreadable;
        },
    };
    var book = try parse_book(arena, text, args.commit);
    if (args.bias) {
        const choice = choose(&book, args.kind);
        try out.print("{s}\n", .{choice.profile.name()});
        if (choice.name) |name| {
            try log.print("sim-fleet: bias {s}: {s}, which reached {s} in {d} of {d} seeds\n", .{
                args.kind, choice.profile.name(), name, choice.reached, choice.seeds,
            });
        } else {
            try log.print("sim-fleet: bias {s}: {s}, which has run {d} seeds of this commit\n", .{
                args.kind, choice.profile.name(), choice.seeds,
            });
        }
        return;
    }
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const input_limit: std.Io.Limit = .limited(constants.fleet_input_bytes_max);
    const input = stdin.interface.allocRemaining(arena, input_limit) catch
        return error.InputUnreadable;
    const seeds = try merge(arena, &book, args.kind, input);
    var rendered: std.Io.Writer.Allocating = .init(arena);
    book.render(arena, &rendered.writer) catch return error.OutOfMemory;
    if (rendered.written().len > constants.fleet_state_bytes_max) return error.BookUnwritable;
    const temp = try std.fmt.allocPrint(arena, "{s}.new", .{args.file});
    cwd.writeFile(io, .{ .sub_path = temp, .data = rendered.written() }) catch
        return error.BookUnwritable;
    cwd.rename(temp, cwd, args.file, io) catch return error.BookUnwritable;
    try out.print("sim-fleet: coverage {s}: {d} seeds added\n", .{ args.kind, seeds });
}

pub fn explain(err: RunError) []const u8 {
    return switch (err) {
        error.BadLine => "stdin has a `coverage: profile=` line sim_fleet cannot read; feed it " ++
            "unchanged `sim_cluster --seeds` output",
        error.BadBook => "the coverage file is not one sim_fleet wrote; move it aside " ++
            "(it holds only this commit's coverage, which the next rounds rebuild)",
        error.BookUnreadable => "cannot read the coverage file (see the line above)",
        error.BookUnwritable => "cannot write the coverage file or its .new next to it, or it " ++
            "grew past the most a state file may hold",
        error.InputUnreadable => "cannot read stdin, or it is larger than a round may be",
        error.OutOfMemory => "out of memory",
        error.WriteFailed => "cannot write to stdout or stderr",
    };
}

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

const round_one =
    \\seed 9: FAILED: J8: a run kept executing
    \\  step: healed
    \\coverage: profile=mixed seeds=3 check.J8=3 fault.crash=2 path.rare=0 dropped=1
    \\coverage: profile=skew seeds=1 check.J8=1 fault.crash=0 path.rare=1
    \\sim-cluster: seeds 1..4, drawn operations: 1 of 4 failed
    \\
;

test "a round's coverage adds up, renders sorted and reads back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var book = try parse_book(arena, "", "abc");
    try testing.expectEqual(@as(u64, 4), try merge(arena, &book, "sim-cluster", round_one));
    try testing.expectEqual(@as(u64, 4), try merge(arena, &book, "sim-cluster", round_one));
    var out: std.Io.Writer.Allocating = .init(arena);
    try book.render(arena, &out.writer);
    try testing.expectEqualStrings(
        \\coverage 1 abc
        \\reach sim-cluster mixed check.J8 6
        \\reach sim-cluster mixed fault.crash 4
        \\reach sim-cluster mixed path.rare 0
        \\reach sim-cluster skew check.J8 2
        \\reach sim-cluster skew fault.crash 0
        \\reach sim-cluster skew path.rare 2
        \\seeds sim-cluster mixed 6
        \\seeds sim-cluster skew 2
        \\
    , out.written());
    const again = try parse_book(arena, out.written(), "abc");
    try testing.expectEqual(@as(u64, 6), again.get("seeds sim-cluster mixed"));
    const other = try parse_book(arena, out.written(), "def");
    try testing.expectEqual(@as(usize, 0), other.counts.count());
    try testing.expectError(error.BadBook, parse_book(arena, "state 3\n", "abc"));
}

test "a coverage line that is not the simulator's is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var book = try parse_book(arena, "", "abc");
    const bad = [_][]const u8{
        "coverage: profile=nope seeds=1 a=1\n",
        "coverage: profile=mixed seeds=x a=1\n",
        "coverage: profile=mixed seeds=1 a=2\n",
        "coverage: profile=mixed seeds=1 a\n",
        "coverage: profile=mixed\n",
    };
    for (bad) |line| try testing.expectError(error.BadLine, merge(arena, &book, "sim-c1", line));
}

test "bias runs a profile with few seeds first, then aims at the least reached name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var book = try parse_book(arena, "", "abc");
    // Nothing yet: the first profile, with no seeds.
    try testing.expectEqual(Profile.mixed, choose(&book, "sim-c1").profile);
    var line: std.Io.Writer.Allocating = .init(arena);
    for (0..profiles) |index| {
        const profile: Profile = @fromBackingInt(@intCast(index));
        // Every profile reaches `common`; only skew (2 of 200) and crash_heavy (1 of 100)
        // reach `rare`; `never` no seed reached, so it is no aim.
        const n: u64 = if (profile == .skew) 200 else 100;
        const rare: u64 = switch (profile) {
            .skew => 2,
            .crash_heavy => 1,
            else => 0,
        };
        try line.writer.print("coverage: profile={s} seeds={d} common={d} rare={d} never=0\n", .{
            profile.name(), n, n, rare,
        });
    }
    _ = try merge(arena, &book, "sim-c1", line.written());
    // Equal shares (1 in 100): the first in the enum's order wins the tie.
    var choice = choose(&book, "sim-c1");
    try testing.expectEqual(Profile.skew, choice.profile);
    try testing.expectEqualStrings("rare", choice.name.?);
    _ = try merge(arena, &book, "sim-c1", "coverage: profile=crash_heavy seeds=1 rare=1\n");
    choice = choose(&book, "sim-c1");
    try testing.expectEqual(Profile.crash_heavy, choice.profile);
    // Another kind's book is apart: sim-cluster has no seeds, so its first profile runs.
    try testing.expectEqual(Profile.mixed, choose(&book, "sim-cluster").profile);
    // A profile below `seeds_min` goes first.
    _ = try merge(arena, &book, "sim-cluster", "coverage: profile=mixed seeds=100 a=1\n");
    try testing.expectEqual(Profile.partitions, choose(&book, "sim-cluster").profile);
}

test "the command line takes a covered kind, a commit and a file" {
    const tail = [_][]const u8{ "--commit", "abc", "--file", "f" };
    const good = parse_args(&(.{ "sim_fleet", "bias", "--kind", "sim-c1" } ++ tail));
    try testing.expect(good.?.bias);
    try testing.expectEqualStrings("f", good.?.file);
    const swarm = .{ "sim_fleet", "coverage", "--kind", "sim-swarm" } ++ tail;
    try testing.expect(parse_args(&swarm) == null);
    const no_commit = .{ "sim_fleet", "coverage", "--kind", "sim-c1", "--file", "f" };
    try testing.expect(parse_args(&no_commit) == null);
    const no_file = .{ "sim_fleet", "coverage", "--kind", "sim-c1", "--commit", "a", "--file" };
    try testing.expect(parse_args(&no_file) == null);
    try testing.expect(parse_args(&.{ "sim_fleet", "ingest" }) == null);
}
