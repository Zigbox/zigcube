//! `sim_fleet`: the simulation fleet's reporter (docs/briefs/c1-9.md, ops/sim-fleet/README.md).
//!
//!     sim_fleet ingest --repo OWNER/NAME --commit SHA --state FILE [--token-file FILE]
//!                      [--tracker N] [--kind sim-cluster|sim-c1|sim-swarm] [--dry-run]
//!                      [--canary RUNNER --canary-seeds A..B [--expect-symptom TEXT]]
//!                      < one run kind's output of a round
//!
//! Reads what one kind of producer printed in one round on stdin: for `sim-cluster`, each
//! `sim_cluster --seeds A..B <operations> --shrink`; for `sim-c1`, the same with `--c1`; for
//! `sim-swarm`, each `sim_swarm --seeds A..B <operations> --shrink`; concatenated, plus
//! `run.sh`'s records of crashed seeds. `run.sh` calls it once per kind per round. It counts
//! the seeds per UTC day in the state file and, on the first round of a new day, first posts the
//! finished days' totals on the tracking issue. Then each distinct failure (fingerprint = kind,
//! failing check, step) that no issue carries yet becomes an issue; one that has an issue gets
//! a comment,
//! at most once per commit and a few times a day. A seed that failed to start (`step: setup`)
//! is the host's trouble: counted, never filed. A deleted or transferred issue is forgotten and
//! filed again; a locked one is skipped. A rate limit stops every write and holds them until
//! GitHub's wait is over. `--dry-run` asks GitHub nothing and prints what it would do.
//!
//! `--canary` reads the output of a teeth canary (`run.sh`, `canary_pick`): the fault-on RUNNER
//! run like a worker of `--kind` over seeds A..B. Its caught checks are not filed; it is counted
//! and filed as kind `sim-canary`, where a miss (no seed failed), a wrong symptom (no failure's
//! check starts with TEXT) and each crash are failures (`issue.canary_verdict`). It prints
//! `sim-fleet: canary RUNNER: caught|MISSED|WRONG SYMPTOM|CRASHED`, and exits 2 when GitHub's
//! hold kept a canary failure from being filed, so `run.sh` runs that canary again next round.
//!
//! Exit codes: 0 done, 1 usage or bad input, 2 environment (state file, token, GitHub). The state
//! file is saved whenever it was read, whatever GitHub answered.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const issue = @import("sim_fleet_issue.zig");
const state_file = @import("sim_fleet_state.zig");
const github_api = @import("sim_fleet_github.zig");

const usage_text =
    "usage: sim_fleet ingest --repo OWNER/NAME --commit SHA --state FILE [--token-file FILE]\n" ++
    "                        [--tracker N] [--kind sim-cluster|sim-c1|sim-swarm] [--dry-run]\n" ++
    "                        [--canary RUNNER --canary-seeds A..B [--expect-symptom TEXT]]\n" ++
    "reads one kind's output of a round on stdin: `sim_cluster --seeds A..B <ops> --shrink`\n" ++
    "(--kind sim-cluster), the same with --c1 (sim-c1), or `sim_swarm --seeds A..B <ops>\n" ++
    "--shrink` (sim-swarm), concatenated; with --canary, the fault-on RUNNER's run of that\n" ++
    "kind over seeds A..B, filed as sim-canary\n";

pub const Options = struct {
    kind: []const u8 = issue.kind_sim_cluster,
    commit: []const u8,
    /// The issue the daily totals go to; none means they are not posted.
    tracker: ?u32 = null,
    now_seconds: i64,
};

/// What an ingest did, for the line it prints.
pub const Summary = struct {
    seeds: u64 = 0,
    failed: u64 = 0,
    crashes: u64 = 0,
    infra: u64 = 0,
    filed: u32 = 0,
    commented: u32 = 0,
    /// Failures with an issue that already had their comment for this commit or this day.
    throttled: u32 = 0,
    /// Issues GitHub answered 404 or 410 for: forgotten, and filed again.
    dropped: u32 = 0,
    /// Issues GitHub refused a comment on (locked): skipped until the next commit.
    forbidden: u32 = 0,
    reports: u32 = 0,
    /// The tracking issue refused the totals (gone or locked); they wait for a later round.
    tracker_refused: bool = false,
    /// GitHub had asked to wait: nothing was written.
    held: bool = false,
    /// What stopped the round's writes, if anything did.
    stopped: ?github_api.Error = null,
};

pub const IngestError = error{ OutOfMemory, StateFull };

/// The failures of one fingerprint within a round, in seed order.
const Group = struct { fingerprint: issue.Fingerprint, members: std.ArrayList(issue.Failure) };

/// Groups the failures worth filing (not the host's) by fingerprint.
fn group_failures(
    arena: std.mem.Allocator,
    kind: []const u8,
    failures: []const issue.Failure,
) error{OutOfMemory}![]Group {
    assert(kind.len > 0);
    var groups: std.ArrayList(Group) = .empty;
    for (failures) |*failure| {
        if (failure.infra()) continue;
        const fp = issue.fingerprint(kind, failure.*);
        const existing = for (groups.items) |*group| {
            if (std.mem.eql(u8, &group.fingerprint, &fp)) break group;
        } else null;
        const group = existing orelse try groups.addOne(arena);
        if (existing == null) group.* = .{ .fingerprint = fp, .members = .empty };
        try group.members.append(arena, failure.*);
    }
    assert(groups.items.len <= failures.len);
    return groups.items;
}

fn counts_of(batch: issue.Batch) state_file.Counts {
    var counts: state_file.Counts = .{ .seeds = batch.seeds, .failed = batch.failures.len };
    for (batch.failures) |*failure| {
        if (failure.crash) counts.crashes += 1;
        if (failure.infra()) counts.infra += 1;
    }
    assert(counts.failed <= counts.seeds);
    assert(counts.crashes + counts.infra <= counts.failed);
    return counts;
}

/// Counts the round into its day, posts the totals of finished days, then files or comments on
/// every failure of the round. The state is updated as it goes, so the caller saves it whatever
/// this returns. A GitHub error that stops the round is in `stopped`, not returned.
pub fn ingest(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    batch: issue.Batch,
    options: Options,
) IngestError!Summary {
    assert(options.now_seconds >= 0);
    assert(options.commit.len > 0);
    const counts = counts_of(batch);
    var summary: Summary = .{
        .seeds = counts.seeds,
        .failed = counts.failed,
        .crashes = counts.crashes,
        .infra = counts.infra,
    };
    const today = state_file.ymd_of(options.now_seconds);
    // A canary that GitHub kept from being filed (held, or stopped) runs again soon and is
    // counted when it is filed, so its seeds are not counted twice; any other kind is counted
    // first: its seeds ran whether or not GitHub answers.
    const canary = std.mem.eql(u8, options.kind, issue.kind_sim_canary);
    const groups = try group_failures(arena, options.kind, batch.failures);
    if (!canary) try count_round(arena, state, today, options, counts, groups);
    if (options.now_seconds < state.hold_until) {
        summary.held = true;
        return summary;
    }
    state.hold_until = 0;
    // The totals go first: the tracker hears about every day even when the issues fail.
    post_daily_totals(arena, github, state, today, options, &summary) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| return halt(github, state, options, &summary, e),
    };
    for (groups) |*group| {
        report_group(arena, github, state, group, options, &summary) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StateFull => return error.StateFull,
            else => |e| return halt(github, state, options, &summary, e),
        };
    }
    if (canary) try count_round(arena, state, today, options, counts, groups);
    return summary;
}

