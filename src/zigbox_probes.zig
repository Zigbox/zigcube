//! The health checks `ZigboxRuntime` has in flight (C3 slice 10): one `zcube-agent probe`
//! worker per check (`probe_worker.zig`), at most one per container. Shell code: processes,
//! pipes, signals.
//!
//! `begin` starts the worker as the leader of a process group of its own, with its standard
//! output on a pipe; `poll` asks the kernel whether it has ended (`waitpid` with WNOHANG, so the
//! agent never blocks) and, once it has, reads its one line. A check is abandoned (a second
//! `begin` for the same container, or the table's end) by SIGKILL to the worker's whole group,
//! which takes the command with it; the worker is reaped later, as supervisors are.
//!
//! The worker bounds the command by `timeout_ms` itself. If it has not ended `worker_grace_ms`
//! after that (a Zigbox call that hangs before the command runs), `poll` kills its group and
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
/// find the container, join it and kill the command. Provisional, for the supervisor to confirm.
pub const worker_grace_ms: u32 = 5_000;

/// At most one check per container, so as many as the runtime has handles.
pub const probes_max: u32 = constants.runtime_handles_max;

const Probe = struct {
    handle: runtime.Handle,
    pid: linux.pid_t,
    /// The read end of the worker's standard output, non-blocking.
    out: linux.fd_t,
    began_ms: u64,
    timeout_ms: u32,
};

pub const Probes = struct {
    probes: [probes_max]Probe = undefined,
    count: u32 = 0,
    /// Workers killed and not yet reaped.
    killed: [probes_max]linux.pid_t = undefined,
    killed_count: u32 = 0,

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
        probes.reap();
        if (probes.index_of(handle)) |index| probes.abandon(index);
        if (probes.count == probes_max) probes.abandon(0); // The oldest; never reached by design.
        if (probes.killed_count == probes_max) probes.reap_blocking();
        var timeout_buffer: [16]u8 = undefined;
        const timeout_text = std.fmt.bufPrint(&timeout_buffer, "{d}", .{timeout_ms}) catch
            unreachable; // A u32 has at most 10 digits.
        var argv: [4 + constants.runtime_command_words_max][]const u8 = undefined;
        argv[0] = exe;
        argv[1] = "probe";
        argv[2] = handle.name();
        argv[3] = timeout_text;
        @memcpy(argv[4..][0..command.len], command);
        const child = std.process.spawn(io, .{
            .argv = argv[0 .. 4 + command.len],
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit, // A worker that fails before its command runs says why here.
            .pgid = 0, // A group of its own: abandoning a check kills the command too.
        }) catch return worker_failed(diag, "start a health check worker");
        const out = child.stdout.?.handle;
        const flags = linux.fcntl(out, linux.F.GETFL, 0);
        const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
        _ = linux.fcntl(out, linux.F.SETFL, flags | nonblock);
        probes.probes[probes.count] = .{
            .handle = handle,
            .pid = child.id.?,
            .out = out,
            .began_ms = now_ms,
            .timeout_ms = timeout_ms,
        };
        probes.count += 1;
    }

    /// Where the check of `handle` stands; null when none is in flight. A final result forgets
    /// the check.
    pub fn poll(probes: *Probes, handle: runtime.Handle, now_ms: u64) ?ProbeResult {
        const index = probes.index_of(handle) orelse return null;
        const probe = &probes.probes[index];
        var status: i32 = 0;
        const rc = linux.waitpid(probe.pid, &status, linux.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) {
                const limit = probe.began_ms + probe.timeout_ms + worker_grace_ms;
                if (now_ms < limit) return .running;
                probes.abandon(index);
                return .{ .refused = refused("the health check worker did not end in time") };
            },
            .INTR => return .running,
            else => {}, // Not our child any more: read what it left.
        }
        var result: ProbeResult = undefined;
        if (!read_result(probe.out, &result)) {
            result = .{ .refused = refused("the health check worker ended without a result") };
        }
        probes.drop(index);
        return result;
    }

    /// Kills every worker still running: their results would have nobody to read them.
    pub fn deinit(probes: *Probes) void {
        while (probes.count > 0) probes.abandon(probes.count - 1);
        probes.reap();
    }

    fn index_of(probes: *const Probes, handle: runtime.Handle) ?u32 {
        for (probes.probes[0..probes.count], 0..) |*probe, index| {
            if (probe.handle.eql(&handle)) return @intCast(index);
        }
        return null;
    }

    fn abandon(probes: *Probes, index: u32) void {
        assert(index < probes.count);
        const pid = probes.probes[index].pid;
        _ = linux.kill(-pid, .KILL); // ESRCH: the group has ended already.
        if (probes.killed_count == probes_max) probes.reap_blocking();
        probes.killed[probes.killed_count] = pid;
        probes.killed_count += 1;
        probes.drop(index);
    }

    fn drop(probes: *Probes, index: u32) void {
        assert(index < probes.count);
        _ = linux.close(probes.probes[index].out);
        probes.count -= 1;
        probes.probes[index] = probes.probes[probes.count];
    }

    /// Collects the killed workers that have ended.
    fn reap(probes: *Probes) void {
        var kept: u32 = 0;
        for (probes.killed[0..probes.killed_count]) |pid| {
            var status: i32 = 0;
            if (linux.waitpid(pid, &status, linux.W.NOHANG) == 0) {
                probes.killed[kept] = pid;
                kept += 1;
            }
        }
        probes.killed_count = kept;
    }

    /// The table of killed workers is full: wait for them. Each was sent SIGKILL, so this is
    /// short.
    fn reap_blocking(probes: *Probes) void {
        for (probes.killed[0..probes.killed_count]) |pid| {
            var status: i32 = 0;
            while (linux.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
        }
        probes.killed_count = 0;
    }
};

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

