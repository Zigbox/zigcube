//! The simulation fleet's view of a failure: parse the runner's output, fingerprint each failure
//! and render the issue or comment that reports it (docs/briefs/c1-9.md). No network and no
//! files: `sim_fleet.zig` does those.

const std = @import("std");
const assert = std.debug.assert;

pub const kind_sim_cluster = "sim-cluster";

/// Hex digits of a fingerprint: 8 bytes of SHA-256, enough that two failures never meet by chance.
pub const fingerprint_bytes = 16;
pub const Fingerprint = [fingerprint_bytes]u8;

/// How the issues the fleet files are found again: the label, and a marker in the body.
pub const label = "sim-fleet";
const marker_open = "<!-- sim-fleet fingerprint: ";
const marker_close = " -->";

/// One failing seed as `sim_cluster --seeds A..B <operations> --shrink` printed it.
pub const Failure = struct {
    seed: u64,
    check: []const u8,
    step: []const u8,
    replay: []const u8,
    shrunk_operations: ?u32 = null,
    shrunk_replay: ?[]const u8 = null,
};

/// A whole run of the runner: the seeds it covered and the seeds that failed.
pub const Batch = struct {
    seeds: u64,
    operations: u32,
    failures: []const Failure,
};

pub const ParseError = error{ NoSummary, BadLine, OutOfMemory };

/// The same failure on any commit and any seed hashes alike: it depends on the kind of run, the
/// check that failed and the step of the run it failed at, and on nothing else.
pub fn fingerprint(kind: []const u8, failure: Failure) Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(kind);
    hash.update("\x00");
    hash.update(failure.check);
    hash.update("\x00");
    hash.update(failure.step);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0 .. fingerprint_bytes / 2].*, .lower);
    return hex;
}

fn after_prefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

/// The text between `seed ` and `: FAILED: `.
fn parse_seed_line(line: []const u8) ?struct { seed: u64, check: []const u8 } {
    const rest = after_prefix(line, "seed ") orelse return null;
    const split = std.mem.indexOf(u8, rest, ": FAILED: ") orelse return null;
    const seed = std.fmt.parseInt(u64, rest[0..split], 10) catch return null;
    return .{ .seed = seed, .check = rest[split + ": FAILED: ".len ..] };
}

const SummaryLine = struct { seeds: u64, operations: u32 };

/// "sim-cluster: seeds A..B, N operations: F of T failed" gives (T, N).
fn parse_summary(line: []const u8) ?SummaryLine {
    const rest = after_prefix(line, "sim-cluster: seeds ") orelse return null;
    const comma = std.mem.indexOf(u8, rest, ", ") orelse return null;
    const dots = std.mem.indexOf(u8, rest[0..comma], "..") orelse return null;
    const first = std.fmt.parseInt(u64, rest[0..dots], 10) catch return null;
    const last = std.fmt.parseInt(u64, rest[dots + 2 .. comma], 10) catch return null;
    if (last < first) return null;
    const tail = rest[comma + 2 ..];
    const space = std.mem.indexOfScalar(u8, tail, ' ') orelse return null;
    const operations = std.fmt.parseInt(u32, tail[0..space], 10) catch return null;
    return .{ .seeds = last - first + 1, .operations = operations };
}

/// Parses the output of a range run. It must end in the runner's summary line: output without it
/// is a run that was cut short, and counting its seeds would be a guess.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Batch {
    var failures: std.ArrayList(Failure) = .empty;
    var summary: ?SummaryLine = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (parse_seed_line(line)) |found| {
            try failures.append(arena, .{
                .seed = found.seed,
                .check = found.check,
                .step = "",
                .replay = "",
            });
        } else if (parse_summary(line)) |found| {
            summary = found;
        } else if (failures.items.len > 0) {
            try parse_detail(&failures.items[failures.items.len - 1], std.mem.trim(u8, line, " "));
        }
    }
    const done = summary orelse return error.NoSummary;
    for (failures.items) |failure| {
        if (failure.step.len == 0 or failure.replay.len == 0) return error.BadLine;
    }
    return .{
        .seeds = done.seeds,
        .operations = done.operations,
        .failures = failures.items,
    };
}

