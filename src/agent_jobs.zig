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
        constants.jobs_max,
    )).items;
    for (subjects) |subject| {
        try work.one(subject);
        if (agent.fence.active) break;
    }
    return work.commits;
}

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

    fn seen_of(work: *const Work, id: []const u8) ?*const records.JobObserved {
        for (work.observed) |*entry| {
            if (std.mem.eql(u8, entry.rec.run, id)) return &entry.rec;
        }
        return null;
    }

    fn listing_of(work: *const Work, id: []const u8) ?*const runtime.Listing {
        for (work.listings) |*listing| {
            const value = label_of(listing, runtime.label_replica) orelse continue;
            if (std.mem.eql(u8, value, id)) return listing;
        }
        return null;
    }

    // ---- One run ----

    fn one(work: *Work, subject: Subject) Error!void {
        const ctx = work.ctx;
        const found = try read_record(ctx, work.state, subject.id);
        const listing = work.listing_of(subject.id);
        const seen = work.seen_of(subject.id);
        const run = work.run_of(subject.id);
        switch (found) {
            .absent, .damaged => {
                if (listing == null and seen == null and subject.assigned) {
                    if (found == .damaged) return work.lost(subject, null, seen, .damaged);
                    if (run) |entry| return work.claim(subject, entry, null);
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
            if (is_running(present)) try work.stop(present, 0);
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
        if (record.phase == .claiming and seen == null) {
            // Nothing was started: claim again, unless the run is not to be claimed.
            const entry = run orelse return;
            if (!subject.assigned) return;
            return work.claim(subject, entry, record);
        }
        try work.lost(subject, record, seen, .vanished);
        if (!subject.assigned) {
            const done = work.seen_of(subject.id);
            const ended = if (done) |held| held.status == .stopped else false;
            if (ended) try remove_record(work.ctx, work.state, subject.id);
        }
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
            .stopped => |reason| try work.stopped(subject, record, reason, seen),
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
            current.stop_cause = work.cause_to_stop(current, run, mono);
            if (current.stop_cause != null) try write_record(ctx, work.state, &current);
        }
        if (current.stop_cause != null or run == null) {
            const grace = if (run) |entry| entry.rec.grace_ms else 0;
            try work.stop(listing, grace);
            return;
        }
        if (current.deadline_mono_ms) |at| {
            work.agent.jobs_wake_mono_ms = @min(work.agent.jobs_wake_mono_ms, at);
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
        if (entry.rec.stop) |asked| return switch (asked.cause) {
            .cancel => .cancel,
            .@"unreachable" => .@"unreachable",
            .not_started => .not_started,
        };
        const at = record.deadline_mono_ms orelse return null;
        if (!std.mem.eql(u8, record.boot_id, work.ctx.boot_id)) return null;
        if (mono >= at) return .deadline;
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
        existing: ?StartRecord,
    ) Error!void {
        const ctx = work.ctx;
        const run = &entry.rec;
        if (run.stop != null) return; // Never claimed: the run moved.
        _ = existing;
        var record: StartRecord = .{
            .run = subject.id,
            .epoch = subject.epoch,
            .phase = .claiming,
        };
        try write_record(ctx, work.state, &record);
        const claimed = try work.report_claim(subject, entry);
        if (!claimed) return;
        const now = ctx.clock.now_ms();
        record.phase = .claimed;
        record.boot_id = ctx.boot_id;
        record.started_at_ms = now;
        record.deadline_mono_ms = ctx.mono_ms() +| run.deadline_ms;
        try write_record(ctx, work.state, &record);
        try work.start(subject, record, run);
    }

    fn report_claim(
        work: *Work,
        subject: Subject,
        entry: *const Entry(records.JobRun),
    ) Error!bool {
        const ctx = work.ctx;
        const agent = work.agent;
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
    ) Error!void {
        const ctx = work.ctx;
        var wanted: Report = .{
            .run = subject.id,
            .status = .running,
            .epoch = record.epoch,
            .started_at_ms = record.started_at_ms,
        };
        const input = work.input_of(subject, run) catch |err| switch (err) {
            error.Unreadable => return work.cannot_start(&wanted),
            else => |other| return other,
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
        if (runtime.spec_problem(&spec) != null) return work.cannot_start(&wanted);
        const outcome = try ctx.runtime.start(&spec, ctx.diag);
        switch (outcome) {
            .started => {},
            .failed => |failure| try work.apply_exit(&wanted, .{ .start_failed = failure }),
        }
        try work.report(wanted);
    }

    /// The run was claimed and cannot start (its input is unreadable, or its spec is one the
    /// runtime refuses): it ends as a start failure, blamed outside.
    fn cannot_start(work: *Work, wanted: *Report) Error!void {
        const ctx = work.ctx;
        var collector: Diag = undefined;
        collector.reset();
        const key = records.job_run_key(records.job_of_run(wanted.run).?);
        records.raise_malformed(&collector, key.slice(), "JobRun");
        var finished: Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        wanted.status = .stopped;
        wanted.exit = .{ .kind = .start_failed };
        wanted.diagnostic = try records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
        wanted.started_at_ms = null;
        try work.report(wanted.*);
    }

    const InputError = error{Unreadable} || Error;

    /// The run's input, fetched after the claim and checked against its digest; null if it has
    /// none. A server that cannot give it, or a digest that does not match, is `Unreadable`.
    fn input_of(work: *Work, subject: Subject, run: *const records.JobRun) InputError!?[]const u8 {
        const ctx = work.ctx;
        const digest = run.input_digest orelse return null;
        if (run.input_env == null) return null;
        const key = records.job_input_key(subject.name);
        const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
            ctx.diag.reset();
            return error.Unreadable;
        };
        const kv = got.kv orelse return error.Unreadable;
        const input = records.read(records.JobInput, ctx.arena, kv, ctx.diag) catch {
            ctx.diag.reset();
            return error.Unreadable;
        };
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(input.base64) catch return error.Unreadable;
        const text = ctx.arena.alloc(u8, size) catch return failures.no_memory(ctx.diag);
        decoder.decode(text, input.base64) catch return error.Unreadable;
        var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &raw, .{});
        const hex = std.fmt.bytesToHex(raw, .lower);
        const expected = std.fmt.allocPrint(ctx.arena, "sha256:{s}", .{&hex}) catch
            return failures.no_memory(ctx.diag);
        if (!std.mem.eql(u8, expected, digest)) return error.Unreadable;
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
        collector.raise(switch (code) {
            .E0521 => .E0521,
            .E0522 => .E0522,
        });
        switch (code) {
            .E0521 => {
                collector.cause("run {s} has no container and nothing says how it ended", .{run});
                collector.fix(.{ .sentence = "see ZC-E0521: find out why the host lost it" });
            },
            else => {
                collector.cause("run {s} has no usable start record", .{run});
                collector.fix(.{ .sentence = "see ZC-E0522: check the state directory" });
            },
        }
        var finished: Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        return records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
    }
};

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