/// The round's seeds in the day's totals, and each group's seeds in what the day saw.
fn count_round(
    arena: std.mem.Allocator,
    state: *state_file.State,
    today: state_file.Ymd,
    options: Options,
    counts: state_file.Counts,
    groups: []Group,
) error{OutOfMemory}!void {
    try state.count(arena, today, options.kind, counts, options.commit);
    for (groups) |*group| {
        const fp = try arena.dupe(u8, &group.fingerprint);
        const number = if (state.find(fp)) |filed| filed.issue else 0;
        const seen = try state.see(arena, today, fp, number) orelse continue;
        seen.seeds += group.members.items.len;
    }
}

/// Records what stopped the round; a rate limit holds every write until GitHub's wait is over.
fn halt(
    github: github_api.Github,
    state: *state_file.State,
    options: Options,
    summary: *Summary,
    err: github_api.Error,
) Summary {
    assert(summary.stopped == null);
    assert(err != error.OutOfMemory);
    summary.stopped = err;
    if (err == error.GitHubRateLimited) {
        const asked = github.retry_after();
        const wait: u32 = if (asked == 0)
            constants.fleet_hold_seconds_default
        else
            @min(asked, constants.fleet_hold_seconds_max);
        state.hold_until = options.now_seconds + wait;
        assert(state.hold_until > options.now_seconds);
    }
    return summary.*;
}

/// Files the group's failure, or comments on its issue unless it had its comment for this
/// commit or this day. Returns only the errors that stop the round.
fn report_group(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    group: *const Group,
    options: Options,
    summary: *Summary,
) (github_api.Error || error{StateFull})!void {
    assert(group.members.items.len > 0);
    const fp = try arena.dupe(u8, &group.fingerprint);
    if (state.find(fp) == null) {
        // A lost state file: the issues still carry the marker.
        const found = try github.find(arena, fp) orelse
            return open_group(arena, github, state, group, options, summary);
        try state.remember(arena, .{
            .fingerprint = fp,
            .issue = found,
            .commit = options.commit,
            .last_commit = "",
        });
    }
    const filed = state.find(fp).?;
    const today = state_file.ymd_of(options.now_seconds);
    const seen = try state.see(arena, today, fp, filed.issue);
    const comments_max = constants.fleet_comments_per_failure_per_day_max;
    // Past the day's cap on distinct failures there is no count: no comment either.
    const comments = if (seen) |item| item.comments else comments_max;
    if (std.mem.eql(u8, filed.last_commit, options.commit) or
        comments >= comments_max)
    {
        summary.throttled += 1;
        return;
    }
    const report = report_of(group, options);
    const body = try issue.comment_body(arena, &report);
    github.comment(arena, filed.issue, body) catch |err| switch (err) {
        error.GitHubGone => {
            // Deleted or transferred: forget it and file the failure again.
            state.forget(fp);
            summary.dropped += 1;
            return open_group(arena, github, state, group, options, summary);
        },
        error.GitHubForbidden => {
            // Locked: no more tries on this commit; the rest of the round goes on.
            filed.last_commit = options.commit;
            summary.forbidden += 1;
            return;
        },
        else => return err,
    };
    filed.last_commit = options.commit;
    seen.?.comments += 1;
    summary.commented += 1;
}

fn report_of(group: *const Group, options: Options) issue.Report {
    assert(group.members.items.len > 0);
    return .{
        .kind = options.kind,
        .commit = options.commit,
        .failure = group.members.items[0],
        .more = group.members.items[1..],
    };
}

fn open_group(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    group: *const Group,
    options: Options,
    summary: *Summary,
) (github_api.Error || error{StateFull})!void {
    const fp = try arena.dupe(u8, &group.fingerprint);
    assert(state.find(fp) == null);
    const report = report_of(group, options);
    const title = try issue.title(arena, options.kind, report.failure);
    const body = try issue.issue_body(arena, &report);
    const number = try github.open(arena, title, body);
    try state.remember(arena, .{
        .fingerprint = fp,
        .issue = number,
        .commit = options.commit,
        .last_commit = options.commit,
    });
    const today = state_file.ymd_of(options.now_seconds);
    if (try state.see(arena, today, fp, number)) |seen| seen.issue = number;
    summary.filed += 1;
}

/// Posts each finished day's totals once, oldest first. A tracker that is gone or locked is
/// skipped (the days wait for a later round); other errors stop the round.
fn post_daily_totals(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    today: state_file.Ymd,
    options: Options,
    summary: *Summary,
) github_api.Error!void {
    assert(summary.reports == 0);
    const tracker = options.tracker orelse return;
    assert(tracker > 0);
    for (try state.unreported(arena, today)) |day| {
        const text = try totals_text(arena, state, &day);
        github.comment(arena, tracker, text) catch |err| switch (err) {
            error.GitHubGone, error.GitHubForbidden => {
                summary.tracker_refused = true;
                return;
            },
            else => return err,
        };
        try state.mark_reported(arena, day.ymd);
        summary.reports += 1;
    }
}

fn totals_text(
    arena: std.mem.Allocator,
    state: *const state_file.State,
    day: *const state_file.Day,
) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    write_totals(w, state, day, try state.seen_on(arena, day.ymd)) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write_totals(
    w: *std.Io.Writer,
    state: *const state_file.State,
    day: *const state_file.Day,
    seen: []const state_file.Seen,
) std.Io.Writer.Error!void {
    try w.print("{s} (UTC): {d} seeds run, {d} failed ({d} crashed, {d} could not start), " ++
        "in {d} ingests (one per kind per round); the last ran at commit `{s}`. A day with " ++
        "no comment here means the fleet did not run.\n", .{
        &day.ymd, day.seeds, day.failed, day.crashes, day.infra, day.batches, day.commit,
    });
    try w.writeAll("\nSeeds by run:\n");
    for (issue.kinds) |kind| {
        const totals = state_file.kind_totals(state, day, kind, issue.kind_sim_cluster);
        try w.print("- {s}: {d} seeds, {d} failed\n", .{ kind, totals.seeds, totals.failed });
    }
    if (seen.len == 0) return;
    try w.writeAll("\nFailures by issue:\n");
    for (seen) |item| {
        // The number may have come later (filed after a hold): the filed entry knows it.
        const number = if (state.find(item.fingerprint)) |filed| filed.issue else item.issue;
        if (number == 0) {
            try w.print("- not filed (`{s}`): {d} seeds\n", .{ item.fingerprint, item.seeds });
        } else {
            try w.print("- #{d}: {d} seeds\n", .{ number, item.seeds });
        }
    }
}

