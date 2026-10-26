//! `PostgresStore`: the Postgres backend of `Store`. One `PostgresStore` is one logical store in
//! one schema of one database, reached through a small bounded pool of connections; several in
//! one process, or in several servers, share the schema through Postgres's own locking.
//!
//! The model is docs/store-design.md: `store_meta` (the current and compacted revisions),
//! `store_log` (append-only, one row per event, `(revision, idx)` primary key), `store_live` (the
//! latest row per key; `USING orioledb` when that extension is present) and `store_lease`.
//!
//! ## Revisions
//!
//! Every write transaction begins `UPDATE store_meta SET revision = revision + 1 RETURNING
//! revision`. The row lock that takes is held until commit or rollback, so writers are serialised:
//! revision order is commit order, a rolled-back transaction gives its revision back (nothing
//! ever burns one, as a sequence would), and the compares of a transaction run under the lock,
//! so READ COMMITTED is enough. A transaction that changes nothing rolls back (or, when it must
//! still do other work first, subtracts its bump before committing). A reader takes the revision
//! and its rows in one statement, so they share a snapshot; Postgres lets a committing writer out
//! of the set of running transactions before it drops its locks, so a snapshot that sees
//! revision N + 1 also sees N.
//!
//! ## Things a caller must know
//!
//! - **Time.** Lease deadlines are milliseconds. `OpenOptions.lease_time` says whose: `.database`
//!   (the default, for production) reads Postgres's `clock_timestamp()`, so two servers on one
//!   database agree and a clock step on either does not move a lease; `.clock` takes an injected
//!   `Clock`, for tests that drive expiry by hand. The two are not interchangeable in one schema:
//!   deadlines written under one mean nothing under the other.
//! - **Connections.** At most `store_postgres_connections_max` per store, one per operation in
//!   flight; a further operation waits `pool_wait_ms`, then fails with ZC-E0207. Each open watch
//!   has a connection of its own, which `LISTEN`s. A connection found dead before an operation
//!   begins is replaced and the operation retried once; one that dies later is ZC-E0213, and a
//!   write whose COMMIT was in flight says its outcome is unknown.
//! - **Watches** are woken by `NOTIFY` and read the log from their position in one snapshot. A
//!   lost notification costs up to `watch_fallback_ms` of latency, never correctness.
//! - **Allocation.** libpq allocates inside the library (a result is held whole until cleared).
//!   Everything handed to the caller is copied into its arena.
//! - A failure is a registered diagnostic (`pq.zig`); the raw Postgres message is the first
//!   cause and the last cause is for the operator.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("libpq_c");
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const Clock = @import("clock.zig").Clock;
const ManualClock = @import("clock.zig").ManualClock;
const pq = @import("pq.zig");
const store = @import("store.zig");
const failures = @import("store_failures.zig");

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const LeaseId = store.LeaseId;
const Error = store.Error;
const Params = pq.Params;

/// Bumped when the schema changes. A schema with a higher number is refused (ZC-E0210).
pub const schema_version: u32 = 1;
/// Marks a schema as ours, so a foreign one is not initialised over.
const application = "zcube-store";
pub const schema_default = "zcube";

// ---- Schema ---------------------------------------------------------------------------------

const schema_head = std.fmt.comptimePrint(
    \\CREATE TABLE store_meta (
    \\    id int PRIMARY KEY CHECK (id = 1),
    \\    application text NOT NULL,
    \\    schema_version int NOT NULL,
    \\    revision bigint NOT NULL,
    \\    compacted_revision bigint NOT NULL
    \\);
    \\INSERT INTO store_meta VALUES (1, '{s}', {d}, 0, 0);
    \\CREATE TABLE store_log (
    \\    revision bigint NOT NULL,
    \\    idx int NOT NULL,
    \\    key text COLLATE "C" NOT NULL,
    \\    deleted boolean NOT NULL,
    \\    value bytea NOT NULL,
    \\    create_revision bigint NOT NULL,
    \\    lease bigint NOT NULL,
    \\    PRIMARY KEY (revision, idx)
    \\);
    \\CREATE INDEX store_log_key ON store_log (key, revision);
    \\
, .{ application, schema_version });

/// The hot, update-heavy table; the one that is `USING orioledb` when that extension is there.
fn live_table(comptime using: []const u8) []const u8 {
    return
    \\CREATE TABLE store_live (
    \\    key text COLLATE "C" PRIMARY KEY,
    \\    value bytea NOT NULL,
    \\    create_revision bigint NOT NULL,
    \\    mod_revision bigint NOT NULL,
    \\    lease bigint NOT NULL
    \\)
    ++ using ++
        \\;
        \\CREATE INDEX store_live_lease ON store_live (lease) WHERE lease <> 0;
        \\
    ;
}

const schema_tail =
    \\CREATE TABLE store_lease (
    \\    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    \\    ttl_ms int NOT NULL,
    \\    deadline_ms bigint NOT NULL
    \\);
;

// `comptimePrint` gives a NUL-terminated string, which is what libpq takes.
const schema_heap = std.fmt.comptimePrint("{s}{s}{s}", .{
    schema_head, live_table(""), schema_tail,
});
const schema_orioledb = std.fmt.comptimePrint("{s}{s}{s}", .{
    schema_head, live_table(" USING orioledb"), schema_tail,
});

pub const TableAccess = enum { heap, orioledb };

/// What the catalogue says about the OrioleDB extension.
pub const Catalogue = struct {
    /// `CREATE EXTENSION` has been run in this database.
    installed: bool,
    /// The server has its files (`pg_available_extensions`).
    available: bool,
};

pub const AccessPlan = enum { heap, orioledb, orioledb_after_create };

/// The decision, separate from the queries that feed it so that it can be tested without the
/// extension: use OrioleDB if it is installed; if it is only available, try to install it and
/// fall back to heap when that is refused (it needs `shared_preload_libraries` and a privilege).
pub fn plan_access(catalogue: Catalogue) AccessPlan {
    if (catalogue.installed) return .orioledb;
    if (catalogue.available) return .orioledb_after_create;
    return .heap;
}

/// The statements that create the schema for a table access method.
pub fn schema_sql(access: TableAccess) [:0]const u8 {
    return switch (access) {
        .heap => schema_heap,
        .orioledb => schema_orioledb,
    };
}

// ---- Statements -------------------------------------------------------------------------------
// Result columns of the read statements share one layout: 0 head revision, 1 compacted
// revision, then the row: 2 key, 3 value, 4 create_revision, 5 mod_revision, 6 lease, 7 deleted.
// A key that is NULL means the statement found no row (it is a LEFT JOIN on the meta row, so the
// revision and the row come from one snapshot).

/// Postgres's clock, or the injected one when `$1` is not NULL. Every lease statement has it as $1.
const lease_now =
    "COALESCE($1::bigint, FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint)";

const sql_meta = "SELECT revision, compacted_revision FROM store_meta WHERE id = 1";
const sql_bump = "UPDATE store_meta SET revision = revision + 1 WHERE id = 1 RETURNING revision";
const sql_unbump = "UPDATE store_meta SET revision = revision - 1 WHERE id = 1";
const sql_lock_meta =
    "SELECT revision, compacted_revision FROM store_meta WHERE id = 1 FOR UPDATE";
const sql_set_compacted = "UPDATE store_meta SET compacted_revision = $1 WHERE id = 1";
const sql_get_live =
    \\SELECT m.revision, m.compacted_revision, l.key, l.value, l.create_revision, l.mod_revision,
    \\       l.lease, false
    \\FROM store_meta m LEFT JOIN store_live l ON l.key = $1 WHERE m.id = 1
;
const sql_get_log =
    \\SELECT m.revision, m.compacted_revision, l.key, l.value, l.create_revision, l.revision,
    \\       l.lease, l.deleted
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, value, create_revision, revision, lease, deleted FROM store_log
    \\    WHERE key = $1 AND revision <= $2 ORDER BY revision DESC, idx DESC LIMIT 1) l ON true
    \\WHERE m.id = 1
;
// A page ends once its values total the page byte limit ($5, or $6 on the log): rows past it come
// back with a NULL value, which tells the reader a further page follows without sending the bytes.
const sql_list_live =
    \\SELECT m.revision, m.compacted_revision, t.key, t.value, t.create_revision, t.mod_revision,
    \\       t.lease, false
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, CASE WHEN n = 1 OR running <= $5 THEN value END AS value, create_revision,
    \\           mod_revision, lease
    \\    FROM (SELECT key, value, create_revision, mod_revision, lease,
    \\                 SUM(octet_length(value)) OVER (ORDER BY key) AS running,
    \\                 ROW_NUMBER() OVER (ORDER BY key) AS n
    \\          FROM store_live
    \\          WHERE key >= $1 AND key > $2 AND ($3::text IS NULL OR key < $3)
    \\          ORDER BY key LIMIT $4) w) t ON true
    \\WHERE m.id = 1 ORDER BY t.key
;
const sql_list_log =
    \\SELECT m.revision, m.compacted_revision, t.key, t.value, t.create_revision, t.revision,
    \\       t.lease, false
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, CASE WHEN n = 1 OR running <= $6 THEN value END AS value, create_revision,
    \\           revision, lease
    \\    FROM (SELECT l.key, l.value, l.create_revision, l.revision, l.lease,
    \\                 SUM(octet_length(l.value)) OVER (ORDER BY l.key) AS running,
    \\                 ROW_NUMBER() OVER (ORDER BY l.key) AS n
    \\          FROM store_log l
    \\          WHERE l.key >= $1 AND l.key > $2 AND ($3::text IS NULL OR l.key < $3)
    \\            AND NOT l.deleted
    \\            AND l.revision = (SELECT MAX(x.revision) FROM store_log x
    \\                              WHERE x.key = l.key AND x.revision <= $5)
    \\          ORDER BY l.key LIMIT $4) w) t ON true
    \\WHERE m.id = 1 ORDER BY t.key
;
// The same two reads, newest key first. `$2` is NULL for the first page, else the last key
// returned, and the page holds the keys below it. The running byte total counts from the newest.
const sql_list_live_reverse =
    \\SELECT m.revision, m.compacted_revision, t.key, t.value, t.create_revision, t.mod_revision,
    \\       t.lease, false
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, CASE WHEN n = 1 OR running <= $5 THEN value END AS value, create_revision,
    \\           mod_revision, lease
    \\    FROM (SELECT key, value, create_revision, mod_revision, lease,
    \\                 SUM(octet_length(value)) OVER (ORDER BY key DESC) AS running,
    \\                 ROW_NUMBER() OVER (ORDER BY key DESC) AS n
    \\          FROM store_live
    \\          WHERE key >= $1 AND ($2::text IS NULL OR key < $2)
    \\            AND ($3::text IS NULL OR key < $3)
    \\          ORDER BY key DESC LIMIT $4) w) t ON true
    \\WHERE m.id = 1 ORDER BY t.key DESC
;
const sql_list_log_reverse =
    \\SELECT m.revision, m.compacted_revision, t.key, t.value, t.create_revision, t.revision,
    \\       t.lease, false
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, CASE WHEN n = 1 OR running <= $6 THEN value END AS value, create_revision,
    \\           revision, lease
    \\    FROM (SELECT l.key, l.value, l.create_revision, l.revision, l.lease,
    \\                 SUM(octet_length(l.value)) OVER (ORDER BY l.key DESC) AS running,
    \\                 ROW_NUMBER() OVER (ORDER BY l.key DESC) AS n
    \\          FROM store_log l
    \\          WHERE l.key >= $1 AND ($2::text IS NULL OR l.key < $2)
    \\            AND ($3::text IS NULL OR l.key < $3)
    \\            AND NOT l.deleted
    \\            AND l.revision = (SELECT MAX(x.revision) FROM store_log x
    \\                              WHERE x.key = l.key AND x.revision <= $5)
    \\          ORDER BY l.key DESC LIMIT $4) w) t ON true
    \\WHERE m.id = 1 ORDER BY t.key DESC
