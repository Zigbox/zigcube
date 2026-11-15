//! `zig build demo-c3`: C3's demo, run for real (docs/briefs/c3.md, "Demo script" and "How
//! demo-c3 runs"; docs/demos/c3.md). zcube-server runs on the host over SQLite; three QEMU guests
//! (the rig of src/demo_c2_vms.zig, its first three) each run `zcube-agent --runtime zigbox` as
//! root, which pulls the service's images through Google's mirror of Docker Hub. The steps are
//! c3-smoke's (`c3_smoke_steps.zig`) and the witness is `c3_witness.zig`, which judges R1 to R5
//! at every revision; only the nodes, the images and the health differ:
//!
//!   - v1, v2 and v3 are three digest-pinned Alpine releases (3.19, 3.20, 3.21). Their tree
//!     digests depend on the host that pulls them, so the demo learns them on guest 1 first, in a
//!     scratch store it deletes.
//!   - The app is the same `sh -c` in every version: after 3 s it creates /tmp/ready unless
//!     /etc/alpine-release says 3.21, and then sleeps. The health check is `test -f /tmp/ready`,
//!     so v3 never becomes healthy because of what its image holds, with no fault scripted.
//!   - Step 4b's agent restart is a `kill -9` on guest 2; `guest.sh containers` before and after
//!     shows the same supervisors and children.
//!
//! Skips unless `ZCUBE_REAL_HOST=1`: it boots three QEMU guests and pulls images. The transcript
//! goes to standard output and to `--transcript FILE`. Exit 0 only if every assertion held.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const steps = @import("c3_smoke_steps.zig");
const vms = @import("demo_c2_vms.zig");
const witness_mod = @import("c3_witness.zig");

const Demo = steps.Demo;
const Host = demo_host.Host;

const usage =
    \\usage: demo_c3 --zcube EXE --server EXE --agent EXE --zbx EXE --guest-script FILE
    \\               [--transcript FILE]
    \\
;

/// The guests the demo boots: node1, node2 and node3.
const nodes_count = 3;

/// v1, v2 and v3: public Alpine images on Docker Hub, pinned to their linux/amd64 manifests
/// (docs/demos/c3.md records them).
pub const references = [3][]const u8{
    "alpine:3.19@sha256:b58899f069c47216f6002a6850143dc6fae0d35eb8b0df9300bbe6327b9c2171",
    "alpine:3.20@sha256:c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e",
    "alpine:3.21@sha256:2d8a11041a92082ba21e364dec73559ce44f1de69b60fa68315f6d3774e59117",
};

/// The app of every version. v3's image is Alpine 3.21, so v3 never creates /tmp/ready.
pub const command = "sleep 3; case $(cat /etc/alpine-release) in 3.21.*) ;; " ++
    "*) touch /tmp/ready ;; esac; while true; do sleep 1; done";

/// The check runs in the guest's container through Zigbox's exec: slower than FakeRuntime's, so
/// a longer interval, and a start period that covers the app's 3 s.
const health = ".interval_ms = 2000, .timeout_ms = 2000, .start_period_ms = 10000, " ++
    ".failure_threshold = 2, .success_threshold = 1";
/// A new replica may wait for its node's first pull of the image: `ready_timeout_ms` covers it.
const rollout = ".max_surge = 1, .max_unavailable = 0, .min_ready_ms = 2000, " ++
    ".ready_timeout_ms = 120000, .progress_deadline_ms = 600000, .grace_ms = 2000, " ++
    ".on_failure = .rollback";

/// Bounds of the steps' waits on real guests: a rollout may pull its image on three nodes.
const rollout_ms: u32 = 6 * 60 * 1000;
/// v3's replica must be placed, miss `ready_timeout_ms` and be rolled back.
const failure_ms: u32 = 8 * 60 * 1000;
/// The guests' agents to register.
const join_ms: u32 = 2 * 60 * 1000;
/// How long a `guest.sh` command may run (`learn` pulls an image).
const guest_timeout_s: u32 = 300;

