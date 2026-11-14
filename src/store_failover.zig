//! The failover runs of `zig build test-store-faults -Dbackend=postgres` (slice 10d; plan in
//! `docs/briefs/c1-10d.md`). Shell code: processes, threads and sockets.
//!
//! A run makes a primary and a streaming standby with `pg_dev pair-up sync|async`, routes the
//! standby's replication through a fault proxy of its own (`R`), and starts a real `zcube-server`
//! on the primary, its store reached through the client proxy `C`. 10c's clients and watcher
//! (`store_faults.zig`, recorded and checked by `testing/history.zig`) load a store of their own
//! on the same primary through `C`, and the run drives the server's revision with applies.
//! Mid-load it fails over: `C` black-holes new connections, the primary is crashed
//! (`pg_ctl -m immediate`), the standby promoted, `C` repointed at it and healed.
//!
//! A quarter of the way in, the run holds the clients while the server sees and saves
//! `lead_revisions` revisions, releases them, and cuts replication off (partitions `R`) for a
//! window in which it counts the clients' acknowledged writes.
//!
//! - `sync` (`synchronous_commit = remote_apply`, the standby in `synchronous_standby_names`): `R`
//!   is cut after the lead. In the window the primary must acknowledge no write (a commit waits
//!   for the standby, which cannot hear it), so the crash lands mid-commit: the run requires a
//!   write of unknown outcome. The clients carry on on the promoted standby, must acknowledge
//!   `writes_after_heal_min` writes there, and the checker must pass over the whole run; the
//!   server must still answer with `store.ok` and a remembered revision at least the one before
//!   the failover. The positive control: a lossless failover does not halt the server.
//! - `async`, the teeth test: `R` is cut before the lead, so the server's remembered revision is
//!   past what the standby has, and the window must see writes acknowledged, so the loss is
//!   certain, not lucky (and asserted: the promoted store's revision must be below the
//!   remembered one). The clients stop at the failover. The server must refuse the promoted
//!   store with ZC-E0215 (apply first, then status), and again after a restart; the promoted
//!   store's revision must not move; the checker must report the clients' lost acknowledged
//!   writes.
//!
//! The clients are held, not timed, so a slow machine stretches the run instead of letting the
//! load end before the failover. A run killed with SIGKILL leaves its server's pid in its work
//! directory; the next run of the mode kills that server first.
//!
//! Every path kills the server, stops the proxies and removes the pair (`pg_dev pair-down`).

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const Diag = diag_mod.Diag;
const pq = @import("pq.zig");
const http = @import("agent_http.zig");
const harness_tls = @import("harness_tls.zig");
const demo_host = @import("demo_host.zig");
const RealClock = @import("agent_clock.zig").RealClock;
const PostgresStore = @import("store_postgres.zig").PostgresStore;
const fault_proxy = @import("testing/fault_proxy.zig");
const history = @import("testing/history.zig");
const faults = @import("store_faults.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Proxy = fault_proxy.Proxy;
const say = faults.say;

pub const Mode = enum { sync, async };

/// Calls per client, and the pause after each: the load lasts a few seconds.
const ops_per_client = 160;
const op_pause_ms = 15;
/// The failover is staged once this share of the calls has been made.
const stage_percent = 25;
/// Revisions the server must see past the moment the run held (async: past the partition).
const lead_revisions = 20;
/// With replication cut off, the run lets this pass before it counts acknowledged writes, and
/// then counts them over the window: a synchronous primary must acknowledge none, an
/// asynchronous one some.
const cut_settle_ms = 100;
const cut_window_ms = 300;
/// Writes the clients must have acknowledged on the promoted store (`sync`): the load crossed
/// the failover.
const writes_after_heal_min = 20;
/// Server ports of the two modes differ even for one seed.
const port_salt = 104_729;
const poll_ms = 50;
const wait_ms_max = 30_000;
const output_bytes_max = 64 * 1024;
const standby_name = "zcube_standby";
const server_schema = "zcube";

/// The run's processes and proxies, and where they are.
const Rig = struct {
    gpa: Allocator,
    io: std.Io,
    mode: Mode,
    options: faults.Options,
    arena: Allocator,
    work: []const u8,
    primary: []const u8,
    standby: []const u8,
    primary_port: u16,
    standby_port: u16,
    replication: *Proxy,
    client: *Proxy,
    /// Libpq settings that reach the store through `client`.
    through: []const u8,
    server: ?std.process.Child = null,
    server_port: u16,
    server_starts: u32 = 0,
    /// The server's CA and the `failover` admin certificate issued from it (B7 slice 6: the
    /// rig talks to `--listen` as an operator would).
    pki: ?harness_tls.Pki = null,
    credentials: ?*harness_tls.Credentials = null,
    /// The server's remembered revision just before the failover.
    remembered: u64 = 0,
    /// `async`: the server's store's revision on the standby just after its promotion.
    promoted_at: u64 = 0,
    /// Writes the clients had acknowledged when `C` was healed onto the promoted store.
    acked_at_heal: u32 = 0,
    applies: u32 = 0,

    fn fail(rig: *const Rig, comptime format: []const u8, args: anytype) error{FailoverFailed} {
        say("failover {s}: FAILED: " ++ format, .{@tagName(rig.mode)} ++ args);
        say("failover {s}: the server's logs are in {s}", .{ @tagName(rig.mode), rig.work });
        return error.FailoverFailed;
    }

    fn note(rig: *const Rig, comptime format: []const u8, args: anytype) void {
        say("failover {s}: " ++ format, .{@tagName(rig.mode)} ++ args);
    }
};

/// One failover run. `passed` is false when what the mode asserts did not hold.
pub fn run(gpa: Allocator, io: std.Io, options: faults.Options, seed: u64) !faults.Report {
    const mode = options.failover.?;
    assert(options.pg_dev.len > 0);
    assert(options.server.len > 0);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One directory per mode, whatever the seed, so that the next run finds what a killed one
    // left: its server is killed first, then its scratch removed.
    const work = try std.fmt.allocPrint(arena, ".zig-cache/store-failover-{s}", .{@tagName(mode)});
    kill_stale_server(io, arena, work);
    std.Io.Dir.cwd().deleteTree(io, work) catch {}; // Best effort: scratch of an earlier run.
    try std.Io.Dir.cwd().createDirPath(io, work);
    const pair = try pair_up(gpa, io, arena, options.pg_dev, mode);
    defer pg_dev_do(gpa, io, options.pg_dev, "pair-down") catch {}; // Best effort: cleanup.
    const replication = try Proxy.start(gpa, pair.primary_port);
    defer replication.stop();
    const client = try Proxy.start(gpa, pair.primary_port);
    defer client.stop();
    const server_seed = seed +% @as(u64, @backingInt(mode)) * port_salt;
    var rig: Rig = .{
        .gpa = gpa,
        .io = io,
        .mode = mode,
        .options = options,
        .arena = arena,
        .work = work,
        .primary = pair.primary,
        .standby = pair.standby,
        .primary_port = pair.primary_port,
        .standby_port = pair.standby_port,
        .replication = replication,
        .client = client,
        .through = try std.fmt.allocPrint(arena, "host=127.0.0.1 port={d} user=zcube " ++
            "dbname=postgres", .{client.port}),
        .server_port = try demo_host.free_port(io, server_seed),
    };
    defer stop_server(&rig);
    try route_replication(&rig);
    try start_server(&rig);
    return try load(&rig, seed);
}

// ---- The pair -----------------------------------------------------------------------------------

const Pair = struct {
    primary: []const u8,
    standby: []const u8,
    primary_port: u16,
    standby_port: u16,
};

/// Runs `pg_dev` with `args`; its output, or an error that has printed it.
fn pg_dev(gpa: Allocator, io: std.Io, exe: []const u8, args: []const []const u8) ![]u8 {
    assert(args.len >= 1);
    assert(args.len <= 2);
    var argv: [3][]const u8 = undefined;
    argv[0] = exe;
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, io, .{
        .argv = argv[0 .. args.len + 1],
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ok) return result.stdout;
    gpa.free(result.stdout);
    say("pg_dev {s} failed:\n{s}", .{ args[0], result.stderr });
    return error.PgDevFailed;
}

/// Runs a `pg_dev` command whose output is not needed.
fn pg_dev_do(gpa: Allocator, io: std.Io, exe: []const u8, command: []const u8) !void {
    gpa.free(try pg_dev(gpa, io, exe, &.{command}));
}

fn pair_up(gpa: Allocator, io: std.Io, arena: Allocator, exe: []const u8, mode: Mode) !Pair {
    const output = try pg_dev(gpa, io, exe, &.{ "pair-up", @tagName(mode) });
    defer gpa.free(output);
    var pair: Pair = .{ .primary = "", .standby = "", .primary_port = 0, .standby_port = 0 };
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ZCUBE_PG_PRIMARY=")) {
            pair.primary = try arena.dupe(u8, line["ZCUBE_PG_PRIMARY=".len..]);
            pair.primary_port = try faults.upstream_port(pair.primary);
        } else if (std.mem.startsWith(u8, line, "ZCUBE_PG_STANDBY=")) {
            pair.standby = try arena.dupe(u8, line["ZCUBE_PG_STANDBY=".len..]);
            pair.standby_port = try faults.upstream_port(pair.standby);
        }
    }
    if (pair.primary.len == 0 or pair.standby.len == 0) return error.PgDevOutput;
    return pair;
}

