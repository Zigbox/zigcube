//! Retention of pull records (`/pulls/<node>/<tree>`, docs/keys.md, C2 slice 7): a node keeps
//! its newest `pulls_per_node_max` records and none older than `pull_age_ms_max`.
//!
//! A pass reads at most `pulls_pages_per_pass_max` pages of the prefix, which ascends by node
//! and then tree, starting after the key the last pass stopped at (`Cursor.after`), and wraps to
//! the start only when a read reaches the end. So every node is reached however many records
//! the others hold, and one node with more records than a pass reads is pruned a pass at a time.
//! A node's run that a pass sees only part of is pruned as the part: both rules are safe on a
//! part, because a record beyond the newest `pulls_per_node_max` of a part has at least that many
//! newer in the whole, and age does not depend on the others. What a part keeps, the next part
//! may thin again, so a node of any size converges to its limit in a few wraps. A delete
//! compares the record's `mod_revision`, so a pull that rewrote the key after the read is never
//! dropped. Fail safe: a record that does not parse is kept (and never counted as old), because
//! dropping on a guess would lose statistics, while keeping one costs a row.
//!
//! The role is `retention`, which may only delete under `/pulls/` (`writers.zig`). Core code.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const failures = @import("store_failures.zig");
const store = @import("store.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Error = controller.Error;

/// Where a pass stopped and when the next is due, on the `Clock`'s scale; 0 is now.
pub const Cursor = struct {
    due_ms: u64 = 0,
    /// Resume after this key. Meaningful only if `resuming`.
    after: records.Key = .{},
    /// True while a read has not yet reached the end of the prefix.
    resuming: bool = false,
    /// Pull records dropped (counted when the delete is attempted), for tests and the shell.
    dropped: u64 = 0,
    /// Whether the last pass failed, how many have, and the last failure whole: statistics
    /// must not stop replica work, so a failure is kept here for the shell to say once.
    failing: bool = false,
    failures: u64 = 0,
    /// The last failure's diagnostic, cause and fix; meaningful only while `failing`.
    failure: diag_mod.Diag = undefined,
};

/// `prune` for the replica controller: a failed pass is recorded in `cursor` and retried after
/// `pulls_retry_ms`, and its diagnostic is moved into the cursor and cleared from `ctx`, so
/// nothing else in the step is held back. Every error path of `prune` sets a diagnostic code (the
/// assertion relies on it): the store's and the records' errors are coded where they arise. A
/// `VerifiedStore` halt (ZC-E0215) comes out of here as an ordinary failure too, and the next
/// step's `status` call reports it, so this function never has to.
pub fn prune_or_back_off(ctx: *const Context, cursor: *Cursor, now_ms: u64) u64 {
    assert(ctx.diag.code == null);
    if (prune(ctx, cursor, now_ms)) |due| {
        cursor.failing = false;
        return due;
    } else |_| {
        assert(ctx.diag.code != null); // Every failure of the store or a record is coded.
        cursor.failing = true;
        cursor.failures += 1;
        cursor.failure = ctx.diag.*;
        ctx.diag.reset();
        return now_ms + constants.pulls_retry_ms;
    }
}

/// One pass; returns when the next is due: now if the prefix was not finished, else a full
/// interval on. `now_ms` is the controller's clock.
pub fn prune(ctx: *const Context, cursor: *Cursor, now_ms: u64) Error!u64 {
    assert(constants.pulls_per_node_max > 0);
    assert(cursor.resuming == (cursor.after.len > 0));
    const revision = (try ctx.store.status(ctx.diag)).revision;
    var seen: std.ArrayList(store.KeyValue) = .empty;
    var after: ?[]const u8 = if (cursor.resuming) cursor.after.slice() else null;
    var complete = false;
    for (0..constants.pulls_pages_per_pass_max) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_pulls,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        seen.appendSlice(ctx.arena, page.kvs) catch return failures.no_memory(ctx.diag);
        after = page.continue_after;
        if (after == null) {
            complete = true;
            break;
        }
    }
    // The cursor moves only once the deletes are in: a failed pass reads the same pages again.
    try prune_nodes(ctx, cursor, seen.items, now_ms);
    if (complete) {
        cursor.resuming = false;
        cursor.after.len = 0;
        return now_ms + constants.pulls_interval_ms;
    }
    const last = after.?;
    assert(last.len <= constants.store_key_bytes_max);
    @memcpy(cursor.after.bytes[0..last.len], last);
    cursor.after.len = @intCast(last.len);
    cursor.resuming = true;
    return now_ms;
}

