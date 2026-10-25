//! `MemoryStore`: the reference implementation of `Store`. It is not a production backend. It
//! exists to pin the semantics in `store.zig` down in tests that run in milliseconds, and to
//! give controllers a store that needs no database. The conformance suite
//! (`zig build test-store`, with the Postgres and SQLite backends) is written against the same
//! rules, and this file is the first thing it runs against.
//!
//! It keeps the whole history in an append-only log, as the SQL backends do (docs/store-design.md),
//! plus a table of live keys. Lookups are linear: the point is clarity, not speed. It is
//! single-threaded: a threaded caller wraps it in a mutex. An allocation failure in the middle
//! of a transaction is reported as `NoCapacity` but is not rolled back; the tests never inject
//! one, and the SQL backends get atomicity from the database.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const Clock = @import("clock.zig").Clock;
const ManualClock = @import("clock.zig").ManualClock;
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const LeaseId = store.LeaseId;
const Error = store.Error;

/// A key as it is now, or as it was when an event wrote it. Strings are owned by `gpa`.
const Entry = struct {
    kind: store.EventKind,
    key: []u8,
    value: []u8,
    create_revision: Revision,
    mod_revision: Revision,
    lease: LeaseId,
};

const LeaseState = struct {
    id: LeaseId,
    ttl_ms: u32,
    deadline_ms: u64,
};

const WatchSlot = struct {
    owner: *MemoryStore,
    used: bool,
    prefix: [constants.store_key_bytes_max]u8,
    prefix_len: u32,
    next_revision: Revision,
};

