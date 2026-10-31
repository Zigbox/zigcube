//! The scheduler (docs/authority.md §2): the sole writer of `/assigned/` and `/allocations/`. It
//! places an unassigned replica, releases the assignment of a replica that is gone, moves a
//! replica between nodes, and holds a replica that fits nowhere with the shortfall as evidence.
//!
//! One placement, release or move is one transaction, written with its decision and compared on
//! every fact it rests on (`compare_sets.zig`). `/allocations/<node>` is the authoritative sum of
//! a node's assignments, and every transaction that adds or removes an assignment rewrites it, so
//! a concurrent insert moves its revision and the stale plan fails (phantoms, authority.md §2). A
//! failed compare means the world changed: the pass stops and the next one plans again from what
//! the store then says; the same transaction is never retried.
//!
//! A pass reads the world once and updates its own copy after each commit it makes (the revision
//! of the transaction is the new revision of every key it wrote), so one pass can make up to
//! `controller_txns_per_step_max` transactions. Level-triggered like every controller: on a
//! converged cluster a pass writes nothing.
//!
//! Not here yet: nothing calls `move_replica` until a node is lost (slice 4), and `/services/` is
//! not read, so the replica of a deleted service is placed and then released.

const std = @import("std");
const assert = std.debug.assert;
const compare_sets = @import("compare_sets.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Requests = records.Requests;
const Revision = store.Revision;
const Wakeup = controller.Wakeup;

pub const actor = "scheduler";
/// The scheduler wakes on any change to what it reads. This is only the fallback if a wake-up
/// was missed, not a polling loop: a pass that finds nothing to do writes nothing.
pub const resync_ms: u64 = 30 * 1000;
/// Replicas whose hold the scheduler remembers, so a hold is written once per change in its
/// reason. A restart forgets them and writes each hold once more.
pub const hold_memory_max: u32 = 256;

pub const watch_prefixes = [_][]const u8{
    records.prefix_replicas,
    records.prefix_assigned,
    records.prefix_nodes,
    records.prefix_node_status,
    records.prefix_allocations,
    records.prefix_audit_allocations,
};

/// What the scheduler resolves a replica to need: its limits, else the default.
pub fn requests_of(replica: *const records.Replica) Requests {
    return .{
        .cpu_millis = replica.limits.cpu_millis orelse constants.request_default_cpu_millis,
        .memory_bytes = replica.limits.memory_bytes orelse constants.request_default_memory_bytes,
    };
}

// ---- The world a pass plans from -------------------------------------------------------------

/// Why a node can or cannot take a replica.
pub const Reason = enum {
    fits,
    /// No `/nodes` record with that name (a move to a node that is not there).
    unknown_node,
    no_status,
    lost,
    fenced,
    /// The status judged an older tenure than the node's current record.
    older_tenure,
    /// An open `/audit/allocations` finding.
    audit_open,
    /// The allocation record is already above the declared capacity.
    over_capacity,
    /// The replica does not fit: `cpu_by` or `memory_by` is how far over it would go.
    short,
    /// The node a replica moves from has no allocation record to release from.
    unaccounted,
};

pub const Verdict = struct {
    reason: Reason,
    cpu_by: u64 = 0,
    memory_by: u64 = 0,
};

const NodeView = struct {
    node: *const Entry(records.Node),
    status: ?records.NodeStatus,
    status_revision: Revision,
    audit_open: bool,
    /// 0 for a node with no allocation record yet.
    alloc_revision: Revision,
    alloc_node_revision: u64,
    allocated: Requests,
    count: u32,
};

const no_node: u32 = std.math.maxInt(u32);

const Assign = struct {
    key: []const u8,
    node: u32,
    replica: []const u8,
    service: []const u8,
    requests: Requests,
    revision: Revision,
    live: bool,
};

/// Everything a pass reads, at one revision, and kept current as the pass commits.
pub const World = struct {
    revision: Revision,
    replicas: []const Entry(records.Replica),
    nodes: []NodeView,
    assigns: std.ArrayList(Assign),
    /// Replica id -> index in `assigns`, for a live assignment.
    assigned_by: std.StringHashMapUnmanaged(u32),
    /// Replica id -> index in `replicas`.
    desired: std.StringHashMapUnmanaged(u32),

    fn node_index(world: *const World, name: []const u8) ?u32 {
        for (world.nodes, 0..) |view, index| {
            if (std.mem.eql(u8, view.node.rec.name, name)) return @intCast(index);
        }
        return null;
    }
};

fn find_by_key(comptime T: type, items: []const Entry(T), key: []const u8) ?*const Entry(T) {
    for (items) |*entry| {
        if (std.mem.eql(u8, entry.kv.key, key)) return entry;
    }
    return null;
}

/// Reads `/replicas`, then everything else at that revision.
pub fn read_world(ctx: *const Context) Error!World {
    const replicas = try controller.list_all(
        records.Replica,
        ctx,
        records.prefix_replicas,
        null,
        constants.replicas_max,
    );
    const at = replicas.revision;
    const assigned = try controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        at,
        constants.replicas_max,
    );
    const nodes = try controller.list_all(
        records.Node,
        ctx,
        records.prefix_nodes,
        at,
        constants.nodes_max,
    );
    const statuses = try controller.list_all(
        records.NodeStatus,
        ctx,
        records.prefix_node_status,
        at,
        constants.nodes_max,
    );
    const allocations = try controller.list_all(
        records.Allocation,
        ctx,
        records.prefix_allocations,
        at,
        constants.nodes_max,
    );
    const audits = try controller.list_all(
        records.Audit,
        ctx,
        records.prefix_audit_allocations,
        at,
        constants.nodes_max,
    );
    var world: World = .{
        .revision = at,
        .replicas = replicas.items,
        .nodes = try views_of(ctx, nodes.items, statuses.items, allocations.items, audits.items),
        .assigns = .empty,
        .assigned_by = .empty,
        .desired = .empty,
    };
    try index_replicas(ctx, &world);
    try index_assigned(ctx, &world, assigned.items);
    return world;
}

