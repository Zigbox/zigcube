//! The simulation fleet's view of a failure: parse the runner's output, fingerprint each failure
//! and render the issue or comment that reports it (docs/briefs/c1-9.md). No network and no
//! files: `sim_fleet.zig` does those.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// The producers a round runs (ops/sim-fleet/README.md): `sim_cluster --seeds A..B <ops> --shrink`,
/// the same with `--c1`, and `sim_swarm --seeds A..B <ops> --shrink`. The kind is part of a
/// failure's fingerprint, so one check failing in two kinds is two issues.
pub const kind_sim_cluster = "sim-cluster";
pub const kind_sim_c1 = "sim-c1";
pub const kind_sim_swarm = "sim-swarm";
pub const kinds = [_][]const u8{ kind_sim_cluster, kind_sim_c1, kind_sim_swarm };

pub fn kind_known(kind: []const u8) bool {
    for (kinds) |known| {
        if (std.mem.eql(u8, known, kind)) return true;
    }
    return false;
}

/// The `zig build` step that installs the runner of `kind` (and so the replay's binary).
fn exe_step(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, kind_sim_swarm)) return "sim-swarm-exe";
    return "sim-cluster-exe";
}

/// The word before ": seeds A..B, N operations: F of T failed", the summary line of the runner.
/// `sim_cluster` prints it for plain and `--c1` runs alike.
fn summary_prefix(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, kind_sim_swarm)) return "sim-swarm: seeds ";
    return "sim-cluster: seeds ";
}

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
    operations: u32,
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

const SummaryLine = struct { seeds: u64, operations: u32 };

/// "sim-cluster: seeds A..B, N operations: F of T failed" (`sim-swarm:` for that kind) gives
/// (T, N).
fn parse_summary(kind: []const u8, line: []const u8) ?SummaryLine {
    const rest = after_prefix(line, summary_prefix(kind)) orelse return null;
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
pub fn parse(arena: std.mem.Allocator, kind: []const u8, text: []const u8) ParseError!Batch {
    assert(kind_known(kind));
    var failures: std.ArrayList(Failure) = .empty;
    var seeds: u64 = 0;
    var operations: ?u32 = null;
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
        } else if (parse_summary(kind, line)) |found| {
            // Batches of one round run the same operation count.
            if (operations) |known| if (known != found.operations) return error.BadLine;
            operations = found.operations;
            seeds += found.seeds;
            open = false;
        } else if (failures.items.len > 0) {
            try parse_detail(&failures.items[failures.items.len - 1], std.mem.trim(u8, line, " "));
        }
    }
    if (open) return error.NoSummary;
    const done = operations orelse return error.NoSummary;
    for (failures.items) |failure| {
        if (failure.step.len == 0) return error.BadLine;
        if (failure.replay.len == 0) return error.BadLine;
    }
    if (failures.items.len > seeds) return error.BadLine;
    return .{ .seeds = seeds, .operations = done, .failures = failures.items };
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
    kind: []const u8,
    commit: []const u8,
    failure: Failure,
) std.mem.Allocator.Error![]const u8 {
    assert(commit.len > 0);
    const replay = failure.shrunk_replay orelse failure.replay;
    assert(replay.len > 0);
    return std.fmt.allocPrint(
        arena,
        "git checkout {s} && zig build -Doptimize=ReleaseSafe {s} && {s}",
        .{ commit, exe_step(kind), replay },
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
    try out.print("- run: {s}\n- commit: `{s}`\n- seed: {d}\n", .{
        report.kind, report.commit, failure.seed,
    });
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
    const replay = try replay_line(arena, report.kind, report.commit, report.failure);
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
    const replay = try replay_line(arena, report.kind, report.commit, report.failure);
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
    const batch = try parse(arena_state.allocator(), kind_sim_cluster, sample);
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
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, cut));
    const no_step =
        \\seed 1: FAILED: x
        \\  replay: zig-out/bin/sim_cluster 1 100 0
        \\sim-cluster: seeds 1..1, 100 operations: 1 of 1 failed
    ;
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_cluster, no_step));
    const clean = "sim-cluster: seeds 5..9, 60 operations: 0 of 5 failed\n";
    const batch = try parse(arena, kind_sim_cluster, clean);
    try std.testing.expectEqual(@as(u64, 5), batch.seeds);
    try std.testing.expectEqual(@as(usize, 0), batch.failures.len);
}

