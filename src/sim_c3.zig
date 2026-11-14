//! C3's rollout checks over the cluster simulation (docs/briefs/c3.md, "Simulation: checks and
//! teeth"), R1 R2 R3 R4 and R6, judged at the head of the store as `sim_c1`'s are: `before_commit`
//! over the head a transaction is about to commit over, `at_revision` over the revision it made.
//! Each check reads only the store, so it judges what was written, not what the controllers
//! meant; each is a little weaker than its sentence in the brief, as its comment says, and never
//! stronger, so a correct controller cannot fail it.
//!
//! Core: no thread, no clock, no I/O.

const std = @import("std");
const controller = @import("controller.zig");
const constants = @import("constants.zig");
const records = @import("records.zig");
const rollout_controller = @import("rollout_controller.zig");
const rollout_plan = @import("rollout_plan.zig");
const store = @import("store.zig");

const Context = controller.Context;
const Snapshot = controller.Snapshot;
const ServiceEntry = controller.Entry(records.Service);

pub const Found = ?[]const u8;

/// What the checks judged: the report prints it, so a check that quietly stopped judging shows.
pub const Tally = struct {
    /// Transactions of the replica controller that retired a running replica of an active
    /// rollout (R1).
    retirements_judged: u64 = 0,
    /// Replicas R1 counted as running though they were not at the head: their report changed
    /// after every key the transaction compared, so the controller may have read them running.
    retirements_doubted: u64 = 0,
    /// Revisions that created a replica of a service whose rollout is active (R2).
    surges_judged: u64 = 0,
    /// Replicas created and compared with their service's history (R3).
    versions_judged: u64 = 0,
    /// Transactions that wrote replicas while their service's rollout was paused (R4).
    paused_judged: u64 = 0,
    /// History records written (R6).
    history_judged: u64 = 0,
};

/// R1, R4 and R6 over the head `request` is about to commit over.
pub fn before_commit(ctx: *const Context, request: store.TxnRequest, tally: *Tally) Found {
    if (history_problem(ctx, request, tally)) |found| return found;
    if (!touches(request, records.prefix_replicas)) return null;
    const snap = controller.read_snapshot(ctx) catch {
        ctx.diag.reset();
        return null;
    };
    for (snap.services) |*service| {
        if (step_problem(ctx, &snap, service, request, tally)) |found| return found;
    }
    return null;
}

/// R2 and R3 over the revision `request` made.
pub fn at_revision(ctx: *const Context, request: ?store.TxnRequest, tally: *Tally) Found {
    const txn = request orelse return null;
    if (!touches(txn, records.prefix_replicas)) return null;
    const snap = controller.read_snapshot(ctx) catch {
        ctx.diag.reset();
        return null;
    };
    for (snap.services) |*service| {
        if (!creates(txn, service.rec.name)) continue;
        if (versions_problem(ctx, &snap, service, txn, tally)) |found| return found;
        if (surge_problem(ctx, &snap, service, tally)) |found| return found;
    }
    return null;
}

fn touches(request: store.TxnRequest, prefix: []const u8) bool {
    for (request.on_success) |op| {
        if (std.mem.startsWith(u8, key_of(op), prefix)) return true;
    }
    return false;
}

fn key_of(op: store.Op) []const u8 {
    return switch (op) {
        .put => |put| put.key,
        .delete => |key| key,
    };
}

/// The id of a replica key of `service` (`/replicas/<service>/<id>`), or null.
fn replica_id(key: []const u8, service: []const u8) ?[]const u8 {
    const prefix = records.replicas_prefix(service);
    if (!std.mem.startsWith(u8, key, prefix.slice())) return null;
    return key[prefix.len..];
}

fn creates(request: store.TxnRequest, service: []const u8) bool {
    for (request.on_success) |op| switch (op) {
        .put => |put| if (replica_id(put.key, service) != null) return true,
        .delete => {},
    };
    return false;
}

