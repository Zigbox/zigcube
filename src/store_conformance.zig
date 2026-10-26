//! The store conformance suite: `zig build test-store -Dbackend=memory|sqlite [-Dseed=N]`.
//!
//! One suite, written against the `Store` interface only, that every backend must pass. It
//! covers what HANDOFF.md lists: compare-and-swap races between writers on separate connections,
//! watch ordering and no gaps under concurrent writers, watch resume after reconnect,
//! compaction errors for reads and for watches, a lease's expiry deleting its keys under one
//! revision, and a put that names a dead lease changing nothing. Details of the rules are in
//! `store.zig`; this file is the check that a backend keeps them.
//!
//! ## Determinism (docs/STYLE.md, "Where Zigcube departs")
//!
//! Every random choice comes from one seed. It is printed at the start of each test, and
//! `-Dseed=N` replays it. Where real threads race, the interleaving is up to the machine, so
//! those tests assert the invariants that must hold for every interleaving (no gap, no
//! duplicate, revision order equals commit order, every event delivered once and in order),
//! never one particular interleaving. `std.Thread` is allowed here and inside a backend; time
//! comes from a `ManualClock`, so lease tests never sleep.
//!
//! ## Connections
//!
//! `Harness.connect` gives a test a `Store`. For SQLite each is a separate connection to one
//! file, which is what the server's writers and the CLI's readers look like. For Postgres each
//! is a `PostgresStore` (its own pool of connections) on one schema, created fresh for the test
//! in the database named by `ZCUBE_TEST_POSTGRES` and dropped when it ends; lease time comes from
//! the injected clock, so the same lease tests run, without sleeping, on every backend. The
//! memory store is a single-threaded reference, so its connections share one instance behind a
//! mutex (`Serialized`); that proves the contract, not the memory store's own locking.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const suite = @import("conformance_options");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const Diag = @import("diag.zig").Diag;
const ManualClock = @import("clock.zig").ManualClock;
const store = @import("store.zig");
const MemoryStore = @import("store_memory.zig").MemoryStore;
const SqliteStore = @import("store_sqlite.zig").SqliteStore;
const OpenOptions = @import("store_sqlite.zig").OpenOptions;
const postgres = @import("store_postgres.zig");
const PostgresStore = postgres.PostgresStore;

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const Store = store.Store;

const backend = suite.backend;

// ---- Bounds of the suite (every loop and buffer has a named limit) ------------------------------

const connections_max = 16;
const writers_count = 4;
const rounds_per_writer = 40;
const counter_increments = 25;
const retries_max = 100_000;
const watch_polls_max = 100_000;
const watch_wait_ms = 20;
const model_steps = 400;
const model_events_max = model_steps * 3;
const key_bytes = 32;

// ---- Harness ---------------------------------------------------------------------------------

const Harness = struct {
    gpa: Allocator,
    manual: ManualClock,
    seed: u64,
    memory: if (backend == .memory) MemoryStore else void,
    memory_mutex: std.Io.Mutex,
    tmp: if (backend == .sqlite) testing.TmpDir else void,
    path_buffer: [160]u8,
    path_len: u32,
    pg_conninfo: if (backend == .postgres) [:0]const u8 else void,
    pg_schema: if (backend == .postgres) [32]u8 else void,
    pg_schema_len: u32,
    connections: [connections_max]?*Connection,

    fn start() !*Harness {
        const harness = try testing.allocator.create(Harness);
        harness.* = .{
            .gpa = testing.allocator,
            .manual = .{},
            .seed = pick_seed(),
            .memory = undefined,
            .memory_mutex = .init,
            .tmp = undefined,
            .path_buffer = undefined,
            .path_len = 0,
            .pg_conninfo = undefined,
            .pg_schema = undefined,
            .pg_schema_len = 0,
            .connections = @splat(null),
        };
        switch (backend) {
            .memory => harness.memory.init(harness.gpa, harness.manual.clock()),
            .sqlite => {
                harness.tmp = testing.tmpDir(.{});
                const format = ".zig-cache/tmp/{s}/s.db";
                const sub_path = harness.tmp.sub_path;
                const buffer = &harness.path_buffer;
                const text = try std.fmt.bufPrintSentinel(buffer, format, .{sub_path}, 0);
                harness.path_len = @intCast(text.len);
            },
            .postgres => try harness.start_postgres(),
        }
        return harness;
    }

    fn stop(harness: *Harness) void {
        for (&harness.connections) |*slot| {
            if (slot.*) |conn| {
                conn.close(harness);
                slot.* = null;
            }
        }
        switch (backend) {
            .memory => harness.memory.deinit(),
            .sqlite => harness.tmp.cleanup(),
            .postgres => harness.drop_postgres_schema(),
        }
        testing.allocator.destroy(harness);
    }

    /// One seed per run, shared by every test: `-Dseed=N` if given, else the seed Zig's build
    /// runner draws for the run and passes to the test binary (`zig build --seed 0xN` replays
    /// it). Nothing is printed while tests pass, because the build runner reports any stderr of
    /// a passing step as a failure; a failing test prints it (`report_seed`).
    fn pick_seed() u64 {
        return suite.seed orelse testing.random_seed;
    }

    fn report_seed(harness: *const Harness) void {
        const banner = "store conformance: backend={s} seed={d} (replay: -Dseed={d})\n";
        std.debug.print(banner, .{ @tagName(backend), harness.seed, harness.seed });
    }

    /// A random generator for one test: the seed, mixed with a name so tests differ.
    fn prng(harness: *const Harness, comptime name: []const u8) std.Random.DefaultPrng {
        return .init(harness.seed ^ std.hash.Wyhash.hash(0, name));
    }

    /// Names the database from the environment and a schema no other run shares.
    fn start_postgres(harness: *Harness) !void {
        const conninfo = testing.environ.getPosix("ZCUBE_TEST_POSTGRES") orelse {
            std.debug.print("ZCUBE_TEST_POSTGRES names no database (see AGENTS.md)\n", .{});
            return error.PostgresNotConfigured;
        };
        harness.pg_conninfo = conninfo;
        const now = std.Io.Clock.real.now(testing.io).toNanoseconds();
        const unique = std.hash.Wyhash.hash(harness.seed, std.mem.asBytes(&now));
        const text = try std.fmt.bufPrint(&harness.pg_schema, "zt_{x:0>16}", .{unique});
        harness.pg_schema_len = @intCast(text.len);
    }

    fn schema_name(harness: *const Harness) []const u8 {
        assert(backend == .postgres);
        return harness.pg_schema[0..harness.pg_schema_len];
    }

    fn pg_options(harness: *Harness) postgres.OpenOptions {
        return .{
            .conninfo = harness.pg_conninfo,
            .schema = harness.schema_name(),
            .create = true,
            .lease_time = .{ .clock = harness.manual.clock() },
        };
    }

    /// Removes the test's schema, through a store of its own.
    fn drop_postgres_schema(harness: *Harness) void {
        var diag: Diag = undefined;
        diag.reset();
        const dropper = testing.allocator.create(PostgresStore) catch return;
        defer testing.allocator.destroy(dropper);
        dropper.open(testing.io, harness.pg_options(), &diag) catch return;
        defer dropper.close();
        dropper.drop_schema(&diag) catch {};
    }

    fn file_path(harness: *const Harness) []const u8 {
        assert(backend == .sqlite);
        return harness.path_buffer[0..harness.path_len];
    }

    /// A new connection to the same logical store.
    fn connect(harness: *Harness) !*Connection {
        var diag: Diag = undefined;
        diag.reset();
        const conn = try harness.gpa.create(Connection);
        errdefer harness.gpa.destroy(conn);
        switch (backend) {
            .memory => conn.serialized = .{
                .inner = harness.memory.interface(),
                .mutex = &harness.memory_mutex,
                .gpa = harness.gpa,
            },
            .sqlite => {
                const clock = harness.manual.clock();
                const open_options: OpenOptions = .{ .create = true, .sync = .normal };
                try conn.sqlite.open(testing.io, clock, harness.file_path(), open_options, &diag);
            },
            .postgres => try conn.postgres.open(testing.io, harness.pg_options(), &diag),
        }
        for (&harness.connections) |*slot| {
            if (slot.* != null) continue;
            slot.* = conn;
            return conn;
        }
        return error.TooManyConnections;
    }
};

