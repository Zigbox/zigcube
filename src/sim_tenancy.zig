//! B6's P1 in the cluster simulation, judged from the simulation's own record (docs/briefs/b6.md):
//! no exclusive node holds a job of another tenant or a service, across node loss, re-registration
//! with other labels, and partitions.
//!
//! The judge does not read a node's labels or a run's `require` back from the store and trust
//! them: it knows which label set each node's agent was configured with when its tenure
//! registered (`note_registrations`, which also checks that the store holds exactly those) and
//! which tenant each job was created for (`job_tenant`), and it decides with its own rule
//! (`refuses`), not the scheduler's.
//!
//! Two parts (docs/decisions/2026-11-13-b6-slice2-p1.md):
//!
//! - P1a, at every revision: a new assignment never lands on a node whose registered labels
//!   refuse it (`placed_problem`, in the tap's `before`).
//! - P1b: a hold that a re-registration made refused is acted on (a replica removed, a run stopped
//!   or ended) within `acted_ms_max` of a healthy store, and none remains at rest. Moving work off
//!   a node takes several writers in turn (the agent registers; the replica or job controller
//!   acts; the scheduler releases), so a refused hold exists for some revisions; the bound and the
//!   at-rest check are what P1 can ask of them.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const sim_net = @import("sim_net.zig");
const store = @import("store.zig");

/// A sentence that fails the run, or null.
pub const Found = ?[]const u8;

/// The label sets a node of the tenant world may carry: tenant `a` or `b`, each exclusive to its
/// tenant or not. Two of the four are exclusive.
pub const tenant_sets = [_][]const []const u8{
    &.{"tenant=a"},
    &.{"tenant=b"},
    &.{ "tenant=a", "exclusive=tenant" },
    &.{ "tenant=b", "exclusive=tenant" },
};

/// The tenant letter of each set in `tenant_sets`, and whether the set is exclusive.
const set_tenant = [_][]const u8{ "a", "b", "a", "b" };
const set_exclusive = [_]bool{ false, false, true, true };

comptime {
    assert(set_tenant.len == tenant_sets.len);
    assert(set_exclusive.len == tenant_sets.len);
}

/// The tenant job number `n` of the tenant world requires (no draw): every fourth names none (it
/// may use only a node that is not exclusive), most name `a` or `b`, and every eleventh names a
/// tenant no node carries (it stays pending and ends `not_started`).
pub fn job_tenant(n: u32) ?[]const u8 {
    if (n % 11 == 4) return "c";
    return switch (n % 4) {
        0 => null,
        1, 3 => "a",
        else => "b",
    };
}

/// The job number of a name made by the simulation's `create_job` ("jb-N"); null for any other.
pub fn job_number(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "jb-")) return null;
    return std.fmt.parseInt(u32, name["jb-".len..], 10) catch null;
}

/// How long a hold a re-registration made refused may stay unacted on, counted from when it was
/// first seen or the store last failed, whichever is later. A registration wakes both
/// controllers at once (the job controller watches `/nodes/`, the replica controller
/// `/node-status/`), and each acts in that pass, so on a healthy store this is a pass and a
/// retried write, not the 30 s resync. It is tight on purpose: a node that comes back under new
/// labels comes back empty (a new tenure), and the paths that replace what a node lost also
/// clear such holds, within seconds to tens of seconds; only a bound under those tells a missing
/// eviction (`relabel_kept`) from them. Per the supervisor's ruling it is a stated multiple of the
/// measured worst case: over seeds 1..60 (150 operations, `--c1 --strong --tenants`) every one of
/// 31 refused holds was acted on before the next one-second scan, so 5 times that resolution.
/// A sim-check constant, not a product bound.
pub const acted_ms_max: u64 = 5_000;

/// Refused holds tracked at once; more fails the run (the world holds far fewer).
const holds_max: u32 = 256;

const Hold = struct {
    /// Wyhash of the `/assigned/` key.
    key_hash: u64,
    since_ms: u64,
    /// Seen by the scan in progress.
    seen: bool,
};

const Registration = struct {
    /// The index into `tenant_sets` the tenure registered with.
    set: u8,
    /// The `/nodes/<name>` key's mod revision: only the node's agent writes the key, so a new one
    /// is a registration (an agent that restarts within its lease registers again in place).
    mod_revision: store.Revision,
};

