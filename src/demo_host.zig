//! The harness under `demo-c0` (src/demo_c0.zig): the real processes the demo starts, the
//! `zcube` command run as a user runs it, the transcript, and every wait. It simulates nothing.
//!
//! Everything the demo starts is killed at the end, whatever happened (`Host.cleanup`), and what is
//! left is counted afterwards (`Host.survivors`). The transcript goes to standard output only (the
//! build runner counts any standard error as a failure), and to a file when one is asked for.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const http = @import("agent_http.zig");
const harness_tls = @import("harness_tls.zig");
const host_procs = @import("host_procs.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
pub const Json = std.json.Value;

/// A step of the demo did not come out as HANDOFF says; the transcript says which and why.
pub const Failed = error{DemoFailed};

/// How often a wait looks, and the longest a started command may run before the demo gives up.
pub const poll_ms: u32 = 100;
/// A poll or a sleep longer than this is reported as a stall (`Host.report_stall`).
pub const stall_ms: u64 = 2_000;
pub const command_timeout_ms: u32 = 60 * 1000;
/// The longest a single command prints, in either stream.
pub const output_bytes_max: usize = 128 * 1024;

pub const Config = struct {
    server_exe: []const u8,
    agent_exe: []const u8,
    cli_exe: []const u8,
    images: []const u8,
    /// The server's `--store` setting; the demo makes the store's file or schema new before it.
    store: []const u8,
    transcript_path: ?[]const u8,
    /// The server's `--lost-grace-ms`, as text; null leaves the server's default.
    lost_grace_ms: ?[]const u8 = null,
    /// The server's `--lease-ttl-ms`, as text; null leaves the server's default.
    lease_ttl_ms: ?[]const u8 = null,
    /// The server's `--config FILE` (a ZON file, for `.relays`); null passes none.
    server_config: ?[]const u8 = null,
    /// `--listen` (TLS) as well as `--insecure-listen`, which the host's own calls use (demo-b7).
    tls_listen: ?[]const u8 = null,
    /// The server serves `--listen` (TLS) on the demo's port and no `--insecure-listen`: the
    /// demo, its `zcube` commands and its agents present certificates of the server's CA
    /// (B7 slice 6). `ca issue-client operator --scope admin` is the demo's own.
    tls_only: bool = false,
};

/// What a `zcube` command did: its exit code (255 if a signal ended it) and both streams.
pub const Cli = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
};