;
// Column 8 is the position inside the transaction, which orders a revision's events.
const sql_watch =
    \\SELECT m.revision, m.compacted_revision, t.key, t.value, t.create_revision, t.revision,
    \\       t.lease, t.deleted, t.idx
    \\FROM store_meta m LEFT JOIN LATERAL (
    \\    SELECT key, value, create_revision, revision, lease, deleted, idx FROM store_log
    \\    WHERE revision >= $1 AND key >= $2 AND ($3::text IS NULL OR key < $3)
    \\    ORDER BY revision, idx LIMIT $4) t ON true
    \\WHERE m.id = 1 ORDER BY t.revision, t.idx
;
// Counts the distinct revisions in a range, whatever their keys: a watch filters by prefix, so
// only this unfiltered count can show a hole. The compaction point rules out the one honest way
// rows disappear.
const sql_revision_count =
    \\SELECT (SELECT count(*) FROM (SELECT DISTINCT revision FROM store_log
    \\                              WHERE revision >= $1 AND revision <= $2) d),
    \\       (SELECT compacted_revision FROM store_meta WHERE id = 1)
;
const sql_put =
    \\WITH up AS (
    \\    INSERT INTO store_live (key, value, create_revision, mod_revision, lease)
    \\    VALUES ($1, $2, $3, $3, $4)
    \\    ON CONFLICT (key) DO UPDATE
    \\        SET value = EXCLUDED.value, mod_revision = EXCLUDED.mod_revision,
    \\            lease = EXCLUDED.lease
    \\    RETURNING create_revision)
    \\INSERT INTO store_log (revision, idx, key, deleted, value, create_revision, lease)
    \\SELECT $3, $5, $1, false, $2, up.create_revision, $4 FROM up
;
const sql_delete =
    \\WITH del AS (DELETE FROM store_live WHERE key = $1 RETURNING create_revision, lease)
    \\INSERT INTO store_log (revision, idx, key, deleted, value, create_revision, lease)
    \\SELECT $2, $3, $1, true, ''::bytea, del.create_revision, del.lease FROM del
;
const sql_notify = "SELECT pg_notify($1, $2)";
const sql_live_lease = "SELECT lease FROM store_live WHERE key = $1";
const sql_lease_alive = "SELECT deadline_ms >= " ++ lease_now ++ " FROM store_lease WHERE id = $2";
const sql_lease_lock = "SELECT ttl_ms FROM store_lease WHERE id = $1 FOR UPDATE";
const sql_lease_renew = "UPDATE store_lease SET deadline_ms = " ++ lease_now ++ " + ttl_ms " ++
    "WHERE id = $2 AND deadline_ms >= " ++ lease_now ++ " RETURNING ttl_ms";
const sql_lease_insert = "INSERT INTO store_lease (ttl_ms, deadline_ms) " ++
    "SELECT $2, " ++ lease_now ++ " + $2 " ++
    "WHERE (SELECT count(*) FROM store_lease) < $3 RETURNING id";
const sql_lease_gate = "SELECT pg_advisory_xact_lock(hashtext($1))";
const sql_lease_delete = "DELETE FROM store_lease WHERE id = $1";
const sql_lease_keys = "SELECT key FROM store_live WHERE lease = $1 ORDER BY key LIMIT $2";
const sql_lease_held = "SELECT count(*) FROM store_live WHERE lease = $1";
// One statement, so the leases and their keys come from one snapshot. The inner query bounds the
// leases; a lease holds at most `store_lease_keys_max` keys, so the rows are bounded too.
const sql_lease_all = "SELECT s.id, s.ttl_ms, GREATEST(s.deadline_ms - " ++ lease_now ++
    ", 0), l.key FROM store_lease s LEFT JOIN store_live l ON l.lease = s.id " ++
    "WHERE s.id IN (SELECT id FROM store_lease ORDER BY id LIMIT $2) ORDER BY s.id, l.key";
const sql_lease_due = "SELECT id FROM store_lease WHERE deadline_ms < " ++ lease_now ++
    " ORDER BY id LIMIT 1";
// Oldest first, so a batch is a prefix in revision order: a tombstone is never pruned in an
// earlier batch than the older rows it supersedes (which would bring a deleted key back to life
// in a historical read).
const sql_compact_batch =
    \\DELETE FROM store_log WHERE (revision, idx) IN (
    \\    SELECT l.revision, l.idx FROM store_log l
    \\    WHERE l.revision <= $1 AND (l.deleted OR EXISTS (
    \\        SELECT 1 FROM store_log n
    \\        WHERE n.key = l.key AND n.revision > l.revision AND n.revision <= $1))
    \\    ORDER BY l.revision, l.idx LIMIT $2)
;

// ---- Opening and options -----------------------------------------------------------------------

/// Where lease deadlines get their "now".
pub const LeaseTime = union(enum) {
    /// Postgres's `clock_timestamp()`: what a server uses.
    database,
    /// An injected clock, in milliseconds: what the tests use to drive expiry by hand.
    clock: Clock,
};

pub const OpenOptions = struct {
    /// libpq connection settings: a keyword/value string or a URI. Our connect timeout and
    /// application name are added after them.
    conninfo: []const u8,
    /// The schema that holds the store's tables: lowercase letters, digits and underscores.
    schema: []const u8 = schema_default,
    /// Create the schema and its tables if the schema is absent or empty. Without it, a missing
    /// store is an operating error, so a mistyped name does not quietly start an empty store.
    create: bool,
    lease_time: LeaseTime = .database,
    /// Wake watches with LISTEN/NOTIFY. Off, they poll every `watch_fallback_ms`.
    listen: bool = true,
    /// How long a statement waits for a lock before ZC-E0208.
    lock_timeout_ms: u32 = constants.store_postgres_lock_timeout_ms,
    /// How long an operation waits for one of the store's connections before ZC-E0207.
    pool_wait_ms: u32 = constants.store_postgres_lock_timeout_ms,
    /// The longest a watch sleeps between reads when no notification wakes it.
    watch_fallback_ms: u32 = constants.store_watch_notify_fallback_ms,
};

const PoolSlot = struct {
    conn: ?*c.PGconn,
    busy: bool,
};

const WatchSlot = struct {
    owner: *PostgresStore,
    used: bool,
    conn: ?*c.PGconn,
    prefix: [constants.store_key_bytes_max]u8,
    prefix_len: u32,
    next_revision: Revision,
    /// True while the watch sleeps on its socket; the tests wait for it before they write.
    waiting: std.atomic.Value(bool),
    /// How many times a notification (rather than the fallback) woke this watch.
    notified: std.atomic.Value(u32),
};

const Meta = struct {
    revision: Revision,
    compacted_revision: Revision,
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

pub const PostgresStore = struct {
    io: std.Io,
    lease_time: LeaseTime,
    listen: bool,
    lock_timeout_ms: u32,
    pool_wait_ms: u32,
    watch_fallback_ms: u32,
    table_access: TableAccess,
    schema_buffer: [constants.store_postgres_schema_bytes_max]u8,
    schema_len: u32,
    conninfo_buffer: [constants.store_postgres_conninfo_bytes_max + 1]u8,
    conninfo_len: u32,
    setup: pq.SqlBuffer(512),
    channel_buffer: [constants.store_postgres_schema_bytes_max + channel_prefix.len]u8,
    channel_len: u32,
    mutex: std.Io.Mutex,
    pool_ready: std.Io.Condition,
    pool: [constants.store_postgres_connections_max]PoolSlot,
    watches: [constants.store_postgres_watches_max]WatchSlot,

    const channel_prefix = "zcube_";

    const vtable: store.Store.VTable = .{
        .status = status_impl,
        .get = get_impl,
        .list = list_impl,
        .txn = txn_impl,
        .watch = watch_impl,
        .lease_grant = lease_grant_impl,
        .lease_keepalive = lease_keepalive_impl,
        .lease_revoke = lease_revoke_impl,
        .lease_list = lease_list_impl,
        .expire_leases = expire_leases_impl,
        .compact = compact_impl,
    };

    const watch_vtable: store.Watch.WatchVTable = .{
        .next = watch_next_impl,
        .close = watch_close_impl,
    };

    /// Connects, and checks (or, with `create`, writes) the schema. Initialises `self` in place:
    /// watches point back at the store, so it must not move afterwards. On error the store is not
    /// open and `close` must not be called.
    pub fn open(
        self: *PostgresStore,
        io: std.Io,
        options: OpenOptions,
        diag: *Diag,
    ) Error!void {
        assert(diag.code == null);
        try check_options(options, diag);
        self.io = io;
        self.lease_time = options.lease_time;
        self.listen = options.listen;
        self.lock_timeout_ms = options.lock_timeout_ms;
        self.pool_wait_ms = options.pool_wait_ms;
        self.watch_fallback_ms = options.watch_fallback_ms;
        self.table_access = .heap;
        @memcpy(self.schema_buffer[0..options.schema.len], options.schema);
        self.schema_len = @intCast(options.schema.len);
        @memcpy(self.conninfo_buffer[0..options.conninfo.len], options.conninfo);
        self.conninfo_buffer[options.conninfo.len] = 0;
        self.conninfo_len = @intCast(options.conninfo.len);
        @memcpy(self.channel_buffer[0..channel_prefix.len], channel_prefix);
        @memcpy(self.channel_buffer[channel_prefix.len..][0..options.schema.len], options.schema);
        self.channel_len = @intCast(channel_prefix.len + options.schema.len);
        self.setup = .{};
        build_setup(&self.setup, options);
        _ = self.setup.terminated();
        self.mutex = .init;
        self.pool_ready = .init;
        for (&self.pool) |*slot| slot.* = .{ .conn = null, .busy = false };
        for (&self.watches) |*slot| slot.used = false;
        errdefer self.close_pool();
        var session = try self.acquire(diag);
        defer session.release();
        try ensure_schema(&session, options.create, diag);
        assert(self.schema().len == options.schema.len);
    }

    /// Closes every connection. All watches must be closed first.
    pub fn close(self: *PostgresStore) void {
        for (self.watches) |slot| assert(!slot.used);
        self.close_pool();
        self.* = undefined;
    }

    fn close_pool(self: *PostgresStore) void {
        for (&self.pool) |*slot| {
            assert(!slot.busy); // Every operation has released its connection.
            if (slot.conn) |conn| pq.close(conn);
            slot.conn = null;
        }
    }

    pub fn interface(self: *PostgresStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *PostgresStore {
        return @ptrCast(@alignCast(context));
    }

    fn schema(self: *const PostgresStore) []const u8 {
        assert(self.schema_len > 0);
        return self.schema_buffer[0..self.schema_len];
    }

    fn conninfo(self: *const PostgresStore) [:0]const u8 {
        assert(self.conninfo_len > 0);
        return self.conninfo_buffer[0..self.conninfo_len :0];
    }

    fn channel(self: *const PostgresStore) []const u8 {
        assert(self.channel_len > channel_prefix.len);
        return self.channel_buffer[0..self.channel_len];
    }

    /// The `now` for a lease statement: the injected clock's, or null for Postgres's own.
    fn lease_now_ms(self: *const PostgresStore) ?u64 {
        return switch (self.lease_time) {
            .database => null,
            .clock => |clock| clock.now_ms(),
        };
    }

    /// Removes the schema and everything in it. For tests, and for tooling that resets a
    /// development store; nothing in the server calls it.
    pub fn drop_schema(self: *PostgresStore, diag: *Diag) Error!void {
        var session = try self.acquire(diag);
        defer session.release();
        var sql: pq.SqlBuffer(128) = .{};
        sql.append("DROP SCHEMA IF EXISTS \"");
        sql.append(self.schema());
        sql.append("\" CASCADE");
        try session.simple(sql.terminated(), diag);
    }

    // ---- The connection pool ---------------------------------------------------------------

    fn open_connection(self: *PostgresStore, diag: *Diag) Error!*c.PGconn {
        return pq.connect(diag, self.conninfo(), self.setup.terminated_const());
    }

    /// Takes a free slot, preferring one that already has a connection; waits for one up to
    /// `pool_wait_ms`.
    fn claim_slot(self: *PostgresStore, diag: *Diag) Error!*PoolSlot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const wait: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(self.pool_wait_ms),
            .clock = .awake,
        } };
        const deadline = wait.toDeadline(self.io);
        while (true) { // Ends with a slot or with the wait running out.
            for (&self.pool) |*slot| {
                if (slot.busy or slot.conn == null) continue;
                slot.busy = true;
                return slot;
            }
            for (&self.pool) |*slot| {
                if (slot.busy) continue;
                slot.busy = true;
                return slot;
            }
            self.pool_ready.waitTimeout(self.io, &self.mutex, deadline) catch {
                return connections_full(diag, self.pool_wait_ms);
            };
        }
    }

    /// Opens an operation: a connection no one else is using.
    fn acquire(self: *PostgresStore, diag: *Diag) Error!Session {
        const slot = try self.claim_slot(diag);
        if (slot.conn == null) {
            slot.conn = self.open_connection(diag) catch |err| {
                self.give_back(slot, null);
                return err;
            };
        }
        return .{
            .owner = self,
            .slot = slot,
            .conn = slot.conn,
            .in_transaction = false,
            .committing = false,
        };
    }

    /// Returns a slot. A connection that is not `healthy` is closed, so the next operation
    /// opens a fresh one.
    fn give_back(self: *PostgresStore, slot: *PoolSlot, healthy: ?*c.PGconn) void {
        if (healthy == null) {
            if (slot.conn) |dead| pq.close(dead);
            slot.conn = null;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assert(slot.busy);
        slot.busy = false;
        self.pool_ready.signal(self.io);
    }
};

