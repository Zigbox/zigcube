//! The rollout controller (C3 slice 7): the one writer of `/rollouts/<service>` (docs/keys.md).
//! When a service's replicas run an older spec than the service asks for, it starts a rollout,
//! and on every pass it judges the rollout on what the agents report (`rollout_plan.pass`) and
//! stores the budget the replica controller may spend: how many new replicas it may start and
//! how many old ones it may retire. It never writes `/replicas/` itself; the replica controller
//! stays that prefix's one writer and obeys the budget (`replica_controller.zig`, gap G3).
//!
//! What it sees per service, on its own clock (the C1 lease-clock rule):
//!
//!   - a replica is **new** if it runs the service's generation and spec, else **old**;
//!   - it is **live** until an admissible report says it stopped or its node is lost; a report
//!     left after its replica record was deleted (the replica is being retired) counts as old,
//!     live and stopping until the agent reports it stopped or deletes it;
//!   - it is **ready** once the controller has seen it running for `min_ready_ms`. Slice 10 plugs
//!     in at `Track.update`: with a health check, "running" becomes "running and healthy";
//!   - a new replica that is held (`hold_failed_replica`), that dies more than
//!     `constants.rollout_restarts_max` times in all, or that is placed and not ready within
//!     `ready_timeout_ms` fails the rollout (ZC-E0304), as `rollout_plan` decides.
//!
//! What it remembers between passes is in memory and starts empty: a restarted server judges
//! readiness and deaths from what it sees after the restart, which can only delay a rollout.
//!
//! Core: no thread, no clock but the one in the context, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const plan_mod = @import("rollout_plan.zig");
const records = @import("records.zig");
const replica_controller = @import("replica_controller.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Snapshot = controller.Snapshot;
const Wakeup = controller.Wakeup;
const DecisionId = records.DecisionId;
const ServiceEntry = Entry(records.Service);
const RolloutEntry = Entry(records.Rollout);

pub const actor = "rollout-controller";

const resync_ms: u64 = 30 * 1000;
const id_bytes_max: u32 = constants.service_name_bytes_max + 1 + 10;
/// Rollout records one pass reads: one per service, and the ones left by deleted services, which
/// the pass deletes.
const rollouts_read_max: u32 = constants.services_max * 2;

pub const watch_prefixes = [_][]const u8{
    records.prefix_services,
    records.prefix_replicas,
    records.prefix_observed,
    records.prefix_assigned,
    records.prefix_replica_numbers,
    records.prefix_node_status,
    records.prefix_rollouts,
};

/// What the controller remembers of one replica between passes, on its own clock.
const Track = struct {
    id_buffer: [id_bytes_max]u8 = undefined,
    id_len: u8 = 0,
    /// The pass that first saw the replica record.
    first_pass: u64 = 0,
    /// Since when the replica has had an assignment (the ready timeout runs from placement).
    assigned_since_ms: ?u64 = null,
    /// Since when the controller has seen it running (C3 slice 10: and healthy).
    running_since_ms: ?u64 = null,
    /// When the controller first saw it held (a start that failed by the user's fault).
    held_at_ms: ?u64 = null,
    /// When the controller first saw it stopped for another reason; `counted` once a rollout's
    /// restart count took it.
    died_at_ms: ?u64 = null,
    counted: bool = false,
    mark: bool = false,

    fn id(track: *const Track) []const u8 {
        return track.id_buffer[0..track.id_len];
    }
};

/// The deaths of one service's new replicas since its rollout began or was last resumed.
const Deaths = struct {
    name_buffer: [constants.service_name_bytes_max]u8 = undefined,
    name_len: u8 = 0,
    to: u64 = 0,
    from_ms: u64 = 0,
    count: u32 = 0,
    exceeded_at_ms: ?u64 = null,
    mark: bool = false,

    fn name(deaths: *const Deaths) []const u8 {
        return deaths.name_buffer[0..deaths.name_len];
    }
};

pub const RolloutController = struct {
    source: controller.DecisionSource,
    passes: u64 = 0,
    tracks: [constants.replicas_max]Track = undefined,
    tracks_count: u32 = 0,
    deaths: [constants.services_max]Deaths = undefined,
    deaths_count: u32 = 0,

    /// Decision ids: `0xA000 | instance`, above the job controller's half (`0x8000 | instance`).
    pub fn init(instance: u16) RolloutController {
        assert(instance <= constants.controller_instance_max);
        comptime assert(constants.controller_instance_max < 0x2000);
        return .{ .source = .{ .instance = 0xA000 | instance } };
    }

    /// One pass. Errors are the store's (its diagnostic is in `ctx.diag`) or a malformed record
    /// (ZC-E0301); the shell retries later.
    pub fn reconcile(rc: *RolloutController, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const snapshot = try controller.read_snapshot(ctx);
        rc.passes += 1;
        rc.observe(&snapshot, now);
        const rollouts = try controller.list_all(
            records.Rollout,
            ctx,
            records.prefix_rollouts,
            snapshot.revision,
            rollouts_read_max,
        );
        var run: Run = .{ .rc = rc, .ctx = ctx, .snap = &snapshot, .now = now };
        for (snapshot.services) |*service| {
            try run.reconcile_service(service, find_rollout(rollouts.items, service.rec.name));
        }
        for (rollouts.items) |*rollout| try run.reconcile_leftover(rollout);
        rc.sweep_deaths();
        var wake_at = @min(now + resync_ms, run.wake_at_ms);
        if (run.acted > 0 or run.more) wake_at = now;
        return .{ .at_ms = wake_at, .prefixes = &watch_prefixes, .acted = run.acted };
    }

    // ---- What the controller remembers ----

    fn observe(rc: *RolloutController, snap: *const Snapshot, now: u64) void {
        for (rc.tracks[0..rc.tracks_count]) |*track| track.mark = false;
        for (snap.replicas) |*replica| {
            if (rc.track_of(replica.rec.id)) |track| track.mark = true;
        }
        var kept: u32 = 0;
        for (rc.tracks[0..rc.tracks_count]) |track| {
            if (!track.mark) continue;
            rc.tracks[kept] = track;
            kept += 1;
        }
        rc.tracks_count = kept;
        for (snap.replicas) |*replica| {
            const track = rc.track_of(replica.rec.id) orelse rc.track_add(replica.rec.id) orelse
                continue;
            update(track, snap, replica, now);
        }
        assert(rc.tracks_count <= snap.replicas.len);
    }

    fn track_of(rc: *RolloutController, id: []const u8) ?*Track {
        for (rc.tracks[0..rc.tracks_count]) |*track| {
            if (std.mem.eql(u8, track.id(), id)) return track;
        }
        return null;
    }

    fn track_add(rc: *RolloutController, id: []const u8) ?*Track {
        if (rc.tracks_count == rc.tracks.len) return null;
        if (id.len > id_bytes_max) return null;
        const track = &rc.tracks[rc.tracks_count];
        track.* = .{ .first_pass = rc.passes, .id_len = @intCast(id.len) };
        @memcpy(track.id_buffer[0..id.len], id);
        rc.tracks_count += 1;
        return track;
    }

    fn deaths_of(rc: *RolloutController, service: []const u8) ?*Deaths {
        for (rc.deaths[0..rc.deaths_count]) |*deaths| {
            if (std.mem.eql(u8, deaths.name(), service)) {
                deaths.mark = true;
                return deaths;
            }
        }
        if (rc.deaths_count == rc.deaths.len) return null;
        if (service.len > constants.service_name_bytes_max) return null;
        const deaths = &rc.deaths[rc.deaths_count];
        deaths.* = .{ .name_len = @intCast(service.len), .mark = true };
        @memcpy(deaths.name_buffer[0..service.len], service);
        rc.deaths_count += 1;
        return deaths;
    }

    fn sweep_deaths(rc: *RolloutController) void {
        var kept: u32 = 0;
        for (rc.deaths[0..rc.deaths_count]) |deaths| {
            if (!deaths.mark) continue;
            rc.deaths[kept] = deaths;
            rc.deaths[kept].mark = false;
            kept += 1;
        }
        rc.deaths_count = kept;
    }
};

/// Updates what the controller remembers of `replica` from this pass's reports.
fn update(
    track: *Track,
    snap: *const Snapshot,
    replica: *const Entry(records.Replica),
    now: u64,
) void {
    const placed = snap.assigned_of(replica.rec.id) != null;
    if (!placed) track.assigned_since_ms = null;
    if (placed and track.assigned_since_ms == null) track.assigned_since_ms = now;
    const observed = replica_controller.admissible_in(snap, snap.observed_of(&replica.rec));
    const lost = node_lost(snap, replica.rec.id);
    const status: ?records.ObservedStatus = if (observed) |found| found.rec.status else null;
    // C3 slice 10 plugs in here: a replica of a service with a health check is "running" for
    // readiness only while its report says it is healthy.
    const running = status == .running and !lost;
    if (!running) track.running_since_ms = null;
    if (running and track.running_since_ms == null) track.running_since_ms = now;
    if (status != .stopped) return;
    if (replica_controller.user_fault(&observed.?.rec)) {
        if (track.held_at_ms == null) track.held_at_ms = now;
    } else {
        if (track.died_at_ms == null) track.died_at_ms = now;
    }
}

/// Whether the node `replica` is placed on is judged lost (its grace is the replica controller's).
fn node_lost(snap: *const Snapshot, replica: []const u8) bool {
    const node = snap.node_of(replica) orelse return false;
    const status = snap.status_of(node) orelse return false;
    return status.rec.state == .lost;
}

fn find_rollout(rollouts: []const RolloutEntry, service: []const u8) ?*const RolloutEntry {
    for (rollouts) |*rollout| {
        if (std.mem.eql(u8, rollout.rec.service, service)) return rollout;
    }
    return null;
}

// ---- One service's view ----------------------------------------------------------------------

/// A service's replicas as one pass sees them: the plan's mix and the facts it is judged on.
pub const View = struct {
    mix: plan_mod.Mix = .{},
    /// Replica records of another spec than the service's (the old ones not yet retired).
    old_records: u32 = 0,
    /// The highest generation among them.
    old_generation: u64 = 0,
    /// The highest generation among them below the service's: one this service ran before. An
    /// old replica at the service's generation or above ran another incarnation of it (deleted
    /// and applied again) or another spec of the same generation, never an earlier generation.
    earlier_generation: u64 = 0,
    held_at_ms: ?u64 = null,
    unready_since_ms: ?u64 = null,
    ready_pending_at_ms: ?u64 = null,
    unplaceable: bool = false,
};

/// Whether `replica` is a new replica of `service`: it runs the service's generation and spec.
/// The same rule as the replica controller's `stale`, so the two count the same replicas.
pub fn is_new(replica: *const records.Replica, service: *const records.Service) bool {
    if (replica.generation < service.generation) return false;
    return records.replica_runs_service(replica, service);
}

/// Whether a replica with this report (if any) on a node of this status counts as live.
pub fn live_report(snap: *const Snapshot, replica: *const records.Replica) bool {
    if (node_lost(snap, replica.id)) return false;
    const observed = replica_controller.admissible_in(snap, snap.observed_of(replica));
    const found = observed orelse return true;
    return found.rec.status != .stopped;
}

/// Reports of `service` whose replica record is gone and whose container may still run: old,
/// live and stopping. A report on a lost node, or one that says stopped, does not count.
pub fn stopping_orphans(snap: *const Snapshot, service: []const u8) u32 {
    var count: u32 = 0;
    for (snap.observed) |*observed| {
        if (records.replica_number(service, observed.rec.replica) == null) continue;
        if (observed.rec.status == .stopped) continue;
        if (has_replica(snap, service, observed.rec.replica)) continue;
        const status = snap.status_of(observed.rec.node);
        if (status) |found| {
            if (found.rec.state == .lost) continue;
        }
        count += 1;
    }
    return count;
}

fn has_replica(snap: *const Snapshot, service: []const u8, id: []const u8) bool {
    for (snap.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.rec.id, id)) continue;
        if (std.mem.eql(u8, replica.rec.service, service)) return true;
    }
    return false;
}

