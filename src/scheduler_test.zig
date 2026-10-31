//! Tests of the scheduler on the memory store and a manual clock. The tests write `/nodes/`,
//! `/node-status/` and `/replicas/` records themselves, as the roles that own them, so each one
//! pins the scheduler's behaviour and nothing of the controllers' or the agent's. After every
//! pass the accounting is reconstructed and compared with the records (I6).

const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const scheduler = @import("scheduler.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const gib: u64 = 1024 * 1024 * 1024;

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    /// Holds what a test reads back, freed when the test ends.
    keep: std.heap.ArenaAllocator,
    diag: Diag,
    sc: scheduler.Scheduler,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.keep = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.sc = scheduler.Scheduler.init(3);
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.keep.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) controller.Context {
        _ = self.arena_state.reset(.retain_capacity);
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    fn put(self: *Fixture, role: writers.Role, key: []const u8, value: anytype) !void {
        const ctx = self.context();
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
    }

    fn revision_of(self: *Fixture, key: []const u8) !store.Revision {
        const ctx = self.context();
        const got = try ctx.store.get(ctx.arena, key, null, &self.diag);
        return if (got.kv) |kv| kv.mod_revision else 0;
    }

    /// Registers a node and, if `ready`, marks it ready for that tenure.
    fn node(self: *Fixture, name: []const u8, cpu: u32, memory: u64, ready: bool) !void {
        const value: records.Node = .{
            .name = name,
            .capacity = .{ .cpu_millis = cpu, .memory_bytes = memory },
        };
        try self.put(.{ .agent = name }, records.node_key(name).slice(), value);
        if (ready) try self.status(name, .ready, 0);
    }

    /// Writes the node's status for its current tenure, plus `skew` (a status of another tenure).
    fn status(self: *Fixture, name: []const u8, state: records.NodeState, skew: u64) !void {
        const tenure = try self.revision_of(records.node_key(name).slice());
        const value: records.NodeStatus = .{
            .state = state,
            .tenure = tenure -% skew,
            .at_ms = self.manual.ms,
            .decision = "x",
        };
        try self.put(.node_controller, records.node_status_key(name).slice(), value);
    }

    fn replica(
        self: *Fixture,
        service: []const u8,
        id: []const u8,
        cpu: ?u32,
        memory: ?u64,
    ) !void {
        const value: records.Replica = .{
            .id = id,
            .service = service,
            .generation = 1,
            .node = "",
            .image = "b3:51aa9c03",
            .command = &.{"true"},
            .limits = .{ .cpu_millis = cpu, .memory_bytes = memory },
        };
        try self.put(.replica_controller, records.replica_key(service, id).slice(), value);
    }

    /// One pass, then the I6 check.
    fn step(self: *Fixture) !controller.Wakeup {
        const ctx = self.context();
        const wake = try self.sc.reconcile(&ctx);
        try self.accounting_holds();
        return wake;
    }

    /// One pass without the I6 check, for a test that writes an allocation record by hand.
    fn sc_step_unchecked(self: *Fixture) !controller.Wakeup {
        const ctx = self.context();
        return self.sc.reconcile(&ctx);
    }

    /// Passes until one writes nothing.
    fn settle(self: *Fixture) !void {
        for (0..32) |_| {
            if ((try self.step()).acted == 0) return;
        }
        return error.DidNotSettle;
    }

    fn accounting_holds(self: *Fixture) !void {
        const ctx = self.context();
        const found = try scheduler.find_mismatch(&ctx);
        if (found) |mismatch| {
            std.debug.print("I6 broken on {s}\n", .{mismatch.node});
            return error.AccountingBroken;
        }
    }

    fn assigned_to(self: *Fixture, id: []const u8) !?[]const u8 {
        const ctx = self.context();
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_assigned,
            .limit = constants.store_list_limit_max,
        }, &self.diag);
        for (page.kvs) |kv| {
            if (!std.mem.endsWith(u8, kv.key, id)) continue;
            const rest = kv.key[records.prefix_assigned.len..];
            const name = rest[0..std.mem.indexOfScalar(u8, rest, '/').?];
            return try testing.allocator.dupe(u8, name);
        }
        return null;
    }

    fn expect_on(self: *Fixture, id: []const u8, want: ?[]const u8) !void {
        const got = try self.assigned_to(id);
        defer if (got) |name| testing.allocator.free(name);
        if (want) |name| {
            try testing.expect(got != null);
            try testing.expectEqualStrings(name, got.?);
        } else try testing.expect(got == null);
    }

    fn allocation(self: *Fixture, name: []const u8) !records.Allocation {
        const ctx = self.context();
        const key = records.allocation_key(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return try records.read(records.Allocation, self.keep.allocator(), got.kv.?, &self.diag);
    }

    /// The decisions of one action, oldest first; the strings are the test allocator's.
    fn decisions(self: *Fixture, action: []const u8) ![]records.Decision {
        const ctx = self.context();
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_decisions,
            .limit = constants.store_list_limit_max,
        }, &self.diag);
        var found: std.ArrayList(records.Decision) = .empty;
        for (page.kvs) |kv| {
            const keep = self.keep.allocator();
            const decision = try records.read(records.Decision, keep, kv, &self.diag);
            if (std.mem.eql(u8, decision.action, action)) {
                try found.append(testing.allocator, decision);
            }
        }
        return found.toOwnedSlice(testing.allocator);
    }

    fn count(self: *Fixture, action: []const u8) !usize {
        const found = try self.decisions(action);
        defer testing.allocator.free(found);
        return found.len;
    }
};

