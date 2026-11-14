//! `zig build demo-b7`: B7's demo (docs/briefs/b7.md, slice 4), run for real: `zcube-server` on
//! SQLite serving the API over TLS (`--listen`), one `zcube-agent` with `FakeRuntime` that talks
//! to it over TLS, and the `zcube` command with a client certificate. No KVM.
//!
//! The steps (docs/demos/b7.md says what each asserts and what is cut):
//!
//!   0. the server makes its CA; `ca issue-client app --scope jobs` and `ca issue-node node1`;
//!   1. node1's agent joins over TLS with its node certificate;
//!   2. the `jobs` client runs a job and cancels it;
//!   3. the same client is refused `POST /v1/services` (403 ZC-E0822);
//!   4. a client with no certificate is refused at the handshake (ZC-E0814 in the server's log);
//!   5. node1's agent credentials are refused a write under node2 (403 ZC-E0822) and allowed
//!      their own node's path.
//!
//! The server also listens with `--insecure-listen` (loopback, the caller `local`): the demo reads
//! what happened through it, as the other demos do, and never acts through it. The transcript
//! goes to standard output and to `--transcript FILE`. Every process started is killed at the
//! end, and the demo then checks that none is left. Exit 0 only if every assertion held.

const std = @import("std");
const demo_host = @import("demo_host.zig");
const steps = @import("demo_b7_steps.zig");

const Host = demo_host.Host;
const Demo = steps.Demo;

const usage =
    \\usage: demo_b7 --zcube EXE --server EXE --agent EXE --images FILE [--transcript FILE]
    \\
;

const Options = struct {
    zcube: []const u8 = "",
    server: []const u8 = "",
    agent: []const u8 = "",
    images: []const u8 = "",
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
        if (std.mem.eql(u8, name, "--images")) options.images = value;
        if (std.mem.eql(u8, name, "--transcript")) options.transcript = value;
    }
    if (options.zcube.len == 0 or options.server.len == 0) return null;
    if (options.agent.len == 0 or options.images.len == 0) return null;
    return options;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    const options = parse_options(args) orelse {
        std.Io.File.stderr().writeStreamingAll(init.io, usage) catch {}; // Nowhere else to say it.
        return 2;
    };
    var host: Host = undefined;
    var demo: Demo = .{ .host = &host };
    prepare(&demo, init, options) catch return 2;
    defer host.arena_state.deinit();
    defer host.cli_environ.deinit();
    return run(&demo);
}

/// Sets up the demo's directory, the two ports, the CLI's environment and the transcript file.
fn prepare(demo: *Demo, init: std.process.Init, options: Options) !void {
    const host = demo.host;
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
    demo.tls_port = try demo_host.free_port(init.io, stamp + 104_729);
    if (demo.tls_port == host.port) demo.tls_port = try demo_host.free_port(init.io, stamp + 7);
    if (demo.tls_port == host.port) return error.NoFreePort;
    demo.tls_address = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{demo.tls_port});
    host.config.tls_listen = demo.tls_address;
    // The command runs in the demo's directory, so every path it is given must be absolute.
    const cwd = std.Io.Dir.cwd();
    host.config.server_exe = try cwd.realPathFileAlloc(init.io, options.server, arena);
    host.config.agent_exe = try cwd.realPathFileAlloc(init.io, options.agent, arena);
    host.config.cli_exe = try cwd.realPathFileAlloc(init.io, options.zcube, arena);
    host.config.images = try cwd.realPathFileAlloc(init.io, options.images, arena);
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    host.work = try std.fmt.allocPrint(arena, "{s}/zcube-demo-b7-{d}-{d}", .{
        base, std.os.linux.getpid(), stamp,
    });
    host.state = try std.fmt.allocPrint(arena, "{s}/state", .{host.work});
    try cwd.createDirPath(init.io, host.state);
    try cwd.createDirPath(init.io, try host.path_in_work("home"));
    try cwd.createDirPath(init.io, try host.path_in_work("certs"));
    try host.cli_environ.put("PATH", init.environ_map.get("PATH") orelse "/usr/bin:/bin");
    try host.cli_environ.put("HOME", try host.path_in_work("home"));
    try host.cli_environ.put("XDG_STATE_HOME", try host.path_in_work("xdg"));
    try host.cli_environ.put("USER", "demo");
    // The command talks to the TLS listener only; step 0 adds the certificate's variables.
    try host.cli_environ.put("ZCUBE_SERVER", demo.tls_address);
    host.config.store = try std.fmt.allocPrint(arena, "sqlite:{s}/store.db", .{host.work});
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
    const left = host.survivors() catch 1;
    if (left == 0) {
        host.say("  ok: every process the demo started is gone (server, agent, supervisors)", .{});
    } else {
        host.say("  FAILED: {d} processes of this run are still running", .{left});
        ok = false;
    }
    std.Io.Dir.cwd().deleteTree(host.io, host.work) catch {}; // Best effort: it is in /tmp.
    host.say("\n{s}", .{if (ok) "demo-b7 PASSED" else "demo-b7 FAILED"});
    return if (ok) 0 else 1;
}

fn script(demo: *Demo) !void {
    try steps.start(demo);
    try steps.agent_joins(demo);
    try steps.jobs_client(demo);
    try steps.jobs_client_refused(demo);
    try steps.no_certificate(demo);
    try steps.node_scope(demo);
    try steps.large_reply(demo);
}