const Options = struct {
    zcube: []const u8 = "",
    server: []const u8 = "",
    agent: []const u8 = "",
    zbx: []const u8 = "",
    guest_script: []const u8 = "",
    transcript: ?[]const u8 = null,
};

fn parse_options(args: []const []const u8) ?Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return null;
        const value = args[index + 1];
        const name = args[index];
        if (std.mem.eql(u8, name, "--zcube")) options.zcube = value;
        if (std.mem.eql(u8, name, "--server")) options.server = value;
        if (std.mem.eql(u8, name, "--agent")) options.agent = value;
        if (std.mem.eql(u8, name, "--zbx")) options.zbx = value;
        if (std.mem.eql(u8, name, "--guest-script")) options.guest_script = value;
        if (std.mem.eql(u8, name, "--transcript")) options.transcript = value;
    }
    if (options.zcube.len == 0 or options.server.len == 0) return null;
    if (options.agent.len == 0 or options.zbx.len == 0) return null;
    if (options.guest_script.len == 0) return null;
    return options;
}

/// The run's nodes: the guests, and the server as they reach it.
const Machines = struct {
    host: *Host,
    guests: *vms.Guests,
    /// `10.0.2.2:<port>`: the host's loopback as QEMU's user networking shows it to a guest.
    server: []const u8,
};

