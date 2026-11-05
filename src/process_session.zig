//! SIGKILL to every process of a session: the shell's way to stop a Zigbox supervisor and all
//! it started, the swarm fetch and its store worker included.
//!
//! The supervisor leads a session of its own (`zigbox_supervisor.run` calls `setsid`), so its
//! session id is its pid. The fetch it starts has a process group of its own inside that session
//! (so that the supervisor can kill the fetch's group at its deadline), which a kill of the
//! supervisor's group does not reach. A session has no kill of its own, so `kill_all` reads
//! `/proc` for the processes whose session is the leader's and kills each.
//!
//! The id is safe to act on: Linux keeps a pid out of use while any process still has it as its
//! session id, so once the caller knows the leader was alive (the launch lock is held), every
//! process with that session id is one of the leader's.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const linux = std.os.linux;

/// The signature `ZigboxRuntime.Options.kill_session` takes; tests swap in a recorder, because
/// their supervisors are simulated pids.
pub const Kill = *const fn (io: std.Io, leader: i32) void;

/// SIGKILL to the group of `leader` and then to every process of its session, read from `/proc`
/// until a read finds none or `session_kill_rounds` are spent. Never waits for them to end.
pub fn kill_all(io: std.Io, leader: i32) void {
    assert(leader > 1);
    _ = linux.kill(-leader, .KILL); // ESRCH: the group is gone already.
    var round: u32 = 0;
    while (round < constants.session_kill_rounds) : (round += 1) {
        if (kill_members(io, leader) == 0) return;
    }
}

/// One read of `/proc`: SIGKILL to each live process of session `session`. How many it signalled.
fn kill_members(io: std.Io, session: i32) u32 {
    assert(session > 1);
    const proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return 0;
    defer proc.close(io);
    var it = proc.iterate();
    var signalled: u32 = 0;
    var seen: u32 = 0;
    while (seen < constants.proc_entries_max) : (seen += 1) {
        const entry = (it.next(io) catch return signalled) orelse return signalled;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue; // Not a process.
        if (pid <= 1) continue;
        var buffer: [512]u8 = undefined;
        const stat = read_stat(io, proc, entry.name, &buffer) orelse continue; // Gone already.
        const member = session_of(stat) orelse continue;
        if (member.session != session or member.zombie) continue;
        _ = linux.kill(pid, .KILL); // ESRCH: it ended in between.
        signalled += 1;
    }
    return signalled;
}

fn read_stat(io: std.Io, proc: std.Io.Dir, name: []const u8, buffer: *[512]u8) ?[]const u8 {
    var path: [32]u8 = undefined;
    const sub = std.fmt.bufPrint(&path, "{s}/stat", .{name}) catch return null;
    return proc.readFile(io, sub, buffer) catch null;
}

const Member = struct { session: i32, zombie: bool };

/// The session and state a `/proc/<pid>/stat` line gives: `pid (comm) state ppid pgrp session
/// ...`. The command may hold any byte, `)` and spaces too, so the fields are read after its
/// last `)`. Null if the line is not of that shape.
fn session_of(stat: []const u8) ?Member {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    _ = fields.next() orelse return null; // ppid
    _ = fields.next() orelse return null; // pgrp
    const session_text = fields.next() orelse return null;
    const session = std.fmt.parseInt(i32, session_text, 10) catch return null;
    return .{ .session = session, .zombie = std.mem.eql(u8, state, "Z") };
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "a stat line's session is read after the command's last parenthesis" {
    const plain = session_of("4242 (sleep) S 1 4240 4200 0 -1 4194560 92 0").?;
    try testing.expectEqual(@as(i32, 4200), plain.session);
    try testing.expect(!plain.zombie);
    const odd = session_of("4243 (a) Z 9 (b) R 1 4243 4201 0").?;
    try testing.expectEqual(@as(i32, 4201), odd.session);
    try testing.expect(!odd.zombie); // The state is the one after the last `)`.
    try testing.expect(session_of("4244 (x) Z 1 4244 77").?.zombie);
    try testing.expect(session_of("garbage") == null);
    try testing.expect(session_of("1 (x) S 1 2") == null);
    try testing.expect(session_of("1 (x) S 1 2 nine") == null);
}

/// Whether `pid` is a live process: in `/proc` and not a zombie (a zombie whose parent is init
/// may wait there for a while; it no longer runs).
pub fn alive(io: std.Io, pid: i32) bool {
    assert(pid > 0);
    const proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{}) catch return false;
    defer proc.close(io);
    var name: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&name, "{d}", .{pid}) catch return false;
    var buffer: [512]u8 = undefined;
    const stat = read_stat(io, proc, text, &buffer) orelse return false;
    const member = session_of(stat) orelse return false;
    return !member.zombie;
}

/// Starts `/bin/bash -c script` as the leader of a new session (`setsid`, which does not fork:
/// the child is not a group leader). Bash, because its `set -m` gives a background job a group
/// of its own without a terminal, and dash's does not. Null when this machine lacks either.
pub fn spawn_session(io: std.Io, script: []const u8) !?std.process.Child {
    std.Io.Dir.accessAbsolute(io, "/usr/bin/setsid", .{}) catch return null;
    std.Io.Dir.accessAbsolute(io, "/bin/bash", .{}) catch return null;
    return try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/setsid", "/bin/bash", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// The pid a test's shell wrote into `name` in `dir`, once it is there (at most 5 s).
pub fn wait_pid_file(io: std.Io, dir: std.Io.Dir, name: []const u8) !i32 {
    var tries: u32 = 0;
    while (tries < 250) : (tries += 1) {
        var text: [32]u8 = undefined;
        const read = dir.readFile(io, name, &text) catch "";
        if (std.mem.endsWith(u8, read, "\n")) {
            return std.fmt.parseInt(i32, std.mem.trim(u8, read, " \n"), 10);
        }
        io.sleep(.fromMilliseconds(20), .awake) catch {}; // Cancelation only ends a try early.
    }
    return error.NoPidFile;
}

test "every process of a session is killed, those in a group of their own too" {
    // Goal: what a supervisor's session holds, a process in another group included (the fetch
    // has one of its own), does not outlive `kill_all`. Method: a session leader whose shell puts
    // `sleep 30` in a job of its own (`set -m`) and writes its pid; after `kill_all` on the
    // leader neither runs.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "set -m; sleep 30 & echo $! > .zig-cache/tmp/{s}/pid; wait",
        .{tmp.sub_path},
    );
    var leader = (try spawn_session(io, script)) orelse return error.SkipZigTest;
    defer leader.kill(io);
    const member = try wait_pid_file(io, tmp.dir, "pid");
    const leader_pid: i32 = leader.id.?;
    try testing.expect(member != leader_pid);
    try testing.expectEqual(@as(usize, @intCast(member)), linux.getpgid(member)); // Its own group.
    kill_all(io, leader_pid);
    _ = try leader.wait(io); // SIGKILL: reaped here, so `alive` cannot see a zombie of ours.
    var tries: u32 = 0;
    while (alive(io, member) and tries < 250) : (tries += 1) {
        io.sleep(.fromMilliseconds(20), .awake) catch {}; // Cancelation only ends a try early.
    }
    try testing.expect(!alive(io, member));
}
