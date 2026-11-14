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
const Diag = @import("diag.zig").Diag;
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
    /// The lease `join` registered on.
    lease: i64 = 0,
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
            .caller = .local,
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
        rig.lease = lease;
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

/// A running report that names `tenure`, as the agent stamps its records.
fn observed_text(
    buffer: []u8,
    node: []const u8,
    replica: []const u8,
    tenure: i64,
) ![]const u8 {
    const format = "{{\"v\":1,\"replica\":\"{s}\",\"node\":\"{s}\",\"generation\":1," ++
        "\"status\":\"running\",\"started_at_ms\":1,\"reported_at_ms\":2," ++
        "\"tenure\":{d}}}";
    return std.fmt.bufPrint(buffer, format, .{ replica, node, tenure });
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

test "a node may not renew or register on the lease of another node's registration (B7)" {
    // Goal: a node certificate keeps its own node alive and no other. Method: node1 registers on
    // its lease; node2 renews that lease (ZC-E0205: node2 is not registered on it) and registers
    // on it (ZC-E0104); node1 renews it and registers on it again.
    var rig = try Rig.start(3);
    defer rig.stop();
    const lease = try rig.grant("node1");
    var buffer: [512]u8 = undefined;
    const body = try register_text(&buffer, lease);
    _ = try rig.ok("PUT", "/v1/agent/nodes/node1", "", body);
    var path: [96]u8 = undefined;
    const theirs = try keepalive_path(&path, lease); // Node2's path.
    try rig.refused(rig.call("POST", theirs, "", ""), 503, "ZC-E0205");
    try rig.refused(rig.call("PUT", "/v1/agent/nodes/node2", "", body), 400, "ZC-E0104");
    const own = try std.fmt.bufPrint(&path, "/v1/agent/nodes/node1/lease/{d}/keepalive", .{lease});
    _ = try rig.ok("POST", own, "", "");
    _ = try rig.ok("PUT", "/v1/agent/nodes/node1", "", body);
    const listed = try rig.ok("GET", "/v1/list", "prefix=/nodes/", "");
    try testing.expectEqual(@as(usize, 1), field(listed, "kvs").array.items.len);
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
    const one = try observed_text(&first, "node2", "hello-1", rig.tenure);
    const two = try observed_text(&second, "node2", "hello-2", rig.tenure);
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
    const rest = "\"status\":\"stopped\",\"exit\":{\"kind\":\"start_failed\"},\"diagnostic\":" ++
        "{\"code\":\"ZBX-E0410\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"no tree with that digest\"," ++
        "\"causes\":[\"digest b3:00ff is not in the store\"]," ++
        "\"while\":[],\"context\":{},\"fixes\":[{\"sentence\":\"check the digest\"}]," ++
        "\"omitted\":{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}},\"reported_at_ms\":2}";
    var record_buffer: [768]u8 = undefined;
    const record = try std.fmt.bufPrint(&record_buffer, "{{\"v\":1,\"replica\":\"broken-1\"," ++
        "\"node\":\"node2\",\"generation\":1,\"tenure\":{d},{s}", .{ rig.tenure, rest });
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
    const mine = try observed_text(&record, "node2", "hello-1", rig.tenure);
    var stranger_buffer: [256]u8 = undefined;
    const stranger = try observed_text(&stranger_buffer, "node3", "hello-1", rig.tenure);
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
    // `refused` is a job's exit kind only (B5); a replica never ends refused.
    var refused_buffer: [384]u8 = undefined;
    const refused = try std.fmt.bufPrint(&refused_buffer, "{{\"v\":2,\"replica\":\"hello-1\"," ++
        "\"node\":\"node2\",\"generation\":1,\"tenure\":{d},\"status\":\"stopped\"," ++
        "\"exit\":{{\"kind\":\"refused\"}},\"reported_at_ms\":2}}", .{rig.tenure});
    const refused_put = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
        .{refused},
    );
    try rig.refused(rig.call("POST", path, "", refused_put), 400, "ZC-E0104");
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

test "a report whose record does not name the request's tenure is refused" {
    // Goal: a record with no tenure would read as C0 and bypass the controller's admissibility
    // gate (authority.md section 3). Method: a record without one, and one with another tenure.
    var rig = try Rig.start(7);
    defer rig.stop();
    try rig.join("node2");
    const before = try rig.revision();
    var body: [2048]u8 = undefined;
    const path = "/v1/agent/nodes/node2/observed";
    var bare_buffer: [256]u8 = undefined;
    const bare = try std.fmt.bufPrint(&bare_buffer, "{{\"v\":1,\"replica\":\"hello-1\"," ++
        "\"node\":\"node2\",\"generation\":1,\"status\":\"running\"," ++
        "\"started_at_ms\":1,\"reported_at_ms\":2}}", .{});
    var other_buffer: [256]u8 = undefined;
    const other = try observed_text(&other_buffer, "node2", "hello-1", rig.tenure + 1);
    for ([_][]const u8{ bare, other }) |value| {
        const wrong_tenure = try std.fmt.bufPrint(
            &body,
            "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
            .{value},
        );
        try rig.refused(rig.call("POST", path, "", wrong_tenure), 400, "ZC-E0104");
    }
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
        .caller = .local,
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
    const text = try observed_text(&record, "node2", "hello-1", old);
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
    var fresh: [256]u8 = undefined;
    const current_text = try observed_text(&fresh, "node2", "hello-1", current);
    const put_current = try std.fmt.bufPrint(
        &body,
        "{{\"puts\":[{{\"key\":\"/observed/node2/hello-1\",\"value\":{s}}}]}}",
        .{current_text},
    );
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/observed", "", put_current);
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
    const value = try observed_text(&record, "node2", "hello-1", rig.tenure);
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
            .caller = .local,
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
        .caller = .local,
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

// ---- PUT /v1/agent/nodes/{node}/store ---------------------------------------------------------

const store_path = "/v1/agent/nodes/node2/store";

/// A summary request body: `summary` is the record's JSON.
fn summary_text(rig: *const Rig, lease: i64, summary: []const u8) ![]u8 {
    const format = "{{\"tenure\":{d},\"lease\":{d},\"summary\":{s}}}";
    return std.fmt.allocPrint(testing.allocator, format, .{ rig.tenure, lease, summary });
}

const small_summary =
    \\{"v":1,"node":"node2","trees":[{"tree":"b3:51aa9c03","bytes":10,"chunks":1,
    \\"sample":"010000000000000000900100"}],"filter":"ab","filter_chunks":1}
;

fn refuse_summary(rig: *Rig, body: []const u8, status: u16, code: []const u8) !void {
    const before = try rig.revision();
    try rig.refused(rig.call("PUT", store_path, "", body), status, code);
    try testing.expectEqual(before, try rig.revision());
}

test "a summary is stored on the node's registration lease, and unknown fields are ignored" {
    // Goal: the happy path and the tolerance of finding 2 (a newer agent's extra members must not
    // be a 400). Method: join, put a summary with unknown members at both levels, read the key.
    var rig = try Rig.start(21);
    defer rig.stop();
    try rig.join("node2");
    const body = try summary_text(&rig, rig.lease, small_summary);
    defer testing.allocator.free(body);
    const gpa = testing.allocator;
    const extra = try std.mem.replaceOwned(
        u8,
        gpa,
        body,
        "\"filter_chunks\":1",
        "\"filter_chunks\":1,\"later\":[1]",
    );
    defer testing.allocator.free(extra);
    _ = try rig.ok("PUT", store_path, "", extra);
    const ctx = rig.world.controller_context();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const got = try ctx.store.get(ctx.arena, records.node_store_key("node2").slice(), null, &diag);
    try testing.expectEqual(@as(store.LeaseId, @intCast(rig.lease)), got.kv.?.lease);
}

test "a summary of a newer version, for another node, or with a bad lease is ZC-E0104" {
    // Goal: finding 1's endpoint rule, 4 and 5. Method: each wrong body is refused with a coded
    // 400 and writes nothing; lease 0 and another node's lease are both refused.
    var rig = try Rig.start(22);
    defer rig.stop();
    try rig.join("node2");
    const other = try rig.grant("node3");
    const newer = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        small_summary,
        "\"v\":1",
        "\"v\":2",
    );
    defer testing.allocator.free(newer);
    const elsewhere = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        small_summary,
        "node2",
        "node9",
    );
    defer testing.allocator.free(elsewhere);
    const cases = [_]struct { lease: i64, text: []const u8 }{
        .{ .lease = rig.lease, .text = newer },
        .{ .lease = rig.lease, .text = elsewhere },
        .{ .lease = 0, .text = small_summary },
        .{ .lease = other, .text = small_summary },
    };
    for (cases) |case| {
        const body = try summary_text(&rig, case.lease, case.text);
        defer testing.allocator.free(body);
        try refuse_summary(&rig, body, 400, "ZC-E0104");
    }
}

