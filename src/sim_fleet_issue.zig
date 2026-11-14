//! The simulation fleet's view of a failure: parse the runner's output, fingerprint each failure
//! and render the issue or comment that reports it (docs/briefs/c1-9.md). No network and no
//! files: `sim_fleet.zig` does those.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const symptom_spec = @import("symptom.zig");

test {
    _ = symptom_spec; // its tests run with this file's
}

/// The producers a round runs (ops/sim-fleet/README.md): `sim_cluster --seeds A..B <ops> --shrink`,
/// the same with `--c1`, and `sim_swarm --seeds A..B <ops> --shrink`. The kind is part of a
/// failure's fingerprint, so one check failing in two kinds is two issues.
pub const kind_sim_cluster = "sim-cluster";
pub const kind_sim_c1 = "sim-c1";
pub const kind_sim_swarm = "sim-swarm";
/// The long soak, `sim_cluster <seed> soak` (src/sim_soak.zig): one seed for hours, its summary
/// `sim-cluster --soak: seeds N..N, K operations: F of 1 failed`. Not part of a round: run.sh
/// does not run it (ops/sim-fleet/soak.sh does).
pub const kind_sim_soak = "sim-soak";
/// Not a simulator: the teeth canary (`run.sh`, `canary_pick`). A batch of it is one fault-on
/// runner's run over fresh seeds, read with its simulator kind's parser and judged by
/// `canary_verdict`: a miss or a wrong symptom is a failure of this kind.
pub const kind_sim_canary = "sim-canary";
/// Not a simulator either: `zig build test-store-faults`, once a day (`run.sh`,
/// `store_faults_day`).
/// A "seed" is one run of the runner (a backend, or a failover mode); see `parse_store_faults`.
pub const kind_store_faults = "store-faults";
pub const kinds = [_][]const u8{
    kind_sim_cluster, kind_sim_c1, kind_sim_swarm, kind_sim_canary, kind_store_faults,
    kind_sim_soak,
};

comptime {
    // The state file refuses more kinds per day than this (sim_fleet_state.zig).
    assert(kinds.len <= constants.fleet_kinds_max);
}

pub fn kind_known(kind: []const u8) bool {
    for (kinds) |known| {
        if (std.mem.eql(u8, known, kind)) return true;
    }
    return false;
}

/// The `zig build` step that installs the runner of `kind` (and so the replay's binary).
fn exe_step(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, kind_sim_swarm)) return "sim-swarm-exe";
    if (std.mem.eql(u8, kind, kind_sim_canary)) return "sim-canary-exe";
    return "sim-cluster-exe";
}

