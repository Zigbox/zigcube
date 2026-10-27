//! `zig build demo-c0 -Dbackend=sqlite|postgres`: HANDOFF's C0 demo, run for real. The pieces are
//! the processes a deployment runs: `zcube-server` on the chosen backend, one `zcube-agent` with
//! `FakeRuntime`, and the `zcube` command, driven through its command line as a person drives it.
//! Nothing is simulated (`zig build sim-c0` is the simulation, and is never reported as this).
//!
//! The steps are HANDOFF's five, and each asserts its outcome:
//!
//!   1. `zcube apply hello.zon` with 3 replicas: `zcube get service hello` shows 3 running;
//!   2. `kill -9` one of the processes on the host: a replacement starts, 3 again;
//!   3. 5 replicas: two more start; back to 2: three stop (the host's processes are counted);
//!   4. a digest that is not in the fixtures: `zcube why service broken` prints the chain;
//!   5. the store backend stops: a `ZC-` diagnostic that blames it, a bundle, recovery.
//!
//! and the acceptance criteria, in the same run: restarting `zcube-server` changes nothing,
//! restarting the agent re-adopts the processes, and every controller action is recorded with its
//! cause and visible to `zcube why`. docs/demos/c0.md says what runs and what is not covered.
//!
//! The transcript (one section per step, the commands and their real output) goes to standard
//! output and to `--transcript FILE`. Every wait is bounded by a constant in `demo_c0_state.zig`;
//! a timeout names its step. Every process started is killed at the end, and the demo then checks
//! that none is left. Exit 0 only if every assertion held.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const pq = @import("pq.zig");
const demo_host = @import("demo_host.zig");
const decisions = @import("demo_c0_decisions.zig");
const outage = @import("demo_c0_outage.zig");
const steps = @import("demo_c0_steps.zig");
const state = @import("demo_c0_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const usage =
    \\usage: demo_c0 --backend sqlite|postgres --zcube EXE --server EXE --agent EXE --images FILE
    \\               [--postgres SETTINGS --pg-stop CMD --pg-start CMD] [--transcript FILE]
    \\
;

const Options = struct {
    backend: []const u8 = "",
    zcube: []const u8 = "",
    server: []const u8 = "",
    agent: []const u8 = "",
    images: []const u8 = "",
    postgres: []const u8 = "",
    pg_stop: []const u8 = "",
    pg_start: []const u8 = "",
    /// The tool of `zig build pg-up`: when no stop and start commands are given, it is run.
    pg_dev: []const u8 = "",
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
        if (std.mem.eql(u8, name, "--pg-stop")) options.pg_stop = value;
        if (std.mem.eql(u8, name, "--pg-start")) options.pg_start = value;
        if (std.mem.eql(u8, name, "--pg-dev")) options.pg_dev = value;
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
    const backend = backend_of(&host, options) orelse return usage_error(init.io);
    var demo: Demo = .{ .host = &host, .backend = backend };
    return run(&demo);
}

/// SQLite, or Postgres with the commands that stop and start it: the ones given, else the tool
/// of `zig build pg-up` (`stop` keeps the data, `up` starts a stopped server again).
fn backend_of(host: *Host, options: Options) ?state.Backend {
    if (!std.mem.eql(u8, options.backend, "postgres")) return .sqlite;
    const given = options.pg_stop.len > 0 and options.pg_start.len > 0;
    if (!given and options.pg_dev.len == 0) return null;
    const stop = if (given) options.pg_stop else std.fmt.allocPrint(
        host.arena(),
        "{s} stop",
        .{options.pg_dev},
    ) catch return null;
    const start = if (given) options.pg_start else std.fmt.allocPrint(
        host.arena(),
        "{s} up",
        .{options.pg_dev},
    ) catch return null;
    return .{ .postgres = .{
        .conninfo = options.postgres,
        .stop_command = stop,
        .start_command = start,
    } };
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
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-c0-{d}-{d}", .{
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
        ok = false;
    };
    host.cleanup();
    host.section("Cleanup");
    if (demo.store_stopped) {
        switch (demo.backend) {
            .postgres => |control| outage.start_postgres(demo, control) catch {
                ok = false;
            },
            .sqlite => {},
        }
    }
    const left = host.survivors() catch 1;
    if (left == 0) {
        host.say("  ok: every process the demo started is gone (supervisors, commands, ...)", .{});
    } else {
        host.say("  FAILED: {d} processes of this run are still running", .{left});
        ok = false;
    }
    drop_postgres_schema(demo) catch {}; // Best effort: it leaves the database as it was found.
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-c0 PASSED" else "demo-c0 FAILED"});
    return if (ok) 0 else 1;
}

// ---- The store of a Postgres run: the demo starts from an empty one ----

fn drop_postgres_schema(demo: *Demo) !void {
    const control = switch (demo.backend) {
        .postgres => |settings| settings,
        .sqlite => return,
    };
    const host = demo.host;
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const conninfo = try std.fmt.allocPrintSentinel(host.arena(), "{s}", .{control.conninfo}, 0);
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
    try steps.apply(demo);
    try steps.kill(demo);
    try steps.restart_server(demo);
    try steps.restart_agent(demo);
    try steps.scale(demo);
    try steps.broken(demo);
    try steps.explained(demo);
    try outage.run(demo);
}

fn step_start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. Start from nothing");
    host.say("  backend {s}; the demo's directory is {s}", .{ demo.backend.name(), host.work });
    _ = try host.zcube(&.{"version"});
    drop_postgres_schema(demo) catch {
        return host.fail("could not empty the Postgres schema before the run", .{});
    };
    try host.start_server(state.start_wait_ms);
    host.say("  zcube-server is up on 127.0.0.1:{d}, store {s}", .{
        host.port, demo.backend.name(),
    });
    try host.start_agent(state.node);
    const registered = struct {
        fn check(_: void, h: *Host) !bool {
            const listed = h.json("/v1/list?prefix=/nodes/") catch return false;
            return listed.object.get("kvs").?.array.items.len == 1;
        }
    };
    try host.wait_for({}, registered.check, "the node to register", state.start_wait_ms);
    try host.check(true, "one zcube-agent (FakeRuntime) registered as {s}", .{state.node});
}
