//! What every controller step shares: the `Context` it runs in, the `Wakeup` it returns, a
//! consistent `Snapshot` of desired and observed state, and the one way a decision is written.
//!
//! ## The step model (docs/core.md)
//!
//! A controller is `reconcile(ctx) -> Wakeup`. It reads what it needs, does what is due, writes
//! each action together with its decision record in one transaction, and returns. It never
//! waits: not on a `Watch`, not on a runtime event, not on a stop. The shell loops, sleeps until
//! `Wakeup.at_ms` or until a key under `Wakeup.prefixes` changes, and calls again. Work too big
//! for one step (more replicas than one transaction holds) is done in parts: the step says
//! `at_ms = now` and the next call carries on from what the store then says, which is the whole
//! reason reconciliation is level-triggered.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Revision = store.Revision;
const Store = store.Store;

pub const Error = store.Error || records.Error;

/// When a controller next needs to run. The shell waits for the sooner of the two.
pub const Wakeup = struct {
    /// On the `Clock`'s scale: run again no later than this. `now` means "I have more to do".
    at_ms: u64,
    /// Run again sooner if a key under any of these changes.
    prefixes: []const []const u8,
    /// Transactions this step committed. Zero on a converged system: that is idempotence.
    acted: u32,
};

pub const Context = struct {
    store: Store,
    clock: Clock,
    /// One arena per step, freed whole when it ends (`constants.request_arena_bytes_max`).
    arena: Allocator,
    diag: *Diag,
};

/// Formats into the step's arena. Running out is `NoCapacity`, as for the store.
pub fn format(ctx: *const Context, comptime text: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(ctx.arena, text, args) catch failures.no_memory(ctx.diag);
}

/// A copy of a key in the arena, for an `Op` that must outlive the `Key` it was built from.
pub fn key_copy(ctx: *const Context, key: *const records.Key) Error![]const u8 {
    return ctx.arena.dupe(u8, key.slice()) catch failures.no_memory(ctx.diag);
}

// ---- Transactions of bounded size ------------------------------------------------------------

/// What one `put_decision` adds to a batch, at most: the decision, its index entry and its
/// summary (`/decision-summaries/`), and the summary's compare. A second decision for the same
/// summary in one batch adds two operations and no compare. Every batch bound that holds
/// decisions is derived from these.
pub const decision_ops: u32 = 3;
pub const decision_compares: u32 = 1;

/// Summaries one batch can hold: every one has a decision, which takes `decision_ops`.
const summaries_max = constants.store_txn_ops_max / decision_ops;

/// A summary put already in a batch: where it is, and the record it holds.
const SummarySlot = struct {
    key: []const u8,
    op_index: u32,
    record: records.Summary,
};

comptime {
    assert(summaries_max > 0);
    assert(decision_ops >= 3);
    assert(decision_compares == 1);
    assert(decision_compares * summaries_max <= constants.store_txn_compares_max);
}

/// The operations and compares of one transaction, within the store's bounds.
pub const Batch = struct {
    ops: [constants.store_txn_ops_max]store.Op = undefined,
    ops_count: u32 = 0,
    compares: [constants.store_txn_compares_max]store.Compare = undefined,
    compares_count: u32 = 0,
    summaries: [summaries_max]SummarySlot = undefined,
    summaries_count: u32 = 0,

    pub fn put(batch: *Batch, key: []const u8, value: []const u8) void {
        assert(batch.ops_count < constants.store_txn_ops_max);
        batch.ops[batch.ops_count] = .{ .put = .{ .key = key, .value = value } };
        batch.ops_count += 1;
    }

    pub fn delete(batch: *Batch, key: []const u8) void {
        assert(batch.ops_count < constants.store_txn_ops_max);
        batch.ops[batch.ops_count] = .{ .delete = key };
        batch.ops_count += 1;
    }

    /// The key must still be at `mod_revision` (0: must not exist) when the batch commits.
    pub fn expect(batch: *Batch, key: []const u8, mod_revision: Revision) void {
        assert(batch.compares_count < constants.store_txn_compares_max);
        batch.compares[batch.compares_count] = .{ .key = key, .mod_revision = mod_revision };
        batch.compares_count += 1;
    }

    pub fn has_room(batch: *const Batch, ops: u32) bool {
        return batch.ops_count + ops <= constants.store_txn_ops_max;
    }

    fn summary_slot(batch: *Batch, key: []const u8) ?*SummarySlot {
        for (batch.summaries[0..batch.summaries_count]) |*slot| {
            if (std.mem.eql(u8, slot.key, key)) return slot;
        }
        return null;
    }
};

