//! `SqliteStore`: the SQLite backend of `Store` (dev, tests and single-node use). One
//! `SqliteStore` is one connection to one database file; several in one process (or the server
//! plus nothing else, see below) share the file through SQLite's own locking.
//!
//! The model is docs/store-design.md: `store_meta` (the current and compacted revisions),
//! `store_log` (append-only, one row per event, `(revision, idx)` primary key), `store_live` (the
//! latest row per key) and `store_lease`. A write is `BEGIN IMMEDIATE`, which takes SQLite's one
//! write lock, so writers are serialised: the revision is read and bumped inside the same
//! transaction as the data it labels, commit order is revision order, and a rolled-back
//! transaction takes no revision, so there are no gaps. WAL mode lets readers keep reading while
//! a writer commits. Every read runs in one read transaction, so the revision it reports and the
//! rows it returns come from one snapshot.
//!
//! ## Things a caller must know
//!
//! - Only the server may open the file while it runs (docs/store-design.md). Other processes
//!   would not break correctness, but they would wait on the write lock and can fail with
//!   ZC-E0208.
//! - Leases are stored as deadlines on the injected `Clock`. A deadline outlives the process,
//!   so in production the clock must be comparable across restarts (wall time in milliseconds);
//!   a monotonic clock whose zero changes at boot is for tests and the memory store only.
//! - A `SqliteStore` is thread-safe: a mutex serialises its operations. A `Watch` is used by one
//!   thread at a time and sleeps outside that mutex, polling the log every
//!   `constants.store_watch_poll_ms` (SQLite has no NOTIFY).
//! - Allocation: SQLite allocates inside its library. Every result this file hands out is
//!   copied into the caller's arena, so the arena limit bounds what a request can hold.
//! - A failure is a registered diagnostic. The raw SQLite message and result code go in the
//!   cause chain (first, so that verbose output shows them); the last cause, the one default
//!   output shows, is written for the operator. See `classify`.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite_c");
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const Clock = @import("clock.zig").Clock;
const ManualClock = @import("clock.zig").ManualClock;
const store = @import("store.zig");
const failures = @import("store_failures.zig");

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const LeaseId = store.LeaseId;
const Error = store.Error;

/// Bumped when the schema changes. A file with a higher number is refused (ZC-E0210).
pub const schema_version: u32 = 1;
/// "ZCUB": marks the file as ours, so a foreign database is not initialised over.
const application_id: u32 = 0x5a43_5542;

