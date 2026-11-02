//! Tests of the agent's endpoints (`agent_api.zig`) through `Api.handle`, against the simulation
//! world: a real controller, the memory store and a simulated runtime behind them. Bytes in, bytes
//! out, as for `api_test.zig`. The agent in the world is `node1`; the tests register `node2`
//! by hand, so what they write never mixes with what the simulated agent reports.

const std = @import("std");
const testing = std.testing;
const agent_api = @import("agent_api.zig");
const api_mod = @import("api.zig");
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const agent_client = @import("agent_client.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");

const Json = std.json.Value;

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 2,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .env = &.{.{ "API_TOKEN", "s3cr3t" }},
    .applied_by = "alex@laptop",
    .request_id = "r-0000001",
};

const Rig = struct {
    world: *sim_world.World,
    api: api_mod.Api,
    parsed: std.heap.ArenaAllocator,
    /// The tenure `join` made; reports to `/observed` carry it (see `call`).
    tenure: i64 = 0,
    patched: [4096]u8 = undefined,

    fn start(seed: u64) !Rig {
        const fixtures = &sim_runtime.default_fixtures;
        const world = try sim_world.World.create(testing.allocator, seed, fixtures);
        return .{
            .world = world,
            .api = .{
                .version = "0.0.0",
                .backend = "memory",
                .started_at_ms = sim_world.epoch_ms,
            },
            .parsed = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn stop(rig: *Rig) void {
        rig.parsed.deinit();
        rig.world.destroy();
    }

    fn call(
        rig: *Rig,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
    ) api_mod.Response {
        const ctx = rig.world.controller_context();
        return rig.api.handle(&ctx, .{
            .method = method,
            .path = path,
            .query = query,
            .body = rig.with_tenure(method, path, body),
        });
    }

    /// A report to `/observed` names the tenure it rests on; the tests write it once, in `join`.
    fn with_tenure(rig: *Rig, method: []const u8, path: []const u8, body: []const u8) []const u8 {
        const posting = std.mem.eql(u8, method, "POST");
        const reporting = posting and std.mem.endsWith(u8, path, "/observed");
        if (!reporting or rig.tenure == 0 or body.len < 3 or body[0] != '{') return body;
        const format = "{{\"tenure\":{d},{s}";
        return std.fmt.bufPrint(&rig.patched, format, .{ rig.tenure, body[1..] }) catch
            unreachable; // The test bodies are far smaller than the buffer.
    }

    /// Grants a lease, registers `node` on it and keeps the registration's revision as the tenure.
    fn join(rig: *Rig, node: []const u8) !void {
        const lease = try rig.grant(node);
        var buffer: [512]u8 = undefined;
        var path: [96]u8 = undefined;
        const target = try std.fmt.bufPrint(&path, "/v1/agent/nodes/{s}", .{node});
        const registered = try rig.ok("PUT", target, "", try register_text(&buffer, lease));
        rig.tenure = field(registered, "revision").integer;
        std.debug.assert(rig.tenure > 0);
    }

    /// The body parsed, copied out of the world's arena so a later call cannot disturb it.
    fn json(rig: *Rig, response: api_mod.Response) !Json {
        const arena = rig.parsed.allocator();
        const copy = try arena.dupe(u8, response.body);
        return std.json.parseFromSliceLeaky(Json, arena, copy, .{});
    }

    fn ok(
        rig: *Rig,
        method: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
    ) !Json {
        const response = rig.call(method, path, query, body);
        if (response.status != 200) std.debug.print("{s}: {s}\n", .{ path, response.body });
        try testing.expectEqual(@as(u16, 200), response.status);
        return rig.json(response);
    }

    fn refused(rig: *Rig, response: api_mod.Response, status: u16, code: []const u8) !void {
        if (response.status != status) std.debug.print("{s}\n", .{response.body});
        try testing.expectEqual(status, response.status);
        const body = try rig.json(response);
        const first = body.object.get("diagnostics").?.array.items[0];
        try testing.expectEqualStrings(code, first.object.get("code").?.string);
    }

    fn revision(rig: *Rig) !i64 {
        const status = try rig.ok("GET", "/v1/status", "", "");
        return status.object.get("store").?.object.get("revision").?.integer;
    }

    fn grant(rig: *Rig, node: []const u8) !i64 {
        var path: [96]u8 = undefined;
        const lease = try std.fmt.bufPrint(&path, "/v1/agent/nodes/{s}/lease", .{node});
        const granted = try rig.ok("POST", lease, "", "{\"ttl_ms\":10000}");
        return field(granted, "lease").object.get("id").?.integer;
    }
};

fn field(value: Json, name: []const u8) Json {
    return value.object.get(name).?;
}

fn register_text(buffer: []u8, lease: i64) ![]const u8 {
    const format = "{{\"lease\":{d},\"capacity\":{{\"cpu_millis\":4000," ++
        "\"memory_bytes\":8589934592}},\"agent_version\":\"0.0.0\",\"address\":\"10.0.0.5:7070\"}}";
    return std.fmt.bufPrint(buffer, format, .{lease});
}

fn keepalive_path(buffer: []u8, lease: i64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/v1/agent/nodes/node2/lease/{d}/keepalive", .{lease});
}

fn watch_query(buffer: []u8, from: i64, timeout_ms: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "from={d}&timeout={d}", .{ from, timeout_ms });
}

fn observed_text(buffer: []u8, node: []const u8, replica: []const u8) ![]const u8 {
    const format = "{{\"v\":1,\"replica\":\"{s}\",\"node\":\"{s}\",\"generation\":1," ++
        "\"status\":\"running\",\"started_at_ms\":1,\"reported_at_ms\":2}}";
    return std.fmt.bufPrint(buffer, format, .{ replica, node });
}

test "a node takes a lease, registers on it and renews it" {
    // Goal: the three calls the agent core makes to join (lease_grant, the put on /nodes/<node>,
    // lease_keepalive). Method: do them, then read the key and the lease from the store.
    var rig = try Rig.start(1);
    defer rig.stop();
    const lease = try rig.grant("node2");
    try testing.expect(lease > 0);
    var buffer: [512]u8 = undefined;
    const body = try register_text(&buffer, lease);
    const registered = try rig.ok("PUT", "/v1/agent/nodes/node2", "", body);
    try testing.expect(field(registered, "revision").integer > 0);

    const listed = try rig.ok("GET", "/v1/list", "prefix=/nodes/node2", "");
    const kv = field(listed, "kvs").array.items[0];
    try testing.expectEqual(lease, field(kv, "lease").integer);
    const node = field(kv, "value");
    try testing.expectEqualStrings("node2", field(node, "name").string);
    try testing.expectEqual(@as(i64, 4000), field(field(node, "capacity"), "cpu_millis").integer);

    var path: [96]u8 = undefined;
    const keepalive = try keepalive_path(&path, lease);
    const renewed = try rig.ok("POST", keepalive, "", "");
    try testing.expectEqual(lease, field(field(renewed, "lease"), "id").integer);
    try testing.expectEqual(@as(i64, 10000), field(field(renewed, "lease"), "ttl_ms").integer);
}

test "a lease that has ended is ZC-E0205, for a keepalive and for a registration" {
    // Goal: the agent learns its lease is gone from the diagnostic's code. Method: renew and
    // register on a lease the store never granted, and on one that has run out.
    var rig = try Rig.start(2);
    defer rig.stop();
    var buffer: [512]u8 = undefined;
    const unknown = rig.call("POST", "/v1/agent/nodes/node2/lease/9999/keepalive", "", "");
    try rig.refused(unknown, 503, "ZC-E0205");
    const body = try register_text(&buffer, 9999);
    try rig.refused(rig.call("PUT", "/v1/agent/nodes/node2", "", body), 503, "ZC-E0205");

    const lease = try rig.grant("node2");
    rig.world.advance(11_000);
    var path: [96]u8 = undefined;
    const keepalive = try keepalive_path(&path, lease);
    try rig.refused(rig.call("POST", keepalive, "", ""), 503, "ZC-E0205");
}

test "a request the endpoints cannot understand is ZC-E0104 or ZC-E0101 and writes nothing" {
    // Goal: the negative space of the routes and bodies. Method: one malformed request per rule,
    // and check that the store's revision did not move.
    var rig = try Rig.start(3);
    defer rig.stop();
    const before = try rig.revision();
    const base = "/v1/agent/nodes/node2";
    const no_lease = "{\"lease\":0,\"capacity\":{\"cpu_millis\":1,\"memory_bytes\":1}}";
    const no_cpu = "{\"lease\":1,\"capacity\":{\"cpu_millis\":0,\"memory_bytes\":1}}";
    const typo = "{\"lease\":1,\"capacity\":{\"cpu_millis\":1,\"memory_bytes\":1},\"typo\":1}";
    const cases = [_]struct { []const u8, []const u8, []const u8, []const u8, u16, []const u8 }{
        .{ "PUT", "/v1/agent/nodes/Node_2", "", "{}", 400, "ZC-E0104" },
        .{ "PUT", base, "", "", 400, "ZC-E0104" },
        .{ "PUT", base, "", no_lease, 400, "ZC-E0104" },
        .{ "PUT", base, "", no_cpu, 400, "ZC-E0104" },
        .{ "PUT", base, "", typo, 400, "ZC-E0104" },
        .{ "GET", base, "", "", 400, "ZC-E0104" },
        .{ "PUT", base, "x=1", "{}", 400, "ZC-E0104" },
        .{ "POST", base ++ "/lease/x/keepalive", "", "", 400, "ZC-E0104" },
        .{ "POST", base ++ "/lease/0/keepalive", "", "", 400, "ZC-E0104" },
        .{ "POST", base ++ "/lease/1/other", "", "", 404, "ZC-E0101" },
        .{ "GET", base ++ "/bogus", "", "", 404, "ZC-E0101" },
        .{ "GET", base ++ "/replicas/extra", "", "", 404, "ZC-E0101" },
        .{ "GET", "/v1/agent/elsewhere/node2", "", "", 404, "ZC-E0101" },
        .{ "GET", "/v1/agent", "", "", 404, "ZC-E0101" },
    };
    for (cases) |case| {
        const response = rig.call(case[0], case[1], case[2], case[3]);
        rig.refused(response, case[4], case[5]) catch |err| {
            std.debug.print("case: {s} {s}\n", .{ case[0], case[1] });
            return err;
        };
    }
    try testing.expectEqual(before, try rig.revision());
}

test "a node is given its own replicas, with the env values the container needs" {
    // Goal: the desired-state read of docs/api.md. Method: apply a service with a secret, let the
    // simulated agent of node1 settle, then read node1's list (it holds the secret) and node2's
    // (empty), and check that the public list still hides the value.
    var rig = try Rig.start(4);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);

    const mine = try rig.ok("GET", "/v1/agent/nodes/node1/replicas", "", "");
    const kvs = field(mine, "kvs").array.items;
    try testing.expectEqual(@as(usize, 2), kvs.len);
    for (kvs) |kv| {
        const replica = field(kv, "value");
        const pair = field(replica, "env").array.items[0];
        try testing.expectEqualStrings("s3cr3t", pair.array.items[1].string);
        try testing.expect(std.mem.startsWith(u8, field(kv, "key").string, "/replicas/hello/"));
        try testing.expect(field(kv, "mod_revision").integer > 0);
    }
    try testing.expect(field(mine, "revision").integer >= field(kvs[0], "mod_revision").integer);

    const other = try rig.ok("GET", "/v1/agent/nodes/node2/replicas", "", "");
    try testing.expectEqual(@as(usize, 0), field(other, "kvs").array.items.len);

    const public = rig.call("GET", "/v1/list", "prefix=/replicas/", "");
    try testing.expect(std.mem.indexOf(u8, public.body, "s3cr3t") == null);
}

