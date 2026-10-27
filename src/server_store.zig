//! The server's store: whichever backend the configuration names, opened and closed in one
//! place, and the real clock the backends and the controllers share. Shell code: files, libpq,
//! SQLite, a mutex.
//!
//! The memory store is single-threaded by design (store_memory.zig), and the server has a thread
//! per connection, so it is wrapped in `Locked`, one mutex around every call. The SQLite and
//! Postgres backends lock for themselves.

const std = @import("std");
const assert = std.debug.assert;
const Clock = @import("clock.zig").Clock;
const config_mod = @import("server_config.zig");
const diag_mod = @import("diag.zig");
const store = @import("store.zig");
const MemoryStore = @import("store_memory.zig").MemoryStore;
const PostgresStore = @import("store_postgres.zig").PostgresStore;
const SqliteStore = @import("store_sqlite.zig").SqliteStore;

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Revision = store.Revision;
const Store = store.Store;

/// Unix milliseconds: decision ids and `at_ms` fields mean wall-clock time (docs/keys.md).
pub const RealClock = struct {
    io: std.Io,

    pub fn clock(real: *RealClock) Clock {
        return .{ .context = real, .now_ms_fn = now_ms_impl };
    }

    fn now_ms_impl(context: *anyopaque) u64 {
        const real: *RealClock = @ptrCast(@alignCast(context));
        const ms = std.Io.Clock.real.now(real.io).toMilliseconds();
        assert(ms > 0); // The machine's clock is after 1970.
        return @intCast(ms);
    }
};

pub const Backend = struct {
    gpa: Allocator,
    real: RealClock,
    kind: Kind,

    const Kind = union(enum) {
        memory: struct { memory: *MemoryStore, locked: *Locked },
        sqlite: *SqliteStore,
        postgres: *PostgresStore,
    };

    /// Opens the store the configuration names. On failure `diag` says why and nothing is open.
    pub fn open(
        gpa: Allocator,
        io: std.Io,
        spec: config_mod.Store,
        create: bool,
        diag: *Diag,
    ) (store.Error || error{OutOfMemory})!*Backend {
        const backend = try gpa.create(Backend);
        errdefer gpa.destroy(backend);
        backend.gpa = gpa;
        backend.real = .{ .io = io };
        const time = backend.real.clock();
        switch (spec) {
            .memory => {
                const memory = try gpa.create(MemoryStore);
                errdefer gpa.destroy(memory);
                memory.init(gpa, time);
                errdefer memory.deinit();
                const locked = try gpa.create(Locked);
                errdefer gpa.destroy(locked);
                locked.* = .{ .inner = memory.interface(), .mutex = .init, .io = io, .gpa = gpa };
                backend.kind = .{ .memory = .{ .memory = memory, .locked = locked } };
            },
            .sqlite => |path| {
                const sqlite = try gpa.create(SqliteStore);
                errdefer gpa.destroy(sqlite);
                try sqlite.open(io, time, path, .{ .create = create }, diag);
                backend.kind = .{ .sqlite = sqlite };
            },
            .postgres => |settings| {
                const postgres = try gpa.create(PostgresStore);
                errdefer gpa.destroy(postgres);
                try postgres.open(io, .{ .conninfo = settings, .create = create }, diag);
                backend.kind = .{ .postgres = postgres };
            },
        }
        return backend;
    }

    /// Closes the store. Every watch must be closed first.
    pub fn close(backend: *Backend) void {
        const gpa = backend.gpa;
        switch (backend.kind) {
            .memory => |parts| {
                gpa.destroy(parts.locked);
                parts.memory.deinit();
                gpa.destroy(parts.memory);
            },
            .sqlite => |sqlite| {
                sqlite.close();
                gpa.destroy(sqlite);
            },
            .postgres => |postgres| {
                postgres.close();
                gpa.destroy(postgres);
            },
        }
        gpa.destroy(backend);
    }

    pub fn handle(backend: *Backend) Store {
        return switch (backend.kind) {
            .memory => |parts| parts.locked.interface(),
            .sqlite => |sqlite| sqlite.interface(),
            .postgres => |postgres| postgres.interface(),
        };
    }

    pub fn clock(backend: *Backend) Clock {
        return backend.real.clock();
    }

    pub fn name(backend: *const Backend) []const u8 {
        return @tagName(backend.kind);
    }
};

/// One mutex around every call of another `Store`, so threads can share a single-threaded one.
pub const Locked = struct {
    inner: Store,
    mutex: std.Io.Mutex,
    io: std.Io,
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

    const Box = struct { inner: store.Watch, owner: *Locked };

    pub fn interface(self: *Locked) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *Locked {
        return @ptrCast(@alignCast(context));
    }

    fn enter(self: *Locked) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn leave(self: *Locked) void {
        self.mutex.unlock(self.io);
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
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const self = from(context);
        self.enter();
        defer self.leave();
        return self.inner.list(arena, options, diag);
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
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        const self = from(context);
        self.enter();
        defer self.leave();
        const box = self.gpa.create(Box) catch return failures_no_memory(diag);
        errdefer self.gpa.destroy(box); // The inner watch failed: nothing owns the box.
        box.* = .{ .inner = try self.inner.watch(options, diag), .owner = self };
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

fn failures_no_memory(diag: *Diag) store.Error {
    return @import("store_failures.zig").no_memory(diag);
}