const schema_sql =
    \\CREATE TABLE store_meta (
    \\    id INTEGER PRIMARY KEY CHECK (id = 1),
    \\    revision INTEGER NOT NULL,
    \\    compacted_revision INTEGER NOT NULL
    \\);
    \\INSERT INTO store_meta (id, revision, compacted_revision) VALUES (1, 0, 0);
    \\CREATE TABLE store_log (
    \\    revision INTEGER NOT NULL,
    \\    idx INTEGER NOT NULL,
    \\    key BLOB NOT NULL,
    \\    deleted INTEGER NOT NULL,
    \\    value BLOB NOT NULL,
    \\    create_revision INTEGER NOT NULL,
    \\    lease INTEGER NOT NULL,
    \\    PRIMARY KEY (revision, idx)
    \\) WITHOUT ROWID;
    \\CREATE INDEX store_log_key ON store_log (key, revision);
    \\CREATE TABLE store_live (
    \\    key BLOB PRIMARY KEY,
    \\    value BLOB NOT NULL,
    \\    create_revision INTEGER NOT NULL,
    \\    mod_revision INTEGER NOT NULL,
    \\    lease INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\CREATE INDEX store_live_lease ON store_live (lease) WHERE lease <> 0;
    \\CREATE TABLE store_lease (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    ttl_ms INTEGER NOT NULL,
    \\    deadline_ms INTEGER NOT NULL
    \\);
++ std.fmt.comptimePrint(
    \\PRAGMA application_id = {d};
    \\PRAGMA user_version = {d};
, .{ application_id, schema_version });

// Every query returns the same leading columns, so one function reads a row into a `KeyValue`:
// key, value, create_revision, mod_revision, lease, deleted.
const sql_meta = "SELECT revision, compacted_revision FROM store_meta WHERE id = 1";
const sql_live_get =
    "SELECT key, value, create_revision, mod_revision, lease, 0 FROM store_live WHERE key = ?1";
const sql_log_get =
    \\SELECT key, value, create_revision, revision, lease, deleted FROM store_log
    \\WHERE key = ?1 AND revision <= ?2 ORDER BY revision DESC LIMIT 1
;
const sql_live_list =
    \\SELECT key, value, create_revision, mod_revision, lease, 0 FROM store_live
    \\WHERE key >= ?1 AND key > ?2 AND (?3 IS NULL OR key < ?3) ORDER BY key LIMIT ?4
;
const sql_log_list =
    \\SELECT l.key, l.value, l.create_revision, l.revision, l.lease, l.deleted
    \\FROM store_log l
    \\WHERE l.key >= ?1 AND l.key > ?2 AND (?3 IS NULL OR l.key < ?3) AND l.deleted = 0
    \\  AND l.revision = (SELECT MAX(n.revision) FROM store_log n
    \\                    WHERE n.key = l.key AND n.revision <= ?5)
    \\ORDER BY l.key LIMIT ?4
;
const sql_watch =
    \\SELECT key, value, create_revision, revision, lease, deleted FROM store_log
    \\WHERE revision >= ?1 AND key >= ?2 AND (?3 IS NULL OR key < ?3)
    \\ORDER BY revision, idx LIMIT ?4
;
const sql_live_mod = "SELECT mod_revision FROM store_live WHERE key = ?1";
const sql_live_head = "SELECT create_revision, lease FROM store_live WHERE key = ?1";
const sql_log_insert =
    \\INSERT INTO store_log (revision, idx, key, deleted, value, create_revision, lease)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
;
const sql_live_put =
    \\INSERT OR REPLACE INTO store_live (key, value, create_revision, mod_revision, lease)
    \\VALUES (?1, ?2, ?3, ?4, ?5)
;
const sql_live_delete = "DELETE FROM store_live WHERE key = ?1";
const sql_set_revision = "UPDATE store_meta SET revision = ?1 WHERE id = 1";
const sql_set_compacted = "UPDATE store_meta SET compacted_revision = ?1 WHERE id = 1";
const sql_lease_get = "SELECT deadline_ms, ttl_ms FROM store_lease WHERE id = ?1";
const sql_lease_count = "SELECT COUNT(*) FROM store_lease";
const sql_lease_insert = "INSERT INTO store_lease (ttl_ms, deadline_ms) VALUES (?1, ?2)";
const sql_lease_renew = "UPDATE store_lease SET deadline_ms = ?2 WHERE id = ?1";
const sql_lease_delete = "DELETE FROM store_lease WHERE id = ?1";
const sql_lease_keys = "SELECT key FROM store_live WHERE lease = ?1 ORDER BY key LIMIT ?2";
const sql_lease_held = "SELECT COUNT(*) FROM store_live WHERE lease = ?1";
const sql_lease_due = "SELECT id FROM store_lease WHERE deadline_ms < ?1 ORDER BY id LIMIT 1";
const sql_compact_batch =
    \\DELETE FROM store_log WHERE (revision, idx) IN (
    \\    SELECT l.revision, l.idx FROM store_log l
    \\    WHERE l.revision <= ?1 AND (l.deleted = 1 OR EXISTS (
    \\        SELECT 1 FROM store_log n
    \\        WHERE n.key = l.key AND n.revision > l.revision AND n.revision <= ?1))
    \\    ORDER BY l.revision, l.idx LIMIT ?2)
;

pub const Sync = enum { full, normal };

pub const OpenOptions = struct {
    /// Create and initialise the file if it does not exist. Without it, a missing file is an
    /// operating error (ZC-E0201), so a mistyped path does not quietly start an empty store.
    create: bool,
    /// `full` survives power loss; `normal` (WAL) can lose the last commits but never corrupts.
    /// Tests use `normal`.
    sync: Sync = .full,
    /// How long to wait for another connection's write lock before ZC-E0208.
    busy_ms: u32 = constants.store_sqlite_busy_ms,
};

const WatchSlot = struct {
    owner: *SqliteStore,
    used: bool,
    prefix: [constants.store_key_bytes_max]u8,
    prefix_len: u32,
    next_revision: Revision,
};

const Meta = struct {
    revision: Revision,
    compacted_revision: Revision,
};

/// The create revision and lease of a live key.
const Head = struct {
    create_revision: Revision,
    lease: LeaseId,
};

/// One row of `store_log`, as `log_event` writes it.
const LogRow = struct {
    revision: Revision,
    idx: u32,
    key: []const u8,
    deleted: bool,
    value: []const u8,
    create_revision: Revision,
    lease: LeaseId,
};

const LeaseRow = struct {
    deadline_ms: i64,
    ttl_ms: u32,
};

/// The keys of one lease, copied out so they can be deleted while the query is finished.
const LeaseKeys = struct {
    bytes: [constants.store_lease_keys_max][constants.store_key_bytes_max]u8,
    lens: [constants.store_lease_keys_max]u32,
    count: u32,

    fn key(keys: *const LeaseKeys, slot: u32) []const u8 {
        assert(slot < keys.count);
        return keys.bytes[slot][0..keys.lens[slot]];
    }
};

pub const SqliteStore = struct {
    io: std.Io,
    clock: Clock,
    mutex: std.Io.Mutex,
    db: *c.sqlite3,
    busy_ms: u32,
    path_buffer: [constants.state_path_bytes_max + 1]u8,
    path_len: u32,
    watches: [constants.store_watches_max]WatchSlot,

    const vtable: store.Store.VTable = .{
        .status = status_impl,
        .get = get_impl,
        .list = list_impl,
        .txn = txn_impl,
        .watch = watch_impl,
        .lease_grant = lease_grant_impl,
        .lease_keepalive = lease_keepalive_impl,
        .lease_revoke = lease_revoke_impl,
        .expire_leases = expire_leases_impl,
        .compact = compact_impl,
    };

    const watch_vtable: store.Watch.WatchVTable = .{
        .next = watch_next_impl,
        .close = watch_close_impl,
    };

    /// Opens the file, enables WAL and checks (or, with `create`, writes) the schema. Initialises
    /// `self` in place: watches point back at the store, so it must not move afterwards. On error
    /// the store is not open and `close` must not be called.
    pub fn open(
        self: *SqliteStore,
        io: std.Io,
        clock: Clock,
        file_path: []const u8,
        options: OpenOptions,
        diag: *Diag,
    ) Error!void {
        assert(diag.code == null);
        assert(file_path.len > 0);
        if (file_path.len > constants.state_path_bytes_max) {
            return fail_path_too_long(diag, file_path);
        }
        self.io = io;
        self.clock = clock;
        self.mutex = .init;
        self.busy_ms = options.busy_ms;
        @memcpy(self.path_buffer[0..file_path.len], file_path);
        self.path_buffer[file_path.len] = 0;
        self.path_len = @intCast(file_path.len);
        for (&self.watches) |*slot| slot.used = false;
        try self.open_database(options.create, diag);
        errdefer _ = c.sqlite3_close(self.db);
        try self.configure(options.sync, diag);
        try self.ensure_schema(options.create, diag);
        assert(self.path().len == file_path.len);
    }

    /// Closes the connection. All watches must be closed first.
    pub fn close(self: *SqliteStore) void {
        for (self.watches) |slot| assert(!slot.used);
        const rc = c.sqlite3_close(self.db);
        assert(rc == c.SQLITE_OK); // Every statement is finalised before its function returns.
        self.* = undefined;
    }

    pub fn interface(self: *SqliteStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *SqliteStore {
        return @ptrCast(@alignCast(context));
    }

    fn lock(self: *SqliteStore) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *SqliteStore) void {
        self.mutex.unlock(self.io);
    }

    fn path(self: *const SqliteStore) []const u8 {
        assert(self.path_len > 0);
        return self.path_buffer[0..self.path_len];
    }

    fn now_ms(self: *const SqliteStore) i64 {
        const now = self.clock.now_ms();
        assert(now <= std.math.maxInt(i64));
        return @intCast(now);
    }

    // ---- Opening -------------------------------------------------------------------------

    fn open_database(self: *SqliteStore, create: bool, diag: *Diag) Error!void {
        var flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX;
        if (create) flags |= c.SQLITE_OPEN_CREATE;
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(&self.path_buffer, &handle, flags, null);
        if (rc != c.SQLITE_OK) {
            const message = if (handle) |h| errmsg(h) else std.mem.sliceTo(c.sqlite3_errstr(rc), 0);
            const failure = fail(diag, self.path(), self.busy_ms, rc, message);
            if (handle) |h| _ = c.sqlite3_close(h); // After `fail` has copied the message.
            return failure;
        }
        self.db = handle.?;
        const timeout_rc = c.sqlite3_busy_timeout(self.db, @intCast(self.busy_ms));
        assert(timeout_rc == c.SQLITE_OK);
    }

    fn configure(self: *SqliteStore, sync: Sync, diag: *Diag) Error!void {
        {
            var stmt = try self.prepare("PRAGMA journal_mode = WAL", diag);
            defer stmt.finalize();
            if (!(try stmt.step(diag))) return self.fail_damaged(diag, "gave no journal mode");
            if (!std.ascii.eqlIgnoreCase(stmt.blob(0), "wal")) {
                return self.fail_no_wal(diag, stmt.blob(0));
            }
        }
        switch (sync) {
            .full => try self.exec("PRAGMA synchronous = FULL", diag),
            .normal => try self.exec("PRAGMA synchronous = NORMAL", diag),
        }
    }

    /// Reads the file's identity under the write lock, so two connections opening a new file
    /// at once initialise it once. Initialises an empty file only when asked to.
    fn ensure_schema(self: *SqliteStore, create: bool, diag: *Diag) Error!void {
        try self.begin_write(diag);
        errdefer self.rollback();
        const app = try self.pragma_value("PRAGMA application_id", diag);
        const version = try self.pragma_value("PRAGMA user_version", diag);
        const tables = try self.pragma_value("SELECT COUNT(*) FROM sqlite_master", diag);
        if (app == application_id) {
            if (version > schema_version) return self.fail_too_new(@intCast(version), diag);
            if (version != schema_version) return self.fail_damaged(diag, "has no schema version");
        } else if (app == 0 and version == 0 and tables == 0) {
            if (!create) return self.fail_damaged(diag, "is empty and was not asked to be created");
            try self.exec(schema_sql, diag);
        } else {
            return self.fail_damaged(diag, "belongs to another application");
        }
        try self.commit(diag);
    }

    fn pragma_value(self: *SqliteStore, comptime sql: [:0]const u8, diag: *Diag) Error!i64 {
        var stmt = try self.prepare(sql, diag);
        defer stmt.finalize();
        if (!(try stmt.step(diag))) return self.fail_damaged(diag, "gave no answer to a query");
        return stmt.int(0);
    }

    // ---- SQLite plumbing -----------------------------------------------------------------

    fn prepare(self: *SqliteStore, comptime sql: [:0]const u8, diag: *Diag) Error!Stmt {
        var raw: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &raw, null);
        if (rc != c.SQLITE_OK) return self.fail_rc(diag, rc);
        return .{ .owner = self, .raw = raw.?, .bind_rc = c.SQLITE_OK };
    }

    fn exec(self: *SqliteStore, comptime sql: [:0]const u8, diag: *Diag) Error!void {
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return self.fail_rc(diag, rc);
    }

    fn begin_write(self: *SqliteStore, diag: *Diag) Error!void {
        try self.exec("BEGIN IMMEDIATE", diag);
    }

    fn begin_read(self: *SqliteStore, diag: *Diag) Error!void {
        try self.exec("BEGIN", diag);
    }

    fn commit(self: *SqliteStore, diag: *Diag) Error!void {
        try self.exec("COMMIT", diag);
    }

    /// Ends the transaction without keeping anything. Harmless when none is open, and it cannot
    /// meaningfully fail, so its result is ignored.
    fn rollback(self: *SqliteStore) void {
        _ = c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
    }

    fn fail_rc(self: *SqliteStore, diag: *Diag, rc: c_int) error{BackendFailed} {
        return fail(diag, self.path(), self.busy_ms, rc, errmsg(self.db));
    }

    fn fail_damaged(
        self: *SqliteStore,
        diag: *Diag,
        comptime what: []const u8,
    ) error{BackendFailed} {
        assert(diag.code == null);
        diag.raise(.E0209);
        diag.cause("the store file " ++ what, .{});
        diag.fix(.{ .sentence = "restore the file from a backup, or point the server at another" });
        diag.context("path", "{s}", .{self.path()});
        return error.BackendFailed;
    }

    fn fail_no_wal(self: *SqliteStore, diag: *Diag, mode: []const u8) error{BackendFailed} {
        assert(diag.code == null);
        diag.raise(.E0202);
        diag.cause("SQLite chose journal mode '{s}' instead of WAL", .{mode});
        diag.cause("the file system under the store file has no write-ahead logging", .{});
        diag.fix(.{ .sentence = "put the store file on a local disk (not a network share)" });
        diag.context("path", "{s}", .{self.path()});
        return error.BackendFailed;
    }

    fn fail_too_new(self: *SqliteStore, diag_version: u32, diag: *Diag) error{BackendFailed} {
        assert(diag.code == null);
        assert(diag_version > schema_version);
        diag.raise(.E0210);
        diag.cause("the store file has schema version {d}; this zcube understands up to {d}", .{
            diag_version, schema_version,
        });
        diag.fix(.{ .sentence = "run the zcube version that created the file, or upgrade zcube" });
        diag.context("path", "{s}", .{self.path()});
        return error.BackendFailed;
    }

    // ---- Reads ---------------------------------------------------------------------------

    fn read_meta(self: *SqliteStore, diag: *Diag) Error!Meta {
        var stmt = try self.prepare(sql_meta, diag);
        defer stmt.finalize();
        if (!(try stmt.step(diag))) return self.fail_damaged(diag, "has no revision record");
        const meta: Meta = .{
            .revision = stmt.unsigned(0),
            .compacted_revision = stmt.unsigned(1),
        };
        if (meta.compacted_revision > meta.revision) {
            return self.fail_damaged(diag, "records a compaction point above its revision");
        }
        return meta;
    }

    fn status_impl(context: *anyopaque, diag: *Diag) Error!store.Status {
        const self = from(context);
        self.lock();
        defer self.unlock();
        const meta = try self.read_meta(diag); // One statement: its own snapshot.
        return .{ .revision = meta.revision, .compacted_revision = meta.compacted_revision };
    }

    fn get_impl(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?Revision,
        diag: *Diag,
    ) Error!store.GetResult {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_read(diag);
        defer self.rollback();
        const meta = try self.read_meta(diag);
        const revision = at_revision orelse meta.revision;
        try check_readable(meta, revision, diag);
        const kv = if (at_revision == null)
            try self.live_get(arena, key, diag)
        else
            try self.log_get(arena, key, revision, diag);
        return .{ .kv = kv, .revision = revision };
    }

    fn live_get(
        self: *SqliteStore,
        arena: Allocator,
        key: []const u8,
        diag: *Diag,
    ) Error!?store.KeyValue {
        var stmt = try self.prepare(sql_live_get, diag);
        defer stmt.finalize();
        stmt.bind_bytes(1, key);
        if (!(try stmt.step(diag))) return null;
        return try row_kv(&stmt, arena, diag);
    }

    /// The key as the log last had it at or before `revision`; a tombstone means absent.
    fn log_get(
        self: *SqliteStore,
        arena: Allocator,
        key: []const u8,
        revision: Revision,
        diag: *Diag,
    ) Error!?store.KeyValue {
        var stmt = try self.prepare(sql_log_get, diag);
        defer stmt.finalize();
        stmt.bind_bytes(1, key);
        stmt.bind_unsigned(2, revision);
        if (!(try stmt.step(diag))) return null;
        if (stmt.int(5) != 0) return null;
        return try row_kv(&stmt, arena, diag);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) Error!store.ListResult {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_read(diag);
        defer self.rollback();
        const meta = try self.read_meta(diag);
        const revision = options.at_revision orelse meta.revision;
        try check_readable(meta, revision, diag);
        var stmt = if (options.at_revision == null)
            try self.prepare(sql_live_list, diag)
        else
            try self.prepare(sql_log_list, diag);
        defer stmt.finalize();
        var end_buffer: [constants.store_key_bytes_max]u8 = undefined;
        stmt.bind_bytes(1, options.prefix);
        stmt.bind_bytes(2, options.continue_after orelse "");
        stmt.bind_optional(3, prefix_end(&end_buffer, options.prefix));
        stmt.bind_unsigned(4, @as(u64, options.limit) + 1); // One more tells if a page follows.
        if (options.at_revision != null) stmt.bind_unsigned(5, revision);
        const page = try collect_page(&stmt, arena, options.limit, diag);
        return .{ .kvs = page.kvs, .revision = revision, .continue_after = page.continue_after };
    }

    // ---- Transactions --------------------------------------------------------------------

    fn txn_impl(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) Error!store.TxnResult {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_write(diag);
        errdefer self.rollback();
        const meta = try self.read_meta(diag);
        const succeeded = try self.compares_hold(request.compares, diag);
        const ops = if (succeeded) request.on_success else request.on_failure;
        try self.check_leases(ops, diag);
        const revision = meta.revision + 1;
        var events: u32 = 0;
        for (ops) |op| {
            if (try self.apply_op(op, revision, events, diag)) events += 1;
        }
        if (events == 0) {
            self.rollback(); // Nothing changed: no revision is taken.
            return .{ .succeeded = succeeded, .revision = meta.revision };
        }
        try self.set_revision(revision, diag);
        try self.commit(diag);
        return .{ .succeeded = succeeded, .revision = revision };
    }

    fn compares_hold(
        self: *SqliteStore,
        compares: []const store.Compare,
        diag: *Diag,
    ) Error!bool {
        assert(compares.len <= constants.store_txn_compares_max);
        var holds = true;
        for (compares) |compare| {
            var stmt = try self.prepare(sql_live_mod, diag);
            defer stmt.finalize();
            stmt.bind_bytes(1, compare.key);
            const current: Revision = if (try stmt.step(diag)) stmt.unsigned(0) else 0;
            if (current != compare.mod_revision) holds = false;
        }
        return holds;
    }

    /// Every lease a put names must be alive, and no lease may end up with too many keys.
    /// Checked before anything is applied, so a refusal leaves the store untouched.
    fn check_leases(self: *SqliteStore, ops: []const store.Op, diag: *Diag) Error!void {
        for (ops, 0..) |op, index| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (put.lease == store.lease_none) continue;
            if (names_lease(ops[0..index], put.lease)) continue; // Checked at its first put.
            if (!(try self.lease_alive(put.lease, diag))) {
                return failures.lease_not_found(diag, put.lease);
            }
            const count = try self.lease_key_count(put.lease, ops, diag);
            if (count > constants.store_lease_keys_max) {
                return failures.lease_keys_full(diag, put.lease, count);
            }
        }
    }

    /// How many keys the lease holds once `ops` is applied: those it holds now, less the ones
    /// `ops` moves off it, plus the ones `ops` puts on it.
    fn lease_key_count(
        self: *SqliteStore,
        lease: LeaseId,
        ops: []const store.Op,
        diag: *Diag,
    ) Error!u32 {
        var stmt = try self.prepare(sql_lease_held, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, lease);
        if (!(try stmt.step(diag))) return self.fail_damaged(diag, "gave no key count");
        var count: u32 = @intCast(stmt.unsigned(0));
        for (ops) |op| {
            const head = try self.live_head(store.op_key(op), diag);
            const was_on = if (head) |h| h.lease == lease else false;
            const now_on = switch (op) {
                .put => |put| put.lease == lease,
                .delete => false,
            };
            if (was_on and !now_on) count -= 1;
            if (!was_on and now_on) count += 1;
        }
        return count;
    }

    fn lease_row(self: *SqliteStore, id: LeaseId, diag: *Diag) Error!?LeaseRow {
        var stmt = try self.prepare(sql_lease_get, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, id);
        if (!(try stmt.step(diag))) return null;
        const ttl_ms = stmt.int(1);
        assert(ttl_ms >= constants.lease_ttl_ms_min);
        assert(ttl_ms <= constants.lease_ttl_ms_max);
        return .{ .deadline_ms = stmt.int(0), .ttl_ms = @intCast(ttl_ms) };
    }

    /// A lease is alive until its deadline has passed, reaped or not.
    fn lease_alive(self: *SqliteStore, id: LeaseId, diag: *Diag) Error!bool {
        const row = (try self.lease_row(id, diag)) orelse return false;
        return self.now_ms() <= row.deadline_ms;
    }

    fn live_head(self: *SqliteStore, key: []const u8, diag: *Diag) Error!?Head {
        var stmt = try self.prepare(sql_live_head, diag);
        defer stmt.finalize();
        stmt.bind_bytes(1, key);
        if (!(try stmt.step(diag))) return null;
        return .{ .create_revision = stmt.unsigned(0), .lease = stmt.unsigned(1) };
    }

    /// Applies one op under `revision`. True if it produced an event (a delete of an absent
    /// key does not).
    fn apply_op(
        self: *SqliteStore,
        op: store.Op,
        revision: Revision,
        idx: u32,
        diag: *Diag,
    ) Error!bool {
        assert(revision > 0);
        assert(idx < constants.store_watch_batch_max);
        switch (op) {
            .put => |put| {
                try self.apply_put(put, revision, idx, diag);
                return true;
            },
            .delete => |key| return self.apply_delete(key, revision, idx, diag),
        }
    }

    fn apply_put(
        self: *SqliteStore,
        put: store.Put,
        revision: Revision,
        idx: u32,
        diag: *Diag,
    ) Error!void {
        const head = try self.live_head(put.key, diag);
        const create_revision = if (head) |h| h.create_revision else revision;
        try self.log_event(.{
            .revision = revision,
            .idx = idx,
            .key = put.key,
            .deleted = false,
            .value = put.value,
            .create_revision = create_revision,
            .lease = put.lease,
        }, diag);
        var stmt = try self.prepare(sql_live_put, diag);
        defer stmt.finalize();
        stmt.bind_bytes(1, put.key);
        stmt.bind_bytes(2, put.value);
        stmt.bind_unsigned(3, create_revision);
        stmt.bind_unsigned(4, revision);
        stmt.bind_unsigned(5, put.lease);
        try stmt.run(diag);
    }

    fn apply_delete(
        self: *SqliteStore,
        key: []const u8,
        revision: Revision,
        idx: u32,
        diag: *Diag,
    ) Error!bool {
        const head = (try self.live_head(key, diag)) orelse return false;
        try self.log_event(.{
            .revision = revision,
            .idx = idx,
            .key = key,
            .deleted = true,
            .value = "",
            .create_revision = head.create_revision,
            .lease = head.lease,
        }, diag);
        var stmt = try self.prepare(sql_live_delete, diag);
        defer stmt.finalize();
        stmt.bind_bytes(1, key);
        try stmt.run(diag);
        return true;
    }

    fn log_event(self: *SqliteStore, row: LogRow, diag: *Diag) Error!void {
        assert(row.revision > 0);
        assert(row.create_revision <= row.revision);
        var stmt = try self.prepare(sql_log_insert, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, row.revision);
        stmt.bind_unsigned(2, row.idx);
        stmt.bind_bytes(3, row.key);
        stmt.bind_unsigned(4, @intFromBool(row.deleted));
        stmt.bind_bytes(5, row.value);
        stmt.bind_unsigned(6, row.create_revision);
        stmt.bind_unsigned(7, row.lease);
        try stmt.run(diag);
    }

    fn set_revision(self: *SqliteStore, revision: Revision, diag: *Diag) Error!void {
        assert(revision > 0);
        var stmt = try self.prepare(sql_set_revision, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, revision);
        try stmt.run(diag);
    }

    // ---- Watch ---------------------------------------------------------------------------

    fn watch_impl(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) Error!store.Watch {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_read(diag);
        defer self.rollback();
        const meta = try self.read_meta(diag);
        if (options.from_revision <= meta.compacted_revision) {
            return failures.compacted(diag, options.from_revision, meta.compacted_revision);
        }
        if (options.from_revision > meta.revision + 1) {
            return failures.future_watch(diag, options.from_revision, meta.revision);
        }
        for (&self.watches) |*slot| {
            if (slot.used) continue;
            slot.owner = self;
            slot.used = true;
            slot.prefix_len = @intCast(options.prefix.len);
            @memcpy(slot.prefix[0..options.prefix.len], options.prefix);
            slot.next_revision = options.from_revision;
            return .{
                .context = slot,
                .vtable = &watch_vtable,
                .delivered = options.from_revision - 1,
            };
        }
        return failures.watch_slots_full(diag);
    }

    /// Re-reads the log until events appear or `timeout_ms` has passed. The wait is a sleep
    /// outside the mutex, so a waiting watch never holds up a writer.
    fn watch_next_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) Error!store.WatchBatch {
        const slot: *WatchSlot = @ptrCast(@alignCast(context));
        const self = slot.owner;
        const started = std.Io.Clock.awake.now(self.io);
        while (true) { // Ends with events, with the timeout, or with an error.
            const batch = try self.poll_once(slot, arena, diag);
            if (batch.events.len > 0) return batch;
            const now = std.Io.Clock.awake.now(self.io);
            const waited_ms = started.durationTo(now).toMilliseconds();
            if (waited_ms >= timeout_ms) return batch;
            const left_ms: u32 = timeout_ms - @as(u32, @intCast(waited_ms));
            const nap_ms: u32 = @min(left_ms, constants.store_watch_poll_ms);
            self.io.sleep(.fromMilliseconds(nap_ms), .awake) catch return batch;
        }
    }

    /// One read of the log from the watch's position, in one snapshot with the revision it
    /// reports as the bookmark. A batch never splits a revision: when the row limit cuts one
    /// in half, that revision is held back whole for the next call.
    fn poll_once(
        self: *SqliteStore,
        slot: *WatchSlot,
        arena: Allocator,
        diag: *Diag,
    ) Error!store.WatchBatch {
        self.lock();
        defer self.unlock();
        assert(slot.used);
        try self.begin_read(diag);
        defer self.rollback();
        const meta = try self.read_meta(diag);
        if (slot.next_revision <= meta.compacted_revision) {
            return failures.compacted(diag, slot.next_revision, meta.compacted_revision);
        }
        var stmt = try self.prepare(sql_watch, diag);
        defer stmt.finalize();
        var end_buffer: [constants.store_key_bytes_max]u8 = undefined;
        stmt.bind_unsigned(1, slot.next_revision);
        stmt.bind_bytes(2, slot.prefix[0..slot.prefix_len]);
        stmt.bind_optional(3, prefix_end(&end_buffer, slot.prefix[0..slot.prefix_len]));
        stmt.bind_unsigned(4, @as(u64, constants.store_watch_batch_max) + 1);
        var events: std.ArrayList(store.Event) = .empty;
        var held_back: ?Revision = null;
        while (try stmt.step(diag)) {
            if (events.items.len == constants.store_watch_batch_max) {
                held_back = stmt.unsigned(3);
                break;
            }
            const event = try row_event(&stmt, arena, diag);
            events.append(arena, event) catch return failures.no_memory(diag);
        }
        var bookmark = meta.revision; // Caught up: everything to the snapshot's head is here.
        if (held_back) |revision| {
            bookmark = revision - 1;
            drop_revision(&events, revision);
        }
        assert(bookmark >= slot.next_revision - 1);
        slot.next_revision = bookmark + 1;
        return .{ .events = events.items, .revision = bookmark };
    }

    fn watch_close_impl(context: *anyopaque) void {
        const slot: *WatchSlot = @ptrCast(@alignCast(context));
        slot.owner.lock();
        defer slot.owner.unlock();
        assert(slot.used);
        slot.used = false;
    }

    // ---- Leases --------------------------------------------------------------------------

    fn lease_grant_impl(context: *anyopaque, ttl_ms: u32, diag: *Diag) Error!store.Lease {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_write(diag);
        errdefer self.rollback();
        var count_stmt = try self.prepare(sql_lease_count, diag);
        defer count_stmt.finalize();
        if (!(try count_stmt.step(diag))) return self.fail_damaged(diag, "gave no lease count");
        if (count_stmt.unsigned(0) >= constants.store_leases_max) {
            return failures.lease_slots_full(diag);
        }
        var stmt = try self.prepare(sql_lease_insert, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, ttl_ms);
        stmt.bind_unsigned(2, @intCast(self.now_ms() + ttl_ms));
        try stmt.run(diag);
        const id: LeaseId = @intCast(c.sqlite3_last_insert_rowid(self.db));
        try self.commit(diag);
        return .{ .id = id, .ttl_ms = ttl_ms };
    }

    fn lease_keepalive_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!store.Lease {
        const self = from(context);
        self.lock();
        defer self.unlock();
        try self.begin_write(diag);
        errdefer self.rollback();
        const row = (try self.lease_row(id, diag)) orelse return failures.lease_not_found(diag, id);
        if (self.now_ms() > row.deadline_ms) return failures.lease_not_found(diag, id);
        var stmt = try self.prepare(sql_lease_renew, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, id);
        stmt.bind_unsigned(2, @intCast(self.now_ms() + row.ttl_ms));
        try stmt.run(diag);
        try self.commit(diag);
        return .{ .id = id, .ttl_ms = row.ttl_ms };
    }

    fn lease_revoke_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!Revision {
        const self = from(context);
        self.lock();
        defer self.unlock();
        return self.revoke_locked(id, diag);
    }

    /// Ends the lease and deletes its keys under one revision (the mutex is held).
    fn revoke_locked(self: *SqliteStore, id: LeaseId, diag: *Diag) Error!Revision {
        try self.begin_write(diag);
        errdefer self.rollback();
        const meta = try self.read_meta(diag);
        if ((try self.lease_row(id, diag)) == null) return failures.lease_not_found(diag, id);
        var keys: LeaseKeys = undefined;
        try self.collect_lease_keys(id, &keys, diag);
        const revision = meta.revision + 1;
        for (0..keys.count) |slot| {
            const idx: u32 = @intCast(slot);
            const deleted = try self.apply_delete(keys.key(idx), revision, idx, diag);
            assert(deleted); // The keys were read in this transaction, under the write lock.
        }
        var stmt = try self.prepare(sql_lease_delete, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, id);
        try stmt.run(diag);
        if (keys.count > 0) try self.set_revision(revision, diag);
        try self.commit(diag);
        return if (keys.count > 0) revision else meta.revision;
    }

    fn collect_lease_keys(
        self: *SqliteStore,
        id: LeaseId,
        keys: *LeaseKeys,
        diag: *Diag,
    ) Error!void {
        var stmt = try self.prepare(sql_lease_keys, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, id);
        stmt.bind_unsigned(2, @as(u64, constants.store_lease_keys_max) + 1);
        keys.count = 0;
        while (try stmt.step(diag)) {
            if (keys.count == constants.store_lease_keys_max) {
                return self.fail_damaged(diag, "holds more keys on one lease than allowed");
            }
            const key = stmt.blob(0);
            @memcpy(keys.bytes[keys.count][0..key.len], key);
            keys.lens[keys.count] = @intCast(key.len);
            keys.count += 1;
        }
    }

    fn expire_leases_impl(context: *anyopaque, diag: *Diag) Error!u32 {
        const self = from(context);
        self.lock();
        defer self.unlock();
        var expired: u32 = 0;
        // Each pass removes one lease, so the loop ends; the bound is the most leases there are.
        for (0..constants.store_leases_max) |_| {
            const id = (try self.next_due_lease(diag)) orelse break;
            _ = self.revoke_locked(id, diag) catch |err| switch (err) {
                // Another connection revoked it between the query and the write lock.
                error.LeaseNotFound => {
                    diag.reset();
                    continue;
                },
                else => return err,
            };
            expired += 1;
        }
        return expired;
    }

    fn next_due_lease(self: *SqliteStore, diag: *Diag) Error!?LeaseId {
        var stmt = try self.prepare(sql_lease_due, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, @intCast(self.now_ms()));
        if (!(try stmt.step(diag))) return null;
        return stmt.unsigned(0);
    }

    // ---- Compaction ----------------------------------------------------------------------

    /// First lowers the floor (an instant, one write), so older reads fail at once; then prunes
    /// the log in bounded batches, letting other writers in between.
    fn compact_impl(context: *anyopaque, revision: Revision, diag: *Diag) Error!void {
        const self = from(context);
        self.lock();
        defer self.unlock();
        if (!(try self.mark_compacted(revision, diag))) return;
        // Each batch deletes at least one row or ends the loop, so it ends.
        while (true) {
            const deleted = try self.prune_batch(revision, diag);
            if (deleted < constants.store_compact_batch_rows) break;
        }
    }

    /// False if there is nothing to do: `revision` is at or below the compaction point.
    fn mark_compacted(self: *SqliteStore, revision: Revision, diag: *Diag) Error!bool {
        try self.begin_write(diag);
        errdefer self.rollback();
        const meta = try self.read_meta(diag);
        if (revision > meta.revision) return failures.future_compact(diag, revision, meta.revision);
        if (revision <= meta.compacted_revision) {
            self.rollback();
            return false;
        }
        var stmt = try self.prepare(sql_set_compacted, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, revision);
        try stmt.run(diag);
        try self.commit(diag);
        return true;
    }

    /// Keeps the latest put per key at or below `revision` and everything above it.
    fn prune_batch(self: *SqliteStore, revision: Revision, diag: *Diag) Error!u32 {
        try self.begin_write(diag);
        errdefer self.rollback();
        var stmt = try self.prepare(sql_compact_batch, diag);
        defer stmt.finalize();
        stmt.bind_unsigned(1, revision);
        stmt.bind_unsigned(2, constants.store_compact_batch_rows);
        try stmt.run(diag);
        const deleted: u32 = @intCast(c.sqlite3_changes(self.db));
        try self.commit(diag);
        assert(deleted <= constants.store_compact_batch_rows);
        return deleted;
    }
};

