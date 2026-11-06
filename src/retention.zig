//! Decision retention (docs/keys.md, docs/authority.md §5): reachability decides what stays.
//!
//! A decision is evictable when it is beyond its subject's budget (the newest 200, at most 7
//! days) and no live subject's explanation needs it. The roots are, for each live subject, its
//! newest decision of each action; a pass walks each root's chain of `decision` causes (as `why`
//! does, bounded by `why_steps_max`) and pins every decision on it, across subjects: a crash
//! loop's `replace_replica` decisions evict each other and never the service's `apply`. A
//! deleted subject's decisions are not roots: they stay 24 hours, then go, and its summaries
//! (`/decision-summaries/`) with them. A decision whose cause was dropped stays readable: `zcube
//! why` reports the missing link as a `gone` step.
//!
//! This runs as part of the controller's step, a few subjects at a time, with a cursor that
//! remembers where it stopped, so one step's work is bounded however many decisions exist. The
//! budget is decided from the by-subject index alone (keys carry the subject and the id, and the
//! id carries the time). The pinned set is computed only when a pass has a candidate in a live
//! subject, once per pass, from the index of every live subject and the decisions on the chains.
//!
//! Fail safe: if the pinned set does not fit its bounds (`retention_pinned_max` decisions,
//! `retention_actions_per_subject_max` actions in a subject, a subject index or a decision that
//! does not fit `retention_scratch_bytes`, a record that does not parse), the pass drops
//! nothing from live subjects and the next pass tries again. Deleted subjects need no pins.
//! A decision written during a pass may cite an old decision the pass is about to drop; the
//! chain then reports `gone`, as for any dropped link.
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

const id_bytes = records.decision_id_bytes;

pub const Cursor = struct {
    /// When the next pass is due, on the `Clock`'s scale. 0: now.
    due_ms: u64 = 0,
    /// Resume after this key of the index. Meaningful only if `resuming`.
    after: records.Key = .{},
    resuming: bool = false,
    /// Decisions this cursor has dropped (counted when the delete is attempted), for the
    /// simulation to tell a link retention removed from one that was never written.
    dropped: u64 = 0,
    /// Decisions a pass may pin; `constants.retention_pinned_max`, lowered only by tests.
    pins_max: u32 = constants.retention_pinned_max,
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
    assert(cursor.pins_max <= constants.retention_pinned_max);
    const revision = (try ctx.store.status(ctx.diag)).revision;
    var txns: u32 = 0;
    var pins: Pins = .{};
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
            .revision = revision,
            .txns = &txns,
            .dropped = &cursor.dropped,
            .pins = &pins,
            .pins_max = cursor.pins_max,
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
    /// The revision the pass reads at.
    revision: store.Revision,
    txns: *u32,
    dropped: *u64,
    pins: *Pins,
    pins_max: u32,
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
        try prune_subject(ctx, subject, kvs[start..end], !partial, work);
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

/// `complete`: `kvs` holds every entry of the subject, not the first page of a longer run.
fn prune_subject(
    ctx: *const Context,
    subject: Subject,
    kvs: []const store.KeyValue,
    complete: bool,
    work: PageWork,
) Error!void {
    assert(kvs.len > 0);
    var drop: [constants.store_list_limit_max]bool = @splat(false);
    const newest = entry_time(kvs[kvs.len - 1].key, subject.prefix.len);
    const standing = standing_of(work.snapshot, subject, newest, work.now_ms);
    mark_drops(kvs, subject.prefix.len, standing, work.now_ms, drop[0..kvs.len]);
    if (standing == .live) try spare_pinned(ctx, kvs, subject, work, drop[0..kvs.len]);
    var batch: Batch = .{};
    if (standing == .gone and complete) try drop_summaries(ctx, subject, &batch, work.txns);
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

/// Deletes the summaries of a deleted subject whose decisions all go. They go first: a failed
/// pass then leaves decisions without their counts, never counts without any decision.
fn drop_summaries(ctx: *const Context, subject: Subject, batch: *Batch, txns: *u32) Error!void {
    const prefix = records.summary_prefix(subject.kind, subject.name);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = constants.store_list_limit_max,
    }, ctx.diag);
    for (page.kvs) |kv| {
        if (!batch.has_room(1)) try flush(ctx, batch, txns);
        batch.delete(kv.key);
    }
}