/// The start of the summary line of the runner, "<name>: seeds A..B, N operations: F of T failed".
/// Each kind has a name of its own: `sim_cluster --c1` prints "sim-cluster --c1", so a range
/// that ran without `--c1` is refused for sim-c1 (it would be counted as covered) and the other
/// way round.
fn summary_prefix(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, kind_sim_swarm)) return "sim-swarm: seeds ";
    if (std.mem.eql(u8, kind, kind_sim_canary)) return "sim-canary: seeds ";
    if (std.mem.eql(u8, kind, kind_sim_c1)) return "sim-cluster --c1: seeds ";
    if (std.mem.eql(u8, kind, kind_sim_soak)) return "sim-cluster --soak: seeds ";
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
    /// A canary's verdict on a whole run (`canary_verdict`): it covers seeds `seed..range_last`,
    /// not one seed, and nothing was shrunk.
    range_last: ?u64 = null,
    /// A canary that failed with the wrong symptom: the check the first failing seed broke.
    observed: ?[]const u8 = null,
    /// The run's last operations before the failure (`  trace: op N at T ms: ...`, of the shrunk
    /// run when it shrank) and a soak check's numbers (`  soak: ...`): the lines as printed, one
    /// span of the input. Empty when the runner printed none (a crash, a swarm run, a canary).
    trace: []const u8 = "",

    /// A run that never started is the host's trouble (see `step_setup`). A crash is never: it
    /// is a bug wherever it happened, and run.sh records a crash that traced no step in `setup`.
    pub fn infra(failure: *const Failure) bool {
        return !failure.crash and std.mem.eql(u8, failure.step, step_setup);
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

const SummaryLine = struct { seeds: u64, operations: ?u32, failed: u64 };

/// "sim-cluster: seeds A..B, N operations: F of T failed" (`sim-swarm:` for that kind) gives
/// (T, N, F); the `auto` form, "..., drawn operations: F of T failed", gives (T, null, F).
fn parse_summary(kind: []const u8, line: []const u8) ?SummaryLine {
    const rest = after_prefix(line, summary_prefix(kind)) orelse return null;
    const comma = std.mem.indexOf(u8, rest, ", ") orelse return null;
    const dots = std.mem.indexOf(u8, rest[0..comma], "..") orelse return null;
    const first = std.fmt.parseInt(u64, rest[0..dots], 10) catch return null;
    const last = std.fmt.parseInt(u64, rest[dots + 2 .. comma], 10) catch return null;
    if (last < first) return null;
    const tail = rest[comma + 2 ..];
    var operations: ?u32 = null;
    var counts: []const u8 = undefined;
    if (after_prefix(tail, "drawn operations: ")) |drawn| {
        counts = drawn;
    } else {
        const space = std.mem.indexOfScalar(u8, tail, ' ') orelse return null;
        operations = std.fmt.parseInt(u32, tail[0..space], 10) catch return null;
        counts = after_prefix(tail[space..], " operations: ") orelse return null;
    }
    const of = std.mem.indexOf(u8, counts, " of ") orelse return null;
    const failed = std.fmt.parseInt(u64, counts[0..of], 10) catch return null;
    const total_text = counts[of + 4 ..];
    const total_end = std.mem.indexOfScalar(u8, total_text, ' ') orelse return null;
    const total = std.fmt.parseInt(u64, total_text[0..total_end], 10) catch return null;
    if (!std.mem.eql(u8, total_text[total_end..], " failed")) return null;
    if (total != last - first + 1) return null;
    if (failed > total) return null;
    return .{ .seeds = total, .operations = operations, .failed = failed };
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
    if (std.mem.eql(u8, kind, kind_store_faults)) return parse_store_faults(arena, text);
    var failures: std.ArrayList(Failure) = .empty;
    var seeds: u64 = 0;
    var operations: ?u32 = null;
    var summaries: u32 = 0; // Summary lines seen; the first fixes whether the round is drawn.
    var open = false; // A failure or nothing at all since the last summary.
    var batch_start: usize = 0; // Where the current batch's failures begin.
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
            if (summaries > 0 and operations != found.operations) return error.BadLine;
            operations = found.operations;
            summaries += 1;
            // The summary's own count of failures is the check on what was read before it.
            if (failures.items.len - batch_start != found.failed) return error.BadLine;
            batch_start = failures.items.len;
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

/// One run of `store_faults` being read: its header's seed and backend, the step it is filed
/// under (`sqlite`, `postgres`, `failover-sync`, `failover-async`) and the first thing it said
/// was wrong.
const StoreRun = struct { seed: u64, backend: []const u8, step: []const u8, check: []const u8 };

/// `backend=B seed=N (replay: ...)`, the first line of every run.
fn parse_store_header(line: []const u8) ?struct { backend: []const u8, seed: u64 } {
    const rest = after_prefix(line, "backend=") orelse return null;
    const space = std.mem.indexOf(u8, rest, " seed=") orelse return null;
    const tail = rest[space + " seed=".len ..];
    const end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const seed = std.fmt.parseInt(u64, tail[0..end], 10) catch return null;
    if (space == 0) return null;
    return .{ .backend = rest[0..space], .seed = seed };
}

/// The name of the checker's verdict in `.{ .failed = .{ .kind = .lost_write, ... } }`.
fn store_verdict_kind(text: []const u8) ?[]const u8 {
    const marker = ".kind = .";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    const from = at + marker.len;
    var end = from;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    if (end == from) return null;
    return text[from..end];
}

/// What a diagnostic line of a run says is wrong, or null if the line is not one: the checker's
/// verdict by stage (`history: lost_write`, `watch: gap`), a client thread that stopped
/// (`client thread stopped: BackendFailed`), a runner's `FAILED: ...`, a failover's
/// `failover sync: FAILED: ...`, with digits elided so one failure is one fingerprint. Each
/// cause is a check of its own: the history checker, the watch checker and a client thread
/// failing are different bugs, so they must never share a fingerprint.
fn store_check(arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}!?[]const u8 {
    for ([_][]const u8{ "history: ", "compaction: ", "watch: " }) |stage| {
        if (!std.mem.startsWith(u8, line, stage)) continue;
        const name = store_verdict_kind(line) orelse return try normalize_crash(arena, line);
        return try std.fmt.allocPrint(arena, "{s}{s}", .{ stage, name });
    }
    if (after_prefix(line, "a client thread stopped: ")) |name| {
        return try std.fmt.allocPrint(arena, "client thread stopped: {s}", .{
            try normalize_crash(arena, name),
        });
    }
    if (after_prefix(line, "FAILED: ")) |text| return try normalize_crash(arena, text);
    if (after_prefix(line, "failover ")) |rest| {
        const at = std.mem.indexOf(u8, rest, ": FAILED: ") orelse return null;
        return try normalize_crash(arena, rest[at + ": FAILED: ".len ..]);
    }
    return null;
}

/// The command that runs exactly the run that failed, and nothing else: its backend, its seed
/// and `-Dstore-faults-only` for its part. Without the part, a replay would also run the
/// conformance suite and the parts before it with the same seed, any of which can fail first
/// and stop the step before the failing part is reached. Postgres's own run needs the database
/// the fleet ran it on (`zig build pg-up`); a failover run makes its own pair.
fn store_replay(arena: std.mem.Allocator, run: StoreRun) error{OutOfMemory}![]const u8 {
    assert(run.step.len > 0);
    assert(run.backend.len > 0);
    const part = after_prefix(run.step, "failover-") orelse "faults";
    var database: []const u8 = "";
    if (std.mem.eql(u8, part, "faults")) {
        if (std.mem.eql(u8, run.backend, "postgres")) database = "zig build pg-up && ";
    }
    return std.fmt.allocPrint(
        arena,
        "{s}zig build test-store-faults -Dbackend={s} -Dseed={d} -Dstore-faults-only={s}",
        .{ database, run.backend, run.seed, part },
    );
}

/// Reads the output of `zig build test-store-faults` for one backend, or several concatenated
/// (the Postgres run and its two failover runs, then the SQLite run). Each run prints
/// `store-faults: backend=B seed=N ...` first and ends in `PASS`, `FAIL seed=N`, `ERROR name
/// seed=N`, or for a failover `failover M: PASS`/`FAILED`. A run is one "seed" of the round,
/// filed under the step `sqlite`, `postgres`, `failover-sync` or `failover-async`, with the
/// verdict it earned as the check. A run that died (run.sh records it as `seed N: CRASHED:`
/// with `step:` and `replay:` lines, as for a simulator, and `setup` when no run started) ends
/// the run it follows; a run with no end is a round cut short, and is refused.
fn parse_store_faults(arena: std.mem.Allocator, text: []const u8) ParseError!Batch {
    var failures: std.ArrayList(Failure) = .empty;
    var runs: u64 = 0;
    var open: ?StoreRun = null;
    var crashed = false; // The last failure is a crash record whose details may follow.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r");
        line = after_prefix(line, "store-faults: ") orelse line;
        if (parse_store_header(line)) |header| {
            if (open != null) return error.BadLine;
            runs += 1;
            open = .{
                .seed = header.seed,
                .backend = header.backend,
                .step = header.backend,
                .check = "",
            };
            crashed = false;
        } else if (parse_seed_line(line)) |found| {
            if (failures.items.len == constants.fleet_round_failures_max) {
                return error.TooManyFailures;
            }
            if (open == null) runs += 1;
            const run: StoreRun = open orelse
                .{ .seed = found.seed, .backend = "", .step = "", .check = "" };
            try failures.append(arena, .{
                .seed = found.seed,
                .check = try normalize_crash(arena, found.check),
                .crash = found.crash,
                .step = run.step,
                .replay = if (open != null) try store_replay(arena, run) else "",
            });
            open = null;
            crashed = true; // Its detail lines follow, crash or not.
        } else if (crashed) {
            const last = &failures.items[failures.items.len - 1];
            try parse_crash_detail(last, std.mem.trim(u8, line, " "));
        } else if (open) |*run| {
            if (try store_run_line(arena, &failures, run, line)) open = null;
        } else if (std.mem.eql(u8, line, "PASS") or std.mem.startsWith(u8, line, "FAIL seed=")) {
            return error.BadLine; // A verdict with no run before it.
        }
    }
    if (open != null) return error.NoSummary;
    if (runs == 0) return error.NoSummary;
    for (failures.items) |failure| {
        if (failure.step.len == 0 or failure.replay.len == 0) return error.BadLine;
    }
    return .{ .seeds = runs, .operations = null, .failures = failures.items };
}

/// A crash record's `step:` and `replay:` lines replace what the run's header gave.
fn parse_crash_detail(failure: *Failure, line: []const u8) ParseError!void {
    if (after_prefix(line, "step: ")) |step| {
        if (step.len == 0) return error.BadLine;
        failure.step = step;
    } else if (after_prefix(line, "replay: ")) |replay| {
        failure.replay = replay;
    }
}

/// One line inside an open run. Returns true when the line ended it.
fn store_run_line(
    arena: std.mem.Allocator,
    failures: *std.ArrayList(Failure),
    run: *StoreRun,
    line: []const u8,
) ParseError!bool {
    if (after_prefix(line, "failover run: ")) |mode| {
        const word = mode[0 .. std.mem.indexOfScalar(u8, mode, ' ') orelse mode.len];
        run.step = try std.fmt.allocPrint(arena, "failover-{s}", .{word});
    } else if (try store_check(arena, line)) |check| {
        if (run.check.len == 0) run.check = check;
    } else if (std.mem.eql(u8, line, "PASS") or std.mem.startsWith(u8, line, "failover ") and
        std.mem.indexOf(u8, line, ": PASS") != null)
    {
        return true;
    } else if (std.mem.startsWith(u8, line, "FAIL seed=") or
        std.mem.startsWith(u8, line, "ERROR "))
    {
        if (failures.items.len == constants.fleet_round_failures_max) return error.TooManyFailures;
        if (run.check.len == 0) {
            run.check = if (after_prefix(line, "ERROR ")) |rest|
                try std.fmt.allocPrint(arena, "error: {s}", .{
                    rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len],
                })
            else
                "the run failed";
        }
        try failures.append(arena, .{
            .seed = run.seed,
            .check = run.check,
            .step = run.step,
            .replay = try store_replay(arena, run.*),
        });
        return true;
    }
    return false;
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
    } else if (std.mem.startsWith(u8, line, "trace: ") or std.mem.startsWith(u8, line, "soak: ")) {
        failure.trace = if (failure.trace.len == 0) line else span(failure.trace, line);
    } else if (after_prefix(line, "shrunk to ")) |rest| {
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadLine;
        failure.shrunk_operations = std.fmt.parseInt(u32, rest[0..space], 10) catch
            return error.BadLine;
    }
}

