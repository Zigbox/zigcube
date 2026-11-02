//! Tests of the agent's check on the server's answers (`agent_client.zig`, "Nothing from
//! behind"): a scripted transport plays the server, so each answer's `chain` is exactly what the
//! test says, including answers an honest server never gives. The remembered pair goes through
//! `SimState`, the simulation's state directory, so a restart is a new `RemoteStore` over the
//! same files.

const std = @import("std");
const testing = std.testing;
const agent_state = @import("agent_state.zig");
const client = @import("agent_client.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Diag = diag_mod.Diag;

/// A server that answers every request with the next scripted body, and keeps the targets.
const Script = struct {
    bodies: []const []const u8,
    next: u32 = 0,
    targets: [8][]const u8 = undefined,
    target_bytes: [8][128]u8 = undefined,

    fn transport(script: *Script) client.Transport {
        return .{ .context = script, .call_fn = call };
    }

    fn call(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: client.Request,
        diag: *Diag,
    ) client.Error!client.Reply {
        _ = arena;
        _ = diag;
        const script: *Script = @ptrCast(@alignCast(context));
        std.debug.assert(script.next < script.bodies.len);
        const slot = &script.target_bytes[script.next];
        @memcpy(slot[0..request.target.len], request.target);
        script.targets[script.next] = slot[0..request.target.len];
        const body = script.bodies[script.next];
        script.next += 1;
        return .{ .status = 200, .body = body };
    }
};

const hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const hash_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

/// A replica list at `revision` with one record, carrying `chain`.
fn answer(buffer: []u8, revision: u64, chain: []const u8) []const u8 {
    const format = "{{\"revision\":{d},\"kvs\":[{{\"key\":\"/replicas/hello/r1\"," ++
        "\"value\":{{}},\"mod_revision\":{d}}}],\"chain\":{s}}}";
    // The tests' buffers hold the longest answer, two hashes and all.
    return std.fmt.bufPrint(buffer, format, .{ revision, revision, chain }) catch unreachable;
}

const Rig = struct {
    script: Script,
    remote: client.RemoteStore,
    diag: Diag,
    arena: std.heap.ArenaAllocator,

    fn init(rig: *Rig, bodies: []const []const u8) void {
        rig.script = .{ .bodies = bodies };
        rig.remote = client.RemoteStore.init(testing.allocator, rig.script.transport(), "node1");
        rig.diag.reset();
        rig.arena = .init(testing.allocator);
    }

    fn deinit(rig: *Rig) void {
        rig.arena.deinit();
    }

    fn list(rig: *Rig) store.Error!store.ListResult {
        rig.diag.reset();
        return rig.remote.interface().list(rig.arena.allocator(), .{
            .prefix = records.prefix_replicas,
            .limit = 100,
        }, &rig.diag);
    }

    fn refused(rig: *Rig) !void {
        try testing.expectError(error.BackendFailed, rig.list());
        try testing.expectEqual(.E0215, rig.diag.code.?);
    }
};

fn expect_known(rig: *const Rig, revision: u64, hash_text: []const u8) !void {
    var hash: store.Hash = undefined;
    _ = try std.fmt.hexToBytes(&hash, hash_text);
    const known = rig.remote.known.?;
    try testing.expectEqual(revision, known.revision);
    try testing.expectEqualSlices(u8, &hash, &known.hash);
}

test "normal progress advances the pair and sends the remembered revision" {
    var b: [3][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 5, "{\"revision\":5,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 7, "{\"revision\":7,\"hash\":\"" ++ hash_b ++ "\",\"known_hash\":\"" ++
            hash_a ++ "\"}"),
        answer(&b[2], 7, "{\"revision\":7,\"hash\":\"" ++ hash_b ++ "\",\"known_hash\":\"" ++
            hash_b ++ "\"}"),
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    try testing.expectEqual(@as(usize, 1), (try rig.list()).kvs.len);
    try expect_known(&rig, 5, hash_a);
    _ = try rig.list();
    try expect_known(&rig, 7, hash_b);
    _ = try rig.list();
    try expect_known(&rig, 7, hash_b);
    try testing.expectEqualStrings("/v1/agent/nodes/node1/replicas", rig.script.targets[0]);
    try testing.expectEqualStrings("/v1/agent/nodes/node1/replicas?known=5", rig.script.targets[1]);
    try testing.expectEqualStrings("/v1/agent/nodes/node1/replicas?known=7", rig.script.targets[2]);
}

test "an answer at a lower revision is ZC-E0215, returns nothing and leaves the pair" {
    var b: [3][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 6, "{\"revision\":6,\"hash\":\"" ++ hash_b ++ "\"}"),
        // Still refused afterwards: the refusal did not lower what is remembered.
        answer(&b[2], 8, "{\"revision\":8,\"hash\":\"" ++ hash_b ++ "\"}"),
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    _ = try rig.list();
    try rig.refused();
    try testing.expectEqualStrings(
        "the server answered from behind: writes it acknowledged are gone",
        rig.diag.causes.slice()[0].slice(),
    );
    try expect_known(&rig, 9, hash_a);
    try rig.refused();
    try expect_known(&rig, 9, hash_a);
}

test "the same revision with a different hash is ZC-E0215" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 9, "{\"revision\":9,\"hash\":\"" ++ hash_b ++ "\",\"known_hash\":\"" ++
            hash_b ++ "\"}"),
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    _ = try rig.list();
    try rig.refused();
    try expect_known(&rig, 9, hash_a);
}

