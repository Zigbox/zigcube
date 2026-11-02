//! `zig build test-store-faults -Dbackend=postgres|sqlite [-Dseed=N] [-Dpostgres=...]`: several
//! client threads issue real `Store` calls while a seeded fault schedule cuts, delays, stalls
//! and black-holes their connections; every call is recorded and the history is checked
//! (`testing/history.zig`). Shell code: threads and sockets.
//!
//! ## What a run does
//!
//! - `clients_count` threads each make `ops_per_client` calls on a `Store` of their own,
//!   spread over a few hot keys per phase so that clients overlap on a key (`hot_keys`):
//!   reads and compare-and-set on register keys (ids below `history.audit_key_min`), blind
//!   puts, and compare-and-sets that cannot succeed, whose `on_failure` branch puts an audit
//!   key (id from `audit_key_min`). Every value is a token from one shared counter, so each
//!   write can be found in the log. One watcher thread follows prefix `/h/` from the first
//!   revision after the base, and reopens its watch from its bookmark whenever it breaks (and
//!   now and then on purpose).
//! - Postgres: the clients and the watcher connect through a `FaultProxy` in front of the
//!   database; the main thread plays the schedule drawn from the seed (latency, `cut_all`,
//!   `cut_after` at varied byte counts so cuts land mid-transaction, `cut_on_commit_reply`, which
//!   resets the connection on the server's COMMIT reply (the commit is made, the client never
//!   hears), one-way stalls, partitions, the black hole, `heal`). A ZC-E0213 raised while
//!   committing ("outcome unknown": the write may or may not have been applied) is recorded as
//!   `unknown`; any other store error, a drop before the COMMIT included, as `fail`, which the
//!   checker takes to mean nothing was changed. The summary splits the unknowns into those found
//!   in the log (`applied`) and those absent; a faulted run with no `applied` unknown has not
//!   exercised the lost acknowledgement and fails.
//! - After the clients finish and the proxy is healed, the runner waits until no store backend is
//!   busy before it reads the final revision, so a COMMIT that finishes late is in the log it
//!   checks. The checker's own test is below: `--mutate` (hidden) makes the clients' stores lie
//!   (`store_mutant.zig`) and the test asserts that each lie is rejected.
//! - Calls also include compare-and-deletes (the success branch carries an audit put, so a lost
//!   answer is found in the log by its token). After the log is read, stage 2 (`Reader`) runs
//!   historical reads and compactions, since a compacted log cannot be read back, and
//!   `history.check_compaction` judges them against that log. Leases are not covered.
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
const diag_mod = @import("diag.zig");
const constants = @import("constants.zig");
const Diag = diag_mod.Diag;
const RealClock = @import("agent_clock.zig").RealClock;
const store = @import("store.zig");
const pq = @import("pq.zig");
const Mutant = @import("store_mutant.zig").Mutant;
const Mutation = @import("store_mutant.zig").Mutation;
const PostgresStore = @import("store_postgres.zig").PostgresStore;
const SqliteStore = @import("store_sqlite.zig").SqliteStore;
const fault_proxy = @import("testing/fault_proxy.zig");
const history = @import("testing/history.zig");

const Allocator = std.mem.Allocator;
const Store = store.Store;

const clients_count = 4;
const ops_per_client = 250;
/// Calls are spread over a few hot keys at a time, so that clients really overlap on a key: a
/// client's `phase_ops` calls go to `hot_keys` keys of its current phase, and each phase has keys
/// of its own. The checker's search is bounded per key (`history.key_calls_max`), so a key takes
/// at most `key_calls_cap` calls; `register_keys` holds every phase of a full run.
const hot_keys = 4;
const phase_ops = 16;
const register_keys = 64;
const key_calls_cap = 56;
const quiet_polls_max = 200;
const quiet_samples = 3;
const quiet_poll_ms = 50;
comptime {
    assert(key_calls_cap < history.key_calls_max);
    assert(register_keys < history.audit_key_min);
    assert(@divExact(register_keys, hot_keys) * phase_ops >= ops_per_client);
    assert(clients_count * phase_ops <= hot_keys * key_calls_cap);
}
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
    /// Test hook (hidden flag `--mutate`): the clients' stores lie, and the run must fail.
    mutation: Mutation = .none,
    ops_per_client: u32 = ops_per_client,
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
    mutation: Mutation,
    ops_per_client: u32,
    clock: @import("clock.zig").Clock,
};