pub const Commit = union(enum) {
    /// Applied; the revision it took.
    applied: Revision,
    /// A compare failed: the state changed under the plan, nothing was written. The step stops
    /// and runs again from the new state.
    conflict,
};

/// Commits `batch` as `role`; a batch that writes a key that is not the role's asserts (I4).
pub fn commit(ctx: *const Context, role: writers.Role, batch: *const Batch) Error!Commit {
    assert(batch.ops_count > 0);
    const request: store.TxnRequest = .{
        .compares = batch.compares[0..batch.compares_count],
        .on_success = batch.ops[0..batch.ops_count],
    };
    const result = try writers.txn(ctx.store, role, request, ctx.diag);
    if (!result.succeeded) return .conflict;
    return .{ .applied = result.revision };
}

// ---- Reading state ---------------------------------------------------------------------------

pub fn Entry(comptime T: type) type {
    return struct { kv: store.KeyValue, rec: T };
}

/// Every record of a kind, ascending by key, read at one revision.
pub fn List(comptime T: type) type {
    return struct { items: []const Entry(T), revision: Revision };
}

/// Reads all records under `prefix`, at `at_revision` if given (so several kinds can be read at
/// one revision), at most `count_max` of them: more is ZC-E0302.
pub fn list_all(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at_revision: ?Revision,
    count_max: u32,
) Error!List(T) {
    return list_pages(T, ctx, prefix, at_revision, count_max, null);
}

/// As `list_all`, for advisory records: one that does not decode, or was written in a newer
/// version, is left out and counted in `skipped` (its diagnostic is dropped) instead of failing
/// the read. The records it returns are still ascending by key.
pub fn list_all_tolerant(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at_revision: ?Revision,
    count_max: u32,
    skipped: *u32,
) Error!List(T) {
    skipped.* = 0;
    return list_pages(T, ctx, prefix, at_revision, count_max, skipped);
}

/// As `list_all_tolerant`, but a read that reaches `count_max` records stops there, with
/// `truncated` set, instead of failing with ZC-E0302: for a screen that shows what fits.
pub fn list_capped_tolerant(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    count_max: u32,
    skipped: *u32,
    truncated: *bool,
) Error!List(T) {
    skipped.* = 0;
    truncated.* = false;
    return list_pages_capped(T, ctx, prefix, null, count_max, skipped, truncated);
}

fn list_pages(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at_revision: ?Revision,
    count_max: u32,
    skipped: ?*u32,
) Error!List(T) {
    return list_pages_capped(T, ctx, prefix, at_revision, count_max, skipped, null);
}

fn list_pages_capped(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at_revision: ?Revision,
    count_max: u32,
    skipped: ?*u32,
    truncated: ?*bool,
) Error!List(T) {
    var items: std.ArrayList(Entry(T)) = .empty;
    var revision = at_revision;
    var after: ?[]const u8 = null;
    const pages_max = @divFloor(count_max, constants.store_list_limit_max) + 1;
    for (0..pages_max + 1) |_| {
        // Ask for no more than the cap still allows, plus one to see that there is more: at the
        // cap a full third page would cost the arena records that are then thrown away.
        const wanted = count_max -| @as(u32, @intCast(items.items.len)) +| 1;
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix,
            .at_revision = revision,
            .limit = @min(constants.store_list_limit_max, wanted),
            .continue_after = after,
        }, ctx.diag);
        revision = page.revision;
        for (page.kvs) |kv| {
            if (items.items.len >= count_max) {
                const flag = truncated orelse return too_many(ctx, prefix, count_max);
                flag.* = true;
                return .{ .items = items.items, .revision = revision.? };
            }
            const rec = records.read(T, ctx.arena, kv, ctx.diag) catch |err| {
                const count = skipped orelse return err;
                if (err != error.Malformed) return err;
                ctx.diag.reset();
                count.* += 1;
                continue;
            };
            items.append(ctx.arena, .{ .kv = kv, .rec = rec }) catch
                return failures.no_memory(ctx.diag);
        }
        after = page.continue_after;
        if (after == null) return .{ .items = items.items, .revision = revision.? };
    }
    return too_many(ctx, prefix, count_max);
}

