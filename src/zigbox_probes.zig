//! The health checks `ZigboxRuntime` has in flight (C3 slice 10): one `zcube-agent probe`
//! worker per check (`probe_worker.zig`), at most one per container. Shell code: processes,
//! pipes, signals. Nothing here blocks: every wait is `WNOHANG`.
//!
//! `begin` starts the worker as the leader of a process group of its own, with its standard
//! output on a pipe. The command it runs in the container, and whatever that command starts, stay
//! in that group (Zigbox's joiner forks the command with CLONE_PARENT and no new session), unless
//! the command calls `setsid` or `setpgid` itself, which escapes this.
//!
//! Every end of a check kills the worker's whole group, so nothing the command left running
//! outlives the check:
//!   - the worker ended (`poll`): `waitid` with WNOWAIT sees it end and leaves it a zombie, so
//!     its pid, the group's id, cannot be reused; then SIGKILL to the group, then the reap. This
//!     needs nothing from the worker, so a worker that crashed is covered too;
//!   - the check is abandoned (`abandon`: a second `begin` for the container, the container
//!     stopped or gone, the table full, the worker past its timeout and grace, the agent's exit):
//!     SIGKILL to the group while the worker is unreaped. The entry stays, marked killed, until a
//!     later sweep reaps the worker.
//!
//! The table holds live checks and killed workers not yet reaped. Each `begin` and `poll` first
//! sweeps it: killed workers that ended are reaped and dropped, and a live check whose worker
//! should have ended (`worker_grace_ms` past its timeout) is collected if its worker ended, and
//! abandoned if not. So a check nobody polls again (its replica went away, or its health check
//! was removed) leaves the table within its timeout and grace, without blocking. When the live
//! checks fill their share, a worker that ended is dropped first, else the check begun first is
//! abandoned. A worker that does not die of SIGKILL (stuck in the kernel) keeps its entry; when
//! those fill the table, `begin` is refused (ZC-E0502) rather than waiting.
//!
//! The worker bounds the command by `timeout_ms` itself, counted from when the command has
//! started (after `exec_start`). If it has not ended `worker_grace_ms` after the check began plus
//! that timeout (a Zigbox call that hangs before the command runs), `poll` abandons it and
//! reports the check refused (ZC-E0502).

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const probe_worker = @import("probe_worker.zig");
const runtime = @import("runtime.zig");

const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const ProbeResult = runtime.ProbeResult;

/// How long past its `timeout_ms` a worker may take to report before it is killed: the time to
/// find the container, join it and kill the command. Internal and provisional
/// (docs/decisions/2026-11-14-probe-worker.md).
pub const worker_grace_ms: u32 = 5_000;

/// Live checks: at most one per container, so as many as the runtime has handles.
pub const probes_max: u32 = constants.runtime_handles_max;

/// Live checks and killed workers not yet reaped, together.
pub const entries_max: u32 = 2 * probes_max;

const Entry = struct {
    handle: runtime.Handle,
    pid: linux.pid_t,
    /// The read end of the worker's standard output, non-blocking; -1 once killed.
    out: linux.fd_t,
    began_ms: u64,
    timeout_ms: u32,
    /// Abandoned: its group was sent SIGKILL and it waits to be reaped.
    killed: bool,

    fn limit_ms(entry: *const Entry) u64 {
        return entry.began_ms + entry.timeout_ms + worker_grace_ms;
    }
};

/// Where a worker stands, asked without reaping it.
const Worker = enum { running, ended, not_ours };

