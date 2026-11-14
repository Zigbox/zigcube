//! The agent's containers as the host sees them: what `zig build agent-smoke` and `demo-c0` count
//! and kill. A container is a command under a supervisor (`zcube-agent supervise <dir>`), and its
//! directory under `<state>/containers/` holds the two pids. The counts come from `/proc`, not
//! from the agent's own records, so a duplicate the agent did not know about would be seen.
//!
//! Shell code (files, `/proc`): test and demo tooling, never imported by the server or the agent.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const process_session = @import("process_session.zig");

const Allocator = std.mem.Allocator;

/// The processes a container's directory records.
pub const Pids = struct {
    name_buffer: [constants.demo_name_bytes_max]u8,
    name_len: u8,
    supervisor: i32,
    command: i32,

    pub fn name(pids: *const Pids) []const u8 {
        return pids.name_buffer[0..pids.name_len];
    }
};

/// The fields of `/proc/<pid>/stat` that the checks use.
pub const ProcInfo = struct { parent: i32, group: i32, session: i32, zombie: bool };

pub const Procs = struct {
    io: std.Io,
    arena: Allocator,
    /// The agent's state directory; its `containers/` holds one directory per container.
    state: []const u8,

    /// The containers the agent has made, running or not, by name.
    pub fn containers(procs: Procs) ![]const Pids {
        const root = try std.fmt.allocPrint(procs.arena, "{s}/containers", .{procs.state});
        // No agent has run yet: no containers.
        var dir = std.Io.Dir.cwd().openDir(procs.io, root, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return &.{};
            return err;
        };
        defer dir.close(procs.io);
        var found: std.ArrayList(Pids) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(procs.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > constants.demo_name_bytes_max) continue;
            var sub = dir.openDir(procs.io, entry.name, .{}) catch continue;
            defer sub.close(procs.io);
            const supervisor = read_pid(procs.io, sub, "supervisor.pid") orelse continue;
            const command = read_pid(procs.io, sub, "child.pid") orelse continue;
            var pids: Pids = .{
                .name_buffer = undefined,
                .name_len = @intCast(entry.name.len),
                .supervisor = supervisor,
                .command = command,
            };
            @memcpy(pids.name_buffer[0..entry.name.len], entry.name);
            try found.append(procs.arena, pids);
        }
        std.mem.sort(Pids, found.items, {}, pids_less);
        return found.items;
    }

    fn pids_less(_: void, first: Pids, second: Pids) bool {
        return std.mem.lessThan(u8, first.name(), second.name());
    }

    /// The live containers: the command runs, and its parent is the supervisor that the directory
    /// names (a recycled pid is not). Stopped containers keep their directories and are left out.
    pub fn running_containers(procs: Procs) ![]const Pids {
        var live: std.ArrayList(Pids) = .empty;
        for (try procs.containers()) |pids| {
            const command = procs.proc(pids.command) orelse continue;
            if (command.zombie) continue;
            if (command.parent != pids.supervisor) continue;
            try live.append(procs.arena, pids);
        }
        return live.items;
    }

    pub fn proc(procs: Procs, pid: i32) ?ProcInfo {
        var path: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch return null;
        var buffer: [1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(procs.io, name, &buffer) catch return null;
        return parse_stat(bytes);
    }

    /// The supervisors that run now: processes whose command line is `<agent> supervise` of a
    /// container under our state directory. A scan of /proc, so a duplicate would be seen.
    pub fn supervisors(procs: Procs) !u32 {
        var proc_dir = try std.Io.Dir.cwd().openDir(procs.io, "/proc", .{ .iterate = true });
        defer proc_dir.close(procs.io);
        var count: u32 = 0;
        var iterator = proc_dir.iterate();
        while (try iterator.next(procs.io)) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            if (procs.is_supervisor(pid)) count += 1;
        }
        return count;
    }

    pub fn is_supervisor(procs: Procs, pid: i32) bool {
        const info = procs.proc(pid) orelse return false;
        if (info.zombie) return false;
        var path: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch return false;
        var buffer: [constants.state_path_bytes_max + 256]u8 = undefined;
        const line = std.Io.Dir.cwd().readFile(procs.io, name, &buffer) catch return false;
        if (std.mem.find(u8, line, "supervise") == null) return false;
        return std.mem.find(u8, line, procs.state) != null;
    }

    /// True if the process exists and is not a zombie (one that ended and is not yet collected).
    pub fn alive(procs: Procs, pid: i32) bool {
        const info = procs.proc(pid) orelse return false;
        return !info.zombie;
    }

    /// Kills every process of every container's session: that of each supervisor running under
    /// the state directory, that of each supervisor a container's directory records, live or
    /// dead, and that of each process that runs in the state directory (`in_state`), which
    /// finds what a container left after the agent removed its directory. A command has a
    /// process group of its own inside its supervisor's session, and what it started may
    /// outlive both, so a kill of the supervisor's group is not enough. Agents, which run in our
    /// own session, are the caller's to kill. Returns how many sessions it signalled.
    pub fn kill_supervisor_groups(procs: Procs) u32 {
        var killed: u32 = 0;
        const recorded = procs.containers() catch &.{};
        const ours = own_session(procs.io);
        var proc_dir = std.Io.Dir.cwd().openDir(procs.io, "/proc", .{ .iterate = true }) catch {
            return killed;
        };
        defer proc_dir.close(procs.io);
        var iterator = proc_dir.iterate();
        while (iterator.next(procs.io) catch null) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            const info = procs.proc(pid) orelse continue;
            if (info.zombie) continue;
            if (info.session <= 1) continue;
            if (info.session == ours) continue;
            if (!procs.is_ours(pid, info, recorded)) continue;
            // A session is ours to kill while a process of it lives: Linux keeps its id out of
            // use until then, so it cannot be a stranger's.
            process_session.kill_all(procs.io, info.session);
            killed += 1;
        }
        return killed;
    }

    /// The processes that live in the session of a container whose supervisor is gone: what a
    /// container left behind when it ended (a pid namespace would have taken it along). Zero
    /// while the run is healthy; a demo checks it before its cleanup kills everything. It finds
    /// them by `is_ours`, so it sees what a removed container left only when the agent runs in
    /// the state directory.
    pub fn orphans(procs: Procs) !u32 {
        const recorded = try procs.containers();
        const ours = own_session(procs.io);
        var left: u32 = 0;
        var proc_dir = try std.Io.Dir.cwd().openDir(procs.io, "/proc", .{ .iterate = true });
        defer proc_dir.close(procs.io);
        var iterator = proc_dir.iterate();
        while (try iterator.next(procs.io)) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            const info = procs.proc(pid) orelse continue;
            if (info.zombie) continue;
            if (info.session == ours) continue;
            if (procs.alive(info.session)) continue; // Its supervisor still runs.
            if (procs.is_ours(pid, info, recorded)) left += 1;
        }
        return left;
    }

    /// What still runs after `kill_supervisor_groups`: every process `is_ours`, each counted
    /// once. The caller settles first: a killed process disappears a moment later.
    pub fn survivors(procs: Procs) !u32 {
        const recorded = try procs.containers();
        var left: u32 = 0;
        var proc_dir = try std.Io.Dir.cwd().openDir(procs.io, "/proc", .{ .iterate = true });
        defer proc_dir.close(procs.io);
        var iterator = proc_dir.iterate();
        while (try iterator.next(procs.io)) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            const info = procs.proc(pid) orelse continue;
            if (info.zombie) continue;
            if (procs.is_ours(pid, info, recorded)) left += 1;
        }
        return left;
    }

    /// A process of this state directory's containers: a supervisor of it, a member of the
    /// session of a supervisor a container's directory records, or a process that runs in the
    /// state directory (`in_state`).
    fn is_ours(procs: Procs, pid: i32, info: ProcInfo, recorded: []const Pids) bool {
        if (procs.is_supervisor(pid)) return true;
        if (procs.in_state(pid)) return true;
        for (recorded) |pids| {
            if (pids.supervisor > 1 and pids.supervisor == info.session) return true;
        }
        return false;
    }

    /// True if the process's working directory is the state directory or under it. A demo
    /// starts its agents there, and supervisors, commands and what those start inherit it.
    pub fn in_state(procs: Procs, pid: i32) bool {
        var path: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&path, "/proc/{d}/cwd", .{pid}) catch return false;
        var buffer: [constants.state_path_bytes_max + 64]u8 = undefined;
        const length = std.Io.Dir.readLinkAbsolute(procs.io, name, &buffer) catch return false;
        const cwd = buffer[0..length];
        if (!std.mem.startsWith(u8, cwd, procs.state)) return false;
        return cwd.len == procs.state.len or cwd[procs.state.len] == '/' or
            cwd[procs.state.len] == ' '; // "<dir> (deleted)"
    }
};