const Args = struct {
    repo: []const u8 = "",
    commit: []const u8 = "",
    state: []const u8 = "",
    token_file: ?[]const u8 = null,
    tracker: ?u32 = null,
    kind: []const u8 = issue.kind_sim_cluster,
    dry_run: bool = false,
    canary: ?[]const u8 = null,
    canary_seeds: ?[]const u8 = null,
    symptom: ?[]const u8 = null,
};

/// The canary of `--canary RUNNER --canary-seeds A..B [--expect-symptom TEXT]`, null without
/// `--canary`, an error for a canary half given or not of a simulator kind.
fn canary_of(args: Args) error{BadCanary}!?issue.Canary {
    const runner = args.canary orelse {
        if (args.canary_seeds != null or args.symptom != null) return error.BadCanary;
        return null;
    };
    const seeds = args.canary_seeds orelse return error.BadCanary;
    if (std.mem.eql(u8, args.kind, issue.kind_sim_canary)) return error.BadCanary;
    // A word: it goes into a replay command and an issue title.
    if (runner.len == 0) return error.BadCanary;
    for (runner) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.BadCanary;
    }
    const dots = std.mem.indexOf(u8, seeds, "..") orelse return error.BadCanary;
    const first = std.fmt.parseInt(u64, seeds[0..dots], 10) catch return error.BadCanary;
    const last = std.fmt.parseInt(u64, seeds[dots + 2 ..], 10) catch return error.BadCanary;
    if (last < first) return error.BadCanary;
    if (args.symptom) |symptom| if (symptom.len == 0) return error.BadCanary;
    return .{
        .runner = runner,
        .kind = args.kind,
        .first = first,
        .last = last,
        .symptom = args.symptom,
    };
}

/// Null if the command line is not valid `ingest`.
fn parse_args(args: []const []const u8) ?Args {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "ingest")) return null;
    var parsed: Args = .{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            parsed.dry_run = true;
            continue;
        }
        index += 1;
        if (index >= args.len) return null;
        const value = args[index];
        if (std.mem.eql(u8, arg, "--repo")) {
            parsed.repo = value;
        } else if (std.mem.eql(u8, arg, "--commit")) {
            parsed.commit = value;
        } else if (std.mem.eql(u8, arg, "--state")) {
            parsed.state = value;
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            parsed.token_file = value;
        } else if (std.mem.eql(u8, arg, "--kind")) {
            parsed.kind = value;
        } else if (std.mem.eql(u8, arg, "--canary")) {
            parsed.canary = value;
        } else if (std.mem.eql(u8, arg, "--canary-seeds")) {
            parsed.canary_seeds = value;
        } else if (std.mem.eql(u8, arg, "--expect-symptom")) {
            parsed.symptom = value;
        } else if (std.mem.eql(u8, arg, "--tracker")) {
            parsed.tracker = std.fmt.parseInt(u32, value, 10) catch return null;
            if (parsed.tracker.? == 0) return null;
        } else {
            return null;
        }
    }
    if (parsed.commit.len == 0 or parsed.state.len == 0) return null;
    // The commit and kind are words in the state file.
    if (std.mem.indexOfAny(u8, parsed.commit, " \t\r\n") != null) return null;
    if (!issue.kind_known(parsed.kind)) return null;
    _ = canary_of(parsed) catch return null;
    if (!parsed.dry_run and (parsed.repo.len == 0 or parsed.token_file == null)) return null;
    return parsed;
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return constants.exit_user;
    const args = parse_args(argv) orelse {
        std.Io.File.stderr().writeStreamingAll(init.io, usage_text) catch {}; // Nowhere else.
        return constants.exit_user;
    };
    var err_buffer: [1024]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(init.io, &err_buffer);
    const log = &err_writer.interface;
    defer log.flush() catch {}; // Nowhere else to report it.
    return run(init, arena, args, log) catch |err| {
        log.print("sim-fleet: {s}\n", .{explain(err)}) catch {}; // Nowhere else.
        return switch (err) {
            error.NoSummary, error.BadLine, error.TooManyFailures => constants.exit_user,
            else => constants.exit_environment,
        };
    };
}

const RunError = issue.ParseError || state_file.ParseError || IngestError ||
    std.Io.Writer.Error ||
    error{
        StateUnreadable,
        StateUnwritable,
        InputUnreadable,
        TokenUnreadable,
        GitHubStopped,
        CanaryHeld,
    };

/// One line: what went wrong and what to do about it. (The fleet's messages are not coded
/// diagnostics yet: docs/briefs/c1-9.md, "Cuts".)
fn explain(err: RunError) []const u8 {
    return switch (err) {
        error.NoSummary => "stdin has no summary line of --kind (`sim-cluster: seeds A..B`, " ++
            "`sim-cluster --c1: seeds A..B` or `sim-swarm: seeds A..B`), or a failure after " ++
            "the last one; feed it that producer's --seeds output (run.sh does)",
        error.BadLine => "stdin has a line sim_fleet cannot read, batches of different " ++
            "operation counts, or a summary whose count of failed seeds is not the number of " ++
            "`seed N:` records before it; feed it unchanged --seeds output",
        error.TooManyFailures => "stdin lists more failing seeds than a round may hold; " ++
            "run smaller batches",
        error.BadState => "the state file is not one sim_fleet wrote; move it aside " ++
            "(the issues' markers rebuild what was filed)",
        error.StateUnreadable => "cannot read the state file (see the line above); " ++
            "fix its permissions, or move it aside to start over",
        error.StateUnwritable => "cannot write the state file or its .new next to it; " ++
            "check the directory's permissions and free space",
        error.StateFull => "the state file holds the most filed failures it may; " ++
            "close and prune old ones, or move it aside",
        error.InputUnreadable => "cannot read stdin, or it is larger than a round may be",
        error.TokenUnreadable => "cannot read the token file (see the line above); " ++
            "it must be readable by this user",
        error.GitHubStopped => "GitHub stopped this round (see the lines above); the state " ++
            "is saved and the next round goes on from it",
        error.CanaryHeld => "GitHub asked to wait, so the canary's failure is not filed; " ++
            "run.sh runs this canary again next round",
        error.OutOfMemory => "out of memory",
        error.WriteFailed => "cannot write to stdout",
    };
}

/// The state at `path`: empty if there is no such file, an error for anything else that keeps
/// it from being read (M6: a state file that exists is never silently treated as empty).
fn load_state(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    log: *std.Io.Writer,
) (state_file.ParseError || error{StateUnreadable})!state_file.State {
    assert(path.len > 0);
    const limit: std.Io.Limit = .limited(constants.fleet_state_bytes_max);
    const text = dir.readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.print("sim-fleet: {s}: {s}\n", .{ path, @errorName(err) }) catch {}; // Exits 2.
            return error.StateUnreadable;
        },
    };
    return state_file.parse(arena, text);
}