test "a summary under an ended tenure is ZC-E0510, and one with too many trees is ZC-E0104" {
    // Goal: finding 5. Method: join twice and write under the first tenure; then 33 trees.
    var rig = try Rig.start(23);
    defer rig.stop();
    try rig.join("node2");
    const old = rig.tenure;
    const old_lease = rig.lease;
    try rig.join("node2");
    rig.tenure = old;
    const stale = try summary_text(&rig, old_lease, small_summary);
    defer testing.allocator.free(stale);
    try refuse_summary(&rig, stale, 503, "ZC-E0510");
    try rig.join("node2");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "{\"v\":1,\"node\":\"node2\",\"trees\":[");
    for (0..constants.summary_trees_max + 1) |index| {
        if (index > 0) try text.append(testing.allocator, ',');
        try text.print(
            testing.allocator,
            "{{\"tree\":\"t{d}\",\"bytes\":1,\"chunks\":0}}",
            .{index},
        );
    }
    try text.appendSlice(testing.allocator, "]}");
    const many = try summary_text(&rig, rig.lease, text.items);
    defer testing.allocator.free(many);
    try refuse_summary(&rig, many, 400, "ZC-E0104");
}

test "the largest summary fits the endpoint, and a body past its cap is refused" {
    // Goal: finding 3, the bound can be reached. Method: a full Bloom filter and 32 full trees
    // as hex make a body over the 64 KiB of any other agent request and under the store's value
    // limit; it is stored. A body one byte past the cap is a 400 that writes nothing.
    var rig = try Rig.start(24);
    defer rig.stop();
    try rig.join("node2");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "{\"v\":1,\"node\":\"node2\",\"filter\":\"");
    try text.appendNTimes(testing.allocator, 'a', constants.summary_filter_bytes_max * 2);
    try text.appendSlice(testing.allocator, "\",\"filter_chunks\":65536,\"trees\":[");
    const sample_digits = constants.summary_sketch_keys * constants.summary_sketch_entry_bytes * 2;
    for (0..constants.summary_trees_max) |index| {
        if (index > 0) try text.append(testing.allocator, ',');
        try text.print(
            testing.allocator,
            "{{\"tree\":\"sha256:{x:0>64}\",\"bytes\":99,\"chunks\":64,\"sample\":\"",
            .{index},
        );
        try text.appendNTimes(testing.allocator, 'b', sample_digits);
        try text.appendSlice(testing.allocator, "\"}");
    }
    try text.appendSlice(testing.allocator, "]}");
    const full = try summary_text(&rig, rig.lease, text.items);
    defer testing.allocator.free(full);
    try testing.expect(full.len > constants.agent_request_bytes_max);
    try testing.expect(full.len <= constants.summary_request_bytes_max);
    _ = try rig.ok("PUT", store_path, "", full);
    const ctx = rig.world.controller_context();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const got = try ctx.store.get(ctx.arena, records.node_store_key("node2").slice(), null, &diag);
    try testing.expect(got.kv.?.value.len <= constants.store_value_bytes_max);
    const huge = try testing.allocator.alloc(u8, constants.summary_request_bytes_max + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    try refuse_summary(&rig, huge, 400, "ZC-E0104");
    try testing.expectEqual(
        constants.summary_request_bytes_max,
        agent_api.body_bytes_max(store_path),
    );
    try testing.expectEqual(
        constants.agent_request_bytes_max,
        agent_api.body_bytes_max("/v1/agent/nodes/node2/observed"),
    );
}