fn too_many(ctx: *const Context, prefix: []const u8, count_max: u32) error{NoCapacity} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0302);
    ctx.diag.cause("more than {d} records under {s}", .{ count_max, prefix });
    ctx.diag.fix(.{ .sentence = "delete what is no longer needed" });
    return error.NoCapacity;
}

/// Desired and observed state at one revision.
pub const Snapshot = struct {
    revision: Revision,
    services: []const Entry(records.Service),
    replicas: []const Entry(records.Replica),
    observed: []const Entry(records.Observed),
    nodes: []const Entry(records.Node),
    /// The scheduler's assignments (`/assigned/`), at the same revision.
    assigned: []const Entry(records.Assigned) = &.{},
    /// The node controller's judgements (`/node-status/`), at the same revision.
    statuses: []const Entry(records.NodeStatus) = &.{},
    /// Replica id to the node it is assigned to.
    node_by_replica: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The node a replica is assigned to, or null while it is unassigned.
    pub fn node_of(snapshot: *const Snapshot, replica: []const u8) ?[]const u8 {
        return snapshot.node_by_replica.get(replica);
    }

    /// The assignment of a replica, or null while it is unassigned: its `mod_revision` is what a
    /// transaction that acted on where the replica runs compares.
    pub fn assigned_of(snapshot: *const Snapshot, replica: []const u8) ?*const Entry(
        records.Assigned,
    ) {
        const node = snapshot.node_of(replica) orelse return null;
        const key = records.assigned_key(node, replica);
        const Order = struct {
            fn compare(wanted: []const u8, item: Entry(records.Assigned)) std.math.Order {
                return std.mem.order(u8, wanted, item.kv.key);
            }
        };
        const index = std.sort.binarySearch(
            Entry(records.Assigned),
            snapshot.assigned,
            key.slice(),
            Order.compare,
        ) orelse return null;
        return &snapshot.assigned[index];
    }

    /// The observed record of a replica, or null if it is unassigned or its node has not
    /// reported it.
    pub fn observed_of(snapshot: *const Snapshot, replica: *const records.Replica) ?*const Entry(
        records.Observed,
    ) {
        const node = snapshot.node_of(replica.id) orelse return null;
        const key = records.observed_key(node, replica.id);
        const Order = struct {
            fn compare(wanted: []const u8, item: Entry(records.Observed)) std.math.Order {
                return std.mem.order(u8, wanted, item.kv.key);
            }
        };
        const index = std.sort.binarySearch(
            Entry(records.Observed),
            snapshot.observed,
            key.slice(),
            Order.compare,
        ) orelse return null;
        return &snapshot.observed[index];
    }

    /// A node's status, or null if the node controller has not judged it.
    pub fn status_of(snapshot: *const Snapshot, node: []const u8) ?*const Entry(
        records.NodeStatus,
    ) {
        const key = records.node_status_key(node);
        for (snapshot.statuses) |*entry| {
            if (std.mem.eql(u8, entry.kv.key, key.slice())) return entry;
        }
        return null;
    }

    /// A node's `/nodes` record, or null if it has none (its lease ended).
    pub fn node_entry(snapshot: *const Snapshot, node: []const u8) ?*const Entry(records.Node) {
        for (snapshot.nodes) |*entry| {
            if (std.mem.eql(u8, entry.rec.name, node)) return entry;
        }
        return null;
    }

    pub fn service_of(snapshot: *const Snapshot, name: []const u8) ?*const Entry(
        records.Service,
    ) {
        for (snapshot.services) |*entry| {
            if (std.mem.eql(u8, entry.rec.name, name)) return entry;
        }
        return null;
    }
};

