//! Decision retention (docs/keys.md): the newest 200 decisions per subject and at most 7 days,
//! whichever is fewer; 24 hours after the subject is gone. A decision whose cause was dropped
//! stays readable: `zcube why` reports the missing link as a `gone` step.
//!
//! This runs as part of the controller's step, a few subjects at a time, with a cursor that
//! remembers where it stopped, so one step's work is bounded however many decisions exist. It
//! reads the by-subject index only (keys carry the subject and the id, and the id carries the
//! time), so no decision record is fetched to decide whether to keep it.
//!
//! One departure from docs/keys.md, which has the controller delete the oldest decision "in the
//! transaction that writes a new one for that subject": a count needs a list, and listing a
//! subject on every write would cost more than doing it for every subject once a minute. A
//! subject can therefore hold a few more than 200 until the next pass.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Error = controller.Error;
const Snapshot = controller.Snapshot;

/// Pages of the index one pass reads before it hands control back; the cursor carries on.
const pages_per_pass_max: u32 = 8;

pub const Cursor = struct {
    /// When the next pass is due, on the `Clock`'s scale. 0: now.
    due_ms: u64 = 0,
    /// Resume after this key of the index. Meaningful only if `resuming`.
    after: records.Key = .{},
    resuming: bool = false,
    /// Decisions this cursor has dropped (counted when the delete is attempted), for the
    /// simulation to tell a link retention removed from one that was never written.
    dropped: u64 = 0,
};

/// Reads up to `pages_per_pass_max` pages of the index from the cursor and drops what retention
/// says, a subject at a time. A page is a run of whole subjects: the last one in a full page may
/// continue on the next, so it is left for the next page unless it is the only one. Returns when
/// the next pass is due: now if the index was not finished, else a full interval on.
pub fn prune(
    ctx: *const Context,
    cursor: *Cursor,
    snapshot: *const Snapshot,
    now_ms: u64,
) Error!u64 {
    const revision = (try ctx.store.status(ctx.diag)).revision;
    var txns: u32 = 0;
    for (0..pages_per_pass_max) |_| {
        if (revision == 0) break;
        const after: ?[]const u8 = if (cursor.resuming) cursor.after.slice() else null;
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_index,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        const last_page = page.continue_after == null;
        const used = try prune_page(ctx, page.kvs, last_page, .{
            .snapshot = snapshot,
            .now_ms = now_ms,
            .txns = &txns,
            .dropped = &cursor.dropped,
        });
        if (used.len > 0) set_cursor(cursor, used.slice());
        if (last_page) break;
        if (txns >= constants.retention_batches_max) return now_ms;
    }
    const finished = !cursor.resuming or index_ended(ctx, cursor, revision);
    if (finished) {
        cursor.resuming = false;
        return now_ms + constants.retention_interval_ms;
    }
    return now_ms;
}

/// Whether nothing follows the cursor in the index.
fn index_ended(ctx: *const Context, cursor: *const Cursor, revision: store.Revision) bool {
    const page = ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_index,
        .at_revision = revision,
        .limit = 1,
        .continue_after = cursor.after.slice(),
    }, ctx.diag) catch {
        ctx.diag.reset();
        return false;
    };
    return page.kvs.len == 0;
}

fn set_cursor(cursor: *Cursor, after: []const u8) void {
    assert(after.len > 0);
    assert(after.len <= constants.store_key_bytes_max);
    @memcpy(cursor.after.bytes[0..after.len], after);
    cursor.after.len = @intCast(after.len);
    cursor.resuming = true;
}

const Subject = struct { kind: records.SubjectKind, name: []const u8, prefix: []const u8 };

/// `/decisions-by-subject/<kind>/<name>/<id>`: the subject and the prefix of all its entries.
fn parse_subject(key: []const u8) ?Subject {
    if (!std.mem.startsWith(u8, key, records.prefix_index)) return null;
    const rest = key[records.prefix_index.len..];
    const kind_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const kind = std.meta.stringToEnum(records.SubjectKind, rest[0..kind_end]) orelse return null;
    const after_kind = rest[kind_end + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, after_kind, '/') orelse return null;
    if (name_end == 0) return null;
    const prefix_len = records.prefix_index.len + kind_end + 1 + name_end + 1;
    return .{ .kind = kind, .name = after_kind[0..name_end], .prefix = key[0..prefix_len] };
}