// ---- POST /v1/agent/nodes/{node}/pulls --------------------------------------------------------

const pulls_path = "/v1/agent/nodes/node2/pulls";

fn pull_text(rig: *const Rig, record: []const u8) ![]u8 {
    const format = "{{\"tenure\":{d},\"pull\":{s}}}";
    return std.fmt.allocPrint(testing.allocator, format, .{ rig.tenure, record });
}

const small_pull =
    \\{"v":1,"node":"node2","tree":"b3:51aa9c03","registry_bytes":10,
    \\"peer_bytes":[{"peer":"node1","bytes":5}],"cached_bytes":1,
    \\"started_at_ms":100,"finished_at_ms":160,"bad_peers":["node3"],"later":true}
;

test "a pull record is stored under the node's key, replaced by a later pull of the tree" {
    // Goal: the endpoint's happy path, unknown members ignored. Method: join, post a record,
    // read the key; post the same tree again with other numbers and read the replacement.
    var rig = try Rig.start(31);
    defer rig.stop();
    try rig.join("node2");
    const body = try pull_text(&rig, small_pull);
    defer testing.allocator.free(body);
    _ = try rig.ok("POST", pulls_path, "", body);
    const ctx = rig.world.controller_context();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const key = records.pull_key("node2", "b3:51aa9c03");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &diag);
    const first = try records.read(records.Pull, ctx.arena, got.kv.?, &diag);
    try testing.expectEqual(@as(u64, 10), first.registry_bytes);
    try testing.expectEqualStrings("node1", first.peer_bytes[0].peer);
    try testing.expectEqualStrings("node3", first.bad_peers[0]);
    const again = try std.mem.replaceOwned(u8, testing.allocator, body, ":10,", ":99,");
    defer testing.allocator.free(again);
    _ = try rig.ok("POST", pulls_path, "", again);
    const replaced = try ctx.store.get(ctx.arena, key.slice(), null, &diag);
    const second = try records.read(records.Pull, ctx.arena, replaced.kv.?, &diag);
    try testing.expectEqual(@as(u64, 99), second.registry_bytes);
}