pub fn read_snapshot(ctx: *const Context) Error!Snapshot {
    const services = try list_all(
        records.Service,
        ctx,
        records.prefix_services,
        null,
        constants.services_max,
    );
    const at = services.revision;
    const replicas = try list_all(
        records.Replica,
        ctx,
        records.prefix_replicas,
        at,
        constants.replicas_max,
    );
    const observed = try list_all(
        records.Observed,
        ctx,
        records.prefix_observed,
        at,
        constants.replicas_max,
    );
    const nodes = try list_all(records.Node, ctx, records.prefix_nodes, at, constants.nodes_max);
    const assigned = try list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        at,
        constants.replicas_max,
    );
    const statuses = try list_all(
        records.NodeStatus,
        ctx,
        records.prefix_node_status,
        at,
        constants.nodes_max,
    );
    var by_replica: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (assigned.items) |entry| {
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
            return records.malformed(ctx.diag, entry.kv.key, "Assigned");
        by_replica.put(ctx.arena, entry.rec.replica, rest[0..slash]) catch
            return failures.no_memory(ctx.diag);
    }
    return .{
        .revision = at,
        .services = services.items,
        .replicas = replicas.items,
        .observed = observed.items,
        .nodes = nodes.items,
        .assigned = assigned.items,
        .statuses = statuses.items,
        .node_by_replica = by_replica,
    };
}

// ---- Decisions -------------------------------------------------------------------------------

/// Who writes decisions and how their ids stay unique without coordination (docs/keys.md): the
/// actor's name, the controller instance the shell assigned, and a counter of this instance.
pub const DecisionSource = struct {
    instance: u16,
    counter: u32 = 0,

    pub fn next(source: *DecisionSource, at_ms: u64) records.DecisionId {
        assert(source.counter < constants.decision_counter_modulus);
        const id = records.decision_id(at_ms, source.instance, source.counter);
        source.counter = (source.counter + 1) % constants.decision_counter_modulus;
        return id;
    }
};

pub const DecisionSpec = struct {
    actor: []const u8,
    action: []const u8,
    subject: records.Subject,
    reason: []const u8,
    cause: records.Cause,
    change: ?[]const u8 = null,
    cause_diagnostic: ?records.Raw = null,
    /// The fields of the cause's key that the decision used (at most
    /// `constants.decision_evidence_bytes_max` bytes of JSON).
    cause_evidence: ?records.Raw = null,
    /// A placement's locality estimate and the `/node-store` revision it read (decision v3).
    locality_bytes: ?u64 = null,
    node_store_revision: ?u64 = null,
    /// The revision the placement's world was read at.
    read_revision: ?u64 = null,
};