const Connection = struct {
    sqlite: if (backend == .sqlite) SqliteStore else void,
    serialized: if (backend == .memory) Serialized else void,
    postgres: if (backend == .postgres) PostgresStore else void,

    fn interface(conn: *Connection) Store {
        return switch (backend) {
            .memory => conn.serialized.interface(),
            .sqlite => conn.sqlite.interface(),
            .postgres => conn.postgres.interface(),
        };
    }

    fn close(conn: *Connection, harness: *Harness) void {
        if (backend == .sqlite) conn.sqlite.close();
        if (backend == .postgres) conn.postgres.close();
        harness.gpa.destroy(conn);
    }
};

/// Puts a mutex around every call of another `Store`, so threads can share the memory store.
const Serialized = struct {
    inner: Store,
    mutex: *std.Io.Mutex,
    gpa: Allocator,

    const vtable: Store.VTable = .{
        .status = status,
        .get = get,
        .list = list,
        .txn = txn,
        .watch = watch,
        .lease_grant = lease_grant,
        .lease_keepalive = lease_keepalive,
        .lease_revoke = lease_revoke,
        .expire_leases = expire_leases,
        .compact = compact,
    };

    const watch_vtable: store.Watch.WatchVTable = .{ .next = watch_next, .close = watch_close };

    const Box = struct { inner: store.Watch, owner: *Serialized };

    fn interface(self: *Serialized) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *Serialized {
        return @ptrCast(@alignCast(context));
    }

    fn enter(self: *Serialized) void {
        self.mutex.lockUncancelable(testing.io);
    }

    fn leave(self: *Serialized) void {
        self.mutex.unlock(testing.io);
    }

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.status(diag);
    }

    fn get(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.get(arena, key, at_revision, diag);
    }

    fn list(
        context: *anyopaque,
        arena: Allocator,
        list_options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.list(arena, list_options, diag);
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.txn(request, diag);
    }

    fn watch(
        context: *anyopaque,
        watch_options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        const self = from(context);
        self.enter();
        defer self.leave();
        const box = self.gpa.create(Box) catch return error.NoCapacity;
        errdefer self.gpa.destroy(box); // The inner watch failed: nothing owns the box.
        box.* = .{ .inner = try self.inner.watch(watch_options, diag), .owner = self };
        return .{ .context = box, .vtable = &watch_vtable, .delivered = box.inner.delivered };
    }

    fn watch_next(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) store.Error!store.WatchBatch {
        const box: *Box = @ptrCast(@alignCast(context));
        box.owner.enter();
        defer box.owner.leave();
        return box.inner.next(arena, timeout_ms, diag);
    }

    fn watch_close(context: *anyopaque) void {
        const box: *Box = @ptrCast(@alignCast(context));
        const owner = box.owner; // The box is freed below, before `leave` runs.
        owner.enter();
        defer owner.leave();
        box.inner.close();
        owner.gpa.destroy(box);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.lease_grant(ttl_ms, diag);
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.lease_keepalive(id, diag);
    }

    fn lease_revoke(context: *anyopaque, id: store.LeaseId, diag: *Diag) store.Error!Revision {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.lease_revoke(id, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) store.Error!u32 {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.expire_leases(diag);
    }

    fn compact(context: *anyopaque, revision: Revision, diag: *Diag) store.Error!void {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.compact(revision, diag);
    }
};

// ---- Helpers ---------------------------------------------------------------------------------

fn put_one(s: Store, diag: *Diag, key: []const u8, value: []const u8) !Revision {
    const op: store.Op = .{ .put = .{ .key = key, .value = value } };
    const result = try s.txn(.{ .on_success = &.{op} }, diag);
    try testing.expect(result.succeeded);
    return result.revision;
}

fn delete_one(s: Store, diag: *Diag, key: []const u8) !Revision {
    const op: store.Op = .{ .delete = key };
    const result = try s.txn(.{ .on_success = &.{op} }, diag);
    return result.revision;
}

/// Checks that a call failed with `expected`, left diagnostic `code`, and clears the diagnostic.
fn expect_failure(diag: *Diag, expected: store.Error, actual: anytype, code: codes.Code) !void {
    try testing.expectError(expected, actual);
    try testing.expectEqual(code, diag.code.?);
    diag.reset();
}

fn expect_status(s: Store, diag: *Diag, revision: Revision, compacted: Revision) !void {
    const status = try s.status(diag);
    try testing.expectEqual(revision, status.revision);
    try testing.expectEqual(compacted, status.compacted_revision);
}

/// Reads `watch` until its bookmark reaches `head` and returns every event it delivered.
fn drain(watch: *store.Watch, arena: Allocator, head: Revision, diag: *Diag) ![]const store.Event {
    var events: std.ArrayList(store.Event) = .empty;
    for (0..watch_polls_max) |_| {
        const batch = try watch.next(arena, 0, diag);
        try events.appendSlice(arena, batch.events);
        if (batch.revision >= head) return events.items;
    }
    return error.WatchDidNotCatchUp;
}

fn start_gate() std.atomic.Value(bool) {
    return .init(false);
}

fn wait_gate(gate: *const std.atomic.Value(bool)) void {
    while (!gate.load(.acquire)) std.atomic.spinLoopHint();
}

/// Spawns one thread per job, opens the gate so they start together, and joins them all.
fn run_jobs(comptime Job: type, jobs: []Job, gate: *std.atomic.Value(bool)) !void {
    var threads: [connections_max]std.Thread = undefined;
    assert(jobs.len <= threads.len);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    errdefer gate.store(true, .release); // Let the threads already started run to the end.
    for (jobs) |*job| {
        threads[spawned] = try std.Thread.spawn(.{}, Job.run, .{job});
        spawned += 1;
    }
    gate.store(true, .release);
}

// ---- Compare-and-swap races --------------------------------------------------------------------

const CreateRace = struct {
    conn: *Connection,
    id: u32,
    gate: *const std.atomic.Value(bool),
    won: bool = false,
    revision: Revision = 0,
    failed: bool = false,

    fn run(job: *CreateRace) void {
        wait_gate(job.gate);
        var diag: Diag = undefined;
        diag.reset();
        var value: [16]u8 = undefined;
        var audit: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&value, "writer-{d}", .{job.id}) catch return;
        const audit_name = std.fmt.bufPrint(&audit, "/c/audit-{d}", .{job.id}) catch return;
        const result = job.conn.interface().txn(.{
            .compares = &.{.{ .key = "/c/key", .mod_revision = 0 }},
            .on_success = &.{.{ .put = .{ .key = "/c/key", .value = text } }},
            .on_failure = &.{.{ .put = .{ .key = audit_name, .value = "lost" } }},
        }, &diag) catch {
            job.failed = true;
            return;
        };
        job.won = result.succeeded;
        job.revision = result.revision;
    }
};