/// Drops from each node's run in `kvs` (ascending by key); a run may be only part of its node.
fn prune_nodes(
    ctx: *const Context,
    cursor: *Cursor,
    kvs: []const store.KeyValue,
    now_ms: u64,
) Error!void {
    var start: usize = 0;
    while (start < kvs.len) {
        const node = node_of(kvs[start].key);
        var end = start + 1;
        while (end < kvs.len and std.mem.eql(u8, node_of(kvs[end].key), node)) end += 1;
        try prune_node(ctx, cursor, kvs[start..end], now_ms);
        start = end;
    }
}

/// The node name of `/pulls/<node>/<tree>`; the whole rest if it has no second slash.
fn node_of(key: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, key, records.prefix_pulls));
    const rest = key[records.prefix_pulls.len..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

const Finished = struct { finished_at_ms: u64 = 0 };

/// The time a record says its pull finished; null for a value that does not parse.
fn finished_of(ctx: *const Context, value: []const u8) ?u64 {
    const parsed = std.json.parseFromSliceLeaky(Finished, ctx.arena, value, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.finished_at_ms;
}

fn prune_node(
    ctx: *const Context,
    cursor: *Cursor,
    run: []const store.KeyValue,
    now_ms: u64,
) Error!void {
    assert(run.len > 0);
    const times = ctx.arena.alloc(?u64, run.len) catch return failures.no_memory(ctx.diag);
    for (run, times) |kv, *time| time.* = finished_of(ctx, kv.value);
    const drop = ctx.arena.alloc(bool, run.len) catch return failures.no_memory(ctx.diag);
    const order = ctx.arena.alloc(u32, run.len) catch return failures.no_memory(ctx.diag);
    mark_drops(times, now_ms, order, drop);
    var batch: Batch = .{};
    for (run, drop) |kv, marked| {
        if (!marked) continue;
        if (!batch.has_room(1) or batch.compares_count == constants.store_txn_compares_max) {
            try flush(ctx, cursor, &batch);
        }
        batch.expect(kv.key, kv.mod_revision);
        batch.delete(kv.key);
    }
    try flush(ctx, cursor, &batch);
}

/// Commits the batch; only deletes that went in count as dropped.
fn flush(ctx: *const Context, cursor: *Cursor, batch: *Batch) Error!void {
    if (batch.ops_count == 0) return;
    // A conflict means a pull rewrote a key since the read: the next pass sees the new record.
    const done = try controller.commit(ctx, .retention, batch);
    if (done == .applied) cursor.dropped += batch.ops_count;
    batch.* = .{};
}

/// Sets `drop[i]` for a record older than `pull_age_ms_max` and for every record beyond the
/// newest `pulls_per_node_max` of its node. A record with no time (`null`) is never dropped and
/// does not count toward the newest. `order` is scratch the size of `times`.
fn mark_drops(times: []const ?u64, now_ms: u64, order: []u32, drop: []bool) void {
    assert(times.len == drop.len);
    assert(order.len == times.len);
    @memset(drop, false);
    var timed: u32 = 0;
    for (times, 0..) |time, at| {
        const finished = time orelse continue;
        if (now_ms > finished and now_ms - finished > constants.pull_age_ms_max) {
            drop[at] = true;
            continue;
        }
        order[timed] = @intCast(at);
        timed += 1;
    }
    // The keys are trees, not times, so the count rule ranks by `finished`, newest first.
    const Rank = struct {
        times: []const ?u64,
        fn newer(rank: @This(), first: u32, second: u32) bool {
            const first_ms = rank.times[first].?;
            const second_ms = rank.times[second].?;
            if (first_ms != second_ms) return first_ms > second_ms;
            return first < second;
        }
    };
    std.mem.sort(u32, order[0..timed], Rank{ .times = times }, Rank.newer);
    if (timed <= constants.pulls_per_node_max) return;
    for (order[constants.pulls_per_node_max..timed]) |at| drop[at] = true;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

test "mark_drops keeps the newest and drops the old, and spares what has no time" {
    // Goal: the rules of the module header at their boundary. Method: ages straddle the limit
    // by one millisecond; with a lowered count (via a long run) the oldest beyond it go.
    const now: u64 = 100 * constants.pull_age_ms_max;
    const times = [_]?u64{
        now - constants.pull_age_ms_max, // exactly at the limit: kept
        now - constants.pull_age_ms_max - 1, // one past: dropped
        null, // unreadable: kept
        now - 5,
    };
    var order: [times.len]u32 = undefined;
    var drop: [times.len]bool = @splat(true); // A known byte: every entry must be written.
    mark_drops(&times, now, &order, &drop);
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, &drop);
}

test "mark_drops drops the oldest beyond the newest pulls_per_node_max" {
    // Goal: the count rule. Method: one more than the limit, distinct times, newest last in key
    // order: exactly the oldest one goes.
    const now: u64 = 100 * constants.pull_age_ms_max;
    var times: [constants.pulls_per_node_max + 1]?u64 = undefined;
    for (&times, 0..) |*time, at| time.* = now - 1000 + at;
    var order: [times.len]u32 = undefined;
    var drop: [times.len]bool = @splat(true);
    mark_drops(&times, now, &order, &drop);
    try testing.expect(drop[0]);
    for (drop[1..]) |dropped| try testing.expect(!dropped);
}

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 100 * constants.pull_age_ms_max };
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

    /// A pull record of `node` for `tree` that finished `age_ms` ago, written as the agent would.
    fn pull(self: *Fixture, node: []const u8, tree: []const u8, age_ms: u64) !void {
        const ctx = self.context();
        const record: records.Pull = .{
            .node = node,
            .tree = tree,
            .started_at_ms = self.manual.ms - age_ms - 5,
            .finished_at_ms = self.manual.ms - age_ms,
        };
        const key = records.pull_key(node, tree);
        var batch: Batch = .{};
        const bytes = try records.encode(ctx.arena, record, ctx.diag);
        batch.put(try controller.key_copy(&ctx, &key), bytes);
        const request: store.TxnRequest = .{ .on_success = batch.ops[0..1] };
        const done = try ctx.store.txn(request, ctx.diag);
        try testing.expect(done.succeeded);
    }

    /// How many keys lie under `prefix`, read a page at a time.
    fn count(self: *Fixture, prefix: []const u8) !usize {
        const ctx = self.context();
        var total: usize = 0;
        var after: ?[]const u8 = null;
        const revision = (try ctx.store.status(ctx.diag)).revision;
        while (true) {
            const options: store.ListOptions = .{
                .prefix = prefix,
                .at_revision = revision,
                .limit = constants.store_list_limit_max,
                .continue_after = after,
            };
            const page = try ctx.store.list(ctx.arena, options, ctx.diag);
            total += page.kvs.len;
            after = page.continue_after orelse return total;
        }
    }

    /// Writes `total` pulls for `node`, trees `b3:<hex>`, a higher index finishing later.
    fn pull_many(self: *Fixture, node: []const u8, total: u32) !void {
        for (0..total) |at| {
            var tree: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at});
            try self.pull(node, name, 100_000 - at);
        }
    }
};