/// An indented line under a `seed N: FAILED:` line: step, replay or the shrunk count.
fn parse_detail(failure: *Failure, line: []const u8) ParseError!void {
    if (after_prefix(line, "step: ")) |step| {
        failure.step = step;
    } else if (after_prefix(line, "replay: ")) |replay| {
        if (failure.replay.len == 0) {
            failure.replay = replay;
        } else {
            failure.shrunk_replay = replay;
        }
    } else if (after_prefix(line, "shrunk to ")) |rest| {
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadLine;
        failure.shrunk_operations = std.fmt.parseInt(u32, rest[0..space], 10) catch
            return error.BadLine;
    }
}

/// The line that rebuilds and replays a failure on the commit that found it.
pub fn replay_line(
    arena: std.mem.Allocator,
    commit: []const u8,
    failure: Failure,
) std.mem.Allocator.Error![]const u8 {
    const replay = failure.shrunk_replay orelse failure.replay;
    return std.fmt.allocPrint(
        arena,
        "git checkout {s} && zig build -Doptimize=ReleaseSafe sim-cluster-exe && {s}",
        .{ commit, replay },
    );
}

pub fn title(
    arena: std.mem.Allocator,
    kind: []const u8,
    failure: Failure,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s}: {s} (step: {s})",
        .{ kind, failure.check, failure.step },
    );
}

/// The seeds of `more` that failed the same way, as ", 3, 9" (no more than `listed_max`).
fn write_seeds(out: *std.Io.Writer, more: []const Failure) std.Io.Writer.Error!void {
    const listed_max = 20;
    for (more[0..@min(more.len, listed_max)], 0..) |failure, index| {
        if (index > 0) try out.writeAll(", ");
        try out.print("{d}", .{failure.seed});
    }
    if (more.len > listed_max) try out.print(" and {d} more", .{more.len - listed_max});
}

fn write_failure(
    out: *std.Io.Writer,
    commit: []const u8,
    failure: Failure,
    replay: []const u8,
) std.Io.Writer.Error!void {
    try out.print("- commit: `{s}`\n- seed: {d}\n", .{ commit, failure.seed });
    if (failure.shrunk_operations) |shrunk| {
        try out.print("- operations: shrunk to {d}\n", .{shrunk});
    } else {
        try out.writeAll("- operations: not shrunk\n");
    }
    try out.print("\nReplay:\n\n```\n{s}\n```\n", .{replay});
}

/// The body of a new issue. `more` are the other seeds of the same batch that failed alike.
pub fn issue_body(
    arena: std.mem.Allocator,
    commit: []const u8,
    failure: Failure,
    more: []const Failure,
) error{OutOfMemory}![]const u8 {
    const replay = try replay_line(arena, commit, failure);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    write_body(w, commit, failure, more, replay) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write_body(
    w: *std.Io.Writer,
    commit: []const u8,
    failure: Failure,
    more: []const Failure,
    replay: []const u8,
) std.Io.Writer.Error!void {
    try w.print("The simulation fleet found a failure no open or closed issue covers.\n\n", .{});
    try w.print("- check: {s}\n- step: {s}\n", .{ failure.check, failure.step });
    try write_failure(w, commit, failure, replay);
    if (more.len > 0) {
        try w.writeAll("\nAlso failing this way in the same batch: seeds ");
        try write_seeds(w, more);
        try w.writeAll(".\n");
    }
    try w.writeAll("\nThe fleet comments here when this fails again. ");
    try w.writeAll("Close the issue when it is fixed; a new failure of the same kind ");
    try w.writeAll("comments on it again, which is how a regression shows.\n\n");
    const fp = fingerprint(kind_sim_cluster, failure);
    try w.print("{s}{s}{s}\n", .{ marker_open, &fp, marker_close });
}

/// A comment for a failure that already has an issue.
pub fn comment_body(
    arena: std.mem.Allocator,
    commit: []const u8,
    failure: Failure,
    more: []const Failure,
) error{OutOfMemory}![]const u8 {
    const replay = try replay_line(arena, commit, failure);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    write_comment(w, commit, failure, more, replay) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write_comment(
    w: *std.Io.Writer,
    commit: []const u8,
    failure: Failure,
    more: []const Failure,
    replay: []const u8,
) std.Io.Writer.Error!void {
    try w.writeAll("The fleet saw this failure again.\n\n");
    try write_failure(w, commit, failure, replay);
    if (more.len > 0) {
        try w.writeAll("\nAlso failing this way in the same batch: seeds ");
        try write_seeds(w, more);
        try w.writeAll(".\n");
    }
}

/// The fingerprint in an issue body, if it carries the fleet's marker.
pub fn marker_of(body: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, marker_open) orelse return null;
    const from = start + marker_open.len;
    const end = std.mem.indexOfPos(u8, body, from, marker_close) orelse return null;
    if (end - from != fingerprint_bytes) return null;
    return body[from..end];
}

const sample =
    \\seed 1: FAILED: a container runs that no replica assigns to its node
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 1 100 0 --heal-at=60
    \\  shrunk to 13 operations
    \\  replay: zig-out/bin/sim_cluster 1 13 0 --heal-at=60
    \\seed 4: FAILED: a container runs that no replica assigns to its node
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 4 100 0 --heal-at=65
    \\  shrunk to 67 operations
    \\  replay: zig-out/bin/sim_cluster 4 67 0 --heal-at=65
    \\seed 7: FAILED: a replica is not placed
    \\  step: convergence
    \\  replay: zig-out/bin/sim_cluster 7 100 0 --heal-at=61
    \\sim-cluster: seeds 1..10, 100 operations: 3 of 10 failed
    \\
;

test "parse reads failures, their shrinks and the seed count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const batch = try parse(arena_state.allocator(), sample);
    try std.testing.expectEqual(@as(u64, 10), batch.seeds);
    try std.testing.expectEqual(@as(u32, 100), batch.operations);
    try std.testing.expectEqual(@as(usize, 3), batch.failures.len);
    try std.testing.expectEqual(@as(u64, 4), batch.failures[1].seed);
    try std.testing.expectEqual(@as(?u32, 67), batch.failures[1].shrunk_operations);
    try std.testing.expectEqualStrings("convergence", batch.failures[2].step);
    try std.testing.expect(batch.failures[2].shrunk_replay == null);
}