test "observed records are reported, read back, and removed, for the node's own keys only" {
    // Goal: the write path of the agent's reports. Method: put two records (one with a full
    // diagnostic), read them, delete one; then every rule of the validation once.
    var rig = try Rig.start(5);
    defer rig.stop();
    try rig.join("node2");
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    const one = try observed_text(&first, "node2", "hello-1");
    const two = try observed_text(&second, "node2", "hello-2");
    var body: [1024]u8 = undefined;
    const put_both = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}," ++
            "{{\"key\":\"/observed/node2/hello-2\",\"value\":{s}}}]}}",
        .{ one, two },
    );
    const done = try rig.ok("POST", "/v1/agent/nodes/node2/observed", "", put_both);
    try testing.expect(field(done, "revision").integer > 0);

    const listed = try rig.ok("GET", "/v1/agent/nodes/node2/observed", "", "");
    try testing.expectEqual(@as(usize, 2), field(listed, "kvs").array.items.len);
    const key = field(field(listed, "kvs").array.items[0], "key").string;
    try testing.expectEqualStrings("/observed/node2/hello-1", key);

    const drop = "{\"deletes\":[\"/observed/node2/hello-1\"]}";
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/observed", "", drop);
    const after = try rig.ok("GET", "/v1/agent/nodes/node2/observed", "", "");
    try testing.expectEqual(@as(usize, 1), field(after, "kvs").array.items.len);
}