pub const MemoryStore = struct {
    gpa: Allocator,
    clock: Clock,
    revision: Revision,
    compacted_revision: Revision,
    lease_next: LeaseId,
    live: std.ArrayList(Entry),
    log: std.ArrayList(Entry),
    leases: std.ArrayList(LeaseState),
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

    /// Initialises in place: watches point back at the store, so it must not move afterwards.
    pub fn init(self: *MemoryStore, gpa: Allocator, clock: Clock) void {
        self.* = .{
            .gpa = gpa,
            .clock = clock,
            .revision = 0,
            .compacted_revision = 0,
            .lease_next = 1,
            .live = .empty,
            .log = .empty,
            .leases = .empty,
            .watches = undefined,
        };
        for (&self.watches) |*slot| slot.used = false;
        assert(self.revision == 0);
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.live.items) |entry| free_entry(self.gpa, entry);
        for (self.log.items) |entry| free_entry(self.gpa, entry);
        self.live.deinit(self.gpa);
        self.log.deinit(self.gpa);
        self.leases.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn interface(self: *MemoryStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *MemoryStore {
        return @ptrCast(@alignCast(context));
    }

    // ---- Reads ---------------------------------------------------------------------------

    fn status_impl(context: *anyopaque, diag: *Diag) Error!store.Status {
        _ = diag;
        const self = from(context);
        return .{ .revision = self.revision, .compacted_revision = self.compacted_revision };
    }

    /// Fails unless `revision` can be read: not older than the compaction point, not future.
    fn check_readable(self: *const MemoryStore, revision: Revision, diag: *Diag) Error!void {
        if (revision > self.revision) {
            diag.raise(.E0204);
            diag.cause("revision {d} was asked for; the store is at {d}", .{
                revision, self.revision,
            });
            diag.fix(.{ .sentence = "use a revision this store returned" });
            return error.FutureRevision;
        }
        if (revision < self.compacted_revision) return compacted(revision, self, diag);
    }

    fn compacted(needed: Revision, self: *const MemoryStore, diag: *Diag) error{Compacted} {
        diag.raise(.E0203);
        diag.cause("history is needed from revision {d}; the store keeps it from {d}", .{
            needed, self.compacted_revision,
        });
        diag.fix(.{ .sentence = "list the current state and watch again from its revision" });
        return error.Compacted;
    }

    fn get_impl(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?Revision,
        diag: *Diag,
    ) Error!store.GetResult {
        const self = from(context);
        const revision = at_revision orelse self.revision;
        try self.check_readable(revision, diag);
        var found: ?Entry = null;
        if (at_revision == null) {
            if (self.find(self.live.items, key)) |index| found = self.live.items[index];
        } else {
            // The last event for the key at or before the revision decides.
            for (self.log.items) |entry| {
                if (entry.mod_revision > revision) break;
                if (std.mem.eql(u8, entry.key, key)) found = entry;
            }
            if (found) |entry| {
                if (entry.kind == .delete) found = null;
            }
        }
        const entry = found orelse return .{ .kv = null, .revision = revision };
        return .{ .kv = try copy_kv(arena, entry, diag), .revision = revision };
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) Error!store.ListResult {
        const self = from(context);
        const revision = options.at_revision orelse self.revision;
        try self.check_readable(revision, diag);
        const entries = try self.snapshot(arena, revision, options.prefix, diag);
        var start: usize = 0;
        if (options.continue_after) |after| {
            while (start < entries.len) : (start += 1) {
                if (std.mem.order(u8, entries[start].key, after) == .gt) break;
            }
        }
        var end = start;
        var bytes: usize = 0;
        while (end < entries.len and end - start < options.limit) : (end += 1) {
            const size = entries[end].value.len;
            if (end > start and bytes + size > constants.store_page_bytes_max) break;
            bytes += size;
        }
        const more = end < entries.len;
        const last_key: ?[]const u8 = if (more) entries[end - 1].key else null;
        return .{ .kvs = entries[start..end], .revision = revision, .continue_after = last_key };
    }

    /// The keys under `prefix` as they were at `revision`, ascending, copied into `arena`.
    fn snapshot(
        self: *const MemoryStore,
        arena: Allocator,
        revision: Revision,
        prefix: []const u8,
        diag: *Diag,
    ) Error![]store.KeyValue {
        var state: std.ArrayList(Entry) = .empty; // Borrowed entries; only the list is arena.
        for (self.log.items) |entry| {
            if (entry.mod_revision > revision) break;
            if (!std.mem.startsWith(u8, entry.key, prefix)) continue;
            const slot = self.find(state.items, entry.key);
            switch (entry.kind) {
                .put => if (slot) |index| {
                    state.items[index] = entry;
                } else {
                    state.append(arena, entry) catch return no_memory(diag);
                },
                .delete => if (slot) |index| {
                    _ = state.swapRemove(index);
                },
            }
        }
        std.mem.sort(Entry, state.items, {}, entry_key_less);
        const kvs = arena.alloc(store.KeyValue, state.items.len) catch return no_memory(diag);
        for (state.items, kvs) |entry, *kv| kv.* = try copy_kv(arena, entry, diag);
        return kvs;
    }

    // ---- Transactions --------------------------------------------------------------------

    fn txn_impl(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) Error!store.TxnResult {
        const self = from(context);
        var succeeded = true;
        for (request.compares) |compare| {
            const index = self.find(self.live.items, compare.key);
            const current: Revision = if (index) |i| self.live.items[i].mod_revision else 0;
            if (current != compare.mod_revision) succeeded = false;
        }
        const ops = if (succeeded) request.on_success else request.on_failure;
        try self.check_leases(ops, diag);
        var bumped = false;
        for (ops) |op| {
            const writes = switch (op) {
                .put => true,
                .delete => |key| self.find(self.live.items, key) != null,
            };
            if (!writes) continue;
            if (!bumped) self.revision += 1;
            bumped = true;
            switch (op) {
                .put => |put| try self.apply_put(put, diag),
                .delete => |key| try self.apply_delete(key, diag),
            }
        }
        return .{ .succeeded = succeeded, .revision = self.revision };
    }

    /// Every lease a put names must be alive, and no lease may end up with too many keys.
    /// Checked before anything is applied, so a refusal leaves the store untouched.
    fn check_leases(self: *const MemoryStore, ops: []const store.Op, diag: *Diag) Error!void {
        for (ops) |op| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (put.lease == store.lease_none) continue;
            if (!self.lease_alive(put.lease)) return lease_not_found(put.lease, diag);
            var count: u32 = 0;
            for (self.live.items) |entry| {
                if (entry.lease == put.lease) count += 1;
            }
            for (ops) |other| {
                if (other != .put) continue;
                if (other.put.lease != put.lease) continue;
                const index = self.find(self.live.items, other.put.key);
                if (index == null) count += 1;
            }
            if (count > constants.store_lease_keys_max) {
                diag.raise(.E0207);
                diag.cause("lease {d} would hold {d} keys; the limit is {d}", .{
                    put.lease, count, constants.store_lease_keys_max,
                });
                diag.fix(.{ .sentence = "attach fewer keys to one lease" });
                return error.NoCapacity;
            }
        }
    }

    fn apply_put(self: *MemoryStore, put: store.Put, diag: *Diag) Error!void {
        assert(self.revision > 0);
        const value = self.gpa.dupe(u8, put.value) catch return no_memory(diag);
        const existing = self.find(self.live.items, put.key);
        var create_revision = self.revision;
        if (existing) |i| create_revision = self.live.items[i].create_revision;
        const key = self.gpa.dupe(u8, put.key) catch return no_memory(diag);
        const logged: Entry = .{
            .kind = .put,
            .key = key,
            .value = value,
            .create_revision = create_revision,
            .mod_revision = self.revision,
            .lease = put.lease,
        };
        self.log.append(self.gpa, logged) catch return no_memory(diag);
        // The live table owns its own copies so that compaction can free the log's.
        const live_entry: Entry = .{
            .kind = .put,
            .key = self.gpa.dupe(u8, put.key) catch return no_memory(diag),
            .value = self.gpa.dupe(u8, put.value) catch return no_memory(diag),
            .create_revision = create_revision,
            .mod_revision = self.revision,
            .lease = put.lease,
        };
        if (existing) |i| {
            free_entry(self.gpa, self.live.items[i]);
            self.live.items[i] = live_entry;
        } else {
            self.live.append(self.gpa, live_entry) catch return no_memory(diag);
        }
    }

    fn apply_delete(self: *MemoryStore, key: []const u8, diag: *Diag) Error!void {
        assert(self.revision > 0);
        const index = self.find(self.live.items, key).?; // Checked by the caller.
        const old = self.live.items[index];
        const logged: Entry = .{
            .kind = .delete,
            .key = self.gpa.dupe(u8, key) catch return no_memory(diag),
            .value = self.gpa.alloc(u8, 0) catch return no_memory(diag),
            .create_revision = old.create_revision,
            .mod_revision = self.revision,
            .lease = old.lease,
        };
        self.log.append(self.gpa, logged) catch return no_memory(diag);
        free_entry(self.gpa, old);
        _ = self.live.swapRemove(index);
    }

    // ---- Watch ---------------------------------------------------------------------------

    fn watch_impl(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) Error!store.Watch {
        const self = from(context);
        if (options.from_revision <= self.compacted_revision) {
            return compacted(options.from_revision, self, diag);
        }
        if (options.from_revision > self.revision + 1) {
            diag.raise(.E0204);
            diag.cause("a watch from revision {d} was asked for; the store is at {d}", .{
                options.from_revision, self.revision,
            });
            diag.fix(.{ .sentence = "watch from a revision this store returned, plus one" });
            return error.FutureRevision;
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
        diag.raise(.E0207);
        diag.cause("all {d} watch slots are in use", .{constants.store_watches_max});
        diag.fix(.{ .sentence = "close watches that are no longer needed" });
        return error.NoCapacity;
    }

    fn watch_next_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) Error!store.WatchBatch {
        _ = timeout_ms; // Deterministic: report what is ready now.
        const slot: *WatchSlot = @ptrCast(@alignCast(context));
        const self = slot.owner;
        assert(slot.used);
        if (slot.next_revision <= self.compacted_revision) {
            return compacted(slot.next_revision, self, diag);
        }
        const prefix = slot.prefix[0..slot.prefix_len];
        var events: std.ArrayList(store.Event) = .empty;
        var bookmark = slot.next_revision - 1;
        var index: usize = 0;
        while (index < self.log.items.len) {
            const revision = self.log.items[index].mod_revision;
            var end = index;
            while (end < self.log.items.len) : (end += 1) {
                if (self.log.items[end].mod_revision != revision) break;
            }
            const run = self.log.items[index..end];
            index = end;
            if (revision < slot.next_revision) continue;
            const matching = count_matching(run, prefix);
            const full = events.items.len + matching > constants.store_watch_batch_max;
            if (full) {
                assert(events.items.len > 0); // A revision always fits (constants.zig).
                break;
            }
            for (run) |entry| {
                if (!std.mem.startsWith(u8, entry.key, prefix)) continue;
                const event: store.Event = .{
                    .kind = entry.kind,
                    .kv = try copy_kv(arena, entry, diag),
                };
                events.append(arena, event) catch return no_memory(diag);
            }
            bookmark = revision;
        }
        if (index == self.log.items.len) bookmark = self.revision;
        slot.next_revision = bookmark + 1;
        return .{ .events = events.items, .revision = bookmark };
    }

    fn watch_close_impl(context: *anyopaque) void {
        const slot: *WatchSlot = @ptrCast(@alignCast(context));
        assert(slot.used);
        slot.used = false;
    }

    // ---- Leases --------------------------------------------------------------------------

    fn lease_alive(self: *const MemoryStore, id: LeaseId) bool {
        for (self.leases.items) |lease| {
            if (lease.id == id) return self.clock.now_ms() <= lease.deadline_ms;
        }
        return false;
    }

    fn lease_grant_impl(context: *anyopaque, ttl_ms: u32, diag: *Diag) Error!store.Lease {
        const self = from(context);
        if (self.leases.items.len >= constants.store_leases_max) {
            diag.raise(.E0207);
            diag.cause("all {d} lease slots are in use", .{constants.store_leases_max});
            diag.fix(.{ .sentence = "revoke leases that are no longer needed" });
            return error.NoCapacity;
        }
        const lease: LeaseState = .{
            .id = self.lease_next,
            .ttl_ms = ttl_ms,
            .deadline_ms = self.clock.now_ms() + ttl_ms,
        };
        self.leases.append(self.gpa, lease) catch return no_memory(diag);
        self.lease_next += 1;
        return .{ .id = lease.id, .ttl_ms = ttl_ms };
    }

    fn lease_keepalive_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!store.Lease {
        const self = from(context);
        if (!self.lease_alive(id)) return lease_not_found(id, diag);
        for (self.leases.items) |*lease| {
            if (lease.id != id) continue;
            lease.deadline_ms = self.clock.now_ms() + lease.ttl_ms;
            return .{ .id = id, .ttl_ms = lease.ttl_ms };
        }
        unreachable; // `lease_alive` found it.
    }

    fn lease_revoke_impl(context: *anyopaque, id: LeaseId, diag: *Diag) Error!Revision {
        const self = from(context);
        var position: ?usize = null;
        for (self.leases.items, 0..) |lease, index| {
            if (lease.id == id) position = index;
        }
        const index = position orelse return lease_not_found(id, diag);
        _ = self.leases.swapRemove(index);
        var keys: [constants.store_lease_keys_max][]const u8 = undefined;
        var count: u32 = 0;
        for (self.live.items) |entry| {
            if (entry.lease != id) continue;
            keys[count] = entry.key; // Borrowed from `live`; stable until the deletes below.
            count += 1;
        }
        if (count == 0) return self.revision;
        // Sorted, so that the events of one revoke come in a defined order.
        std.mem.sort([]const u8, keys[0..count], {}, bytes_less);
        var owned: [constants.store_lease_keys_max][constants.store_key_bytes_max]u8 = undefined;
        self.revision += 1;
        for (keys[0..count], 0..) |key, slot| {
            @memcpy(owned[slot][0..key.len], key); // `apply_delete` frees the live copy.
            try self.apply_delete(owned[slot][0..key.len], diag);
        }
        return self.revision;
    }

    fn expire_leases_impl(context: *anyopaque, diag: *Diag) Error!u32 {
        const self = from(context);
        const now = self.clock.now_ms();
        var expired: u32 = 0;
        while (true) {
            var due: ?LeaseId = null;
            for (self.leases.items) |lease| {
                if (lease.deadline_ms < now) due = lease.id;
            }
            const id = due orelse break;
            _ = try lease_revoke_impl(context, id, diag);
            expired += 1;
        }
        return expired;
    }

    // ---- Compaction ----------------------------------------------------------------------

    fn compact_impl(context: *anyopaque, revision: Revision, diag: *Diag) Error!void {
        const self = from(context);
        if (revision > self.revision) {
            diag.raise(.E0204);
            diag.cause("compaction to revision {d} was asked for; the store is at {d}", .{
                revision, self.revision,
            });
            diag.fix(.{ .sentence = "compact to a revision this store returned" });
            return error.FutureRevision;
        }
        if (revision <= self.compacted_revision) return;
        // Keep an event if it is newer than the point, or it is the latest put of its key at or
        // before it. Tombstones at or before the point say nothing a reader at or after the
        // point needs: the key is simply absent.
        var kept: usize = 0;
        for (self.log.items, 0..) |entry, index| {
            if (entry.mod_revision > revision or self.is_latest_put(index, revision)) {
                self.log.items[kept] = entry;
                kept += 1;
            } else {
                free_entry(self.gpa, entry);
            }
        }
        self.log.items.len = kept;
        self.compacted_revision = revision;
    }

    fn is_latest_put(self: *const MemoryStore, index: usize, revision: Revision) bool {
        const entry = self.log.items[index];
        if (entry.kind != .put) return false;
        for (self.log.items[index + 1 ..]) |later| {
            if (later.mod_revision > revision) break;
            if (std.mem.eql(u8, later.key, entry.key)) return false;
        }
        return true;
    }

    // ---- Helpers -------------------------------------------------------------------------

    fn find(self: *const MemoryStore, entries: []const Entry, key: []const u8) ?usize {
        _ = self;
        for (entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }
};

fn count_matching(run: []const Entry, prefix: []const u8) u32 {
    var count: u32 = 0;
    for (run) |entry| {
        if (std.mem.startsWith(u8, entry.key, prefix)) count += 1;
    }
    return count;
}

fn free_entry(gpa: Allocator, entry: Entry) void {
    gpa.free(entry.key);
    gpa.free(entry.value);
}

fn entry_key_less(context: void, first: Entry, second: Entry) bool {
    _ = context;
    return std.mem.order(u8, first.key, second.key) == .lt;
}

fn bytes_less(context: void, first: []const u8, second: []const u8) bool {
    _ = context;
    return std.mem.order(u8, first, second) == .lt;
}

fn copy_kv(arena: Allocator, entry: Entry, diag: *Diag) Error!store.KeyValue {
    const key = arena.dupe(u8, entry.key) catch return no_memory(diag);
    const value = arena.dupe(u8, entry.value) catch return no_memory(diag);
    return .{
        .key = key,
        .value = value,
        .create_revision = entry.create_revision,
        .mod_revision = entry.mod_revision,
        .lease = entry.lease,
    };
}

fn no_memory(diag: *Diag) error{NoCapacity} {
    diag.raise(.E0207);
    diag.cause("the memory set aside for this request ran out", .{});
    diag.fix(.{ .sentence = "ask for smaller pages, or raise the request arena limit" });
    return error.NoCapacity;
}

fn lease_not_found(id: LeaseId, diag: *Diag) error{LeaseNotFound} {
    diag.raise(.E0205);
    diag.cause("lease {d} is unknown, expired or revoked", .{id});
    diag.fix(.{ .sentence = "grant a new lease and register again" });
    return error.LeaseNotFound;
}

// ---- Tests: these pin the semantics every backend must share ----------------------------------

const testing = std.testing;

const Fixture = struct {
    manual: ManualClock = .{},
    memory: MemoryStore = undefined,
    arena_state: std.heap.ArenaAllocator = undefined,
    diag: Diag = undefined,

    fn start(fixture: *Fixture) void {
        fixture.memory.init(testing.allocator, fixture.manual.clock());
        fixture.arena_state = .init(testing.allocator);
        fixture.diag.reset();
    }

    fn stop(fixture: *Fixture) void {
        fixture.arena_state.deinit();
        fixture.memory.deinit();
    }

    fn arena(fixture: *Fixture) Allocator {
        return fixture.arena_state.allocator();
    }

    fn put(fixture: *Fixture, key: []const u8, value: []const u8) !Revision {
        const op: store.Op = .{ .put = .{ .key = key, .value = value } };
        const result = try fixture.memory.interface().txn(
            .{ .on_success = &.{op} },
            &fixture.diag,
        );
        try testing.expect(result.succeeded);
        return result.revision;
    }

    fn expect_code(fixture: *Fixture, code: @import("diag/codes.zig").Code) !void {
        try testing.expectEqual(code, fixture.diag.code.?);
        fixture.diag.reset();
    }
};

test "compare-and-swap: create-only, update-if-unchanged, and the failure branch" {
    // Goal: the CAS rules of HANDOFF. Method: create a key with mod_revision 0, race a second
    // create (loses), update with the right and the wrong revision, and check that only the
    // winning branch is applied and each write takes exactly one revision.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    const key = "/services/hello";

    const create: store.Op = .{ .put = .{ .key = key, .value = "v1" } };
    const first = try s.txn(.{
        .compares = &.{.{ .key = key, .mod_revision = 0 }},
        .on_success = &.{create},
    }, &fixture.diag);
    try testing.expect(first.succeeded);
    try testing.expectEqual(@as(Revision, 1), first.revision);

    const loser = try s.txn(.{
        .compares = &.{.{ .key = key, .mod_revision = 0 }},
        .on_success = &.{.{ .put = .{ .key = key, .value = "lost" } }},
        .on_failure = &.{.{ .put = .{ .key = "/services/audit", .value = "create raced" } }},
    }, &fixture.diag);
    try testing.expect(!loser.succeeded);
    try testing.expectEqual(@as(Revision, 2), loser.revision);

    const update = try s.txn(.{
        .compares = &.{.{ .key = key, .mod_revision = 1 }},
        .on_success = &.{.{ .put = .{ .key = key, .value = "v2" } }},
    }, &fixture.diag);
    try testing.expect(update.succeeded);
    const got = (try s.get(fixture.arena(), key, null, &fixture.diag));
    try testing.expectEqualStrings("v2", got.kv.?.value);
    try testing.expectEqual(@as(Revision, 1), got.kv.?.create_revision);
    try testing.expectEqual(@as(Revision, 3), got.kv.?.mod_revision);

    const stale = try s.txn(.{
        .compares = &.{.{ .key = key, .mod_revision = 1 }},
        .on_success = &.{.{ .put = .{ .key = key, .value = "stale" } }},
    }, &fixture.diag);
    try testing.expect(!stale.succeeded);
    try testing.expectEqual(@as(Revision, 3), stale.revision); // Wrote nothing: no revision.
}

test "a transaction that changes nothing takes no revision" {
    // Goal: "revision bumps iff a key changes". Method: delete an absent key, then an empty
    // transaction; the revision must not move.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    _ = try fixture.put("/a", "1");
    const result = try s.txn(.{ .on_success = &.{.{ .delete = "/absent" }} }, &fixture.diag);
    try testing.expect(result.succeeded);
    try testing.expectEqual(@as(Revision, 1), result.revision);
    try testing.expectEqual(@as(Revision, 1), (try s.status(&fixture.diag)).revision);
}

test "list pages are consistent at one revision and ordered by key" {
    // Goal: pagination with at_revision. Method: write five keys, read page one, write more
    // (including inside the prefix), then read page two at the first page's revision; the
    // later writes must not appear, and the pages must join up with no repeat and no gap.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    for ([_][]const u8{ "/r/e", "/r/b", "/r/d", "/r/a", "/r/c", "/other/x" }) |key| {
        _ = try fixture.put(key, "v");
    }
    const page1 = try s.list(fixture.arena(), .{ .prefix = "/r/", .limit = 2 }, &fixture.diag);
    try testing.expectEqual(@as(usize, 2), page1.kvs.len);
    try testing.expectEqualStrings("/r/a", page1.kvs[0].key);
    try testing.expectEqualStrings("/r/b", page1.kvs[1].key);
    try testing.expectEqualStrings("/r/b", page1.continue_after.?);

    _ = try fixture.put("/r/bb", "late");
    _ = try s.txn(.{ .on_success = &.{.{ .delete = "/r/d" }} }, &fixture.diag);

    const page2 = try s.list(fixture.arena(), .{
        .prefix = "/r/",
        .limit = 10,
        .at_revision = page1.revision,
        .continue_after = page1.continue_after,
    }, &fixture.diag);
    try testing.expectEqual(@as(usize, 3), page2.kvs.len);
    try testing.expectEqualStrings("/r/c", page2.kvs[0].key);
    try testing.expectEqualStrings("/r/d", page2.kvs[1].key);
    try testing.expectEqualStrings("/r/e", page2.kvs[2].key);
    try testing.expect(page2.continue_after == null);
}