pub const Tenancy = struct {
    /// Per node: the registration of its current tenure; null while it has none.
    registered: [sim_net.nodes_max]?Registration = @splat(null),
    /// The set the node last registered with, kept across the tenure's end.
    last_set: [sim_net.nodes_max]?u8 = @splat(null),
    holds: [holds_max]Hold = undefined,
    hold_count: u32 = 0,
    /// Registrations whose set differed from the node's previous one.
    relabels: u32 = 0,
    /// New assignments judged by P1a, and refused holds P1b saw.
    placements_judged: u64 = 0,
    refused_seen: u64 = 0,
    /// The longest a refused hold waited to be acted on, from when it was first seen.
    acted_worst_ms: u64 = 0,
    violation: Found = null,
};

/// Whether a node registered with set `set` refuses an assignment: a run whose job requires
/// `tenant` (or none, null), or a service replica (`is_job` false). The judge's own rule: a
/// tenant run goes only to a node of that tenant; a run of no tenant and a replica only to a node
/// that is not exclusive.
pub fn refuses(set: u8, is_job: bool, tenant: ?[]const u8) bool {
    assert(set < tenant_sets.len);
    if (is_job) {
        if (tenant) |t| return !std.mem.eql(u8, t, set_tenant[set]);
    }
    return set_exclusive[set];
}

/// Records each node's registration as the store holds it after a commit (or a lease expiry): a
/// new `/nodes/<name>` mod revision is a registration made with `configured[i]`, the set node
/// `i`'s agent runs with, and the stored labels must be exactly that set's.
pub fn note_registrations(
    t: *Tenancy,
    ctx: *const controller.Context,
    names: []const []const u8,
    configured: []const u8,
) void {
    assert(names.len == configured.len);
    assert(names.len <= sim_net.nodes_max);
    for (names, configured, 0..) |name, set, i| {
        const key = records.node_key(name);
        const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            continue; // The tap reads the store beneath the faults; a refusal is not P1's.
        };
        const kv = got.kv orelse {
            t.registered[i] = null;
            continue;
        };
        if (t.registered[i]) |known| {
            if (known.mod_revision == kv.mod_revision) continue;
        }
        const node = records.read(records.Node, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            t.violation = t.violation orelse "P1: a node cannot be decoded";
            continue;
        };
        if (!labels_equal(node.labels, tenant_sets[set])) {
            t.violation = t.violation orelse
                "P1: a node's stored labels are not those its agent registered with";
        }
        if (t.last_set[i]) |last| {
            if (last != set) t.relabels += 1;
        }
        t.registered[i] = .{ .set = set, .mod_revision = kv.mod_revision };
        t.last_set[i] = set;
    }
}

fn labels_equal(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// P1a: each new assignment in `request` lands on a node whose registered labels take it, and a
/// run's stored `require` is the one its job was created with. Called before the transaction
/// commits, against the head it commits over.
pub fn placed_problem(
    t: *Tenancy,
    ctx: *const controller.Context,
    names: []const []const u8,
    request: store.TxnRequest,
) Found {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_assigned)) continue;
        const existing = ctx.store.get(ctx.arena, put.key, null, ctx.diag) catch {
            ctx.diag.reset();
            return "P1: an assignment cannot be read";
        };
        if (existing.kv != null) continue;
        const assigned = std.json.parseFromSliceLeaky(records.Assigned, ctx.arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch return "P1: an assignment cannot be decoded";
        const index = node_index(names, put.key) orelse continue; // Not a simulated node.
        const registration = t.registered[index] orelse continue; // I7's to say.
        t.placements_judged += 1;
        var tenant: ?[]const u8 = null;
        if (assigned.job) |job| {
            const number = job_number(job) orelse continue;
            tenant = job_tenant(number);
            if (require_problem(ctx, job, tenant)) |found| return found;
        }
        if (refuses(registration.set, assigned.job != null, tenant)) {
            return if (assigned.job != null)
                "P1: a run placed on a node whose registered labels refuse its job"
            else
                "P1: a service replica placed on an exclusive node";
        }
    }
    return null;
}

/// The stored run of `job` carries exactly `require = {tenant = <tenant>}`, or none.
fn require_problem(ctx: *const controller.Context, job: []const u8, tenant: ?[]const u8) Found {
    const run_at = records.job_run_key(job);
    const got = ctx.store.get(ctx.arena, run_at.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "P1: a run cannot be read";
    };
    const kv = got.kv orelse return null; // J5's to say.
    const run = records.read(records.JobRun, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return "P1: a run cannot be decoded";
    };
    const require: []const records.Pair = if (run.placement) |p| p.require else &.{};
    const want = tenant orelse {
        if (require.len == 0) return null;
        return "P1: a run's stored require is not the one its job was created with";
    };
    if (require.len == 1 and std.mem.eql(u8, require[0][0], "tenant") and
        std.mem.eql(u8, require[0][1], want)) return null;
    return "P1: a run's stored require is not the one its job was created with";
}

