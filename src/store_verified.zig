//! `VerifiedStore`: a `Store` that refuses to act on a store that went backwards
//! (docs/store-design.md, "Nothing acts on a store that went backwards"). Core code: no files,
//! no threads, no clock but the `Clock` it is given.
//!
//! It wraps the real store, so everything that reaches the store (the controller, the API
//! handlers, the maintenance timers) goes through it, and one check covers them all. It remembers
//! the highest `(revision, hash)` pair it has seen. On every `status` it compares the store with
//! that pair:
//!
//! - a lower revision: the store lost writes it had acknowledged (a failover to a replica that
//!   was behind, a restore from an old backup);
//! - the same or a higher revision whose chain hash at the remembered revision differs: the
//!   history forked;
//! - a store that cannot say what its hash was at the remembered revision (`NoHash`, the
//!   remembered revision is below the store's chain start): unverifiable, treated as the same.
//!
//! Any of these halts the wrapper with `ZC-E0215`: from then on every call fails with that
//! diagnostic, so controllers do not step and writes are refused, until `accept` is called by an
//! operator's decision. There is no automatic recovery. A transaction's result carries the chain
//! hash of its revision and is checked like a `status`, and the pair advances with it, so a
//! write acknowledged after the last `status` is remembered too. Lease expiry is preceded and
//! followed by a check.
//!
//! The remembered pair is saved through `Remember` (the shell writes a file) whenever the file
//! is behind it and `constants.verified_save_ms` has passed, from any status or write; a pair
//! that lags behind the store is safe, only weaker (a crash and a rollback inside that window go
//! unnoticed). A failed save is retried at the next interval and visible in `save_trouble`.

const std = @import("std");
const assert = std.debug.assert;
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const failures = @import("store_failures.zig");
const store = @import("store.zig");

const Hash = store.Hash;
const Revision = store.Revision;
const Store = store.Store;

pub const Pair = struct {
    revision: Revision,
    hash: Hash,

    pub fn eql(a: Pair, b: Pair) bool {
        return a.revision == b.revision and std.mem.eql(u8, &a.hash, &b.hash);
    }
};

/// Where the shell keeps the pair. `save` returns false if it could not make it durable.
pub const Remember = struct {
    context: *anyopaque,
    save_fn: *const fn (context: *anyopaque, pair: Pair) bool,
};

