//! Invariants both simulations check over the store (C1 slice 4g): the summaries count exactly,
//! a lost node's replicas wait out the grace, the allocation auditor stays quiet, and I7. Each
//! check returns what it found wrong, or null; the simulation reports it as a failed step.
//! Core: reads the store through a `controller.Context` and nothing else.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;

/// What a check found wrong; null when it holds.
pub const Found = ?[]const u8;

/// Decisions counted by the key of the summary that counts them.
pub const Counts = std.StringHashMapUnmanaged(u64);

const out_of_memory = "the checks ran out of memory";
const summaries_listed_max: u32 = constants.store_list_limit_max * 64;

pub fn count(ctx: *const Context, counts: *Counts, decision: *const records.Decision) Found {
    const subject = decision.subject;
    const key = records.summary_key(
        subject.kind,
        subject.name,
        decision.action,
        decision.cause.kind,
    );
    const owned = ctx.arena.dupe(u8, key.slice()) catch return out_of_memory;
    const slot = counts.getOrPut(ctx.arena, owned) catch return out_of_memory;
    if (!slot.found_existing) slot.value_ptr.* = 0;
    slot.value_ptr.* += 1;
    return null;
}

/// Every summary at `at` counts exactly the decisions `counts` holds for it (all of them, read at
/// `at`), and every counted decision has its summary. The caller skips it once retention has
/// dropped a decision: a summary keeps counting what was dropped.
pub fn summaries(ctx: *const Context, counts: *const Counts, at: store.Revision) Found {
    const listed = controller.list_all(
        records.Summary,
        ctx,
        records.prefix_summaries,
        at,
        summaries_listed_max,
    ) catch {
        ctx.diag.reset();
        return "the summaries cannot be listed";
    };
    for (listed.items) |entry| {
        const counted = counts.get(entry.kv.key) orelse 0;
        if (entry.rec.count != counted) return "a summary's count is not its decisions'";
    }
    if (listed.items.len != counts.count()) return "a decision is counted by no summary";
    return null;
}

/// A `mark_replica_lost` caused by a decision: that decision is its node's `mark_lost`, and the
/// replica was replaced no earlier than `grace_ms` after it. `cause` is the cause's record, when
/// it is still in the store.
pub fn lost_grace(
    ctx: *const Context,
    decision: *const records.Decision,
    cause: ?store.KeyValue,
    grace_ms: u64,
) Found {
    assert(decision.cause.kind == .decision);
    if (!std.mem.eql(u8, decision.action, "mark_replica_lost")) return null;
    const kv = cause orelse return null;
    const lost = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return "a decision cannot be read";
    };
    if (!std.mem.eql(u8, lost.action, "mark_lost")) {
        return "a lost replica's cause is not its node's mark_lost";
    }
    if (decision.at_ms < lost.at_ms +| grace_ms) {
        return "a lost node's replica was replaced within the grace";
    }
    return null;
}

/// No simulation corrupts an allocation record, so the allocation auditor has no finding open.
pub fn no_findings(ctx: *const Context) Found {
    const page = ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_audit_allocations,
        .limit = 1,
    }, ctx.diag) catch {
        ctx.diag.reset();
        return "the auditor's findings cannot be listed";
    };
    if (page.kvs.len > 0) return "the allocation auditor opened a finding on a healthy run";
    return null;
}

/// I7 (docs/authority.md): at the revision each assignment was written, its node's status was
/// `ready` for the node's tenure then. Only assignments written after `checked` are read, each at
/// its own revision; one whose revision was compacted away is passed over.
pub fn placements(ctx: *const Context, checked: store.Revision, head: store.Revision) Found {
    assert(checked <= head);
    const assigned = controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        head,
        summaries_listed_max,
    ) catch {
        ctx.diag.reset();
        return "the assignments cannot be listed";
    };
    for (assigned.items) |entry| {
        if (entry.kv.mod_revision <= checked) continue;
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
            return "an assignment key names no node";
        if (ready_at(ctx, rest[0..slash], entry.kv.mod_revision)) |found| return found;
    }
    return null;
}

fn ready_at(ctx: *const Context, node: []const u8, at: store.Revision) Found {
    const node_at = records.node_key(node);
    const status_at = records.node_status_key(node);
    const registered = ctx.store.get(ctx.arena, node_at.slice(), at, ctx.diag) catch |err| {
        ctx.diag.reset();
        return if (err == error.Compacted) null else "a node cannot be read at a placement";
    };
    const status = ctx.store.get(ctx.arena, status_at.slice(), at, ctx.diag) catch |err| {
        ctx.diag.reset();
        return if (err == error.Compacted) null else "a node status cannot be read at a placement";
    };
    const node_kv = registered.kv orelse return "I7: a placement onto a node not registered";
    const status_kv = status.kv orelse return "I7: a placement onto a node with no status";
    const judged = records.read(records.NodeStatus, ctx.arena, status_kv, ctx.diag) catch {
        ctx.diag.reset();
        return "a node status cannot be read";
    };
    if (judged.state != .ready) return "I7: a placement onto a node that is not ready";
    if (judged.tenure != node_kv.mod_revision) {
        return "I7: a placement onto a node whose status judged another tenure";
    }
    return null;
}
