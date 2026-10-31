//! The service and replica controller of C0: it keeps `/replicas/<service>/*` matching
//! `/services/<name>`, and places each replica on a node. One step, level-triggered and
//! idempotent (see `controller.zig` for the step model): it compares what is desired with what
//! the agents observed, and for every difference it commits the action together with a decision
//! record that names its cause (docs/keys.md, "Decisions"). On a converged system a step writes
//! nothing.
//!
//! What it decides (docs/api.md items 9 to 11, docs/keys.md):
//!
//!   - fewer replicas than wanted: `scale_up` on the service, `create_replica` for each new one;
//!   - more than wanted: `scale_down`, `stop_replica` for the victims (not running ones first,
//!     then the newest);
//!   - a replica whose container ended (exit, signal, `oom`, `pid_limit`, `lost`, or a start that
//!     failed through no fault of the user): `delete_replica` or `mark_replica_lost` on the
//!     replica, then `replace_replica` on the service and a new replica;
//!   - a replica whose start failed through the user's fault (the diagnostic's blame is `user`):
//!     it is **held**, with a `hold_failed_replica` decision on the service, and neither retried
//!     nor replaced; a new `generation` of the service replaces it;
//!   - a replica behind its service's `generation`: replaced (a change of the replica count alone
//!     does not bump `generation`, so scaling never replaces what runs);
//!   - replicas of a service that no longer exists: `scale_down` on the (gone) service and
//!     `stop_replica` for each;
//!   - a replica with no node: placed by `place` (the C0 scheduler: a node whose declared
//!     capacity fits the replica's resolved requests, the fewest replicas of the same service
//!     first), with a `place_replica` decision.
//!
//! A transaction touches at most `batch_replicas_max` replicas, so a big change takes several
//! steps; each leaves the system in a state the next step can continue from.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const retention = @import("retention.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Batch = controller.Batch;
const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Snapshot = controller.Snapshot;
const Wakeup = controller.Wakeup;
const DecisionId = records.DecisionId;
const ServiceEntry = Entry(records.Service);
const ReplicaEntry = Entry(records.Replica);
const ObservedEntry = Entry(records.Observed);
const NumberEntry = Entry(records.ReplicaNumber);

pub const actor = "replica-controller";
pub const scheduler_actor = "scheduler";

/// Replicas one transaction creates or removes: 2 operations for the service decision, 3 for each
/// replica (a decision with its index entry, and the replica), and 1 for the service itself.
const batch_replicas_max: u32 = 4;
/// Placements per transaction: 3 operations each.
const batch_places_max: u32 = 5;
const resync_ms: u64 = 30 * 1000;

pub const watch_prefixes = [_][]const u8{
    records.prefix_services,
    records.prefix_replicas,
    records.prefix_observed,
    records.prefix_nodes,
    records.prefix_replica_numbers,
};

comptime {
    assert(2 + batch_replicas_max * 3 + 1 <= constants.store_txn_ops_max);
    assert(batch_places_max * 3 <= constants.store_txn_ops_max);
    assert(1 + batch_replicas_max <= constants.store_txn_compares_max);
}

pub const ReplicaController = struct {
    source: controller.DecisionSource,
    retention: retention.Cursor = .{},

    /// `instance` is this controller's number, from the shell: it keeps decision ids unique
    /// when two servers run, and a restarted server takes a new one.
    pub fn init(instance: u16) ReplicaController {
        return .{ .source = .{ .instance = instance } };
    }

    /// One pass. Errors are the store's (its diagnostic is in `ctx.diag`) or a malformed record
    /// (ZC-E0301); the shell retries later.
    pub fn reconcile(rc: *ReplicaController, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const snapshot = try controller.read_snapshot(ctx);
        const numbers = try controller.list_all(
            records.ReplicaNumber,
            ctx,
            records.prefix_replica_numbers,
            snapshot.revision,
            constants.services_max,
        );
        var run: Run = .{
            .rc = rc,
            .ctx = ctx,
            .snap = &snapshot,
            .numbers = numbers.items,
            .txns_left = constants.controller_txns_per_step_max,
        };
        try run.place_unplaced();
        for (snapshot.services) |*service| try run.reconcile_service(service);
        try run.reconcile_orphans();
        try run.reconcile_numbers();
        if (now >= rc.retention.due_ms) {
            rc.retention.due_ms = try retention.prune(ctx, &rc.retention, &snapshot, now);
        }
        const again = run.more or run.acted > 0;
        var wake_at = now + resync_ms;
        if (again) wake_at = now;
        if (rc.retention.due_ms < wake_at) wake_at = @max(rc.retention.due_ms, now);
        return .{ .at_ms = wake_at, .prefixes = &watch_prefixes, .acted = run.acted };
    }
};