test "history can be read until it is compacted, and the error is explicit" {
    // Goal: at_revision and compaction. Method: three versions of a key, a delete, read each
    // revision, compact, then read below, at and above the compaction point.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    _ = try fixture.put("/k", "one"); // 1
    _ = try fixture.put("/k", "two"); // 2
    _ = try fixture.put("/other", "x"); // 3
    _ = try s.txn(.{ .on_success = &.{.{ .delete = "/k" }} }, &fixture.diag); // 4

    const at1 = try s.get(fixture.arena(), "/k", 1, &fixture.diag);
    try testing.expectEqualStrings("one", at1.kv.?.value);
    const at3 = try s.get(fixture.arena(), "/k", 3, &fixture.diag);
    try testing.expectEqualStrings("two", at3.kv.?.value);
    try testing.expect((try s.get(fixture.arena(), "/k", 4, &fixture.diag)).kv == null);

    try s.compact(3, &fixture.diag);
    try testing.expectError(error.Compacted, s.get(fixture.arena(), "/k", 2, &fixture.diag));
    try fixture.expect_code(.E0203);
    const kept = try s.get(fixture.arena(), "/k", 3, &fixture.diag);
    try testing.expectEqualStrings("two", kept.kv.?.value);
    try testing.expect((try s.get(fixture.arena(), "/k", 4, &fixture.diag)).kv == null);
    try testing.expectError(error.FutureRevision, s.get(fixture.arena(), "/k", 5, &fixture.diag));
    try fixture.expect_code(.E0204);

    try s.compact(2, &fixture.diag); // Below the point: nothing to do, not an error.
    try testing.expectEqual(@as(Revision, 3), (try s.status(&fixture.diag)).compacted_revision);
    try testing.expectError(error.FutureRevision, s.compact(9, &fixture.diag));
    try fixture.expect_code(.E0204);
}