/// The session of this process: the demo's own, which its agents and server share.
fn own_session(io: std.Io) i32 {
    var buffer: [1024]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, "/proc/self/stat", &buffer) catch return -1;
    const info = parse_stat(bytes) orelse return -1;
    return info.session;
}

fn read_pid(io: std.Io, dir: std.Io.Dir, name: []const u8) ?i32 {
    var buffer: [32]u8 = undefined;
    const bytes = dir.readFile(io, name, &buffer) catch return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, "\n "), 10) catch null;
}

/// "pid (comm) S ppid pgrp session ...": the fields after the closing parenthesis.
pub fn parse_stat(bytes: []const u8) ?ProcInfo {
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, bytes[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    const parent = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const group = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const session = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    return .{ .parent = parent, .group = group, .session = session, .zombie = state[0] == 'Z' };
}

test "parse_stat reads the fields after the command name, whatever it holds" {
    const plain = parse_stat("12 (sh) S 7 12 12 0 -1").?;
    try std.testing.expectEqual(@as(i32, 7), plain.parent);
    try std.testing.expectEqual(@as(i32, 12), plain.group);
    try std.testing.expect(!plain.zombie);
    const odd = parse_stat("13 (a) b) Z 1 13 14 0").?;
    try std.testing.expect(odd.zombie);
    try std.testing.expectEqual(@as(i32, 14), odd.session);
    try std.testing.expect(parse_stat("no parenthesis") == null);
}
