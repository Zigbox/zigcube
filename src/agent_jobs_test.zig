//! Tests of the agent's runs (docs/agent.md, "Runs") against the simulation world: the claim
//! before the start, the start record, a restart in each phase, the deadline on the monotonic
//! clock, and the cause of a stop. The tests write the server's records (the run, the
//! assignment, the input) themselves, so each pins what the agent does with them.

const std = @import("std");
const testing = std.testing;
const agent_mod = @import("agent.zig");
const agent_jobs = @import("agent_jobs.zig");
const agent_state = @import("agent_state.zig");
const rt = @import("runtime.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const codes = @import("diag/codes.zig");
const records = @import("records.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");

const image = "b3:51aa9c03";
const run_id = "train-job";
const job_name = "train";

/// What a test compares of a `JobObserved`; the record itself lives in an arena.
const Seen = struct {
    status: records.JobObservedStatus,
    exit: ?records.Exit,
    stop_cause: ?records.StopCause,
    assignment: u64,
    tenure: u64,
    has_diagnostic: bool,
    /// The code of the stored diagnostic, e.g. `ZC-E0523`.
    code: ?[12]u8,
    started: bool,
};

const Rig = struct {
    world: *sim_world.World,

    fn start() !Rig {
        const fixtures = &sim_runtime.default_fixtures;
        const world = try sim_world.World.create(testing.allocator, 5, fixtures);
        errdefer world.destroy();
        world.advance(2_000);
        try testing.expect(world.agent.tenure != 0);
        return .{ .world = world };
    }

    fn stop(rig: *Rig) void {
        rig.world.destroy();
    }

    fn put(rig: *Rig, role: writers.Role, key: []const u8, value: anytype) !store.Revision {
        const world = rig.world;
        const arena = world.fresh_arena();
        const bytes = try records.encode(arena, value, &world.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try writers.txn(
            world.store_handle(),
            role,
            .{ .on_success = &.{op} },
            &world.diag,
        );
        try testing.expect(done.succeeded);
        return done.revision;
    }

    fn run_record(rig: *Rig, stop_asked: ?records.RunStop, deadline_ms: u64) records.JobRun {
        _ = rig;
        return .{
            .id = run_id,
            .job = job_name,
            .image = image,
            .command = &.{"true"},
            .deadline_ms = deadline_ms,
            .start_by_ms = sim_world.epoch_ms + 1_000_000,
            .created_at_ms = sim_world.epoch_ms,
            .stop = stop_asked,
        };
    }

    /// The run and its assignment to this node; returns the assignment's revision (the epoch).
    fn assign(rig: *Rig, deadline_ms: u64) !store.Revision {
        return rig.assign_run(rig.run_record(null, deadline_ms));
    }

    fn assign_run(rig: *Rig, run: records.JobRun) !store.Revision {
        _ = try rig.put(.job_controller, records.job_run_key(job_name).slice(), run);
        const assigned: records.Assigned = .{
            .replica = run_id,
            .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
            .reason = "test",
            .job = job_name,
        };
        const key = records.assigned_key(sim_world.node_name, run_id);
        return rig.put(.scheduler, key.slice(), assigned);
    }

    fn ask_stop(rig: *Rig, cause: records.RunStopCause, deadline_ms: u64) !void {
        const asked: records.RunStop = .{ .cause = cause, .at_ms = rig.world.now_ms() };
        const run = rig.run_record(asked, deadline_ms);
        _ = try rig.put(.job_controller, records.job_run_key(job_name).slice(), run);
    }

    fn step(rig: *Rig) void {
        _ = rig.world.agent_step();
        try_ok(rig.world.last_failure == null);
    }

    fn observed(rig: *Rig) !?Seen {
        const world = rig.world;
        const arena = world.fresh_arena();
        const key = records.job_observed_key(sim_world.node_name, job_name);
        const got = try world.store_handle().get(arena, key.slice(), null, &world.diag);
        const kv = got.kv orelse return null;
        const value = try records.read(records.JobObserved, arena, kv, &world.diag);
        return .{
            .status = value.status,
            .exit = value.exit,
            .stop_cause = value.stop_cause,
            .assignment = value.assignment,
            .tenure = value.tenure,
            .has_diagnostic = value.diagnostic != null,
            .code = if (value.diagnostic) |raw| code_of(raw.text) else null,
            .started = value.started_at_ms != null,
        };
    }

    fn running(rig: *Rig) bool {
        return rig.world.sim.running_count() == 1;
    }

    /// The start record's phase and cause, read from the agent's files.
    fn start_record(rig: *Rig) !?agent_jobs.StartRecord {
        const world = rig.world;
        const arena = world.fresh_arena();
        var buffer: [96]u8 = undefined;
        const name = agent_jobs.record_name(&buffer, run_id);
        const bytes = world.files.interface().read(arena, name) catch return null;
        const parsed = try std.json.parseFromSliceLeaky(
            agent_jobs.StartRecord,
            arena,
            bytes,
            .{ .ignore_unknown_fields = true },
        );
        return parsed;
    }
};

/// The `code` of a stored diagnostic's JSON.
fn code_of(text: []const u8) ?[12]u8 {
    const Shape = struct { code: []const u8 = "" };
    const parsed = std.json.parseFromSlice(
        Shape,
        testing.allocator,
        text,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();
    var out: [12]u8 = @splat(0);
    if (parsed.value.code.len == 0 or parsed.value.code.len > out.len) return null;
    @memcpy(out[0..parsed.value.code.len], parsed.value.code);
    return out;
}

fn expect_code(seen: Seen, expected: []const u8) !void {
    const code = seen.code orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings(expected, std.mem.sliceTo(&code, 0));
}

fn try_ok(ok: bool) void {
    std.debug.assert(ok);
}

test "a run is claimed, then started, and reported running under the tenure" {
    // Goal: the claim is in the store before the container exists, and the start leaves a record
    // with a deadline. Method: assign a run, step once, and look at all three.
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
    try testing.expectEqual(epoch, seen.assignment);
    try testing.expectEqual(rig.world.agent.tenure, seen.tenure);
    const record = (try rig.start_record()).?;
    try testing.expectEqual(agent_jobs.Phase.claimed, record.phase);
    try testing.expect(record.deadline_mono_ms != null);
}

test "a write the server answers with ZC-E0510 fences the agent at once" {
    // Goal: a tenure that ended is told from a refusal (#172): the agent fences on the answer
    // itself, not when the heartbeat finds out. Method: the store answers every write under the
    // agent's job observations as a server does for a replaced tenure, and one pass is run.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    const prefix = records.job_observed_prefix(sim_world.node_name);
    rig.world.switched.tenure_ended_put_prefix = prefix.slice();
    starts_seen = 0;
    rig.world.sim.on_start = count_start;
    try testing.expect(!rig.world.agent.fence.active);
    rig.step();
    // The claim is the first write and it is refused: the fence must come from it alone, with
    // nothing started (a later `running` report would fence too and hide a missing claim fence).
    try testing.expectEqual(@as(u32, 0), starts_seen);
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
    try testing.expect(rig.world.agent.fence.active or rig.world.agent.fences > 0);
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(u64, 0), rig.world.agent.job_reports_refused);
}

/// Starts the simulated runtime has seen, counted by its `on_start` hook (a container the fence
/// stopped afterwards still counts, which `running()` cannot tell).
var starts_seen: u32 = 0;

fn count_start(context: *anyopaque, spec: *const @import("runtime.zig").Spec) void {
    _ = context;
    _ = spec;
    starts_seen += 1;
}

/// Arms the ZC-E0510 answer for every later write under the agent's job observations; run by
/// the world's `before_put` hook in the claim's own transaction, so the claim lands and the
/// next report is the first one refused.
fn end_the_tenure(context: *anyopaque) void {
    const rig: *Rig = @ptrCast(@alignCast(context));
    // The world keeps the slice, so it lives in a file-level variable, not on this frame.
    const Held = struct {
        var prefix: @TypeOf(records.job_observed_prefix(sim_world.node_name)) = undefined;
    };
    Held.prefix = records.job_observed_prefix(sim_world.node_name);
    rig.world.switched.tenure_ended_put_prefix = Held.prefix.slice();
}

test "a running report the server answers with ZC-E0510 fences the agent at once" {
    // Goal: the same as the claim's test, for the `running` report: the claim commits, the run
    // starts, and the report that follows meets an ended tenure. Method: the claim's own write
    // arms the answer (`end_the_tenure`); one pass is run.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.world.switched.before_put = .{
        .prefix = records.prefix_job_observed,
        .context = &rig,
        .run = end_the_tenure,
    };
    starts_seen = 0;
    rig.world.sim.on_start = count_start;
    try testing.expect(!rig.world.agent.fence.active);
    rig.step();
    // The claim landed (the hook ran), the run started, and the `running` report was the write
    // that fenced.
    try testing.expectEqual(@as(u32, 1), starts_seen);
    try testing.expect(rig.world.switched.before_put == null);
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.claimed, seen.status);
    try testing.expect(rig.world.agent.fence.active or rig.world.agent.fences > 0);
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(u64, 0), rig.world.agent.job_reports_refused);
}

