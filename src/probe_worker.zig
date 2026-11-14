//! `zcube-agent probe NAME TIMEOUT_MS WORD...`: one health check in a Zigbox container (C3
//! slice 10). The agent's `ZigboxRuntime.probe_begin` starts this worker; `probe_poll` reads the
//! one line it writes on its standard output and reaps it.
//!
//! Why a process: Zigbox `exec_start` must run on the process's only thread, and the thread that
//! starts the command must be the one that waits for it (`zigbox.zig`, M6b). The agent has many
//! threads, so, as C2's fetch worker, the check runs in a process of its own, single-threaded
//! until the command runs.
//!
//! The worker:
//!   - keeps its standard output as the result channel (a close-on-exec copy) and gives the
//!     command /dev/null for its three streams, so nothing the command prints can pass for a
//!     result line, and the command holds no end of the agent's pipe;
//!   - starts the command with `keep_history = false` (a check every few seconds would fill the
//!     container's exec history);
//!   - opens a pidfd on the command, then starts one timer thread, which, at `TIMEOUT_MS`, sends
//!     SIGKILL through that pidfd. Not `exec_signal`: that reads `handle.pid.?` and asserts the
//!     handle is running, and `exec_wait` clears both when the command ends, so a timer that
//!     fires as the command ends would read them as they change. A pidfd names this one process
//!     until it is reaped and fails with ESRCH after, so a late timer kills nothing else. (A
//!     Zigbox finding, docs/decisions/2026-11-14-probe-worker.md.)
//!   - waits with `exec_wait` and writes one line:
//!       `exited N`       the command ended; N is its exit code (128 + signal for a signal);
//!       `timed_out`      the timer killed it;
//!       `refused JSON`   the check could not run: the diagnostic, as `zigbox.diagnostic`
//!                        writes it (Zigbox's code when exec refused, else a ZC-E0502).
//!
//! The agent kills the worker's process group (it starts the worker as a group leader, and the
//! command stays in that group) when it abandons a check or the worker outlives its timeout and
//! grace. Not in `zcube-agent --help`: it is the agent's, not an operator's.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");

const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const ProbeResult = runtime.ProbeResult;
const HostReal = zigbox.host_real.HostReal;

/// The longest line the worker writes: `refused `, the longest diagnostic JSON Zigbox reads back
/// (its `diag_wire_bytes_max`, 16 KiB, which `parse_json` enforces) and the newline.
pub const line_bytes_max: u32 = 16 * 1024 + 16;

/// SIGKILL, as `ExecExit.signaled` reports it.
const signal_kill: u8 = 9;

/// Writes the line for a final result (never `running`).
pub fn write_line(writer: *std.Io.Writer, result: *const ProbeResult) std.Io.Writer.Error!void {
    assert(result.final());
    switch (result.*) {
        .running => unreachable, // Asserted above: only a final result is written.
        .exited => |code| try writer.print("exited {d}\n", .{code}),
        .timed_out => try writer.writeAll("timed_out\n"),
        .refused => |*diagnostic| {
            try writer.writeAll("refused ");
            try zigbox.diagnostic.write_json(writer, diagnostic); // It ends the line.
        },
    }
}

/// Reads a worker's output: true and `out` set when it is exactly one well-formed line.
pub fn parse_line(out: *ProbeResult, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if (bytes.len > line_bytes_max) return false;
    if (bytes[bytes.len - 1] != '\n') return false;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return false;
    if (std.mem.eql(u8, line, "timed_out")) {
        out.* = .timed_out;
        return true;
    }
    if (std.mem.startsWith(u8, line, "exited ")) {
        const code = std.fmt.parseInt(u8, line["exited ".len..], 10) catch return false;
        out.* = .{ .exited = code };
        return true;
    }
    if (std.mem.startsWith(u8, line, "refused ")) {
        out.* = .{ .refused = undefined };
        zigbox.diagnostic.parse_json(&out.refused, line["refused ".len..]) catch return false;
        return out.refused.code.len > 0;
    }
    return false;
}

/// What the worker was asked to run.
pub const Args = struct {
    name: []const u8,
    timeout_ms: u32,
    command: []const []const u8,
};

/// The arguments after `probe`, or null when they are not complete or not valid.
pub fn parse_args(args: []const []const u8) ?Args {
    if (args.len < 3) return null;
    const name = args[0];
    if (runtime.name_problem(name) != null) return null;
    const timeout_ms = std.fmt.parseInt(u32, args[1], 10) catch return null;
    if (timeout_ms == 0 or timeout_ms > constants.health_interval_ms_max) return null;
    const command = args[2..];
    if (command.len > constants.runtime_command_words_max) return null;
    for (command) |word| if (word.len == 0) return null;
    return .{ .name = name, .timeout_ms = timeout_ms, .command = command };
}

