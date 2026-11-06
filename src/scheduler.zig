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
//! A lost node's replicas are not moved: the replica controller replaces each under a new id once
//! `lost_grace_ms` has passed (authority.md §3), and this scheduler releases the old assignment
//! like any retired replica's. `move_replica` is built and tested for the moves that keep an id
//! (rebalancing, C7's fenced stateful replicas); nothing calls it yet. `/services/` is not read,
//! so the replica of a deleted service is placed and then released.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const compare_sets = @import("compare_sets.zig");
const accounting = @import("allocations.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const chunk_summary = @import("chunk_summary.zig");
const failures = @import("store_failures.zig");
const node_store = @import("node_store.zig");
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
/// reason. A restart forgets them and writes each hold once more. One slot for every replica and
/// every run there can be: with fewer, a pass over more held subjects than slots would miss every
/// time, rewrite every hold and never converge.
pub const hold_memory_max: u32 = constants.replicas_max + constants.jobs_max;

comptime {
    assert(hold_memory_max >= constants.replicas_max + constants.jobs_max);
    // The largest compare set and the summary compare of the one decision in the transaction.
    const compares = compare_sets.set_max + controller.decision_compares;
    assert(compares <= constants.store_txn_compares_max);
    assert(controller.decision_ops + 4 <= constants.store_txn_ops_max); // A move's writes.
}

pub const watch_prefixes = [_][]const u8{
    records.prefix_replicas,
    records.prefix_assigned,
    records.prefix_nodes,
    records.prefix_node_status,
    records.prefix_allocations,
    records.prefix_audit_allocations,
    records.prefix_job_runs,
    records.prefix_job_status,
};

/// What the scheduler resolves a replica to need: its limits, else the default.
pub fn requests_of(replica: *const records.Replica) Requests {
    return .{
        .cpu_millis = replica.limits.cpu_millis orelse constants.request_default_cpu_millis,
        .memory_bytes = replica.limits.memory_bytes orelse constants.request_default_memory_bytes,
    };
}

/// What the scheduler resolves a run to need: its limits, else the default.
pub fn run_requests_of(run: *const records.JobRun) Requests {
    return .{
        .cpu_millis = run.limits.cpu_millis orelse constants.request_default_cpu_millis,
        .memory_bytes = run.limits.memory_bytes orelse constants.request_default_memory_bytes,
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
    /// A move of a replica that has no `/replicas` record.
    unknown_replica,
    /// A move of a replica that is not assigned to any node.
    not_assigned,
    /// The node already holds `jobs_per_node_max` runs (a run waits `pending`, ZC-W0308).
    jobs_full,
    /// The node already holds `runtime_handles_max` assignments in all.
    handles_full,
    /// A move to the node the replica is already on.
    same_node,
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
    /// The revision of the node's `/audit-allocations` record (0: none), for L1.
    audit_revision: Revision,
    /// 0 for a node with no allocation record yet.
    alloc_revision: Revision,
    alloc_node_revision: u64,
    allocated: Requests,
    count: u32,
    /// Of `count`, the assignments that are runs (`<job>-job`), counted from `/assigned/`.
    jobs: u32,
    /// The `/node-store/<node>` the pass read: its revision (0 if the node has none) and the
    /// trees it advertises. Advisory evidence; never compared (authority.md section 2).
    store_revision: Revision,
    held: []const HeldSketch,
};

/// A tree of a node's summary, decoded once when the world is read. A tree whose sample does not
/// decode is left out: it scores 0.
const HeldSketch = struct { digest: []const u8, sketch: chunk_summary.Sketch };

const no_node: u32 = std.math.maxInt(u32);

/// The most nodes a world holds: every registered node, and the nodes that have a status or an
/// allocation record but no `/nodes` record (a lost node, whose assignments are released).
pub const views_max: u32 = 2 * constants.nodes_max;

const Assign = struct {
    key: []const u8,
    node: u32,
    replica: []const u8,
    service: []const u8,
    requests: Requests,
    revision: Revision,
    live: bool,
    /// A run: its `replica` is the run id and `service` is empty.
    job: bool = false,
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
    /// `/job-status/`, every retained job's, at the world's revision.
    job_statuses: []const Entry(records.JobStatus) = &.{},
    /// Job name -> index in `job_statuses`.
    job_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// `/node-store/` records the read left out because they did not decode or were newer.
    summaries_skipped: u32 = 0,

    fn job_status(world: *const World, job: []const u8) ?*const Entry(records.JobStatus) {
        const index = world.job_index.get(job) orelse return null;
        return &world.job_statuses[index];
    }

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
    const rec = records;
    const con = constants;
    const list = controller.list_all;
    const replicas = try list(rec.Replica, ctx, rec.prefix_replicas, null, con.replicas_max);
    const at = replicas.revision;
    const assigned = try list(rec.Assigned, ctx, rec.prefix_assigned, at, con.assigned_max);
    const job_statuses = try list(
        rec.JobStatus,
        ctx,
        rec.prefix_job_status,
        at,
        con.job_admitted_window_max,
    );
    const nodes = try list(rec.Node, ctx, rec.prefix_nodes, at, con.nodes_max);
    const statuses = try list(rec.NodeStatus, ctx, rec.prefix_node_status, at, con.nodes_max);
    const allocations = try list(rec.Allocation, ctx, rec.prefix_allocations, at, con.nodes_max);
    const audits = try list(rec.Audit, ctx, rec.prefix_audit_allocations, at, con.nodes_max);
    // Summaries are advisory: one that is malformed, or newer than this release reads, must not
    // stop every placement. It is skipped, counted, and its node scores 0 (authority.md section 2).
    var summaries_skipped: u32 = 0;
    const summaries = try controller.list_all_tolerant(
        records.NodeStore,
        ctx,
        records.prefix_node_store,
        at,
        constants.nodes_max,
        &summaries_skipped,
    );
    var world: World = .{
        .revision = at,
        .replicas = replicas.items,
        .nodes = try views_of(ctx, nodes.items, .{
            .statuses = statuses.items,
            .allocations = allocations.items,
            .audits = audits.items,
            .summaries = summaries.items,
        }),
        .assigns = .empty,
        .assigned_by = .empty,
        .desired = .empty,
        .summaries_skipped = summaries_skipped,
    };
    world.job_statuses = job_statuses.items;
    try index_replicas(ctx, &world);
    try index_jobs(ctx, &world);
    try index_assigned(ctx, &world, assigned.items);
    return world;
}

/// The per-node records a view is made from.
const Sources = struct {
    statuses: []const Entry(records.NodeStatus),
    allocations: []const Entry(records.Allocation),
    audits: []const Entry(records.Audit),
    summaries: []const Entry(records.NodeStore),
};

fn views_of(
    ctx: *const Context,
    nodes: []const Entry(records.Node),
    sources: Sources,
) Error![]NodeView {
    const views = ctx.arena.alloc(NodeView, views_max) catch return failures.no_memory(ctx.diag);
    var count: u32 = 0;
    for (nodes) |*node| {
        views[count] = try view_of(ctx, node, sources);
        count += 1;
    }
    // A node with no `/nodes` record is named by its status or allocation record. Its view has
    // no capacity and tenure 0, so nothing fits on it, and the compare on `/nodes/<node>` at
    // revision 0 says "still absent".
    for (sources.statuses) |entry| {
        const name = entry.kv.key[records.prefix_node_status.len..];
        try add_ghost(ctx, views, &count, name, sources);
    }
    for (sources.allocations) |entry| {
        const name = entry.kv.key[records.prefix_allocations.len..];
        try add_ghost(ctx, views, &count, name, sources);
    }
    return views[0..count];
}

fn add_ghost(
    ctx: *const Context,
    views: []NodeView,
    count: *u32,
    name: []const u8,
    sources: Sources,
) Error!void {
    for (views[0..count.*]) |view| {
        if (std.mem.eql(u8, view.node.rec.name, name)) return;
    }
    // Bounded: statuses and allocations are written only for registered nodes, at most
    // `nodes_max` of each.
    if (count.* == views_max) return failures.no_memory(ctx.diag);
    const ghost = ctx.arena.create(Entry(records.Node)) catch return failures.no_memory(ctx.diag);
    const key = records.node_key(name);
    ghost.* = .{
        .kv = .{
            .key = try controller.key_copy(ctx, &key),
            .value = "",
            .create_revision = 0,
            .mod_revision = 0,
        },
        .rec = .{ .name = name, .capacity = .{ .cpu_millis = 0, .memory_bytes = 0 } },
    };
    views[count.*] = try view_of(ctx, ghost, sources);
    count.* += 1;
}

fn view_of(
    ctx: *const Context,
    node: *const Entry(records.Node),
    sources: Sources,
) Error!NodeView {
    const name = node.rec.name;
    const statuses = sources.statuses;
    const allocations = sources.allocations;
    const audits = sources.audits;
    const summary_key = records.node_store_key(name);
    const summary = find_by_key(records.NodeStore, sources.summaries, summary_key.slice());
    const status_key = records.node_status_key(name);
    const status = find_by_key(records.NodeStatus, statuses, status_key.slice());
    const alloc_key = records.allocation_key(name);
    const alloc = find_by_key(records.Allocation, allocations, alloc_key.slice());
    const audit = find_by_key(records.Audit, audits, records.audit_key(name).slice());
    return .{
        .node = node,
        .status = if (status) |found| found.rec else null,
        .status_revision = if (status) |found| found.kv.mod_revision else 0,
        .audit_open = audit != null,
        .audit_revision = if (audit) |found| found.kv.mod_revision else 0,
        .alloc_revision = if (alloc) |found| found.kv.mod_revision else 0,
        .alloc_node_revision = if (alloc) |found| found.rec.node_revision else 0,
        .allocated = if (alloc) |found| found.rec.allocated else .{
            .cpu_millis = 0,
            .memory_bytes = 0,
        },
        .count = if (alloc) |found| found.rec.count else 0,
        .jobs = 0,
        .store_revision = if (summary) |found| found.kv.mod_revision else 0,
        .held = if (summary) |found| try decode_held(ctx, found.rec.trees) else &.{},
    };
}

/// The sketches of a summary's trees, decoded once per pass; a tree that does not decode is
/// skipped.
fn decode_held(ctx: *const Context, trees: []const records.HeldTree) Error![]const HeldSketch {
    const held = ctx.arena.alloc(HeldSketch, @min(trees.len, constants.summary_trees_max)) catch
        return failures.no_memory(ctx.diag);
    var count: usize = 0;
    for (trees) |tree| {
        if (count == held.len) break;
        const sketch = node_store.sketch_of(tree) orelse continue;
        held[count] = .{ .digest = tree.tree, .sketch = sketch };
        count += 1;
    }
    return held[0..count];
}

fn index_replicas(ctx: *const Context, world: *World) Error!void {
    for (world.replicas, 0..) |*replica, index| {
        world.desired.put(ctx.arena, replica.rec.id, @intCast(index)) catch
            return failures.no_memory(ctx.diag);
    }
}

fn index_jobs(ctx: *const Context, world: *World) Error!void {
    for (world.job_statuses, 0..) |*status, index| {
        const name = status.kv.key[records.prefix_job_status.len..];
        world.job_index.put(ctx.arena, name, @intCast(index)) catch
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
            .job = entry.rec.job != null,
        });
        if (entry.rec.job != null and node != no_node) world.nodes[node].jobs += 1;
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
fn judge(view: *const NodeView, need: Requests, is_run: bool) Verdict {
    const status = view.status orelse return .{ .reason = .no_status };
    switch (status.state) {
        .lost => return .{ .reason = .lost },
        .fenced => return .{ .reason = .fenced },
        .ready => {},
    }
    if (status.tenure != view.node.kv.mod_revision) return .{ .reason = .older_tenure };
    if (view.audit_open) return .{ .reason = .audit_open };
    if (view.count >= constants.runtime_handles_max) return .{ .reason = .handles_full };
    if (is_run and view.jobs >= constants.jobs_per_node_max) return .{ .reason = .jobs_full };
    const capacity = view.node.rec.capacity;
    if (view.allocated.cpu_millis > capacity.cpu_millis) return .{ .reason = .over_capacity };
    if (view.allocated.memory_bytes > capacity.memory_bytes) return .{ .reason = .over_capacity };
    const cpu_after = @as(u64, view.allocated.cpu_millis) + need.cpu_millis;
    const cpu_by = cpu_after -| capacity.cpu_millis;
    // A request near the top of u64 overflows the sum: that is short on memory by "everything".
    const memory_by = if (std.math.add(u64, view.allocated.memory_bytes, need.memory_bytes)) |sum|
        sum -| capacity.memory_bytes
    else |_|
        std.math.maxInt(u64);
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

/// Whether node `first` is a better home than `second`: fewest assignments of the same service
/// (spread), then the most bytes of the replica's image already held (locality), then least
/// allocated (CPU, then memory, as a fraction of capacity), then the lower name. Fit is decided
/// before: only nodes that fit are compared.
fn precedes(world: *const World, rank: Rank, first: u32, second: u32) bool {
    // The teeth fault: locality ahead of spread (a build whose root switched it on).
    if (c1_teeth.locality_before_spread and rank.locality[first] != rank.locality[second]) {
        return rank.locality[first] > rank.locality[second];
    }
    if (rank.counts[first] != rank.counts[second]) return rank.counts[first] < rank.counts[second];
    if (rank.locality[first] != rank.locality[second]) {
        return rank.locality[first] > rank.locality[second];
    }
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

/// What `precedes` ranks by, per node index.
const Rank = struct {
    counts: []const u32,
    locality: []const u64,
};

/// Bytes of `image`'s tree each node holds by its summary. The tree's sketch is taken from the
/// first node whose summary lists the tree: a tree no node holds scores 0 everywhere, because the
/// scheduler has no other source of a tree's chunks (docs/swarm.md, limits). A summary that does
/// not decode scores 0.
fn locality_of(world: *const World, image: []const u8, out: []u64) void {
    assert(out.len == world.nodes.len);
    @memset(out, 0);
    var target: ?*const chunk_summary.Sketch = null;
    for (world.nodes) |*view| {
        for (view.held) |*tree| {
            if (!std.mem.eql(u8, tree.digest, image)) continue;
            target = &tree.sketch;
            break;
        }
        if (target != null) break;
    }
    const wanted = target orelse return;
    for (world.nodes, out) |*view, *slot| {
        var held: [constants.summary_trees_max]chunk_summary.Sketch = undefined;
        for (view.held, 0..) |tree, index| held[index] = tree.sketch;
        slot.* = chunk_summary.locality_bytes(wanted, held[0..view.held.len]);
    }
}

/// Compares `used_a / cap_a` with `used_b / cap_b` without dividing.
fn fraction_order(used_a: u64, cap_a: u64, used_b: u64, cap_b: u64) std.math.Order {
    const left = @as(u128, used_a) * cap_b;
    const right = @as(u128, used_b) * cap_a;
    return std.math.order(left, right);
}

/// What a placement decision records of the locality step (Decision v3).
const Placed = struct { locality_bytes: u64, store_revision: Revision, read_revision: Revision };

const Chosen = struct {
    index: u32,
    candidates: u32,
    service_count: u32,
    /// Bytes of the replica's image the node holds by its summary, and the revision of the
    /// summary read (0 if it has none).
    locality_bytes: u64,
    store_revision: Revision,
};

fn choose(
    world: *const World,
    service: []const u8,
    image: []const u8,
    verdicts: []const Verdict,
) ?Chosen {
    assert(verdicts.len == world.nodes.len);
    var counts: [views_max]u32 = undefined;
    service_counts(world, service, counts[0..world.nodes.len]);
    var locality: [views_max]u64 = undefined;
    locality_of(world, image, locality[0..world.nodes.len]);
    const rank: Rank = .{
        .counts = counts[0..world.nodes.len],
        .locality = locality[0..world.nodes.len],
    };
    var best: ?u32 = null;
    var candidates: u32 = 0;
    for (verdicts, 0..) |verdict, index| {
        if (verdict.reason != .fits) continue;
        candidates += 1;
        const at: u32 = @intCast(index);
        if (best == null or precedes(world, rank, at, best.?)) best = at;
    }
    const index = best orelse return null;
    return .{
        .index = index,
        .candidates = candidates,
        .service_count = counts[index],
        .locality_bytes = locality[index],
        .store_revision = world.nodes[index].store_revision,
    };
}

// ---- The scheduler ---------------------------------------------------------------------------

const Hold = struct { replica: u64, evidence: u64 };

/// What a hold is about: a replica, or a run (whose status is compared too).
const Held = struct {
    kind: records.SubjectKind,
    /// The replica id or run id: the key of the hold memory.
    id: []const u8,
    /// The decision's subject name when it is not `id` (a job's name, not its run id).
    name: ?[]const u8 = null,
    key: []const u8,
    revision: Revision,
    status_key: ?[]const u8 = null,
    status_revision: Revision = 0,
};

/// The run a placement is for, as read.
const RunTarget = struct {
    job: []const u8,
    run_id: []const u8,
    run_kv: store.KeyValue,
    status: *const Entry(records.JobStatus),
};

/// A member of a node's assignments, as the world records it.
const Member = struct { id: []const u8, service: []const u8, job: bool = false };

/// The words of a placement reason that differ between a replica and a run.
const PlaceWords = struct { note: []const u8, group: []const u8 };

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

/// What a release is: the decision's action and subject, and for a run the revision of the job's
/// status that was read (0: there is none), which the release compares.
const ReleaseAs = struct {
    action: []const u8,
    subject: records.Subject,
    status_revision: ?Revision = null,
};

const ReleaseWhy = struct { cause: records.Cause, reason: []const u8 };

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
        try sc.sweep_holds(ctx, world);
        var index: u32 = 0;
        while (index < world.assigns.items.len and !pass.stopped) : (index += 1) {
            try sc.release_one(ctx, world, &pass, index);
        }
        for (0..world.replicas.len) |replica| {
            if (pass.stopped) break;
            try sc.place_one(ctx, world, &pass, @intCast(replica));
        }
        for (0..world.job_statuses.len) |status| {
            if (pass.stopped) break;
            try sc.place_run(ctx, world, &pass, @intCast(status));
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
        if (!assign.live) return;
        if (assign.job) return sc.release_run(ctx, world, pass, index);
        if (world.desired.contains(assign.replica)) return;
        if (assign.node == no_node) return; // No record names the node: nothing to release from.
        const view = &world.nodes[assign.node];
        if (view.alloc_revision == 0) return; // Unaccounted: the auditor's finding, not ours.
        if (subtract(view, assign.requests) == null) return;
        if (!pass.budget()) return;
        // The replica controller's `stop_replica` (scale down), `delete_replica` or
        // `mark_replica_lost` (a replacement) retired it, if its decision is still indexed; else
        // only a pass found it gone, and the store does not say at which revision.
        const stopped = try indexed_decision(ctx, assign.replica, "stop_replica", .last);
        const deleted = stopped orelse
            try indexed_decision(ctx, assign.replica, "delete_replica", .last);
        const retired = deleted orelse
            try indexed_decision(ctx, assign.replica, "mark_replica_lost", .last);
        const cause: records.Cause = if (retired) |*id| controller.cause_decision(id) else .{
            .kind = .resync,
        };
        const fmt = "replica {s} is gone; its {d}m CPU and {d} MiB on {s} are released";
        const reason = try controller.format(ctx, fmt, .{
            assign.replica,
            assign.requests.cpu_millis,
            mib_of(assign.requests.memory_bytes),
            view.node.rec.name,
        });
        const as: ReleaseAs = .{
            .action = "release_replica",
            .subject = .{ .kind = .replica, .name = assign.replica },
        };
        try sc.commit_release(ctx, world, pass, index, as, .{ .cause = cause, .reason = reason });
    }

    /// Releases a run whose job is over (its status terminal) or gone (no `/jobs/<name>` and no
    /// status): the job controller's terminal status is what frees the node, and retention's
    /// delete of the job is what frees a node whose run was never ended. A run whose job still
    /// has a non-terminal status keeps its node, gone job or not, and so does a run whose job is
    /// live with its run and status missing: that is the job controller's contradiction hold, and
    /// nothing about the workload changes.
    fn release_run(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        index: u32,
    ) Error!void {
        const assign = world.assigns.items[index];
        const job = records.job_of_run(assign.replica) orelse return;
        const status = world.job_status(job);
        if (status) |found| {
            if (!records.job_state_terminal(found.rec.state)) return;
        } else if (try Scheduler.job_record_exists(ctx, world, job)) {
            // A live job without a status is the job controller's contradiction (ZC-E0307):
            // its workload may be live, and nothing about it changes.
            return;
        }
        if (assign.node == no_node) return;
        const view = &world.nodes[assign.node];
        if (view.alloc_revision == 0) return;
        if (subtract(view, assign.requests) == null) return;
        if (!pass.budget()) return;
        var cause: records.Cause = .{ .kind = .resync };
        if (status) |found| {
            const text = found.rec.decision orelse "";
            if (text.len == records.decision_id_bytes) cause = .{ .kind = .decision, .id = text };
        }
        const why = if (status == null) "its job is gone" else "its job has ended";
        const fmt = "run {s} is over ({s}); its {d}m CPU and {d} MiB on {s} are released";
        const reason = try controller.format(ctx, fmt, .{
            assign.replica,
            why,
            assign.requests.cpu_millis,
            mib_of(assign.requests.memory_bytes),
            view.node.rec.name,
        });
        const as: ReleaseAs = .{
            .action = "release_run",
            .subject = .{ .kind = .job, .name = job },
            .status_revision = if (status) |found| found.kv.mod_revision else 0,
        };
        try sc.commit_release(ctx, world, pass, index, as, .{ .cause = cause, .reason = reason });
    }

    fn job_record_exists(ctx: *const Context, world: *const World, job: []const u8) Error!bool {
        const key = records.job_key(job);
        const got = try ctx.store.get(ctx.arena, key.slice(), world.revision, ctx.diag);
        return got.kv != null;
    }

    /// Releases assignment `index`: its decision, the assignment deleted and the allocation
    /// lowered, under the release compares.
    fn commit_release(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        index: u32,
        as: ReleaseAs,
        why: ReleaseWhy,
    ) Error!void {
        const assign = world.assigns.items[index];
        const view = &world.nodes[assign.node];
        const after = subtract(view, assign.requests).?;
        const name = view.node.rec.name;
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        if (as.status_revision) |status_revision| {
            const reads: compare_sets.ReleaseRead = .{
                .assigned_revision = assign.revision,
                .allocation_revision = view.alloc_revision,
                .status_revision = status_revision,
            };
            compare_sets.release_run(&set, name, assign.replica, as.subject.name, reads);
        } else {
            const alloc = view.alloc_revision;
            compare_sets.release(&set, name, assign.replica, assign.revision, alloc);
        }
        expect_all(&batch, &set);
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = as.action,
            .subject = as.subject,
            .reason = why.reason,
            .cause = why.cause,
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
        var verdicts: [views_max]Verdict = undefined;
        const judged = verdicts[0..world.nodes.len];
        for (world.nodes, judged) |*view, *verdict| verdict.* = judge(view, need, false);
        const chosen = choose(world, replica.rec.service, replica.rec.image, judged) orelse {
            const subject: Held = .{
                .kind = .replica,
                .id = replica.rec.id,
                .key = replica.kv.key,
                .revision = replica.kv.mod_revision,
            };
            return sc.hold(ctx, world, pass, subject, need, judged);
        };
        if (!pass.budget()) return;
        const view = &world.nodes[chosen.index];
        const name = view.node.rec.name;
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        compare_sets.placement(&set, replica_read(replica), node_read(view));
        expect_placement(&batch, &set);
        const defaulted = replica.rec.limits.cpu_millis == null or
            replica.rec.limits.memory_bytes == null;
        const words: PlaceWords = .{
            .note = if (defaulted) " (a default: the service sets no limits)" else "",
            .group = "replicas of this service",
        };
        const reason = try place_reason(ctx, world, words, chosen, need);
        const evidence: Placed = .{
            .locality_bytes = chosen.locality_bytes,
            .store_revision = chosen.store_revision,
            .read_revision = world.revision,
        };
        try sc.put_place_decision(ctx, &batch, replica, reason, "place_replica", null, evidence);
        const key = try assign_key(ctx, name, replica.rec.id);
        const value = records.assigned_replica(
            replica.rec.id,
            replica.rec.service,
            need,
            reason,
        );
        batch.put(key, try records.encode(ctx.arena, value, ctx.diag));
        const after = add(view.allocated, need);
        try put_allocation(ctx, &batch, name, after, view.count + 1, view.node.kv.mod_revision);
        const revision = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        const member: Member = .{ .id = replica.rec.id, .service = replica.rec.service };
        try adopt_assign(ctx, world, chosen.index, key, member, need, after, revision);
        sc.forget_hold(replica.rec.id);
    }

    /// Places the run of a job whose status is not terminal and which no node holds. The run is
    /// read at the world's revision and compared with the status: a run stopped since, or a job
    /// that ended since, fails the transaction and the next pass looks again.
    fn place_run(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        status_index: u32,
    ) Error!void {
        const status = &world.job_statuses[status_index];
        if (records.job_state_terminal(status.rec.state)) return;
        const job = status.kv.key[records.prefix_job_status.len..];
        if (records.name_problem(job, constants.service_name_bytes_max) != null) return;
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const run_id = ctx.arena.dupe(u8, records.job_run_id(&buffer, job)) catch
            return failures.no_memory(ctx.diag);
        const assigned = world.assigned_by.contains(run_id);
        if (assigned and !c1_teeth.job_double) return;
        const run_at = records.job_run_key(job);
        const got = try ctx.store.get(ctx.arena, run_at.slice(), world.revision, ctx.diag);
        // The job controller writes the run and its status together: a status alone is its
        // contradiction to report (ZC-E0307), not a run to place.
        const run_kv = got.kv orelse return;
        const run = try records.read(records.JobRun, ctx.arena, run_kv, ctx.diag);
        if (run.stop != null and !c1_teeth.job_double) return;
        // Test-only: a stopped run is placed again even where it is assigned (J5).
        if (assigned and run.stop == null) return;
        const need = run_requests_of(&run);
        var verdicts: [views_max]Verdict = undefined;
        const judged = verdicts[0..world.nodes.len];
        for (world.nodes, judged) |*view, *verdict| verdict.* = judge(view, need, true);
        const chosen = choose(world, "", run.image, judged) orelse {
            const subject: Held = .{
                .kind = .job,
                .id = run_id,
                .name = job,
                .key = run_kv.key,
                .revision = run_kv.mod_revision,
                .status_key = status.kv.key,
                .status_revision = status.kv.mod_revision,
            };
            return sc.hold(ctx, world, pass, subject, need, judged);
        };
        if (!pass.budget()) return;
        const target: RunTarget = .{
            .job = job,
            .run_id = run_id,
            .run_kv = run_kv,
            .status = status,
        };
        try sc.commit_run_placement(ctx, world, pass, target, run, chosen);
    }

    fn commit_run_placement(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        pass: *Pass,
        target: RunTarget,
        run: records.JobRun,
        chosen: Chosen,
    ) Error!void {
        const job = target.job;
        const run_id = target.run_id;
        const run_kv = target.run_kv;
        const status = target.status;
        const need = run_requests_of(&run);
        const view = &world.nodes[chosen.index];
        const name = view.node.rec.name;
        var batch: Batch = .{};
        var set: compare_sets.Set = .{};
        const read: compare_sets.RunRead = .{
            .job = job,
            .run = run_id,
            .run_revision = run_kv.mod_revision,
            .status_revision = status.kv.mod_revision,
        };
        compare_sets.placement_run(&set, read, node_read(view));
        expect_placement(&batch, &set);
        const defaulted = run.limits.cpu_millis == null or run.limits.memory_bytes == null;
        const words: PlaceWords = .{
            .note = if (defaulted) " (a default: the job sets no limits)" else "",
            .group = "runs",
        };
        const reason = try place_reason(ctx, world, words, chosen, need);
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = "place_run",
            .subject = .{ .kind = .job, .name = job },
            .reason = reason,
            .cause = .{ .kind = .desired, .key = run_kv.key, .revision = run_kv.mod_revision },
            .locality_bytes = chosen.locality_bytes,
            .node_store_revision = chosen.store_revision,
            .read_revision = world.revision,
        }, &batch);
        const key = try assign_key(ctx, name, run_id);
        const value = records.assigned_run(run_id, job, need, reason);
        batch.put(key, try records.encode(ctx.arena, value, ctx.diag));
        const after = add(view.allocated, need);
        try put_allocation(ctx, &batch, name, after, view.count + 1, view.node.kv.mod_revision);
        const revision = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        const member: Member = .{ .id = run_id, .service = "", .job = true };
        try adopt_assign(ctx, world, chosen.index, key, member, need, after, revision);
        sc.forget_hold(run_id);
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
        given: ?records.Cause,
        placed: ?Placed,
    ) Error!void {
        const created = if (given == null)
            try indexed_decision(ctx, replica.rec.id, "create_replica", .first)
        else
            null;
        const cause: records.Cause = if (given) |found| found else if (created) |*id|
            controller.cause_decision(id)
        else
            .{
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
            .locality_bytes = if (placed) |found| found.locality_bytes else null,
            .node_store_revision = if (placed) |found| found.store_revision else null,
            .read_revision = if (placed) |found| found.read_revision else null,
        }, batch);
    }

    /// No node fits: writes `hold_pending` once per change in what the evidence says.
    fn hold(
        sc: *Scheduler,
        ctx: *const Context,
        world: *const World,
        pass: *Pass,
        subject: Held,
        need: Requests,
        verdicts: []const Verdict,
    ) Error!void {
        const shape_hash = shape_of(world, need, verdicts);
        const slot = sc.hold_slot(subject.id);
        if (sc.holds[slot].replica == hold_key(subject.id)) {
            if (sc.holds[slot].evidence == shape_hash) return;
        }
        if (!pass.budget()) return;
        var batch: Batch = .{};
        batch.expect(subject.key, subject.revision);
        if (subject.status_key) |status_key| batch.expect(status_key, subject.status_revision);
        const evidence = try evidence_of(ctx, world, need, verdicts);
        const reason = try hold_reason(ctx, world, need, verdicts);
        _ = try controller.put_decision(ctx, &sc.source, .{
            .actor = actor,
            .action = "hold_pending",
            .subject = .{ .kind = subject.kind, .name = subject.name orelse subject.id },
            .reason = reason,
            .cause = .{ .kind = .desired, .key = subject.key, .revision = subject.revision },
            .cause_evidence = .{ .text = evidence },
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .scheduler, &batch)) orelse return;
        sc.holds[slot] = .{ .replica = hold_key(subject.id), .evidence = shape_hash };
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

    /// Forgets the holds of replicas and runs that are gone, so the memory never holds more than
    /// the subjects there are and `hold_slot` always finds a slot without evicting a live one.
    fn sweep_holds(sc: *Scheduler, ctx: *const Context, world: *const World) Error!void {
        var any = false;
        for (sc.holds) |held| any = any or held.replica != 0;
        if (!any) return;
        var live: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (world.replicas) |replica| {
            live.put(ctx.arena, hold_key(replica.rec.id), {}) catch
                return failures.no_memory(ctx.diag);
        }
        for (world.job_statuses) |status| {
            if (records.job_state_terminal(status.rec.state)) continue;
            const job = status.kv.key[records.prefix_job_status.len..];
            if (records.name_problem(job, constants.service_name_bytes_max) != null) continue;
            var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
            live.put(ctx.arena, hold_key(records.job_run_id(&buffer, job)), {}) catch
                return failures.no_memory(ctx.diag);
        }
        for (&sc.holds) |*held| {
            if (held.replica == 0 or live.contains(held.replica)) continue;
            held.* = .{ .replica = 0, .evidence = 0 };
        }
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
    /// for a move (a lost node's replicas are replaced under new ids); the transaction is built
    /// and tested here.
    pub fn move_replica(
        sc: *Scheduler,
        ctx: *const Context,
        world: *World,
        spec: MoveSpec,
    ) Error!MoveResult {
        const replica_index = world.desired.get(spec.replica) orelse return .{ .refused = .{
            .reason = .unknown_replica,
        } };
        const from_index = world.assigned_by.get(spec.replica) orelse return .{ .refused = .{
            .reason = .not_assigned,
        } };
        const replica = &world.replicas[replica_index];
        const from = world.assigns.items[from_index];
        const to_node = world.node_index(spec.to) orelse return .{ .refused = .{
            .reason = .unknown_node,
        } };
        if (from.node == to_node) return .{ .refused = .{ .reason = .same_node } };
        const need = from.requests;
        const target = &world.nodes[to_node];
        const verdict = judge(target, need, false);
        if (verdict.reason != .fits) return .{ .refused = verdict };
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
        const action = "place_replica";
        try sc.put_place_decision(ctx, &batch, replica, spec.reason, action, spec.cause, null);
        batch.delete(from.key);
        const name = target.node.rec.name;
        const key = try assign_key(ctx, name, spec.replica);
        const value = records.assigned_replica(
            spec.replica,
            replica.rec.service,
            need,
            spec.reason,
        );
        batch.put(key, try records.encode(ctx.arena, value, ctx.diag));
        const target_after = add(target.allocated, need);
        try put_moved_allocations(ctx, &batch, source, source_after, target, target_after);
        const done = try controller.commit(ctx, .scheduler, &batch);
        const revision = switch (done) {
            .conflict => return .conflict,
            .applied => |revision| revision,
        };
        forget_assign(world, from_index, source_after, revision);
        const member: Member = .{ .id = replica.rec.id, .service = replica.rec.service };
        try adopt_assign(ctx, world, to_node, key, member, need, target_after, revision);
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
    /// The decision's cause; null for the replica's creation.
    cause: ?records.Cause = null,
};

comptime {
    const compares = compare_sets.placement_count + compare_sets.release_count;
    assert(compares + controller.decision_compares <= constants.store_txn_compares_max);
    assert(controller.decision_ops + 4 <= constants.store_txn_ops_max);
}

pub const MoveResult = union(enum) {
    moved,
    /// A compared key moved: plan again from a fresh read.
    conflict,
    /// The target cannot take the replica, or the source has nothing to release from.
    refused: Verdict,
};

// ---- Keeping the world current after a commit ------------------------------------------------

/// The sum of two requests. Saturating: after a fit check the sum is within a capacity and so
/// cannot saturate, and reconstructing a node's assignments (I6) from a corrupt record must
/// report a mismatch, not panic.
fn add(allocated: Requests, need: Requests) Requests {
    return .{
        .cpu_millis = allocated.cpu_millis +| need.cpu_millis,
        .memory_bytes = allocated.memory_bytes +| need.memory_bytes,
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
    if (assign.job) view.jobs -= 1;
    assign.live = false;
    _ = world.assigned_by.remove(assign.replica);
}

fn adopt_assign(
    ctx: *const Context,
    world: *World,
    node: u32,
    key: []const u8,
    member: Member,
    need: Requests,
    allocated: Requests,
    revision: Revision,
) Error!void {
    const view = &world.nodes[node];
    world_note(view, allocated, view.count + 1, revision);
    view.alloc_node_revision = view.node.kv.mod_revision;
    if (member.job) view.jobs += 1;
    try add_assign(ctx, world, .{
        .key = key,
        .node = node,
        .replica = member.id,
        .service = member.service,
        .requests = need,
        .revision = revision,
        .live = true,
        .job = member.job,
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

/// `expect_all` for a placement, and the one place the sim-c1 negative tests weaken the scheduler:
/// in a build whose root switched on `c1_teeth.skip_allocation_compare`, `/allocations/<node>` is
/// left out; with `skip_readiness_compare`, `/node-status/<node>` and `/nodes/<node>` are.
/// Both constants are false in every other build, so this is `expect_all`.
fn expect_placement(batch: *Batch, set: *compare_sets.Set) void {
    if (!c1_teeth.any) return expect_all(batch, set);
    for (set.compares()) |compare| {
        const skip_allocation = c1_teeth.skip_allocation_compare and
            std.mem.startsWith(u8, compare.key, records.prefix_allocations);
        const skip_readiness = c1_teeth.skip_readiness_compare and
            (std.mem.startsWith(u8, compare.key, records.prefix_node_status) or
                std.mem.startsWith(u8, compare.key, records.prefix_nodes));
        if (skip_allocation or skip_readiness) continue;
        batch.expect(compare.key, compare.mod_revision);
    }
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

/// A size for a sentence: whole MiB from 1 MiB up, whole KiB below, so a small share is not
/// "0 MiB".
fn size_words(ctx: *const Context, bytes: u64) Error![]const u8 {
    if (bytes >= 1024 * 1024) return controller.format(ctx, "{d} MiB", .{mib_of(bytes)});
    return controller.format(ctx, "{d} KiB", .{@divFloor(bytes, 1024)});
}

// ---- Words -----------------------------------------------------------------------------------

fn place_reason(
    ctx: *const Context,
    world: *const World,
    words: PlaceWords,
    chosen: Chosen,
    need: Requests,
) Error![]const u8 {
    const name = world.nodes[chosen.index].node.rec.name;
    const note = words.note;
    const total: u32 = @intCast(world.nodes.len);
    if (total == 1) {
        return controller.format(ctx, "{s} is the only node, and it fits {d}m CPU and {d} " ++
            "MiB{s}", .{ name, need.cpu_millis, mib_of(need.memory_bytes), note });
    }
    return controller.format(ctx, "{s} is the best of the {d} of {d} nodes that fit {d}m CPU " ++
        "and {d} MiB{s}: {d} {s} there, then {s} of the image already " ++
        "there ({s}), then least allocated, then name", .{
        name,
        chosen.candidates,
        total,
        need.cpu_millis,
        mib_of(need.memory_bytes),
        note,
        chosen.service_count,
        words.group,
        try size_words(ctx, chosen.locality_bytes),
        if (chosen.store_revision == 0) "no summary" else "by its summary",
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

/// What a hold says apart from its numbers: what the replica needs, and per node why it is
/// excluded or which resources it lacks. A placement elsewhere changes how far short a node is
/// but not this, and a hold is written again only when this changes.
fn shape_of(world: *const World, need: Requests, verdicts: []const Verdict) u64 {
    assert(verdicts.len == world.nodes.len);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&need.cpu_millis));
    hasher.update(std.mem.asBytes(&need.memory_bytes));
    for (verdicts, world.nodes) |verdict, view| {
        hasher.update(view.node.rec.name);
        hasher.update(&.{ 0, @backingInt(verdict.reason) });
        hasher.update(&.{ @intFromBool(verdict.cpu_by > 0), @intFromBool(verdict.memory_by > 0) });
    }
    return hasher.final();
}

const exclusions = [_]Reason{
    .unknown_node, .lost,       .fenced,        .no_status,
    .older_tenure, .audit_open, .over_capacity, .jobs_full,
    .handles_full,
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

const Which = enum { first, last };

/// The id of the first or last decision of `action` about a replica, from its by-subject index
/// (one page: a replica with more entries than that has its older ones missed).
fn indexed_decision(
    ctx: *const Context,
    replica: []const u8,
    action: []const u8,
    which: Which,
) Error!?records.DecisionId {
    const prefix = records.index_prefix(.replica, replica);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = constants.store_list_limit_max,
    }, ctx.diag);
    var found: ?records.DecisionId = null;
    for (page.kvs) |kv| {
        const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
        if (!std.mem.eql(u8, entry.action, action)) continue;
        if (entry.id.len != records.decision_id_bytes) continue;
        var id: records.DecisionId = .{};
        @memcpy(&id.bytes, entry.id);
        if (which == .first) return id;
        found = id;
    }
    return found;
}

// ---- L1 as a check ---------------------------------------------------------------------------

/// L1 (the simulations'): the placement `request` is about to commit is no worse on spread, among
/// the nodes that fit, than an order of fit and spread alone would choose. Locality may pick among
/// nodes tied on spread; it never costs a node that fits fewer of the service's replicas. Fit
/// itself is I6's (capacity) and I7's (readiness). Judged over the head the transaction commits
/// over, but a rival whose node, status, allocation or audit record is newer than the decision's
/// `read_revision` is skipped: the scheduler could not have seen it, and a placement that lost
/// that race is not a wrong one. A put of `/assigned/` for a replica that already has an
/// assignment is a move, which has no locality step, and is not judged. `judged` counts the
/// placements judged. Returns null, or the sentence that names what broke.
pub fn placement_problem(
    ctx: *const Context,
    request: store.TxnRequest,
    judged: *u64,
) ?[]const u8 {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_assigned)) continue;
        const rest = put.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "L1: a malformed key";
        const read_revision = decision_read_revision(ctx, request) orelse continue;
        const world = read_world(ctx) catch {
            ctx.diag.reset();
            return "L1: the world cannot be read";
        };
        const replica_id = rest[slash + 1 ..];
        if (world.assigned_by.contains(replica_id)) continue;
        const at = world.node_index(rest[0..slash]) orelse return "L1: a placement onto no node";
        const index = world.desired.get(replica_id) orelse continue;
        const need = requests_of(&world.replicas[index].rec);
        var counts: [views_max]u32 = undefined;
        service_counts(&world, world.replicas[index].rec.service, counts[0..world.nodes.len]);
        // Whether the node still fits at the head is I6's and I7's to say (a placement whose
        // compare was skipped lands on a node that changed): L1 judges only a placement that does.
        if (judge(&world.nodes[at], need, false).reason != .fits) continue;
        for (world.nodes, 0..) |*view, other| {
            if (judge(view, need, false).reason != .fits) continue;
            // A rival that changed after the scheduler read the world was judged on what the
            // scheduler saw, not on this: a lost race is not a wrong choice.
            if (changed_since(view, read_revision)) continue;
            if (counts[other] < counts[at]) {
                return "L1: a placement onto a node with more of the service than one that fits";
            }
        }
        judged.* += 1;
    }
    return null;
}

/// Whether any record that decides a node's fit or its replica count is newer than `revision`.
fn changed_since(view: *const NodeView, revision: Revision) bool {
    if (view.node.kv.mod_revision > revision) return true;
    if (view.status_revision > revision) return true;
    if (view.alloc_revision > revision) return true;
    return view.audit_revision > revision;
}

/// The revision the placement in `request` says its world was read at, from its decision; null
/// if the transaction carries none (it is not judged).
fn decision_read_revision(ctx: *const Context, request: store.TxnRequest) ?Revision {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
        const kv: store.KeyValue = .{
            .key = put.key,
            .value = put.value,
            .create_revision = 0,
            .mod_revision = 0,
        };
        const decision = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            continue;
        };
        if (decision.read_revision) |found| return found;
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
/// (authority.md I6), both read at one revision. Returns the first node, by name, that disagrees,
/// or null. The auditor and the simulations run the same reconstruction (`allocations.zig`).
pub fn find_mismatch(ctx: *const Context) Error!?Mismatch {
    const reconstruction = try accounting.reconstruct(ctx);
    const tally = reconstruction.first_mismatch() orelse return null;
    return .{
        .node = tally.node,
        .recorded = tally.recorded orelse accounting.zero,
        .reconstructed = tally.reconstructed,
    };
}