pub const Host = struct {
    io: std.Io,
    arena_state: std.heap.ArenaAllocator,
    config: Config,
    /// The directory of this run: store file, state, logs, service files, the CLI's home.
    work: []const u8,
    state: []const u8,
    port: u16,
    cli_environ: std.process.Environ.Map,
    server: ?std.process.Child = null,
    agent: ?std.process.Child = null,
    server_starts: u32 = 0,
    agent_starts: u32 = 0,
    /// The step being run, named in every failure.
    step: []const u8 = "setup",
    transcript: ?std.Io.File = null,
    /// With `Config.tls_only`: the CA and the certificates issued from it, and the operator's
    /// credentials once loaded.
    pki: ?harness_tls.Pki = null,
    credentials: ?*harness_tls.Credentials = null,

    pub fn arena(host: *Host) Allocator {
        return host.arena_state.allocator();
    }

    pub fn procs(host: *Host) host_procs.Procs {
        return .{ .io = host.io, .arena = host.arena(), .state = host.state };
    }

    pub fn now_ms(host: *const Host) u64 {
        return @intCast(std.Io.Clock.awake.now(host.io).toMilliseconds());
    }

    pub fn path_in_work(host: *Host, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(host.arena(), "{s}/{s}", .{ host.work, name });
    }

    // ---- The transcript ----

    pub fn out(host: *Host, text: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(host.io, text) catch {}; // Nowhere else to say it.
        if (host.transcript) |file| file.writeStreamingAll(host.io, text) catch {}; // Same.
    }

    pub fn say(host: *Host, comptime format: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(host.arena(), format ++ "\n", args) catch {
            host.out("(a line of the transcript did not fit in memory)\n");
            return;
        };
        host.out(line);
    }

    /// A new step: a heading in the transcript, and the name every failure carries.
    pub fn section(host: *Host, comptime title: []const u8) void {
        host.step = title;
        host.say("\n== " ++ title ++ " ==", .{});
    }

    /// An outcome the demo asserts. A false one ends the demo.
    pub fn check(host: *Host, ok: bool, comptime what: []const u8, args: anytype) Failed!void {
        if (ok) {
            host.say("  ok: " ++ what, args);
            return;
        }
        return host.fail(what, args);
    }

    pub fn fail(host: *Host, comptime what: []const u8, args: anytype) Failed {
        host.say("  FAILED in step \"{s}\": " ++ what, .{host.step} ++ args);
        return error.DemoFailed;
    }

    // ---- Processes we start ----

    pub fn spawn(
        host: *Host,
        exe: []const u8,
        args: []const []const u8,
        log: []const u8,
    ) !std.process.Child {
        const name = try host.path_in_work(log);
        const file = try std.Io.Dir.cwd().createFile(host.io, name, .{});
        defer file.close(host.io);
        const argv = try host.arena().alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        return std.process.spawn(host.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
        });
    }

    pub fn start_server(host: *Host, wait_ms: u32) !void {
        host.server_starts += 1;
        const arena_allocator = host.arena();
        const listen = try std.fmt.allocPrint(arena_allocator, "127.0.0.1:{d}", .{host.port});
        const log = try std.fmt.allocPrint(arena_allocator, "server-{d}.log", .{
            host.server_starts,
        });
        // A Postgres store has no directory beside it, so the server needs one to remember the
        // highest revision it saw (ZC-E0106 without it); the same one serves every restart.
        const state_dir = try host.path_in_work("server-state");
        // `tls_only` serves `--listen` on the demo's port; `tls_listen` adds one beside it.
        if (host.config.tls_only) assert(host.config.tls_listen == null);
        if (host.config.tls_listen != null) assert(!host.config.tls_only);
        var args: std.ArrayList([]const u8) = .empty;
        const listener = if (host.config.tls_only) "--listen" else "--insecure-listen";
        if (host.config.tls_only and host.pki == null) host.pki = .{
            .io = host.io,
            .arena = arena_allocator,
            .server_exe = host.config.server_exe,
            .store = host.config.store,
            .state_dir = state_dir,
            .certs = try host.path_in_work("certs"),
        };
        try args.appendSlice(arena_allocator, &.{
            listener,         listen,
            "--store",        host.config.store,
            "--state-dir",    state_dir,
            "--create-store", "--quiet",
        });
        if (host.config.lost_grace_ms) |grace| {
            try args.appendSlice(arena_allocator, &.{ "--lost-grace-ms", grace });
        }
        if (host.config.lease_ttl_ms) |ttl| {
            try args.appendSlice(arena_allocator, &.{ "--lease-ttl-ms", ttl });
        }
        if (host.config.server_config) |path| {
            try args.appendSlice(arena_allocator, &.{ "--config", path });
        }
        if (host.config.tls_listen) |address| {
            try args.appendSlice(arena_allocator, &.{ "--listen", address });
        }
        host.server = try host.spawn(host.config.server_exe, args.items, log);
        const ready = struct {
            fn check(_: void, h: *Host) !bool {
                if (!try h.tls_ready()) return false;
                const reply = h.call("GET", "/v1/status", "") catch return false;
                return reply.status == 200;
            }
        };
        try host.wait_for({}, ready.check, "the server to answer", wait_ms);
    }

    pub fn start_agent(host: *Host, node: []const u8) !void {
        host.agent_starts += 1;
        const arena_allocator = host.arena();
        const server = try std.fmt.allocPrint(arena_allocator, "127.0.0.1:{d}", .{host.port});
        const log = try std.fmt.allocPrint(arena_allocator, "agent-{d}.log", .{host.agent_starts});
        const args = [_][]const u8{
            "--node",         node,
            "--server",       server,
            "--state-dir",    host.state,
            "--cpu-millis",   "4000",
            "--memory-bytes", "8589934592",
            "--images",       host.config.images,
            "--verbose",
        };
        const tls = try host.agent_tls(node);
        const all = try std.mem.concat(arena_allocator, []const u8, &.{ &args, tls });
        host.agent = try host.spawn(host.config.agent_exe, all, log);
    }

    /// With `Config.tls_only`, whether the operator's credentials are loaded: once the server
    /// wrote its CA, `ca issue-client operator --scope admin` (the first time), then loaded and
    /// exported to the `zcube` commands. True at once without it. Only a CA not yet written is
    /// waited for: a failing `ca issue-client` or a broken state directory fails the step at once.
    fn tls_ready(host: *Host) !bool {
        if (!host.config.tls_only) return true;
        if (host.credentials != null) return true;
        // start_server makes the Pki before it starts a tls_only server.
        assert(host.pki != null);
        const pki = &host.pki.?;
        const ca = pki.find_ca() catch return host.fail("{s}", .{pki.said});
        if (ca == null) return false;
        const issued = pki.issue("operator", "admin") catch return host.fail("{s}", .{pki.said});
        if (issued) {
            host.say("$ zcube-server ca issue-client operator --scope admin " ++
                "--store <the store> --state-dir server-state --out certs", .{});
            host.print_indented(pki.said);
        }
        host.credentials = pki.load("operator") catch return host.fail("{s}", .{pki.said});
        pki.export_to(&host.cli_environ, "operator") catch return host.fail("{s}", .{pki.said});
        return true;
    }

    /// With `Config.tls_only`, an agent's `--ca`, `--cert` and `--key`: a node certificate
    /// issued for `node` the first time (`ca issue-node`). Empty without it.
    pub fn agent_tls(host: *Host, node: []const u8) ![]const []const u8 {
        if (!host.config.tls_only) return &.{};
        // An agent starts after the server, and start_server makes the Pki for a tls_only one.
        assert(host.pki != null);
        const pki = &host.pki.?;
        const issued = pki.issue(node, null) catch return host.fail("{s}", .{pki.said});
        if (issued) {
            host.say("$ zcube-server ca issue-node {s} --store <the store> " ++
                "--state-dir server-state --out certs", .{node});
            host.print_indented(pki.said);
        }
        const flags = pki.flags(node) catch return host.fail("{s}", .{pki.said});
        return host.arena().dupe([]const u8, &flags);
    }

    /// SIGTERM, then wait: a clean stop is exit 0.
    pub fn stop_child(host: *Host, child: *?std.process.Child, comptime what: []const u8) !void {
        var process = child.* orelse return;
        std.posix.kill(process.id.?, .TERM) catch {}; // Already gone is fine; wait says how.
        const term = try process.wait(host.io);
        child.* = null;
        const clean = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        try host.check(clean, what ++ " stopped cleanly on SIGTERM (exit 0)", .{});
    }

    // ---- The API, for what the CLI does not show ----

    pub fn call(host: *Host, method: []const u8, path: []const u8, body: []const u8) !http.Reply {
        const tls = if (host.config.tls_only) host.credentials orelse
            return error.ApiUnreachable else null;
        return host.call_with(tls, method, path, body);
    }

    /// How the transcript names the demo port's listener.
    pub fn listener_text(host: *const Host) []const u8 {
        return if (host.config.tls_only) "TLS, --listen" else "plain HTTP, --insecure-listen";
    }

    /// That the demo's port serves TLS only (B7 slice 6): a plain-HTTP `GET /v1/status` gets no
    /// answer, and the same request with the operator's certificate gets 200. Fails the demo when
    /// `Config.tls_only` is off, so a demo that calls it cannot quietly run over plain HTTP.
    pub fn check_tls_only(host: *Host) !void {
        const plain = host.call_with(null, "GET", "/v1/status", "");
        const refused = if (plain) |reply| reply.status != 200 else |_| true;
        try host.check(refused, "a plain-HTTP GET /v1/status on 127.0.0.1:{d} gets no answer", .{
            host.port,
        });
        const credentials = host.credentials orelse
            return host.fail("the demo holds no TLS credentials (Config.tls_only is off)", .{});
        const reply = host.call_with(credentials, "GET", "/v1/status", "") catch |err|
            return host.fail("GET /v1/status over TLS failed: {t}", .{err});
        const what = "the same request over TLS, as operator, answers {d}";
        try host.check(reply.status == 200, what, .{reply.status});
    }

    fn call_with(
        host: *Host,
        tls: ?*harness_tls.Credentials,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !http.Reply {
        const address = try net.IpAddress.parse("127.0.0.1", host.port);
        const client: http.Client = .{ .io = host.io, .address = address, .tls = tls };
        var diag: Diag = undefined;
        diag.reset();
        return client.call(host.arena(), .{
            .method = method,
            .target = path,
            .body = body,
        }, &diag) catch error.ApiUnreachable;
    }

    pub fn json(host: *Host, path: []const u8) !Json {
        const reply = try host.call("GET", path, "");
        try host.check_quiet(reply.status == 200, "GET {s} answered {d}", .{ path, reply.status });
        return std.json.parseFromSliceLeaky(Json, host.arena(), reply.body, .{});
    }

    /// An assertion that says nothing when it holds (plumbing, not an outcome of the demo).
    pub fn check_quiet(
        host: *Host,
        ok: bool,
        comptime what: []const u8,
        args: anytype,
    ) Failed!void {
        if (!ok) return host.fail(what, args);
    }

    // ---- The zcube command ----

    /// Runs `zcube <args>` in the demo's directory as a user would: the environment holds the
    /// server's address and a home of its own, and nothing else is shared. Echoes the command and
    /// everything it printed when `show` is set.
    pub fn run_cli(host: *Host, args: []const []const u8, show: bool) !Cli {
        const argv = try host.arena().alloc([]const u8, args.len + 1);
        argv[0] = host.config.cli_exe;
        @memcpy(argv[1..], args);
        const result = std.process.run(host.arena(), host.io, .{
            .argv = argv,
            .cwd = .{ .path = host.work },
            .environ_map = &host.cli_environ,
            .stdout_limit = .limited(output_bytes_max),
            .stderr_limit = .limited(output_bytes_max),
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(command_timeout_ms),
                .clock = .awake,
            } },
        }) catch |err| {
            return host.fail("zcube {s} did not finish: {s}", .{
                try std.mem.join(host.arena(), " ", args), @errorName(err),
            });
        };
        const code: u8 = switch (result.term) {
            .exited => |value| value,
            else => 255,
        };
        const cli: Cli = .{ .code = code, .out = result.stdout, .err = result.stderr };
        if (show) try host.echo(args, cli);
        return cli;
    }

    /// The command, shown.
    pub fn zcube(host: *Host, args: []const []const u8) !Cli {
        return host.run_cli(args, true);
    }

    /// The command, not shown: for a poll that runs until something is true.
    pub fn zcube_quiet(host: *Host, args: []const []const u8) !Cli {
        return host.run_cli(args, false);
    }

    fn echo(host: *Host, args: []const []const u8, cli: Cli) !void {
        host.say("$ zcube {s}", .{try std.mem.join(host.arena(), " ", args)});
        host.print_indented(cli.out);
        host.print_indented(cli.err);
        if (cli.code != 0) host.say("[exit {d}]", .{cli.code});
    }

    fn print_indented(host: *Host, text: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, text, "\n");
        if (trimmed.len == 0) return;
        host.out(trimmed);
        host.out("\n");
    }

    // ---- Waiting ----

    /// Polls `check(ctx, host)` until it is true. The wait is bounded: past `limit_ms` the demo
    /// fails, naming the step and what it waited for. Says how long it took.
    pub fn wait_for(
        host: *Host,
        ctx: anytype,
        comptime check_fn: fn (@TypeOf(ctx), *Host) anyerror!bool,
        comptime what: []const u8,
        limit_ms: u32,
    ) !void {
        assert(limit_ms > poll_ms);
        const started = host.now_ms();
        while (host.now_ms() - started < limit_ms) {
            const polled = host.now_ms();
            const done = try check_fn(ctx, host);
            host.report_stall("a poll", polled, host.now_ms(), started);
            if (done) {
                host.say("  waited {d} ms for " ++ what, .{host.now_ms() - started});
                return;
            }
            const slept = host.now_ms();
            try host.io.sleep(.fromMilliseconds(poll_ms), .awake);
            host.report_stall("a sleep of poll_ms", slept, host.now_ms(), started);
        }
        return host.fail("timed out after {d} ms waiting for " ++ what, .{limit_ms});
    }

    /// Says so when one poll or one sleep took more than `stall_ms`. A sleep that overshoots
    /// means the demo's own process, or the machine, did not run. A slow poll alone is ambiguous:
    /// a freeze of the whole machine that starts while the poll is in flight looks the same as a
    /// silent server. The server's own "elapsed while its mutex was held" line (store_sqlite.zig,
    /// naming the store call) says whether a store call's time covered the stall; the machine's
    /// pressure and steal time say whether it was frozen.
    /// CI's 2026-11-07 failure (docs/demos/notes/2026-11-07-demo-c1-sqlite-stall.md) could not be.
    fn report_stall(
        host: *Host,
        comptime what: []const u8,
        from_ms: u64,
        to_ms: u64,
        wait_started_ms: u64,
    ) void {
        assert(to_ms >= from_ms);
        if (to_ms - from_ms <= stall_ms) return;
        host.say("  STALL: " ++ what ++ " took {d} ms, {d} ms into a wait (demo clock {d} ms)", .{
            to_ms - from_ms, from_ms - wait_started_ms, from_ms,
        });
    }

    /// Lets time pass, for a step that asserts that nothing happens meanwhile.
    pub fn settle(host: *Host, comptime why: []const u8, duration_ms: u32) !void {
        host.say("  (watching for {d} ms: " ++ why ++ ")", .{duration_ms});
        try host.io.sleep(.fromMilliseconds(duration_ms), .awake);
    }

    // ---- The end, whatever happened ----

    /// Kills everything this run started: the agent and the server, then every process group of
    /// a supervisor under the state directory (the supervisor, its command, what that started).
    pub fn cleanup(host: *Host) void {
        if (host.agent) |*child| child.kill(host.io);
        host.agent = null;
        if (host.server) |*child| child.kill(host.io);
        host.server = null;
        _ = host.procs().kill_supervisor_groups();
    }

    /// What still runs after `cleanup`: supervisors and the commands of every container the
    /// agent made. Settles first: a killed process disappears a moment later.
    pub fn survivors(host: *Host) !u32 {
        try host.io.sleep(.fromMilliseconds(500), .awake);
        const procs_now = host.procs();
        var count = try procs_now.supervisors();
        for (try procs_now.containers()) |pids| {
            if (procs_now.alive(pids.command)) count += 1;
        }
        return count;
    }

    pub fn dump_logs(host: *Host) void {
        for ([_][]const u8{ "server", "agent" }) |kind| {
            const is_server = std.mem.eql(u8, kind, "server");
            const starts = if (is_server) host.server_starts else host.agent_starts;
            for (1..starts + 1) |index| {
                const name = std.fmt.allocPrint(
                    host.arena(),
                    "{s}/{s}-{d}.log",
                    .{ host.work, kind, index },
                ) catch continue;
                const text = std.Io.Dir.cwd().readFileAlloc(
                    host.io,
                    name,
                    host.arena(),
                    .limited(8192),
                ) catch continue;
                host.say("---- {s} {d} ----\n{s}", .{ kind, index, text });
            }
        }
    }
};

