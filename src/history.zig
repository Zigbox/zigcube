//! A service's generation history, `/history/<service>/<generation>` (docs/keys.md). The API
//! writes a record in the transaction of every apply that creates a service or raises its
//! generation, keeps the newest `constants.history_generations_max`, and deletes them all before
//! the service itself is deleted, so a service that is gone leaves no history behind.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;
pub const Error = controller.Error;

/// One stored history key, the generation it names and the revision that wrote it (a record is
/// never changed, so its `mod_revision` is when its generation was applied).
pub const Stored = struct { generation: u64, key: []const u8, mod_revision: store.Revision };

/// The service a history belongs to, as stored now: its key's `create_revision` and the generation
/// it runs.
pub const Owner = struct { create_revision: store.Revision, generation: u64 };

/// The history keys of `service`, ascending by generation (keys sort bytewise, so "10" comes
/// before "2": they are sorted here). A key under the prefix that names no generation is left
/// out: only the API writes there. More than `history_scan_max` is ZC-E0302.
pub fn stored(ctx: *const Context, service: []const u8) Error![]Stored {
    const prefix = records.history_prefix(service);
    var found: std.ArrayList(Stored) = .empty;
    var after: ?[]const u8 = null;
    var revision: ?store.Revision = null;
    while (true) {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .at_revision = revision,
            .limit = constants.history_scan_max + 1,
            .continue_after = after,
        }, ctx.diag);
        revision = page.revision;
        for (page.kvs) |kv| {
            if (found.items.len >= constants.history_scan_max) {
                return controller.too_many(ctx, prefix.slice(), constants.history_scan_max);
            }
            const generation = records.history_generation(kv.key) orelse continue;
            const entry: Stored = .{
                .generation = generation,
                .key = kv.key,
                .mod_revision = kv.mod_revision,
            };
            found.append(ctx.arena, entry) catch
                return failures.no_memory(ctx.diag);
        }
        after = page.continue_after;
        if (after == null) break;
    }
    std.mem.sortUnstable(Stored, found.items, {}, generation_less);
    return found.items;
}

fn generation_less(_: void, a: Stored, b: Stored) bool {
    return a.generation < b.generation;
}

/// The history of `owner` a rollback may restore, ascending: the generations from `owner`'s own
/// down to the first one missing, each written while this service existed. A record written
/// before the service was created belongs to an earlier service of the same name, deleted by a
/// build before C3, which leaves history behind; a generation missing below the service's own was
/// applied by such a build (a downgrade), so what lies below the gap is from before it. Neither
/// is this service's history as it stands: restoring it could bring back a deleted service's spec.
pub fn usable(ctx: *const Context, service: []const u8, owner: Owner) Error![]Stored {
    const existing = try stored(ctx, service);
    const low = usable_low(existing, owner);
    var count: usize = 0;
    for (existing) |entry| {
        if (!is_usable(entry, owner, low)) continue;
        existing[count] = entry;
        count += 1;
    }
    return existing[0..count];
}

/// The lowest generation of the unbroken run that ends at `owner.generation`, or null when the
/// owner's own generation has no record.
fn usable_low(existing: []const Stored, owner: Owner) ?u64 {
    var low: ?u64 = null;
    var expect = owner.generation;
    var index = existing.len;
    while (index > 0) {
        index -= 1;
        const entry = existing[index];
        if (entry.generation > expect) continue;
        if (entry.generation < expect) break;
        if (entry.mod_revision < owner.create_revision) break;
        low = expect;
        if (expect == 1) break;
        expect -= 1;
    }
    return low;
}

fn is_usable(entry: Stored, owner: Owner, low: ?u64) bool {
    const from = low orelse return false;
    if (entry.mod_revision < owner.create_revision) return false;
    return entry.generation >= from and entry.generation <= owner.generation;
}

/// Adds `record` to `batch`, deletes every stored record `usable` would not give `owner` (all of
/// them for a new service, `owner` null), then the oldest usable generations so that at most
/// `history_generations_max` remain once it commits. A record stored at the same generation is
/// replaced, not counted twice. Deletes beyond the batch's room are left for the next apply: the
/// cap is a bound on growth, the newest generations are never the ones dropped, and `usable`
/// never offers a record that is left over.
pub fn put(
    ctx: *const Context,
    batch: *controller.Batch,
    record: *const records.History,
    owner: ?Owner,
) Error!void {
    assert(record.generation > 0);
    assert(batch.has_room(1));
    if (owner) |service| assert(record.generation == service.generation + 1);
    if (owner == null) assert(record.generation == 1);
    const existing = try stored(ctx, record.service);
    const key = records.history_key(record.service, record.generation);
    const key_copy = try controller.key_copy(ctx, &key);
    batch.put(key_copy, try records.encode(ctx.arena, record.*, ctx.diag));
    const low = if (owner) |service| usable_low(existing, service) else null;
    var kept: u32 = 1;
    for (existing) |entry| {
        if (entry.generation == record.generation) continue; // Replaced by the put.
        if (owner != null and is_usable(entry, owner.?, low)) {
            kept += 1;
            continue;
        }
        if (!delete_room(batch)) return;
        batch.delete(entry.key);
    }
    var excess: u32 = kept -| constants.history_generations_max;
    for (existing) |entry| {
        if (excess == 0) break;
        if (owner == null or !is_usable(entry, owner.?, low)) continue;
        if (!delete_room(batch)) return;
        batch.delete(entry.key);
        excess -= 1;
    }
}