/// How a subject stands with retention.
const Standing = enum {
    /// It exists: its budget applies, and decisions that something live needs are kept.
    live,
    /// It was deleted less than a day ago: its decisions stay.
    kept_a_day,
    /// It was deleted more than a day ago: all its decisions go.
    gone,
};

fn standing_of(snapshot: *const Snapshot, subject: Subject, newest: u64, now_ms: u64) Standing {
    if (exists(snapshot, subject)) return .live;
    if (age_ms(now_ms, newest) > constants.decision_gone_age_ms_max) return .gone;
    return .kept_a_day;
}

/// Sets `drop[i]` for each entry that retention would remove if nothing live needed it. Entries
/// ascend by id, so by time.
fn mark_drops(
    kvs: []const store.KeyValue,
    prefix_len: usize,
    standing: Standing,
    now_ms: u64,
    drop: []bool,
) void {
    assert(kvs.len == drop.len);
    if (standing == .kept_a_day) return;
    var kept: u32 = 0;
    for (kvs, drop) |kv, *dropped| {
        const too_old = age_ms(now_ms, entry_time(kv.key, prefix_len)) >
            constants.decision_age_ms_max;
        dropped.* = standing == .gone or too_old;
        if (!dropped.*) kept += 1;
    }
    for (drop) |*dropped| {
        if (kept <= constants.decisions_per_subject_max) break;
        if (dropped.*) continue;
        dropped.* = true;
        kept -= 1;
    }
    if (standing == .live) assert(kept <= constants.decisions_per_subject_max);
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
        // The snapshot holds no jobs, and a job's chain is short (`decisions_per_subject_max` is
        // far more than a job needs): never claim it gone, so a live job's chain is not cut as
        // an orphan's.
        .job => return true,
    }
}

// ---- Reachability ------------------------------------------------------------------------------

const PinnedSet = std.AutoHashMapUnmanaged([id_bytes]u8, void);

/// The pinned set of one `prune` call, computed the first time a live subject has a candidate.
const Pins = struct {
    tried: bool = false,
    /// Null after a try that failed safe.
    set: ?PinnedSet = null,
};

/// Clears the mark of every entry something live needs: all of them if the set could not be
/// computed within its bounds.
fn spare_pinned(
    ctx: *const Context,
    kvs: []const store.KeyValue,
    subject: Subject,
    work: PageWork,
    drop: []bool,
) Error!void {
    assert(kvs.len == drop.len);
    const any = std.mem.indexOfScalar(bool, drop, true) != null;
    if (!any) return;
    if (!work.pins.tried) {
        work.pins.tried = true;
        work.pins.set = try compute_pins(ctx, work.snapshot, work.revision, work.pins_max);
    }
    const set = work.pins.set orelse {
        @memset(drop, false);
        return;
    };
    for (kvs, drop) |kv, *marked| {
        if (!marked.*) continue;
        const id = kv.key[subject.prefix.len..];
        if (id.len != id_bytes) continue;
        if (set.contains(id[0..id_bytes].*)) marked.* = false;
    }
}

const PinError = Error || error{Overflow};

/// The ids of every decision on the chain of a root of a live subject, or null if they do not
/// fit the bounds (the caller then drops nothing). Store failures other than a record that will
/// not parse or a page that does not fit are the caller's.
fn compute_pins(
    ctx: *const Context,
    snapshot: *const Snapshot,
    revision: store.Revision,
    pins_max: u32,
) Error!?PinnedSet {
    assert(pins_max > 0);
    const buffer = ctx.arena.alloc(u8, constants.retention_scratch_bytes) catch return null;
    var set: PinnedSet = .empty;
    set.ensureTotalCapacity(ctx.arena, pins_max) catch return null;
    var walk: Walk = .{
        .ctx = ctx,
        .scratch = std.heap.FixedBufferAllocator.init(buffer),
        .set = &set,
        .revision = revision,
        .pins_max = pins_max,
    };
    walk.subjects(snapshot) catch |err| switch (err) {
        error.Overflow, error.Malformed, error.NoCapacity => {
            ctx.diag.reset();
            return null;
        },
        else => |other| return other,
    };
    return set;
}