// ---- One step --------------------------------------------------------------------------------

const Class = enum { live, held, dead, stale };

const Item = struct {
    replica: *const Entry(records.Replica),
    observed: ?*const Entry(records.Observed),
    class: Class,
    running: bool,
    number: u32,
};

const ServicePlan = struct {
    items: [constants.replicas_per_service_max]Item = undefined,
    count: u32 = 0,
    live: u32 = 0,
    held: u32 = 0,
    dead: u32 = 0,
    stale: u32 = 0,

    fn slice(plan: *const ServicePlan) []const Item {
        return plan.items[0..plan.count];
    }
};

const Run = struct {
    rc: *ReplicaController,
    ctx: *const Context,
    snap: *const Snapshot,
    /// `/replica-numbers/`, read at the snapshot's revision.
    numbers: []const NumberEntry,
    txns_left: u32,
    acted: u32 = 0,
    /// Work is left for the next step (a conflict, a spent budget, a partial change).
    more: bool = false,

    /// True if one more transaction may be committed in this step.
    fn budget(run: *Run) bool {
        if (run.txns_left == 0) {
            run.more = true;
            return false;
        }
        run.txns_left -= 1;
        return true;
    }

    /// Commits; a conflict is not an error: the plan was made on state that has changed, so the
    /// next step plans again.
    fn finish(run: *Run, batch: *const Batch) Error!bool {
        const done = try controller.commit(run.ctx, .replica_controller, batch);
        switch (done) {
            .applied => {
                run.acted += 1;
                run.more = true;
                return true;
            },
            .conflict => {
                run.more = true;
                return false;
            },
        }
    }

    fn reconcile_service(run: *Run, service: *const Entry(records.Service)) Error!void {
        var plan: ServicePlan = .{};
        try run.classify(service, &plan);
        if (!try run.hold_pass(service, &plan)) return;
        if (plan.dead + plan.stale > 0) return run.replace(service, &plan);
        const keep = plan.live + plan.held;
        if (keep < service.rec.replicas) return run.scale_up(service, keep);
        if (keep > service.rec.replicas) return run.scale_down(service, &plan);
    }

    // ---- Reading ----

    fn classify(run: *Run, service: *const Entry(records.Service), plan: *ServicePlan) Error!void {
        for (run.snap.replicas) |*replica| {
            if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
            if (plan.count == constants.replicas_per_service_max) {
                run.ctx.diag.raise(.E0302);
                run.ctx.diag.cause("service {s} has more than {d} replicas", .{
                    service.rec.name, constants.replicas_per_service_max,
                });
                run.ctx.diag.fix(.{ .sentence = "delete the extra replica keys by hand" });
                return error.NoCapacity;
            }
            const number = records.replica_number(service.rec.name, replica.rec.id) orelse
                return records.malformed(run.ctx.diag, replica.kv.key, "Replica");
            const observed = run.snap.observed_of(&replica.rec);
            var item: Item = .{
                .replica = replica,
                .observed = observed,
                .class = .live,
                .running = false,
                .number = number,
            };
            item.class = classify_one(replica.rec.generation, service.rec.generation, observed);
            item.running = if (observed) |found| found.rec.status == .running else false;
            plan.items[plan.count] = item;
            plan.count += 1;
        }
        std.mem.sort(Item, plan.items[0..plan.count], {}, by_number);
        for (plan.slice()) |item| switch (item.class) {
            .live => plan.live += 1,
            .held => plan.held += 1,
            .dead => plan.dead += 1,
            .stale => plan.stale += 1,
        };
    }

    // ---- Holding a failed start ----

    /// Writes a `hold_failed_replica` decision for each held replica that has none for its current
    /// observed record. False if the transaction did not commit (the step stops for this service).
    fn hold_pass(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!bool {
        var batch: Batch = .{};
        for (plan.slice()) |item| {
            if (item.class != .held) continue;
            const observed = item.observed.?;
            if (try run.already_held(service.rec.name, observed)) continue;
            if (!batch.has_room(2)) break;
            batch.expect(observed.kv.key, observed.kv.mod_revision);
            const reason = try controller.format(run.ctx, "replica {s} failed to start on {s}; " ++
                "it was not replaced because a new one would fail the same way", .{
                item.replica.rec.id, item.replica.rec.node,
            });
            _ = try controller.put_decision(run.ctx, &run.rc.source, .{
                .actor = actor,
                .action = "hold_failed_replica",
                .subject = .{ .kind = .service, .name = service.rec.name },
                .reason = reason,
                .cause = .{
                    .kind = .observed,
                    .key = observed.kv.key,
                    .revision = observed.kv.mod_revision,
                },
                .cause_diagnostic = observed.rec.diagnostic,
            }, &batch);
        }
        if (batch.ops_count == 0) return true;
        if (!run.budget()) return false;
        return run.finish(&batch);
    }

    /// Whether one of the service's newest decisions already explains this observed record.
    fn already_held(run: *Run, service: []const u8, observed: *const ObservedEntry) Error!bool {
        const ctx = run.ctx;
        const prefix = records.index_prefix(.service, service);
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = constants.decisions_scan_max,
            .reverse = true,
        }, ctx.diag);
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
            if (!std.mem.eql(u8, entry.action, "hold_failed_replica")) continue;
            const key = records.decision_key(entry.id);
            const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
            const found = got.kv orelse continue;
            const decision = try records.read(records.Decision, ctx.arena, found, ctx.diag);
            const cause_key = decision.cause.key orelse continue;
            if (!std.mem.eql(u8, cause_key, observed.kv.key)) continue;
            if (decision.cause.revision == observed.kv.mod_revision) return true;
        }
        return false;
    }

    // ---- Replacing ----

    /// Removes up to a batch of dead and stale replicas and creates their replacements.
    fn replace(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!void {
        var removed: [batch_replicas_max]*const Item = undefined;
        var removed_count: u32 = 0;
        for (plan.slice()) |*item| {
            if (item.class != .dead and item.class != .stale) continue;
            if (removed_count == batch_replicas_max) break;
            removed[removed_count] = item;
            removed_count += 1;
        }
        const keep = plan.live + plan.held;
        const wanted = service.rec.replicas;
        const missing = if (wanted > keep) wanted - keep else 0;
        const creations = @min(batch_replicas_max - removed_count, missing);
        if (!run.budget()) return;

        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        var first_dead: ?DecisionId = null;
        for (removed[0..removed_count]) |item| {
            if (item.class != .dead) continue;
            const id = try run.remove_dead(&batch, item);
            if (first_dead == null) first_dead = id;
        }
        const why = try run.replace_reason(service, plan, removed[0..removed_count], keep);
        const cause: records.Cause = if (first_dead) |*id|
            controller.cause_decision(id)
        else
            desired_cause(service);
        const decision = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "replace_replica",
            .subject = .{ .kind = .service, .name = service.rec.name },
            .reason = why,
            .cause = cause,
        }, &batch);
        for (removed[0..removed_count]) |item| {
            if (item.class == .stale) try run.remove_stale(&batch, item, &decision, service);
        }
        try run.create_replicas(&batch, service, &decision, creations);
        _ = try run.finish(&batch);
    }

    fn replace_reason(
        run: *Run,
        service: *const Entry(records.Service),
        plan: *const ServicePlan,
        removed: []const *const Item,
        keep: u32,
    ) Error![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        const name = service.rec.name;
        const wanted = service.rec.replicas;
        if (plan.dead == 0) {
            const head = try controller.format(run.ctx, "service {s} is at generation {d} and " ++
                "{d} {s} run an older one; replacing ", .{
                name, service.rec.generation, plan.stale, plural(plan.stale, "replica", "replicas"),
            });
            text.appendSlice(run.ctx.arena, head) catch return nomem(run.ctx);
        } else {
            const head = try controller.format(run.ctx, "service {s} wants {d} {s} and {d} " ++
                "remain (", .{ name, wanted, plural(wanted, "replica", "replicas"), keep });
            text.appendSlice(run.ctx.arena, head) catch return nomem(run.ctx);
        }
        for (removed, 0..) |item, index| {
            if (index > 0) text.appendSlice(run.ctx.arena, "; ") catch return nomem(run.ctx);
            const piece = try run.removal_phrase(item);
            text.appendSlice(run.ctx.arena, piece) catch return nomem(run.ctx);
        }
        if (plan.dead > 0) text.append(run.ctx.arena, ')') catch return nomem(run.ctx);
        return text.items;
    }

    fn removal_phrase(run: *Run, item: *const Item) Error![]const u8 {
        const id = item.replica.rec.id;
        if (item.class == .stale) return controller.format(run.ctx, "{s}", .{id});
        const exit = item.observed.?.rec.exit orelse records.Exit{ .kind = .lost };
        var buffer: [64]u8 = undefined;
        return controller.format(run.ctx, "{s} {s}", .{ id, records.exit_text(exit, &buffer) });
    }

    /// The decision and the delete for a replica whose container ended.
    fn remove_dead(run: *Run, batch: *Batch, item: *const Item) Error!DecisionId {
        const observed = item.observed.?;
        const replica = item.replica;
        const exit = observed.rec.exit orelse records.Exit{ .kind = .lost };
        var buffer: [64]u8 = undefined;
        const lost = exit.kind == .lost;
        const reason = if (lost)
            try controller.format(run.ctx, "{s} was lost on {s}: its supervisor or process " ++
                "vanished, so it is being removed", .{ replica.rec.id, replica.rec.node })
        else
            try controller.format(run.ctx, "{s} {s} on {s}, so it is being removed", .{
                replica.rec.id, records.exit_text(exit, &buffer), replica.rec.node,
            });
        const id = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = if (lost) "mark_replica_lost" else "delete_replica",
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = .{
                .kind = .observed,
                .key = observed.kv.key,
                .revision = observed.kv.mod_revision,
            },
            .cause_diagnostic = observed.rec.diagnostic,
        }, batch);
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        batch.delete(replica.kv.key);
        return id;
    }

    /// The decision and the delete for a replica that is to stop for a reason the service gave.
    fn remove_stale(
        run: *Run,
        batch: *Batch,
        item: *const Item,
        because: *const DecisionId,
        service: *const Entry(records.Service),
    ) Error!void {
        const replica = item.replica;
        const reason = try controller.format(run.ctx, "{s} is at generation {d}, and service " ++
            "{s} is at {d}", .{
            replica.rec.id, replica.rec.generation, service.rec.name, service.rec.generation,
        });
        try run.stop_replica(batch, replica, reason, because);
    }

    fn stop_replica(
        run: *Run,
        batch: *Batch,
        replica: *const Entry(records.Replica),
        reason: []const u8,
        because: *const DecisionId,
    ) Error!void {
        _ = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "stop_replica",
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = controller.cause_decision(because),
        }, batch);
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        batch.delete(replica.kv.key);
    }

    // ---- Creating ----

    /// Adds `count` replicas to `batch`, each with its decision, and moves the service's counter
    /// (`/replica-numbers/<service>`) in the same transaction, compared at the revision read
    /// (docs/keys.md).
    fn create_replicas(
        run: *Run,
        batch: *Batch,
        service: *const Entry(records.Service),
        because: *const DecisionId,
        count: u32,
    ) Error!void {
        if (count == 0) return;
        const counter = run.counter_of(service.rec.name);
        var next = if (counter) |found| found.rec.next else run.first_number(service);
        for (0..count) |_| {
            if (next > constants.replica_number_max) return run.numbers_used_up(service);
            const id = try controller.format(run.ctx, "{s}-{d}", .{ service.rec.name, next });
            const reason = try controller.format(run.ctx, "creating {s} (generation {d}) for " ++
                "service {s}", .{ id, service.rec.generation, service.rec.name });
            _ = try controller.put_decision(run.ctx, &run.rc.source, .{
                .actor = actor,
                .action = "create_replica",
                .subject = .{ .kind = .replica, .name = id },
                .reason = reason,
                .cause = controller.cause_decision(because),
            }, batch);
            const replica: records.Replica = .{
                .id = id,
                .service = service.rec.name,
                .generation = service.rec.generation,
                .node = "",
                .image = service.rec.image,
                .command = service.rec.command,
                .env = service.rec.env,
                .limits = service.rec.limits,
            };
            const key = records.replica_key(service.rec.name, id);
            const value = try records.encode(run.ctx.arena, replica, run.ctx.diag);
            batch.put(try controller.key_copy(run.ctx, &key), value);
            next += 1;
        }
        const counter_at = records.replica_numbers_key(service.rec.name);
        const key = try controller.key_copy(run.ctx, &counter_at);
        batch.expect(key, if (counter) |found| found.kv.mod_revision else 0);
        const number: records.ReplicaNumber = .{ .next = next };
        const bytes = try records.encode(run.ctx.arena, number, run.ctx.diag);
        batch.put(key, bytes);
    }

    fn counter_of(run: *Run, service: []const u8) ?*const NumberEntry {
        const key = records.replica_numbers_key(service);
        for (run.numbers) |*entry| {
            if (std.mem.eql(u8, entry.kv.key, key.slice())) return entry;
        }
        return null;
    }

    /// The first number of a service that has no counter yet: the larger of a v1 service
    /// record's `next_replica` and one past the highest replica number there is, so a number is
    /// never reused.
    fn first_number(run: *Run, service: *const ServiceEntry) u64 {
        var first: u64 = service.rec.next_replica orelse 1;
        for (run.snap.replicas) |replica| {
            if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
            const number = records.replica_number(service.rec.name, replica.rec.id) orelse continue;
            first = @max(first, @as(u64, number) + 1);
        }
        return first;
    }

    /// Deletes the counter of a service that is gone once none of its replicas remain.
    fn reconcile_numbers(run: *Run) Error!void {
        var batch: Batch = .{};
        for (run.numbers) |*entry| {
            const name = entry.kv.key[records.prefix_replica_numbers.len..];
            if (run.snap.service_of(name) != null) continue;
            if (run.has_replicas(name)) continue;
            if (batch.ops_count == batch_replicas_max) {
                run.more = true;
                break;
            }
            batch.expect(entry.kv.key, entry.kv.mod_revision);
            batch.delete(entry.kv.key);
        }
        if (batch.ops_count == 0) return;
        if (!run.budget()) return;
        _ = try run.finish(&batch);
    }

    fn has_replicas(run: *Run, service: []const u8) bool {
        for (run.snap.replicas) |replica| {
            if (std.mem.eql(u8, replica.rec.service, service)) return true;
        }
        return false;
    }

    fn numbers_used_up(run: *Run, service: *const Entry(records.Service)) error{NoCapacity} {
        run.ctx.diag.raise(.E0302);
        run.ctx.diag.cause("service {s} has used all {d} replica numbers", .{
            service.rec.name, constants.replica_number_max,
        });
        run.ctx.diag.fix(.{ .sentence = "delete the service and apply it again under a new name" });
        return error.NoCapacity;
    }

    fn scale_up(run: *Run, service: *const Entry(records.Service), keep: u32) Error!void {
        const wanted = service.rec.replicas;
        assert(keep < wanted);
        const creations = @min(batch_replicas_max, wanted - keep);
        if (!run.budget()) return;
        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        const reason = try controller.format(run.ctx, "service {s} wants {d} {s} and {d} exist", .{
            service.rec.name, wanted, plural(wanted, "replica", "replicas"), keep,
        });
        const decision = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "scale_up",
            .subject = .{ .kind = .service, .name = service.rec.name },
            .reason = reason,
            .cause = desired_cause(service),
        }, &batch);
        try run.create_replicas(&batch, service, &decision, creations);
        _ = try run.finish(&batch);
    }

    // ---- Removing ----

    fn scale_down(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!void {
        const wanted = service.rec.replicas;
        const keep = plan.live + plan.held;
        assert(keep > wanted);
        var victims: [constants.replicas_per_service_max]Item = undefined;
        var count: u32 = 0;
        for (plan.slice()) |item| {
            victims[count] = item;
            count += 1;
        }
        std.mem.sort(Item, victims[0..count], {}, by_victim_order);
        const taken = @min(batch_replicas_max, keep - wanted);
        if (!run.budget()) return;

        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        var names: std.ArrayList(u8) = .empty;
        for (victims[0..taken], 0..) |item, index| {
            if (index > 0) names.appendSlice(run.ctx.arena, ", ") catch return nomem(run.ctx);
            names.appendSlice(run.ctx.arena, item.replica.rec.id) catch return nomem(run.ctx);
        }
        const reason = try controller.format(run.ctx, "service {s} wants {d} {s} and {d} " ++
            "exist; removing {s}", .{
            service.rec.name, wanted, plural(wanted, "replica", "replicas"), keep, names.items,
        });
        const decision = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "scale_down",
            .subject = .{ .kind = .service, .name = service.rec.name },
            .reason = reason,
            .cause = desired_cause(service),
        }, &batch);
        for (victims[0..taken]) |item| {
            const why = try controller.format(run.ctx, "removing {s} to get from {d} to {d} {s}", .{
                item.replica.rec.id, keep, wanted, plural(wanted, "replica", "replicas"),
            });
            try run.stop_replica(&batch, item.replica, why, &decision);
        }
        _ = try run.finish(&batch);
    }

    /// Replicas whose service is gone: `scale_down` on the gone service, `stop_replica` for each.
    fn reconcile_orphans(run: *Run) Error!void {
        var gone: ?[]const u8 = null;
        var batch: Batch = .{};
        var decision: ?DecisionId = null;
        var count: u32 = 0;
        for (run.snap.replicas) |*replica| {
            if (run.snap.service_of(replica.rec.service) != null) continue;
            if (gone == null) gone = replica.rec.service;
            if (!std.mem.eql(u8, gone.?, replica.rec.service)) continue;
            if (count == batch_replicas_max) break;
            if (decision == null) decision = try run.deleted_decision(&batch, gone.?);
            const why = try controller.format(run.ctx, "stopping {s}: its service {s} was " ++
                "deleted", .{ replica.rec.id, gone.? });
            try run.stop_replica(&batch, replica, why, &decision.?);
            count += 1;
        }
        if (count == 0) return;
        if (!run.budget()) return;
        _ = try run.finish(&batch);
    }

    fn deleted_decision(run: *Run, batch: *Batch, service: []const u8) Error!DecisionId {
        const reason = try controller.format(run.ctx, "service {s} was deleted; stopping its " ++
            "replicas", .{service});
        const key = records.service_key(service);
        return controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "scale_down",
            .subject = .{ .kind = .service, .name = service },
            .reason = reason,
            .cause = .{
                .kind = .desired,
                .key = try controller.key_copy(run.ctx, &key),
                .revision = run.snap.revision,
            },
        }, batch);
    }

    // ---- Scheduling ----

    fn place_unplaced(run: *Run) Error!void {
        var batch: Batch = .{};
        var placed: u32 = 0;
        var loads: [constants.nodes_max]Load = undefined;
        const nodes = run.snap.nodes;
        for (nodes, 0..) |node, index| loads[index] = load_of(run.snap, node.rec);
        for (run.snap.replicas) |*replica| {
            if (replica.rec.node.len != 0) continue;
            if (run.snap.service_of(replica.rec.service) == null) continue;
            if (placed == batch_places_max) break;
            const chosen = choose_node(run.snap, replica, loads[0..nodes.len]) orelse continue;
            try run.place(&batch, replica, nodes[chosen].rec, loads[chosen..][0..1]);
            placed += 1;
        }
        if (placed == 0) return;
        if (!run.budget()) return;
        _ = try run.finish(&batch);
    }

    fn place(
        run: *Run,
        batch: *Batch,
        replica: *const Entry(records.Replica),
        node: records.Node,
        load: []Load,
    ) Error!void {
        const need = requests_of(&replica.rec);
        const defaulted = replica.rec.limits.cpu_millis == null or
            replica.rec.limits.memory_bytes == null;
        const node_count: u32 = @intCast(run.snap.nodes.len);
        const reason = try run.place_reason(node, need, defaulted, node_count);
        const created = try run.create_decision_of(replica.rec.id);
        const cause: records.Cause = if (created) |*id| controller.cause_decision(id) else .{
            .kind = .resync,
        };
        _ = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = scheduler_actor,
            .action = "place_replica",
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = cause,
        }, batch);
        var placed = replica.rec;
        placed.node = node.name;
        placed.requests = need;
        const value = try records.encode(run.ctx.arena, placed, run.ctx.diag);
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        batch.put(replica.kv.key, value);
        load[0].cpu += need.cpu_millis;
        load[0].memory += need.memory_bytes;
        load[0].count += 1;
    }

    fn place_reason(
        run: *Run,
        node: records.Node,
        need: records.Requests,
        defaulted: bool,
        node_count: u32,
    ) Error![]const u8 {
        const mib = @divFloor(need.memory_bytes, 1024 * 1024);
        const note = if (defaulted) " (a default: the service sets no limits)" else "";
        if (node_count == 1) {
            return controller.format(run.ctx, "{s} is the only node, and it fits {d}m CPU and " ++
                "{d} MiB{s}", .{ node.name, need.cpu_millis, mib, note });
        }
        return controller.format(run.ctx, "{s} has the fewest replicas of this service of the " ++
            "{d} nodes, and it fits {d}m CPU and {d} MiB{s}", .{
            node.name, node_count, need.cpu_millis, mib, note,
        });
    }

    /// The id of the decision that created a replica, read from its by-subject index.
    fn create_decision_of(run: *Run, replica: []const u8) Error!?DecisionId {
        const ctx = run.ctx;
        const prefix = records.index_prefix(.replica, replica);
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = 8,
        }, ctx.diag);
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
            if (!std.mem.eql(u8, entry.action, "create_replica")) continue;
            var id: DecisionId = .{};
            if (entry.id.len != records.decision_id_bytes) continue;
            @memcpy(&id.bytes, entry.id);
            return id;
        }
        return null;
    }
};