// ---- One pass --------------------------------------------------------------------------------

const Run = struct {
    rc: *RolloutController,
    ctx: *const Context,
    snap: *const Snapshot,
    now: u64,
    acted: u32 = 0,
    more: bool = false,
    wake_at_ms: u64 = std.math.maxInt(u64),

    fn view(run: *Run, service: *const ServiceEntry, policy: *const plan_mod.Policy) View {
        var result: View = .{};
        for (run.snap.replicas) |*replica| {
            if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
            const track = run.rc.track_of(replica.rec.id);
            const fresh = is_new(&replica.rec, &service.rec);
            if (!fresh) {
                result.old_records += 1;
                result.old_generation = @max(result.old_generation, replica.rec.generation);
                if (replica.rec.generation < service.rec.generation) {
                    const generation = replica.rec.generation;
                    result.earlier_generation = @max(result.earlier_generation, generation);
                }
            }
            if (!live_report(run.snap, &replica.rec)) {
                if (fresh) result.held_at_ms = later(result.held_at_ms, held_at(track));
                continue;
            }
            const since = if (track) |found| found.running_since_ms else null;
            const ready = plan_mod.ready(since, run.now, policy.min_ready_ms);
            if (!ready) {
                if (plan_mod.ready_at(since, policy.min_ready_ms)) |at| {
                    result.ready_pending_at_ms = earlier(result.ready_pending_at_ms, at);
                }
            }
            if (fresh) {
                result.mix.new_live += 1;
                if (ready) result.mix.new_ready += 1;
                if (!ready) run.note_unready(&result, track);
            } else {
                result.mix.old_live += 1;
                if (ready) result.mix.old_ready += 1;
            }
        }
        const orphans = stopping_orphans(run.snap, service.rec.name);
        result.mix.old_live += orphans;
        result.mix.old_stopping += orphans;
        result.mix.assert_valid();
        return result;
    }

    fn note_unready(run: *Run, result: *View, track: ?*Track) void {
        const found = track orelse return;
        if (found.assigned_since_ms) |since| {
            result.unready_since_ms = earlier(result.unready_since_ms, since);
        } else if (found.first_pass < run.rc.passes) {
            result.unplaceable = true;
        }
    }

    /// Counts deaths of the service's new replicas since `from_ms` against the restart bound;
    /// returns when the bound was passed, if it was.
    fn count_deaths(run: *Run, service: *const ServiceEntry, from_ms: u64) ?u64 {
        const deaths = run.rc.deaths_of(service.rec.name) orelse return null;
        if (deaths.to != service.rec.generation or deaths.from_ms != from_ms) {
            deaths.* = .{
                .name_buffer = deaths.name_buffer,
                .name_len = deaths.name_len,
                .to = service.rec.generation,
                .from_ms = from_ms,
                .mark = true,
            };
        }
        for (run.snap.replicas) |*replica| {
            if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
            if (!is_new(&replica.rec, &service.rec)) continue;
            const track = run.rc.track_of(replica.rec.id) orelse continue;
            const died = track.died_at_ms orelse continue;
            if (track.counted) continue;
            track.counted = true;
            if (died < from_ms) continue;
            deaths.count += 1;
            if (deaths.count > constants.rollout_restarts_max and deaths.exceeded_at_ms == null) {
                deaths.exceeded_at_ms = died;
            }
        }
        return deaths.exceeded_at_ms;
    }

    fn reconcile_service(
        run: *Run,
        service: *const ServiceEntry,
        found: ?*const RolloutEntry,
    ) Error!void {
        const policy = service.rec.rollout_policy();
        const seen = run.view(service, &policy);
        var current: ?*const RolloutEntry = null;
        if (found) |rollout| {
            if (records.rollout_of(&rollout.rec, service.kv.create_revision)) current = rollout;
        }
        if (current) |rollout| {
            if (rollout.rec.to == service.rec.generation) {
                if (state_of(&rollout.rec)) |state| {
                    return run.go_on(service, &policy, &seen, rollout, state);
                }
            }
        }
        if (seen.old_records == 0) return;
        try run.begin(service, &policy, &seen, found);
    }

    fn facts_of(
        run: *Run,
        service: *const ServiceEntry,
        seen: *const View,
        state: *const plan_mod.State,
    ) plan_mod.Facts {
        return .{
            .desired = service.rec.replicas,
            .mix = seen.mix,
            .now_ms = run.now,
            .new_held_at_ms = seen.held_at_ms,
            .new_restarts_exceeded_at_ms = run.count_deaths(service, state.evidence_from_ms),
            .new_unready_since_ms = seen.unready_since_ms,
            .ready_pending_at_ms = seen.ready_pending_at_ms,
            .unplaceable = seen.unplaceable,
        };
    }

    fn begin(
        run: *Run,
        service: *const ServiceEntry,
        policy: *const plan_mod.Policy,
        seen: *const View,
        found: ?*const RolloutEntry,
    ) Error!void {
        const reason = try run.reason_of(service);
        const from = from_of(service, seen, found);
        // The service ran an earlier generation if a rollback started this, or if `from` names
        // one (0 for none): a failed first generation owes no rollback.
        const ran_before = reason == .rollback or from != 0;
        const state = plan_mod.begin(policy, reason, ran_before, run.now);
        const facts = run.facts_of(service, seen, &state);
        const result = plan_mod.pass(policy, &state, &facts);
        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        const key = records.rollout_key(service.rec.name);
        const key_bytes = try controller.key_copy(run.ctx, &key);
        batch.expect(key_bytes, if (found) |rollout| rollout.kv.mod_revision else 0);
        const text = try controller.format(run.ctx, "service {s} is at generation {d} and {d} " ++
            "of its replicas run generation {d} or another spec; rolling them out ({s}, " ++
            "{d} {s} wanted)", .{
            service.rec.name,
            service.rec.generation,
            seen.old_records,
            seen.old_generation,
            @tagName(policy.strategy),
            service.rec.replicas,
            plural(service.rec.replicas, "replica", "replicas"),
        });
        const id = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "rollout_start",
            .subject = .{ .kind = .service, .name = service.rec.name },
            .reason = text,
            .cause = desired_cause(service),
            .cause_evidence = try evidence.service(run.ctx, &service.rec),
        }, &batch);
        const cause = try controller.format(run.ctx, "{s}", .{id.slice()});
        var rollout: records.Rollout = .{
            .service = service.rec.name,
            .service_created = service.kv.create_revision,
            .from = from,
            .to = service.rec.generation,
            .phase = .progressing,
            .started_at_ms = state.started_at_ms,
            .deadline_at_ms = state.deadline_at_ms,
            .cause_decision = cause,
        };
        try run.fill(&rollout, service, seen, &result);
        batch.put(key_bytes, try records.encode(run.ctx.arena, rollout, run.ctx.diag));
        try run.finish(&batch);
    }

    /// The generation the service last ran to completion: the target of its rollout if that
    /// ended `complete`, else what that rollout started from, so an apply over a rollout still
    /// progressing, paused or failed never names a generation that never became ready. With no
    /// rollout of this service, the newest earlier generation its old replicas run: the first
    /// generation has no rollout of its own.
    fn from_of(service: *const ServiceEntry, seen: *const View, found: ?*const RolloutEntry) u64 {
        const rollout = found orelse return seen.earlier_generation;
        if (!records.rollout_of(&rollout.rec, service.kv.create_revision)) {
            return seen.earlier_generation;
        }
        if (rollout.rec.to >= service.rec.generation) return rollout.rec.from;
        if (rollout.rec.phase == .complete) return rollout.rec.to;
        return rollout.rec.from;
    }

    fn reason_of(run: *Run, service: *const ServiceEntry) Error!plan_mod.Reason {
        const key = records.history_key(service.rec.name, service.rec.generation);
        const ctx = run.ctx;
        const got = try ctx.store.get(ctx.arena, key.slice(), run.snap.revision, ctx.diag);
        const kv = got.kv orelse return .apply;
        const history = try records.read(records.History, run.ctx.arena, kv, run.ctx.diag);
        return switch (history.reason) {
            .apply => .apply,
            .rollback, .auto_rollback => .rollback,
        };
    }

    /// Writes `result` into `rollout`: the state, the budget and what it was computed on.
    fn fill(
        run: *Run,
        rollout: *records.Rollout,
        service: *const ServiceEntry,
        seen: *const View,
        result: *const plan_mod.Pass,
    ) Error!void {
        const state = &result.state;
        rollout.phase = state.phase;
        rollout.started_at_ms = state.started_at_ms;
        rollout.deadline_at_ms = state.deadline_at_ms;
        rollout.reason = switch (state.reason) {
            .apply => .apply,
            .rollback => .rollback,
        };
        rollout.evidence_from_ms = if (state.evidence_from_ms == state.started_at_ms)
            null
        else
            state.evidence_from_ms;
        rollout.paused_at_ms = state.paused_at_ms;
        rollout.paused_by = if (state.paused_by) |by| switch (by) {
            .user => .user,
            .failure => .failure,
        } else null;
        rollout.next_at_ms = result.next_at_ms;
        rollout.ready_new = seen.mix.new_ready;
        rollout.budget = result.plan.stored();
        if (c1_teeth.rollout_pause and !plan_mod.active(state.phase)) {
            const policy = service.rec.rollout_policy();
            rollout.budget = plan_mod.budget(&policy, service.rec.replicas, &seen.mix, .progressing)
                .stored();
        }
        rollout.budget_revision = run.snap.revision;
        rollout.budget_next = try run.counter_next(service.rec.name);
        rollout.budget_old = seen.old_records;
    }

    fn counter_next(run: *Run, service: []const u8) Error!?u64 {
        const key = records.replica_numbers_key(service);
        const ctx = run.ctx;
        const got = try ctx.store.get(ctx.arena, key.slice(), run.snap.revision, ctx.diag);
        const kv = got.kv orelse return null;
        const number = try records.read(records.ReplicaNumber, run.ctx.arena, kv, run.ctx.diag);
        return number.next;
    }

    fn go_on(
        run: *Run,
        service: *const ServiceEntry,
        policy: *const plan_mod.Policy,
        seen: *const View,
        rollout: *const RolloutEntry,
        state: plan_mod.State,
    ) Error!void {
        const facts = run.facts_of(service, seen, &state);
        var result = plan_mod.pass(policy, &state, &facts);
        if (result.failure == .deadline and facts.unplaceable) result.failure = .stalled;
        if (result.next_at_ms) |at| run.wake_at_ms = @min(run.wake_at_ms, at);
        var next = rollout.rec;
        const before_old = rollout.rec.budget_old;
        try run.fill(&next, service, seen, &result);
        next.retired_old = rollout.rec.retired_old + (before_old -| seen.old_records);
        const moved = result.state.phase != state.phase;
        if (!moved and !run.drifted(&rollout.rec, &next, service)) return;
        var batch: Batch = .{};
        batch.expect(service.kv.key, service.kv.mod_revision);
        batch.expect(rollout.kv.key, rollout.kv.mod_revision);
        if (moved) {
            const id = try run.decide_move(service, &rollout.rec, &result, seen, &batch);
            next.cause_decision = try controller.format(run.ctx, "{s}", .{id.slice()});
        }
        batch.put(rollout.kv.key, try records.encode(run.ctx.arena, next, run.ctx.diag));
        try run.finish(&batch);
    }

    /// Whether the stored rollout no longer says what this pass would write: the budget's basis
    /// moved, the service changed since the budget was computed, or a stored member changed.
    fn drifted(
        run: *Run,
        stored: *const records.Rollout,
        next: *const records.Rollout,
        service: *const ServiceEntry,
    ) bool {
        _ = run;
        if (service.kv.mod_revision > stored.budget_revision) return true;
        if (!std.meta.eql(stored.budget, next.budget)) return true;
        if (stored.budget_old != next.budget_old) return true;
        if (!std.meta.eql(stored.budget_next, next.budget_next)) return true;
        if (stored.ready_new != next.ready_new) return true;
        if (!std.meta.eql(stored.next_at_ms, next.next_at_ms)) return true;
        if (stored.deadline_at_ms != next.deadline_at_ms) return true;
        return stored.retired_old != next.retired_old;
    }

    fn decide_move(
        run: *Run,
        service: *const ServiceEntry,
        stored: *const records.Rollout,
        result: *const plan_mod.Pass,
        seen: *const View,
        batch: *Batch,
    ) Error!DecisionId {
        const name = service.rec.name;
        const to = service.rec.generation;
        const action: []const u8, const text: []const u8 = switch (result.state.phase) {
            .complete => .{ "rollout_step", try controller.format(run.ctx, "the rollout of " ++
                "{s} to generation {d} is complete: {d} new {s} ready and no old one left", .{
                name, to, seen.mix.new_ready, plural(seen.mix.new_ready, "replica", "replicas"),
            }) },
            .failed => .{ "rollout_fail", try run.failure_text(service, result, seen) },
            .paused => .{ "rollout_pause", try controller.format(run.ctx, "ZC-W0304 the " ++
                "rollout of {s} to generation {d} failed and paused itself: {s}", .{
                name, to, try run.failure_text(service, result, seen),
            }) },
            .progressing, .rolling_back => unreachable, // `pass` never resumes.
        };
        return controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = action,
            .subject = .{ .kind = .service, .name = name },
            .reason = text,
            .cause = cause_of(stored),
        }, batch);
    }

    fn failure_text(
        run: *Run,
        service: *const ServiceEntry,
        result: *const plan_mod.Pass,
        seen: *const View,
    ) Error![]const u8 {
        const failure = result.failure orelse return controller.format(run.ctx, "the rollout " ++
            "of {s} failed", .{service.rec.name});
        const code = @tagName(failure.code());
        const policy = service.rec.rollout_policy();
        const what = switch (failure) {
            .held => "a new replica failed to start through the release's fault and is held",
            .restarts => "new replicas stopped more than rollout_restarts_max (3) times",
            .ready_timeout => "a new replica placed was not ready within ready_timeout_ms",
            .stalled => "new replicas could not be placed before progress_deadline_ms",
            .deadline => "the rollout passed progress_deadline_ms",
        };
        return controller.format(run.ctx, "ZC-{s} the rollout of {s} to generation {d} " ++
            "failed: {s}; {d} of {d} new replicas are ready (on_failure {s})", .{
            code,
            service.rec.name,
            service.rec.generation,
            what,
            seen.mix.new_ready,
            service.rec.replicas,
            @tagName(policy.on_failure),
        });
    }

    /// Deletes a rollout no service owns any more (deleted, or deleted and applied again).
    fn reconcile_leftover(run: *Run, rollout: *const RolloutEntry) Error!void {
        if (run.snap.service_of(rollout.rec.service)) |service| {
            if (records.rollout_of(&rollout.rec, service.kv.create_revision)) return;
            // `reconcile_service` began a new one over it or found nothing to roll: a record of
            // a previous incarnation with no new rollout to replace it goes here.
            if (service.kv.mod_revision > run.snap.revision) return;
        }
        var batch: Batch = .{};
        batch.expect(rollout.kv.key, rollout.kv.mod_revision);
        const service_key = records.service_key(rollout.rec.service);
        const text = try controller.format(run.ctx, "the rollout of {s} to generation {d} " ++
            "belongs to a service that was deleted; removing it", .{
            rollout.rec.service, rollout.rec.to,
        });
        _ = try controller.put_decision(run.ctx, &run.rc.source, .{
            .actor = actor,
            .action = "rollout_step",
            .subject = .{ .kind = .service, .name = rollout.rec.service },
            .reason = text,
            .cause = .{
                .kind = .desired,
                .key = try controller.key_copy(run.ctx, &service_key),
                .revision = run.snap.revision,
            },
        }, &batch);
        batch.delete(rollout.kv.key);
        try run.finish(&batch);
    }

    fn finish(run: *Run, batch: *const Batch) Error!void {
        const done = try controller.commit(run.ctx, .rollout_controller, batch);
        run.more = true;
        if (done == .applied) run.acted += 1;
    }
};

