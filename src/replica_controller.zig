//! The service and replica controller of C0: it keeps `/replicas/<service>/*` matching
//! `/services/<name>`. It does not place them (`scheduler.zig` does). One step, level-triggered and
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
//!   - a replica placed on a node that is `lost` (and not registered again since), once
//!     `lost_grace_ms` has passed since the node controller's `mark_lost`: `mark_replica_lost`
//!     caused by that `mark_lost`, then `replace_replica` and a new replica under a **new id**
//!     (authority.md §3: ids are never reused, so the old instance on a partitioned node is never
//!     taken for the new one); the scheduler then releases the old assignment;
//!   - a replica whose start failed through the user's fault (the diagnostic's blame is `user`):
//!     it is **held**, with a `hold_failed_replica` decision on the service, and neither retried
//!     nor replaced; a new `generation` of the service replaces it;
//!   - a replica behind its service's `generation`, or whose image, source, command, env or
//!     limits are not the service's: replaced (a change of the replica count alone does not bump
//!     `generation`, so scaling never replaces what runs; the spec is compared as well because a
//!     service deleted and applied again between two steps restarts at generation 1);
//!   - replicas of a service that no longer exists: `scale_down` on the (gone) service and
//!     `stop_replica` for each;
//!
//! A transaction touches at most `batch_replicas_max` replicas, so a big change takes several
//! steps; each leaves the system in a state the next step can continue from.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const retention = @import("retention.zig");
const pull_retention = @import("pull_retention.zig");
const records = @import("records.zig");
const rollout_controller = @import("rollout_controller.zig");
const rollout_plan = @import("rollout_plan.zig");
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

/// Replicas one transaction creates or removes: `decision_ops` operations for the service
/// decision, `decision_ops + 1` for each replica (its decision, and the replica record or its
/// delete), and 1 for the counter.
const batch_replicas_max: u32 = 2;
/// Distinct nodes whose judgement one removing transaction rests on (a lost node, or a ready one
/// a cited report came from): each costs two compares (its status and its `/nodes` record),
/// which a batch of `batch_replicas_max` replicas on three nodes would push past
/// `store_txn_compares_max`. A replica on a further node waits for the next pass.
const judged_nodes_batch_max: u32 = 2;
/// Holds one transaction writes: three compares each (the summary, the report, the assignment)
/// and two for its node, which `store_txn_compares_max` allows for this many.
const hold_batch_max: u32 = 2;
const resync_ms: u64 = 30 * 1000;

pub const watch_prefixes = [_][]const u8{
    records.prefix_services,
    records.prefix_replicas,
    records.prefix_observed,
    records.prefix_assigned,
    records.prefix_replica_numbers,
    records.prefix_node_status,
    records.prefix_rollouts,
};

comptime {
    const decision = controller.decision_ops;
    assert(decision + batch_replicas_max * (decision + 1) + 1 <= constants.store_txn_ops_max);
    // The operations no longer bind (the decision's own compare does, below): one more replica
    // would fit them but not the compares.
    // The service, the counter and the service decision's summary; per replica its key, its
    // assignment and its decision's summary; and per lost node, once however many of its
    // replicas the batch removes, the node's status and its `/nodes` record.
    const fixed = 2 + controller.decision_compares;
    const per_replica = 2 + controller.decision_compares;
    const per_judged_node = 2;
    assert(fixed + batch_replicas_max * per_replica + judged_nodes_batch_max * per_judged_node <=
        constants.store_txn_compares_max);
    // One more lost node would not fit, so the limit is what the store allows, not slack.
    assert(fixed + batch_replicas_max * per_replica +
        (judged_nodes_batch_max + 1) * per_judged_node > constants.store_txn_compares_max);
    assert(fixed + (batch_replicas_max + 1) * per_replica +
        judged_nodes_batch_max * per_judged_node > constants.store_txn_compares_max);
    assert(judged_nodes_batch_max <= batch_replicas_max);
    const per_hold = controller.decision_compares + 2 + per_judged_node;
    assert(hold_batch_max * per_hold <= constants.store_txn_compares_max);
}

