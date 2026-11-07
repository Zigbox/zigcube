//! The agent's runs: jobs the scheduler assigned to this node (docs/briefs/b1.md, "How the agent
//! runs a job to completion"; docs/agent.md, "Runs"). Core code: no files, clocks or sockets of
//! its own, only the `Context`.
//!
//! A run is a replica with these differences. It is **claimed, then started, once**: the agent
//! writes a start record in its state directory (`jobs/<run id>.json`), commits a `claimed`
//! observation that rests on its tenure, the run as it read it, the assignment (the *epoch*) and
//! on there being no observation of the run yet, then fetches the input, then starts the
//! container. Nothing restarts it: an exited container is reported once and left. The start
//! record says, after any crash, whether the agent may have started the run; the store says
//! whether anyone has claimed it. A run found claimed is never claimed or started again.
//!
//! The deadline is kept in the start record as a time on the monotonic clock with the boot id it
//! is on; it is written *before* the container starts, so a crash between the two leaves a
//! deadline no later than the real one. The stop a fence or the server asks for is recorded as
//! `stop_cause` in the start record before the container is signalled, so the report that goes
//! out after a restart or a new tenure names it.

const std = @import("std");
const assert = std.debug.assert;
const agent_mod = @import("agent.zig");
const agent_state = @import("agent_state.zig");
const compare_sets = @import("compare_sets.zig");
const constants = @import("constants.zig");
const c1_teeth = @import("c1_teeth.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");

const Agent = agent_mod.Agent;
const Context = agent_mod.Context;
const Error = agent_mod.Error;
const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Entry = controller.Entry;

pub const dir = "jobs/";
const suffix = ".json";

pub const Phase = enum { claiming, claimed };

/// What the agent keeps of a run it may have started. Never removed while the run is assigned.
pub const StartRecord = struct {
    v: u32 = 1,
    run: []const u8,
    /// The `/assigned/<node>/<run>` revision it was claimed under.
    epoch: u64,
    phase: Phase,
    boot_id: []const u8 = "",
    /// When the run started, on the wall clock (what the report says).
    started_at_ms: ?u64 = null,
    /// When the run's deadline falls, on the monotonic clock of `boot_id`.
    deadline_mono_ms: ?u64 = null,
    stop_cause: ?records.StopCause = null,
    /// The run's grace period, kept so a stop made without the run's record (it is no longer
    /// served) still gives the process the time the job asked for.
    grace_ms: u32 = 0,
};

/// The record's name in the state directory.
pub fn record_name(buffer: *[agent_state.name_bytes_max]u8, run: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ dir, run, suffix }) catch
        unreachable; // `dir`, a run id and `suffix` fit `name_bytes_max`: asserted below.
}

comptime {
    const longest = dir.len + constants.job_run_id_bytes_max + suffix.len;
    assert(longest <= agent_state.name_bytes_max);
    assert(constants.agent_node_runs_max * 2 <= agent_state.files_max);
}

const Found = union(enum) { absent, damaged, record: StartRecord };

fn read_record(ctx: *const Context, state: agent_state.AgentState, run: []const u8) Error!Found {
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    const bytes = state.read(ctx.arena, record_name(&buffer, run)) catch |err| switch (err) {
        error.Absent => return .absent,
        error.Io, error.TooBig => return .damaged,
        else => |other| return state_failed(ctx, other, "read a run's start record"),
    };
    if (bytes.len == 0) return .absent;
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(StartRecord, ctx.arena, bytes, options) catch
        return .damaged;
    if (!std.mem.eql(u8, parsed.run, run)) return .damaged;
    return .{ .record = parsed };
}

fn write_record(
    ctx: *const Context,
    state: agent_state.AgentState,
    record: *const StartRecord,
) Error!void {
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const bytes = std.json.Stringify.valueAlloc(ctx.arena, record.*, options) catch
        return failures.no_memory(ctx.diag);
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    state.put_atomic(record_name(&buffer, record.run), bytes) catch |err|
        return state_failed(ctx, err, "write a run's start record");
}

fn remove_record(ctx: *const Context, state: agent_state.AgentState, run: []const u8) Error!void {
    var buffer: [agent_state.name_bytes_max]u8 = undefined;
    state.remove(record_name(&buffer, run)) catch |err| switch (err) {
        error.Absent => {},
        else => return state_failed(ctx, err, "remove a run's start record"),
    };
}

fn state_failed(ctx: *const Context, err: agent_state.Error, what: []const u8) Error {
    const mapped: agent_state.Error = if (err == error.Crashed) error.Io else err;
    return @import("agent_records.zig").state_failed(ctx.diag, mapped, what);
}

/// A run to look at: an assignment of this node, or a container or start record left of one.
const Subject = struct {
    id: []const u8,
    name: []const u8,
    epoch: u64,
    assigned: bool,
};

/// Records the fence as the cause of a running run container's stop, before it is signalled
/// (`Agent.fence_step`). A cause already recorded stands. Needs no server.
pub fn note_fence(ctx: *const Context, listing: *const runtime.Listing) Error!void {
    const state = ctx.state orelse return;
    const id = label_of(listing, runtime.label_replica) orelse return;
    if (label_of(listing, runtime.label_job) == null) return;
    switch (try read_record(ctx, state, id)) {
        .absent, .damaged => {},
        .record => |found| {
            if (found.stop_cause != null) return;
            var changed = found;
            changed.stop_cause = .fence;
            try write_record(ctx, state, &changed);
        },
    }
}

