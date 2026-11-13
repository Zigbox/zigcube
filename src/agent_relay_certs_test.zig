//! `agent_relay_certs.zig` against a scripted server (B4 slice 2): a certificate for the run's key
//! is written, ZC-E0706 marks the run refused and logs why, a certificate for another key is not
//! taken, and a failure to reach the server waits for the retry.

const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const agent_state = @import("agent_state.zig");
const agent_records = @import("agent_records.zig");
const client_mod = @import("agent_client.zig");
const certs = @import("agent_relay_certs.zig");
const relay_tls = @import("relay_tls.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

const container = "relayed-run";
const job = "train-1";

/// Answers every call with `status` and `body`, or `Unreachable` when `status` is 0.
const Script = struct {
    status: u16 = 200,
    body: []const u8 = "",
    calls: u32 = 0,
    target: [128]u8 = undefined,
    target_length: u32 = 0,

    fn transport(script: *Script) client_mod.Transport {
        return .{ .context = script, .call_fn = call };
    }

    fn call(
        context: *anyopaque,
        arena: Allocator,
        request: client_mod.Request,
        diag: *Diag,
    ) client_mod.Error!client_mod.Reply {
        _ = arena;
        const script: *Script = @ptrCast(@alignCast(context));
        script.calls += 1;
        @memcpy(script.target[0..request.target.len], request.target);
        script.target_length = @intCast(request.target.len);
        if (script.status == 0) {
            client_mod.raise_bad_reply(diag, "the scripted server is unreachable");
            return error.Unreachable;
        }
        return .{ .status = script.status, .body = script.body };
    }
};

const Rig = struct {
    sim: agent_state.SimState,
    arena_state: std.heap.ArenaAllocator,
    asker: certs.Asker = .{ .node = "node1" },
    script: Script = .{},
    diag: Diag = undefined,
    key: [32]u8,

    fn init(rig: *Rig) !void {
        rig.* = .{
            .sim = .init(testing.allocator, 1),
            .arena_state = .init(testing.allocator),
            .key = (try Ed25519.KeyPair.generateDeterministic(@splat(0x31))).public_key.toBytes(),
        };
        rig.diag.reset();
        const request: relay_tls.Request = .{
            .key = rig.key,
            .epoch = 42,
            .image_digest = @splat(0x5A),
            .job = job,
        };
        var text: [relay_tls.Request.bytes_max]u8 = undefined;
        try rig.put(agent_records.file_relay_public, request.format(&text));
    }

    fn deinit(rig: *Rig) void {
        rig.arena_state.deinit();
        rig.sim.deinit();
    }

    fn put(rig: *Rig, file: []const u8, data: []const u8) !void {
        var buffer: [agent_state.name_bytes_max]u8 = undefined;
        try rig.sim.interface().put_atomic(agent_records.path(&buffer, container, file), data);
    }

    fn read(rig: *Rig, file: []const u8) ?[]const u8 {
        var buffer: [agent_state.name_bytes_max]u8 = undefined;
        const path = agent_records.path(&buffer, container, file);
        return rig.sim.interface().read(rig.arena_state.allocator(), path) catch null;
    }

    fn step(rig: *Rig, now_ms: u64) certs.Asker.Outcome {
        rig.diag.reset();
        return rig.asker.step(
            rig.sim.interface(),
            rig.script.transport(),
            rig.arena_state.allocator(),
            now_ms,
            1000,
            &rig.diag,
        );
    }

    /// A 200 answer carrying a workload certificate for `key`.
    fn answer(rig: *Rig, key: [32]u8) !void {
        var der: x509.Der = .{};
        var request = x509_test.workload_request(key);
        request.path = .job;
        request.name = job;
        try x509.issue_workload(&der, try x509_test.ca_pair(), &request);
        rig.script.body = try std.fmt.allocPrint(
            rig.arena_state.allocator(),
            "{{\"certificate\":\"{x}\",\"not_before_ms\":1,\"not_after_ms\":2}}",
            .{der.slice()},
        );
    }
};

test "relay certificates: the server's certificate for the run's key is written once" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.answer(rig.key);
    try testing.expectEqual(certs.Asker.Outcome.asked, rig.step(1000));
    try testing.expectEqualStrings(
        "/v1/agent/nodes/node1/runs/" ++ job ++ "/certificate",
        rig.script.target[0..rig.script.target_length],
    );
    const der = rig.read(agent_records.file_relay_certificate) orelse return error.TestFailed;
    var detail: x509.Detail = .{};
    const parsed = try x509.parse_profile(der, .cluster, &detail);
    try testing.expectEqualSlices(u8, &rig.key, parsed.public_key.of(der));
    // Answered: the next pass asks nothing.
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(2000));
    try testing.expectEqual(@as(u32, 1), rig.script.calls);
}

test "relay certificates: ZC-E0706 marks the run refused and logs the server's cause" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.script.status = 409;
    rig.script.body =
        \\{"diagnostics":[{"code":"ZC-E0706","causes":["the run's claim is lost"]}]}
    ;
    try testing.expectEqual(certs.Asker.Outcome.asked, rig.step(1000));
    const expected = "relay: ZC-E0706 zcube-server refused job " ++ job ++
        " a certificate: the run's claim is lost\n";
    const marker = rig.read(agent_records.file_relay_refused) orelse return error.TestFailed;
    try testing.expectEqualStrings(expected, marker);
    const log = rig.read(agent_records.file_relay_log) orelse return error.TestFailed;
    try testing.expectEqualStrings(expected, log);
    try testing.expect(rig.read(agent_records.file_relay_certificate) == null);
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(2000));
    try testing.expectEqual(@as(u32, 1), rig.script.calls);
}

test "relay certificates: a certificate for another key is not taken" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.answer((try Ed25519.KeyPair.generateDeterministic(@splat(0x32))).public_key.toBytes());
    try testing.expectEqual(certs.Asker.Outcome.failed, rig.step(1000));
    try testing.expect(rig.diag.code.? == .E0504);
    try testing.expect(rig.read(agent_records.file_relay_certificate) == null);
    try testing.expect(rig.read(agent_records.file_relay_refused) == null);
}

test "relay certificates: an unreachable server or another refusal waits for the retry" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.script.status = 0;
    try testing.expectEqual(certs.Asker.Outcome.failed, rig.step(1000));
    try testing.expect(rig.diag.code != null);
    // Before the retry time nothing is asked; after it, the next answer is taken.
    const retry = 1000 + constants.peer_join_retry_ms;
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(retry - 1));
    try testing.expectEqual(@as(u32, 1), rig.script.calls);
    rig.script.status = 503;
    rig.script.body =
        \\{"diagnostics":[{"code":"ZC-E0213","causes":["the store is unreachable"]}]}
    ;
    try testing.expectEqual(certs.Asker.Outcome.failed, rig.step(retry));
    try testing.expect(rig.read(agent_records.file_relay_refused) == null);
    rig.script.status = 200;
    try rig.answer(rig.key);
    try testing.expectEqual(certs.Asker.Outcome.asked, rig.step(2 * retry));
    try testing.expect(rig.read(agent_records.file_relay_certificate) != null);
}