const Shared = struct {
    run: *const Run,
    ticker: history.Ticker = .{},
    next_token: std.atomic.Value(u64) = .init(1),
    clients_left: std.atomic.Value(u32) = .init(clients_count),
    watch_stop: std.atomic.Value(bool) = .init(false),
    /// Calls made on each register key, so that none passes the checker's bound.
    key_calls: [register_keys]std.atomic.Value(u32) = @splat(.init(0)),
    /// The revision the watcher must reach once the clients are done; 0 until known.
    watch_final: std.atomic.Value(u64) = .init(0),

    /// Counts a call on `key`; false if the key has had its share.
    fn reserve(shared: *Shared, key: u8) bool {
        assert(key < register_keys);
        const before = shared.key_calls[key].fetchAdd(1, .monotonic);
        assert(before < std.math.maxInt(u32) / 2); // A runaway loop, not a busy key.
        return before < key_calls_cap;
    }

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
    mutant: Mutant,
    diag: Diag,
    rng: std.Random.DefaultPrng,
    last_seen: [register_keys]u64,
    failure: ?anyerror,

    fn s(client: *Client) Store {
        const real = client.conn.interface(client.shared.run.backend);
        if (client.shared.run.mutation == .none) return real;
        return client.mutant.interface();
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
    for (0..client.shared.run.ops_per_client) |op_index| {
        _ = arena_state.reset(.retain_capacity);
        const key = pick_key(client.shared, rng, op_index);
        const roll = rng.uintLessThan(u32, 100);
        if (roll < 35) {
            try do_read(client, arena_state.allocator(), key);
        } else if (roll < 65) {
            try do_cas(client, key, client.last_seen[key]);
        } else if (roll < 75) {
            try do_cas(client, key, client.last_seen[key] + wrong_revision_offset);
        } else if (roll < 88) {
            try do_blind(client, key);
        } else {
            try do_delete(client, key);
        }
    }
}

/// A key of the current phase that has calls left (see `hot_keys`).
fn pick_key(shared: *Shared, rng: std.Random, op_index: usize) u8 {
    const base: usize = op_index / phase_ops * hot_keys;
    assert(base + hot_keys <= register_keys);
    const first = rng.uintLessThan(usize, hot_keys);
    for (0..hot_keys) |step| {
        const key: u8 = @intCast(base + (first + step) % hot_keys);
        if (shared.reserve(key)) return key;
    }
    unreachable; // The cap of every key of a phase cannot be spent by one phase's calls.
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

/// Deletes the key if this client last saw it present, at the revision it saw: compare-and-
/// delete. The success branch carries an audit put too, so that a delete whose answer is lost
/// can be found in the log by the token (a delete event has no value of its own). Otherwise
/// it is a compare-and-set, since a delete of an absent key makes no revision.
fn do_delete(client: *Client, key: u8) !void {
    const expected = client.last_seen[key];
    if (expected == 0) return do_cas(client, key, expected);
    const shared = client.shared;
    const audit: u8 = @intCast(history.audit_key_min + client.id);
    const success: [2]history.Put = .{
        .{ .key = key, .value = 0, .delete = true },
        .{ .key = audit, .value = shared.token() },
    };
    const failure: [1]history.Put = .{.{ .key = audit, .value = shared.token() }};
    const txn: history.Txn = .{
        .compare = .{ .key = key, .mod_revision = expected },
        .success = &success,
        .failure = &failure,
    };
    if (try do_txn(client, txn)) |result| {
        if (result.succeeded) client.last_seen[key] = 0;
    }
}

/// Makes the call and records it; null if it did not return an answer.
fn do_txn(client: *Client, txn: history.Txn) !?history.TxnAck {
    const shared = client.shared;
    const handle = try client.recorder.invoke(&shared.ticker, .{ .txn = txn });
    var texts: [4]struct { key: [8]u8, value: [24]u8 } = undefined;
    var success_ops: [2]store.Op = undefined;
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
        // Only a connection that dropped while committing may have written; a drop before the
        // COMMIT (ZC-E0213 as well) certainly changed nothing.
        const lost = pq.dropped_during_commit(&client.diag);
        client.diag.reset();
        if (lost) client.recorder.unknown(handle) else client.recorder.fail(&shared.ticker, handle);
        return null;
    };
    const ack: history.TxnAck = .{ .succeeded = result.succeeded, .revision = result.revision };
    client.recorder.ack_txn(&shared.ticker, handle, ack);
    return ack;
}

fn op_of(key_buffer: *[8]u8, value_buffer: *[24]u8, put: history.Put) store.Op {
    if (put.delete) return .{ .delete = history.key_text(key_buffer, put.key) };
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
    var armed_commit = false;
    switch (rng.uintLessThan(u32, 10)) {
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
        // The lost acknowledgement: the COMMIT is applied and its reply never arrives. Left
        // armed (no heal) until a COMMIT reply passes, so it is seldom wasted.
        7, 8 => {
            proxy.cut_on_commit_reply();
            armed_commit = true;
        },
        else => {},
    }
    if (!armed_commit and rng.uintLessThan(u32, 3) != 0) proxy.heal();
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
        .compacted => {}, // Only a historical read is refused so; stage 1 has none.
    };
    return total;
}