/// From the start of `first` to the end of `last`, two lines of the same input text.
fn span(first: []const u8, last: []const u8) []const u8 {
    const start = @intFromPtr(first.ptr);
    const end = @intFromPtr(last.ptr) + last.len;
    assert(end >= start + first.len);
    return first.ptr[0 .. end - start];
}

/// A teeth canary's run (`sim_fleet ingest --canary`): the fault-on runner, the simulator kind
/// whose parser reads its output, the seeds it ran (`auto` operations, `--profile=auto`) and the
/// text a caught failure's check starts with (null: any check).
pub const Canary = struct {
    runner: []const u8,
    kind: []const u8,
    first: u64,
    last: u64,
    symptom: ?[]const u8,
};

pub const step_canary = "canary";
pub const step_canary_symptom = "canary-symptom";

/// `crashed`: no seed ran to its end (each crashed or could not start), so nothing was judged;
/// the crashes are filed.
/// `not_run`: no seed could start (the host's trouble, step `setup`): counted, never filed, and
/// run.sh runs the canary again.
pub const Verdict = enum { caught, missed, wrong_symptom, crashed, not_run };

/// What the canary's run says, and what of it is filed under `kind_sim_canary`.
pub const Judged = struct { verdict: Verdict, batch: Batch };

/// Judges a canary's parsed run. Its checks that failed are the fault being caught, so they are
/// not filed; its crashes and seeds that could not start are filed as they are (crashes under
/// the canary's own fingerprint). No seed failing a check is a miss: the fleet has stopped
/// detecting, unless no seed ran to its end. Seeds that failed, but none with the symptom, are a
/// wrong symptom: the check meant
/// to fire did not. Each is one failure at a step of its own, so the two never share an issue.
/// Every replay names the runner, which prints its simulator's name.
pub fn canary_verdict(
    arena: std.mem.Allocator,
    canary: Canary,
    batch: Batch,
) error{OutOfMemory}!Judged {
    assert(kind_known(canary.kind));
    assert(!std.mem.eql(u8, canary.kind, kind_sim_canary));
    assert(canary.first <= canary.last);
    var kept: std.ArrayList(Failure) = .empty;
    var checks: u64 = 0;
    var crashes: u64 = 0;
    var first_check: ?Failure = null;
    var symptom_seen = false;
    for (batch.failures) |failure| {
        var own = failure;
        own.replay = try runner_replay(arena, canary.runner, failure.replay);
        if (failure.shrunk_replay) |shrunk| {
            own.shrunk_replay = try runner_replay(arena, canary.runner, shrunk);
        }
        if (failure.crash or failure.infra()) {
            if (failure.crash) crashes += 1;
            try kept.append(arena, own);
            continue;
        }
        checks += 1;
        if (first_check == null) first_check = own;
        const symptom = canary.symptom orelse "";
        if (symptom.len == 0 or symptom_spec.matches(failure.check, symptom)) symptom_seen = true;
    }
    // Seeds that ran to their end: every seed but those kept above.
    const ran = batch.seeds - kept.items.len;
    const verdict: Verdict = if (checks > 0)
        (if (symptom_seen) .caught else .wrong_symptom)
    else if (ran > 0) .missed else if (crashes > 0) .crashed else .not_run;
    switch (verdict) {
        .caught, .crashed, .not_run => {},
        .missed => try kept.append(arena, .{
            .seed = canary.first,
            .range_last = canary.last,
            .check = try std.fmt.allocPrint(
                arena,
                "the fleet has stopped detecting: {s} failed no seed",
                .{canary.runner},
            ),
            .step = step_canary,
            .replay = try canary_replay(arena, canary),
        }),
        .wrong_symptom => {
            const seen = first_check.?;
            try kept.append(arena, .{
                .seed = seen.seed,
                .check = try std.fmt.allocPrint(
                    arena,
                    "{s} failed, but never with \"{s}\"",
                    .{ canary.runner, canary.symptom.? },
                ),
                .step = step_canary_symptom,
                .replay = seen.shrunk_replay orelse seen.replay,
                .observed = seen.check,
            });
        },
    }
    assert(kept.items.len <= batch.failures.len + 1);
    return .{
        .verdict = verdict,
        .batch = .{ .seeds = batch.seeds, .operations = batch.operations, .failures = kept.items },
    };
}