/// The key after which the next subject's entries start: past every key of this subject's.
fn subject_end(prefix: []const u8) records.Key {
    var key: records.Key = .{};
    @memcpy(key.bytes[0..prefix.len], prefix);
    key.bytes[prefix.len] = '~';
    key.len = @intCast(prefix.len + 1);
    return key;
}

const PageWork = struct {
    snapshot: *const Snapshot,
    now_ms: u64,
    txns: *u32,
    dropped: *u64,
};

/// Prunes the whole subjects in `kvs`, and returns the key to resume after (length 0 if the page
/// held no subject). On a page that is not the last, the final subject is left for the next page
/// unless it is the only one.
fn prune_page(
    ctx: *const Context,
    kvs: []const store.KeyValue,
    last_page: bool,
    work: PageWork,
) Error!records.Key {
    var resume_after: records.Key = .{};
    var start: usize = 0;
    while (start < kvs.len) {
        const subject = parse_subject(kvs[start].key) orelse {
            resume_after = key_of(kvs[start].key);
            start += 1;
            continue;
        };
        var end = start + 1;
        while (end < kvs.len and std.mem.startsWith(u8, kvs[end].key, subject.prefix)) end += 1;
        const partial = end == kvs.len and !last_page;
        if (partial and start > 0) return resume_after;
        try prune_subject(ctx, subject, kvs[start..end], work);
        resume_after = subject_end(subject.prefix);
        start = end;
    }
    return resume_after;
}

fn key_of(text: []const u8) records.Key {
    var key: records.Key = .{};
    @memcpy(key.bytes[0..text.len], text);
    key.len = @intCast(text.len);
    return key;
}

fn prune_subject(
    ctx: *const Context,
    subject: Subject,
    kvs: []const store.KeyValue,
    work: PageWork,
) Error!void {
    var drop: [constants.store_list_limit_max]bool = @splat(false);
    mark_drops(kvs, subject, work.snapshot, work.now_ms, drop[0..kvs.len]);
    var batch: Batch = .{};
    for (kvs, drop[0..kvs.len]) |kv, marked| {
        if (!marked) continue;
        if (!batch.has_room(2)) try flush(ctx, &batch, work.txns);
        const id = kv.key[subject.prefix.len..];
        if (id.len != records.decision_id_bytes) continue;
        const decision = records.decision_key(id);
        work.dropped.* += 1;
        batch.delete(kv.key);
        batch.delete(try controller.key_copy(ctx, &decision));
    }
    try flush(ctx, &batch, work.txns);
}

fn flush(ctx: *const Context, batch: *Batch, txns: *u32) Error!void {
    if (batch.ops_count == 0) return;
    _ = try controller.commit(ctx, .retention, batch);
    txns.* += 1;
    batch.* = .{};
}

/// Sets `drop[i]` for each entry that retention removes. Entries ascend by id, so by time.
fn mark_drops(
    kvs: []const store.KeyValue,
    subject: Subject,
    snapshot: *const Snapshot,
    now_ms: u64,
    drop: []bool,
) void {
    assert(kvs.len == drop.len);
    if (kvs.len == 0) return;
    const newest = entry_time(kvs[kvs.len - 1].key, subject.prefix.len);
    const stale = age_ms(now_ms, newest) > constants.decision_gone_age_ms_max;
    const gone = !exists(snapshot, subject) and stale;
    var kept: u32 = 0;
    for (kvs, drop) |kv, *dropped| {
        const at = entry_time(kv.key, subject.prefix.len);
        const too_old = age_ms(now_ms, at) > constants.decision_age_ms_max;
        dropped.* = gone or too_old;
        if (!dropped.*) kept += 1;
    }
    for (drop) |*dropped| {
        if (kept <= constants.decisions_per_subject_max) break;
        if (dropped.*) continue;
        dropped.* = true;
        kept -= 1;
    }
    if (!gone) assert(kept <= constants.decisions_per_subject_max);
}

