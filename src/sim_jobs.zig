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
/// Containers the trackers keep a clock for at once: every container the runtimes of the most
/// nodes a simulation has can hold (`sim_cluster.zig` asserts the product), so that no live job
/// container goes unjudged for want of a slot.
pub const watch_max: u32 = 16 * constants.runtime_handles_max;

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
    /// The node's total of wedged time when the container was first seen.
    wedged_base_ms: u64 = 0,
    /// Whether it was re-taken at the start of the window that matters to J8, the deadline.
    wedge_marked: bool = false,
    /// The node's total of wedged time when the run's `stop` was first seen (J6 counts only
    /// wedged time after the stop).
    stop_wedged_base_ms: ?u64 = null,
};

/// How long a watched run's node was wedged since the mark `note_marks` took.
pub fn wedged_since(watch: *const Watch, wedged_total_ms: u64) u64 {
    return wedged_total_ms - watch.wedged_base_ms;
}

/// Takes the node's total of wedged time at the moments the bounds start to count it (every
/// tick, wedged or not): J8's at the run's deadline, J6's at the run's stop.
pub fn note_marks(
    watch: *Watch,
    now_ms: u64,
    deadline_ms: u64,
    stopped: bool,
    wedged_total_ms: u64,
) void {
    const age = now_ms -| watch.first_seen_ms;
    if (!watch.wedge_marked and age >= deadline_ms) {
        watch.wedge_marked = true;
        watch.wedged_base_ms = wedged_total_ms;
    }
    if (stopped and watch.stop_wedged_base_ms == null) {
        watch.stop_wedged_base_ms = wedged_total_ms;
    }
}

/// The bound of J6: from the commit of a run's `stop`, the larger of what an agent whose link is
/// up needs (a resync, the grace, the kill) and what the fence needs when it is cut off (the
/// lease's ttl less the margin, the stop, the kill), and the simulator's own granularity.
pub fn stop_bound_ms(lease_ttl_ms: u64, grace_ms: u64, granularity_ms: u64) u64 {
    const linked = constants.agent_resync_ms + grace_ms + constants.fence_kill_latency_ms;
    const fenced = lease_ttl_ms - constants.fence_margin_ms + constants.fence_stop_ms +
        constants.fence_kill_latency_ms;
    return @max(linked, fenced) + granularity_ms;
}

/// The bound of J8: the deadline and the grace, the clocks' rate error (`clock_ppm`, either
/// way), the simulator's granularity (`granularity_ms`: when it looks), the kill's latency and the
/// time the node was wedged after the deadline (`wedged_ms`: its agent down or frozen, or a
/// container ignoring its stop; the supervisors run on, but nobody enforces the deadline).
/// Nothing for a cut link, the store being out or a failed step: the agent stops the run from
/// its own records and clock, waking at the deadline and at the end of the grace, so a node cut
/// off from the server gets no more time than one that is not, and neither does the fence's
/// ttl. A deadline enforced merely late, or only through the fence, is caught.
pub fn deadline_bound_ms(
    deadline_ms: u64,
    grace_ms: u64,
    clock_ppm: u64,
    granularity_ms: u64,
    wedged_ms: u64,
) u64 {
    const base = deadline_ms + grace_ms;
    const extra = constants.fence_kill_latency_ms + wedged_ms;
    return base + base * clock_ppm / 1_000_000 + extra + granularity_ms;
}

/// How long a run executed past its deadline and its grace, net of the time its node was wedged
/// after the deadline (`wedged_ms`, as J8 counts it): the report's "past deadline" figure.
pub fn deadline_past_ms(age_ms: u64, deadline_ms: u64, grace_ms: u64, wedged_ms: u64) u64 {
    return (age_ms -| (deadline_ms + grace_ms)) -| wedged_ms;
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
    try std.testing.expect(deadline_bound_ms(10_000, 0, 10_000, 0, 0) >
        deadline_bound_ms(10_000, 0, 0, 0, 0));
    try std.testing.expect(deadline_bound_ms(10_000, 0, 0, 0, 500) >
        deadline_bound_ms(10_000, 0, 0, 0, 0));
}

test "deadline_past_ms: wedged time is not past the deadline" {
    try std.testing.expectEqual(@as(u64, 0), deadline_past_ms(5_000, 4_000, 500, 600));
    try std.testing.expectEqual(@as(u64, 100), deadline_past_ms(5_000, 4_000, 500, 400));
    try std.testing.expectEqual(@as(u64, 500), deadline_past_ms(5_000, 4_000, 500, 0));
    try std.testing.expectEqual(@as(u64, 0), deadline_past_ms(3_000, 4_000, 500, 0));
}

test "J8's bound has no room for the fence" {
    // Goal: pin the release review's MUST (PR #147): the agent enforces a deadline without the
    // server, so J8 gives a cut-off node nothing for the fence. A bound that grew back by the
    // fence's reach would let an agent that stops a run only through the fence pass.
    const fenced = constants.lease_ttl_ms - constants.fence_margin_ms + constants.fence_stop_ms;
    const deadline: u64 = 60_000;
    const grace: u64 = 2_000;
    const bound = deadline_bound_ms(deadline, grace, 0, 0, 0);
    try std.testing.expect(bound < deadline + grace + fenced);
    try std.testing.expectEqual(deadline + grace + constants.fence_kill_latency_ms, bound);
}

test "note_marks: wedges before the deadline do not count" {
    // Goal: pin the tightening of J6 and J8 (#127): the base is re-taken at the start of the
    // window that matters, not kept from first sight. A mutant that never re-takes it leaves
    // a base of 0 and this test fails.
    const deadline: u64 = 60_000;
    var watch: Watch = .{
        .node = 0,
        .name_hash = 1,
        .first_seen_ms = 1000,
        .ended_since_ms = null,
    };
    // 5 s of wedge, long before the window.
    note_marks(&watch, 1000 + 10_000, deadline, false, 5000);
    try std.testing.expect(!watch.wedge_marked);
    try std.testing.expectEqual(@as(u64, 5000), wedged_since(&watch, 5000));
    // At the deadline: the wedge base is taken, and the earlier wedge no longer counts.
    note_marks(&watch, 1000 + deadline, deadline, false, 7000);
    try std.testing.expectEqual(@as(u64, 7000), watch.wedged_base_ms);
    try std.testing.expectEqual(@as(u64, 0), wedged_since(&watch, 7000));
    // A wedge after the mark does count.
    try std.testing.expectEqual(@as(u64, 500), wedged_since(&watch, 7500));
    // J6: the stop's base is taken once, at first sight of the stop.
    note_marks(&watch, 1000 + deadline + 5, deadline, true, 7600);
    try std.testing.expectEqual(@as(?u64, 7600), watch.stop_wedged_base_ms);
    note_marks(&watch, 1000 + deadline + 9, deadline, true, 9000);
    try std.testing.expectEqual(@as(?u64, 7600), watch.stop_wedged_base_ms);
}
