//! `Store`: control-plane storage, a versioned key-value store with etcd-like semantics. The
//! API server and the controllers use only this; there is no backend-specific SQL above it.
//! Backends: Postgres, SQLite, and `store_memory.zig` (the reference the tests pin semantics to).
//! How a backend realises these rules is in docs/store-design.md; the keys are in docs/keys.md.
//!
//! ## Revisions
//!
//! One global, monotonic `Revision` per store. A store starts at revision 0 (empty). Every
//! committed write transaction that changes at least one key takes the next revision, and all
//! the events it produces carry it. A transaction that changes nothing (a delete of an absent
//! key, a failed compare with no failure ops) takes no revision. Revisions never repeat and are
//! never skipped: a reader that has seen revision N has seen every change up to N.
//!
//! ## Failure
//!
//! Every operation that can fail takes a `*Diag` and returns a plain `Error`. The error says
//! THAT it failed; the `Diag` says WHY, with the code in the table below, so a store failure
//! reaches `zcube why` intact. A caller that handles the error itself (a controller that
//! relists after `Compacted`) calls `diag.reset()`; one that cannot hands the `Diag` up.
//!
//!     error.Compacted       ZC-E0203   a revision older than the compaction point
//!     error.FutureRevision  ZC-E0204   a revision above the store's current one
//!     error.LeaseNotFound   ZC-E0205   unknown, expired or revoked lease
//!     error.TooLarge        ZC-E0206   key, value, transaction or ttl over its bound
//!     error.NoCapacity      ZC-E0207   watch slots, lease slots or arena exhausted
//!     error.BackendFailed   ZC-E0201 (unreachable) or ZC-E0202 (the backend refused or failed)
//!
//! ## Memory
//!
//! Everything a call returns (keys, values, event lists) is allocated from the `arena` the
//! caller passes in, and is valid until the caller resets or frees that arena. The store keeps
//! no reference to the caller's arguments after a call returns: it copies what it keeps. A
//! request or a reconcile pass owns one arena (`constants.request_arena_bytes_max`); running out
//! of it is `error.NoCapacity`, never a crash.
//!
//! ## Concurrency
//!
//! A `Store` may be used from several threads at once. Each operation is atomic and
//! linearizable with respect to the revision order. A `Watch` is used by one thread at a time.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;

pub const Revision = u64;

/// 0 means "no lease".
pub const LeaseId = u64;
pub const lease_none: LeaseId = 0;

pub const Error = error{
    Compacted,
    FutureRevision,
    LeaseNotFound,
    TooLarge,
    NoCapacity,
    BackendFailed,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
    /// The revision at which this key was last created (a put of an absent key).
    create_revision: Revision,
    /// The revision of the write that produced this value. Never 0 for a key that exists.
    mod_revision: Revision,
    lease: LeaseId = lease_none,
};

pub const Status = struct {
    /// The current revision: that of the latest committed write, 0 for an empty store.
    revision: Revision,
    /// History older than this is gone: reads and watches below it fail with `Compacted`.
    compacted_revision: Revision,
};

// ---- Reads ---------------------------------------------------------------------------------

pub const GetResult = struct {
    /// Null if the key does not exist at `revision`; that is not an error.
    kv: ?KeyValue,
    /// The revision the read was made at: `at_revision` if given, else the current one.
    revision: Revision,
};

pub const ListOptions = struct {
    /// Keys that start with these bytes. The empty prefix lists everything.
    prefix: []const u8,
    /// Read the state as of this revision. Null: the current state. Pass the `revision` of the
    /// first page to read the following pages consistently.
    at_revision: ?Revision = null,
    /// At most this many entries, from 1 to `constants.store_list_limit_max`. A page also ends
    /// early once its values total `constants.store_page_bytes_max` (it has at least one entry).
    limit: u32,
    /// Resume after this key, as returned in `ListResult.continue_after`. Null: from the start.
    continue_after: ?[]const u8 = null,
};

