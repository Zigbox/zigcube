//! The node controller, C1 slice 3's minimum: it marks a node `ready`. Without it nothing is
//! `ready` and the scheduler places nothing (docs/authority.md §2, I7).
//!
//! A node with a `/nodes/<node>` record and no `/node-status/<node>`, or a status that judged an
//! older tenure, gets `ready` for the tenure of the record now there: the tenure revision is the
//! record's `mod_revision` (authority.md §3). The write is compared against both keys at the
//! revision read, so a node that re-registered meanwhile is judged again on the next pass.
//!
//! A ready node whose record is gone (the store deleted it when its lease ran out) is marked
//! `lost` for the tenure it had, with a `mark_lost` decision that carries the lease's `ttl` and
//! when the server last heard from the agent (C1 slice 4). Its observed records are then removed
//! a page at a time, each page with a `remove_observed` decision. `fenced` needs a fencing proof,
//! which nothing produces in C1.
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

/// Nodes one transaction marks: 3 operations and 2 compares each, plus the decision's.
const batch_nodes_max: u32 = 3;
/// Observed records one transaction removes: the rest of the transaction is its one decision.
pub const observed_removals_per_txn: u32 = constants.store_txn_ops_max - controller.decision_ops;
/// The soonest the controller samples the leases again, so a lease whose time is up but which the
/// store has not yet revoked does not make it spin.
pub const lease_sample_min_ms: u64 = 200;

comptime {
    assert(batch_nodes_max * (1 + controller.decision_ops) <= constants.store_txn_ops_max);
    const compares_per_node = 2 + controller.decision_compares;
    assert(batch_nodes_max * compares_per_node <= constants.store_txn_compares_max);
    assert(observed_removals_per_txn > 0);
    assert(2 + controller.decision_compares <= constants.store_txn_compares_max);
}

/// What the controller last learned of a ready node's lease: a cache (authority.md §1), empty
/// after a restart, used only as evidence of when the server last heard from the agent.
const LeaseMemo = struct {
    node: records.Key = .{},
    tenure: u64 = 0,
    lease: store.LeaseId = store.lease_none,
    ttl_ms: u32 = 0,
    /// On the controller's clock: when the agent's last keepalive was received.
    heard_ms: u64 = 0,
};