pub const ReplicaController = struct {
    source: controller.DecisionSource,
    retention: retention.Cursor = .{},
    pulls: pull_retention.Cursor = .{},
    /// How long after a node is marked lost its replicas are replaced (authority.md §2, §3). A
    /// parameter so the server (`--lost-grace-ms`), the simulations and the tests can set it.
    lost_grace_ms: u64 = constants.lost_grace_ms,

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
        var run: Run = .{
            .rc = rc,
            .ctx = ctx,
            .snap = &snapshot,
            .txns_left = constants.controller_txns_per_step_max,
        };
        for (snapshot.services) |*service| try run.reconcile_service(service);
        try run.reconcile_orphans();
        if (now >= rc.retention.due_ms) {
            rc.retention.due_ms = try retention.prune(ctx, &rc.retention, &snapshot, now);
        }
        if (now >= rc.pulls.due_ms) {
            // Statistics: a failed pass is recorded and retried later, never the step's failure.
            rc.pulls.due_ms = pull_retention.prune_or_back_off(ctx, &rc.pulls, now);
        }
        const again = run.more or run.acted > 0;
        var wake_at = @min(now + resync_ms, run.wake_at_ms);
        if (again) wake_at = now;
        if (rc.retention.due_ms < wake_at) wake_at = @max(rc.retention.due_ms, now);
        if (rc.pulls.due_ms < wake_at) wake_at = @max(rc.pulls.due_ms, now);
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
    /// Not reported stopped and not on a lost node: it counts toward the surge bound.
    live: bool = true,
    number: u32,
    /// The status of the lost node the replica is placed on, once its grace has passed.
    lost: ?*const Entry(records.NodeStatus) = null,
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

const RolloutEntry = Entry(records.Rollout);

/// What a service's rollout allows this pass (`Run.roll_of`).
const Roll = struct {
    policy: rollout_plan.Policy,
    /// The rollout of the service's generation, if there is one.
    rollout: ?RolloutEntry = null,
    /// Replicas that count toward the surge bound: live replicas of the service and reports
    /// of replicas being retired that are not yet stopped.
    live: u32 = 0,
    /// Replicas reported running on a ready node (R1's count).
    up: u32 = 0,
    /// Replicas that may be created before the surge bound: unbounded with no rollout.
    room: u32 = std.math.maxInt(u32),
    /// The rollout starts and retires replicas (progressing or rolling back), or there is none.
    starts: bool = true,
    /// The rollout is paused: nothing new starts.
    paused: bool = false,
};

const Run = struct {
    rc: *ReplicaController,
    ctx: *const Context,
    snap: *const Snapshot,
    txns_left: u32,
    acted: u32 = 0,
    /// Work is left for the next step (a conflict, a spent budget, a partial change).
    more: bool = false,
    /// The earliest end of a lost node's grace, for a replica still placed on it.
    wake_at_ms: u64 = std.math.maxInt(u64),

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
        if (try run.seed_counter(service)) return;
        var plan: ServicePlan = .{};
        try run.classify(service, &plan);
        if (!try run.hold_pass(service, &plan)) return;
        const roll = try run.roll_of(service, &plan);
        if (plan.dead > 0) return run.replace(service, &plan, &roll);
        if (plan.stale > 0 and roll.starts) return run.roll_out(service, &plan, &roll);
        // A halted rollout (failed or paused) keeps its stale replicas, which then count as
        // any other toward what the service asks for.
        const keep = plan.live + plan.held + plan.stale;
        if (keep < service.rec.replicas) return run.scale_up(service, keep, &roll);
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
            const observed = run.admissible(run.snap.observed_of(&replica.rec));
            var item: Item = .{
                .replica = replica,
                .observed = observed,
                .class = .live,
                .running = false,
                .number = number,
            };
            item.class = classify_one(&replica.rec, &service.rec, observed);
            item.live = rollout_controller.live_report(run.snap, &replica.rec);
            if (item.class == .live or item.class == .stale) {
                item.lost = run.lost_placement(replica.rec.id);
                if (item.lost != null) item.class = .dead;
            }
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

    /// `found` if the controller may act on it (authority.md section 3), else null: the replica is
    /// then treated as not reported, and the node controller's judgement decides what happens to
    /// it. A C1 report carries the tenure it was written under, the node's `/nodes` record must
    /// still have that revision, the report's placement epoch (if it names one) must be the
    /// assignment's revision, and the node's status must be `ready`. A C0 report carries no
    /// tenure and is taken as it is.
    fn admissible(run: *Run, found: ?*const Entry(records.Observed)) ?*const Entry(
        records.Observed,
    ) {
        return admissible_in(run.snap, found);
    }

    /// The status of the node `replica` is placed on, if that node is lost for the tenure the
    /// status judged (no newer `/nodes` record) and the grace has passed; before then, the step
    /// wakes at the grace's end.
    fn lost_placement(run: *Run, replica: []const u8) ?*const Entry(records.NodeStatus) {
        const node = run.snap.node_of(replica) orelse return null;
        const status = run.snap.status_of(node) orelse return null;
        if (status.rec.state != .lost) return null;
        if (run.snap.node_entry(node)) |entry| {
            // Registered again: the node controller judges the new tenure first.
            if (entry.kv.mod_revision > status.rec.tenure) return null;
        }
        const due = status.rec.at_ms +| run.rc.lost_grace_ms;
        if (run.ctx.clock.now_ms() < due) {
            run.wake_at_ms = @min(run.wake_at_ms, due);
            return null;
        }
        return status;
    }

    // ---- Holding a failed start ----

    /// Writes a `hold_failed_replica` decision for each held replica that has none for its current
    /// observed record. False if the transaction did not commit (the step stops for this service).
    fn hold_pass(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!bool {
        var batch: Batch = .{};
        var holds: u32 = 0;
        for (plan.slice()) |item| {
            if (item.class != .held) continue;
            if (holds == hold_batch_max) break;
            const observed = item.observed.?;
            if (try run.already_held(service.rec.name, observed)) continue;
            if (!batch.has_room(controller.decision_ops)) break;
            holds += 1;
            // Each hold compares its report and the assignment it was found through, and the
            // node it rests on once: `hold_batch_max` holds fit `store_txn_compares_max`.
            batch.expect(observed.kv.key, observed.kv.mod_revision);
            const placed = run.snap.assigned_of(item.replica.rec.id).?;
            batch.expect(placed.kv.key, placed.kv.mod_revision);
            if (judged_by_status(observed)) try run.expect_node_judged(&batch, observed.rec.node);
            const reason = try controller.format(run.ctx, "replica {s} failed to start on {s}; " ++
                "it was not replaced because a new one would fail the same way", .{
                item.replica.rec.id, observed.rec.node,
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
                .cause_evidence = try evidence.observed(run.ctx, &observed.rec),
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

    /// Removes up to a batch of dead replicas and creates their replacements. Stale replicas are
    /// the rollout's (`roll_out`). While a service has stale replicas, a transaction removes one
    /// dead replica, so its replacement always fits: a replica of the service's generation is
    /// replaced whatever the rollout's phase (R4), a stale one only while the rollout starts
    /// replicas, and neither past the surge bound (R2).
    fn replace(
        run: *Run,
        service: *const ServiceEntry,
        plan: *const ServicePlan,
        roll: *const Roll,
    ) Error!void {
        var removed: [batch_replicas_max]*const Item = undefined;
        var removed_count: u32 = 0;
        var lost_nodes: [judged_nodes_batch_max][]const u8 = undefined;
        var lost_nodes_count: u32 = 0;
        const removals_max: u32 = if (plan.stale > 0) 1 else batch_replicas_max;
        for (plan.slice()) |*item| {
            if (item.class != .dead) continue;
            if (removed_count == removals_max) break;
            if (judged_node(item)) |node| {
                if (!note_node(lost_nodes[0..], &lost_nodes_count, node)) continue;
            }
            removed[removed_count] = item;
            removed_count += 1;
        }
        const keep = plan.live + plan.held;
        const wanted = service.rec.replicas;
        const missing = if (wanted > keep) wanted - keep else 0;
        var creations = @min(batch_replicas_max - removed_count, missing);
        // A replica that failed on its own is replaced, of either generation, without waiting
        // for the rollout's budget (c3.md): only the surge bound applies. Stale replicas still
        // missing are the rollout's to start.
        if (plan.stale > 0) creations = @min(creations, removed_count);
        creations = @min(creations, roll.room);
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
            .cause_evidence = if (first_dead == null)
                try evidence.service(run.ctx, &service.rec)
            else
                null,
        }, &batch);
        try run.create_replicas(&batch, service, &decision, creations);
        _ = try run.finish(&batch);
    }

    // ---- Rolling out (C3 slice 7) ----

    /// The service's rollout as this pass reads it (`/rollouts/<service>` at the snapshot's
    /// revision), if it is one of this incarnation and generation, and what it allows.
    fn roll_of(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!Roll {
        var roll: Roll = .{ .policy = service.rec.rollout_policy() };
        var live = rollout_controller.stopping_orphans(run.snap, service.rec.name);
        for (plan.slice()) |item| {
            if (item.class == .dead or item.class == .held) continue;
            if (item.live) live += 1;
            if (item.running and item.lost == null) roll.up += 1;
        }
        roll.live = live;
        const key = records.rollout_key(service.rec.name);
        const ctx = run.ctx;
        const got = try ctx.store.get(ctx.arena, key.slice(), run.snap.revision, ctx.diag);
        const kv = got.kv orelse return roll;
        const rec = try records.read(records.Rollout, run.ctx.arena, kv, run.ctx.diag);
        if (!records.rollout_of(&rec, service.kv.create_revision)) return roll;
        if (rec.to != service.rec.generation) return roll;
        roll.rollout = .{ .kv = kv, .rec = rec };
        const live_max = service.rec.replicas + roll.policy.max_surge;
        roll.room = live_max -| live;
        roll.starts = rollout_plan.active(rec.phase) or c1_teeth.rollout_pause;
        roll.paused = rec.phase == .paused and !c1_teeth.rollout_pause;
        return roll;
    }

    /// Spends the rollout's budget on the service's stale replicas: starts new ones within
    /// `budget.start` (less what the counter moved since the budget was computed) and retires old
    /// ones within `budget.retire` (a running one) and `budget.retire_unready` (one that is not
    /// running), less what was retired since; one that is not live costs nothing. A running one is
    /// retired only while the replicas running stay at `replicas - max_unavailable` or above
    /// (R1). Nothing happens without a rollout of the service's generation whose budget was
    /// computed on the service as it is, or while the rollout is paused or failed (R4).
    fn roll_out(
        run: *Run,
        service: *const ServiceEntry,
        plan: *const ServicePlan,
        roll: *const Roll,
    ) Error!void {
        const rollout = roll.rollout orelse return;
        if (!roll.starts) return;
        if (service.kv.mod_revision > rollout.rec.budget_revision) return;
        const counter = try run.counter_of(service.rec.name);
        const keep = plan.live + plan.held;
        const missing = service.rec.replicas -| keep;
        var creations = @min(@min(run.starts_left(&rollout, counter), missing), roll.room);
        creations = @min(creations, batch_replicas_max);
        var retired: [batch_replicas_max]*const Item = undefined;
        const retired_count = run.choose_retired(
            service,
            plan,
            roll,
            retired[0 .. batch_replicas_max - creations],
        );
        if (creations + retired_count == 0) return;
        if (!run.budget()) return;
        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        if (!c1_teeth.rollout_budget) batch.expect(rollout.kv.key, rollout.kv.mod_revision);
        const why = if (retired_count > 0)
            try run.replace_reason(service, plan, retired[0..retired_count], keep)
        else
            try controller.format(run.ctx, "the rollout of {s} to generation {d} may start " ++
                "{d} new {s}", .{
                service.rec.name, service.rec.generation,
                creations,        plural(creations, "replica", "replicas"),
            });
        const decision = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "replace_replica",
            .subject = .{ .kind = .service, .name = service.rec.name },
            .reason = why,
            .cause = rollout_cause(&rollout.rec, service),
        }, &batch);
        for (retired[0..retired_count]) |item| {
            try run.remove_stale(&batch, item, &decision, service);
        }
        try run.create_replicas(&batch, service, &decision, creations);
        _ = try run.finish(&batch);
    }

    /// New replicas the budget still allows: `budget.start` less the numbers the counter handed
    /// out since the budget was computed (any creation since then is counted against it).
    fn starts_left(run: *Run, rollout: *const RolloutEntry, counter: ?NumberEntry) u32 {
        _ = run;
        const start = rollout.rec.budget.start;
        if (c1_teeth.rollout_budget) return start;
        const now: ?u64 = if (counter) |found| found.rec.next else null;
        const then = rollout.rec.budget_next orelse return if (now == null) start else 0;
        const used = (now orelse then) -| then;
        return @intCast(@as(u64, start) -| used);
    }

    /// Picks the stale replicas to retire in this transaction into `out`; returns how many.
    fn choose_retired(
        run: *Run,
        service: *const ServiceEntry,
        plan: *const ServicePlan,
        roll: *const Roll,
        out: []*const Item,
    ) u32 {
        _ = run;
        const rollout = &roll.rollout.?.rec;
        const used = rollout.budget_old -| plan.stale;
        var ready_left = rollout.budget.retire -| used;
        var unready_left = (rollout.budget.retire + rollout.budget.retire_unready) -| used;
        const ready_min = service.rec.replicas -| roll.policy.max_unavailable;
        const rolling = roll.policy.strategy == .rolling;
        var up = roll.up;
        var count: u32 = 0;
        // The cheapest first: not live, then live and not running, then running.
        for ([_]u8{ 0, 1, 2 }) |cost| {
            for (plan.slice()) |*item| {
                if (count == out.len) return count;
                if (item.class != .stale) continue;
                const running = item.running and item.lost == null;
                const item_cost: u8 = if (!item.live) 0 else if (!running) 1 else 2;
                if (item_cost != cost) continue;
                if (c1_teeth.rollout_budget) {
                    out[count] = item;
                    count += 1;
                    continue;
                }
                if (cost == 1 and unready_left == 0) continue;
                if (cost == 2) {
                    if (ready_left == 0) continue;
                    if (rolling and up -| 1 < ready_min) continue;
                    up -|= 1;
                }
                if (cost > 0) {
                    unready_left -|= 1;
                    ready_left -|= 1;
                }
                out[count] = item;
                count += 1;
            }
        }
        return count;
    }

    /// Counts `node` among the nodes whose status the batch compares. False if it is a new one and
    /// the batch already has `judged_nodes_batch_max` (the compare budget).
    fn note_node(
        nodes: [][]const u8,
        count: *u32,
        node: []const u8,
    ) bool {
        for (nodes[0..count.*]) |known| {
            if (std.mem.eql(u8, known, node)) return true;
        }
        if (count.* == nodes.len) return false;
        nodes[count.*] = node;
        count.* += 1;
        return true;
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
            // A stale replica is behind in generation, or ahead of or equal to it and running
            // another spec (a service applied again starts over at generation 1): say only
            // what holds for every one of them.
            const what = if (stale_behind(plan, service) == plan.stale)
                "run an older one"
            else
                "do not run what it asks for";
            const head = try controller.format(run.ctx, "service {s} is at generation {d} and " ++
                "{d} {s} {s}; replacing ", .{
                name,
                service.rec.generation,
                plan.stale,
                plural(plan.stale, "replica", "replicas"),
                what,
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
        if (item.lost) |status| {
            const node = status.kv.key[records.prefix_node_status.len..];
            return controller.format(run.ctx, "{s} lost with node {s}", .{ id, node });
        }
        const exit = item.observed.?.rec.exit orelse records.Exit{ .kind = .lost };
        var buffer: [64]u8 = undefined;
        return controller.format(run.ctx, "{s} {s}", .{ id, records.exit_text(exit, &buffer) });
    }

    /// The decision and the delete for a replica whose container ended.
    fn remove_dead(run: *Run, batch: *Batch, item: *const Item) Error!DecisionId {
        if (item.lost) |status| return run.remove_lost(batch, item.replica, status);
        const observed = item.observed.?;
        const replica = item.replica;
        const exit = observed.rec.exit orelse records.Exit{ .kind = .lost };
        var buffer: [64]u8 = undefined;
        const lost = exit.kind == .lost;
        const reason = if (lost)
            try controller.format(run.ctx, "{s} was lost on {s}: its supervisor or process " ++
                "vanished, so it is being removed", .{ replica.rec.id, observed.rec.node })
        else
            try controller.format(run.ctx, "{s} {s} on {s}, so it is being removed", .{
                replica.rec.id, records.exit_text(exit, &buffer), observed.rec.node,
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
            .cause_evidence = .{ .text = try exit_evidence(run.ctx, exit) },
        }, batch);
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        // The observed record was found through the assignment: if the replica moved, the
        // judgement was about another placement, so the assignment is in the read set.
        const placed = run.snap.assigned_of(replica.rec.id).?;
        batch.expect(placed.kv.key, placed.kv.mod_revision);
        // The report was admissible because the node was ready under the tenure it names. The
        // report's own key is not compared: the compare budget has no room for it, and any change
        // to what it says is a new tenure, a new placement or a new status, all of which are.
        if (judged_by_status(observed)) try run.expect_node_judged(batch, observed.rec.node);
        batch.delete(replica.kv.key);
        return id;
    }

    /// The decision and the delete for a replica on a node lost past its grace, caused by the
    /// node's `mark_lost`. Compared: the replica, its assignment (the placement judged) and the
    /// node's status (still the `lost` that was read).
    fn remove_lost(
        run: *Run,
        batch: *Batch,
        replica: *const ReplicaEntry,
        status: *const Entry(records.NodeStatus),
    ) Error!DecisionId {
        const node = status.kv.key[records.prefix_node_status.len..];
        const reason = try controller.format(run.ctx, "{s} was on node {s}, lost {d} ms ago; " ++
            "it is being removed and replaced under a new id", .{
            replica.rec.id, node, run.ctx.clock.now_ms() -| status.rec.at_ms,
        });
        const id = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "mark_replica_lost",
            .subject = .{ .kind = .replica, .name = replica.rec.id },
            .reason = reason,
            .cause = .{ .kind = .decision, .id = status.rec.decision },
        }, batch);
        batch.expect(replica.kv.key, replica.kv.mod_revision);
        const placed = run.snap.assigned_of(replica.rec.id).?;
        batch.expect(placed.kv.key, placed.kv.mod_revision);
        try run.expect_node_judged(batch, node);
        batch.delete(replica.kv.key);
        return id;
    }

    /// Compares what the judgement of a node rests on: its status at the revision read (`lost`
    /// for a removal off a lost node, `ready` for one that cites a report) and its `/nodes`
    /// record as read (absent is revision 0). Once per node per batch: a second replica of the
    /// node adds nothing.
    fn expect_node_judged(run: *Run, batch: *Batch, node: []const u8) Error!void {
        // Test-only fault (the sim-c1-teeth-stale negative test): the node's status and
        // registration are not compared, so a report that went stale before the commit is acted on.
        if (c1_teeth.stale_observation) return;
        const status = run.snap.status_of(node).?;
        for (batch.compares[0..batch.compares_count]) |compare| {
            if (std.mem.eql(u8, compare.key, status.kv.key)) return;
        }
        batch.expect(status.kv.key, status.kv.mod_revision);
        const registered = run.snap.node_entry(node);
        const key = records.node_key(node);
        batch.expect(
            try controller.key_copy(run.ctx, &key),
            if (registered) |entry| entry.kv.mod_revision else 0,
        );
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
        const behind = replica.rec.generation < service.rec.generation;
        const reason = if (behind)
            try controller.format(run.ctx, "{s} is at generation {d}, and service " ++
                "{s} is at {d}", .{
                replica.rec.id, replica.rec.generation, service.rec.name, service.rec.generation,
            })
        else
            try controller.format(run.ctx, "{s} (generation {d}) does not run what service " ++
                "{s} (generation {d}) asks for: it is left from before the service was " ++
                "applied again", .{
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
        const counter = try run.counter_of(service.rec.name);
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
                .image = service.rec.image,
                .command = service.rec.command,
                .env = service.rec.env,
                .limits = service.rec.limits,
                .source = service.rec.source,
                .health = service.rec.health,
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

    /// A service record that still carries a C0 `next_replica` gets its counter at once, not
    /// only when it next needs a replica: a C0 service at full count that is deleted and applied
    /// again would otherwise start from 1 and reuse an id. True if it tried (the next pass goes
    /// on); false if there was nothing to seed.
    fn seed_counter(run: *Run, service: *const ServiceEntry) Error!bool {
        if (service.rec.next_replica == null) return false;
        if (try run.counter_of(service.rec.name) != null) return false;
        if (!run.budget()) return true;
        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        try run.put_counter(&batch, service.rec.name, run.first_number(service));
        _ = try run.finish(&batch);
        return true;
    }

    /// Creates a counter that is absent at the snapshot's revision (compared as absent).
    fn put_counter(run: *Run, batch: *Batch, service: []const u8, next: u64) Error!void {
        const counter_at = records.replica_numbers_key(service);
        const key = try controller.key_copy(run.ctx, &counter_at);
        batch.expect(key, 0);
        const number: records.ReplicaNumber = .{ .next = next };
        batch.put(key, try records.encode(run.ctx.arena, number, run.ctx.diag));
    }

    /// The service's counter at the snapshot's revision, or null if it has none. One read per
    /// service about to get replicas; the counters are never listed, so how many there are
    /// bounds nothing.
    fn counter_of(run: *Run, service: []const u8) Error!?NumberEntry {
        const key = records.replica_numbers_key(service);
        const got = try run.ctx.store.get(
            run.ctx.arena,
            key.slice(),
            run.snap.revision,
            run.ctx.diag,
        );
        const kv = got.kv orelse return null;
        const rec = try records.read(records.ReplicaNumber, run.ctx.arena, kv, run.ctx.diag);
        return .{ .kv = kv, .rec = rec };
    }

    /// The first number of a service that has no counter yet: the larger of a v1 service
    /// record's `next_replica` and one past the highest replica number there is, so a number is
    /// never reused. A counter is never deleted (one small key per service name ever applied), so
    /// this runs only for a name never counted before.
    fn first_number(run: *Run, service: *const ServiceEntry) u64 {
        return @max(service.rec.next_replica orelse 1, run.past_highest(service.rec.name));
    }

    /// One past the highest replica number of `service` in the snapshot, or 1 if it has none.
    fn past_highest(run: *Run, service: []const u8) u64 {
        var first: u64 = 1;
        for (run.snap.replicas) |replica| {
            if (!std.mem.eql(u8, replica.rec.service, service)) continue;
            const number = records.replica_number(service, replica.rec.id) orelse continue;
            first = @max(first, @as(u64, number) + 1);
        }
        return first;
    }

    fn numbers_used_up(run: *Run, service: *const Entry(records.Service)) error{NoCapacity} {
        run.ctx.diag.raise(.E0302);
        run.ctx.diag.cause("service {s} has used all {d} replica numbers", .{
            service.rec.name, constants.replica_number_max,
        });
        run.ctx.diag.fix(.{ .sentence = "delete the service and apply it again under a new name" });
        return error.NoCapacity;
    }

    /// Creates the replicas the service lacks: past the surge bound only once the replicas
    /// being retired are observed stopped (R2), and none while its rollout is paused (R4).
    fn scale_up(
        run: *Run,
        service: *const Entry(records.Service),
        keep: u32,
        roll: *const Roll,
    ) Error!void {
        const wanted = service.rec.replicas;
        assert(keep < wanted);
        if (roll.paused) return;
        const creations = @min(@min(batch_replicas_max, wanted - keep), roll.room);
        if (creations == 0) return;
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
            .cause_evidence = try evidence.service(run.ctx, &service.rec),
        }, &batch);
        try run.create_replicas(&batch, service, &decision, creations);
        _ = try run.finish(&batch);
    }

    // ---- Removing ----

    fn scale_down(run: *Run, service: *const ServiceEntry, plan: *const ServicePlan) Error!void {
        const wanted = service.rec.replicas;
        const keep = plan.live + plan.held + plan.stale;
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
            .cause_evidence = try evidence.service(run.ctx, &service.rec),
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
        // A deleted service that never had a counter (deleted before the seeding pass) leaves
        // one past its highest replica, so a re-apply cannot reuse an id.
        if (try run.counter_of(gone.?) == null) {
            try run.put_counter(&batch, gone.?, run.past_highest(gone.?));
        }
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
            .cause_evidence = try evidence.deleted_service(run.ctx, service),
        }, batch);
    }
};

// ---- Pure helpers ------------------------------------------------------------------------------

/// `found` if a controller may act on it (authority.md section 3), else null: see
/// `Run.admissible`. The rollout controller judges readiness on the same reports.
pub fn admissible_in(
    snap: *const Snapshot,
    found: ?*const Entry(records.Observed),
) ?*const Entry(records.Observed) {
    const entry = found orelse return null;
    const tenure = entry.rec.tenure orelse return entry;
    const node = snap.node_entry(entry.rec.node) orelse return null;
    if (node.kv.mod_revision != tenure) return null;
    if (entry.rec.assignment) |epoch| {
        const placed = snap.assigned_of(entry.rec.replica) orelse return null;
        if (placed.kv.mod_revision != epoch) return null;
    }
    const status = snap.status_of(entry.rec.node) orelse return null;
    if (status.rec.state != .ready) return null;
    return entry;
}

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

/// Whether the controller judged `observed` admissible from the node's status and tenure (a C1
/// report); a C0 report has no tenure and nothing to compare.
fn judged_by_status(observed: *const Entry(records.Observed)) bool {
    return observed.rec.tenure != null;
}

/// The node whose status and `/nodes` record the removal of `item` compares: the lost node, or the
/// ready one an exit report came from.
fn judged_node(item: *const Item) ?[]const u8 {
    if (item.lost) |status| return status.kv.key[records.prefix_node_status.len..];
    const observed = item.observed orelse return null;
    if (item.class != .dead) return null;
    if (!judged_by_status(observed)) return null;
    return observed.rec.node;
}

fn classify_one(
    replica: *const records.Replica,
    service: *const records.Service,
    observed: ?*const Entry(records.Observed),
) Class {
    // A service deleted and applied again between two steps starts over at generation 1, so a
    // replica of the old one can be ahead of the new service or equal to it (docs/keys.md): only
    // what it runs says whether it is current.
    const current = replica.generation >= service.generation and
        records.replica_runs_service(replica, service);
    const stopped = if (observed) |found| found.rec.status == .stopped else false;
    // A stale replica that stopped on its own is dead: it is replaced at once, without waiting
    // for the rollout's budget (c3.md). Only a current one is held for its user's fault.
    if (!stopped) return if (current) .live else .stale;
    if (current and user_fault(&observed.?.rec)) return .held;
    return .dead;
}

/// A start that failed through the user's fault: the diagnostic the runtime gave says `user`.
pub fn user_fault(observed: *const records.Observed) bool {
    const exit = observed.exit orelse return false;
    if (exit.kind != .start_failed) return false;
    const raw = observed.diagnostic orelse return false;
    var diagnostic: records.Diagnostic = undefined;
    if (!records.diagnostic_parse(&diagnostic, raw)) return false;
    return diagnostic.blame == .user;
}

/// What the decision acted on in the observed record, as docs/keys.md shows it:
/// `{"status":"stopped","exit":{"kind":"oom"}}`, with `code` or `signal` when the exit has one.
/// The observed record is deleted with the replica, so this is what is left of the exit.
fn exit_evidence(ctx: *const Context, exit: records.Exit) Error![]const u8 {
    const kind = @tagName(exit.kind);
    if (exit.code) |code| return controller.format(
        ctx,
        "{{\"status\":\"stopped\",\"exit\":{{\"kind\":\"{s}\",\"code\":{d}}}}}",
        .{ kind, code },
    );
    if (exit.signal) |signal| return controller.format(
        ctx,
        "{{\"status\":\"stopped\",\"exit\":{{\"kind\":\"{s}\",\"signal\":{d}}}}}",
        .{ kind, signal },
    );
    return controller.format(
        ctx,
        "{{\"status\":\"stopped\",\"exit\":{{\"kind\":\"{s}\"}}}}",
        .{kind},
    );
}

/// The cause of a step of a rollout: the rollout's last decision, else the service.
fn rollout_cause(rollout: *const records.Rollout, service: *const ServiceEntry) records.Cause {
    if (rollout.cause_decision.len == 0) return desired_cause(service);
    return .{ .kind = .decision, .id = rollout.cause_decision };
}

fn desired_cause(service: *const Entry(records.Service)) records.Cause {
    return .{ .kind = .desired, .key = service.kv.key, .revision = service.kv.mod_revision };
}

/// How many of the plan's stale replicas are behind the service in generation.
fn stale_behind(plan: *const ServicePlan, service: *const Entry(records.Service)) u32 {
    var behind: u32 = 0;
    for (plan.slice()) |item| {
        if (item.class != .stale) continue;
        if (item.replica.rec.generation < service.rec.generation) behind += 1;
    }
    assert(behind <= plan.stale);
    return behind;
}

fn plural(count: u32, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

fn nomem(ctx: *const Context) error{NoCapacity} {
    return @import("store_failures.zig").no_memory(ctx.diag);
}