fn views_of(
    ctx: *const Context,
    nodes: []const Entry(records.Node),
    statuses: []const Entry(records.NodeStatus),
    allocations: []const Entry(records.Allocation),
    audits: []const Entry(records.Audit),
) Error![]NodeView {
    const views = ctx.arena.alloc(NodeView, nodes.len) catch return failures.no_memory(ctx.diag);
    for (nodes, views) |*node, *view| {
        const name = node.rec.name;
        const status_key = records.node_status_key(name);
        const status = find_by_key(records.NodeStatus, statuses, status_key.slice());
        const alloc_key = records.allocation_key(name);
        const alloc = find_by_key(records.Allocation, allocations, alloc_key.slice());
        const audit = find_by_key(records.Audit, audits, records.audit_key(name).slice());
        view.* = .{
            .node = node,
            .status = if (status) |found| found.rec else null,
            .status_revision = if (status) |found| found.kv.mod_revision else 0,
            .audit_open = audit != null,
            .alloc_revision = if (alloc) |found| found.kv.mod_revision else 0,
            .alloc_node_revision = if (alloc) |found| found.rec.node_revision else 0,
            .allocated = if (alloc) |found| found.rec.allocated else .{
                .cpu_millis = 0,
                .memory_bytes = 0,
            },
            .count = if (alloc) |found| found.rec.count else 0,
        };
    }
    return views;
}

fn index_replicas(ctx: *const Context, world: *World) Error!void {
    for (world.replicas, 0..) |*replica, index| {
        world.desired.put(ctx.arena, replica.rec.id, @intCast(index)) catch
            return failures.no_memory(ctx.diag);
    }
}

fn index_assigned(
    ctx: *const Context,
    world: *World,
    assigned: []const Entry(records.Assigned),
) Error!void {
    for (assigned) |*entry| {
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse unreachable; // Key shape.
        const node = world.node_index(rest[0..slash]) orelse no_node;
        try add_assign(ctx, world, .{
            .key = entry.kv.key,
            .node = node,
            .replica = entry.rec.replica,
            .service = entry.rec.service,
            .requests = entry.rec.requests,
            .revision = entry.kv.mod_revision,
            .live = true,
        });
    }
}

fn add_assign(ctx: *const Context, world: *World, assign: Assign) Error!void {
    const index: u32 = @intCast(world.assigns.items.len);
    world.assigns.append(ctx.arena, assign) catch return failures.no_memory(ctx.diag);
    world.assigned_by.put(ctx.arena, assign.replica, index) catch
        return failures.no_memory(ctx.diag);
}

// ---- Fit, exclusion and spread ---------------------------------------------------------------

