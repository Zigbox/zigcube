//! `agent_relay_certs.zig` against a scripted server (B4 slice 2): a certificate for the run's key
//! is written, ZC-E0706 with 409 marks the run refused and logs why, ZC-E0706 with 503 is asked
//! again, a certificate for another key is not taken, a failure waits for the retry of that
//! container only, a run not yet reported running is not asked for, and a slow server cannot
//! hold the step past its budget.

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
    /// What each call costs the host's budget, as a slow server would.
    cost_ms: u32 = 0,
    host: ?*FakeHost = null,
    /// Calls whose target contains this are unreachable, whatever `status` says.
    fail_target: []const u8 = "",
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
        if (script.host) |host| {
            std.debug.assert(request.timeout_ms.? <= host.left_ms);
            host.left_ms -= @min(host.left_ms, script.cost_ms);
        }
        const failing = script.fail_target.len > 0 and
            std.mem.indexOf(u8, request.target, script.fail_target) != null;
        if (script.status == 0 or failing) {
            client_mod.raise_bad_reply(diag, "the scripted server is unreachable");
            return error.Unreachable;
        }
        return .{ .status = script.status, .body = script.body };
    }
};

/// The agent around the step: a budget each call spends, and the runs known reported running.
const FakeHost = struct {
    left_ms: u32 = constants.relay_cert_step_ms_max,
    reported: bool = true,

    fn host(fake: *FakeHost) certs.Host {
        return .{ .context = fake, .left_fn = left, .reported_fn = reported_fn };
    }

    fn left(context: *anyopaque) u32 {
        const fake: *FakeHost = @ptrCast(@alignCast(context));
        return fake.left_ms;
    }

    fn reported_fn(context: *anyopaque, run: []const u8) bool {
        const fake: *FakeHost = @ptrCast(@alignCast(context));
        std.debug.assert(run.len > 0);
        return fake.reported;
    }
};

const Rig = struct {
    sim: agent_state.SimState,
    arena_state: std.heap.ArenaAllocator,
    asker: certs.Asker = .{ .node = "node1" },
    script: Script = .{},
    fake: FakeHost = .{},
    diag: Diag = undefined,
    key: [32]u8,

    fn init(rig: *Rig) !void {
        rig.* = .{
            .sim = .init(testing.allocator, 1),
            .arena_state = .init(testing.allocator),
            .key = (try Ed25519.KeyPair.generateDeterministic(@splat(0x31))).public_key.toBytes(),
        };
        rig.diag.reset();
        try rig.add(container, job);
    }

    /// A relayed run's container, `name`, whose supervisor wrote its request for `job_name`.
    fn add(rig: *Rig, name: []const u8, job_name: []const u8) !void {
        const request: relay_tls.Request = .{
            .key = rig.key,
            .epoch = 42,
            .image_digest = @splat(0x5A),
            .job = job_name,
        };
        var text: [relay_tls.Request.bytes_max]u8 = undefined;
        var buffer: [agent_state.name_bytes_max]u8 = undefined;
        const path = agent_records.path(&buffer, name, agent_records.file_relay_public);
        try rig.sim.interface().put_atomic(path, request.format(&text));
    }

    fn deinit(rig: *Rig) void {
        rig.arena_state.deinit();
        rig.sim.deinit();
    }

    fn read(rig: *Rig, file: []const u8) ?[]const u8 {
        return rig.read_of(container, file);
    }

    fn read_of(rig: *Rig, name: []const u8, file: []const u8) ?[]const u8 {
        var buffer: [agent_state.name_bytes_max]u8 = undefined;
        const path = agent_records.path(&buffer, name, file);
        return rig.sim.interface().read(rig.arena_state.allocator(), path) catch null;
    }

    fn step(rig: *Rig, now_ms: u64) certs.Asker.Outcome {
        rig.diag.reset();
        return rig.asker.step(
            rig.sim.interface(),
            rig.script.transport(),
            rig.arena_state.allocator(),
            now_ms,
            rig.fake.host(),
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

test "relay certificates: ZC-E0706 with 503 is asked again, not marked refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.script.status = 503;
    rig.script.body =
        \\{"diagnostics":[{"code":"ZC-E0706","causes":["the run has not started"]}]}
    ;
    // Deferred without a word: no failure shown, no marker, no log line.
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(1000));
    try testing.expect(rig.diag.code == null);
    try testing.expect(rig.read(agent_records.file_relay_refused) == null);
    try testing.expect(rig.read(agent_records.file_relay_log) == null);
    const retry = 1000 + constants.peer_join_retry_ms;
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(retry - 1));
    try testing.expectEqual(@as(u32, 1), rig.script.calls);
    rig.script.status = 200;
    try rig.answer(rig.key);
    try testing.expectEqual(certs.Asker.Outcome.asked, rig.step(retry));
    try testing.expect(rig.read(agent_records.file_relay_certificate) != null);
}

