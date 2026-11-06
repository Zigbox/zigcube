//! The allocation accounting, reconstructed (docs/authority.md, "Auditing the accounting"): each
//! node's tally rebuilt from its assignments and set beside its `/allocations/<node>` record and
//! its open finding, all read at one revision. The auditor (`auditor.zig`), `GET
//! /v1/check/allocations` and the simulations' I6 check run this one reconstruction.
//!
//! `repair` is the scheduler's `repair_allocation`, which an operator's request runs: it writes
//! the reconstructed tally to a node that has an open finding. It is the scheduler's because the
//! scheduler is `/allocations/`'s one writer; the auditor never repairs.
//!
//! Core: no thread, no clock but the one in the context, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Revision = store.Revision;
const Tally = records.Tally;

pub const zero: Tally = .{ .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 }, .count = 0 };

/// One node's accounting at the reconstruction's revision.
pub const NodeTally = struct {
    node: []const u8,
    /// `/allocations/<node>`, or null when there is none.
    recorded: ?Tally,
    /// Its `mod_revision`; 0 when absent.
    allocation_revision: Revision,
    /// `node_revision` of the record, 0 when absent.
    node_revision: u64,
    /// The sum of the node's assignments.
    reconstructed: Tally,
    /// `/audit/allocations/<node>`, the open finding, if any.
    finding: ?*const Entry(records.Audit),

    /// A node with no record holds no assignment.
    pub fn consistent(tally: *const NodeTally) bool {
        return tally_equal(tally.recorded orelse zero, tally.reconstructed);
    }
};

pub const Reconstruction = struct {
    revision: Revision,
    /// Every node with a record, an assignment or a finding, ascending by name.
    nodes: []const NodeTally,

    pub fn first_mismatch(reconstruction: *const Reconstruction) ?*const NodeTally {
        for (reconstruction.nodes) |*tally| {
            if (!tally.consistent()) return tally;
        }
        return null;
    }
};

/// Lists `/assigned/`, then `/allocations/` and `/audit/allocations/` at the same revision, and
/// rebuilds every node's tally.
pub fn reconstruct(ctx: *const Context) Error!Reconstruction {
    const assigned = try controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        null,
        constants.assigned_max,
    );
    const allocations = try controller.list_all(
        records.Allocation,
        ctx,
        records.prefix_allocations,
        assigned.revision,
        constants.nodes_max,
    );
    const audits = try controller.list_all(
        records.Audit,
        ctx,
        records.prefix_audit_allocations,
        assigned.revision,
        constants.nodes_max,
    );
    var nodes: Nodes = .{ .ctx = ctx };
    for (allocations.items) |*entry| {
        const tally = try nodes.slot(entry.kv.key[records.prefix_allocations.len..]);
        tally.recorded = .{ .allocated = entry.rec.allocated, .count = entry.rec.count };
        tally.allocation_revision = entry.kv.mod_revision;
        tally.node_revision = entry.rec.node_revision;
    }
    for (audits.items) |*entry| {
        const tally = try nodes.slot(entry.kv.key[records.prefix_audit_allocations.len..]);
        tally.finding = entry;
    }
    for (assigned.items) |entry| {
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const tally = try nodes.slot(rest[0..slash]);
        tally.reconstructed = plus(tally.reconstructed, entry.rec.requests);
    }
    const sorted = nodes.items.items;
    std.mem.sort(NodeTally, sorted, {}, by_name);
    return .{ .revision = assigned.revision, .nodes = sorted };
}

const Nodes = struct {
    ctx: *const Context,
    items: std.ArrayList(NodeTally) = .empty,

    fn slot(nodes: *Nodes, name: []const u8) Error!*NodeTally {
        for (nodes.items.items) |*tally| {
            if (std.mem.eql(u8, tally.node, name)) return tally;
        }
        if (nodes.items.items.len >= constants.nodes_max * 2) {
            return failures.no_memory(nodes.ctx.diag);
        }
        const tally = nodes.items.addOne(nodes.ctx.arena) catch
            return failures.no_memory(nodes.ctx.diag);
        tally.* = .{
            .node = name,
            .recorded = null,
            .allocation_revision = 0,
            .node_revision = 0,
            .reconstructed = zero,
            .finding = null,
        };
        return tally;
    }
};

fn by_name(_: void, first: NodeTally, second: NodeTally) bool {
    return std.mem.order(u8, first.node, second.node) == .lt;
}

fn plus(tally: Tally, requests: records.Requests) Tally {
    return .{
        .allocated = .{
            .cpu_millis = tally.allocated.cpu_millis +| requests.cpu_millis,
            .memory_bytes = tally.allocated.memory_bytes +| requests.memory_bytes,
        },
        .count = tally.count +| 1,
    };
}