/// Off in the runner's own test: a passing test prints nothing (the build runner reports any
/// stderr of a passing step as a failure). Set before the threads start, never while they run.
var say_enabled = true;

fn say(comptime format: []const u8, args: anytype) void {
    if (!say_enabled) return;
    std.debug.print("store-faults: " ++ format ++ "\n", args);
}

/// Prints a failed store call as the diagnostic it raised, after `what` was being done.
fn say_failure(what: []const u8, diag: *const Diag) void {
    assert(what.len > 0);
    var diagnostic: diag_mod.Diagnostic = undefined;
    if (diag.code == null) return say("{s}", .{what});
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .text, false, &buffer);
    say("{s}:\n{s}", .{ what, text });
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
        } else if (std.mem.eql(u8, name, "--mutate")) {
            options.mutation = std.meta.stringToEnum(Mutation, value) orelse return null;
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
        say("usage: store_faults --backend postgres|sqlite [--postgres SETTINGS] [--seed N]" ++
            " [--mutate drop_ack|stale_read|reuse_revision|all_unknown|keep_delete|" ++
            "ignore_compact|over_compact|stale_history]", .{});
        return exit_user;
    };
    var seed_bytes: [8]u8 = undefined;
    init.io.random(&seed_bytes);
    const seed = options.seed orelse std.mem.readInt(u64, &seed_bytes, .little);
    say("backend={s} seed={d} (replay: -Dseed={d})", .{ @tagName(options.backend), seed, seed });
    if (options.backend == .sqlite) {
        say("sqlite: no proxy applies; history checker only, no faults", .{});
    }
    const report = execute(init.gpa, init.io, options, seed) catch |err| {
        say("ERROR {s} seed={d}", .{ @errorName(err), seed });
        return 1;
    };
    if (!report.passed) say("FAIL seed={d} (replay: -Dseed={d})", .{ seed, seed });
    return if (report.passed) 0 else 1;
}

/// How a run ended. `kind` is the checker's verdict when it was the checker that failed it.
const Stopped = enum { uncovered, bad_value, client };

const Report = struct {
    passed: bool,
    kind: ?history.Kind = null,
    /// Why a run failed when it was not the checker's verdict.
    stopped: ?Stopped = null,
    /// Writes whose outcome was unknown, split by what the log says: in it, or absent.
    unknown_applied: u32 = 0,
    unknown_absent: u32 = 0,
    /// Writes whose call failed with a certainty that nothing was written.
    failed_writes: u32 = 0,
    /// Deletes the store acknowledged as made.
    deletes: u32 = 0,
};