fn label_of(listing: *const runtime.Listing, key: []const u8) ?[]const u8 {
    for (listing.labels) |label| {
        if (std.mem.eql(u8, label.key, key)) return label.value;
    }
    return null;
}

/// Stops each running run container whose deadline has come, from its start record and this
/// node's monotonic clock alone, and kills it once its grace has passed: the deadline needs no
/// server (docs/briefs/b1.md, "The server never decides a running job's deadline"). Runs at the
/// start of every step, before any call, so a server that cannot be reached, a call that hangs or
/// another run whose report keeps failing never holds a stop back; `pass` reports the ending when
/// the server answers. Records `stop_cause: deadline` before the signal, as `pass` does. Sets
/// `deadline_wake_mono_ms` to the next deadline or kill, which caps the step's waits and calls.
/// Never fails: one run's failure (its record, its stop) is noted (`Agent.note_enforce_failure`)
/// and the next run is looked at, so no run's trouble holds back another's stop or the
/// heartbeat that follows (docs/decisions/2026-11-07-agent-enforces-deadline-offline.md).
pub fn enforce_deadlines(
    agent: *Agent,
    ctx: *const Context,
    listings: []const runtime.Listing,
) void {
    agent.deadline_wake_mono_ms = std.math.maxInt(u64);
    if (c1_teeth.job_deadline_offline) return; // Test-only: only the pass enforces it (J8).
    const state = ctx.state orelse return;
    for (listings) |*listing| {
        if (!is_running(listing)) continue;
        if (label_of(listing, runtime.label_job) == null) continue;
        const id = label_of(listing, runtime.label_replica) orelse continue;
        const read = read_record(ctx, state, id) catch {
            agent.note_enforce_failure(ctx, "read a run's start record");
            continue;
        };
        switch (read) {
            // No record to say when: `pass` stops it as `unknown`, with the server's word.
            .absent, .damaged => {},
            .record => |found| enforce_one(agent, ctx, state, listing, found),
        }
    }
}

fn enforce_one(
    agent: *Agent,
    ctx: *const Context,
    state: agent_state.AgentState,
    listing: *const runtime.Listing,
    found: StartRecord,
) void {
    // A `claiming` record's time bounds the input fetch, not the run: its container is the
    // pass's to judge. Another boot's time is not comparable: the run ends through the fence.
    if (found.phase != .claimed) return;
    if (!std.mem.eql(u8, found.boot_id, ctx.boot_id)) return;
    const mono = ctx.mono_ms();
    var record = found;
    if (record.stop_cause == null) {
        const at = record.deadline_mono_ms orelse return;
        const due = at +| c1_teeth.job_deadline_late_ms;
        if (c1_teeth.job_deadline) return;
        if (mono < due) return note_deadline_wake(agent, due);
        record.stop_cause = .deadline;
        // The cause is in `record` for the stop below; if the write fails the stop still goes
        // out, and the next step finds the same deadline passed and writes it again.
        write_record(ctx, state, &record) catch
            agent.note_enforce_failure(ctx, "record a run's deadline");
    }
    // Any recorded cause is a stop under way: send it, or the kill once the grace has passed.
    agent.stop_listing(ctx, listing, record.grace_ms) catch {
        agent.note_enforce_failure(ctx, "stop a run's container");
        return; // The next step tries again (the loop's resync), not a busy retry.
    };
    const pending = agent.pending_stop(listing.handle.name()) orelse return;
    const now = ctx.clock.now_ms();
    if (pending.deadline_ms > now) note_deadline_wake(agent, mono + (pending.deadline_ms - now));
}

fn note_deadline_wake(agent: *Agent, at_mono_ms: u64) void {
    agent.deadline_wake_mono_ms = @min(agent.deadline_wake_mono_ms, at_mono_ms);
}

/// One reconcile step's work on runs. Returns how many store writes were committed.
pub fn pass(
    agent: *Agent,
    ctx: *const Context,
    listings: []const runtime.Listing,
    assigned: []const Entry(records.Assigned),
) Error!u32 {
    agent.jobs_wake_mono_ms = std.math.maxInt(u64);
    const state = ctx.state orelse return 0;
    var work: Work = .{ .agent = agent, .ctx = ctx, .state = state, .listings = listings };
    const subjects = try work.subjects(assigned);
    if (subjects.len == 0) return 0;

    const cctx = ctx.as_controller();
    work.runs = (try controller.list_all(
        records.JobRun,
        &cctx,
        records.prefix_job_runs,
        null,
        constants.agent_node_runs_max,
    )).items;
    const prefix = records.job_observed_prefix(agent.config.node);
    work.observed = (try controller.list_all(
        records.JobObserved,
        &cctx,
        prefix.slice(),
        null,
        constants.job_admitted_window_max,
    )).items;
    for (subjects) |subject| {
        try work.one(subject);
        if (agent.fence.active) break;
    }
    return work.commits;
}

/// How long a run whose input could not be fetched waits before the next try.
const input_retry_ms: u64 = 1_000;

