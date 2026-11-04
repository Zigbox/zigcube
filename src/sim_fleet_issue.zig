//! The simulation fleet's view of a failure: parse the runner's output, fingerprint each failure
//! and render the issue or comment that reports it (docs/briefs/c1-9.md). No network and no
//! files: `sim_fleet.zig` does those.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const kind_sim_cluster = "sim-cluster";

/// Hex digits of a fingerprint: 8 bytes of SHA-256, enough that two failures never meet by chance.
pub const fingerprint_bytes = 16;
pub const Fingerprint = [fingerprint_bytes]u8;

/// How the issues the fleet files are found again: the label, and a marker in the body.
pub const label = "sim-fleet";
const marker_open = "<!-- sim-fleet fingerprint: ";
const marker_close = " -->";

/// The step `sim_cluster` reports when the run never started (it could not allocate its world):
/// the host's trouble, not the simulator's finding, so it is counted and never filed.
pub const step_setup = "setup";

/// One failing seed as `sim_cluster --seeds A..B <operations> --shrink` printed it, or a crash
/// as `run.sh` recorded it (`seed N: CRASHED: <panic message>`, same detail lines).
pub const Failure = struct {
    seed: u64,
    check: []const u8,
    step: []const u8,
    replay: []const u8,
    shrunk_operations: ?u32 = null,
    shrunk_replay: ?[]const u8 = null,
    /// The simulator panicked or died on this seed; `check` is its message, digits elided.
    crash: bool = false,

    /// A run that never started is the host's trouble (see `step_setup`).
    pub fn infra(failure: *const Failure) bool {
        return std.mem.eql(u8, failure.step, step_setup);
    }
};

/// One round of the runner: every batch's seeds and failures, the batches concatenated.
pub const Batch = struct {
    seeds: u64,
    /// The fixed operation count of the round, or null when the runner drew each seed's own
    /// (`auto`: its summary says `drawn operations`).
    operations: ?u32,
    failures: []const Failure,
};

pub const ParseError = error{ NoSummary, BadLine, TooManyFailures, OutOfMemory };

/// The same failure on any commit and any seed hashes alike: it depends on the kind of run, the
/// check that failed (or the crash message) and the step of the run it failed at, and on nothing
/// else. A crash hashes a tag of its own, so it never meets a check of the same text.
pub fn fingerprint(kind: []const u8, failure: Failure) Fingerprint {
    assert(kind.len > 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(kind);
    hash.update("\x00");
    if (failure.crash) hash.update("crash\x00");
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

const SeedLine = struct { seed: u64, check: []const u8, crash: bool };

/// `seed N: FAILED: <check>` or `seed N: CRASHED: <message>`.
fn parse_seed_line(line: []const u8) ?SeedLine {
    const rest = after_prefix(line, "seed ") orelse return null;
    const colon = std.mem.indexOf(u8, rest, ": ") orelse return null;
    const seed = std.fmt.parseInt(u64, rest[0..colon], 10) catch return null;
    const tail = rest[colon + 2 ..];
    if (after_prefix(tail, "FAILED: ")) |check| {
        return .{ .seed = seed, .check = check, .crash = false };
    }
    if (after_prefix(tail, "CRASHED: ")) |message| {
        return .{ .seed = seed, .check = message, .crash = true };
    }
    return null;
}

const SummaryLine = struct { seeds: u64, operations: ?u32 };

/// "sim-cluster: seeds A..B, N operations: F of T failed" gives (T, N); the `auto` form,
/// "sim-cluster: seeds A..B, drawn operations: F of T failed", gives (T, null).
fn parse_summary(line: []const u8) ?SummaryLine {
    const rest = after_prefix(line, "sim-cluster: seeds ") orelse return null;
    const comma = std.mem.indexOf(u8, rest, ", ") orelse return null;
    const dots = std.mem.indexOf(u8, rest[0..comma], "..") orelse return null;
    const first = std.fmt.parseInt(u64, rest[0..dots], 10) catch return null;
    const last = std.fmt.parseInt(u64, rest[dots + 2 .. comma], 10) catch return null;
    if (last < first) return null;
    const tail = rest[comma + 2 ..];
    if (std.mem.startsWith(u8, tail, "drawn operations: ")) {
        return .{ .seeds = last - first + 1, .operations = null };
    }
    const space = std.mem.indexOfScalar(u8, tail, ' ') orelse return null;
    const operations = std.fmt.parseInt(u32, tail[0..space], 10) catch return null;
    return .{ .seeds = last - first + 1, .operations = operations };
}

/// A crash message with every run of digits replaced by `N` and cut to the check limit, so the
/// same panic at another index or address is one failure.
fn normalize_crash(arena: std.mem.Allocator, message: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_digits = false;
    for (message) |byte| {
        if (out.items.len == constants.fleet_check_bytes_max) break;
        if (std.ascii.isDigit(byte)) {
            if (!in_digits) try out.append(arena, 'N');
            in_digits = true;
        } else {
            try out.append(arena, byte);
            in_digits = false;
        }
    }
    assert(out.items.len <= constants.fleet_check_bytes_max);
    return out.items;
}

/// Parses the output of one round: the outputs of its batches one after another, each ending in
/// the runner's summary line. A failure after the last summary is a batch that was cut short,
/// and counting its seeds would be a guess, so the whole round is refused.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Batch {
    var failures: std.ArrayList(Failure) = .empty;
    var seeds: u64 = 0;
    var operations: ?u32 = null;
    var summaries: u32 = 0; // Summary lines seen; the first fixes whether the round is drawn.
    var open = false; // A failure or nothing at all since the last summary.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (parse_seed_line(line)) |found| {
            if (failures.items.len == constants.fleet_round_failures_max) {
                return error.TooManyFailures;
            }
            const check = if (found.crash) try normalize_crash(arena, found.check) else found.check;
            try failures.append(arena, .{
                .seed = found.seed,
                .check = check,
                .crash = found.crash,
                .step = "",
                .replay = "",
            });
            open = true;
        } else if (parse_summary(line)) |found| {
            // Batches of one round run the same operation count.
            if (summaries > 0 and operations != found.operations) return error.BadLine;
            operations = found.operations;
            summaries += 1;
            seeds += found.seeds;
            open = false;
        } else if (failures.items.len > 0) {
            try parse_detail(&failures.items[failures.items.len - 1], std.mem.trim(u8, line, " "));
        }
    }
    if (open) return error.NoSummary;
    if (summaries == 0) return error.NoSummary;
    for (failures.items) |failure| {
        if (failure.step.len == 0) return error.BadLine;
        if (failure.replay.len == 0) return error.BadLine;
    }
    if (failures.items.len > seeds) return error.BadLine;
    return .{ .seeds = seeds, .operations = operations, .failures = failures.items };
}