/// A plain connection to one node, for the run's own queries.
fn node(rig: *const Rig, conninfo: []const u8, diag: *Diag) !*pq.Connection {
    const settings = try rig.arena.dupeSentinel(u8, conninfo, 0);
    return pq.connect(diag, settings, "SELECT 1") catch |err| {
        faults.say_failure("cannot connect to a node of the pair", diag);
        return err;
    };
}

/// The first column of the first row of `sql` on `conn`, copied into the rig's arena.
fn query(rig: *const Rig, conn: *pq.Connection, sql: [:0]const u8) ![]const u8 {
    var diag: Diag = undefined;
    diag.reset();
    var result = pq.exec_simple(&diag, conn, sql, .{}) catch |err| {
        faults.say_failure(sql, &diag);
        return err;
    };
    defer result.clear();
    if (result.rows() == 0) return "";
    return try rig.arena.dupe(u8, result.bytes(0, 0));
}

/// Routes the standby's replication through `R`, and waits until it streams through it (and,
/// for `sync`, until the primary counts it as its synchronous standby).
fn route_replication(rig: *Rig) !void {
    var diag: Diag = undefined;
    diag.reset();
    const standby = try node(rig, rig.standby, &diag);
    defer pq.close(standby);
    const primary = try node(rig, rig.primary, &diag);
    defer pq.close(primary);
    // ALTER SYSTEM cannot run in a transaction block: one statement per call.
    const alter = try std.fmt.allocPrintSentinel(rig.arena, "ALTER SYSTEM SET primary_conninfo " ++
        "= 'host=127.0.0.1 port={d} user=zcube application_name={s}'", .{
        rig.replication.port, standby_name,
    }, 0);
    _ = try query(rig, standby, alter);
    _ = try query(rig, standby, "SELECT pg_reload_conf()");
    const port = try std.fmt.allocPrint(rig.arena, "{d}", .{rig.replication.port});
    const streaming_sql = "SELECT sender_port FROM pg_stat_wal_receiver WHERE status = 'streaming'";
    const sync_sql = "SELECT count(*) FROM pg_stat_replication WHERE sync_state = 'sync'";
    var waited: u32 = 0;
    while (waited < wait_ms_max) : (waited += poll_ms) {
        const routed = std.mem.eql(u8, try query(rig, standby, streaming_sql), port);
        const counted = rig.mode == .async or
            std.mem.eql(u8, try query(rig, primary, sync_sql), "1");
        if (routed and counted) return;
        faults.nap(rig.io, poll_ms);
    }
    return rig.fail("the standby did not stream through the replication proxy", .{});
}

