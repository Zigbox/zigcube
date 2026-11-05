//! Invariants both simulations check over the store (C1 slice 4g): the summaries count exactly,
//! a lost node's replicas wait out the grace, the allocation auditor stays quiet, and I7. Each
//! check returns what it found wrong, or null; the simulation reports it as a failed step.
//! Core: reads the store through a `controller.Context` and nothing else.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;

/// What a check found wrong; null when it holds.
pub const Found = ?[]const u8;

/// Decisions counted by the key of the summary that counts them.
pub const Counts = std.StringHashMapUnmanaged(u64);

const out_of_memory = "the checks ran out of memory";
const summaries_listed_max: u32 = constants.store_list_limit_max * 64;

pub fn count(ctx: *const Context, counts: *Counts, decision: *const records.Decision) Found {
    const subject = decision.subject;
    const key = records.summary_key(
        subject.kind,
        subject.name,
        decision.action,
        decision.cause.kind,
    );
    const owned = ctx.arena.dupe(u8, key.slice()) catch return out_of_memory;
    const slot = counts.getOrPut(ctx.arena, owned) catch return out_of_memory;
    if (!slot.found_existing) slot.value_ptr.* = 0;
    slot.value_ptr.* += 1;
    return null;
}

/// Every summary at `at` counts exactly the decisions `counts` holds for it (all of them, read at
/// `at`), and every counted decision has its summary. The caller skips it once retention has
/// dropped a decision: a summary keeps counting what was dropped.
pub fn summaries(ctx: *const Context, counts: *const Counts, at: store.Revision) Found {
    const listed = controller.list_all(
        records.Summary,
        ctx,
        records.prefix_summaries,
        at,
        summaries_listed_max,
    ) catch {
        ctx.diag.reset();
        return "the summaries cannot be listed";
    };
    for (listed.items) |entry| {
        const counted = counts.get(entry.kv.key) orelse 0;
        if (entry.rec.count != counted) return "a summary's count is not its decisions'";
    }
    if (listed.items.len != counts.count()) return "a decision is counted by no summary";
    return null;
}

/// A `mark_replica_lost` caused by a decision: that decision is its node's `mark_lost`, and the
/// replica was replaced no earlier than `grace_ms` after it. `cause` is the cause's record, when
/// it is still in the store.
pub fn lost_grace(
    ctx: *const Context,
    decision: *const records.Decision,
    cause: ?store.KeyValue,
    grace_ms: u64,
) Found {
    assert(decision.cause.kind == .decision);
    if (!std.mem.eql(u8, decision.action, "mark_replica_lost")) return null;
    const kv = cause orelse return null;
    const lost = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return "a decision cannot be read";
    };
    if (!std.mem.eql(u8, lost.action, "mark_lost")) {
        return "a lost replica's cause is not its node's mark_lost";
    }
    if (decision.at_ms < lost.at_ms +| grace_ms) {
        return "a lost node's replica was replaced within the grace";
    }
    return null;
}

/// No simulation corrupts an allocation record, so the allocation auditor has no finding open.
pub fn no_findings(ctx: *const Context) Found {
    const page = ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_audit_allocations,
        .limit = 1,
    }, ctx.diag) catch {
        ctx.diag.reset();
        return "the auditor's findings cannot be listed";
    };
    if (page.kvs.len > 0) return "the allocation auditor opened a finding on a healthy run";
    return null;
}

/// I7 (docs/authority.md): at the revision each assignment was written, its node's status was
/// `ready` for the node's tenure then. Only assignments written after `checked` are read, each at
/// its own revision; one whose revision was compacted away is passed over.
pub fn placements(ctx: *const Context, checked: store.Revision, head: store.Revision) Found {
    assert(checked <= head);
    const assigned = controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        head,
        summaries_listed_max,
    ) catch {
        ctx.diag.reset();
        return "the assignments cannot be listed";
    };
    for (assigned.items) |entry| {
        if (entry.kv.mod_revision <= checked) continue;
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
            return "an assignment key names no node";
        if (ready_at(ctx, rest[0..slash], entry.kv.mod_revision)) |found| return found;
    }
    return null;
}