test "an observed record keeps the diagnostic it carries" {
    // Goal: the runtime's diagnostic reaches the store through the agent endpoints unchanged,
    // which is how `zcube why` shows it. Method: put a start_failed record with a diagnostic,
    // read it through the generic list, and compare the code and a cause.
    var rig = try Rig.start(6);
    defer rig.stop();
    try rig.join("node2");
    const record = "{\"v\":1,\"replica\":\"broken-1\",\"node\":\"node2\",\"generation\":1," ++
        "\"status\":\"stopped\",\"exit\":{\"kind\":\"start_failed\"},\"diagnostic\":" ++
        "{\"code\":\"ZBX-E0410\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"no tree with that digest\"," ++
        "\"causes\":[\"digest b3:00ff is not in the store\"]," ++
        "\"while\":[],\"context\":{},\"fixes\":[{\"sentence\":\"check the digest\"}]," ++
        "\"omitted\":{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}},\"reported_at_ms\":2}";
    var body: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/broken-1\",\"value\":{s}}}]}}",
        .{record},
    );
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/observed", "", text);
    const listed = try rig.ok("GET", "/v1/list", "prefix=/observed/node2/", "");
    const value = field(field(listed, "kvs").array.items[0], "value");
    try testing.expectEqualStrings("start_failed", field(field(value, "exit"), "kind").string);
    const diagnostic = field(value, "diagnostic");
    try testing.expectEqualStrings("ZBX-E0410", field(diagnostic, "code").string);
    try testing.expectEqualStrings("no tree with that digest", field(diagnostic, "summary").string);
}