pub const NodeController = struct {
    source: controller.DecisionSource,
    memos: [constants.nodes_max]LeaseMemo = @splat(.{}),

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
        var more = try nc.judge(ctx, nodes.items, statuses.items, &acted);
        if (!more) more = try nc.remove_observed(ctx, nodes.items, statuses.items, &acted);
        const sample_at = try nc.sample_leases(ctx, nodes.items, statuses.items);
        const wake_at = if (more) now else @min(now + resync_ms, sample_at);
        assert(wake_at >= now);
        return .{ .at_ms = wake_at, .prefixes = &watch_prefixes, .acted = acted };
    }

    /// Marks ready the nodes with no status for their tenure and lost the ready nodes whose
    /// record is gone, a batch at a time. Returns whether there may be more to do.
    fn judge(
        nc: *NodeController,
        ctx: *const Context,
        nodes: []const Entry(records.Node),
        statuses: []const Entry(records.NodeStatus),
        acted: *u32,
    ) Error!bool {
        var more = false;
        var batch: Batch = .{};
        var batched: u32 = 0;
        for (nodes) |*node| {
            const status = status_of(statuses, node.rec.name);
            if (!needs_ready(node, status)) continue;
            if (batched == batch_nodes_max) {
                more = true;
                break;
            }
            try nc.mark_ready(ctx, &batch, node, status);
            batched += 1;
        }
        for (statuses) |*status| {
            if (status.rec.state != .ready) continue;
            const name = status.kv.key[records.prefix_node_status.len..];
            if (node_of(nodes, name) != null) continue;
            if (batched == batch_nodes_max) {
                more = true;
                break;
            }
            try nc.mark_lost(ctx, &batch, name, status);
            batched += 1;
        }
        if (batched == 0) return more;
        switch (try controller.commit(ctx, .node_controller, &batch)) {
            .applied => acted.* += 1,
            .conflict => {},
        }
        return true;
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

    /// The node's record is gone: its lease ran out (authority.md §3). The status becomes `lost`
    /// for the tenure it judged, compared with the record still absent and the status as read.
    fn mark_lost(
        nc: *NodeController,
        ctx: *const Context,
        batch: *Batch,
        name: []const u8,
        status: *const Entry(records.NodeStatus),
    ) Error!void {
        assert(status.rec.state == .ready);
        const node_key = records.node_key(name);
        const node_bytes = try controller.key_copy(ctx, &node_key);
        const memo = nc.memo_of(name, status.rec.tenure);
        const lease = if (memo) |found|
            found.lease
        else
            try lease_at_tenure(ctx, &node_key, status);
        const ttl_ms: u64 = if (memo) |found| found.ttl_ms else constants.node_lease_ttl_ms;
        const now = ctx.clock.now_ms();
        const reason = if (memo) |found|
            try controller.format(ctx, "node {s} is lost: its lease {d} (ttl {d} ms) ran out; " ++
                "the server last heard from it {d} ms ago", .{
                name, lease, ttl_ms, now -| found.heard_ms,
            })
        else
            try controller.format(ctx, "node {s} is lost: its lease {d} ran out; when the " ++
                "server last heard from it is unknown (the server restarted)", .{ name, lease });
        const evidence = if (memo) |found|
            try controller.format(ctx, "{{\"tenure\":{d},\"lease\":{d},\"ttl_ms\":{d}," ++
                "\"last_heard_ms\":{d}}}", .{ status.rec.tenure, lease, ttl_ms, found.heard_ms })
        else
            try controller.format(ctx, "{{\"tenure\":{d},\"lease\":{d},\"ttl_ms\":{d}," ++
                "\"last_heard_ms\":null}}", .{ status.rec.tenure, lease, ttl_ms });
        const id = try controller.put_decision(ctx, &nc.source, .{
            .actor = actor,
            .action = "mark_lost",
            .subject = .{ .kind = .node, .name = name },
            .reason = reason,
            .cause = .{
                .kind = .lease_expired,
                .key = node_bytes,
                .revision = status.rec.tenure,
                .lease = lease,
                .ttl_ms = ttl_ms,
            },
            .cause_evidence = .{ .text = evidence },
        }, batch);
        const value: records.NodeStatus = .{
            .state = .lost,
            .tenure = status.rec.tenure,
            .at_ms = now,
            .decision = id.slice(),
        };
        batch.expect(node_bytes, 0);
        batch.expect(status.kv.key, status.kv.mod_revision);
        batch.put(status.kv.key, try records.encode(ctx.arena, value, ctx.diag));
    }

    fn memo_of(nc: *const NodeController, name: []const u8, tenure: u64) ?*const LeaseMemo {
        for (&nc.memos) |*memo| {
            if (memo.node.len == 0 or memo.tenure != tenure) continue;
            if (std.mem.eql(u8, memo.node.slice(), name)) return memo;
        }
        return null;
    }

    /// Remembers each ready node's lease and when its last keepalive was received, and returns
    /// when to look again: the soonest predicted expiry, so the last look before an expiry has
    /// seen the last keepalive.
    fn sample_leases(
        nc: *NodeController,
        ctx: *const Context,
        nodes: []const Entry(records.Node),
        statuses: []const Entry(records.NodeStatus),
    ) Error!u64 {
        const now = ctx.clock.now_ms();
        var next: u64 = std.math.maxInt(u64);
        var leases: ?[]const store.LeaseInfo = null;
        var used: u32 = 0;
        var fresh: [constants.nodes_max]LeaseMemo = @splat(.{});
        for (nodes) |*node| {
            if (node.kv.lease == store.lease_none) continue;
            const status = status_of(statuses, node.rec.name) orelse continue;
            if (status.rec.state != .ready) continue;
            if (status.rec.tenure != node.kv.mod_revision) continue;
            if (leases == null) leases = try ctx.store.lease_list(ctx.arena, ctx.diag);
            const info = lease_info(leases.?, node.kv.lease) orelse continue;
            assert(info.remaining_ms <= info.ttl_ms);
            const heard = (now + info.remaining_ms) -| info.ttl_ms;
            fresh[used] = .{
                .node = name_key(node.rec.name),
                .tenure = node.kv.mod_revision,
                .lease = info.id,
                .ttl_ms = info.ttl_ms,
                .heard_ms = heard,
            };
            used += 1;
            next = @min(next, @max(heard + info.ttl_ms, now + lease_sample_min_ms));
        }
        // A lost node's memo is kept until it is judged, so `mark_lost` can still cite it.
        for (&nc.memos) |*memo| {
            if (memo.node.len == 0 or used == constants.nodes_max) continue;
            const name = memo.node.slice();
            if (node_of(nodes, name) != null) continue;
            const status = status_of(statuses, name) orelse continue;
            if (status.rec.state != .ready or status.rec.tenure != memo.tenure) continue;
            fresh[used] = memo.*;
            used += 1;
        }
        nc.memos = fresh;
        return next;
    }

    /// Removes a page of a lost node's observed records, with one decision, while its record is
    /// still absent and its status still the one read (authority.md §3). Returns whether there
    /// may be more.
    fn remove_observed(
        nc: *NodeController,
        ctx: *const Context,
        nodes: []const Entry(records.Node),
        statuses: []const Entry(records.NodeStatus),
        acted: *u32,
    ) Error!bool {
        for (statuses) |*status| {
            if (status.rec.state != .lost) continue;
            const name = status.kv.key[records.prefix_node_status.len..];
            if (node_of(nodes, name) != null) continue;
            const prefix = records.observed_prefix(name);
            const page = try ctx.store.list(ctx.arena, .{
                .prefix = prefix.slice(),
                .limit = observed_removals_per_txn,
            }, ctx.diag);
            if (page.kvs.len == 0) continue;
            assert(page.kvs.len <= observed_removals_per_txn);
            var batch: Batch = .{};
            const node_key = records.node_key(name);
            batch.expect(try controller.key_copy(ctx, &node_key), 0);
            batch.expect(status.kv.key, status.kv.mod_revision);
            const reason = try controller.format(ctx, "node {s} is lost; {d} of its observed " ++
                "records are removed, the first {s}", .{
                name, page.kvs.len, page.kvs[0].key[prefix.len..],
            });
            const cause: records.Cause = .{ .kind = .decision, .id = status.rec.decision };
            _ = try controller.put_decision(ctx, &nc.source, .{
                .actor = actor,
                .action = "remove_observed",
                .subject = .{ .kind = .node, .name = name },
                .reason = reason,
                .cause = cause,
            }, &batch);
            for (page.kvs) |kv| batch.delete(kv.key);
            switch (try controller.commit(ctx, .node_controller, &batch)) {
                .applied => acted.* += 1,
                .conflict => {},
            }
            return true;
        }
        return false;
    }
};