fn connections_full(diag: *Diag, waited_ms: u32) error{NoCapacity} {
    assert(diag.code == null);
    diag.raise(.E0207);
    diag.cause("all {d} store connections were busy for {d} ms", .{
        constants.store_postgres_connections_max, waited_ms,
    });
    diag.fix(.{ .sentence = "retry; if it persists, a transaction is being held open" });
    return error.NoCapacity;
}

/// The names and sizes in the options, checked before anything is opened. A bad one is the
/// operator's: the settings are wrong, so no store was reached.
fn check_options(options: OpenOptions, diag: *Diag) Error!void {
    assert(options.lock_timeout_ms > 0);
    assert(options.watch_fallback_ms > 0);
    if (options.conninfo.len == 0) return fail_setting(diag, "the connection settings are empty");
    if (options.conninfo.len > constants.store_postgres_conninfo_bytes_max) {
        return fail_setting(diag, "the connection settings are over the size limit");
    }
    if (schema_problem(options.schema)) |problem| return fail_setting(diag, problem);
}

fn fail_setting(diag: *Diag, what: []const u8) error{BackendFailed} {
    assert(diag.code == null);
    diag.raise(.E0201);
    diag.cause("{s}", .{what});
    diag.cause("no Postgres server was contacted", .{});
    diag.fix(.{ .sentence = "correct the store settings: a libpq connection string and a schema" ++
        " of lowercase letters, digits and underscores" });
    return error.BackendFailed;
}

/// Null if `name` can be a schema: it is quoted in SQL and joins a NOTIFY channel name, so the
/// alphabet is small and it starts with a letter or an underscore.
pub fn schema_problem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "the schema name is empty";
    if (name.len > constants.store_postgres_schema_bytes_max) return "the schema name is too long";
    if (std.ascii.isDigit(name[0])) return "the schema name starts with a digit";
    for (name) |byte| {
        const allowed = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_';
        if (!allowed) return "the schema name has a character outside a-z, 0-9 and _";
    }
    return null;
}

/// The settings every connection gets before its first use.
fn build_setup(buffer: *pq.SqlBuffer(512), options: OpenOptions) void {
    buffer.append("SET search_path TO \"");
    buffer.append(options.schema);
    buffer.append("\"; SET lock_timeout = ");
    buffer.append_number(options.lock_timeout_ms);
    buffer.append("; SET statement_timeout = ");
    buffer.append_number(constants.store_postgres_statement_timeout_ms);
    buffer.append("; SET idle_in_transaction_session_timeout = ");
    buffer.append_number(constants.store_postgres_idle_txn_ms);
    buffer.append("; SET client_min_messages = warning");
    assert(buffer.len < 512);
}

// ---- A session: one connection, for one operation ---------------------------------------------

const no_params: Params = .{};

const Session = struct {
    owner: *PostgresStore,
    slot: *PoolSlot,
    /// Null once a reconnect failed; `release` then returns the slot without a connection.
    conn: ?*c.PGconn,
    in_transaction: bool,
    committing: bool,

    /// Ends the operation: anything still open is rolled back, and a connection that cannot be
    /// brought back to idle is closed rather than returned.
    fn release(session: *Session) void {
        var healthy = session.conn;
        if (session.conn) |conn| {
            if (!pq.is_open(conn)) healthy = null;
            if (healthy != null and !pq.rollback(conn)) healthy = null;
        }
        session.owner.give_back(session.slot, healthy);
        session.* = undefined;
    }

    fn context(session: *const Session) pq.Context {
        return .{
            .committing = session.committing,
            .lock_timeout_ms = session.owner.lock_timeout_ms,
        };
    }

    fn run(
        session: *Session,
        sql: [:0]const u8,
        params: *const Params,
        diag: *Diag,
    ) Error!pq.Result {
        const conn = session.conn.?;
        return pq.exec(diag, conn, sql, params, session.context());
    }

    fn simple(session: *Session, sql: [:0]const u8, diag: *Diag) Error!void {
        const conn = session.conn.?;
        var result = try pq.exec_simple(diag, conn, sql, session.context());
        result.clear();
    }

    /// A statement outside a transaction, or the one that opens it. A connection found dead is
    /// replaced and the statement retried once: nothing has been done on this operation's
    /// behalf yet, so repeating it is safe. Inside a transaction it is not, and the loss is
    /// ZC-E0213.
    fn query(
        session: *Session,
        sql: [:0]const u8,
        params: *const Params,
        diag: *Diag,
    ) Error!pq.Result {
        return session.run(sql, params, diag) catch |err| {
            if (!session.lost_before_work(diag)) return err;
            diag.reset();
            try session.reconnect(diag);
            return session.run(sql, params, diag);
        };
    }

    fn lost_before_work(session: *const Session, diag: *const Diag) bool {
        if (diag.code.? != .E0213) return false;
        return !session.in_transaction and !session.committing;
    }

    fn reconnect(session: *Session, diag: *Diag) Error!void {
        if (session.conn) |old| pq.close(old);
        session.conn = null;
        session.slot.conn = null;
        const fresh = try session.owner.open_connection(diag);
        session.conn = fresh;
        session.slot.conn = fresh;
    }

    fn begin(session: *Session, diag: *Diag) Error!void {
        assert(!session.in_transaction);
        var result = try session.query("BEGIN ISOLATION LEVEL READ COMMITTED", &no_params, diag);
        result.clear();
        session.in_transaction = true;
    }

    fn commit(session: *Session, diag: *Diag) Error!void {
        assert(session.in_transaction);
        session.committing = true;
        try session.simple("COMMIT", diag);
        session.committing = false;
        session.in_transaction = false;
    }

    /// Discards the transaction; the connection stays usable.
    fn rollback(session: *Session) void {
        assert(session.in_transaction);
        const conn = session.conn.?;
        if (pq.rollback(conn)) session.in_transaction = false;
    }
};

// ---- Failures specific to this backend ---------------------------------------------------------

fn fail_damaged(
    self: *const PostgresStore,
    diag: *Diag,
    comptime what: []const u8,
) error{BackendFailed} {
    assert(diag.code == null);
    diag.raise(.E0209);
    diag.cause("the store schema \"{s}\" " ++ what, .{self.schema()});
    diag.fix(.{ .sentence = "restore the schema from a backup, or point the server at another" });
    diag.context("schema", "{s}", .{self.schema()});
    return error.BackendFailed;
}

fn fail_too_new(self: *const PostgresStore, diag: *Diag, found: i32) error{BackendFailed} {
    assert(diag.code == null);
    assert(found > schema_version);
    diag.raise(.E0210);
    diag.cause("the store schema has version {d}; this zcube understands up to {d}", .{
        found, schema_version,
    });
    diag.fix(.{ .sentence = "run the zcube version that created the schema, or upgrade zcube" });
    diag.context("schema", "{s}", .{self.schema()});
    return error.BackendFailed;
}

/// A hole in the revisions a watch is about to deliver. The write path makes one impossible
/// (docs/store-design.md); seeing one means that reasoning is wrong somewhere, so this is a bug
/// report, not a skipped event.
fn fail_hole(diag: *Diag, from: Revision, to: Revision) error{BackendFailed} {
    assert(diag.code == null);
    assert(from <= to);
    diag.raise(.B0001);
    diag.cause("the store log has a hole between revisions {d} and {d}", .{ from, to });
    diag.cause("a watch read the log again {d} times and the revision stayed missing", .{
        constants.store_watch_hole_retries_max,
    });
    return error.BackendFailed;
}

// ---- Helpers ----------------------------------------------------------------------------------

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

/// Row `row` of a read statement as a key-value (columns 2 to 6 of the shared layout).
fn row_kv(result: *const pq.Result, row: u32, arena: Allocator, diag: *Diag) Error!store.KeyValue {
    const key = arena.dupe(u8, result.bytes(row, 2)) catch return failures.no_memory(diag);
    const value = arena.dupe(u8, result.bytes(row, 3)) catch return failures.no_memory(diag);
    return .{
        .key = key,
        .value = value,
        .create_revision = result.unsigned(row, 4),
        .mod_revision = result.unsigned(row, 5),
        .lease = result.unsigned(row, 6),
    };
}

/// The head and compaction revisions every read statement leads with.
fn row_meta(result: *const pq.Result) Meta {
    assert(result.rows() > 0);
    return .{ .revision = result.unsigned(0, 0), .compacted_revision = result.unsigned(0, 1) };
}

/// Removes the trailing events of `revision`, which the row limit cut in half.
fn drop_revision(events: *std.ArrayList(store.Event), revision: Revision) void {
    while (events.items.len > 0) {
        if (events.items[events.items.len - 1].kv.mod_revision != revision) break;
        events.items.len -= 1;
    }
    assert(events.items.len > 0); // A revision holds at most 64 events; a batch holds 256.
}

const Page = struct {
    kvs: []const store.KeyValue,
    continue_after: ?[]const u8,
};

/// Reads the page out of a list statement, which was asked for one row more than `limit` to see
/// whether another page follows, and which sends a NULL value for rows past the page byte limit.
fn collect_page(
    result: *const pq.Result,
    arena: Allocator,
    limit: u32,
    diag: *Diag,
) Error!Page {
    var kvs: std.ArrayList(store.KeyValue) = .empty;
    var more = false;
    for (0..result.rows()) |index| {
        const row: u32 = @intCast(index);
        if (result.is_null(row, 2)) break; // The meta row with no data row joined to it.
        if (kvs.items.len == limit or result.is_null(row, 3)) {
            more = true;
            break;
        }
        kvs.append(arena, try row_kv(result, row, arena, diag)) catch {
            return failures.no_memory(diag);
        };
    }
    assert(kvs.items.len <= limit);
    if (more) assert(kvs.items.len > 0);
    return .{
        .kvs = kvs.items,
        .continue_after = if (more) kvs.items[kvs.items.len - 1].key else null,
    };
}

// ---- Reads ------------------------------------------------------------------------------------

fn read_meta(self: *PostgresStore, diag: *Diag) Error!Meta {
    var session = try self.acquire(diag);
    defer session.release();
    var result = try session.query(sql_meta, &no_params, diag);
    defer result.clear();
    return checked_meta(self, &result, diag);
}

/// The meta row of an answer, refused if it cannot be a store's (the record is missing, or the
/// compaction point is above the revision).
fn checked_meta(self: *const PostgresStore, result: *const pq.Result, diag: *Diag) Error!Meta {
    if (result.rows() == 0) return fail_damaged(self, diag, "has no revision record");
    const meta = row_meta(result);
    if (meta.compacted_revision > meta.revision) {
        return fail_damaged(self, diag, "records a compaction point above its revision");
    }
    return meta;
}

fn status_impl(context: *anyopaque, diag: *Diag) Error!store.Status {
    const meta = try read_meta(PostgresStore.from(context), diag);
    return .{ .revision = meta.revision, .compacted_revision = meta.compacted_revision };
}

