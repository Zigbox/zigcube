//! The server's controllers run as one: the node controller, the scheduler and the replica
//! controller, each a core step of its own (`controller.zig`), in that order, so one pass can mark
//! a node ready, place the replicas that were waiting for it and create the replicas the
//! service lacks. Every shell that runs the server's side (`server_drive.zig`, the simulations)
//! drives this and not the three separately.
//!
//! Core: no thread, no clock but the one in the context, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const controller = @import("controller.zig");
const node_controller = @import("node_controller.zig");
const replica_controller = @import("replica_controller.zig");
const scheduler = @import("scheduler.zig");

const Context = controller.Context;
const Error = controller.Error;
const Wakeup = controller.Wakeup;

/// Every prefix any of the three watches.
pub const watch_prefixes = node_controller.watch_prefixes ++ scheduler.watch_prefixes ++
    replica_controller.watch_prefixes;

pub const ControlPlane = struct {
    nodes: node_controller.NodeController,
    scheduler: scheduler.Scheduler,
    replicas: replica_controller.ReplicaController,
    /// Run `scheduler.find_mismatch` after each scheduler pass (the simulations and tests do;
    /// the server does not pay for it).
    check_i6: bool = false,
    /// The first disagreement the last check found between a node's allocation record and its
    /// assignments (authority.md I6), or null. Set by `reconcile`; the caller reads it.
    mismatch: ?scheduler.Mismatch = null,

    /// `instance` is the number the shell assigned this server; each controller takes one derived
    /// from it, so their decision ids never collide. Ids sort by time, then instance: the replica
    /// controller's comes before the scheduler's, so within one millisecond a placement sorts
    /// after its creation.
    pub fn init(instance: u16) ControlPlane {
        return .{
            .nodes = node_controller.NodeController.init(instance *% 3),
            .scheduler = scheduler.Scheduler.init(instance *% 3 +% 2),
            .replicas = replica_controller.ReplicaController.init(instance *% 3 +% 1),
        };
    }

    /// One pass of all three. The wake-up is the earliest of theirs.
    pub fn reconcile(plane: *ControlPlane, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const first = try plane.nodes.reconcile(ctx);
        const second = try plane.scheduler.reconcile(ctx);
        if (plane.check_i6) plane.mismatch = try scheduler.find_mismatch(ctx);
        const third = try plane.replicas.reconcile(ctx);
        return .{
            .at_ms = @min(first.at_ms, @min(second.at_ms, third.at_ms)),
            .prefixes = &watch_prefixes,
            .acted = first.acted + second.acted + third.acted,
        };
    }
};