pub const Probes = struct {
    entries: [entries_max]Entry = undefined,
    count: u32 = 0,
    /// The bounds, lowered only by tests.
    live_max: u32 = probes_max,
    count_max: u32 = entries_max,

    /// Starts a worker for `handle`, abandoning a check already in flight for it.
    pub fn begin(
        probes: *Probes,
        io: std.Io,
        exe: []const u8,
        handle: runtime.Handle,
        command: []const []const u8,
        timeout_ms: u32,
        now_ms: u64,
        diag: *Diag,
    ) error{RuntimeFailed}!void {
        assert(command.len > 0);
        assert(command.len <= constants.runtime_command_words_max);
        assert(timeout_ms > 0);
        assert(probes.live_max < probes.count_max);
        assert(probes.count_max <= entries_max);
        probes.sweep(now_ms, null);
        if (probes.index_of(handle)) |index| probes.abandon(index);
        if (probes.live_count() == probes.live_max) probes.evict();
        assert(probes.live_count() < probes.live_max);
        if (probes.count == probes.count_max) {
            return worker_failed(diag, "start a health check worker: too many killed workers" ++
                " have not ended");
        }
        const spawned = spawn(io, exe, handle, command, timeout_ms) catch
            return worker_failed(diag, "start a health check worker");
        probes.entries[probes.count] = .{
            .handle = handle,
            .pid = spawned.pid,
            .out = spawned.out,
            .began_ms = now_ms,
            .timeout_ms = timeout_ms,
            .killed = false,
        };
        probes.count += 1;
    }

    /// Where the check of `handle` stands; null when none is in flight. A final result forgets
    /// the check.
    pub fn poll(probes: *Probes, handle: runtime.Handle, now_ms: u64) ?ProbeResult {
        probes.sweep(now_ms, handle); // That check is this poll's to end, with its result.
        const index = probes.index_of(handle) orelse return null;
        const entry = &probes.entries[index];
        switch (worker_state(entry.pid)) {
            .running => {
                if (now_ms < entry.limit_ms()) return .running;
                probes.abandon(index);
                return .{ .refused = refused("the health check worker did not end in time") };
            },
            .ended, .not_ours => {},
        }
        var result: ProbeResult = undefined;
        if (!read_result(entry.out, &result)) {
            result = .{ .refused = refused("the health check worker ended without a result") };
        }
        probes.collect(index);
        return result;
    }

    /// Abandons the check of `handle`, if one is in flight: its container stopped or is gone.
    pub fn forget(probes: *Probes, handle: runtime.Handle) void {
        if (probes.index_of(handle)) |index| probes.abandon(index);
    }

    /// Kills every worker still running: their results would have nobody to read them. Workers
    /// that have not died yet are left to the agent's parent to reap: this never waits.
    pub fn deinit(probes: *Probes) void {
        for (0..probes.count) |index| {
            if (!probes.entries[index].killed) probes.abandon(@intCast(index));
        }
        probes.sweep_killed();
        probes.count = 0;
    }

    pub fn live_count(probes: *const Probes) u32 {
        var live: u32 = 0;
        for (probes.entries[0..probes.count]) |*entry| live += @intFromBool(!entry.killed);
        return live;
    }

    fn index_of(probes: *const Probes, handle: runtime.Handle) ?u32 {
        for (probes.entries[0..probes.count], 0..) |*entry, index| {
            if (!entry.killed and entry.handle.eql(&handle)) return @intCast(index);
        }
        return null;
    }

    /// Reaps the killed workers that ended; ends the live checks past their limit, but for
    /// `skip`'s.
    fn sweep(probes: *Probes, now_ms: u64, skip: ?runtime.Handle) void {
        probes.sweep_killed();
        var index = probes.count;
        while (index > 0) {
            index -= 1;
            const entry = &probes.entries[index];
            if (entry.killed or now_ms < entry.limit_ms()) continue;
            if (skip != null and entry.handle.eql(&skip.?)) continue;
            switch (worker_state(entry.pid)) {
                .running => probes.abandon(index),
                .ended, .not_ours => probes.collect(index),
            }
        }
    }

    /// Drops the killed workers that have been reaped. Backwards, so a swap-remove moves only
    /// entries already seen.
    fn sweep_killed(probes: *Probes) void {
        var index = probes.count;
        while (index > 0) {
            index -= 1;
            const entry = &probes.entries[index];
            if (entry.killed and reap(entry.pid)) probes.remove(index);
        }
    }

    /// The live checks are at their bound: drops a worker that ended (its result is lost), else
    /// abandons the check begun first.
    fn evict(probes: *Probes) void {
        var oldest: ?u32 = null;
        for (probes.entries[0..probes.count], 0..) |*entry, index| {
            if (entry.killed) continue;
            if (worker_state(entry.pid) != .running) return probes.collect(@intCast(index));
            if (oldest == null or entry.began_ms < probes.entries[oldest.?].began_ms) {
                oldest = @intCast(index);
            }
        }
        probes.abandon(oldest.?);
    }

    /// SIGKILL to the worker's group while the worker is unreaped, so the group id is still its.
    fn abandon(probes: *Probes, index: u32) void {
        assert(index < probes.count);
        const entry = &probes.entries[index];
        assert(!entry.killed);
        _ = linux.kill(-entry.pid, .KILL); // ESRCH: the group has ended already.
        _ = linux.close(entry.out);
        entry.out = -1;
        entry.killed = true;
    }

    /// The worker has ended (or is not ours): kills what is left of its group, reaps it, and
    /// drops the entry.
    fn collect(probes: *Probes, index: u32) void {
        assert(index < probes.count);
        const entry = &probes.entries[index];
        assert(!entry.killed);
        // A worker that is not our child has no zombie holding its pid: its group is not sent
        // anything, for the number may be another process's now.
        const ours = worker_state(entry.pid) == .ended;
        if (ours) _ = linux.kill(-entry.pid, .KILL); // ESRCH: nothing was left in the group.
        _ = linux.close(entry.out);
        entry.out = -1;
        // A zombie is reaped at once; if the reap was interrupted, a later sweep finishes it.
        if (!ours or reap(entry.pid)) {
            probes.remove(index);
        } else {
            entry.killed = true;
        }
    }

    fn remove(probes: *Probes, index: u32) void {
        assert(index < probes.count);
        probes.count -= 1;
        probes.entries[index] = probes.entries[probes.count];
    }
};