test "the fingerprint ignores the seed, the commit and the shrink; the step changes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const batch = try parse(arena_state.allocator(), kind_sim_cluster, sample);
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
    const batch = try parse(arena, kind_sim_cluster, sample);
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
    const batch = try parse(arena, kind_sim_cluster, sample);
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
    const batch = try parse(arena, kind_sim_cluster, round);
    try std.testing.expectEqual(@as(u64, 30), batch.seeds);
    try std.testing.expectEqual(@as(usize, 6), batch.failures.len);
    const cut = sample ++ "seed 3: FAILED: x\n  step: end\n  replay: r\n";
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, cut));
    const other_operations = sample ++ "sim-cluster: seeds 1..2, 60 operations: 0 of 2 failed\n";
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_cluster, other_operations));
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, ""));
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
    const batch = try parse(arena, kind_sim_cluster, crash_record);
    try std.testing.expectEqual(@as(usize, 1), batch.failures.len);
    const crash = batch.failures[0];
    try std.testing.expect(crash.crash);
    try std.testing.expect(!crash.infra());
    try std.testing.expectEqualStrings("index out of bounds: index N, len N", crash.check);
    const other_text = "seed 9: CRASHED: index out of bounds: index 40, len 7\n" ++
        "  step: healed\n  replay: r\nsim-cluster: seeds 9..9, 100 operations: 1 of 1 failed\n";
    const other_index = try parse(arena, kind_sim_cluster, other_text);
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
    const cut = try parse(arena, kind_sim_cluster, long);
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
    const batch = try parse(arena_state.allocator(), kind_sim_cluster, text);
    try std.testing.expect(batch.failures[0].infra());
    try std.testing.expect(!batch.failures[0].crash);
    const empty_step = "seed 5: FAILED: out of memory\n  step: \n  replay: r\n" ++
        "sim-cluster: seeds 1..9, 100 operations: 1 of 9 failed\n";
    const arena = arena_state.allocator();
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_cluster, empty_step));
}