test "an exit report the server answers with ZC-E0510 fences the agent at once" {
    // Goal: the same, for the report of an exit. Method: the run is reported running, its
    // container exits, the store then answers every observation write as for an ended tenure,
    // and one pass is run: the exit report is the write that meets it.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    try testing.expectEqual(records.JobObservedStatus.running, (try rig.observed()).?.status);
    try rig.world.sim.inject(run_id, .{ .exit = 3 });
    end_the_tenure(&rig);
    try testing.expect(!rig.world.agent.fence.active);
    rig.step();
    try testing.expect(rig.world.agent.fence.active or rig.world.agent.fences > 0);
    // The exit was not recorded: the store still says `running`.
    try testing.expectEqual(records.JobObservedStatus.running, (try rig.observed()).?.status);
    try testing.expectEqual(@as(u64, 0), rig.world.agent.job_reports_refused);
}

test "a run whose server record asks for a stop is never claimed" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    try rig.ask_stop(.cancel, 60_000);
    rig.step();
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
}

test "a claim in the store without a start record is never started again" {
    // Goal: a run is claimed at most once, ever. The agent lost its files (or crashed between
    // the claim and the record); the store says claimed, so the run ends `lost`, not started.
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    const claimed: records.JobObserved = .{
        .run = run_id,
        .node = sim_world.node_name,
        .tenure = rig.world.agent.tenure,
        .assignment = epoch,
        .status = .claimed,
        .reported_at_ms = rig.world.now_ms(),
    };
    const key = records.job_observed_key(sim_world.node_name, job_name);
    _ = try rig.put(.{ .agent = sim_world.node_name }, key.slice(), claimed);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(records.ExitKind.lost, seen.exit.?.kind);
    try expect_code(seen, "ZC-E0522");
}

test "an exit is reported with its code and no stop cause" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try rig.world.sim.inject(run_id, .{ .exit = 3 });
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(records.ExitKind.exited, seen.exit.?.kind);
    try testing.expectEqual(@as(?u8, 3), seen.exit.?.code);
    try testing.expectEqual(@as(?records.StopCause, null), seen.stop_cause);
}

test "a container that exited with no start record reports its exit, not lost" {
    // Goal: RB-N3. The start record is gone (a lost file), the container ended with code 7: the
    // exit is what happened, and the run is not reported `lost` (ZC-E0522).
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try rig.world.sim.inject(run_id, .{ .exit = 7 });
    var buffer: [96]u8 = undefined;
    try rig.world.files.interface().remove(agent_jobs.record_name(&buffer, run_id));
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(records.ExitKind.exited, seen.exit.?.kind);
    try testing.expectEqual(@as(?u8, 7), seen.exit.?.code);
}

test "a container that exited with no start record is reported under the current assignment" {
    // Goal: seed 893. The run was observed running under assignment 1 and then assigned again
    // (assignment 2); its container ended and the start record is gone. The store refuses a
    // report that names assignment 1, and the agent made it again on every pass; the exit must
    // be reported under the current assignment, once. Method: observe, reassign, end it.
    var rig = try Rig.start();
    defer rig.stop();
    const first = try rig.assign(60_000);
    rig.step();
    try testing.expectEqual(first, (try rig.observed()).?.assignment);
    const second = try rig.assign(60_000);
    try testing.expect(second > first);
    try rig.world.sim.inject(run_id, .{ .exit = 5 });
    var buffer: [96]u8 = undefined;
    try rig.world.files.interface().remove(agent_jobs.record_name(&buffer, run_id));
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(second, seen.assignment);
    try testing.expectEqual(@as(?u8, 5), seen.exit.?.code);
}

test "a runtime that fails to start ends the run start_failed, with its diagnostic" {
    // Goal: RB-N4. `runtime.start` returns an error (not an outcome): the claimed run ends at
    // once as a start failure and is not left claimed.
    var rig = try Rig.start();
    defer rig.stop();
    var wrapper: FailingList = .{ .inner = rig.world.sim.interface(), .start_failing = true };
    rig.world.runtime_override = wrapper.interface();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(records.ExitKind.start_failed, seen.exit.?.kind);
    try expect_code(seen, "ZC-E0201");
}

test "a start error after the container is up leaves the run claimed, then adopted" {
    // Goal: RB-N4 (review of PR #159). `start` starts the container and then returns an error:
    // the run is executing, so it is not reported start_failed; the next pass adopts it.
    var rig = try Rig.start();
    defer rig.stop();
    var wrapper: FailingList = .{
        .inner = rig.world.sim.interface(),
        .start_failing = true,
        .start_first = true,
    };
    rig.world.runtime_override = wrapper.interface();
    _ = try rig.assign(60_000);
    _ = rig.world.agent_step();
    try testing.expect(rig.world.last_failure != null);
    try testing.expect(rig.running());
    // Never reported as a start failure: the job pass of the same step adopted it, or the
    // next one does.
    if (try rig.observed()) |early| {
        try testing.expect(early.status != .stopped);
    }
    rig.world.last_failure = null;
    wrapper.start_failing = false;
    rig.step();
    try testing.expect(rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
    try testing.expectEqual(@as(u32, 1), wrapper.refused);
}

test "a cancel stops the container and is reported as the cause" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try rig.ask_stop(.cancel, 60_000);
    rig.step();
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .cancel), seen.stop_cause);
}

test "a cancel that races an exit reports the exit with no cause" {
    // The container ended before the agent saw the cancel: the exit is what happened.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try rig.world.sim.inject(run_id, .{ .exit = 0 });
    try rig.ask_stop(.cancel, 60_000);
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?u8, 0), seen.exit.?.code);
    try testing.expectEqual(@as(?records.StopCause, null), seen.stop_cause);
}

test "the deadline stops the run on the monotonic clock, under the same boot" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(5_000);
    rig.step();
    try testing.expect(rig.running());
    rig.world.advance(4_000);
    try testing.expect(rig.running());
    rig.world.advance(3_000);
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .deadline), seen.stop_cause);
    try expect_code(seen, "ZC-W0503");
}

test "a run started in a step arms its deadline wake before the step's later calls (#202)" {
    // Goal: J8 failed in the burst world (seeds 14 and 17): a run started late in a step whose
    // remaining calls hung (a cut link, 7 s) kept executing until the step ended, past its
    // deadline and grace, because only the start of a step looked at the runs' deadlines.
    // Method: one step claims and starts a run with a 5 s deadline; its start record carries the
    // deadline, and by the time the step returns the agent's wake is that deadline, so the calls
    // the same step still makes are capped by it (`calls_deadline_ms`) and the next wait is cut.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(5_000);
    rig.step();
    try testing.expect(rig.running());
    const record = (try rig.start_record()).?;
    const world = rig.world;
    try testing.expectEqual(record.deadline_mono_ms.?, world.agent.deadline_wake_mono_ms);
    const mono = world.now_ms();
    try testing.expect(world.agent.act_in_ms(mono) <= 5_000);
    try testing.expect(world.agent.calls_deadline_ms(mono) <= mono + 5_000 + 1_000);
}

test "the deadline stops the run while the server cannot be reached, before the fence" {
    // Goal: pin the release review's MUST (PR #147): the agent enforces a run's deadline from
    // its own records and clock, so a cut-off node stops the run at its deadline, not when its
    // lease's fence comes (ttl - margin later). Method: the store goes down right after the
    // start; past the deadline, and well before the fence, the run is stopped with the cause
    // recorded, and the ending is reported once the store is back.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(3_000);
    rig.step();
    try testing.expect(rig.running());
    rig.world.set_store_down(true);
    rig.world.advance(2_000);
    try testing.expect(rig.running());
    rig.world.advance(2_000);
    try testing.expect(!rig.running());
    try testing.expect(!rig.world.agent.fence.active);
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(@as(?records.StopCause, .deadline), kept.stop_cause);
    rig.world.set_store_down(false);
    rig.world.advance(2_000);
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .deadline), seen.stop_cause);
}

test "a deadline of another boot is not compared: the run is stopped by the host's loss" {
    // The monotonic clock restarts with the boot, so a deadline from an earlier boot says
    // nothing. The container is gone with the reboot, and the run ends lost, not `deadline`.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(5_000);
    rig.step();
    try testing.expect(rig.running());
    rig.world.boot_id = "another-boot";
    rig.world.restart_agent();
    rig.world.advance(10_000);
    const seen = (try rig.observed()).?;
    try testing.expect(seen.stop_cause != .deadline);
}

test "a restart in the claiming phase with no claim claims again" {
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, run_id);
    const record: agent_jobs.StartRecord = .{ .run = run_id, .epoch = epoch, .phase = .claiming };
    const arena = rig.world.fresh_arena();
    const bytes = try std.json.Stringify.valueAlloc(arena, record, .{});
    try rig.world.files.interface().put_atomic(name, bytes);
    rig.step();
    try testing.expect(rig.running());
    try testing.expectEqual(records.JobObservedStatus.running, (try rig.observed()).?.status);
}

