//! A `Store` wrapper that lets the simulator see every revision as it is made (sim-c1,
//! docs/authority.md §4). The invariants are claimed "at every revision", and a check that runs
//! between operations sees only the states the run happens to stop at; this one runs inside the
//! store call, right after each mutation commits and before the caller hears of it, so no
//! intermediate revision is missed and a lost acknowledgement (`AckLossStore`, above this one)
//! cannot hide a commit.
//!
//! `before` runs ahead of a `txn` and may commit a competing write through the store beneath this
//! one: it is how a negative test makes "a node lost between planning and commit". It is null in
//! every run that is not a negative test. Core code: no thread, clock or file.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const TapStore = struct {
    /// The store beneath: what `before` writes to, and what the checks read.
    inner: store.Store,
    context: *anyopaque,
    /// Called after each call that changed the revision, with the transaction if it was one.
    after: *const fn (*anyopaque, ?store.TxnRequest, store.Revision) void,
    /// Called before each `txn`; may write through `inner`.
    before: ?*const fn (context: *anyopaque, request: store.TxnRequest) void = null,
    /// Revisions observed, for the report.
    revisions_seen: u64 = 0,
    head: store.Revision = 0,

    const vtable: store.Store.VTable = .{
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
        .hash_at = hash_at,
    };

    pub fn interface(self: *TapStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *TapStore {
        return @ptrCast(@alignCast(context));
    }

    /// Tells `after` if the revision moved since the last call.
    fn tap(self: *TapStore, request: ?store.TxnRequest) void {
        var scratch: Diag = undefined;
        scratch.reset();
        const now = self.inner.status(&scratch) catch return;
        if (now.revision == self.head) return;
        self.head = now.revision;
        self.revisions_seen += 1;
        self.after(self.context, request, now.revision);
    }

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        return from(context).inner.status(diag);
    }

    fn get(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        return from(context).inner.get(arena, key, at_revision, diag);
    }

    fn list(
        context: *anyopaque,
        arena: Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        return from(context).inner.list(arena, options, diag);
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const self = from(context);
        if (self.before) |hook| {
            hook(self.context, request);
            self.tap(null);
        }
        const result = try self.inner.txn(request, diag);
        self.tap(if (result.succeeded) request else null);
        return result;
    }

    fn watch(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        return from(context).inner.watch(options, diag);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        return from(context).inner.lease_grant(ttl_ms, diag);
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        return from(context).inner.lease_keepalive(id, diag);
    }

    fn lease_revoke(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Revision {
        const self = from(context);
        const result = try self.inner.lease_revoke(id, diag);
        self.tap(null);
        return result;
    }

    fn lease_list(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        return from(context).inner.lease_list(arena, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) store.Error!u32 {
        const self = from(context);
        const result = try self.inner.expire_leases(diag);
        self.tap(null);
        return result;
    }

    fn compact(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!void {
        return from(context).inner.compact(revision, diag);
    }

    fn hash_at(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!store.Hash {
        return from(context).inner.hash_at(revision, diag);
    }
};

const testing = std.testing;

const Seen = struct {
    revisions: [8]store.Revision = undefined,
    keys: [8]u32 = undefined,
    count: u32 = 0,

    fn after(context: *anyopaque, request: ?store.TxnRequest, revision: store.Revision) void {
        const seen: *Seen = @ptrCast(@alignCast(context));
        seen.revisions[seen.count] = revision;
        seen.keys[seen.count] = if (request) |r| @intCast(r.on_success.len) else 0;
        seen.count += 1;
    }
};

test "the tap hears each revision once, with the transaction that made it" {
    const MemoryStore = @import("store_memory.zig").MemoryStore;
    const ManualClock = @import("clock.zig").ManualClock;
    var clock: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, clock.clock());
    defer memory.deinit();
    var seen: Seen = .{};
    var tapped: TapStore = .{
        .inner = memory.interface(),
        .context = &seen,
        .after = Seen.after,
    };
    const kv = tapped.interface();
    var diag: Diag = undefined;
    diag.reset();
    const put = [_]store.Op{.{ .put = .{ .key = "/a", .value = "1" } }};
    _ = try kv.txn(.{ .on_success = &put }, &diag);
    // A transaction whose compare fails writes nothing: no revision, no call.
    const stale = [_]store.Compare{.{ .key = "/a", .mod_revision = 99 }};
    const result = try kv.txn(.{ .compares = &stale, .on_success = &put }, &diag);
    try testing.expect(!result.succeeded);
    try testing.expectEqual(@as(usize, 1), seen.count);
    try testing.expectEqual(@as(usize, 1), seen.keys[0]);
}