fn read_token(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    log: *std.Io.Writer,
) error{TokenUnreadable}![]const u8 {
    const limit: std.Io.Limit = .limited(constants.fleet_token_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| {
        // The path and the reason only: never the contents.
        log.print("sim-fleet: {s}: {s}\n", .{ path, @errorName(err) }) catch {}; // Exits 2.
        return error.TokenUnreadable;
    };
    const token = std.mem.trim(u8, text, " \t\r\n");
    if (token.len == 0) {
        log.print("sim-fleet: {s}: empty\n", .{path}) catch {}; // Exits 2.
        return error.TokenUnreadable;
    }
    return token;
}

fn run(
    init: std.process.Init,
    arena: std.mem.Allocator,
    args: Args,
    log: *std.Io.Writer,
) RunError!u8 {
    const io = init.io;
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const input_limit: std.Io.Limit = .limited(constants.fleet_input_bytes_max);
    const input = stdin.interface.allocRemaining(arena, input_limit) catch
        return error.InputUnreadable;
    const read = try read_input(arena, args, input);
    const batch = read.batch;
    const kind = read.kind;
    // A dry run keeps its own state file: it must not mark anything filed in the real one.
    const state_path = if (args.dry_run)
        try std.fmt.allocPrint(arena, "{s}.dry", .{args.state})
    else
        args.state;
    var state = try load_state(arena, io, std.Io.Dir.cwd(), state_path, log);
    const options: Options = .{
        .kind = kind,
        .commit = args.commit,
        .tracker = args.tracker,
        .now_seconds = std.Io.Clock.real.now(io).toSeconds(),
    };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {}; // Nowhere else to report it.
    const outcome = if (args.dry_run) blk: {
        var printer: github_api.Printer = .{ .out = out };
        break :blk ingest(arena, printer.github(), &state, batch, options);
    } else blk: {
        const token = try read_token(arena, io, args.token_file.?, log);
        var http: github_api.Http = .{
            .client = .{ .allocator = init.gpa, .io = io },
            .repo = args.repo,
            .token = token,
            .log = log,
        };
        defer http.client.deinit();
        break :blk ingest(arena, http.github(), &state, batch, options);
    };
    // Saved whatever GitHub answered: what was filed stays filed, and a hold stays held.
    try save(arena, io, state_path, &state);
    const summary = try outcome;
    try print_summary(out, kind, &summary, &state, args.dry_run);
    if (read.verdict) |verdict| {
        const word = switch (verdict) {
            .caught => "caught",
            .missed => "MISSED",
            .wrong_symptom => "WRONG SYMPTOM",
            .crashed => "CRASHED",
            .not_run => "NOT RUN",
        };
        try out.print("sim-fleet: canary {s}: {s}\n", .{ args.canary.?, word });
    }
    return exit_of(read.verdict != null, &summary);
}

/// How a round that was ingested ends: GitHub stopping it is `GitHubStopped`; a canary's
/// failure that a hold kept from being filed is `CanaryHeld`. A canary runs once in many
/// rounds, so both are found again soon (run.sh retries on exit 2, with a cap), not when the
/// cycle comes back to the canary.
fn exit_of(canary: bool, summary: *const Summary) error{ GitHubStopped, CanaryHeld }!u8 {
    if (summary.stopped != null) return error.GitHubStopped;
    if (canary and summary.held and summary.failed > summary.infra) return error.CanaryHeld;
    return constants.exit_ok;
}

/// What a round's input is filed as: the batch as parsed, or a canary's judged batch under the
/// kind `sim-canary`.
const Read = struct { kind: []const u8, batch: issue.Batch, verdict: ?issue.Verdict };

fn read_input(arena: std.mem.Allocator, args: Args, text: []const u8) issue.ParseError!Read {
    const parsed = try issue.parse(arena, args.kind, text);
    // parse_args checked it.
    const canary = canary_of(args) catch unreachable;
    const run_of = canary orelse return .{ .kind = args.kind, .batch = parsed, .verdict = null };
    const judged = try issue.canary_verdict(arena, run_of, parsed);
    return .{ .kind = issue.kind_sim_canary, .batch = judged.batch, .verdict = judged.verdict };
}

fn print_summary(
    out: *std.Io.Writer,
    kind: []const u8,
    summary: *const Summary,
    state: *const state_file.State,
    dry_run: bool,
) std.Io.Writer.Error!void {
    try out.print(
        "sim-fleet: {s}: {d} seeds, {d} failed ({d} crashed, {d} could not start): " ++
            "{d} issues filed, {d} comments, {d} throttled, {d} refiled, {d} locked, " ++
            "{d} daily reports{s}\n",
        .{
            kind,
            summary.seeds,
            summary.failed,
            summary.crashes,
            summary.infra,
            summary.filed,
            summary.commented,
            summary.throttled,
            summary.dropped,
            summary.forbidden,
            summary.reports,
            if (dry_run) " (dry run)" else "",
        },
    );
    if (summary.tracker_refused) {
        try out.writeAll("sim-fleet: the tracking issue refused the totals; " ++
            "they are posted when it accepts them\n");
    }
    if (summary.held) {
        try out.print("sim-fleet: GitHub asked to wait; nothing written until {d} (unix)\n", .{
            state.hold_until,
        });
    }
    if (summary.stopped) |err| {
        try out.print("sim-fleet: stopped writing to GitHub: {s}\n", .{@errorName(err)});
        if (state.hold_until > 0) {
            try out.print("sim-fleet: holding every write until {d} (unix)\n", .{state.hold_until});
        }
    }
}

/// Writes the state next to its file and renames it over it, so a crash leaves the old one.
fn save(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: *const state_file.State,
) error{ StateUnwritable, OutOfMemory }!void {
    var out: std.Io.Writer.Allocating = .init(arena);
    state.render(&out.writer) catch return error.OutOfMemory;
    const temp = try std.fmt.allocPrint(arena, "{s}.new", .{path});
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = temp, .data = out.written() }) catch
        return error.StateUnwritable;
    cwd.rename(temp, cwd, path, io) catch return error.StateUnwritable;
}

const teeth_output =
    \\seed 1: FAILED: a container runs that no replica assigns to its node
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 1 100 0 --heal-at=60
    \\  shrunk to 13 operations
    \\  replay: zig-out/bin/sim_cluster 1 13 0 --heal-at=60
    \\seed 2: FAILED: a container runs that no replica assigns to its node
    \\  step: healed
    \\  replay: zig-out/bin/sim_cluster 2 100 0 --heal-at=60
    \\  shrunk to 67 operations
    \\  replay: zig-out/bin/sim_cluster 2 67 0 --heal-at=60
    \\seed 3: FAILED: a replica is not placed
    \\  step: convergence
    \\  replay: zig-out/bin/sim_cluster 3 100 0 --heal-at=60
    \\sim-cluster: seeds 1..10, 100 operations: 3 of 10 failed
    \\