/// The newest decision of each action of one subject.
const Roots = struct {
    actions: [constants.retention_actions_per_subject_max][]const u8 = undefined,
    ids: [constants.retention_actions_per_subject_max][id_bytes]u8 = undefined,
    count: u32 = 0,

    fn has(roots: *const Roots, action: []const u8) bool {
        for (roots.actions[0..roots.count]) |seen| {
            if (std.mem.eql(u8, seen, action)) return true;
        }
        return false;
    }
};

const Walk = struct {
    ctx: *const Context,
    /// Reset for each index page and each decision read.
    scratch: std.heap.FixedBufferAllocator,
    set: *PinnedSet,
    revision: store.Revision,
    pins_max: u32,

    fn subjects(walk: *Walk, snapshot: *const Snapshot) PinError!void {
        for (snapshot.services) |service| try walk.subject(.service, service.rec.name);
        for (snapshot.replicas) |replica| try walk.subject(.replica, replica.rec.id);
        for (snapshot.nodes) |node| try walk.subject(.node, node.rec.name);
    }

    /// Pins the chain of each root of one live subject.
    fn subject(walk: *Walk, kind: records.SubjectKind, name: []const u8) PinError!void {
        var roots: Roots = .{};
        try walk.find_roots(kind, name, &roots);
        for (roots.ids[0..roots.count]) |root| try walk.pin_chain(root);
    }

    /// The subject's newest decision of each action, from its index in one page.
    fn find_roots(
        walk: *Walk,
        kind: records.SubjectKind,
        name: []const u8,
        roots: *Roots,
    ) PinError!void {
        walk.scratch.reset();
        const scratch = walk.scratch.allocator();
        const prefix = records.index_prefix(kind, name);
        const page = try walk.ctx.store.list(scratch, .{
            .prefix = prefix.slice(),
            .at_revision = walk.revision,
            .limit = constants.store_list_limit_max,
            .reverse = true,
        }, walk.ctx.diag);
        if (page.continue_after != null) return error.Overflow;
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, scratch, kv, walk.ctx.diag);
            if (entry.id.len != id_bytes) return error.Overflow;
            if (roots.has(entry.action)) continue;
            if (roots.count == constants.retention_actions_per_subject_max) return error.Overflow;
            roots.actions[roots.count] = entry.action;
            @memcpy(&roots.ids[roots.count], entry.id);
            roots.count += 1;
        }
        assert(roots.count <= page.kvs.len);
    }

    /// Pins `root` and the decisions its causes lead to, at most `why_steps_max` of them; one
    /// already pinned has been walked, so the walk stops there.
    fn pin_chain(walk: *Walk, root: [id_bytes]u8) PinError!void {
        var id = root;
        for (0..constants.why_steps_max) |_| {
            if (walk.set.contains(id)) return;
            if (walk.set.count() >= walk.pins_max) return error.Overflow;
            walk.set.putAssumeCapacity(id, {});
            walk.scratch.reset();
            const scratch = walk.scratch.allocator();
            const key = records.decision_key(&id);
            const got = try walk.ctx.store.get(scratch, key.slice(), null, walk.ctx.diag);
            const kv = got.kv orelse return; // Already dropped: the chain ends there.
            const decision = try records.read(records.Decision, scratch, kv, walk.ctx.diag);
            if (decision.cause.kind != .decision) return;
            const next = decision.cause.id orelse return;
            if (next.len != id_bytes) return;
            @memcpy(&id, next);
        }
    }
};

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
    next_counter: u32 = 0,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 10 * constants.decision_age_ms_max };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.next_counter = 0;
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

    const Spec = struct {
        kind: records.SubjectKind = .service,
        name: []const u8,
        age: u64,
        action: []const u8 = "apply",
        /// The decision this one is caused by; else it is caused by the desired spec.
        because: ?[]const u8 = null,
    };

    /// A decision and its index entry, `age` old, with an id that is unique and sorts by time.
    fn decide(self: *Fixture, spec: Spec) !records.DecisionId {
        const ctx = self.context();
        const id = records.decision_id(self.manual.ms - spec.age, 1, self.next_counter);
        self.next_counter += 1;
        const cause: records.Cause = if (spec.because) |cause_id|
            .{ .kind = .decision, .id = cause_id }
        else
            .{ .kind = .desired, .key = "/services/x", .revision = 1 };
        const decision: records.Decision = .{
            .id = id.slice(),
            .at_ms = self.manual.ms - spec.age,
            .actor = "test",
            .action = spec.action,
            .subject = .{ .kind = spec.kind, .name = spec.name },
            .reason = "because",
            .cause = cause,
        };
        const entry: records.IndexEntry = .{
            .id = id.slice(),
            .at_ms = decision.at_ms,
            .action = spec.action,
            .summary = "because",
        };
        var batch: Batch = .{};
        const index = records.index_key(spec.kind, spec.name, id.slice());
        const decision_at = records.decision_key(id.slice());
        const encoded = try records.encode(ctx.arena, entry, ctx.diag);
        batch.put(try controller.key_copy(&ctx, &index), encoded);
        batch.put(
            try controller.key_copy(&ctx, &decision_at),
            try records.encode(ctx.arena, decision, ctx.diag),
        );
        _ = try controller.commit(&ctx, .retention, &batch);
        return id;
    }

    /// A summary record, as `put_decision` would have left it.
    fn summarise(self: *Fixture, name: []const u8, action: []const u8) !void {
        const ctx = self.context();
        const key = records.summary_key(.service, name, action, .desired);
        const summary: records.Summary = .{
            .count = 3,
            .first_at_ms = 1,
            .last_at_ms = 2,
            .newest = "1761350000123-0001-0009",
        };
        var batch: Batch = .{};
        const encoded = try records.encode(ctx.arena, summary, ctx.diag);
        batch.put(try controller.key_copy(&ctx, &key), encoded);
        _ = try controller.commit(&ctx, .retention, &batch);
    }

    fn count(self: *Fixture, prefix: []const u8) !usize {
        const ctx = self.context();
        const page = try ctx.store.list(ctx.arena, .{ .prefix = prefix, .limit = 500 }, ctx.diag);
        return page.kvs.len;
    }

    fn present(self: *Fixture, id: *const records.DecisionId) !bool {
        const ctx = self.context();
        const key = records.decision_key(id.slice());
        return (try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag)).kv != null;
    }

    /// One whole pass over the index with the given live subjects.
    fn prune_once(self: *Fixture, snapshot: *const Snapshot) !void {
        var cursor: Cursor = .{};
        try self.prune_with(snapshot, &cursor);
    }

    fn prune_with(self: *Fixture, snapshot: *const Snapshot, cursor: *Cursor) !void {
        const ctx = self.context();
        _ = try prune(&ctx, cursor, snapshot, self.manual.ms);
    }
};