/// Waits until the standby has replayed everything the primary has written so far.
fn wait_replayed(rig: *Rig) !void {
    var diag: Diag = undefined;
    diag.reset();
    const lsn = lsn: {
        const primary = try node(rig, rig.primary, &diag);
        defer pq.close(primary);
        break :lsn try query(rig, primary, "SELECT pg_current_wal_lsn()");
    };
    const standby = try node(rig, rig.standby, &diag);
    defer pq.close(standby);
    const format = "SELECT pg_last_wal_replay_lsn() >= '{s}'::pg_lsn";
    const sql = try std.fmt.allocPrintSentinel(rig.arena, format, .{lsn}, 0);
    var waited: u32 = 0;
    while (waited < wait_ms_max) : (waited += poll_ms) {
        if (std.mem.eql(u8, try query(rig, standby, sql), "t")) return;
        faults.nap(rig.io, poll_ms);
    }
    return rig.fail("the standby did not replay the primary's WAL", .{});
}

// ---- The server ---------------------------------------------------------------------------------

/// Starts `zcube-server` on the store through `C`, with a state directory that every start of
/// this run shares, and waits until it answers.
fn start_server(rig: *Rig) !void {
    assert(rig.server == null);
    rig.server_starts += 1;
    const arena = rig.arena;
    const log = try std.fmt.allocPrint(arena, "{s}/server-{d}.log", .{
        rig.work, rig.server_starts,
    });
    const file = try std.Io.Dir.cwd().createFile(rig.io, log, .{});
    defer file.close(rig.io);
    const listen = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{rig.server_port});
    const state = try std.fmt.allocPrint(arena, "{s}/state", .{rig.work});
    const store_arg = try std.fmt.allocPrint(arena, "postgres:{s}", .{rig.through});
    const argv = [_][]const u8{
        rig.options.server, "--listen",    listen, "--store",
        store_arg,          "--state-dir", state,  "--create-store",
        "--quiet",
    };
    if (rig.pki == null) rig.pki = .{
        .io = rig.io,
        .arena = arena,
        .server_exe = rig.options.server,
        .store = store_arg,
        .state_dir = state,
        .certs = try std.fmt.allocPrint(arena, "{s}/certs", .{rig.work}),
    };
    rig.server = try std.process.spawn(rig.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .{ .file = file },
    });
    // For the next run, should this one be killed before it kills the server.
    const pid = try std.fmt.allocPrint(arena, "{d}\n", .{rig.server.?.id.?});
    const pid_path = try std.fmt.allocPrint(arena, "{s}/server.pid", .{rig.work});
    try std.Io.Dir.cwd().writeFile(rig.io, .{ .sub_path = pid_path, .data = pid });
    var waited: u32 = 0;
    while (waited < wait_ms_max) : (waited += poll_ms) {
        if (!try tls_ready(rig)) {
            faults.nap(rig.io, poll_ms);
            continue;
        }
        if (call(rig, "GET", "/v1/status", "")) |reply| {
            if (reply.status == 200) return;
        } else |_| {}
        faults.nap(rig.io, poll_ms);
    }
    return rig.fail("the server did not answer within {d} ms", .{wait_ms_max});
}

