//! `sim_fleet`: the simulation fleet's reporter (docs/briefs/c1-9.md, ops/sim-fleet/README.md).
//!
//!     sim_fleet ingest --repo OWNER/NAME --commit SHA --state FILE [--token-file FILE]
//!                      [--tracker N] [--kind sim-cluster] [--dry-run]  < sim_cluster output
//!
//! Reads what `sim_cluster --seeds A..B <operations> --shrink` printed on stdin. Each distinct
//! failure (fingerprint = kind, failing check, step) that no issue carries yet becomes an issue;
//! one that has an issue gets a comment. It counts the seeds per UTC day in the state file and,
//! on the first batch of a new day, posts the finished days' totals as a comment on the tracking
//! issue. `--dry-run` asks GitHub nothing and prints what it would do.
//!
//! Exit codes: 0 done, 1 usage or bad input, 2 environment (state file, token, GitHub).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const issue = @import("sim_fleet_issue.zig");
const state_file = @import("sim_fleet_state.zig");
const github_api = @import("sim_fleet_github.zig");

const usage_text =
    "usage: sim_fleet ingest --repo OWNER/NAME --commit SHA --state FILE [--token-file FILE]\n" ++
    "                        [--tracker N] [--kind sim-cluster] [--dry-run]\n" ++
    "reads the output of `sim_cluster --seeds A..B <operations> --shrink` on stdin\n";

/// The stdin of one run is a few lines per failing seed.
const input_bytes_max = 1 << 20;
const state_bytes_max = 1 << 20;

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
    filed: u32 = 0,
    commented: u32 = 0,
    reports: u32 = 0,
};

/// The failures of one fingerprint within a batch, in seed order.
const Group = struct { fingerprint: issue.Fingerprint, members: std.ArrayList(issue.Failure) };

fn group_failures(
    arena: std.mem.Allocator,
    kind: []const u8,
    failures: []const issue.Failure,
) error{OutOfMemory}![]Group {
    var groups: std.ArrayList(Group) = .empty;
    for (failures) |failure| {
        const fp = issue.fingerprint(kind, failure);
        const existing = for (groups.items) |*group| {
            if (std.mem.eql(u8, &group.fingerprint, &fp)) break group;
        } else null;
        const group = existing orelse try groups.addOne(arena);
        if (existing == null) group.* = .{ .fingerprint = fp, .members = .empty };
        try group.members.append(arena, failure);
    }
    return groups.items;
}

/// Files or comments on every failure of the batch, counts the batch into its day, and posts the
/// totals of finished days. The state is updated as it goes, so the caller saves it even when
/// this fails halfway.
pub fn ingest(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    batch: issue.Batch,
    options: Options,
) (github_api.Error || error{OutOfMemory})!Summary {
    assert(options.now_seconds >= 0);
    var summary: Summary = .{ .seeds = batch.seeds, .failed = batch.failures.len };
    const today = state_file.ymd_of(options.now_seconds);
    // Counted first: the seeds ran whether or not GitHub answers.
    try state.count(arena, today, batch.seeds, batch.failures.len, options.commit);
    for (try group_failures(arena, options.kind, batch.failures)) |group| {
        const first = group.members.items[0];
        const more = group.members.items[1..];
        try report_group(arena, github, state, group.fingerprint, first, more, options, &summary);
    }
    try post_daily_totals(arena, github, state, today, options, &summary);
    return summary;
}

fn report_group(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    fingerprint: issue.Fingerprint,
    first: issue.Failure,
    more: []const issue.Failure,
    options: Options,
    summary: *Summary,
) (github_api.Error || error{OutOfMemory})!void {
    const fp = try arena.dupe(u8, &fingerprint);
    var known: ?u32 = if (state.find(fp)) |filed| filed.issue else null;
    if (known == null) {
        // A lost state file: the issues still carry the marker.
        known = try github.find(arena, fp);
        if (known) |number| try remember(arena, state, fp, number, options.commit);
    }
    if (known) |number| {
        const body = try issue.comment_body(arena, options.commit, first, more);
        try github.comment(arena, number, body);
        summary.commented += 1;
        return;
    }
    const title = try issue.title(arena, options.kind, first);
    const body = try issue.issue_body(arena, options.commit, first, more);
    const number = try github.open(arena, title, body);
    try remember(arena, state, fp, number, options.commit);
    summary.filed += 1;
}