/// Whether `view` can take a replica needing `need`, and if not, why. The order is the order a
/// reader fixes first: readiness, then findings, then capacity.
fn judge(view: *const NodeView, need: Requests) Verdict {
    const status = view.status orelse return .{ .reason = .no_status };
    switch (status.state) {
        .lost => return .{ .reason = .lost },
        .fenced => return .{ .reason = .fenced },
        .ready => {},
    }
    if (status.tenure != view.node.kv.mod_revision) return .{ .reason = .older_tenure };
    if (view.audit_open) return .{ .reason = .audit_open };
    const capacity = view.node.rec.capacity;
    if (view.allocated.cpu_millis > capacity.cpu_millis) return .{ .reason = .over_capacity };
    if (view.allocated.memory_bytes > capacity.memory_bytes) return .{ .reason = .over_capacity };
    const cpu_after = @as(u64, view.allocated.cpu_millis) + need.cpu_millis;
    const memory_after = view.allocated.memory_bytes + need.memory_bytes;
    const cpu_by = cpu_after -| capacity.cpu_millis;
    const memory_by = memory_after -| capacity.memory_bytes;
    if (cpu_by == 0 and memory_by == 0) return .{ .reason = .fits };
    return .{ .reason = .short, .cpu_by = cpu_by, .memory_by = memory_by };
}

/// Replicas of `service` assigned to each node.
fn service_counts(world: *const World, service: []const u8, counts: []u32) void {
    assert(counts.len == world.nodes.len);
    @memset(counts, 0);
    for (world.assigns.items) |assign| {
        if (!assign.live or assign.node == no_node) continue;
        if (std.mem.eql(u8, assign.service, service)) counts[assign.node] += 1;
    }
}

/// Whether node `first` is a better home than `second`: fewest assignments of the same service,
/// then least allocated (CPU, then memory, as a fraction of capacity), then the lower name.
fn precedes(world: *const World, counts: []const u32, first: u32, second: u32) bool {
    if (counts[first] != counts[second]) return counts[first] < counts[second];
    const left = &world.nodes[first];
    const right = &world.nodes[second];
    const cpu = fraction_order(
        left.allocated.cpu_millis,
        left.node.rec.capacity.cpu_millis,
        right.allocated.cpu_millis,
        right.node.rec.capacity.cpu_millis,
    );
    if (cpu != .eq) return cpu == .lt;
    const memory = fraction_order(
        left.allocated.memory_bytes,
        left.node.rec.capacity.memory_bytes,
        right.allocated.memory_bytes,
        right.node.rec.capacity.memory_bytes,
    );
    if (memory != .eq) return memory == .lt;
    return std.mem.order(u8, left.node.rec.name, right.node.rec.name) == .lt;
}

/// Compares `used_a / cap_a` with `used_b / cap_b` without dividing.
fn fraction_order(used_a: u64, cap_a: u64, used_b: u64, cap_b: u64) std.math.Order {
    const left = @as(u128, used_a) * cap_b;
    const right = @as(u128, used_b) * cap_a;
    return std.math.order(left, right);
}

const Chosen = struct { index: u32, candidates: u32, service_count: u32 };

fn choose(world: *const World, service: []const u8, verdicts: []const Verdict) ?Chosen {
    assert(verdicts.len == world.nodes.len);
    var counts: [constants.nodes_max]u32 = undefined;
    service_counts(world, service, counts[0..world.nodes.len]);
    var best: ?u32 = null;
    var candidates: u32 = 0;
    for (verdicts, 0..) |verdict, index| {
        if (verdict.reason != .fits) continue;
        candidates += 1;
        const at: u32 = @intCast(index);
        if (best == null or precedes(world, &counts, at, best.?)) best = at;
    }
    const index = best orelse return null;
    return .{ .index = index, .candidates = candidates, .service_count = counts[index] };
}

// ---- The scheduler ---------------------------------------------------------------------------

const Hold = struct { replica: u64, evidence: u64 };

const Pass = struct {
    txns_left: u32 = constants.controller_txns_per_step_max,
    acted: u32 = 0,
    more: bool = false,
    stopped: bool = false,

    fn budget(pass: *Pass) bool {
        if (pass.txns_left == 0) {
            pass.more = true;
            return false;
        }
        pass.txns_left -= 1;
        return true;
    }

    /// The revision a commit took, or null if the world changed under the plan: the pass stops
    /// and the next one plans again.
    fn landed(pass: *Pass, done: controller.Commit) ?Revision {
        switch (done) {
            .applied => |revision| {
                pass.acted += 1;
                return revision;
            },
            .conflict => {
                pass.more = true;
                pass.stopped = true;
                return null;
            },
        }
    }
};