fn get_impl(
    context: *anyopaque,
    arena: Allocator,
    key: []const u8,
    at_revision: ?Revision,
    diag: *Diag,
) Error!store.GetResult {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    var params: Params = .{};
    params.add_bytes(.text, key);
    if (at_revision) |revision| params.add_int8(revision);
    const sql = if (at_revision == null) sql_get_live else sql_get_log;
    var result = try session.query(sql, &params, diag);
    defer result.clear();
    const meta = try checked_meta(self, &result, diag);
    const revision = at_revision orelse meta.revision;
    try check_readable(meta, revision, diag);
    const found = !result.is_null(0, 2) and !result.boolean(0, 7); // A tombstone is absent.
    const kv = if (found) try row_kv(&result, 0, arena, diag) else null;
    return .{ .kv = kv, .revision = revision };
}

fn list_impl(
    context: *anyopaque,
    arena: Allocator,
    options: store.ListOptions,
    diag: *Diag,
) Error!store.ListResult {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    var end_buffer: [constants.store_key_bytes_max]u8 = undefined;
    var params: Params = .{};
    params.add_bytes(.text, options.prefix);
    if (options.reverse) {
        params.add_optional_text(options.continue_after);
    } else {
        params.add_bytes(.text, options.continue_after orelse "");
    }
    params.add_optional_text(prefix_end(&end_buffer, options.prefix));
    params.add_int8(@as(u64, options.limit) + 1); // One more tells if a page follows.
    if (options.at_revision) |revision| params.add_int8(revision);
    params.add_int8(constants.store_page_bytes_max);
    const sql = switch (options.reverse) {
        false => if (options.at_revision == null) sql_list_live else sql_list_log,
        true => if (options.at_revision == null) sql_list_live_reverse else sql_list_log_reverse,
    };
    var result = try session.query(sql, &params, diag);
    defer result.clear();
    const meta = try checked_meta(self, &result, diag);
    const revision = options.at_revision orelse meta.revision;
    try check_readable(meta, revision, diag);
    const page = try collect_page(&result, arena, options.limit, diag);
    return .{ .kvs = page.kvs, .revision = revision, .continue_after = page.continue_after };
}

// ---- Transactions ------------------------------------------------------------------------------

/// The write side of a session. Every method here runs inside the transaction `begin` opened,
/// under the lock on the meta row that `bump` took.
const Writer = struct {
    session: *Session,
    diag: *Diag,

    /// Takes the next revision and, with it, the writer lock (held until commit or rollback).
    fn bump(writer: Writer) Error!Revision {
        var result = try writer.session.run(sql_bump, &no_params, writer.diag);
        defer result.clear();
        assert(result.rows() == 1);
        const revision = result.unsigned(0, 0);
        assert(revision > 0);
        return revision;
    }

    /// Gives the revision back without letting go of the lock, for a transaction that still has
    /// work to do but wrote no event.
    fn unbump(writer: Writer) Error!void {
        var result = try writer.session.run(sql_unbump, &no_params, writer.diag);
        result.clear();
    }

    fn compares_hold(writer: Writer, compares: []const store.Compare) Error!bool {
        assert(compares.len <= constants.store_txn_compares_max);
        if (compares.len == 0) return true;
        var sql: pq.SqlBuffer(1024) = .{};
        var params: Params = .{};
        sql.append("SELECT COALESCE(bool_and(COALESCE(l.mod_revision, 0) = c.revision), true) " ++
            "FROM (VALUES ");
        for (compares, 0..) |compare, index| {
            if (index > 0) sql.append(", ");
            sql.append("($");
            sql.append_number(@intCast(2 * index + 1));
            sql.append(", $");
            sql.append_number(@intCast(2 * index + 2));
            sql.append(")");
            params.add_bytes(.text, compare.key);
            params.add_int8(compare.mod_revision);
        }
        sql.append(") AS c(key, revision) LEFT JOIN store_live l ON l.key = c.key");
        var result = try writer.session.run(sql.terminated(), &params, writer.diag);
        defer result.clear();
        return result.boolean(0, 0);
    }

    /// Applies one op under `revision`. True if it produced an event (a delete of an absent
    /// key does not).
    fn apply_op(writer: Writer, op: store.Op, revision: Revision, idx: u32) Error!bool {
        assert(revision > 0);
        assert(idx < constants.store_watch_batch_max);
        var params: Params = .{};
        switch (op) {
            .put => |put| {
                params.add_bytes(.text, put.key);
                params.add_bytes(.bytea, put.value);
                params.add_int8(revision);
                params.add_int8(put.lease);
                params.add_int4(idx);
                var result = try writer.session.run(sql_put, &params, writer.diag);
                defer result.clear();
                assert(result.affected() == 1);
                return true;
            },
            .delete => |key| return writer.apply_delete(key, revision, idx),
        }
    }

    fn apply_delete(writer: Writer, key: []const u8, revision: Revision, idx: u32) Error!bool {
        var params: Params = .{};
        params.add_bytes(.text, key);
        params.add_int8(revision);
        params.add_int4(idx);
        var result = try writer.session.run(sql_delete, &params, writer.diag);
        defer result.clear();
        const deleted = result.affected();
        assert(deleted <= 1);
        return deleted == 1;
    }

    /// Tells watchers a revision is coming (delivered at commit, in commit order), then commits.
    fn finish(writer: Writer, revision: Revision) Error!void {
        var number: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&number, "{d}", .{revision}) catch unreachable; // u64 fits.
        var params: Params = .{};
        params.add_bytes(.text, writer.session.owner.channel());
        params.add_bytes(.text, text);
        var result = try writer.session.run(sql_notify, &params, writer.diag);
        result.clear();
        try writer.session.commit(writer.diag);
    }

    /// Every lease a put names must be alive, and no lease may end up with too many keys.
    /// Checked before anything is applied, so a refusal leaves the store untouched.
    fn check_leases(writer: Writer, ops: []const store.Op) Error!void {
        for (ops, 0..) |op, index| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (put.lease == store.lease_none) continue;
            if (names_lease(ops[0..index], put.lease)) continue; // Checked at its first put.
            if (!(try writer.lease_alive(put.lease))) {
                return failures.lease_not_found(writer.diag, put.lease);
            }
            const count = try writer.lease_key_count(put.lease, ops);
            if (count > constants.store_lease_keys_max) {
                return failures.lease_keys_full(writer.diag, put.lease, count);
            }
        }
    }

    /// A lease is alive until its deadline has passed, reaped or not.
    fn lease_alive(writer: Writer, id: LeaseId) Error!bool {
        var params: Params = .{};
        params.add_optional_int8(writer.session.owner.lease_now_ms());
        params.add_int8(id);
        var result = try writer.session.run(sql_lease_alive, &params, writer.diag);
        defer result.clear();
        if (result.rows() == 0) return false;
        return result.boolean(0, 0);
    }

    /// How many keys the lease holds once `ops` is applied: those it holds now, less the ones
    /// `ops` moves off it, plus the ones `ops` puts on it.
    fn lease_key_count(writer: Writer, lease: LeaseId, ops: []const store.Op) Error!u32 {
        var params: Params = .{};
        params.add_int8(lease);
        var held = try writer.session.run(sql_lease_held, &params, writer.diag);
        defer held.clear();
        var count: u32 = @intCast(held.unsigned(0, 0));
        for (ops) |op| {
            const was_on = (try writer.key_lease(store.op_key(op))) == lease;
            const now_on = switch (op) {
                .put => |put| put.lease == lease,
                .delete => false,
            };
            if (was_on and !now_on) count -= 1;
            if (!was_on and now_on) count += 1;
        }
        return count;
    }

    /// The lease a live key is on; null if the key does not exist.
    fn key_lease(writer: Writer, key: []const u8) Error!?LeaseId {
        var params: Params = .{};
        params.add_bytes(.text, key);
        var result = try writer.session.run(sql_live_lease, &params, writer.diag);
        defer result.clear();
        if (result.rows() == 0) return null;
        return result.unsigned(0, 0);
    }
};

fn txn_impl(context: *anyopaque, request: store.TxnRequest, diag: *Diag) Error!store.TxnResult {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    try session.begin(diag);
    const writer: Writer = .{ .session = &session, .diag = diag };
    const revision = try writer.bump();
    const succeeded = try writer.compares_hold(request.compares);
    const ops = if (succeeded) request.on_success else request.on_failure;
    try writer.check_leases(ops);
    var events: u32 = 0;
    for (ops) |op| {
        if (try writer.apply_op(op, revision, events)) events += 1;
    }
    if (events == 0) {
        session.rollback(); // Nothing changed: the bump goes with it, and no revision is taken.
        return .{ .succeeded = succeeded, .revision = revision - 1 };
    }
    try writer.finish(revision);
    return .{ .succeeded = succeeded, .revision = revision };
}

// ---- Leases ------------------------------------------------------------------------------------

fn lease_grant_impl(context: *anyopaque, ttl_ms: u32, diag: *Diag) Error!store.Lease {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    try session.begin(diag);
    // The count and the insert must not interleave with another grant's, or the slots could be
    // overfilled: a lock on the schema's name makes grants take turns (it ends with the commit).
    var gate: Params = .{};
    gate.add_bytes(.text, self.schema());
    var locked = try session.run(sql_lease_gate, &gate, diag);
    locked.clear();
    var params: Params = .{};
    params.add_optional_int8(self.lease_now_ms());
    params.add_int4(ttl_ms);
    params.add_int8(constants.store_leases_max);
    var result = try session.run(sql_lease_insert, &params, diag);
    defer result.clear();
    if (result.rows() == 0) return failures.lease_slots_full(diag);
    const id = result.unsigned(0, 0);
    try session.commit(diag);
    return .{ .id = id, .ttl_ms = ttl_ms };
}

fn lease_keepalive_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!store.Lease {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    var params: Params = .{};
    params.add_optional_int8(self.lease_now_ms());
    params.add_int8(id);
    // One statement: it renews only a lease whose time has not run out, so an expired lease can
    // never be revived between a check and the write.
    var result = try session.query(sql_lease_renew, &params, diag);
    defer result.clear();
    if (result.rows() == 0) return failures.lease_not_found(diag, id);
    const ttl_ms = result.int4(0, 0);
    assert(ttl_ms >= constants.lease_ttl_ms_min);
    return .{ .id = id, .ttl_ms = @intCast(ttl_ms) };
}

fn lease_revoke_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!Revision {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    try session.begin(diag);
    const writer: Writer = .{ .session = &session, .diag = diag };
    const revision = try writer.bump();
    var params: Params = .{};
    params.add_int8(id);
    var found = try session.run(sql_lease_lock, &params, diag);
    const exists = found.rows() == 1;
    found.clear();
    if (!exists) return failures.lease_not_found(diag, id);
    var keys: LeaseKeys = undefined;
    try collect_lease_keys(&session, id, &keys, diag);
    for (0..keys.count) |slot| {
        const idx: u32 = @intCast(slot);
        const deleted = try writer.apply_delete(keys.key(idx), revision, idx);
        assert(deleted); // The keys were read in this transaction, under the writer lock.
    }
    var removal = try session.run(sql_lease_delete, &params, diag);
    removal.clear();
    if (keys.count == 0) {
        try writer.unbump(); // No event, so no revision; the lease row still goes.
        try session.commit(diag);
        return revision - 1;
    }
    try writer.finish(revision);
    return revision;
}

fn collect_lease_keys(session: *Session, id: LeaseId, keys: *LeaseKeys, diag: *Diag) Error!void {
    var params: Params = .{};
    params.add_int8(id);
    params.add_int8(@as(u64, constants.store_lease_keys_max) + 1);
    var result = try session.run(sql_lease_keys, &params, diag);
    defer result.clear();
    if (result.rows() > constants.store_lease_keys_max) {
        return fail_damaged(session.owner, diag, "holds more keys on one lease than allowed");
    }
    keys.count = result.rows();
    for (0..keys.count) |slot| {
        const key = result.bytes(@intCast(slot), 0);
        @memcpy(keys.bytes[slot][0..key.len], key);
        keys.lens[slot] = @intCast(key.len);
    }
}

