//! `zig build test-store-faults -Dbackend=postgres|sqlite [-Dseed=N] [-Dpostgres=...]`: several
//! client threads issue real `Store` calls while a seeded fault schedule cuts, delays, stalls
//! and black-holes their connections; every call is recorded and the history is checked
//! (`testing/history.zig`). Shell code: threads and sockets.
//!
//! ## What a run does
//!
//! - `clients_count` threads each make `ops_per_client` calls on a `Store` of their own:
//!   reads and compare-and-set on register keys (ids below `history.audit_key_min`), blind
//!   puts, and compare-and-sets that cannot succeed, whose `on_failure` branch puts an audit
//!   key (id from `audit_key_min`). Every value is a token from one shared counter, so each
//!   write can be found in the log. One watcher thread follows prefix `/h/` from the first
//!   revision after the base, and reopens its watch from its bookmark whenever it breaks (and
//!   now and then on purpose).
//! - Postgres: the clients and the watcher connect through a `FaultProxy` in front of the
//!   database; the main thread plays the schedule drawn from the seed (latency, `cut_all`,
//!   `cut_after` at varied byte counts so cuts land mid-transaction and near `COMMIT`, one-way
//!   stalls, partitions, the black hole, `heal`). A store error with code ZC-E0213 ("outcome
//!   unknown": the write may or may not have been applied) is recorded as `unknown`; any other
//!   store error as `fail`, which the checker takes to mean nothing was changed.
//! - SQLite has no connection to cut, so no proxy applies: it runs the same clients and the
//!   same checker, without faults. The output says so.
//! - At the end: `heal`, read `status.revision` on a direct connection (not through the
//!   proxy), read the whole log from base + 1 there, then `history.check` and `check_watch`
//!   with the same `Options`. A failure prints the verdict and the seed and exits 1.
//!
//! The run is bounded for the checker: `history.check_revision_order` is quadratic in the
//! number of calls, so a run stays at a few thousand.

const std = @import("std");
const assert = std.debug.assert;
const Diag = @import("diag.zig").Diag;
const codes = @import("diag/codes.zig");
const RealClock = @import("agent_clock.zig").RealClock;
const store = @import("store.zig");
const PostgresStore = @import("store_postgres.zig").PostgresStore;
const SqliteStore = @import("store_sqlite.zig").SqliteStore;
const fault_proxy = @import("testing/fault_proxy.zig");
const history = @import("testing/history.zig");

const Allocator = std.mem.Allocator;
const Store = store.Store;

const clients_count = 4;
const ops_per_client = 250;
const register_keys = 64;
const wrong_revision_offset = 1_000_000;
const watch_prefix = "/h/";
const watch_poll_ms = 30;
const watch_polls_per_open = 20;
const watch_polls_max = 100_000;
const catch_up_ms = 30_000;
const exit_user = 2;

const Backend = enum { postgres, sqlite };

const Options = struct {
    backend: Backend,
    postgres: []const u8,
    seed: ?u64,
};

/// A store connection of either kind. In place: stores point back at themselves.
const Conn = struct {
    postgres: PostgresStore,
    sqlite: SqliteStore,

    fn open(conn: *Conn, shared: *const Shared, conninfo: []const u8, diag: *Diag) !void {
        const run = shared.run;
        switch (run.backend) {
            .postgres => try conn.postgres.open(run.io, .{
                .conninfo = conninfo,
                .schema = run.schema,
                .create = true,
            }, diag),
            .sqlite => try conn.sqlite.open(run.io, run.clock, run.sqlite_path, .{
                .create = true,
                .sync = .normal,
            }, diag),
        }
    }

    fn interface(conn: *Conn, backend: Backend) Store {
        return switch (backend) {
            .postgres => conn.postgres.interface(),
            .sqlite => conn.sqlite.interface(),
        };
    }

    fn close(conn: *Conn, backend: Backend) void {
        switch (backend) {
            .postgres => conn.postgres.close(),
            .sqlite => conn.sqlite.close(),
        }
    }
};