/// The rollout of `service`'s current generation, or null.
fn rollout_of(ctx: *const Context, service: *const ServiceEntry) ?records.Rollout {
    const key = records.rollout_key(service.rec.name);
    const got = get(ctx, key.slice()) orelse return null;
    const kv = got;
    const rollout = records.read(records.Rollout, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    if (!records.rollout_of(&rollout, service.kv.create_revision)) return null;
    if (rollout.to != service.rec.generation) return null;
    return rollout;
}

fn find_replica(snap: *const Snapshot, id: []const u8) ?*const controller.Entry(records.Replica) {
    for (snap.replicas) |*replica| {
        if (std.mem.eql(u8, replica.rec.id, id)) return replica;
    }
    return null;
}

/// Whether the node `replica` is placed on is judged lost or fenced: its replica is dead to the
/// replica controller whatever its last report says.
fn on_lost_node(snap: *const Snapshot, replica: *const records.Replica) bool {
    const node = snap.node_of(replica.id) orelse return false;
    const status = snap.status_of(node) orelse return false;
    return status.rec.state != .ready;
}

fn stopped(snap: *const Snapshot, replica: *const records.Replica) bool {
    const observed = snap.observed_of(replica) orelse return false;
    return observed.rec.status == .stopped;
}

fn running(snap: *const Snapshot, replica: *const records.Replica) bool {
    const observed = snap.observed_of(replica) orelse return false;
    return observed.rec.status == .running;
}

/// What one transaction does to one service's replicas.
const Step = struct {
    created: u32 = 0,
    /// Of `created`, those that run the service's current spec (`rollout_controller.is_new`).
    created_new: u32 = 0,
    /// Deleted replicas that had stopped or whose node is lost: replaced, not retired.
    dead: u32 = 0,
    /// Of `dead`, those that ran the service's current spec.
    dead_new: u32 = 0,
    /// Deleted replicas of another generation that had not stopped: a rollout's retirements.
    retired: u32 = 0,
    /// Of `retired`, those reported running.
    retired_running: u32 = 0,
};

fn step_of(
    ctx: *const Context,
    snap: *const Snapshot,
    service: *const ServiceEntry,
    request: store.TxnRequest,
) Step {
    var step: Step = .{};
    for (request.on_success) |op| switch (op) {
        .put => |put| {
            const id = replica_id(put.key, service.rec.name) orelse continue;
            if (find_replica(snap, id) != null) continue;
            step.created += 1;
            if (created_new(ctx, put, service)) step.created_new += 1;
        },
        .delete => |key| {
            const id = replica_id(key, service.rec.name) orelse continue;
            const replica = find_replica(snap, id) orelse continue;
            if (stopped(snap, &replica.rec) or on_lost_node(snap, &replica.rec)) {
                step.dead += 1;
                if (rollout_controller.is_new(&replica.rec, &service.rec)) step.dead_new += 1;
            } else if (!rollout_controller.is_new(&replica.rec, &service.rec)) {
                step.retired += 1;
                if (running(snap, &replica.rec)) step.retired_running += 1;
            }
        },
    };
    return step;
}

/// Whether the replica `put` creates runs `service`'s current spec. One that does not decode is
/// counted as new, the stricter reading.
fn created_new(ctx: *const Context, put: store.Put, service: *const ServiceEntry) bool {
    const kv: store.KeyValue = .{
        .key = put.key,
        .value = put.value,
        .create_revision = 1,
        .mod_revision = 1,
    };
    const replica = records.read(records.Replica, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return true;
    };
    return rollout_controller.is_new(&replica, &service.rec);
}

/// R4: a paused rollout starts and retires nothing; a replica that failed on its own is still
/// replaced, one for one. R1: while a rolling rollout is active, retiring a running replica
/// leaves at least `replicas - max_unavailable` running. "Running" stands in for ready (ready
/// implies running, so the check is weaker than R1 until slice 10's readiness), and a replica on
/// a lost node counts as running, which weakens it again: the controller counts it as down.
fn step_problem(
    ctx: *const Context,
    snap: *const Snapshot,
    service: *const ServiceEntry,
    request: store.TxnRequest,
    tally: *Tally,
) Found {
    var step = step_of(ctx, snap, service, request);
    scaled_down(ctx, snap, service, request, &step);
    if (step.created + step.retired == 0) return null;
    const rollout = rollout_of(ctx, service) orelse return null;
    if (rollout.phase == .paused) {
        tally.paused_judged += 1;
        if (step.retired > 0) return "R4: a paused rollout retired a replica";
        if (step.created > step.dead) return "R4: a paused rollout started a replica";
        // A replacement runs the generation of the replica it replaces: an old replica replaced
        // at the new spec is a start (TLA+ review, C3 slice 7).
        if (step.created_new > step.dead_new) {
            return "R4: a paused rollout started a replica of the new generation";
        }
        return null;
    }
    if (!rollout_plan.active(rollout.phase)) return null;
    const policy = service.rec.rollout_policy();
    if (policy.strategy != .rolling or step.retired_running == 0) return null;
    tally.retirements_judged += 1;
    // The controller promises the floor on the state it read
    // (docs/decisions/2026-11-14-c3-rolling-floor-compares.md). A report the transaction did not
    // compare and that changed after every key it did may have changed after that read: a
    // replica that crashed there is not the controller's doing, so R1 counts it as running.
    const read_at = compared_since(request);
    var up: u32 = 0;
    for (snap.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
        if (running(snap, &replica.rec)) {
            up += 1;
        } else if (snap.observed_of(&replica.rec)) |observed| {
            if (observed.kv.mod_revision > read_at and !compared(request, observed.kv.key)) {
                up += 1;
                tally.retirements_doubted += 1;
            }
        }
    }
    const floor = service.rec.replicas -| policy.max_unavailable;
    if (up - step.retired_running < floor) {
        return "R1: a retirement left fewer replicas running than replicas - max_unavailable";
    }
    return null;
}

/// The least revision the transaction's read can have been at: the highest it compared.
fn compared_since(request: store.TxnRequest) store.Revision {
    var at: store.Revision = 0;
    for (request.compares) |compare| at = @max(at, compare.mod_revision);
    return at;
}

fn compared(request: store.TxnRequest, key: []const u8) bool {
    for (request.compares) |compare| {
        if (std.mem.eql(u8, compare.key, key)) return true;
    }
    return false;
}

/// A user's scale-down (a `scale_down` decision on the service in the transaction) removes
/// replicas of either generation, paused or not: the removals down to `replicas` are not the
/// rollout's retirements. Any beyond are.
fn scaled_down(
    ctx: *const Context,
    snap: *const Snapshot,
    service: *const ServiceEntry,
    request: store.TxnRequest,
    step: *Step,
) void {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
        const kv: store.KeyValue = .{
            .key = put.key,
            .value = put.value,
            .create_revision = 1,
            .mod_revision = 1,
        };
        const decision = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            continue;
        };
        if (!std.mem.eql(u8, decision.action, "scale_down")) continue;
        if (decision.subject.kind != .service) continue;
        if (!std.mem.eql(u8, decision.subject.name, service.rec.name)) continue;
        break;
    } else return;
    var count: u32 = 0;
    for (snap.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
        if (stopped(snap, &replica.rec) or on_lost_node(snap, &replica.rec)) continue;
        count += 1;
    }
    const excess = @min(step.retired, count -| service.rec.replicas);
    step.retired -= excess;
    step.retired_running -|= excess;
}