fn lease_list_impl(
    context: *anyopaque,
    arena: Allocator,
    diag: *Diag,
) Error![]const store.LeaseInfo {
    const self = PostgresStore.from(context);
    var session = try self.acquire(diag);
    defer session.release();
    var params: Params = .{};
    params.add_optional_int8(self.lease_now_ms());
    params.add_int8(constants.store_leases_max);
    var result = try session.query(sql_lease_all, &params, diag);
    defer result.clear();
    var leases: std.ArrayList(store.LeaseInfo) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    for (0..result.rows()) |index| {
        const row: u32 = @intCast(index);
        const id = result.unsigned(row, 0);
        if (leases.items.len == 0 or leases.items[leases.items.len - 1].id != id) {
            seal_lease_keys(leases.items, &keys);
            const ttl_ms: u32 = @intCast(result.int4(row, 1));
            const remaining: u64 = @intCast(result.int8(row, 2));
            leases.append(arena, .{
                .id = id,
                .ttl_ms = ttl_ms,
                .remaining_ms = @intCast(@min(remaining, ttl_ms)),
                .keys = &.{},
            }) catch return failures.no_memory(diag);
        }
        if (result.is_null(row, 3)) continue; // A lease that holds no key.
        const key = arena.dupe(u8, result.bytes(row, 3)) catch return failures.no_memory(diag);
        keys.append(arena, key) catch return failures.no_memory(diag);
        assert(keys.items.len <= constants.store_lease_keys_max);
    }
    seal_lease_keys(leases.items, &keys);
    return leases.items;
}

/// Hands the keys gathered so far to the newest lease and starts a fresh list.
fn seal_lease_keys(leases: []store.LeaseInfo, keys: *std.ArrayList([]const u8)) void {
    if (leases.len > 0) leases[leases.len - 1].keys = keys.items;
    keys.* = .empty;
}

fn expire_leases_impl(context: *anyopaque, diag: *Diag) Error!u32 {
    const self = PostgresStore.from(context);
    var expired: u32 = 0;
    // Each pass removes one lease, so the loop ends; the bound is the most leases there are.
    for (0..constants.store_leases_max) |_| {
        const id = (try next_due_lease(self, diag)) orelse break;
        _ = lease_revoke_impl(context, id, diag) catch |err| switch (err) {
            // Another server revoked it between the query and the writer lock.
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

fn next_due_lease(self: *PostgresStore, diag: *Diag) Error!?LeaseId {
    var session = try self.acquire(diag);
    defer session.release();
    var params: Params = .{};
    params.add_optional_int8(self.lease_now_ms());
    var result = try session.query(sql_lease_due, &params, diag);
    defer result.clear();
    if (result.rows() == 0) return null;
    return result.unsigned(0, 0);
}

// ---- Compaction --------------------------------------------------------------------------------

/// First lowers the floor (an instant, one write under the writer lock), so older reads fail at
/// once; then prunes the log in bounded batches, letting other writers in between.
fn compact_impl(context: *anyopaque, revision: Revision, diag: *Diag) Error!void {
    const self = PostgresStore.from(context);
    if (!(try mark_compacted(self, revision, diag))) return;
    // Each batch deletes at least one row or ends the loop, so it ends.
    while (true) {
        const deleted = try prune_batch(self, revision, diag);
        if (deleted < constants.store_compact_batch_rows) break;
    }
}

/// False if there is nothing to do: `revision` is at or below the compaction point.
fn mark_compacted(self: *PostgresStore, revision: Revision, diag: *Diag) Error!bool {
    var session = try self.acquire(diag);
    defer session.release();
    try session.begin(diag);
    var locked = try session.run(sql_lock_meta, &no_params, diag);
    defer locked.clear();
    const meta = try checked_meta(self, &locked, diag);
    if (revision > meta.revision) return failures.future_compact(diag, revision, meta.revision);
    if (revision <= meta.compacted_revision) return false;
    var params: Params = .{};
    params.add_int8(revision);
    var result = try session.run(sql_set_compacted, &params, diag);
    result.clear();
    try session.commit(diag);
    return true;
}

/// Keeps the latest put per key at or below `revision` and everything above it.
fn prune_batch(self: *PostgresStore, revision: Revision, diag: *Diag) Error!u32 {
    var session = try self.acquire(diag);
    defer session.release();
    var params: Params = .{};
    params.add_int8(revision);
    params.add_int8(constants.store_compact_batch_rows);
    var result = try session.query(sql_compact_batch, &params, diag);
    defer result.clear();
    const deleted = result.affected();
    assert(deleted <= constants.store_compact_batch_rows);
    return deleted;
}

// ---- The schema --------------------------------------------------------------------------------

const sql_schema_state =
    \\SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1),
    \\       to_regclass($2) IS NOT NULL,
    \\       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    \\        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S'))
;
const sql_identity = "SELECT application, schema_version FROM store_meta WHERE id = 1";
const sql_catalogue =
    \\SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'orioledb'),
    \\       EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'orioledb')
;
const sql_access =
    \\SELECT am.amname FROM pg_class c JOIN pg_am am ON am.oid = c.relam
    \\WHERE c.oid = to_regclass($1)
;

const SchemaState = struct {
    exists: bool,
    has_meta: bool,
    relations: u64,
};

/// Reads the schema's identity under a lock that makes concurrent openers take turns, so two
/// servers starting on an empty database initialise it once. Initialises an empty schema only
/// when asked to, and never one that holds anything else.
fn ensure_schema(session: *Session, create: bool, diag: *Diag) Error!void {
    const self = session.owner;
    try session.begin(diag);
    var gate: Params = .{};
    gate.add_bytes(.text, self.schema());
    var locked = try session.run(sql_lease_gate, &gate, diag);
    locked.clear();
    const state = try read_schema_state(session, diag);
    if (state.has_meta) {
        try check_identity(session, diag);
    } else if (!create) {
        return fail_damaged(self, diag, "is missing or empty and was not asked to be created");
    } else if (state.relations > 0) {
        return fail_damaged(self, diag, "belongs to another application");
    } else {
        if (!state.exists) try create_schema(session, diag);
        self.table_access = try create_tables(session, diag);
    }
    try session.commit(diag);
    if (state.has_meta) self.table_access = try read_access(session, diag);
}

fn qualified_meta(self: *const PostgresStore, buffer: *pq.SqlBuffer(96)) []const u8 {
    buffer.append("\"");
    buffer.append(self.schema());
    buffer.append("\".store_meta");
    return buffer.terminated();
}

fn read_schema_state(session: *Session, diag: *Diag) Error!SchemaState {
    var name: pq.SqlBuffer(96) = .{};
    var params: Params = .{};
    params.add_bytes(.text, session.owner.schema());
    params.add_bytes(.text, qualified_meta(session.owner, &name));
    var result = try session.run(sql_schema_state, &params, diag);
    defer result.clear();
    assert(result.rows() == 1);
    return .{
        .exists = result.boolean(0, 0),
        .has_meta = result.boolean(0, 1),
        .relations = result.unsigned(0, 2),
    };
}

/// The schema has a `store_meta`: it must say it is ours, at a version this zcube understands.
fn check_identity(session: *Session, diag: *Diag) Error!void {
    const self = session.owner;
    var result = try session.query(sql_identity, &no_params, diag);
    defer result.clear();
    if (result.rows() == 0) return fail_damaged(self, diag, "has no identity record");
    if (!std.mem.eql(u8, result.bytes(0, 0), application)) {
        return fail_damaged(self, diag, "belongs to another application");
    }
    const found = result.int4(0, 1);
    if (found > schema_version) return fail_too_new(self, diag, found);
    if (found != schema_version) return fail_damaged(self, diag, "has no usable schema version");
}

fn create_schema(session: *Session, diag: *Diag) Error!void {
    var sql: pq.SqlBuffer(96) = .{};
    sql.append("CREATE SCHEMA \"");
    sql.append(session.owner.schema());
    sql.append("\"");
    try session.simple(sql.terminated(), diag);
}

/// Creates the tables, with `store_live` on OrioleDB when the catalogue allows it.
fn create_tables(session: *Session, diag: *Diag) Error!TableAccess {
    var result = try session.query(sql_catalogue, &no_params, diag);
    const catalogue: Catalogue = .{
        .installed = result.boolean(0, 0),
        .available = result.boolean(0, 1),
    };
    result.clear();
    const access: TableAccess = switch (plan_access(catalogue)) {
        .heap => .heap,
        .orioledb => .orioledb,
        .orioledb_after_create => try install_orioledb(session, diag),
    };
    try session.simple(schema_sql(access), diag);
    return access;
}

fn install_orioledb(session: *Session, diag: *Diag) Error!TableAccess {
    if (try try_install_extension(session, "orioledb", diag)) return .orioledb;
    return .heap;
}

/// Tries `CREATE EXTENSION` inside a savepoint, so a refusal (the library is not preloaded, or
/// the role may not) leaves the transaction usable. False if it was refused.
fn try_install_extension(
    session: *Session,
    comptime name: []const u8,
    diag: *Diag,
) Error!bool {
    try session.simple("SAVEPOINT zcube_extension", diag);
    session.simple("CREATE EXTENSION " ++ name, diag) catch {
        diag.reset();
        try session.simple("ROLLBACK TO SAVEPOINT zcube_extension", diag);
        return false;
    };
    try session.simple("RELEASE SAVEPOINT zcube_extension", diag);
    return true;
}

/// Which access method `store_live` actually has, whatever created it.
fn read_access(session: *Session, diag: *Diag) Error!TableAccess {
    var name: pq.SqlBuffer(96) = .{};
    name.append("\"");
    name.append(session.owner.schema());
    name.append("\".store_live");
    var params: Params = .{};
    params.add_bytes(.text, name.terminated());
    var result = try session.query(sql_access, &params, diag);
    defer result.clear();
    if (result.rows() == 0) return fail_damaged(session.owner, diag, "has no live table");
    const method = result.bytes(0, 0);
    return if (std.mem.eql(u8, method, "orioledb")) .orioledb else .heap;
}

// ---- Watch -------------------------------------------------------------------------------------

fn watch_impl(context: *anyopaque, options: store.WatchOptions, diag: *Diag) Error!store.Watch {
    const self = PostgresStore.from(context);
    const meta = try read_meta(self, diag);
    if (options.from_revision <= meta.compacted_revision) {
        return failures.compacted(diag, options.from_revision, meta.compacted_revision);
    }
    if (options.from_revision > meta.revision + 1) {
        return failures.future_watch(diag, options.from_revision, meta.revision);
    }
    const slot = try claim_watch(self, options, diag);
    open_watch_connection(slot, diag) catch |err| {
        release_watch(slot);
        return err;
    };
    return .{
        .context = slot,
        .vtable = &PostgresStore.watch_vtable,
        .delivered = options.from_revision - 1,
    };
}

fn claim_watch(self: *PostgresStore, options: store.WatchOptions, diag: *Diag) Error!*WatchSlot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (&self.watches) |*slot| {
        if (slot.used) continue;
        slot.owner = self;
        slot.used = true;
        slot.conn = null;
        slot.prefix_len = @intCast(options.prefix.len);
        @memcpy(slot.prefix[0..options.prefix.len], options.prefix);
        slot.next_revision = options.from_revision;
        slot.waiting = .init(false);
        slot.notified = .init(0);
        return slot;
    }
    return failures.watch_slots_full(diag);
}

fn release_watch(slot: *WatchSlot) void {
    const self = slot.owner;
    if (slot.conn) |conn| pq.close(conn);
    slot.conn = null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    assert(slot.used);
    slot.used = false;
}

/// A connection of the watch's own. It LISTENs before the first read of the log, so a commit
/// that the read misses is announced, and one it sees is not lost either way.
fn open_watch_connection(slot: *WatchSlot, diag: *Diag) Error!void {
    const self = slot.owner;
    assert(slot.conn == null);
    const conn = try self.open_connection(diag);
    errdefer pq.close(conn);
    if (self.listen) {
        var sql: pq.SqlBuffer(128) = .{};
        sql.append("LISTEN \"");
        sql.append(self.channel());
        sql.append("\"");
        var result = try pq.exec_simple(diag, conn, sql.terminated(), .{});
        result.clear();
    }
    slot.conn = conn;
}