/// An indented line under a `seed N:` line: step, replay or the shrunk count.
fn parse_detail(failure: *Failure, line: []const u8) ParseError!void {
    if (after_prefix(line, "step: ")) |step| {
        if (step.len == 0) return error.BadLine;
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
    assert(commit.len > 0);
    const replay = failure.shrunk_replay orelse failure.replay;
    assert(replay.len > 0);
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
    assert(kind.len > 0);
    const crash: []const u8 = if (failure.crash) "crash: " else "";
    return std.fmt.allocPrint(
        arena,
        "{s}: {s}{s} (step: {s})",
        .{ kind, crash, failure.check, failure.step },
    );
}

/// What an issue or a comment reports: the first failure of a fingerprint in a round, and the
/// other seeds of the round that failed alike.
pub const Report = struct {
    kind: []const u8,
    commit: []const u8,
    failure: Failure,
    more: []const Failure,
};

/// The seeds of `more` that failed the same way, as "3, 9" (no more than the listed limit).
fn write_seeds(out: *std.Io.Writer, more: []const Failure) std.Io.Writer.Error!void {
    const listed_max = constants.fleet_seeds_listed_max;
    assert(more.len > 0);
    for (more[0..@min(more.len, listed_max)], 0..) |failure, index| {
        if (index > 0) try out.writeAll(", ");
        try out.print("{d}", .{failure.seed});
    }
    if (more.len > listed_max) try out.print(" and {d} more", .{more.len - listed_max});
}

fn write_failure(
    out: *std.Io.Writer,
    report: *const Report,
    replay: []const u8,
) std.Io.Writer.Error!void {
    const failure = report.failure;
    try out.print("- commit: `{s}`\n- seed: {d}\n", .{ report.commit, failure.seed });
    if (failure.crash) {
        try out.writeAll("- operations: not shrunk (the simulator crashed)\n");
    } else if (failure.shrunk_operations) |shrunk| {
        try out.print("- operations: shrunk to {d}\n", .{shrunk});
    } else {
        try out.writeAll("- operations: not shrunk\n");
    }
    try out.print("\nReplay:\n\n```\n{s}\n```\n", .{replay});
    if (report.more.len > 0) {
        try out.writeAll("\nAlso failing this way in the same round: seeds ");
        try write_seeds(out, report.more);
        try out.writeAll(".\n");
    }
}

/// The body of a new issue, with the marker that finds it again.
pub fn issue_body(arena: std.mem.Allocator, report: *const Report) error{OutOfMemory}![]const u8 {
    const replay = try replay_line(arena, report.commit, report.failure);
    var out: std.Io.Writer.Allocating = .init(arena);
    write_body(&out.writer, report, replay) catch return error.OutOfMemory;
    const body = try out.toOwnedSlice();
    assert(marker_of(body) != null);
    return body;
}

fn write_body(
    w: *std.Io.Writer,
    report: *const Report,
    replay: []const u8,
) std.Io.Writer.Error!void {
    const failure = report.failure;
    try w.writeAll("The simulation fleet found a failure no open or closed issue covers.\n\n");
    if (failure.crash) {
        try w.print("- crash: {s}\n- step: {s}\n", .{ failure.check, failure.step });
        try w.writeAll("- the message has its digits replaced by N; the replay prints it whole\n");
    } else {
        try w.print("- check: {s}\n- step: {s}\n", .{ failure.check, failure.step });
    }
    try write_failure(w, report, replay);
    try w.writeAll("\nThe fleet comments here when this fails again on a later commit ");
    try w.writeAll("(a few times a day at most; the daily totals on the tracking issue count ");
    try w.writeAll("every seed). Close the issue when it is fixed; a new failure of the same ");
    try w.writeAll("kind comments on it again, which is how a regression shows.\n\n");
    const fp = fingerprint(report.kind, failure);
    try w.print("{s}{s}{s}\n", .{ marker_open, &fp, marker_close });
}

/// A comment for a failure that already has an issue.
pub fn comment_body(
    arena: std.mem.Allocator,
    report: *const Report,
) error{OutOfMemory}![]const u8 {
    const replay = try replay_line(arena, report.commit, report.failure);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("The fleet saw this failure again.\n\n") catch return error.OutOfMemory;
    write_failure(w, report, replay) catch return error.OutOfMemory;
    const body = try out.toOwnedSlice();
    assert(marker_of(body) == null);
    return body;
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
    try std.testing.expectEqual(@as(?u32, 100), batch.operations);
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

test "an auto round's summary says drawn operations; mixing it with a fixed one refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The runner's auto form (see report_failure in sim_cluster_main.zig): a failure carries profile and shape lines.
    const auto =
        \\seed 2: FAILED: a replica is not placed
        \\  step: convergence
        \\  profile: partitions
        \\  shape: operations=120 nodes=5 lease_ttl_ms=7000 replicas_pct=150
        \\  replay: zig-out/bin/sim_cluster 2 120 5 --profile=partitions
        \\sim-cluster: seeds 1..3, drawn operations: 1 of 3 failed
        \\
    ;
    const batch = try parse(arena, auto);
    try std.testing.expectEqual(@as(u64, 3), batch.seeds);
    try std.testing.expectEqual(@as(?u32, null), batch.operations);
    try std.testing.expectEqualStrings("convergence", batch.failures[0].step);
    const two = auto ++ "sim-cluster: seeds 4..5, drawn operations: 0 of 2 failed\n";
    try std.testing.expectEqual(@as(u64, 5), (try parse(arena, two)).seeds);
    const mixed = auto ++ "sim-cluster: seeds 4..5, 100 operations: 0 of 2 failed\n";
    try std.testing.expectError(error.BadLine, parse(arena, mixed));
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
    const report: Report = .{
        .kind = kind_sim_cluster,
        .commit = "abc123",
        .failure = batch.failures[0],
        .more = batch.failures[1..2],
    };
    const body = try issue_body(arena, &report);
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
    const report: Report = .{
        .kind = kind_sim_cluster,
        .commit = "def456",
        .failure = batch.failures[2],
        .more = &.{},
    };
    const text = try comment_body(arena, &report);
    try std.testing.expect(std.mem.indexOf(u8, text, "sim_cluster 7 100 0 --heal-at=61") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not shrunk") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Also failing") == null);
}

