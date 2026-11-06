//! The job controller of B1 (docs/briefs/b1.md, "The job controller"): for every `/jobs/<name>`
//! it creates the run and its `pending` status, ends the run in two phases, and keeps the status
//! true to what the agents observed. It is the only writer of `/job-runs/`, `/job-status/` and
//! `/job-endings`; it places nothing and releases nothing (the scheduler does both).
//!
//! For each job, in this order (a job takes at most one transaction a pass):
//!
//!   1. no run and no status: create both, with a `job-created` decision, unless the job ever had
//!      them. "Ever had" is that decision in `/decisions-by-subject/job/<name>` (owner's choice
//!      A, docs/decisions/2026-11-05-b1-controller-never-recreates-a-run.md); a run without a
//!      status, a status without a run, or that decision without a run is ZC-E0307 and nothing
//!      about the job changes;
//!   2. an admissible report of the run (tenure, assignment epoch and node `ready`: I2, I6) ends it
//!      (the exit table, `map_ending`), or marks it `running`;
//!   3. a run with no claim anywhere gets `stop` (phase one) when the job was cancelled, when its
//!      start-by time passed, or when its node was lost; once it has `stop` and no claim exists
//!      the status is written terminal (phase two), comparing the run, the status and the count;
//!   4. a running run whose tenure ended and stayed ended for `lost_grace_ms` is `failed
//!      unreachable`; a fence report from a newer tenure ends it `failed fenced`.
//!
//! A terminal status is written once. A report that arrives for an ended job is ignored (ZC-W0307
//! is not yet recorded: slice 3 cut it). Core: no thread, no clock but the context's, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const zigbox = @import("zigbox");

const Batch = controller.Batch;
const Context = controller.Context;
const Entry = controller.Entry;
const Error = controller.Error;
const Wakeup = controller.Wakeup;
const Revision = store.Revision;

pub const actor = "job-controller";

pub const watch_prefixes = [_][]const u8{
    records.prefix_jobs,
    records.prefix_job_runs,
    records.prefix_job_status,
    records.prefix_job_observed,
    records.prefix_assigned,
    records.prefix_nodes,
    records.prefix_node_status,
};

const resync_ms: u64 = 30 * 1000;
/// Jobs whose contradiction or unmappable ending this controller already recorded, so a
/// contradictory job costs one decision, not one a pass. A restart forgets them.
const noted_max = 64;
/// Runs whose node's tenure ended without a `lost` judgement of its own, with the time the
/// controller first saw it end.
const seen_max = 128;
const none: u32 = std.math.maxInt(u32);

const Map = std.StringHashMapUnmanaged(u32);

const Seen = struct { hash: u64, at_ms: u64 };

pub const JobController = struct {
    source: controller.DecisionSource,
    /// How long after a run's tenure ended it is failed `unreachable`. A parameter, as the replica
    /// controller's.
    lost_grace_ms: u64 = constants.lost_grace_ms,
    noted: [noted_max]u64 = @splat(0),
    noted_next: u32 = 0,
    seen: [seen_max]Seen = @splat(.{ .hash = 0, .at_ms = 0 }),
    seen_next: u32 = 0,

    /// Decision ids of the controllers are `instance*4 + role`; this one takes the top quarter
    /// of the numbers, which the others never reach for the instances a shell hands out.
    pub fn init(instance: u16) JobController {
        return .{ .source = .{ .instance = 0xC000 +% (instance & 0x3fff) } };
    }

    pub fn reconcile(jc: *JobController, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const world = try read_world(ctx);
        var pass: Pass = .{
            .jc = jc,
            .ctx = ctx,
            .world = &world,
            .txns_left = constants.controller_txns_per_step_max,
            .wake_at_ms = now + resync_ms,
        };
        for (world.jobs) |*job| {
            if (pass.stopped or pass.txns_left == 0) break;
            try pass.step_job(job);
        }
        const again = pass.more or pass.txns_left == 0;
        return .{
            .at_ms = if (again) now else pass.wake_at_ms,
            .prefixes = &watch_prefixes,
            .acted = pass.acted,
        };
    }

    fn was_noted(jc: *const JobController, hash: u64) bool {
        for (jc.noted) |one| if (one == hash) return true;
        return false;
    }

    fn note(jc: *JobController, hash: u64) void {
        jc.noted[jc.noted_next % noted_max] = hash;
        jc.noted_next +%= 1;
    }

    /// When the controller first saw `hash` (a run's tenure) ended: now, the first time.
    fn first_seen(jc: *JobController, hash: u64, now: u64) u64 {
        for (jc.seen) |one| if (one.hash == hash) return one.at_ms;
        jc.seen[jc.seen_next % seen_max] = .{ .hash = hash, .at_ms = now };
        jc.seen_next +%= 1;
        return now;
    }
};