/// A key-sized buffer holding a node's name.
fn name_key(name: []const u8) records.Key {
    assert(name.len > 0);
    assert(name.len <= constants.node_name_bytes_max);
    var key: records.Key = .{};
    @memcpy(key.bytes[0..name.len], name);
    key.len = @intCast(name.len);
    return key;
}

fn lease_info(leases: []const store.LeaseInfo, id: store.LeaseId) ?*const store.LeaseInfo {
    assert(id != store.lease_none);
    for (leases) |*info| {
        if (info.id == id) return info;
    }
    return null;
}

/// The lease the node registered on, from its record at the tenure revision, or 0 when the store
/// has compacted it away.
fn lease_at_tenure(
    ctx: *const Context,
    node_key: *const records.Key,
    status: *const Entry(records.NodeStatus),
) Error!store.LeaseId {
    assert(status.rec.tenure > 0);
    const got = ctx.store.get(ctx.arena, node_key.slice(), status.rec.tenure, ctx.diag) catch |err|
        switch (err) {
            error.Compacted => {
                ctx.diag.reset();
                return store.lease_none;
            },
            else => return err,
        };
    const kv = got.kv orelse return store.lease_none;
    return kv.lease;
}

/// Whether the node has no status for its current tenure. A status for the current tenure, in
/// whatever state, is the node controller's own earlier judgement and stands.
fn needs_ready(
    node: *const Entry(records.Node),
    status: ?*const Entry(records.NodeStatus),
) bool {
    const found = status orelse return true;
    return found.rec.tenure != node.kv.mod_revision;
}