/// A prepared statement and its binds. A bind that fails is remembered and reported by the next
/// `step`, so a call site binds without an error path of its own. Text is bound as a blob by
/// reference (`SQLITE_STATIC`): every statement is stepped and finalised before the function
/// that owns the bound memory returns.
const Stmt = struct {
    owner: *SqliteStore,
    raw: *c.sqlite3_stmt,
    bind_rc: c_int,

    fn finalize(stmt: *Stmt) void {
        _ = c.sqlite3_finalize(stmt.raw); // Its result repeats the last step's, already reported.
        stmt.* = undefined;
    }

    fn note(stmt: *Stmt, rc: c_int) void {
        if (stmt.bind_rc == c.SQLITE_OK) stmt.bind_rc = rc;
    }

    fn bind_bytes(stmt: *Stmt, index: c_int, bytes: []const u8) void {
        const rc = if (bytes.len == 0)
            c.sqlite3_bind_zeroblob(stmt.raw, index, 0) // A null pointer would bind NULL.
        else
            c.sqlite3_bind_blob64(stmt.raw, index, bytes.ptr, bytes.len, null);
        stmt.note(rc);
    }

    fn bind_optional(stmt: *Stmt, index: c_int, bytes: ?[]const u8) void {
        if (bytes) |present| {
            stmt.bind_bytes(index, present);
        } else {
            stmt.note(c.sqlite3_bind_null(stmt.raw, index));
        }
    }

    fn bind_unsigned(stmt: *Stmt, index: c_int, value: u64) void {
        assert(value <= std.math.maxInt(i64));
        stmt.note(c.sqlite3_bind_int64(stmt.raw, index, @intCast(value)));
    }

    /// True if a row is ready, false when the statement is done.
    fn step(stmt: *Stmt, diag: *Diag) Error!bool {
        if (stmt.bind_rc != c.SQLITE_OK) return stmt.owner.fail_rc(diag, stmt.bind_rc);
        const rc = c.sqlite3_step(stmt.raw);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return stmt.owner.fail_rc(diag, rc);
    }

    /// For a statement that produces no rows.
    fn run(stmt: *Stmt, diag: *Diag) Error!void {
        const row = try stmt.step(diag);
        assert(!row);
    }

    fn int(stmt: *const Stmt, column: c_int) i64 {
        return c.sqlite3_column_int64(stmt.raw, column);
    }

    fn unsigned(stmt: *const Stmt, column: c_int) u64 {
        const value = stmt.int(column);
        assert(value >= 0);
        return @intCast(value);
    }

    /// The column's bytes, valid until the next step or finalize.
    fn blob(stmt: *const Stmt, column: c_int) []const u8 {
        const pointer = c.sqlite3_column_blob(stmt.raw, column);
        const length: usize = @intCast(c.sqlite3_column_bytes(stmt.raw, column));
        if (length == 0) return &.{};
        return @as([*]const u8, @ptrCast(pointer.?))[0..length];
    }
};