test "a restart of the agent adopts the running container and starts nothing" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    rig.world.restart_agent();
    rig.world.advance(3_000);
    try testing.expectEqual(@as(u32, 1), rig.world.sim.running_count());
    try testing.expectEqual(records.JobObservedStatus.running, (try rig.observed()).?.status);
}

test "a claimed run whose container is gone ends lost" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try rig.world.sim.inject(run_id, .process_vanished);
    rig.world.sim.evict(run_id);
    rig.world.advance(2_000);
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(records.ExitKind.lost, seen.exit.?.kind);
    try testing.expect(!rig.running());
}

test "a fence is recorded as the cause and reported under the next tenure" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(600_000);
    rig.step();
    const first = rig.world.agent.tenure;
    rig.world.set_store_down(true);
    const ttl = rig.world.agent.lease_ttl_ms;
    rig.world.advance(ttl + 8_000);
    try testing.expect(!rig.running());
    rig.world.set_store_down(false);
    rig.world.advance(ttl + 8_000);
    try testing.expect(rig.world.agent.tenure > first);
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .fence), seen.stop_cause);
    try testing.expectEqual(rig.world.agent.tenure, seen.tenure);
}

test "an oom or a pid limit ends the run with that kind, and no cause" {
    // Goal: the runtime's faults reach the job's observation unchanged (the fake runtime's
    // `faults/<run id>` files are these injections by name). Method: inject each, step, read.
    const faults = [_]struct { sim_runtime.Fault, records.ExitKind }{
        .{ .oom, .oom },
        .{ .pid_limit, .pid_limit },
    };
    for (faults) |case| {
        var rig = try Rig.start();
        defer rig.stop();
        _ = try rig.assign(60_000);
        rig.step();
        try rig.world.sim.inject(run_id, case[0]);
        rig.step();
        const seen = (try rig.observed()).?;
        try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
        try testing.expectEqual(case[1], seen.exit.?.kind);
        try testing.expectEqual(@as(?records.StopCause, null), seen.stop_cause);
    }
}

// ---- The windows of a claim, and the failures of a start ----

/// What a claim committed and the agent did not see leaves: the `claiming` record and the
/// `claimed` observation (a reply lost; a crash between the claim and the record write).
fn leave_claim(rig: *Rig, epoch: store.Revision, tenure: u64) !void {
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, run_id);
    const record: agent_jobs.StartRecord = .{ .run = run_id, .epoch = epoch, .phase = .claiming };
    const bytes = try std.json.Stringify.valueAlloc(rig.world.fresh_arena(), record, .{});
    try rig.world.files.interface().put_atomic(name, bytes);
    const claimed: records.JobObserved = .{
        .run = run_id,
        .node = sim_world.node_name,
        .tenure = tenure,
        .assignment = epoch,
        .status = .claimed,
        .reported_at_ms = rig.world.now_ms(),
    };
    const key = records.job_observed_key(sim_world.node_name, job_name);
    _ = try rig.put(.{ .agent = sim_world.node_name }, key.slice(), claimed);
}

test "a claim applied and not seen by the agent is started, once" {
    // Goal: a lost reply (or a crash between the claim and the record) must not end a run that
    // never started as `lost`. Method: leave exactly the state those windows leave.
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    try leave_claim(&rig, epoch, rig.world.agent.tenure);
    rig.step();
    try testing.expect(rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
    try testing.expectEqual(agent_jobs.Phase.claimed, (try rig.start_record()).?.phase);
    rig.step();
    try testing.expectEqual(@as(u32, 1), rig.world.sim.running_count());
}

test "a claim of an earlier tenure is reported not started, never lost" {
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    try leave_claim(&rig, epoch, rig.world.agent.tenure - 1);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
    try testing.expect(!seen.has_diagnostic);
}

test "a claimed run that carries a stop is reported not started, never started" {
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    try leave_claim(&rig, epoch, rig.world.agent.tenure);
    try rig.ask_stop(.cancel, 60_000);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
    try testing.expect(!seen.has_diagnostic);
}

test "a claiming record of a run that is not assigned and not claimed is removed" {
    // Goal: a refused claim leaves no file behind once the run is released.
    var rig = try Rig.start();
    defer rig.stop();
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, run_id);
    const record: agent_jobs.StartRecord = .{ .run = run_id, .epoch = 7, .phase = .claiming };
    const bytes = try std.json.Stringify.valueAlloc(rig.world.fresh_arena(), record, .{});
    try rig.world.files.interface().put_atomic(name, bytes);
    rig.step();
    try testing.expectEqual(@as(?agent_jobs.StartRecord, null), try rig.start_record());
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
}

fn stop_the_run(context: *anyopaque) void {
    const rig: *Rig = @ptrCast(@alignCast(context));
    rig.ask_stop(.cancel, 60_000) catch unreachable; // A test: the rig's own write cannot fail.
}

test "a claim the server refuses starts nothing, and its record goes once the run is released" {
    // The refused-claim test of review 5797621715: the run gets a `stop` after the agent read
    // it and before its claim commits, so the claim is refused (applied: false). Nothing is
    // started and no observation is written; the claiming record stays while the run is
    // assigned, and is removed once the job ends and the assignment is released.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.world.switched.before_put = .{
        .prefix = records.prefix_job_observed,
        .context = &rig,
        .run = stop_the_run,
    };
    rig.step();
    try testing.expect(rig.world.switched.before_put == null);
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(agent_jobs.Phase.claiming, kept.phase);
    // The job ends: its assignment is released.
    const released = [_]store.Op{.{ .delete = records.assigned_key(
        sim_world.node_name,
        run_id,
    ).slice() }};
    const done = try writers.txn(
        rig.world.store_handle(),
        .scheduler,
        .{ .on_success = &released },
        &rig.world.diag,
    );
    try testing.expect(done.succeeded);
    rig.step();
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(?agent_jobs.StartRecord, null), try rig.start_record());
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
}

const hello_digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

fn assign_with_input(rig: *Rig, input_digest: []const u8, base64: ?[]const u8) !void {
    var run = rig.run_record(null, 60_000);
    run.input_env = "INPUT";
    run.input_digest = input_digest;
    _ = try rig.assign_run(run);
    if (base64) |text| {
        const key = records.job_input_key(job_name);
        _ = try rig.put(.api, key.slice(), records.JobInput{ .base64 = text });
    }
}

test "an input that cannot be fetched is tried again, and does not end the run" {
    var rig = try Rig.start();
    defer rig.stop();
    const digest = hello_digest;
    try assign_with_input(&rig, digest, "aGVsbG8=");
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    _ = rig.world.agent_step();
    try testing.expect(!rig.running());
    const waiting = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.claimed, waiting.status);
    try testing.expect(rig.world.last_failure == null); // The failure stayed inside the run.
    rig.world.switched.down_get_prefix = null;
    rig.world.advance(5_000);
    rig.step();
    rig.step();
    try testing.expect(rig.running());
    try testing.expectEqual(records.JobObservedStatus.running, (try rig.observed()).?.status);
}

test "an input that does not match its digest, or is absent, ends the run as start_failed" {
    const cases = [_]?[]const u8{ "b3RoZXI=", null };
    for (cases) |base64| {
        var rig = try Rig.start();
        defer rig.stop();
        const digest = hello_digest;
        try assign_with_input(&rig, digest, base64);
        rig.step();
        try testing.expect(!rig.running());
        const seen = (try rig.observed()).?;
        try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
        try testing.expectEqual(records.ExitKind.start_failed, seen.exit.?.kind);
        try expect_code(seen, "ZC-E0523");
        rig.step();
        try testing.expectEqual(records.JobObservedStatus.stopped, (try rig.observed()).?.status);
    }
}

test "a start the runtime refuses ends the run as start_failed" {
    var rig = try Rig.start();
    defer rig.stop();
    var run = rig.run_record(null, 60_000);
    run.image = "b3:ffffffff";
    _ = try rig.assign_run(run);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.ExitKind.start_failed, seen.exit.?.kind);
    try expect_code(seen, "ZBX-E0410"); // The runtime's own refusal, relayed.
}

test "a spec the runtime's rules refuse ends the run start_failed with ZC-E0130" {
    var rig = try Rig.start();
    defer rig.stop();
    var run = rig.run_record(null, 60_000);
    var env: [constants.runtime_env_count_max][2][]const u8 = undefined;
    var names: [constants.runtime_env_count_max][8]u8 = undefined;
    for (&env, &names, 0..) |*pair, *name, index| {
        const text = std.fmt.bufPrint(name, "V{d}", .{index}) catch unreachable; // Fits 8 bytes.
        pair.* = .{ text, "x" };
    }
    run.env = &env;
    run.input_env = "INPUT";
    run.input_digest = hello_digest;
    _ = try rig.assign_run(run);
    const key = records.job_input_key(job_name);
    _ = try rig.put(.api, key.slice(), records.JobInput{ .base64 = "aGVsbG8=" });
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.ExitKind.start_failed, seen.exit.?.kind);
    try expect_code(seen, "ZC-E0130");
}