pub fn main(init: std.process.Init) u8 {
    const stdout = std.Io.File.stdout();
    const real = init.minimal.environ.getPosix("ZCUBE_REAL_HOST") orelse "";
    if (!std.mem.eql(u8, real, "1")) {
        const skipped = "demo-c3: skipped (set ZCUBE_REAL_HOST=1; it boots three QEMU guests)\n";
        stdout.writeStreamingAll(init.io, skipped) catch {}; // Nowhere else to say it.
        return 0;
    }
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    const options = parse_options(args) orelse {
        std.Io.File.stderr().writeStreamingAll(init.io, usage) catch {}; // As above.
        return 2;
    };
    var host: Host = undefined;
    prepare(&host, init, options) catch |err| {
        std.debug.print("demo-c3: setup failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer host.arena_state.deinit();
    defer host.cli_environ.deinit();
    var vm_out: std.Io.File.Writer = .initStreaming(stdout, init.io, &.{});
    var guests: vms.Guests = .{
        .peer_ports = @splat(0),
        .out = &vm_out.interface,
        .limit = nodes_count,
    };
    // Each guest forwards its peer port, unused here (no peer fetch): a free host port each.
    for (guests.peer_ports[0..nodes_count], 1..) |*port, index| {
        port.* = demo_host.free_port(init.io, @as(u64, host.port) * 31 + index) catch return 2;
    }
    var machines: Machines = .{
        .host = &host,
        .guests = &guests,
        .server = std.fmt.allocPrint(host.arena(), "10.0.2.2:{d}", .{host.port}) catch return 2,
    };
    var witness: witness_mod.Witness = .{ .host = &host };
    var demo: Demo = .{
        .host = &host,
        .nodes = .{
            .context = &machines,
            .pass = pass,
            .restart_agent = restart_agent,
            .names = vms.names[0..nodes_count],
        },
        .witness = &witness,
        .backend = "sqlite",
        .postgres = "",
    };
    return run(&demo, init, options);
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
    const cwd = std.Io.Dir.cwd();
    host.config.server_exe = try cwd.realPathFileAlloc(init.io, options.server, arena);
    host.config.cli_exe = try cwd.realPathFileAlloc(init.io, options.zcube, arena);
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-c3-{d}-{d}", .{
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
    host.config.store = try std.fmt.allocPrint(arena, "sqlite:{s}/store.db", .{host.work});
    if (options.transcript) |path| host.transcript = try cwd.createFile(init.io, path, .{});
}

fn run(demo: *Demo, init: std.process.Init, options: Options) u8 {
    const host = demo.host;
    const machines = machines_of(demo.nodes.context);
    defer if (host.transcript) |file| file.close(host.io);
    var ok = true;
    boot_and_run(demo, init, options) catch |err| {
        if (err != error.DemoFailed) host.say("FAILED: {s}", .{@errorName(err)});
        diagnose(host);
        guest_logs(machines);
        host.dump_logs();
        ok = false;
    };
    host.section("Cleanup");
    host.cleanup();
    machines.guests.shutdown();
    machines.guests.deinit(host.io);
    host.say("  the server is stopped and the guests are powered off", .{});
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-c3 PASSED" else "demo-c3 FAILED"});
    return if (ok) 0 else 1;
}

fn boot_and_run(demo: *Demo, init: std.process.Init, options: Options) !void {
    const host = demo.host;
    const machines = machines_of(demo.nodes.context);
    host.section("Boot: three QEMU guests through zigbox_vm");
    var bodies: [vms.uploads.len][]const u8 = undefined;
    const paths = [vms.uploads.len][]const u8{ options.agent, options.zbx, options.guest_script };
    for (&bodies, paths) |*body, path| {
        body.* = try std.Io.Dir.cwd().readFileAlloc(init.io, path, host.arena(), .unlimited);
    }
    const started = host.now_ms();
    try machines.guests.boot(init, bodies);
    host.say("  the guests booted and were provisioned in {d} ms", .{host.now_ms() - started});
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

/// The server, the images' tree digests, three agents, then the witness.
fn step_start(demo: *Demo) !void {
    const host = demo.host;
    const machines = machines_of(demo.nodes.context);
    host.section("0. Start: zcube-server on the host, an agent on each guest");
    _ = try host.zcube(&.{"version"});
    try host.start_server(steps.start_wait_ms);
    host.say("  zcube-server is up on 127.0.0.1:{d} (SQLite); the guests reach it at {s}", .{
        host.port, machines.server,
    });
    for (0..nodes_count) |index| _ = try guest(machines, index, "setup-root", .{});
    // A tree digest depends on the host that pulls the image: learn each on guest 1, in a
    // scratch store, so every node's agent still pulls for real.
    var trees: [3][]const u8 = undefined;
    for (&trees, references) |*tree, reference| tree.* = try learn(machines, reference);
    demo.setup = .{
        .images = trees,
        .sources = references,
        .command = command,
        .health = health,
        .rollout = rollout,
        .min_ready_ms = 2000,
        .rollout_ms = rollout_ms,
        .failure_ms = failure_ms,
        .v3_fails = "its image is Alpine 3.21, so the app never creates /tmp/ready",
    };
    for (0..nodes_count) |index| {
        _ = try guest(machines, index, "agent {s} {s}", .{ vms.names[index], machines.server });
    }
    try wait_nodes(demo);
    _ = try host.zcube(&.{ "get", "nodes" });
    host.say("  images: v1 {s} = {s}", .{ references[0], trees[0] });
    host.say("          v2 {s} = {s}", .{ references[1], trees[1] });
    host.say("          v3 {s} = {s}", .{ references[2], trees[2] });
    try demo.witness.start();
}

fn learn(machines: *Machines, reference: []const u8) ![]const u8 {
    const output = try guest(machines, 0, "learn {s}", .{reference});
    const at = std.mem.indexOf(u8, output, "tree b3:") orelse
        return machines.host.fail("no tree learned for {s}", .{reference});
    const tree = output[at + "tree ".len ..];
    const length = "b3:".len + 64;
    if (tree.len < length) return machines.host.fail("a short tree for {s}", .{reference});
    return tree[0..length];
}

/// The three agents registered: three `/nodes/` records.
fn wait_nodes(demo: *Demo) !void {
    const host = demo.host;
    const started = host.now_ms();
    while (host.now_ms() - started < join_ms) {
        if (try nodes_registered(host) == nodes_count) {
            host.say("  ok: {d} nodes registered after {d} ms", .{
                nodes_count, host.now_ms() - started,
            });
            return;
        }
        try pass(demo.nodes.context, 1000);
    }
    return host.fail("{d} nodes registered within {d} ms", .{ nodes_count, join_ms });
}

fn nodes_registered(host: *Host) !usize {
    const listed = try host.json("/v1/list?prefix=/nodes/");
    if (listed != .object) return 0;
    const kvs = listed.object.get("kvs") orelse return 0;
    if (kvs != .array) return 0;
    return kvs.array.items.len;
}

fn machines_of(context: *anyopaque) *Machines {
    return @ptrCast(@alignCast(context));
}

/// A guest's session moves only while it is pumped: time passes in pumps of every guest.
fn pass(context: *anyopaque, ms: u32) !void {
    const machines = machines_of(context);
    const host = machines.host;
    const until = host.now_ms() + ms;
    while (host.now_ms() < until) try machines.guests.pump_all(25);
}

/// `guest.sh <arguments>` as root on guest `index`, shown in the transcript; a non-zero exit
/// ends the demo.
fn guest(
    machines: *Machines,
    index: usize,
    comptime format: []const u8,
    args: anytype,
) ![]const u8 {
    const host = machines.host;
    const arguments = try std.fmt.allocPrint(host.arena(), format, args);
    const result = try machines.guests.root(@intCast(index), arguments, guest_timeout_s);
    const output = try host.arena().dupe(u8, result.output);
    host.say("{s}# guest.sh {s}", .{ vms.names[index], arguments });
    host.out(output);
    host.out("\n");
    if (result.status != 0) {
        return host.fail("guest.sh {s} on {s} exited {d}", .{
            arguments, vms.names[index], result.status,
        });
    }
    return output;
}

/// SIGKILL of the agent on guest `index` (not its containers), then a start on the same state
/// directory: the same supervisors run the same children before and after.
fn restart_agent(context: *anyopaque, index: u32) !void {
    const machines = machines_of(context);
    const host = machines.host;
    const name = vms.names[index];
    const before = try guest(machines, index, "containers", .{});
    const supervisors = std.mem.count(u8, before, "supervisor ");
    try host.check_quiet(supervisors > 0, "{s} runs no container", .{name});
    _ = try guest(machines, index, "kill-agent", .{});
    host.say("  kill -9 of {s}'s agent; its containers are left running ({d})", .{
        name, supervisors,
    });
    _ = try guest(machines, index, "start-agent", .{});
    const after = try guest(machines, index, "containers", .{});
    const same = std.mem.eql(u8, std.mem.trim(u8, before, " \n"), std.mem.trim(u8, after, " \n"));
    try host.check(same, "{s}'s agent restarted; the same {d} containers run, under the same " ++
        "supervisors with the same children", .{ name, supervisors });
}

/// What the service looked like when a step failed: the rollout, the replicas, the record.
fn diagnose(host: *Host) void {
    host.section("At the failure");
    if (host.server == null) return;
    _ = host.zcube(&.{ "rollout", "status", "app" }) catch {}; // Best effort, after a failure.
    _ = host.zcube(&.{ "get", "replicas", "app" }) catch {}; // Best effort, after a failure.
    _ = host.zcube(&.{ "why", "service", "app" }) catch {}; // Best effort, after a failure.
}

/// What each guest's agent logged, for a failed run.
fn guest_logs(machines: *Machines) void {
    for (0..nodes_count) |index| {
        if (!machines.guests.started[index]) continue;
        const result = machines.guests.root(@intCast(index), "logs", 60) catch continue;
        machines.host.say("---- {s}: guest.sh logs ----", .{vms.names[index]});
        machines.host.out(result.output);
        machines.host.out("\n");
    }
}

fn witness_report(demo: *Demo) void {
    const tally = demo.witness.tally;
    demo.host.section("The witness");
    demo.host.say("  ok: R1 R2 R3 R4 R5 held at each of {d} revisions; {d} replicas created, " ++
        "{d} retired, at most {d} live; no health fault scripted", .{
        tally.revisions, tally.created, tally.retirements, tally.live_max,
    });
}

comptime {
    assert(vms.uploads.len == 3);
    assert(nodes_count <= vms.count);
    assert(steps.restarted_node < nodes_count);
}