/// SIGKILL and wait: the server's own shutdown is not under test.
fn stop_server(rig: *Rig) void {
    var child = rig.server orelse return;
    child.kill(rig.io);
    rig.server = null;
}

/// Kills the server a killed earlier run of this mode left running: the pid in its work
/// directory, if that process is still a `zcube-server` with its state there (a pid is reused).
fn kill_stale_server(io: std.Io, arena: Allocator, work: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const pid_path = std.fmt.allocPrint(arena, "{s}/server.pid", .{work}) catch return;
    // No file: no earlier run left a server.
    const text = cwd.readFileAlloc(io, pid_path, arena, .limited(32)) catch return;
    const pid_text = std.mem.trim(u8, text, " \n");
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch return; // Not ours.
    if (pid <= 1) return;
    const proc_path = std.fmt.allocPrint(arena, "/proc/{d}/cmdline", .{pid}) catch return;
    // `readFile`, not `readFileAlloc`: a /proc file's size is 0. Gone: nothing to kill.
    var buffer: [4096]u8 = undefined;
    const cmdline = cwd.readFile(io, proc_path, &buffer) catch return;
    if (!contains(cmdline, "zcube-server") or !contains(cmdline, work)) return;
    std.posix.kill(pid, .KILL) catch return; // It exited meanwhile.
    say("failover: killed zcube-server {d}, left running by a killed earlier run", .{pid});
}