fn errmsg(db: *c.sqlite3) []const u8 {
    return std.mem.sliceTo(c.sqlite3_errmsg(db), 0);
}

// ---- Failures --------------------------------------------------------------------------------

pub const Class = enum { busy, damaged, cannot_open, failed };

/// Which diagnostic a SQLite result code becomes. Extended codes share their primary's low byte.
pub fn classify(rc: c_int) Class {
    assert(rc != c.SQLITE_OK);
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => .busy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => .damaged,
        c.SQLITE_CANTOPEN => .cannot_open,
        else => .failed,
    };
}

/// Turns a SQLite failure into a diagnostic. The raw message and code come first in the cause
/// chain; the last cause, which default output shows, says what to the operator it means.
fn fail(
    diag: *Diag,
    file_path: []const u8,
    busy_ms: u32,
    rc: c_int,
    message: []const u8,
) error{BackendFailed} {
    assert(diag.code == null);
    const class = classify(rc);
    switch (class) {
        .busy => diag.raise(.E0208),
        .damaged => diag.raise(.E0209),
        .cannot_open => diag.raise(.E0201),
        .failed => diag.raise(.E0202),
    }
    diag.cause("SQLite reported: {s} (result code {d})", .{ message, rc });
    switch (class) {
        .busy => {
            diag.cause("another connection held the write lock for over {d} ms", .{busy_ms});
            diag.fix(.{ .sentence = "stop whatever else uses the store file, then retry" });
        },
        .damaged => {
            diag.cause("the store file is damaged or is not a zcube store", .{});
            diag.fix(.{ .sentence = "restore the file from a backup, or use another path" });
        },
        .cannot_open => {
            diag.cause("the store file can't be opened or created", .{});
            diag.fix(.{ .sentence = "check the store path, that its directory exists and that" ++
                " the server may read and write it" });
        },
        .failed => {
            diag.cause("{s}", .{failed_cause(rc & 0xff)});
            diag.fix(.{ .sentence = "fix that condition, then retry; nothing was changed" });
        },
    }
    diag.context("path", "{s}", .{file_path});
    return error.BackendFailed;
}

