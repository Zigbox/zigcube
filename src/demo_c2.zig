//! `zig build demo-c2`: SPEC's C2 demo, run for real (docs/demos/c2.md, "demo-c2"). The server
//! runs on the host over SQLite; four QEMU guests (src/demo_c2_vms.zig) each run one
//! `zcube-agent --runtime zigbox` as root, which reaches the server at
//! 10.0.2.2 and advertises its peer server as `10.0.2.2:H_i`, a host port forwarded to it. The
//! `zcube` command runs on the host. The script is src/demo_c2_script.zig.
//!
//! Skips unless `ZCUBE_REAL_HOST=1`: it boots four guests and pulls images from GHCR. The
//! transcript goes to standard output and to `--transcript FILE`. Exit 0 only if every rule held.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const script = @import("demo_c2_script.zig");
const steps = @import("demo_c2_steps.zig");
const vms = @import("demo_c2_vms.zig");

const Host = demo_host.Host;

const usage =
    \\usage: demo_c2 --zcube EXE --server EXE --agent EXE --zbx EXE --guest-script FILE
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
        const skipped = "demo-c2: skipped (set ZCUBE_REAL_HOST=1; it boots four QEMU guests)\n";
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
        std.debug.print("demo-c2: setup failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer host.arena_state.deinit();
    defer host.cli_environ.deinit();
    // The guests' own output (image download, boot) is unbuffered: it interleaves with the
    // transcript in the order it happened.
    var vm_out: std.Io.File.Writer = .initStreaming(stdout, init.io, &.{});
    var guests: vms.Guests = .{ .peer_ports = undefined, .out = &vm_out.interface };
    guest_ports(&guests, init.io, host.port) catch return 2;
    var demo: steps.Demo = .{
        .host = &host,
        .guests = &guests,
        .server = std.fmt.allocPrint(host.arena(), "10.0.2.2:{d}", .{host.port}) catch return 2,
    };
    return run(&demo, init, options);
}

/// H_i: four free host ports, distinct from each other and from the server's.
fn guest_ports(guests: *vms.Guests, io: std.Io, server_port: u16) !void {
    var seed: u64 = @as(u64, server_port) * 31 + 1;
    for (&guests.peer_ports, 0..) |*port, index| {
        while (true) : (seed += 1) {
            const candidate = try demo_host.free_port(io, seed);
            const taken = candidate == server_port or
                std.mem.indexOfScalar(u16, guests.peer_ports[0..index], candidate) != null;
            if (!taken) {
                port.* = candidate;
                break;
            }
        }
    }
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
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-c2-{d}-{d}", .{
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
    host.say("  the server is stopped and the four guests are powered off", .{});
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-c2 PASSED" else "demo-c2 FAILED"});
    return if (ok) 0 else 1;
}

fn boot_and_run(demo: *steps.Demo, init: std.process.Init, options: Options) !void {
    const host = demo.host;
    host.section("Boot: four QEMU guests through zigbox_vm");
    var bodies: [vms.uploads.len][]const u8 = undefined;
    const paths = [vms.uploads.len][]const u8{ options.agent, options.zbx, options.guest_script };
    for (&bodies, paths) |*body, path| {
        body.* = try std.Io.Dir.cwd().readFileAlloc(init.io, path, host.arena(), .unlimited);
    }
    const started = host.now_ms();
    try demo.guests.boot(init, bodies);
    host.say("  four guests booted and provisioned in {d} ms; peer ports {d} {d} {d} {d}", .{
        host.now_ms() - started,
        demo.guests.peer_ports[0],
        demo.guests.peer_ports[1],
        demo.guests.peer_ports[2],
        demo.guests.peer_ports[3],
    });
    try script.run(demo);
}

/// What each started guest's agent and fetches logged, for a failed run.
fn guest_logs(demo: *steps.Demo) void {
    for (0..vms.count) |index| {
        if (!demo.guests.started[index]) continue;
        const result = demo.guests.root(@intCast(index), "logs", 60) catch continue;
        demo.host.say("---- {s}: guest.sh logs ----", .{vms.names[index]});
        demo.host.out(result.output);
        demo.host.out("\n");
    }
}

comptime {
    assert(vms.uploads.len == 3);
}