fn hash_of(parts: []const []const u8, number: u64) u64 {
    var hasher = std.hash.Wyhash.init(number);
    for (parts) |part| hasher.update(part);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

// ---- The world a pass reads ------------------------------------------------------------------

const World = struct {
    revision: Revision,
    jobs: []const Entry(records.Job),
    runs: []const Entry(records.JobRun),
    statuses: []const Entry(records.JobStatus),
    observed: []const Entry(records.JobObserved),
    nodes: []const Entry(records.Node),
    node_statuses: []const Entry(records.NodeStatus),
    assigned: []const Entry(records.Assigned),
    endings: ?Entry(records.JobEndings),
    run_of: Map,
    status_of: Map,
    assigned_of: Map,
    observed_head: Map,
    observed_next: []u32,

    fn run(world: *const World, name: []const u8) ?*const Entry(records.JobRun) {
        const at = world.run_of.get(name) orelse return null;
        return &world.runs[at];
    }

    fn status(world: *const World, name: []const u8) ?*const Entry(records.JobStatus) {
        const at = world.status_of.get(name) orelse return null;
        return &world.statuses[at];
    }

    fn assignment(world: *const World, run_id: []const u8) ?*const Entry(records.Assigned) {
        const at = world.assigned_of.get(run_id) orelse return null;
        return &world.assigned[at];
    }

    fn node_entry(world: *const World, name: []const u8) ?*const Entry(records.Node) {
        for (world.nodes) |*entry| if (std.mem.eql(u8, entry.rec.name, name)) return entry;
        return null;
    }

    fn node_status(world: *const World, name: []const u8) ?*const Entry(records.NodeStatus) {
        const prefix = records.prefix_node_status;
        for (world.node_statuses) |*entry| {
            if (std.mem.eql(u8, entry.kv.key[prefix.len..], name)) return entry;
        }
        return null;
    }

    fn endings_revision(world: *const World) Revision {
        return if (world.endings) |entry| entry.kv.mod_revision else 0;
    }

    fn ended_count(world: *const World) u64 {
        return if (world.endings) |entry| entry.rec.ended else 0;
    }
};

/// The node an assignment key `/assigned/<node>/<run>` names.
fn assigned_node(key: []const u8) []const u8 {
    const rest = key[records.prefix_assigned.len..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

fn rows(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at: Revision,
    count_max: u32,
) Error![]const Entry(T) {
    return (try controller.list_all(T, ctx, prefix, at, count_max)).items;
}

fn read_world(ctx: *const Context) Error!World {
    const window = constants.job_admitted_window_max;
    const jobs = try controller.list_all(
        records.Job,
        ctx,
        records.prefix_jobs,
        null,
        constants.jobs_max,
    );
    const at = jobs.revision;
    const runs = try rows(records.JobRun, ctx, records.prefix_job_runs, at, window);
    const statuses = try rows(records.JobStatus, ctx, records.prefix_job_status, at, window);
    const observed = try rows(records.JobObserved, ctx, records.prefix_job_observed, at, window);
    const nodes = try rows(records.Node, ctx, records.prefix_nodes, at, constants.nodes_max);
    const node_statuses = try rows(
        records.NodeStatus,
        ctx,
        records.prefix_node_status,
        at,
        constants.nodes_max,
    );
    const assigned = try rows(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        at,
        constants.assigned_max,
    );
    const got = try ctx.store.get(ctx.arena, records.key_job_endings, at, ctx.diag);
    var endings: ?Entry(records.JobEndings) = null;
    if (got.kv) |kv| {
        const rec = try records.read(records.JobEndings, ctx.arena, kv, ctx.diag);
        endings = .{ .kv = kv, .rec = rec };
    }
    var world: World = .{
        .revision = at,
        .jobs = jobs.items,
        .runs = runs,
        .statuses = statuses,
        .observed = observed,
        .nodes = nodes,
        .node_statuses = node_statuses,
        .assigned = assigned,
        .endings = endings,
        .run_of = .empty,
        .status_of = .empty,
        .assigned_of = .empty,
        .observed_head = .empty,
        .observed_next = ctx.arena.alloc(u32, observed.len) catch
            return failures.no_memory(ctx.diag),
    };
    try index_world(ctx, &world);
    return world;
}

fn index_world(ctx: *const Context, world: *World) Error!void {
    for (world.runs, 0..) |entry, at| {
        world.run_of.put(ctx.arena, entry.rec.job, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
    for (world.statuses, 0..) |entry, at| {
        const name = entry.kv.key[records.prefix_job_status.len..];
        world.status_of.put(ctx.arena, name, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
    for (world.assigned, 0..) |entry, at| {
        if (entry.rec.job == null) continue;
        world.assigned_of.put(ctx.arena, entry.rec.replica, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
    for (world.observed, 0..) |entry, at| {
        const head = world.observed_head.get(entry.rec.run) orelse none;
        world.observed_next[at] = head;
        world.observed_head.put(ctx.arena, entry.rec.run, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
}

// ---- How a run ended -------------------------------------------------------------------------

/// How a report says a run ended: the state, the end, and the cause the agent recorded.
pub const Ending = struct {
    state: records.JobState,
    end: records.JobEnd,
    stop_cause: ?records.StopCause,
};

fn failed(cause: records.JobFailure, stop: ?records.StopCause) Ending {
    return .{ .state = .failed, .end = .{ .kind = .failed, .cause = cause }, .stop_cause = stop };
}

/// The ending a `stopped` report stands for (docs/briefs/b1.md, "Settled here"), or null when the
/// report cannot be mapped (ZC-B0004): the stop cause the agent recorded decides first, because a
/// run it stopped must not read as the exit that stopping caused.
pub fn map_ending(observed: *const records.JobObserved) ?Ending {
    const exit = observed.exit orelse return null;
    if (observed.stop_cause) |cause| return switch (cause) {
        .cancel => .{
            .state = .cancelled,
            .end = .{ .kind = .cancelled },
            .stop_cause = cause,
        },
        .deadline, .not_started => failed(.deadline, cause),
        .fence => failed(.fenced, cause),
        .@"unreachable" => failed(.@"unreachable", cause),
    };
    return switch (exit.kind) {
        .exited => if (exit.code != null and exit.signal == null) .{
            .state = .exited,
            .end = .{ .kind = .exited, .code = exit.code },
            .stop_cause = null,
        } else null,
        .signaled => if (exit.signal != null and exit.code == null) .{
            .state = .exited,
            .end = .{ .kind = .exited, .signal = exit.signal },
            .stop_cause = null,
        } else null,
        .oom => failed(.oom, null),
        .pid_limit => failed(.pid_limit, null),
        .start_failed => failed(.start_failed, null),
        .lost => failed(.unknown, null),
    };
}

// ---- A pass ----------------------------------------------------------------------------------

const Pass = struct {
    jc: *JobController,
    ctx: *const Context,
    world: *const World,
    txns_left: u32,
    acted: u32 = 0,
    more: bool = false,
    stopped: bool = false,
    wake_at_ms: u64,

    fn landed(pass: *Pass, done: controller.Commit) ?Revision {
        switch (done) {
            .applied => |revision| {
                pass.acted += 1;
                pass.txns_left -= 1;
                return revision;
            },
            .conflict => {
                pass.more = true;
                pass.stopped = true;
                return null;
            },
        }
    }

    fn step_job(pass: *Pass, job: *const Entry(records.Job)) Error!void {
        const name = job.rec.name;
        const run = pass.world.run(name);
        const status = pass.world.status(name);
        if (run == null and status == null) return pass.create(job);
        if (run == null or status == null) return pass.contradict(job, run, status);
        if (records.job_state_terminal(status.?.rec.state)) return;
        try pass.advance(job, run.?, status.?);
    }

    // ---- Step 1: the run and its status ----

    fn create(pass: *Pass, job: *const Entry(records.Job)) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        if (try created_before(ctx, name)) return pass.contradict(job, null, null);
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const id = ctx.arena.dupe(u8, records.job_run_id(&buffer, name)) catch
            return failures.no_memory(ctx.diag);
        const now = ctx.clock.now_ms();
        const spec = job.rec;
        const run: records.JobRun = .{
            .id = id,
            .job = name,
            .image = spec.image,
            .source = spec.source,
            .command = spec.command,
            .env = spec.env,
            .limits = spec.limits,
            .deadline_ms = spec.deadline_ms,
            .grace_ms = spec.grace_ms,
            .labels = spec.labels,
            .input_env = spec.input_env,
            .input_digest = spec.input_digest,
            .input_bytes = spec.input_bytes,
            .start_by_ms = spec.created_at_ms +| spec.deadline_ms,
            .created_at_ms = now,
        };
        var batch: Batch = .{};
        const job_at = records.job_key(name);
        const run_at = try controller.key_copy(ctx, &records.job_run_key(name));
        const status_at = try controller.key_copy(ctx, &records.job_status_key(name));
        batch.expect(try controller.key_copy(ctx, &job_at), job.kv.mod_revision);
        batch.expect(run_at, 0);
        batch.expect(status_at, 0);
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "job-created",
            .subject = .{ .kind = .job, .name = name },
            .reason = "created the run for the job",
            .cause = .{ .kind = .desired, .key = job.kv.key, .revision = job.kv.mod_revision },
            .read_revision = pass.world.revision,
        }, &batch);
        const status: records.JobStatus = .{
            .state = .pending,
            .decision = decided.slice(),
            .reported_at_ms = now,
        };
        batch.put(run_at, try records.encode(ctx.arena, run, ctx.diag));
        batch.put(status_at, try records.encode(ctx.arena, status, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// A run or status missing, or a missing run the job once had: recorded once, changed never.
    fn contradict(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: ?*const Entry(records.JobRun),
        status: ?*const Entry(records.JobStatus),
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        const hash = hash_of(&.{ "contradiction", name }, 0);
        if (pass.jc.was_noted(hash)) return;
        const what = if (run == null and status == null)
            "has a job-created decision but neither a run nor a status"
        else if (run == null)
            "has a status but no run"
        else
            "has a run but no status";
        const cause = try controller.format(ctx, "job {s} {s}", .{ name, what });
        const raw = try diagnostic_text(
            ctx,
            .E0307,
            cause,
            "restore the missing record, or delete all the job's keys in one transaction",
        );
        var batch: Batch = .{};
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "hold-contradictory-job",
            .subject = .{ .kind = .job, .name = name },
            .reason = "the job's records contradict each other; nothing about it changes",
            .cause = .{ .kind = .desired, .key = job.kv.key, .revision = job.kv.mod_revision },
            .cause_diagnostic = raw,
            .read_revision = pass.world.revision,
        }, &batch);
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), job.kv.mod_revision);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
        pass.jc.note(hash);
    }

    // ---- Steps 2 to 5: a live run ----

    fn advance(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
    ) Error!void {
        const world = pass.world;
        var any = false;
        var live: ?*const Entry(records.JobObserved) = null;
        var fence: ?*const Entry(records.JobObserved) = null;
        var at = world.observed_head.get(run.rec.id) orelse none;
        while (at != none) : (at = world.observed_next[at]) {
            const entry = &world.observed[at];
            any = true;
            if (pass.admissible(entry, run)) {
                live = entry;
            } else if (entry.rec.stop_cause == .fence and entry.rec.status == .stopped) {
                fence = entry;
            }
        }
        if (live) |entry| {
            if (try pass.from_report(job, run, status, entry)) return;
        }
        if (fence) |entry| {
            if (status.rec.state == .running and status.rec.epoch == entry.rec.assignment) {
                return pass.end(job, run, status, .{
                    .ending = failed(.fenced, .fence),
                    .reason = "the run was fenced and ended",
                    .report = entry,
                });
            }
        }
        if (status.rec.state == .running) return pass.judge_running(job, run, status);
        try pass.judge_unclaimed(job, run, status, any);
    }

    /// A report is admissible when it comes from the tenure the node holds now, under the epoch
    /// the run is assigned at, and the node is ready (authority.md I2, I6).
    fn admissible(
        pass: *Pass,
        entry: *const Entry(records.JobObserved),
        run: *const Entry(records.JobRun),
    ) bool {
        const world = pass.world;
        const node = world.node_entry(entry.rec.node) orelse return false;
        if (node.kv.mod_revision != entry.rec.tenure) return false;
        const placed = world.assignment(run.rec.id) orelse return false;
        if (placed.kv.mod_revision != entry.rec.assignment) return false;
        if (!std.mem.eql(u8, assigned_node(placed.kv.key), entry.rec.node)) return false;
        const judged = world.node_status(entry.rec.node) orelse return false;
        return judged.rec.state == .ready;
    }

    /// An admissible report: a claim or a running report marks the run running; a stopped one ends
    /// it. True when it acted or must stop the pass for this job (an unmappable ending).
    fn from_report(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        entry: *const Entry(records.JobObserved),
    ) Error!bool {
        if (entry.rec.status == .stopped) {
            const ending = map_ending(&entry.rec) orelse {
                try pass.unmappable(job, entry);
                return true;
            };
            try pass.end(job, run, status, .{
                .ending = ending,
                .reason = "the run ended as its agent reported",
                .report = entry,
            });
            return true;
        }
        if (status.rec.state == .running) return false;
        try pass.mark_running(job, run, status, entry);
        return true;
    }

    fn mark_running(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        entry: *const Entry(records.JobObserved),
    ) Error!void {
        const ctx = pass.ctx;
        const now = ctx.clock.now_ms();
        var batch: Batch = .{};
        const status_at = try controller.key_copy(ctx, &records.job_status_key(job.rec.name));
        batch.expect(status_at, status.kv.mod_revision);
        try expect_key(ctx, &batch, &records.job_run_key(job.rec.name), run.kv.mod_revision);
        batch.expect(entry.kv.key, entry.kv.mod_revision);
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "job-running",
            .subject = .{ .kind = .job, .name = job.rec.name },
            .reason = "the run was claimed by its node",
            .cause = .{ .kind = .observed, .key = entry.kv.key, .revision = entry.kv.mod_revision },
            .read_revision = pass.world.revision,
        }, &batch);
        const next: records.JobStatus = .{
            .state = .running,
            .node = entry.rec.node,
            .epoch = entry.rec.assignment,
            .tenure = entry.rec.tenure,
            .started_at_ms = entry.rec.started_at_ms orelse now,
            .decision = decided.slice(),
            .reported_at_ms = now,
        };
        batch.put(status_at, try records.encode(ctx.arena, next, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// A running run: failed `unreachable` once its tenure has been over for the grace.
    fn judge_running(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
    ) Error!void {
        const node = status.rec.node orelse return;
        const tenure = status.rec.tenure orelse return;
        const since = pass.tenure_ended_at(node, tenure, run.rec.id) orelse return;
        if (!pass.past_grace(since)) return;
        try pass.end(job, run, status, .{
            .ending = failed(.@"unreachable", .@"unreachable"),
            .reason = "the node of the run was lost and did not come back within the grace",
            .report = null,
        });
    }

    /// When the tenure `tenure` of `node` ended, as far as the store says: the node controller's
    /// `lost` judgement of that tenure, else the first time this controller saw `/nodes/<node>`
    /// gone or changed. Null while it has not ended.
    fn tenure_ended_at(pass: *Pass, node: []const u8, tenure: u64, run_id: []const u8) ?u64 {
        const world = pass.world;
        if (world.node_status(node)) |judged| {
            if (judged.rec.state == .lost and judged.rec.tenure == tenure) return judged.rec.at_ms;
        }
        const entry = world.node_entry(node);
        if (entry != null and entry.?.kv.mod_revision == tenure) return null;
        const hash = hash_of(&.{ "tenure", run_id, node }, tenure);
        return pass.jc.first_seen(hash, pass.ctx.clock.now_ms());
    }

    fn past_grace(pass: *Pass, since: u64) bool {
        const due = since +| pass.jc.lost_grace_ms;
        if (pass.ctx.clock.now_ms() >= due) return true;
        pass.wake_at_ms = @min(pass.wake_at_ms, due);
        return false;
    }

    /// A run no admissible report claims: stop it when it must not start, end it once it has a
    /// stop and nothing claimed it, and show a placement in the status.
    fn judge_unclaimed(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        any: bool,
    ) Error!void {
        if (run.rec.stop) |stop| {
            if (any) return; // A claim exists: the agent reports how it ended.
            return pass.end_unstarted(job, run, status, stop);
        }
        if (try pass.stop_cause(job, run)) |cause| return pass.write_stop(job, run, status, cause);
        const placed = pass.world.assignment(run.rec.id) orelse return;
        if (status.rec.state != .pending) return;
        try pass.mark_placed(job, run, status, placed);
    }

    fn stop_cause(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
    ) Error!?records.RunStopCause {
        if (job.rec.cancel_requested != null) return .cancel;
        const now = pass.ctx.clock.now_ms();
        if (now > run.rec.start_by_ms) return .not_started;
        const placed = pass.world.assignment(run.rec.id) orelse {
            pass.wake_at_ms = @min(pass.wake_at_ms, run.rec.start_by_ms +| 1);
            return null;
        };
        const node = assigned_node(placed.kv.key);
        const judged = pass.world.node_status(node) orelse return null;
        if (judged.rec.state != .lost) return null;
        if (pass.world.node_entry(node)) |entry| {
            if (entry.kv.mod_revision > judged.rec.tenure) return null;
        }
        if (!pass.past_grace(judged.rec.at_ms)) return null;
        return .@"unreachable";
    }

    fn write_stop(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        cause: records.RunStopCause,
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        var next = run.rec;
        next.stop = .{ .cause = cause, .at_ms = ctx.clock.now_ms() };
        var batch: Batch = .{};
        const run_at = try controller.key_copy(ctx, &records.job_run_key(name));
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), job.kv.mod_revision);
        batch.expect(run_at, run.kv.mod_revision);
        try expect_key(ctx, &batch, &records.job_status_key(name), status.kv.mod_revision);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "stop-job",
            .subject = .{ .kind = .job, .name = name },
            .reason = switch (cause) {
                .cancel => "the job was cancelled before it was claimed",
                .not_started => "the run did not start within its deadline",
                .@"unreachable" => "the node of the run was lost before it claimed the run",
            },
            .cause = .{ .kind = .desired, .key = job.kv.key, .revision = job.kv.mod_revision },
            .read_revision = pass.world.revision,
        }, &batch);
        batch.put(run_at, try records.encode(ctx.arena, next, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    fn mark_placed(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        placed: *const Entry(records.Assigned),
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        var batch: Batch = .{};
        const status_at = try controller.key_copy(ctx, &records.job_status_key(name));
        batch.expect(status_at, status.kv.mod_revision);
        batch.expect(try controller.key_copy(ctx, &records.job_run_key(name)), run.kv.mod_revision);
        batch.expect(placed.kv.key, placed.kv.mod_revision);
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "job-placed",
            .subject = .{ .kind = .job, .name = name },
            .reason = "the run was assigned to a node",
            .cause = cause_of(.desired, &placed.kv),
            .read_revision = pass.world.revision,
        }, &batch);
        var next = status.rec;
        next.state = .placed;
        next.node = assigned_node(placed.kv.key);
        next.epoch = placed.kv.mod_revision;
        next.decision = decided.slice();
        next.reported_at_ms = ctx.clock.now_ms();
        batch.put(status_at, try records.encode(ctx.arena, next, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    // ---- Phase two and the terminal write ----

    /// The run has its `stop` and no claim exists at a revision at or after the stop (the world is
    /// read at one, and the run's last write is the stop): nothing has started and nothing can.
    fn end_unstarted(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        stopped: records.RunStop,
    ) Error!void {
        const ending: Ending = switch (stopped.cause) {
            .cancel => .{
                .state = .cancelled,
                .end = .{ .kind = .cancelled },
                .stop_cause = .cancel,
            },
            .not_started => failed(.deadline, .not_started),
            .@"unreachable" => failed(.not_started, .@"unreachable"),
        };
        try pass.end(job, run, status, .{
            .ending = ending,
            .reason = switch (stopped.cause) {
                .cancel => "the job was cancelled and the run had not started",
                .not_started => "the run did not start within its deadline",
                .@"unreachable" => "the node was lost before it started the run",
            },
            .report = null,
        });
    }

    const End = struct {
        ending: Ending,
        reason: []const u8,
        report: ?*const Entry(records.JobObserved),
    };

    /// The terminal status, once: compares the run, the status and the count of endings (and the
    /// report it rests on).
    fn end(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        done: End,
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        const now = ctx.clock.now_ms();
        var batch: Batch = .{};
        const status_at = try controller.key_copy(ctx, &records.job_status_key(name));
        batch.expect(status_at, status.kv.mod_revision);
        batch.expect(try controller.key_copy(ctx, &records.job_run_key(name)), run.kv.mod_revision);
        batch.expect(records.key_job_endings, pass.world.endings_revision());
        var cause: records.Cause = .{
            .kind = .desired,
            .key = run.kv.key,
            .revision = run.kv.mod_revision,
        };
        if (done.report) |report| {
            batch.expect(report.kv.key, report.kv.mod_revision);
            cause = cause_of(.observed, &report.kv);
        }
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "end-job",
            .subject = .{ .kind = .job, .name = name },
            .reason = done.reason,
            .cause = cause,
            .read_revision = pass.world.revision,
        }, &batch);
        var next = status.rec;
        next.state = done.ending.state;
        next.end = done.ending.end;
        next.stop_cause = done.ending.stop_cause;
        next.ended_at_ms = now;
        next.decision = decided.slice();
        next.reported_at_ms = now;
        if (done.report) |report| {
            next.node = report.rec.node;
            next.diagnostic = report.rec.diagnostic;
            next.started_at_ms = report.rec.started_at_ms orelse next.started_at_ms;
        }
        assert(next.valid());
        const counted: records.JobEndings = .{ .ended = pass.world.ended_count() + 1 };
        batch.put(status_at, try records.encode(ctx.arena, next, ctx.diag));
        batch.put(records.key_job_endings, try records.encode(ctx.arena, counted, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// ZC-B0004: a report that maps to no ending. The job is left as it was; one decision says so.
    fn unmappable(
        pass: *Pass,
        job: *const Entry(records.Job),
        entry: *const Entry(records.JobObserved),
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        const hash = hash_of(&.{ "unmappable", name }, entry.kv.mod_revision);
        if (pass.jc.was_noted(hash)) return;
        const cause = try controller.format(
            ctx,
            "{s} reported an exit of kind {s} that maps to no ending",
            .{ entry.rec.run, @tagName(entry.rec.exit.?.kind) },
        );
        const raw = try diagnostic_text(ctx, .B0004, cause, "report it with the diagnostic bundle");
        var batch: Batch = .{};
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), job.kv.mod_revision);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "hold-unmapped-ending",
            .subject = .{ .kind = .job, .name = name },
            .reason = "the agent's report maps to no ending; the job is left as it was",
            .cause = .{ .kind = .observed, .key = entry.kv.key, .revision = entry.kv.mod_revision },
            .cause_diagnostic = raw,
            .read_revision = pass.world.revision,
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
        pass.jc.note(hash);
    }
};

fn expect_key(
    ctx: *const Context,
    batch: *Batch,
    key: *const records.Key,
    rev: Revision,
) Error!void {
    batch.expect(try controller.key_copy(ctx, key), rev);
}

fn cause_of(kind: records.CauseKind, kv: *const store.KeyValue) records.Cause {
    return .{ .kind = kind, .key = kv.key, .revision = kv.mod_revision };
}

/// True when `/decisions-by-subject/job/<name>` holds a `job-created`: the job had a run.
fn created_before(ctx: *const Context, name: []const u8) Error!bool {
    const prefix = records.index_prefix(.job, name);
    var after: ?[]const u8 = null;
    var at: ?Revision = null;
    while (true) {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = constants.store_list_limit_max,
            .continue_after = after,
            .at_revision = at,
        }, ctx.diag);
        at = page.revision;
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
            if (std.mem.eql(u8, entry.action, "job-created")) return true;
        }
        after = page.continue_after orelse return false;
    }
}

/// A diagnostic as the JSON a decision embeds (DIAGNOSTICS.md).
fn diagnostic_text(
    ctx: *const Context,
    comptime code: codes.Code,
    cause: []const u8,
    fix: []const u8,
) Error!records.Raw {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(code);
    collector.cause("{s}", .{cause});
    collector.fix(.{ .sentence = fix });
    const diagnostic = ctx.arena.create(zigbox.diagnostic.Diagnostic) catch
        return failures.no_memory(ctx.diag);
    diag_mod.to_diagnostic(diagnostic, &collector);
    diagnostic.docs = .{};
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    zigbox.diagnostic.write_json(&text.writer, diagnostic) catch
        return failures.no_memory(ctx.diag);
    const written = text.written();
    assert(written.len > 1);
    assert(written[written.len - 1] == '\n');
    return .{ .text = written[0 .. written.len - 1] };
}