/// R2: once a replica of an active rollout's service is created, the replicas that count toward
/// surge (reported not stopped, on a node not lost, and the stopping containers of replicas
/// already removed) number at most `replicas + max_surge`.
fn surge_problem(
    ctx: *const Context,
    snap: *const Snapshot,
    service: *const ServiceEntry,
    tally: *Tally,
) Found {
    const rollout = rollout_of(ctx, service) orelse return null;
    if (!rollout_plan.active(rollout.phase)) return null;
    tally.surges_judged += 1;
    var live = rollout_controller.stopping_orphans(snap, service.rec.name);
    for (snap.replicas) |*replica| {
        if (!std.mem.eql(u8, replica.rec.service, service.rec.name)) continue;
        if (stopped(snap, &replica.rec) or on_lost_node(snap, &replica.rec)) continue;
        live += 1;
    }
    const policy = service.rec.rollout_policy();
    if (live > service.rec.replicas + policy.max_surge) {
        return "R2: more replicas live than replicas + max_surge";
    }
    return null;
}

/// R3: a replica created runs a version that was applied: its service's current image at its
/// generation, or the image `/history` holds for that generation. A generation retention has
/// already dropped is not judged.
fn versions_problem(
    ctx: *const Context,
    snap: *const Snapshot,
    service: *const ServiceEntry,
    request: store.TxnRequest,
    tally: *Tally,
) Found {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        const id = replica_id(put.key, service.rec.name) orelse continue;
        const replica = find_replica(snap, id) orelse continue;
        const rec = &replica.rec;
        if (rec.generation > service.rec.generation) {
            return "R3: a replica runs a generation its service never had";
        }
        if (rec.generation == service.rec.generation) {
            tally.versions_judged += 1;
            if (!std.mem.eql(u8, rec.image, service.rec.image)) {
                return "R3: a replica runs another image than its generation's";
            }
            continue;
        }
        const key = records.history_key(service.rec.name, rec.generation);
        const kv = get(ctx, key.slice()) orelse continue;
        const applied = records.read(records.History, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            continue;
        };
        tally.versions_judged += 1;
        if (!std.mem.eql(u8, rec.image, applied.image)) {
            return "R3: a replica runs another image than its generation's";
        }
    }
    return null;
}

