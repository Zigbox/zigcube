//! The server's controllers run as one: the node controller, the scheduler, the allocation
//! auditor, the job controller, the rollout controller and the replica controller, each a core
//! step of its own (`controller.zig`), in that order, so one pass can mark a node ready, place
//! the replicas that were waiting for it, audit the accounting those placements changed, move
//! the rollouts on and create the replicas the service lacks. Every shell that runs the server's
//! side (`server_drive.zig`, the simulations) drives this and not the six separately.
//!
//! Core: no thread, no clock but the one in the context, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const auditor = @import("auditor.zig");
const controller = @import("controller.zig");
const job_controller = @import("job_controller.zig");
const node_controller = @import("node_controller.zig");
const replica_controller = @import("replica_controller.zig");
const rollout_controller = @import("rollout_controller.zig");
const scheduler = @import("scheduler.zig");

const Context = controller.Context;
const Error = controller.Error;
const Wakeup = controller.Wakeup;

/// Every prefix any of the four watches. The auditor's are all the scheduler's too.
pub const watch_prefixes = node_controller.watch_prefixes ++ scheduler.watch_prefixes ++
    replica_controller.watch_prefixes ++ job_controller.watch_prefixes ++
    rollout_controller.watch_prefixes;

comptime {
    for (auditor.watch_prefixes) |prefix| {
        for (scheduler.watch_prefixes) |watched| {
            if (std.mem.eql(u8, prefix, watched)) break;
        } else @compileError("the auditor watches a prefix the scheduler does not");
    }
}

pub const ControlPlane = struct {
    nodes: node_controller.NodeController,
    scheduler: scheduler.Scheduler,
    jobs: job_controller.JobController,
    rollouts: rollout_controller.RolloutController,
    replicas: replica_controller.ReplicaController,
    auditor: auditor.Auditor,
    /// Run `scheduler.find_mismatch` after each scheduler pass (the simulations and tests do;
    /// the server does not pay for it).
    check_i6: bool = false,
    /// The first disagreement the last check found between a node's allocation record and its
    /// assignments (authority.md I6), or null. Set by `reconcile`; the caller reads it.
    mismatch: ?scheduler.Mismatch = null,

    /// `instance` is the number the shell assigned this server; each controller takes one derived
    /// from it, so their decision ids never collide. Ids sort by time, then instance: the replica
    /// controller's comes before the scheduler's, so within one millisecond a placement sorts
    /// after its creation. (Instance 0 numbers the first three as before the auditor joined.)
    pub fn init(instance: u16) ControlPlane {
        assert(instance <= constants.controller_instance_max);
        return .{
            .nodes = node_controller.NodeController.init(instance *% 4),
            .scheduler = scheduler.Scheduler.init(instance *% 4 +% 2),
            .jobs = job_controller.JobController.init(instance),
            .rollouts = rollout_controller.RolloutController.init(instance),
            .replicas = replica_controller.ReplicaController.init(instance *% 4 +% 1),
            .auditor = auditor.Auditor.init(instance *% 4 +% 3),
        };
    }

    /// The instance a server started at `now_ms` takes: 1 to `controller_instance_max`, by the
    /// second, so a restart a second later is a different one.
    pub fn instance_from(now_ms: u64) u16 {
        const seconds = now_ms / 1000;
        return @intCast(1 + seconds % constants.controller_instance_max);
    }

    /// How long a lost node's replicas and observed records stay before they are replaced (under
    /// new ids) or removed (docs/authority.md §3; `zcube-server --lost-grace-ms`).
    pub fn set_lost_grace(plane: *ControlPlane, grace_ms: u32) void {
        plane.nodes.lost_grace_ms = grace_ms;
        plane.jobs.lost_grace_ms = grace_ms;
        plane.replicas.lost_grace_ms = grace_ms;
    }

    /// One pass of all four. The wake-up is the earliest of theirs.
    pub fn reconcile(plane: *ControlPlane, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const first = try plane.nodes.reconcile(ctx);
        const second = try plane.scheduler.reconcile(ctx);
        if (plane.check_i6) plane.mismatch = try scheduler.find_mismatch(ctx);
        const audited = try plane.auditor.reconcile(ctx);
        // A job pass that fails (a corrupt record no guard covers) must not stop the replicas'
        // controller (RB-S2): its error and diagnostic are kept, the replicas run, and the job
        // pass's error is what the caller gets.
        var job_diag: @TypeOf(ctx.diag.*) = undefined;
        var job_error: ?Error = null;
        var jobs: Wakeup = undefined;
        if (plane.jobs.reconcile(ctx)) |woken| {
            jobs = woken;
        } else |err| {
            job_error = err;
            job_diag = ctx.diag.*;
            ctx.diag.reset();
        }
        // The rollout controller runs right before the replicas' controller, so the budget it
        // stores is the one the replicas' pass spends (C3 slice 7). A rollout pass that fails
        // is held like the job pass's (RB-S2): the replicas still run on the budgets stored.
        var rollout_diag: @TypeOf(ctx.diag.*) = undefined;
        var rollout_error: ?Error = null;
        var rolled: Wakeup = undefined;
        if (plane.rollouts.reconcile(ctx)) |woken| {
            rolled = woken;
        } else |err| {
            rollout_error = err;
            rollout_diag = ctx.diag.*;
            ctx.diag.reset();
        }
        const third = try plane.replicas.reconcile(ctx);
        if (job_error) |err| {
            ctx.diag.* = job_diag;
            return err;
        }
        if (rollout_error) |err| {
            ctx.diag.* = rollout_diag;
            return err;
        }
        return .{
            .at_ms = @min(
                @min(@min(first.at_ms, second.at_ms), @min(audited.at_ms, third.at_ms)),
                @min(jobs.at_ms, rolled.at_ms),
            ),
            .prefixes = &watch_prefixes,
            .acted = first.acted + second.acted + audited.acted + third.acted + jobs.acted +
                rolled.acted,
        };
    }
};
