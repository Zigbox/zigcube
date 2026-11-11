//! The job controller of B1 (docs/briefs/b1.md, "The job controller"): for every `/jobs/<name>`
//! it creates the run and its `pending` status, ends the run in two phases, and keeps the status
//! true to what the agents observed. It is the only writer of `/job-runs/`, `/job-status/` and
//! `/job-endings`; it places nothing and releases nothing (the scheduler does both).
//!
//! For each job, in this order (a job takes at most one transaction a pass):
//!
//!   1. no run and no status: create both, with a `job_created` decision, unless this incarnation
//!      of the job ever had them. "Ever had" is that decision in
//!      `/decisions-by-subject/job/<name>`, written after the job was created (owner's choice A,
//!      docs/decisions/2026-11-05-b1-controller-never-recreates-a-run.md; a job deleted and
//!      created again under the same name is a new incarnation); a run without a status, a status
//!      without a run, or that decision without a run is ZC-E0307 and nothing about the job
//!      changes;
//!   2. an admissible report of the run (tenure, assignment epoch and node `ready`: I2, I6) ends it
//!      (the exit table, `map_ending`), or marks it `running`;
//!   3. a run its node never claimed gets `stop` (phase one) when the job was cancelled, when its
//!      start-by time passed, or when its node was lost; once it has `stop` and no claim exists
//!      the status is written terminal (phase two), comparing the run, the status and the count;
//!   4. a run its node claimed, or that is running, but whose report is not admissible, ends
//!      `failed unreachable` once the claim's (or the status's) tenure ended and stayed ended for
//!      `lost_grace_ms`: a claimed run is never ended as unstarted, because it may be running; a
//!      fence report from a newer tenure ends a running run `failed fenced`.
//!
//! A terminal status is written once. A report that arrives for a job that ended within
//! `job_finished_age_ms_min` is dropped with a `drop_report` decision carrying ZC-W0307.
//!
//! Reads: the nodes, their statuses and the assignments are read once a step; the jobs are read
//! `job_controller_page_max` at a time, each page with its runs, statuses and reports in an arena
//! of its own that is reset before the next page (`constants.job_controller_page_bytes_max`),
//! because `/jobs/` also holds the ended jobs of the retention window. A step that runs out of
//! transactions keeps its place (`cursor`) and the next carries on; one that resumed and reached
//! the end asks for one more full sweep. A report is looked for under the node the run is
//! assigned to: a job's run is never reassigned.
//!
//! Every hold and every dropped report is recorded once per record revision and found again in
//! the job's decisions (`has_decision`), so a restart records nothing twice and nothing bounds
//! how many jobs may hold at once. Core: no thread, no clock but the context's, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const c1_teeth = @import("c1_teeth.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const evidence = @import("evidence.zig");
const failures = @import("store_failures.zig");
const job_retention = @import("job_retention.zig");
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
/// Runs whose node's tenure ended without a `lost` judgement of its own, with the time the
/// controller first saw it end: one slot for each run that can be live.
const seen_max = constants.jobs_max;
const hold_action = "hold_contradictory_job";
const none: u32 = std.math.maxInt(u32);
/// Pages of jobs one step can read: the whole retention window, and a page for the end.
const pages_max = constants.job_admitted_window_max / constants.job_controller_page_max + 2;

comptime {
    assert(seen_max >= constants.jobs_max);
    assert(pages_max * constants.job_controller_page_max >= constants.job_admitted_window_max);
}

const Map = std.StringHashMapUnmanaged(u32);

/// A run (by hash) whose tenure (by hash) the controller saw end at `at_ms`.
const Seen = struct { run: u64, tenure: u64, at_ms: u64 };

