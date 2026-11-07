//! The two agents of `demo-b1`: real `zcube-agent` processes with `FakeRuntime`, each with a
//! state directory of its own under the run's, on one machine and 1000m of CPU. A node is powered
//! off the way `demo/kill-node.sh` does it: `kill -9` of the agent, then of every supervisor's
//! process group under its state directory; `kill_agent` kills the agent alone, which leaves its
//! containers running for the restarted agent to adopt.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const host_procs = @import("host_procs.zig");

const Host = demo_host.Host;

pub const names = [_][]const u8{ "node1", "node2" };
pub const count: usize = names.len;

const log_bytes_max: usize = 16 * 1024 * 1024;

pub const Fleet = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    agents: [count]?std.process.Child = @splat(null),
    starts: [count]u32 = @splat(0),

    /// `<work>/state/<node>`: the agent's `--state-dir`, which holds its containers.
    pub fn state_dir(fleet: *Fleet, index: usize) ![]const u8 {
        const host = fleet.host;
        return std.fmt.allocPrint(host.arena(), "{s}/{s}", .{ host.state, names[index] });
    }

    pub fn procs(fleet: *Fleet, index: usize) host_procs.Procs {
        const dir = fleet.state_dir(index) catch @panic("out of memory in the demo's arena");
        return .{ .io = fleet.host.io, .arena = fleet.host.arena(), .state = dir };
    }

    pub fn agent_pid(fleet: *const Fleet, index: usize) ?i32 {
        const child = fleet.agents[index] orelse return null;
        return child.id;
    }

    /// Starts (or restarts) the agent of node `index`; a restart uses the same state directory.
    pub fn start_agent(fleet: *Fleet, index: usize) !void {
        const host = fleet.host;
        assert(fleet.agents[index] == null);
        fleet.starts[index] += 1;
        const arena = host.arena();
        const server = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{host.port});
        const dir = try fleet.state_dir(index);
        try std.Io.Dir.cwd().createDirPath(host.io, dir);
        const args = [_][]const u8{
            "--node",         names[index],
            "--server",       server,
            "--state-dir",    dir,
            "--cpu-millis",   "1000",
            "--memory-bytes", "8589934592",
            "--images",       host.config.images,
            "--verbose",
        };
        const log = try log_name(arena, index, fleet.starts[index]);
        fleet.agents[index] = try host.spawn(host.config.agent_exe, &args, log);
    }

    /// `kill -9` of the agent alone: its supervisors and their commands live on.
    pub fn kill_agent(fleet: *Fleet, index: usize) !void {
        assert(index < count);
        var child = fleet.agents[index] orelse return;
        std.posix.kill(child.id.?, .KILL) catch {}; // Already gone is fine; wait says how.
        _ = try child.wait(fleet.host.io);
        fleet.agents[index] = null;
    }

    /// Writes the fault word (`oom`, `pid_limit`, `lost`) for container `name` of node `index`.
    pub fn fault(fleet: *Fleet, index: usize, name: []const u8, word: []const u8) !void {
        assert(index < count);
        const host = fleet.host;
        const path = try std.fmt.allocPrint(host.arena(), "{s}/faults/{s}", .{
            try fleet.state_dir(index), name,
        });
        try std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = word });
    }

    /// Power off: SIGKILL of the agent, so it cannot revoke its lease, then of every supervisor's
    /// group (the supervisor, its container's command, what that started).
    pub fn power_off(fleet: *Fleet, index: usize) !void {
        assert(index < count);
        var child = fleet.agents[index] orelse return;
        std.posix.kill(child.id.?, .KILL) catch {}; // Already gone is fine; wait says how.
        _ = try child.wait(fleet.host.io);
        fleet.agents[index] = null;
        _ = fleet.procs(index).kill_supervisor_groups();
    }

    /// True if the agent of node `index` is a running process.
    pub fn agent_alive(fleet: *Fleet, index: usize) bool {
        const pid = fleet.agent_pid(index) orelse return false;
        return fleet.procs(index).alive(pid);
    }

    /// What the agent of node `index` has printed since its latest start.
    pub fn agent_log(fleet: *Fleet, index: usize) ![]const u8 {
        const host = fleet.host;
        const name = try log_name(host.arena(), index, fleet.starts[index]);
        const path = try host.path_in_work(name);
        const cwd = std.Io.Dir.cwd();
        return cwd.readFileAlloc(host.io, path, host.arena(), .limited(log_bytes_max));
    }

    /// Kills every agent and every supervisor group of the run.
    pub fn cleanup(fleet: *Fleet) void {
        for (0..count) |index| {
            if (fleet.agents[index]) |*child| child.kill(fleet.host.io);
            fleet.agents[index] = null;
            _ = fleet.procs(index).kill_supervisor_groups();
        }
    }

    /// What still runs after `cleanup`: supervisors and the commands of every container of every
    /// node. Settles first: a killed process disappears a moment later.
    pub fn survivors(fleet: *Fleet) !u32 {
        try fleet.host.io.sleep(.fromMilliseconds(500), .awake);
        var left: u32 = 0;
        for (0..count) |index| {
            const procs_now = fleet.procs(index);
            left += try procs_now.supervisors();
            for (try procs_now.containers()) |pids| {
                if (procs_now.alive(pids.command)) left += 1;
            }
        }
        return left;
    }

    pub fn dump_logs(fleet: *Fleet) void {
        const host = fleet.host;
        for (0..count) |index| {
            for (1..fleet.starts[index] + 1) |start| {
                const name = log_name(host.arena(), index, @intCast(start)) catch continue;
                const path = host.path_in_work(name) catch continue;
                const body = std.Io.Dir.cwd().readFileAlloc(
                    host.io,
                    path,
                    host.arena(),
                    .limited(8192),
                ) catch continue;
                host.say("---- agent {s} start {d} ----\n{s}", .{ names[index], start, body });
            }
        }
    }
};

fn log_name(arena: std.mem.Allocator, index: usize, start: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "agent-{s}-{d}.log", .{ names[index], start });
}
