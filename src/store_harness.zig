//! The harness of the store conformance suite: one `Harness` per test, which gives the test
//! `Store` connections to the backend chosen by the build (`conformance_options`), plus the
//! helpers the tests share. The suite is split in two files that both use it:
//! `store_conformance_single.zig` (no threads; it also runs in `zig build test` and under WASI in
//! `zig build wasm-test`, against the memory store) and `store_conformance.zig` (the racing tests
//! and the entry point of `zig build test-store`). See the latter's header for the rules.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const suite = @import("conformance_options");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const Diag = @import("diag.zig").Diag;
const ManualClock = @import("clock.zig").ManualClock;
const store = @import("store.zig");
const MemoryStore = @import("store_memory.zig").MemoryStore;
// Only the backend under test is analysed: the others need C libraries that a WASI build lacks.
const SqliteStore = if (suite.backend == .sqlite) @import("store_sqlite.zig").SqliteStore else void;
const OpenOptions = if (suite.backend == .sqlite) @import("store_sqlite.zig").OpenOptions else void;
const postgres = if (suite.backend == .postgres) @import("store_postgres.zig") else void;
const PostgresStore = if (suite.backend == .postgres) postgres.PostgresStore else void;
const fault_proxy = if (suite.backend == .postgres) @import("testing/fault_proxy.zig") else void;

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const Store = store.Store;

pub const backend = suite.backend;

// ---- Bounds of the suite (every loop and buffer has a named limit) ------------------------------

pub const connections_max = 16;
pub const writers_count = 4;
pub const rounds_per_writer = 40;
pub const counter_increments = 25;
pub const retries_max = 100_000;
pub const watch_polls_max = 100_000;
pub const watch_wait_ms = 20;
pub const model_steps = 400;
pub const model_events_max = model_steps * 3;
pub const key_bytes = 32;

// ---- Harness ---------------------------------------------------------------------------------