test "a replica is placed on the only node, with its decision and its allocation" {
    // Goal: the basic placement. Method: one node, one replica with limits; the assignment,
    // the allocation record and the `place_replica` decision all exist after one pass.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.replica("hello", "hello-1", 500, gib);
    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    try fixture.expect_on("hello-1", "n1");
    const allocation = try fixture.allocation("n1");
    try testing.expectEqual(@as(u32, 500), allocation.allocated.cpu_millis);
    try testing.expectEqual(gib, allocation.allocated.memory_bytes);
    try testing.expectEqual(@as(u32, 1), allocation.count);
    try testing.expectEqual(@as(usize, 1), try fixture.count("place_replica"));
    const again = try fixture.step();
    try testing.expectEqual(@as(u32, 0), again.acted);
    try testing.expect(again.at_ms > fixture.manual.ms);
}

test "fit is checked on CPU and on memory, each failing alone" {
    // Goal: either resource alone keeps a replica off a node, and the hold names which.
    // Method: n1 has little CPU and a lot of memory, n2 the reverse; a replica too big for
    // each on one resource only is held, and the evidence shows that resource for that node.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 1000, 8 * gib, true);
    try fixture.node("n2", 8000, gib, true);
    try fixture.replica("big", "big-1", 2000, 2 * gib);
    try fixture.settle();
    try fixture.expect_on("big-1", null);
    const holds = try fixture.decisions("hold_pending");
    defer testing.allocator.free(holds);
    try testing.expectEqual(@as(usize, 1), holds.len);
    const evidence = holds[0].cause_evidence.?.text;
    try testing.expect(std.mem.indexOf(u8, evidence, "\"cpu_short\":{\"n1\":1000}") != null);
    const memory_short = "\"memory_short\":{\"n2\":1073741824}";
    try testing.expect(std.mem.indexOf(u8, evidence, memory_short) != null);
    // A replica that fits one of them is placed there.
    try fixture.replica("small", "small-1", 1000, gib);
    try fixture.settle();
    try fixture.expect_on("small-1", "n1");
}

test "the spread order: fewest of the service, then least allocated, then name" {
    // Goal: the three tie-breaks, in order. Method: each case sets the nodes up so that only
    // the tie-break under test separates them.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("a", 4000, 8 * gib, true);
    try fixture.node("b", 4000, 8 * gib, true);
    try fixture.node("c", 4000, 8 * gib, true);
    // Name: three equal empty nodes, so the first replica goes to the lowest name.
    try fixture.replica("web", "web-1", 100, gib);
    try fixture.settle();
    try fixture.expect_on("web-1", "a");
    // Fewest of the service: a has one web, so b and c are ahead; the name decides between them.
    try fixture.replica("web", "web-2", 100, gib);
    try fixture.settle();
    try fixture.expect_on("web-2", "b");
    try fixture.replica("web", "web-3", 100, gib);
    try fixture.settle();
    try fixture.expect_on("web-3", "c");
    // Least allocated: another service's load makes b the fullest and c the emptiest of the
    // nodes with no `db`; `db-1` goes to the least allocated (CPU fraction), not the lowest name.
    try fixture.replica("load", "load-1", 2000, gib);
    try fixture.settle();
    try fixture.expect_on("load-1", "a"); // All hold one web; a is the lowest name.
    try fixture.replica("load", "load-2", 1000, gib);
    try fixture.settle();
    try fixture.expect_on("load-2", "b"); // b and c hold none of `load`; equal; name.
    try fixture.replica("db", "db-1", 100, gib);
    try fixture.settle();
    try fixture.expect_on("db-1", "c"); // Nobody holds a db; c has the least CPU allocated.
}

