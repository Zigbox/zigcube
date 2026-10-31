//! A `Store` that lies on purpose, for the fault runner's own test (`store_faults.zig`).
//!
//! A checker that has never failed a real history proves nothing, so the runner can wrap each
//! client's store in a `Mutant` (hidden flag `--mutate`) and the test asserts that the checker
//! rejects what each lie produces:
//!
//! - `drop_ack`: every fifth write is not made, and the store says it was, at a revision that
//!   does not exist in the log (an acknowledged write that is missing: `lost_write`). The made-up
//!   revisions count up from `phantom_base`, far above any real one, so the verdict is the lost
//!   write and never a clash with a real revision.
//! - `stale_read`: a `get` returns the value this client read last, when the store's current one
//!   differs (a read that went back in time: `not_linearizable`).
//! - `reuse_revision`: every second write that changed something reports the revision of this
//!   client's previous write (two writes with one revision: `revision_reused`; the checker finds
//!   that before it compares real time across keys, which is why this is not `revision_order`).
//!
//! Test code only: nothing in the server or the agent imports it.

const std = @import("std");
const assert = std.debug.assert;
const store = @import("store.zig");
const Diag = @import("diag.zig").Diag;
const history = @import("testing/history.zig");

const Store = store.Store;
const Error = store.Error;

pub const Mutation = enum { none, drop_ack, stale_read, reuse_revision };

const phantom_base: u64 = 1 << 40;
const drop_period = 5;
const reuse_period = 2;
const value_bytes_max = 24;

/// What a client last read of one register key.
const Seen = struct {
    present: bool = false,
    mod_revision: u64 = 0,
    value: [value_bytes_max]u8 = @splat(0),
    length: u8 = 0,
};

pub const Mutant = struct {
    inner: Store,
    kind: Mutation,
    writes: u32 = 0,
    phantom: u64 = phantom_base,
    last_revision: u64 = 0,
    seen: [history.audit_key_min]Seen = @splat(.{}),

    pub fn init(inner: Store, kind: Mutation) Mutant {
        assert(kind != .none);
        return .{ .inner = inner, .kind = kind };
    }

    pub fn interface(mutant: *Mutant) Store {
        return .{ .context = mutant, .vtable = &vtable };
    }

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

    fn of(context: *anyopaque) *Mutant {
        return @ptrCast(@alignCast(context));
    }

    fn status(context: *anyopaque, diag: *Diag) Error!store.Status {
        return of(context).inner.status(diag);
    }

    fn get(
        context: *anyopaque,
        arena: std.mem.Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) Error!store.GetResult {
        const mutant = of(context);
        const real = try mutant.inner.get(arena, key, at_revision, diag);
        if (mutant.kind != .stale_read) return real;
        const id = history.parse_key(key) orelse return real;
        if (id >= mutant.seen.len) return real;
        const before = mutant.seen[id];
        mutant.seen[id] = remember(real);
        const now = mutant.seen[id];
        if (!before.present or before.mod_revision == now.mod_revision) return real;
        const value = arena.dupe(u8, before.value[0..before.length]) catch return real;
        return .{ .kv = .{
            .key = key,
            .value = value,
            .create_revision = before.mod_revision,
            .mod_revision = before.mod_revision,
        }, .revision = real.revision };
    }

    fn remember(result: store.GetResult) Seen {
        const kv = result.kv orelse return .{};
        var seen: Seen = .{ .present = true, .mod_revision = kv.mod_revision };
        assert(kv.value.len <= value_bytes_max);
        @memcpy(seen.value[0..kv.value.len], kv.value);
        seen.length = @intCast(kv.value.len);
        return seen;
    }

    fn txn(context: *anyopaque, request: store.TxnRequest, diag: *Diag) Error!store.TxnResult {
        const mutant = of(context);
        switch (mutant.kind) {
            .drop_ack => {
                mutant.writes += 1;
                if (mutant.writes % drop_period != 0) return mutant.inner.txn(request, diag);
                mutant.phantom += 1;
                return .{ .succeeded = true, .revision = mutant.phantom };
            },
            .reuse_revision => return mutant.reuse(request, diag),
            else => return mutant.inner.txn(request, diag),
        }
    }

    fn reuse(mutant: *Mutant, request: store.TxnRequest, diag: *Diag) Error!store.TxnResult {
        const real = try mutant.inner.txn(request, diag);
        const wrote = if (real.succeeded) request.on_success.len > 0 else request.on_failure.len > 0;
        if (!wrote) return real;
        mutant.writes += 1;
        if (mutant.last_revision != 0 and mutant.writes % reuse_period == 0) {
            return .{ .succeeded = real.succeeded, .revision = mutant.last_revision };
        }
        mutant.last_revision = real.revision;
        return real;
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) Error!store.ListResult {
        return of(context).inner.list(arena, options, diag);
    }

    fn watch(context: *anyopaque, options: store.WatchOptions, diag: *Diag) Error!store.Watch {
        return of(context).inner.watch(options, diag);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) Error!store.Lease {
        return of(context).inner.lease_grant(ttl_ms, diag);
    }

    fn lease_keepalive(context: *anyopaque, id: store.LeaseId, diag: *Diag) Error!store.Lease {
        return of(context).inner.lease_keepalive(id, diag);
    }

    fn lease_revoke(context: *anyopaque, id: store.LeaseId, diag: *Diag) Error!store.Revision {
        return of(context).inner.lease_revoke(id, diag);
    }

    fn lease_list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        diag: *Diag,
    ) Error![]const store.LeaseInfo {
        return of(context).inner.lease_list(arena, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) Error!u32 {
        return of(context).inner.expire_leases(diag);
    }

    fn compact(context: *anyopaque, revision: store.Revision, diag: *Diag) Error!void {
        return of(context).inner.compact(revision, diag);
    }
};
