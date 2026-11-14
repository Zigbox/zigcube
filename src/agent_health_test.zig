//! Tests of the agent's health checks (C3 slice 9; docs/agent.md, "Health checks") against the
//! simulation world: a service applied with a check, its replica's container scripted to pass,
//! fail, hang or be refused (`SimRuntime.set_health`), and what the replica's `/observed` record
//! says: the verdict, the failures in a row, the last exit and the diagnostic.

const std = @import("std");
const testing = std.testing;
const codes = @import("diag/codes.zig");
const records = @import("records.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");

const service = "web";

const Seen = struct {
    v: u32,
    status: records.ObservedStatus,
    health: ?records.HealthState,
    health_failures: ?u32,
    last_probe_exit: ?u8,
    /// The stored diagnostic's code, e.g. `ZC-W0502`.
    code: ?[]const u8,
    revision: u64,
};

const Rig = struct {
    world: *sim_world.World,
    replica_buffer: [64]u8 = undefined,
    replica: []const u8 = "",

    fn start(health: ?records.Health) !*Rig {
        const rig = try testing.allocator.create(Rig);
        errdefer testing.allocator.destroy(rig);
        const fixtures = &sim_runtime.default_fixtures;
        const world = try sim_world.World.create(testing.allocator, 9, fixtures);
        errdefer world.destroy();
        rig.* = .{ .world = world };
        world.advance(2_000);
        var id_buffer: [16]u8 = undefined;
        _ = try world.apply(.{
            .name = service,
            .image = sim_runtime.default_fixtures[0],
            .replicas = 1,
            .command = &.{ "serve", "--port", "8080" },
            .applied_by = "alex@laptop",
            .request_id = world.request_id(&id_buffer),
            .health = health,
        });
        world.advance(2_000);
        const name = world.first_running(service, &rig.replica_buffer) orelse
            return error.TestUnexpectedResult;
        rig.replica = name;
        return rig;
    }

    fn stop(rig: *Rig) void {
        rig.world.destroy();
        testing.allocator.destroy(rig);
    }

    fn script(rig: *Rig, health: sim_runtime.HealthScript) !void {
        try rig.world.sim.set_health(rig.replica, health);
    }

    fn seen(rig: *Rig) !Seen {
        const world = rig.world;
        const arena = world.fresh_arena();
        const key = records.observed_key(sim_world.node_name, rig.replica);
        const got = try world.store_handle().get(arena, key.slice(), null, &world.diag);
        const kv = got.kv.?;
        const value = try records.read(records.Observed, arena, kv, &world.diag);
        return .{
            .v = value.v,
            .status = value.status,
            .health = value.health,
            .health_failures = value.health_failures,
            .last_probe_exit = value.last_probe_exit,
            .code = if (value.diagnostic) |raw| try code_of(arena, raw.text) else null,
            .revision = kv.mod_revision,
        };
    }
};

fn code_of(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const Shape = struct { code: []const u8 };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = try std.json.parseFromSliceLeaky(Shape, arena, text, options);
    return parsed.code;
}

fn check(failure_threshold: u32, success_threshold: u32, start_period_ms: u32) records.Health {
    return .{
        .command = &.{ "curl", "-f", "http://localhost:8080/health" },
        .interval_ms = 1_000,
        .timeout_ms = 500,
        .start_period_ms = start_period_ms,
        .failure_threshold = failure_threshold,
        .success_threshold = success_threshold,
    };
}