/// Whether `batch` can take one more delete and still the decision the caller adds after it.
fn delete_room(batch: *const controller.Batch) bool {
    return batch.has_room(1 + controller.decision_ops);
}

/// Deletes every history record of `service`, in transactions that each still find the service at
/// `service_mod_revision`, before the caller deletes the service. A conflict means the service
/// changed: what was deleted stays deleted (a rollback to it is ZC-E0128) and the caller starts
/// again from the new state.
pub fn delete_all(
    ctx: *const Context,
    service: []const u8,
    service_mod_revision: store.Revision,
) Error!controller.Commit {
    assert(service_mod_revision > 0);
    const existing = try stored(ctx, service);
    const service_key = records.service_key(service);
    const service_key_copy = try controller.key_copy(ctx, &service_key);
    var last: controller.Commit = .{ .applied = 0 };
    var at: usize = 0;
    while (at < existing.len) {
        var batch: controller.Batch = .{};
        batch.expect(service_key_copy, service_mod_revision);
        while (at < existing.len and batch.has_room(1)) : (at += 1) {
            batch.delete(existing[at].key);
        }
        last = try controller.commit(ctx, .api, &batch);
        if (last == .conflict) return .conflict;
    }
    return last;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

/// An owner that every record written so far belongs to (no service record in these tests).
fn owner_at(generation: u64) Owner {
    return .{ .create_revision = 0, .generation = generation };
}

fn history_record(generation: u64) records.History {
    return .{
        .service = "hello",
        .generation = generation,
        .image = "b3:51aa9c03",
        .command = &.{"/bin/hello"},
        .applied_by = "test",
        .request_id = "r1",
        .applied_at_ms = 1000 * generation,
        .reason = .apply,
    };
}

test "history keeps the newest generations, in numeric order" {
    // Goal: the cap drops the lowest generation by number, not by key order ("10" < "2"), and a
    // record rewritten at its own generation does not push another out.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1761350000123 };
    const memory = try testing.allocator.create(MemoryStore);
    defer testing.allocator.destroy(memory);
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: Context = .{
        .store = memory.interface(),
        .clock = manual.clock(),
        .arena = arena_state.allocator(),
        .diag = &diag,
    };
    const total = constants.history_generations_max + 4;
    var generation: u64 = 1;
    while (generation <= total) : (generation += 1) {
        var batch: controller.Batch = .{};
        const record = history_record(generation);
        try put(&ctx, &batch, &record, if (generation == 1) null else owner_at(generation - 1));
        try testing.expect(try controller.commit(&ctx, .api, &batch) == .applied);
    }
    const left = try stored(&ctx, "hello");
    try testing.expectEqual(@as(usize, constants.history_generations_max), left.len);
    const oldest = total - constants.history_generations_max + 1;
    try testing.expectEqual(@as(u64, oldest), left[0].generation);
    try testing.expectEqual(@as(u64, total), left[left.len - 1].generation);

    var again: controller.Batch = .{};
    const rewrite = history_record(total);
    try put(&ctx, &again, &rewrite, owner_at(total - 1));
    try testing.expectEqual(@as(u32, 1), again.ops_count);

    // The service is deleted by a build that leaves its history and applied again: generation 1
    // replaces its own key and deletes every other generation that fits, the rest next time;
    // what is left over is not usable meanwhile.
    var fresh: controller.Batch = .{};
    const first = history_record(1);
    try put(&ctx, &fresh, &first, null);
    try testing.expect(!fresh.has_room(1 + controller.decision_ops));
    const created = switch (try controller.commit(&ctx, .api, &fresh)) {
        .applied => |revision| revision,
        .conflict => return error.TestUnexpectedResult,
    };
    const owner: Owner = .{ .create_revision = created, .generation = 1 };
    try testing.expect((try stored(&ctx, "hello")).len > 1);
    const own = try usable(&ctx, "hello", owner);
    try testing.expectEqual(@as(usize, 1), own.len);
    try testing.expectEqual(@as(u64, 1), own[0].generation);
    var next: controller.Batch = .{};
    const second = history_record(2);
    try put(&ctx, &next, &second, owner);
    try testing.expect(try controller.commit(&ctx, .api, &next) == .applied);
    const now = try stored(&ctx, "hello");
    try testing.expectEqual(@as(usize, 2), now.len);
    try testing.expectEqual(@as(u64, 1), now[0].generation);
    try testing.expectEqual(@as(u64, 2), now[1].generation);
}