pub const ListResult = struct {
    /// Ascending by key, bytewise.
    kvs: []const KeyValue,
    /// The revision the page was read at (the current one, if `at_revision` was null).
    revision: Revision,
    /// Set if more entries follow: pass it as `continue_after`, with `at_revision = revision`.
    continue_after: ?[]const u8,
};

// ---- Transactions --------------------------------------------------------------------------

/// "The key's `mod_revision` equals `mod_revision`." A `mod_revision` of 0 means the key must
/// not exist. This one comparison is compare-and-swap, create-only, and delete-if-unchanged.
pub const Compare = struct {
    key: []const u8,
    mod_revision: Revision,
};

pub const Put = struct {
    key: []const u8,
    value: []const u8,
    /// Attaches the key to a lease; the key is deleted when the lease ends. `lease_none`
    /// detaches it: a put replaces the lease association along with the value.
    lease: LeaseId = lease_none,
};

pub const Op = union(enum) {
    put: Put,
    /// Deleting an absent key does nothing and produces no event.
    delete: []const u8,
};

pub const TxnRequest = struct {
    /// All must hold, evaluated atomically at the commit point. Empty: always succeeds.
    compares: []const Compare = &.{},
    on_success: []const Op = &.{},
    on_failure: []const Op = &.{},
};

pub const TxnResult = struct {
    /// True if every compare held and `on_success` was applied; false if `on_failure` was.
    succeeded: bool,
    /// The revision after the transaction: the new one if it wrote, else the current one.
    revision: Revision,
};

// ---- Watch ---------------------------------------------------------------------------------

pub const EventKind = enum { put, delete };

pub const Event = struct {
    kind: EventKind,
    /// For a delete, `value` is empty and `mod_revision` is the revision of the delete.
    kv: KeyValue,
};

pub const WatchOptions = struct {
    prefix: []const u8,
    /// The first revision to deliver: events with `mod_revision >= from_revision`. A caller that
    /// has seen everything up to revision N passes N + 1.
    from_revision: Revision,
};

pub const WatchBatch = struct {
    /// Ordered by revision, then by position in the transaction. A revision's events are never
    /// split across batches. May be empty (see `Watch.next`).
    events: []const Event,
    /// Every matching event up to and including this revision has been delivered, in this
    /// batch or an earlier one. Resume from `revision + 1`. It advances even when `events` is
    /// empty, so an idle watch can reconnect without a relist.
    revision: Revision,
};

/// An open watch: an ordered, gap-free stream of the events under a prefix.
///
/// Guarantees: no event is skipped, none is repeated, none is reordered, and all events of one
/// revision arrive in one batch. If the store has compacted past the watch's position (it fell
/// behind), `next` fails with `Compacted` and the caller lists again and opens a new watch.
pub const Watch = struct {
    context: *anyopaque,
    vtable: *const WatchVTable,
    /// The `revision` of the last batch returned (or `from_revision - 1` at the start).
    delivered: Revision,

    pub const WatchVTable = struct {
        next: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            timeout_ms: u32,
            diag: *Diag,
        ) Error!WatchBatch,
        close: *const fn (context: *anyopaque) void,
    };

    /// Waits up to `timeout_ms` for events, returning at once if some are ready, and an empty
    /// batch if none arrive in time (the long-poll shape). A deterministic backend may return
    /// an empty batch at once rather than wait.
    pub fn next(
        watch: *Watch,
        arena: std.mem.Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) Error!WatchBatch {
        assert(diag.code == null);
        const batch = watch.vtable.next(watch.context, arena, timeout_ms, diag) catch |err| {
            assert(diag.code != null);
            return err;
        };
        assert(batch.revision >= watch.delivered);
        var previous: Revision = watch.delivered;
        for (batch.events) |event| {
            assert(event.kv.mod_revision > watch.delivered); // No repeats.
            assert(event.kv.mod_revision >= previous); // No reordering.
            assert(event.kv.mod_revision <= batch.revision); // No event past the bookmark.
            previous = event.kv.mod_revision;
        }
        watch.delivered = batch.revision;
        return batch;
    }

    /// Releases the watch slot. The `Watch` must not be used afterwards.
    pub fn close(watch: *Watch) void {
        watch.vtable.close(watch.context);
        watch.* = undefined;
    }
};