test "a watch delivers every event once, in order, and resumes from its bookmark" {
    // Goal: the watch contract. Method: write, watch from the start and from the middle, write
    // a multi-key transaction, and read in two steps; the transaction's events must arrive
    // together, filtered by prefix, and a reconnect from bookmark + 1 must see only new ones.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    _ = try fixture.put("/w/a", "1"); // 1
    _ = try fixture.put("/x/a", "ignored"); // 2

    var watch = try s.watch(.{ .prefix = "/w/", .from_revision = 1 }, &fixture.diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/w/b", .value = "2" } },
        .{ .put = .{ .key = "/x/b", .value = "ignored" } },
        .{ .put = .{ .key = "/w/c", .value = "3" } },
    };
    _ = try s.txn(.{ .on_success = &ops }, &fixture.diag); // 3

    const batch = try watch.next(fixture.arena(), 0, &fixture.diag);
    try testing.expectEqual(@as(Revision, 3), batch.revision);
    try testing.expectEqual(@as(usize, 3), batch.events.len);
    try testing.expectEqualStrings("/w/a", batch.events[0].kv.key);
    try testing.expectEqualStrings("/w/b", batch.events[1].kv.key);
    try testing.expectEqualStrings("/w/c", batch.events[2].kv.key);
    try testing.expectEqual(@as(Revision, 3), batch.events[2].kv.mod_revision);

    // Idle: no events, but the bookmark still advances past a write outside the prefix.
    _ = try fixture.put("/x/c", "ignored"); // 4
    const idle = try watch.next(fixture.arena(), 0, &fixture.diag);
    try testing.expectEqual(@as(usize, 0), idle.events.len);
    try testing.expectEqual(@as(Revision, 4), idle.revision);
    watch.close();

    _ = try s.txn(.{ .on_success = &.{.{ .delete = "/w/a" }} }, &fixture.diag); // 5
    const resume_from = idle.revision + 1;
    var again = try s.watch(.{ .prefix = "/w/", .from_revision = resume_from }, &fixture.diag);
    defer again.close();
    const resumed = try again.next(fixture.arena(), 0, &fixture.diag);
    try testing.expectEqual(@as(usize, 1), resumed.events.len);
    try testing.expectEqual(store.EventKind.delete, resumed.events[0].kind);
    try testing.expectEqual(@as(Revision, 5), resumed.events[0].kv.mod_revision);
    try testing.expectEqual(@as(usize, 0), resumed.events[0].kv.value.len);
}