pub const VerifiedStore = struct {
    inner: Store,
    clock: Clock,
    remember: ?Remember,
    // The fields below are guarded by `lock`, held only while they are read or written, never
    // across a call into `inner` or `remember`.
    lock: std.atomic.Mutex = .unlocked,
    known: ?Pair,
    /// The last pair handed to `remember` that it accepted.
    saved: ?Pair,
    saved_ms: u64 = 0,
    halted: ?failures.Rollback = null,
    /// Bumped by `accept`. A result or a save that began under an older epoch is dropped: it
    /// describes the store as it was before the operator's decision.
    epoch: u32 = 0,
    /// The last save failed; cleared by the next that succeeds.
    save_failed: bool = false,

    pub fn init(inner: Store, clock: Clock, remember: ?Remember, known: ?Pair) VerifiedStore {
        // What was loaded from the file is what the file holds: nothing is due to be saved.
        return .{
            .inner = inner,
            .clock = clock,
            .remember = remember,
            .known = known,
            .saved = known,
        };
    }

    pub fn interface(self: *VerifiedStore) Store {
        return .{ .context = self, .vtable = &vtable };
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
        .hash_at = hash_at,
    };

    // ---- The operator's side ----

    /// What the wrapper stopped on, or null while it acts.
    pub fn halt_state(self: *VerifiedStore) ?failures.Rollback {
        self.enter();
        defer self.leave();
        return self.halted;
    }

    /// The pair remembered now, null before the first status.
    pub fn remembered(self: *VerifiedStore) ?Pair {
        self.enter();
        defer self.leave();
        return self.known;
    }

    /// True while the last attempt to save the remembered pair failed (`ZC-E0216`). The pair is
    /// then ahead of the file: a crash now forgets the difference.
    pub fn save_trouble(self: *VerifiedStore) bool {
        self.enter();
        defer self.leave();
        return self.save_failed;
    }

    pub const Accepted = struct { old: ?Pair, new: Pair };

    /// The operator's decision: remember the store as it is now and act again. Fails (and stays
    /// halted) if the store cannot be read or the new pair cannot be saved. Results and saves
    /// that were under way are dropped (the epoch moves).
    pub fn accept(self: *VerifiedStore, diag: *Diag) store.Error!Accepted {
        assert(diag.code == null);
        const now = try self.inner.status(diag);
        const pair: Pair = .{ .revision = now.revision, .hash = now.hash };
        if (self.remember) |remember| {
            if (!remember.save_fn(remember.context, pair)) return not_saved(diag);
        }
        self.enter();
        const old = self.known;
        self.known = pair;
        self.saved = pair;
        self.saved_ms = self.clock.now_ms();
        self.save_failed = false;
        self.halted = null;
        self.epoch +%= 1;
        self.leave();
        // A save that began before the bump may have written after ours: write the pair again.
        self.persist();
        return .{ .old = old, .new = pair };
    }

    /// Saves the remembered pair if the file is behind it; the server calls it as it stops.
    /// False if that failed: the next start remembers an older pair.
    pub fn flush(self: *VerifiedStore) bool {
        self.persist();
        return !self.save_trouble();
    }

    // ---- The check ----

    fn from(context: *anyopaque) *VerifiedStore {
        return @ptrCast(@alignCast(context));
    }

    /// The lock guards a few field reads and writes; holding it for longer than this many tries
    /// is a bug (a call into `inner` made under it), not load.
    const spins_max: u32 = 1 << 24;

    fn enter(self: *VerifiedStore) void {
        var spins: u32 = 0;
        while (!self.lock.tryLock()) {
            spins += 1;
            assert(spins < spins_max);
            std.atomic.spinLoopHint();
        }
    }

    fn leave(self: *VerifiedStore) void {
        self.lock.unlock();
    }

    fn epoch_now(self: *VerifiedStore) u32 {
        self.enter();
        defer self.leave();
        return self.epoch;
    }

    fn not_saved(diag: *Diag) store.Error {
        return failures.not_saved(diag);
    }

    /// Fails with `ZC-E0215` while halted.
    fn gate(self: *VerifiedStore, diag: *Diag) store.Error!void {
        self.enter();
        const halted = self.halted;
        self.leave();
        if (halted) |rollback| return failures.went_backwards(diag, rollback);
    }

    /// Halts, unless the operator accepted since `epoch` began (the evidence is then stale and
    /// dropped). The first cause stands: a later check must not overwrite the evidence.
    fn halt(
        self: *VerifiedStore,
        diag: *Diag,
        rollback: failures.Rollback,
        epoch: u32,
    ) store.Error!void {
        self.enter();
        if (self.epoch != epoch) {
            self.leave();
            return;
        }
        if (self.halted == null) self.halted = rollback;
        const kept = self.halted.?;
        self.leave();
        diag.reset();
        return failures.went_backwards(diag, kept);
    }

    /// Compares `now` with the remembered pair, and moves the pair forward.
    fn check(self: *VerifiedStore, now: store.Status, epoch: u32, diag: *Diag) store.Error!void {
        assert(diag.code == null);
        self.enter();
        const known = self.known;
        const current = self.epoch;
        self.leave();
        if (current != epoch) return;
        const pair = known orelse return self.advance(now, epoch);
        var rollback: failures.Rollback = .{
            .remembered_revision = pair.revision,
            .remembered_hash = pair.hash,
            .now_revision = now.revision,
            .now_hash = now.hash,
        };
        if (now.revision < pair.revision) return self.halt(diag, rollback, epoch);
        var there = now.hash;
        if (now.revision > pair.revision) {
            there = self.inner.hash_at(pair.revision, diag) catch |err| {
                if (err != error.NoHash) return err; // Trouble reading: the caller retries.
                diag.reset();
                rollback.unverifiable = true;
                return self.halt(diag, rollback, epoch);
            };
        }
        if (!std.mem.eql(u8, &there, &pair.hash)) {
            rollback.now_hash = there;
            return self.halt(diag, rollback, epoch);
        }
        self.advance(now, epoch);
    }

    fn advance(self: *VerifiedStore, now: store.Status, epoch: u32) void {
        self.enter();
        if (self.epoch != epoch) return self.leave();
        if (self.known) |known| {
            if (now.revision <= known.revision) return self.leave();
        }
        self.known = .{ .revision = now.revision, .hash = now.hash };
        self.leave();
    }

    /// Saves the remembered pair if the file is behind it and the last save is older than
    /// `constants.verified_save_ms`. Every status, and every write, calls it, so an idle
    /// cluster that has stopped writing still saves the newest pair.
    fn save_if_due(self: *VerifiedStore) void {
        if (self.remember == null) return;
        self.enter();
        const known = self.known;
        const saved = self.saved;
        const waited = self.clock.now_ms() -| self.saved_ms;
        self.leave();
        const pair = known orelse return;
        if (saved) |done| if (done.eql(pair)) return;
        if (saved != null and waited < constants.verified_save_ms) return;
        self.persist();
    }

    /// Saves the remembered pair now. If `accept` ran meanwhile the pair written may be the old
    /// one: write again, the current one (twice at most; the next save repairs the rest).
    fn persist(self: *VerifiedStore) void {
        const remember = self.remember orelse return;
        for (0..2) |_| {
            self.enter();
            const pair = self.known;
            const epoch = self.epoch;
            const saved = self.saved;
            self.leave();
            const current = pair orelse return;
            if (saved) |done| if (done.eql(current)) return;
            const ok = remember.save_fn(remember.context, current);
            self.enter();
            const same = self.epoch == epoch;
            if (same) {
                // A failed save is retried at the next interval, not at every call.
                self.saved_ms = self.clock.now_ms();
                self.save_failed = !ok;
                if (ok) self.saved = current;
            }
            self.leave();
            if (same) return;
        }
    }

    /// Reads the store's head and checks it. The store may be reached before and after a call
    /// that changes it; a write that already happened stands whatever this finds out.
    fn verify(self: *VerifiedStore, diag: *Diag) store.Error!store.Status {
        const epoch = self.epoch_now();
        const now = try self.inner.status(diag);
        try self.check(now, epoch, diag);
        self.save_if_due();
        return now;
    }

    /// `verify` after a change: a failure to read is the next step's to report, a halt is not.
    fn settle(self: *VerifiedStore, diag: *Diag) store.Error!void {
        _ = self.verify(diag) catch |err| {
            if (self.halt_state() != null) return err;
            diag.reset();
        };
    }

    // ---- The Store interface ----

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        const self = from(context);
        try self.gate(diag);
        return self.verify(diag);
    }

    fn get(
        context: *anyopaque,
        arena: std.mem.Allocator,
        key: []const u8,
        at_revision: ?Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        const self = from(context);
        try self.gate(diag);
        return self.inner.get(arena, key, at_revision, diag);
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const self = from(context);
        try self.gate(diag);
        return self.inner.list(arena, options, diag);
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const self = from(context);
        try self.gate(diag);
        const epoch = self.epoch_now();
        const result = try self.inner.txn(request, diag);
        // The write is done; what is left is to learn whether the store it went to is the one
        // remembered. The result carries the chain hash of its revision, so the pair advances
        // with every acknowledged write, not only at a `status`.
        self.enter();
        const known = self.known;
        self.leave();
        const behind = if (known) |pair| result.revision < pair.revision else false;
        if (result.hash != null and !behind) {
            const now: store.Status = .{
                .revision = result.revision,
                .compacted_revision = 0,
                .hash = result.hash.?,
            };
            self.check(now, epoch, diag) catch |err| {
                if (self.halt_state() != null) return err;
                diag.reset(); // Could not read: the write stands, the next status verifies.
            };
            self.save_if_due();
        } else if (behind) {
            // Below the remembered revision: a write that finished out of order, or a store
            // that is behind. The store's head and its hash at the remembered revision tell.
            try self.settle(diag);
        }
        return result;
    }

    fn watch(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        const self = from(context);
        try self.gate(diag);
        return self.inner.watch(options, diag);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_grant(ttl_ms, diag);
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_keepalive(id, diag);
    }

    fn lease_revoke(context: *anyopaque, id: store.LeaseId, diag: *Diag) store.Error!Revision {
        const self = from(context);
        try self.gate(diag);
        _ = try self.verify(diag);
        const revision = try self.inner.lease_revoke(id, diag);
        try self.settle(diag);
        return revision;
    }

    fn lease_list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_list(arena, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) store.Error!u32 {
        const self = from(context);
        try self.gate(diag);
        _ = try self.verify(diag);
        const expired = try self.inner.expire_leases(diag);
        if (expired > 0) try self.settle(diag);
        return expired;
    }

    fn compact(context: *anyopaque, revision: Revision, diag: *Diag) store.Error!void {
        const self = from(context);
        try self.gate(diag);
        return self.inner.compact(revision, diag);
    }

    fn hash_at(context: *anyopaque, revision: Revision, diag: *Diag) store.Error!Hash {
        const self = from(context);
        try self.gate(diag);
        return self.inner.hash_at(revision, diag);
    }
};

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;
const codes = @import("diag/codes.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

/// Records what `Remember` was asked to save.
const Recorder = struct {
    saves: u32 = 0,
    last: ?Pair = null,
    fail: bool = false,

    fn remember(recorder: *Recorder) Remember {
        return .{ .context = recorder, .save_fn = save };
    }

    fn save(context: *anyopaque, pair: Pair) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        if (recorder.fail) return false;
        recorder.saves += 1;
        recorder.last = pair;
        return true;
    }
};