pub const JobController = struct {
    source: controller.DecisionSource,
    /// How long after a run's tenure ended it is failed `unreachable`. A parameter, as the replica
    /// controller's.
    lost_grace_ms: u64 = constants.lost_grace_ms,
    /// The last job a step that ran out of transactions finished with; the next one starts after
    /// it. Null: from the first job.
    cursor: ?records.Key = null,
    seen: [seen_max]Seen = @splat(.{ .run = 0, .tenure = 0, .at_ms = 0 }),
    seen_next: u32 = 0,
    /// The retention of ended jobs (job_retention.zig): the job controller is the role that
    /// reads the jobs' window anyway, and a failed pass never fails its step.
    retention: job_retention.Cursor = .{},

    /// Decision ids of the controllers are `instance*4 + role`, under 0x8000 for the instances a
    /// shell hands out (`constants.controller_instance_max`); this one takes the top half.
    pub fn init(instance: u16) JobController {
        assert(instance <= constants.controller_instance_max);
        return .{ .source = .{ .instance = 0x8000 | instance } };
    }

    pub fn reconcile(jc: *JobController, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const shared = try read_shared(ctx);
        var pass: Pass = .{
            .jc = jc,
            .ctx = ctx,
            .world = undefined,
            .txns_left = constants.controller_txns_per_step_max,
            .wake_at_ms = now + resync_ms,
        };
        const resumed = jc.cursor != null;
        var after: ?records.Key = jc.cursor;
        var arena_state = std.heap.ArenaAllocator.init(ctx.arena);
        defer arena_state.deinit();
        var finished = false;
        // Test-only (`c1_teeth.job_evicted`): a sweep stops after `jobs_max` jobs and restarts.
        const sweep_pages = if (c1_teeth.job_evicted)
            constants.jobs_max / constants.job_controller_page_max
        else
            pages_max;
        for (0..sweep_pages) |_| {
            _ = arena_state.reset(.retain_capacity);
            const page_ctx: Context = .{
                .store = ctx.store,
                .clock = ctx.clock,
                .arena = arena_state.allocator(),
                .diag = ctx.diag,
            };
            const after_key: ?[]const u8 = if (after) |*key| key.slice() else null;
            const page = try read_page(&page_ctx, &shared, after_key);
            pass.ctx = &page_ctx;
            pass.world = &page.world;
            for (page.unreadable) |*entry| {
                if (pass.stopped or pass.txns_left == 0) break;
                try pass.hold_unreadable(entry);
            }
            for (page.world.jobs) |*job| {
                if (pass.stopped or pass.txns_left == 0) break;
                try pass.step_job(job);
                if (!pass.stopped) after = key_of(job.kv.key);
            }
            if (pass.stopped or pass.txns_left == 0) break;
            if (page.last) |last| after = key_of(last);
            if (!page.more) {
                finished = true;
                break;
            }
        }
        if (c1_teeth.job_evicted and !pass.stopped and pass.txns_left > 0) finished = true;
        jc.cursor = if (finished) null else after;
        if (now >= jc.retention.due_ms) {
            jc.retention.due_ms = job_retention.prune_or_back_off(ctx, &jc.retention, now);
        }
        pass.wake_at_ms = @min(pass.wake_at_ms, @max(jc.retention.due_ms, now));
        // A sweep that began in the middle has not judged the jobs before its start.
        const again = pass.more or pass.txns_left == 0 or !finished or resumed;
        return .{
            .at_ms = if (again) now else pass.wake_at_ms,
            .prefixes = &watch_prefixes,
            .acted = pass.acted,
        };
    }

    /// When the controller first saw the tenure `tenure` of run `run` ended: now, the first
    /// time. A run holds one slot, whatever its tenures; the oldest slot goes when none is free.
    fn first_seen(jc: *JobController, run: u64, tenure: u64, now: u64) u64 {
        var free: ?u32 = null;
        for (&jc.seen, 0..) |*one, at| {
            if (one.run == run) {
                if (one.tenure == tenure) return one.at_ms;
                one.* = .{ .run = run, .tenure = tenure, .at_ms = now };
                return now;
            }
            if (one.run == 0 and free == null) free = @intCast(at);
        }
        const at = free orelse jc.seen_next % seen_max;
        jc.seen[at] = .{ .run = run, .tenure = tenure, .at_ms = now };
        if (free == null) jc.seen_next +%= 1;
        return now;
    }

    /// The run ended: its slot is free for another.
    fn forget_run(jc: *JobController, run: u64) void {
        for (&jc.seen) |*one| {
            if (one.run == run) one.* = .{ .run = 0, .tenure = 0, .at_ms = 0 };
        }
    }
};

fn key_of(bytes: []const u8) records.Key {
    var key: records.Key = .{};
    @memcpy(key.bytes[0..bytes.len], bytes);
    key.len = @intCast(bytes.len);
    return key;
}