pub const Harness = struct {
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
    /// `ZCUBE_TEST_PROXY` set: the connections go through a proxy that delays and stalls.
    proxy: if (backend == .postgres) ?*fault_proxy.Proxy else void,
    proxy_conninfo: if (backend == .postgres) ?[:0]u8 else void,
    proxy_thread: if (backend == .postgres) ?std.Thread else void,
    proxy_stop: std.atomic.Value(bool),
    connections_made: u32,
    connections: [connections_max]?*Connection,

    pub fn start() !*Harness {
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
            .proxy = if (backend == .postgres) null else {},
            .proxy_conninfo = if (backend == .postgres) null else {},
            .proxy_thread = if (backend == .postgres) null else {},
            .proxy_stop = .init(false),
            .connections_made = 0,
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

    pub fn stop(harness: *Harness) void {
        for (&harness.connections) |*slot| {
            if (slot.*) |conn| {
                conn.close(harness);
                slot.* = null;
            }
        }
        switch (backend) {
            .memory => harness.memory.deinit(),
            .sqlite => harness.tmp.cleanup(),
            .postgres => {
                harness.stop_proxy();
                harness.drop_postgres_schema();
            },
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

    pub fn report_seed(harness: *const Harness) void {
        const banner = "store conformance: backend={s} seed={d} (replay: -Dseed={d})\n";
        std.debug.print(banner, .{ @tagName(backend), harness.seed, harness.seed });
    }

    /// A random generator for one test: the seed, mixed with a name so tests differ.
    pub fn prng(harness: *const Harness, comptime name: []const u8) std.Random.DefaultPrng {
        return .init(harness.seed ^ std.hash.Wyhash.hash(0, name));
    }

    /// Names the database from the environment and a schema no other run shares.
    fn start_postgres(harness: *Harness) !void {
        const conninfo = testing.environ.getPosix("ZCUBE_TEST_POSTGRES") orelse {
            std.debug.print("ZCUBE_TEST_POSTGRES names no database (see AGENTS.md)\n", .{});
            return error.PostgresNotConfigured;
        };
        harness.pg_conninfo = conninfo;
        errdefer harness.stop_proxy();
        if (testing.environ.getPosix("ZCUBE_TEST_PROXY") != null) try harness.start_proxy(conninfo);
        const now = std.Io.Clock.real.now(testing.io).toNanoseconds();
        const unique = std.hash.Wyhash.hash(harness.seed, std.mem.asBytes(&now));
        const text = try std.fmt.bufPrint(&harness.pg_schema, "zt_{x:0>16}", .{unique});
        harness.pg_schema_len = @intCast(text.len);
    }

    /// Points the connections at a proxy in front of `conninfo`'s server (the schema is still
    /// dropped over `conninfo` itself) and starts the thread that disturbs it.
    fn start_proxy(harness: *Harness, conninfo: []const u8) !void {
        var port: u16 = 5432;
        var words = std.mem.tokenizeScalar(u8, conninfo, ' ');
        while (words.next()) |word| {
            if (!std.mem.startsWith(u8, word, "port=")) continue;
            port = try std.fmt.parseInt(u16, word[5..], 10);
        }
        const proxy = try fault_proxy.Proxy.start(harness.gpa, port);
        harness.proxy = proxy;
        const format = "{s} host=127.0.0.1 port={d}"; // The last keyword wins in libpq.
        const args = .{ conninfo, proxy.port };
        harness.proxy_conninfo = try std.fmt.allocPrintSentinel(harness.gpa, format, args, 0);
        harness.pg_conninfo = harness.proxy_conninfo.?;
        harness.proxy_thread = try std.Thread.spawn(.{}, disturb, .{harness});
    }

    fn stop_proxy(harness: *Harness) void {
        const proxy = harness.proxy orelse return;
        harness.proxy_stop.store(true, .release);
        if (harness.proxy_thread) |thread| thread.join();
        // The tests must really have gone through it.
        if (harness.connections_made > 0) assert(proxy.stats().accepted > 0);
        proxy.stop();
        harness.proxy = null;
        if (harness.proxy_conninfo) |text| harness.gpa.free(text);
        harness.proxy_conninfo = null;
    }

    fn drop_conninfo(harness: *const Harness) []const u8 {
        const direct = testing.environ.getPosix("ZCUBE_TEST_POSTGRES").?;
        return if (harness.proxy != null) direct else harness.pg_conninfo;
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
        var options = harness.pg_options();
        options.conninfo = harness.drop_conninfo();
        dropper.open(testing.io, options, &diag) catch return;
        defer dropper.close();
        dropper.drop_schema(&diag) catch {};
    }

    fn file_path(harness: *const Harness) []const u8 {
        assert(backend == .sqlite);
        return harness.path_buffer[0..harness.path_len];
    }

    /// A new connection to the same logical store.
    pub fn connect(harness: *Harness) !*Connection {
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
            harness.connections_made += 1;
            return conn;
        }
        return error.TooManyConnections;
    }
};

/// Until stopped, makes the network slow, narrow and now and then silent in one direction, in
/// turns of a few tens of milliseconds, and heals it between turns. Nothing is ever cut, so every
/// call in the suite still gets its answer, only later.
fn disturb(harness: *Harness) void {
    const proxy = harness.proxy.?;
    var prng = harness.prng("disturb");
    const rng = prng.random();
    while (!harness.proxy_stop.load(.acquire)) {
        proxy.heal();
        switch (rng.uintLessThan(u32, 3)) {
            0 => proxy.set_latency(rng.intRangeAtMost(u32, 1, 8)),
            1 => proxy.set_bandwidth(rng.intRangeAtMost(u64, 20_000, 200_000)),
            else => proxy.stall(if (rng.boolean()) .to_server else .to_client),
        }
        const ms = rng.intRangeAtMost(u64, 10, 60);
        testing.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
    }
    proxy.heal();
}

pub const Connection = struct {
    sqlite: if (backend == .sqlite) SqliteStore else void,
    serialized: if (backend == .memory) Serialized else void,
    postgres: if (backend == .postgres) PostgresStore else void,

    pub fn interface(conn: *Connection) Store {
        return switch (backend) {
            .memory => conn.serialized.interface(),
            .sqlite => conn.sqlite.interface(),
            .postgres => conn.postgres.interface(),
        };
    }

    pub fn close(conn: *Connection, harness: *Harness) void {
        if (backend == .sqlite) conn.sqlite.close();
        if (backend == .postgres) conn.postgres.close();
        harness.gpa.destroy(conn);
    }
};

/// Puts a mutex around every call of another `Store`, so threads can share the memory store.
pub const Serialized = struct {
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
        .lease_list = lease_list,
        .expire_leases = expire_leases,
        .compact = compact,
    };

    const watch_vtable: store.Watch.WatchVTable = .{ .next = watch_next, .close = watch_close };

    const Box = struct { inner: store.Watch, owner: *Serialized };

    pub fn interface(self: *Serialized) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *Serialized {
        return @ptrCast(@alignCast(context));
    }

    /// A single-threaded build (WASI) has nobody to exclude, and no `std.Io` to lock with.
    fn enter(self: *Serialized) void {
        if (builtin.single_threaded) return;
        self.mutex.lockUncancelable(testing.io);
    }

    fn leave(self: *Serialized) void {
        if (builtin.single_threaded) return;
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

    fn lease_list(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.lease_list(arena, diag);
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

pub fn put_one(s: Store, diag: *Diag, key: []const u8, value: []const u8) !Revision {
    const op: store.Op = .{ .put = .{ .key = key, .value = value } };
    const result = try s.txn(.{ .on_success = &.{op} }, diag);
    try testing.expect(result.succeeded);
    return result.revision;
}

pub fn delete_one(s: Store, diag: *Diag, key: []const u8) !Revision {
    const op: store.Op = .{ .delete = key };
    const result = try s.txn(.{ .on_success = &.{op} }, diag);
    return result.revision;
}

/// Checks that a call failed with `expected`, left diagnostic `code`, and clears the diagnostic.
pub fn expect_failure(diag: *Diag, expected: store.Error, actual: anytype, code: codes.Code) !void {
    try testing.expectError(expected, actual);
    try testing.expectEqual(code, diag.code.?);
    diag.reset();
}

pub fn expect_status(s: Store, diag: *Diag, revision: Revision, compacted: Revision) !void {
    const status = try s.status(diag);
    try testing.expectEqual(revision, status.revision);
    try testing.expectEqual(compacted, status.compacted_revision);
}

/// Reads `watch` until its bookmark reaches `head` and returns every event it delivered.
pub fn drain(
    watch: *store.Watch,
    arena: Allocator,
    head: Revision,
    diag: *Diag,
) ![]const store.Event {
    var events: std.ArrayList(store.Event) = .empty;
    for (0..watch_polls_max) |_| {
        const batch = try watch.next(arena, 0, diag);
        try events.appendSlice(arena, batch.events);
        if (batch.revision >= head) return events.items;
    }
    return error.WatchDidNotCatchUp;
}