test "a pull of another node, version, tree, peer name or too many peers is ZC-E0104" {
    // Goal: the endpoint's checks. Method: each wrong record is refused with a coded 400 and
    // writes nothing.
    var rig = try Rig.start(32);
    defer rig.stop();
    try rig.join("node2");
    const gpa = testing.allocator;
    const swaps = [_][2][]const u8{
        .{ "\"v\":1", "\"v\":2" },
        .{ "\"node\":\"node2\"", "\"node\":\"node9\"" },
        .{ "b3:51aa9c03", "" },
        .{ "b3:51aa9c03", "b3:51aa\\u0000" },
        // A peer name that is not a node name could carry terminal control bytes (ESC, here).
        .{ "\"peer\":\"node1\"", "\"peer\":\"node1\\u001b[2J\"" },
        .{ "\"node3\"", "\"Node3\"" },
        .{ "\"node3\"", "\"\\u001b]0;x\\u0007\"" },
    };
    for (swaps) |swap| {
        const record = try std.mem.replaceOwned(u8, gpa, small_pull, swap[0], swap[1]);
        defer gpa.free(record);
        const body = try pull_text(&rig, record);
        defer gpa.free(body);
        const before = try rig.revision();
        try rig.refused(rig.call("POST", pulls_path, "", body), 400, "ZC-E0104");
        try testing.expectEqual(before, try rig.revision());
    }
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(gpa);
    const head = "{\"v\":1,\"node\":\"node2\",\"tree\":\"b3:51aa9c03\",\"bad_peers\":[";
    try many.appendSlice(gpa, head);
    for (0..constants.pull_peers_max + 1) |index| {
        if (index > 0) try many.append(gpa, ',');
        try many.print(gpa, "\"n{d}\"", .{index});
    }
    try many.appendSlice(gpa, "]}");
    const body = try pull_text(&rig, many.items);
    defer gpa.free(body);
    try rig.refused(rig.call("POST", pulls_path, "", body), 400, "ZC-E0104");
    const wrong_method = rig.call("GET", pulls_path, "", "");
    try testing.expect(wrong_method.status != 200);
}

