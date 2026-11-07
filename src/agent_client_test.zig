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
    /// The status every reply carries.
    status: u16 = 200,
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
        return .{ .status = script.status, .body = body };
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

    fn load(rig: *Rig, files: *agent_state.SimState, server: []const u8) !void {
        rig.diag.reset();
        const arena = rig.arena.allocator();
        try rig.remote.load(files.interface(), "/state", server, arena, &rig.diag);
    }

    /// The file does not load: ZC-E0216, and the cause gives `reason`.
    fn expect_unusable(rig: *Rig, files: *agent_state.SimState, reason: []const u8) !void {
        try testing.expectError(error.BackendFailed, rig.load(files, "127.0.0.1:7070"));
        try testing.expectEqual(.E0216, rig.diag.code.?);
        const cause = rig.diag.causes.slice()[0].slice();
        try testing.expect(std.mem.endsWith(u8, cause, reason));
        try testing.expectEqual(null, rig.remote.known);
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
        if (std.mem.eql(u8, fix.command.slice(), "rm '<state dir>/remembered'")) {
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
    try rig.load(&files, "127.0.0.1:7070");
    try testing.expectEqual(null, rig.remote.known);
    _ = try rig.list();
    try rig.remote.save(files.interface(), 0);
    // A host crash after the save loses nothing: put_atomic synced it.
    files.crash_now(.host);
    files.restart();
    var again: Rig = undefined;
    again.init(bodies[1..2]);
    defer again.deinit();
    try again.load(&files, "127.0.0.1:7070");
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
    try damaged.expect_unusable(&files, "it is not what the agent writes");
}

fn read_file(files: *agent_state.SimState, arena: std.mem.Allocator) ![]const u8 {
    return files.interface().read(arena, client.remembered_file);
}

test "a server that keeps no pair: the agent neither refuses nor keeps one, and says so once" {
    // Goal: a memory-store server starts empty with every restart and does not hold that against
    // its store (`"verified": false`); the agent must not either, or a restart bricks it.
    // Method: a pair remembered at 9, then unverified answers at 2 and 1 (a restarted memory
    // store), then a verified one again.
    var b: [3][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 2, "{\"revision\":2,\"hash\":\"" ++ hash_b ++ "\",\"verified\":false}"),
        answer(&b[1], 1, "{\"revision\":1,\"hash\":\"" ++ hash_c ++ "\",\"verified\":false}"),
        answer(&b[2], 3, "{\"revision\":3,\"hash\":\"" ++ hash_c ++ "\",\"verified\":true}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 3);
    defer files.deinit();
    const before = "{\"v\":2,\"server\":\"127.0.0.1:7070\",\"revision\":9,\"hash\":\"" ++
        hash_a ++ "\"}\n";
    try files.interface().put_atomic(client.remembered_file, before);
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    try rig.load(&files, "127.0.0.1:7070");
    try expect_known(&rig, 9, hash_a);
    try testing.expectEqual(null, rig.remote.take_notice());

    try testing.expectEqual(@as(usize, 1), (try rig.list()).kvs.len);
    try testing.expectEqual(null, rig.remote.known);
    try testing.expectEqual(client.Notice.unverified, rig.remote.take_notice().?);
    try rig.remote.save(files.interface(), 0);
    try testing.expectEqualStrings(before, try read_file(&files, rig.arena.allocator()));
    // No `known` is sent any more, nothing is refused, and the news is not repeated.
    _ = try rig.list();
    try testing.expectEqualStrings("/v1/agent/nodes/node1/replicas", rig.script.targets[1]);
    try testing.expectEqual(null, rig.remote.take_notice());
    // A server that keeps its pair again is remembered from its first answer, and saved at once.
    _ = try rig.list();
    try expect_known(&rig, 3, hash_c);
    try rig.remote.save(files.interface(), 1);
    const after = "{\"v\":2,\"server\":\"127.0.0.1:7070\",\"revision\":3,\"hash\":\"" ++
        hash_c ++ "\"}\n";
    try testing.expectEqualStrings(after, try read_file(&files, rig.arena.allocator()));
}

test "a pair saved for another server is not compared; a version 1 file is kept as it is" {
    // Goal: the file names the server it was saved for, so an agent pointed at another server
    // starts fresh instead of refusing it; a file from before the address (version 1) is kept.
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 2, "{\"revision\":2,\"hash\":\"" ++ hash_b ++ "\"}"),
        answer(&b[1], 4, "{\"revision\":4,\"hash\":\"" ++ hash_b ++ "\"}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 4);
    defer files.deinit();
    const old = "{\"v\":2,\"server\":\"10.0.0.1:7070\",\"revision\":9,\"hash\":\"" ++
        hash_a ++ "\"}";
    try files.interface().put_atomic(client.remembered_file, old);
    var rig: Rig = undefined;
    rig.init(bodies[0..1]);
    defer rig.deinit();
    try rig.load(&files, "10.0.0.2:7070");
    try testing.expectEqual(null, rig.remote.known);
    try testing.expectEqual(client.Notice.server_changed, rig.remote.take_notice().?);
    try testing.expectEqualStrings("10.0.0.1:7070", rig.remote.previous_server_name());
    _ = try rig.list();
    try rig.remote.save(files.interface(), 0);
    const saved = try read_file(&files, rig.arena.allocator());
    try testing.expect(std.mem.indexOf(u8, saved, "\"server\":\"10.0.0.2:7070\",\"revision\":2,") !=
        null);

    const v1 = "{\"v\":1,\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}\n";
    try files.interface().put_atomic(client.remembered_file, v1);
    var older: Rig = undefined;
    older.init(bodies[1..2]);
    defer older.deinit();
    try older.load(&files, "10.0.0.2:7070");
    try expect_known(&older, 9, hash_a);
    try testing.expectEqual(null, older.remote.take_notice());
    try older.refused();
}

test "a file version of 0 or not a number is damaged, and only a higher one is newer" {
    var files = agent_state.SimState.init(testing.allocator, 5);
    defer files.deinit();
    const damaged = "it is not what the agent writes";
    const cases = [_]struct { text: []const u8, reason: []const u8 }{
        .{ .text = "{\"v\":0,\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}", .reason = damaged },
        .{
            .text = "{\"v\":\"2\",\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}",
            .reason = damaged,
        },
        .{ .text = "{\"v\":-1,\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}", .reason = damaged },
        .{ .text = "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}", .reason = damaged },
        // Version 2 always names its server, version 1 never does.
        .{ .text = "{\"v\":2,\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}", .reason = damaged },
        .{
            .text = "{\"v\":1,\"server\":\"a\",\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}",
            .reason = damaged,
        },
        .{
            .text = "{\"v\":3,\"other\":true}",
            .reason = "it was written by a newer zcube-agent",
        },
    };
    for (cases) |case| {
        try files.interface().put_atomic(client.remembered_file, case.text);
        var rig: Rig = undefined;
        rig.init(&.{});
        defer rig.deinit();
        try rig.expect_unusable(&files, case.reason);
    }
}

test "the fix line quotes the state directory for the shell" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 6, "{\"revision\":6,\"hash\":\"" ++ hash_b ++ "\"}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 6);
    defer files.deinit();
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    rig.diag.reset();
    const arena = rig.arena.allocator();
    try rig.remote.load(files.interface(), "/var/lib/it's here", "a:1", arena, &rig.diag);
    _ = try rig.list();
    try rig.refused();
    const fixes = rig.diag.fixes.slice();
    const last = fixes[fixes.len - 1].command.slice();
    try testing.expectEqualStrings("rm '/var/lib/it'\\''s here/remembered'", last);
}

test "a clean stop saves the pair whatever the time since the last save" {
    var b: [2][384]u8 = undefined;
    const bodies = [_][]const u8{
        answer(&b[0], 9, "{\"revision\":9,\"hash\":\"" ++ hash_a ++ "\"}"),
        answer(&b[1], 11, "{\"revision\":11,\"hash\":\"" ++ hash_b ++ "\",\"known_hash\":\"" ++
            hash_a ++ "\"}"),
    };
    var files = agent_state.SimState.init(testing.allocator, 7);
    defer files.deinit();
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    try rig.load(&files, "a:1");
    _ = try rig.list();
    try rig.remote.save(files.interface(), 1000);
    _ = try rig.list();
    try rig.remote.save(files.interface(), 1001);
    const throttled = try read_file(&files, rig.arena.allocator());
    try testing.expect(std.mem.indexOf(u8, throttled, "\"revision\":9,") != null);
    try rig.remote.save_final(files.interface(), 1002);
    const final = try read_file(&files, rig.arena.allocator());
    try testing.expect(std.mem.indexOf(u8, final, "\"revision\":11,") != null);
}

const pull_json = "{\"v\":1,\"node\":\"node1\",\"tree\":\"b3:aa\",\"finished_at_ms\":5}";

test "a pull record a server refuses is ZC-E0504, and a foreign one is never sent" {
    // Goal: RemoteStore.pull sends only a put of a pull record under its own key, and a 404 from
    // a server without the endpoint is a coded refusal. Method: a scripted 404, then a delete, a
    // record under another key and a second operation, none of which reach the transport.
    const bodies = [_][]const u8{"{}"};
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    rig.script.status = 404;
    const remote = rig.remote.interface();
    const tenure = [_]store.Compare{.{ .key = "/nodes/node1", .mod_revision = 4 }};
    const put: store.Op = .{ .put = .{ .key = "/pulls/node1/b3:aa", .value = pull_json } };
    try testing.expectError(
        error.BackendFailed,
        remote.txn(.{ .compares = &tenure, .on_success = &.{put} }, &rig.diag),
    );
    try testing.expectEqual(.E0504, rig.diag.code.?);
    try testing.expectEqual(@as(u32, 1), rig.script.next);

    const refusals = [_][]const store.Op{
        &.{.{ .delete = "/pulls/node1/b3:aa" }},
        &.{.{ .put = .{ .key = "/pulls/node1/b3:bb", .value = pull_json } }},
        &.{ put, .{ .put = .{ .key = "/pulls/node1/b3:cc", .value = pull_json } } },
    };
    for (refusals) |ops| {
        rig.diag.reset();
        try testing.expectError(
            error.BackendFailed,
            remote.txn(.{ .compares = &tenure, .on_success = ops }, &rig.diag),
        );
        try testing.expectEqual(.B0001, rig.diag.code.?);
    }
    try testing.expectEqual(@as(u32, 1), rig.script.next);
}

const job_claim_value = "{\"v\":1,\"run\":\"batch-job\",\"status\":\"claimed\"}";

fn job_claim_request(compares: []const store.Compare) store.TxnRequest {
    const put: store.Op = .{ .put = .{
        .key = "/job-observed/node1/batch",
        .value = job_claim_value,
    } };
    return .{ .compares = compares, .on_success = &.{put} };
}

test "a job report is one POST to job-observed, and a claim that did not apply is not a fault" {
    // Goal: the job report mapping. Method: a scripted applied:true, then applied:false, then a
    // refusal of an ended tenure (ZC-E0510); each is a result, not an error, and the target is
    // the job-observed endpoint. A compare the server cannot carry never reaches the transport.
    const bodies = [_][]const u8{
        "{\"revision\":9,\"applied\":true,\"chain\":{\"revision\":9,\"hash\":\"" ++
            hash_a ++ "\"}}",
        "{\"revision\":10,\"applied\":false,\"chain\":{\"revision\":10,\"hash\":\"" ++ hash_b ++
            "\",\"known_hash\":\"" ++ hash_a ++ "\"}}",
    };
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    const remote = rig.remote.interface();
    const compares = [_]store.Compare{
        .{ .key = "/nodes/node1", .mod_revision = 4 },
        .{ .key = "/job-runs/batch", .mod_revision = 6 },
        .{ .key = "/assigned/node1/batch-job", .mod_revision = 7 },
        .{ .key = "/job-observed/node1/batch", .mod_revision = 0 },
    };
    const first = try remote.txn(job_claim_request(&compares), &rig.diag);
    try testing.expect(first.succeeded);
    try testing.expectEqualStrings(
        "/v1/agent/nodes/node1/job-observed",
        rig.script.targets[0],
    );
    const second = try remote.txn(job_claim_request(&compares), &rig.diag);
    try testing.expect(!second.succeeded);

    const stale = [_]store.Compare{.{ .key = "/replicas/a/b", .mod_revision = 1 }};
    rig.diag.reset();
    try testing.expectError(
        error.BackendFailed,
        remote.txn(job_claim_request(&stale), &rig.diag),
    );
    try testing.expectEqual(@as(u32, 2), rig.script.next);
}

test "a job report under an ended tenure comes back as not succeeded" {
    const bodies = [_][]const u8{"{\"diagnostics\":[{\"code\":\"ZC-E0510\"}]}"};
    var rig: Rig = undefined;
    rig.init(&bodies);
    defer rig.deinit();
    rig.script.status = 503;
    const compares = [_]store.Compare{.{ .key = "/nodes/node1", .mod_revision = 4 }};
    const result = try rig.remote.interface().txn(job_claim_request(&compares), &rig.diag);
    try testing.expect(!result.succeeded);
}

test "a damaged input is told from an absent one, and neither is a fault of the link" {
    // Goal: ZC-E0523 over HTTP keeps its two causes. Method: scripted refusals of the input
    // endpoint; the absent one reads as no value, the damaged one as a value that does not decode.
    const prefix = "{\"diagnostics\":[{\"code\":\"ZC-E0523\",\"summary\":\"s\",\"causes\":[\"";
    const absent = prefix ++ "train-job names an input by digest and the server holds none\"]}]}";
    // The literal, not the constant: the phrase is wire protocol, and a reworded constant must
    // fail here and in agent_api_test.zig, not move with the tests.
    try testing.expectEqualStrings("does not match its digest", records.input_mismatch_phrase);
    const damaged = prefix ++ "the input held for train-job does not match its digest\"]}]}";
    const bodies = [_][]const u8{ absent, damaged };
    var rig: Rig = undefined;
    rig.init(&bodies);
    rig.script.status = 404;
    defer rig.deinit();
    const remote = rig.remote.interface();
    const arena = rig.arena.allocator();
    const key = records.job_input_key("train");
    const first = try remote.get(arena, key.slice(), null, &rig.diag);
    try testing.expect(first.kv == null);
    const second = try remote.get(arena, key.slice(), null, &rig.diag);
    const kv = second.kv orelse return error.TestExpectedEqual;
    const decoded = records.read(records.JobInput, arena, kv, &rig.diag);
    try testing.expect(std.meta.isError(decoded));
}

test "a keepalive answered with a ttl the agent cannot fence under is ZC-E0121" {
    // Goal: RemoteStore refuses a short ttl from the server, as `heartbeat` relies on.
    var rig: Rig = undefined;
    const body = "{\"lease\":{\"id\":7,\"ttl_ms\":4000},\"chain\":{\"revision\":5," ++
        "\"hash\":\"" ++ hash_a ++ "\"}}";
    const bodies = [_][]const u8{body};
    rig.init(&bodies);
    defer rig.deinit();
    rig.diag.reset();
    const remote = rig.remote.interface();
    try testing.expectError(error.BackendFailed, remote.lease_keepalive(7, &rig.diag));
    try testing.expectEqual(.E0121, rig.diag.code.?);
}