fn entry_time(key: []const u8, prefix_len: usize) u64 {
    return records.decision_id_time(key[prefix_len..]) orelse 0;
}

fn age_ms(now_ms: u64, at_ms: u64) u64 {
    return if (now_ms > at_ms) now_ms - at_ms else 0;
}

fn exists(snapshot: *const Snapshot, subject: Subject) bool {
    switch (subject.kind) {
        .service => return snapshot.service_of(subject.name) != null,
        .replica => {
            for (snapshot.replicas) |replica| {
                if (std.mem.eql(u8, replica.rec.id, subject.name)) return true;
            }
            return false;
        },
        .node => {
            for (snapshot.nodes) |node| {
                if (std.mem.eql(u8, node.rec.name, subject.name)) return true;
            }
            return false;
        },
    }
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 10 * constants.decision_age_ms_max };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) Context {
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    /// An index entry and its decision for a service subject, `age_ms` old.
    fn decide(self: *Fixture, name: []const u8, age: u64, counter: u32) !void {
        const ctx = self.context();
        const at = self.manual.ms - age;
        const id = records.decision_id(at, 1, counter);
        var batch: Batch = .{};
        const index = records.index_key(.service, name, id.slice());
        const decision = records.decision_key(id.slice());
        batch.put(try controller.key_copy(&ctx, &index), "{\"v\":1}");
        batch.put(try controller.key_copy(&ctx, &decision), "{\"v\":1}");
        _ = try controller.commit(&ctx, .retention, &batch);
    }

    fn count(self: *Fixture, prefix: []const u8) !usize {
        const ctx = self.context();
        const page = try ctx.store.list(ctx.arena, .{ .prefix = prefix, .limit = 500 }, ctx.diag);
        return page.kvs.len;
    }
};

const empty_snapshot: Snapshot = .{
    .revision = 0,
    .services = &.{},
    .replicas = &.{},
    .observed = &.{},
    .nodes = &.{},
};

test "decisions older than seven days go, with their index entries, and newer ones stay" {
    // Goal: the age rule. Method: one old and one fresh decision for a service that exists; a
    // pass drops exactly the old pair.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.decide("hello", constants.decision_age_ms_max + 1, 0);
    try fixture.decide("hello", 1000, 1);
    const service: records.Service = .{
        .name = "hello",
        .image = "i",
        .replicas = 1,
        .command = &.{"x"},
        .generation = 1,
    };
    const services = [_]Entry{.{ .kv = undefined, .rec = service }};
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    const due = try prune(&ctx, &cursor, &snapshot, fixture.manual.ms);
    try testing.expectEqual(fixture.manual.ms + constants.retention_interval_ms, due);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_decisions));
}

const Entry = controller.Entry(records.Service);

test "a subject keeps its newest two hundred and drops the older ones" {
    // Goal: the count rule at its boundary: 201 decisions leave 200, the oldest gone.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.decisions_per_subject_max + 1;
    for (0..total) |index| try fixture.decide("hello", 100_000 - index, @intCast(index));
    const service: records.Service = .{
        .name = "hello",
        .image = "i",
        .replicas = 1,
        .command = &.{"x"},
        .generation = 1,
    };
    const services = [_]Entry{.{ .kv = undefined, .rec = service }};
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    _ = try prune(&ctx, &cursor, &snapshot, fixture.manual.ms);
    try testing.expectEqual(@as(usize, 200), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 200), try fixture.count(records.prefix_decisions));
}

test "a deleted subject's decisions stay a day, then go" {
    // Goal: the 24-hour rule: with the service gone, entries survive while the newest is under a
    // day old and are all dropped once it is over a day old.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.decide("gone", constants.decision_gone_age_ms_max - 1000, 0);
    var ctx = fixture.context();
    var cursor: Cursor = .{};
    _ = try prune(&ctx, &cursor, &empty_snapshot, fixture.manual.ms);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_index));
    fixture.manual.advance(2000);
    ctx = fixture.context();
    cursor = .{};
    _ = try prune(&ctx, &cursor, &empty_snapshot, fixture.manual.ms);
    try testing.expectEqual(@as(usize, 0), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 0), try fixture.count(records.prefix_decisions));
}
