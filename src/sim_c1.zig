//! The per-revision checks of `sim-c1` (docs/authority.md §4), run by the cluster simulator from
//! `TapStore` right after each revision commits. Each returns null, or the sentence that names the
//! invariant it broke, which starts with the invariant's label (`I6: ...`) so that a negative test
//! can say which one it expects. They read the store at its head, which is the revision just made:
//! nothing runs between the commit and the check. Core code.

const std = @import("std");
const assert = std.debug.assert;
const accounting = @import("allocations.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");

const Context = controller.Context;

pub const Found = ?[]const u8;

/// Runs every check that one committed transaction calls for. `request` is null for a revision
/// that came from a lease (an expiry deletes a node's registration): nothing is placed by it.
pub fn at_revision(ctx: *const Context, request: ?store.TxnRequest) Found {
    const txn = request orelse return null;
    if (writers.foreign_key(txn)) |_| {
        return "I4: a transaction wrote keys that no single writer role owns";
    }
    if (admissible_observations(ctx, txn)) |found| return found;
    if (!touches(txn, records.prefix_assigned) and !touches(txn, records.prefix_allocations)) {
        return null;
    }
    if (exclusive_assignments(ctx)) |found| return found;
    if (conserved(ctx)) |found| return found;
    return placed_on_ready(ctx, txn);
}

fn touches(request: store.TxnRequest, prefix: []const u8) bool {
    for (request.on_success) |op| {
        const key = switch (op) {
            .put => |put| put.key,
            .delete => |key| key,
        };
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

/// I1a: each replica id has at most one assignment.
fn exclusive_assignments(ctx: *const Context) Found {
    const assigned = controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        null,
        constants.replicas_max,
    ) catch {
        ctx.diag.reset();
        return "I1a: the assignments cannot be listed";
    };
    for (assigned.items, 0..) |first, index| {
        for (assigned.items[index + 1 ..]) |second| {
            if (std.mem.eql(u8, first.rec.replica, second.rec.replica)) {
                return "I1a: a replica has two assignments";
            }
        }
    }
    return null;
}

/// I6: every allocation equals the sum of its node's assignments, and none is above the node's
/// declared capacity. Each placement or release lands in one transaction with its allocation, so
/// equality at every revision is "changed exactly once, by exactly the replica's requests".
fn conserved(ctx: *const Context) Found {
    const rebuilt = accounting.reconstruct(ctx) catch {
        ctx.diag.reset();
        return "I6: the allocations cannot be rebuilt";
    };
    if (rebuilt.first_mismatch() != null) {
        return "I6: an allocation disagrees with the sum of its node's assignments";
    }
    for (rebuilt.nodes) |tally| {
        const recorded = tally.recorded orelse continue;
        const key = records.node_key(tally.node);
        const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            return "I6: a node cannot be read";
        };
        const kv = got.kv orelse continue; // A lost node's allocation drains as it is released.
        const node = records.read(records.Node, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            return "I6: a node cannot be decoded";
        };
        if (recorded.allocated.cpu_millis > node.capacity.cpu_millis or
            recorded.allocated.memory_bytes > node.capacity.memory_bytes)
        {
            return "I6: a node's allocation is above its declared capacity";
        }
    }
    return null;
}

/// I7: every assignment this transaction wrote is on a node whose status is `ready` under the
/// node's current tenure.
fn placed_on_ready(ctx: *const Context, request: store.TxnRequest) Found {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_assigned)) continue;
        const rest = put.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "I7: a malformed key";
        if (ready(ctx, rest[0..slash])) |found| return found;
    }
    return null;
}

fn ready(ctx: *const Context, node: []const u8) Found {
    const node_key = records.node_key(node);
    const status_key = records.node_status_key(node);
    const registered = ctx.store.get(ctx.arena, node_key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "I7: a node cannot be read";
    };
    const status = ctx.store.get(ctx.arena, status_key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "I7: a node status cannot be read";
    };
    const node_kv = registered.kv orelse return "I7: a placement onto a node not registered";
    const status_kv = status.kv orelse return "I7: a placement onto a node with no status";
    const judged = records.read(records.NodeStatus, ctx.arena, status_kv, ctx.diag) catch {
        ctx.diag.reset();
        return "I7: a node status cannot be decoded";
    };
    if (judged.state != .ready) return "I7: a placement onto a node that is not ready";
    if (judged.tenure != node_kv.mod_revision) {
        return "I7: a placement onto a node whose status judged another tenure";
    }
    return null;
}

/// I3: each decision in `request` that cites an observation cites one that was admissible at its
/// revision: the report named the tenure of its node, and that node's registration, read at the
/// same revision, was that tenure. A revision compaction took is not judged.
fn admissible_observations(ctx: *const Context, request: store.TxnRequest) Found {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
        const decision = std.json.parseFromSliceLeaky(records.Decision, ctx.arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (decision.cause.kind != .observed) continue;
        const key = decision.cause.key orelse continue;
        const revision = decision.cause.revision orelse continue;
        if (admissible_at(ctx, key, revision)) |found| return found;
    }
    return null;
}

fn admissible_at(ctx: *const Context, key: []const u8, revision: store.Revision) Found {
    const got = ctx.store.get(ctx.arena, key, revision, ctx.diag) catch {
        ctx.diag.reset();
        return null; // Compacted (or unreadable): not judged.
    };
    const kv = got.kv orelse return null;
    const observed = records.read(records.Observed, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const tenure = observed.tenure orelse return null;
    const node_key = records.node_key(observed.node);
    const node = ctx.store.get(ctx.arena, node_key.slice(), revision, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const node_kv = node.kv orelse return "I3: a decision cites an observation of a node that " ++
        "was not registered at that revision";
    if (node_kv.mod_revision != tenure) {
        return "I3: a decision cites an observation from another tenure of its node";
    }
    return null;
}