/// What the worker keeps for one check: the handle is about 600 KiB, so it lives on the heap.
const Storage = struct {
    handle: zigbox.ExecHandle,
    result: ProbeResult,
    line: [line_bytes_max]u8,
};

const bad_args = "the arguments of zcube-agent probe are not valid";

pub fn run(init: std.process.Init, args: []const []const u8) u8 {
    // The result channel: a copy of standard output that the command does not inherit.
    const out_rc = linux.fcntl(1, linux.F.DUPFD_CLOEXEC, 3);
    if (linux.errno(out_rc) != .SUCCESS) return constants.exit_environment;
    const out: linux.fd_t = @intCast(out_rc);
    const storage = std.heap.page_allocator.create(Storage) catch {
        return constants.exit_environment;
    };
    defer std.heap.page_allocator.destroy(storage);
    if (!quiet_streams()) {
        storage.result = .{ .refused = failure("its streams could not be set to /dev/null") };
    } else if (parse_args(args)) |parsed| {
        check(init, &parsed, storage);
    } else {
        storage.result = .{ .refused = failure(bad_args) };
    }
    var writer: std.Io.Writer = .fixed(&storage.line);
    write_line(&writer, &storage.result) catch return constants.exit_internal;
    if (!write_all(out, writer.buffered())) return constants.exit_environment;
    return constants.exit_ok;
}

/// Points standard input, output and error at /dev/null: they are the command's.
fn quiet_streams() bool {
    const rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const null_fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(null_fd);
    for ([_]linux.fd_t{ 0, 1, 2 }) |target| {
        if (linux.errno(linux.dup2(null_fd, target)) != .SUCCESS) return false;
    }
    return true;
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

/// Runs the check; `storage.result` holds how it ended.
fn check(init: std.process.Init, args: *const Args, storage: *Storage) void {
    var real: HostReal = .{ .environ = init.minimal.environ };
    const spec: zigbox.ExecSpec = .{ .name = args.name, .command = args.command };
    var zbx_diag: zigbox.diag.Diag = undefined;
    zbx_diag.reset();
    const handle = &storage.handle;
    const options: zigbox.ExecOptions = .{ .keep_history = false };
    zigbox.exec_start(real.interface(), &spec, options, handle, &zbx_diag) catch {
        storage.result = .{ .refused = undefined };
        zigbox.diagnostic.from_diag(&storage.result.refused, &zbx_diag);
        return;
    };
    const pid: linux.pid_t = @intCast(handle.pid.?);
    var timer: Timer = .{ .timeout_ms = args.timeout_ms };
    const started = timer.start(pid);
    const exit = zigbox.exec_wait(handle);
    if (started) timer.stop();
    storage.result = verdict(exit, handle, timer.fired.load(.acquire), started);
}

/// How the check ended, from the command's exit and what the timer did.
fn verdict(
    exit: zigbox.ExecExit,
    handle: *const zigbox.ExecHandle,
    fired: bool,
    timed: bool,
) ProbeResult {
    if (!timed) return .{ .refused = failure("its timer could not be started") };
    switch (exit) {
        .lost => {
            var out: ProbeResult = .{ .refused = undefined };
            zigbox.diagnostic.from_diag(&out.refused, &handle.lost_diag);
            return out;
        },
        .signaled => |number| {
            if (fired and number == signal_kill) return .timed_out;
            if (handle.container_ended) {
                return .{ .refused = failure("the container ended while the check ran") };
            }
        },
        .exited => {},
    }
    return .{ .exited = exit.code().? };
}

pub const next_interval = "see the agent's log; the check runs again at its next interval";

fn failure(cause: []const u8) Diagnostic {
    var collector: Diag = undefined;
    collector.reset();
    collector.raise(.E0502);
    collector.cause("the health check worker: {s}", .{cause});
    collector.fix(.{ .sentence = next_interval });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

/// The thread that ends a check at its timeout. It runs with every signal blocked, so the
/// signals `exec_wait` forwards to the command all reach the waiting thread.
const Timer = struct {
    timeout_ms: u32,
    fired: std.atomic.Value(bool) = .init(false),
    pidfd: linux.fd_t = -1,
    /// The timer waits on the read end; the write end closes to stop it early.
    pipe: [2]linux.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,

    /// Starts the timer for `pid`; false when it could not be (the check is then refused).
    fn start(timer: *Timer, pid: linux.pid_t) bool {
        assert(timer.thread == null);
        const pidfd_rc = linux.pidfd_open(pid, 0);
        if (linux.errno(pidfd_rc) != .SUCCESS) return timer.kill_now(pid);
        timer.pidfd = @intCast(pidfd_rc);
        if (linux.errno(linux.pipe2(&timer.pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
            return timer.give_up();
        }
        // The new thread takes the mask it is started with: block everything around the spawn.
        const all = linux.sigfillset();
        var before: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.BLOCK, &all, &before);
        timer.thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Timer.wait, .{timer}) catch
            null;
        _ = linux.sigprocmask(linux.SIG.SETMASK, &before, null);
        if (timer.thread == null) return timer.give_up();
        return true;
    }

    /// No timer: the command must not run unbounded, so it is killed now.
    fn give_up(timer: *Timer) bool {
        _ = linux.pidfd_send_signal(timer.pidfd, .KILL, null, 0);
        _ = linux.close(timer.pidfd);
        timer.pidfd = -1;
        for (&timer.pipe) |*fd| if (fd.* >= 0) {
            _ = linux.close(fd.*);
            fd.* = -1;
        };
        return false;
    }

    /// The pid is the worker's unreaped child, so it is still this command's.
    fn kill_now(timer: *Timer, pid: linux.pid_t) bool {
        assert(timer.pidfd == -1);
        _ = linux.kill(pid, .KILL);
        return false;
    }

    fn wait(timer: *Timer) void {
        var fds = [1]linux.pollfd{.{ .fd = timer.pipe[0], .events = linux.POLL.IN }};
        const timeout: i32 = @intCast(timer.timeout_ms);
        while (true) {
            const rc = linux.poll(&fds, 1, timeout);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue, // Every signal is blocked here; kept for safety.
                else => break, // Cannot wait: end the check rather than leave it unbounded.
            }
            if (rc > 0) return; // Stopped: the command has ended.
            break;
        }
        timer.fired.store(true, .release);
        _ = linux.pidfd_send_signal(timer.pidfd, .KILL, null, 0); // ESRCH: it ended meanwhile.
    }

    /// After `exec_wait`: wakes the thread if it still waits, and joins it.
    fn stop(timer: *Timer) void {
        assert(timer.thread != null);
        _ = linux.close(timer.pipe[1]);
        timer.thread.?.join();
        _ = linux.close(timer.pipe[0]);
        _ = linux.close(timer.pidfd);
        timer.thread = null;
    }
};

const testing = std.testing;

test "probe_worker: each result survives its line" {
    var buffer: [line_bytes_max]u8 = undefined;
    const results = [_]ProbeResult{
        .{ .exited = 0 },
        .{ .exited = 255 },
        .timed_out,
        .{ .refused = failure("the arguments of zcube-agent probe are not valid") },
    };
    for (&results) |*result| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try write_line(&writer, result);
        var back: ProbeResult = undefined;
        try testing.expect(parse_line(&back, writer.buffered()));
        try testing.expectEqual(std.meta.activeTag(result.*), std.meta.activeTag(back));
        switch (result.*) {
            .exited => |code| try testing.expectEqual(code, back.exited),
            .refused => |*diagnostic| {
                try testing.expectEqualStrings(diagnostic.code.slice(), back.refused.code.slice());
                try testing.expectEqualStrings(
                    diagnostic.causes.items[0].slice(),
                    back.refused.causes.items[0].slice(),
                );
                try testing.expectEqualStrings(diagnostic.docs.slice(), back.refused.docs.slice());
            },
            else => {},
        }
    }
}