fn failed_cause(primary: c_int) []const u8 {
    return switch (primary) {
        c.SQLITE_READONLY => "the store file or its directory can't be written to",
        c.SQLITE_FULL => "the disk holding the store file is full",
        c.SQLITE_IOERR => "the file system reported an I/O error on the store file",
        else => "the database refused the operation",
    };
}

fn fail_path_too_long(diag: *Diag, file_path: []const u8) error{BackendFailed} {
    assert(diag.code == null);
    assert(file_path.len > constants.state_path_bytes_max);
    diag.raise(.E0201);
    diag.cause("the store path is {d} bytes; the limit is {d}", .{
        file_path.len, constants.state_path_bytes_max,
    });
    diag.fix(.{ .sentence = "use a shorter path for the store file" });
    return error.BackendFailed;
}

// ---- Helpers ---------------------------------------------------------------------------------

fn check_readable(meta: Meta, revision: Revision, diag: *Diag) Error!void {
    if (revision > meta.revision) return failures.future_read(diag, revision, meta.revision);
    if (revision < meta.compacted_revision) {
        return failures.compacted(diag, revision, meta.compacted_revision);
    }
}

/// True if an op in `ops` is a put on `lease`.
fn names_lease(ops: []const store.Op, lease: LeaseId) bool {
    for (ops) |op| {
        switch (op) {
            .put => |put| if (put.lease == lease) return true,
            .delete => {},
        }
    }
    return false;
}