/// Adds a decision, its by-subject index entry and the update of its summary to `batch` (at most
/// `decision_ops` operations and `decision_compares` compare) and returns its id. The decision
/// is committed with the action it records, or not at all. The summary is read here and compared
/// at the revision read (0: absent), so its count is exact: a concurrent writer of the same
/// summary makes the transaction a conflict. A second decision for the same summary in one batch
/// updates the put already there. A summary is never a cause.
pub fn put_decision(
    ctx: *const Context,
    source: *DecisionSource,
    spec: DecisionSpec,
    batch: *Batch,
) Error!records.DecisionId {
    assert(spec.reason.len > 0);
    assert(batch.has_room(decision_ops));
    if (spec.cause_evidence) |evidence| {
        assert(evidence.text.len <= constants.decision_evidence_bytes_max);
    }
    const at_ms = ctx.clock.now_ms();
    assert(at_ms <= constants.decision_time_ms_max);
    const id = source.next(at_ms);
    const locality = spec.locality_bytes != null;
    const decision: records.Decision = .{
        .v = if (locality) records.decision_version_locality else records.decision_version_plain,
        .id = id.slice(),
        .at_ms = at_ms,
        .actor = spec.actor,
        .action = spec.action,
        .subject = spec.subject,
        .reason = spec.reason,
        .change = spec.change,
        .cause = spec.cause,
        .cause_diagnostic = spec.cause_diagnostic,
        .cause_evidence = spec.cause_evidence,
        .locality_bytes = spec.locality_bytes,
        .node_store_revision = spec.node_store_revision,
        .read_revision = spec.read_revision,
    };
    const entry: records.IndexEntry = .{
        .id = id.slice(),
        .at_ms = at_ms,
        .action = spec.action,
        .summary = spec.reason,
    };
    const decision_at = records.decision_key(id.slice());
    const index_at = records.index_key(spec.subject.kind, spec.subject.name, id.slice());
    batch.put(try key_copy(ctx, &decision_at), try records.encode(ctx.arena, decision, ctx.diag));
    batch.put(try key_copy(ctx, &index_at), try records.encode(ctx.arena, entry, ctx.diag));
    try count_decision(ctx, batch, spec, &decision);
    return id;
}

/// Adds one to the summary of the decision's subject, action and kind of cause.
fn count_decision(
    ctx: *const Context,
    batch: *Batch,
    spec: DecisionSpec,
    decision: *const records.Decision,
) Error!void {
    const summary_at = records.summary_key(
        spec.subject.kind,
        spec.subject.name,
        spec.action,
        spec.cause.kind,
    );
    const key = try key_copy(ctx, &summary_at);
    const newest = ctx.arena.dupe(u8, decision.id) catch return failures.no_memory(ctx.diag);
    if (batch.summary_slot(key)) |slot| {
        assert(slot.record.count > 0);
        slot.record.count += 1;
        slot.record.last_at_ms = @max(slot.record.last_at_ms, decision.at_ms);
        slot.record.newest = newest;
        const bytes = try records.encode(ctx.arena, slot.record, ctx.diag);
        batch.ops[slot.op_index] = .{ .put = .{ .key = key, .value = bytes } };
        return;
    }
    assert(batch.summaries_count < summaries_max);
    const got = try ctx.store.get(ctx.arena, key, null, ctx.diag);
    var record: records.Summary = .{
        .count = 1,
        .first_at_ms = decision.at_ms,
        .last_at_ms = decision.at_ms,
        .newest = newest,
    };
    var revision: Revision = 0;
    if (got.kv) |kv| {
        const old = try records.read(records.Summary, ctx.arena, kv, ctx.diag);
        record.count = old.count + 1;
        record.first_at_ms = @min(old.first_at_ms, decision.at_ms);
        record.last_at_ms = @max(old.last_at_ms, decision.at_ms);
        revision = kv.mod_revision;
    }
    batch.expect(key, revision);
    batch.summaries[batch.summaries_count] = .{
        .key = key,
        .op_index = batch.ops_count,
        .record = record,
    };
    batch.summaries_count += 1;
    batch.put(key, try records.encode(ctx.arena, record, ctx.diag));
}