/// Whether the rig holds its `failover` admin credentials: once the server wrote its CA, issues
/// them (the first time) and loads them. Only a CA not yet written is waited for.
fn tls_ready(rig: *Rig) !bool {
    if (rig.credentials != null) return true;
    // start_server makes the Pki before it starts the server.
    assert(rig.pki != null);
    const pki = &rig.pki.?;
    const ca = pki.find_ca() catch return rig.fail("{s}", .{pki.said});
    if (ca == null) return false;
    _ = pki.issue("failover", "admin") catch return rig.fail("{s}", .{pki.said});
    rig.credentials = pki.load("failover") catch return rig.fail("{s}", .{pki.said});
    return true;
}

fn call(rig: *const Rig, method: []const u8, target: []const u8, body: []const u8) !http.Reply {
    const address = try net.IpAddress.parse("127.0.0.1", rig.server_port);
    const credentials = rig.credentials orelse return error.ApiUnreachable;
    const client: http.Client = .{ .io = rig.io, .address = address, .tls = credentials };
    var diag: Diag = undefined;
    diag.reset();
    return client.call(rig.arena, .{ .method = method, .target = target, .body = body }, &diag);
}

/// The server's view of its store: `GET /v1/status`'s `store` object.
const Seen = struct {
    ok: bool,
    revision: u64 = 0,
    remembered: u64 = 0,
    save_failed: bool = false,
    code: []const u8 = "",
    body: []const u8,
};

fn status(rig: *const Rig) !Seen {
    const reply = try call(rig, "GET", "/v1/status", "");
    if (reply.status != 200) return rig.fail("GET /v1/status answered {d}", .{reply.status});
    const root = try std.json.parseFromSliceLeaky(Json, rig.arena, reply.body, .{});
    const state = member(root, "store") orelse return error.BadStatus;
    const ok = member(state, "ok") orelse return error.BadStatus;
    if (ok != .bool) return error.BadStatus;
    var seen: Seen = .{ .ok = ok.bool, .body = reply.body };
    if (member(state, "revision")) |value| seen.revision = try number(value);
    if (member(state, "remembered")) |pair| {
        if (member(pair, "revision")) |value| seen.remembered = try number(value);
    }
    seen.save_failed = member(state, "remembered_save_failed") != null;
    if (member(state, "diagnostic")) |diagnostic| {
        if (member(diagnostic, "code")) |code| {
            if (code == .string) seen.code = code.string;
        }
    }
    return seen;
}

fn member(value: Json, name: []const u8) ?Json {
    if (value != .object) return null;
    return value.object.get(name);
}

fn number(value: Json) !u64 {
    if (value != .integer) return error.BadStatus;
    if (value.integer < 0) return error.BadStatus;
    return @intCast(value.integer);
}

/// One write through the server: the service's replica count cycles, so every apply changes it.
fn apply(rig: *Rig) !http.Reply {
    rig.applies += 1;
    const body = try std.fmt.allocPrint(rig.arena, "{{\"name\":\"failover\"," ++
        "\"image\":\"b3:51aa9c03\",\"replicas\":{d},\"command\":[\"sh\",\"-c\",\"sleep 1\"]}}", .{
        rig.applies % 3 + 1,
    });
    return call(rig, "POST", "/v1/apply", body);
}

/// An apply that must succeed; `when` says where the run was.
fn apply_ok(rig: *Rig, comptime when: []const u8) !void {
    const reply = try apply(rig);
    if (reply.status / 100 != 2) {
        return rig.fail("an apply " ++ when ++ " answered {d}:\n{s}", .{
            reply.status, reply.body,
        });
    }
}

/// Applies until the server remembers at least `target`.
fn lead_to(rig: *Rig, target: u64) !Seen {
    var waited: u32 = 0;
    while (waited < wait_ms_max) : (waited += poll_ms) {
        try apply_ok(rig, "before the failover");
        const seen = try status(rig);
        if (seen.remembered >= target) return seen;
        faults.nap(rig.io, poll_ms);
    }
    return rig.fail("the server never remembered revision {d}", .{target});
}

// ---- The load and the failover ------------------------------------------------------------------