test "a pull under a tenure that has been replaced is ZC-E0510 and writes nothing" {
    // Goal: statistics are written by the node that holds the tenure, as every agent write.
    var rig = try Rig.start(33);
    defer rig.stop();
    try rig.join("node2");
    const old = rig.tenure;
    try rig.join("node2");
    rig.tenure = old;
    const body = try pull_text(&rig, small_pull);
    defer testing.allocator.free(body);
    const before = try rig.revision();
    try rig.refused(rig.call("POST", pulls_path, "", body), 503, "ZC-E0510");
    try testing.expectEqual(before, try rig.revision());
}

// ---- Runs (B1 slice 4) ----

/// Writes `value` at `key` as `role`, and returns the revision it got.
fn put_as(rig: *Rig, role: @import("writers.zig").Role, key: []const u8, value: anytype) !u64 {
    const world = rig.world;
    const arena = world.fresh_arena();
    const bytes = try records.encode(arena, value, &world.diag);
    const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
    const done = try @import("writers.zig").txn(
        world.store_handle(),
        role,
        .{ .on_success = &.{op} },
        &world.diag,
    );
    try testing.expect(done.succeeded);
    return done.revision;
}

const run_fixture: records.JobRun = .{
    .id = "train-job",
    .job = "train",
    .image = "b3:51aa9c03",
    .command = &.{"true"},
    .deadline_ms = 60_000,
    .start_by_ms = 1_000_000,
    .created_at_ms = 0,
};

/// A run of job `train` assigned to node2; returns the run's and the assignment's revisions.
fn assign_run(rig: *Rig) ![2]u64 {
    const run_revision = try put_as(
        rig,
        .job_controller,
        records.job_run_key("train").slice(),
        run_fixture,
    );
    const assigned: records.Assigned = .{
        .replica = "train-job",
        .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        .reason = "test",
        .job = "train",
    };
    const key = records.assigned_key("node2", "train-job");
    const epoch = try put_as(rig, .scheduler, key.slice(), assigned);
    return .{ run_revision, epoch };
}

fn claim_text(buffer: []u8, tenure: i64, run_revision: u64, epoch: u64) ![]const u8 {
    const format = "{{\"tenure\":{d},\"run_revision\":{d},\"value\":{{\"v\":1," ++
        "\"run\":\"train-job\",\"node\":\"node2\",\"tenure\":{d},\"assignment\":{d}," ++
        "\"status\":\"claimed\",\"reported_at_ms\":2}}}}";
    return std.fmt.bufPrint(buffer, format, .{ tenure, run_revision, tenure, epoch });
}

test "the runs of a node are listed, and a run's input is given only after its claim" {
    // Goal: the input is the one thing a node may not read before it claims the run.
    var rig = try Rig.start(21);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    _ = try put_as(&rig, .api, records.job_input_key("train").slice(), records.JobInput{
        .base64 = "aGVsbG8=",
    });
    const listed = try rig.ok("GET", "/v1/agent/nodes/node2/runs", "", "");
    try testing.expectEqual(@as(usize, 1), field(listed, "kvs").array.items.len);

    const early = rig.call("GET", "/v1/agent/nodes/node2/runs/train/input", "", "");
    try rig.refused(early, early.status, "ZC-E0133");
    try testing.expect(early.status != 200);

    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    const claimed = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try testing.expect(field(claimed, "applied").bool);
    const given = try rig.ok("GET", "/v1/agent/nodes/node2/runs/train/input", "", "");
    try testing.expectEqualStrings("aGVsbG8=", field(field(given, "input"), "base64").string);

    // Another node never gets it.
    try rig.join("node3");
    const other = rig.call("GET", "/v1/agent/nodes/node3/runs/train/input", "", "");
    try testing.expect(other.status != 200);
}