test "a node is excluded when it is not ready, judged an older tenure, in audit, or over" {
    // Goal: each exclusion alone, and the hold names it. Method: five nodes, each broken one
    // way; a sixth healthy node is added afterwards and takes the replica.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, false); // No status.
    try fixture.node("n2", 4000, 8 * gib, true);
    try fixture.status("n2", .lost, 0);
    try fixture.node("n3", 4000, 8 * gib, true);
    try fixture.status("n3", .ready, 1); // Judged an older tenure.
    try fixture.node("n4", 4000, 8 * gib, true);
    const audit: records.Audit = .{
        .recorded = .{ .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 }, .count = 0 },
        .reconstructed = .{ .allocated = .{ .cpu_millis = 1, .memory_bytes = 1 }, .count = 1 },
        .revision = 1,
        .decision = "x",
    };
    try fixture.put(.auditor, records.audit_key("n4").slice(), audit);
    try fixture.node("n5", 1000, gib, true);
    try fixture.put(.scheduler, records.allocation_key("n5").slice(), records.Allocation{
        .allocated = .{ .cpu_millis = 2000, .memory_bytes = 2 * gib },
        .count = 1,
        .node_revision = 1,
    });
    try fixture.replica("hello", "hello-1", 100, gib);
    _ = try fixture.sc_step_unchecked();
    try fixture.expect_on("hello-1", null);
    const holds = try fixture.decisions("hold_pending");
    defer testing.allocator.free(holds);
    try testing.expectEqual(@as(usize, 1), holds.len);
    const evidence = holds[0].cause_evidence.?.text;
    for ([_][]const u8{
        "\"no_status\":[\"n1\"]",
        "\"lost\":[\"n2\"]",
        "\"older_tenure\":[\"n3\"]",
        "\"audit_open\":[\"n4\"]",
        "\"over_capacity\":[\"n5\"]",
    }) |expected| try testing.expect(std.mem.indexOf(u8, evidence, expected) != null);
    try fixture.node("n6", 4000, 8 * gib, true);
    _ = try fixture.sc_step_unchecked();
    try fixture.expect_on("hello-1", "n6");
}

test "a hold names every node of a full cluster within the evidence bound" {
    // Goal: the evidence stays within `decision_evidence_bytes_max` with `nodes_max` nodes and
    // still names them all. Method: 64 nodes short on CPU alone; then the worst case, short on
    // both, where the bound is kept and the nodes that do not fit are counted.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var names: [constants.nodes_max][3]u8 = undefined;
    for (&names, 0..) |*name, index| {
        _ = std.fmt.bufPrint(name, "n{d:0>2}", .{index}) catch unreachable; // Three bytes hold it.
        try fixture.node(name, 100, 8 * gib, true);
    }
    try fixture.replica("big", "big-1", 200, gib);
    try fixture.settle();
    var holds = try fixture.decisions("hold_pending");
    try testing.expectEqual(@as(usize, 1), holds.len);
    var evidence = holds[0].cause_evidence.?.text;
    try testing.expect(evidence.len <= constants.decision_evidence_bytes_max);
    for (names) |name| {
        const quoted = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{name});
        defer testing.allocator.free(quoted);
        try testing.expect(std.mem.indexOf(u8, evidence, quoted) != null);
    }
    try testing.expect(std.mem.indexOf(u8, evidence, "omitted") == null);
    testing.allocator.free(holds);

    try fixture.replica("huge", "huge-1", 200, 16 * gib);
    try fixture.settle();
    holds = try fixture.decisions("hold_pending");
    defer testing.allocator.free(holds);
    evidence = holds[holds.len - 1].cause_evidence.?.text;
    try testing.expect(evidence.len <= constants.decision_evidence_bytes_max);
    try testing.expect(std.mem.indexOf(u8, evidence, "\"omitted\":") != null);
}

test "one hold_pending per change in the reason, not per pass" {
    // Goal: a held replica is written about when the reason changes. Method: hold; pass twice
    // (one decision); add a node that is too small too (the reason changed: a second); pass
    // again (still two); add a node that fits (it is placed, with no further hold).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 1000, 8 * gib, true);
    try fixture.replica("big", "big-1", 2000, gib);
    _ = try fixture.step();
    _ = try fixture.step();
    try testing.expectEqual(@as(usize, 1), try fixture.count("hold_pending"));
    try fixture.node("n2", 1500, 8 * gib, true);
    _ = try fixture.step();
    _ = try fixture.step();
    try testing.expectEqual(@as(usize, 2), try fixture.count("hold_pending"));
    try fixture.node("n3", 4000, 8 * gib, true);
    try fixture.settle();
    try fixture.expect_on("big-1", "n3");
    try testing.expectEqual(@as(usize, 2), try fixture.count("hold_pending"));
}