/// Makes the clients' store on the primary, then hands 10c's runner the staging (`conduct`).
fn load(rig: *Rig, seed: u64) !faults.Report {
    const gpa = rig.gpa;
    var real: RealClock = .{ .io = rig.io };
    const schema = try std.fmt.allocPrint(rig.arena, "zf_{x:0>16}", .{seed});
    const run_state: faults.Run = .{
        .gpa = gpa,
        .io = rig.io,
        .backend = .postgres,
        .seed = seed,
        .schema = schema,
        .sqlite_path = "",
        .mutation = .none,
        .ops_per_client = ops_per_client,
        .clock = real.clock(),
        .op_pause_ms = op_pause_ms,
    };
    var shared: faults.Shared = .{ .run = &run_state };
    const diag = try gpa.create(Diag);
    defer gpa.destroy(diag);
    diag.reset();
    const direct = try gpa.create(faults.Conn);
    defer gpa.destroy(direct);
    direct.open(&shared, rig.primary, diag) catch |err| {
        faults.say_failure("cannot open the clients' store on the primary", diag);
        return err;
    };
    defer direct.close(.postgres);
    const base = (try direct.interface(.postgres).status(diag)).revision;
    try wait_replayed(rig);
    return try faults.run_and_check(&shared, .{
        .direct_conninfo = rig.primary,
        .direct = direct.interface(.postgres),
        .diag = diag,
        .base = base,
        .proxy = rig.client,
        .conninfo = rig.through,
        .coverage = .failover,
    }, .{ .context = rig, .conduct_fn = conduct });
}

fn conduct(
    context: *anyopaque,
    shared: *faults.Shared,
    setup: faults.Setup,
    clients: []faults.Client,
    watcher: *faults.Watcher,
) anyerror!faults.Report {
    const rig: *Rig = @ptrCast(@alignCast(context));
    var threads: faults.Threads = .{};
    try threads.start(shared, clients, watcher);
    var clients_joined = false;
    var watcher_joined = false;
    defer {
        shared.stop_load.store(true, .release);
        if (!clients_joined) threads.join_clients();
        if (!watcher_joined) threads.watcher.join();
    }
    try stage(rig, shared);
    try fail_over(rig, shared);
    threads.join_clients();
    clients_joined = true;
    // From here the store is the promoted standby's, read without the proxy.
    const promoted = try rig.gpa.create(faults.Conn);
    defer rig.gpa.destroy(promoted);
    promoted.open(shared, rig.standby, setup.diag) catch |err| {
        faults.say_failure("cannot open the clients' store on the promoted standby", setup.diag);
        return err;
    };
    defer promoted.close(.postgres);
    var after = setup;
    after.direct = promoted.interface(.postgres);
    after.direct_conninfo = rig.standby;
    const final = (try after.direct.status(setup.diag)).revision;
    // `sync`: the watcher follows the promoted store to the end. `async`: it was stopped.
    shared.watch_final.store(final, .release);
    shared.watch_stop.store(true, .release);
    threads.watcher.join();
    watcher_joined = true;
    for (clients) |client| if (client.failure) |err| return faults.fail_client(err);
    if (watcher.failure) |err| return faults.fail_client(err);
    var log = try faults.read_log(rig.gpa, after.direct, after.base + 1, final, setup.diag);
    defer log.deinit(rig.gpa);
    const finished: faults.Finished = .{ .log = log.items, .final = final };
    const report = try faults.verdict(shared, after, clients, watcher, finished);
    return switch (rig.mode) {
        .sync => try judge_sync(rig, shared, report),
        .async => try judge_async(rig, report),
    };
}

/// Waits for a quarter of the load, then holds the clients while the server sees and saves
/// `lead_revisions` revisions, and cuts replication off: `async` before the lead (so the
/// server's revisions are past what the standby has), `sync` after it (so the window shows
/// that the primary acknowledges nothing its standby has not applied).
fn stage(rig: *Rig, shared: *faults.Shared) !void {
    const stage_ops = faults.clients_count * ops_per_client * stage_percent / 100;
    var waited: u32 = 0;
    while (shared.ops_done.load(.monotonic) < stage_ops) : (waited += poll_ms) {
        if (waited > wait_ms_max) return rig.fail("the load never reached the failover", .{});
        if (shared.clients_left.load(.acquire) == 0) return rig.fail("the load ended early", .{});
        try apply_ok(rig, "before the failover");
        faults.nap(rig.io, poll_ms);
    }
    if (rig.mode == .async) rig.replication.partition();
    try lead(rig, shared);
    if (rig.mode == .sync) rig.replication.partition();
    try cut_window(rig, shared);
}

