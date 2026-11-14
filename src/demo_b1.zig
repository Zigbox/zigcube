//! `zig build demo-b1 -Dbackend=sqlite|postgres`: B1's demo (docs/briefs/b1.md), run for real:
//! `zcube-server` on the chosen backend, two `zcube-agent`s with `FakeRuntime` of 1000m CPU each
//! and the `zcube` command, as processes. Nothing is simulated except what the fake runtime
//! is told to (OOM through its fault file).
//!
//! The steps (docs/demos/b1.md says what each asserts and what is cut):
//!
//!   1. six jobs end in the right state and for the right cause; `job run` is idempotent;
//!   2. a watcher is killed after the third ending and restarted from its last revision;
//!   3. `kill -9` of an agent while its job runs: the job is adopted and exits 5;
//!   4. a node powered off under a job: `failed unreachable`, not started elsewhere;
//!   5. five jobs of 500m on two nodes of 1000m: four run, the fifth waits, then runs.
//!
//! The transcript goes to standard output and to `--transcript FILE`. Every wait is bounded by a
//! constant in `demo_b1_state.zig`. Every process started is killed at the end, and the demo then
//! checks that none is left. Exit 0 only if every assertion held.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const diag_mod = @import("diag.zig");
const fleet_mod = @import("demo_b1_fleet.zig");
const endings = @import("demo_b1_endings.zig");
const nodes = @import("demo_b1_nodes.zig");
const packing = @import("demo_b1_packing.zig");
const pq = @import("pq.zig");
const state = @import("demo_b1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const usage =
    \\usage: demo_b1 --backend sqlite|postgres --zcube EXE --server EXE --agent EXE --images FILE
    \\               [--postgres SETTINGS] [--transcript FILE]
    \\
;

const Options = struct {
    backend: []const u8 = "",
    zcube: []const u8 = "",
    server: []const u8 = "",
    agent: []const u8 = "",
    images: []const u8 = "",
    postgres: []const u8 = "",
    transcript: ?[]const u8 = null,
};

fn parse_options(args: []const []const u8) ?Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return null;
        const value = args[index + 1];
        const name = args[index];
        if (std.mem.eql(u8, name, "--backend")) options.backend = value;
        if (std.mem.eql(u8, name, "--zcube")) options.zcube = value;
        if (std.mem.eql(u8, name, "--server")) options.server = value;
        if (std.mem.eql(u8, name, "--agent")) options.agent = value;
        if (std.mem.eql(u8, name, "--images")) options.images = value;
        if (std.mem.eql(u8, name, "--postgres")) options.postgres = value;
        if (std.mem.eql(u8, name, "--transcript")) options.transcript = value;
    }
    if (options.zcube.len == 0 or options.server.len == 0) return null;
    if (options.agent.len == 0 or options.images.len == 0) return null;
    return options;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    const options = parse_options(args) orelse return usage_error(init.io);
    const is_postgres = std.mem.eql(u8, options.backend, "postgres");
    if (!is_postgres and !std.mem.eql(u8, options.backend, "sqlite")) return usage_error(init.io);
    if (is_postgres and options.postgres.len == 0) return usage_error(init.io);
    var host: Host = undefined;
    prepare(&host, init, options) catch return 2;
    defer host.arena_state.deinit();
    defer host.cli_environ.deinit();
    var fleet: fleet_mod.Fleet = .{ .host = &host, .gpa = init.gpa };
    var demo: Demo = .{
        .host = &host,
        .fleet = &fleet,
        .backend = options.backend,
        .postgres = options.postgres,
    };
    return run(&demo);
}

fn usage_error(io: std.Io) u8 {
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {}; // Nowhere else to say it.
    return 2;
}

/// Sets up the demo's directory, the CLI's environment and the transcript file.
fn prepare(host: *Host, init: std.process.Init, options: Options) !void {
    const stamp: u64 = @intCast(std.Io.Clock.real.now(init.io).toMilliseconds());
    host.* = .{
        .io = init.io,
        .arena_state = .init(init.gpa),
        .config = .{
            .server_exe = "",
            .agent_exe = "",
            .cli_exe = "",
            .images = "",
            .store = "",
            .transcript_path = options.transcript,
            .lease_ttl_ms = state.ttl_text,
        },
        .work = "",
        .state = "",
        .port = try demo_host.free_port(init.io, stamp),
        .cli_environ = std.process.Environ.Map.init(init.gpa),
    };
    const arena = host.arena();
    // The command runs in the demo's directory, so every path it is given must be absolute.
    const cwd = std.Io.Dir.cwd();
    host.config.server_exe = try cwd.realPathFileAlloc(init.io, options.server, arena);
    host.config.agent_exe = try cwd.realPathFileAlloc(init.io, options.agent, arena);
    host.config.cli_exe = try cwd.realPathFileAlloc(init.io, options.zcube, arena);
    host.config.images = try cwd.realPathFileAlloc(init.io, options.images, arena);
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-b1-{d}-{d}", .{
        base, std.os.linux.getpid(), stamp,
    });
    host.state = try std.fmt.allocPrint(arena, "{s}/state", .{host.work});
    try cwd.createDirPath(init.io, host.state);
    try cwd.createDirPath(init.io, try host.path_in_work("home"));
    try host.cli_environ.put("PATH", init.environ_map.get("PATH") orelse "/usr/bin:/bin");
    try host.cli_environ.put("HOME", try host.path_in_work("home"));
    try host.cli_environ.put("XDG_STATE_HOME", try host.path_in_work("xdg"));
    try host.cli_environ.put("USER", "demo");
    try host.cli_environ.put("ZCUBE_SERVER", try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{
        host.port,
    }));
    host.config.store = if (std.mem.eql(u8, options.backend, "postgres"))
        try std.fmt.allocPrint(arena, "postgres:{s}", .{options.postgres})
    else
        try std.fmt.allocPrint(arena, "sqlite:{s}/store.db", .{host.work});
    if (options.transcript) |path| host.transcript = try cwd.createFile(init.io, path, .{});
}

