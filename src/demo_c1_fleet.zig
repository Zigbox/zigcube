//! The three agents of `demo-c1`: real `zcube-agent` processes with `FakeRuntime`, each with a
//! state directory of its own under the run's, on one machine. `node1` reaches the server through
//! a fault proxy (`testing/fault_proxy.zig`) that the partition test controls; the others connect
//! directly. A node is powered off the way `demo/kill-node.sh` does it: `kill -9` of the agent,
//! then of every supervisor's process group under its state directory.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const fault_proxy = @import("testing/fault_proxy.zig");
const host_procs = @import("host_procs.zig");

const Host = demo_host.Host;

pub const names = [_][]const u8{ "node1", "node2", "node3" };
pub const count: usize = names.len;
/// The node whose connection to the server the partition test controls.
pub const proxied: usize = 0;
/// The node that is powered off and restarted (HANDOFF's step 3 and 4).
pub const powered_off: usize = 2;

const log_bytes_max: usize = 16 * 1024 * 1024;

pub const Fleet = struct {
    host: *Host,
    gpa: std.mem.Allocator,
    proxy: ?*fault_proxy.Proxy = null,
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

    pub fn start_proxy(fleet: *Fleet) !void {
        assert(fleet.proxy == null);
        fleet.proxy = try fault_proxy.Proxy.start(fleet.gpa, fleet.host.port);
    }

    /// Starts (or restarts) the agent of node `index`; a restart uses the same state directory.
    pub fn start_agent(fleet: *Fleet, index: usize) !void {
        const host = fleet.host;
        assert(fleet.agents[index] == null);
        fleet.starts[index] += 1;
        const arena = host.arena();
        const port = if (index == proxied) fleet.proxy.?.port else host.port;
        const server = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{port});
        const dir = try fleet.state_dir(index);
        try std.Io.Dir.cwd().createDirPath(host.io, dir);
        const args = [_][]const u8{
            "--node",         names[index],
            "--server",       server,
            "--state-dir",    dir,
            "--cpu-millis",   "4000",
            "--memory-bytes", "8589934592",
            "--images",       host.config.images,
            "--verbose",
        };
        const log = try log_name(arena, index, fleet.starts[index]);
        fleet.agents[index] = try host.spawn(host.config.agent_exe, &args, log);
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

    /// Kills every agent and every supervisor group of the run, and stops the proxy.
    pub fn cleanup(fleet: *Fleet) void {
        for (0..count) |index| {
            if (fleet.agents[index]) |*child| child.kill(fleet.host.io);
            fleet.agents[index] = null;
            _ = fleet.procs(index).kill_supervisor_groups();
        }
        if (fleet.proxy) |proxy| proxy.stop();
        fleet.proxy = null;
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