/// The command that runs the canary's whole range again.
fn canary_replay(arena: std.mem.Allocator, canary: Canary) error{OutOfMemory}![]const u8 {
    const c1: []const u8 = if (std.mem.eql(u8, canary.kind, kind_sim_c1)) " --c1" else "";
    return std.fmt.allocPrint(
        arena,
        "zig-out/bin/{s} --seeds {d}..{d} auto --profile=auto{s}",
        .{ canary.runner, canary.first, canary.last, c1 },
    );
}

/// A replay line with the simulator's name (which a fault-on runner prints, being built from the
/// same main) replaced by the runner's, so the replay runs with the fault on.
fn runner_replay(
    arena: std.mem.Allocator,
    runner: []const u8,
    replay: []const u8,
) error{OutOfMemory}![]const u8 {
    for ([_][]const u8{ "zig-out/bin/sim_cluster ", "zig-out/bin/sim_swarm " }) |simulator| {
        if (after_prefix(replay, simulator)) |rest| {
            return std.fmt.allocPrint(arena, "zig-out/bin/{s} {s}", .{ runner, rest });
        }
    }
    return replay;
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
    if (std.mem.eql(u8, kind, kind_store_faults)) {
        return std.fmt.allocPrint(arena, "git checkout {s} && {s}", .{ commit, replay });
    }
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
    try out.print("- run: {s}\n- commit: `{s}`\n", .{ report.kind, report.commit });
    if (failure.range_last) |last| {
        try out.print("- seeds: {d}..{d}, each with its own drawn operations and profile\n", .{
            failure.seed, last,
        });
    } else {
        try out.print("- seed: {d}\n", .{failure.seed});
    }
    if (failure.observed) |observed| try out.print("- failed instead with: {s}\n", .{observed});
    // A canary's whole run (`range_last`) has no operation count and nothing shrunk.
    if (failure.range_last == null and !std.mem.eql(u8, report.kind, kind_store_faults)) {
        try write_operations(out, failure);
    }
    try out.print("\nReplay:\n\n```\n{s}\n```\n", .{replay});
    try write_trace(out, failure.trace);
    if (report.more.len > 0) {
        try out.writeAll("\nAlso failing this way in the same round: seeds ");
        try write_seeds(out, report.more);
        try out.writeAll(".\n");
    }
}

/// The trace under the replay, folded: its lines unindented, at most `trace_lines_max` of them
/// (the runner prints 24 operations and a soak line).
fn write_trace(out: *std.Io.Writer, trace: []const u8) std.Io.Writer.Error!void {
    if (trace.len == 0) return;
    try out.writeAll("\n<details><summary>Trace: the last operations before the failure" ++
        "</summary>\n\n```\n");
    var lines = std.mem.splitScalar(u8, trace, '\n');
    var written: u32 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (written == trace_lines_max) {
            try out.writeAll("(cut)\n");
            break;
        }
        try out.print("{s}\n", .{line[0..@min(line.len, trace_line_bytes_max)]});
        written += 1;
    }
    try out.writeAll("```\n\n</details>\n");
}

const trace_lines_max: u32 = 32;
const trace_line_bytes_max: usize = 200;