fn ready_at(ctx: *const Context, node: []const u8, at: store.Revision) Found {
    const node_at = records.node_key(node);
    const status_at = records.node_status_key(node);
    const registered = ctx.store.get(ctx.arena, node_at.slice(), at, ctx.diag) catch |err| {
        ctx.diag.reset();
        return if (err == error.Compacted) null else "a node cannot be read at a placement";
    };
    const status = ctx.store.get(ctx.arena, status_at.slice(), at, ctx.diag) catch |err| {
        ctx.diag.reset();
        return if (err == error.Compacted) null else "a node status cannot be read at a placement";
    };
    const node_kv = registered.kv orelse return "I7: a placement onto a node not registered";
    const status_kv = status.kv orelse return "I7: a placement onto a node with no status";
    const judged = records.read(records.NodeStatus, ctx.arena, status_kv, ctx.diag) catch {
        ctx.diag.reset();
        return "a node status cannot be read";
    };
    if (judged.state != .ready) return "I7: a placement onto a node that is not ready";
    if (judged.tenure != node_kv.mod_revision) {
        return "I7: a placement onto a node whose status judged another tenure";
    }
    return null;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const diag_mod = @import("diag.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

/// A memory store with a manual clock, written raw (no writer roles: these tests hand the
/// checks a store that is wrong on purpose, which no role could write).
const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: diag_mod.Diag,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
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

    /// Puts `value` at `key`; returns the revision of the write.
    fn put(self: *Fixture, key: []const u8, value: anytype) !store.Revision {
        const ctx = self.context();
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try ctx.store.txn(.{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
        return done.revision;
    }

    fn head(self: *Fixture) !store.Revision {
        return (try self.context().store.status(&self.diag)).revision;
    }
};

fn sample_decision(action: []const u8, at_ms: u64, cause: records.Cause) records.Decision {
    return .{
        .id = "1761350000000-0001-0001",
        .at_ms = at_ms,
        .actor = "test",
        .action = action,
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "a test decision",
        .cause = cause,
    };
}

test "summaries finds a count that is not the decisions' and a decision no summary counts" {
    // Goal: the exact-count check (4e) has teeth. Method: a store whose summary counts 2 for one
    // decision is Found; the right count passes; a counted decision with no summary is Found.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const ctx = fixture.context();
    const decision = sample_decision("create_replica", 1, .{ .kind = .desired });
    var counts: Counts = .empty;
    try testing.expectEqual(@as(Found, null), count(&ctx, &counts, &decision));
    const key = records.summary_key(.replica, "hello-1", "create_replica", .desired);
    const wrong: records.Summary = .{
        .count = 2,
        .first_at_ms = 1,
        .last_at_ms = 1,
        .newest = "x",
    };
    const at = try fixture.put(key.slice(), wrong);
    try testing.expect(summaries(&ctx, &counts, at) != null);

    const right: records.Summary = .{
        .count = 1,
        .first_at_ms = 1,
        .last_at_ms = 1,
        .newest = "x",
    };
    const fixed = try fixture.put(key.slice(), right);
    try testing.expectEqual(@as(Found, null), summaries(&ctx, &counts, fixed));

    _ = count(&ctx, &counts, &sample_decision("other", 2, .{ .kind = .resync }));
    try testing.expect(summaries(&ctx, &counts, fixed) != null);
}

test "lost_grace finds a replacement inside the grace and a cause that is not a mark_lost" {
    // Goal: no replica of a lost node is replaced before `lost_grace_ms`. Method: a
    // `mark_replica_lost` 1 ms early is Found; at exactly the grace it passes; a cause that is
    // not a `mark_lost` is Found; other actions are not judged.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const ctx = fixture.context();
    const grace: u64 = 1000;
    const cause: records.Cause = .{ .kind = .decision, .id = "mark-lost-1" };
    const lost = sample_decision("mark_lost", 5000, .{ .kind = .lease_expired });
    const bytes = try records.encode(ctx.arena, lost, ctx.diag);
    const kv: store.KeyValue = .{
        .key = "/decisions/mark-lost-1",
        .value = bytes,
        .create_revision = 1,
        .mod_revision = 1,
    };
    const early = sample_decision("mark_replica_lost", 5000 + grace - 1, cause);
    try testing.expect(lost_grace(&ctx, &early, kv, grace) != null);
    const on_time = sample_decision("mark_replica_lost", 5000 + grace, cause);
    try testing.expectEqual(@as(Found, null), lost_grace(&ctx, &on_time, kv, grace));
    const other = sample_decision("delete_replica", 5000, cause);
    try testing.expectEqual(@as(Found, null), lost_grace(&ctx, &other, kv, grace));
    const not_lost = try records.encode(ctx.arena, early, ctx.diag);
    const wrong_kv: store.KeyValue = .{
        .key = kv.key,
        .value = not_lost,
        .create_revision = 1,
        .mod_revision = 1,
    };
    try testing.expect(lost_grace(&ctx, &on_time, wrong_kv, grace) != null);
}

test "no_findings finds an open allocation finding" {
    // Goal: the quiet-auditor check fails on a healthy run's first finding. Method: empty
    // `/audit/allocations/` passes; one record there is Found.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const ctx = fixture.context();
    try testing.expectEqual(@as(Found, null), no_findings(&ctx));
    const key = records.audit_key("node1");
    _ = try fixture.put(key.slice(), .{ .v = 1 });
    try testing.expect(no_findings(&ctx) != null);
}

test "placements finds an assignment onto an unregistered, unready or other-tenure node" {
    // Goal: I7 has teeth. Method: an assignment onto a node with no record, then a registered
    // node with no status, a `lost` status, a `ready` status of another tenure are each Found;
    // a `ready` status for the node's tenure passes; assignments at or below `checked` are not
    // read.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const ctx = fixture.context();
    const assigned = records.assigned_replica(
        "hello-1",
        "hello",
        .{ .cpu_millis = 1, .memory_bytes = 1 },
        "a test",
    );
    const slot = "/assigned/node1/hello-1";
    const first = try fixture.put(slot, assigned);
    try testing.expect(placements(&ctx, 0, first) != null);
    try testing.expectEqual(@as(Found, null), placements(&ctx, first, first));

    const node: records.Node = .{
        .name = "node1",
        .capacity = .{ .cpu_millis = 4000, .memory_bytes = 1 << 30 },
    };
    const tenure = try fixture.put(records.node_key("node1").slice(), node);
    const placed = try fixture.put(slot, assigned);
    try testing.expect(placements(&ctx, first, placed) != null);

    const status_key = records.node_status_key("node1");
    var status: records.NodeStatus = .{
        .state = .lost,
        .tenure = tenure,
        .at_ms = 1,
        .decision = "d",
    };
    _ = try fixture.put(status_key.slice(), status);
    const on_lost = try fixture.put(slot, assigned);
    try testing.expect(placements(&ctx, placed, on_lost) != null);

    status.state = .ready;
    status.tenure = tenure + 1;
    _ = try fixture.put(status_key.slice(), status);
    const on_other = try fixture.put(slot, assigned);
    try testing.expect(placements(&ctx, on_lost, on_other) != null);

    status.tenure = tenure;
    _ = try fixture.put(status_key.slice(), status);
    const good = try fixture.put(slot, assigned);
    try testing.expectEqual(@as(Found, null), placements(&ctx, on_other, good));
}