const Spawned = struct { pid: linux.pid_t, out: linux.fd_t };

fn spawn(
    io: std.Io,
    exe: []const u8,
    handle: runtime.Handle,
    command: []const []const u8,
    timeout_ms: u32,
) !Spawned {
    var timeout_buffer: [16]u8 = undefined;
    const timeout_text = std.fmt.bufPrint(&timeout_buffer, "{d}", .{timeout_ms}) catch
        unreachable; // A u32 has at most 10 digits.
    var argv: [4 + constants.runtime_command_words_max][]const u8 = undefined;
    argv[0] = exe;
    argv[1] = "probe";
    argv[2] = handle.name();
    argv[3] = timeout_text;
    @memcpy(argv[4..][0..command.len], command);
    const child = try std.process.spawn(io, .{
        .argv = argv[0 .. 4 + command.len],
        .stdin = .ignore,
        .stdout = .pipe,
        // Only a worker that fails before it moves its own streams to /dev/null (the copy of
        // its output, the open of /dev/null) can write here; everything else is in its line.
        .stderr = .inherit,
        .pgid = 0, // A group of its own, which the command joins: see the top of the file.
    });
    const out = child.stdout.?.handle;
    const flags = linux.fcntl(out, linux.F.GETFL, 0);
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(out, linux.F.SETFL, flags | nonblock);
    return .{ .pid = child.id.?, .out = out };
}

/// Asks whether `pid` has ended, without reaping it (WNOWAIT): an ended worker stays a zombie,
/// which keeps its pid, and so its group's id, from being reused.
fn worker_state(pid: linux.pid_t) Worker {
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    const flags = linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT;
    const rc = linux.waitid(.PID, pid, &info, flags, null);
    return switch (linux.errno(rc)) {
        .SUCCESS => if (info.fields.common.first.piduid.pid == 0) .running else .ended,
        .INTR => .running,
        else => .not_ours,
    };
}

/// Reaps `pid` if it has ended; true when it is gone (reaped now, or not our child).
fn reap(pid: linux.pid_t) bool {
    var status: i32 = 0;
    const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc != 0,
        .INTR => false, // Not reaped: keep it for the next sweep.
        else => true, // ECHILD: not ours to wait for.
    };
}