pub const Scheduler = struct {
    source: controller.DecisionSource,
    holds: [hold_memory_max]Hold = @splat(.{ .replica = 0, .evidence = 0 }),
    holds_next: u32 = 0,

    pub fn init(instance: u16) Scheduler {
        return .{ .source = .{ .instance = instance } };
    }

    /// One pass. Errors are the store's (its diagnostic is in `ctx.diag`) or a malformed record.
    pub fn reconcile(sc: *Scheduler, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        var world = try read_world(ctx);
        return sc.reconcile_world(ctx, &world);
    }

    /// A pass over a world already read: releases first (they free capacity), then places.
    pub fn reconcile_world(sc: *Scheduler, ctx: *const Context, world: *World) Error!Wakeup {
        var pass: Pass = .{};
        var index: u32 = 0;
        while (index < world.assigns.items.len and !pass.stopped) : (index += 1) {
            try sc.release_one(ctx, world, &pass, index);
        }
        for (0..world.replicas.len) |replica| {
            if (pass.stopped) break;
            try sc.place_one(ctx, world, &pass, @intCast(replica));
        }
        const now = ctx.clock.now_ms();
        const wake_at = if (pass.more) now else now + resync_ms;
        return .{ .at_ms = wake_at, .prefixes = &watch_prefixes, .acted = pass.acted };
    }

    // ---- Release ----

    fn release_one(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        index: u32,
    ) Error!void {
        const assign = world.assigns.items[index];
        if (!assign.live or world.desired.contains(assign.replica)) return;
        if (assign.node == no_node) return; // The node is gone: slice 4's removal of its records.
        const view = &world.nodes[assign.node];
        if (view.alloc_revision == 0) return; // Unaccounted: the auditor's finding, not ours.
        const after = subtract(view, assign.requests) orelse return;
        if (!pass.budget()) return;
        const name = view.node.rec.name;
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        compare_sets.release(&set, name, assign.replica, assign.revision, view.alloc_revision);
        expect_all(&batch, &set);
        const fmt = "replica {s} is gone; its {d}m CPU and {d} MiB on {s} are released";
        const reason = try controller.format(ctx, fmt, .{
            assign.replica,
            assign.requests.cpu_millis,
            mib_of(assign.requests.memory_bytes),
            name,
        });
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = "release_replica",
            .subject = .{ .kind = .replica, .name = assign.replica },
            .reason = reason,
            .cause = .{ .kind = .resync },
        }, &batch);
        batch.delete(assign.key);
        try put_allocation(ctx, &batch, name, after, view.count - 1, view.alloc_node_revision);
        const revision = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        forget_assign(world, index, after, revision);
    }

    // ---- Place and hold ----

    fn place_one(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        replica_index: u32,
    ) Error!void {
        const replica = &world.replicas[replica_index];
        if (world.assigned_by.contains(replica.rec.id)) return;
        const need = requests_of(&replica.rec);
        var verdicts: [constants.nodes_max]Verdict = undefined;
        const judged = verdicts[0..world.nodes.len];
        for (world.nodes, judged) |*view, *verdict| verdict.* = judge(view, need);
        const chosen = choose(world, replica.rec.service, judged) orelse {
            return sc.hold(ctx, world, pass, replica, judged);
        };
        if (!pass.budget()) return;
        const view = &world.nodes[chosen.index];
        const name = view.node.rec.name;
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        compare_sets.placement(&set, replica_read(replica), node_read(view));
        expect_all(&batch, &set);
        const reason = try place_reason(ctx, world, replica, chosen, need);
        try sc.put_place_decision(ctx, &batch, replica, reason, "place_replica");
        const key = try assign_key(ctx, name, replica.rec.id);
        const value: records.Assigned = .{
            .replica = replica.rec.id,
            .service = replica.rec.service,
            .requests = need,
            .reason = reason,
        };
        batch.put(key, try records.encode(ctx.arena, value, ctx.diag));
        const after = add(view.allocated, need);
        try put_allocation(ctx, &batch, name, after, view.count + 1, view.node.kv.mod_revision);
        const revision = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        try adopt_assign(ctx, world, chosen.index, key, replica, need, after, revision);
        sc.forget_hold(replica.rec.id);
    }

    /// The decision of a placement: caused by the replica's creation if it can be found, else by
    /// the replica as it is now.
    fn put_place_decision(
        sc: *Scheduler,
        ctx: *const Context,
        batch: *Batch,
        replica: *const Entry(records.Replica),
        reason: []const u8,
        action: []const u8,
    ) Error!void {
        const created = try create_decision_of(ctx, replica.rec.id);
        const cause: records.Cause = if (created) |*id| controller.cause_decision(id) else .{
            .kind = .desired,
            .key = replica.kv.key,
            .revision = replica.kv.mod_revision,
        };
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = action,
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = cause,
        }, batch);
    }

    /// No node fits: writes `hold_pending` once per change in what the evidence says.
    fn hold(
        sc: *Scheduler,
        ctx: *const Context,
        world: *const World,
        pass: *Pass,
        replica: *const Entry(records.Replica),
        verdicts: []const Verdict,
    ) Error!void {
        const need = requests_of(&replica.rec);
        const evidence = try evidence_of(ctx, world, need, verdicts);
        const evidence_hash = std.hash.Wyhash.hash(0, evidence);
        const slot = sc.hold_slot(replica.rec.id);
        if (sc.holds[slot].replica == hold_key(replica.rec.id)) {
            if (sc.holds[slot].evidence == evidence_hash) return;
        }
        if (!pass.budget()) return;
        var batch: Batch = .{};
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        const reason = try hold_reason(ctx, world, need, verdicts);
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = "hold_pending",
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = .{
                .kind = .desired,
                .key = replica.kv.key,
                .revision = replica.kv.mod_revision,
            },
            .cause_evidence = .{ .text = evidence },
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        sc.holds[slot] = .{ .replica = hold_key(replica.rec.id), .evidence = evidence_hash };
    }

    fn hold_key(replica: []const u8) u64 {
        return std.hash.Wyhash.hash(0, replica) | 1;
    }

    /// The slot holding `replica`, else a free one, else the oldest (the memory is a ring).
    fn hold_slot(sc: *Scheduler, replica: []const u8) usize {
        const wanted = hold_key(replica);
        var free: ?usize = null;
        for (sc.holds, 0..) |held, index| {
            if (held.replica == wanted) return index;
            if (held.replica == 0 and free == null) free = index;
        }
        if (free) |index| return index;
        const index = sc.holds_next;
        sc.holds_next = (sc.holds_next + 1) % hold_memory_max;
        return index;
    }

    fn forget_hold(sc: *Scheduler, replica: []const u8) void {
        const wanted = hold_key(replica);
        for (&sc.holds) |*held| {
            if (held.replica == wanted) held.* = .{ .replica = 0, .evidence = 0 };
        }
    }

    // ---- Move ----

    /// Moves an assigned replica to `spec.to` in one transaction: releases it on the old node and
    /// places it on the new, under the eight compares of `compare_sets.move`. Nothing in C1 asks
    /// for a move until slice 4 (a lost node); the transaction is built and tested here.
    pub fn move_replica(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        spec: MoveSpec,
    ) Error!MoveResult {
        const replica_index = world.desired.get(spec.replica).?; // The caller read the world.
        const from_index = world.assigned_by.get(spec.replica).?; // A replica to move is assigned.
        const replica = &world.replicas[replica_index];
        const from = world.assigns.items[from_index];
        const to_node = world.node_index(spec.to) orelse return .{ .refused = .{
            .reason = .unknown_node,
        } };
        const need = from.requests;
        const target = &world.nodes[to_node];
        const verdict = judge(target, need);
        if (verdict.reason != .fits) return .{ .refused = verdict };
        assert(from.node != to_node);
        if (from.node == no_node) return .{ .refused = .{ .reason = .unaccounted } };
        const source = &world.nodes[from.node];
        if (source.alloc_revision == 0) return .{ .refused = .{ .reason = .unaccounted } };
        const source_after = subtract(source, need) orelse return .{
            .refused = .{ .reason = .unaccounted },
        };
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        const read: compare_sets.Source = .{
            .node = source.node.rec.name,
            .assigned_revision = from.revision,
            .allocation_revision = source.alloc_revision,
        };
        compare_sets.move(&set, replica_read(replica), read, node_read(target));
        expect_all(&batch, &set);
        try sc.put_place_decision(ctx, &batch, replica, spec.reason, "place_replica");
        batch.delete(from.key);
        const name = target.node.rec.name;
        const key = try assign_key(ctx, name, spec.replica);
        const value: records.Assigned = .{
            .replica = spec.replica,
            .service = replica.rec.service,
            .requests = need,
            .reason = spec.reason,
        };
        batch.put(key, try records.encode(ctx.arena, value, ctx.diag));
        const target_after = add(target.allocated, need);
        try put_moved_allocations(ctx, &batch, source, source_after, target, target_after);
        const done = try controller.commit(ctx, .scheduler, &batch);
        const revision = switch (done) {
            .conflict => return .conflict,
            .applied => |revision| revision,
        };
        forget_assign(world, from_index, source_after, revision);
        try adopt_assign(ctx, world, to_node, key, replica, need, target_after, revision);
        return .moved;
    }
};