test "cas: of several writers racing to create a key, exactly one wins" {
    // Goal: create-only compare-and-swap is atomic across connections. Method: each writer on its
    // own connection and thread creates "/c/key" if absent, and records an audit key if it
    // lost. Whatever the interleaving, exactly one create succeeds, the key holds the winner's
    // value, and the writers' revisions are exactly 1..n: one per write, no gap, no repeat.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var gate = start_gate();
    var jobs: [writers_count]CreateRace = undefined;
    for (&jobs, 0..) |*job, id| {
        job.* = .{ .conn = try harness.connect(), .id = @intCast(id), .gate = &gate };
    }
    try run_jobs(CreateRace, &jobs, &gate);

    var seen: [writers_count + 1]bool = @splat(false);
    var winners: u32 = 0;
    var winner: *const CreateRace = &jobs[0];
    for (&jobs) |*job| {
        try testing.expect(!job.failed);
        try testing.expect(job.revision >= 1 and job.revision <= writers_count);
        try testing.expect(!seen[job.revision]);
        seen[job.revision] = true;
        if (job.won) {
            winners += 1;
            winner = job;
        }
    }
    try testing.expectEqual(@as(u32, 1), winners);

    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    const got = try s.get(arena_state.allocator(), "/c/key", null, &diag);
    var expected: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, "writer-{d}", .{winner.id});
    try testing.expectEqualStrings(text, got.kv.?.value);
    try testing.expectEqual(winner.revision, got.kv.?.mod_revision);
    try testing.expectEqual(winner.revision, got.kv.?.create_revision);
    try expect_status(s, &diag, writers_count, 0);
}

const Counter = struct {
    conn: *Connection,
    gate: *const std.atomic.Value(bool),
    retries: u32 = 0,
    failed: bool = false,

    fn run(job: *Counter) void {
        wait_gate(job.gate);
        var diag: Diag = undefined;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        for (0..counter_increments) |_| {
            if (!job.increment(&arena_state, &diag)) {
                job.failed = true;
                return;
            }
        }
    }

    /// Read, add one, write back if nobody wrote in between; retry otherwise. True once
    /// committed.
    fn increment(job: *Counter, arena_state: *std.heap.ArenaAllocator, diag: *Diag) bool {
        const s = job.conn.interface();
        for (0..retries_max) |_| {
            diag.reset();
            _ = arena_state.reset(.retain_capacity);
            const got = s.get(arena_state.allocator(), "/n/counter", null, diag) catch return false;
            const kv = got.kv orelse return false;
            const current = std.fmt.parseInt(u32, kv.value, 10) catch return false;
            var text: [12]u8 = undefined;
            const next = std.fmt.bufPrint(&text, "{d}", .{current + 1}) catch return false;
            const result = s.txn(.{
                .compares = &.{.{ .key = "/n/counter", .mod_revision = kv.mod_revision }},
                .on_success = &.{.{ .put = .{ .key = "/n/counter", .value = next } }},
            }, diag) catch return false;
            if (result.succeeded) return true;
            job.retries += 1;
        }
        return false;
    }
};

test "cas: concurrent read-modify-write loses no update and takes one revision each" {
    // Goal: update-if-unchanged is atomic across connections. Method: writers increment one
    // counter through get + compare-and-swap, retrying when they lose. The final value must
    // be the number of increments (no lost update), and because a lost compare writes
    // nothing, the revision must be exactly 1 + the increments (a failed attempt takes none).
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const first = (try harness.connect()).interface();
    _ = try put_one(first, &diag, "/n/counter", "0");

    var gate = start_gate();
    var jobs: [writers_count]Counter = undefined;
    for (&jobs) |*job| job.* = .{ .conn = try harness.connect(), .gate = &gate };
    try run_jobs(Counter, &jobs, &gate);
    for (&jobs) |*job| try testing.expect(!job.failed);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try first.get(arena_state.allocator(), "/n/counter", null, &diag);
    const total: u32 = writers_count * counter_increments;
    var expected: [12]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, "{d}", .{total});
    try testing.expectEqualStrings(text, got.kv.?.value);
    try expect_status(first, &diag, 1 + total, 0);
}

// ---- Watch under concurrent writers -------------------------------------------------------------

const Planned = struct {
    key: [key_bytes]u8,
    key_len: u8,
    kind: store.EventKind,
    /// Under the watched prefix "/w/".
    watched: bool,

    fn slice(planned: *const Planned) []const u8 {
        return planned.key[0..planned.key_len];
    }
};

/// One transaction a writer made: its revision and the events it must have produced, in order.
const Committed = struct {
    revision: Revision = 0,
    count: u8 = 0,
    events: [3]Planned = undefined,

    fn add(plan: *Committed, kind: store.EventKind, key: []const u8) void {
        assert(plan.count < plan.events.len);
        var planned: Planned = .{
            .key = undefined,
            .key_len = @intCast(key.len),
            .kind = kind,
            .watched = std.mem.startsWith(u8, key, "/w/"),
        };
        @memcpy(planned.key[0..key.len], key);
        plan.events[plan.count] = planned;
        plan.count += 1;
    }

    fn add_put(plan: *Committed, comptime format: []const u8, args: anytype) void {
        var buffer: [key_bytes]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, format, args) catch unreachable; // 32 bytes fit.
        plan.add(.put, key);
    }
};

/// Decides what a writer does in `round`: one to three puts, sometimes with a delete of its
/// previous key, sometimes under a prefix nobody watches. `alive` is a key it may delete.
fn plan_round(id: u32, round: u32, random: std.Random, alive: *?Planned) Committed {
    var plan: Committed = .{};
    switch (random.uintLessThan(u32, 10)) {
        0...4 => {
            plan.add_put("/w/{d}/{d:0>3}", .{ id, round });
            alive.* = plan.events[0];
        },
        5, 6 => {
            plan.add_put("/w/{d}/{d:0>3}a", .{ id, round });
            plan.add_put("/w/{d}/{d:0>3}b", .{ id, round });
        },
        7 => {
            plan.add_put("/w/{d}/{d:0>3}", .{ id, round });
            const fresh = plan.events[0];
            if (alive.*) |old| plan.add(.delete, old.slice());
            alive.* = fresh;
        },
        8 => plan.add_put("/other/{d}/{d:0>3}", .{ id, round }),
        else => {
            plan.add_put("/w/{d}/{d:0>3}x", .{ id, round });
            plan.add_put("/other/{d}/{d:0>3}y", .{ id, round });
            plan.add_put("/w/{d}/{d:0>3}z", .{ id, round });
        },
    }
    assert(plan.count > 0);
    return plan;
}

fn commit_round(s: Store, plan: *Committed, diag: *Diag) bool {
    var ops: [3]store.Op = undefined;
    for (plan.events[0..plan.count], 0..) |*event, index| {
        ops[index] = switch (event.kind) {
            .put => .{ .put = .{ .key = event.slice(), .value = event.slice() } },
            .delete => .{ .delete = event.slice() },
        };
    }
    const result = s.txn(.{ .on_success = ops[0..plan.count] }, diag) catch return false;
    if (!result.succeeded) return false;
    plan.revision = result.revision;
    return true;
}