fn write_operations(out: *std.Io.Writer, failure: Failure) std.Io.Writer.Error!void {
    assert(failure.range_last == null);
    if (failure.crash) {
        try out.writeAll("- operations: not shrunk (the simulator crashed)\n");
    } else if (failure.shrunk_operations) |shrunk| {
        try out.print("- operations: shrunk to {d}\n", .{shrunk});
    } else {
        try out.writeAll("- operations: not shrunk\n");
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
    if (std.mem.eql(u8, report.kind, kind_sim_canary)) {
        try w.writeAll("This is the fleet's teeth canary: the runner is built with a test-only ");
        try w.writeAll("fault on, and the fleet must catch it (ops/sim-fleet/README.md).\n\n");
    }
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

test "an auto round's summary says drawn operations; mixing it with a fixed one refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Real output (src/testdata/sim_cluster_drawn.txt): `sim_teeth --seeds 1..3 auto
    // --profile=auto` (the teeth fault makes every seed fail; the format is `sim_cluster`'s).
    const auto = @embedFile("testdata/sim_cluster_drawn.txt");
    const batch = try parse(arena, kind_sim_cluster, auto);
    try std.testing.expectEqual(@as(u64, 3), batch.seeds);
    try std.testing.expectEqual(@as(?u32, null), batch.operations);
    try std.testing.expectEqual(@as(usize, 3), batch.failures.len);
    try std.testing.expectEqualStrings("faults", batch.failures[0].step);
    try std.testing.expect(
        std.mem.indexOf(u8, batch.failures[1].replay, "--profile=skew") != null,
    );
    // The c1 run names itself in the drawn summary too, and a plain run's is refused as c1.
    const c1 = try std.mem.replaceOwned(u8, arena, auto, "sim-cluster:", "sim-cluster --c1:");
    try std.testing.expectEqual(@as(u64, 3), (try parse(arena, kind_sim_c1, c1)).seeds);
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_c1, auto));
    const two = auto ++ "sim-cluster: seeds 4..5, drawn operations: 0 of 2 failed\n";
    try std.testing.expectEqual(@as(u64, 5), (try parse(arena, kind_sim_cluster, two)).seeds);
    const mixed = auto ++ "sim-cluster: seeds 4..5, 100 operations: 0 of 2 failed\n";
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_cluster, mixed));
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
    // A crash before the first traced step: run.sh's crash_record names the step `setup`.
    const crashed = "seed 5: CRASHED: reached unreachable code\n  step: setup\n  replay: r\n" ++
        "sim-cluster: seeds 5..5, 100 operations: 1 of 1 failed\n";
    const crash_batch = try parse(arena, kind_sim_cluster, crashed);
    try std.testing.expect(crash_batch.failures[0].crash);
    try std.testing.expect(!crash_batch.failures[0].infra());
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

// Real outputs, captured on 2026-11-04 from `sim_c1_teeth_allocation --seeds 1..3 100 --c1
// --shrink` and `sim_swarm_teeth --seeds 1..6 100 --shrink` (built from this commit), and clean
// runs of `sim_cluster --c1`, `sim_cluster` and `sim_swarm`.
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
    \\seed 3: FAILED: I6: an allocation disagrees with the sum of its node's assignments
    \\  step: faults
    \\  replay: zig-out/bin/sim_cluster 3 100 0 --c1 --heal-at=65
    \\  shrunk to 7 operations
    \\  replay: zig-out/bin/sim_cluster 3 7 0 --c1 --heal-at=65
    \\sim-cluster --c1: seeds 1..3, 100 operations: 3 of 3 failed
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
    \\  step: fetch
    \\  replay: zig-out/bin/sim_swarm 4 100
    \\  shrunk to 1 operations
    \\  replay: zig-out/bin/sim_swarm 4 1
    \\seed 5: FAILED: a chunk with wrong bytes was accepted
    \\  step: fetch
    \\  replay: zig-out/bin/sim_swarm 5 100
    \\  shrunk to 1 operations
    \\  replay: zig-out/bin/sim_swarm 5 1
    \\seed 6: FAILED: a chunk with wrong bytes was accepted
    \\  step: fetch
    \\  replay: zig-out/bin/sim_swarm 6 100
    \\  shrunk to 1 operations
    \\  replay: zig-out/bin/sim_swarm 6 1
    \\sim-swarm: seeds 1..6, 100 operations: 5 of 6 failed
    \\
;

// Hand-written (no teeth runner fails at the locality step): an unshrunk swarm failure.
const swarm_unshrunk =
    \\seed 4: FAILED: a locality estimate was wrong
    \\  step: locality
    \\  replay: zig-out/bin/sim_swarm 4 100
    \\sim-swarm: seeds 1..6, 100 operations: 1 of 6 failed
    \\
;

const swarm_clean = "sim-swarm: seeds 1..20, 60 operations: 0 of 20 failed\n";
const c1_clean = "sim-cluster --c1: seeds 1..8, 60 operations: 0 of 8 failed\n";
const plain_clean = "sim-cluster: seeds 1..8, 60 operations: 0 of 8 failed\n";

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
    \\sim-cluster --c1: seeds 7..7, 100 operations: 1 of 1 failed
    \\
;