/// The two allocation records a move rewrites: one replica fewer on the source, one more on the
/// target, each compared against the revision read.
fn put_moved_allocations(
    ctx: *const Context,
    batch: *Batch,
    source: *const NodeView,
    source_after: Requests,
    target: *const NodeView,
    target_after: Requests,
) Error!void {
    const from_name = source.node.rec.name;
    const count = source.count - 1;
    try put_allocation(ctx, batch, from_name, source_after, count, source.alloc_node_revision);
    const to_name = target.node.rec.name;
    const to_revision = target.node.kv.mod_revision;
    try put_allocation(ctx, batch, to_name, target_after, target.count + 1, to_revision);
}

pub const MoveSpec = struct {
    replica: []const u8,
    to: []const u8,
    reason: []const u8,
};

pub const MoveResult = union(enum) {
    moved,
    /// A compared key moved: plan again from a fresh read.
    conflict,
    /// The target cannot take the replica, or the source has nothing to release from.
    refused: Verdict,
};

// ---- Keeping the world current after a commit ------------------------------------------------

fn add(allocated: Requests, need: Requests) Requests {
    return .{
        .cpu_millis = allocated.cpu_millis + need.cpu_millis,
        .memory_bytes = allocated.memory_bytes + need.memory_bytes,
    };
}