/// The index in `names` of the node an `/assigned/<node>/<id>` key names.
fn node_index(names: []const []const u8, key: []const u8) ?usize {
    assert(std.mem.startsWith(u8, key, records.prefix_assigned));
    const rest = key[records.prefix_assigned.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, rest[0..slash])) return i;
    }
    return null;
}

/// P1b: reads every assignment, tracks those their node's registration refuses, and fails one
/// left unacted on for `acted_ms_max` after `healthy_since_ms` (the last store failure) or its
/// first sighting. With `at_rest`, any refused assignment left fails. Call it only on a healthy
/// store.
pub fn scan(
    t: *Tenancy,
    ctx: *const controller.Context,
    names: []const []const u8,
    now_ms: u64,
    healthy_since_ms: u64,
    at_rest: bool,
) Found {
    const all = controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        null,
        constants.replicas_max + constants.job_admitted_window_max,
    ) catch {
        ctx.diag.reset();
        return "P1: the assignments cannot be read";
    };
    for (t.holds[0..t.hold_count]) |*hold| hold.seen = false;
    for (all.items) |entry| {
        const index = node_index(names, entry.kv.key) orelse continue;
        const registration = t.registered[index] orelse continue;
        var tenant: ?[]const u8 = null;
        if (entry.rec.job) |job| tenant = job_tenant(job_number(job) orelse continue);
        if (!refuses(registration.set, entry.rec.job != null, tenant)) continue;
        if (at_rest) return "P1: a refused assignment remains at rest";
        const hold = track(t, std.hash.Wyhash.hash(0, entry.kv.key), now_ms) orelse
            return "P1: more refused holds than the check tracks";
        if (acted_on(ctx, &entry.rec)) continue;
        const waited = now_ms -| hold.since_ms;
        t.acted_worst_ms = @max(t.acted_worst_ms, waited);
        if (now_ms >= @max(hold.since_ms, healthy_since_ms) +| acted_ms_max) {
            return if (entry.rec.job != null)
                "P1: a job held on a node that refuses it past the bound"
            else
                "P1: a service replica held on an exclusive node past the bound";
        }
    }
    var kept: u32 = 0;
    for (t.holds[0..t.hold_count]) |hold| {
        if (!hold.seen) continue;
        t.holds[kept] = hold;
        kept += 1;
    }
    t.hold_count = kept;
    return null;
}

fn track(t: *Tenancy, key_hash: u64, now_ms: u64) ?*Hold {
    for (t.holds[0..t.hold_count]) |*hold| {
        if (hold.key_hash != key_hash) continue;
        hold.seen = true;
        return hold;
    }
    if (t.hold_count == holds_max) return null;
    t.holds[t.hold_count] = .{ .key_hash = key_hash, .since_ms = now_ms, .seen = true };
    t.hold_count += 1;
    t.refused_seen += 1;
    return &t.holds[t.hold_count - 1];
}

/// Whether the server has acted on a refused hold: the replica is gone, or the run is gone,
/// replaced, stopped or ended. The scheduler releases the assignment afterwards.
fn acted_on(ctx: *const controller.Context, assigned: *const records.Assigned) bool {
    const job = assigned.job orelse {
        const key = records.replica_key(assigned.service, assigned.replica);
        const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            return true; // Unreadable on a healthy store is another check's.
        };
        return got.kv == null;
    };
    const run_at = records.job_run_key(job);
    const got = ctx.store.get(ctx.arena, run_at.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return true;
    };
    const kv = got.kv orelse return true;
    const run = records.read(records.JobRun, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return true;
    };
    if (!std.mem.eql(u8, run.id, assigned.replica)) return true;
    if (run.stop != null) return true;
    const status_at = records.job_status_key(job);
    const status_got = ctx.store.get(ctx.arena, status_at.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return true;
    };
    const status_kv = status_got.kv orelse return false;
    const status = records.read(records.JobStatus, ctx.arena, status_kv, ctx.diag) catch {
        ctx.diag.reset();
        return true;
    };
    return records.job_state_terminal(status.state);
}

test "refuses: the judge's own rule" {
    // Tenant runs go to their tenant's nodes, exclusive or not.
    try std.testing.expect(!refuses(0, true, "a"));
    try std.testing.expect(!refuses(2, true, "a"));
    try std.testing.expect(refuses(1, true, "a"));
    try std.testing.expect(refuses(3, true, "a"));
    try std.testing.expect(refuses(0, true, "c"));
    // A run of no tenant and a replica avoid exclusive nodes.
    try std.testing.expect(!refuses(1, true, null));
    try std.testing.expect(refuses(3, true, null));
    try std.testing.expect(!refuses(0, false, null));
    try std.testing.expect(refuses(2, false, null));
}