/// One statement on the watch's connection. A connection found dead is replaced (and listens
/// again) and the statement retried once: a read of the log is repeatable.
fn watch_run(
    slot: *WatchSlot,
    sql: [:0]const u8,
    params: *const Params,
    diag: *Diag,
) Error!pq.Result {
    const context: pq.Context = .{ .lock_timeout_ms = slot.owner.lock_timeout_ms };
    if (slot.conn == null) try open_watch_connection(slot, diag);
    return pq.exec(diag, slot.conn.?, sql, params, context) catch |err| {
        if (diag.code.? != .E0213) return err;
        diag.reset();
        pq.close(slot.conn.?);
        slot.conn = null;
        try open_watch_connection(slot, diag);
        return pq.exec(diag, slot.conn.?, sql, params, context);
    };
}

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
        const batch = try poll_once(slot, arena, diag);
        if (batch.events.len > 0) return batch;
        const now = std.Io.Clock.awake.now(self.io);
        const waited_ms = started.durationTo(now).toMilliseconds();
        if (waited_ms >= timeout_ms) return batch;
        const left_ms: u32 = timeout_ms - @as(u32, @intCast(waited_ms));
        wait_for_wakeup(slot, @min(left_ms, self.watch_fallback_ms));
    }
}

/// Sleeps until the server announces a commit or `wait_ms` has passed, whichever is first. The
/// announcement is a hint to read sooner; the caller reads the log either way.
fn wait_for_wakeup(slot: *WatchSlot, wait_ms: u32) void {
    const self = slot.owner;
    assert(wait_ms > 0);
    const conn = slot.conn orelse return;
    if (!self.listen) {
        self.io.sleep(.fromMilliseconds(wait_ms), .awake) catch {};
        return;
    }
    // A notification libpq has already read (while it read a result) never reaches the socket.
    if (!pq.consume(conn)) return; // The connection is gone; the next read reports it.
    if (take_notifications(slot, conn)) return;
    slot.waiting.store(true, .release);
    defer slot.waiting.store(false, .release);
    var fds = [1]std.posix.pollfd{.{
        .fd = pq.socket(conn),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @intCast(wait_ms)) catch return;
    if (ready == 0) return;
    if (pq.consume(conn)) _ = take_notifications(slot, conn);
}

/// Discards every queued notification; true if there were any.
fn take_notifications(slot: *WatchSlot, conn: *c.PGconn) bool {
    var any = false;
    while (pq.take_notification(conn)) any = true;
    if (any) _ = slot.notified.fetchAdd(1, .monotonic);
    return any;
}

/// One read of the log from the watch's position, in one snapshot with the revision it reports
/// as the bookmark. Defence in depth: the revisions it is about to cover must all be there. On a
/// hole it reads again a bounded number of times and then raises a bug (ZC-B0001); it never
/// skips a revision.
fn poll_once(slot: *WatchSlot, arena: Allocator, diag: *Diag) Error!store.WatchBatch {
    assert(slot.used);
    var attempt: u32 = 0;
    while (true) { // Ends with a batch, an error, or the retries running out.
        const position = slot.next_revision;
        const batch = try read_log(slot, arena, diag);
        assert(batch.revision + 1 >= position);
        const covered = batch.revision >= position; // Else nothing new: nothing to check.
        if (!covered or try revisions_present(slot, position, batch.revision, diag)) {
            slot.next_revision = batch.revision + 1;
            return batch;
        }
        if (attempt == constants.store_watch_hole_retries_max) {
            return fail_hole(diag, position, batch.revision);
        }
        attempt += 1;
        const wait: std.Io.Duration = .fromMilliseconds(constants.store_watch_hole_wait_ms);
        slot.owner.io.sleep(wait, .awake) catch {};
    }
}

/// A batch never splits a revision: when the row limit cuts one in half, that revision is held
/// back whole for the next call.
fn read_log(slot: *WatchSlot, arena: Allocator, diag: *Diag) Error!store.WatchBatch {
    var end_buffer: [constants.store_key_bytes_max]u8 = undefined;
    const prefix = slot.prefix[0..slot.prefix_len];
    var params: Params = .{};
    params.add_int8(slot.next_revision);
    params.add_bytes(.text, prefix);
    params.add_optional_text(prefix_end(&end_buffer, prefix));
    params.add_int8(@as(u64, constants.store_watch_batch_max) + 1);
    var result = try watch_run(slot, sql_watch, &params, diag);
    defer result.clear();
    const meta = try checked_meta(slot.owner, &result, diag);
    if (slot.next_revision <= meta.compacted_revision) {
        return failures.compacted(diag, slot.next_revision, meta.compacted_revision);
    }
    var events: std.ArrayList(store.Event) = .empty;
    var held_back: ?Revision = null;
    for (0..result.rows()) |index| {
        const row: u32 = @intCast(index);
        if (result.is_null(row, 2)) break; // The meta row with no event joined to it.
        if (events.items.len == constants.store_watch_batch_max) {
            held_back = result.unsigned(row, 5);
            break;
        }
        const kind: store.EventKind = if (result.boolean(row, 7)) .delete else .put;
        const kv = try row_kv(&result, row, arena, diag);
        events.append(arena, .{ .kind = kind, .kv = kv }) catch return failures.no_memory(diag);
    }
    var bookmark = meta.revision; // Caught up: everything to the snapshot's head is here.
    if (held_back) |revision| {
        bookmark = revision - 1;
        drop_revision(&events, revision);
    }
    return .{ .events = events.items, .revision = bookmark };
}

/// True if every revision from `from` to `to` has at least one row in the log, whatever its key.
/// A compaction that moved past `from` since the read is not a hole; it is `Compacted`.
fn revisions_present(slot: *WatchSlot, from: Revision, to: Revision, diag: *Diag) Error!bool {
    assert(from <= to);
    var params: Params = .{};
    params.add_int8(from);
    params.add_int8(to);
    var result = try watch_run(slot, sql_revision_count, &params, diag);
    defer result.clear();
    if (result.unsigned(0, 0) == to - from + 1) return true;
    const compacted = result.unsigned(0, 1);
    if (from <= compacted) return failures.compacted(diag, from, compacted);
    return false;
}

fn watch_close_impl(context: *anyopaque) void {
    const slot: *WatchSlot = @ptrCast(@alignCast(context));
    release_watch(slot);
}

// ---- Tests -------------------------------------------------------------------------------------
// The behaviour every backend shares is checked by the conformance suite
// (`zig build test-store -Dbackend=postgres`). These cover what only this backend has: the
// schema, the failures, the connections, NOTIFY and the lease clock. Those that need a database
// read it from `ZCUBE_TEST_POSTGRES` and are skipped when it is unset; `test-store` sets it, and
// also sets `ZCUBE_TEST_POSTGRES_REQUIRED`, which turns a missing one into a failure.

const testing = std.testing;
const codes = @import("diag/codes.zig");
const repeat = @import("test_util.zig").repeat;

test "schema names are small, lowercase and start with a letter" {
    // Goal: the name is safe in quotes and in a NOTIFY channel. Method: each rule once, and the
    // longest name that is still accepted.
    try testing.expect(schema_problem("zcube") == null);
    try testing.expect(schema_problem("_x9") == null);
    try testing.expect(schema_problem(repeat('a', 32)) == null);
    try testing.expect(schema_problem(repeat('a', 33)) != null);
    try testing.expect(schema_problem("") != null);
    try testing.expect(schema_problem("9lives") != null);
    try testing.expect(schema_problem("Zcube") != null);
    try testing.expect(schema_problem("a\"b") != null);
    try testing.expect(schema_problem("a-b") != null);
}

test "OrioleDB is chosen from the catalogue, and only store_live moves" {
    // Goal: the OrioleDB path is decided correctly although it can't run here. Method: the three
    // catalogue answers through `plan_access`, and the DDL it picks between.
    const installed: Catalogue = .{ .installed = true, .available = true };
    try testing.expectEqual(AccessPlan.orioledb, plan_access(installed));
    const only_files: Catalogue = .{ .installed = false, .available = true };
    try testing.expectEqual(AccessPlan.orioledb_after_create, plan_access(only_files));
    const absent: Catalogue = .{ .installed = false, .available = false };
    try testing.expectEqual(AccessPlan.heap, plan_access(absent));
    const heap = schema_sql(.heap);
    const oriole = schema_sql(.orioledb);
    try testing.expect(std.mem.indexOf(u8, heap, "orioledb") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, oriole, "USING orioledb"));
    const live = std.mem.indexOf(u8, oriole, "CREATE TABLE store_live").?;
    const using = std.mem.indexOf(u8, oriole, "USING orioledb").?;
    const lease_table = std.mem.indexOf(u8, oriole, "CREATE TABLE store_lease").?;
    try testing.expect(live < using and using < lease_table);
    // Everything but that one clause is the same, which is what "works on heap" means.
    try testing.expectEqual(heap.len + " USING orioledb".len, oriole.len);
}

test "settings that cannot work are refused before any server is contacted" {
    // Goal: a bad setting is ZC-E0201 with a fix, not a libpq error. Method: an empty
    // connection string, an over-long one, and a schema with a bad name.
    var diag: Diag = undefined;
    diag.reset();
    var db: PostgresStore = undefined;
    const bad = [_]OpenOptions{
        .{ .conninfo = "", .create = true },
        .{
            .conninfo = repeat('x', constants.store_postgres_conninfo_bytes_max + 1),
            .create = true,
        },
        .{ .conninfo = "host=127.0.0.1", .schema = "No Good", .create = true },
    };
    for (bad) |options| {
        try testing.expectError(error.BackendFailed, db.open(testing.io, options, &diag));
        try testing.expectEqual(codes.Code.E0201, diag.code.?);
        try testing.expect(diag.fixes.count >= 1);
        try testing.expectEqualStrings("no Postgres server was contacted", diag.last_cause().?);
        diag.reset();
    }
}

test "opening a store whose server is down is ZC-E0201, as the demo shows it" {
    // Goal: HANDOFF C0 demo step 5: a stopped Postgres reads as a store-backend problem with a
    // fix, not as a connection-library error. Method: open against a port nobody listens on,
    // and check the text a user would read, and that the store is left closed.
    var diag: Diag = undefined;
    diag.reset();
    var db: PostgresStore = undefined;
    const options: OpenOptions = .{
        .conninfo = "host=127.0.0.1 port=1 user=zcube dbname=zcube",
        .create = true,
    };
    try testing.expectError(error.BackendFailed, db.open(testing.io, options, &diag));
    try testing.expectEqual(codes.Code.E0201, diag.code.?);
    try testing.expectEqualStrings("can't reach the store backend", diag.entry().summary);
    try testing.expectEqualStrings(
        "the Postgres server at 127.0.0.1 port 1 did not accept a connection",
        diag.last_cause().?,
    );
    try testing.expectEqual(@as(u8, constants.exit_external), diag.exit_code());
    try testing.expect(diag.fixes.count >= 2);
}

/// The database the tests use, or a skip (or, under `test-store`, a failure) when none is set.
fn test_conninfo() ![:0]const u8 {
    if (testing.environ.getPosix("ZCUBE_TEST_POSTGRES")) |settings| return settings;
    if (testing.environ.getPosix("ZCUBE_TEST_POSTGRES_REQUIRED") != null) {
        return error.PostgresNotConfigured;
    }
    return error.SkipZigTest;
}