test "parse refuses output cut short or without a step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cut = sample[0 .. sample.len - 50];
    try std.testing.expectError(error.NoSummary, parse(arena, cut));
    const no_step =
        \\seed 1: FAILED: x
        \\  replay: zig-out/bin/sim_cluster 1 100 0
        \\sim-cluster: seeds 1..1, 100 operations: 1 of 1 failed
    ;
    try std.testing.expectError(error.BadLine, parse(arena, no_step));
    const clean = "sim-cluster: seeds 5..9, 60 operations: 0 of 5 failed\n";
    const batch = try parse(arena, clean);
    try std.testing.expectEqual(@as(u64, 5), batch.seeds);
    try std.testing.expectEqual(@as(usize, 0), batch.failures.len);
}

test "the fingerprint ignores the seed, the commit and the shrink; the step changes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const batch = try parse(arena_state.allocator(), sample);
    const a = fingerprint(kind_sim_cluster, batch.failures[0]);
    const b = fingerprint(kind_sim_cluster, batch.failures[1]);
    try std.testing.expectEqualStrings(&a, &b);
    var other_step = batch.failures[0];
    other_step.step = "convergence";
    const c = fingerprint(kind_sim_cluster, other_step);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    const d = fingerprint(kind_sim_cluster, batch.failures[2]);
    try std.testing.expect(!std.mem.eql(u8, &a, &d));
    const e = fingerprint("store-faults", batch.failures[0]);
    try std.testing.expect(!std.mem.eql(u8, &a, &e));
}

test "the issue body names commit, seed, shrunk operations, replay and the marker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, sample);
    const body = try issue_body(arena, "abc123", batch.failures[0], batch.failures[1..2]);
    const expected_replay = "git checkout abc123 && zig build -Doptimize=ReleaseSafe " ++
        "sim-cluster-exe && zig-out/bin/sim_cluster 1 13 0 --heal-at=60";
    try std.testing.expect(std.mem.indexOf(u8, body, expected_replay) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "- seed: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shrunk to 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "seeds 4.") != null);
    const fp = fingerprint(kind_sim_cluster, batch.failures[0]);
    try std.testing.expectEqualStrings(&fp, marker_of(body).?);
    try std.testing.expect(marker_of("no marker here") == null);
    const text = try title(arena, kind_sim_cluster, batch.failures[0]);
    try std.testing.expectEqualStrings(
        "sim-cluster: a container runs that no replica assigns to its node (step: healed)",
        text,
    );
}

test "a failure that was not shrunk replays the full run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, sample);
    const text = try comment_body(arena, "def456", batch.failures[2], &.{});
    try std.testing.expect(std.mem.indexOf(u8, text, "sim_cluster 7 100 0 --heal-at=61") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not shrunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Also failing") == null);
}