/// What stays fixed for the run.
const Run = struct {
    gpa: Allocator,
    io: std.Io,
    backend: Backend,
    seed: u64,
    schema: []const u8,
    sqlite_path: []const u8,
    clock: @import("clock.zig").Clock,
};

const Shared = struct {
    run: *const Run,
    ticker: history.Ticker = .{},
    next_token: std.atomic.Value(u64) = .init(1),
    clients_left: std.atomic.Value(u32) = .init(clients_count),
    watch_stop: std.atomic.Value(bool) = .init(false),
    /// The revision the watcher must reach once the clients are done; 0 until known.
    watch_final: std.atomic.Value(u64) = .init(0),

    fn token(shared: *Shared) u64 {
        return shared.next_token.fetchAdd(1, .monotonic);
    }
};

fn nap(io: std.Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {}; // Cancelled: the run is over.
}

// ---- Clients ------------------------------------------------------------------------------------

const Client = struct {
    shared: *Shared,
    id: u32,
    recorder: history.Recorder,
    conn: Conn,
    diag: Diag,
    rng: std.Random.DefaultPrng,
    last_seen: [register_keys]u64,
    failure: ?anyerror,

    fn s(client: *Client) Store {
        return client.conn.interface(client.shared.run.backend);
    }
};

fn client_main(client: *Client) void {
    run_client(client) catch |err| {
        client.failure = err;
    };
    _ = client.shared.clients_left.fetchSub(1, .acq_rel);
}

fn run_client(client: *Client) !void {
    var arena_state = std.heap.ArenaAllocator.init(client.shared.run.gpa);
    defer arena_state.deinit();
    const rng = client.rng.random();
    for (0..ops_per_client) |_| {
        _ = arena_state.reset(.retain_capacity);
        const key = rng.uintLessThan(u8, register_keys);
        const roll = rng.uintLessThan(u32, 100);
        if (roll < 40) {
            try do_read(client, arena_state.allocator(), key);
        } else if (roll < 75) {
            try do_cas(client, key, client.last_seen[key]);
        } else if (roll < 85) {
            try do_cas(client, key, client.last_seen[key] + wrong_revision_offset);
        } else {
            try do_blind(client, key);
        }
    }
}

fn do_read(client: *Client, arena: Allocator, key: u8) !void {
    const shared = client.shared;
    const handle = try client.recorder.invoke(&shared.ticker, .{ .read = key });
    var key_buffer: [8]u8 = undefined;
    const name = history.key_text(&key_buffer, key);
    const found = client.s().get(arena, name, null, &client.diag) catch {
        client.diag.reset();
        client.recorder.fail(&shared.ticker, handle);
        return;
    };
    var ack: history.ReadAck = .{ .mod_revision = 0, .value = 0 };
    if (found.kv) |kv| {
        ack = .{
            .mod_revision = kv.mod_revision,
            .value = history.parse_value(kv.value) orelse return error.BadValue,
        };
    }
    client.recorder.ack_read(&shared.ticker, handle, ack);
    client.last_seen[key] = ack.mod_revision;
}

fn do_cas(client: *Client, key: u8, expected: u64) !void {
    const shared = client.shared;
    const success: [1]history.Put = .{.{ .key = key, .value = shared.token() }};
    const audit: u8 = @intCast(history.audit_key_min + client.id);
    const failure: [1]history.Put = .{.{ .key = audit, .value = shared.token() }};
    const txn: history.Txn = .{
        .compare = .{ .key = key, .mod_revision = expected },
        .success = &success,
        .failure = &failure,
    };
    if (try do_txn(client, txn)) |result| {
        if (result.succeeded) client.last_seen[key] = result.revision;
    }
}

fn do_blind(client: *Client, key: u8) !void {
    const success: [1]history.Put = .{.{ .key = key, .value = client.shared.token() }};
    const txn: history.Txn = .{ .compare = null, .success = &success, .failure = &.{} };
    if (try do_txn(client, txn)) |result| client.last_seen[key] = result.revision;
}