/// A cause that points at another decision.
pub fn cause_decision(id: *const records.DecisionId) records.Cause {
    return .{ .kind = .decision, .id = id.slice() };
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

test "a decision and its index entry are written together, with a unique sortable id" {
    // Goal: put_decision's contract: two operations, ids that sort by time and never repeat
    // within a controller instance, and a record that reads back with its cause.
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
    var source: DecisionSource = .{ .instance = 1 };
    var batch: Batch = .{};
    const subject: records.Subject = .{ .kind = .service, .name = "hello" };
    const first = try put_decision(&ctx, &source, .{
        .actor = "replica-controller",
        .action = "scale_up",
        .subject = subject,
        .reason = "service hello wants 3 replicas and 0 exist",
        .cause = .{ .kind = .desired, .key = "/services/hello", .revision = 1 },
    }, &batch);
    const second = try put_decision(&ctx, &source, .{
        .actor = "replica-controller",
        .action = "create_replica",
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "creating hello-1",
        .cause = cause_decision(&first),
    }, &batch);
    // Each decision: the record, the index entry and its summary (here two different summaries).
    try testing.expectEqual(@as(u32, 6), batch.ops_count);
    try testing.expect(std.mem.order(u8, first.slice(), second.slice()) == .lt);
    try testing.expectEqualStrings("1761350000123-0001-0000", first.slice());
    const done = try commit(&ctx, .replica_controller, &batch);
    try testing.expectEqual(@as(Revision, 1), done.applied);

    const key = records.decision_key(first.slice());
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &diag);
    const back = try records.read(records.Decision, ctx.arena, got.kv.?, &diag);
    try testing.expectEqualStrings("scale_up", back.action);
    try testing.expectEqual(records.CauseKind.desired, back.cause.kind);
}

test "a commit whose compare fails reports a conflict and writes nothing" {
    // Goal: the contract of `commit`: the state changed under the plan, so nothing is applied.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{};
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
    var batch: Batch = .{};
    batch.expect("/services/x", 7);
    batch.put("/services/x", "{}");
    try testing.expect((try commit(&ctx, .api, &batch)) == .conflict);
    const status = try ctx.store.status(&diag);
    try testing.expectEqual(@as(Revision, 0), status.revision);
}

test "two decisions for one summary in a batch make one put and one compare, counted twice" {
    // Goal: put_decision's merge. Method: two decisions with one subject, action and kind of
    // cause in one batch: 2 x (record, index) + one summary put, one compare; after the commit
    // the summary counts 2 and names the newer decision.
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
    var source: DecisionSource = .{ .instance = 1 };
    var batch: Batch = .{};
    const spec: DecisionSpec = .{
        .actor = "replica-controller",
        .action = "create_replica",
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "creating hello-1",
        .cause = .{ .kind = .desired, .key = "/services/hello", .revision = 1 },
    };
    _ = try put_decision(&ctx, &source, spec, &batch);
    manual.ms += 5;
    const newer = try put_decision(&ctx, &source, spec, &batch);
    try testing.expectEqual(@as(u32, 5), batch.ops_count);
    try testing.expectEqual(@as(u32, 1), batch.compares_count);
    try testing.expectEqual(@as(u32, 1), batch.summaries_count);
    try testing.expect((try commit(&ctx, .replica_controller, &batch)) == .applied);
    const key = records.summary_key(.replica, "hello-1", "create_replica", .desired);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &diag);
    const summary = try records.read(records.Summary, ctx.arena, got.kv.?, &diag);
    try testing.expectEqual(@as(u64, 2), summary.count);
    try testing.expectEqualStrings(newer.slice(), summary.newest);
    try testing.expectEqual(@as(u64, 1761350000128), summary.last_at_ms);
}

test "a summary written by another controller between plan and commit is a conflict" {
    // Goal: the summary's compare is exact. Method: plan a decision (the summary is absent, so
    // the compare expects revision 0), let another writer create that summary, then commit:
    // a conflict, and the decision is not written.
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
    var source: DecisionSource = .{ .instance = 1 };
    var batch: Batch = .{};
    const id = try put_decision(&ctx, &source, .{
        .actor = "replica-controller",
        .action = "create_replica",
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "creating hello-1",
        .cause = .{ .kind = .desired, .key = "/services/hello", .revision = 1 },
    }, &batch);
    const key = records.summary_key(.replica, "hello-1", "create_replica", .desired);
    const other: store.Op = .{ .put = .{ .key = key.slice(), .value = "{}" } };
    _ = try ctx.store.txn(.{ .on_success = &.{other} }, &diag);
    try testing.expect((try commit(&ctx, .replica_controller, &batch)) == .conflict);
    const decision_at = records.decision_key(id.slice());
    const got = try ctx.store.get(ctx.arena, decision_at.slice(), null, &diag);
    try testing.expect(got.kv == null);
}
