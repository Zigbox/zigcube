//! Tests of the agent's runs (docs/agent.md, "Runs") against the simulation world: the claim
//! before the start, the start record, a restart in each phase, the deadline on the monotonic
//! clock, and the cause of a stop. The tests write the server's records (the run, the
//! assignment, the input) themselves, so each pins what the agent does with them.

const std = @import("std");
const testing = std.testing;
const agent_jobs = @import("agent_jobs.zig");
const agent_state = @import("agent_state.zig");
const rt = @import("runtime.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
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
    start_failing: bool = false,
    /// With `start_failing`: the inner runtime starts the container first, as a runtime whose
    /// supervisor is up when a later step fails.
    start_first: bool = false,
    /// How many starts it refused.
    refused: u32 = 0,

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
        return self.inner.vtable.start(self.inner.context, spec, diag);
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
        if (self.failing) {
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