/// Makes the call and records it; null if it did not return an answer.
fn do_txn(client: *Client, txn: history.Txn) !?history.TxnAck {
    const shared = client.shared;
    const handle = try client.recorder.invoke(&shared.ticker, .{ .txn = txn });
    var texts: [3]struct { key: [8]u8, value: [24]u8 } = undefined;
    var success_ops: [1]store.Op = undefined;
    var failure_ops: [1]store.Op = undefined;
    var compares: [1]store.Compare = undefined;
    var used: usize = 0;
    for (txn.success, 0..) |put, index| {
        success_ops[index] = op_of(&texts[used].key, &texts[used].value, put);
        used += 1;
    }
    for (txn.failure, 0..) |put, index| {
        failure_ops[index] = op_of(&texts[used].key, &texts[used].value, put);
        used += 1;
    }
    var request: store.TxnRequest = .{
        .on_success = success_ops[0..txn.success.len],
        .on_failure = failure_ops[0..txn.failure.len],
    };
    if (txn.compare) |compare| {
        compares[0] = .{
            .key = history.key_text(&texts[used].key, compare.key),
            .mod_revision = compare.mod_revision,
        };
        request.compares = &compares;
    }
    const result = client.s().txn(request, &client.diag) catch {
        const lost = client.diag.code.? == codes.Code.E0213;
        client.diag.reset();
        if (lost) client.recorder.unknown(handle) else client.recorder.fail(&shared.ticker, handle);
        return null;
    };
    const ack: history.TxnAck = .{ .succeeded = result.succeeded, .revision = result.revision };
    client.recorder.ack_txn(&shared.ticker, handle, ack);
    return ack;
}

fn op_of(key_buffer: *[8]u8, value_buffer: *[24]u8, put: history.Put) store.Op {
    return .{ .put = .{
        .key = history.key_text(key_buffer, put.key),
        .value = history.value_text(value_buffer, put.value),
    } };
}

// ---- The watcher --------------------------------------------------------------------------------

const Watcher = struct {
    shared: *Shared,
    conn: Conn,
    diag: Diag,
    from_revision: u64,
    bookmark: u64,
    events: std.ArrayList(history.LogEvent),
    opens: u32,
    failure: ?anyerror,

    fn s(watcher: *Watcher) Store {
        return watcher.conn.interface(watcher.shared.run.backend);
    }
};

fn log_event(event: store.Event) !history.LogEvent {
    return .{
        .revision = event.kv.mod_revision,
        .kind = switch (event.kind) {
            .put => .put,
            .delete => .delete,
        },
        .key = history.parse_key(event.kv.key) orelse return error.BadKey,
        .value = if (event.kind == .put)
            history.parse_value(event.kv.value) orelse return error.BadValue
        else
            0,
    };
}

fn watcher_main(watcher: *Watcher) void {
    watch_until_caught_up(watcher) catch |err| {
        watcher.failure = err;
    };
}

fn watch_until_caught_up(watcher: *Watcher) !void {
    const shared = watcher.shared;
    const run = shared.run;
    var arena_state = std.heap.ArenaAllocator.init(run.gpa);
    defer arena_state.deinit();
    var deadline: u64 = 0;
    while (true) {
        const final = shared.watch_final.load(.acquire);
        if (final != 0 and watcher.bookmark >= final) return;
        if (shared.watch_stop.load(.acquire)) {
            if (deadline == 0) deadline = run.clock.now_ms() + catch_up_ms;
            if (run.clock.now_ms() > deadline) return error.WatcherDidNotCatchUp;
        }
        var watch = watcher.s().watch(.{
            .prefix = watch_prefix,
            .from_revision = watcher.bookmark + 1,
        }, &watcher.diag) catch {
            watcher.diag.reset();
            nap(run.io, 10);
            continue;
        };
        watcher.opens += 1;
        try poll_watch(watcher, &watch, &arena_state);
        watch.close();
    }
}

/// Reads batches until the watch breaks, has been open for a while, or has reached the end.
fn poll_watch(watcher: *Watcher, watch: *store.Watch, arena_state: *std.heap.ArenaAllocator) !void {
    const gpa = watcher.shared.run.gpa;
    for (0..watch_polls_per_open) |_| {
        _ = arena_state.reset(.retain_capacity);
        const batch = watch.next(arena_state.allocator(), watch_poll_ms, &watcher.diag) catch {
            watcher.diag.reset();
            return;
        };
        for (batch.events) |event| try watcher.events.append(gpa, try log_event(event));
        watcher.bookmark = batch.revision;
        const final = watcher.shared.watch_final.load(.acquire);
        if (final != 0 and watcher.bookmark >= final) return;
    }
}