// ---- Leases --------------------------------------------------------------------------------

pub const Lease = struct {
    id: LeaseId,
    ttl_ms: u32,
};

// ---- The interface -------------------------------------------------------------------------

pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// What a backend implements. The wrappers below check arguments and results once, for
    /// every backend, so a backend can assume well-formed input and the callers can assume the
    /// documented postconditions.
    pub const VTable = struct {
        status: *const fn (context: *anyopaque, diag: *Diag) Error!Status,
        get: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            key: []const u8,
            at_revision: ?Revision,
            diag: *Diag,
        ) Error!GetResult,
        list: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            options: ListOptions,
            diag: *Diag,
        ) Error!ListResult,
        txn: *const fn (context: *anyopaque, request: TxnRequest, diag: *Diag) Error!TxnResult,
        watch: *const fn (context: *anyopaque, options: WatchOptions, diag: *Diag) Error!Watch,
        lease_grant: *const fn (context: *anyopaque, ttl_ms: u32, diag: *Diag) Error!Lease,
        lease_keepalive: *const fn (context: *anyopaque, id: LeaseId, diag: *Diag) Error!Lease,
        lease_revoke: *const fn (context: *anyopaque, id: LeaseId, diag: *Diag) Error!Revision,
        expire_leases: *const fn (context: *anyopaque, diag: *Diag) Error!u32,
        compact: *const fn (context: *anyopaque, revision: Revision, diag: *Diag) Error!void,
    };

    /// The current and compacted revisions.
    pub fn status(store: Store, diag: *Diag) Error!Status {
        assert(diag.code == null);
        const result = try finish(diag, store.vtable.status(store.context, diag));
        assert(result.compacted_revision <= result.revision);
        return result;
    }

    /// One key, now or `at_revision`. A missing key is `kv == null`, not an error.
    pub fn get(
        store: Store,
        arena: std.mem.Allocator,
        key: []const u8,
        at_revision: ?Revision,
        diag: *Diag,
    ) Error!GetResult {
        assert(diag.code == null);
        assert(key_problem(key) == null);
        const result = try finish(diag, store.vtable.get(
            store.context,
            arena,
            key,
            at_revision,
            diag,
        ));
        if (at_revision) |revision| assert(result.revision == revision);
        if (result.kv) |kv| {
            assert(std.mem.eql(u8, kv.key, key));
            assert(kv.mod_revision > 0);
            assert(kv.mod_revision <= result.revision);
            assert(kv.create_revision <= kv.mod_revision);
        }
        return result;
    }

    /// Entries under a prefix, one page at a time.
    pub fn list(
        store: Store,
        arena: std.mem.Allocator,
        options: ListOptions,
        diag: *Diag,
    ) Error!ListResult {
        assert(diag.code == null);
        assert(options.limit > 0);
        assert(options.limit <= constants.store_list_limit_max);
        assert(prefix_problem(options.prefix) == null);
        if (options.continue_after != null) assert(options.at_revision != null);
        const result = try finish(diag, store.vtable.list(store.context, arena, options, diag));
        assert(result.kvs.len <= options.limit);
        if (result.continue_after != null) assert(result.kvs.len > 0);
        if (options.at_revision) |revision| assert(result.revision == revision);
        var previous: ?[]const u8 = options.continue_after;
        for (result.kvs) |kv| {
            assert(std.mem.startsWith(u8, kv.key, options.prefix));
            assert(kv.mod_revision <= result.revision);
            if (previous) |before| assert(std.mem.order(u8, before, kv.key) == .lt);
            previous = kv.key;
        }
        return result;
    }

    /// Compare-and-swap. All compares hold: apply `on_success`; else apply `on_failure`. The
    /// chosen branch is applied atomically, under one revision. An oversized request is
    /// `TooLarge` before anything is read or written. Duplicate keys within one branch are a
    /// programmer error.
    pub fn txn(store: Store, request: TxnRequest, diag: *Diag) Error!TxnResult {
        assert(diag.code == null);
        for (request.compares) |compare| assert(key_problem(compare.key) == null);
        try check_txn_size(request, diag);
        assert(!has_duplicate_keys(request.on_success));
        assert(!has_duplicate_keys(request.on_failure));
        const result = try finish(diag, store.vtable.txn(store.context, request, diag));
        if (result.revision == 0) assert(request.on_success.len + request.on_failure.len == 0);
        return result;
    }

    /// Opens a watch. `from_revision` below the compaction point (or at it) is `Compacted`;
    /// more than one past the current revision is `FutureRevision`.
    pub fn watch(store: Store, options: WatchOptions, diag: *Diag) Error!Watch {
        assert(diag.code == null);
        assert(prefix_problem(options.prefix) == null);
        assert(options.from_revision > 0);
        const opened = try finish(diag, store.vtable.watch(store.context, options, diag));
        assert(opened.delivered == options.from_revision - 1);
        return opened;
    }

    /// A lease that lasts `ttl_ms` from now unless kept alive. The time is the backend's: the
    /// store's own clock decides expiry, never the caller's.
    pub fn lease_grant(store: Store, ttl_ms: u32, diag: *Diag) Error!Lease {
        assert(diag.code == null);
        try check_ttl(ttl_ms, diag);
        const lease = try finish(diag, store.vtable.lease_grant(store.context, ttl_ms, diag));
        assert(lease.id != lease_none);
        assert(lease.ttl_ms == ttl_ms);
        return lease;
    }

    /// Restarts the lease's clock for its full ttl. `LeaseNotFound` if it has ended, and a lease
    /// whose time has run out has ended even before `expire_leases` deletes its keys: it can
    /// never be renewed, so an owner that is told so can stop its work knowing the keys go.
    pub fn lease_keepalive(store: Store, id: LeaseId, diag: *Diag) Error!Lease {
        assert(diag.code == null);
        assert(id != lease_none);
        const lease = try finish(diag, store.vtable.lease_keepalive(store.context, id, diag));
        assert(lease.id == id);
        return lease;
    }

    /// Ends the lease now and deletes its keys, all under one revision, which is returned (the
    /// current revision if the lease held no keys).
    pub fn lease_revoke(store: Store, id: LeaseId, diag: *Diag) Error!Revision {
        assert(diag.code == null);
        assert(id != lease_none);
        return finish(diag, store.vtable.lease_revoke(store.context, id, diag));
    }

    /// Revokes every lease whose time has run out, each as `lease_revoke` would. Returns how
    /// many. Backends start no threads of their own: the server calls this on a timer, which
    /// keeps expiry deterministic in tests and puts the schedule in one place.
    pub fn expire_leases(store: Store, diag: *Diag) Error!u32 {
        assert(diag.code == null);
        return finish(diag, store.vtable.expire_leases(store.context, diag));
    }

    /// Discards history below `revision`: afterwards reads below it and watches from it or
    /// below fail with `Compacted`. Reads at `revision` and later are unaffected. Compacting to
    /// or below the current compaction point does nothing; above the current revision is
    /// `FutureRevision`.
    pub fn compact(store: Store, revision: Revision, diag: *Diag) Error!void {
        assert(diag.code == null);
        assert(revision > 0);
        try finish(diag, store.vtable.compact(store.context, revision, diag));
    }
};