test "agent health: a passing check is healthy, failures in a row make it unhealthy" {
    const rig = try Rig.start(check(3, 2, 0));
    defer rig.stop();
    var seen = try rig.seen();
    try testing.expectEqual(@as(u32, 3), seen.v);
    try testing.expectEqual(records.ObservedStatus.running, seen.status);
    try testing.expectEqual(records.HealthState.healthy, seen.health.?);
    try testing.expectEqual(@as(?u8, 0), seen.last_probe_exit);
    try testing.expectEqual(@as(?u32, 0), seen.health_failures);
    try testing.expect(seen.code == null);
    // Written on change only: more passes write nothing.
    rig.world.advance(5_000);
    try testing.expectEqual(seen.revision, (try rig.seen()).revision);

    try rig.script(.unhealthy);
    rig.world.advance(1_800);
    try testing.expectEqual(records.HealthState.healthy, (try rig.seen()).health.?);
    rig.world.advance(1_000);
    seen = try rig.seen();
    try testing.expectEqual(records.HealthState.unhealthy, seen.health.?);
    try testing.expectEqual(@as(?u32, 3), seen.health_failures);
    try testing.expectEqual(@as(?u8, 1), seen.last_probe_exit);
    try testing.expectEqual(records.ObservedStatus.running, seen.status);
    const unhealthy_at = seen.revision;
    rig.world.advance(5_000);
    try testing.expectEqual(unhealthy_at, (try rig.seen()).revision);

    // Two passes in a row (success_threshold) to be healthy again.
    try rig.script(.healthy);
    rig.world.advance(1_000);
    try testing.expectEqual(records.HealthState.unhealthy, (try rig.seen()).health.?);
    rig.world.advance(1_200);
    seen = try rig.seen();
    try testing.expectEqual(records.HealthState.healthy, seen.health.?);
    try testing.expectEqual(@as(?u32, 0), seen.health_failures);
}

test "agent health: a check that hangs times out (ZC-W0502), one refused is ZC-E0516" {
    const rig = try Rig.start(check(2, 1, 0));
    defer rig.stop();
    try testing.expectEqual(records.HealthState.healthy, (try rig.seen()).health.?);
    try rig.script(.hangs);
    rig.world.advance(3_000);
    var seen = try rig.seen();
    try testing.expectEqual(records.HealthState.unhealthy, seen.health.?);
    try testing.expectEqualStrings(codes.full_name(.W0502), seen.code.?);
    // A timed-out check has no exit: the last exit stays the last pass's.
    try testing.expectEqual(@as(?u8, 0), seen.last_probe_exit);

    try rig.script(.refuses);
    rig.world.advance(3_000);
    seen = try rig.seen();
    // A refused check counts as neither: the verdict stands.
    try testing.expectEqual(records.HealthState.unhealthy, seen.health.?);
    try testing.expectEqualStrings(codes.full_name(.E0516), seen.code.?);
    try testing.expectEqual(records.ObservedStatus.running, seen.status);

    try rig.script(.healthy);
    rig.world.advance(2_000);
    seen = try rig.seen();
    try testing.expectEqual(records.HealthState.healthy, seen.health.?);
    try testing.expect(seen.code == null);
}

test "agent health: failures in the start period are not counted" {
    // The container started about 2 s ago, and its first check passed; the start period is 6 s.
    const rig = try Rig.start(check(1, 1, 6_000));
    defer rig.stop();
    try testing.expectEqual(records.HealthState.healthy, (try rig.seen()).health.?);
    try rig.script(.unhealthy);
    rig.world.advance(2_000);
    var seen = try rig.seen();
    // Failed checks inside the start period: not counted, and the pass does not end it early.
    try testing.expectEqual(records.HealthState.healthy, seen.health.?);
    try testing.expectEqual(@as(?u32, 0), seen.health_failures);
    rig.world.advance(4_000);
    seen = try rig.seen();
    try testing.expectEqual(records.HealthState.unhealthy, seen.health.?);
    try testing.expectEqual(@as(?u32, 1), seen.health_failures);
}

test "agent health: a restarted agent reports unknown until the checks run again" {
    const rig = try Rig.start(check(1, 1, 0));
    defer rig.stop();
    try testing.expectEqual(records.HealthState.healthy, (try rig.seen()).health.?);
    const world = rig.world;
    world.restart_agent();
    // The steps that adopt the container write `unknown` before its first check has ended.
    var unknown_seen = false;
    var step: u32 = 0;
    while (step < 40) : (step += 1) {
        world.advance(sim_world.tick_ms);
        const seen = try rig.seen();
        if (seen.health.? == .unknown) unknown_seen = true;
        if (unknown_seen and seen.health.? == .healthy) break;
    }
    try testing.expect(unknown_seen);
    try testing.expectEqual(records.HealthState.healthy, (try rig.seen()).health.?);
}

test "agent health: a replica without a check is written at version 2, with no health" {
    const rig = try Rig.start(null);
    defer rig.stop();
    rig.world.advance(3_000);
    const seen = try rig.seen();
    try testing.expectEqual(@as(u32, 2), seen.v);
    try testing.expect(seen.health == null);
    try testing.expect(seen.health_failures == null);
    try testing.expect(seen.last_probe_exit == null);
}