fn run(demo: *Demo) u8 {
    const host = demo.host;
    defer if (host.transcript) |file| file.close(host.io);
    var ok = true;
    script(demo) catch |err| {
        if (err != error.DemoFailed) host.say("FAILED: {s}", .{@errorName(err)});
        host.dump_logs();
        demo.fleet.dump_logs();
        ok = false;
    };
    // Before the cleanup, which kills everything: what an ended container left running.
    const orphaned = demo.fleet.orphans() catch 1;
    const started = pids_started(demo);
    host.cleanup();
    demo.fleet.cleanup();
    endings.stop_watcher(demo);
    host.section("Cleanup");
    const left = (demo.fleet.survivors() catch 1) +
        still_running(demo, started);
    if (orphaned == 0) {
        host.say("  ok: no ended container left a process running", .{});
    } else {
        host.say("  FAILED: {d} processes outlived the containers that started them", .{orphaned});
        ok = false;
    }
    if (left == 0) {
        host.say("  ok: every process the demo started is gone (agents, supervisors, ...)", .{});
    } else {
        host.say("  FAILED: {d} processes of this run are still running", .{left});
        ok = false;
    }
    drop_postgres_schema(demo) catch {}; // Best effort: it leaves the database as it was found.
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-b1 PASSED" else "demo-b1 FAILED"});
    return if (ok) 0 else 1;
}

/// The server and the agents the demo started, as they are before the cleanup kills them.
const Started = struct { pids: [1 + fleet_mod.count]i32 = @splat(0) };

fn pids_started(demo: *Demo) Started {
    var started: Started = .{};
    if (demo.host.server) |child| started.pids[0] = child.id orelse 0;
    for (demo.fleet.agents, 0..) |agent, index| {
        if (agent) |child| started.pids[1 + index] = child.id orelse 0;
    }
    return started;
}

/// How many of those processes still run: `kill` reaps its child, so none may.
fn still_running(demo: *Demo, started: Started) u32 {
    const procs = demo.host.procs();
    var count: u32 = 0;
    for (started.pids) |pid| {
        if (pid > 1 and procs.alive(pid)) count += 1;
    }
    return count;
}

// ---- The store of a Postgres run: the demo starts from an empty one ----

fn drop_postgres_schema(demo: *Demo) !void {
    if (!std.mem.eql(u8, demo.backend, "postgres")) return;
    const host = demo.host;
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const conninfo = try std.fmt.allocPrintSentinel(host.arena(), "{s}", .{demo.postgres}, 0);
    const conn = pq.connect(&diag, conninfo, "SELECT 1") catch return error.DemoFailed;
    defer pq.close(conn);
    var result = pq.exec_simple(&diag, conn, "DROP SCHEMA IF EXISTS zcube CASCADE", .{}) catch {
        return error.DemoFailed;
    };
    result.clear();
}

// ---- The script ----

fn script(demo: *Demo) !void {
    try step_start(demo);
    try endings.first_three(demo);
    try endings.last_three(demo);
    try nodes.adoption(demo);
    try nodes.power_off(demo);
    try packing.run(demo);
}

fn step_start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. Start from nothing");
    host.say("  backend {s}; the demo's directory is {s}", .{ demo.backend, host.work });
    _ = try host.zcube(&.{"version"});
    drop_postgres_schema(demo) catch {
        return host.fail("could not empty the Postgres schema before the run", .{});
    };
    try host.start_server(state.start_wait_ms);
    host.say("  zcube-server is up on 127.0.0.1:{d}, store {s}, lease ttl {d} ms", .{
        host.port, demo.backend, state.ttl_ms,
    });
    for (0..fleet_mod.count) |index| try demo.fleet.start_agent(index);
    host.say("  two zcube-agents (FakeRuntime, 1000m CPU each) started", .{});
}