/// A failed call always leaves a diagnostic behind; a successful one never does.
fn finish(diag: *Diag, result: anytype) @TypeOf(result) {
    if (result) |_| {
        assert(diag.code == null);
    } else |_| {
        assert(diag.code != null);
    }
    return result;
}

// ---- Validation shared by all backends ------------------------------------------------------

pub const KeyProblem = enum { empty, too_long, not_absolute, bad_byte };

/// Null if `key` is a valid key: "/" then printable ASCII, at most `store_key_bytes_max`.
/// Keys are built by code from validated names, so an invalid one is a programmer error.
pub fn key_problem(key: []const u8) ?KeyProblem {
    if (key.len == 0) return .empty;
    if (key.len > constants.store_key_bytes_max) return .too_long;
    if (key[0] != '/') return .not_absolute;
    for (key) |byte| {
        if (byte < 0x21 or byte >= 0x7f) return .bad_byte;
    }
    return null;
}

/// A prefix is a key prefix: empty, or "/" then printable ASCII.
pub fn prefix_problem(prefix: []const u8) ?KeyProblem {
    if (prefix.len == 0) return null;
    return key_problem(prefix);
}

fn has_duplicate_keys(ops: []const Op) bool {
    assert(ops.len <= constants.store_txn_ops_max);
    for (ops, 0..) |first, index| {
        for (ops[index + 1 ..]) |second| {
            if (std.mem.eql(u8, op_key(first), op_key(second))) return true;
        }
    }
    return false;
}