// ---- Pure helpers ------------------------------------------------------------------------------

fn by_number(context: void, first: Item, second: Item) bool {
    _ = context;
    return first.number < second.number;
}

/// Victims first: replicas that are not running, then the newest (highest number).
fn by_victim_order(context: void, first: Item, second: Item) bool {
    _ = context;
    if (first.running != second.running) return !first.running;
    return first.number > second.number;
}

fn classify_one(replica_generation: u64, service_generation: u64, observed: ?*const Entry(
    records.Observed,
)) Class {
    if (replica_generation < service_generation) return .stale;
    const found = observed orelse return .live;
    if (found.rec.status != .stopped) return .live;
    if (user_fault(&found.rec)) return .held;
    return .dead;
}

/// A start that failed through the user's fault: the diagnostic the runtime gave says `user`.
fn user_fault(observed: *const records.Observed) bool {
    const exit = observed.exit orelse return false;
    if (exit.kind != .start_failed) return false;
    const raw = observed.diagnostic orelse return false;
    var diagnostic: records.Diagnostic = undefined;
    if (!records.diagnostic_parse(&diagnostic, raw)) return false;
    return diagnostic.blame == .user;
}

fn desired_cause(service: *const Entry(records.Service)) records.Cause {
    return .{ .kind = .desired, .key = service.kv.key, .revision = service.kv.mod_revision };
}