;

const day_one: i64 = 1_793_581_200; // 2026-11-02 01:00 UTC.
const day_two: i64 = day_one + 86_400;

fn test_options(commit: []const u8, now: i64) Options {
    return .{ .commit = commit, .tracker = 7, .now_seconds = now };
}

test "one issue per fingerprint, one comment per commit, then the day's totals" {
    // Goal: H1, a failure seen every round gets one issue, then one comment per new commit
    // and none for a commit it already reported; the finished day's totals go out once.
    // Method: the same round ingested on commits aaa, bbb, bbb, then on the next day.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const batch = try issue.parse(arena, issue.kind_sim_cluster, teeth_output);

    const first = try ingest(arena, fake.github(), &state, batch, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(u32, 2), first.filed); // Two fingerprints, three seeds.
    try std.testing.expectEqual(@as(u32, 0), first.commented);
    try std.testing.expectEqual(@as(usize, 2), fake.issues.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.issues.items[0].body, "seeds 2.") != null);

    const second = try ingest(arena, fake.github(), &state, batch, test_options("bbb", day_one));
    try std.testing.expectEqual(@as(u32, 0), second.filed);
    try std.testing.expectEqual(@as(u32, 2), second.commented);
    try std.testing.expect(std.mem.indexOf(u8, fake.comments.items[0].body, "bbb") != null);

    // The same commit again: throttled, no request at all.
    const requests = fake.requests;
    const third = try ingest(arena, fake.github(), &state, batch, test_options("bbb", day_one));
    try std.testing.expectEqual(@as(u32, 2), third.throttled);
    try std.testing.expectEqual(@as(u32, 0), third.commented);
    try std.testing.expectEqual(requests, fake.requests);

    // The next day's first round posts yesterday's totals once, before anything else.
    const comments_before = fake.comments.items.len;
    const fourth = try ingest(arena, fake.github(), &state, batch, test_options("ccc", day_two));
    try std.testing.expectEqual(@as(u32, 1), fourth.reports);
    const posted = fake.comments.items[comments_before];
    try std.testing.expectEqual(@as(u32, 7), posted.number);
    const totals = "2026-11-02 (UTC): 30 seeds run, 9 failed (0 crashed, 0 could not start), in 3";
    try std.testing.expect(std.mem.indexOf(u8, posted.body, totals) != null);
    try std.testing.expect(std.mem.indexOf(u8, posted.body, "- #1: 6 seeds") != null);
    try std.testing.expect(std.mem.indexOf(u8, posted.body, "- #2: 3 seeds") != null);
    const fifth = try ingest(arena, fake.github(), &state, batch, test_options("ddd", day_two));
    try std.testing.expectEqual(@as(u32, 0), fifth.reports);
}

test "comments on one failure are capped per day, whatever the commits" {
    // Goal: H1, a failure seen on many commits in one day gets a bounded number of comments.
    // Method: ingest one failing round on more distinct commits than the cap.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const one = try issue.parse(
        arena,
        issue.kind_sim_cluster,
        "seed 1: FAILED: x\n  step: end\n  replay: r1\n" ++
            "sim-cluster: seeds 1..2, 5 operations: 1 of 2 failed\n",
    );
    const rounds = constants.fleet_comments_per_failure_per_day_max + 3;
    var commit_buffer: [16]u8 = undefined;
    for (0..rounds) |round| {
        const commit = try std.fmt.bufPrint(&commit_buffer, "c{d}", .{round});
        const options = test_options(try arena.dupe(u8, commit), day_one);
        _ = try ingest(arena, fake.github(), &state, one, options);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.issues.items.len);
    const cap = constants.fleet_comments_per_failure_per_day_max;
    try std.testing.expectEqual(@as(usize, cap), fake.comments.items.len);
}

test "the totals go out despite a locked and a deleted issue, and the deleted one is refiled" {
    // Goal: H2, per-issue errors neither stop the tracker's totals nor the rest of the round;
    // a 404 drops the filed entry so the failure gets a new issue; a 403 is skipped.
    // Method: file two issues on day one; on day two, issue 1 is locked and issue 2 is gone.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const batch = try issue.parse(arena, issue.kind_sim_cluster, teeth_output);
    _ = try ingest(arena, fake.github(), &state, batch, test_options("aaa", day_one));
    fake.locked = 1;
    fake.gone = 2;
    const next = try ingest(arena, fake.github(), &state, batch, test_options("bbb", day_two));
    try std.testing.expectEqual(@as(?github_api.Error, null), next.stopped);
    try std.testing.expectEqual(@as(u32, 1), next.reports);
    try std.testing.expectEqual(@as(u32, 1), next.forbidden);
    try std.testing.expectEqual(@as(u32, 1), next.dropped);
    try std.testing.expectEqual(@as(u32, 1), next.filed);
    try std.testing.expectEqual(@as(usize, 3), fake.issues.items.len);
    try std.testing.expectEqual(@as(u32, 7), fake.comments.items[0].number);
    const refiled = state.find(&issue.fingerprint(issue.kind_sim_cluster, batch.failures[2]));
    try std.testing.expectEqual(@as(u32, 3), refiled.?.issue);
    // The locked issue is not retried on the same commit.
    const requests = fake.requests;
    const again = try ingest(arena, fake.github(), &state, batch, test_options("bbb", day_two));
    try std.testing.expectEqual(@as(u32, 2), again.throttled);
    try std.testing.expectEqual(requests, fake.requests);
}

test "a rate limit stops the round and holds every write until GitHub's wait is over" {
    // Goal: H1, on 403/429 rate limits nothing more is written, and nothing at all until the
    // Retry-After passed; the rounds in between are still counted.
    // Method: the fake refuses every request after the second; ingest during and after the hold.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{
        .gpa = std.testing.allocator,
        .rate_limit_after = 2, // A find and an open.
        .retry_after_seconds = 120,
    };
    defer fake.deinit();
    var state: state_file.State = .{};
    const batch = try issue.parse(arena, issue.kind_sim_cluster, teeth_output);
    const first = try ingest(arena, fake.github(), &state, batch, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(?github_api.Error, error.GitHubRateLimited), first.stopped);
    try std.testing.expectEqual(@as(u32, 1), first.filed);
    try std.testing.expectEqual(@as(u32, 3), fake.requests); // Find, open, a refused find.
    try std.testing.expectEqual(day_one + 120, state.hold_until);

    const held = try ingest(arena, fake.github(), &state, batch, test_options("bbb", day_one + 60));
    try std.testing.expect(held.held);
    try std.testing.expectEqual(@as(u32, 3), fake.requests);
    try std.testing.expectEqual(@as(u64, 20), state.days.items[0].seeds);

    fake.rate_limit_after = null;
    const late = test_options("ccc", day_one + 121);
    const after = try ingest(arena, fake.github(), &state, batch, late);
    try std.testing.expectEqual(@as(?github_api.Error, null), after.stopped);
    try std.testing.expectEqual(@as(u32, 1), after.filed);
    try std.testing.expectEqual(@as(u32, 1), after.commented);
    try std.testing.expectEqual(@as(i64, 0), state.hold_until);
}