/// Reads the worker's whole output (it has ended, so it is all there) and parses it.
fn read_result(fd: linux.fd_t, out: *ProbeResult) bool {
    var buffer: [probe_worker.line_bytes_max + 1]u8 = undefined;
    var used: usize = 0;
    while (used < buffer.len) {
        const rc = linux.read(fd, buffer[used..].ptr, buffer.len - used);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                used += rc;
            },
            .INTR => {},
            else => break, // EAGAIN: something else holds the pipe open; take what came.
        }
    }
    return probe_worker.parse_line(out, buffer[0..used]);
}

fn refused(cause: []const u8) Diagnostic {
    var collector: Diag = undefined;
    collector.reset();
    collector.raise(.E0502);
    collector.cause("{s}", .{cause});
    collector.fix(.{ .sentence = probe_worker.next_interval });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

fn worker_failed(diag: *Diag, operation: []const u8) error{RuntimeFailed} {
    if (diag.code != null) return error.RuntimeFailed;
    diag.raise(.E0502);
    diag.cause("can't {s}", .{operation});
    diag.fix(.{ .sentence = "check the host's process limits" });
    return error.RuntimeFailed;
}

const testing = std.testing;

/// A stand-in for `zcube-agent`: `probe NAME TIMEOUT WORD`, acting on WORD. A word that leaves a
/// child behind writes its pid to `NAME.child` next to the script once the child exists.
const fake_worker =
    \\#!/bin/sh
    \\child() {
    \\  sleep 30 >/dev/null 2>&1 &
    \\  echo $! > "$(dirname "$0")/$2.tmp" && mv "$(dirname "$0")/$2.tmp" "$(dirname "$0")/$2.child"
    \\}
    \\case "$4" in
    \\  exit3) printf 'exited 3\n' ;;
    \\  timeout) printf 'timed_out\n' ;;
    \\  hang) child "$@"; wait ;;
    \\  leave) child "$@"; printf 'exited 0\n' ;;
    \\  garbage) printf 'hello\n' ;;
    \\  *) ;;
    \\esac
    \\
;

const Rig = struct {
    tmp: testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8,
    exe: []const u8,
    probes: Probes,
    diag: Diag,

    fn up(rig: *Rig) !void {
        const io = testing.io;
        rig.tmp = testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        try rig.tmp.dir.writeFile(io, .{ .sub_path = "worker", .data = fake_worker });
        const base = try rig.tmp.dir.realPath(io, &rig.path_buffer);
        const tail = "/worker";
        @memcpy(rig.path_buffer[base..][0..tail.len], tail);
        rig.path_buffer[base + tail.len] = 0;
        rig.exe = rig.path_buffer[0 .. base + tail.len];
        const path: [*:0]const u8 = @ptrCast(rig.exe.ptr);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.chmod(path, 0o755)));
        rig.probes = .{};
        rig.diag.reset();
    }

    fn down(rig: *Rig) void {
        rig.probes.deinit();
        rig.tmp.cleanup();
    }

    fn begin_at(rig: *Rig, name: []const u8, word: []const u8, timeout_ms: u32, now: u64) !void {
        const handle = runtime.Handle.init(name);
        try rig.probes.begin(testing.io, rig.exe, handle, &.{word}, timeout_ms, now, &rig.diag);
    }

    fn begin(rig: *Rig, name: []const u8, word: []const u8, timeout_ms: u32) !void {
        try rig.begin_at(name, word, timeout_ms, 0);
    }

    /// Polls at time 0 (the guard never fires) until the check ends.
    fn settle(rig: *Rig, name: []const u8) !ProbeResult {
        const handle = runtime.Handle.init(name);
        for (0..1000) |_| {
            const result = rig.probes.poll(handle, 0) orelse return error.NoProbe;
            if (result.final()) return result;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.NeverEnded;
    }

    /// The pid of the child the fake worker for `name` left, once it has written it.
    fn child(rig: *Rig, name: []const u8) !linux.pid_t {
        var path: [64]u8 = undefined;
        const file = try std.fmt.bufPrint(&path, "{s}.child", .{name});
        var buffer: [32]u8 = undefined;
        for (0..500) |_| {
            const bytes = rig.tmp.dir.readFile(testing.io, file, &buffer) catch |err| switch (err) {
                error.FileNotFound => {
                    try testing.io.sleep(.fromMilliseconds(10), .awake);
                    continue;
                },
                else => return err,
            };
            return std.fmt.parseInt(linux.pid_t, std.mem.trimEnd(u8, bytes, "\n"), 10);
        }
        return error.NoChild;
    }

    /// The fake worker of a live check, and its child, are both running.
    fn expect_running(rig: *Rig, name: []const u8) !void {
        const index = rig.probes.index_of(runtime.Handle.init(name)) orelse return error.NoProbe;
        try testing.expect(alive(rig.probes.entries[index].pid));
        try testing.expect(alive(try rig.child(name)));
    }
};