test "a report that is not this node's own, or not one transaction, is refused" {
    // Goal: an agent cannot write another node's keys, nor a key that is not its record's, nor a
    // transaction the store would assert on. Method: one bad report per rule; the revision
    // must not move.
    var rig = try Rig.start(7);
    defer rig.stop();
    try rig.join("node2");
    const before = try rig.revision();
    var record: [256]u8 = undefined;
    const mine = try observed_text(&record, "node2", "hello-1");
    var stranger_buffer: [256]u8 = undefined;
    const stranger = try observed_text(&stranger_buffer, "node3", "hello-1");
    var body: [2048]u8 = undefined;
    const path = "/v1/agent/nodes/node2/observed";

    const wrong_node = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
        .{stranger},
    );
    try rig.refused(rig.call("POST", path, "", wrong_node), 400, "ZC-E0104");
    const wrong_key = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-9\",\"value\":{s}}}]}}",
        .{mine},
    );
    try rig.refused(rig.call("POST", path, "", wrong_key), 400, "ZC-E0104");
    const elsewhere = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/nodes/node2\",\"value\":{s}}}]}}",
        .{mine},
    );
    try rig.refused(rig.call("POST", path, "", elsewhere), 400, "ZC-E0104");
    const twice = "{\"deletes\":[\"/observed/node2/a\",\"/observed/node2/a\"]}";
    try rig.refused(rig.call("POST", path, "", twice), 400, "ZC-E0104");
    const other_node = "{\"deletes\":[\"/observed/node3/a\"]}";
    try rig.refused(rig.call("POST", path, "", other_node), 400, "ZC-E0104");
    const nested = "{\"deletes\":[\"/observed/node2/a/b\"]}";
    try rig.refused(rig.call("POST", path, "", nested), 400, "ZC-E0104");
    try rig.refused(rig.call("POST", path, "", "{}"), 400, "ZC-E0104");
    try rig.refused(rig.call("POST", path, "", "{\"typo\":[]}"), 400, "ZC-E0104");
    try rig.refused(rig.call("POST", path, "x=1", twice), 400, "ZC-E0104");

    // One more operation than a transaction holds.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    try many.appendSlice(testing.allocator, "{\"deletes\":[");
    for (0..constants.agent_report_ops_max + 1) |index| {
        if (index > 0) try many.append(testing.allocator, ',');
        try many.print(testing.allocator, "\"/observed/node2/r-{d}\"", .{index});
    }
    try many.appendSlice(testing.allocator, "]}");
    try rig.refused(rig.call("POST", path, "", many.items), 400, "ZC-E0104");
    try testing.expectEqual(before, try rig.revision());
}