fn execute(gpa: Allocator, io: std.Io, options: Options, seed: u64) !Report {
    var schema_buffer: [32]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buffer, "zf_{x:0>16}", .{seed});
    var path_buffer: [96]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/store-faults-{d}", .{seed});
    var file_buffer: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/s.db", .{directory});
    var real: RealClock = .{ .io = io };
    const run: Run = .{
        .gpa = gpa,
        .io = io,
        .mutation = options.mutation,
        .ops_per_client = options.ops_per_client,
        .backend = options.backend,
        .seed = seed,
        .schema = schema,
        .sqlite_path = file,
        .clock = real.clock(),
    };
    if (options.backend == .sqlite) {
        // A directory left by an earlier run of this seed (one that was killed) goes first.
        std.Io.Dir.cwd().deleteTree(io, directory) catch {}; // Best effort: it is scratch.
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }
    defer if (options.backend == .sqlite) {
        std.Io.Dir.cwd().deleteTree(io, directory) catch {}; // Best effort: it is scratch.
    };
    return try drive(&run, options);
}

fn drive(run: *const Run, options: Options) !Report {
    const gpa = run.gpa;
    var shared: Shared = .{ .run = run };
    const diag = try gpa.create(Diag);
    defer gpa.destroy(diag);
    diag.reset();
    // The direct connection: never through the proxy. It creates the store and drops it. A
    // schema left by an earlier run of this seed goes first, and before the store is opened: a
    // half-made one would make the open fail (ZC-E0209) and the drop would never run.
    if (run.backend == .postgres) {
        drop_leftover_schema(run, options.postgres, diag) catch |err| {
            say_failure("cannot drop a left-over schema", diag);
            return err;
        };
    }
    const direct = try gpa.create(Conn);
    defer gpa.destroy(direct);
    direct.open(&shared, options.postgres, diag) catch |err| {
        say_failure("cannot open the store", diag);
        return err;
    };
    // Every path from here closes `direct`, and drops the schema it made.
    defer {
        if (run.backend == .postgres) direct.postgres.drop_schema(diag) catch {}; // Scratch.
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
        .direct_conninfo = options.postgres,
    });
}

/// Drops the schema of this run's seed over a plain connection, so that it works whatever
/// state the schema is in.
fn drop_leftover_schema(run: *const Run, conninfo: []const u8, diag: *Diag) !void {
    assert(run.backend == .postgres);
    assert(run.schema.len > 0);
    var conninfo_buffer: [512]u8 = undefined;
    const settings = std.fmt.bufPrintSentinel(&conninfo_buffer, "{s}", .{conninfo}, 0) catch {
        return error.ConninfoTooLong;
    };
    const conn = try pq.connect(diag, settings, "SELECT 1");
    defer pq.close(conn);
    var sql_buffer: [128]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(
        &sql_buffer,
        "DROP SCHEMA IF EXISTS \"{s}\" CASCADE",
        .{run.schema},
        0,
    );
    var result = try pq.exec_simple(diag, conn, sql, .{});
    result.clear();
}

const Setup = struct {
    /// The settings of a connection that does not go through the proxy.
    direct_conninfo: []const u8,
    direct: Store,
    diag: *Diag,
    base: u64,
    proxy: ?*fault_proxy.Proxy,
    conninfo: []const u8,
};

fn run_and_check(shared: *Shared, setup: Setup) !Report {
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
            .mutant = undefined,
            .diag = undefined,
            .rng = .init(run.seed ^ (0x9e3779b97f4a7c15 *% (index + 1))),
            .last_seen = @splat(0),
            .failure = null,
        };
        client.diag.reset();
        try client.conn.open(shared, setup.conninfo, &client.diag);
        opened += 1;
        if (run.mutation != .none) {
            client.mutant = Mutant.init(client.conn.interface(run.backend), run.mutation);
        }
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