/// Not ended: gone from /proc, or a zombie, is dead.
fn alive(pid: linux.pid_t) bool {
    var path: [32]u8 = undefined;
    // Cannot fail: "/proc/", a pid of at most ten digits and "/stat" fit 32 bytes.
    const name = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable;
    var buffer: [512]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(testing.io, name, &buffer) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return false;
    return bytes[close + 2] != 'Z';
}

fn expect_dead(pid: linux.pid_t) !void {
    for (0..500) |_| {
        if (!alive(pid)) return;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.StillAlive;
}

test "zigbox_probes: a worker's line is the check's result, and the check is then forgotten" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "exit3", 1000);
    try rig.begin("web-2", "timeout", 1000);
    try testing.expectEqual(@as(u32, 2), rig.probes.count);
    const first = try rig.settle("web-1");
    try testing.expectEqual(@as(u8, 3), first.exited);
    const second = try rig.settle("web-2");
    try testing.expect(second == .timed_out);
    try testing.expectEqual(@as(u32, 0), rig.probes.count);
    try testing.expect(rig.probes.poll(runtime.Handle.init("web-1"), 0) == null);
}

test "zigbox_probes: a worker that ends without a line is a refused check" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "silent", 1000);
    try rig.begin("web-2", "garbage", 1000);
    for ([_][]const u8{ "web-1", "web-2" }) |name| {
        const result = try rig.settle(name);
        try testing.expectEqualStrings("ZC-E0502", result.refused.code.slice());
        try testing.expectEqualStrings(
            "the health check worker ended without a result",
            result.refused.causes.items[0].slice(),
        );
    }
}

test "zigbox_probes: a worker that ends leaves nothing of its group running" {
    // Goal: a check that passes can still have started a child (a command that backgrounds
    // one); the group dies with the check. Method: the fake worker leaves a `sleep` and exits.
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "leave", 1000);
    const child = try rig.child("web-1");
    const result = try rig.settle("web-1");
    try testing.expectEqual(@as(u8, 0), result.exited);
    try expect_dead(child);
    try testing.expectEqual(@as(u32, 0), rig.probes.count);
}

test "zigbox_probes: a worker past its timeout and grace is killed with its group" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "hang", 100);
    const handle = runtime.Handle.init("web-1");
    const child = try rig.child("web-1");
    try testing.expect(rig.probes.poll(handle, 100 + worker_grace_ms - 1).? == .running);
    try rig.expect_running("web-1");
    const result = rig.probes.poll(handle, 100 + worker_grace_ms).?;
    try testing.expectEqualStrings("ZC-E0502", result.refused.code.slice());
    try testing.expectEqualStrings(
        "the health check worker did not end in time",
        result.refused.causes.items[0].slice(),
    );
    try testing.expectEqual(@as(u32, 0), rig.probes.live_count());
    try expect_dead(child);
    try testing.expect(rig.probes.poll(handle, 100 + worker_grace_ms) == null);
}

test "zigbox_probes: a second begin of the same handle abandons the first with its group" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "hang", 60_000);
    const child = try rig.child("web-1");
    try rig.begin("web-1", "exit3", 1000);
    try testing.expectEqual(@as(u32, 1), rig.probes.live_count());
    try expect_dead(child);
    const result = try rig.settle("web-1");
    try testing.expectEqual(@as(u8, 3), result.exited);
}