test "a crash is filed under its own fingerprint and a seed that never started is not filed" {
    // Goal: H3 and M7, a crash record becomes an issue titled as a crash; `step: setup` (the
    // host ran out of memory) is counted in the day, never filed.
    // Method: one round with a crash record and an out-of-memory line.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const round = try issue.parse(arena, issue.kind_sim_cluster,
        \\seed 5: FAILED: out of memory
        \\  step: setup
        \\  replay: zig-out/bin/sim_cluster 5 100 0
        \\sim-cluster: seeds 1..10, 100 operations: 1 of 10 failed
        \\seed 77: CRASHED: index out of bounds: index 12, len 3
        \\  step: healed
        \\  replay: zig-out/bin/sim_cluster 77 100 0
        \\sim-cluster: seeds 77..77, 100 operations: 1 of 1 failed
        \\
    );
    const summary = try ingest(arena, fake.github(), &state, round, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(u32, 1), summary.filed);
    try std.testing.expectEqual(@as(u64, 1), summary.crashes);
    try std.testing.expectEqual(@as(u64, 1), summary.infra);
    const title = fake.issues.items[0].title;
    try std.testing.expect(std.mem.startsWith(u8, title, "sim-cluster: crash: index out of"));
    try std.testing.expectEqual(@as(u64, 1), state.days.items[0].infra);
    try std.testing.expectEqual(@as(u64, 11), state.days.items[0].seeds);
}

test "a lost state file is rebuilt from the markers on the issues" {
    // Goal: a state file lost between rounds files no duplicates.
    // Method: file with one state, then ingest with an empty one on a new commit.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    const batch = try issue.parse(arena, issue.kind_sim_cluster, teeth_output);
    var old: state_file.State = .{};
    _ = try ingest(arena, fake.github(), &old, batch, test_options("aaa", day_one));
    var fresh: state_file.State = .{};
    const again = try ingest(arena, fake.github(), &fresh, batch, test_options("bbb", day_one));
    try std.testing.expectEqual(@as(u32, 0), again.filed);
    try std.testing.expectEqual(@as(u32, 2), again.commented);
    try std.testing.expectEqual(@as(usize, 2), fresh.filed.items.len);
}

test "a clean batch files nothing and still counts its seeds" {
    // Goal: seeds that pass are counted. Method: one clean summary line.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const clean = try issue.parse(
        arena,
        issue.kind_sim_cluster,
        "sim-cluster: seeds 1..40, 100 operations: 0 of 40 failed\n",
    );
    const summary = try ingest(arena, fake.github(), &state, clean, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(u64, 40), summary.seeds);
    try std.testing.expectEqual(@as(usize, 0), fake.issues.items.len);
    try std.testing.expectEqual(@as(u64, 40), state.days.items[0].seeds);
}

test "the dry run prints one would-be issue, then would-be comments, and asks GitHub nothing" {
    // Goal: the dry run shows the issue, then a comment for a new commit, nothing for a repeat.
    // Method: ingest one failure on aaa, bbb, bbb through the printer.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var printer: github_api.Printer = .{ .out = &out.writer };
    var state: state_file.State = .{};
    const one = try issue.parse(
        arena,
        issue.kind_sim_cluster,
        "seed 1: FAILED: x\n  step: end\n  replay: r1\n" ++
            "sim-cluster: seeds 1..2, 5 operations: 1 of 2 failed\n",
    );
    _ = try ingest(arena, printer.github(), &state, one, test_options("aaa", day_one));
    _ = try ingest(arena, printer.github(), &state, one, test_options("bbb", day_one));
    _ = try ingest(arena, printer.github(), &state, one, test_options("bbb", day_one));
    const text = out.written();
    try std.testing.expect(std.mem.count(u8, text, "would file issue") == 1);
    try std.testing.expect(std.mem.count(u8, text, "would comment on issue #0") == 1);
}

test "a missing state file is empty; one that cannot be read is an error" {
    // Goal: M6, only FileNotFound means a first run; anything else stops with an error, so a
    // state file that exists is never overwritten as if empty.
    // Method: load a missing path, a directory, a garbled file and a valid one.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log: std.Io.Writer.Allocating = .init(arena);
    const missing = try load_state(arena, io, tmp.dir, "missing", &log.writer);
    try std.testing.expectEqual(@as(usize, 0), missing.filed.items.len);
    try tmp.dir.createDir(io, "a-directory", .default_dir);
    try std.testing.expectError(
        error.StateUnreadable,
        load_state(arena, io, tmp.dir, "a-directory", &log.writer),
    );
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "a-directory") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "garbled", .data = "version 9\n" });
    try std.testing.expectError(
        error.BadState,
        load_state(arena, io, tmp.dir, "garbled", &log.writer),
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "good", .data = "filed abc 4 c1\n" });
    const good = try load_state(arena, io, tmp.dir, "good", &log.writer);
    try std.testing.expectEqual(@as(u32, 4), good.filed.items[0].issue);
}

test "parse_args wants a commit and a state, and a repo and token unless dry" {
    // Goal: the command line is checked before anything runs. Method: valid and invalid lines.
    const ok = parse_args(&.{ "f", "ingest", "--commit", "c", "--state", "s", "--dry-run" });
    try std.testing.expect(ok != null);
    try std.testing.expect(ok.?.dry_run);
    const no_repo = parse_args(&.{ "f", "ingest", "--commit", "c", "--state", "s" });
    try std.testing.expect(no_repo == null);
    const real = parse_args(&.{
        "f",      "ingest", "--commit",  "c", "--state",      "s",
        "--repo", "a/b",    "--tracker", "9", "--token-file", "t",
    });
    try std.testing.expectEqual(@as(?u32, 9), real.?.tracker);
    const other = parse_args(&.{
        "f", "ingest", "--commit", "c", "--state", "s", "--dry-run", "--kind", "store-faults",
    });
    try std.testing.expect(other == null);
    try std.testing.expect(parse_args(&.{ "f", "ingest", "--bogus", "1" }) == null);
    const spaced = parse_args(&.{ "f", "ingest", "--commit", "a b", "--state", "s", "--dry-run" });
    try std.testing.expect(spaced == null);
}