test "a watch that falls behind compaction fails explicitly, as does an old start" {
    // Goal: "compacted" is an error, not silence. Method: open a watch, compact past it, read;
    // then open one from a compacted revision and from the future.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    _ = try fixture.put("/a", "1");
    _ = try fixture.put("/a", "2");
    _ = try fixture.put("/a", "3");

    var watch = try s.watch(.{ .prefix = "/", .from_revision = 2 }, &fixture.diag);
    defer watch.close();
    try s.compact(3, &fixture.diag);
    try testing.expectError(error.Compacted, watch.next(fixture.arena(), 0, &fixture.diag));
    try fixture.expect_code(.E0203);
    try testing.expectError(
        error.Compacted,
        s.watch(.{ .prefix = "/", .from_revision = 3 }, &fixture.diag),
    );
    try fixture.expect_code(.E0203);
    var fresh = try s.watch(.{ .prefix = "/", .from_revision = 4 }, &fixture.diag);
    fresh.close();
    try testing.expectError(
        error.FutureRevision,
        s.watch(.{ .prefix = "/", .from_revision = 5 }, &fixture.diag),
    );
    try fixture.expect_code(.E0204);
}

test "an expired lease deletes its keys under one revision, and cannot be renewed" {
    // Goal: lease semantics. Method: attach two keys, renew once, let it lapse; expiry must
    // delete both in one revision and show up on a watch, and a late keepalive must fail.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    const lease = try s.lease_grant(1000, &fixture.diag);
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/nodes/n2", .value = "b", .lease = lease.id } },
        .{ .put = .{ .key = "/nodes/n1", .value = "a", .lease = lease.id } },
        .{ .put = .{ .key = "/services/s", .value = "kept" } },
    };
    const written = try s.txn(.{ .on_success = &ops }, &fixture.diag);

    fixture.manual.advance(900);
    _ = try s.lease_keepalive(lease.id, &fixture.diag);
    fixture.manual.advance(900);
    try testing.expectEqual(@as(u32, 0), try s.expire_leases(&fixture.diag));

    const options: store.WatchOptions = .{
        .prefix = "/nodes/",
        .from_revision = written.revision + 1,
    };
    var watch = try s.watch(options, &fixture.diag);
    defer watch.close();
    fixture.manual.advance(200);
    try testing.expectError(error.LeaseNotFound, s.lease_keepalive(lease.id, &fixture.diag));
    try fixture.expect_code(.E0205);
    try testing.expectEqual(@as(u32, 1), try s.expire_leases(&fixture.diag));

    const batch = try watch.next(fixture.arena(), 0, &fixture.diag);
    try testing.expectEqual(@as(usize, 2), batch.events.len);
    try testing.expectEqual(store.EventKind.delete, batch.events[0].kind);
    try testing.expectEqualStrings("/nodes/n1", batch.events[0].kv.key);
    try testing.expectEqualStrings("/nodes/n2", batch.events[1].kv.key);
    try testing.expectEqual(written.revision + 1, batch.events[0].kv.mod_revision);
    try testing.expectEqual(batch.events[0].kv.mod_revision, batch.events[1].kv.mod_revision);
    const kept = try s.get(fixture.arena(), "/services/s", null, &fixture.diag);
    try testing.expect(kept.kv != null);
}