/// The smallest key that is greater than every key starting with `prefix`; null for the empty
/// prefix (no upper bound). Keys are printable ASCII, so the last byte can always be bumped.
fn prefix_end(buffer: *[constants.store_key_bytes_max]u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return null;
    @memcpy(buffer[0..prefix.len], prefix);
    const last = &buffer[prefix.len - 1];
    assert(last.* < 0x7f);
    last.* += 1;
    return buffer[0..prefix.len];
}

fn row_kv(stmt: *const Stmt, arena: Allocator, diag: *Diag) Error!store.KeyValue {
    const key = arena.dupe(u8, stmt.blob(0)) catch return failures.no_memory(diag);
    const value = arena.dupe(u8, stmt.blob(1)) catch return failures.no_memory(diag);
    return .{
        .key = key,
        .value = value,
        .create_revision = stmt.unsigned(2),
        .mod_revision = stmt.unsigned(3),
        .lease = stmt.unsigned(4),
    };
}

fn row_event(stmt: *const Stmt, arena: Allocator, diag: *Diag) Error!store.Event {
    const kind: store.EventKind = if (stmt.int(5) != 0) .delete else .put;
    return .{ .kind = kind, .kv = try row_kv(stmt, arena, diag) };
}

const Page = struct {
    kvs: []const store.KeyValue,
    continue_after: ?[]const u8,
};