const Writer = struct {
    conn: *Connection,
    id: u32,
    seed: u64,
    gate: *const std.atomic.Value(bool),
    finished: *std.atomic.Value(u32),
    committed: [rounds_per_writer]Committed = undefined,
    rounds: u32 = 0,
    failed: bool = false,

    fn run(job: *Writer) void {
        defer _ = job.finished.fetchAdd(1, .release);
        wait_gate(job.gate);
        var prng: std.Random.DefaultPrng = .init(job.seed);
        var diag: Diag = undefined;
        diag.reset();
        var alive: ?Planned = null;
        for (0..rounds_per_writer) |round| {
            var plan = plan_round(job.id, @intCast(round), prng.random(), &alive);
            if (!commit_round(job.conn.interface(), &plan, &diag)) {
                job.failed = true;
                return;
            }
            job.committed[round] = plan;
            job.rounds += 1;
        }
    }
};

const Seen = struct {
    revision: Revision,
    kind: store.EventKind,
    key: [key_bytes]u8,
    key_len: u8,
};

/// Watches "/w/" from revision 1 while the writers run, checking each batch as it arrives,
/// and returns the head revision once the writers have finished and the watch has caught up.
fn collect_watch(
    s: Store,
    finished: *const std.atomic.Value(u32),
    seen: *std.ArrayList(Seen),
    diag: *Diag,
) !Revision {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var watch = try s.watch(.{ .prefix = "/w/", .from_revision = 1 }, diag);
    defer watch.close();
    var bookmark: Revision = 0;
    var last_event: Revision = 0;
    for (0..watch_polls_max) |_| {
        _ = arena_state.reset(.retain_capacity);
        const batch = try watch.next(arena_state.allocator(), watch_wait_ms, diag);
        try testing.expect(batch.revision >= bookmark);
        for (batch.events) |event| {
            // After the last bookmark, up to this one, and never in two batches: no gap, no repeat.
            try testing.expect(event.kv.mod_revision > bookmark);
            try testing.expect(event.kv.mod_revision <= batch.revision);
            try testing.expect(event.kv.mod_revision >= last_event);
            if (event.kv.mod_revision > last_event) last_event = event.kv.mod_revision;
            var entry: Seen = .{
                .revision = event.kv.mod_revision,
                .kind = event.kind,
                .key = undefined,
                .key_len = @intCast(event.kv.key.len),
            };
            @memcpy(entry.key[0..event.kv.key.len], event.kv.key);
            try seen.append(testing.allocator, entry);
        }
        bookmark = batch.revision;
        if (finished.load(.acquire) != writers_count) continue;
        const head = (try s.status(diag)).revision;
        if (bookmark >= head) return head;
    }
    return error.WatchDidNotCatchUp;
}

/// The writers' transactions indexed by revision; fails on a repeat or a hole.
fn index_by_revision(
    jobs: []const Writer,
    head: Revision,
    by_revision: []?*const Committed,
) !void {
    try testing.expectEqual(@as(usize, @intCast(head + 1)), by_revision.len);
    for (by_revision) |*slot| slot.* = null;
    for (jobs) |*job| {
        var previous: Revision = 0;
        for (job.committed[0..job.rounds]) |*commit| {
            try testing.expect(commit.revision > previous); // A writer's own order is kept.
            previous = commit.revision;
            try testing.expect(commit.revision >= 1 and commit.revision <= head);
            try testing.expect(by_revision[@intCast(commit.revision)] == null); // No repeat.
            by_revision[@intCast(commit.revision)] = commit;
        }
    }
    for (by_revision[1..]) |slot| try testing.expect(slot != null); // No hole.
}

test "watch: concurrent writers produce an ordered, gap-free stream, one batch per revision" {
    // Goal: the watch guarantee under load. Method: writers on separate connections commit
    // random one-to-three-key transactions (puts and deletes, some outside the watched prefix)
    // while this thread watches "/w/" from revision 1. Each writer remembers the revision and
    // events of every commit. Afterwards: the revisions are exactly 1..head (revision order is
    // commit order, none lost, none doubled), each writer's own commits are in order, and the
    // watch delivered precisely the watched events of every revision, in revision order and
    // in transaction order, with no revision split across batches.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var prng = harness.prng("watch-writers");
    var gate = start_gate();
    var finished: std.atomic.Value(u32) = .init(0);
    const jobs = try testing.allocator.alloc(Writer, writers_count);
    defer testing.allocator.free(jobs);
    for (jobs, 0..) |*job, id| {
        job.* = .{
            .conn = try harness.connect(),
            .id = @intCast(id),
            .seed = prng.random().int(u64),
            .gate = &gate,
            .finished = &finished,
        };
    }
    const watcher = (try harness.connect()).interface();
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(testing.allocator);
    var diag: Diag = undefined;
    diag.reset();
    var threads: [writers_count]std.Thread = undefined;
    for (jobs, &threads) |*job, *thread| thread.* = try std.Thread.spawn(.{}, Writer.run, .{job});
    gate.store(true, .release);
    const outcome = collect_watch(watcher, &finished, &seen, &diag);
    for (threads) |thread| thread.join();
    const head = try outcome;

    for (jobs) |job| try testing.expect(!job.failed);
    try testing.expectEqual(@as(Revision, writers_count * rounds_per_writer), head);
    const by_revision = try testing.allocator.alloc(?*const Committed, @intCast(head + 1));
    defer testing.allocator.free(by_revision);
    try index_by_revision(jobs, head, by_revision);
    try expect_stream(by_revision, seen.items);
}

/// The watched events of every revision, in order, must equal what the watch delivered.
fn expect_stream(by_revision: []const ?*const Committed, seen: []const Seen) !void {
    var next: usize = 0;
    for (by_revision[1..], 1..) |slot, revision| {
        for (slot.?.events[0..slot.?.count]) |*planned| {
            if (!planned.watched) continue;
            try testing.expect(next < seen.len);
            const got = seen[next];
            next += 1;
            try testing.expectEqual(@as(Revision, revision), got.revision);
            try testing.expectEqual(planned.kind, got.kind);
            try testing.expectEqualStrings(planned.slice(), got.key[0..got.key_len]);
        }
    }
    try testing.expectEqual(seen.len, next);
}

test "watch: a revision that does not fit the batch is held back whole, never skipped" {
    // Goal: regression for "no gaps" at the batch limit. Method: fill one batch exactly with
    // single-put revisions, then commit a two-event transaction that cannot fit after it. The
    // first batch must stop at the revision before the pair (the bookmark must not jump past
    // what was held back), the second must carry both events of the pair, and together they must
    // deliver every event exactly once, in order.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    var name: [16]u8 = undefined;
    for (0..constants.store_watch_batch_max) |index| {
        const key = try std.fmt.bufPrint(&name, "/w/{d:0>4}", .{index});
        _ = try put_one(s, &diag, key, "v");
    }
    const pair = [_]store.Op{
        .{ .put = .{ .key = "/w/last-a", .value = "a" } },
        .{ .put = .{ .key = "/w/last-b", .value = "b" } },
    };
    const head = (try s.txn(.{ .on_success = &pair }, &diag)).revision;

    var watch = try s.watch(.{ .prefix = "/w/", .from_revision = 1 }, &diag);
    defer watch.close();
    const first = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, constants.store_watch_batch_max), first.events.len);
    try testing.expectEqual(head - 1, first.revision);
    const second = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 2), second.events.len);
    try testing.expectEqual(head, second.events[0].kv.mod_revision);
    try testing.expectEqual(head, second.events[1].kv.mod_revision);
    try testing.expectEqual(head, second.revision);
    const idle = try watch.next(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(head, idle.revision);
}

// ---- Revisions ------------------------------------------------------------------------------