/// The plan's state as `rollout` stores it, or null if what is stored is not a state the plan
/// could have written (the rollout then begins again).
pub fn state_of(rollout: *const records.Rollout) ?plan_mod.State {
    const evidence_from = rollout.evidence_from_ms orelse rollout.started_at_ms;
    if (rollout.deadline_at_ms < rollout.started_at_ms) return null;
    if (evidence_from < rollout.started_at_ms) return null;
    const reason: plan_mod.Reason = switch (rollout.reason) {
        .apply => .apply,
        .rollback => .rollback,
    };
    const paused = rollout.phase == .paused;
    if (paused != (rollout.paused_at_ms != null)) return null;
    if (paused != (rollout.paused_by != null)) return null;
    if (plan_mod.active(rollout.phase)) {
        if (rollout.phase != reason.active_phase()) return null;
    }
    if (rollout.paused_at_ms) |at| {
        if (at < evidence_from) return null;
    }
    const state: plan_mod.State = .{
        .phase = rollout.phase,
        .reason = reason,
        .earlier = reason == .rollback or rollout.from != 0,
        .started_at_ms = rollout.started_at_ms,
        .deadline_at_ms = rollout.deadline_at_ms,
        .evidence_from_ms = evidence_from,
        .paused_at_ms = rollout.paused_at_ms,
        .paused_by = if (rollout.paused_by) |by| switch (by) {
            .user => .user,
            .failure => .failure,
        } else null,
    };
    state.assert_valid();
    return state;
}