test "a put naming a dead lease changes nothing" {
    // Goal: transactions are atomic even when the refusal is found late. Method: a transaction
    // whose second op names an unknown lease; the first op must not have been applied.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/a", .value = "1" } },
        .{ .put = .{ .key = "/b", .value = "2", .lease = 99 } },
    };
    try testing.expectError(error.LeaseNotFound, s.txn(.{ .on_success = &ops }, &fixture.diag));
    try fixture.expect_code(.E0205);
    try testing.expectEqual(@as(Revision, 0), (try s.status(&fixture.diag)).revision);
    try testing.expect((try s.get(fixture.arena(), "/a", null, &fixture.diag)).kv == null);
}

test "revoking a lease frees its keys; oversized requests are refused with a code" {
    // Goal: the negative space of the limits. Method: revoke, then a value one byte over the
    // bound, a branch with too many ops, and a ttl outside the range.
    var fixture: Fixture = .{};
    fixture.start();
    defer fixture.stop();
    const s = fixture.memory.interface();
    const lease = try s.lease_grant(5000, &fixture.diag);
    const attach: store.Op = .{ .put = .{ .key = "/n", .value = "v", .lease = lease.id } };
    _ = try s.txn(.{ .on_success = &.{attach} }, &fixture.diag);
    try testing.expectEqual(@as(Revision, 2), try s.lease_revoke(lease.id, &fixture.diag));
    try testing.expectError(error.LeaseNotFound, s.lease_revoke(lease.id, &fixture.diag));
    try fixture.expect_code(.E0205);

    const big = try testing.allocator.alloc(u8, constants.store_value_bytes_max + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expectError(
        error.TooLarge,
        s.txn(.{ .on_success = &.{.{ .put = .{ .key = "/big", .value = big } }} }, &fixture.diag),
    );
    try fixture.expect_code(.E0206);

    var many: [constants.store_txn_ops_max + 1]store.Op = undefined;
    var names: [many.len][8]u8 = undefined;
    for (&many, &names, 0..) |*op, *name, index| {
        const text = try std.fmt.bufPrint(name, "/k{d:0>4}", .{index});
        op.* = .{ .delete = text };
    }
    try testing.expectError(error.TooLarge, s.txn(.{ .on_success = &many }, &fixture.diag));
    try fixture.expect_code(.E0206);
    try testing.expectError(error.TooLarge, s.lease_grant(1, &fixture.diag));
    try fixture.expect_code(.E0206);
}