test "a damaged start record ends the run lost, with a diagnostic" {
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    var buffer: [96]u8 = undefined;
    try rig.world.files.interface().put_atomic(agent_jobs.record_name(&buffer, run_id), "{not");
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.ExitKind.lost, seen.exit.?.kind);
    try expect_code(seen, "ZC-E0522");
}

test "a running run the server no longer serves is stopped with a recorded cause" {
    // Goal: the stop the agent makes on its own is recorded before it signals, so the report
    // does not read as the job crashing.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const world = rig.world;
    const key = records.job_run_key(job_name);
    const op: store.Op = .{ .delete = key.slice() };
    const txn: store.TxnRequest = .{ .on_success = &.{op} };
    const done = try writers.txn(world.store_handle(), .job_controller, txn, &world.diag);
    try testing.expect(done.succeeded);
    rig.step();
    try testing.expect(!rig.running());
    try testing.expectEqual(
        @as(?records.StopCause, .@"unreachable"),
        (try rig.start_record()).?.stop_cause,
    );
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(@as(?records.StopCause, .@"unreachable"), seen.stop_cause);
}

test "a run released while it runs ends on the node and is never reported again" {
    // Goal (B2 re-review MUST 1): a run released while it runs ends on this node. The agent
    // removes its start record once the container is gone and makes no report the store would
    // refuse, then or on any later pass, and nothing it sees moves the heartbeat forward.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const world = rig.world;
    const run_key = records.job_run_key(job_name);
    const gone = [_]store.Op{ .{ .delete = run_key.slice() }, .{ .delete = records.assigned_key(
        sim_world.node_name,
        run_id,
    ).slice() } };
    const done = try writers.txn(
        world.store_handle(),
        .job_controller,
        .{ .on_success = gone[0..1] },
        &world.diag,
    );
    try testing.expect(done.succeeded);
    const released = try writers.txn(
        world.store_handle(),
        .scheduler,
        .{ .on_success = gone[1..2] },
        &world.diag,
    );
    try testing.expect(released.succeeded);
    for (0..5) |_| rig.step();
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(?agent_jobs.StartRecord, null), try rig.start_record());
    try expect_quiet(&rig, 20);
}

/// `passes` more agent passes, each with the heartbeat pushed far away: none of them may make a
/// report the store refuses, and none may pull the heartbeat forward. Every pass runs before
/// either is checked, so a pass that panics is reached.
fn expect_quiet(rig: *Rig, passes: u32) !void {
    const far: u64 = 1 << 60;
    var moved: u32 = 0;
    for (0..passes) |_| {
        rig.world.agent.renew_at_ms = far;
        rig.step();
        if (rig.world.agent.renew_at_ms != far) moved += 1;
    }
    try testing.expectEqual(@as(u32, 0), moved);
    try testing.expectEqual(@as(u64, 0), rig.world.agent.job_reports_refused);
}

test "a run whose job is deleted and then released while it runs is never reported" {
    // Goal (B2 re-review MUST 2): retention removes the job, its run and its observation while
    // the run still holds its assignment; then the scheduler releases it. The agent has no
    // assignment to report under, so it reports nothing (before the fix it reported under
    // epoch 0 and the write-time check's assertion panicked), and the run ends on the node.
    var rig = try Rig.start();
    defer rig.stop();
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    try testing.expect((try rig.observed()) != null);
    const world = rig.world;
    const job_key = records.job_key(job_name);
    const run_key = records.job_run_key(job_name);
    const seen_key = records.job_observed_key(sim_world.node_name, job_name);
    const retained = [_]store.Op{
        .{ .delete = job_key.slice() },
        .{ .delete = run_key.slice() },
        .{ .delete = seen_key.slice() },
    };
    const swept = try writers.txn(
        world.store_handle(),
        .retention,
        .{ .on_success = &retained },
        &world.diag,
    );
    try testing.expect(swept.succeeded);
    const assigned_key = records.assigned_key(sim_world.node_name, run_id);
    const release = [_]store.Op{.{ .delete = assigned_key.slice() }};
    const released = try writers.txn(
        world.store_handle(),
        .scheduler,
        .{ .on_success = &release },
        &world.diag,
    );
    try testing.expect(released.succeeded);
    try expect_quiet(&rig, 25);
    try testing.expect(!rig.running());
    try testing.expectEqual(@as(?agent_jobs.StartRecord, null), try rig.start_record());
    try testing.expectEqual(@as(?Seen, null), try rig.observed());
}

test "a damaged input value ends the run start_failed with ZC-E0523" {
    var rig = try Rig.start();
    defer rig.stop();
    try assign_with_input(&rig, hello_digest, null);
    const key = records.job_input_key(job_name);
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = "{not json" } };
    const done = try writers.txn(
        rig.world.store_handle(),
        .api,
        .{ .on_success = &.{op} },
        &rig.world.diag,
    );
    try testing.expect(done.succeeded);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.ExitKind.start_failed, seen.exit.?.kind);
    try expect_code(seen, "ZC-E0523");
}

test "a run whose input fetch fails does not hold back another run's exit report" {
    // Goal: a per-run failure stays in the run. "zeta-job" sorts after "train-job", so the
    // pass reaches the failing run first.
    var rig = try Rig.start();
    defer rig.stop();
    var other = rig.run_record(null, 60_000);
    other.id = "zeta-job";
    other.job = "zeta";
    _ = try rig.put(.job_controller, records.job_run_key("zeta").slice(), other);
    const assigned: records.Assigned = .{
        .replica = "zeta-job",
        .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        .reason = "test",
        .job = "zeta",
    };
    const other_key = records.assigned_key(sim_world.node_name, "zeta-job");
    _ = try rig.put(.scheduler, other_key.slice(), assigned);
    rig.step();
    try testing.expectEqual(@as(u32, 1), rig.world.sim.running_count());
    try assign_with_input(&rig, hello_digest, "aGVsbG8=");
    try rig.world.sim.inject("zeta-job", .{ .exit = 4 });
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    rig.step();
    try testing.expect(rig.world.last_failure == null);
    const arena = rig.world.fresh_arena();
    const key = records.job_observed_key(sim_world.node_name, "zeta");
    const got = try rig.world.store_handle().get(arena, key.slice(), null, &rig.world.diag);
    const value = try records.read(records.JobObserved, arena, got.kv.?, &rig.world.diag);
    try testing.expectEqual(records.JobObservedStatus.stopped, value.status);
    try testing.expectEqual(@as(?u8, 4), value.exit.?.code);
}

test "a claim left under an older epoch is not started under the new assignment" {
    var rig = try Rig.start();
    defer rig.stop();
    const epoch = try rig.assign(60_000);
    try leave_claim(&rig, epoch - 1, rig.world.agent.tenure);
    rig.step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
}

test "a leftover of an earlier job of the same name is not this job's claim, start or container" {
    // Goal: run ids are `<name>-job`, so a name reused after retention shares its id with a job
    // that is gone. Method: leave a `stopped` observation and a `claimed` start record made under
    // an assignment older than the new job's run, then assign the new job: it is claimed and
    // started, and the claim replaces the leftover observation.
    var rig = try Rig.start();
    defer rig.stop();
    const old_epoch: store.Revision = 1; // Before any run record of this world.
    const left: records.JobObserved = .{
        .run = run_id,
        .node = sim_world.node_name,
        .tenure = rig.world.agent.tenure,
        .assignment = old_epoch,
        .status = .stopped,
        .exit = .{ .kind = .lost },
        .reported_at_ms = rig.world.now_ms(),
    };
    const key = records.job_observed_key(sim_world.node_name, job_name);
    _ = try rig.put(.{ .agent = sim_world.node_name }, key.slice(), left);
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, run_id);
    const record: agent_jobs.StartRecord = .{
        .run = run_id,
        .epoch = old_epoch,
        .phase = .claimed,
    };
    const bytes = try std.json.Stringify.valueAlloc(rig.world.fresh_arena(), record, .{});
    try rig.world.files.interface().put_atomic(name, bytes);

    const epoch = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
    try testing.expectEqual(epoch, seen.assignment);
    const now = (try rig.start_record()).?;
    try testing.expectEqual(epoch, now.epoch);
}