/// Reads up to `limit` rows (the statement was bound with one more, to see if a page follows),
/// ending early once the values total a page's byte limit. The value of a row is measured
/// before it is copied, so a row that does not fit is never copied.
fn collect_page(stmt: *Stmt, arena: Allocator, limit: u32, diag: *Diag) Error!Page {
    var kvs: std.ArrayList(store.KeyValue) = .empty;
    var bytes: usize = 0;
    var more = false;
    while (try stmt.step(diag)) {
        const size = stmt.blob(1).len;
        const page_full = kvs.items.len > 0 and bytes + size > constants.store_page_bytes_max;
        if (kvs.items.len == limit or page_full) {
            more = true;
            break;
        }
        bytes += size;
        kvs.append(arena, try row_kv(stmt, arena, diag)) catch return failures.no_memory(diag);
    }
    assert(kvs.items.len <= limit);
    if (more) assert(kvs.items.len > 0);
    return .{
        .kvs = kvs.items,
        .continue_after = if (more) kvs.items[kvs.items.len - 1].key else null,
    };
}

/// Removes the trailing events of `revision`, which the row limit cut in half.
fn drop_revision(events: *std.ArrayList(store.Event), revision: Revision) void {
    while (events.items.len > 0) {
        if (events.items[events.items.len - 1].kv.mod_revision != revision) break;
        events.items.len -= 1;
    }
    assert(events.items.len > 0); // A revision holds at most 64 events; a batch holds 256.
}

// ---- Tests: failures and what only this backend can show --------------------------------------
// The behaviour every backend shares is checked by the conformance suite
// (`zig build test-store -Dbackend=sqlite`); these cover the file, the schema and the failures.

const testing = std.testing;
const codes = @import("diag/codes.zig");
const repeat = @import("test_util.zig").repeat;

const Fixture = struct {
    tmp: testing.TmpDir,
    manual: ManualClock,
    diag: Diag,
    path_buffer: [160]u8,
    path_len: u32,

    fn create() !*Fixture {
        const fixture = try testing.allocator.create(Fixture);
        fixture.tmp = testing.tmpDir(.{});
        fixture.manual = .{};
        fixture.diag.reset();
        const format = ".zig-cache/tmp/{s}/s.db";
        const sub_path = fixture.tmp.sub_path;
        const text = try std.fmt.bufPrintSentinel(&fixture.path_buffer, format, .{sub_path}, 0);
        fixture.path_len = @intCast(text.len);
        return fixture;
    }

    fn destroy(fixture: *Fixture) void {
        fixture.tmp.cleanup();
        testing.allocator.destroy(fixture);
    }

    fn path(fixture: *const Fixture) [:0]const u8 {
        return fixture.path_buffer[0..fixture.path_len :0];
    }

    fn open(fixture: *Fixture, db: *SqliteStore, open_options: OpenOptions) Error!void {
        const clock = fixture.manual.clock();
        return db.open(testing.io, clock, fixture.path(), open_options, &fixture.diag);
    }

    /// A new, opened store; the caller closes and frees it.
    fn open_new(fixture: *Fixture, open_options: OpenOptions) !*SqliteStore {
        const db = try testing.allocator.create(SqliteStore);
        errdefer testing.allocator.destroy(db);
        try fixture.open(db, open_options);
        return db;
    }

    /// The file's `user_version`, read with SQLite directly.
    fn raw_user_version(fixture: *const Fixture) !i64 {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY;
        const file = fixture.path().ptr;
        try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(file, &db, flags, null));
        defer _ = c.sqlite3_close(db);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "PRAGMA user_version";
        try testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        return c.sqlite3_column_int64(stmt, 0);
    }

    /// Runs SQL on the file with SQLite directly, as an outside tool would.
    fn raw_exec(fixture: *const Fixture, comptime sql: [:0]const u8) !void {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const file = fixture.path().ptr;
        try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(file, &db, flags, null));
        defer _ = c.sqlite3_close(db);
        try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, sql.ptr, null, null, null));
    }
};

fn release(db: *SqliteStore) void {
    db.close();
    testing.allocator.destroy(db);
}

/// A failure is a designed diagnostic: a registered code, a fix, and a last cause (the one that
/// default output shows) that carries no SQLite result code; the raw message, if any, is first.
fn expect_designed(diag: *const Diag, code: codes.Code) !void {
    try testing.expectEqual(code, diag.code.?);
    try testing.expect(diag.fixes.count >= 1);
    const last = diag.last_cause().?;
    try testing.expect(std.mem.indexOf(u8, last, "SQLITE") == null);
    try testing.expect(std.mem.indexOf(u8, last, "result code") == null);
    if (diag.causes.count > 1) {
        const first = diag.causes.slice()[0].slice();
        try testing.expect(std.mem.startsWith(u8, first, "SQLite reported:"));
    }
}

fn expect_open_fails(fixture: *Fixture, open_options: OpenOptions, code: codes.Code) !void {
    const db = try testing.allocator.create(SqliteStore);
    defer testing.allocator.destroy(db);
    try testing.expectError(error.BackendFailed, fixture.open(db, open_options));
    try expect_designed(&fixture.diag, code);
    fixture.diag.reset();
}

test "result codes become the right class of failure" {
    // Goal: the one mapping from SQLite's codes to diagnostics. Method: each primary code, and an
    // extended code, which carries its primary in the low byte.
    try testing.expectEqual(Class.busy, classify(c.SQLITE_BUSY));
    try testing.expectEqual(Class.busy, classify(c.SQLITE_BUSY | (1 << 8)));
    try testing.expectEqual(Class.busy, classify(c.SQLITE_LOCKED));
    try testing.expectEqual(Class.damaged, classify(c.SQLITE_CORRUPT));
    try testing.expectEqual(Class.damaged, classify(c.SQLITE_NOTADB));
    try testing.expectEqual(Class.cannot_open, classify(c.SQLITE_CANTOPEN));
    try testing.expectEqual(Class.failed, classify(c.SQLITE_IOERR | (2 << 8)));
    try testing.expectEqual(Class.failed, classify(c.SQLITE_FULL));
    try testing.expectEqual(Class.failed, classify(c.SQLITE_READONLY));
    try testing.expectEqual(Class.failed, classify(c.SQLITE_ERROR));
}