fn remember(
    arena: std.mem.Allocator,
    state: *state_file.State,
    fp: []const u8,
    number: u32,
    commit: []const u8,
) error{OutOfMemory}!void {
    try state.filed.append(arena, .{
        .fingerprint = fp,
        .issue = number,
        .commit = try arena.dupe(u8, commit),
    });
}

fn post_daily_totals(
    arena: std.mem.Allocator,
    github: github_api.Github,
    state: *state_file.State,
    today: state_file.Ymd,
    options: Options,
    summary: *Summary,
) (github_api.Error || error{OutOfMemory})!void {
    const tracker = options.tracker orelse return;
    for (try state.unreported(arena, today)) |day| {
        const text = try std.fmt.allocPrint(
            arena,
            "{s} (UTC): {d} seeds run, {d} failed, in {d} batches; the last batch ran at " ++
                "commit `{s}`. A day with no comment here means the fleet did not run.",
            .{ &day.ymd, day.seeds, day.failed, day.batches, day.commit },
        );
        try github.comment(arena, tracker, text);
        state.reported = try arena.dupe(u8, &day.ymd);
        summary.reports += 1;
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
};

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
        } else if (std.mem.eql(u8, arg, "--tracker")) {
            parsed.tracker = std.fmt.parseInt(u32, value, 10) catch return null;
        } else {
            return null;
        }
    }
    if (parsed.commit.len == 0 or parsed.state.len == 0) return null;
    if (!std.mem.eql(u8, parsed.kind, issue.kind_sim_cluster)) return null;
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
    var err_buffer: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(init.io, &err_buffer);
    const log = &err_writer.interface;
    defer log.flush() catch {}; // Nowhere else to report it.
    return run(init, arena, args, log) catch |err| {
        log.print("sim-fleet: {s}\n", .{@errorName(err)}) catch {}; // Nowhere else.
        return switch (err) {
            error.NoSummary, error.BadLine => constants.exit_user,
            else => constants.exit_environment,
        };
    };
}

const RunError = github_api.Error || issue.ParseError || state_file.ParseError ||
    std.Io.Writer.Error ||
    error{ StateUnreadable, StateUnwritable, InputUnreadable, TokenUnreadable };

fn read_file(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(limit)) catch null;
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
    const input = stdin.interface.allocRemaining(arena, .limited(input_bytes_max)) catch
        return error.InputUnreadable;
    const batch = try issue.parse(arena, input);
    // A dry run keeps its own state file: it must not mark anything filed in the real one.
    const state_path = if (args.dry_run)
        std.fmt.allocPrint(arena, "{s}.dry", .{args.state}) catch return error.OutOfMemory
    else
        args.state;
    // A missing state file is a first run; a garbled one is an error (parse below).
    const text = read_file(arena, io, state_path, state_bytes_max) orelse "";
    var state = try state_file.parse(arena, text);
    const options: Options = .{
        .kind = args.kind,
        .commit = args.commit,
        .tracker = args.tracker,
        .now_seconds = std.Io.Clock.real.now(io).toSeconds(),
    };
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {}; // Nowhere else to report it.
    const outcome = if (args.dry_run) blk: {
        var printer: github_api.Printer = .{ .out = out };
        break :blk ingest(arena, printer.github(), &state, batch, options);
    } else blk: {
        const token = read_file(arena, io, args.token_file.?, 4096) orelse
            return error.TokenUnreadable;
        var http: github_api.Http = .{
            .client = .{ .allocator = init.gpa, .io = io },
            .repo = args.repo,
            .token = std.mem.trim(u8, token, " \t\r\n"),
            .log = log,
        };
        defer http.client.deinit();
        break :blk ingest(arena, http.github(), &state, batch, options);
    };
    // Saved whether or not GitHub answered: what was filed stays filed.
    try save(arena, io, state_path, &state);
    const summary = try outcome;
    try out.print(
        "sim-fleet: {d} seeds, {d} failed: {d} issues filed, {d} comments, {d} daily reports{s}\n",
        .{
            summary.seeds,
            summary.failed,
            summary.filed,
            summary.commented,
            summary.reports,
            if (args.dry_run) " (dry run)" else "",
        },
    );
    return constants.exit_ok;
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