/// R6: a history record of the service as it now exists is never written again with other
/// bytes, and the newest generation one transaction writes is above every one stored. Records
/// of a service deleted and applied again (older than its `create_revision`) may be replaced.
fn history_problem(ctx: *const Context, request: store.TxnRequest, tally: *Tally) Found {
    var newest: ?u64 = null;
    var newest_service: []const u8 = "";
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_history)) continue;
        tally.history_judged += 1;
        const rest = put.key[records.prefix_history.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const name = rest[0..slash];
        const generation = std.fmt.parseInt(u64, rest[slash + 1 ..], 10) catch continue;
        if (newest == null or generation > newest.?) {
            newest = generation;
            newest_service = name;
        }
        const created = service_created(ctx, name) orelse continue;
        const kv = get(ctx, put.key) orelse continue;
        if (kv.create_revision < created) continue;
        if (!std.mem.eql(u8, kv.value, put.value)) return "R6: a history record was rewritten";
    }
    const generation = newest orelse return null;
    const created = service_created(ctx, newest_service) orelse return null;
    const prefix = records.history_prefix(newest_service);
    const stored = controller.list_all(records.History, ctx, prefix.slice(), null, 64) catch {
        ctx.diag.reset();
        return null;
    };
    for (stored.items) |entry| {
        if (entry.kv.create_revision < created) continue;
        if (entry.rec.generation > generation) {
            return "R6: a history generation did not increase";
        }
    }
    return null;
}

fn service_created(ctx: *const Context, name: []const u8) ?u64 {
    if (records.name_problem(name, constants.service_name_bytes_max) != null) return null;
    const key = records.service_key(name);
    const got = get(ctx, key.slice()) orelse return null;
    const kv = got;
    return kv.create_revision;
}

/// The value at `key` at the head, or null if there is none or the store cannot be read.
fn get(ctx: *const Context, key: []const u8) ?store.KeyValue {
    const got = ctx.store.get(ctx.arena, key, null, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    return got.kv;
}