/// Whether `service`'s rollout of its current generation stopped short, failed or paused: its
/// replicas may then mix generations and number up to `max_surge` more than it asks for.
pub fn halted(ctx: *const Context, service: *const Entry(records.Service)) Error!bool {
    const key = records.rollout_key(service.rec.name);
    const rollout = try get_entry(records.Rollout, ctx, key) orelse return false;
    if (!records.rollout_of(&rollout.rec, service.kv.create_revision)) return false;
    if (rollout.rec.to != service.rec.generation) return false;
    return rollout.rec.phase == .failed or rollout.rec.phase == .paused;
}

// ---- Pause and resume (the API's handlers, C3 slice 11) --------------------------------------

pub const Request = enum { pause, resume_rollout };

pub const Outcome = union(enum) {
    /// Written: the rollout's new phase.
    done: records.RolloutPhase,
    /// Nothing changed: the rollout was already in that state.
    unchanged: records.RolloutPhase,
    /// ZC-E0129 is in `ctx.diag`: no rollout to pause or resume.
    refused,
    /// The rollout or its service moved while the request was planned; ask again.
    conflict,
};

/// A user's pause or resume of `service`'s rollout. The rollout controller stays the one writer
/// of `/rollouts/`: the handler commits as its role, with a decision of `source` (the API's).
pub fn request(
    ctx: *const Context,
    source: *controller.DecisionSource,
    service_name: []const u8,
    what: Request,
) Error!Outcome {
    assert(ctx.diag.code == null);
    const now = ctx.clock.now_ms();
    const service = try get_entry(records.Service, ctx, records.service_key(service_name)) orelse
        return refuse(ctx, service_name, "does not exist");
    const rollout = try get_entry(records.Rollout, ctx, records.rollout_key(service_name)) orelse
        return refuse(ctx, service_name, "has no rollout");
    if (!records.rollout_of(&rollout.rec, service.kv.create_revision)) {
        return refuse(ctx, service_name, "has no rollout");
    }
    if (rollout.rec.to != service.rec.generation) {
        return refuse(ctx, service_name, "has no rollout of its current generation");
    }
    const state = state_of(&rollout.rec) orelse return refuse(ctx, service_name, "has no rollout");
    const policy = service.rec.rollout_policy();
    const next = switch (what) {
        .pause => plan_mod.pause_rollout(&state, now),
        .resume_rollout => plan_mod.resume_rollout(&policy, &state, now),
    } catch return refuse(ctx, service_name, switch (state.phase) {
        .complete => "has no rollout in progress (the last one is complete)",
        else => "has a failed rollout, which a resume cannot continue",
    });
    if (std.meta.eql(next, state)) return .{ .unchanged = state.phase };
    var stored = rollout.rec;
    write_state(&stored, &next);
    var batch: Batch = .{};
    batch.expect(service.kv.key, service.kv.mod_revision);
    batch.expect(rollout.kv.key, rollout.kv.mod_revision);
    const text = try controller.format(ctx, "the rollout of {s} to generation {d} was {s} " ++
        "by the user", .{
        service_name, rollout.rec.to, if (what == .pause) "paused" else "resumed",
    });
    const id = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = if (what == .pause) "rollout_pause" else "rollout_resume",
        .subject = .{ .kind = .service, .name = service_name },
        .reason = text,
        .cause = cause_of(&rollout.rec),
    }, &batch);
    stored.cause_decision = try controller.format(ctx, "{s}", .{id.slice()});
    // The budget is the controller's to recompute: none until its next pass.
    stored.budget = .{};
    batch.put(rollout.kv.key, try records.encode(ctx.arena, stored, ctx.diag));
    const done = try controller.commit(ctx, .rollout_controller, &batch);
    return switch (done) {
        .applied => .{ .done = next.phase },
        .conflict => .conflict,
    };
}