test "three kinds on one day: separate issues, separate counts, and the totals break them down" {
    // Goal: the same check failing in sim-cluster and sim-c1 is two issues, and the daily post
    // says how many seeds each kind ran. Method: ingest one failure per kind, then the next day.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const failing = "seed 3: FAILED: I6: an allocation disagrees\n  step: faults\n" ++
        "  replay: zig-out/bin/sim_cluster 3 100 0 --c1\n";
    const swarm_text = "seed 5: FAILED: a chunk with wrong bytes was accepted\n  step: fetch\n" ++
        "  replay: zig-out/bin/sim_swarm 5 100\n  shrunk to 1 operations\n" ++
        "  replay: zig-out/bin/sim_swarm 5 1\n";
    const cluster_tail = "sim-cluster: seeds 1..100, 100 operations: 1 of 100 failed\n";
    const c1_tail = "sim-cluster --c1: seeds 1..100, 100 operations: 1 of 100 failed\n";
    const swarm_tail = "sim-swarm: seeds 1..50, 100 operations: 1 of 50 failed\n";
    const Input = struct { kind: []const u8, text: []const u8, seeds: u32, tail: []const u8 };
    const inputs = [_]Input{
        .{ .kind = issue.kind_sim_cluster, .text = failing, .seeds = 100, .tail = cluster_tail },
        .{ .kind = issue.kind_sim_c1, .text = failing, .seeds = 100, .tail = c1_tail },
        .{ .kind = issue.kind_sim_swarm, .text = swarm_text, .seeds = 50, .tail = swarm_tail },
    };
    for (inputs) |input| {
        const text = try std.mem.concat(arena, u8, &.{ input.text, input.tail });
        const batch = try issue.parse(arena, input.kind, text);
        var options = test_options("aaa", day_one);
        options.kind = input.kind;
        const summary = try ingest(arena, fake.github(), &state, batch, options);
        try std.testing.expectEqual(@as(u32, 1), summary.filed);
        try std.testing.expectEqual(@as(u64, input.seeds), summary.seeds);
    }
    try std.testing.expectEqual(@as(usize, 3), fake.issues.items.len);
    const swarm_body = fake.issues.items[2].body;
    try std.testing.expect(std.mem.indexOf(u8, swarm_body, "sim-swarm-exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, swarm_body, "- run: sim-swarm") != null);
    const day = &state.days.items[0];
    try std.testing.expectEqual(@as(u64, 250), day.seeds);
    const default = issue.kind_sim_cluster;
    const swarm = state_file.kind_totals(&state, day, issue.kind_sim_swarm, default);
    try std.testing.expectEqual(@as(u64, 50), swarm.seeds);
    const cluster = state_file.kind_totals(&state, day, issue.kind_sim_cluster, default);
    try std.testing.expectEqual(@as(u64, 100), cluster.seeds);
    const before = fake.comments.items.len;
    const next = try issue.parse(
        arena,
        issue.kind_sim_swarm,
        "sim-swarm: seeds 1..9, 100 operations: 0 of 9 failed\n",
    );
    var next_options = test_options("bbb", day_two);
    next_options.kind = issue.kind_sim_swarm;
    _ = try ingest(arena, fake.github(), &state, next, next_options);
    const posted = fake.comments.items[before].body;
    for ([_][]const u8{
        "- sim-cluster: 100 seeds, 1 failed",
        "- sim-c1: 100 seeds, 1 failed",
        "- sim-swarm: 50 seeds, 1 failed",
    }) |line| try std.testing.expect(std.mem.indexOf(u8, posted, line) != null);
}

/// What `sim_c1_teeth_wedge --seeds 2000..2003 auto --profile=auto --c1 --shrink` printed
/// (seed 2001 failed; the runner's replays carry `sim_cluster`, the main it is built from).
const canary_wedge_caught = "seed 2001: FAILED: I1b: a replaced replica kept executing longer " ++
    "than the lost grace plus the kill latency\n" ++
    "  step: faults\n" ++
    "  profile: slow_store\n" ++
    "  shape: operations=82 nodes=13 lease_ttl_ms=8373 replicas_pct=100\n" ++
    "  replay: zig-out/bin/sim_cluster 2001 82 13 --c1 --profile=slow_store " ++
    "--lease-ttl-ms=8373 --replicas-pct=100 --heal-at=41\n" ++
    "  shrunk to 20 operations\n" ++
    "  replay: zig-out/bin/sim_cluster 2001 20 13 --c1 --profile=slow_store " ++
    "--lease-ttl-ms=8373 --replicas-pct=100 --heal-at=41\n" ++
    "sim-cluster --c1: seeds 2000..2003, drawn operations: 1 of 4 failed\n";
/// The same run had the fault broken some other check instead.
const canary_wedge_wrong = "seed 2002: FAILED: I6: an allocation disagrees with the sum of " ++
    "its node's assignments\n" ++
    "  step: faults\n" ++
    "  profile: mixed\n" ++
    "  shape: operations=109 nodes=8 lease_ttl_ms=9769 replicas_pct=100\n" ++
    "  replay: zig-out/bin/sim_cluster 2002 109 8 --c1 --lease-ttl-ms=9769 " ++
    "--replicas-pct=100 --heal-at=89\n" ++
    "sim-cluster --c1: seeds 2000..2003, drawn operations: 1 of 4 failed\n";
const canary_wedge_missed = "sim-cluster --c1: seeds 2000..2003, drawn operations: 0 of 4 failed\n";
const canary_wedge: issue.Canary = .{
    .runner = "sim_c1_teeth_wedge",
    .kind = issue.kind_sim_c1,
    .first = 2000,
    .last = 2003,
    .symptom = "I1b: a replaced replica kept executing longer",
};

fn canary_ingest(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    text: []const u8,
    commit: []const u8,
) !Summary {
    const parsed = try issue.parse(arena, canary_wedge.kind, text);
    const judged = try issue.canary_verdict(arena, canary_wedge, parsed);
    var options = test_options(commit, day_one);
    options.kind = issue.kind_sim_canary;
    return ingest(arena, github, state, judged.batch, options);
}

test "a canary that caught its fault files nothing; a miss and a wrong symptom are two issues" {
    // Goal: the canary's real output, read with its kind's parser: a caught fault is counted
    // and files nothing; a miss and a wrong symptom are each an issue, deduplicated apart.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const caught = try canary_ingest(arena, fake.github(), &state, canary_wedge_caught, "aaa");
    try std.testing.expectEqual(@as(u32, 0), caught.filed);
    try std.testing.expectEqual(@as(u64, 4), caught.seeds);
    try std.testing.expectEqual(@as(u64, 0), caught.failed);
    const missed = try canary_ingest(arena, fake.github(), &state, canary_wedge_missed, "aaa");
    try std.testing.expectEqual(@as(u32, 1), missed.filed);
    const wrong = try canary_ingest(arena, fake.github(), &state, canary_wedge_wrong, "aaa");
    try std.testing.expectEqual(@as(u32, 1), wrong.filed);
    try std.testing.expectEqual(@as(usize, 2), fake.issues.items.len);
    const miss_issue = fake.issues.items[0];
    try std.testing.expect(std.mem.startsWith(u8, miss_issue.title, "sim-canary: the fleet " ++
        "has stopped detecting: sim_c1_teeth_wedge failed no seed (step: canary)"));
    for ([_][]const u8{
        "sim-canary-exe && zig-out/bin/sim_c1_teeth_wedge --seeds 2000..2003 auto " ++
            "--profile=auto --c1",
        "- seeds: 2000..2003, each with its own drawn operations and profile",
        "teeth canary",
    }) |text| try std.testing.expect(std.mem.indexOf(u8, miss_issue.body, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, miss_issue.body, "- seed: ") == null);
    try std.testing.expect(std.mem.indexOf(u8, miss_issue.body, "operations: not") == null);
    const wrong_issue = fake.issues.items[1];
    try std.testing.expect(std.mem.indexOf(u8, wrong_issue.title, "but never with") != null);
    for ([_][]const u8{
        "- failed instead with: I6: an allocation disagrees",
        "zig-out/bin/sim_c1_teeth_wedge 2002 109 8 --c1",
        "- seed: 2002",
    }) |text| try std.testing.expect(std.mem.indexOf(u8, wrong_issue.body, text) != null);
    // Missed again on the same commit: no new issue and no comment.
    const again = try canary_ingest(arena, fake.github(), &state, canary_wedge_missed, "aaa");
    try std.testing.expectEqual(@as(u32, 0), again.filed);
    try std.testing.expectEqual(@as(u32, 1), again.throttled);
    try std.testing.expectEqual(@as(usize, 2), fake.issues.items.len);
}

test "a canary held by GitHub is not counted, is not filed, and ends as CanaryHeld" {
    // Goal: a canary's miss that a hold keeps from being filed ends the run as CanaryHeld (run.sh
    // then runs it again), and its seeds are counted once, when it is finally filed.
    // Method: a hold in the future and a miss as input; then the hold over, the miss again.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    state.hold_until = day_one + 60;
    const held = try canary_ingest(arena, fake.github(), &state, canary_wedge_missed, "aaa");
    try std.testing.expect(held.held);
    try std.testing.expectEqual(@as(u32, 0), held.filed);
    try std.testing.expectEqual(@as(u32, 0), fake.requests);
    try std.testing.expectError(error.CanaryHeld, exit_of(true, &held));
    // Any other kind held is not run again by the canary rule.
    try std.testing.expectEqual(constants.exit_ok, try exit_of(false, &held));
    try std.testing.expectEqual(@as(usize, 0), state.days.items.len);

    state.hold_until = 0;
    const filed = try canary_ingest(arena, fake.github(), &state, canary_wedge_missed, "aaa");
    try std.testing.expectEqual(@as(u32, 1), filed.filed);
    try std.testing.expectEqual(constants.exit_ok, try exit_of(true, &filed));
    try std.testing.expectEqual(@as(u64, 4), state.days.items[0].seeds);
    const stopped: Summary = .{ .stopped = error.GitHubRateLimited };
    try std.testing.expectError(error.GitHubStopped, exit_of(true, &stopped));
}

test "a canary no seed of which could start is NOT RUN: counted, never filed" {
    // Goal: the host's out-of-memory kill (run.sh's record in step setup) is not a crash of the
    // canary and not a miss; run.sh runs the canary again.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const text = "seed 2000: FAILED: killed (out of memory?)\n  step: setup\n" ++
        "  replay: zig-out/bin/sim_c1_teeth_wedge --seeds 2000..2003 auto --c1 --profile=auto\n" ++
        "sim-cluster --c1: seeds 2000..2000, drawn operations: 1 of 1 failed\n";
    const parsed = try issue.parse(arena, issue.kind_sim_c1, text);
    const judged = try issue.canary_verdict(arena, canary_wedge, parsed);
    try std.testing.expectEqual(issue.Verdict.not_run, judged.verdict);
    var options = test_options("aaa", day_one);
    options.kind = issue.kind_sim_canary;
    const summary = try ingest(arena, fake.github(), &state, judged.batch, options);
    try std.testing.expectEqual(@as(u32, 0), summary.filed);
    try std.testing.expectEqual(@as(u64, 1), summary.infra);
    try std.testing.expectEqual(@as(usize, 0), fake.issues.items.len);
}

test "a canary's crash is filed under sim-canary with the runner's replay" {
    // Goal: a crash record of the canary's run (run.sh's crash_record) is filed, not dropped,
    // and its replay runs the fault-on runner, not the plain simulator.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "seed 42: CRASHED: reached unreachable code\n" ++
        "  step: faults\n" ++
        "  replay: zig-out/bin/sim_cluster 42 80 3 --c1 --profile=mixed\n" ++
        "sim-cluster --c1: seeds 42..42, drawn operations: 1 of 1 failed\n";
    const parsed = try issue.parse(arena, issue.kind_sim_c1, text);
    var one = canary_wedge;
    one.first = 42;
    one.last = 42;
    const judged = try issue.canary_verdict(arena, one, parsed);
    // Its only seed crashed: the crash is filed, and no miss (nothing ran to its end).
    try std.testing.expectEqual(issue.Verdict.crashed, judged.verdict);
    try std.testing.expectEqual(@as(usize, 1), judged.batch.failures.len);
    const crash = judged.batch.failures[0];
    try std.testing.expect(crash.crash);
    try std.testing.expectEqualStrings(
        "zig-out/bin/sim_c1_teeth_wedge 42 80 3 --c1 --profile=mixed",
        crash.replay,
    );
    const plain = issue.fingerprint(issue.kind_sim_c1, parsed.failures[0]);
    const own = issue.fingerprint(issue.kind_sim_canary, crash);
    try std.testing.expect(!std.mem.eql(u8, &plain, &own));
}

test "the canary's arguments come together or not at all" {
    // Goal: --canary needs its seeds, names a simulator kind and a runner that is one word.
    const base = [_][]const u8{ "sim_fleet", "ingest", "--commit", "c", "--state", "s" } ++
        [_][]const u8{"--dry-run"};
    const good = base ++ [_][]const u8{ "--kind", "sim-c1", "--canary", "sim_c1_teeth_wedge" } ++
        [_][]const u8{ "--canary-seeds", "5..9", "--expect-symptom", "I1b: a replaced" };
    const args = parse_args(&good).?;
    const canary = (try canary_of(args)).?;
    try std.testing.expectEqual(@as(u64, 5), canary.first);
    try std.testing.expectEqualStrings("I1b: a replaced", canary.symptom.?);
    for ([_][]const []const u8{
        &(base ++ [_][]const u8{ "--canary", "sim_teeth" }),
        &(base ++ [_][]const u8{ "--canary-seeds", "1..2" }),
        &(base ++ [_][]const u8{ "--canary", "a b", "--canary-seeds", "1..2" }),
        &(base ++ [_][]const u8{ "--canary", "sim_teeth", "--canary-seeds", "9..2" }),
        &(base ++ [_][]const u8{
            "--kind", "sim-canary", "--canary", "sim_teeth", "--canary-seeds", "1..2",
        }),
    }) |bad| try std.testing.expect(parse_args(bad) == null);
}