/// The lowest port the kernel hands to outgoing connections, from `ip_local_port_range`.
fn ephemeral_port_min(io: std.Io) u16 {
    var buffer: [64]u8 = undefined;
    const path = "/proc/sys/net/ipv4/ip_local_port_range";
    const text = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return ephemeral_port_default;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    const first = words.next() orelse return ephemeral_port_default;
    return std.fmt.parseInt(u16, first, 10) catch ephemeral_port_default;
}

const ephemeral_port_default: u16 = 32768;
/// The demo's port is chosen from here up to the start of the ephemeral range.
const port_floor: u16 = 10_000;
const port_tries_max: u32 = 64;

/// A port the system is not using now, for a server that is stopped and started again. It is
/// *below* the kernel's ephemeral range on purpose: while the server is down, the agent keeps
/// connecting to its port, and a connection from an ephemeral port to a port in that range with
/// no listener can connect to itself (TCP simultaneous open) and keep the port, so the server
/// that starts next is told that another process is listening on it. `seed` spreads runs apart.
pub fn free_port(io: std.Io, seed: u64) !u16 {
    const ceiling = ephemeral_port_min(io);
    assert(ceiling > port_floor);
    const span: u64 = ceiling - port_floor;
    var attempt: u32 = 0;
    while (attempt < port_tries_max) : (attempt += 1) {
        const port: u16 = @intCast(port_floor + (seed + attempt * 7919) % span);
        const address = try net.IpAddress.parse("127.0.0.1", port);
        var listener = address.listen(io, .{}) catch continue;
        listener.deinit(io);
        return port;
    }
    return error.NoFreePort;
}