/// A stand-in for `zcube-agent`: `probe NAME TIMEOUT WORD`, acting on WORD.
const fake_worker =
    \\#!/bin/sh
    \\case "$4" in
    \\  exit3) printf 'exited 3\n' ;;
    \\  timeout) printf 'timed_out\n' ;;
    \\  hang) sleep 30 & wait ;;
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

    fn begin(rig: *Rig, name: []const u8, word: []const u8, timeout_ms: u32) !void {
        const handle = runtime.Handle.init(name);
        try rig.probes.begin(testing.io, rig.exe, handle, &.{word}, timeout_ms, 0, &rig.diag);
    }

    /// Polls at time 0 (the guard never fires) until the check ends.
    fn settle(rig: *Rig, name: []const u8) !ProbeResult {
        const handle = runtime.Handle.init(name);
        for (0..1000) |_| {
            const result = rig.probes.poll(handle, 0) orelse return error.NoProbe;
            if (result.final()) return result;
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        return error.NeverEnded;
    }
};

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

test "zigbox_probes: a worker past its timeout and grace is killed with its group" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "hang", 100);
    const handle = runtime.Handle.init("web-1");
    const pid = rig.probes.probes[0].pid;
    try testing.expect(rig.probes.poll(handle, 100 + worker_grace_ms - 1).? == .running);
    const result = rig.probes.poll(handle, 100 + worker_grace_ms).?;
    try testing.expectEqualStrings("ZC-E0502", result.refused.code.slice());
    try testing.expectEqualStrings(
        "the health check worker did not end in time",
        result.refused.causes.items[0].slice(),
    );
    try testing.expectEqual(@as(u32, 0), rig.probes.count);
    try testing.expectEqual(@as(u32, 1), rig.probes.killed_count);
    rig.probes.reap_blocking();
    // The whole group is gone, the worker's `sleep` with it.
    for (0..500) |_| {
        if (linux.errno(linux.kill(-pid, @fromBackingInt(@intCast(0)))) == .SRCH) break;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    } else return error.GroupAlive;
}

test "zigbox_probes: a second begin abandons the check in flight" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.begin("web-1", "hang", 60_000);
    try rig.begin("web-1", "exit3", 1000);
    try testing.expectEqual(@as(u32, 1), rig.probes.count);
    try testing.expectEqual(@as(u32, 1), rig.probes.killed_count);
    const result = try rig.settle("web-1");
    try testing.expectEqual(@as(u8, 3), result.exited);
}