/// The allocation after releasing `need`, or null if the record could not contain it (an
/// accounting defect the auditor reports, never one the scheduler papers over).
fn subtract(view: *const NodeView, need: Requests) ?Requests {
    if (view.count == 0) return null;
    if (view.allocated.cpu_millis < need.cpu_millis) return null;
    if (view.allocated.memory_bytes < need.memory_bytes) return null;
    return .{
        .cpu_millis = view.allocated.cpu_millis - need.cpu_millis,
        .memory_bytes = view.allocated.memory_bytes - need.memory_bytes,
    };
}

fn world_note(view: *NodeView, allocated: Requests, count: u32, revision: Revision) void {
    view.allocated = allocated;
    view.count = count;
    view.alloc_revision = revision;
}

fn forget_assign(world: *World, index: u32, allocated: Requests, revision: Revision) void {
    const assign = &world.assigns.items[index];
    assert(assign.live);
    const view = &world.nodes[assign.node];
    world_note(view, allocated, view.count - 1, revision);
    assign.live = false;
    _ = world.assigned_by.remove(assign.replica);
}

fn adopt_assign(
    ctx: *const Context,
    world: *World,
    node: u32,
    key: []const u8,
    replica: *const Entry(records.Replica),
    need: Requests,
    allocated: Requests,
    revision: Revision,
) Error!void {
    const view = &world.nodes[node];
    world_note(view, allocated, view.count + 1, revision);
    view.alloc_node_revision = view.node.kv.mod_revision;
    try add_assign(ctx, world, .{
        .key = key,
        .node = node,
        .replica = replica.rec.id,
        .service = replica.rec.service,
        .requests = need,
        .revision = revision,
        .live = true,
    });
}

fn replica_read(replica: *const Entry(records.Replica)) compare_sets.ReplicaRead {
    return .{
        .service = replica.rec.service,
        .replica = replica.rec.id,
        .replica_revision = replica.kv.mod_revision,
    };
}

fn node_read(view: *const NodeView) compare_sets.NodeRead {
    return .{
        .node = view.node.rec.name,
        .node_revision = view.node.kv.mod_revision,
        .status_revision = view.status_revision,
        .allocation_revision = view.alloc_revision,
    };
}

fn expect_all(batch: *Batch, set: *compare_sets.Set) void {
    for (set.compares()) |compare| batch.expect(compare.key, compare.mod_revision);
}

fn assign_key(ctx: *const Context, node: []const u8, replica: []const u8) Error![]const u8 {
    const key = records.assigned_key(node, replica);
    return controller.key_copy(ctx, &key);
}

fn put_allocation(
    ctx: *const Context,
    batch: *Batch,
    node: []const u8,
    allocated: Requests,
    count: u32,
    node_revision: u64,
) Error!void {
    const value: records.Allocation = .{
        .allocated = allocated,
        .count = count,
        .node_revision = node_revision,
    };
    const key = records.allocation_key(node);
    const bytes = try records.encode(ctx.arena, value, ctx.diag);
    batch.put(try controller.key_copy(ctx, &key), bytes);
}

fn mib_of(bytes: u64) u64 {
    return @divFloor(bytes, 1024 * 1024);
}

// ---- Words -----------------------------------------------------------------------------------