fn node_of(nodes: []const Entry(records.Node), name: []const u8) ?*const Entry(records.Node) {
    for (nodes) |*node| {
        if (std.mem.eql(u8, node.rec.name, name)) return node;
    }
    return null;
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

    /// Registers `name` on a lease of `ttl_ms`, as the agent does, and returns the lease.
    fn register_leased(self: *Fixture, name: []const u8, ttl_ms: u32) !store.LeaseId {
        const ctx = self.context();
        const lease = try ctx.store.lease_grant(ttl_ms, &self.diag);
        const node: records.Node = .{
            .name = name,
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
        };
        const bytes = try records.encode(ctx.arena, node, &self.diag);
        const key = records.node_key(name);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes, .lease = lease.id } };
        _ = try writers.txn(ctx.store, .{ .agent = name }, .{ .on_success = &.{op} }, &self.diag);
        return lease.id;
    }

    fn observe(self: *Fixture, node: []const u8, replica: []const u8) !void {
        const ctx = self.context();
        const value: records.Observed = .{
            .replica = replica,
            .node = node,
            .generation = 1,
            .status = .running,
            .reported_at_ms = self.manual.ms,
        };
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const key = records.observed_key(node, replica);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
        _ = try writers.txn(ctx.store, .{ .agent = node }, .{ .on_success = &.{op} }, &self.diag);
    }

    fn count(self: *Fixture, prefix: []const u8) !usize {
        const ctx = self.context();
        const limit = constants.store_list_limit_max;
        const request: store.ListOptions = .{ .prefix = prefix, .limit = limit };
        const page = try ctx.store.list(ctx.arena, request, &self.diag);
        return page.kvs.len;
    }

    fn decision(self: *Fixture, id: []const u8) !records.Decision {
        const ctx = self.context();
        const key = records.decision_key(id);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return records.read(records.Decision, ctx.arena, got.kv.?, &self.diag);
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
    const names = [_][]const u8{ "n1", "n2", "n3", "n4", "n5" };
    comptime assert(names.len == batch_nodes_max + 2);
    for (names) |name| try fixture.register(name);
    const first = try fixture.step();
    try testing.expectEqual(@as(u32, 1), first.acted);
    try testing.expectEqual(fixture.manual.ms, first.at_ms);
    _ = try fixture.step();
    for (names) |name| try testing.expect((try fixture.status(name)) != null);
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}