/// Records the revision every `get` of a request asked for.
const GetSpy = struct {
    var original: *const store.Store.VTable = undefined;
    var seen: [8]?store.Revision = @splat(0);
    var count: usize = 0;

    fn get(
        context: *anyopaque,
        arena: std.mem.Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        seen[count] = at_revision;
        count += 1;
        return original.get(context, arena, key, at_revision, diag);
    }
};

test "a run's input is read at one revision" {
    // Goal: RA-N3. The assignment, the claim and the input are three keys of one decision, so the
    // handler reads them at the same revision. Method: spy on the revision each get asks for.
    var rig = try Rig.start(22);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    _ = try put_as(&rig, .api, records.job_input_key("train").slice(), records.JobInput{
        .base64 = "aGVsbG8=",
    });
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);

    var ctx = rig.world.controller_context();
    var vtable = ctx.store.vtable.*;
    GetSpy.original = ctx.store.vtable;
    GetSpy.count = 0;
    vtable.get = GetSpy.get;
    ctx.store.vtable = &vtable;
    const response = rig.api.handle(&ctx, .{
        .caller = .local,
        .method = "GET",
        .path = "/v1/agent/nodes/node2/runs/train/input",
        .query = "",
        .body = "",
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    var gets: usize = 0;
    for (GetSpy.seen[0..GetSpy.count]) |at| {
        // The input, claim and assignment gets are the ones with a revision; any other read the
        // handler makes (the chain) is not part of the three.
        if (at == null) continue;
        try testing.expectEqual(GetSpy.seen[0], at);
        gets += 1;
    }
    try testing.expect(gets >= 3);
}

test "retained runs and observations beyond jobs_max do not stop a node's run listings" {
    // Goal: run records stay until retention, 24 h after the ending, so more than `jobs_max` of
    // them can exist. A node's list reads its own assignments, not all of them.
    var rig = try Rig.start(25);
    defer rig.stop();
    try rig.join("node2");
    _ = try assign_run(&rig);
    var name_buffer: [32]u8 = undefined;
    for (0..constants.jobs_max + 1) |number| {
        const name = try std.fmt.bufPrint(&name_buffer, "old{d}", .{number});
        var id_buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const id = records.job_run_id(&id_buffer, name);
        var old = run_fixture;
        old.id = id;
        old.job = name;
        _ = try put_as(&rig, .job_controller, records.job_run_key(name).slice(), old);
        const seen: records.JobObserved = .{
            .run = id,
            .node = "node2",
            .tenure = @intCast(rig.tenure),
            .assignment = 1,
            .status = .stopped,
            .exit = .{ .kind = .lost },
            .reported_at_ms = 1,
        };
        const key = records.job_observed_key("node2", name);
        _ = try put_as(&rig, .{ .agent = "node2" }, key.slice(), seen);
    }
    const listed = try rig.ok("GET", "/v1/agent/nodes/node2/runs", "", "");
    try testing.expectEqual(@as(usize, 1), field(listed, "kvs").array.items.len);
    // The observations come a page at a time, each page at the revision of the first.
    var total: usize = 0;
    var query: []const u8 = "";
    var pages: u32 = 0;
    while (true) : (pages += 1) {
        const page = try rig.ok("GET", "/v1/agent/nodes/node2/job-observed", query, "");
        const kvs = field(page, "kvs").array.items;
        try testing.expect(kvs.len <= constants.store_list_limit_max);
        total += kvs.len;
        const more = page.object.get("more") orelse break;
        if (!more.bool) break;
        const key = kvs[kvs.len - 1].object.get("key").?.string;
        const prefix = records.job_observed_prefix("node2");
        query = try std.fmt.allocPrint(rig.parsed.allocator(), "after={s}&at={d}", .{
            key[prefix.slice().len..],
            field(page, "revision").integer,
        });
    }
    try testing.expectEqual(@as(usize, constants.jobs_max + 1), total);
    try testing.expectEqual(@as(u32, 1), pages); // 513 records: a page of 500, then 13.
}

test "a claim may replace only a leftover of an earlier job, never this job's observation" {
    var rig = try Rig.start(26);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    const first = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    const claim_revision: u64 = @intCast(field(first, "revision").integer);
    var again: [512]u8 = undefined;
    const format = "{{\"tenure\":{d},\"run_revision\":{d},\"observed_revision\":{d},\"value\":" ++
        "{{\"v\":1,\"run\":\"train-job\",\"node\":\"node2\",\"tenure\":{d}," ++
        "\"assignment\":{d},\"status\":\"claimed\",\"reported_at_ms\":2}}}}";
    const body = try std.fmt.bufPrint(
        &again,
        format,
        .{ rig.tenure, revisions[0], claim_revision, rig.tenure, revisions[1] },
    );
    const before = try rig.revision();
    const response = rig.call("POST", "/v1/agent/nodes/node2/job-observed", "", body);
    try rig.refused(response, 400, "ZC-E0104");
    try testing.expect(std.mem.indexOf(u8, response.body, "observed_revision") != null);
    const reason = "an observation of this job's run";
    try testing.expect(std.mem.indexOf(u8, response.body, reason) != null);
    try testing.expectEqual(before, try rig.revision());
}

test "a claim replaces a leftover observation older than the run, and says applied" {
    // Goal: a reused job name has the old run id; the gone job's observation is a leftover.
    var rig = try Rig.start(27);
    defer rig.stop();
    try rig.join("node2");
    const leftover: records.JobObserved = .{
        .run = "train-job",
        .node = "node2",
        .tenure = @intCast(rig.tenure),
        .assignment = 1,
        .status = .stopped,
        .exit = .{ .kind = .lost },
        .reported_at_ms = 1,
    };
    const key = records.job_observed_key("node2", "train");
    const left = try put_as(&rig, .{ .agent = "node2" }, key.slice(), leftover);
    const revisions = try assign_run(&rig); // The run is created after the leftover.
    var buffer: [512]u8 = undefined;
    const format = "{{\"tenure\":{d},\"run_revision\":{d},\"observed_revision\":{d},\"value\":" ++
        "{{\"v\":1,\"run\":\"train-job\",\"node\":\"node2\",\"tenure\":{d}," ++
        "\"assignment\":{d},\"status\":\"claimed\",\"reported_at_ms\":2}}}}";
    const text = try std.fmt.bufPrint(
        &buffer,
        format,
        .{ rig.tenure, revisions[0], left, rig.tenure, revisions[1] },
    );
    const answer = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try testing.expect(field(answer, "applied").bool);
    const kept = try rig.ok("GET", "/v1/agent/nodes/node2/job-observed", "", "");
    const rec = field(kept, "kvs").array.items[0];
    try testing.expectEqualStrings("claimed", field(field(rec, "value"), "status").string);
}

test "a damaged input value is ZC-E0523, with nothing left in the diagnostic" {
    var rig = try Rig.start(23);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    const key = records.job_input_key("train");
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = "{not json" } };
    const done = try @import("writers.zig").txn(
        rig.world.store_handle(),
        .api,
        .{ .on_success = &.{op} },
        &rig.world.diag,
    );
    try testing.expect(done.succeeded);
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    const response = rig.call("GET", "/v1/agent/nodes/node2/runs/train/input", "", "");
    try rig.refused(response, response.status, "ZC-E0523");
    try testing.expect(std.mem.indexOf(u8, response.body, records.input_mismatch_phrase) != null);
    // Wire protocol: the agent's client matches this literal text (agent_client_test.zig pins
    // the same literal on its side). Change both together, with a version bump.
    try testing.expect(std.mem.indexOf(u8, response.body, "does not match its digest") != null);
    // Nothing of the failed read stays: the answer carries one diagnostic and one cause.
    const body = try rig.json(response);
    const diagnostics = body.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(@as(usize, 1), diagnostics[0].object.get("causes").?.array.items.len);
}