test "txn: a transaction that changes nothing takes no revision, even on an empty store" {
    // Goal: regression for a wrong postcondition in `Store.txn` that the seeded model test found
    // (seed 34 on SQLite): it asserted that a transaction with operations returns a revision above
    // zero, but deleting an absent key on an empty store changes nothing, so the revision is
    // the current one, 0. Method: each way of changing nothing, first on the empty store and
    // then on a store with one key; the revision must not move and the key must be as it was.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const absent = try s.txn(.{ .on_success = &.{.{ .delete = "/absent" }} }, &diag);
    try testing.expect(absent.succeeded);
    try testing.expectEqual(@as(Revision, 0), absent.revision);
    const empty = try s.txn(.{}, &diag);
    try testing.expectEqual(@as(Revision, 0), empty.revision);
    try expect_status(s, &diag, 0, 0);

    _ = try put_one(s, &diag, "/k", "v");
    const lost = try s.txn(.{
        .compares = &.{.{ .key = "/k", .mod_revision = 0 }},
        .on_success = &.{.{ .put = .{ .key = "/k", .value = "no" } }},
    }, &diag);
    try testing.expect(!lost.succeeded);
    try testing.expectEqual(@as(Revision, 1), lost.revision);
    try testing.expectEqual(@as(Revision, 1), (try delete_one(s, &diag, "/absent")));
    try expect_status(s, &diag, 1, 0);
}

// ---- Resume, compaction, leases ----------------------------------------------------------------

test "watch: after a reconnect, resuming from bookmark + 1 sees exactly what is new" {
    // Goal: a watcher that loses its connection loses nothing. Method: a reader on one
    // connection watches and reads, including a write outside its prefix that moves only the
    // bookmark; it closes; a writer on another connection changes things; a reader on a third
    // connection resumes from the old bookmark + 1 and must see precisely the new events, once,
    // in order. Then it resumes at head + 1 (nothing yet), sees the next write arrive, and
    // is refused a start beyond head + 1.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const writer = (try harness.connect()).interface();
    _ = try put_one(writer, &diag, "/r/a", "1");
    _ = try put_one(writer, &diag, "/x/ignored", "2");
    _ = try put_one(writer, &diag, "/r/b", "3");

    var first = try (try harness.connect()).interface().watch(
        .{ .prefix = "/r/", .from_revision = 1 },
        &diag,
    );
    const batch = try first.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), batch.events.len);
    try testing.expectEqual(@as(Revision, 3), batch.revision);
    _ = try put_one(writer, &diag, "/x/c", "4"); // Outside the prefix: only the bookmark moves.
    const idle = try first.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(@as(Revision, 4), idle.revision);
    first.close();

    _ = try put_one(writer, &diag, "/r/c", "5");
    _ = try delete_one(writer, &diag, "/r/a");
    var again = try (try harness.connect()).interface().watch(
        .{ .prefix = "/r/", .from_revision = idle.revision + 1 },
        &diag,
    );
    const resumed = try again.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), resumed.events.len);
    try testing.expectEqualStrings("/r/c", resumed.events[0].kv.key);
    try testing.expectEqual(@as(Revision, 5), resumed.events[0].kv.mod_revision);
    try testing.expectEqual(store.EventKind.delete, resumed.events[1].kind);
    try testing.expectEqual(@as(Revision, 6), resumed.events[1].kv.mod_revision);
    try testing.expectEqual(@as(usize, 0), resumed.events[1].kv.value.len);
    try testing.expectEqual(@as(Revision, 6), resumed.revision);
    again.close();

    var tail = try writer.watch(.{ .prefix = "/r/", .from_revision = 7 }, &diag);
    defer tail.close();
    try testing.expectEqual(@as(usize, 0), (try tail.next(arena, 0, &diag)).events.len);
    _ = try put_one(writer, &diag, "/r/d", "6");
    const late = try tail.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), late.events.len);
    try testing.expectEqual(@as(Revision, 7), late.events[0].kv.mod_revision);
    try expect_failure(&diag, error.FutureRevision, writer.watch(
        .{ .prefix = "/r/", .from_revision = 9 },
        &diag,
    ), .E0204);
}

test "compaction: reads and watches below the point fail explicitly; at and above it work" {
    // Goal: "compacted" is an error, never silence, and compaction keeps every state a reader
    // at or after the point can ask for. Method: build history with a delete and a re-create,
    // record the state at revision 3, open watches before and after the point, compact to 3,
    // and check reads below, at and above it, the two watches, a new watch, and the bounds
    // of `compact` itself.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    _ = try put_one(s, &diag, "/k", "one"); // 1
    _ = try put_one(s, &diag, "/k", "two"); // 2
    _ = try put_one(s, &diag, "/other", "x"); // 3
    _ = try delete_one(s, &diag, "/k"); // 4
    _ = try put_one(s, &diag, "/k", "three"); // 5
    const before = try s.list(arena, .{ .prefix = "/", .at_revision = 3, .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 2), before.kvs.len);

    var behind = try s.watch(.{ .prefix = "/", .from_revision = 2 }, &diag);
    defer behind.close();
    var ahead = try s.watch(.{ .prefix = "/", .from_revision = 5 }, &diag);
    defer ahead.close();
    try s.compact(3, &diag);
    try expect_status(s, &diag, 5, 3);

    try expect_failure(&diag, error.Compacted, s.get(arena, "/k", 2, &diag), .E0203);
    const old_list: store.ListOptions = .{ .prefix = "/", .at_revision = 2, .limit = 10 };
    try expect_failure(&diag, error.Compacted, s.list(arena, old_list, &diag), .E0203);
    const at_point = try s.list(arena, .{ .prefix = "/", .at_revision = 3, .limit = 10 }, &diag);
    try testing.expectEqual(before.kvs.len, at_point.kvs.len);
    for (before.kvs, at_point.kvs) |was, now| {
        try testing.expectEqualStrings(was.key, now.key);
        try testing.expectEqualStrings(was.value, now.value);
        try testing.expectEqual(was.mod_revision, now.mod_revision);
    }
    try testing.expect((try s.get(arena, "/k", 4, &diag)).kv == null);
    try testing.expectEqualStrings("three", (try s.get(arena, "/k", 5, &diag)).kv.?.value);
    try expect_failure(&diag, error.FutureRevision, s.get(arena, "/k", 6, &diag), .E0204);

    try expect_failure(&diag, error.Compacted, behind.next(arena, 0, &diag), .E0203);
    const kept = try ahead.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), kept.events.len);
    try testing.expectEqual(@as(Revision, 5), kept.events[0].kv.mod_revision);
    const stale: store.WatchOptions = .{ .prefix = "/", .from_revision = 3 };
    try expect_failure(&diag, error.Compacted, s.watch(stale, &diag), .E0203);
    var fresh = try s.watch(.{ .prefix = "/", .from_revision = 4 }, &diag);
    fresh.close();

    try s.compact(2, &diag); // Below the point: nothing to do, and not an error.
    try expect_status(s, &diag, 5, 3);
    try expect_failure(&diag, error.FutureRevision, s.compact(9, &diag), .E0204);
    try s.compact(5, &diag);
    try expect_failure(&diag, error.Compacted, s.get(arena, "/k", 4, &diag), .E0203);
    try testing.expectEqualStrings("three", (try s.get(arena, "/k", 5, &diag)).kv.?.value);
}