test "each kind's real output parses: failures, shrinks, clean runs and crashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c1 = try parse(arena, kind_sim_c1, c1_failing);
    try std.testing.expectEqual(@as(u64, 3), c1.seeds);
    try std.testing.expectEqual(@as(usize, 3), c1.failures.len);
    try std.testing.expectEqualStrings("faults", c1.failures[1].step);
    try std.testing.expectEqual(@as(?u32, 7), c1.failures[1].shrunk_operations);
    const swarm = try parse(arena, kind_sim_swarm, swarm_failing);
    try std.testing.expectEqual(@as(u64, 6), swarm.seeds);
    try std.testing.expectEqual(@as(usize, 5), swarm.failures.len);
    const unshrunk = try parse(arena, kind_sim_swarm, swarm_unshrunk);
    try std.testing.expectEqualStrings("locality", unshrunk.failures[0].step);
    try std.testing.expect(unshrunk.failures[0].shrunk_replay == null);
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
    // A plain range is never sim-c1 (a missing --c1 would count as covered), nor the reverse.
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_c1, plain_clean));
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, c1_clean));
    const plain = try parse(arena, kind_sim_cluster, plain_clean);
    try std.testing.expectEqual(@as(u64, 8), plain.seeds);
}

test "a summary's failure count must match the seed records before it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Real swarm output says 5 of 6; lose a record (or claim fewer) and the round is refused.
    const lost = std.mem.replaceOwned(u8, arena, swarm_failing, "5 of 6 failed", "4 of 6 failed");
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_swarm, try lost));
    const more = std.mem.replaceOwned(u8, arena, swarm_failing, "5 of 6 failed", "6 of 6 failed");
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_swarm, try more));
    // A clean summary that follows a failure record of its own batch is a mismatch too.
    const stray = "seed 9: FAILED: x\n  step: end\n  replay: r\n" ++ swarm_clean;
    try std.testing.expectError(error.BadLine, parse(arena, kind_sim_swarm, stray));
    // The total must be the range's size.
    const wrong_total = "sim-swarm: seeds 1..20, 60 operations: 0 of 19 failed\n";
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_swarm, wrong_total));
}

test "one check failing in two kinds is two fingerprints, and one kind keeps one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain_text = try std.mem.replaceOwned(u8, arena, c1_failing, " --c1: seeds", ": seeds");
    const cluster = try parse(arena, kind_sim_cluster, plain_text);
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
    const unshrunk = try parse(arena, kind_sim_swarm, swarm_unshrunk);
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-swarm-exe && " ++
            "zig-out/bin/sim_swarm 1 1",
        try replay_line(arena, kind_sim_swarm, "abc123", swarm.failures[0]),
    );
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-swarm-exe && " ++
            "zig-out/bin/sim_swarm 4 100",
        try replay_line(arena, kind_sim_swarm, "abc123", unshrunk.failures[0]),
    );
    const c1 = try parse(arena, kind_sim_c1, c1_failing);
    try std.testing.expectEqualStrings(
        "git checkout abc123 && zig build -Doptimize=ReleaseSafe sim-cluster-exe && " ++
            "zig-out/bin/sim_cluster 2 7 0 --c1 --heal-at=60",
        try replay_line(arena, kind_sim_c1, "abc123", c1.failures[1]),
    );
}

// Real output of `store_faults` (sqlite, `--mutate drop_ack` and `stale_history`), trimmed of its
// count lines; the failover lines are as src/store_failover.zig prints them.
const store_clean =
    \\store-faults: backend=postgres seed=11 (replay: -Dseed=11)
    \\store-faults: calls=1000 acked=990 failed=3 unknown=7 (applied=2 absent=5) log_events=9
    \\store-faults: PASS
    \\store-faults: backend=postgres seed=11 (replay: -Dseed=11)
    \\store-faults: failover run: sync standby
    \\store-faults: failover sync: held at revision 12; the server remembers 12
    \\store-faults: failover sync: PASS: no acknowledged write lost
    \\store-faults: backend=postgres seed=11 (replay: -Dseed=11)
    \\store-faults: failover run: async standby
    \\store-faults: failover async: PASS: the promoted store is at 40
    \\store-faults: backend=sqlite seed=12 (replay: -Dseed=12)
    \\store-faults: sqlite: no proxy applies; history checker only, no faults
    \\store-faults: PASS
    \\
;
const store_failing =
    \\store-faults: backend=sqlite seed=587643522279407410 (replay: -Dseed=587643522279407410)
    \\store-faults: sqlite: no proxy applies; history checker only, no faults
    \\store-faults: history: .{ .failed = .{ .kind = .lost_write, .revision = 1099511627777,
    \\ .key = 0, .entry = 8 } }
    \\store-faults: FAIL seed=587643522279407410 (replay: -Dseed=587643522279407410)
    \\store-faults: backend=postgres seed=7 (replay: -Dseed=7)
    \\store-faults: failover run: async standby
    \\store-faults: failover async: FAILED: the server did not halt, ZC-E0215 missing after 31 s
    \\store-faults: failover async: the server's logs are in /tmp/x
    \\store-faults: FAIL seed=7 (replay: -Dseed=7)
    \\
;

test "store-faults output parses: clean runs count, failures are filed under their run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const clean = try parse(arena, kind_store_faults, store_clean);
    try std.testing.expectEqual(@as(u64, 4), clean.seeds);
    try std.testing.expectEqual(@as(usize, 0), clean.failures.len);
    try std.testing.expectEqual(@as(?u32, null), clean.operations);
    const bad = try parse(arena, kind_store_faults, store_failing);
    try std.testing.expectEqual(@as(u64, 2), bad.seeds);
    try std.testing.expectEqual(@as(usize, 2), bad.failures.len);
    try std.testing.expectEqualStrings("history: lost_write", bad.failures[0].check);
    try std.testing.expectEqualStrings("sqlite", bad.failures[0].step);
    try std.testing.expectEqualStrings(
        "the server did not halt, ZC-EN missing after N s",
        bad.failures[1].check,
    );
    try std.testing.expectEqualStrings("failover-async", bad.failures[1].step);
    try std.testing.expectEqualStrings(
        "git checkout abc && zig build test-store-faults -Dbackend=postgres -Dseed=7 " ++
            "-Dstore-faults-only=async",
        try replay_line(arena, kind_store_faults, "abc", bad.failures[1]),
    );
    const t = try title(arena, kind_store_faults, bad.failures[0]);
    try std.testing.expectEqualStrings("store-faults: history: lost_write (step: sqlite)", t);
}

