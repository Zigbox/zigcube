//! `zig build c3-smoke -Dbackend=sqlite|postgres`: C3's demo script (docs/briefs/c3.md, "Demo
//! script") with `FakeRuntime`, a smoke and not `demo-c3`: `zcube-server` on the chosen backend,
//! three `zcube-agent`s (separate state directories on one machine) and the `zcube` command,
//! driven through its command line. It is not the brief's KVM run (three QEMU guests with Zigbox):
//! docs/demos/c3.md says what that leaves out.
//!
//!   1. `app` v1, 3 replicas with a health check; what is refused (E0125 to E0127, E0129);
//!   2. v2 with surge 1, unavailable 0: never fewer than 3 ready, at every revision;
//!   3. v3 whose check never passes: the rollout stops at its first replica and rolls back;
//!      `zcube why` is shown, not asserted (docs/demos/c3.md);
//!   4. history, `rollback --to 1` paused (an agent restarted meanwhile keeps its containers),
//!      resumed (the server restarted mid-rollout resumes it), and an apply during a rollback.
//!
//! A witness (`c3_witness.zig`) follows the store's watch and judges R1 R2 R3 R4 R5 at every
//! revision. Every process started is killed at the end and checked gone. Exit 0 only if every
//! assertion held.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const diag_mod = @import("diag.zig");
const fleet_mod = @import("demo_c1_fleet.zig");
const host_procs = @import("host_procs.zig");
const pq = @import("pq.zig");
const steps = @import("c3_smoke_steps.zig");
const witness_mod = @import("c3_witness.zig");

const Demo = steps.Demo;
const Host = demo_host.Host;
const usage =
    \\usage: c3_smoke --backend sqlite|postgres --zcube EXE --server EXE --agent EXE
    \\               [--postgres SETTINGS] [--transcript FILE]
    \\
;

const Options = struct {
    backend: []const u8 = "",
    zcube: []const u8 = "",
    server: []const u8 = "",
    agent: []const u8 = "",
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
        if (std.mem.eql(u8, name, "--postgres")) options.postgres = value;
        if (std.mem.eql(u8, name, "--transcript")) options.transcript = value;
    }
    if (options.zcube.len == 0 or options.server.len == 0) return null;
    if (options.agent.len == 0) return null;
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
    var witness: witness_mod.Witness = .{ .host = &host };
    var demo: Demo = .{
        .host = &host,
        .nodes = .{
            .context = &fleet,
            .pass = pass,
            .restart_agent = restart_agent,
            .names = &fleet_mod.names,
        },
        .witness = &witness,
        .backend = options.backend,
        .postgres = options.postgres,
    };
    return run(&demo);
}

fn fleet_of(demo: *Demo) *fleet_mod.Fleet {
    return @ptrCast(@alignCast(demo.nodes.context));
}

/// FakeRuntime's nodes are host processes that run without help: time passes in a sleep.
fn pass(context: *anyopaque, ms: u32) !void {
    const fleet: *fleet_mod.Fleet = @ptrCast(@alignCast(context));
    try fleet.host.io.sleep(.fromMilliseconds(ms), .awake);
}

/// SIGKILL of one agent (not its containers), then a start on the same state directory: every
/// container it ran runs on, under the same supervisor, and the new agent adopts them.
fn restart_agent(context: *anyopaque, index: u32) !void {
    const fleet: *fleet_mod.Fleet = @ptrCast(@alignCast(context));
    const host = fleet.host;
    const name = fleet_mod.names[index];
    const before = try fleet.procs(index).running_containers();
    try host.check_quiet(before.len > 0, "{s} runs no container", .{name});
    var child = fleet.agents[index] orelse return host.fail("{s} has no agent", .{name});
    std.posix.kill(child.id.?, .KILL) catch {}; // Already gone is fine; wait says how.
    _ = try child.wait(host.io);
    fleet.agents[index] = null;
    host.say("  kill -9 of {s}'s agent; its containers are left running ({d})", .{
        name, before.len,
    });
    try fleet.start_agent(index);
    const after = try fleet.procs(index).running_containers();
    try host.check(same_containers(before, after), "{s}'s agent restarted; the same {d} " ++
        "containers run, under the same supervisors", .{ name, after.len });
}

fn same_containers(before: []const host_procs.Pids, after: []const host_procs.Pids) bool {
    if (before.len != after.len) return false;
    for (before) |old| {
        for (after) |new| {
            if (!std.mem.eql(u8, old.name(), new.name())) continue;
            if (old.supervisor == new.supervisor and old.command == new.command) break;
            return false;
        } else return false;
    }
    return true;
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
            .lease_ttl_ms = steps.ttl_text,
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
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-c3-smoke-{d}-{d}", .{
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
    host.config.images = try write_images(host);
    if (options.transcript) |path| host.transcript = try cwd.createFile(init.io, path, .{});
}

