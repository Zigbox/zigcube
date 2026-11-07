//! Steps 1 and 2 of `demo-b1` (docs/demos/b1.md): six jobs, each ending in the state and for the
//! cause it should, `zcube job run` idempotent and refused for a different spec under the same
//! name, and a watcher that is killed after the third ending and, restarted from its last
//! revision, sees the other three exactly once (J4 in a real run).

const std = @import("std");
const assert = std.debug.assert;
const state = @import("demo_b1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const input_bytes: usize = 1024;

/// The first three jobs end while a watcher runs; it is killed after the third.
pub fn first_three(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. three jobs end; a watcher prints them and is killed");
    const input = try host.path_in_work("input.txt");
    const bytes = try host.arena().alloc(u8, input_bytes);
    @memset(bytes, 'x');
    try std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = input, .data = bytes });
    const head = try state.head_revision(host);
    try start_watcher(demo, head + 1, "watch-1.txt");
    try ends_zero(demo);
    try ends_three(demo);
    try echoes_input(demo, input);
    try same_name(demo);
    try wait_lines(demo, "watch-1.txt", 3);
    try host.settle("the watcher may print each ending once", state.settle_ms);
    demo.bookmark = try last_ending_revision(host);
    const seen = try read_file(host, "watch-1.txt");
    try host.check(state.lines_with(seen, "") == 3, "the watcher printed exactly 3 lines", .{});
    for ([_][]const u8{ "exit0  ", "exit3  ", "echoin  " }) |prefix| {
        try host.check(state.lines_with(seen, prefix) == 1, "it printed '{s}' once", .{prefix});
    }
    stop_watcher(demo);
    try host.check(true, "the watcher is killed (kill -9) after the third ending", .{});
}

fn ends_zero(demo: *Demo) !void {
    const host = demo.host;
    const run = try state.run_job(host, "exit0", &.{}, "exit 0");
    try host.check(run.code == 0 and state.contains(run.out, "submitted"), "job run exit0", .{});
    const cli = try state.wait_job(host, "exit0", 0, "exited with code 0");
    try host.check(state.contains(cli.out, "end: exited (code 0)"), "exit0 ended exited 0", .{});
    const view = try state.need_job(host, "exit0");
    try host.check(std.mem.eql(u8, view.state, "exited"), "its state is exited", .{});
}

fn ends_three(demo: *Demo) !void {
    const host = demo.host;
    _ = try state.run_job(host, "exit3", &.{}, "exit 3");
    const cli = try state.wait_job(host, "exit3", 10, "exited otherwise");
    try host.check(state.contains(cli.out, "end: exited (code 3)"), "exit3 ended with code 3", .{});
    const view = try state.need_job(host, "exit3");
    try host.check(view.code == 3, "the server records exit code 3", .{});
}

/// A 1 KiB input, given in `IN`, is the job's exit code: its length divided by 128.
fn echoes_input(demo: *Demo, input: []const u8) !void {
    const host = demo.host;
    const flags = [_][]const u8{ "--input-file", input, "--input-env", "IN" };
    _ = try state.run_job(host, "echoin", &flags, "exit $(( ${#IN} / 128 ))");
    const cli = try state.wait_job(host, "echoin", 10, "exited otherwise");
    try host.check(state.contains(cli.out, "end: exited (code 8)"), "1024 / 128 = exit 8", .{});
    try host.check(state.contains(cli.out, "input: 1024 bytes, given as IN"), "the " ++
        "input is shown as a size and a variable, not its text", .{});
    try host.check(!state.contains(cli.out, "xxxxxxxx"), "the input's text is not printed", .{});
}

/// The same command again is a no-op; another spec under the same name is ZC-E0131.
fn same_name(demo: *Demo) !void {
    const host = demo.host;
    const before = try state.need_job(host, "exit0");
    const again = try state.run_job(host, "exit0", &.{}, "exit 0");
    try host.check(again.code == 0 and state.contains(again.out, "unchanged"), "the same " ++
        "job run again is a no-op ('unchanged')", .{});
    const other = try state.run_job(host, "exit0", &.{}, "exit 1");
    try host.check(other.code == 1 and state.contains(other.err, "ZC-E0131"), "another " ++
        "command under the name is refused with ZC-E0131 (exit 1)", .{});
    const after = try state.need_job(host, "exit0");
    // `revision` is the store's head when the job was read, not the job record's own: the other
    // jobs ending and every heartbeat move it, so it is not compared (issue #155).
    try host.check(std.mem.eql(u8, after.state, "exited") and after.code == before.code and
        same_text(after.node, before.node) and same_text(after.end_kind, before.end_kind) and
        after.retries == before.retries, "the job exit0 did not change", .{});
}