test "a pass drops old pulls of every node and leaves fresh ones" {
    // Goal: the age rule through the store, per node, with the retention role's delete accepted
    // by `writers`. Method: two nodes, one old and one fresh pull each.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.pull("n1", "b3:aaaa0000", constants.pull_age_ms_max + 1);
    try fixture.pull("n1", "b3:bbbb0000", 1000);
    try fixture.pull("n2", "b3:aaaa0000", constants.pull_age_ms_max + 1);
    try fixture.pull("n2", "b3:bbbb0000", 1000);
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    const due = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(fixture.manual.ms + constants.pulls_interval_ms, due);
    try testing.expectEqual(@as(u64, 2), cursor.dropped);
    try testing.expectEqual(@as(usize, 2), try fixture.count(records.prefix_pulls));
    try testing.expectEqual(@as(usize, 1), try fixture.count("/pulls/n1/"));
    try testing.expectEqual(@as(usize, 1), try fixture.count("/pulls/n2/"));
}

test "a node past its count keeps its newest and another node is untouched" {
    // Goal: the count rule through the store, and that it is per node. Method: n1 has the limit
    // plus three pulls, n2 has one; the three oldest of n1 go.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.pulls_per_node_max + 3;
    for (0..total) |at| {
        var tree: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at});
        try fixture.pull("n1", name, 10_000 - at); // A higher index is older.
    }
    try fixture.pull("n2", "b3:ffff0000", 5);
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    _ = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(@as(u64, 3), cursor.dropped);
    const kept = try fixture.count("/pulls/n1/");
    try testing.expectEqual(@as(usize, constants.pulls_per_node_max), kept);
    try testing.expectEqual(@as(usize, 1), try fixture.count("/pulls/n2/"));
    const oldest = records.pull_key("n1", "b3:00000067"); // Index 103: the oldest.
    const got = try ctx.store.get(ctx.arena, oldest.slice(), null, ctx.diag);
    try testing.expect(got.kv == null);
}