test "probe_worker: a line that is not exactly one result is refused" {
    var out: ProbeResult = undefined;
    const bad = [_][]const u8{
        "",
        "exited 0",
        "exited 256\n",
        "exited -1\n",
        "exited 0\nexited 1\n",
        "timed_out \n",
        "refused {}\n",
        "refused not json\n",
        "running\n",
        "hello\n",
    };
    for (bad) |line| try testing.expect(!parse_line(&out, line));
}

test "probe_worker: arguments" {
    const ok = parse_args(&.{ "web-1", "2000", "test", "-f", "/tmp/ok" }).?;
    try testing.expectEqualStrings("web-1", ok.name);
    try testing.expectEqual(@as(u32, 2000), ok.timeout_ms);
    try testing.expectEqual(@as(usize, 3), ok.command.len);
    try testing.expect(parse_args(&.{ "web-1", "2000" }) == null);
    try testing.expect(parse_args(&.{ "web-1", "0", "true" }) == null);
    try testing.expect(parse_args(&.{ "web-1", "x", "true" }) == null);
    try testing.expect(parse_args(&.{ "", "10", "true" }) == null);
    try testing.expect(parse_args(&.{ "web-1", "10", "" }) == null);
    var too_many: [constants.runtime_command_words_max + 3][]const u8 = undefined;
    @memset(&too_many, "w");
    too_many[1] = "10";
    try testing.expect(parse_args(&too_many) == null);
    try testing.expect(parse_args(too_many[0 .. too_many.len - 1]) != null);
}