test "a leftover container of an earlier job of the same name is stopped, never adopted" {
    // Goal: containers made under an assignment older than the run (a job of the same name that
    // is gone) must not be adopted as this job's. Method: leave one running and one exited
    // container of that name, labelled with a created revision before any run record, then
    // assign the new job: the running one is stopped, neither is adopted, the new run starts.
    // Teeth (checked by hand, B2 slice 1): `is_stale` returning false fails this test (the old
    // container is adopted); returning true fails the adoption tests above (the live one is
    // stopped).
    const runtime = @import("runtime.zig");
    var rig = try Rig.start();
    defer rig.stop();
    const sim = &rig.world.sim;
    const labels = [_]runtime.Label{
        .{ .key = runtime.label_replica, .value = run_id },
        .{ .key = runtime.label_job, .value = job_name },
        .{ .key = runtime.label_created, .value = "1" },
    };
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const old_names = [_][]const u8{ "train-job-old1", "train-job-old2" };
    for (old_names) |name| {
        const spec: runtime.Spec = .{
            .name = name,
            .image = image,
            .command = &.{"true"},
            .labels = &labels,
        };
        _ = try sim.interface().start(&spec, &diag);
    }
    try sim.inject(old_names[1], .{ .exit = 0 });
    try testing.expectEqual(@as(u32, 1), sim.running_count());

    const epoch = try rig.assign(60_000);
    rig.step();
    rig.step();
    try testing.expect(sim.process(old_names[0]) != .alive);
    try testing.expect(sim.process(old_names[1]) != .alive);
    try testing.expectEqual(@as(u32, 1), sim.running_count()); // The new run alone.
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
    try testing.expectEqual(epoch, seen.assignment);
    try testing.expectEqual(@as(?records.StopCause, null), seen.stop_cause);
}

test "a spec the runtime refuses is rendered with its field and its limit" {
    // Goal: ZC-E0130's cause names the field and the limit it broke, for each problem, and the
    // deadline cause says "killed" only for a SIGKILL.
    const runtime = @import("runtime.zig");
    const expected = [_]struct { runtime.SpecProblem, []const u8, []const u8 }{
        .{ .bad_name, "name:", "valid container name" },
        .{ .bad_image, "image:", "1 to 67 bytes" },
        .{ .bad_command, "command:", "1 to 64 words" },
        .{ .bad_source, "source:", "over 1024 bytes" },
        .{ .too_many_env, "env:", "more than 16 variables" },
        .{ .too_many_labels, "labels:", "more than 8 labels" },
        .{ .bad_label, "labels:", "key over 32 bytes" },
        .{ .missing_replica_label, "labels:", "replica label" },
    };
    for (expected) |case| {
        var collector: diag_mod.Diag = undefined;
        collector.reset();
        agent_jobs.raise_spec(&collector, "train-job", case[0]);
        try testing.expect(collector.code.? == .E0130);
        const cause = collector.causes.slice()[0].slice();
        try testing.expect(std.mem.indexOf(u8, cause, case[1]) != null);
        try testing.expect(std.mem.indexOf(u8, cause, case[2]) != null);
    }
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    agent_jobs.raise_deadline(&collector, "train-job", false);
    try testing.expect(std.mem.indexOf(u8, collector.causes.slice()[0].slice(), "killed") == null);
}

test "a run whose input fetch keeps failing ends at its deadline, not started" {
    // The fetch fails for a reason that is not about the input, for good: the run's own
    // deadline is what ends it (stop_cause not_started, which the server ends failed deadline).
    var rig = try Rig.start();
    defer rig.stop();
    try assign_with_input(&rig, hello_digest, "aGVsbG8=");
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    _ = rig.world.agent_step();
    try testing.expectEqual(records.JobObservedStatus.claimed, (try rig.observed()).?.status);
    rig.world.advance(30_000);
    _ = rig.world.agent_step();
    try testing.expect(!rig.running());
    try testing.expectEqual(records.JobObservedStatus.claimed, (try rig.observed()).?.status);
    rig.world.advance(40_000); // Past deadline_ms (60 s) from the claim.
    _ = rig.world.agent_step();
    _ = rig.world.agent_step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
    try testing.expect(!rig.running());
    // The report names why: claimed, and the input never came (principle 4).
    try expect_code(seen, "ZC-W0503");
}

fn assign_input_by(rig: *Rig, start_by_ms: u64) !void {
    var run = rig.run_record(null, 60_000);
    run.input_env = "INPUT";
    run.input_digest = hello_digest;
    run.start_by_ms = start_by_ms;
    _ = try rig.assign_run(run);
    const key = records.job_input_key(job_name);
    _ = try rig.put(.api, key.slice(), records.JobInput{ .base64 = "aGVsbG8=" });
}

test "the input fetch's retries end at start_by_ms, not a full deadline after the claim" {
    // Q7: a job ends within twice deadline_ms of creation. The claim lands 50 s into a 60 s
    // start window; the fetch fails for good. The run must be reported not started by the
    // end of the window (10 s), not 60 s after the claim.
    var rig = try Rig.start();
    defer rig.stop();
    try assign_input_by(&rig, rig.world.now_ms() + 10_000);
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    _ = rig.world.agent_step();
    try testing.expectEqual(records.JobObservedStatus.claimed, (try rig.observed()).?.status);
    rig.world.advance(9_000);
    _ = rig.world.agent_step();
    try testing.expectEqual(records.JobObservedStatus.claimed, (try rig.observed()).?.status);
    rig.world.advance(2_000); // 11 s after the claim: past start_by_ms, far from deadline_ms.
    _ = rig.world.agent_step();
    _ = rig.world.agent_step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
    try expect_code(seen, "ZC-W0503");
    try testing.expect(!rig.running());
}

test "an input that arrives after the retry bound does not start the run" {
    // The first pass at or after the bound finds the fetch working again: a start would arm a
    // full deadline on top of the wait, beyond twice deadline_ms, so the run is not started.
    // The bound is moved into the past in the start record: the simulation steps the agent at
    // every wake, so a pass cannot be made to land late by waiting.
    var rig = try Rig.start();
    defer rig.stop();
    try assign_input_by(&rig, rig.world.now_ms() + 60_000);
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    _ = rig.world.agent_step();
    var record = (try rig.start_record()).?;
    try testing.expectEqual(agent_jobs.Phase.claiming, record.phase);
    record.deadline_mono_ms = 1;
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, run_id);
    // Not `fresh_arena`: it would reset the arena the record's strings live in.
    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, record, .{});
    defer testing.allocator.free(bytes);
    try rig.world.files.interface().put_atomic(name, bytes);
    rig.world.switched.down_get_prefix = null;
    rig.world.advance(1_000);
    _ = rig.world.agent_step();
    try testing.expect(!rig.running());
    const seen = (try rig.observed()).?;
    try testing.expectEqual(@as(?records.StopCause, .not_started), seen.stop_cause);
}

test "a late run that fetches in time starts and ends within twice deadline_ms of creation" {
    var rig = try Rig.start();
    defer rig.stop();
    const created = rig.world.now_ms();
    try assign_input_by(&rig, created + 10_000);
    rig.world.switched.down_get_prefix = records.prefix_job_input;
    _ = rig.world.agent_step();
    rig.world.advance(8_000);
    rig.world.switched.down_get_prefix = null;
    rig.step();
    rig.step();
    try testing.expect(rig.running());
    rig.world.advance(61_000); // The deadline counts from the start: 8 s + 61 s < 2 x 60 s.
    rig.step();
    rig.step();
    try testing.expectEqual(@as(?records.StopCause, .deadline), (try rig.observed()).?.stop_cause);
}

test "the not_started report of an unfetchable input is a golden" {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    agent_jobs.raise_not_started(&collector, "train-job", "ZC-E0504: the server answered 503");
    try testing.expect(collector.code.? == .W0503);
    const cause = collector.causes.slice()[0].slice();
    try testing.expectEqualStrings(
        "train-job was claimed, but its input could not be fetched before the deadline: " ++
            "ZC-E0504: the server answered 503",
        cause,
    );
}

// ---- Enforcement never fails the step (PR #150 review) ----