test "store-faults: errors, crash records and cut-short output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const errored_text =
        "store-faults: backend=sqlite seed=3 (replay: -Dseed=3)\n" ++
        "store-faults: ERROR OutOfMemory seed=3\n";
    const errored = try parse(arena, kind_store_faults, errored_text);
    try std.testing.expectEqualStrings("error: OutOfMemory", errored.failures[0].check);
    // A run that died after its header: the crash record ends it, once.
    const died_text =
        "store-faults: backend=postgres seed=3 (replay: -Dseed=3)\n" ++
        "seed 3: CRASHED: killed by signal 9\n  step: postgres\n  replay: zig build t\n";
    const died = try parse(arena, kind_store_faults, died_text);
    try std.testing.expectEqual(@as(u64, 1), died.seeds);
    try std.testing.expect(died.failures[0].crash);
    // No run started (no database, no build): a record of its own, counted and never filed.
    const none_text =
        "seed 0: FAILED: no run started: exit 1\n  step: setup\n  replay: zig build t\n";
    const none = try parse(arena, kind_store_faults, none_text);
    try std.testing.expectEqual(@as(u64, 1), none.seeds);
    try std.testing.expect(none.failures[0].infra());
    // Cut short: a header with no end, two headers in a row, or no run at all is refused.
    const header = "store-faults: backend=sqlite seed=3 (replay: -Dseed=3)\n";
    try std.testing.expectError(error.NoSummary, parse(arena, kind_store_faults, header));
    try std.testing.expectError(error.BadLine, parse(arena, kind_store_faults, header ++ header));
    try std.testing.expectError(error.NoSummary, parse(arena, kind_store_faults, ""));
    try std.testing.expectError(error.BadLine, parse(arena, kind_store_faults, "PASS\n"));
}

test "store-faults fingerprints hash the kind and ignore the seed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try parse(arena, kind_store_faults, store_failing);
    var other = bad.failures[0];
    other.seed += 1;
    try std.testing.expectEqualSlices(
        u8,
        &fingerprint(kind_store_faults, bad.failures[0]),
        &fingerprint(kind_store_faults, other),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint(kind_store_faults, bad.failures[0]),
        &fingerprint(kind_sim_cluster, bad.failures[0]),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint(kind_store_faults, bad.failures[0]),
        &fingerprint(kind_store_faults, bad.failures[1]),
    ));
}

test "store-faults replays run exactly the failing part" {
    // Goal: every replay line names the part that failed, so that it runs that part alone with
    // its own seed. Method: a SQLite failure, a Postgres history failure, a run that died during
    // a failover run, and run.sh's record of a failed conformance run, each parsed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try parse(arena, kind_store_faults, store_failing);
    try std.testing.expectEqualStrings(
        "zig build test-store-faults -Dbackend=sqlite -Dseed=587643522279407410 " ++
            "-Dstore-faults-only=faults",
        bad.failures[0].replay,
    );
    const postgres_text =
        "store-faults: backend=postgres seed=8 (replay: -Dseed=8)\n" ++
        "store-faults: history: .{ .failed = .{ .kind = .lost_write, .revision = 3 } }\n" ++
        "store-faults: FAIL seed=8 (replay: -Dseed=8)\n";
    const postgres = try parse(arena, kind_store_faults, postgres_text);
    try std.testing.expectEqualStrings(
        "zig build pg-up && zig build test-store-faults -Dbackend=postgres -Dseed=8 " ++
            "-Dstore-faults-only=faults",
        postgres.failures[0].replay,
    );
    // A run that died in its failover: run.sh's crash record has no step, so the run's own
    // step and replay stand.
    const died_text =
        "store-faults: backend=postgres seed=9 (replay: -Dseed=9)\n" ++
        "store-faults: failover run: sync standby\n" ++
        "seed 9: CRASHED: killed by SIGKILL, for memory (the kernel's out-of-memory killer)\n";
    const died = try parse(arena, kind_store_faults, died_text);
    try std.testing.expect(died.failures[0].crash);
    try std.testing.expectEqualStrings("failover-sync", died.failures[0].step);
    try std.testing.expectEqualStrings(
        "zig build test-store-faults -Dbackend=postgres -Dseed=9 -Dstore-faults-only=sync",
        died.failures[0].replay,
    );
    // run.sh's record of a failed conformance run (sf_conformance), after a run that passed.
    const conformance_text =
        "store-faults: backend=postgres seed=5 (replay: -Dseed=5)\n" ++
        "store-faults: PASS\n" ++
        "seed 5: FAILED: conformance: txn: the result's hash is the chain hash of its " ++
        "revision\n" ++
        "  step: conformance\n" ++
        "  replay: zig build pg-up && zig build test-store-faults -Dbackend=postgres " ++
        "-Dseed=5 -Dstore-faults-only=conformance\n";
    const conformance = try parse(arena, kind_store_faults, conformance_text);
    try std.testing.expectEqual(@as(u64, 2), conformance.seeds);
    try std.testing.expectEqual(@as(usize, 1), conformance.failures.len);
    try std.testing.expect(!conformance.failures[0].infra());
    try std.testing.expectEqualStrings("conformance", conformance.failures[0].step);
    try std.testing.expect(std.mem.endsWith(
        u8,
        conformance.failures[0].replay,
        "-Dseed=5 -Dstore-faults-only=conformance",
    ));
}

