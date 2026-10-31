//! The node controller, C1 slice 3's minimum: it marks a node `ready`. Without it nothing is
//! `ready` and the scheduler places nothing (docs/authority.md §2, I7).
//!
//! A node with a `/nodes/<node>` record and no `/node-status/<node>`, or a status that judged an
//! older tenure, gets `ready` for the tenure of the record now there: the tenure revision is the
//! record's `mod_revision` (authority.md §3). The write is compared against both keys at the
//! revision read, so a node that re-registered meanwhile is judged again on the next pass. Lease
//! expiry, `lost`, `fenced` and the removal of a lost node's observed records are slice 4.
//!
//! Level-triggered like every controller: on a converged cluster a pass writes nothing.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Wakeup = controller.Wakeup;

pub const actor = "node-controller";
pub const resync_ms: u64 = 30 * 1000;

pub const watch_prefixes = [_][]const u8{ records.prefix_nodes, records.prefix_node_status };

/// Nodes one transaction marks: 3 operations and 2 compares each.
const batch_nodes_max: u32 = 5;

comptime {
    assert(batch_nodes_max * 3 <= constants.store_txn_ops_max);
    assert(batch_nodes_max * 2 <= constants.store_txn_compares_max);
}

pub const NodeController = struct {
    source: controller.DecisionSource,

    pub fn init(instance: u16) NodeController {
        return .{ .source = .{ .instance = instance } };
    }

    /// One pass. Errors are the store's (its diagnostic is in `ctx.diag`) or a malformed record.
    pub fn reconcile(nc: *NodeController, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const nodes = try controller.list_all(
            records.Node,
            ctx,
            records.prefix_nodes,
            null,
            constants.nodes_max,
        );
        const statuses = try controller.list_all(
            records.NodeStatus,
            ctx,
            records.prefix_node_status,
            nodes.revision,
            constants.nodes_max,
        );
        var acted: u32 = 0;
        var more = false;
        var batch: Batch = .{};
        var batched: u32 = 0;
        for (nodes.items) |*node| {
            const status = status_of(statuses.items, node.rec.name);
            if (!needs_ready(node, status)) continue;
            if (batched == batch_nodes_max) {
                more = true;
                break;
            }
            try nc.mark_ready(ctx, &batch, node, status);
            batched += 1;
        }
        if (batched > 0) {
            switch (try controller.commit(ctx, .node_controller, &batch)) {
                .applied => acted += 1,
                .conflict => {},
            }
            more = true;
        }
        const wake_at = if (more) now else now + resync_ms;
        return .{ .at_ms = wake_at, .prefixes = &watch_prefixes, .acted = acted };
    }

    fn mark_ready(
        nc: *NodeController,
        ctx: *const Context,
        batch: *Batch,
        node: *const Entry(records.Node),
        status: ?*const Entry(records.NodeStatus),
    ) Error!void {
        const name = node.rec.name;
        const reason = if (status) |old|
            try controller.format(ctx, "node {s} registered again (tenure {d}, was {d}); it is " ++
                "ready", .{ name, node.kv.mod_revision, old.rec.tenure })
        else
            try controller.format(ctx, "node {s} registered (tenure {d}) and has no status; it " ++
                "is ready", .{ name, node.kv.mod_revision });
        const capacity = node.rec.capacity;
        const evidence = try controller.format(
            ctx,
            "{{\"cpu_millis\":{d},\"memory_bytes\":{d}}}",
            .{ capacity.cpu_millis, capacity.memory_bytes },
        );
        const id = try controller.put_decision(ctx, &nc.source, .{
            .actor = actor,
            .action = "mark_ready",
            .subject = .{ .kind = .node, .name = name },
            .reason = reason,
            .cause = .{ .kind = .observed, .key = node.kv.key, .revision = node.kv.mod_revision },
            .cause_evidence = .{ .text = evidence },
        }, batch);
        const value: records.NodeStatus = .{
            .state = .ready,
            .tenure = node.kv.mod_revision,
            .at_ms = ctx.clock.now_ms(),
            .decision = id.slice(),
        };
        const key = records.node_status_key(name);
        const key_bytes = try controller.key_copy(ctx, &key);
        batch.expect(node.kv.key, node.kv.mod_revision);
        batch.expect(key_bytes, if (status) |old| old.kv.mod_revision else 0);
        batch.put(key_bytes, try records.encode(ctx.arena, value, ctx.diag));
    }
};