test "a pass resumes where the last stopped, so a node past the first 2,000 records is pruned" {
    // Goal: no node is starved by the ones before it. A pass that restarted at the first key (the
    // old one) read the same first 2,000 records every time and never reached a later node.
    // Method: twenty nodes a01..a20 at 100 records each, exactly a pass's 2,000 and nothing to
    // drop, then node z21 with 500; passes run until the cursor wraps (two); z21 is then at its
    // limit, the others are untouched and the cursor is back at the start.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    comptime assert(constants.pulls_per_node_max == 100);
    const pass_records = constants.store_list_limit_max * constants.pulls_pages_per_pass_max;
    comptime assert(20 * 100 == pass_records);
    for (1..21) |at| {
        var node: [3]u8 = undefined;
        try fixture.pull_many(try std.fmt.bufPrint(&node, "a{d:0>2}", .{at}), 100);
    }
    try fixture.pull_many("z21", 500);
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    var passes: u32 = 0;
    while (true) {
        const due = try prune(&ctx, &cursor, fixture.manual.ms);
        passes += 1;
        if (!cursor.resuming) {
            try testing.expectEqual(fixture.manual.ms + constants.pulls_interval_ms, due);
            break;
        }
        try testing.expectEqual(fixture.manual.ms, due); // Not finished: due now.
        try testing.expect(passes < 3);
    }
    try testing.expectEqual(@as(u32, 2), passes);
    try testing.expectEqual(@as(usize, 0), cursor.after.len);
    const limit: usize = constants.pulls_per_node_max;
    try testing.expectEqual(limit, try fixture.count("/pulls/z21/"));
    try testing.expectEqual(limit, try fixture.count("/pulls/a01/"));
    try testing.expectEqual(limit, try fixture.count("/pulls/a20/"));
    try testing.expectEqual(@as(u64, 500 - limit), cursor.dropped);
}

test "one node with more records than a pass reads converges to its limit" {
    // Goal: a single large node does not stall retention. Method: 2,300 pulls of one node, the
    // pass reads 2,000; each pass drops what is safe on the part it saw; within four passes the
    // node is at its limit, and the newest records are the ones kept.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.store_list_limit_max * constants.pulls_pages_per_pass_max + 300;
    try fixture.pull_many("n1", total);
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    var passes: u32 = 0;
    while (try fixture.count("/pulls/n1/") > constants.pulls_per_node_max) {
        _ = try prune(&ctx, &cursor, fixture.manual.ms);
        passes += 1;
        try testing.expect(passes <= 4);
    }
    const kept = try fixture.count("/pulls/n1/");
    try testing.expectEqual(@as(usize, constants.pulls_per_node_max), kept);
    // A higher index finished later, so the newest hundred are the last hundred written.
    const newest = records.pull_key("n1", "b3:000008fb"); // Index 2299.
    const got = try ctx.store.get(ctx.arena, newest.slice(), null, ctx.diag);
    try testing.expect(got.kv != null);
    const oldest = records.pull_key("n1", "b3:00000000");
    const gone = try ctx.store.get(ctx.arena, oldest.slice(), null, ctx.diag);
    try testing.expect(gone.kv == null);
}