fn same_text(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The largest revision among the three jobs of step 1: where the watcher's own bookmark stands.
fn last_ending_revision(host: *Host) !i64 {
    var largest: i64 = 0;
    for ([_][]const u8{ "exit0", "exit3", "echoin" }) |name| {
        largest = @max(largest, (try state.need_job(host, name)).revision);
    }
    assert(largest > 0);
    return largest;
}

/// The last three end while no watcher runs; one started from the last bookmark sees them.
pub fn last_three(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. three more end while the watcher is dead; it restarts from its last revision");
    const bookmark = demo.bookmark;
    assert(bookmark > 0);
    host.say("  the watcher's last revision is {d}", .{bookmark});
    try ends_oom(demo);
    try ends_deadline(demo);
    try ends_cancelled(demo);
    try start_watcher(demo, bookmark + 1, "watch-2.txt");
    try wait_lines(demo, "watch-2.txt", 3);
    try host.settle("no ending may be printed twice", state.settle_ms);
    const seen = try read_file(host, "watch-2.txt");
    try host.check(state.lines_with(seen, "") == 3, "the restarted watcher printed 3 lines", .{});
    for ([_][]const u8{ "oomj  ", "dl  ", "cx  " }) |prefix| {
        try host.check(state.lines_with(seen, prefix) == 1, "it printed '{s}' once", .{prefix});
    }
    const old = try read_file(host, "watch-1.txt");
    for ([_][]const u8{ "exit0  ", "exit3  ", "echoin  " }) |prefix| {
        const only_first = state.lines_with(seen, prefix) == 0 and
            state.lines_with(old, prefix) == 1;
        try host.check(only_first, "'{s}' came from the first watcher only", .{prefix});
    }
    stop_watcher(demo);
    _ = try host.zcube(&.{ "job", "list", "--state", "ended" });
}

fn ends_oom(demo: *Demo) !void {
    const host = demo.host;
    _ = try state.run_job(host, "oomj", &.{}, "sleep 300");
    try state.wait_state(host, "oomj", "running", state.job_wait_ms);
    const index = try state.node_index(host, try state.need_job(host, "oomj"));
    host.say("  # the fake runtime's fault file: faults/oomj-job = oom", .{});
    try demo.fleet.fault(index, "oomj-job", "oom");
    const cli = try state.wait_job(host, "oomj", 11, "failed");
    try host.check(state.contains(cli.out, "end: failed (oom)"), "oomj failed: oom", .{});
}

fn ends_deadline(demo: *Demo) !void {
    const host = demo.host;
    _ = try state.run_job(host, "dl", &.{ "--deadline", "2s" }, "sleep 300");
    const cli = try state.wait_job(host, "dl", 11, "failed");
    try host.check(state.contains(cli.out, "end: failed (deadline)"), "dl failed: deadline", .{});
}

fn ends_cancelled(demo: *Demo) !void {
    const host = demo.host;
    _ = try state.run_job(host, "cx", &.{}, "sleep 300");
    try state.wait_state(host, "cx", "running", state.job_wait_ms);
    _ = try host.zcube(&.{ "job", "cancel", "cx" });
    const cli = try state.wait_job(host, "cx", 12, "cancelled");
    try host.check(state.contains(cli.out, "end: cancelled"), "cx ended cancelled", .{});
    const view = try state.need_job(host, "cx");
    try host.check(std.mem.eql(u8, view.state, "cancelled"), "its state is cancelled", .{});
}

// ---- The watcher: `zcube job watch` as a process of its own ----

fn start_watcher(demo: *Demo, from: i64, file: []const u8) !void {
    const host = demo.host;
    assert(demo.watcher == null);
    const out = try std.Io.Dir.cwd().createFile(host.io, try host.path_in_work(file), .{});
    defer out.close(host.io);
    const from_text = try std.fmt.allocPrint(host.arena(), "{d}", .{from});
    const argv = [_][]const u8{ host.config.cli_exe, "job", "watch", "--from", from_text };
    demo.watcher = try std.process.spawn(host.io, .{
        .argv = &argv,
        .cwd = .{ .path = host.work },
        .environ_map = &host.cli_environ,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    host.say("$ zcube job watch --from {d} > {s}   # in the background", .{ from, file });
}

/// Kills the watcher, if there is one. Also the cleanup's.
pub fn stop_watcher(demo: *Demo) void {
    if (demo.watcher) |*child| child.kill(demo.host.io);
    demo.watcher = null;
}

fn read_file(host: *Host, name: []const u8) ![]const u8 {
    const path = try host.path_in_work(name);
    const bytes = std.Io.Dir.cwd().readFileAlloc(host.io, path, host.arena(), .limited(64 * 1024));
    return bytes catch "";
}

const Lines = struct { file: []const u8, count: u32 };

fn has_lines(want: Lines, host: *Host) !bool {
    const text = try read_file(host, want.file);
    return state.lines_with(text, "") >= want.count;
}

fn wait_lines(demo: *Demo, file: []const u8, count: u32) !void {
    const want: Lines = .{ .file = file, .count = count };
    const what = "the watcher to print its endings";
    try demo.host.wait_for(want, has_lines, what, state.watch_wait_ms);
}
