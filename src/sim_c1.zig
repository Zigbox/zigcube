//! The checks of `sim-c1` (docs/authority.md §4), run by the cluster simulator from `TapStore`:
//! `at_revision` right after each revision commits (I1a, I4, I6, I7), and `before_commit` just
//! ahead of each transaction, whose verdict counts only if the transaction then commits (I2, I3:
//! both are about the state a transaction commits over, which is the head just before it). Each
//! returns null, or the sentence that names the
//! invariant it broke, which starts with the invariant's label (`I6: ...`) so that a negative test
//! can say which one it expects. They read the store at its head, which is the revision just made:
//! nothing runs between the commit and the check. Core code.

const std = @import("std");
const assert = std.debug.assert;
const accounting = @import("allocations.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const scheduler = @import("scheduler.zig");
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
        constants.assigned_max,
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

/// What `before_commit` judged and what it could not: the report prints it, so that a check that
/// quietly stopped judging shows.
pub const Tally = struct {
    /// Writes under a tenure or a placement epoch, each compared on its key (I2).
    guarded_writes: u64 = 0,
    /// Cited observations proved admissible (I3).
    observations_judged: u64 = 0,
    /// Cited observations not judged: the revision was compacted, or the cause is incomplete.
    observations_unjudged: u64 = 0,
    /// Citations of a key that is not an agent's report (a node, an allocation): not §3's.
    facts_other: u64 = 0,
    /// Placements checked for fit and spread (L1, `scheduler.placement_problem`).
    placements_judged: u64 = 0,
};

/// Checks one transaction about to commit against the head it will commit over (I2 and I3). The
/// caller keeps the verdict and acts on it only if the transaction commits: a transaction whose
/// compare fails writes nothing, which is the store doing its job.
pub fn before_commit(ctx: *const Context, request: store.TxnRequest, tally: *Tally) Found {
    if (scheduler.placement_problem(ctx, request, &tally.placements_judged)) |found| return found;
    if (superseded(ctx, request, tally)) |found| return found;
    return admissible_observations(ctx, request, tally);
}

/// The key whose compare guards a write: an agent's put under `/observed/<node>/` rests on the
/// node's tenure (`/nodes/<node>`), and any write to `/assigned/<node>/<id>` on that key's own
/// revision (the placement epoch). A delete under `/observed/` is the node controller's cleanup of
/// a node whose tenure is gone, so it is not guarded.
fn guard_of(op: store.Op) ?records.Key {
    switch (op) {
        .put => |put| if (std.mem.startsWith(u8, put.key, records.prefix_observed)) {
            const rest = put.key[records.prefix_observed.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
            return records.node_key(rest[0..slash]);
        },
        .delete => {},
    }
    const key = switch (op) {
        .put => |put| put.key,
        .delete => |key| key,
    };
    if (!std.mem.startsWith(u8, key, records.prefix_assigned)) return null;
    var guard: records.Key = .{};
    if (key.len > guard.bytes.len) return null;
    @memcpy(guard.bytes[0..key.len], key);
    guard.len = @intCast(key.len);
    return guard;
}

/// I2: every write under a tenure or a placement epoch carries a compare on that key, and the
/// key is still at the revision compared when the transaction commits.
fn superseded(ctx: *const Context, request: store.TxnRequest, tally: *Tally) Found {
    for (request.on_success) |op| {
        const guard = guard_of(op) orelse continue;
        var compared: ?store.Revision = null;
        for (request.compares) |compare| {
            if (std.mem.eql(u8, compare.key, guard.slice())) compared = compare.mod_revision;
        }
        const revision = compared orelse {
            return "I2: a transaction wrote under a tenure or placement epoch it did not compare";
        };
        const got = ctx.store.get(ctx.arena, guard.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            return "I2: a tenure or placement epoch cannot be read";
        };
        const now: store.Revision = if (got.kv) |kv| kv.mod_revision else 0;
        if (now != revision) {
            return "I2: a transaction commits over a superseded tenure or placement epoch";
        }
        tally.guarded_writes += 1;
    }
    return null;
}

/// I3: each decision in `request` that cites an observation cites one that is admissible where the
/// decision commits (authority.md §3): its tenure is the node's current tenure, its assignment is
/// the current revision of `/assigned/<node>/<id>`, and `/node-status/<node>` is ready. The
/// observation itself is read at the cited revision; one compaction took is counted, not judged.
fn admissible_observations(ctx: *const Context, request: store.TxnRequest, tally: *Tally) Found {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
        const decision = std.json.parseFromSliceLeaky(records.Decision, ctx.arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch {
            tally.observations_unjudged += 1;
            continue;
        };
        if (decision.cause.kind != .observed) continue;
        const key = decision.cause.key orelse "";
        const revision = decision.cause.revision orelse 0;
        if (key.len == 0 or revision == 0) {
            tally.observations_unjudged += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, key, records.prefix_observed)) {
            // A node's registration or an allocation, cited as an observation of the node
            // controller or the auditor: not an agent's report, which §3 is about.
            tally.facts_other += 1;
            continue;
        }
        const got = ctx.store.get(ctx.arena, key, revision, ctx.diag) catch {
            ctx.diag.reset();
            tally.observations_unjudged += 1;
            continue;
        };
        const kv = got.kv orelse
            return "I3: a decision cites an observation that does not exist at its cited revision";
        if (admissible(ctx, kv)) |found| return found;
        tally.observations_judged += 1;
    }
    return null;
}

fn admissible(ctx: *const Context, kv: store.KeyValue) Found {
    const observed = records.read(records.Observed, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return "I3: a cited observation cannot be decoded";
    };
    const tenure = observed.tenure orelse return "I3: a cited observation names no tenure";
    const node_key = records.node_key(observed.node);
    const node = ctx.store.get(ctx.arena, node_key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "I3: a node cannot be read";
    };
    const node_kv = node.kv orelse return "I3: a decision cites an observation of a node that " ++
        "is not registered";
    if (node_kv.mod_revision != tenure) {
        return "I3: a decision cites an observation from another tenure of its node";
    }
    // The agent stamps `assignment` from slice 6 (keys.md); until then a report has none, and
    // §3's second condition waits for it.
    if (observed.assignment) |epoch| {
        const assigned_key = records.assigned_key(observed.node, observed.replica);
        const assigned = ctx.store.get(ctx.arena, assigned_key.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            return "I3: an assignment cannot be read";
        };
        const assigned_kv = assigned.kv orelse return "I3: a decision cites an observation of " ++
            "a replica that is not assigned";
        if (assigned_kv.mod_revision != epoch) {
            return "I3: a decision cites an observation from another placement epoch";
        }
    }
    const status_key = records.node_status_key(observed.node);
    const status = ctx.store.get(ctx.arena, status_key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "I3: a node status cannot be read";
    };
    const status_kv = status.kv orelse return "I3: a decision cites an observation of a node " ++
        "with no status";
    const judged = records.read(records.NodeStatus, ctx.arena, status_kv, ctx.diag) catch {
        ctx.diag.reset();
        return "I3: a node status cannot be decoded";
    };
    if (judged.state != .ready) {
        return "I3: a decision cites an observation of a node that is not ready";
    }
    return null;
}