test "zigbox_probes: forget kills the check's group" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "hang", 60_000);
    const child = try rig.child("web-1");
    rig.probes.forget(runtime.Handle.init("web-1"));
    rig.probes.forget(runtime.Handle.init("web-2")); // None in flight: nothing happens.
    try testing.expectEqual(@as(u32, 0), rig.probes.live_count());
    try expect_dead(child);
    try testing.expect(rig.probes.poll(runtime.Handle.init("web-1"), 0) == null);
    try testing.expectEqual(@as(u32, 0), rig.probes.count); // That poll's sweep reaped it.
}

test "zigbox_probes: a check never polled again leaves the table after its timeout and grace" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin_at("gone-1", "hang", 100, 0);
    try rig.begin_at("gone-2", "exit3", 100, 0);
    const child = try rig.child("gone-1");
    try rig.begin_at("web-1", "exit3", 100, 100 + worker_grace_ms - 1);
    try testing.expectEqual(@as(u32, 3), rig.probes.live_count());
    try rig.begin_at("web-2", "exit3", 100, 100 + worker_grace_ms);
    try expect_dead(child);
    try testing.expectEqual(@as(u32, 2), rig.probes.live_count());
    try testing.expect(rig.probes.index_of(runtime.Handle.init("gone-1")) == null);
    try testing.expect(rig.probes.index_of(runtime.Handle.init("gone-2")) == null);
}

test "zigbox_probes: a full table abandons the check begun first, not the first slot" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    rig.probes.live_max = 2;
    rig.probes.count_max = 4;
    try rig.begin_at("web-1", "hang", 60_000, 5); // Slot 0, begun last.
    try rig.begin_at("web-2", "hang", 60_000, 1); // Slot 1, begun first.
    const first = try rig.child("web-2");
    try rig.expect_running("web-1");
    try rig.begin_at("web-3", "exit3", 60_000, 10);
    try expect_dead(first);
    try rig.expect_running("web-1");
    try testing.expect(rig.probes.poll(runtime.Handle.init("web-1"), 10).? == .running);
    try testing.expect(rig.probes.index_of(runtime.Handle.init("web-2")) == null);
    try testing.expectEqual(@as(u8, 3), (try rig.settle("web-3")).exited);
}

test "zigbox_probes: a full table drops a worker that ended before it abandons a live one" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    rig.probes.live_max = 2;
    rig.probes.count_max = 4;
    try rig.begin_at("web-1", "hang", 60_000, 1); // Begun first, still running.
    try rig.begin_at("web-2", "exit3", 60_000, 5);
    const ended = rig.probes.entries[rig.probes.index_of(runtime.Handle.init("web-2")).?].pid;
    for (0..500) |_| {
        if (worker_state(ended) == .ended) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.NeverEnded;
    try rig.begin_at("web-3", "exit3", 60_000, 10);
    try rig.expect_running("web-1");
    try testing.expect(rig.probes.index_of(runtime.Handle.init("web-2")) == null);
    try testing.expectEqual(@as(u32, 2), rig.probes.count); // web-2 was reaped, not killed.
}

test "zigbox_probes: begin is refused, not blocked, when killed workers fill the table" {
    // Goal: a worker that does not die of SIGKILL never makes the agent wait. Method: a killed
    // entry for a child that is never signalled stands for it.
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    rig.probes.live_max = 1;
    rig.probes.count_max = 2;
    const stuck = try std.process.spawn(testing.io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const stuck_pid = stuck.id.?;
    defer {
        _ = linux.kill(stuck_pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(stuck_pid, &status, 0);
    }
    rig.probes.entries[0] = .{
        .handle = runtime.Handle.init("stuck"),
        .pid = stuck_pid,
        .out = -1,
        .began_ms = 0,
        .timeout_ms = 1,
        .killed = true,
    };
    rig.probes.count = 1;
    try rig.begin("web-1", "hang", 60_000);
    const child = try rig.child("web-1");
    try testing.expectError(error.RuntimeFailed, rig.begin("web-2", "exit3", 1000));
    try testing.expect(rig.diag.code.? == .E0502);
    try expect_dead(child); // web-1 was evicted to make room, and its group killed.
    try testing.expectEqual(@as(u32, 0), rig.probes.live_count());
    try testing.expectEqual(@as(u32, 2), rig.probes.count);
}