/// The agent's files with `put_atomic` failing, as a full or broken disk does, for names that
/// contain `poisoned` once `armed`; everything else passes through to the simulated files.
const FailingPut = struct {
    inner: agent_state.AgentState,
    poisoned: []const u8,
    armed: bool = false,
    refused: u32 = 0,

    const vtable: agent_state.AgentState.VTable = .{
        .put_atomic = put_atomic,
        .append = append,
        .read = read,
        .remove = remove,
        .list = list,
    };

    fn interface(self: *FailingPut) agent_state.AgentState {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *FailingPut {
        return @ptrCast(@alignCast(context));
    }

    fn put_atomic(context: *anyopaque, name: []const u8, data: []const u8) agent_state.Error!void {
        const self = from(context);
        if (self.armed and std.mem.indexOf(u8, name, self.poisoned) != null) {
            self.refused += 1;
            return error.Io;
        }
        return self.inner.put_atomic(name, data);
    }

    fn append(context: *anyopaque, name: []const u8, data: []const u8) agent_state.Error!void {
        return from(context).inner.append(name, data);
    }

    fn read(
        context: *anyopaque,
        arena: std.mem.Allocator,
        name: []const u8,
    ) agent_state.Error![]const u8 {
        return from(context).inner.read(arena, name);
    }

    fn remove(context: *anyopaque, name: []const u8) agent_state.Error!void {
        return from(context).inner.remove(name);
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        prefix: []const u8,
    ) agent_state.Error![]const []const u8 {
        return from(context).inner.list(arena, prefix);
    }
};

/// The simulated runtime with `list` failing while `failing` is set, and `start` while
/// `start_failing` is.
const FailingList = struct {
    inner: rt.Runtime,
    failing: bool = false,
    /// With `agent`: `list` fails only while the agent's before-call hook runs.
    fail_in_hook: bool = false,
    agent: ?*const agent_mod.Agent = null,
    start_failing: bool = false,
    /// With `start_failing`: the inner runtime starts the container first, as a runtime whose
    /// supervisor is up when a later step fails.
    start_first: bool = false,
    /// How many starts it refused.
    refused: u32 = 0,
    /// Armed by each start that succeeds: the next allocation fails.
    arm_after_start: ?*FailOnce = null,

    const vtable: rt.Runtime.VTable = .{
        .start = start,
        .stop = stop,
        .signal = signal,
        .inspect = inspect,
        .list = list,
        .events = events,
    };

    fn interface(self: *FailingList) rt.Runtime {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *FailingList {
        return @ptrCast(@alignCast(context));
    }

    fn start(
        context: *anyopaque,
        spec: *const rt.Spec,
        diag: *diag_mod.Diag,
    ) rt.Error!rt.StartOutcome {
        const self = from(context);
        if (self.start_failing) {
            self.refused += 1;
            if (self.start_first) {
                _ = try self.inner.vtable.start(self.inner.context, spec, diag);
            }
            diag.raise(.E0201);
            diag.cause("the simulated runtime cannot start a container", .{});
            diag.fix(.{ .sentence = "none: a test switched it off" });
            return error.RuntimeFailed;
        }
        const outcome = try self.inner.vtable.start(self.inner.context, spec, diag);
        if (self.arm_after_start) |arena| arena.armed = true;
        return outcome;
    }

    fn stop(
        context: *anyopaque,
        handle: rt.Handle,
        grace_ms: u32,
        diag: *diag_mod.Diag,
    ) rt.Error!void {
        const inner = from(context).inner;
        return inner.vtable.stop(inner.context, handle, grace_ms, diag);
    }

    fn signal(
        context: *anyopaque,
        handle: rt.Handle,
        number: u8,
        diag: *diag_mod.Diag,
    ) rt.Error!void {
        const inner = from(context).inner;
        return inner.vtable.signal(inner.context, handle, number, diag);
    }

    fn inspect(
        context: *anyopaque,
        handle: rt.Handle,
        diag: *diag_mod.Diag,
    ) rt.Error!rt.Status {
        const inner = from(context).inner;
        return inner.vtable.inspect(inner.context, handle, diag);
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        diag: *diag_mod.Diag,
    ) rt.Error![]const rt.Listing {
        const self = from(context);
        const in_hook = self.fail_in_hook and self.agent.?.in_before_call;
        if (self.failing or in_hook) {
            diag.raise(.E0201);
            diag.cause("the simulated runtime cannot list its containers", .{});
            diag.fix(.{ .sentence = "none: a test switched it off" });
            return error.RuntimeFailed;
        }
        return self.inner.vtable.list(self.inner.context, arena, diag);
    }

    fn events(
        context: *anyopaque,
        arena: std.mem.Allocator,
        timeout_ms: u32,
        diag: *diag_mod.Diag,
    ) rt.Error![]const rt.StatusChange {
        const inner = from(context).inner;
        return inner.vtable.events(inner.context, arena, timeout_ms, diag);
    }
};

/// A second job's run, beside `assign`'s: `job`, `id` and its deadline.
fn assign_other(rig: *Rig, job: []const u8, id: []const u8, deadline_ms: u64) !void {
    var run = rig.run_record(null, deadline_ms);
    run.id = id;
    run.job = job;
    _ = try rig.put(.job_controller, records.job_run_key(job).slice(), run);
    const assigned: records.Assigned = .{
        .replica = id,
        .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        .reason = "test",
        .job = job,
    };
    const key = records.assigned_key(sim_world.node_name, id);
    _ = try rig.put(.scheduler, key.slice(), assigned);
}

test "a run's unwritable start record neither fences the node nor holds back another run" {
    // Goal: pin the review's MUST (PR #150): a failure in one run's enforcement (its record's
    // write) must not fail the step before the heartbeat, or the node is fenced for one run's
    // trouble and the runs after it in the listing are never stopped. Method: two runs, the
    // first with the earlier deadline and a state directory that refuses every write of its
    // record; 40 s pass, well past the ttl. The lease is kept and no fence falls; the first run
    // is stopped all the same (the cause is only in memory), and so is the other at its deadline
    // with its cause recorded; the failure was noted.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(3_000);
    try assign_other(&rig, "other", "other-job", 4_000);
    world.advance(500);
    try testing.expectEqual(@as(u32, 2), world.sim.running_count());
    var failing: FailingPut = .{ .inner = world.files.interface(), .poisoned = run_id };
    world.state_override = failing.interface();
    failing.armed = true;
    const lease = world.agent.lease;
    world.advance(40_000);
    try testing.expect(failing.refused > 0);
    try testing.expect(world.agent.enforce_failures > 0);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
    try testing.expect(!world.agent.fence.active);
    try testing.expectEqual(lease, world.agent.lease);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    failing.armed = false;
    var buffer: [96]u8 = undefined;
    const name = agent_jobs.record_name(&buffer, "other-job");
    const bytes = try world.files.interface().read(world.fresh_arena(), name);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"deadline\"") != null);
}

test "a run whose step fails does not hold back the runs after it in the same pass (#205)" {
    // Goal: the release reviews' SHOULD (RA, RB): one job's failing step (here its start record
    // cannot be written) must not abort the pass, or every later job on the node is starved of
    // its claim, start, cancel and report. Method: two runs; "other-job" sorts before
    // "train-job", and its record refuses every write. Within the 2 s the test advances,
    // "train-job" is claimed and started all the same, the failure is noted, and the node is not
    // fenced.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    var failing: FailingPut = .{ .inner = world.files.interface(), .poisoned = "other-job" };
    world.state_override = failing.interface();
    failing.armed = true;
    try assign_other(&rig, "other", "other-job", 60_000);
    _ = try rig.assign(60_000);
    world.advance(2_000);
    try testing.expect(failing.refused > 0);
    try testing.expect(world.agent.enforce_failures > 0 or world.last_failure != null);
    try testing.expect(!world.agent.fence.active);
    try testing.expectEqual(@as(u32, 1), world.sim.running_count());
    try testing.expect(world.sim.has(run_id));
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.running, seen.status);
}

test "a lost answer to an earlier run's write does not hold back a later run's stop (#247)" {
    // Goal: #247 and #248. A store call of one run that fails with a failure that is not the
    // runtime's (here the store commits the write and the answer is lost, ZC-E0201) ends the
    // pass's store calls, but must not skip the stop of a run later in name order whose stop has
    // committed: J6's linked bound assumes the next pass reaches it. Method: "train-job" runs;
    // "other-job", which sorts first, is assigned with every write of its observation committed
    // and its answer lost; "train-job" is cancelled. One step later its cancel is recorded as its
    // cause and its container is stopped, though that step failed on "other-job".
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const other = records.job_observed_key(sim_world.node_name, "other");
    world.switched.lost_answer_prefix = other.slice();
    try assign_other(&rig, "other", "other-job", 60_000);
    try rig.ask_stop(.cancel, 60_000);
    _ = world.agent_step();
    try testing.expect(world.switched.lost_answers > 0);
    try testing.expectEqual(@as(?codes.Code, .E0201), world.last_failure);
    // No store call follows the lost answer in that step.
    try testing.expectEqual(@as(u32, 0), world.switched.calls_since_mark);
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(@as(?records.StopCause, .cancel), kept.stop_cause);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    // Once the answers come back, the cancel is reported as the cause.
    world.switched.lost_answer_prefix = null;
    world.last_failure = null;
    rig.step();
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .cancel), seen.stop_cause);
}

test "a failed read of the runs' reports does not hold back a stop the runs already show (#142)" {
    // Goal: #142 (seed 2821617909). The job pass reads the runs, then this node's reports. When
    // the second read fails, the runs it already holds say which stops are committed; a pass
    // that ended there withheld the stop for as long as that read kept failing, while the
    // heartbeat went on (so the fence never came), and the run outlived J6's bound. Method:
    // "train-job" runs and is cancelled; the reports' list fails (ZC-E0201) for one step. That
    // step records the cancel as the cause and stops the container, and makes no write after
    // the failed read; once the read works, the cancel is reported.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    try rig.ask_stop(.cancel, 60_000);
    const prefix = records.job_observed_prefix(sim_world.node_name);
    world.switched.down_list_prefix = prefix.slice();
    const txns_before = world.switched.txns_since_mark;
    world.switched.marked = true;
    _ = world.agent_step();
    world.switched.down_list_prefix = null;
    try testing.expectEqual(@as(?codes.Code, .E0201), world.last_failure);
    try testing.expectEqual(txns_before, world.switched.txns_since_mark);
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(@as(?records.StopCause, .cancel), kept.stop_cause);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    world.last_failure = null;
    rig.step();
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .cancel), seen.stop_cause);
}