fn plural(count: u32, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

fn nomem(ctx: *const Context) error{NoCapacity} {
    return @import("store_failures.zig").no_memory(ctx.diag);
}

/// What the scheduler resolves a replica to need: its limits, else the default.
pub fn requests_of(replica: *const records.Replica) records.Requests {
    return .{
        .cpu_millis = replica.limits.cpu_millis orelse constants.request_default_cpu_millis,
        .memory_bytes = replica.limits.memory_bytes orelse constants.request_default_memory_bytes,
    };
}

/// A node's used capacity, from the replicas assigned to it.
const Load = struct { cpu: u64, memory: u64, count: u32 };

fn load_of(snapshot: *const Snapshot, node: records.Node) Load {
    var load: Load = .{ .cpu = 0, .memory = 0, .count = 0 };
    for (snapshot.replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.node, node.name)) continue;
        const need = replica.rec.requests orelse requests_of(&replica.rec);
        load.cpu += need.cpu_millis;
        load.memory += need.memory_bytes;
        load.count += 1;
    }
    return load;
}

/// The node for a replica: one whose capacity fits it, with the fewest replicas of the same
/// service, then the lowest name. Null if none fits.
fn choose_node(
    snapshot: *const Snapshot,
    replica: *const ReplicaEntry,
    loads: []const Load,
) ?usize {
    const need = requests_of(&replica.rec);
    var best: ?usize = null;
    var best_count: u32 = 0;
    for (snapshot.nodes, 0..) |node, index| {
        const fits_cpu = loads[index].cpu + need.cpu_millis <= node.rec.capacity.cpu_millis;
        const memory_after = loads[index].memory + need.memory_bytes;
        const fits_memory = memory_after <= node.rec.capacity.memory_bytes;
        if (!fits_cpu) continue;
        if (!fits_memory) continue;
        const count = service_count_on(snapshot, node.rec.name, replica.rec.service);
        if (best == null or count < best_count) {
            best = index;
            best_count = count;
        }
    }
    return best;
}

fn service_count_on(snapshot: *const Snapshot, node: []const u8, service: []const u8) u32 {
    var count: u32 = 0;
    for (snapshot.replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.node, node)) continue;
        if (std.mem.eql(u8, replica.rec.service, service)) count += 1;
    }
    return count;
}