/// One schema of the test database, dropped when the test ends, and a clock for its leases.
const Fixture = struct {
    manual: ManualClock,
    diag: Diag,
    conninfo: [:0]const u8,
    schema_buffer: [32]u8,
    schema_len: u32,

    fn create() !*Fixture {
        const conninfo = try test_conninfo();
        const fixture = try testing.allocator.create(Fixture);
        fixture.manual = .{};
        fixture.diag.reset();
        fixture.conninfo = conninfo;
        const now = std.Io.Clock.real.now(testing.io).toNanoseconds();
        const unique = std.hash.Wyhash.hash(testing.random_seed, std.mem.asBytes(&now));
        const text = try std.fmt.bufPrint(&fixture.schema_buffer, "zp_{x:0>16}", .{unique});
        fixture.schema_len = @intCast(text.len);
        return fixture;
    }

    fn destroy(fixture: *Fixture) void {
        fixture.admin_sql("DROP SCHEMA IF EXISTS \"{s}\" CASCADE", .{fixture.schema()}) catch {};
        testing.allocator.destroy(fixture);
    }

    fn schema(fixture: *const Fixture) []const u8 {
        return fixture.schema_buffer[0..fixture.schema_len];
    }

    fn options(fixture: *Fixture, creating: bool) OpenOptions {
        return .{
            .conninfo = fixture.conninfo,
            .schema = fixture.schema(),
            .create = creating,
            .lease_time = .{ .clock = fixture.manual.clock() },
        };
    }

    /// A new, opened store; the caller closes and frees it with `release`.
    fn open_new(fixture: *Fixture, open_options: OpenOptions) !*PostgresStore {
        const db = try testing.allocator.create(PostgresStore);
        errdefer testing.allocator.destroy(db);
        try db.open(testing.io, open_options, &fixture.diag);
        return db;
    }

    /// Runs SQL as an outside tool would, on a connection of its own, and returns the first
    /// column of the first row if the statement is a SELECT of a bigint (else 0).
    fn admin_sql(fixture: *Fixture, comptime format: []const u8, args: anytype) !void {
        _ = try fixture.admin_value(format, args);
    }

    fn admin_value(fixture: *Fixture, comptime format: []const u8, args: anytype) !i64 {
        var text: [512]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&text, format, args, 0);
        var diag: Diag = undefined; // Its own: the fixture's may hold the failure a test expects.
        diag.reset();
        const conn = try pq.connect(&diag, fixture.conninfo, "SELECT 1");
        defer pq.close(conn);
        var result = try pq.exec(&diag, conn, sql, &no_params, .{});
        defer result.clear();
        if (result.rows() == 0 or c.PQnfields(result.raw) == 0) return 0;
        return result.int8(0, 0);
    }
};

fn release(db: *PostgresStore) void {
    db.close();
    testing.allocator.destroy(db);
}

/// A failure is a designed diagnostic: the code, a fix, and a last cause that is the operator's.
fn expect_designed(diag: *const Diag, code: codes.Code) !void {
    try testing.expectEqual(code, diag.code.?);
    try testing.expect(diag.fixes.count >= 1);
    const last = diag.last_cause().?;
    try testing.expect(std.mem.indexOf(u8, last, "libpq") == null);
    try testing.expect(std.mem.indexOf(u8, last, "SQLSTATE") == null);
}

fn expect_open_fails(fixture: *Fixture, open_options: OpenOptions, code: codes.Code) !void {
    const db = try testing.allocator.create(PostgresStore);
    defer testing.allocator.destroy(db);
    try testing.expectError(error.BackendFailed, db.open(testing.io, open_options, &fixture.diag));
    try expect_designed(&fixture.diag, code);
    fixture.diag.reset();
}

const put_a: store.Op = .{ .put = .{ .key = "/a", .value = "1" } };

/// The server-side process id of the store's first pooled connection (it must have one).
fn backend_pid(db: *PostgresStore) i64 {
    const conn = db.pool[0].conn.?;
    return c.PQbackendPID(conn);
}

/// Terminates a backend and waits until the server no longer lists it, so what the test does
/// next meets a connection that is certainly gone.
fn terminate(fixture: *Fixture, pid: i64) !void {
    const kill = "SELECT pg_terminate_backend({d})::int::bigint";
    const stopped = try fixture.admin_value(kill, .{pid});
    try testing.expectEqual(@as(i64, 1), stopped);
    for (0..1000) |_| {
        const left = "SELECT count(*) FROM pg_stat_activity WHERE pid = {d}";
        if (try fixture.admin_value(left, .{pid}) == 0) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.BackendDidNotExit;
}

test "open: a missing store is created only when asked, and a mistyped name is refused" {
    // Goal: a mistyped schema does not quietly start an empty store. Method: open without
    // `create` on a schema that is not there (ZC-E0209, and nothing is created), then with it.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try expect_open_fails(fixture, fixture.options(false), .E0209);
    const exists = "SELECT count(*) FROM pg_namespace WHERE nspname = '{s}'";
    try testing.expectEqual(@as(i64, 0), try fixture.admin_value(exists, .{fixture.schema()}));
    const db = try fixture.open_new(fixture.options(true));
    try testing.expectEqual(TableAccess.heap, db.table_access); // No OrioleDB on this server.
    release(db);
    try testing.expectEqual(@as(i64, 1), try fixture.admin_value(exists, .{fixture.schema()}));
    release(try fixture.open_new(fixture.options(false))); // Now it is there.
}

test "open: a schema that holds other tables is ZC-E0209 and is left as it was" {
    // Goal: never initialise over something that is not ours. Method: a schema with a table of
    // someone else's, opened with `create`; then the same table in the way of an empty store.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try fixture.admin_sql("CREATE SCHEMA \"{s}\"", .{fixture.schema()});
    try fixture.admin_sql("CREATE TABLE \"{s}\".somebody_elses (x int)", .{fixture.schema()});
    try expect_open_fails(fixture, fixture.options(true), .E0209);
    const tables = "SELECT count(*) FROM pg_tables WHERE schemaname = '{s}'";
    try testing.expectEqual(@as(i64, 1), try fixture.admin_value(tables, .{fixture.schema()}));
}

test "open: a store_meta that says another application is ZC-E0209" {
    // Goal: the identity row decides, not the table's name. Method: make a store, change the
    // application it names, open it again.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    release(try fixture.open_new(fixture.options(true)));
    const rename = "UPDATE \"{s}\".store_meta SET application = 'other'";
    try fixture.admin_sql(rename, .{fixture.schema()});
    try expect_open_fails(fixture, fixture.options(true), .E0209);
}

test "open: a schema from a newer zcube is ZC-E0210 and is not touched" {
    // Goal: refuse rather than guess. Method: make a store, bump its schema version the way a
    // newer zcube would, and open it again; the version must still be there afterwards.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    release(try fixture.open_new(fixture.options(true)));
    try fixture.admin_sql("UPDATE \"{s}\".store_meta SET schema_version = 99", .{fixture.schema()});
    try expect_open_fails(fixture, fixture.options(true), .E0210);
    try expect_open_fails(fixture, fixture.options(false), .E0210);
    const version = "SELECT schema_version::bigint FROM \"{s}\".store_meta";
    try testing.expectEqual(@as(i64, 99), try fixture.admin_value(version, .{fixture.schema()}));
}

test "open: wrong credentials are ZC-E0211 and a missing database ZC-E0212" {
    // Goal: the two failures an operator mistypes settings into are told apart, with fixes that
    // name what to run. Method: a role that does not exist (on a server that checks passwords,
    // a wrong password fails the same way), and a database that does not exist.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var text: [512]u8 = undefined;
    const settings = "{s} user=zc_no_such_role password=wrong";
    const user = try std.fmt.bufPrintSentinel(&text, settings, .{fixture.conninfo}, 0);
    var denied = fixture.options(true);
    denied.conninfo = user;
    try expect_open_fails(fixture, denied, .E0211);
    var other: [512]u8 = undefined;
    const named = "{s} dbname=zc_no_such_database";
    const database = try std.fmt.bufPrintSentinel(&other, named, .{fixture.conninfo}, 0);
    var missing = fixture.options(true);
    missing.conninfo = database;
    const db = try testing.allocator.create(PostgresStore);
    defer testing.allocator.destroy(db);
    try testing.expectError(error.BackendFailed, db.open(testing.io, missing, &fixture.diag));
    try expect_designed(&fixture.diag, .E0212);
    try testing.expectEqualStrings(
        "Postgres at 127.0.0.1 has no database named zc_no_such_database",
        fixture.diag.last_cause().?,
    );
    const create = fixture.diag.fixes.slice()[1];
    try testing.expect(std.mem.startsWith(u8, create.command.slice(), "createdb "));
}

test "open: two servers starting on an empty schema initialise it once" {
    // Goal: the advisory lock makes concurrent openers take turns. Method: four threads open
    // the same new schema at once; all must succeed and there must be one meta row.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const Job = struct {
        fixture: *Fixture,
        ok: bool = false,

        fn run(job: *@This()) void {
            var diag: Diag = undefined;
            diag.reset();
            const db = testing.allocator.create(PostgresStore) catch return;
            defer testing.allocator.destroy(db);
            db.open(testing.io, job.fixture.options(true), &diag) catch return;
            db.close();
            job.ok = true;
        }
    };
    var jobs: [4]Job = undefined;
    var threads: [4]std.Thread = undefined;
    for (&jobs, &threads) |*job, *thread| {
        job.* = .{ .fixture = fixture };
        thread.* = try std.Thread.spawn(.{}, Job.run, .{job});
    }
    for (threads) |thread| thread.join();
    for (jobs) |job| try testing.expect(job.ok);
    const rows = "SELECT count(*) FROM \"{s}\".store_meta";
    try testing.expectEqual(@as(i64, 1), try fixture.admin_value(rows, .{fixture.schema()}));
}

test "a connection that died while idle is replaced before the next operation" {
    // Goal: a restart of Postgres between two requests costs nothing. Method: use the store,
    // terminate its connection's backend, and write again; the write must succeed.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    const s = db.interface();
    _ = try s.txn(.{ .on_success = &.{put_a} }, &fixture.diag);
    try terminate(fixture, backend_pid(db));
    const again = try s.txn(.{ .on_success = &.{put_a} }, &fixture.diag);
    try testing.expectEqual(@as(Revision, 2), again.revision);
}

test "a connection lost inside a transaction is ZC-E0213, rolled back, and the store recovers" {
    // Goal: a drop mid-operation is reported with what happened to the work, and does not
    // poison the pool. Method: begin and take the writer lock on a session, terminate its
    // backend, run the next statement (ZC-E0213: nothing was changed), release, and check that
    // the store is still usable and has not moved.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    var session = try db.acquire(&fixture.diag);
    try session.begin(&fixture.diag);
    const writer: Writer = .{ .session = &session, .diag = &fixture.diag };
    _ = try writer.bump();
    try terminate(fixture, c.PQbackendPID(session.conn.?));
    try testing.expectError(error.BackendFailed, writer.apply_op(put_a, 1, 0));
    try expect_designed(&fixture.diag, .E0213);
    try testing.expectEqualStrings(
        "the connection to Postgres dropped; nothing was changed",
        fixture.diag.last_cause().?,
    );
    fixture.diag.reset();
    session.release();
    const status = try db.interface().status(&fixture.diag);
    try testing.expectEqual(@as(Revision, 0), status.revision);
    _ = try db.interface().txn(.{ .on_success = &.{put_a} }, &fixture.diag);
}

test "a writer that waits too long for the lock is ZC-E0208, and nothing is left half done" {
    // Goal: a stuck peer is an operating error with a name, not a hang. Method: one session holds
    // the writer lock; a store with a short lock wait tries to write (ZC-E0208), reads still work
    // (a reader takes no lock), and after the holder lets go the write succeeds as revision 1.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var options = fixture.options(true);
    options.lock_timeout_ms = 100;
    const waiter = try fixture.open_new(options);
    defer release(waiter);
    const holder = try fixture.open_new(fixture.options(false));
    defer release(holder);
    var session = try holder.acquire(&fixture.diag);
    try session.begin(&fixture.diag);
    const writer: Writer = .{ .session = &session, .diag = &fixture.diag };
    _ = try writer.bump();
    const s = waiter.interface();
    const refused = s.txn(.{ .on_success = &.{put_a} }, &fixture.diag);
    try testing.expectError(error.BackendFailed, refused);
    try expect_designed(&fixture.diag, .E0208);
    try testing.expectEqual(@as(u8, constants.exit_environment), fixture.diag.exit_code());
    fixture.diag.reset();
    try testing.expectEqual(@as(Revision, 0), (try s.status(&fixture.diag)).revision);
    session.release(); // Rolls the holder's bump back.
    const written = try s.txn(.{ .on_success = &.{put_a} }, &fixture.diag);
    try testing.expectEqual(@as(Revision, 1), written.revision);
}

