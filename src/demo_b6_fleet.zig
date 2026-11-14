//! The three agents of `demo-b6`: real `zcube-agent` processes with `FakeRuntime`, each with a
//! state directory of its own under the run's, on one machine and 1000m of CPU, and the labels of
//! B6: `node1` is `tenant=a`, `node2` is `tenant=a` and `exclusive=tenant` (both by `--label`), and
//! `node3` is `tenant=b`, given by `.labels` in a ZON file (`--config`), so both ways an operator
//! labels a node are run. A node is powered off the way `demo/kill-node.sh` does it: `kill -9` of
//! the agent, then of every supervisor's process group under its state directory. (A copy of
//! `demo_b1_fleet.zig` with three nodes and their labels; the demos stay independent.)

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const host_procs = @import("host_procs.zig");

const Host = demo_host.Host;

pub const names = [_][]const u8{ "node1", "node2", "node3" };
/// Each node's labels, as the transcript states them.
pub const labels = [_][]const u8{ "tenant=a", "tenant=a exclusive=tenant", "tenant=b" };
/// The node whose labels come from its configuration file.
pub const configured: usize = 2;
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
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{
            "--node",         names[index],
            "--server",       server,
            "--state-dir",    dir,
            "--cpu-millis",   "1000",
            "--memory-bytes", "8589934592",
            "--images",       host.config.images,
            "--verbose",
        });
        switch (index) {
            0 => try args.appendSlice(arena, &.{ "--label", "tenant=a" }),
            1 => try args.appendSlice(arena, &.{
                "--label", "tenant=a", "--label", "exclusive=tenant",
            }),
            configured => try args.appendSlice(arena, &.{ "--config", try fleet.config_file() }),
            else => unreachable, // `names` has three nodes.
        }
        const log = try log_name(arena, index, fleet.starts[index]);
        fleet.agents[index] = try host.spawn(host.config.agent_exe, args.items, log);
    }

    /// `<work>/node3.zon`, the configuration file of `node3`: its labels and nothing else, so
    /// every other setting comes from the same flags as the other nodes'.
    pub fn config_file(fleet: *Fleet) ![]const u8 {
        const host = fleet.host;
        const path = try host.path_in_work("node3.zon");
        const text = ".{ .labels = .{\"tenant=b\"} }\n";
        try std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = text });
        return path;
    }

    /// `kill -9` of the agent alone: its supervisors and their commands live on.
    pub fn kill_agent(fleet: *Fleet, index: usize) !void {
        assert(index < count);
        var child = fleet.agents[index] orelse return;
        std.posix.kill(child.id.?, .KILL) catch {}; // Already gone is fine; wait says how.
        _ = try child.wait(fleet.host.io);
        fleet.agents[index] = null;
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

    /// What still runs after `cleanup`: supervisors and every process of every container's
    /// session, on every node. Settles first: a killed process disappears a moment later.
    pub fn survivors(fleet: *Fleet) !u32 {
        try fleet.host.io.sleep(.fromMilliseconds(500), .awake);
        var left: u32 = 0;
        for (0..count) |index| {
            left += try fleet.procs(index).survivors();
        }
        return left;
    }

    /// What ended containers left running, on every node (`Procs.orphans`); before `cleanup`.
    pub fn orphans(fleet: *Fleet) !u32 {
        try fleet.host.io.sleep(.fromMilliseconds(500), .awake);
        var left: u32 = 0;
        for (0..count) |index| left += try fleet.procs(index).orphans();
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