fn play(shared: *Shared, setup: Setup, clients: []Client, watcher: *Watcher) !Report {
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
    if (setup.proxy != null) try wait_quiet(shared, setup);
    const final = (try setup.direct.status(setup.diag)).revision;
    shared.watch_final.store(final, .release);
    shared.watch_stop.store(true, .release);
    watch_thread.join();
    for (clients) |client| if (client.failure) |err| return fail_client(err);
    if (watcher.failure) |err| return fail_client(err);
    var log = try read_log(gpa, setup.direct, setup.base + 1, final, setup.diag);
    defer log.deinit(gpa);
    const finished: Finished = .{ .log = log.items, .final = final };
    var report = try verdict(shared, setup, clients, watcher, finished);
    if (!report.passed) return report;
    const stage = try compaction_stage(shared, setup, finished);
    if (stage.failure) |err| {
        say("FAILED: a historical read returned bytes that are not a value the runner wrote " ++
            "({s}): the store corrupted a value", .{@errorName(err)});
        return .{ .passed = false, .stopped = .bad_value };
    }
    if (stage.verdict != .ok) {
        say("compaction: {any}", .{stage.verdict});
        report.passed = false;
        report.kind = stage.verdict.failed.kind;
    } else if (!stage.counts.covered()) {
        const counts = stage.counts;
        say("FAILED: the compaction stage lacked coverage (served={d} refused={d} " ++
            "compactions={d}): it needs a served read, a refused read and an acknowledged " ++
            "compaction", .{ counts.served, counts.refused, counts.compactions });
        report.passed = false;
        report.stopped = .uncovered;
    } else {
        say("PASS", .{});
    }
    return report;
}

// ---- Stage 2: historical reads and compaction ---------------------------------------------------

const readers_count = 3;
const reader_ops = 60;
const compact_percent = 15;

/// A client of the second stage: it reads keys as they were at some revision and compacts. The
/// stage runs after the log was read (a compacted log cannot be read back), under the same
/// fault schedule, and its history is judged against that log by `history.check_compaction`.
const Reader = struct {
    shared: *Shared,
    recorder: history.Recorder,
    conn: Conn,
    mutant: Mutant,
    diag: Diag,
    rng: std.Random.DefaultPrng,
    base: u64,
    final: u64,
    failure: ?anyerror = null,

    fn s(reader: *Reader) Store {
        const real = reader.conn.interface(reader.shared.run.backend);
        if (reader.shared.run.mutation == .none) return real;
        return reader.mutant.interface();
    }
};

fn reader_main(reader: *Reader) void {
    var arena_state = std.heap.ArenaAllocator.init(reader.shared.run.gpa);
    defer arena_state.deinit();
    const rng = reader.rng.random();
    for (0..reader_ops) |_| {
        _ = arena_state.reset(.retain_capacity);
        const span = reader.final - reader.base;
        if (rng.uintLessThan(u32, 100) < compact_percent) {
            // Low in the range, so that most of it stays readable.
            const to = reader.base + 1 + rng.uintAtMost(u64, span / 2);
            compact_call(reader, to);
        } else {
            const key = rng.uintLessThan(u8, register_keys);
            const revision = reader.base + 1 + rng.uintLessThan(u64, span);
            read_at(reader, arena_state.allocator(), key, revision) catch |err| {
                reader.failure = err;
                break;
            };
        }
    }
    _ = reader.shared.clients_left.fetchSub(1, .acq_rel);
}

fn compact_call(reader: *Reader, revision: u64) void {
    const shared = reader.shared;
    const handle = reader.recorder.invoke(&shared.ticker, .{ .compact = revision }) catch return;
    reader.s().compact(revision, &reader.diag) catch {
        reader.diag.reset();
        reader.recorder.unknown(handle); // It may have been applied.
        return;
    };
    reader.recorder.ack_done(&shared.ticker, handle, .acked);
}