test "one issue per fingerprint, then comments, then the day's totals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const batch = try issue.parse(arena, teeth_output);

    const first = try ingest(arena, fake.github(), &state, batch, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(u32, 2), first.filed); // Two fingerprints, three seeds.
    try std.testing.expectEqual(@as(u32, 0), first.commented);
    try std.testing.expectEqual(@as(usize, 2), fake.issues.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.issues.items[0].body, "seeds 2.") != null);

    // The same failures on a later commit: comments, no new issues, and nothing on the tracker
    // yet (the day is not over).
    const later = test_options("bbb", day_one + 60);
    const second = try ingest(arena, fake.github(), &state, batch, later);
    try std.testing.expectEqual(@as(u32, 0), second.filed);
    try std.testing.expectEqual(@as(u32, 2), second.commented);
    try std.testing.expectEqual(@as(usize, 2), fake.issues.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.comments.items[0].body, "bbb") != null);

    // The next day's first batch posts yesterday's totals once.
    const third = try ingest(arena, fake.github(), &state, batch, test_options("ccc", day_two));
    try std.testing.expectEqual(@as(u32, 1), third.reports);
    const posted = fake.comments.items[fake.comments.items.len - 1];
    try std.testing.expectEqual(@as(u32, 7), posted.number);
    const totals = "2026-11-02 (UTC): 20 seeds run, 6 failed, in 2";
    try std.testing.expect(std.mem.indexOf(u8, posted.body, totals) != null);
    const again = test_options("ccc", day_two + 5);
    const fourth = try ingest(arena, fake.github(), &state, batch, again);
    try std.testing.expectEqual(@as(u32, 0), fourth.reports);
}

test "a lost state file is rebuilt from the markers on the issues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    const batch = try issue.parse(arena, teeth_output);
    var old: state_file.State = .{};
    _ = try ingest(arena, fake.github(), &old, batch, test_options("aaa", day_one));
    var fresh: state_file.State = .{};
    const again = try ingest(arena, fake.github(), &fresh, batch, test_options("bbb", day_one));
    try std.testing.expectEqual(@as(u32, 0), again.filed);
    try std.testing.expectEqual(@as(u32, 2), again.commented);
    try std.testing.expectEqual(@as(usize, 2), fresh.filed.items.len);
}

test "a clean batch files nothing and still counts its seeds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: github_api.Fake = .{ .gpa = std.testing.allocator };
    defer fake.deinit();
    var state: state_file.State = .{};
    const clean = try issue.parse(
        arena,
        "sim-cluster: seeds 1..40, 100 operations: 0 of 40 failed\n",
    );
    const summary = try ingest(arena, fake.github(), &state, clean, test_options("aaa", day_one));
    try std.testing.expectEqual(@as(u64, 40), summary.seeds);
    try std.testing.expectEqual(@as(usize, 0), fake.issues.items.len);
    try std.testing.expectEqual(@as(u64, 40), state.days.items[0].seeds);
}

test "the dry run prints one would-be issue, then would-be comments, and asks GitHub nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var printer: github_api.Printer = .{ .out = &out.writer };
    var state: state_file.State = .{};
    const one = try issue.parse(arena, "seed 1: FAILED: x\n  step: end\n  replay: r1\n" ++
        "sim-cluster: seeds 1..2, 5 operations: 1 of 2 failed\n");
    _ = try ingest(arena, printer.github(), &state, one, test_options("aaa", day_one));
    _ = try ingest(arena, printer.github(), &state, one, test_options("bbb", day_one));
    const text = out.written();
    try std.testing.expect(std.mem.count(u8, text, "would file issue") == 1);
    try std.testing.expect(std.mem.count(u8, text, "would comment on issue #0") == 1);
}

test "parse_args wants a commit and a state, and a repo and token unless dry" {
    const ok = parse_args(&.{ "f", "ingest", "--commit", "c", "--state", "s", "--dry-run" });
    try std.testing.expect(ok != null and ok.?.dry_run);
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
}