fn write(s: Store, key: []const u8, value: []const u8) !Revision {
    var diag: Diag = undefined;
    diag.reset();
    const op: store.Op = .{ .put = .{ .key = key, .value = value } };
    return (try s.txn(.{ .on_success = &.{op} }, &diag)).revision;
}

fn expect_halted(call_result: anytype, diag: *Diag) !void {
    try testing.expectError(error.BackendFailed, call_result);
    try testing.expectEqual(codes.Code.E0215, diag.code.?);
    diag.reset();
}

test "a store that went backwards is refused, everything stops, and accept resumes" {
    // Goal: nothing acts on a store that lost writes it acknowledged. Method: two memory stores
    // with the same first two writes, the first with a third; the wrapper sees the long one,
    // then the short one takes its place (a failover to a replica that was behind).
    var manual: ManualClock = .{};
    var long: MemoryStore = undefined;
    long.init(testing.allocator, manual.clock());
    defer long.deinit();
    var short: MemoryStore = undefined;
    short.init(testing.allocator, manual.clock());
    defer short.deinit();
    for ([_][]const u8{ "/a", "/b" }) |key| {
        _ = try write(long.interface(), key, "1");
        _ = try write(short.interface(), key, "1");
    }
    _ = try write(long.interface(), "/c", "1");
    var recorder: Recorder = .{};
    var verified = VerifiedStore.init(long.interface(), manual.clock(), recorder.remember(), null);
    const guarded = verified.interface();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(@as(Revision, 3), (try guarded.status(&diag)).revision);
    try testing.expectEqual(@as(Revision, 3), recorder.last.?.revision);

    verified.inner = short.interface();
    try expect_halted(guarded.status(&diag), &diag);
    try testing.expect(verified.halt_state() != null);
    // Controllers do not step (reads fail), writes are refused, maintenance is refused.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expect_halted(guarded.get(arena_state.allocator(), "/a", null, &diag), &diag);
    const op: store.Op = .{ .put = .{ .key = "/x", .value = "1" } };
    try expect_halted(guarded.txn(.{ .on_success = &.{op} }, &diag), &diag);
    try expect_halted(guarded.expire_leases(&diag), &diag);
    // The diagnostic names both revisions and shortened hashes, and the way out.
    try testing.expectError(error.BackendFailed, guarded.status(&diag));
    var rendered: [constants.diag_output_bytes_max]u8 = undefined;
    var diagnostic: @import("diag.zig").Diagnostic = undefined;
    @import("diag.zig").to_diagnostic(&diagnostic, &diag);
    const text = @import("diag.zig").render(&diagnostic, .text, false, &rendered);
    try testing.expect(std.mem.indexOf(u8, text, "revision 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "revision 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zcube store accept-rollback --confirm") != null);
    diag.reset();

    // The operator accepts: the short store is now the truth, and the old pair is reported.
    const accepted = try verified.accept(&diag);
    try testing.expectEqual(@as(Revision, 3), accepted.old.?.revision);
    try testing.expectEqual(@as(Revision, 2), accepted.new.revision);
    try testing.expect(verified.halt_state() == null);
    try testing.expectEqual(@as(Revision, 2), recorder.last.?.revision);
    try testing.expectEqual(@as(Revision, 2), (try guarded.status(&diag)).revision);
    try testing.expectEqual(@as(Revision, 3), try write(guarded, "/y", "1"));
}

test "a fork, with the same or a higher revision, is refused" {
    // Goal: the same revision number with different history is caught by the hash. Method: two
    // stores that differ in their third write; the wrapper knows one, the other answers at its
    // own revision 3 and, after one more write, at revision 4.
    var manual: ManualClock = .{};
    var one: MemoryStore = undefined;
    one.init(testing.allocator, manual.clock());
    defer one.deinit();
    var two: MemoryStore = undefined;
    two.init(testing.allocator, manual.clock());
    defer two.deinit();
    for ([_]Store{ one.interface(), two.interface() }) |s| {
        _ = try write(s, "/a", "1");
        _ = try write(s, "/b", "1");
    }
    _ = try write(one.interface(), "/c", "left");
    _ = try write(two.interface(), "/c", "right");
    var verified = VerifiedStore.init(one.interface(), manual.clock(), null, null);
    const guarded = verified.interface();
    var diag: Diag = undefined;
    diag.reset();
    _ = try guarded.status(&diag);

    verified.inner = two.interface(); // Same revision, different hash.
    try expect_halted(guarded.status(&diag), &diag);
    _ = try verified.accept(&diag);
    try testing.expect(verified.halt_state() == null);

    // Higher revision whose history at the remembered revision differs.
    verified.inner = one.interface();
    _ = try write(one.interface(), "/d", "1");
    try expect_halted(guarded.status(&diag), &diag);
    try testing.expectEqual(@as(Revision, 3), verified.halt_state().?.remembered_revision);
}

test "a store that moves forward on the same history is never refused" {
    // Goal: no false alarm. Method: writes, a manual clock past the save interval, many statuses.
    var manual: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var recorder: Recorder = .{};
    var verified = VerifiedStore.init(
        memory.interface(),
        manual.clock(),
        recorder.remember(),
        null,
    );
    const guarded = verified.interface();
    var diag: Diag = undefined;
    diag.reset();
    for (0..20) |step| {
        _ = try write(guarded, "/k", "v");
        _ = try guarded.status(&diag);
        manual.advance(constants.verified_save_ms / 4);
        _ = step;
    }
    try testing.expectEqual(@as(Revision, 20), verified.remembered().?.revision);
    // Saves are throttled, and the last pair is saved at the end.
    try testing.expect(recorder.saves < 20);
    _ = verified.flush();
    try testing.expectEqual(@as(Revision, 20), recorder.last.?.revision);
}

test "a restart across a rollback is caught from the saved pair" {
    // Goal: the pair outlives the server. Method: the first wrapper saves its pair; a second one,
    // built as a restarted server builds it, from the saved pair, meets the shorter store.
    var manual: ManualClock = .{};
    var long: MemoryStore = undefined;
    long.init(testing.allocator, manual.clock());
    defer long.deinit();
    var short: MemoryStore = undefined;
    short.init(testing.allocator, manual.clock());
    defer short.deinit();
    _ = try write(short.interface(), "/a", "1");
    _ = try write(long.interface(), "/a", "1");
    _ = try write(long.interface(), "/b", "1");
    var recorder: Recorder = .{};
    var first = VerifiedStore.init(long.interface(), manual.clock(), recorder.remember(), null);
    var diag: Diag = undefined;
    diag.reset();
    _ = try first.interface().status(&diag);

    var second = VerifiedStore.init(short.interface(), manual.clock(), null, recorder.last);
    try expect_halted(second.interface().status(&diag), &diag);
    // The same store restarted is fine.
    var again = VerifiedStore.init(long.interface(), manual.clock(), null, recorder.last);
    _ = try again.interface().status(&diag);
}

test "a remembered hash the store does not have at that revision is refused" {
    // Goal: a pair that matches no history of this store (a store replaced by another) is caught
    // even when the store is ahead. Method: a made-up pair at revision 1. The NoHash branch (a
    // pair below a migrated store's chain start) needs a migrated store: not covered here.
    var manual: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    _ = try write(memory.interface(), "/a", "1");
    _ = try write(memory.interface(), "/b", "1");
    const made_up: Pair = .{ .revision = 1, .hash = @splat(0x42) };
    var verified = VerifiedStore.init(memory.interface(), manual.clock(), null, made_up);
    var diag: Diag = undefined;
    diag.reset();
    try expect_halted(verified.interface().status(&diag), &diag);
}

test "a write acknowledged after the last status is remembered, so a stale replica is caught" {
    // Goal: the pair advances with every acknowledged write, not only at `status`. Method: a
    // status at revision 2, three writes through the wrapper (revisions 3..5, no status), then
    // the store under the wrapper is swapped for a copy of the same history at revision 3 (a
    // standby that had not seen 4 and 5). The next write answers revision 4 and is refused.
    var manual: ManualClock = .{};
    var long: MemoryStore = undefined;
    long.init(testing.allocator, manual.clock());
    defer long.deinit();
    var standby: MemoryStore = undefined;
    standby.init(testing.allocator, manual.clock());
    defer standby.deinit();
    for ([_][]const u8{ "/a", "/b", "/c" }) |key| {
        _ = try write(standby.interface(), key, "1");
        if (!std.mem.eql(u8, key, "/c")) _ = try write(long.interface(), key, "1");
    }
    var verified = VerifiedStore.init(long.interface(), manual.clock(), null, null);
    const guarded = verified.interface();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(@as(Revision, 2), (try guarded.status(&diag)).revision);
    for ([_][]const u8{ "/c", "/d", "/e" }) |key| _ = try write(guarded, key, "1");
    try testing.expectEqual(@as(Revision, 5), verified.remembered().?.revision);

    verified.inner = standby.interface();
    const op: store.Op = .{ .put = .{ .key = "/f", .value = "1" } };
    try expect_halted(guarded.txn(.{ .on_success = &.{op} }, &diag), &diag);
    try testing.expectEqual(@as(Revision, 5), verified.halt_state().?.remembered_revision);
    try testing.expectEqual(@as(Revision, 4), verified.halt_state().?.now_revision);
}

test "a write that finishes after a later one is not a rollback" {
    // Goal: no false alarm from two writers whose answers arrive out of order. Method: the pair
    // is at revision 3; a result for revision 2 (as a slow writer would deliver) is checked
    // against the store's head, which is on the same history.
    var manual: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var verified = VerifiedStore.init(memory.interface(), manual.clock(), null, null);
    const guarded = verified.interface();
    for ([_][]const u8{ "/a", "/b", "/c" }) |key| _ = try write(guarded, key, "1");
    var diag: Diag = undefined;
    diag.reset();
    const early = try memory.interface().hash_at(2, &diag);
    const result: store.TxnResult = .{ .succeeded = true, .revision = 2, .hash = early };
    const behind = result.revision < verified.remembered().?.revision;
    try testing.expect(behind);
    try verified.settle(&diag);
    try testing.expect(verified.halt_state() == null);
}

test "the newest pair is saved when the cluster goes idle, and a failed save is reported" {
    // Goal: a burst followed by silence still ends with the newest pair on disk, and a save that
    // fails is visible. Method: writes inside one save interval, then only statuses after the
    // interval; then a failing `Remember`.
    var manual: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var recorder: Recorder = .{};
    const remember = recorder.remember();
    var verified = VerifiedStore.init(memory.interface(), manual.clock(), remember, null);
    const guarded = verified.interface();
    var diag: Diag = undefined;
    diag.reset();
    _ = try guarded.status(&diag);
    for (0..5) |_| _ = try write(guarded, "/k", "v");
    try testing.expect(recorder.last.?.revision < 5); // Throttled.
    manual.advance(constants.verified_save_ms);
    _ = try guarded.status(&diag); // No rise, but the file is behind and the interval is up.
    try testing.expectEqual(@as(Revision, 5), recorder.last.?.revision);

    recorder.fail = true;
    _ = try write(guarded, "/k", "v");
    manual.advance(constants.verified_save_ms);
    _ = try guarded.status(&diag);
    try testing.expect(verified.save_trouble());
    try testing.expect(!verified.flush());
    recorder.fail = false;
    manual.advance(constants.verified_save_ms);
    _ = try guarded.status(&diag);
    try testing.expect(!verified.save_trouble());
    try testing.expectEqual(@as(Revision, 6), recorder.last.?.revision);
}

test "a result that began before accept is dropped" {
    // Goal: accept does not race with a status in flight. Method: take the epoch as a status
    // would, accept, then deliver the stale status (a rollback evidence): it neither halts nor
    // moves the pair.
    var manual: ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    for ([_][]const u8{ "/a", "/b" }) |key| _ = try write(memory.interface(), key, "1");
    var verified = VerifiedStore.init(memory.interface(), manual.clock(), null, .{
        .revision = 2,
        .hash = @splat(0x11),
    });
    var diag: Diag = undefined;
    diag.reset();
    const epoch = verified.epoch_now();
    _ = try verified.accept(&diag);
    const stale: store.Status = .{ .revision = 1, .compacted_revision = 0, .hash = @splat(0x22) };
    try verified.check(stale, epoch, &diag);
    try testing.expect(verified.halt_state() == null);
    try testing.expectEqual(@as(Revision, 2), verified.remembered().?.revision);
}
