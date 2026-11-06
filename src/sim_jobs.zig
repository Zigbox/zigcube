//! The job half of the cluster simulation (docs/briefs/b1.md, "The checks and their teeth"): the
//! ledger of every `Runtime.start` that J2 and J7 judge, and the bounds J1, J6 and J8 hold the
//! running containers to. `sim_cluster.zig` drives the workload and the per-tick trackers and
//! owns the nodes; this file holds what needs neither. Core code: the ledger is fed by the
//! simulated runtime's start hook and reads the store through a `Context`.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");

const Context = controller.Context;

/// Runs the ledger can hold. A run past it is counted, not judged (J2 stays sound for the rest).
pub const ledger_max: u32 = 4096;
/// Containers the trackers keep a clock for at once.
pub const watch_max: u32 = 128;

/// What a start was judged against, and the first verdict that failed.
pub const State = struct {
    /// Hashes of the run ids started so far, in every node and every agent life.
    ledger: [ledger_max]u64 = undefined,
    ledger_count: u32 = 0,
    ledger_full: u32 = 0,
    /// The first of J2 and J7 to fail; the cluster's safety check reports it.
    violation: ?[]const u8 = null,
    /// Starts judged against a committed claim (J7).
    starts_judged: u64 = 0,
    /// Workload counters: what the report shows so that a run that never made a job shows.
    created: u32 = 0,
    cancelled: u32 = 0,
    ended: u32 = 0,
    /// Per-container clocks of the trackers.
    watch: [watch_max]Watch = undefined,
    watch_count: u32 = 0,
    /// The longest a stopped run was seen executing, and a container past its terminal status.
    stop_worst_ms: u64 = 0,
    overlap_worst_ms: u64 = 0,
    deadline_worst_ms: u64 = 0,
};

/// One live job container: when a tracker first saw it, when it first saw it with its job ended.
pub const Watch = struct {
    node: u32,
    name_hash: u64,
    /// When the tracker first saw the container: the run's start on the ledger, within a tick.
    first_seen_ms: u64,
    ended_since_ms: ?u64,
    /// The node's totals of wedged time and of cut-link time when the container was first seen.
    wedged_base_ms: u64 = 0,
    link_base_ms: u64 = 0,
    /// Whether those two were re-taken at the start of the window that matters to J8: the link's
    /// at the fence's reach before the deadline, the wedge's at the deadline.
    link_marked: bool = false,
    wedge_marked: bool = false,
    /// The node's total of wedged time when the run's `stop` was first seen (J6 counts only
    /// wedged time after the stop).
    stop_wedged_base_ms: ?u64 = null,
};

/// The bound of J6: from the commit of a run's `stop`, the larger of what an agent whose link is
/// up needs (a resync, the grace, the kill) and what the fence needs when it is cut off (the
/// lease's ttl less the margin, the stop, the kill), and the simulator's own granularity.
pub fn stop_bound_ms(lease_ttl_ms: u64, grace_ms: u64, granularity_ms: u64) u64 {
    const linked = constants.agent_resync_ms + grace_ms + constants.fence_kill_latency_ms;
    const fenced = lease_ttl_ms - constants.fence_margin_ms + constants.fence_stop_ms +
        constants.fence_kill_latency_ms;
    return @max(linked, fenced) + granularity_ms;
}

/// How much of its window a run's node could not enforce the deadline.
pub const Cut = struct {
    /// Time the agent was down or frozen, or a container ignored its stop, during the window.
    wedged_ms: u64,
    /// Whether the node's link or the store was cut at any time during the window: the agent could
    /// not read its run, so it enforced the deadline only through the fence.
    link: bool,
};

/// The bound of J8: the deadline, the grace, the clocks' rate error (`clock_ppm`, either way),
/// the simulator's granularity, the kill and two resyncs for the agent to look (to stop, to
/// kill). Only if the node was cut off during the run's window (`cut`: partitioned, the store
/// out, a failed step or a failed watch and its back-off) the fence replaces the resync and
/// the kill (the lease's ttl less the margin, the stop, the kill), and the time the node was
/// wedged is added: its supervisors run on, but nobody enforces the deadline. A node that was
/// never cut off gets no more, so a deadline enforced merely late is caught.
pub fn deadline_bound_ms(
    deadline_ms: u64,
    grace_ms: u64,
    clock_ppm: u64,
    lease_ttl_ms: u64,
    granularity_ms: u64,
    cut: Cut,
) u64 {
    const base = deadline_ms + grace_ms;
    // The agent looks at the run once a resync: the first look after the deadline stops it, the
    // first look after the grace kills it.
    const linked = constants.fence_kill_latency_ms + 2 * constants.agent_resync_ms;
    const fenced = lease_ttl_ms - constants.fence_margin_ms + constants.fence_stop_ms +
        constants.fence_kill_latency_ms;
    const cut_off = cut.link or cut.wedged_ms > 0;
    const extra = if (cut_off) @max(linked, fenced) + cut.wedged_ms else linked;
    return base + base * clock_ppm / 1_000_000 + extra + granularity_ms;
}