test "the marker hashes the kind of the run it reports" {
    // Goal: L2, the marker is the fingerprint `ingest` looks for, for any kind. Method: render
    // with another kind and compare with that kind's fingerprint.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, kind_sim_cluster, sample);
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

// Real outputs, captured from the teeth runners (`sim_c1_teeth_allocation --seeds 1..3 100 --c1
// --shrink`, `sim_swarm_teeth --seeds 1..6 100 --shrink`), and the crash records `run.sh` writes.
const c1_failing =
    \\seed 1: FAILED: I6: an allocation disagrees with the sum of its node's assignments
    \\  step: faults
    \\  replay: zig-out/bin/sim_cluster 1 100 0 --c1 --heal-at=60
    \\  shrunk to 3 operations
    \\  replay: zig-out/bin/sim_cluster 1 3 0 --c1 --heal-at=60
    \\seed 2: FAILED: I6: an allocation disagrees with the sum of its node's assignments
    \\  step: faults
    \\  replay: zig-out/bin/sim_cluster 2 100 0 --c1 --heal-at=60
    \\  shrunk to 7 operations
    \\  replay: zig-out/bin/sim_cluster 2 7 0 --c1 --heal-at=60
    \\sim-cluster: seeds 1..3, 100 operations: 2 of 3 failed
    \\
;

const swarm_failing =
    \\seed 1: FAILED: a chunk with wrong bytes was accepted
    \\  step: fetch
    \\  replay: zig-out/bin/sim_swarm 1 100
    \\  shrunk to 1 operations
    \\  replay: zig-out/bin/sim_swarm 1 1
    \\seed 2: FAILED: a chunk with wrong bytes was accepted
    \\  step: fetch
    \\  replay: zig-out/bin/sim_swarm 2 100
    \\  shrunk to 1 operations
    \\  replay: zig-out/bin/sim_swarm 2 1
    \\seed 4: FAILED: a chunk with wrong bytes was accepted
    \\  step: locality
    \\  replay: zig-out/bin/sim_swarm 4 100
    \\sim-swarm: seeds 1..6, 100 operations: 3 of 6 failed
    \\
;

const swarm_clean = "sim-swarm: seeds 1..20, 60 operations: 0 of 20 failed\n";
const c1_clean = "sim-cluster: seeds 1..8, 60 operations: 0 of 8 failed\n";

const swarm_crash =
    \\seed 7: CRASHED: reached unreachable code
    \\  step: run
    \\  replay: zig-out/bin/sim_swarm 7 100
    \\sim-swarm: seeds 7..7, 100 operations: 1 of 1 failed
    \\
;

const c1_crash =
    \\seed 7: CRASHED: index out of bounds: index 40, len 7
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 7 100 0 --c1
    \\sim-cluster: seeds 7..7, 100 operations: 1 of 1 failed
    \\
;

test "each kind's real output parses: failures, shrinks, clean runs and crashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c1 = try parse(arena, kind_sim_c1, c1_failing);
    try std.testing.expectEqual(@as(u64, 3), c1.seeds);
    try std.testing.expectEqual(@as(usize, 2), c1.failures.len);
    try std.testing.expectEqualStrings("faults", c1.failures[1].step);
    try std.testing.expectEqual(@as(?u32, 7), c1.failures[1].shrunk_operations);
    const swarm = try parse(arena, kind_sim_swarm, swarm_failing);
    try std.testing.expectEqual(@as(u64, 6), swarm.seeds);
    try std.testing.expectEqual(@as(usize, 3), swarm.failures.len);
    try std.testing.expectEqualStrings("locality", swarm.failures[2].step);
    try std.testing.expect(swarm.failures[2].shrunk_replay == null);
    try std.testing.expectEqual(@as(?u32, 1), swarm.failures[0].shrunk_operations);
    const clean = try parse(arena, kind_sim_swarm, swarm_clean);
    try std.testing.expectEqual(@as(u64, 20), clean.seeds);
    const c1_ok = try parse(arena, kind_sim_c1, c1_clean);
    try std.testing.expectEqual(@as(u64, 8), c1_ok.seeds);
    const swarm_crashed = try parse(arena, kind_sim_swarm, swarm_crash);
    try std.testing.expect(swarm_crashed.failures[0].crash);
    try std.testing.expectEqualStrings("run", swarm_crashed.failures[0].step);
    const c1_crashed = try parse(arena, kind_sim_c1, c1_crash);
    const crash_check = c1_crashed.failures[0].check;
    try std.testing.expectEqualStrings("index out of bounds: index N, len N", crash_check);
    // A kind reads only its own summary line: swarm text is no sim-cluster batch and back.
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, swarm_clean));
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_swarm, c1_clean));
}

test "one check failing in two kinds is two fingerprints, and one kind keeps one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cluster = try parse(arena, kind_sim_cluster, c1_failing);
    const c1 = try parse(arena, kind_sim_c1, c1_failing);
    const a = fingerprint(kind_sim_cluster, cluster.failures[0]);
    const b = fingerprint(kind_sim_c1, c1.failures[0]);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    // Seeds 1 and 2 failed alike in the same kind.
    try std.testing.expectEqualStrings(&b, &fingerprint(kind_sim_c1, c1.failures[1]));
    const swarm_crashed = try parse(arena, kind_sim_swarm, swarm_crash);
    var as_cluster = swarm_crashed.failures[0];
    as_cluster.step = "run";
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint(kind_sim_swarm, as_cluster),
        &fingerprint(kind_sim_cluster, as_cluster),
    ));
    const other = try parse(arena, kind_sim_c1, c1_crash);
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint(kind_sim_c1, other.failures[0]),
        &fingerprint(kind_sim_c1, c1.failures[0]),
    ));
}

test "the replay line builds the kind's own runner and replays the shrunk run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const swarm = try parse(arena, kind_sim_swarm, swarm_failing);
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-swarm-exe && " ++
            "zig-out/bin/sim_swarm 1 1",
        try replay_line(arena, kind_sim_swarm, "abc123", swarm.failures[0]),
    );
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-swarm-exe && " ++
            "zig-out/bin/sim_swarm 4 100",
        try replay_line(arena, kind_sim_swarm, "abc123", swarm.failures[2]),
    );
    const c1 = try parse(arena, kind_sim_c1, c1_failing);
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-cluster-exe && " ++
            "zig-out/bin/sim_cluster 2 7 0 --c1 --heal-at=60",
        try replay_line(arena, kind_sim_c1, "abc123", c1.failures[1]),
    );
}