test "the watch says whether an assignment of the node changed, and holds when nothing did" {
    // Goal: the long poll's contract. Method: at the head, nothing changed and the reply may be
    // held; a change of the node's own /assigned/node2/ has changed it at once; an apply (new
    // replicas) and another node's assignment do not count; a revision too far ahead and a
    // compacted one are refused.
    var rig = try Rig.start(8);
    defer rig.stop();
    const base = "/v1/agent/nodes/node2/watch";
    const head = try rig.revision();
    var hold_buffer: [64]u8 = undefined;
    var now_buffer: [64]u8 = undefined;

    const hold_query = try watch_query(&hold_buffer, head + 1, 3000);
    const quiet = rig.call("GET", base, hold_query, "");
    try testing.expectEqual(@as(u16, 200), quiet.status);
    try testing.expectEqual(@as(u32, 3000), quiet.hold_ms);
    try testing.expectEqual(@as(usize, 1), quiet.hold_prefixes.len);
    try testing.expectEqualStrings("/assigned/node2/", quiet.hold_prefixes[0]);
    const idle = try rig.json(quiet);
    try testing.expect(!field(idle, "changed").bool);
    try testing.expectEqual(head, field(idle, "revision").integer);

    // The shell asks again with `hold` false after a hold ended: no second hold.
    const ctx = rig.world.controller_context();
    const again = rig.api.handle(&ctx, .{
        .method = "GET",
        .path = base,
        .query = hold_query,
        .hold = false,
    });
    try testing.expectEqual(@as(u32, 0), again.hold_ms);
    const now_query = try watch_query(&now_buffer, head + 1, 0);
    const nothing = try rig.ok("GET", base, now_query, "");
    try testing.expect(!field(nothing, "changed").bool);

    const lease = try rig.grant("node2");
    var buffer: [512]u8 = undefined;
    _ = try rig.ok("PUT", "/v1/agent/nodes/node2", "", try register_text(&buffer, lease));
    const unrelated = try rig.ok("GET", base, now_query, "");
    try testing.expect(!field(unrelated, "changed").bool);
    try testing.expect(field(unrelated, "revision").integer > head);

    _ = try rig.world.apply(hello);
    rig.world.advance(1000); // The controller creates the replicas.
    // The scheduler places the new replicas on node2, the one node: its assignments changed.
    const placed = try rig.ok("GET", base, hold_query, "");
    try testing.expect(field(placed, "changed").bool);
    const placed_head = try rig.revision();
    var quiet_buffer: [64]u8 = undefined;
    const after_query = try watch_query(&quiet_buffer, placed_head + 1, 3000);
    rig.world.diag.reset();
    const other = records.assigned_key("node3", "hello-1");
    const mine = records.assigned_key("node2", "hello-1");
    const put = [_]store.Op{
        .{ .put = .{ .key = other.slice(), .value = "{}" } },
    };
    _ = try rig.world.store_handle().txn(.{ .on_success = &put }, &rig.world.diag);
    const elsewhere = try rig.ok("GET", base, after_query, "");
    try testing.expect(!field(elsewhere, "changed").bool);
    const put_mine = [_]store.Op{.{ .put = .{ .key = mine.slice(), .value = "{}" } }};
    _ = try rig.world.store_handle().txn(.{ .on_success = &put_mine }, &rig.world.diag);
    const changed = try rig.ok("GET", base, after_query, "");
    try testing.expect(field(changed, "changed").bool);
}