/// With the clients held, makes the server see and save `lead_revisions` revisions.
fn lead(rig: *Rig, shared: *faults.Shared) !void {
    shared.hold.store(true, .release);
    defer shared.hold.store(false, .release);
    const held = (try status(rig)).revision;
    _ = try lead_to(rig, held + lead_revisions);
    // The remembered pair is saved at most every `verified_save_ms`, from a status or a write.
    faults.nap(rig.io, constants.verified_save_ms + 200);
    const saved = try status(rig);
    if (!saved.ok) return rig.fail("the store failed before the failover:\n{s}", .{saved.body});
    if (saved.save_failed) return rig.fail("the server could not save its revision", .{});
    rig.remembered = saved.remembered;
    rig.note("held at revision {d}; the server remembers {d}; {d} client calls made", .{
        held, saved.remembered, shared.ops_done.load(.monotonic),
    });
}

/// Counts the clients' acknowledged writes while the standby cannot hear the primary. `sync`:
/// none, as every commit waits for the standby to apply it (the clients block in COMMIT, so the
/// failover lands mid-commit). `async`: some, which the failover then loses.
fn cut_window(rig: *Rig, shared: *faults.Shared) !void {
    faults.nap(rig.io, cut_settle_ms); // A reply already on its way is not the primary's choice.
    const before = shared.acked_writes.load(.monotonic);
    faults.nap(rig.io, cut_window_ms);
    const acked = shared.acked_writes.load(.monotonic) - before;
    rig.note("replication cut off: {d} writes acknowledged in {d} ms", .{ acked, cut_window_ms });
    switch (rig.mode) {
        .sync => if (acked != 0) {
            return rig.fail("the primary acknowledged {d} writes its synchronous standby " ++
                "could not have applied", .{acked});
        },
        .async => if (acked == 0) {
            return rig.fail("no write was acknowledged with replication cut off: the loss " ++
                "would not be certain", .{});
        },
    }
}

/// The failover: new connections to the old primary hang, it crashes, the standby is promoted
/// and `C` sends new connections there. `async` stops the clients first.
fn fail_over(rig: *Rig, shared: *faults.Shared) !void {
    if (shared.clients_left.load(.acquire) == 0) {
        return rig.fail("the load ended before the failover", .{});
    }
    if (rig.mode == .async) shared.stop_load.store(true, .release);
    rig.client.black_hole(true);
    try pg_dev_do(rig.gpa, rig.io, rig.options.pg_dev, "pair-crash");
    if (rig.mode == .async) {
        // No client may reach the promoted store: what it wrote there would reuse revisions.
        var waited: u32 = 0;
        while (shared.clients_left.load(.acquire) != 0) : (waited += poll_ms) {
            if (waited > wait_ms_max) return rig.fail("the clients did not stop", .{});
            faults.nap(rig.io, poll_ms);
        }
    }
    try pg_dev_do(rig.gpa, rig.io, rig.options.pg_dev, "pair-promote");
    // Read before anything can reach the promoted store: nothing may write there later.
    if (rig.mode == .async) rig.promoted_at = try promoted_revision(rig);
    rig.client.repoint(rig.standby_port);
    rig.client.heal();
    rig.acked_at_heal = shared.acked_writes.load(.monotonic);
    rig.note("failed over at {d} client calls", .{shared.ops_done.load(.monotonic)});
}

// ---- Verdicts -----------------------------------------------------------------------------------