test "a released assignment frees its allocation, and a gone replica is released once" {
    // Goal: release. Method: place two replicas, delete one replica record; the assignment goes,
    // the allocation shrinks, one `release_replica` decision; nothing more on the next pass.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.replica("hello", "hello-1", 500, gib);
    try fixture.replica("hello", "hello-2", 500, gib);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 2), (try fixture.allocation("n1")).count);
    const ctx = fixture.context();
    const key = records.replica_key("hello", "hello-1");
    const delete: store.Op = .{ .delete = key.slice() };
    const ops: store.TxnRequest = .{ .on_success = &.{delete} };
    _ = try writers.txn(ctx.store, .replica_controller, ops, &fixture.diag);
    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    try fixture.expect_on("hello-1", null);
    try fixture.expect_on("hello-2", "n1");
    const allocation = try fixture.allocation("n1");
    try testing.expectEqual(@as(u32, 1), allocation.count);
    try testing.expectEqual(@as(u32, 500), allocation.allocated.cpu_millis);
    try testing.expectEqual(@as(usize, 1), try fixture.count("release_replica"));
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}

test "a replica without limits takes the defaults, and a move changes both allocations" {
    // Goal: `requests_of` resolves the defaults, and `move_replica` keeps I6 across two nodes.
    // Method: place one defaulted replica on n1, move it to n2, then to a node that is lost.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.node("n2", 4000, 8 * gib, true);
    try fixture.node("n3", 4000, 8 * gib, true);
    try fixture.status("n3", .lost, 0);
    try fixture.replica("hello", "hello-1", null, null);
    try fixture.settle();
    try fixture.expect_on("hello-1", "n1");
    const first = try fixture.allocation("n1");
    try testing.expectEqual(constants.request_default_cpu_millis, first.allocated.cpu_millis);
    try testing.expectEqual(constants.request_default_memory_bytes, first.allocated.memory_bytes);

    // The world lives in its own arena: the fixture's helpers reset theirs on every call.
    var ctx = fixture.context();
    ctx.arena = fixture.keep.allocator();
    var world = try scheduler.read_world(&ctx);
    const spec: scheduler.MoveSpec = .{ .replica = "hello-1", .to = "n2", .reason = "test move" };
    try testing.expect((try fixture.sc.move_replica(&ctx, &world, spec)) == .moved);
    try fixture.accounting_holds();
    try fixture.expect_on("hello-1", "n2");
    try testing.expectEqual(@as(u32, 0), (try fixture.allocation("n1")).count);
    try testing.expectEqual(@as(u32, 1), (try fixture.allocation("n2")).count);
    // The world the move left behind is current: a pass over it writes nothing.
    try testing.expectEqual(@as(u32, 0), (try fixture.sc.reconcile_world(&ctx, &world)).acted);

    const lost: scheduler.MoveSpec = .{ .replica = "hello-1", .to = "n3", .reason = "test move" };
    const refused = try fixture.sc.move_replica(&ctx, &world, lost);
    try testing.expect(refused == .refused);
    try testing.expectEqual(scheduler.Reason.lost, refused.refused.reason);
    try fixture.expect_on("hello-1", "n2");
}

test "a request near the top of u64 is short on memory, not an overflow" {
    // Goal: the fit sum cannot overflow. Method: n1 holds 1 GiB; a replica asking for almost
    // 2^64 bytes would overflow `allocated + need`, and is held with memory short.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.replica("hello", "hello-1", 100, gib);
    try fixture.settle();
    const huge: u64 = std.math.maxInt(u64) - 1024;
    try fixture.replica("huge", "huge-1", 100, huge);
    try fixture.settle();
    try fixture.expect_on("huge-1", null);
    const holds = try fixture.decisions("hold_pending");
    defer testing.allocator.free(holds);
    try testing.expectEqual(@as(usize, 1), holds.len);
    const evidence = holds[0].cause_evidence.?.text;
    try testing.expect(std.mem.indexOf(u8, evidence, "\"memory_short\":{\"n1\":") != null);
    try testing.expect(std.mem.indexOf(u8, evidence, "\"cpu_short\"") == null);
}