pub fn op_key(op: Op) []const u8 {
    return switch (op) {
        .put => |put| put.key,
        .delete => |key| key,
    };
}

fn check_txn_size(request: TxnRequest, diag: *Diag) Error!void {
    const compares = request.compares.len;
    if (compares > constants.store_txn_compares_max) {
        diag.raise(.E0206);
        diag.cause("a transaction has {d} compares; the limit is {d}", .{
            compares, constants.store_txn_compares_max,
        });
        diag.fix(.{ .sentence = "split the change into smaller transactions" });
        return error.TooLarge;
    }
    for ([_][]const Op{ request.on_success, request.on_failure }) |ops| {
        if (ops.len > constants.store_txn_ops_max) {
            diag.raise(.E0206);
            diag.cause("a transaction branch has {d} operations; the limit is {d}", .{
                ops.len, constants.store_txn_ops_max,
            });
            diag.fix(.{ .sentence = "split the change into smaller transactions" });
            return error.TooLarge;
        }
        for (ops) |op| {
            assert(key_problem(op_key(op)) == null);
            switch (op) {
                .delete => {},
                .put => |put| try check_value(put.value, diag),
            }
        }
    }
}

fn check_value(value: []const u8, diag: *Diag) Error!void {
    if (value.len <= constants.store_value_bytes_max) return;
    diag.raise(.E0206);
    diag.cause("a value is {d} bytes; the limit is {d}", .{
        value.len, constants.store_value_bytes_max,
    });
    diag.fix(.{ .sentence = "store large data outside the control plane and keep a reference" });
    return error.TooLarge;
}

fn check_ttl(ttl_ms: u32, diag: *Diag) Error!void {
    if (ttl_ms >= constants.lease_ttl_ms_min and ttl_ms <= constants.lease_ttl_ms_max) return;
    diag.raise(.E0206);
    diag.cause("a lease ttl of {d} ms is outside {d} to {d} ms", .{
        ttl_ms, constants.lease_ttl_ms_min, constants.lease_ttl_ms_max,
    });
    diag.fix(.{ .sentence = "choose a ttl inside the range" });
    return error.TooLarge;
}

const repeat = @import("test_util.zig").repeat;

test "keys are absolute printable paths within the bound" {
    // Goal: the boundary where a key becomes invalid. Method: each rule once, and the longest
    // key that is still accepted.
    try std.testing.expect(key_problem("/services/hello") == null);
    try std.testing.expectEqual(KeyProblem.empty, key_problem("").?);
    try std.testing.expectEqual(KeyProblem.not_absolute, key_problem("services").?);
    try std.testing.expectEqual(KeyProblem.bad_byte, key_problem("/a b").?);
    try std.testing.expectEqual(KeyProblem.bad_byte, key_problem("/a\x00").?);
    const longest = "/" ++ repeat('k', constants.store_key_bytes_max - 1);
    try std.testing.expect(key_problem(longest) == null);
    try std.testing.expectEqual(KeyProblem.too_long, key_problem(longest ++ "k").?);
    try std.testing.expect(prefix_problem("") == null);
}