test "the watch refuses a revision too far ahead, a bad query and a compacted revision" {
    // Goal: the long poll's refusals. Method: ask for a revision past the head, for malformed
    // queries, and for a revision below the compaction point.
    var rig = try Rig.start(8);
    defer rig.stop();
    const base = "/v1/agent/nodes/node2/watch";
    var future_buffer: [64]u8 = undefined;
    _ = try rig.world.apply(hello);
    rig.world.advance(1000);
    const future = try std.fmt.bufPrint(&future_buffer, "from={d}", .{(try rig.revision()) + 5});
    try rig.refused(rig.call("GET", base, future, ""), 400, "ZC-E0204");
    try rig.refused(rig.call("GET", base, "", ""), 400, "ZC-E0104");
    try rig.refused(rig.call("GET", base, "from=0", ""), 400, "ZC-E0104");
    try rig.refused(rig.call("GET", base, "from=1&timeout=25001", ""), 400, "ZC-E0104");
    try rig.refused(rig.call("GET", base, "from=1&from=2", ""), 400, "ZC-E0104");
    try rig.refused(rig.call("GET", base, "from=1&prefix=/x", ""), 400, "ZC-E0104");

    rig.world.advance(1000);
    const world_head = try rig.revision();
    rig.world.diag.reset();
    try rig.world.store_handle().compact(@intCast(world_head), &rig.world.diag);
    try rig.refused(rig.call("GET", base, "from=1", ""), 410, "ZC-E0203");
}

test "a report under a tenure that has been replaced is ZC-E0510 and writes nothing" {
    // Goal: I2, an observation from an old tenure is refused. Method: join, join again (a new
    // registration, a new revision), then report under the first tenure and under the second.
    var rig = try Rig.start(8);
    defer rig.stop();
    try rig.join("node2");
    const old = rig.tenure;
    try rig.join("node2");
    try testing.expect(rig.tenure > old);
    var record: [256]u8 = undefined;
    const text = try observed_text(&record, "node2", "hello-1");
    var body: [1024]u8 = undefined;
    const put = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
        .{text},
    );
    const current = rig.tenure;
    rig.tenure = old;
    const before = try rig.revision();
    const response = rig.call("POST", "/v1/agent/nodes/node2/observed", "", put);
    try rig.refused(response, 503, "ZC-E0510");
    try testing.expectEqual(before, try rig.revision());
    rig.tenure = current;
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/observed", "", put);
}

/// The answer's `chain`, checked against the store: `revision` and `hash` are its head now, and
/// `known_hash` is its hash at `known` when one was sent.
fn expect_chain(rig: *Rig, answer: Json, known: ?u64) !void {
    const chain = field(answer, "chain");
    rig.world.diag.reset();
    const handle = rig.world.store_handle();
    const head = try handle.status(&rig.world.diag);
    try testing.expectEqual(@as(i64, @intCast(head.revision)), field(chain, "revision").integer);
    var text: [64]u8 = undefined;
    const hash = try std.fmt.bufPrint(&text, "{x}", .{&head.hash});
    try testing.expectEqualStrings(hash, field(chain, "hash").string);
    const at = known orelse {
        try testing.expect(chain.object.get("known_hash") == null);
        return;
    };
    try testing.expectEqual(true, field(chain, "verified").bool);
    const there = try handle.hash_at(at, &rig.world.diag);
    const expected = try std.fmt.bufPrint(&text, "{x}", .{&there});
    try testing.expectEqualStrings(expected, field(chain, "known_hash").string);
}