test "a claim is applied once; a second, a moved run or a moved assignment is applied: false" {
    var rig = try Rig.start(22);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    const first = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try testing.expect(field(first, "applied").bool);
    const before = try rig.revision();
    const second = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try testing.expect(!field(second, "applied").bool);
    try testing.expectEqual(before, try rig.revision());
}

test "a claim of a run that moved since the agent read it is applied: false" {
    var rig = try Rig.start(23);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    var stopped = run_fixture;
    stopped.stop = .{ .cause = .cancel, .at_ms = 5 };
    _ = try put_as(&rig, .job_controller, records.job_run_key("train").slice(), stopped);
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    const before = try rig.revision();
    const answer = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try testing.expect(!field(answer, "applied").bool);
    try testing.expectEqual(before, try rig.revision());
}

test "a job report under a tenure that has been replaced is ZC-E0510 and writes nothing" {
    var rig = try Rig.start(24);
    defer rig.stop();
    try rig.join("node2");
    const old = rig.tenure;
    const revisions = try assign_run(&rig);
    try rig.join("node2");
    var buffer: [512]u8 = undefined;
    const text = try claim_text(&buffer, old, revisions[0], revisions[1]);
    const before = try rig.revision();
    const response = rig.call("POST", "/v1/agent/nodes/node2/job-observed", "", text);
    try rig.refused(response, 503, "ZC-E0510");
    try testing.expectEqual(before, try rig.revision());
}

