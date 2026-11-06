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
        const run = rig.run_record(null, deadline_ms);
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
    try testing.expect(seen.has_diagnostic);
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
