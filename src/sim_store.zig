//! A `Store` wrapper that loses acknowledgements: the call runs on the inner store, commits, and
//! the caller is told it failed. `SwitchedStore` (sim_world.zig) fails a call *before* it reaches
//! the store, and `MemoryStore` has no fault hooks, so neither can produce the case this does: a
//! write that happened and an error that says it did not. A real backend does this when a
//! connection drops between COMMIT and its reply; a retry that is not idempotent then does the
//! write twice, and a writer that trusts the error loses track of what it wrote.
//!
//! Only the calls that change something can lose their acknowledgement (`txn`, the lease calls and
//! `compact`); a read has nothing to lose. Core code: the choice is made by a seeded `Prng`.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const AckLossStore = struct {
    inner: store.Store,
    prng: std.Random.DefaultPrng,
    /// Chance, in thousandths, that a committed write is reported as failed. 0 turns it off.
    loss_per_mille: u32,
    /// The next write loses its acknowledgement whatever the rate (a test's lever).
    lose_next: bool = false,
    /// Writes that committed and were reported as failed, for a report and for tests.
    lost_count: u32 = 0,

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

    pub fn init(inner: store.Store, seed: u64, loss_per_mille: u32) AckLossStore {
        assert(loss_per_mille <= 1000);
        return .{ .inner = inner, .prng = .init(seed), .loss_per_mille = loss_per_mille };
    }

    pub fn interface(self: *AckLossStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *AckLossStore {
        return @ptrCast(@alignCast(context));
    }

    /// True if the write that just committed must be reported as failed.
    fn loses(self: *AckLossStore) bool {
        if (self.lose_next) {
            self.lose_next = false;
            return true;
        }
        if (self.loss_per_mille == 0) return false;
        return self.prng.random().uintLessThan(u32, 1000) < self.loss_per_mille;
    }

    /// ZC-E0201, as when a connection is reset after the request went out.
    fn lost(self: *AckLossStore, diag: *Diag) store.Error {
        self.lost_count += 1;
        diag.reset();
        diag.raise(.E0201);
        diag.cause("connection reset by peer", .{});
        diag.cause("the simulated store committed, then lost the acknowledgement", .{});
        diag.fix(.{ .sentence = "read the store again to see whether the write happened" });
        return error.BackendFailed;
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
        const result = try self.inner.txn(request, diag);
        if (self.loses()) return self.lost(diag);
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
        const self = from(context);
        const result = try self.inner.lease_grant(ttl_ms, diag);
        if (self.loses()) return self.lost(diag);
        return result;
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const self = from(context);
        const result = try self.inner.lease_keepalive(id, diag);
        if (self.loses()) return self.lost(diag);
        return result;
    }

    fn lease_revoke(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Revision {
        const self = from(context);
        const result = try self.inner.lease_revoke(id, diag);
        if (self.loses()) return self.lost(diag);
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
        if (self.loses()) return self.lost(diag);
        return result;
    }

    fn compact(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!void {
        const self = from(context);
        try self.inner.compact(revision, diag);
        if (self.loses()) return self.lost(diag);
    }

    /// A read: passed through, never lost.
    fn hash_at(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!store.Hash {
        const self = from(context);
        return self.inner.hash_at(revision, diag);
    }
};

const testing = std.testing;

test "a write that committed is reported as failed, and a read is never" {
    // Goal: the lost acknowledgement. Method: lose the next put on a memory store, see the
    // error with ZC-E0201, read the key back (it is there), and check a read and an
    // unarmed write are untouched.
    const MemoryStore = @import("store_memory.zig").MemoryStore;
    const ManualClock = @import("clock.zig").ManualClock;
    var clock: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, clock.clock());
    defer memory.deinit();
    var lossy = AckLossStore.init(memory.interface(), 7, 0);
    const kv = lossy.interface();
    var diag: Diag = undefined;
    diag.reset();

    const put = [_]store.Op{.{ .put = .{ .key = "/a", .value = "1" } }};
    lossy.lose_next = true;
    try testing.expectError(error.BackendFailed, kv.txn(.{ .on_success = &put }, &diag));
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0201), diag.code);
    try testing.expectEqual(@as(u32, 1), lossy.lost_count);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    diag.reset();
    const got = try kv.get(arena_state.allocator(), "/a", null, &diag);
    try testing.expect(got.kv != null);

    const next = [_]store.Op{.{ .put = .{ .key = "/b", .value = "2" } }};
    const result = try kv.txn(.{ .on_success = &next }, &diag);
    try testing.expect(result.succeeded);
    try testing.expectEqual(@as(u32, 1), lossy.lost_count);
}

test "the rate loses about that share of writes, from the seed alone" {
    // Goal: swarm testing can set the rate, including zero and one. Method: count losses over
    // 400 puts at three rates; 0 loses none, 1000 loses all, and the same seed repeats.
    const MemoryStore = @import("store_memory.zig").MemoryStore;
    const ManualClock = @import("clock.zig").ManualClock;
    const rates = [_]u32{ 0, 250, 1000 };
    var counts: [3]u32 = undefined;
    for (rates, 0..) |rate, index| {
        var clock: ManualClock = .{};
        var memory: MemoryStore = undefined;
        memory.init(testing.allocator, clock.clock());
        defer memory.deinit();
        var lossy = AckLossStore.init(memory.interface(), 99, rate);
        var diag: Diag = undefined;
        const put = [_]store.Op{.{ .put = .{ .key = "/a", .value = "1" } }};
        for (0..400) |_| {
            diag.reset();
            _ = lossy.interface().txn(.{ .on_success = &put }, &diag) catch {};
        }
        counts[index] = lossy.lost_count;
    }
    try testing.expectEqual(@as(u32, 0), counts[0]);
    try testing.expect(counts[1] > 60 and counts[1] < 140);
    try testing.expectEqual(@as(u32, 400), counts[2]);
}