test "a round of several batches sums their seeds; a batch cut short refuses the round" {
    // Goal: run.sh feeds one round (every worker's output, one after another) to one ingest.
    // Method: two copies of the sample and a clean batch; then the same with the last cut.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const clean = "sim-cluster: seeds 50..59, 100 operations: 0 of 10 failed\n";
    const round = sample ++ clean ++ sample;
    const batch = try parse(arena, round);
    try std.testing.expectEqual(@as(u64, 30), batch.seeds);
    try std.testing.expectEqual(@as(usize, 6), batch.failures.len);
    const cut = sample ++ "seed 3: FAILED: x\n  step: end\n  replay: r\n";
    try std.testing.expectError(error.NoSummary, parse(arena, cut));
    const other_operations = sample ++ "sim-cluster: seeds 1..2, 60 operations: 0 of 2 failed\n";
    try std.testing.expectError(error.BadLine, parse(arena, other_operations));
    try std.testing.expectError(error.NoSummary, parse(arena, ""));
}

/// What run.sh writes for a seed whose replay crashed (ops/sim-fleet/run.sh, `record_crash`).
const crash_record =
    \\seed 77: CRASHED: index out of bounds: index 12, len 3
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 77 100 0
    \\sim-cluster: seeds 77..77, 100 operations: 1 of 1 failed
    \\