test "relay certificates: a run not yet reported running is not asked for" {
    // The request lands before the agent's `running` report: nothing is asked (the server
    // could only defer it); once the report is known, the certificate is asked for and written.
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.answer(rig.key);
    rig.fake.reported = false;
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(1000));
    try testing.expectEqual(@as(u32, 0), rig.script.calls);
    try testing.expect(rig.read(agent_records.file_relay_refused) == null);
    rig.fake.reported = true;
    try testing.expectEqual(certs.Asker.Outcome.asked, rig.step(1001));
    try testing.expect(rig.read(agent_records.file_relay_certificate) != null);
}

test "relay certificates: one container's failure does not hold back another's" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    // Listed first (sorted by name), and unreachable.
    try rig.add("a-broken", "broken-1");
    rig.script.fail_target = "/runs/broken-1/";
    try rig.answer(rig.key);
    try testing.expectEqual(certs.Asker.Outcome.failed, rig.step(1000));
    try testing.expect(rig.diag.code != null);
    try testing.expectEqual(@as(u32, 2), rig.script.calls);
    try testing.expect(rig.read(agent_records.file_relay_certificate) != null);
    try testing.expect(rig.read_of("a-broken", agent_records.file_relay_certificate) == null);
    // The broken one waits for its own retry; the answered one is not asked again.
    try testing.expectEqual(certs.Asker.Outcome.idle, rig.step(1001));
    try testing.expectEqual(@as(u32, 2), rig.script.calls);
    rig.script.fail_target = "";
    try testing.expectEqual(
        certs.Asker.Outcome.asked,
        rig.step(1000 + constants.peer_join_retry_ms),
    );
    try testing.expect(rig.read_of("a-broken", agent_records.file_relay_certificate) != null);
}

test "relay certificates: a slow server cannot hold the step past its budget or cap" {
    // Every call spends a third of the step's budget: at most three asks are made, each given
    // only what is left (Script asserts the timeout fits), and the step stops at 0. With a free
    // server, the cap bounds the asks of one step.
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var index: u32 = 0;
    while (index < constants.relay_cert_asks_per_step_max + 2) : (index += 1) {
        var name_buffer: [32]u8 = undefined;
        var job_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "run-{d:0>2}", .{index});
        const job_name = try std.fmt.bufPrint(&job_buffer, "job-{d:0>2}", .{index});
        try rig.add(name, job_name);
    }
    rig.script.status = 0;
    rig.script.host = &rig.fake;
    rig.script.cost_ms = constants.relay_cert_step_ms_max / 3;
    _ = rig.step(1000);
    try testing.expect(rig.script.calls <= 4);
    try testing.expect(rig.fake.left_ms < rig.script.cost_ms);
    rig.script.calls = 0;
    rig.script.cost_ms = 0;
    rig.fake.left_ms = constants.relay_cert_step_ms_max;
    _ = rig.step(1000 + constants.peer_join_retry_ms);
    try testing.expectEqual(constants.relay_cert_asks_per_step_max, rig.script.calls);
}
