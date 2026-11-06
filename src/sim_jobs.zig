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
    first_seen_ms: u64,
    ended_since_ms: ?u64,
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

/// The bound of J8: the deadline, the grace, the kill, one resync for the agent to look, the
/// clocks' rate error (`clock_ppm`, either way) and the simulator's granularity. An agent that is
/// cut off from the server cannot read its run, so it enforces the deadline only through the
/// fence: a cut that begins just before the deadline adds what the fence needs (the lease's ttl
/// less the margin, the stop, the kill).
pub fn deadline_bound_ms(
    deadline_ms: u64,
    grace_ms: u64,
    clock_ppm: u64,
    lease_ttl_ms: u64,
    granularity_ms: u64,
) u64 {
    const base = deadline_ms + grace_ms;
    const fenced = lease_ttl_ms - constants.fence_margin_ms + constants.fence_stop_ms +
        constants.fence_kill_latency_ms;
    return base + base * clock_ppm / 1_000_000 + constants.fence_kill_latency_ms +
        constants.agent_resync_ms + fenced + granularity_ms;
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
    try std.testing.expect(deadline_bound_ms(10_000, 0, 10_000, 10_000, 0) >
        deadline_bound_ms(10_000, 0, 0, 10_000, 0));
}