const Work = struct {
    agent: *Agent,
    ctx: *const Context,
    state: agent_state.AgentState,
    listings: []const runtime.Listing,
    runs: []const Entry(records.JobRun) = &.{},
    observed: []const Entry(records.JobObserved) = &.{},
    commits: u32 = 0,

    /// Every assigned run, then the runs that have a container or a start record and no
    /// assignment (a run released, or one stopped by a fence), each once.
    fn subjects(work: *Work, assigned: []const Entry(records.Assigned)) Error![]const Subject {
        const ctx = work.ctx;
        var found: std.ArrayList(Subject) = .empty;
        for (assigned) |entry| {
            if (!records.assigned_is_job(&entry.rec)) continue;
            const name = entry.rec.job.?;
            found.append(ctx.arena, .{
                .id = entry.rec.replica,
                .name = name,
                .epoch = entry.kv.mod_revision,
                .assigned = true,
            }) catch return failures.no_memory(ctx.diag);
        }
        for (work.listings) |*listing| {
            if (label_of(listing, runtime.label_job) == null) continue;
            const id = label_of(listing, runtime.label_replica) orelse continue;
            try work.orphan(&found, id);
        }
        const names = work.state.list(ctx.arena, dir) catch |err|
            return state_failed(ctx, err, "list the start records");
        for (names) |entry| {
            if (agent_state.is_temp(entry)) continue;
            if (!std.mem.startsWith(u8, entry, dir)) continue;
            if (!std.mem.endsWith(u8, entry, suffix)) continue;
            try work.orphan(&found, entry[dir.len .. entry.len - suffix.len]);
        }
        return found.items;
    }

    fn orphan(work: *Work, found: *std.ArrayList(Subject), id: []const u8) Error!void {
        const name = records.job_of_run(id) orelse return;
        for (found.items) |subject| {
            if (std.mem.eql(u8, subject.id, id)) return;
        }
        const leftover: Subject = .{ .id = id, .name = name, .epoch = 0, .assigned = false };
        found.append(work.ctx.arena, leftover) catch return failures.no_memory(work.ctx.diag);
    }

    fn run_of(work: *const Work, id: []const u8) ?*const Entry(records.JobRun) {
        for (work.runs) |*entry| {
            if (std.mem.eql(u8, entry.rec.id, id)) return entry;
        }
        return null;
    }

    fn observed_entry(work: *const Work, id: []const u8) ?*const Entry(records.JobObserved) {
        for (work.observed) |*entry| {
            if (std.mem.eql(u8, entry.rec.run, id)) return entry;
        }
        return null;
    }

    /// The node's observation of the run, unless it belongs to an earlier job of the same name.
    fn seen_of(work: *const Work, id: []const u8) ?*const records.JobObserved {
        const entry = work.observed_entry(id) orelse return null;
        if (work.is_stale_epoch(id, entry.rec.assignment)) return null;
        return &entry.rec;
    }

    /// The revision of the leftover observation of an earlier job of this subject's name, if
    /// there is one: what a claim has to replace.
    fn stale_observation(work: *const Work, subject: Subject) ?u64 {
        const entry = work.observed_entry(subject.id) orelse return null;
        if (!work.is_stale_epoch(subject.id, entry.rec.assignment)) return null;
        return entry.kv.mod_revision;
    }

    /// True if `epoch`, an assignment revision some record or container remembers, is older than
    /// the run being served. A run id is `<name>-job`, so a name reused after retention has the
    /// old id; the job's `/job-runs` record is created once, for the job's whole life, and every
    /// assignment of that job (and so every claim, start record and container) is later than
    /// it. A re-assignment of the same job is not stale: its claim must stay one claim.
    fn is_stale_epoch(work: *const Work, id: []const u8, epoch: u64) bool {
        const entry = work.run_of(id) orelse return false;
        return epoch < entry.kv.create_revision;
    }

    /// The run's container. For a run that is assigned, only one made under this assignment:
    /// a container of an earlier job of the same name is `stale_listing`.
    fn listing_of(work: *const Work, id: []const u8) ?*const runtime.Listing {
        for (work.listings) |*listing| {
            const value = label_of(listing, runtime.label_replica) orelse continue;
            if (!std.mem.eql(u8, value, id)) continue;
            if (work.is_stale(listing, id)) continue;
            return listing;
        }
        return null;
    }

    fn is_stale(work: *const Work, listing: *const runtime.Listing, id: []const u8) bool {
        const made = label_of(listing, runtime.label_created) orelse return false;
        const epoch = std.fmt.parseInt(u64, made, 10) catch return false;
        return work.is_stale_epoch(id, epoch);
    }

    /// Stops the containers of earlier jobs of this run's name that are still running.
    fn stop_stale(work: *Work, id: []const u8) Error!void {
        for (work.listings) |*listing| {
            const value = label_of(listing, runtime.label_replica) orelse continue;
            if (!std.mem.eql(u8, value, id) or !work.is_stale(listing, id)) continue;
            if (is_running(listing)) try work.stop(listing, 0);
        }
    }

    // ---- One run ----

    fn one(work: *Work, subject: Subject) Error!void {
        const ctx = work.ctx;
        try work.stop_stale(subject.id);
        var found = try read_record(ctx, work.state, subject.id);
        // A start record of an earlier job of this name: nothing of this one was started.
        if (found == .record and work.is_stale_epoch(subject.id, found.record.epoch)) {
            found = .absent;
        }
        const listing = work.listing_of(subject.id);
        const seen = work.seen_of(subject.id);
        const run = work.run_of(subject.id);
        switch (found) {
            .absent, .damaged => {
                if (listing == null and seen == null and subject.assigned) {
                    if (found == .damaged) return work.lost(subject, null, seen, .damaged);
                    if (run) |entry| return work.claim(subject, entry);
                    return;
                }
                if (listing == null and seen == null) return;
                return work.unknown(subject, listing, seen);
            },
            .record => |record| {
                if (listing) |present| return work.container(subject, record, present, seen, run);
                return work.gone(subject, record, seen, run);
            },
        }
    }

    /// A container or a claim and no start record: the agent cannot tell what it started.
    fn unknown(
        work: *Work,
        subject: Subject,
        listing: ?*const runtime.Listing,
        seen: ?*const records.JobObserved,
    ) Error!void {
        if (listing) |present| {
            if (is_running(present)) {
                // No start record to say; the run's own grace, if it is still served.
                const grace = if (work.run_of(subject.id)) |entry| entry.rec.grace_ms else 0;
                try work.stop(present, grace);
            }
        }
        try work.lost(subject, null, seen, .missing);
    }

    const Why = enum { missing, damaged, vanished };

    /// Reports the run stopped, `lost`, once.
    fn lost(
        work: *Work,
        subject: Subject,
        record: ?StartRecord,
        seen: ?*const records.JobObserved,
        why: Why,
    ) Error!void {
        if (seen) |existing| {
            if (existing.status == .stopped) return;
        }
        const raw = switch (why) {
            .missing, .damaged => try work.coded(.E0522, subject.id),
            .vanished => try work.coded(.E0521, subject.id),
        };
        const epoch = if (record) |held|
            held.epoch
        else if (seen) |held|
            held.assignment
        else
            subject.epoch;
        try work.report(.{
            .run = subject.id,
            .status = .stopped,
            .epoch = epoch,
            .exit = .{ .kind = .lost },
            .stop_cause = if (record) |held| held.stop_cause else null,
            .diagnostic = raw,
            .started_at_ms = if (record) |held| held.started_at_ms else null,
        });
    }

    /// The run has a start record and no container.
    fn gone(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        seen: ?*const records.JobObserved,
        run: ?*const Entry(records.JobRun),
    ) Error!void {
        if (record.phase == .claiming) {
            if (seen == null) return work.unclaimed(subject, run);
            const held = seen.?;
            if (held.status == .claimed) return work.claimed_unstarted(subject, record, held, run);
        }
        try work.lost(subject, record, seen, .vanished);
        if (!subject.assigned) {
            const done = work.seen_of(subject.id);
            const ended = if (done) |held| held.status == .stopped else false;
            if (ended) try remove_record(work.ctx, work.state, subject.id);
        }
    }

    /// A `claiming` record and no observation: nothing was started, because the claim comes
    /// first. A run that is still assigned is claimed again; a leaked record (the claim was
    /// refused and the run has since been released) is removed.
    fn unclaimed(
        work: *Work,
        subject: Subject,
        run: ?*const Entry(records.JobRun),
    ) Error!void {
        if (!subject.assigned) return remove_record(work.ctx, work.state, subject.id);
        const entry = run orelse return;
        return work.claim(subject, entry);
    }

    /// A `claiming` record, our own `claimed` observation and no container: the claim was
    /// applied and the agent did not learn it (a reply lost, or a crash before the record was
    /// written). Nothing was started, because `start` follows the `claimed` record. Under the
    /// current tenure and epoch, with the run served and no `stop`, it is started now (still at
    /// most once); otherwise it is reported stopped as not started.
    fn claimed_unstarted(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        held: *const records.JobObserved,
        run: ?*const Entry(records.JobRun),
    ) Error!void {
        const entry = run orelse return work.not_started(subject, record);
        const mine = subject.assigned and held.tenure == work.agent.tenure and
            held.assignment == record.epoch and record.epoch == subject.epoch and
            entry.rec.stop == null;
        if (mine) return work.begin(subject, entry, record);
        return work.not_started(subject, record);
    }

    fn not_started(work: *Work, subject: Subject, record: StartRecord) Error!void {
        var wanted: Report = .{
            .run = subject.id,
            .status = .stopped,
            .epoch = record.epoch,
            .exit = .{ .kind = .lost },
            .stop_cause = .not_started,
        };
        // A run whose input could not be fetched before its bound says why (ZC-W0503). Other
        // routes here (a lost claim answer, a stop) have no failure of this run to name.
        if (work.agent.input_failure(subject.id)) |failure| {
            var collector: Diag = undefined;
            collector.reset();
            raise_not_started(&collector, subject.id, failure);
            var finished: Diagnostic = undefined;
            diag_mod.to_diagnostic(&finished, &collector);
            const ctx = work.ctx;
            wanted.diagnostic = try records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
        }
        try work.report(wanted);
    }

    // ---- A container of this run exists ----

    fn container(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        listing: *const runtime.Listing,
        seen: ?*const records.JobObserved,
        run: ?*const Entry(records.JobRun),
    ) Error!void {
        switch (listing.status) {
            .starting, .running => try work.running(subject, record, listing, seen, run),
            .stopped => |reason| {
                if (c1_teeth.job_restart and record.stop_cause == null) {
                    // Test-only: start a run whose container already exited (J2, J7).
                    if (run) |entry| return work.start(subject, record, &entry.rec, null);
                }
                try work.stopped(subject, record, reason, seen);
            },
        }
    }

    fn running(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        listing: *const runtime.Listing,
        seen: ?*const records.JobObserved,
        run: ?*const Entry(records.JobRun),
    ) Error!void {
        const ctx = work.ctx;
        var current = record;
        if (current.phase == .claiming) {
            // A container exists, so a claim was committed before it started.
            current.phase = .claimed;
            try write_record(ctx, work.state, &current);
        }
        const mono = ctx.mono_ms();
        const live = seen == null or seen.?.status != .stopped;
        if (live and (seen == null or seen.?.status != .running)) {
            try work.report(.{
                .run = subject.id,
                .status = .running,
                .epoch = current.epoch,
                .started_at_ms = current.started_at_ms,
            });
        }
        if (current.stop_cause == null) {
            // A run the server no longer serves ended while this node was cut off: the only
            // reason it stops serving a running run is `unreachable`.
            current.stop_cause = work.cause_to_stop(current, run, mono) orelse
                if (run == null) records.StopCause.@"unreachable" else null;
            if (current.stop_cause != null) try write_record(ctx, work.state, &current);
        }
        if (current.stop_cause != null) {
            const grace = if (run) |entry| entry.rec.grace_ms else current.grace_ms;
            try work.stop(listing, grace);
            return;
        }
        if (current.deadline_mono_ms) |at| {
            work.agent.jobs_wake_mono_ms = @min(
                work.agent.jobs_wake_mono_ms,
                at +| c1_teeth.job_deadline_late_ms,
            );
        }
    }

    /// Why a running run is to be stopped now, if it is: the server's `stop`, or the deadline.
    /// A different boot's deadline is not comparable: the run ends `lost` through the stop.
    fn cause_to_stop(
        work: *const Work,
        record: StartRecord,
        run: ?*const Entry(records.JobRun),
        mono: u64,
    ) ?records.StopCause {
        const entry = run orelse return null;
        if (entry.rec.stop) |asked| if (!c1_teeth.job_cancel) return switch (asked.cause) {
            .cancel => .cancel,
            .@"unreachable" => .@"unreachable",
            .not_started => .not_started,
        };
        const at = record.deadline_mono_ms orelse return null;
        if (!std.mem.eql(u8, record.boot_id, work.ctx.boot_id)) return null;
        const due = at +| c1_teeth.job_deadline_late_ms;
        if (mono >= due and !c1_teeth.job_deadline) return .deadline;
        return null;
    }

    fn stopped(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        reason: runtime.ExitReason,
        seen: ?*const records.JobObserved,
    ) Error!void {
        if (seen) |existing| {
            if (existing.status == .stopped) {
                if (!subject.assigned) try remove_record(work.ctx, work.state, subject.id);
                return;
            }
        }
        var wanted: Report = .{
            .run = subject.id,
            .status = .stopped,
            .epoch = record.epoch,
            .stop_cause = record.stop_cause,
            .started_at_ms = record.started_at_ms,
        };
        try work.apply_exit(&wanted, reason);
        if (record.stop_cause == .deadline and wanted.diagnostic == null) {
            var collector: Diag = undefined;
            collector.reset();
            const killed = if (wanted.exit) |exit| exit.signal == 9 else false;
            raise_deadline(&collector, subject.id, killed);
            var finished: Diagnostic = undefined;
            diag_mod.to_diagnostic(&finished, &collector);
            const ctx = work.ctx;
            wanted.diagnostic = try records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
        }
        try work.report(wanted);
    }

    fn stop(work: *Work, listing: *const runtime.Listing, grace_ms: u32) Error!void {
        if (!is_running(listing)) return;
        try work.agent.stop_listing(work.ctx, listing, grace_ms);
    }

    // ---- Claim, then start ----

    fn claim(
        work: *Work,
        subject: Subject,
        entry: *const Entry(records.JobRun),
    ) Error!void {
        const ctx = work.ctx;
        const run = &entry.rec;
        if (run.stop != null) return; // Never claimed: the run moved.
        const record: StartRecord = .{
            .run = subject.id,
            .epoch = subject.epoch,
            .phase = .claiming,
            .grace_ms = run.grace_ms,
            // Bounds the input fetch's retries: `begin` re-arms it with the start.
            .boot_id = ctx.boot_id,
            .deadline_mono_ms = ctx.mono_ms() +| fetch_bound_ms(ctx, run),
        };
        try write_record(ctx, work.state, &record);
        if (c1_teeth.job_claim) {
            // Test-only: start before the claim commits (J7).
            try work.begin(subject, entry, record);
            _ = try work.report_claim(subject, entry);
            return;
        }
        const claimed = try work.report_claim(subject, entry);
        if (!claimed) return;
        try work.begin(subject, entry, record);
    }

    /// How long the input fetch may be retried from now: what is left of the server's start
    /// backstop (`start_by_ms`, the same length as the deadline from creation), at most
    /// `deadline_ms`. The start then arms the deadline in full, so a job ends within twice
    /// `deadline_ms` of creation (docs/briefs/b1.md, Q7), however long the fetch took.
    fn fetch_bound_ms(ctx: *const Context, run: *const records.JobRun) u64 {
        return @min(run.start_by_ms -| ctx.clock.now_ms(), run.deadline_ms);
    }

    /// The run is claimed by this node, this tenure and epoch, and nothing is started: fetch the
    /// input, then write the `claimed` record, then start. A failure to fetch the input that
    /// says nothing about the input (the server or the link) leaves the record as it is, so a
    /// later pass comes back here; only an input that is absent or does not match its digest
    /// ends the run.
    fn begin(
        work: *Work,
        subject: Subject,
        entry: *const Entry(records.JobRun),
        claiming: StartRecord,
    ) Error!void {
        const ctx = work.ctx;
        const run = &entry.rec;
        var record = claiming;
        if (past_bound(ctx, record)) return work.not_started(subject, record);
        const input = work.input_of(subject, run) catch |err| switch (err) {
            error.InputAbsent => return work.cannot_start(subject, record, .{ .input = .absent }),
            error.InputMismatch => {
                return work.cannot_start(subject, record, .{ .input = .mismatch });
            },
            // The fetch failed for a reason that says nothing about the input (the server or
            // the link): keep it inside this run. The record stays `claiming`, a later pass
            // comes back, and the other runs of this pass are not held back.
            else => {
                keep_failure(work.agent, subject.id, ctx.diag);
                ctx.diag.reset();
                const mono = ctx.mono_ms();
                if (record.deadline_mono_ms) |at| {
                    // Past the retry bound nothing has started: report it as not started
                    // (the server ends it `failed deadline`). A bound written by another
                    // boot is not comparable. `Agent.restore` fences, so after another boot
                    // the claim's tenure no longer matches and `claimed_unstarted` reports
                    // `not_started` before it gets here: only a `claiming` record written
                    // before the bound existed reaches the re-arm below. Were `restore` to
                    // keep the tenure over a reboot, that re-arm would restart the bound in
                    // full after every reboot.
                    const this_boot = std.mem.eql(u8, record.boot_id, ctx.boot_id);
                    if (this_boot and mono >= at) return work.not_started(subject, record);
                    if (this_boot) return work.retry_input(at);
                }
                record.boot_id = ctx.boot_id;
                record.deadline_mono_ms = mono +| fetch_bound_ms(ctx, run);
                try write_record(ctx, work.state, &record);
                return work.retry_input(record.deadline_mono_ms.?);
            },
        };
        record.phase = .claimed;
        record.boot_id = ctx.boot_id;
        record.started_at_ms = ctx.clock.now_ms();
        record.deadline_mono_ms = ctx.mono_ms() +| run.deadline_ms;
        try write_record(ctx, work.state, &record);
        try work.start(subject, record, run, input);
    }

    /// The retry bound of a `claiming` record has been reached on this boot: the pass is late (the
    /// agent paused), and a start now would arm a full deadline on top of it.
    fn past_bound(ctx: *const Context, record: StartRecord) bool {
        const at = record.deadline_mono_ms orelse return false;
        if (!std.mem.eql(u8, record.boot_id, ctx.boot_id)) return false;
        return ctx.mono_ms() >= at;
    }

    /// Keeps the failure being dropped, for `not_started` to name.
    fn keep_failure(agent: *Agent, run: []const u8, failed: *const Diag) void {
        var text: [160]u8 = undefined;
        const code = failed.code orelse return;
        const cause = failed.last_cause() orelse "no cause given";
        const said = std.fmt.bufPrint(&text, "ZC-{s}: {s}", .{ @tagName(code), cause }) catch
            text[0..];
        agent.note_input_failure(run, said);
    }

    /// Wake for another fetch, but not later than the deadline that bounds the retries.
    fn retry_input(work: *Work, deadline: u64) void {
        const later = @min(work.ctx.mono_ms() +| input_retry_ms, deadline);
        work.agent.jobs_wake_mono_ms = @min(work.agent.jobs_wake_mono_ms, later);
    }

    fn report_claim(
        work: *Work,
        subject: Subject,
        entry: *const Entry(records.JobRun),
    ) Error!bool {
        const ctx = work.ctx;
        const agent = work.agent;
        // A leftover observation of an earlier job of this name (another assignment epoch) is
        // replaced by the claim; one of this assignment would make the claim refuse.
        const replaces = work.stale_observation(subject) orelse 0;
        const claimed = records.JobObserved{
            .run = subject.id,
            .node = agent.config.node,
            .tenure = agent.tenure,
            .assignment = subject.epoch,
            .status = .claimed,
            .reported_at_ms = ctx.clock.now_ms(),
        };
        const set = ctx.arena.create(compare_sets.Set) catch return failures.no_memory(ctx.diag);
        set.* = .{};
        compare_sets.job_claim(
            set,
            agent.config.node,
            agent.tenure,
            subject.name,
            entry.kv.mod_revision,
            subject.epoch,
            replaces,
        );
        return switch (try work.commit(claimed, set.compares())) {
            .applied => true,
            .refused, .fenced => false,
        };
    }

    fn start(
        work: *Work,
        subject: Subject,
        record: StartRecord,
        run: *const records.JobRun,
        input: ?[]const u8,
    ) Error!void {
        const ctx = work.ctx;
        var wanted: Report = .{
            .run = subject.id,
            .status = .running,
            .epoch = record.epoch,
            .started_at_ms = record.started_at_ms,
        };
        var created: [20]u8 = undefined;
        const created_text = std.fmt.bufPrint(&created, "{d}", .{subject.epoch}) catch
            unreachable; // A u64 has at most 20 digits.
        const labels = [_]runtime.Label{
            .{ .key = runtime.label_replica, .value = subject.id },
            .{ .key = runtime.label_job, .value = subject.name },
            .{ .key = runtime.label_image, .value = run.image },
            .{ .key = runtime.label_created, .value = created_text },
        };
        const extra: usize = if (input != null) 1 else 0;
        const env = ctx.arena.alloc(runtime.EnvVar, run.env.len + extra) catch
            return failures.no_memory(ctx.diag);
        for (run.env, env[0..run.env.len]) |pair, *slot| {
            slot.* = .{ .name = pair[0], .value = pair[1] };
        }
        if (input) |text| env[run.env.len] = .{ .name = run.input_env.?, .value = text };
        const spec: runtime.Spec = .{
            .name = subject.id,
            .image = run.image,
            .source = run.source,
            .command = run.command,
            .env = env,
            .limits = .{
                .cpu_millis = run.limits.cpu_millis,
                .memory_bytes = run.limits.memory_bytes,
                .pids = run.limits.pids,
            },
            .labels = &labels,
        };
        if (runtime.spec_problem(&spec)) |problem| {
            return work.cannot_start(subject, record, .{ .spec = problem });
        }
        const outcome = try ctx.runtime.start(&spec, ctx.diag);
        switch (outcome) {
            .started => {},
            .failed => |failure| try work.apply_exit(&wanted, .{ .start_failed = failure }),
        }
        try work.report(wanted);
    }

    const Refusal = union(enum) {
        input: InputProblem,
        spec: runtime.SpecProblem,
    };

    /// The run was claimed and cannot start (its input is absent or does not match its digest,
    /// or its spec is one the runtime refuses): it ends as a start failure.
    fn cannot_start(work: *Work, subject: Subject, record: StartRecord, why: Refusal) Error!void {
        const ctx = work.ctx;
        var collector: Diag = undefined;
        collector.reset();
        switch (why) {
            .input => |problem| raise_input(&collector, subject.id, problem),
            .spec => |problem| raise_spec(&collector, subject.id, problem),
        }
        var finished: Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        try work.report(.{
            .run = subject.id,
            .status = .stopped,
            .epoch = record.epoch,
            .exit = .{ .kind = .start_failed },
            .diagnostic = try records.diagnostic_raw(ctx.arena, &finished, ctx.diag),
        });
    }

    const InputError = error{ InputAbsent, InputMismatch } || Error;

    /// The run's input, fetched after the claim and checked against its digest; null if it has
    /// none. A store or transport error is returned as it is (the run is tried again); only a
    /// server that says the input is absent, or a digest that does not match, ends the run.
    fn input_of(work: *Work, subject: Subject, run: *const records.JobRun) InputError!?[]const u8 {
        const ctx = work.ctx;
        const digest = run.input_digest orelse return null;
        if (run.input_env == null) return null;
        const key = records.job_input_key(subject.name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
        const kv = got.kv orelse return error.InputAbsent;
        const input = records.read(records.JobInput, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            return error.InputMismatch;
        };
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(input.base64) catch return error.InputMismatch;
        const text = ctx.arena.alloc(u8, size) catch return failures.no_memory(ctx.diag);
        decoder.decode(text, input.base64) catch return error.InputMismatch;
        var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &raw, .{});
        const hex = std.fmt.bytesToHex(raw, .lower);
        const expected = std.fmt.allocPrint(ctx.arena, "sha256:{s}", .{&hex}) catch
            return failures.no_memory(ctx.diag);
        if (!std.mem.eql(u8, expected, digest)) return error.InputMismatch;
        return text;
    }

    // ---- Reports ----

    const Report = struct {
        run: []const u8,
        status: records.JobObservedStatus,
        epoch: u64,
        exit: ?records.Exit = null,
        stop_cause: ?records.StopCause = null,
        diagnostic: ?records.Raw = null,
        started_at_ms: ?u64 = null,
    };

    fn apply_exit(work: *Work, wanted: *Report, reason: runtime.ExitReason) Error!void {
        const arena = work.ctx.arena;
        wanted.status = .stopped;
        switch (reason) {
            .exited => |code| wanted.exit = .{ .kind = .exited, .code = code },
            .signaled => |number| wanted.exit = .{ .kind = .signaled, .signal = number },
            .oom => wanted.exit = .{ .kind = .oom },
            .pid_limit => wanted.exit = .{ .kind = .pid_limit },
            .start_failed => |*failure| {
                wanted.exit = .{ .kind = .start_failed };
                wanted.diagnostic = try records.diagnostic_raw(arena, failure, work.ctx.diag);
                wanted.started_at_ms = null;
            },
            .lost => |maybe| {
                wanted.exit = .{ .kind = .lost };
                if (maybe) |*explanation| {
                    const ctx_diag = work.ctx.diag;
                    wanted.diagnostic = try records.diagnostic_raw(arena, explanation, ctx_diag);
                }
            },
        }
    }

    /// Commits a report unless the store already says the same. A report rests on the tenure
    /// alone; a refusal of it is the end of the tenure, so the agent fences.
    fn report(work: *Work, wanted: Report) Error!void {
        const ctx = work.ctx;
        const agent = work.agent;
        if (work.seen_of(wanted.run)) |existing| {
            if (same(existing, wanted)) return;
        }
        const value: records.JobObserved = .{
            .run = wanted.run,
            .node = agent.config.node,
            .tenure = agent.tenure,
            .assignment = wanted.epoch,
            .status = wanted.status,
            .exit = wanted.exit,
            .stop_cause = wanted.stop_cause,
            .diagnostic = wanted.diagnostic,
            .started_at_ms = wanted.started_at_ms,
            .reported_at_ms = ctx.clock.now_ms(),
        };
        assert(value.valid());
        const node_key = records.node_key(agent.config.node);
        const tenure = ctx.arena.alloc(store_compare, 1) catch return failures.no_memory(ctx.diag);
        tenure[0] = .{ .key = node_key.slice(), .mod_revision = agent.tenure };
        const outcome = try work.commit(value, tenure);
        if (outcome == .refused) {
            try agent.begin_fence(ctx, ctx.mono_ms());
        }
    }

    const store_compare = @import("store.zig").Compare;
    const Outcome = enum { applied, refused, fenced };

    fn commit(
        work: *Work,
        value: records.JobObserved,
        compares: []const store_compare,
    ) Error!Outcome {
        const ctx = work.ctx;
        const name = records.job_of_run(value.run).?;
        const key = records.job_observed_key(work.agent.config.node, name);
        const bytes = try records.encode(ctx.arena, value, ctx.diag);
        const copy = ctx.arena.dupe(u8, key.slice()) catch return failures.no_memory(ctx.diag);
        var batch: controller.Batch = .{};
        batch.put(copy, bytes);
        for (compares) |compare| batch.expect(compare.key, compare.mod_revision);
        const cctx = ctx.as_controller();
        const role: @import("writers.zig").Role = .{ .agent = work.agent.config.node };
        const result = try controller.commit(&cctx, role, &batch);
        switch (result) {
            .applied => {
                work.commits += 1;
                return .applied;
            },
            .conflict => return .refused,
        }
    }

    /// A coded diagnostic of ours as the `Raw` a report carries.
    fn coded(work: *Work, code: enum { E0521, E0522 }, run: []const u8) Error!records.Raw {
        const ctx = work.ctx;
        var collector: Diag = undefined;
        collector.reset();
        switch (code) {
            .E0521 => raise_run_end_unknown(&collector, run, ctx.state_dir),
            .E0522 => raise_start_record(&collector, run, ctx.state_dir),
        }
        var finished: Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        return records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
    }
};