test "a fork that grew past the remembered revision is ZC-E0215 through known_hash" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 12, "{\"revision\":12,\"hash\":\"" ++ hash_c ++ "\",\"known_hash\":\"" ++
            hash_b ++ "\"}"),
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    _ = try rig.list();
    try rig.refused();
    try expect_known(&rig, 9, hash_a);
    // The fix line tells the operator which file to remove.
    var found = false;
    for (rig.diag.fixes.slice()) |fix| {
        if (std.mem.indexOf(u8, fix.command.slice(), "rm <state dir>/remembered") != null) {
            found = true;
        }
    }
    try testing.expect(found);
}

test "an answer that cannot be checked at the remembered revision is ZC-E0215" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 12, "{\"revision\":12,\"hash\":\"" ++ hash_c ++ "\"}"),
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    _ = try rig.list();
    try rig.refused();
    try expect_known(&rig, 9, hash_a);
}

test "an answer without a chain pair is ZC-E0504" {
    const bodies = [_][]const u8{"{\"revision\":3,\"kvs\":[]}"};
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    try testing.expectError(error.BackendFailed, rig.list());
    try testing.expectEqual(.E0504, rig.diag.code.?);
}

test "the pair survives a restart through the state directory, and an old one loads empty" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 6, "{\"revision\":6,\"hash\":\"" ++ hash_b ++ "\"}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 1);
    defer files.deinit();
    var rig: Rig = undefined;
    rig.init(bodies[0..1]);
    defer rig.deinit();
    // A state directory from before the pair: nothing remembered, and the agent starts.
    try rig.remote.load(files.interface(), "/state", rig.arena.allocator(), &rig.diag);
    try testing.expectEqual(null, rig.remote.known);
    _ = try rig.list();
    try rig.remote.save(files.interface(), 0);
    // A host crash after the save loses nothing: put_atomic synced it.
    files.crash_now(.host);
    files.restart();
    var again: Rig = undefined;
    again.init(bodies[1..2]);
    defer again.deinit();
    try again.remote.load(files.interface(), "/state", again.arena.allocator(), &again.diag);
    try expect_known(&again, 9, hash_a);
    try again.refused();
}

test "saves are throttled, and a damaged file is ZC-E0216" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 11, "{\"revision\":11,\"hash\":\"" ++ hash_b ++ "\",\"known_hash\":\"" ++
            hash_a ++ "\"}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 2);
    defer files.deinit();
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    _ = try rig.list();
    try rig.remote.save(files.interface(), 1000);
    _ = try rig.list();
    try rig.remote.save(files.interface(), 1500);
    const arena = rig.arena.allocator();
    const early = try files.interface().read(arena, client.remembered_file);
    try testing.expect(std.mem.indexOf(u8, early, "\"revision\":9,") != null);
    try rig.remote.save(files.interface(), 2000);
    const later = try files.interface().read(arena, client.remembered_file);
    try testing.expect(std.mem.indexOf(u8, later, "\"revision\":11,") != null);

    try files.interface().put_atomic(client.remembered_file, "{\"v\":1,\"revision\":");
    var damaged: Rig = undefined;
    damaged.init(&.{});
    defer damaged.deinit();
    const loaded = damaged.remote.load(files.interface(), "/state", arena, &damaged.diag);
    try testing.expectError(error.BackendFailed, loaded);
    try testing.expectEqual(.E0216, damaged.diag.code.?);
}