fn read_at(reader: *Reader, arena: Allocator, key: u8, revision: u64) !void {
    const shared = reader.shared;
    const call: history.Call = .{ .read_at = .{ .key = key, .revision = revision } };
    const handle = reader.recorder.invoke(&shared.ticker, call) catch return;
    var key_buffer: [8]u8 = undefined;
    const name = history.key_text(&key_buffer, key);
    const found = reader.s().get(arena, name, revision, &reader.diag) catch |err| {
        reader.diag.reset();
        if (err == error.Compacted) {
            reader.recorder.ack_done(&shared.ticker, handle, .compacted);
        } else {
            reader.recorder.fail(&shared.ticker, handle);
        }
        return;
    };
    var ack: history.ReadAck = .{ .mod_revision = 0, .value = 0 };
    if (found.kv) |kv| {
        // Every value under /h/ is the runner's: bytes that are not a token are a store bug.
        const value = history.parse_value(kv.value) orelse {
            reader.recorder.fail(&shared.ticker, handle);
            return error.BadValue;
        };
        ack = .{ .mod_revision = kv.mod_revision, .value = value };
    }
    reader.recorder.ack_read(&shared.ticker, handle, ack);
}

const Stage = struct {
    verdict: history.Verdict,
    /// Some read was served, some refused, and some compaction was acknowledged.
    counts: StageCounts,
    /// A reader stopped on an error (a value that is not a token).
    failure: ?anyerror,
};

const StageCounts = struct {
    served: u32 = 0,
    refused: u32 = 0,
    compactions: u32 = 0,

    fn covered(counts: StageCounts) bool {
        return counts.served > 0 and counts.refused > 0 and counts.compactions > 0;
    }
};

fn stage_counts(entries: []const history.Entry) StageCounts {
    var counts: StageCounts = .{};
    for (entries) |entry| switch (entry.call) {
        .read_at => {
            if (entry.outcome == .acked) counts.served += 1;
            if (entry.outcome == .compacted) counts.refused += 1;
        },
        .compact => if (entry.outcome == .acked) {
            counts.compactions += 1;
        },
        else => {},
    };
    return counts;
}

fn compaction_stage(shared: *Shared, setup: Setup, finished: Finished) !Stage {
    const run = shared.run;
    const gpa = run.gpa;
    assert(finished.final > setup.base);
    var readers: [readers_count]Reader = undefined;
    var opened: usize = 0;
    defer for (readers[0..opened]) |*reader| {
        reader.recorder.deinit();
        reader.conn.close(run.backend);
    };
    for (&readers, 0..) |*reader, index| {
        reader.* = .{
            .shared = shared,
            .recorder = history.Recorder.init(gpa, @intCast(index)),
            .conn = undefined,
            .mutant = undefined,
            .diag = undefined,
            .rng = .init(run.seed ^ (0xd1b54a32d192ed03 *% (index + 1))),
            .base = setup.base,
            .final = finished.final,
        };
        reader.diag.reset();
        try reader.conn.open(shared, setup.conninfo, &reader.diag);
        opened += 1;
        if (run.mutation != .none) {
            reader.mutant = Mutant.init(reader.conn.interface(run.backend), run.mutation);
        }
    }
    shared.clients_left.store(readers_count, .release);
    var threads: [readers_count]std.Thread = undefined;
    for (&readers, 0..) |*reader, index| {
        threads[index] = try std.Thread.spawn(.{}, reader_main, .{reader});
    }
    var schedule = std.Random.DefaultPrng.init(run.seed ^ 0x2545f4914f6cdd1d);
    while (shared.clients_left.load(.acquire) != 0) {
        if (setup.proxy) |proxy| {
            fault_step(proxy, schedule.random(), run.io);
        } else {
            nap(run.io, 20);
        }
    }
    for (threads) |thread| thread.join();
    if (setup.proxy) |proxy| proxy.heal();
    var recorders: [readers_count]*const history.Recorder = undefined;
    for (&readers, 0..) |*reader, index| recorders[index] = &reader.recorder;
    const entries = try history.merge(gpa, &recorders);
    defer gpa.free(entries);
    const options: history.Options = .{
        .base_revision = setup.base,
        .final_revision = finished.final,
    };
    const checked = history.check_compaction(entries, finished.log, options);
    const counts = stage_counts(entries);
    say("compaction stage: reads served={d} refused={d} compactions={d}", .{
        counts.served, counts.refused, counts.compactions,
    });
    var failure: ?anyerror = null;
    for (readers) |reader| failure = failure orelse reader.failure;
    return .{ .verdict = checked, .counts = counts, .failure = failure };
}