test "more held replicas than the old memory held converge: a second pass writes nothing" {
    // Goal: the hold memory covers every replica there can be. Method: 300 replicas that fit
    // nowhere; passes settle (the old 256 slots never would), and one more writes nothing.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 1000, 8 * gib, true);
    for (0..300) |number| {
        var id: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&id, "big-{d}", .{number + 1}) catch unreachable; // Fits.
        try fixture.replica("big", name, 2000, gib);
    }
    try fixture.settle();
    try testing.expectEqual(@as(usize, 300), try fixture.count("hold_pending"));
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
    try testing.expectEqual(@as(usize, 300), try fixture.count("hold_pending"));
}

test "a hold is not rewritten when only the amounts change, not the shape" {
    // Goal: the dedupe key is the shape of the reason. Method: big-1 is short on CPU on both
    // nodes; a small replica placed on n1 makes n1 short by more, which writes no new hold.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 1000, 8 * gib, true);
    try fixture.node("n2", 1500, 8 * gib, true);
    try fixture.replica("big", "big-1", 2000, gib);
    try fixture.settle();
    try testing.expectEqual(@as(usize, 1), try fixture.count("hold_pending"));
    try fixture.replica("small", "small-1", 100, gib);
    try fixture.settle();
    try fixture.expect_on("small-1", "n1");
    try testing.expectEqual(@as(usize, 1), try fixture.count("hold_pending"));
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}

test "a release cites the decision that stopped the replica, else a resync" {
    // Goal: `why replica` does not say resync when the replica controller retired it. Method:
    // one replica gets a `stop_replica` decision in the transaction that deletes it; another
    // is deleted bare.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.replica("hello", "hello-1", 500, gib);
    try fixture.replica("hello", "hello-2", 500, gib);
    try fixture.settle();
    var ctx = fixture.context();
    var source: controller.DecisionSource = .{ .instance = 9 };
    var batch: controller.Batch = .{};
    const stop = try controller.put_decision(&ctx, &source, .{
        .actor = "replica-controller",
        .action = "stop_replica",
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "removing hello-1",
        .cause = .{ .kind = .resync },
    }, &batch);
    const gone_key = records.replica_key("hello", "hello-1");
    batch.delete(gone_key.slice());
    const done = try controller.commit(&ctx, .replica_controller, &batch);
    try testing.expect(done == .applied);
    const bare = records.replica_key("hello", "hello-2");
    const delete: store.Op = .{ .delete = bare.slice() };
    const ops: store.TxnRequest = .{ .on_success = &.{delete} };
    _ = try writers.txn(ctx.store, .replica_controller, ops, &fixture.diag);
    try fixture.settle();
    const releases = try fixture.decisions("release_replica");
    defer testing.allocator.free(releases);
    try testing.expectEqual(@as(usize, 2), releases.len);
    for (releases) |release| {
        if (std.mem.eql(u8, release.subject.name, "hello-1")) {
            try testing.expectEqual(records.CauseKind.decision, release.cause.kind);
            try testing.expectEqualStrings(stop.slice(), release.cause.id.?);
        } else try testing.expectEqual(records.CauseKind.resync, release.cause.kind);
    }
}

test "a move is refused, not asserted, for a caller's bad input" {
    // Goal: `move_replica` returns `refused` for an unknown replica, one that is not assigned,
    // a move to its own node and an unknown node. Method: each against a settled world.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.node("n1", 4000, 8 * gib, true);
    try fixture.node("n2", 4000, 8 * gib, true);
    try fixture.replica("hello", "hello-1", 500, gib);
    try fixture.settle();
    try fixture.replica("big", "big-1", 9000, gib);
    var ctx = fixture.context();
    ctx.arena = fixture.keep.allocator();
    var world = try scheduler.read_world(&ctx);
    const cases = [_]struct { scheduler.MoveSpec, scheduler.Reason }{
        .{ .{ .replica = "nope-1", .to = "n2", .reason = "t" }, .unknown_replica },
        .{ .{ .replica = "big-1", .to = "n2", .reason = "t" }, .not_assigned },
        .{ .{ .replica = "hello-1", .to = "n1", .reason = "t" }, .same_node },
        .{ .{ .replica = "hello-1", .to = "n9", .reason = "t" }, .unknown_node },
    };
    for (cases) |case| {
        const result = try fixture.sc.move_replica(&ctx, &world, case[0]);
        try testing.expect(result == .refused);
        try testing.expectEqual(case[1], result.refused.reason);
    }
    try fixture.expect_on("hello-1", "n1");
    try fixture.accounting_holds();
}