pub fn tally_equal(first: Tally, second: Tally) bool {
    if (first.count != second.count) return false;
    if (first.allocated.cpu_millis != second.allocated.cpu_millis) return false;
    return first.allocated.memory_bytes == second.allocated.memory_bytes;
}

/// `{"recorded":…,"reconstructed":…,"revision":N}`: a finding's evidence.
pub fn evidence(
    ctx: *const Context,
    recorded: Tally,
    reconstructed: Tally,
    revision: Revision,
) Error![]const u8 {
    const text = try controller.format(
        ctx,
        "{{\"recorded\":{f},\"reconstructed\":{f},\"revision\":{d}}}",
        .{ TallyJson{ .tally = recorded }, TallyJson{ .tally = reconstructed }, revision },
    );
    assert(text.len <= constants.decision_evidence_bytes_max);
    return text;
}

pub const TallyJson = struct {
    tally: Tally,

    pub fn format(value: TallyJson, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{{\"cpu_millis\":{d},\"memory_bytes\":{d},\"count\":{d}}}", .{
            value.tally.allocated.cpu_millis,
            value.tally.allocated.memory_bytes,
            value.tally.count,
        });
    }
};

// ---- Repair (the scheduler's, on an operator's request) -------------------------------------

pub const repair_actor = "scheduler";
pub const repair_action = "repair_allocation";

pub const Repaired = struct {
    revision: Revision,
    decision: []const u8,
    recorded: Tally,
    reconstructed: Tally,
};

pub const RepairResult = union(enum) {
    repaired: Repaired,
    /// The node has no open finding: nothing to repair (`ZC-E0402`).
    no_finding,
    /// A compare failed: the accounting or the finding moved. Nothing was written.
    conflict,
};

/// Writes the node's reconstructed tally to `/allocations/<node>` with a `repair_allocation`
/// decision whose cause is the finding's decision and whose reason names the operator's request.
/// Compares `/allocations/<node>` and `/audit/allocations/<node>` at the revisions read; no
/// readiness compare, so a lost node can be repaired.
pub fn repair(
    ctx: *const Context,
    source: *controller.DecisionSource,
    node: []const u8,
    request_id: []const u8,
) Error!RepairResult {
    assert(node.len > 0);
    assert(request_id.len > 0);
    const reconstruction = try reconstruct(ctx);
    const tally = for (reconstruction.nodes) |*tally| {
        if (std.mem.eql(u8, tally.node, node)) break tally;
    } else return .no_finding;
    const finding = tally.finding orelse return .no_finding;
    const node_at = records.node_key(node);
    const at = reconstruction.revision;
    const registered = try ctx.store.get(ctx.arena, node_at.slice(), at, ctx.diag);
    const node_revision = if (registered.kv) |kv| kv.mod_revision else tally.node_revision;
    const value: records.Allocation = .{
        .allocated = tally.reconstructed.allocated,
        .count = tally.reconstructed.count,
        .node_revision = node_revision,
    };
    var batch: controller.Batch = .{};
    const allocation_at = records.allocation_key(node);
    const audit_at = records.audit_key(node);
    const allocation_key = try controller.key_copy(ctx, &allocation_at);
    batch.expect(allocation_key, tally.allocation_revision);
    batch.expect(try controller.key_copy(ctx, &audit_at), finding.kv.mod_revision);
    batch.put(allocation_key, try records.encode(ctx.arena, value, ctx.diag));
    const recorded = tally.recorded orelse zero;
    const id = try controller.put_decision(ctx, source, .{
        .actor = repair_actor,
        .action = repair_action,
        .subject = .{ .kind = .node, .name = node },
        .reason = try controller.format(
            ctx,
            "repaired on request {s}: {d} assignments, recorded {d}",
            .{ request_id, tally.reconstructed.count, recorded.count },
        ),
        .cause = .{ .kind = .decision, .id = finding.rec.decision },
        .cause_evidence = .{ .text = try evidence(
            ctx,
            recorded,
            tally.reconstructed,
            reconstruction.revision,
        ) },
    }, &batch);
    return switch (try controller.commit(ctx, .scheduler, &batch)) {
        .conflict => .conflict,
        .applied => |revision| .{ .repaired = .{
            .revision = revision,
            .decision = ctx.arena.dupe(u8, id.slice()) catch return failures.no_memory(ctx.diag),
            .recorded = recorded,
            .reconstructed = tally.reconstructed,
        } },
    };
}