fn fail_client(err: anyerror) Report {
    say("a client thread stopped: {s}", .{@errorName(err)});
    return .{ .passed = false, .stopped = .client };
}

/// Waits until no store backend is still working on a statement. A COMMIT that the proxy held
/// back, or that a backend was part-way through when its client was cut, can finish after the
/// last client returned; the log must be read after it, or the final revision would be one too
/// low and the checker would report a gap that is not there. Quiet means `quiet_samples`
/// readings in a row with nothing running; it gives up after `quiet_polls_max` readings (other
/// users of the database can keep it busy) and says so.
fn wait_quiet(shared: *Shared, setup: Setup) !void {
    const run = shared.run;
    var text: [512]u8 = undefined;
    const conninfo = std.fmt.bufPrintSentinel(&text, "{s}", .{setup.direct_conninfo}, 0) catch {
        return error.ConninfoTooLong;
    };
    const conn = try pq.connect(setup.diag, conninfo, "SELECT 1");
    defer pq.close(conn);
    var quiet: u32 = 0;
    for (0..quiet_polls_max) |_| {
        nap(run.io, quiet_poll_ms);
        var result = try pq.exec_simple(setup.diag, conn, busy_sql, .{});
        defer result.clear();
        assert(result.rows() == 1);
        const busy = std.fmt.parseInt(u32, result.bytes(0, 0), 10) catch return error.BadCount;
        quiet = if (busy == 0) quiet + 1 else 0;
        if (quiet == quiet_samples) return;
    }
    say("warning: store backends were still busy after the run; the log may be short", .{});
}

/// Statements of the store's own connections that are not idle (this poll excepted).
const busy_sql: [:0]const u8 =
    "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'zcube-store' " ++
    "AND datname = current_database() AND pid <> pg_backend_pid() " ++
    "AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')";

const Finished = struct {
    log: []const history.LogEvent,
    final: u64,
};

/// Splits the writes of unknown outcome by what the log says: some branch in it, or none.
fn split_unknowns(
    gpa: Allocator,
    entries: []const history.Entry,
    log: []const history.LogEvent,
) !Report {
    var present: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer present.deinit(gpa);
    for (log) |event| {
        if (event.kind == .put) try present.put(gpa, event.value, {});
    }
    var report: Report = .{ .passed = true };
    for (entries) |entry| {
        if (entry.call == .txn and entry.outcome == .failed) report.failed_writes += 1;
        if (entry.call == .txn and entry.outcome == .acked and entry.succeeded) {
            for (entry.call.txn.success) |put| {
                if (put.delete) report.deletes += 1;
            }
        }
        if (entry.outcome != .unknown) continue;
        if (entry.call != .txn) continue;
        var found = false;
        for ([_][]const history.Put{ entry.call.txn.success, entry.call.txn.failure }) |puts| {
            for (puts) |put| found = found or present.contains(put.value);
        }
        if (found) report.unknown_applied += 1 else report.unknown_absent += 1;
    }
    return report;
}

/// A faulted run must have met both outcomes of a lost connection, or it has not tested them.
fn covered_both_cases(setup: Setup, report: *const Report) bool {
    if (report.deletes == 0) {
        say("FAILED: no delete was acknowledged: deletes were never exercised", .{});
        return false;
    }
    if (setup.proxy == null) {
        assert(report.unknown_applied == 0); // Without faults no write is ever left unknown.
        return true;
    }
    if (report.unknown_applied == 0) {
        // The point of the cuts at COMMIT replies is a write that was made and never
        // acknowledged. A run that never met one has not tested that case.
        say("FAILED: no unknown write was found in the log: the lost acknowledgement " ++
            "(commit made, reply cut) was never exercised", .{});
        return false;
    }
    if (report.failed_writes == 0) {
        // A drop before the COMMIT certainly wrote nothing and is recorded as failed. A run
        // with none took every store error for a lost acknowledgement (`all_unknown`).
        say("FAILED: no write was recorded as failed: every store error was taken to be a " ++
            "lost acknowledgement, which hides a lost write", .{});
        return false;
    }
    return true;
}