test "store-faults: the watch checker and a client thread fail under fingerprints of their own" {
    // Goal: a failure of the history checker, of the watch checker and of a client thread are
    // three issues, never one. Method: the runner's real lines for each (`history: {any}`,
    // `watch: {any}`, `a client thread stopped: NAME`), then its FAIL line, parsed; the checks
    // and fingerprints must all differ, and two client errors must differ too.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = "store-faults: backend=sqlite seed=4 (replay: -Dseed=4)\n";
    const fail = "store-faults: FAIL seed=4 (replay: -Dseed=4)\n";
    const verdict = ".{ .failed = .{ .kind = .log_gap, .revision = 2 } }\n";
    const texts = [_][]const u8{
        header ++ "store-faults: history: " ++ verdict ++ fail,
        header ++ "store-faults: watch: " ++ verdict ++ fail,
        header ++ "store-faults: a client thread stopped: BackendFailed\n" ++ fail,
        header ++ "store-faults: a client thread stopped: OutOfMemory\n" ++ fail,
    };
    const checks = [_][]const u8{
        "history: log_gap",
        "watch: log_gap",
        "client thread stopped: BackendFailed",
        "client thread stopped: OutOfMemory",
    };
    var prints: [texts.len]Fingerprint = undefined;
    for (texts, checks, 0..) |text, check, index| {
        const batch = try parse(arena, kind_store_faults, text);
        try std.testing.expectEqual(@as(usize, 1), batch.failures.len);
        try std.testing.expectEqualStrings(check, batch.failures[0].check);
        prints[index] = fingerprint(kind_store_faults, batch.failures[0]);
    }
    for (prints, 0..) |left, index| {
        for (prints[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, &left, &right));
        }
    }
}

// C3 fleet 7: the shape `sim_cluster --seeds A..B <ops> --shrink` prints since the trace (the
// shrunk run's last operations), and a soak's failure (`sim_cluster <seed> soak`).
const traced_failing =
    \\seed 4: FAILED: J8: a run was never started (seed 4, at 61000 ms)
    \\  step: end
    \\  profile: mixed
    \\  shape: operations=300 nodes=3 lease_ttl_ms=15000 replicas_pct=100
    \\  replay: zig-out/bin/sim_cluster 4 300 3 --heal-at=200
    \\  shrunk to 41 operations
    \\  replay: zig-out/bin/sim_cluster 4 41 3 --heal-at=200
    \\  trace: op 39 at 58100 ms: job_create
    \\  trace: op 40 at 60900 ms: apply web
    \\coverage: profile=mixed seeds=1 op.advance=1
    \\sim-cluster: seeds 4..4, 300 operations: 1 of 1 failed
;

const soak_failing =
    \\soak: epoch 1 operations=500 wall_ms=4000 live_bytes=1000
    \\soak: epoch 2 operations=1000 wall_ms=9000 live_bytes=9000
    \\seed 7: FAILED: soak: memory grew faster than the history it holds
    \\  step: soak
    \\  profile: mixed
    \\  shape: operations=1000 nodes=0 lease_ttl_ms=15000 replicas_pct=100
    \\  replay: zig-out/bin/sim_cluster 7 soak 0 --soak-operations=1000 --soak-epoch=500
    \\  soak: 90 live bytes per history item, 20 after the warm-up, limit 4 times
    \\sim-cluster --soak: seeds 7..7, 1000 operations: 1 of 1 failed
;

test "an issue carries the shrunk replay and the trace of the shrunk run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, kind_sim_cluster, traced_failing);
    try std.testing.expectEqual(@as(usize, 1), batch.failures.len);
    const failure = batch.failures[0];
    try std.testing.expectEqual(@as(?u32, 41), failure.shrunk_operations);
    try std.testing.expectEqualStrings(
        "trace: op 39 at 58100 ms: job_create\n  trace: op 40 at 60900 ms: apply web",
        failure.trace,
    );
    const report: Report = .{
        .kind = kind_sim_cluster,
        .commit = "abc",
        .failure = failure,
        .more = &.{},
    };
    const body = try issue_body(arena, &report);
    const replay = "zig-out/bin/sim_cluster 4 41 3 --heal-at=200\n```";
    try std.testing.expect(std.mem.indexOf(u8, body, replay) != null);
    const trace = "```\ntrace: op 39 at 58100 ms: job_create\n" ++
        "trace: op 40 at 60900 ms: apply web\n```";
    try std.testing.expect(std.mem.indexOf(u8, body, trace) != null);
    try std.testing.expect(std.mem.indexOf(u8, try comment_body(arena, &report), trace) != null);
    // The trace is evidence, not identity: the same check at the same step is the same issue.
    var untraced = failure;
    untraced.trace = "";
    try std.testing.expectEqualStrings(
        &fingerprint(kind_sim_cluster, untraced),
        &fingerprint(kind_sim_cluster, failure),
    );
}

test "a soak's failure is read under its own kind, its numbers in the trace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const batch = try parse(arena, kind_sim_soak, soak_failing);
    try std.testing.expectEqual(@as(u64, 1), batch.seeds);
    try std.testing.expectEqual(@as(?u32, 1000), batch.operations);
    const failure = batch.failures[0];
    try std.testing.expectEqualStrings("soak", failure.step);
    try std.testing.expect(std.mem.startsWith(u8, failure.trace, "soak: 90 live bytes"));
    // A plain round's parser does not take a soak's summary, nor the other way round.
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_cluster, soak_failing));
    try std.testing.expectError(error.NoSummary, parse(arena, kind_sim_soak, traced_failing));
    const line = try replay_line(arena, kind_sim_soak, "abc", failure);
    const runs = "sim-cluster-exe && zig-out/bin/sim_cluster 7 soak";
    try std.testing.expect(std.mem.indexOf(u8, line, runs) != null);
}