fn report_text(buffer: []u8, tenure: i64, epoch: u64, status: []const u8) ![]const u8 {
    const exit = if (std.mem.eql(u8, status, "stopped"))
        ",\"exit\":{\"kind\":\"exited\",\"code\":0}"
    else
        "";
    const format = "{{\"tenure\":{d},\"value\":{{\"v\":1,\"run\":\"train-job\"," ++
        "\"node\":\"node2\",\"tenure\":{d},\"assignment\":{d},\"status\":\"{s}\"," ++
        "\"reported_at_ms\":3{s}}}}}";
    return std.fmt.bufPrint(buffer, format, .{ tenure, tenure, epoch, status, exit });
}

test "a report of a retired or superseded run is applied: false and writes nothing" {
    // Goal: B2. A late report whose assignment is no longer the stored one is refused at write
    // time, so the store never holds an observation the job controller would ignore.
    var rig = try Rig.start(25);
    defer rig.stop();
    try rig.join("node2");
    const revisions = try assign_run(&rig);
    var buffer: [512]u8 = undefined;
    const claim = try claim_text(&buffer, rig.tenure, revisions[0], revisions[1]);
    _ = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", claim);
    // The assignment it ran under: stored.
    const live = try report_text(&buffer, rig.tenure, revisions[1], "running");
    const stored = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", live);
    try testing.expect(field(stored, "applied").bool);
    // Superseded: the run is placed again, under a newer assignment.
    const assigned: records.Assigned = .{
        .replica = "train-job",
        .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        .reason = "test",
        .job = "train",
    };
    const key = records.assigned_key("node2", "train-job");
    const newer = try put_as(&rig, .scheduler, key.slice(), assigned);
    const before = try rig.revision();
    const old = try report_text(&buffer, rig.tenure, revisions[1], "stopped");
    const refused = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", old);
    try testing.expect(!field(refused, "applied").bool);
    try testing.expectEqual(before, try rig.revision());
    // Retired: the assignment is gone.
    const gone: store.Op = .{ .delete = key.slice() };
    const released = try @import("writers.zig").txn(
        rig.world.store_handle(),
        .scheduler,
        .{ .on_success = &.{gone} },
        &rig.world.diag,
    );
    try testing.expect(released.succeeded);
    const after = try rig.revision();
    const late = try report_text(&buffer, rig.tenure, newer, "stopped");
    const retired = try rig.ok("POST", "/v1/agent/nodes/node2/job-observed", "", late);
    try testing.expect(!field(retired, "applied").bool);
    try testing.expectEqual(after, try rig.revision());
}
