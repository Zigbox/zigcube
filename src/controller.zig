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

/// The operations and compares of one transaction, within the store's bounds.
pub const Batch = struct {
    ops: [constants.store_txn_ops_max]store.Op = undefined,
    ops_count: u32 = 0,
    compares: [constants.store_txn_compares_max]store.Compare = undefined,
    compares_count: u32 = 0,

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
    var items: std.ArrayList(Entry(T)) = .empty;
    var revision = at_revision;
    var after: ?[]const u8 = null;
    const pages_max = @divFloor(count_max, constants.store_list_limit_max) + 1;
    for (0..pages_max + 1) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        revision = page.revision;
        for (page.kvs) |kv| {
            if (items.items.len >= count_max) return too_many(ctx, prefix, count_max);
            const rec = try records.read(T, ctx.arena, kv, ctx.diag);
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

    /// The observed record of a replica, or null if its node has not reported it.
    pub fn observed_of(snapshot: *const Snapshot, replica: *const records.Replica) ?*const Entry(
        records.Observed,
    ) {
        if (replica.node.len == 0) return null;
        const key = records.observed_key(replica.node, replica.id);
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
    return .{
        .revision = at,
        .services = services.items,
        .replicas = replicas.items,
        .observed = observed.items,
        .nodes = nodes.items,
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
};

/// Adds a decision and its by-subject index entry to `batch` (two operations) and returns its id.
/// The decision is committed with the action it records, or not at all.
pub fn put_decision(
    ctx: *const Context,
    source: *DecisionSource,
    spec: DecisionSpec,
    batch: *Batch,
) Error!records.DecisionId {
    assert(spec.reason.len > 0);
    assert(batch.has_room(2));
    if (spec.cause_evidence) |evidence| {
        assert(evidence.text.len <= constants.decision_evidence_bytes_max);
    }
    const at_ms = ctx.clock.now_ms();
    assert(at_ms <= constants.decision_time_ms_max);
    const id = source.next(at_ms);
    const decision: records.Decision = .{
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
    return id;
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
    try testing.expectEqual(@as(u32, 4), batch.ops_count);
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