test "the pool is bounded: a further operation waits, then is ZC-E0207" {
    // Goal: connections are a counted resource. Method: take every connection of a store, ask for
    // one more with a short wait (ZC-E0207), give one back, and the same call succeeds.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var options = fixture.options(true);
    options.pool_wait_ms = 20;
    const db = try fixture.open_new(options);
    defer release(db);
    var held: [constants.store_postgres_connections_max]Session = undefined;
    for (&held) |*session| session.* = try db.acquire(&fixture.diag);
    try testing.expectError(error.NoCapacity, db.acquire(&fixture.diag));
    try testing.expectEqual(codes.Code.E0207, fixture.diag.code.?);
    fixture.diag.reset();
    held[0].release();
    var again = try db.acquire(&fixture.diag);
    again.release();
    for (held[1..]) |*session| session.release();
}

test "lease time is Postgres's own by default, so a stored deadline decides expiry" {
    // Goal: with `.database` two servers agree and no clock of ours is consulted. Method: grant
    // a lease and check its deadline is about now + ttl on Postgres's clock; then move the
    // deadline into the past in the table: the lease can no longer be renewed or used, and
    // `expire_leases` deletes its key, with no clock advanced by hand.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var options = fixture.options(true);
    options.lease_time = .database;
    const db = try fixture.open_new(options);
    defer release(db);
    const s = db.interface();
    const lease = try s.lease_grant(60_000, &fixture.diag);
    const remaining = "SELECT deadline_ms - " ++
        "FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint " ++
        "FROM \"{s}\".store_lease WHERE id = {d}";
    const left_ms = try fixture.admin_value(remaining, .{ fixture.schema(), lease.id });
    try testing.expect(left_ms > 50_000 and left_ms <= 60_000);
    const keyed: store.Op = .{ .put = .{ .key = "/n", .value = "node", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{keyed} }, &fixture.diag);
    try testing.expectEqual(lease.id, (try s.lease_keepalive(lease.id, &fixture.diag)).id);
    try testing.expectEqual(@as(u32, 0), try s.expire_leases(&fixture.diag));
    const past = "UPDATE \"{s}\".store_lease SET deadline_ms = 1 WHERE id = {d}";
    try fixture.admin_sql(past, .{ fixture.schema(), lease.id });
    try testing.expectError(error.LeaseNotFound, s.lease_keepalive(lease.id, &fixture.diag));
    fixture.diag.reset();
    const dead = s.txn(.{ .on_success = &.{keyed} }, &fixture.diag);
    try testing.expectError(error.LeaseNotFound, dead);
    fixture.diag.reset();
    try testing.expectEqual(@as(u32, 1), try s.expire_leases(&fixture.diag));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try s.get(arena_state.allocator(), "/n", null, &fixture.diag);
    try testing.expect(got.kv == null);
}

test "a lease clock is read once per call: the injected clock decides, not the database" {
    // Goal: the test seam does what the conformance suite relies on. Method: a lease on the
    // injected clock expires when that clock passes its deadline, though Postgres's time has
    // barely moved.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    const s = db.interface();
    const lease = try s.lease_grant(1000, &fixture.diag);
    try testing.expectEqual(@as(u32, 0), try s.expire_leases(&fixture.diag));
    fixture.manual.advance(1001);
    try testing.expectEqual(@as(u32, 1), try s.expire_leases(&fixture.diag));
    try testing.expectError(error.LeaseNotFound, s.lease_keepalive(lease.id, &fixture.diag));
    fixture.diag.reset();
}

/// A watch's slot, for the tests that look at how it waits.
fn slot_of(watch: *store.Watch) *WatchSlot {
    return @ptrCast(@alignCast(watch.context));
}

const Waiter = struct {
    watch: *store.Watch,
    timeout_ms: u32,
    arena: std.heap.ArenaAllocator,
    events: u32 = 0,
    failed: bool = false,

    fn run(job: *Waiter) void {
        var diag: Diag = undefined;
        diag.reset();
        const batch = job.watch.next(job.arena.allocator(), job.timeout_ms, &diag) catch {
            job.failed = true;
            return;
        };
        job.events = @intCast(batch.events.len);
    }
};

/// Waits (bounded) until the watch is asleep on its socket or its wait, then writes.
fn write_once_waiting(fixture: *Fixture, writer: store.Store, watch: *store.Watch) !void {
    for (0..5000) |_| {
        if (slot_of(watch).waiting.load(.acquire)) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.WatchNeverWaited;
    const put_w: store.Op = .{ .put = .{ .key = "/w/a", .value = "1" } };
    _ = try writer.txn(.{ .on_success = &.{put_w} }, &fixture.diag);
}

test "watch: a commit wakes a watch that would otherwise sleep a minute" {
    // Goal: NOTIFY wakes a long-poll watch at once. Method: the fallback poll is set to a
    // minute, so only a notification can end the wait in time; a thread waits in `next`, the test
    // writes once it sees the watch asleep, and the thread must return the event and count one
    // notification. (Without NOTIFY the thread would run out its 30 s and return nothing.)
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var options = fixture.options(true);
    options.watch_fallback_ms = 60_000;
    const watching = try fixture.open_new(options);
    defer release(watching);
    const writer = try fixture.open_new(fixture.options(false));
    defer release(writer);
    const from_one: store.WatchOptions = .{ .prefix = "/w/", .from_revision = 1 };
    var watch = try watching.interface().watch(from_one, &fixture.diag);
    defer watch.close();
    var job: Waiter = .{ .watch = &watch, .timeout_ms = 30_000, .arena = .init(testing.allocator) };
    defer job.arena.deinit();
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&job});
    write_once_waiting(fixture, writer.interface(), &watch) catch |err| {
        const put_x: store.Op = .{ .put = .{ .key = "/w/a", .value = "x" } };
        _ = try writer.interface().txn(.{ .on_success = &.{put_x} }, &fixture.diag);
        thread.join();
        return err;
    };
    thread.join();
    try testing.expect(!job.failed);
    try testing.expectEqual(@as(u32, 1), job.events);
    try testing.expect(slot_of(&watch).notified.load(.monotonic) >= 1);
}

test "watch: with no notifications at all, the fallback poll still delivers" {
    // Goal: a watch never depends on a notification arriving. Method: LISTEN is off and the
    // fallback is 10 ms; a thread waits, the test writes, and the thread must get the event
    // having been woken by no notification.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var options = fixture.options(true);
    options.listen = false;
    options.watch_fallback_ms = 10;
    const watching = try fixture.open_new(options);
    defer release(watching);
    const writer = try fixture.open_new(fixture.options(false));
    defer release(writer);
    const from_one: store.WatchOptions = .{ .prefix = "/w/", .from_revision = 1 };
    var watch = try watching.interface().watch(from_one, &fixture.diag);
    defer watch.close();
    var job: Waiter = .{ .watch = &watch, .timeout_ms = 30_000, .arena = .init(testing.allocator) };
    defer job.arena.deinit();
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&job});
    try testing.io.sleep(.fromMilliseconds(30), .awake);
    const put_w: store.Op = .{ .put = .{ .key = "/w/a", .value = "1" } };
    _ = try writer.interface().txn(.{ .on_success = &.{put_w} }, &fixture.diag);
    thread.join();
    try testing.expect(!job.failed);
    try testing.expectEqual(@as(u32, 1), job.events);
    try testing.expectEqual(@as(u32, 0), slot_of(&watch).notified.load(.monotonic));
}

test "watch: a hole in the log is re-read, then ZC-B0001, and the revision is never skipped" {
    // Goal: the defence in depth works. Method: three revisions; revision 2's rows are moved out
    // of the log as a lost commit would leave it. A watch from 1 must fail with a bug diagnostic
    // after re-reading, and must not deliver 3 past the hole. With the rows put back, the same
    // watch delivers 1, 2 and 3 in order: its position did not move.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    const s = db.interface();
    for ([_][]const u8{ "1", "2", "3" }) |value| {
        const op: store.Op = .{ .put = .{ .key = "/h/k", .value = value } };
        _ = try s.txn(.{ .on_success = &.{op} }, &fixture.diag);
    }
    const schema = fixture.schema();
    const away = "UPDATE \"{s}\".store_log SET revision = 20 WHERE revision = 2";
    try fixture.admin_sql(away, .{schema});
    var watch = try s.watch(.{ .prefix = "/h/", .from_revision = 1 }, &fixture.diag);
    defer watch.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BackendFailed, watch.next(arena, 0, &fixture.diag));
    try testing.expectEqual(codes.Code.B0001, fixture.diag.code.?);
    try testing.expectEqual(@as(u8, constants.exit_internal), fixture.diag.exit_code());
    fixture.diag.reset();
    const back = "UPDATE \"{s}\".store_log SET revision = 2 WHERE revision = 20";
    try fixture.admin_sql(back, .{schema});
    const batch = try watch.next(arena, 0, &fixture.diag);
    try testing.expectEqual(@as(usize, 3), batch.events.len);
    for (batch.events, 1..) |event, revision| {
        try testing.expectEqual(@as(Revision, revision), event.kv.mod_revision);
    }
}

test "watch: every slot is its own connection, and one more than the limit is ZC-E0207" {
    // Goal: watches are bounded by the connections they hold. Method: open the most the backend
    // allows, check the next is refused with a code, close one, and the same call succeeds.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    const s = db.interface();
    var watches: [constants.store_postgres_watches_max]store.Watch = undefined;
    var opened: usize = 0;
    defer for (watches[0..opened]) |*watch| watch.close();
    for (&watches) |*watch| {
        watch.* = try s.watch(.{ .prefix = "/", .from_revision = 1 }, &fixture.diag);
        opened += 1;
    }
    const one_more = s.watch(.{ .prefix = "/", .from_revision = 1 }, &fixture.diag);
    try testing.expectError(error.NoCapacity, one_more);
    try testing.expectEqual(codes.Code.E0207, fixture.diag.code.?);
    fixture.diag.reset();
    watches[opened - 1].close();
    opened -= 1;
    var again = try s.watch(.{ .prefix = "/", .from_revision = 1 }, &fixture.diag);
    again.close();
}

test "a store whose tables are removed under it is ZC-E0209, not a libpq error" {
    // Goal: a schema damaged while the server runs is a designed diagnostic. Method: write, drop
    // the live table from outside, read; the SQLSTATE for a missing table must become E0209.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    const s = db.interface();
    _ = try s.txn(.{ .on_success = &.{put_a} }, &fixture.diag);
    try fixture.admin_sql("DROP TABLE \"{s}\".store_live", .{fixture.schema()});
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const read = s.get(arena_state.allocator(), "/a", null, &fixture.diag);
    try testing.expectError(error.BackendFailed, read);
    try expect_designed(&fixture.diag, .E0209);
}

test "an extension that cannot be installed leaves the transaction usable" {
    // Goal: the OrioleDB fallback mechanism, which the real extension can't exercise here.
    // Method: ask a savepoint to install an extension that does not exist; it must say no, and
    // the schema must still be creatable in the same transaction afterwards.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    var session = try db.acquire(&fixture.diag);
    defer session.release();
    try session.begin(&fixture.diag);
    const installed = try try_install_extension(&session, "zcube_no_such_extension", &fixture.diag);
    try testing.expect(!installed);
    try testing.expect(fixture.diag.code == null);
    try session.simple("CREATE TEMP TABLE zcube_still_usable (x int)", &fixture.diag);
}

test "drop_schema removes the store and only the store" {
    // Goal: the reset used by tests and tooling is exact. Method: a store and an unrelated schema;
    // drop the store's; the other stays.
    const fixture = try Fixture.create();
    defer fixture.destroy();
    var other: [48]u8 = undefined;
    const other_name = try std.fmt.bufPrint(&other, "{s}_keep", .{fixture.schema()});
    try fixture.admin_sql("CREATE SCHEMA \"{s}\"", .{other_name});
    defer fixture.admin_sql("DROP SCHEMA \"{s}\"", .{other_name}) catch {};
    const db = try fixture.open_new(fixture.options(true));
    defer release(db);
    try db.drop_schema(&fixture.diag);
    const count = "SELECT count(*) FROM pg_namespace WHERE nspname IN ('{s}', '{s}')";
    const left = try fixture.admin_value(count, .{ fixture.schema(), other_name });
    try testing.expectEqual(@as(i64, 1), left);
}