fn place_reason(
    ctx: *const Context,
    world: *const World,
    replica: *const Entry(records.Replica),
    chosen: Chosen,
    need: Requests,
) Error![]const u8 {
    const name = world.nodes[chosen.index].node.rec.name;
    const defaulted = replica.rec.limits.cpu_millis == null or
        replica.rec.limits.memory_bytes == null;
    const note = if (defaulted) " (a default: the service sets no limits)" else "";
    const total: u32 = @intCast(world.nodes.len);
    if (total == 1) {
        return controller.format(ctx, "{s} is the only node, and it fits {d}m CPU and {d} " ++
            "MiB{s}", .{ name, need.cpu_millis, mib_of(need.memory_bytes), note });
    }
    return controller.format(ctx, "{s} is the best of the {d} of {d} nodes that fit {d}m CPU " ++
        "and {d} MiB{s}: {d} replicas of this service there, then least allocated, then name", .{
        name,
        chosen.candidates,
        total,
        need.cpu_millis,
        mib_of(need.memory_bytes),
        note,
        chosen.service_count,
    });
}

fn hold_reason(
    ctx: *const Context,
    world: *const World,
    need: Requests,
    verdicts: []const Verdict,
) Error![]const u8 {
    var short: u32 = 0;
    for (verdicts) |verdict| {
        if (verdict.reason == .short) short += 1;
    }
    const total: u32 = @intCast(world.nodes.len);
    const excluded = total - short;
    return controller.format(ctx, "no node fits {d}m CPU and {d} MiB: {d} of {d} nodes lack " ++
        "the room, {d} are excluded", .{
        need.cpu_millis, mib_of(need.memory_bytes), short, total, excluded,
    });
}

const exclusions = [_]Reason{
    .unknown_node, .lost,       .fenced,        .no_status,
    .older_tenure, .audit_open, .over_capacity,
};

/// Room kept free in the evidence for the closing brackets and the `omitted` count.
const evidence_reserve: u32 = 40;

const Evidence = struct {
    bytes: [constants.decision_evidence_bytes_max]u8 = undefined,
    len: u32 = 0,
    omitted: u32 = 0,

    /// Appends `piece` if it fits ahead of the reserve; otherwise counts one omitted node.
    fn append(e: *Evidence, text: []const u8) bool {
        if (e.len + text.len + evidence_reserve > e.bytes.len) return false;
        @memcpy(e.bytes[e.len..][0..text.len], text);
        e.len += @intCast(text.len);
        return true;
    }

    fn literal(e: *Evidence, text: []const u8) void {
        assert(e.len + text.len <= e.bytes.len);
        @memcpy(e.bytes[e.len..][0..text.len], text);
        e.len += @intCast(text.len);
    }

    fn piece(e: *Evidence, comptime text: []const u8, args: anytype) bool {
        var buffer: [96]u8 = undefined;
        const out = std.fmt.bufPrint(&buffer, text, args) catch return false;
        return e.append(out);
    }
};

/// The shortfall of every node, as compact JSON of at most `decision_evidence_bytes_max` bytes:
/// what the replica needs, the excluded nodes by reason, and by how much each node that lacks
/// room is short. A node that does not fit in the bound is counted in `omitted`.
fn evidence_of(
    ctx: *const Context,
    world: *const World,
    need: Requests,
    verdicts: []const Verdict,
) Error![]const u8 {
    assert(verdicts.len == world.nodes.len);
    var e: Evidence = .{};
    const opened = e.piece("{{\"need\":{{\"cpu_millis\":{d},\"memory_bytes\":{d}}}", .{
        need.cpu_millis, need.memory_bytes,
    });
    assert(opened); // The head is fixed-size and far below the bound.
    for (exclusions) |reason| write_excluded(&e, world, verdicts, reason);
    write_short(&e, world, verdicts, "cpu_short");
    write_short(&e, world, verdicts, "memory_short");
    if (e.omitted > 0) {
        var buffer: [32]u8 = undefined;
        // 32 bytes hold `,"omitted":` and a u32.
        const text = std.fmt.bufPrint(&buffer, ",\"omitted\":{d}", .{e.omitted}) catch unreachable;
        e.literal(text);
    }
    e.literal("}");
    return ctx.arena.dupe(u8, e.bytes[0..e.len]) catch failures.no_memory(ctx.diag);
}

fn write_excluded(
    e: *Evidence,
    world: *const World,
    verdicts: []const Verdict,
    reason: Reason,
) void {
    var first = true;
    for (verdicts, world.nodes) |verdict, view| {
        if (verdict.reason != reason) continue;
        const name = view.node.rec.name;
        if (first) {
            if (!e.piece(",\"{s}\":[", .{@tagName(reason)})) {
                e.omitted += 1;
                continue;
            }
            first = false;
        }
        const comma: []const u8 = if (e.bytes[e.len - 1] == '[') "" else ",";
        if (!e.piece("{s}\"{s}\"", .{ comma, name })) e.omitted += 1;
    }
    if (!first) e.literal("]");
}