const ServiceEntry = controller.Entry(records.Service);
const ReplicaEntry = controller.Entry(records.Replica);

fn service_record(name: []const u8) records.Service {
    return .{ .name = name, .image = "i", .replicas = 1, .command = &.{"x"}, .generation = 1 };
}

fn replica_record(service: []const u8, id: []const u8) records.Replica {
    return .{ .id = id, .service = service, .generation = 1, .image = "i", .command = &.{"x"} };
}

const empty_snapshot: Snapshot = .{
    .revision = 0,
    .services = &.{},
    .replicas = &.{},
    .observed = &.{},
    .nodes = &.{},
};

test "decisions older than seven days go, with their index entries, and newer ones stay" {
    // Goal: the age rule. Method: one old and one fresh decision of one action for a service
    // that exists; the fresh one is the root, so a pass drops exactly the old pair.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const old = try fixture.decide(.{ .name = "hello", .age = constants.decision_age_ms_max + 1 });
    const fresh = try fixture.decide(.{ .name = "hello", .age = 1000 });
    const services = [_]ServiceEntry{.{ .kv = undefined, .rec = service_record("hello") }};
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    try fixture.prune_once(&snapshot);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_decisions));
    try testing.expect(!try fixture.present(&old));
    try testing.expect(try fixture.present(&fresh));
}

test "a subject keeps its newest two hundred and drops the older ones" {
    // Goal: the count rule at its boundary: 201 decisions leave 200, the oldest gone.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.decisions_per_subject_max + 1;
    for (0..total) |index| _ = try fixture.decide(.{ .name = "hello", .age = 100_000 - index });
    const services = [_]ServiceEntry{.{ .kv = undefined, .rec = service_record("hello") }};
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    try fixture.prune_once(&snapshot);
    try testing.expectEqual(@as(usize, 200), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 200), try fixture.count(records.prefix_decisions));
}