test "a node whose lease ran out is lost, with the ttl and when it was last heard" {
    // Goal: lease expiry to `lost` (authority.md §3, c1.md "Lease timeout printed at failover").
    // Method: a leased node is ready and sampled; a keepalive 4 s later; the lease runs out; the
    // next pass marks it lost for the tenure it had, citing the lease, its ttl and the keepalive.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const lease = try fixture.register_leased("n1", 10_000);
    const tenure = try fixture.node_revision("n1");
    _ = try fixture.step();
    fixture.manual.ms += 4000;
    _ = try fixture.memory.interface().lease_keepalive(lease, &fixture.diag);
    const heard = fixture.manual.ms;
    const wake = try fixture.step();
    try testing.expectEqual(@as(u32, 0), wake.acted);
    try testing.expectEqual(heard + 10_000, wake.at_ms); // Sampled again at the predicted expiry.
    fixture.manual.ms = wake.at_ms + 1;
    const expired = try fixture.memory.interface().expire_leases(&fixture.diag);
    try testing.expectEqual(@as(u32, 1), expired);
    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    const status = (try fixture.status("n1")).?;
    try testing.expectEqual(records.NodeState.lost, status.rec.state);
    try testing.expectEqual(tenure, status.rec.tenure);
    const decided = try fixture.decision(status.rec.decision);
    try testing.expectEqualStrings("mark_lost", decided.action);
    try testing.expectEqual(records.CauseKind.lease_expired, decided.cause.kind);
    try testing.expectEqual(lease, decided.cause.lease.?);
    try testing.expectEqual(@as(u64, 10_000), decided.cause.ttl_ms.?);
    const evidence = decided.cause_evidence.?.text;
    var buffer: [64]u8 = undefined;
    const heard_text = try std.fmt.bufPrint(&buffer, "\"last_heard_ms\":{d}", .{heard});
    try testing.expect(std.mem.indexOf(u8, evidence, heard_text) != null);
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
}

test "a lost node is judged without memory after a restart, and ready again when it registers" {
    // Goal: the lease memory is a cache; re-registration of a lost node is a new tenure.
    // Method: a fresh controller (no samples) marks lost with the lease read at the tenure
    // revision; the node registers again and is ready under the new tenure.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const lease = try fixture.register_leased("n1", 1000);
    _ = try fixture.step();
    fixture.nc = NodeController.init(3);
    fixture.manual.ms += 1001;
    _ = try fixture.memory.interface().expire_leases(&fixture.diag);
    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    const lost = (try fixture.status("n1")).?;
    try testing.expectEqual(records.NodeState.lost, lost.rec.state);
    const decided = try fixture.decision(lost.rec.decision);
    try testing.expectEqual(lease, decided.cause.lease.?);
    try testing.expect(std.mem.indexOf(u8, decided.cause_evidence.?.text, "null") != null);
    _ = try fixture.register_leased("n1", 1000);
    try testing.expectEqual(@as(u32, 1), (try fixture.step()).acted);
    const ready = (try fixture.status("n1")).?;
    try testing.expectEqual(records.NodeState.ready, ready.rec.state);
    try testing.expect(ready.rec.tenure > lost.rec.tenure);
}

test "a lost node's observed records are removed a page at a time; a live node's are kept" {
    // Goal: authority.md §3, the node controller removes a lost node's observed records itself.
    // Method: more records than one page on a lost node, a few on a live one; passes remove the
    // lost node's in pages, each with a `remove_observed` decision, and leave the live node's.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    _ = try fixture.register_leased("n1", 1000);
    try fixture.register("n2");
    _ = try fixture.step();
    var name_buffer: [16]u8 = undefined;
    const total = observed_removals_per_txn + 3;
    for (0..total) |index| {
        try fixture.observe("n1", try std.fmt.bufPrint(&name_buffer, "hello-{d}", .{index}));
    }
    try fixture.observe("n2", "other-1");
    fixture.manual.ms += 1001;
    _ = try fixture.memory.interface().expire_leases(&fixture.diag);
    _ = try fixture.step(); // Marks n1 lost.
    try testing.expectEqual(@as(usize, total), try fixture.count("/observed/n1/"));
    const first = try fixture.step();
    try testing.expectEqual(@as(u32, 1), first.acted);
    try testing.expectEqual(fixture.manual.ms, first.at_ms);
    try testing.expectEqual(@as(usize, 3), try fixture.count("/observed/n1/"));
    _ = try fixture.step();
    try testing.expectEqual(@as(usize, 0), try fixture.count("/observed/n1/"));
    try testing.expectEqual(@as(usize, 1), try fixture.count("/observed/n2/"));
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
    // mark_ready, mark_lost and one remove_observed per page.
    try testing.expectEqual(@as(usize, 4), try fixture.count("/decisions-by-subject/node/n1/"));
}