/// J2 and J7 for one `Runtime.start`: the run id was never started before, and a claim for this
/// run, tenure and epoch is committed, and the run has no `stop`. `spec` of a replica is skipped.
pub fn note_start(
    state: *State,
    ctx: *const Context,
    node: []const u8,
    tenure: u64,
    spec: *const runtime.Spec,
) void {
    const job = job_label(spec.labels) orelse return;
    state.starts_judged += 1;
    const hash = std.hash.Wyhash.hash(0, spec.name);
    for (state.ledger[0..state.ledger_count]) |seen| {
        if (seen == hash) return fail(state, "J2: a run id was started a second time");
    }
    if (state.ledger_count < ledger_max) {
        state.ledger[state.ledger_count] = hash;
        state.ledger_count += 1;
    } else {
        state.ledger_full += 1;
    }
    if (claim_problem(ctx, node, tenure, job, spec)) |found| return fail(state, found);
    const run_at = records.job_run_key(job);
    const got = ctx.store.get(ctx.arena, run_at.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return fail(state, "J7: a run cannot be read");
    };
    const kv = got.kv orelse return fail(state, "J7: a run was started that has no run record");
    const run = records.read(records.JobRun, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return fail(state, "J7: a run cannot be decoded");
    };
    if (run.stop != null) return fail(state, "J7: a run was started after its stop committed");
}

fn fail(state: *State, found: []const u8) void {
    if (state.violation == null) state.violation = found;
}

fn job_label(labels: []const runtime.Label) ?[]const u8 {
    for (labels) |label| {
        if (std.mem.eql(u8, label.key, runtime.label_job)) return label.value;
    }
    return null;
}

fn label_value(labels: []const runtime.Label, key: []const u8) ?[]const u8 {
    for (labels) |label| {
        if (std.mem.eql(u8, label.key, key)) return label.value;
    }
    return null;
}

/// The committed claim of `job` by `node`, which must name this run, this tenure and the epoch
/// the container is labelled with.
fn claim_problem(
    ctx: *const Context,
    node: []const u8,
    tenure: u64,
    job: []const u8,
    spec: *const runtime.Spec,
) ?[]const u8 {
    const key = records.job_observed_key(node, job);
    const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return "J7: a claim cannot be read";
    };
    const kv = got.kv orelse return "J7: a run was started with no committed claim";
    const claim = records.read(records.JobObserved, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return "J7: a claim cannot be decoded";
    };
    if (!std.mem.eql(u8, claim.run, spec.name)) {
        return "J7: a run was started on another run's claim";
    }
    if (claim.tenure != tenure) {
        return "J7: a run was started under another tenure than its claim";
    }
    const text = label_value(spec.labels, runtime.label_created) orelse
        return "J7: a run was started with no epoch";
    const epoch = std.fmt.parseInt(u64, text, 10) catch return "J7: a run's epoch is not a number";
    if (claim.assignment != epoch) {
        return "J7: a run was started under another epoch than its claim";
    }
    return null;
}

test "bounds grow with the grace and the deadline" {
    const short = stop_bound_ms(10_000, 0, 0);
    try std.testing.expect(stop_bound_ms(10_000, 60_000, 0) > short);
    const none: Cut = .{ .wedged_ms = 0, .link = false };
    try std.testing.expect(deadline_bound_ms(10_000, 0, 10_000, 10_000, 0, none) >
        deadline_bound_ms(10_000, 0, 0, 10_000, 0, none));
    const cut: Cut = .{ .wedged_ms = 0, .link = true };
    try std.testing.expect(deadline_bound_ms(10_000, 0, 0, 10_000, 0, cut) >
        deadline_bound_ms(10_000, 0, 0, 10_000, 0, none));
}