fn write_short(
    e: *Evidence,
    world: *const World,
    verdicts: []const Verdict,
    comptime key: []const u8,
) void {
    var first = true;
    for (verdicts, world.nodes) |verdict, view| {
        if (verdict.reason != .short) continue;
        const cpu = comptime std.mem.eql(u8, key, "cpu_short");
        const by = if (cpu) verdict.cpu_by else verdict.memory_by;
        if (by == 0) continue;
        if (first) {
            if (!e.piece(",\"" ++ key ++ "\":{{", .{})) {
                e.omitted += 1;
                continue;
            }
            first = false;
        }
        const comma: []const u8 = if (e.bytes[e.len - 1] == '{') "" else ",";
        if (!e.piece("{s}\"{s}\":{d}", .{ comma, view.node.rec.name, by })) e.omitted += 1;
    }
    if (!first) e.literal("}");
}

/// The id of the decision that created a replica, read from its by-subject index.
fn create_decision_of(ctx: *const Context, replica: []const u8) Error!?records.DecisionId {
    const prefix = records.index_prefix(.replica, replica);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = 8,
    }, ctx.diag);
    for (page.kvs) |kv| {
        const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
        if (!std.mem.eql(u8, entry.action, "create_replica")) continue;
        if (entry.id.len != records.decision_id_bytes) continue;
        var id: records.DecisionId = .{};
        @memcpy(&id.bytes, entry.id);
        return id;
    }
    return null;
}

// ---- I6 as a check ---------------------------------------------------------------------------

pub const Mismatch = struct {
    node: []const u8,
    recorded: records.Tally,
    reconstructed: records.Tally,
};

/// Reconstructs every node's allocation from its assignments and compares it with the record
/// (authority.md I6), both read at one revision. Returns the first node that disagrees, or null.
/// The auditor and the simulations run the same reconstruction.
pub fn find_mismatch(ctx: *const Context) Error!?Mismatch {
    const assigned = try controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        null,
        constants.replicas_max,
    );
    const allocations = try controller.list_all(
        records.Allocation,
        ctx,
        records.prefix_allocations,
        assigned.revision,
        constants.nodes_max,
    );
    var sums: [constants.nodes_max]records.Tally = undefined;
    var names: [constants.nodes_max][]const u8 = undefined;
    var seen: u32 = 0;
    for (assigned.items) |entry| {
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const node = rest[0..std.mem.indexOfScalar(u8, rest, '/').?];
        const slot = for (names[0..seen], 0..) |name, index| {
            if (std.mem.eql(u8, name, node)) break index;
        } else blk: {
            if (seen == constants.nodes_max) return failures.no_memory(ctx.diag);
            names[seen] = node;
            sums[seen] = .{ .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 }, .count = 0 };
            seen += 1;
            break :blk seen - 1;
        };
        sums[slot] = .{
            .allocated = add(sums[slot].allocated, entry.rec.requests),
            .count = sums[slot].count + 1,
        };
    }
    return mismatch_in(names[0..seen], sums[0..seen], allocations.items);
}

fn mismatch_in(
    names: []const []const u8,
    sums: []const records.Tally,
    allocations: []const Entry(records.Allocation),
) ?Mismatch {
    const zero: records.Tally = .{
        .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 },
        .count = 0,
    };
    for (allocations) |entry| {
        const node = entry.kv.key[records.prefix_allocations.len..];
        var rebuilt = zero;
        for (names, sums) |name, sum| {
            if (std.mem.eql(u8, name, node)) rebuilt = sum;
        }
        const recorded: records.Tally = .{
            .allocated = entry.rec.allocated,
            .count = entry.rec.count,
        };
        if (!tally_equal(recorded, rebuilt)) return .{
            .node = node,
            .recorded = recorded,
            .reconstructed = rebuilt,
        };
    }
    for (names, sums) |name, sum| {
        const key = records.allocation_key(name);
        if (find_by_key(records.Allocation, allocations, key.slice()) != null) continue;
        return .{ .node = name, .recorded = zero, .reconstructed = sum };
    }
    return null;
}

fn tally_equal(first: records.Tally, second: records.Tally) bool {
    if (first.count != second.count) return false;
    if (first.allocated.cpu_millis != second.allocated.cpu_millis) return false;
    return first.allocated.memory_bytes == second.allocated.memory_bytes;
}