test "lease: expiry deletes its keys under one revision, visible to a watcher elsewhere" {
    // Goal: lease expiry as the server will use it. Method: one connection grants a lease and
    // attaches two keys (and one unattached key), renews it once, and lets it lapse on the
    // manual clock; a watch on a second connection and `expire_leases` on a third must see both
    // keys deleted under a single revision, a late keepalive must fail, and expiring again must
    // do nothing and take no revision.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owner = (try harness.connect()).interface();
    const lease = try owner.lease_grant(1000, &diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/nodes/n2", .value = "b", .lease = lease.id } },
        .{ .put = .{ .key = "/nodes/n1", .value = "a", .lease = lease.id } },
        .{ .put = .{ .key = "/services/s", .value = "kept" } },
    };
    const written = try owner.txn(.{ .on_success = &ops }, &diag);

    harness.manual.advance(900);
    try testing.expectEqual(lease.id, (try owner.lease_keepalive(lease.id, &diag)).id);
    harness.manual.advance(900); // 1800: past the original deadline, inside the renewed one.
    const reaper = (try harness.connect()).interface();
    try testing.expectEqual(@as(u32, 0), try reaper.expire_leases(&diag));

    const watcher = (try harness.connect()).interface();
    var watch = try watcher.watch(
        .{ .prefix = "/nodes/", .from_revision = written.revision + 1 },
        &diag,
    );
    defer watch.close();
    harness.manual.advance(200);
    try expect_failure(&diag, error.LeaseNotFound, owner.lease_keepalive(lease.id, &diag), .E0205);
    try testing.expectEqual(@as(u32, 1), try reaper.expire_leases(&diag));

    const batch = try watch.next(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 2), batch.events.len);
    try testing.expectEqual(store.EventKind.delete, batch.events[0].kind);
    try testing.expectEqualStrings("/nodes/n1", batch.events[0].kv.key);
    try testing.expectEqualStrings("/nodes/n2", batch.events[1].kv.key);
    try testing.expectEqual(written.revision + 1, batch.events[0].kv.mod_revision);
    try testing.expectEqual(batch.events[0].kv.mod_revision, batch.events[1].kv.mod_revision);
    try testing.expect((try owner.get(arena, "/services/s", null, &diag)).kv != null);
    try testing.expectEqual(@as(u32, 0), try reaper.expire_leases(&diag));
    try expect_status(owner, &diag, written.revision + 1, 0);
}

test "lease: revoke frees its keys in one revision and reports it; unknown leases are refused" {
    // Goal: revoke's contract. Method: revoke a lease with keys (the returned revision is that of
    // the deletion), revoke one that holds no key (the current revision, no new one), then
    // revoke the first again (unknown) and an id never granted.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const lease = try s.lease_grant(5000, &diag);
    const attach: store.Op = .{ .put = .{ .key = "/n", .value = "v", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{attach} }, &diag);
    try testing.expectEqual(@as(Revision, 2), try s.lease_revoke(lease.id, &diag));
    try expect_failure(&diag, error.LeaseNotFound, s.lease_revoke(lease.id, &diag), .E0205);
    const empty = try s.lease_grant(5000, &diag);
    try testing.expectEqual(@as(Revision, 2), try s.lease_revoke(empty.id, &diag));
    try expect_failure(&diag, error.LeaseNotFound, s.lease_revoke(777_777, &diag), .E0205);
    try expect_status(s, &diag, 2, 0);
}

test "lease: a put that names a dead lease changes nothing" {
    // Goal: a transaction is all or nothing even when the refusal comes late. Method: for a lease
    // that was never granted, one that ran out but was not yet reaped, and one that was
    // revoked, submit a transaction whose first op is fine and whose second names the lease.
    // It must fail with ZC-E0205 and leave no trace: no revision, no first key. A dead lease
    // named only by the branch not taken is no problem.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    const lapsed = try s.lease_grant(1000, &diag);
    const revoked = try s.lease_grant(1000, &diag);
    _ = try s.lease_revoke(revoked.id, &diag);
    harness.manual.advance(1500);
    for ([_]store.LeaseId{ 777_777, lapsed.id, revoked.id }) |dead| {
        const ops = [_]store.Op{
            .{ .put = .{ .key = "/a", .value = "1" } },
            .{ .put = .{ .key = "/b", .value = "2", .lease = dead } },
        };
        const refused = s.txn(.{ .on_success = &ops }, &diag);
        try expect_failure(&diag, error.LeaseNotFound, refused, .E0205);
        try expect_status(s, &diag, 0, 0);
        try testing.expect((try s.get(arena_state.allocator(), "/a", null, &diag)).kv == null);
    }
    const untaken = try s.txn(.{
        .compares = &.{.{ .key = "/a", .mod_revision = 0 }},
        .on_success = &.{.{ .put = .{ .key = "/a", .value = "1" } }},
        .on_failure = &.{.{ .put = .{ .key = "/b", .value = "2", .lease = lapsed.id } }},
    }, &diag);
    try testing.expect(untaken.succeeded);
    try expect_status(s, &diag, 1, 0);
}

test "lease: one lease holds at most the limit of keys, and a refusal changes nothing" {
    // Goal: the bound that lets a revoke fit in one watch batch. Method: fill a lease to its
    // limit in transactions of at most the per-branch limit, then try one more key.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const lease = try s.lease_grant(60_000, &diag);
    var name: [16]u8 = undefined;
    var attached: u32 = 0;
    while (attached < constants.store_lease_keys_max) : (attached += 1) {
        const key = try std.fmt.bufPrint(&name, "/l/{d:0>3}", .{attached});
        const op: store.Op = .{ .put = .{ .key = key, .value = "v", .lease = lease.id } };
        _ = try s.txn(.{ .on_success = &.{op} }, &diag);
    }
    const head = (try s.status(&diag)).revision;
    const extra: store.Op = .{ .put = .{ .key = "/l/extra", .value = "v", .lease = lease.id } };
    try expect_failure(&diag, error.NoCapacity, s.txn(.{ .on_success = &.{extra} }, &diag), .E0207);
    try expect_status(s, &diag, head, 0);
    const again: store.Op = .{ .put = .{ .key = "/l/000", .value = "w", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{again} }, &diag); // Updating a key it holds is fine.
}

test "lease: moving a key onto a full lease is refused; moving one off it makes room" {
    // Goal: the key limit counts the keys a lease would hold after the transaction, not just the
    // keys that are new. A revoke deletes all of them in one watch batch, so a lease over the
    // limit would break that. Method: fill one lease to the limit and give another lease a
    // key; putting the other lease's key onto the full lease must be refused with nothing
    // changed. Then, in a single transaction, move one of the full lease's keys to the other
    // lease and attach the key that was refused; that leaves the count unchanged, so it works.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const full = try s.lease_grant(60_000, &diag);
    const other = try s.lease_grant(60_000, &diag);
    var name: [16]u8 = undefined;
    for (0..constants.store_lease_keys_max) |index| {
        const key = try std.fmt.bufPrint(&name, "/l/{d:0>3}", .{index});
        const op: store.Op = .{ .put = .{ .key = key, .value = "v", .lease = full.id } };
        _ = try s.txn(.{ .on_success = &.{op} }, &diag);
    }
    const theirs: store.Op = .{ .put = .{ .key = "/o/key", .value = "v", .lease = other.id } };
    _ = try s.txn(.{ .on_success = &.{theirs} }, &diag);
    const head = (try s.status(&diag)).revision;

    const steal: store.Op = .{ .put = .{ .key = "/o/key", .value = "v", .lease = full.id } };
    try expect_failure(&diag, error.NoCapacity, s.txn(.{ .on_success = &.{steal} }, &diag), .E0207);
    try expect_status(s, &diag, head, 0);

    const swap = [_]store.Op{
        .{ .put = .{ .key = "/l/000", .value = "v", .lease = other.id } },
        steal,
    };
    const swapped = try s.txn(.{ .on_success = &swap }, &diag);
    try testing.expectEqual(head + 1, swapped.revision);
    try testing.expectEqual(head + 2, try s.lease_revoke(full.id, &diag));
}