// ---- The fault schedule -------------------------------------------------------------------------

fn pick_direction(rng: std.Random) fault_proxy.Direction {
    return if (rng.boolean()) .to_server else .to_client;
}

/// One step of the schedule, then a pause. Every fault but `cut_all` is undone by `heal`.
fn fault_step(proxy: *fault_proxy.Proxy, rng: std.Random, io: std.Io) void {
    switch (rng.uintLessThan(u32, 8)) {
        0 => {
            proxy.set_latency(rng.intRangeAtMost(u32, 1, 15));
            nap(io, rng.intRangeAtMost(u64, 100, 300));
        },
        1 => proxy.cut_all(),
        2, 3 => {
            // Half the cuts are close to the arming point: a small message, or COMMIT.
            const limit: u64 = if (rng.boolean()) 40 else 600;
            proxy.cut_after(pick_direction(rng), rng.uintAtMost(u64, limit));
        },
        4 => {
            proxy.stall(pick_direction(rng));
            nap(io, rng.intRangeAtMost(u64, 50, 300));
        },
        5 => {
            proxy.black_hole(true);
            nap(io, rng.intRangeAtMost(u64, 50, 300));
        },
        6 => {
            proxy.partition();
            nap(io, rng.intRangeAtMost(u64, 50, 200));
        },
        else => {},
    }
    if (rng.uintLessThan(u32, 3) != 0) proxy.heal();
    nap(io, rng.intRangeAtMost(u64, 20, 120));
}

// ---- Setup and verdict --------------------------------------------------------------------------

/// The log from `from` to `final`, read through `s`.
fn read_log(
    gpa: Allocator,
    s: Store,
    from: u64,
    final: u64,
    diag: *Diag,
) !std.ArrayList(history.LogEvent) {
    var log: std.ArrayList(history.LogEvent) = .empty;
    errdefer log.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var watch = try s.watch(.{ .prefix = watch_prefix, .from_revision = from }, diag);
    defer watch.close();
    for (0..watch_polls_max) |_| {
        _ = arena_state.reset(.retain_capacity);
        const batch = try watch.next(arena_state.allocator(), 0, diag);
        for (batch.events) |event| try log.append(gpa, try log_event(event));
        if (batch.revision >= final) return log;
    }
    return error.LogNotReached;
}

/// The port in libpq settings in keyword/value form (5432 if none is given).
fn upstream_port(conninfo: []const u8) !u16 {
    var words = std.mem.tokenizeScalar(u8, conninfo, ' ');
    var port: u16 = 5432;
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "port=")) port = try std.fmt.parseInt(u16, word[5..], 10);
    }
    return port;
}

const Outcome = struct {
    ok: u32 = 0,
    failed: u32 = 0,
    unknown: u32 = 0,
};

fn tally(entries: []const history.Entry) Outcome {
    var total: Outcome = .{};
    for (entries) |entry| switch (entry.outcome) {
        .acked => total.ok += 1,
        .failed => total.failed += 1,
        .unknown => total.unknown += 1,
    };
    return total;
}

fn say(comptime format: []const u8, args: anytype) void {
    std.debug.print("store-faults: " ++ format ++ "\n", args);
}