fn hash_of(parts: []const []const u8, number: u64) u64 {
    var hasher = std.hash.Wyhash.init(number);
    for (parts) |part| hasher.update(part);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

// ---- The world a pass reads ------------------------------------------------------------------

/// What every page shares, read once a step at one revision.
const Shared = struct {
    revision: Revision,
    nodes: []const Entry(records.Node),
    node_statuses: []const Entry(records.NodeStatus),
    assigned: []const Entry(records.Assigned),
    assigned_of: Map,
};

/// One page of jobs with the records they need, read at the step's revision.
const World = struct {
    revision: Revision,
    jobs: []const Entry(records.Job),
    runs: []const Entry(records.JobRun),
    statuses: []const Entry(records.JobStatus),
    nodes: []const Entry(records.Node),
    node_statuses: []const Entry(records.NodeStatus),
    assigned: []const Entry(records.Assigned),
    run_of: Map,
    status_of: Map,
    assigned_of: Map,

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
};

const Page = struct {
    world: World,
    more: bool,
    /// The last job key the page listed, readable or not: the next page starts after it.
    last: ?[]const u8,
    /// Jobs left out of the page because one of their records does not decode (ZC-E0301/E0303).
    unreadable: []const Unreadable,
};

/// A job the pass cannot read: it is held with one decision and left as it is, and the jobs after
/// it are judged as usual.
const Unreadable = struct { job: Entry(records.Job), diagnostic: records.Raw };

/// The node an assignment key `/assigned/<node>/<run>` names.
fn assigned_node(key: []const u8) []const u8 {
    const rest = key[records.prefix_assigned.len..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

fn rows(
    comptime T: type,
    ctx: *const Context,
    prefix: []const u8,
    at: ?Revision,
    count_max: u32,
) Error!controller.List(T) {
    return controller.list_all(T, ctx, prefix, at, count_max);
}

fn read_shared(ctx: *const Context) Error!Shared {
    const nodes = try rows(records.Node, ctx, records.prefix_nodes, null, constants.nodes_max);
    const at = nodes.revision;
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
    var shared: Shared = .{
        .revision = at,
        .nodes = nodes.items,
        .node_statuses = node_statuses.items,
        .assigned = assigned.items,
        .assigned_of = .empty,
    };
    for (shared.assigned, 0..) |entry, index| {
        if (entry.rec.job == null) continue;
        shared.assigned_of.put(ctx.arena, entry.rec.replica, @intCast(index)) catch
            return failures.no_memory(ctx.diag);
    }
    return shared;
}

/// The next page of jobs after the key `after`, with the runs and statuses of exactly those jobs.
fn read_page(ctx: *const Context, shared: *const Shared, after: ?[]const u8) Error!Page {
    const listed = try ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_jobs,
        .at_revision = shared.revision,
        .limit = constants.job_controller_page_max,
        .continue_after = after,
    }, ctx.diag);
    var unreadable: std.ArrayList(Unreadable) = .empty;
    var readable: std.ArrayList(Entry(records.Job)) = .empty;
    for (listed.kvs) |kv| {
        const rec = records.read(records.Job, ctx.arena, kv, ctx.diag) catch |err| {
            if (err != error.Malformed) return err;
            try note_unreadable(ctx, &unreadable, .{ .kv = kv, .rec = undefined });
            continue;
        };
        readable.append(ctx.arena, .{ .kv = kv, .rec = rec }) catch
            return failures.no_memory(ctx.diag);
    }
    const jobs: []const Entry(records.Job) = readable.items;
    var world: World = .{
        .revision = shared.revision,
        .jobs = jobs,
        .runs = &.{},
        .statuses = &.{},
        .nodes = shared.nodes,
        .node_statuses = shared.node_statuses,
        .assigned = shared.assigned,
        .run_of = .empty,
        .status_of = .empty,
        .assigned_of = shared.assigned_of,
    };
    if (jobs.len > 0) try read_records_of(ctx, shared, &world, &unreadable);
    return .{
        .world = world,
        .more = listed.continue_after != null,
        .last = if (listed.kvs.len > 0) listed.kvs[listed.kvs.len - 1].key else null,
        .unreadable = unreadable.items,
    };
}

/// Reads the runs and statuses of `world.jobs` into `world`; a job one of whose records does not
/// decode is noted in `unreadable` and left out of `world` altogether.
fn read_records_of(
    ctx: *const Context,
    shared: *const Shared,
    world: *World,
    unreadable: *std.ArrayList(Unreadable),
) Error!void {
    const jobs = world.jobs;
    var dropped: std.StringHashMapUnmanaged(void) = .empty;
    const read_runs = try read_each(records.JobRun, ctx, records.job_run_key, jobs, shared, .{
        .unreadable = unreadable,
        .dropped = &dropped,
    });
    const read_statuses = try read_each(
        records.JobStatus,
        ctx,
        records.job_status_key,
        jobs,
        shared,
        .{ .unreadable = unreadable, .dropped = &dropped },
    );
    if (dropped.count() > 0) {
        world.jobs = try without(Entry(records.Job), ctx, jobs, records.prefix_jobs, &dropped);
    }
    world.runs = try without(
        Entry(records.JobRun),
        ctx,
        read_runs,
        records.prefix_job_runs,
        &dropped,
    );
    world.statuses = try without(
        Entry(records.JobStatus),
        ctx,
        read_statuses,
        records.prefix_job_status,
        &dropped,
    );
    for (world.runs, 0..) |entry, at| {
        const name = entry.kv.key[records.prefix_job_runs.len..];
        world.run_of.put(ctx.arena, name, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
    for (world.statuses, 0..) |entry, at| {
        const name = entry.kv.key[records.prefix_job_status.len..];
        world.status_of.put(ctx.arena, name, @intCast(at)) catch
            return failures.no_memory(ctx.diag);
    }
}

/// Records `job` as unreadable with the diagnostic the failed read left in `ctx.diag`, which is
/// cleared: a record that does not decode must not stop the jobs after it.
fn note_unreadable(
    ctx: *const Context,
    list: *std.ArrayList(Unreadable),
    job: Entry(records.Job),
) Error!void {
    const raw = try diagnostic_of(ctx);
    ctx.diag.reset();
    list.append(ctx.arena, .{ .job = job, .diagnostic = raw }) catch
        return failures.no_memory(ctx.diag);
}

/// `items` without those whose key (after `prefix`) names a job in `dropped`.
fn without(
    comptime T: type,
    ctx: *const Context,
    items: []const T,
    prefix: []const u8,
    dropped: *const std.StringHashMapUnmanaged(void),
) Error![]const T {
    if (dropped.count() == 0) return items;
    var kept: std.ArrayList(T) = .empty;
    for (items) |item| {
        if (dropped.contains(item.kv.key[prefix.len..])) continue;
        kept.append(ctx.arena, item) catch return failures.no_memory(ctx.diag);
    }
    return kept.items;
}

/// Where `read_each` puts a job whose record does not decode.
const Unreadables = struct {
    unreadable: *std.ArrayList(Unreadable),
    dropped: *std.StringHashMapUnmanaged(void),
};

/// The record, at the key `key_of_job` names, of each of `jobs` (a page: at most
/// `job_controller_page_max`), read by key at the step's revision, ascending. A job with none has
/// no entry. Records of no job on
/// the page (orphans: a restore, a hand edit) are never listed, so they cost nothing however many
/// there are.
fn read_each(
    comptime T: type,
    ctx: *const Context,
    comptime key_of_job: fn ([]const u8) records.Key,
    jobs: []const Entry(records.Job),
    shared: *const Shared,
    bad: Unreadables,
) Error![]const Entry(T) {
    var items: std.ArrayList(Entry(T)) = .empty;
    for (jobs) |job| {
        const name = job.kv.key[records.prefix_jobs.len..];
        const key = key_of_job(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), shared.revision, ctx.diag);
        const kv = got.kv orelse continue;
        const rec = records.read(T, ctx.arena, kv, ctx.diag) catch |err| {
            if (err != error.Malformed) return err;
            if (bad.dropped.contains(name)) {
                ctx.diag.reset();
                continue;
            }
            try note_unreadable(ctx, bad.unreadable, job);
            bad.dropped.put(ctx.arena, name, {}) catch return failures.no_memory(ctx.diag);
            continue;
        };
        items.append(ctx.arena, .{ .kv = kv, .rec = rec }) catch
            return failures.no_memory(ctx.diag);
    }
    return items.items;
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

    /// True when the pass may commit again. A step that commits twice (a hold, then the stop
    /// or the ending the job is due: `claim`'s unreadable report, `unmappable`, the `job_rewrite`
    /// tooth) asks before its second commit. With nothing left, or after a conflict, the pass
    /// stops at the job, so the cursor stays before it and the next step, run at once, judges it
    /// again; the hold is not repeated there (`has_decision`), so that step commits once.
    fn may_commit(pass: *Pass) bool {
        if (pass.stopped) return false;
        if (pass.txns_left > 0) return true;
        pass.stopped = true;
        pass.more = true;
        return false;
    }

    fn landed(pass: *Pass, done: controller.Commit) ?Revision {
        switch (done) {
            .applied => |revision| {
                assert(pass.txns_left > 0); // Every commit is within the step's budget.
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
        if (records.job_state_terminal(status.?.rec.state)) {
            if (c1_teeth.job_rewrite) {
                try pass.rewrite(status.?);
                if (!pass.may_commit()) return;
            }
            return pass.late_report(job, status.?);
        }
        try pass.advance(job, run.?, status.?);
    }

    // ---- Step 1: the run and its status ----

    fn create(pass: *Pass, job: *const Entry(records.Job)) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        if (try has_decision(ctx, name, "job_created", job.kv.create_revision)) {
            return pass.contradict(job, null, null);
        }
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
            .relay = spec.relay,
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
            .action = "job_created",
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
        if (try has_decision(ctx, name, hold_action, job.kv.mod_revision)) return;
        const what = if (run == null and status == null)
            "has a job_created decision but neither a run nor a status"
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
            .action = hold_action,
            .subject = .{ .kind = .job, .name = name },
            .reason = "the job's records contradict each other; nothing about it changes",
            .cause = .{ .kind = .desired, .key = job.kv.key, .revision = job.kv.mod_revision },
            .cause_diagnostic = raw,
            .read_revision = pass.world.revision,
        }, &batch);
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), job.kv.mod_revision);
        // A job with no run never started and never will (a new run is never made, I8a), so it
        // takes no `jobs_max` slot: the hold counts it as ended, once per incarnation of the job
        // (an earlier hold of this incarnation, for another revision of the record, did). A job
        // that has a run might be placed, so it keeps its slot (#177), and so does one whose status
        // says `placed` or `running`: only a missing or `pending` status means it never started.
        const never_started = run == null and
            (status == null or status.?.rec.state == .pending);
        if (never_started and !try has_decision(ctx, name, hold_action, job.kv.create_revision)) {
            const counted = try pass.endings(&batch);
            batch.put(records.key_job_endings, try records.encode(ctx.arena, counted, ctx.diag));
        }
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    // ---- Steps 2 to 5: a live run ----

    fn advance(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
    ) Error!void {
        var live: ?*const Entry(records.JobObserved) = null;
        var fence: ?*const Entry(records.JobObserved) = null;
        const claim_seen: ?*const Entry(records.JobObserved) = switch (try pass.claim(job, run)) {
            .unreadable => {
                if (!pass.may_commit()) return;
                return pass.judge_unreadable(job, run, status);
            },
            .none => null,
            .seen => |entry| entry,
        };
        if (claim_seen) |entry| {
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
        try pass.judge_unclaimed(job, run, status, claim_seen);
    }

    /// What the node the run is assigned to reported of it, if anything.
    const Claim = union(enum) {
        none,
        /// The report does not decode (ZC-E0301/E0303): one decision says so, and the caller
        /// judges the run without it (`judge_unreadable`): the report cannot move the run, but it
        /// cannot hold back a cancel or a lost node either.
        unreadable,
        seen: *const Entry(records.JobObserved),
    };

    fn claim(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
    ) Error!Claim {
        const ctx = pass.ctx;
        const placed = pass.world.assignment(run.rec.id) orelse return .none;
        const key = records.job_observed_key(assigned_node(placed.kv.key), job.rec.name);
        const got = try ctx.store.get(ctx.arena, key.slice(), pass.world.revision, ctx.diag);
        const kv = got.kv orelse return .none;
        const rec = records.read(records.JobObserved, ctx.arena, kv, ctx.diag) catch |err| {
            if (err != error.Malformed) return err;
            try pass.hold_unreadable_report(job, &kv);
            return .unreadable;
        };
        if (!std.mem.eql(u8, rec.run, run.rec.id)) return .none;
        const entry = ctx.arena.create(Entry(records.JobObserved)) catch
            return failures.no_memory(ctx.diag);
        entry.* = .{ .kv = kv, .rec = rec };
        return .{ .seen = entry };
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
    /// it. True when it acted. An unmappable ending is held with a decision; with no stop yet it
    /// returns false, so the pass goes on to write the cancel's stop, and once a stop exists the
    /// run ends `failed unknown`: the job is not pinned.
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
                if (!pass.may_commit()) return true;
                // Once a stop exists the report is the last the agent sends, so the run ends
                // here, failed with an unknown cause, or it would never end (RB-S8).
                const stop = run.rec.stop orelse return false;
                try pass.end(job, run, status, .{
                    .ending = failed(.unknown, stop_cause_of(stop.cause)),
                    .reason = "the run was stopped and its agent's report maps to no ending",
                    .report = entry,
                });
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

    fn stop_cause_of(cause: records.RunStopCause) records.StopCause {
        return switch (cause) {
            .cancel => .cancel,
            .@"unreachable" => .@"unreachable",
            .not_started => .not_started,
        };
    }

    /// Compares what a judgement about `run` read of its placement (the read-set rule): the
    /// assignment, the node's record and its judgement, and, unless `report_compared`, the node's
    /// report of the run (absent: revision 0). A run with no assignment has nothing to compare.
    fn expect_placement(
        pass: *Pass,
        batch: *Batch,
        name: []const u8,
        run: *const Entry(records.JobRun),
        report_compared: bool,
    ) Error!void {
        const ctx = pass.ctx;
        const world = pass.world;
        const placed = world.assignment(run.rec.id) orelse return;
        const node = assigned_node(placed.kv.key);
        batch.expect(placed.kv.key, placed.kv.mod_revision);
        const node_at = if (world.node_entry(node)) |entry| entry.kv.mod_revision else 0;
        try expect_key(ctx, batch, &records.node_key(node), node_at);
        const judged_at = if (world.node_status(node)) |entry| entry.kv.mod_revision else 0;
        try expect_key(ctx, batch, &records.node_status_key(node), judged_at);
        if (report_compared) return;
        const key = records.job_observed_key(node, name);
        const got = try ctx.store.get(ctx.arena, key.slice(), world.revision, ctx.diag);
        const seen_at = if (got.kv) |kv| kv.mod_revision else 0;
        try expect_key(ctx, batch, &key, seen_at);
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
        try pass.expect_placement(&batch, job.rec.name, run, true);
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "job_running",
            .subject = .{ .kind = .job, .name = job.rec.name },
            .reason = "the run was claimed by its node",
            .cause = .{ .kind = .observed, .key = entry.kv.key, .revision = entry.kv.mod_revision },
            .cause_evidence = try evidence.job_observed(ctx, &entry.rec),
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
        if (run.rec.stop == null and job.rec.cancel_requested != null) {
            return pass.write_stop(job, run, status, .cancel);
        }
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
        const run_hash = hash_of(&.{run_id}, 0);
        return pass.jc.first_seen(run_hash, hash_of(&.{node}, tenure), pass.ctx.clock.now_ms());
    }

    fn past_grace(pass: *Pass, since: u64) bool {
        const due = since +| pass.jc.lost_grace_ms;
        if (pass.ctx.clock.now_ms() >= due) return true;
        pass.wake_at_ms = @min(pass.wake_at_ms, due);
        return false;
    }

    /// A run no admissible report claims: stop it when it must not start, end it once it has a
    /// stop and nothing claimed it, and show a placement in the status. A run whose node did
    /// claim it, with a report that is not admissible, may be running: it is never ended as
    /// unstarted (`judge_claimed`).
    fn judge_unclaimed(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        claim_seen: ?*const Entry(records.JobObserved),
    ) Error!void {
        if (claim_seen) |entry| return pass.judge_claimed(job, run, status, entry);
        if (run.rec.stop) |stop| return pass.end_unstarted(job, run, status, stop);
        if (try pass.stop_cause(job, run)) |cause| return pass.write_stop(job, run, status, cause);
        const placed = pass.world.assignment(run.rec.id) orelse return;
        if (status.rec.state != .pending) return;
        try pass.mark_placed(job, run, status, placed);
    }

    /// A claim that is not admissible (its tenure is not the node's now, the node is not ready,
    /// or it is for another assignment) on a run not yet running: a cancel is still written, so
    /// the agent that may hold the run stops it; the run ends `failed unreachable` when the
    /// claim's tenure has been over for the grace, as a running run does, and never before.
    fn judge_claimed(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
        claimed: *const Entry(records.JobObserved),
    ) Error!void {
        if (run.rec.stop == null and job.rec.cancel_requested != null) {
            return pass.write_stop(job, run, status, .cancel);
        }
        const since = pass.tenure_ended_at(claimed.rec.node, claimed.rec.tenure, run.rec.id) orelse
            return;
        if (!pass.past_grace(since)) return;
        try pass.end(job, run, status, .{
            .ending = failed(.@"unreachable", .@"unreachable"),
            .reason = "the node of the run was lost and did not come back within the grace",
            .report = null,
            .node = claimed.rec.node,
        });
    }

    fn stop_cause(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
    ) Error!?records.RunStopCause {
        if (job.rec.cancel_requested != null) return .cancel;
        const now = pass.ctx.clock.now_ms();
        // Test-only (`c1_teeth.job_unclaimed`): a run nobody claimed is never ended (J8).
        if (!c1_teeth.job_unclaimed and now > run.rec.start_by_ms) return .not_started;
        const placed = pass.world.assignment(run.rec.id) orelse {
            pass.wake_at_ms = @min(pass.wake_at_ms, run.rec.start_by_ms +| 1);
            return null;
        };
        if (!pass.node_lost(assigned_node(placed.kv.key))) return null;
        return .@"unreachable";
    }

    /// The node's judgement is `lost` for the tenure it still holds, and the grace is over.
    fn node_lost(pass: *Pass, node: []const u8) bool {
        const judged = pass.world.node_status(node) orelse return false;
        if (judged.rec.state != .lost) return false;
        if (pass.world.node_entry(node)) |entry| {
            if (entry.kv.mod_revision > judged.rec.tenure) return false;
        }
        return pass.past_grace(judged.rec.at_ms);
    }

    /// The node's report of the run does not decode, so what it claims is not known. Nothing it
    /// says moves the run, but the run does not wait on it: a running run is judged as ever; a
    /// cancel, or a node lost past the grace, writes the stop; and once a stop exists and the node
    /// is lost the run ends `failed unknown`, as a stopped report that maps to no ending does
    /// (RB-S8): it may have started, and nothing readable says how it went. While the node is
    /// alive the run waits for its next report, which replaces the unreadable one.
    fn judge_unreadable(
        pass: *Pass,
        job: *const Entry(records.Job),
        run: *const Entry(records.JobRun),
        status: *const Entry(records.JobStatus),
    ) Error!void {
        if (status.rec.state == .running) return pass.judge_running(job, run, status);
        const placed = pass.world.assignment(run.rec.id) orelse return;
        const node = assigned_node(placed.kv.key);
        const stop = run.rec.stop orelse {
            if (job.rec.cancel_requested != null) {
                return pass.write_stop(job, run, status, .cancel);
            }
            if (pass.node_lost(node)) return pass.write_stop(job, run, status, .@"unreachable");
            return;
        };
        if (!pass.node_lost(node)) return;
        try pass.end(job, run, status, .{
            .ending = failed(.unknown, stop_cause_of(stop.cause)),
            .reason = "the node was lost and its report of the run does not decode",
            .report = null,
            .node = node,
        });
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
        try pass.expect_placement(&batch, name, run, false);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "stop_job",
            .subject = .{ .kind = .job, .name = name },
            .reason = switch (cause) {
                .cancel => "the job was cancelled; its run is to stop",
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
            .action = "job_placed",
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
        /// The node to show when there is no report (the status of a claimed run has none yet).
        node: ?[]const u8 = null,
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
        const counted = try pass.endings(&batch);
        var cause: records.Cause = .{
            .kind = .desired,
            .key = run.kv.key,
            .revision = run.kv.mod_revision,
        };
        if (done.report) |report| {
            batch.expect(report.kv.key, report.kv.mod_revision);
            cause = cause_of(.observed, &report.kv);
        }
        try pass.expect_placement(&batch, name, run, done.report != null);
        const decided = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "end_job",
            .subject = .{ .kind = .job, .name = name },
            .reason = done.reason,
            .cause = cause,
            .cause_evidence = if (done.report) |report|
                try evidence.job_observed(ctx, &report.rec)
            else
                null,
            .read_revision = pass.world.revision,
        }, &batch);
        var next = status.rec;
        next.state = done.ending.state;
        next.end = done.ending.end;
        next.stop_cause = done.ending.stop_cause;
        next.ended_at_ms = now;
        next.decision = decided.slice();
        next.reported_at_ms = now;
        if (done.node) |node| next.node = node;
        if (done.report) |report| {
            next.node = report.rec.node;
            next.diagnostic = report.rec.diagnostic;
            next.started_at_ms = report.rec.started_at_ms orelse next.started_at_ms;
        }
        assert(next.valid());
        batch.put(status_at, try records.encode(ctx.arena, next, ctx.diag));
        batch.put(records.key_job_endings, try records.encode(ctx.arena, counted, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
        pass.jc.forget_run(hash_of(&.{run.rec.id}, 0));
    }

    /// The count of endings with this one in it, read now (not with the page: another job's
    /// ending in this step has moved it), and the compare that makes the count exact.
    fn endings(pass: *Pass, batch: *Batch) Error!records.JobEndings {
        const ctx = pass.ctx;
        const got = try ctx.store.get(ctx.arena, records.key_job_endings, null, ctx.diag);
        var ended: u64 = 0;
        var revision: Revision = 0;
        if (got.kv) |kv| {
            revision = kv.mod_revision;
            ended = (try records.read(records.JobEndings, ctx.arena, kv, ctx.diag)).ended;
        }
        batch.expect(records.key_job_endings, revision);
        return .{ .ended = ended + 1 };
    }

    /// ZC-B0004: a report that maps to no ending. The job is left as it was; one decision says so.
    fn unmappable(
        pass: *Pass,
        job: *const Entry(records.Job),
        entry: *const Entry(records.JobObserved),
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        if (try has_decision(ctx, name, "hold_unmapped_ending", entry.kv.mod_revision)) return;
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
            .action = "hold_unmapped_ending",
            .subject = .{ .kind = .job, .name = name },
            .reason = "the agent's report maps to no ending; the job is left as it was",
            .cause = .{ .kind = .observed, .key = entry.kv.key, .revision = entry.kv.mod_revision },
            .cause_diagnostic = raw,
            .cause_evidence = try evidence.job_observed(ctx, &entry.rec),
            .read_revision = pass.world.revision,
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// ZC-E0301/ZC-E0303: a job one of whose records does not decode. One decision says so, once
    /// per revision of the job's record; the job is left as it was and the others go on.
    fn hold_unreadable(pass: *Pass, entry: *const Unreadable) Error!void {
        const ctx = pass.ctx;
        const kv = entry.job.kv;
        const name = kv.key[records.prefix_jobs.len..];
        if (try has_decision(ctx, name, "hold_unreadable_job", kv.mod_revision)) return;
        var batch: Batch = .{};
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), kv.mod_revision);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "hold_unreadable_job",
            .subject = .{ .kind = .job, .name = name },
            .reason = "a record of the job does not decode; the job is left as it was",
            .cause = .{ .kind = .resync },
            .cause_diagnostic = entry.diagnostic,
            .read_revision = pass.world.revision,
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// ZC-E0301/ZC-E0303: the node's report of the job does not decode. One `hold_unreadable_job`
    /// decision says so, once per revision of the report; the job is left as it was.
    fn hold_unreadable_report(
        pass: *Pass,
        job: *const Entry(records.Job),
        report: *const store.KeyValue,
    ) Error!void {
        const ctx = pass.ctx;
        const raw = try diagnostic_of(ctx);
        ctx.diag.reset();
        const name = job.rec.name;
        if (try has_decision(ctx, name, "hold_unreadable_job", report.mod_revision)) return;
        var batch: Batch = .{};
        batch.expect(try controller.key_copy(ctx, &records.job_key(name)), job.kv.mod_revision);
        batch.expect(report.key, report.mod_revision);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "hold_unreadable_job",
            .subject = .{ .kind = .job, .name = name },
            .reason = "its report does not decode; a cancel waits for a good one or a lost node",
            .cause = cause_of(.observed, report),
            .cause_diagnostic = raw,
            .read_revision = pass.world.revision,
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    // ---- A report for an ended job ----

    /// Test-only (`c1_teeth.job_rewrite`, must break J3): a terminal status written again, once,
    /// with a later `ended_at_ms`.
    fn rewrite(pass: *Pass, status: *const Entry(records.JobStatus)) Error!void {
        const ctx = pass.ctx;
        const ended_at = status.rec.ended_at_ms orelse return;
        if (status.rec.reported_at_ms != ended_at) return;
        var next = status.rec;
        next.ended_at_ms = ended_at + 1;
        next.reported_at_ms = ended_at + 1;
        var batch: Batch = .{};
        batch.expect(status.kv.key, status.kv.mod_revision);
        batch.put(status.kv.key, try records.encode(ctx.arena, next, ctx.diag));
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
    }

    /// ZC-W0307: the node reported after the job ended. The ending stays; one decision says so,
    /// once for each revision of the report. Only jobs that ended within `job_finished_age_ms_min`
    /// are looked at: a report later than that finds the job deleted or about to be.
    fn late_report(
        pass: *Pass,
        job: *const Entry(records.Job),
        status: *const Entry(records.JobStatus),
    ) Error!void {
        const ctx = pass.ctx;
        const name = job.rec.name;
        const node = status.rec.node orelse return;
        const ended_at = status.rec.ended_at_ms orelse return;
        if (ctx.clock.now_ms() -| ended_at >= constants.job_finished_age_ms_min) return;
        const key = records.job_observed_key(node, name);
        const got = try ctx.store.get(ctx.arena, key.slice(), pass.world.revision, ctx.diag);
        const kv = got.kv orelse return;
        if (kv.mod_revision < status.kv.mod_revision) return; // The report the ending rests on.
        if (try has_decision(ctx, name, "drop_report", kv.mod_revision)) return;
        const report = records.read(records.JobObserved, ctx.arena, kv, ctx.diag) catch |err| {
            if (err != error.Malformed) return err;
            return pass.hold_unreadable_report(job, &kv);
        };
        const how = if (status.rec.end) |ended| if (ended.cause) |c| @tagName(c) else "-" else "-";
        const cause = try controller.format(
            ctx,
            "{s} reported {s} after the job ended as {s} ({s})",
            .{ report.node, report.run, @tagName(status.rec.state), how },
        );
        const raw = try diagnostic_text(
            ctx,
            .W0307,
            cause,
            "nothing: the ending stands; `zcube why job` shows both",
        );
        var batch: Batch = .{};
        batch.expect(kv.key, kv.mod_revision);
        try expect_key(ctx, &batch, &records.job_status_key(name), status.kv.mod_revision);
        _ = try controller.put_decision(ctx, &pass.jc.source, .{
            .actor = actor,
            .action = "drop_report",
            .subject = .{ .kind = .job, .name = name },
            .reason = "the job had ended; the report was not applied",
            .cause = .{ .kind = .observed, .key = kv.key, .revision = kv.mod_revision },
            .cause_diagnostic = raw,
            .cause_evidence = try evidence.job_observed(ctx, &report),
            .read_revision = pass.world.revision,
        }, &batch);
        _ = pass.landed(try controller.commit(ctx, .job_controller, &batch)) orelse return;
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

/// True when `/decisions-by-subject/job/<name>` holds a decision of `action` whose index entry
/// was created at `min_revision` or later: of this incarnation of the job (the job's
/// `create_revision`) or since this revision of a record (its `mod_revision`).
fn has_decision(
    ctx: *const Context,
    name: []const u8,
    action: []const u8,
    min_revision: Revision,
) Error!bool {
    const prefix = records.index_prefix(.job, name);
    var after: ?[]const u8 = null;
    var at: ?Revision = null;
    for (0..constants.decisions_per_subject_max / constants.store_list_limit_max + 2) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = constants.store_list_limit_max,
            .continue_after = after,
            .at_revision = at,
        }, ctx.diag);
        at = page.revision;
        for (page.kvs) |kv| {
            if (kv.create_revision < min_revision) continue;
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
            if (std.mem.eql(u8, entry.action, action)) return true;
        }
        after = page.continue_after orelse return false;
    }
    // The index is longer than the budget reads: whether this was decided is unknown. Treat it as
    // decided (I8a fails closed: no second run, no second hold) rather than fail the step, which
    // would stop every controller after this one on each pass.
    return true;
}

/// The diagnostic `ctx.diag` holds, as the text a decision carries.
fn diagnostic_of(ctx: *const Context) Error!records.Raw {
    const diagnostic = ctx.arena.create(zigbox.diagnostic.Diagnostic) catch
        return failures.no_memory(ctx.diag);
    diag_mod.to_diagnostic(diagnostic, ctx.diag);
    diagnostic.docs = .{};
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    zigbox.diagnostic.write_json(&text.writer, diagnostic) catch
        return failures.no_memory(ctx.diag);
    const written = text.written();
    assert(written.len > 1);
    return .{ .text = written[0 .. written.len - 1] };
}

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