// ---- The diagnostics of a run (one function each, which the golden test also calls) ----

/// ZC-E0521: a run's container is gone and nothing says how it ended.
pub fn raise_run_end_unknown(diag: *Diag, run: []const u8, state_dir: []const u8) void {
    diag.raise(.E0521);
    diag.cause("{s} has no container and left no exit record in {s}", .{ run, state_dir });
    diag.fix(.{
        .sentence = "find why the host restarted or the state directory was lost; " ++
            "it is not run again",
    });
}

/// ZC-E0522: a run's start record is missing or damaged.
pub fn raise_start_record(diag: *Diag, run: []const u8, state_dir: []const u8) void {
    diag.raise(.E0522);
    diag.cause("the start record of {s} in {s} is missing or damaged", .{ run, state_dir });
    diag.fix(.{ .sentence = "check the state directory's disk and permissions" });
}

/// ZC-W0503: a run reached its deadline and was stopped.
pub fn raise_deadline(diag: *Diag, run: []const u8, killed: bool) void {
    diag.raise(.W0503);
    if (killed) {
        diag.cause("{s} reached its deadline; it was stopped and then killed", .{run});
    } else {
        diag.cause("{s} reached its deadline; it was stopped", .{run});
    }
    diag.fix(.{ .sentence = "raise deadline_ms if the job needs the time" });
}