test "limits: oversized requests are refused with a code and write nothing" {
    // Goal: the negative space of the size bounds, through the interface. Method: a value one
    // byte over the limit, a branch one operation over, and a ttl outside its range.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const s = (try harness.connect()).interface();
    const big = try testing.allocator.alloc(u8, constants.store_value_bytes_max + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const too_big: store.Op = .{ .put = .{ .key = "/big", .value = big } };
    try expect_failure(&diag, error.TooLarge, s.txn(.{ .on_success = &.{too_big} }, &diag), .E0206);

    var many: [constants.store_txn_ops_max + 1]store.Op = undefined;
    var names: [many.len][8]u8 = undefined;
    for (&many, &names, 0..) |*op, *name, index| {
        op.* = .{ .delete = try std.fmt.bufPrint(name, "/k{d:0>4}", .{index}) };
    }
    try expect_failure(&diag, error.TooLarge, s.txn(.{ .on_success = &many }, &diag), .E0206);
    try expect_failure(&diag, error.TooLarge, s.lease_grant(1, &diag), .E0206);
    try expect_status(s, &diag, 0, 0);
}

// ---- Pagination ------------------------------------------------------------------------------

test "list: pages are consistent at one revision, ordered bytewise, and join with no gap" {
    // Goal: pagination with at_revision. Method: write keys out of order (and one outside the
    // prefix), read page one, change the store (inside the prefix: an insert and a delete), then
    // read the rest at the first page's revision: the later changes must not appear and the pages
    // must join up with no repeat and no gap.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = (try harness.connect()).interface();
    for ([_][]const u8{ "/r/e", "/r/b", "/r/d", "/r/a", "/r/c", "/other/x" }) |key| {
        _ = try put_one(s, &diag, key, "v");
    }
    const page1 = try s.list(arena, .{ .prefix = "/r/", .limit = 2 }, &diag);
    try testing.expectEqual(@as(usize, 2), page1.kvs.len);
    try testing.expectEqualStrings("/r/a", page1.kvs[0].key);
    try testing.expectEqualStrings("/r/b", page1.kvs[1].key);
    try testing.expectEqualStrings("/r/b", page1.continue_after.?);

    _ = try put_one(s, &diag, "/r/bb", "late");
    _ = try delete_one(s, &diag, "/r/d");

    const page2 = try s.list(arena, .{
        .prefix = "/r/",
        .limit = 10,
        .at_revision = page1.revision,
        .continue_after = page1.continue_after,
    }, &diag);
    try testing.expectEqual(@as(usize, 3), page2.kvs.len);
    try testing.expectEqualStrings("/r/c", page2.kvs[0].key);
    try testing.expectEqualStrings("/r/d", page2.kvs[1].key);
    try testing.expectEqualStrings("/r/e", page2.kvs[2].key);
    try testing.expect(page2.continue_after == null);
    const now = try s.list(arena, .{ .prefix = "/r/", .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 5), now.kvs.len); // a, b, bb, c, e.
}

// ---- A model to compare against ----------------------------------------------------------------

const model_keys = [_][]const u8{ "/m/x/a", "/m/x/b", "/m/x/c", "/m/y/a", "/m/y/b", "/m/z" };
const model_prefixes = [_][]const u8{ "/m/", "/m/x/", "/m/y/", "/m/z", "/m/x/b", "" };
/// The key a compare-and-swap writes when its compare fails.
const audit_key: u8 = 5;
const pages_max = 64;

const ModelEvent = struct {
    revision: Revision,
    key: u8,
    kind: store.EventKind,
    value: [12]u8,
    value_len: u8,
    create_revision: Revision,

    fn value_slice(event: *const ModelEvent) []const u8 {
        return event.value[0..event.value_len];
    }
};

/// What one op of a model transaction does.
const Change = struct {
    key: u8,
    delete: bool,
    value: [12]u8 = undefined,
    value_len: u8 = 0,
};

/// The whole history, kept forever: the store forgets below its compaction point, the model does
/// not, so it can say what any reachable revision must look like.
const Model = struct {
    events: [model_events_max]ModelEvent = undefined,
    count: u32 = 0,
    head: Revision = 0,
    compacted: Revision = 0,
    counter: u32 = 0,

    /// The key as it was at `revision`: its last event then, if that was a put.
    fn state(model: *const Model, key: u8, revision: Revision) ?*const ModelEvent {
        var found: ?*const ModelEvent = null;
        for (model.events[0..model.count]) |*event| {
            if (event.revision > revision) break;
            if (event.key == key) found = event;
        }
        const event = found orelse return null;
        return if (event.kind == .put) event else null;
    }

    fn fresh_value(model: *Model, change: *Change) void {
        model.counter += 1;
        // Cannot fail: "v" and a u32 are at most 11 bytes, and the buffer holds 12.
        const text = std.fmt.bufPrint(&change.value, "v{d}", .{model.counter}) catch unreachable;
        change.value_len = @intCast(text.len);
    }

    /// Applies one transaction: a put always writes, a delete only if the key exists. One
    /// revision if anything was written, none otherwise.
    fn apply(model: *Model, changes: []const Change) void {
        const revision = model.head + 1;
        var wrote = false;
        for (changes) |change| {
            const live = model.state(change.key, model.head);
            if (change.delete and live == null) continue;
            assert(model.count < model.events.len);
            model.events[model.count] = .{
                .revision = revision,
                .key = change.key,
                .kind = if (change.delete) .delete else .put,
                .value = change.value,
                .value_len = if (change.delete) 0 else change.value_len,
                .create_revision = if (live) |l| l.create_revision else revision,
            };
            model.count += 1;
            wrote = true;
        }
        if (wrote) model.head = revision;
    }
};

fn build_ops(changes: []const Change, ops: *[3]store.Op) void {
    assert(changes.len <= ops.len);
    for (changes, 0..) |*change, index| {
        ops[index] = if (change.delete)
            .{ .delete = model_keys[change.key] }
        else
            .{ .put = .{
                .key = model_keys[change.key],
                .value = change.value[0..change.value_len],
            } };
    }
}

fn expect_kv(got: ?store.KeyValue, want: ?*const ModelEvent) !void {
    const event = want orelse {
        try testing.expect(got == null);
        return;
    };
    const kv = got.?;
    try testing.expectEqualStrings(model_keys[event.key], kv.key);
    try testing.expectEqualStrings(event.value_slice(), kv.value);
    try testing.expectEqual(event.create_revision, kv.create_revision);
    try testing.expectEqual(event.revision, kv.mod_revision);
    try testing.expectEqual(store.lease_none, kv.lease);
}

const ModelRun = struct {
    s: Store,
    model: Model = .{},
    prng: std.Random.DefaultPrng,
    diag: Diag = undefined,
    arena_state: std.heap.ArenaAllocator,

    fn arena(run: *ModelRun) Allocator {
        return run.arena_state.allocator();
    }

    fn check_status(run: *ModelRun) !void {
        try expect_status(run.s, &run.diag, run.model.head, run.model.compacted);
    }

    /// A revision a read may ask for: from the compaction point to the head.
    fn readable_revision(run: *ModelRun) Revision {
        const span = run.model.head - run.model.compacted + 1;
        return run.model.compacted + run.prng.random().uintLessThan(u64, span);
    }

    fn step_write(run: *ModelRun) !void {
        const random = run.prng.random();
        var changes: [3]Change = undefined;
        const count = random.intRangeAtMost(u32, 1, 3);
        const start = random.uintLessThan(u32, model_keys.len);
        for (changes[0..count], 0..) |*change, index| {
            const key: u8 = @intCast((start + index) % model_keys.len);
            change.* = .{ .key = key, .delete = random.uintLessThan(u32, 4) == 0 };
            if (!change.delete) run.model.fresh_value(change);
        }
        var ops: [3]store.Op = undefined;
        build_ops(changes[0..count], &ops);
        const result = try run.s.txn(.{ .on_success = ops[0..count] }, &run.diag);
        run.model.apply(changes[0..count]);
        try testing.expect(result.succeeded);
        try testing.expectEqual(run.model.head, result.revision);
    }

    fn step_cas(run: *ModelRun) !void {
        const random = run.prng.random();
        const key: u8 = @intCast(random.uintLessThan(u32, model_keys.len));
        const live = run.model.state(key, run.model.head);
        const actual: Revision = if (live) |l| l.revision else 0;
        const holds = random.uintLessThan(u32, 3) != 0;
        const expected = if (holds) actual else actual + 1; // A revision it cannot have.
        var success = [1]Change{.{ .key = key, .delete = false }};
        var failure = [1]Change{.{ .key = audit_key, .delete = false }};
        run.model.fresh_value(&success[0]);
        run.model.fresh_value(&failure[0]);
        var success_ops: [3]store.Op = undefined;
        var failure_ops: [3]store.Op = undefined;
        build_ops(&success, &success_ops);
        build_ops(&failure, &failure_ops);
        const result = try run.s.txn(.{
            .compares = &.{.{ .key = model_keys[key], .mod_revision = expected }},
            .on_success = success_ops[0..1],
            .on_failure = failure_ops[0..1],
        }, &run.diag);
        run.model.apply(if (holds) &success else &failure);
        try testing.expectEqual(holds, result.succeeded);
        try testing.expectEqual(run.model.head, result.revision);
    }

    fn step_get(run: *ModelRun) !void {
        const random = run.prng.random();
        const key: u8 = @intCast(random.uintLessThan(u32, model_keys.len));
        const model = &run.model;
        switch (random.uintLessThan(u32, 6)) {
            0 => {
                const got = try run.s.get(run.arena(), model_keys[key], null, &run.diag);
                try expect_kv(got.kv, model.state(key, model.head));
            },
            1 => if (model.compacted > 0) {
                const old = random.uintLessThan(u64, model.compacted);
                const got = run.s.get(run.arena(), model_keys[key], old, &run.diag);
                try expect_failure(&run.diag, error.Compacted, got, .E0203);
            },
            2 => {
                const future = model.head + 1 + random.uintLessThan(u64, 3);
                const got = run.s.get(run.arena(), model_keys[key], future, &run.diag);
                try expect_failure(&run.diag, error.FutureRevision, got, .E0204);
            },
            else => {
                const revision = run.readable_revision();
                const got = try run.s.get(run.arena(), model_keys[key], revision, &run.diag);
                try testing.expectEqual(revision, got.revision);
                try expect_kv(got.kv, model.state(key, revision));
            },
        }
    }

    fn step_list(run: *ModelRun) !void {
        const random = run.prng.random();
        const prefix = model_prefixes[random.uintLessThan(u32, model_prefixes.len)];
        const limit = random.intRangeAtMost(u32, 1, 4);
        var revision: ?Revision = if (random.boolean()) null else run.readable_revision();
        var after: ?[]const u8 = null;
        var got: std.ArrayList(store.KeyValue) = .empty;
        var finished = false;
        for (0..pages_max) |_| {
            const page = try run.s.list(run.arena(), .{
                .prefix = prefix,
                .at_revision = revision,
                .limit = limit,
                .continue_after = after,
            }, &run.diag);
            try testing.expect(page.kvs.len <= limit);
            revision = page.revision; // Later pages are read at the first page's revision.
            try got.appendSlice(run.arena(), page.kvs);
            after = page.continue_after;
            if (after == null) {
                finished = true;
                break;
            }
        }
        try testing.expect(finished);
        try run.expect_listing(prefix, revision.?, got.items);
    }

    fn expect_listing(
        run: *ModelRun,
        prefix: []const u8,
        revision: Revision,
        got: []const store.KeyValue,
    ) !void {
        var index: usize = 0;
        for (model_keys, 0..) |name, key| {
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const want = run.model.state(@intCast(key), revision) orelse continue;
            try testing.expect(index < got.len);
            try expect_kv(got[index], want);
            index += 1;
        }
        try testing.expectEqual(got.len, index);
    }

    fn step_compact(run: *ModelRun) !void {
        if (run.model.head == 0) return;
        const revision = 1 + run.prng.random().uintLessThan(u64, run.model.head);
        try run.s.compact(revision, &run.diag);
        run.model.compacted = @max(run.model.compacted, revision);
    }

    /// The watch from the compaction point must replay exactly the history above it.
    fn check_replay(run: *ModelRun) !void {
        const model = &run.model;
        const start: store.WatchOptions = .{
            .prefix = "/m/",
            .from_revision = model.compacted + 1,
        };
        var watch = try run.s.watch(start, &run.diag);
        defer watch.close();
        const events = try drain(&watch, run.arena(), model.head, &run.diag);
        var index: usize = 0;
        for (model.events[0..model.count]) |*want| {
            if (want.revision <= model.compacted) continue;
            try testing.expect(index < events.len);
            const got = events[index];
            index += 1;
            try testing.expectEqual(want.kind, got.kind);
            try testing.expectEqualStrings(model_keys[want.key], got.kv.key);
            try testing.expectEqualStrings(want.value_slice(), got.kv.value);
            try testing.expectEqual(want.revision, got.kv.mod_revision);
            try testing.expectEqual(want.create_revision, got.kv.create_revision);
        }
        try testing.expectEqual(events.len, index);
    }
};

test "model: seeded random operations agree with a model of the store" {
    // Goal: the semantics of get, list, transactions, compaction and watch, checked against an
    // independent model over many random steps. Method: a seeded sequence of writes (puts and
    // deletes, up to three keys), compare-and-swap with right and wrong revisions, reads at
    // random revisions (including compacted and future ones), paginated lists, and compactions.
    // After every step the status must match the model, and at the end a watch from the
    // compaction point must replay exactly the model's history above it. The seed is printed;
    // `-Dseed=N` replays the run.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    const run = try testing.allocator.create(ModelRun);
    defer testing.allocator.destroy(run);
    run.* = .{
        .s = (try harness.connect()).interface(),
        .prng = harness.prng("model"),
        .arena_state = .init(testing.allocator),
    };
    defer run.arena_state.deinit();
    run.diag.reset();
    for (0..model_steps) |_| {
        _ = run.arena_state.reset(.retain_capacity);
        switch (run.prng.random().uintLessThan(u32, 100)) {
            0...34 => try run.step_write(),
            35...54 => try run.step_cas(),
            55...71 => try run.step_get(),
            72...95 => try run.step_list(),
            else => try run.step_compact(),
        }
        try run.check_status();
    }
    try run.check_replay();
}