test "open: a missing file, a missing directory and an over-long path are ZC-E0201" {
    // Goal: a mistyped path does not quietly start an empty store. Method: open without
    // `create` on a missing file, with `create` in a directory that does not exist, and with a
    // path over the bound.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try expect_open_fails(fixture, .{ .create = false }, .E0201);
    const db = try testing.allocator.create(SqliteStore);
    defer testing.allocator.destroy(db);
    const missing_dir = "/zcube-no-such-directory/s.db";
    const clock = fixture.manual.clock();
    const opened = db.open(testing.io, clock, missing_dir, .{ .create = true }, &fixture.diag);
    try testing.expectError(error.BackendFailed, opened);
    try expect_designed(&fixture.diag, .E0201);
    fixture.diag.reset();
    const long = repeat('a', constants.state_path_bytes_max + 1);
    const refused = db.open(testing.io, clock, long, .{ .create = true }, &fixture.diag);
    try testing.expectError(error.BackendFailed, refused);
    try expect_designed(&fixture.diag, .E0201);
}

test "open: a damaged, empty or foreign file is ZC-E0209 and is left as it was" {
    // Goal: never initialise over something that is not ours. Method: a file of garbage, an
    // empty file opened without `create`, and a database of another application.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "s.db", .data = repeat('x', 4096) });
    try expect_open_fails(fixture, .{ .create = true }, .E0209);

    try fixture.tmp.dir.deleteFile(testing.io, "s.db");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "s.db", .data = "" });
    try expect_open_fails(fixture, .{ .create = false }, .E0209);
    const db = try fixture.open_new(.{ .create = true }); // With `create` an empty file is made.
    release(db);

    try fixture.tmp.dir.deleteFile(testing.io, "s.db");
    try fixture.raw_exec("CREATE TABLE somebody_elses (x)");
    try expect_open_fails(fixture, .{ .create = true }, .E0209);
}

test "open: a schema from a newer zcube is ZC-E0210 and the file is not touched" {
    // Goal: refuse rather than guess. Method: make a store, bump its schema version the way a
    // newer zcube would, and open it again; the version must still be there afterwards.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    release(try fixture.open_new(.{ .create = true }));
    try fixture.raw_exec("PRAGMA user_version = 99");
    try expect_open_fails(fixture, .{ .create = true }, .E0210);
    try expect_open_fails(fixture, .{ .create = false }, .E0210);
    try testing.expectEqual(@as(i64, 99), try fixture.raw_user_version());
}

test "a busy database is ZC-E0208 after the wait, and recovers when the lock is released" {
    // Goal: a stuck peer is an operating error, not a hang or a raw SQLite code. Method: one
    // connection takes the write lock and keeps it; a second, with a short wait, tries to
    // write (fails), and to read (WAL lets it); after the first lets go, the write succeeds.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const holder = try fixture.open_new(.{ .create = true, .sync = .normal });
    defer release(holder);
    const waiter = try fixture.open_new(.{ .create = false, .sync = .normal, .busy_ms = 50 });
    defer release(waiter);
    var diag: Diag = undefined;
    diag.reset();
    try holder.begin_write(&diag);
    const op: store.Op = .{ .put = .{ .key = "/a", .value = "1" } };
    const s = waiter.interface();
    try testing.expectError(error.BackendFailed, s.txn(.{ .on_success = &.{op} }, &diag));
    try expect_designed(&diag, .E0208);
    diag.reset();
    try testing.expectEqual(@as(Revision, 0), (try s.status(&diag)).revision);
    holder.rollback();
    const written = try s.txn(.{ .on_success = &.{op} }, &diag);
    try testing.expectEqual(@as(Revision, 1), written.revision);
}

test "a write the database refuses is ZC-E0202 and takes no revision" {
    // Goal: a failing write is reported, rolled back, and leaves the store usable. Method: make
    // the connection read-only the way a full or read-only disk would, try to write, then
    // lift it and write again.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(.{ .create = true, .sync = .normal });
    defer release(db);
    var diag: Diag = undefined;
    diag.reset();
    const s = db.interface();
    const op: store.Op = .{ .put = .{ .key = "/a", .value = "1" } };
    try db.exec("PRAGMA query_only = 1", &diag);
    try testing.expectError(error.BackendFailed, s.txn(.{ .on_success = &.{op} }, &diag));
    try expect_designed(&diag, .E0202);
    try testing.expectEqualStrings(
        "the store file or its directory can't be written to",
        diag.last_cause().?,
    );
    diag.reset();
    try db.exec("PRAGMA query_only = 0", &diag);
    const written = try s.txn(.{ .on_success = &.{op} }, &diag);
    try testing.expectEqual(@as(Revision, 1), written.revision);
}

test "a store survives a restart: data, revision, compaction point and leases" {
    // Goal: the file is the store. Method: write, attach a key to a lease, compact, close;
    // reopen and read back everything; the lease must still expire on the same clock.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const first = try fixture.open_new(.{ .create = true, .sync = .normal });
    var diag: Diag = undefined;
    diag.reset();
    var s = first.interface();
    const lease = try s.lease_grant(1000, &diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/a", .value = "1" } },
        .{ .put = .{ .key = "/n", .value = "node", .lease = lease.id } },
    };
    _ = try s.txn(.{ .on_success = &ops }, &diag);
    _ = try s.txn(.{ .on_success = &.{.{ .put = .{ .key = "/a", .value = "2" } }} }, &diag);
    try s.compact(2, &diag);
    release(first);

    const second = try fixture.open_new(.{ .create = false, .sync = .normal });
    defer release(second);
    s = second.interface();
    const status = try s.status(&diag);
    try testing.expectEqual(@as(Revision, 2), status.revision);
    try testing.expectEqual(@as(Revision, 2), status.compacted_revision);
    const got = try s.get(arena_state.allocator(), "/a", null, &diag);
    try testing.expectEqualStrings("2", got.kv.?.value);
    fixture.manual.advance(1500);
    try testing.expectEqual(@as(u32, 1), try s.expire_leases(&diag));
    try testing.expect((try s.get(arena_state.allocator(), "/n", null, &diag)).kv == null);
}

test "compaction deletes the history it no longer needs from the file" {
    // Goal: compaction frees space, not just the right answers (the suite checks those).
    // Method: five versions of a key and a deleted key; count the log's rows before and after.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(.{ .create = true, .sync = .normal });
    defer release(db);
    var diag: Diag = undefined;
    diag.reset();
    const s = db.interface();
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |value| {
        _ = try s.txn(.{ .on_success = &.{.{ .put = .{ .key = "/k", .value = value } }} }, &diag);
    }
    _ = try s.txn(.{ .on_success = &.{.{ .put = .{ .key = "/gone", .value = "x" } }} }, &diag);
    _ = try s.txn(.{ .on_success = &.{.{ .delete = "/gone" }} }, &diag);
    const rows = "SELECT COUNT(*) FROM store_log";
    try testing.expectEqual(@as(i64, 7), try db.pragma_value(rows, &diag));
    try s.compact(7, &diag);
    try testing.expectEqual(@as(i64, 1), try db.pragma_value(rows, &diag)); // Only /k at 5.
}