/// ZC-W0503: a run was claimed and its input could not be fetched before its start bound.
pub fn raise_not_started(diag: *Diag, run: []const u8, failure: []const u8) void {
    diag.raise(.W0503);
    diag.cause("{s} was claimed, but its input could not be fetched before the deadline: {s}", .{
        run, failure,
    });
    diag.fix(.{ .sentence = "check that the node reaches the server; submit the job again" });
}

pub const InputProblem = enum { absent, mismatch };

/// ZC-E0523: a run's input is not the one its digest names.
pub fn raise_input(diag: *Diag, run: []const u8, problem: InputProblem) void {
    diag.raise(.E0523);
    switch (problem) {
        .absent => diag.cause("{s} names an input by digest and the server holds none", .{run}),
        .mismatch => diag.cause("the input held for {s} {s}", .{
            run, records.input_mismatch_phrase,
        }),
    }
    diag.fix(.{ .sentence = "report it with the diagnostic bundle; submit the job again" });
}

/// ZC-E0130: the runtime refuses a run's spec. The cause names the field and its limit, as
/// the API's own E0130 does; the API checks these at submit, so reaching this is our gap.
pub fn raise_spec(diag: *Diag, run: []const u8, problem: runtime.SpecProblem) void {
    diag.raise(.E0130);
    const c = constants;
    switch (problem) {
        .bad_name => diag.cause("name: the run id {s} is not a valid container name", .{run}),
        .bad_image => diag.cause("image: {s} must be 1 to {d} bytes", .{
            run, c.image_digest_bytes_max,
        }),
        .bad_command => diag.cause("command: {s} must have 1 to {d} words, the first not empty", .{
            run, c.runtime_command_words_max,
        }),
        .bad_source => diag.cause("source: {s} is over {d} bytes", .{ run, c.source_bytes_max }),
        .too_many_env => diag.cause("env: {s} has more than {d} variables, with the input", .{
            run, c.runtime_env_count_max,
        }),
        .too_many_labels => diag.cause("labels: {s} has more than {d} labels", .{
            run, c.runtime_labels_max,
        }),
        .bad_label => diag.cause(
            "labels: a label of {s} has an empty key, a key over {d} bytes, a value over {d} " ++
                "bytes or '=' in its key",
            .{ run, c.label_key_bytes_max, c.label_value_bytes_max },
        ),
        .missing_replica_label => diag.cause("labels: {s} lacks the replica label", .{run}),
    }
    diag.fix(.{ .sentence = "submit the job again with that field corrected, and report this " ++
        "with the diagnostic bundle: the API should have refused it" });
}

fn same(existing: *const records.JobObserved, wanted: Work.Report) bool {
    if (existing.status != wanted.status) return false;
    if (existing.stop_cause != wanted.stop_cause) return false;
    if (existing.assignment != wanted.epoch) return false;
    const old = existing.exit orelse return wanted.exit == null;
    const new = wanted.exit orelse return false;
    return old.equal(new);
}

fn is_running(listing: *const runtime.Listing) bool {
    return switch (listing.status) {
        .starting, .running => true,
        .stopped => false,
    };
}