fn parse_options(args: []const []const u8) ?Options {
    var options: Options = .{ .backend = .postgres, .postgres = "", .seed = null };
    var index: usize = 1;
    while (index + 1 < args.len) : (index += 2) {
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--backend")) {
            options.backend = std.meta.stringToEnum(Backend, value) orelse return null;
        } else if (std.mem.eql(u8, name, "--postgres")) {
            options.postgres = value;
        } else if (std.mem.eql(u8, name, "--seed")) {
            options.seed = std.fmt.parseInt(u64, value, 10) catch return null;
        } else {
            return null;
        }
    }
    if (index != args.len) return null;
    if (options.backend == .postgres and options.postgres.len == 0) return null;
    return options;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return exit_user;
    const options = parse_options(args) orelse {
        say("usage: store_faults --backend postgres|sqlite [--postgres SETTINGS] [--seed N]", .{});
        return exit_user;
    };
    var seed_bytes: [8]u8 = undefined;
    init.io.random(&seed_bytes);
    const seed = options.seed orelse std.mem.readInt(u64, &seed_bytes, .little);
    say("backend={s} seed={d} (replay: -Dseed={d})", .{ @tagName(options.backend), seed, seed });
    if (options.backend == .sqlite) {
        say("sqlite: no proxy applies; history checker only, no faults", .{});
    }
    const passed = execute(init, options, seed) catch |err| {
        say("ERROR {s} seed={d}", .{ @errorName(err), seed });
        return 1;
    };
    if (!passed) say("FAIL seed={d} (replay: -Dseed={d})", .{ seed, seed });
    return if (passed) 0 else 1;
}

fn execute(init: std.process.Init, options: Options, seed: u64) !bool {
    const gpa = init.gpa;
    var schema_buffer: [32]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buffer, "zf_{x:0>16}", .{seed});
    var path_buffer: [96]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/store-faults-{d}", .{seed});
    var file_buffer: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/s.db", .{directory});
    var real: RealClock = .{ .io = init.io };
    const run: Run = .{
        .gpa = gpa,
        .io = init.io,
        .backend = options.backend,
        .seed = seed,
        .schema = schema,
        .sqlite_path = file,
        .clock = real.clock(),
    };
    if (options.backend == .sqlite) try std.Io.Dir.cwd().createDirPath(init.io, directory);
    defer if (options.backend == .sqlite) {
        std.Io.Dir.cwd().deleteTree(init.io, directory) catch {}; // Best effort: it is scratch.
    };
    return try drive(&run, options);
}

fn drive(run: *const Run, options: Options) !bool {
    const gpa = run.gpa;
    var shared: Shared = .{ .run = run };
    const diag = try gpa.create(Diag);
    defer gpa.destroy(diag);
    diag.reset();
    // The direct connection: never through the proxy. It creates the store and drops it.
    const direct = try gpa.create(Conn);
    defer gpa.destroy(direct);
    direct.open(&shared, options.postgres, diag) catch |err| {
        say("cannot open the store: {s}", .{@errorName(err)});
        return err;
    };
    defer {
        if (run.backend == .postgres) direct.postgres.drop_schema(diag) catch {};
        direct.close(run.backend);
    }
    const direct_store = direct.interface(run.backend);
    const base = (try direct_store.status(diag)).revision;
    var proxy: ?*fault_proxy.Proxy = null;
    var client_conninfo: []const u8 = options.postgres;
    if (run.backend == .postgres) {
        proxy = try fault_proxy.Proxy.start(gpa, try upstream_port(options.postgres));
        client_conninfo = try std.fmt.allocPrint(gpa, "{s} host=127.0.0.1 port={d}", .{
            options.postgres, proxy.?.port,
        });
    }
    defer if (proxy) |p| {
        p.stop();
        gpa.free(client_conninfo);
    };
    return try run_and_check(&shared, .{
        .direct = direct_store,
        .diag = diag,
        .base = base,
        .proxy = proxy,
        .conninfo = client_conninfo,
    });
}

const Setup = struct {
    direct: Store,
    diag: *Diag,
    base: u64,
    proxy: ?*fault_proxy.Proxy,
    conninfo: []const u8,
};