/// Whether the node has no status for its current tenure. A status for the current tenure, in
/// whatever state, is the node controller's own earlier judgement and stands.
fn needs_ready(
    node: *const Entry(records.Node),
    status: ?*const Entry(records.NodeStatus),
) bool {
    const found = status orelse return true;
    return found.rec.tenure != node.kv.mod_revision;
}

pub fn status_of(
    statuses: []const Entry(records.NodeStatus),
    node: []const u8,
) ?*const Entry(records.NodeStatus) {
    const key = records.node_status_key(node);
    for (statuses) |*entry| {
        if (std.mem.eql(u8, entry.kv.key, key.slice())) return entry;
    }
    return null;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const writers = @import("writers.zig");
const Diag = @import("diag.zig").Diag;

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,
    nc: NodeController,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.nc = NodeController.init(2);
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) Context {
        _ = self.arena_state.reset(.retain_capacity);
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    fn register(self: *Fixture, name: []const u8) !void {
        const ctx = self.context();
        const node: records.Node = .{
            .name = name,
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
        };
        const bytes = try records.encode(ctx.arena, node, &self.diag);
        const key = records.node_key(name);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
        _ = try writers.txn(ctx.store, .{ .agent = name }, .{ .on_success = &.{op} }, &self.diag);
    }

    fn step(self: *Fixture) !Wakeup {
        const ctx = self.context();
        return self.nc.reconcile(&ctx);
    }

    fn status(self: *Fixture, name: []const u8) !?Entry(records.NodeStatus) {
        const ctx = self.context();
        const key = records.node_status_key(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        const kv = got.kv orelse return null;
        const rec = try records.read(records.NodeStatus, ctx.arena, kv, &self.diag);
        return .{ .kv = kv, .rec = rec };
    }

    fn node_revision(self: *Fixture, name: []const u8) !store.Revision {
        const ctx = self.context();
        const key = records.node_key(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return got.kv.?.mod_revision;
    }
};

test "a registered node is marked ready for its tenure, once" {
    // Goal: the minimal node controller. Method: nothing to do with no nodes; a node gets
    // `ready` with the tenure its record has and a decision; a second pass writes nothing.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
    try fixture.register("n1");
    try fixture.register("n2");
    const wake = try fixture.step();
    try testing.expectEqual(@as(u32, 1), wake.acted);
    for ([_][]const u8{ "n1", "n2" }) |name| {
        const status = (try fixture.status(name)).?;
        try testing.expectEqual(records.NodeState.ready, status.rec.state);
        try testing.expectEqual(try fixture.node_revision(name), status.rec.tenure);
        try testing.expectEqual(fixture.manual.ms, status.rec.at_ms);
    }
    const again = try fixture.step();
    try testing.expectEqual(@as(u32, 0), again.acted);
    try testing.expect(again.at_ms > fixture.manual.ms);
}

test "a node that registered again is ready for the new tenure; a current judgement stands" {
    // Goal: a status for an older tenure is replaced, a status for the current one is not.
    // Method: re-register n1 (a new `mod_revision`); mark n2 `lost` for its tenure by hand.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register("n1");
    try fixture.register("n2");
    _ = try fixture.step();
    const first = (try fixture.status("n1")).?;
    try fixture.register("n1");
    const lost: records.NodeStatus = .{
        .state = .lost,
        .tenure = try fixture.node_revision("n2"),
        .at_ms = fixture.manual.ms,
        .decision = "x",
    };
    const ctx = fixture.context();
    const key = records.node_status_key("n2");
    const bytes = try records.encode(ctx.arena, lost, &fixture.diag);
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
    _ = try writers.txn(ctx.store, .node_controller, .{ .on_success = &.{op} }, &fixture.diag);

    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    const second = (try fixture.status("n1")).?;
    try testing.expect(second.rec.tenure > first.rec.tenure);
    try testing.expectEqual(try fixture.node_revision("n1"), second.rec.tenure);
    try testing.expectEqual(records.NodeState.lost, (try fixture.status("n2")).?.rec.state);
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}

test "more nodes than a batch take several passes" {
    // Goal: the batch bound. Method: batch_nodes_max + 2 nodes; passes say they have more.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const names = [_][]const u8{ "n1", "n2", "n3", "n4", "n5", "n6", "n7" };
    comptime assert(names.len == batch_nodes_max + 2);
    for (names) |name| try fixture.register(name);
    const first = try fixture.step();
    try testing.expectEqual(@as(u32, 1), first.acted);
    try testing.expectEqual(fixture.manual.ms, first.at_ms);
    _ = try fixture.step();
    for (names) |name| try testing.expect((try fixture.status(name)) != null);
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}
