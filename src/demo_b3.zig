//! `zig build demo-b3`: B3's demo, run for real (docs/demos/b3.md). The server runs on the host
//! over SQLite with one relay in its configuration, `botpike`, whose upstream is a test server on
//! the guest's loopback. One QEMU guest (the rig of src/demo_c2_vms.zig, one guest of it) runs
//! `zcube-agent --runtime zigbox` as root. A job with `--relay botpike` runs a Python image with
//! no network but the relay (`supervise-zigbox` passes `listen`), and tries to reach the world:
//! 1.1.1.1:443, the node's address, the metadata address, zcube-server, the upstream itself and
//! the relay port of another job, a DNS lookup and a raw socket. Each must fail; a request to the
//! relay must reach the test upstream, which is also where the job reports what it saw.
//!
//! Skips unless `ZCUBE_REAL_HOST=1`: it boots a QEMU guest and pulls an image from GHCR. The
//! transcript goes to standard output and to `--transcript FILE`. Exit 0 only if every rule held.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const script = @import("demo_b3_script.zig");
const steps = @import("demo_c2_steps.zig");
const vms = @import("demo_c2_vms.zig");

const Host = demo_host.Host;

const usage =
    \\usage: demo_b3 --zcube EXE --server EXE --agent EXE --zbx EXE --guest-script FILE
    \\               [--transcript FILE]
    \\
;

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

pub fn main(init: std.process.Init) u8 {
    const stdout = std.Io.File.stdout();
    const real = init.minimal.environ.getPosix("ZCUBE_REAL_HOST") orelse "";
    if (!std.mem.eql(u8, real, "1")) {
        const skipped = "demo-b3: skipped (set ZCUBE_REAL_HOST=1; it boots a QEMU guest)\n";
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
        std.debug.print("demo-b3: setup failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer host.arena_state.deinit();
    defer host.cli_environ.deinit();
    var vm_out: std.Io.File.Writer = .initStreaming(stdout, init.io, &.{});
    var guests: vms.Guests = .{
        .peer_ports = @splat(0),
        .out = &vm_out.interface,
        .limit = 1,
    };
    // Only guest 1 boots, and it forwards its peer port: a free host port, unused by the demo.
    guests.peer_ports[0] = demo_host.free_port(init.io, @as(u64, host.port) * 31 + 1) catch
        return 2;
    var demo: steps.Demo = .{
        .host = &host,
        .guests = &guests,
        .server = std.fmt.allocPrint(host.arena(), "10.0.2.2:{d}", .{host.port}) catch return 2,
    };
    return run(&demo, init, options);
}

/// Sets up the demo's directory, the CLI's environment, the server's configuration and the
/// transcript file.
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
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-b3-{d}-{d}", .{
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
    // The relay `botpike` and where it leads, as the agent (on the guest) reaches it.
    const config_path = try host.path_in_work("server.zon");
    const config_text = try std.fmt.allocPrint(arena,
        \\.{{ .relays = .{{ .botpike = .{{ .address = "{s}" }} }} }}
        \\
    , .{script.upstream});
    try cwd.writeFile(init.io, .{ .sub_path = config_path, .data = config_text });
    host.config.server_config = config_path;
    if (options.transcript) |path| host.transcript = try cwd.createFile(init.io, path, .{});
}

fn run(demo: *steps.Demo, init: std.process.Init, options: Options) u8 {
    const host = demo.host;
    defer if (host.transcript) |file| file.close(host.io);
    var ok = true;
    boot_and_run(demo, init, options) catch |err| {
        if (err != error.DemoFailed) host.say("FAILED: {s}", .{@errorName(err)});
        guest_logs(demo);
        host.dump_logs();
        ok = false;
    };
    host.section("Cleanup");
    host.cleanup();
    demo.guests.shutdown();
    demo.guests.deinit(host.io);
    host.say("  the server is stopped and the guest is powered off", .{});
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-b3 PASSED" else "demo-b3 FAILED"});
    return if (ok) 0 else 1;
}

fn boot_and_run(demo: *steps.Demo, init: std.process.Init, options: Options) !void {
    const host = demo.host;
    host.section("Boot: one QEMU guest through zigbox_vm");
    var bodies: [vms.uploads.len][]const u8 = undefined;
    const paths = [vms.uploads.len][]const u8{ options.agent, options.zbx, options.guest_script };
    for (&bodies, paths) |*body, path| {
        body.* = try std.Io.Dir.cwd().readFileAlloc(init.io, path, host.arena(), .unlimited);
    }
    const started = host.now_ms();
    try demo.guests.boot(init, bodies);
    host.say("  the guest booted and was provisioned in {d} ms", .{host.now_ms() - started});
    try script.run(demo);
}

/// What the guest's agent, relays and upstream logged, for a failed run.
fn guest_logs(demo: *steps.Demo) void {
    if (!demo.guests.started[0]) return;
    const result = demo.guests.root(0, "logs", 60) catch return;
    demo.host.say("---- {s}: guest.sh logs ----", .{vms.names[0]});
    demo.host.out(result.output);
    demo.host.out("\n");
}

comptime {
    assert(vms.uploads.len == 3);
}