fn run_and_check(shared: *Shared, setup: Setup) !bool {
    const run = shared.run;
    const gpa = run.gpa;
    const clients = try gpa.alloc(Client, clients_count);
    defer gpa.free(clients);
    var opened: usize = 0;
    defer for (clients[0..opened]) |*client| {
        client.recorder.deinit();
        client.conn.close(run.backend);
    };
    for (clients, 0..) |*client, index| {
        client.* = .{
            .shared = shared,
            .id = @intCast(index),
            .recorder = history.Recorder.init(gpa, @intCast(index)),
            .conn = undefined,
            .diag = undefined,
            .rng = .init(run.seed ^ (0x9e3779b97f4a7c15 *% (index + 1))),
            .last_seen = @splat(0),
            .failure = null,
        };
        client.diag.reset();
        try client.conn.open(shared, setup.conninfo, &client.diag);
        opened += 1;
    }
    const watcher = try gpa.create(Watcher);
    defer gpa.destroy(watcher);
    watcher.* = .{
        .shared = shared,
        .conn = undefined,
        .diag = undefined,
        .from_revision = setup.base + 1,
        .bookmark = setup.base,
        .events = .empty,
        .opens = 0,
        .failure = null,
    };
    defer watcher.events.deinit(gpa);
    watcher.diag.reset();
    try watcher.conn.open(shared, setup.conninfo, &watcher.diag);
    defer watcher.conn.close(run.backend);
    return try play(shared, setup, clients, watcher);
}

fn play(shared: *Shared, setup: Setup, clients: []Client, watcher: *Watcher) !bool {
    const run = shared.run;
    const gpa = run.gpa;
    var threads: [clients_count]std.Thread = undefined;
    const watch_thread = try std.Thread.spawn(.{}, watcher_main, .{watcher});
    for (clients, 0..) |*client, index| {
        threads[index] = try std.Thread.spawn(.{}, client_main, .{client});
    }
    var schedule = std.Random.DefaultPrng.init(run.seed ^ 0x5851f42d4c957f2d);
    while (shared.clients_left.load(.acquire) != 0) {
        if (setup.proxy) |proxy| {
            fault_step(proxy, schedule.random(), run.io);
        } else {
            nap(run.io, 20);
        }
    }
    for (threads) |thread| thread.join();
    if (setup.proxy) |proxy| proxy.heal();
    const final = (try setup.direct.status(setup.diag)).revision;
    shared.watch_final.store(final, .release);
    shared.watch_stop.store(true, .release);
    watch_thread.join();
    for (clients) |client| if (client.failure) |err| return fail_client(err);
    if (watcher.failure) |err| return fail_client(err);
    var log = try read_log(gpa, setup.direct, setup.base + 1, final, setup.diag);
    defer log.deinit(gpa);
    return try verdict(shared, setup, clients, watcher, .{ .log = log.items, .final = final });
}

fn fail_client(err: anyerror) bool {
    say("a client thread stopped: {s}", .{@errorName(err)});
    return false;
}

const Finished = struct {
    log: []const history.LogEvent,
    final: u64,
};

fn verdict(
    shared: *Shared,
    setup: Setup,
    clients: []Client,
    watcher: *const Watcher,
    finished: Finished,
) !bool {
    const gpa = shared.run.gpa;
    var recorders: [clients_count]*const history.Recorder = undefined;
    for (clients, 0..) |*client, index| recorders[index] = &client.recorder;
    const entries = try history.merge(gpa, &recorders);
    defer gpa.free(entries);
    const options: history.Options = .{
        .base_revision = setup.base,
        .final_revision = finished.final,
    };
    const total = tally(entries);
    say("calls={d} acked={d} failed={d} unknown={d} log_events={d} " ++
        "revision={d} watch_opens={d}", .{
        entries.len,      total.ok,       total.failed,  total.unknown,
        finished.log.len, finished.final, watcher.opens,
    });
    if (setup.proxy) |proxy| {
        const stats = proxy.stats();
        say("proxy: accepted={d} upstream_connects={d} cuts={d}", .{
            stats.accepted, stats.upstream_connects, stats.cuts,
        });
        if (stats.accepted == 0) return error.ProxyUnused;
    }
    const checked = try history.check(gpa, entries, finished.log, options);
    if (checked != .ok) {
        say("history: {any}", .{checked});
        return false;
    }
    const record: history.WatchRecord = .{
        .from_revision = watcher.from_revision,
        .bookmark = watcher.bookmark,
        .events = watcher.events.items,
    };
    const watched = history.check_watch(finished.log, record, options);
    if (watched != .ok) {
        say("watch: {any}", .{watched});
        return false;
    }
    say("PASS", .{});
    return true;
}