test "every agent answer carries the store's chain pair, and its hash at the agent's revision" {
    // Goal: what the agent checks (agent_client.zig, "Nothing from behind") is the store's own
    // pair. Method: call each endpoint without and with `known`, compare `chain` with `status`
    // and `hash_at`; a `known` above the head gets no `known_hash`, and `known` is the only
    // parameter the other endpoints take.
    var rig = try Rig.start(9);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const base = "/v1/agent/nodes/node2";
    const lease = try rig.grant("node2");
    var buffer: [512]u8 = undefined;
    const body = try register_text(&buffer, lease);
    const registered = try rig.ok("PUT", base, "known=1", body);
    try expect_chain(&rig, registered, 1);
    const head: u64 = @intCast(try rig.revision());
    var query_buffer: [64]u8 = undefined;
    const at_head = try std.fmt.bufPrint(&query_buffer, "known={d}", .{head});

    var path: [96]u8 = undefined;
    const renewed = try rig.ok("POST", try keepalive_path(&path, lease), at_head, "");
    try expect_chain(&rig, renewed, head);
    const replicas = try rig.ok("GET", "/v1/agent/nodes/node1/replicas", at_head, "");
    try expect_chain(&rig, replicas, head);
    const observed = try rig.ok("GET", base ++ "/observed", "", "");
    try expect_chain(&rig, observed, null);
    var watch_buffer: [64]u8 = undefined;
    const watch = try std.fmt.bufPrint(&watch_buffer, "from=1&timeout=0&known={d}", .{head});
    try expect_chain(&rig, try rig.ok("GET", base ++ "/watch", watch, ""), head);

    const ahead = try std.fmt.bufPrint(&query_buffer, "known={d}", .{head + 100});
    try expect_chain(&rig, try rig.ok("GET", base ++ "/replicas", ahead, ""), null);
    try rig.refused(rig.call("GET", base ++ "/replicas", "from=1", ""), 400, "ZC-E0104");
    try rig.refused(rig.call("GET", base ++ "/replicas", "known=x", ""), 400, "ZC-E0104");
}

test "known on the lease grant, assigned and observed endpoints, and on a watch above the head" {
    // Goal: the endpoints the first test leaves out take `known` too, and a write's pair is its
    // own transaction's (it equals the head here: nothing else writes between the calls).
    var rig = try Rig.start(10);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    try rig.join("node2"); // A report names the tenure it rests on.
    const base = "/v1/agent/nodes/node2";
    const head: u64 = @intCast(try rig.revision());
    var query_buffer: [64]u8 = undefined;
    const below = try std.fmt.bufPrint(&query_buffer, "known={d}", .{head - 1});
    const granted = try rig.ok("POST", base ++ "/lease", below, "{\"ttl_ms\":10000}");
    try expect_chain(&rig, granted, head - 1);

    var record: [256]u8 = undefined;
    const value = try observed_text(&record, "node2", "hello-1");
    var body: [512]u8 = undefined;
    const put = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
        .{value},
    );
    const reported = try rig.ok("POST", base ++ "/observed", below, put);
    try expect_chain(&rig, reported, head - 1);
    const reported_chain = field(reported, "chain");
    try testing.expectEqual(
        field(reported, "revision").integer,
        field(reported_chain, "revision").integer,
    );
    const listed = try rig.ok("GET", base ++ "/observed", below, "");
    try expect_chain(&rig, listed, head - 1);
    const assigned = try rig.ok("GET", base ++ "/assigned", below, "");
    try expect_chain(&rig, assigned, head - 1);
    try expect_chain(&rig, try rig.ok("GET", base ++ "/assigned", "", ""), null);
    try rig.refused(rig.call("GET", base ++ "/assigned", "from=1", ""), 400, "ZC-E0104");

    // The agent remembers no more than the head it was last told, so a `known` above the head
    // the watch reads first is from another history: no `known_hash`.
    const now: u64 = @intCast(try rig.revision());
    var watch_buffer: [64]u8 = undefined;
    const ahead = try std.fmt.bufPrint(&watch_buffer, "from=1&timeout=0&known={d}", .{now + 1});
    try expect_chain(&rig, try rig.ok("GET", base ++ "/watch", ahead, ""), null);
}

