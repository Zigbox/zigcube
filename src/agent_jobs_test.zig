//! Tests of the agent's runs (docs/agent.md, "Runs") against the simulation world: the claim
//! before the start, the start record, a restart in each phase, the deadline on the monotonic
//! clock, and the cause of a stop. The tests write the server's records (the run, the
//! assignment, the input) themselves, so each pins what the agent does with them.

const std = @import("std");
const testing = std.testing;
const agent_jobs = @import("agent_jobs.zig");
const constants = @import("constants.zig");
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
            .start_by_ms = 1_000_000,
            .created_at_ms = 0,
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

/// The first `ZC-` code in a stored diagnostic's JSON.
fn code_of(text: []const u8) ?[12]u8 {
    const at = std.mem.indexOf(u8, text, "Z") orelse return null;
    var out: [12]u8 = @splat(0);
    const end = std.mem.indexOfScalarPos(u8, text, at, '"') orelse return null;
    @memcpy(out[0..@min(12, end - at)], text[at..][0..@min(12, end - at)]);
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

test "a spec the runtime refuses is rendered with its field and its limit" {
    // Goal: ZC-E0130's cause names the field and the limit it broke, for each problem, and the
    // deadline cause says "killed" only for a SIGKILL.
    const diag_mod = @import("diag.zig");
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