fn verdict(
    shared: *Shared,
    setup: Setup,
    clients: []Client,
    watcher: *const Watcher,
    finished: Finished,
) !Report {
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
    var report = try split_unknowns(gpa, entries, finished.log);
    assert(report.unknown_applied + report.unknown_absent == total.unknown);
    say("calls={d} acked={d} failed={d} unknown={d} (applied={d} absent={d}) log_events={d} " ++
        "revision={d} watch_opens={d}", .{
        entries.len,      total.ok,               total.failed,
        total.unknown,    report.unknown_applied, report.unknown_absent,
        finished.log.len, finished.final,         watcher.opens,
    });
    if (setup.proxy) |proxy| {
        const stats = proxy.stats();
        say("proxy: accepted={d} upstream_connects={d} cuts={d} commit_cuts={d}", .{
            stats.accepted, stats.upstream_connects, stats.cuts, stats.commit_cuts,
        });
        if (stats.accepted == 0) return error.ProxyUnused;
    }
    const checked = try history.check(gpa, entries, finished.log, options);
    if (checked != .ok) {
        say("history: {any}", .{checked});
        report.passed = false;
        report.kind = checked.failed.kind;
        return report;
    }
    const record: history.WatchRecord = .{
        .from_revision = watcher.from_revision,
        .bookmark = watcher.bookmark,
        .events = watcher.events.items,
    };
    const watched = history.check_watch(finished.log, record, options);
    if (watched != .ok) {
        say("watch: {any}", .{watched});
        report.passed = false;
        report.kind = watched.failed.kind;
        return report;
    }
    if (!covered_both_cases(setup, &report)) {
        report.passed = false;
        report.stopped = .uncovered;
        return report;
    }
    return report;
}

// ---- The runner's own test ----------------------------------------------------------------------

fn mutated_report(mutation: Mutation, seed: u64) !Report {
    const options: Options = .{
        .backend = .sqlite,
        .postgres = "",
        .seed = seed,
        .mutation = mutation,
    };
    return execute(std.testing.allocator, std.testing.io, options, seed);
}

test "the runner passes an honest store and rejects each kind of lie with its own verdict" {
    // Goal: prove the runner can fail. A checker that has never rejected a real run might be
    // checking nothing, so each `Mutation` makes the clients' store lie in one way and the run
    // must end with the verdict that lie earns. Method: the SQLite backend (no database to
    // start), the full run, a fixed seed. Threads interleave as the machine likes, so a lie
    // that needs a coincidence to show (a stale read needs a write in between) gets three
    // seeds; the other two are certain on the first.
    say_enabled = false;
    defer say_enabled = true;
    const honest = try mutated_report(.none, 7);
    try std.testing.expect(honest.passed);
    try std.testing.expectEqual(@as(?history.Kind, null), honest.kind);
    const cases = [_]struct { mutation: Mutation, kind: history.Kind }{
        .{ .mutation = .drop_ack, .kind = .lost_write },
        .{ .mutation = .stale_read, .kind = .not_linearizable },
        .{ .mutation = .reuse_revision, .kind = .revision_reused },
        .{ .mutation = .keep_delete, .kind = .event_mismatch },
        .{ .mutation = .ignore_compact, .kind = .compacted_read_served },
        .{ .mutation = .over_compact, .kind = .read_above_compaction_failed },
        .{ .mutation = .stale_history, .kind = .read_at_wrong },
    };
    for (cases) |case| {
        var caught = false;
        for (0..3) |attempt| {
            const report = try mutated_report(case.mutation, 100 + attempt);
            if (report.passed) continue; // The lie did not show this time: try another seed.
            try std.testing.expectEqual(@as(?history.Kind, case.kind), report.kind);
            caught = true;
            break;
        }
        try std.testing.expect(caught);
    }
}