test "a server that keeps no pair for its store says so in every answer" {
    var rig = try Rig.start(11);
    defer rig.stop();
    rig.api.pair_kept = false;
    const answer = try rig.ok("GET", "/v1/agent/nodes/node2/replicas", "known=1", "");
    try testing.expectEqual(false, field(field(answer, "chain"), "verified").bool);
}

/// The world's store with every call but `hash_at`, which has no hash to give: a store migrated
/// from one without a chain, asked below the chain's start.
var no_hash_vtable: store.Store.VTable = undefined;

fn no_hash_at(
    context: *anyopaque,
    revision: store.Revision,
    diag: *diag_mod.Diag,
) store.Error!store.Hash {
    _ = context;
    return failures.no_hash(diag, revision, revision + 1);
}

/// `RemoteStore`'s transport straight into `Api.handle`, over the store without hashes.
const NoHashTransport = struct {
    rig: *Rig,

    fn transport(self: *NoHashTransport) agent_client.Transport {
        return .{ .context = self, .call_fn = call };
    }

    fn call(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: agent_client.Request,
        diag: *diag_mod.Diag,
    ) agent_client.Error!agent_client.Reply {
        _ = diag;
        const self: *NoHashTransport = @ptrCast(@alignCast(context));
        var ctx = self.rig.world.controller_context();
        ctx.store = .{ .context = ctx.store.context, .vtable = &no_hash_vtable };
        const split = std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len;
        const query = if (split < request.target.len) request.target[split + 1 ..] else "";
        const response = self.rig.api.handle(&ctx, .{
            .method = request.method,
            .path = request.target[0..split],
            .query = query,
            .body = request.body,
        });
        // The world's arena is reset by the next call: the reply is the caller's.
        const body = try arena.dupe(u8, response.body);
        return .{ .status = response.status, .body = body };
    }
};

test "a store with no hash at the agent's revision: no known_hash, and the agent refuses it" {
    // Goal: the NoHash branch end to end. Method: the agent's `RemoteStore` over `Api.handle`
    // and the world's store with `hash_at` answering NoHash; the first list remembers a pair, the
    // second sends it as `known`, gets no `known_hash` and is refused as unverifiable.
    var rig = try Rig.start(12);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    no_hash_vtable = rig.world.store_handle().vtable.*;
    no_hash_vtable.hash_at = no_hash_at;
    const head: u64 = @intCast(try rig.revision());
    var query_buffer: [64]u8 = undefined;
    const below = try std.fmt.bufPrint(&query_buffer, "known={d}", .{head - 1});
    var plain = rig.world.controller_context();
    plain.store = .{ .context = plain.store.context, .vtable = &no_hash_vtable };
    const response = rig.api.handle(&plain, .{
        .method = "GET",
        .path = "/v1/agent/nodes/node1/replicas",
        .query = below,
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    const chain = field(try rig.json(response), "chain");
    try testing.expect(chain.object.get("known_hash") == null);

    var through: NoHashTransport = .{ .rig = &rig };
    var remote = agent_client.RemoteStore.init(testing.allocator, through.transport(), "node1");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const options: store.ListOptions = .{ .prefix = records.prefix_replicas, .limit = 100 };
    _ = try remote.interface().list(arena_state.allocator(), options, &diag);
    try testing.expectEqual(head, remote.known.?.revision);
    // A write moves the head on, so the next answer's `known` is below it and needs `hash_at`.
    var other = hello;
    other.name = "other";
    other.request_id = "r-0000002";
    _ = try rig.world.apply(other);
    try testing.expectError(
        error.BackendFailed,
        remote.interface().list(arena_state.allocator(), options, &diag),
    );
    try testing.expectEqual(.E0215, diag.code.?);
    var cause: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &cause,
        "the server has no hash for revision {d}, so it cannot be checked",
        .{head},
    );
    try testing.expectEqualStrings(expected, diag.causes.slice()[0].slice());
    try testing.expectEqual(head, remote.known.?.revision);
}