/// "train-job" running, and "other-job", which sorts first, assigned; the caller has set
/// `lost_answer_prefix` to "other-job"'s observation, so the next step's first write of it is
/// committed and its answer lost (ZC-E0201).
fn run_then_assign_other(rig: *Rig) !void {
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    try assign_other(rig, "other", "other-job", 60_000);
}

test "after a lost answer, a running run whose start record is gone or damaged is stopped (#247)" {
    // Goal: the review's SHOULD (PR #250, mutant m5). After a failure that is not the runtime's,
    // `stop_only` stops a running container that has no readable start record (a state
    // directory that lost or damaged it), as `unknown` would: it must not wait for a pass with
    // no server failure. Method: as the #247 test, with "train-job"'s record removed, then (a
    // second world) damaged, before the step; no stop is asked. That step stops it.
    for ([_]bool{ false, true }) |damaged| {
        var rig = try Rig.start();
        defer rig.stop();
        const world = rig.world;
        const other = records.job_observed_key(sim_world.node_name, "other");
        world.switched.lost_answer_prefix = other.slice();
        try run_then_assign_other(&rig);
        var buffer: [96]u8 = undefined;
        const name = agent_jobs.record_name(&buffer, run_id);
        if (damaged) {
            try world.files.interface().put_atomic(name, "{not");
        } else {
            try world.files.interface().remove(name);
        }
        _ = world.agent_step();
        try testing.expectEqual(@as(u32, 1), world.switched.lost_answers);
        try testing.expectEqual(@as(?codes.Code, .E0201), world.last_failure);
        try testing.expectEqual(@as(u32, 0), world.switched.calls_since_mark);
        try testing.expect(world.sim.ended_at_ms(run_id) != null);
    }
}

test "after a lost answer, a running run the server no longer serves is stopped (#247)" {
    // Goal: the review's SHOULD (PR #250, mutant m6). After a failure that is not the runtime's,
    // a running run that is gone from the runs this pass read is stopped with the cause
    // `unreachable` recorded first, as `running` would, in the same pass. Method: as the #247
    // test, with "train-job"'s run deleted before the step in place of a cancel.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    const other = records.job_observed_key(sim_world.node_name, "other");
    world.switched.lost_answer_prefix = other.slice();
    try run_then_assign_other(&rig);
    const key = records.job_run_key(job_name);
    const op: store.Op = .{ .delete = key.slice() };
    const txn: store.TxnRequest = .{ .on_success = &.{op} };
    const done = try writers.txn(world.store_handle(), .job_controller, txn, &world.diag);
    try testing.expect(done.succeeded);
    _ = world.agent_step();
    try testing.expectEqual(@as(u32, 1), world.switched.lost_answers);
    try testing.expectEqual(@as(?codes.Code, .E0201), world.last_failure);
    try testing.expectEqual(@as(u32, 0), world.switched.calls_since_mark);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    try testing.expectEqual(
        @as(?records.StopCause, .@"unreachable"),
        (try rig.start_record()).?.stop_cause,
    );
}

test "a replica stage's failure does not hold back a run's stop (#247)" {
    // Goal: the reviews' SHOULD (PR #250, mutant m2). A replica stage's failure that is not the
    // runtime's must not skip the job pass, or a run whose cancel has committed runs a step
    // longer: #247 one stage up. The replica stage makes no store call (its writes wait for the
    // flush, after the job pass), so the failure is the step arena running out (ZC-E0207) just
    // after the replica's container starts. The job pass then makes one store call, the read of
    // the runs, and no transaction. Method: "train-job" runs; a replica is assigned and the next
    // allocation after its start fails; "train-job" is cancelled. That step records the cancel
    // as its cause and stops its container.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    const replica: records.Replica = .{
        .id = "web-1",
        .service = "web",
        .generation = 1,
        .image = image,
        .command = &.{"true"},
    };
    _ = try rig.put(.replica_controller, records.replica_key("web", "web-1").slice(), replica);
    const assigned = records.assigned_replica(
        "web-1",
        "web",
        .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        "test",
    );
    const key = records.assigned_key(sim_world.node_name, "web-1");
    _ = try rig.put(.scheduler, key.slice(), assigned);
    try rig.ask_stop(.cancel, 60_000);
    var arena: FailOnce = .{ .inner = world.arena_state.allocator(), .store = &world.switched };
    var wrapper: FailingList = .{ .inner = world.sim.interface(), .arm_after_start = &arena };
    world.runtime_override = wrapper.interface();
    world.arena_override = arena.allocator();
    // No `advance`: the server's controllers would delete a replica of a service that is not
    // there.
    _ = world.agent_step();
    world.runtime_override = null;
    world.arena_override = null;
    try testing.expectEqual(@as(u32, 1), arena.failed);
    try testing.expectEqual(@as(?codes.Code, .E0207), world.last_failure);
    try testing.expectEqual(@as(u32, 1), world.switched.calls_since_mark);
    try testing.expectEqual(@as(u32, 0), world.switched.txns_since_mark);
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(@as(?records.StopCause, .cancel), kept.stop_cause);
    try testing.expect(world.sim.ended_at_ms(run_id) != null);
    try testing.expect(world.sim.ended_at_ms("web-1") == null);
    // Once memory is back, the cancel is reported as the cause.
    world.last_failure = null;
    rig.step();
    rig.step();
    const seen = (try rig.observed()).?;
    try testing.expectEqual(records.JobObservedStatus.stopped, seen.status);
    try testing.expectEqual(@as(?records.StopCause, .cancel), seen.stop_cause);
}

/// The allocator interface's length type.
const Length = usize;

/// An allocator that passes every request to `inner` except the first one after `armed` is
/// set, which it refuses; it then marks `store` (`SwitchedStore.mark`).
const FailOnce = struct {
    inner: std.mem.Allocator,
    store: *sim_world.SwitchedStore,
    armed: bool = false,
    failed: u32 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *FailOnce) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *FailOnce {
        return @ptrCast(@alignCast(context));
    }

    /// True if this request is the one refused.
    fn refuse(self: *FailOnce) bool {
        if (!self.armed) return false;
        self.armed = false;
        self.failed += 1;
        self.store.mark();
        return true;
    }

    fn alloc(context: *anyopaque, len: Length, alignment: std.mem.Alignment, ret: Length) ?[*]u8 {
        const self = from(context);
        if (self.refuse()) return null;
        return self.inner.rawAlloc(len, alignment, ret);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Length,
        ret: Length,
    ) bool {
        const self = from(context);
        if (self.refuse()) return false;
        return self.inner.rawResize(memory, alignment, new_len, ret);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Length,
        ret: Length,
    ) ?[*]u8 {
        const self = from(context);
        if (self.refuse()) return null;
        return self.inner.rawRemap(memory, alignment, new_len, ret);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: Length) void {
        from(context).inner.rawFree(memory, alignment, ret);
    }
};

test "a runtime listing that fails does not fail the step before the heartbeat" {
    // Goal: the review's SHOULD (PR #150), decided: a node that cannot list its containers skips
    // enforcement for the step and keeps its lease, as it did before enforcement moved ahead of
    // the heartbeat. Method: the runtime's list fails for 40 s, well past the ttl: no fence, the
    // lease is the one it had, the failure is noted; once the list works the overdue run is
    // stopped for its deadline.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(3_000);
    world.advance(500);
    try testing.expect(rig.running());
    var wrapper: FailingList = .{ .inner = world.sim.interface() };
    world.runtime_override = wrapper.interface();
    wrapper.failing = true;
    const lease = world.agent.lease;
    world.advance(40_000);
    try testing.expect(world.agent.enforce_failures > 0);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
    try testing.expectEqual(lease, world.agent.lease);
    try testing.expect(rig.running());
    wrapper.failing = false;
    world.advance(2_000);
    try testing.expect(!rig.running());
    const kept = (try rig.start_record()).?;
    try testing.expectEqual(@as(?records.StopCause, .deadline), kept.stop_cause);
}