test "a deleted subject's decisions stay a day, then go, and its summaries with them" {
    // Goal: the 24-hour rule: with the service gone, entries survive while the newest is under a
    // day old and are all dropped, with the summaries, once it is over a day old.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    for (0..3) |index| {
        _ = try fixture.decide(.{
            .name = "gone",
            .age = constants.decision_gone_age_ms_max - 1000 + index,
        });
    }
    try fixture.summarise("gone", "apply");
    try fixture.summarise("gone", "delete_service");
    try fixture.summarise("other", "apply");
    try fixture.prune_once(&empty_snapshot);
    try testing.expectEqual(@as(usize, 3), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 3), try fixture.count(records.prefix_summaries));
    fixture.manual.advance(2000);
    try fixture.prune_once(&empty_snapshot);
    try testing.expectEqual(@as(usize, 0), try fixture.count(records.prefix_index));
    try testing.expectEqual(@as(usize, 0), try fixture.count(records.prefix_decisions));
    // The summary of another subject is not this subject's to lose.
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_summaries));
}

test "a crash loop never evicts the service's apply or a live replica's chain" {
    // Goal: reachability. Method: a service with an apply, two scale-ups and then more
    // replace_replica decisions than the budget holds; a live replica whose creation cites the
    // older scale-up. Evicted: the surplus replace_replica decisions. Kept: the apply and the
    // newest scale-up (roots), the older scale-up (on the replica's chain), the replica's
    // decisions (roots), and the newest replace_replica.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const apply = try fixture.decide(.{ .name = "hello", .age = 900_000 });
    const scale_old = try fixture.decide(.{
        .name = "hello",
        .age = 800_000,
        .action = "scale_up",
    });
    const scale_new = try fixture.decide(.{
        .name = "hello",
        .age = 700_000,
        .action = "scale_up",
    });
    const create = try fixture.decide(.{
        .kind = .replica,
        .name = "hello-1",
        .age = 790_000,
        .action = "create_replica",
        .because = scale_old.slice(),
    });
    const place = try fixture.decide(.{
        .kind = .replica,
        .name = "hello-1",
        .age = 780_000,
        .action = "place_replica",
        .because = create.slice(),
    });
    const loops = constants.decisions_per_subject_max + 50;
    var first_loop: ?records.DecisionId = null;
    var last_loop: records.DecisionId = undefined;
    for (0..loops) |index| {
        last_loop = try fixture.decide(.{
            .name = "hello",
            .age = 600_000 - 1000 * index,
            .action = "replace_replica",
        });
        if (first_loop == null) first_loop = last_loop;
    }
    const services = [_]ServiceEntry{.{ .kv = undefined, .rec = service_record("hello") }};
    const replicas = [_]ReplicaEntry{
        .{ .kv = undefined, .rec = replica_record("hello", "hello-1") },
    };
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    snapshot.replicas = &replicas;
    try fixture.prune_once(&snapshot);

    for ([_]*const records.DecisionId{ &apply, &scale_old, &scale_new, &create, &place }) |id| {
        try testing.expect(try fixture.present(id));
    }
    try testing.expect(try fixture.present(&last_loop));
    try testing.expect(!try fixture.present(&first_loop.?));
    // 3 unpinned-by-budget survivors on top of the 200 newest: apply, scale_old, scale_new.
    const kept = constants.decisions_per_subject_max;
    try testing.expectEqual(kept + 3 + 2, try fixture.count(records.prefix_decisions));
}

test "a pass that cannot pin everything drops nothing from live subjects" {
    // Goal: the fail-safe. Method: the same history with a pin bound too small for the roots;
    // nothing is dropped; with the real bound the surplus goes.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.decisions_per_subject_max + 10;
    for (0..total) |index| {
        _ = try fixture.decide(.{
            .name = "hello",
            .age = 600_000 - 1000 * index,
            .action = if (index % 2 == 0) "scale_up" else "scale_down",
        });
    }
    const services = [_]ServiceEntry{.{ .kv = undefined, .rec = service_record("hello") }};
    var snapshot = empty_snapshot;
    snapshot.services = &services;
    var cursor: Cursor = .{ .pins_max = 1 };
    try fixture.prune_with(&snapshot, &cursor);
    try testing.expectEqual(@as(usize, total), try fixture.count(records.prefix_index));
    fixture.diag.reset();
    try fixture.prune_once(&snapshot);
    try testing.expectEqual(@as(usize, 200), try fixture.count(records.prefix_index));
}