fn write_state(rollout: *records.Rollout, state: *const plan_mod.State) void {
    rollout.phase = state.phase;
    rollout.deadline_at_ms = state.deadline_at_ms;
    rollout.evidence_from_ms = if (state.evidence_from_ms == state.started_at_ms)
        null
    else
        state.evidence_from_ms;
    rollout.paused_at_ms = state.paused_at_ms;
    rollout.paused_by = if (state.paused_by) |by| switch (by) {
        .user => .user,
        .failure => .failure,
    } else null;
}

fn refuse(ctx: *const Context, service: []const u8, why: []const u8) Outcome {
    ctx.diag.raise(.E0129);
    ctx.diag.cause("service {s} {s}", .{ service, why });
    ctx.diag.fix(.{ .sentence = "see what the service runs" });
    return .refused;
}

fn get_entry(comptime T: type, ctx: *const Context, key: records.Key) Error!?Entry(T) {
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = got.kv orelse return null;
    return .{ .kv = kv, .rec = try records.read(T, ctx.arena, kv, ctx.diag) };
}

fn held_at(track: ?*Track) ?u64 {
    const found = track orelse return null;
    return found.held_at_ms;
}

fn later(first: ?u64, second: ?u64) ?u64 {
    const a = first orelse return second;
    const b = second orelse return first;
    return @max(a, b);
}

fn earlier(first: ?u64, second: u64) u64 {
    const a = first orelse return second;
    return @min(a, second);
}

fn desired_cause(service: *const ServiceEntry) records.Cause {
    return .{ .kind = .desired, .key = service.kv.key, .revision = service.kv.mod_revision };
}

fn cause_of(rollout: *const records.Rollout) records.Cause {
    if (rollout.cause_decision.len == 0) return .{ .kind = .resync };
    return .{ .kind = .decision, .id = rollout.cause_decision };
}

fn plural(count: u32, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}