/// A lossless failover: the checker passed, the failover landed mid-commit, the load carried on
/// past it, and the server carries on on the promoted store.
fn judge_sync(rig: *Rig, shared: *faults.Shared, report: faults.Report) !faults.Report {
    if (!report.passed) {
        rig.note("FAILED: the history checker rejected a failover to a synchronous standby", .{});
        return report;
    }
    // The store serialises commits on its meta row, so in the window one client waits in
    // COMMIT and the others wait before theirs (recorded as failed: nothing written). One
    // unknown per run is what a crash mid-commit leaves; none means it never landed there.
    const in_flight = report.unknown_applied + report.unknown_absent;
    if (in_flight == 0) {
        return rig.fail("no commit was in flight at the crash: the run did not test one", .{});
    }
    const after = shared.acked_writes.load(.monotonic) - rig.acked_at_heal;
    if (after < writes_after_heal_min) {
        return rig.fail("the clients acknowledged {d} writes on the promoted store, below " ++
            "{d}: the load did not cross the failover", .{ after, writes_after_heal_min });
    }
    try apply_ok(rig, "after the failover");
    const seen = try status(rig);
    if (!seen.ok) return rig.fail("the server refused the promoted store:\n{s}", .{seen.body});
    if (seen.remembered < rig.remembered) {
        return rig.fail("the server remembers {d}, below {d} before the failover", .{
            seen.remembered, rig.remembered,
        });
    }
    rig.note("PASS: no acknowledged write lost; {d} commits in flight at the crash; {d} writes " ++
        "acknowledged after it; the server carries on at revision {d}", .{
        in_flight, after, seen.remembered,
    });
    return report;
}

/// A lossy failover: the server must refuse the promoted store (ZC-E0215) on a write, on
/// status and across a restart, nothing may have written there, and the checker must report the
/// lost acknowledged writes.
fn judge_async(rig: *Rig, report: faults.Report) !faults.Report {
    const promoted = rig.promoted_at;
    if (promoted >= rig.remembered) {
        return rig.fail("the loss was not certain: the promoted store is at {d}, the server " ++
            "remembers {d}", .{ promoted, rig.remembered });
    }
    const expected = try std.fmt.allocPrint(rig.arena, "the store is at revision {d}", .{
        promoted,
    });
    // The write path first, on its own: no status call has told the server yet.
    const reply = try apply(rig);
    if (reply.status != 502 or !contains(reply.body, "ZC-E0215")) {
        return rig.fail("an apply on the promoted store answered {d}, not 502 with " ++
            "ZC-E0215:\n{s}", .{ reply.status, reply.body });
    }
    try expect_halted(rig, try status(rig), expected, "after the failover");
    stop_server(rig);
    try start_server(rig);
    try expect_halted(rig, try status(rig), expected, "after a restart");
    const now = try promoted_revision(rig);
    if (now != promoted) {
        return rig.fail("the promoted store moved from {d} to {d}: a halted server wrote", .{
            promoted, now,
        });
    }
    if (report.passed or report.kind != .lost_write) {
        return rig.fail("the history checker did not report a lost write (passed={}, " ++
            "kind={any})", .{ report.passed, report.kind });
    }
    rig.note("PASS: the promoted store is at {d}, the server remembers {d}; ZC-E0215 on " ++
        "apply, status and restart; the store did not move; the checker reports a lost write", .{
        promoted, rig.remembered,
    });
    return .{ .passed = true };
}

fn expect_halted(rig: *Rig, seen: Seen, expected: []const u8, comptime when: []const u8) !void {
    const halted = !seen.ok and std.mem.eql(u8, seen.code, "ZC-E0215") and
        contains(seen.body, "the store is behind") and contains(seen.body, expected);
    if (!halted) {
        return rig.fail("the server did not halt with ZC-E0215 (\"{s}\") " ++ when ++ ":\n{s}", .{
            expected, seen.body,
        });
    }
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

/// The revision of the server's store on the promoted standby, read without the server.
fn promoted_revision(rig: *Rig) !u64 {
    var diag: Diag = undefined;
    diag.reset();
    const promoted = try rig.gpa.create(PostgresStore);
    defer rig.gpa.destroy(promoted);
    promoted.open(rig.io, .{
        .conninfo = rig.standby,
        .schema = server_schema,
        .create = false,
    }, &diag) catch |err| {
        faults.say_failure("cannot open the server's store on the promoted standby", &diag);
        return err;
    };
    defer promoted.close();
    return (try promoted.interface().status(&diag)).revision;
}
