//! The local-mode step of `demo-c1` (c1.md, "Local mode"): on copies of the executables in a
//! directory of its own, `zcube local up` starts a server on SQLite and one agent, `zcube apply`
//! of `hello.zon` reaches 3 running, and `zcube local down` stops both. The containers outlive
//! `down` on purpose, so the demo stops them itself (`stop_all`), and `demo_c1.zig` calls it at
//! the end whatever happened.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const host_procs = @import("host_procs.zig");
const state = @import("demo_c1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const replicas: u32 = 3;
const address_prefix = "  export ZCUBE_SERVER=";

fn local_dir(host: *Host) ![]const u8 {
    return host.path_in_work("local");
}

pub fn procs(host: *Host) host_procs.Procs {
    const dir = std.fmt.allocPrint(host.arena(), "{s}/agent", .{local_dir(host) catch ""}) catch "";
    return .{ .io = host.io, .arena = host.arena(), .state = dir };
}

/// Copies the three executables beside one another: `zcube local` finds the server and the agent
/// beside itself.
fn copy_executables(host: *Host) ![]const u8 {
    const bin = try host.path_in_work("local-bin");
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(host.io, bin);
    const config = host.config;
    const from = [_][]const u8{ config.cli_exe, config.server_exe, config.agent_exe };
    const names = [_][]const u8{ "zcube", "zcube-server", "zcube-agent" };
    for (from, names) |source, name| {
        const to = try std.fmt.allocPrint(host.arena(), "{s}/{s}", .{ bin, name });
        try cwd.copyFile(source, cwd, to, host.io, .{});
    }
    return std.fmt.allocPrint(host.arena(), "{s}/zcube", .{bin});
}

fn running_count(host: *Host) !u32 {
    const rows = (try state.replica_rows(host, "hello")) orelse return 0;
    return state.c0.count_status(rows, "running");
}

fn three_run(_: void, host: *Host) !bool {
    return try running_count(host) == replicas;
}

pub fn run(demo: *Demo) !void {
    const host = demo.host;
    host.section("6. local mode: zcube local up, apply hello.zon, see it run");
    const saved_environ = host.cli_environ;
    const saved_exe = host.config.cli_exe;
    defer host.cli_environ = saved_environ;
    defer host.config.cli_exe = saved_exe;
    host.config.cli_exe = try copy_executables(host);
    var plain = try saved_environ.clone(host.arena());
    _ = plain.swapRemove("ZCUBE_SERVER");
    try plain.put("ZCUBE_LOCAL_DIR", try local_dir(host));
    host.cli_environ = plain;
    const up = try host.zcube(&.{ "local", "up" });
    const started = up.code == 0 and state.contains(up.out, "local: up");
    try host.check(started, "zcube local up exits 0", .{});
    const at = std.mem.find(u8, up.out, address_prefix) orelse {
        return host.fail("zcube local up did not print the address to export", .{});
    };
    var address = up.out[at + address_prefix.len ..];
    if (std.mem.findScalar(u8, address, '\n')) |end| address = address[0..end];
    var served = try plain.clone(host.arena());
    try served.put("ZCUBE_SERVER", address);
    host.cli_environ = served;
    try state.write_service(host, "hello", replicas);
    const applied = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try host.check(state.contains(applied.out, "applied service hello: created"), "applied " ++
        "service hello: created", .{});
    try host.wait_for({}, three_run, "3 replicas to run in local mode", state.converge_ms);
    const supervisors = try procs(host).supervisors();
    try host.check(supervisors == replicas, "the host runs {d} supervisors under the local " ++
        "agent", .{supervisors});
    _ = try host.zcube(&.{ "get", "replicas", "hello" });
    const down = try host.zcube(&.{ "local", "down" });
    try host.check(down.code == 0 and state.contains(down.out, "local: stopped"), "zcube local " ++
        "down stops the server and the agent", .{});
}

/// Kills what the step started, best effort: `down`, then every supervisor group of the local
/// agent (containers outlive `down` on purpose).
pub fn stop_all(demo: *Demo) void {
    const host = demo.host;
    _ = procs(host).kill_supervisor_groups();
    for ([_][]const u8{ "server", "agent" }) |role| {
        const name = std.fmt.allocPrint(host.arena(), "{s}/{s}.pid", .{
            local_dir(host) catch return, role,
        }) catch return;
        var buffer: [64]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(host.io, name, &buffer) catch continue;
        var tokens = std.mem.tokenizeAny(u8, bytes, " \n");
        const pid = std.fmt.parseInt(i32, tokens.next() orelse continue, 10) catch continue;
        std.posix.kill(pid, .KILL) catch {}; // May be gone.
    }
}