test "a cancel takes effect while a replica's start keeps failing" {
    // Goal: RA-SHOULD1. A replica whose runtime start errors fails the replica pass at every
    // step; the job pass must still run, or a cancel is withheld for as long as the error lasts
    // (the heartbeat succeeds, so no fence ends it). Method: a run is running; the runtime's
    // start then fails and a replica is assigned; the run is cancelled; steps fail with the
    // replica's error and the run stops all the same with the cancel as its cause.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(60_000);
    rig.step();
    try testing.expect(rig.running());
    var wrapper: FailingList = .{ .inner = world.sim.interface(), .start_failing = true };
    world.runtime_override = wrapper.interface();
    const replica: records.Replica = .{
        .id = "web-1",
        .service = "web",
        .generation = 1,
        .image = "b3:51aa9c03",
        .command = &.{"true"},
    };
    _ = try rig.put(.replica_controller, records.replica_key("web", "web-1").slice(), replica);
    const assigned = records.assigned_replica(
        "web-1",
        "web",
        .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        "test",
    );
    const key = records.assigned_key(sim_world.node_name, "web-1");
    _ = try rig.put(.scheduler, key.slice(), assigned);
    try rig.ask_stop(.cancel, 60_000);
    // No `advance`: the server's controllers would delete a replica of a service that is not
    // there. Each step fails with the replica's error and the cancel is acted on all the same.
    for (0..3) |_| {
        const result = world.agent_step();
        try testing.expect(result.failed != null);
    }
    try testing.expect(wrapper.refused >= 3);
    try testing.expect(!rig.running());
    wrapper.start_failing = false;
    const seen = (try rig.observed()).?;
    try testing.expectEqual(@as(?records.StopCause, .cancel), seen.stop_cause);
}

test "run wakes closer together than a heartbeat do not cut the heartbeat" {
    // Goal: the review's SHOULD (PR #150): a call to the server that a run's wake falls inside
    // must get `call_inflight_min_ms`, or wakes 100 ms apart cut every 150 ms keepalive and the
    // lease starves. Method: eight runs whose deadlines are 100 ms apart and span the moment the
    // lease is renewed; a keepalive costs 150 ms of the clock and is cut by the cap the agent
    // sets, as a real exchange is. No keepalive is cut and the lease is the same afterwards.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    const names = [_][]const u8{
        "wake0", "wake1", "wake2", "wake3", "wake4", "wake5", "wake6", "wake7",
    };
    const ids = [_][]const u8{
        "wake0-job", "wake1-job", "wake2-job", "wake3-job",
        "wake4-job", "wake5-job", "wake6-job", "wake7-job",
    };
    const first = (world.agent.renew_at_ms - world.now_ms()) - 300;
    for (names, ids, 0..) |job, id, i| try assign_other(&rig, job, id, first + 100 * i);
    world.switched.keepalive_cost = .{
        .clock = &world.manual,
        .cost_ms = 150,
        .cap_ms = &world.call_cap_ms,
    };
    const lease = world.agent.lease;
    world.advance(300);
    try testing.expectEqual(@as(u32, 8), world.sim.running_count());
    world.advance(first + 1_500);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    try testing.expectEqual(@as(u32, 0), world.switched.keepalive_cost.?.cut);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
    try testing.expectEqual(lease, world.agent.lease);
}

test "each call of a step gets its own floor when a run's wake is near" {
    // Goal: #142 (J6 seed 102): `calls_deadline_ms` gives a call `call_inflight_min_ms` past a
    // run's wake, but the cap was set once per step, so all of a step's reads shared one floor
    // and the later ones were cut step after step. Method: eight runs with deadlines 100 ms
    // apart keep a wake within the floor of every step; every call costs 150 ms of the clock,
    // so a step's calls together take far more than the floor. The agent gives the cap again
    // before each call, so none is cut, the lease holds and every run is stopped.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    const names = [_][]const u8{
        "floor0", "floor1", "floor2", "floor3", "floor4", "floor5", "floor6", "floor7",
    };
    const ids = [_][]const u8{
        "floor0-job", "floor1-job", "floor2-job", "floor3-job",
        "floor4-job", "floor5-job", "floor6-job", "floor7-job",
    };
    const first = (world.agent.renew_at_ms - world.now_ms()) - 300;
    for (names, ids, 0..) |job, id, i| try assign_other(&rig, job, id, first + 100 * i);
    world.switched.call_cost = .{
        .clock = &world.manual,
        .cost_ms = 150,
        .cap_ms = &world.call_cap_ms,
    };
    world.advance(first + 5_000);
    try testing.expectEqual(@as(u32, 0), world.sim.running_count());
    try testing.expectEqual(@as(u32, 0), world.switched.call_cost.?.cut);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
    // When, not only whether: a run whose deadline falls during a step is stopped before the
    // step's next call, so at most one call (150 ms) and a tick past its deadline. Without the
    // enforcement in `Agent.before_call` it waits for the next step, a whole step later.
    for (ids, 0..) |id, i| {
        const started = world.sim.started_at_ms(id).?;
        const ended = world.sim.ended_at_ms(id).?;
        const deadline = started + (first + 100 * i);
        try testing.expect(ended >= deadline);
        try testing.expect(ended <= deadline + 150 + sim_world.tick_ms);
    }
}

test "a listing that fails mid-step leaves the run's wake due and is counted once" {
    // Goal: review of PR #212 (SHOULD). If the container listing fails in `before_call`, the
    // wake must not drop to "never" (that would cap the rest of the step at the fence only,
    // past J8's lateness bound): it stays due, each call gets one floor and tries the listing
    // again, and the failure is counted once per step. Method: a run whose deadline falls
    // while a step's calls cost 150 ms each; the listing fails only inside the hook. After the
    // step the wake is still due and one failure is counted, however many calls retried.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    _ = try rig.assign(1_000);
    world.advance(300);
    try testing.expect(rig.running());
    var wrapper: FailingList = .{
        .inner = world.sim.interface(),
        .fail_in_hook = true,
        .agent = world.agent,
    };
    world.runtime_override = wrapper.interface();
    const deadline = world.sim.started_at_ms(run_id).? + 1_000;
    // Without call costs a step takes no clock time: advance to just short of the deadline
    // with the ordinary steps, then make the step's calls cross it.
    while (world.now_ms() + 250 < deadline) world.advance(50);
    world.switched.call_cost = .{
        .clock = &world.manual,
        .cost_ms = 150,
        .cap_ms = &world.call_cap_ms,
    };
    const before = world.agent.enforce_failures;
    _ = world.agent_step();
    world.switched.call_cost = null;
    try testing.expect(world.now_ms() > deadline);
    try testing.expectEqual(before + 1, world.agent.enforce_failures);
    try testing.expect(world.agent.deadline_wake_mono_ms != std.math.maxInt(u64));
    world.runtime_override = null;
    rig.step();
    try testing.expect(!rig.running());
}

test "a run's reported cause is the one its start record holds, whenever the deadline falls" {
    // Goal: review of PR #212 (SHOULD). The pass reads a run's start record, then reports
    // `running` (store calls, which enforce a deadline that comes due), then may record a
    // cause from its own copy; `running` re-reads the record after the report so a cause the
    // hook recorded is kept. Method: the run is started by one step (its `running` is
    // reported by the next), the server then asks to cancel it, and the next step's calls
    // (150 ms) cross the run's deadline at a different point in each run of the sweep. In
    // every run the cause reported is the cause the start record holds, and a run stopped
    // at its deadline (not before) says so. The sweep does not reach the lost update itself
    // (the report has one call and the record is read just before it): the test keeps the
    // property, the re-read is its guard.
    var checked: u32 = 0;
    var deadline_ms: u64 = 100;
    while (deadline_ms <= 1_000) : (deadline_ms += 50) {
        var rig = try Rig.start();
        defer rig.stop();
        const world = rig.world;
        _ = try rig.assign(deadline_ms);
        world.switched.call_cost = .{
            .clock = &world.manual,
            .cost_ms = 150,
            .cap_ms = &world.call_cap_ms,
        };
        _ = world.agent_step();
        if (!rig.running()) continue;
        try rig.ask_stop(.cancel, deadline_ms);
        _ = world.agent_step();
        world.switched.call_cost = null;
        _ = world.agent_step();
        const record = (try rig.start_record()) orelse continue;
        const seen = (try rig.observed()) orelse continue;
        if (seen.status != .stopped) continue;
        try testing.expectEqual(record.stop_cause, seen.stop_cause);
        checked += 1;
    }
    try testing.expect(checked > 0);
}

test "an agent with no runs never cuts a call before its fence" {
    // Goal: demo-c1 (PR #150, CI run 42355098100) runs no jobs, so no run's wake may cap a
    // call: the cap is the fence and nothing else, at every moment. Method: no run is assigned;
    // keepalives cost 150 ms of the clock and are cut by the cap the agent sets. Over three
    // lease terms no call is cut, the cap equals the fence at each step, and the lease holds.
    var rig = try Rig.start();
    defer rig.stop();
    const world = rig.world;
    world.switched.keepalive_cost = .{
        .clock = &world.manual,
        .cost_ms = 150,
        .cap_ms = &world.call_cap_ms,
    };
    const lease = world.agent.lease;
    var elapsed: u64 = 0;
    while (elapsed < 24_000) : (elapsed += 250) {
        world.advance(250);
        const mono = world.now_ms();
        try testing.expectEqual(
            world.agent.fence_at_ms() orelse std.math.maxInt(u64),
            world.agent.calls_deadline_ms(mono),
        );
    }
    try testing.expectEqual(@as(u32, 0), world.switched.keepalive_cost.?.cut);
    try testing.expectEqual(@as(u32, 0), world.agent.fences);
    try testing.expectEqual(lease, world.agent.lease);
}