;

test "a crash is its own failure: digits elided, a crash title, and never a check's fingerprint" {
    // Goal: H3, a crash of the simulator is filed under its message and step. Method: parse the
    // record run.sh writes; compare with the same text as a check and with other digits.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, crash_record);
    try std.testing.expectEqual(@as(usize, 1), batch.failures.len);
    const crash = batch.failures[0];
    try std.testing.expect(crash.crash);
    try std.testing.expect(!crash.infra());
    try std.testing.expectEqualStrings("index out of bounds: index N, len N", crash.check);
    const other_index = try parse(arena, "seed 9: CRASHED: index out of bounds: " ++
        "index 40, len 7\n" ++
        "  step: healed\n  replay: r\nsim-cluster: seeds 9..9, 100 operations: 1 of 1 failed\n");
    const a = fingerprint(kind_sim_cluster, crash);
    try std.testing.expectEqualStrings(&a, &fingerprint(kind_sim_cluster, other_index.failures[0]));
    var as_check = crash;
    as_check.crash = false;
    try std.testing.expect(!std.mem.eql(u8, &a, &fingerprint(kind_sim_cluster, as_check)));
    const text = try title(arena, kind_sim_cluster, crash);
    try std.testing.expectEqualStrings(
        "sim-cluster: crash: index out of bounds: index N, len N (step: healed)",
        text,
    );
    const xs: [400]u8 = @splat('x');
    const long = try std.fmt.allocPrint(arena, "seed 1: CRASHED: {s}\n  step: end\n" ++
        "  replay: r\nsim-cluster: seeds 1..1, 1 operations: 1 of 1 failed\n", .{&xs});
    const cut = try parse(arena, long);
    const check_max: usize = constants.fleet_check_bytes_max;
    try std.testing.expectEqual(check_max, cut.failures[0].check.len);
}

test "a run that could not allocate its world is infrastructure, and its step parses" {
    // Goal: M7, `FAILED: out of memory` from `simulate` carries `step: setup` and is not a bug.
    // Method: the exact lines sim_cluster prints for it (sim_cluster.zig, `simulate`).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "seed 5: FAILED: out of memory\n  step: setup\n" ++
        "  replay: zig-out/bin/sim_cluster 5 100 0 --heal-at=70\n" ++
        "sim-cluster: seeds 1..9, 100 operations: 1 of 9 failed\n";
    const batch = try parse(arena_state.allocator(), text);
    try std.testing.expect(batch.failures[0].infra());
    try std.testing.expect(!batch.failures[0].crash);
    const empty_step = "seed 5: FAILED: out of memory\n  step: \n  replay: r\n" ++
        "sim-cluster: seeds 1..9, 100 operations: 1 of 9 failed\n";
    try std.testing.expectError(error.BadLine, parse(arena_state.allocator(), empty_step));
}

test "the marker hashes the kind of the run it reports" {
    // Goal: L2, the marker is the fingerprint `ingest` looks for, for any kind. Method: render
    // with another kind and compare with that kind's fingerprint.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, sample);
    const report: Report = .{
        .kind = "store-faults",
        .commit = "c",
        .failure = batch.failures[0],
        .more = &.{},
    };
    const body = try issue_body(arena, &report);
    const expected = fingerprint("store-faults", batch.failures[0]);
    try std.testing.expectEqualStrings(&expected, marker_of(body).?);
    const other = fingerprint(kind_sim_cluster, batch.failures[0]);
    try std.testing.expect(!std.mem.eql(u8, &other, marker_of(body).?));
}