fn run(demo: *Demo) u8 {
    const host = demo.host;
    defer if (host.transcript) |file| file.close(host.io);
    var ok = true;
    script(demo) catch |err| {
        if (err != error.DemoFailed) host.say("FAILED: {s}", .{@errorName(err)});
        diagnose(host);
        host.dump_logs();
        fleet_of(demo).dump_logs();
        ok = false;
    };
    const started = pids_started(demo);
    host.cleanup();
    fleet_of(demo).cleanup();
    host.section("Cleanup");
    const left = (fleet_of(demo).survivors() catch 1) + still_running(demo, started);
    if (left == 0) {
        host.say("  ok: every process the demo started is gone (agents, supervisors, ...)", .{});
    } else {
        host.say("  FAILED: {d} processes of this run are still running", .{left});
        ok = false;
    }
    drop_postgres_schema(demo) catch {}; // Best effort: it leaves the database as it was found.
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "c3-smoke PASSED" else "c3-smoke FAILED"});
    return if (ok) 0 else 1;
}

/// What the service looked like when a step failed: the rollout, the replicas, the record.
fn diagnose(host: *Host) void {
    host.section("At the failure");
    _ = host.zcube(&.{ "rollout", "status", "app" }) catch {}; // Best effort, after a failure.
    _ = host.zcube(&.{ "get", "replicas", "app" }) catch {}; // Best effort, after a failure.
    _ = host.zcube(&.{ "why", "service", "app" }) catch {}; // Best effort, after a failure.
    const reply = host.call("GET", "/v1/list?prefix=/rollouts/app", "") catch return;
    host.say("GET /v1/list?prefix=/rollouts/app\n{s}", .{reply.body});
}

/// The server and the agents the demo started, as they are before the cleanup kills them.
const Started = struct { pids: [1 + fleet_mod.count]i32 = @splat(0) };

fn pids_started(demo: *Demo) Started {
    var started: Started = .{};
    if (demo.host.server) |child| started.pids[0] = child.id orelse 0;
    for (fleet_of(demo).agents, 0..) |agent, index| {
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
    try steps.v1(demo);
    try steps.refusals(demo);
    try steps.v2(demo);
    try steps.v3(demo);
    try steps.history(demo);
    try steps.rollback_paused(demo);
    try steps.resume_and_restart(demo);
    try steps.apply_wins(demo);
    witness_report(demo);
}

/// The agents' image list: the three digests of the demo (`v3` is present; its check fails).
fn write_images(host: *Host) ![]const u8 {
    const path = try host.path_in_work("images.zon");
    const text = try std.fmt.allocPrint(host.arena(), ".{{ .images = .{{ \"{s}\", \"{s}\", " ++
        "\"{s}\" }} }}\n", .{ steps.fake_images[0], steps.fake_images[1], steps.fake_images[2] });
    try std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = text });
    return path;
}

fn step_start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. Start from nothing");
    host.say("  backend {s}; the demo's directory is {s}", .{ demo.backend, host.work });
    _ = try host.zcube(&.{"version"});
    drop_postgres_schema(demo) catch {
        return host.fail("could not empty the Postgres schema before the run", .{});
    };
    try host.start_server(steps.start_wait_ms);
    host.say("  zcube-server is up on 127.0.0.1:{d}, store {s}, lease ttl {s} ms", .{
        host.port, demo.backend, steps.ttl_text,
    });
    try fleet_of(demo).start_proxy();
    var fault_dirs: [fleet_mod.count][]const u8 = undefined;
    for (0..fleet_mod.count) |index| {
        try fleet_of(demo).start_agent(index);
        fault_dirs[index] = try std.fmt.allocPrint(host.arena(), "{s}/faults", .{
            try fleet_of(demo).state_dir(index),
        });
    }
    demo.witness.fault_dirs = try host.arena().dupe([]const u8, &fault_dirs);
    host.say("  three zcube-agents (FakeRuntime) started; images {s} (v1), {s} (v2), {s} (v3)", .{
        steps.fake_images[0], steps.fake_images[1], steps.fake_images[2],
    });
    try demo.witness.start();
}

fn witness_report(demo: *Demo) void {
    const tally = demo.witness.tally;
    demo.host.section("The witness");
    demo.host.say("  ok: R1 R2 R3 R4 R5 held at each of {d} revisions; {d} replicas created, " ++
        "{d} retired, at most {d} live; {d} health faults scripted", .{
        tally.revisions, tally.created, tally.retirements, tally.live_max, tally.faults_written,
    });
}
