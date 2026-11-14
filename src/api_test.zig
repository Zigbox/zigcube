//! Tests of the API handlers (`api.zig`) against the simulation world: a real controller, a real
//! agent and the memory store behind the API, so each answer is the answer to a real state. The
//! requests are bytes in, and the answers are parsed back from the bytes that come out.

const std = @import("std");
const testing = std.testing;
const api_mod = @import("api.zig");
const agent_state = @import("agent_state.zig");
const apply_mod = @import("apply.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");

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

    /// Compacts the store to `revision`, as the server's maintenance would.
    fn compact(rig: *Rig, revision: i64) !void {
        rig.world.diag.reset();
        try rig.world.memory.interface().compact(@intCast(revision), &rig.world.diag);
    }

    /// One request. The answer's bytes live in the world's arena until the next call.
    fn call(rig: *Rig, request: api_mod.Request) api_mod.Response {
        const ctx = rig.world.controller_context();
        return rig.api.handle(&ctx, request);
    }

    fn get(rig: *Rig, path: []const u8, query: []const u8) api_mod.Response {
        return rig.call(.{ .method = "GET", .path = path, .query = query });
    }

    /// The body parsed, copied out of the world's arena so a later call cannot disturb it.
    fn json(rig: *Rig, response: api_mod.Response) !Json {
        const arena = rig.parsed.allocator();
        const copy = try arena.dupe(u8, response.body);
        return std.json.parseFromSliceLeaky(Json, arena, copy, .{});
    }

    fn ok(rig: *Rig, path: []const u8, query: []const u8) !Json {
        const response = rig.get(path, query);
        if (response.status != 200) std.debug.print("{s}\n", .{response.body});
        try testing.expectEqual(@as(u16, 200), response.status);
        return rig.json(response);
    }

    /// Expects a failure with `status` and the code, and checks the body names the request.
    fn refused(rig: *Rig, response: api_mod.Response, status: u16, code: []const u8) !void {
        if (response.status != status) std.debug.print("{s}\n", .{response.body});
        try testing.expectEqual(status, response.status);
        const body = try rig.json(response);
        try testing.expectEqualStrings(response.request_id, body.object.get("request_id").?.string);
        const first = body.object.get("diagnostics").?.array.items[0];
        try testing.expectEqualStrings(code, first.object.get("code").?.string);
        try testing.expect(first.object.get("docs") == null);
    }
};

fn field(value: Json, name: []const u8) Json {
    return value.object.get(name).?;
}

test "status answers with the store's revision, and with its diagnostic when the store is down" {
    // Goal: docs/api.md, "GET /v1/status": it always answers 200, so the console can tell
    // "server down" from "store down". Method: ask with the store up and down.
    var rig = try Rig.start(1);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const up = try rig.ok("/v1/status", "");
    try testing.expect(field(field(up, "store"), "ok").bool);
    try testing.expect(field(field(up, "store"), "revision").integer > 0);
    try testing.expectEqualStrings("memory", field(field(up, "store"), "backend").string);
    try testing.expectEqual(@as(i64, @intCast(rig.world.now_ms())), field(up, "time_ms").integer);

    rig.world.set_store_down(true);
    const down = try rig.ok("/v1/status", "");
    const store_part = field(down, "store");
    try testing.expect(!field(store_part, "ok").bool);
    const diagnostic = field(store_part, "diagnostic");
    try testing.expectEqualStrings("ZC-E0201", field(diagnostic, "code").string);
    try testing.expect(store_part.object.get("revision") == null);
    try testing.expect(field(store_part, "diagnostic").object.get("docs") == null);
}

test "list pages, reverses, reads at a revision and keeps env values from a read-only token" {
    // Goal: Store.list one to one, and api.md item 8. Method: apply a service with a secret,
    // read it back, page through replicas, and ask for revisions out of range.
    var rig = try Rig.start(2);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);

    const services = try rig.ok("/v1/list", "prefix=%2Fservices%2F");
    const kv = field(services, "kvs").array.items[0];
    try testing.expectEqualStrings("/services/hello", field(kv, "key").string);
    try testing.expectEqualStrings("hello", field(field(kv, "value"), "name").string);
    const env = field(field(kv, "value"), "env").array.items[0];
    try testing.expectEqualStrings("API_TOKEN", env.array.items[0].string);
    try testing.expect(env.array.items[1] == .null);

    const replicas = rig.get("/v1/list", "prefix=/replicas/");
    try testing.expect(std.mem.indexOf(u8, replicas.body, "s3cr3t") == null);
    rig.api.read_only = false;
    const writer = rig.get("/v1/list", "prefix=/services/");
    try testing.expect(std.mem.indexOf(u8, writer.body, "s3cr3t") != null);
    rig.api.read_only = true;

    const first = try rig.ok("/v1/list", "prefix=/replicas/&limit=1");
    try testing.expectEqual(@as(usize, 1), field(first, "kvs").array.items.len);
    const after = field(first, "continue").string;
    const at = field(first, "revision").integer;
    var query_buffer: [160]u8 = undefined;
    const format = "prefix=/replicas/&limit=1&at={d}&continue={s}";
    const second_query = try std.fmt.bufPrint(&query_buffer, format, .{ at, after });
    const second = try rig.ok("/v1/list", second_query);
    const second_kv = field(second, "kvs").array.items[0];
    try testing.expectEqualStrings("/replicas/hello/hello-2", field(second_kv, "key").string);
    try testing.expect(field(second, "continue") == .null);

    const newest = try rig.ok("/v1/list", "prefix=/replicas/&limit=1&reverse=true");
    const newest_kv = field(newest, "kvs").array.items[0];
    try testing.expectEqualStrings("/replicas/hello/hello-2", field(newest_kv, "key").string);

    try rig.refused(rig.get("/v1/list", "at=9999999"), 400, "ZC-E0204");
    try rig.compact(field(first, "revision").integer);
    try rig.refused(rig.get("/v1/list", "at=1"), 410, "ZC-E0203");
}

test "a read-only token sees neither a job run's env values nor its input digest" {
    // Goal: GET /v1/list redaction covers /job-runs/ as it covers /jobs/. Method: put a run
    // record with a secret and a digest, read it back with both token kinds.
    var rig = try Rig.start(4);
    defer rig.stop();
    const run =
        \\{"v":1,"id":"j-1","job":"j","image":"i","command":["x"],"env":[["K","s3cr3t"]],
        \\"deadline_ms":1,"input_digest":"sha256:dd","start_by_ms":1,"created_at_ms":1}
    ;
    const put = [_]store.Op{.{ .put = .{ .key = "/job-runs/j-1", .value = run } }};
    _ = try rig.world.store_handle().txn(.{ .on_success = &put }, &rig.world.diag);

    const hidden = rig.get("/v1/list", "prefix=/job-runs/");
    try testing.expect(std.mem.indexOf(u8, hidden.body, "s3cr3t") == null);
    try testing.expect(std.mem.indexOf(u8, hidden.body, "sha256:dd") == null);
    rig.api.read_only = false;
    const shown = rig.get("/v1/list", "prefix=/job-runs/");
    try testing.expect(std.mem.indexOf(u8, shown.body, "s3cr3t") != null);
    try testing.expect(std.mem.indexOf(u8, shown.body, "sha256:dd") != null);
}

test "a read-only token sees no env value of a service's history, on any read path" {
    // Goal: docs/api.md item 8 for `/history/` (C3 slice 5): a history record copies the spec,
    // so its `env` values are as secret as the service's. Method: apply two generations with a
    // secret, then read through every path a read-only token has (a list of the history prefix,
    // of one key as `zcube get` asks, of the whole store, a watch, why) and through the writer;
    // a record under a prefix the API has no rule for is hidden too, so the next spec copy
    // cannot leak by being left off a list. Teeth: removing the redaction fails every check.
    var rig = try Rig.start(5);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    var second = hello;
    second.image = "b3:51aa9c04";
    second.request_id = "r-0000002";
    _ = try rig.world.apply(second);
    rig.world.advance(2000);
    const unknown =
        \\{"v":1,"env":[["K","s3cr3t"]]}
    ;
    const put = [_]store.Op{.{ .put = .{ .key = "/rollouts/hello", .value = unknown } }};
    _ = try rig.world.store_handle().txn(.{ .on_success = &put }, &rig.world.diag);

    const history = try rig.ok("/v1/list", "prefix=%2Fhistory%2Fhello%2F");
    const kvs = field(history, "kvs").array.items;
    try testing.expectEqual(@as(usize, 2), kvs.len);
    for (kvs) |kv| {
        const env = field(field(kv, "value"), "env").array.items[0];
        try testing.expectEqualStrings("API_TOKEN", env.array.items[0].string);
        try testing.expect(env.array.items[1] == .null);
    }
    const paths = [_][2][]const u8{
        .{ "/v1/list", "prefix=/history/hello/1" },
        .{ "/v1/list", "prefix=/history/" },
        .{ "/v1/list", "prefix=/rollouts/" },
        .{ "/v1/list", "prefix=/&limit=500" },
        .{ "/v1/watch", "from=1&timeout=0" },
        .{ "/v1/watch", "from=1&timeout=0&prefix=/history/" },
        .{ "/v1/why/service/hello", "" },
    };
    for (paths) |path| {
        const hidden = rig.get(path[0], path[1]);
        try testing.expectEqual(@as(u16, 200), hidden.status);
        try testing.expect(std.mem.indexOf(u8, hidden.body, "s3cr3t") == null);
    }
    rig.api.read_only = false;
    for (paths[0..6]) |path| {
        const shown = rig.get(path[0], path[1]);
        try testing.expect(std.mem.indexOf(u8, shown.body, "s3cr3t") != null);
    }
}

test "watch answers what is ready with a bookmark and leaves the waiting to the shell" {
    // Goal: api.md, "GET /v1/watch": ordered events from `from`, an idle answer that still
    // advances the bookmark, repeated prefixes, deletes with a null value, 410 and 400.
    var rig = try Rig.start(3);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);

    const all = try rig.ok("/v1/watch", "from=1&timeout=0");
    const events = field(all, "events").array.items;
    try testing.expect(events.len > 5);
    var last: i64 = 0;
    for (events) |event| {
        const revision = field(field(event, "kv"), "mod_revision").integer;
        try testing.expect(revision >= last);
        last = revision;
    }
    const bookmark = field(all, "revision").integer;
    try testing.expectEqual(last, bookmark);

    const only = try rig.ok("/v1/watch", "from=1&timeout=0&prefix=/services/&prefix=/nodes/");
    for (field(only, "events").array.items) |event| {
        const key = field(field(event, "kv"), "key").string;
        const wanted = std.mem.startsWith(u8, key, "/services/") or
            std.mem.startsWith(u8, key, "/nodes/");
        try testing.expect(wanted);
    }
    try testing.expectEqual(bookmark, field(only, "revision").integer);

    var query_buffer: [64]u8 = undefined;
    const idle_query = try std.fmt.bufPrint(&query_buffer, "from={d}&timeout=0", .{bookmark + 1});
    const idle = rig.get("/v1/watch", idle_query);
    try testing.expectEqual(@as(u32, 0), idle.hold_ms);
    const idle_json = try rig.json(idle);
    try testing.expectEqual(@as(usize, 0), field(idle_json, "events").array.items.len);
    try testing.expectEqual(bookmark, field(idle_json, "revision").integer);

    const waiting_format = "from={d}&timeout=5000";
    const waiting_query = try std.fmt.bufPrint(&query_buffer, waiting_format, .{bookmark + 1});
    const waiting = rig.get("/v1/watch", waiting_query);
    try testing.expectEqual(@as(u32, 5000), waiting.hold_ms);
    const again = rig.call(.{
        .method = "GET",
        .path = "/v1/watch",
        .query = waiting_query,
        .hold = false,
    });
    try testing.expectEqual(@as(u32, 0), again.hold_ms);
    try testing.expectEqual(@as(u16, 200), again.status);

    _ = try rig.world.delete_service("hello");
    const deleted_format = "from={d}&timeout=0&prefix=/services/";
    const deleted_query = try std.fmt.bufPrint(&query_buffer, deleted_format, .{bookmark + 1});
    const deleted = try rig.ok("/v1/watch", deleted_query);
    const event = field(deleted, "events").array.items[0];
    try testing.expectEqualStrings("delete", field(event, "type").string);
    try testing.expect(field(field(event, "kv"), "value") == .null);

    try rig.refused(rig.get("/v1/watch", "from=99999999&timeout=0"), 400, "ZC-E0204");
    try rig.compact(bookmark);
    try rig.refused(rig.get("/v1/watch", "from=1&timeout=0"), 410, "ZC-E0203");
    try rig.refused(rig.get("/v1/watch", "timeout=0"), 400, "ZC-E0104");
}

test "a watch that is behind the head answers at once, however few of its events are kept" {
    // Goal: api.md, "GET /v1/watch": an answer with no event is held only when the bookmark has
    // reached the head. Method: enough writes under a prefix nobody watches that one call reads
    // `watch_batches_max` full batches, keeps none and stops short of the head; the held answer
    // was the defect (RA-S3).
    var rig = try Rig.start(3);
    defer rig.stop();
    const ops_per_txn = constants.store_txn_ops_max;
    const txns = (constants.store_watch_batch_max * 66) / ops_per_txn;
    var keys: [ops_per_txn][24]u8 = undefined;
    var ops: [ops_per_txn]store.Op = undefined;
    for (0..txns) |txn_index| {
        for (&ops, &keys, 0..) |*op, *key, index| {
            const number = txn_index * ops_per_txn + index;
            const text = try std.fmt.bufPrint(key, "/noise/{d}", .{number});
            op.* = .{ .put = .{ .key = text, .value = "x" } };
        }
        _ = try rig.world.store_handle().txn(.{ .on_success = &ops }, &rig.world.diag);
    }
    const head = (try rig.world.store_handle().status(&rig.world.diag)).revision;
    const Case = struct { path: []const u8, query: []const u8 };
    const cases = [_]Case{
        .{ .path = "/v1/watch", .query = "from=1&timeout=5000&prefix=/job-status/" },
        .{ .path = "/v1/jobs/watch", .query = "from=1&timeout=5000" },
    };
    for (cases) |case| {
        const behind = rig.get(case.path, case.query);
        try testing.expectEqual(@as(u16, 200), behind.status);
        try testing.expectEqual(@as(u32, 0), behind.hold_ms);
        const json = try rig.json(behind);
        const bookmark = field(json, "revision").integer;
        try testing.expect(bookmark < head);
    }
    // Once the bookmark is the head, the idle answer is held again.
    var query_buffer: [64]u8 = undefined;
    const query = try std.fmt.bufPrint(&query_buffer, "from={d}&timeout=5000", .{head + 1});
    try testing.expectEqual(@as(u32, 5000), rig.get("/v1/watch", query).hold_ms);
    try testing.expectEqual(@as(u32, 5000), rig.get("/v1/jobs/watch", query).hold_ms);
}

test "leases lists the node's lease with the key it holds" {
    // Goal: api.md, "GET /v1/leases", which the Nodes screen polls for the TTL remaining.
    var rig = try Rig.start(4);
    defer rig.stop();
    rig.world.advance(1000);
    const body = try rig.ok("/v1/leases", "");
    const lease = field(body, "leases").array.items[0];
    try testing.expectEqual(@as(i64, 10000), field(lease, "ttl_ms").integer);
    try testing.expectEqualStrings("/nodes/node1", field(lease, "keys").array.items[0].string);
}

test "why answers with the chain, and 404 for a subject that never existed" {
    // Goal: api.md, "GET /v1/why": state, steps and the diagnostic of a failed start in a step.
    var rig = try Rig.start(5);
    defer rig.stop();
    var broken = hello;
    broken.name = "broken";
    broken.image = "b3:00ff7be1";
    broken.replicas = 1;
    _ = try rig.world.apply(broken);
    rig.world.advance(3000);
    const body = try rig.ok("/v1/why/service/broken", "");
    const state = field(body, "state");
    try testing.expectEqualStrings("service broken: 0/1 running", field(state, "text").string);
    try testing.expectEqualStrings("failing", field(field(body, "state"), "health").string);
    const steps = field(body, "steps").array.items;
    try testing.expectEqualStrings("decision", field(steps[0], "type").string);
    try testing.expectEqualStrings("observed", field(steps[1], "type").string);
    const failure = field(steps[1], "diagnostic");
    try testing.expectEqualStrings("ZBX-E0410", field(failure, "code").string);
    try testing.expect(field(steps[1], "diagnostic").object.get("docs") == null);

    const decision = field(field(steps[0], "decision"), "id").string;
    var query_buffer: [64]u8 = undefined;
    const query = try std.fmt.bufPrint(&query_buffer, "decision={s}", .{decision});
    const pinned = try rig.ok("/v1/why/service/broken", query);
    try testing.expectEqualStrings(decision, field(pinned, "at_decision").string);

    try rig.refused(rig.get("/v1/why/service/nope", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/why/pod/x", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/why/service/broken", "decision=zzz"), 400, "ZC-E0104");
}

test "request ids are assigned, echoed, and reported with failures" {
    // Goal: api.md, "Request ID": a new id on every request, success or failure; a valid client
    // id is used; an invalid one is refused and the refusal carries a new id.
    var rig = try Rig.start(6);
    defer rig.stop();
    const first = rig.get("/v1/status", "");
    try testing.expectEqualStrings("r-0000001", first.request_id);
    try testing.expectEqualStrings("r-0000002", rig.get("/v1/status", "").request_id);
    const sent = rig.call(.{
        .method = "GET",
        .path = "/v1/status",
        .request_id = "from-the-cli-0001",
    });
    try testing.expectEqualStrings("from-the-cli-0001", sent.request_id);
    const short = rig.call(.{ .method = "GET", .path = "/v1/status", .request_id = "abc" });
    try rig.refused(short, 400, "ZC-E0104");
    try testing.expect(!std.mem.eql(u8, short.request_id, "abc"));
    const odd = rig.call(.{
        .method = "GET",
        .path = "/v1/status",
        .request_id = "has spaces here",
    });
    try rig.refused(odd, 400, "ZC-E0104");
    const missing = rig.get("/v1/nothing", "");
    try rig.refused(missing, 404, "ZC-E0101");
}

test "requests the API cannot understand are ZC-E0104 and write nothing" {
    // Goal: each way a request can be wrong, once. Method: a method, a parameter, three numbers,
    // a dangling continue, a bad escape.
    var rig = try Rig.start(7);
    defer rig.stop();
    try rig.refused(rig.call(.{ .method = "POST", .path = "/v1/status" }), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/status", "x=1"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "limit=0"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "limit=501"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "limit=ten"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "continue=/a"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "prefix=%2"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "prefix=a"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/list", "prefix=/a&prefix=/b"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/watch", "from=1&timeout=25001"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/status/extra", ""), 404, "ZC-E0101");
}

test "the store failing during a request is its own diagnostic with the status its blame decides" {
    // Goal: api.md, "Errors": 503 for a store that did not answer, immediately.
    var rig = try Rig.start(8);
    defer rig.stop();
    rig.world.set_store_down(true);
    try rig.refused(rig.get("/v1/list", ""), 503, "ZC-E0201");
    try rig.refused(rig.get("/v1/watch", "from=1&timeout=0"), 503, "ZC-E0201");
    try rig.refused(rig.get("/v1/leases", ""), 503, "ZC-E0201");
}

test "the status follows the blame of the first diagnostic" {
    // Goal: the table of api.md, "Errors", for each blame and the codes that single one out.
    try testing.expectEqual(@as(u16, 404), api_mod.status_for(.E0101, .user));
    try testing.expectEqual(@as(u16, 409), api_mod.status_for(.E0105, .user));
    try testing.expectEqual(@as(u16, 410), api_mod.status_for(.E0203, .user));
    try testing.expectEqual(@as(u16, 400), api_mod.status_for(.E0204, .user));
    try testing.expectEqual(@as(u16, 503), api_mod.status_for(.E0207, .environment));
    try testing.expectEqual(@as(u16, 503), api_mod.status_for(.E0201, .external));
    try testing.expectEqual(@as(u16, 502), api_mod.status_for(.E0202, .external));
    try testing.expectEqual(@as(u16, 500), api_mod.status_for(.B0001, .internal));
}

test "codes lists both registries; explain prints what the CLI prints" {
    // Goal: api.md, "GET /v1/codes and /v1/explain": Zigcube's codes, Zigbox's
    // (ZBX-E0410 among them); the long text is the CLI's text.
    var rig = try Rig.start(9);
    defer rig.stop();
    const listed = try rig.ok("/v1/codes", "");
    var seen_zc = false;
    var seen_zbx = false;
    for (field(listed, "codes").array.items) |entry| {
        const code = field(entry, "code").string;
        if (std.mem.eql(u8, code, "ZC-E0101")) seen_zc = true;
        if (std.mem.eql(u8, code, "ZBX-E0410")) seen_zbx = true;
    }
    try testing.expect(seen_zc and seen_zbx);

    const explained = try rig.ok("/v1/explain/ZC-E0203", "");
    const text = field(explained, "explanation").string;
    const head = "ZC-E0203: that revision was compacted away\n";
    try testing.expect(std.mem.startsWith(u8, text, head));
    var buffer: [@import("constants.zig").diag_output_bytes_max]u8 = undefined;
    const cli = @import("diag.zig").explain(.E0203, &buffer);
    try testing.expectEqualStrings(cli, text);

    const runtime_text = try rig.ok("/v1/explain/ZBX-E0410", "");
    const zbx_text = field(runtime_text, "explanation").string;
    try testing.expect(std.mem.indexOf(u8, zbx_text, "tree") != null);
    try rig.refused(rig.get("/v1/explain/ZC-E9999", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/explain/ZBX-E9999", ""), 404, "ZC-E0101");
}

const hello_json =
    \\{"name":"hello","image":"b3:51aa9c03","replicas":2,
    \\ "command":["sh","-c","sleep 1"],"env":[["API_TOKEN","s3cr3t"]],"applied_by":"alex@laptop"}
;

fn post(rig: *Rig, query: []const u8, body: []const u8) api_mod.Response {
    return rig.call(.{ .method = "POST", .path = "/v1/apply", .query = query, .body = body });
}

test "POST /v1/apply creates, scales, answers a dry run without writing, and reports no change" {
    // Goal: the proposed write endpoint of docs/api.md. Method: apply, read back through the
    // read endpoints, scale, dry-run a change, repeat an apply; check the revision each time.
    var rig = try Rig.start(10);
    defer rig.stop();
    const created = try rig.json(post(&rig, "", hello_json));
    try testing.expectEqualStrings("create", field(created, "action").string);
    try testing.expectEqual(@as(i64, 1), field(created, "generation").integer);
    try testing.expectEqualStrings("created", field(created, "change").string);
    const decision = field(created, "decision").string;
    try testing.expect(field(created, "revision").integer > 0);
    try testing.expect(!field(created, "dry_run").bool);

    rig.world.advance(2000);
    const listed = try rig.ok("/v1/list", "prefix=%2Fservices%2F");
    try testing.expectEqual(@as(usize, 1), field(listed, "kvs").array.items.len);
    const why = try rig.ok("/v1/why/service/hello", "");
    const state_text = field(field(why, "state"), "text").string;
    try testing.expectEqualStrings("service hello: 2/2 running", state_text);
    const index = try rig.ok("/v1/list", "prefix=%2Fdecisions%2F");
    var found = false;
    for (field(index, "kvs").array.items) |kv| {
        if (std.mem.endsWith(u8, field(kv, "key").string, decision)) found = true;
    }
    try testing.expect(found);

    const before = rig.world.revision().?;
    const two = "\"replicas\":2";
    const four = "\"replicas\":4";
    const scaled_json = try std.mem.replaceOwned(u8, testing.allocator, hello_json, two, four);
    defer testing.allocator.free(scaled_json);
    const dry = try rig.json(post(&rig, "dry_run=1", scaled_json));
    try testing.expectEqualStrings("update", field(dry, "action").string);
    try testing.expectEqualStrings("replicas 2 → 4", field(dry, "change").string);
    try testing.expect(field(dry, "dry_run").bool);
    try testing.expect(dry.object.get("decision") == null);
    try testing.expectEqual(before, rig.world.revision().?);

    const real = try rig.json(post(&rig, "", scaled_json));
    try testing.expectEqual(@as(i64, 1), field(real, "generation").integer);
    const same = try rig.json(post(&rig, "", scaled_json));
    try testing.expectEqualStrings("none", field(same, "action").string);
    try testing.expectEqualStrings("no change", field(same, "change").string);
}

test "a body that is not a service is ZC-E0104 and writes nothing" {
    // Goal: every way a write can be refused before it touches the store. Method: no body, JSON
    // that is not a service, an unknown field, a bad name, an applied_by with a newline.
    var rig = try Rig.start(11);
    defer rig.stop();
    try rig.refused(post(&rig, "", ""), 400, "ZC-E0104");
    try rig.refused(post(&rig, "", "{"), 400, "ZC-E0104");
    try rig.refused(post(&rig, "", "{\"name\":\"x\"}"), 400, "ZC-E0104");
    try rig.refused(post(&rig, "dry_run=maybe", hello_json), 400, "ZC-E0104");
    try rig.refused(post(&rig, "x=1", hello_json), 400, "ZC-E0104");
    const small = "{\"name\":\"a\",\"image\":\"b\",\"replicas\":1,\"command\":[\"c\"]";
    const typo = small ++ ",\"replica\":3}";
    try rig.refused(post(&rig, "", typo), 400, "ZC-E0104");
    const upper = "{\"name\":\"Hello\",\"image\":\"b\",\"replicas\":1,\"command\":[\"c\"]}";
    try rig.refused(post(&rig, "", upper), 400, "ZC-E0104");
    const newline = small ++ ",\"applied_by\":\"x\\ny\"}";
    try rig.refused(post(&rig, "", newline), 400, "ZC-E0104");
    try testing.expectEqual(@as(store.Revision, 0), rig.world.revision().?);
}

test "POST /v1/apply takes a source, serves it back, and refuses one that is not a pin" {
    // Goal: P1 of docs/briefs/c2-2.md at the API. Method: apply with a digest-pinned source and
    // read the service and its replicas back; then a tag, a number and an unknown neighbour are
    // ZC-E0104 and write nothing more.
    var rig = try Rig.start(13);
    defer rig.stop();
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const reference = "registry.example/hello@sha256:" ++ digest;
    const head = "{\"name\":\"hello\",\"image\":\"b3:51aa9c03\",\"replicas\":1,\"command\":[\"c\"]";
    const created = try rig.json(post(&rig, "", head ++ ",\"source\":\"" ++ reference ++ "\"}"));
    try testing.expectEqualStrings("create", field(created, "action").string);
    rig.world.advance(2000);
    const listed = try rig.ok("/v1/list", "prefix=%2Fservices%2F");
    const kv = field(listed, "kvs").array.items[0];
    try testing.expectEqualStrings(reference, field(field(kv, "value"), "source").string);
    const replicas = try rig.ok("/v1/list", "prefix=%2Freplicas%2F");
    const replica_kv = field(replicas, "kvs").array.items[0];
    try testing.expectEqualStrings(reference, field(field(replica_kv, "value"), "source").string);
    const before = rig.world.revision().?;
    const tag = head ++ ",\"source\":\"registry.example/hello:v1\"}";
    try rig.refused(post(&rig, "", tag), 400, "ZC-E0104");
    try rig.refused(post(&rig, "", head ++ ",\"source\":7}"), 400, "ZC-E0104");
    try rig.refused(post(&rig, "", head ++ ",\"sources\":\"x\"}"), 400, "ZC-E0104");
    try testing.expectEqual(before, rig.world.revision().?);
}

test "DELETE /v1/services/{name} deletes, and a missing service is ZC-E0101" {
    // Goal: the second proposed write endpoint. Method: apply, delete, delete again; the replicas
    // are stopped by the controller afterwards, and a wrong path or method is a refusal.
    var rig = try Rig.start(12);
    defer rig.stop();
    _ = try rig.json(post(&rig, "", hello_json));
    rig.world.advance(2000);
    const deleted = rig.call(.{ .method = "DELETE", .path = "/v1/services/hello" });
    const body = try rig.json(deleted);
    try testing.expectEqual(@as(u16, 200), deleted.status);
    try testing.expectEqualStrings("delete", field(body, "action").string);
    try testing.expect(field(body, "decision").string.len > 0);
    rig.world.advance(5000);
    try testing.expectEqual(@as(u32, 0), rig.world.replica_count("hello"));
    const again = rig.call(.{ .method = "DELETE", .path = "/v1/services/hello" });
    try rig.refused(again, 404, "ZC-E0101");
    try rig.refused(rig.call(.{ .method = "DELETE", .path = "/v1/list" }), 400, "ZC-E0104");
    const odd = rig.call(.{ .method = "PUT", .path = "/v1/apply", .body = hello_json });
    try rig.refused(odd, 400, "ZC-E0104");
}

// ---- The allocation accounting (C1 slice 4c, 4d) -----------------------------------------------

const writers = @import("writers.zig");

/// Puts node1's allocation record back with one assignment more than it holds, as a defect would.
fn corrupt_node1(rig: *Rig) !void {
    const ctx = rig.world.controller_context();
    const at = records.allocation_key(sim_world.node_name);
    const got = try ctx.store.get(ctx.arena, at.slice(), null, ctx.diag);
    var wrong = try records.read(records.Allocation, ctx.arena, got.kv.?, ctx.diag);
    wrong.count += 1;
    const bytes = try records.encode(ctx.arena, wrong, ctx.diag);
    const op: store.Op = .{ .put = .{ .key = at.slice(), .value = bytes } };
    _ = try writers.txn(ctx.store, .scheduler, .{ .on_success = &.{op} }, ctx.diag);
}

fn repair(rig: *Rig, query: []const u8) api_mod.Response {
    const path = "/v1/repair/allocations/" ++ sim_world.node_name;
    return rig.call(.{ .method = "POST", .path = path, .query = query });
}

test "status lists the auditor's finding; check shows it; repair asks, then writes and cites it" {
    // Goal: docs/api.md, the check and repair endpoints and status `findings`. Method: hello on
    // node1, its record corrupted; the auditor's pass opens the finding; check and status show
    // it; a repair without confirm writes nothing; with it the record is the reconstruction and
    // the next pass clears the finding.
    var rig = try Rig.start(1);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const healthy = try rig.ok("/v1/check/allocations", "");
    try testing.expectEqual(@as(i64, 0), field(healthy, "inconsistent").integer);
    const statuses = field(try rig.ok("/v1/status", ""), "findings").array.items;
    try testing.expectEqual(@as(usize, 0), statuses.len);
    try rig.refused(repair(&rig, "confirm=true"), 409, "ZC-E0402");

    try corrupt_node1(&rig);
    _ = rig.world.settle();
    const check = try rig.ok("/v1/check/allocations", "");
    try testing.expectEqual(@as(i64, 1), field(check, "inconsistent").integer);
    const node = field(check, "nodes").array.items[0];
    try testing.expectEqualStrings(sim_world.node_name, field(node, "node").string);
    try testing.expect(!field(node, "consistent").bool);
    try testing.expectEqual(@as(i64, 3), field(field(node, "recorded"), "count").integer);
    try testing.expectEqual(@as(i64, 2), field(field(node, "reconstructed"), "count").integer);
    const decision = field(field(node, "finding"), "decision").string;
    const findings = field(try rig.ok("/v1/status", ""), "findings").array.items;
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings(decision, field(findings[0], "decision").string);

    const before = (try rig.ok("/v1/status", "")).object.get("store").?;
    try rig.refused(repair(&rig, ""), 400, "ZC-E0401");
    const after = (try rig.ok("/v1/status", "")).object.get("store").?;
    try testing.expectEqual(field(before, "revision").integer, field(after, "revision").integer);
    try rig.refused(repair(&rig, "confirm=maybe"), 400, "ZC-E0104");

    const done = repair(&rig, "confirm=true");
    try testing.expectEqual(@as(u16, 200), done.status);
    const body = try rig.json(done);
    try testing.expectEqualStrings(done.request_id, field(body, "request_id").string);
    try testing.expectEqualStrings("repair_allocation", field(body, "action").string);
    try testing.expectEqual(@as(i64, 2), field(field(body, "reconstructed"), "count").integer);
    _ = rig.world.settle();
    const repaired = try rig.ok("/v1/check/allocations", "");
    try testing.expectEqual(@as(i64, 0), field(repaired, "inconsistent").integer);
    const cleared = field(repaired, "nodes").array.items[0];
    try testing.expect(field(cleared, "finding") == .null);
    try rig.refused(repair(&rig, "confirm=true"), 409, "ZC-E0402");
}

/// Puts a pull record of `node` for `tree` into the store as the agent would, finished at `at_ms`.
fn put_pull(rig: *Rig, node: []const u8, tree: []const u8, at_ms: u64, version: u32) !void {
    const ctx = rig.world.controller_context();
    const record: records.Pull = .{
        .v = version,
        .node = node,
        .tree = tree,
        .registry_bytes = 1000,
        .peer_bytes = &.{.{ .peer = "node2", .bytes = 500 }},
        .cached_bytes = 20,
        .finished_at_ms = at_ms,
    };
    const bytes = try records.encode(ctx.arena, record, ctx.diag);
    const key = records.pull_key(node, tree);
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
    _ = try writers.txn(ctx.store, .{ .agent = node }, .{ .on_success = &.{op} }, ctx.diag);
}

test "stats pull lists the pulls newest first, by node, with a limit, and counts what it skips" {
    // Goal: docs/api.md, "GET /v1/stats/pull". Method: three pulls on two nodes, one record from
    // a version that does not exist yet, one that is not JSON; then ask all, one node, a limit.
    var rig = try Rig.start(3);
    defer rig.stop();
    try put_pull(&rig, "node1", "b3:00000001", 100, 1);
    try put_pull(&rig, "node2", "b3:00000002", 300, 1);
    try put_pull(&rig, "node1", "b3:00000003", 200, 1);
    try put_pull(&rig, "node1", "b3:00000004", 400, 99);
    const ctx = rig.world.controller_context();
    const junk: store.Op = .{ .put = .{ .key = "/pulls/node3/b3:00000005", .value = "{" } };
    _ = try writers.txn(ctx.store, .{ .agent = "node3" }, .{ .on_success = &.{junk} }, ctx.diag);

    const all = try rig.ok("/v1/stats/pull", "");
    const pulls = field(all, "pulls").array.items;
    try testing.expectEqual(@as(usize, 3), pulls.len);
    try testing.expectEqualStrings("b3:00000002", field(pulls[0], "tree").string);
    try testing.expectEqualStrings("b3:00000003", field(pulls[1], "tree").string);
    try testing.expectEqualStrings("b3:00000001", field(pulls[2], "tree").string);
    try testing.expectEqual(@as(i64, 1000), field(pulls[0], "registry_bytes").integer);
    const peer = field(pulls[0], "peer_bytes").array.items[0];
    try testing.expectEqualStrings("node2", field(peer, "peer").string);
    try testing.expectEqual(@as(i64, 2), field(all, "skipped").integer);
    try testing.expectEqual(false, field(all, "truncated").bool);
    try testing.expectEqual(@as(i64, 3), field(all, "matched").integer);

    const mine = try rig.ok("/v1/stats/pull", "node=node1");
    try testing.expectEqual(@as(usize, 2), field(mine, "pulls").array.items.len);
    const one = try rig.ok("/v1/stats/pull", "limit=1");
    try testing.expectEqual(@as(usize, 1), field(one, "pulls").array.items.len);
    const none = try rig.ok("/v1/stats/pull", "node=node9");
    try testing.expectEqual(@as(usize, 0), field(none, "pulls").array.items.len);
}

test "stats pull counts a stored row that names a peer that is not a node name as skipped" {
    // Goal: the read side of the agent endpoint's peer-name check. Method: one good pull and one
    // row stored with a bad peer name (written straight to the store, as a bug or another
    // writer could); the bad one is skipped, not served.
    var rig = try Rig.start(10);
    defer rig.stop();
    try put_pull(&rig, "node1", "b3:00000001", 100, 1);
    const ctx = rig.world.controller_context();
    const value =
        \\{"v":1,"node":"node1","tree":"b3:00000002","peer_bytes":[{"peer":"a b","bytes":1}]}
    ;
    const key = records.pull_key("node1", "b3:00000002");
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = value } };
    _ = try writers.txn(ctx.store, .{ .agent = "node1" }, .{ .on_success = &.{op} }, ctx.diag);
    const reply = try rig.ok("/v1/stats/pull", "");
    try testing.expectEqual(@as(usize, 1), field(reply, "pulls").array.items.len);
    try testing.expectEqual(@as(i64, 1), field(reply, "skipped").integer);
    try testing.expectEqual(@as(i64, 1), field(reply, "matched").integer);
}

test "stats pull stops at its read cap and says truncated instead of failing" {
    // Goal: more records than the cap (retention is eventual, so a cluster can hold them) is a
    // partial answer, not ZC-E0302. Method: cap + 5 pulls on two nodes; ask for 500; the reply
    // lists 500, matched is the cap, truncated is true, and a node-limited read is complete.
    var rig = try Rig.start(8);
    defer rig.stop();
    const total = constants.pulls_read_max + 5;
    for (0..total) |at| {
        var tree: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at});
        try put_pull(&rig, if (at < 10) "node2" else "node1", name, 1000 + at, 1);
    }
    const reply = try rig.ok("/v1/stats/pull", "limit=500");
    try testing.expectEqual(@as(usize, 500), field(reply, "pulls").array.items.len);
    try testing.expectEqual(@as(i64, constants.pulls_read_max), field(reply, "matched").integer);
    try testing.expectEqual(true, field(reply, "truncated").bool);
    const small = try rig.ok("/v1/stats/pull", "node=node2");
    try testing.expectEqual(false, field(small, "truncated").bool);
    try testing.expectEqual(@as(usize, 10), field(small, "pulls").array.items.len);
}

test "stats pull at its read cap with the largest records fits the request arena" {
    // Goal: constants.zig's claim that the cap's worst case fits `request_arena_bytes_max`, which
    // an arena that frees nothing makes easy to get wrong. Method: `pulls_read_max` + 5 records
    // each with the most peers, bad peers and longest names the agent endpoint accepts; one
    // request with limit 500; the arena's whole capacity must stay within the real limit.
    var rig = try Rig.start(9);
    defer rig.stop();
    const node: [constants.node_name_bytes_max]u8 = @splat('n');
    const peer: [constants.node_name_bytes_max]u8 = @splat('p');
    var peers: [constants.pull_peers_max]records.PullPeer = undefined;
    for (&peers) |*slot| slot.* = .{ .peer = &peer, .bytes = std.math.maxInt(u64) };
    var bad: [constants.pull_peers_max][]const u8 = undefined;
    for (&bad) |*slot| slot.* = &peer;
    var longest: usize = 0;
    for (0..constants.pulls_read_max + 5) |at| {
        const ctx = rig.world.controller_context();
        var tree: [64]u8 = @splat('t');
        _ = std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at}) catch unreachable; // 11 bytes fit in 64.
        const record: records.Pull = .{
            .node = &node,
            .tree = &tree,
            .registry_bytes = std.math.maxInt(u64),
            .peer_bytes = &peers,
            .cached_bytes = std.math.maxInt(u64),
            .started_at_ms = std.math.maxInt(u64),
            .finished_at_ms = 1000 + at,
            .bad_peers = &bad,
        };
        const bytes = try records.encode(ctx.arena, record, ctx.diag);
        try testing.expect(bytes.len <= constants.pull_record_bytes_max);
        longest = @max(longest, bytes.len);
        const key = records.pull_key(&node, &tree);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
        _ = try writers.txn(ctx.store, .{ .agent = &node }, .{ .on_success = &.{op} }, ctx.diag);
    }
    try testing.expect(longest > constants.pull_record_bytes_max / 2); // Really near the worst.

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rig.world.controller_context();
    ctx.arena = arena.allocator();
    const response = rig.api.handle(&ctx, .{
        .method = "GET",
        .path = "/v1/stats/pull",
        .query = "limit=500",
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    // Every byte the arena took, chunk overhead included, is at most what the real one allows.
    try testing.expect(arena.queryCapacity() <= constants.request_arena_bytes_max);
    try testing.expect(response.body.len > 400 * constants.pull_record_bytes_max / 2);
    try testing.expect(std.mem.indexOf(u8, response.body, "\"truncated\":true") != null);
}

test "stats pull with malformed rows near the cap says truncated, never ZC-E0302" {
    // Goal: docs/api.md's "never a failure" when rows that do not parse use up the pages. Method:
    // the cap's worth minus 10 valid pulls on node1, then three pages of rows on node2 that are
    // not JSON; the reply is 200 with truncated, and the skipped rows count toward the cap.
    var rig = try Rig.start(10);
    defer rig.stop();
    const valid = constants.pulls_read_max - 10;
    for (0..valid) |at| {
        var tree: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at});
        try put_pull(&rig, "node1", name, 1000 + at, 1);
    }
    const ctx = rig.world.controller_context();
    for (0..3 * constants.store_list_limit_max) |at| {
        var key: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&key, "/pulls/node2/b3:{x:0>8}", .{at});
        const op: store.Op = .{ .put = .{ .key = name, .value = "not json" } };
        _ = try writers.txn(ctx.store, .{ .agent = "node2" }, .{ .on_success = &.{op} }, ctx.diag);
    }
    const reply = try rig.ok("/v1/stats/pull", "limit=500");
    try testing.expectEqual(true, field(reply, "truncated").bool);
    try testing.expectEqual(@as(usize, valid), field(reply, "pulls").array.items.len);
    try testing.expectEqual(@as(i64, 10), field(reply, "skipped").integer);
}

test "stats pull refuses a bad node, a bad limit, an unknown parameter and an unknown kind" {
    // Goal: the handler's parameter checks. Method: one request each; every answer is a 400/404
    // with a code and the request's id.
    var rig = try Rig.start(4);
    defer rig.stop();
    try rig.refused(rig.get("/v1/stats/pull", "node=A%20B"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/stats/pull", "limit=0"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/stats/pull", "limit=501"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/stats/pull", "bogus=1"), 400, "ZC-E0104");
    try rig.refused(rig.get("/v1/stats/other", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/stats", ""), 404, "ZC-E0101");
}

test "the agent publishes the pull records its fetches left, and removes every file it read" {
    // Goal: slice 7's data path, agent side. Method: leave `pull.json` in three container
    // directories (a good record, one for another node, one that is not JSON) in the state
    // directory; one agent step stores the good one under /pulls/node1/ and removes all three.
    var rig = try Rig.start(5);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const files = rig.world.files.interface();
    const good =
        \\{"v":1,"node":"node1","tree":"b3:51aa9c03","registry_bytes":7,"finished_at_ms":9}
    ;
    const foreign = "{\"v\":1,\"node\":\"node2\",\"tree\":\"b3:51aa9c03\"}";
    try files.put_atomic("containers/hello-1/pull.json", good);
    try files.put_atomic("containers/hello-2/pull.json", foreign);
    try files.put_atomic("containers/hello-3/pull.json", "{");
    const stepped = rig.world.agent_step();
    try testing.expect(stepped.failed == null);
    // The two it dropped are counted and named, for ZC-W0504 (issue #93); the stored one is not.
    try testing.expectEqual(@as(u32, 2), rig.world.agent.pull_drops);
    try testing.expect(std.mem.startsWith(u8, rig.world.agent.pull_drop(), "container hello-"));

    const ctx = rig.world.controller_context();
    const options: store.ListOptions = .{ .prefix = records.prefix_pulls, .limit = 10 };
    const listed = try ctx.store.list(ctx.arena, options, ctx.diag);
    try testing.expectEqual(@as(usize, 1), listed.kvs.len);
    try testing.expectEqualStrings("/pulls/node1/b3:51aa9c03", listed.kvs[0].key);
    const names = [_][]const u8{
        "containers/hello-1/pull.json",
        "containers/hello-2/pull.json",
        "containers/hello-3/pull.json",
    };
    for (names) |name| {
        try testing.expectError(error.Absent, files.read(ctx.arena, name));
    }
}

/// The agent's files with `remove` failing as a host refusing it does; everything else passes
/// through to the simulated files.
const FailingRemove = struct {
    inner: agent_state.AgentState,
    removes: u32 = 0,

    const vtable: agent_state.AgentState.VTable = .{
        .put_atomic = put_atomic,
        .append = append,
        .read = read,
        .remove = remove,
        .list = list,
    };

    fn interface(self: *FailingRemove) agent_state.AgentState {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *FailingRemove {
        return @ptrCast(@alignCast(context));
    }

    fn put_atomic(context: *anyopaque, name: []const u8, data: []const u8) agent_state.Error!void {
        return from(context).inner.put_atomic(name, data);
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
        _ = name;
        from(context).removes += 1;
        return error.Io;
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        prefix: []const u8,
    ) agent_state.Error![]const []const u8 {
        return from(context).inner.list(arena, prefix);
    }
};

test "a pull record whose file cannot be removed is not counted as dropped, in any step" {
    // Goal: ZC-W0504's count is of records dropped, and a record is dropped only once its file is
    // gone (else each retried step would count it again). Method: a record for another node, every
    // remove failing; two steps both fail with the state-file code, `pull_drops` stays 0 and no
    // text is noted, though the remove was tried both times.
    var rig = try Rig.start(5);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const files = rig.world.files.interface();
    const foreign = "{\"v\":1,\"node\":\"node2\",\"tree\":\"b3:51aa9c03\"}";
    try files.put_atomic("containers/hello-2/pull.json", foreign);
    var failing: FailingRemove = .{ .inner = files };
    rig.world.state_override = failing.interface();
    for (0..2) |_| {
        const stepped = rig.world.agent_step();
        try testing.expect(stepped.failed != null);
        try testing.expectEqual(@as(u32, 0), rig.world.agent.pull_drops);
        try testing.expectEqual(@as(usize, 0), rig.world.agent.pull_drop().len);
        rig.world.advance(2000);
    }
    try testing.expect(failing.removes >= 2);
    // Once the host lets the remove through, the record is dropped and counted once.
    rig.world.state_override = null;
    rig.world.advance(2000);
    _ = rig.world.agent_step();
    try testing.expectEqual(@as(u32, 1), rig.world.agent.pull_drops);
}

test "a pull record the server refuses puts the server's cause into the drop text" {
    // Goal: ZC-W0504 names why a record was dropped. Method: a good record, a store that refuses
    // every write under /pulls/ with ZC-E0504 and a known cause; `pull_drop_text` is filled with a
    // known byte first, so a text that is not rewritten (or not cut at its length) shows.
    var rig = try Rig.start(5);
    defer rig.stop();
    _ = try rig.world.apply(hello);
    rig.world.advance(2000);
    const files = rig.world.files.interface();
    const good =
        \\{"v":1,"node":"node1","tree":"b3:51aa9c03","registry_bytes":7,"finished_at_ms":9}
    ;
    try files.put_atomic("containers/hello-1/pull.json", good);
    @memset(&rig.world.agent.pull_drop_text, 0xAA);
    rig.world.switched.refuse_put_prefix = records.prefix_pulls;
    const stepped = rig.world.agent_step();
    try testing.expect(stepped.failed == null);
    try testing.expectEqual(@as(u32, 1), rig.world.agent.pull_drops);
    const text = rig.world.agent.pull_drop();
    try testing.expect(std.mem.startsWith(u8, text, "container hello-1"));
    try testing.expect(std.mem.indexOf(u8, text, "the server refused the write") != null);
    try testing.expect(std.mem.indexOfScalar(u8, text, 0xAA) == null);
    const gone = files.read(rig.parsed.allocator(), "containers/hello-1/pull.json");
    try testing.expectError(error.Absent, gone);
}

test "a pull retention pass that fails is recorded and does not fail the controller step" {
    // Goal: statistics never hold replica work back. Method: an old pull record, every delete under
    // /pulls/ failing as an unreachable server does; the server steps without error, the replicas
    // of an applied service are placed, and the cursor says what failed and backs off; once the
    // store answers, the record is dropped and the failure is cleared.
    var rig = try Rig.start(7);
    defer rig.stop();
    try put_pull(&rig, "node1", "b3:00000001", 100, 1);
    rig.world.switched.down_write_prefix = "/pulls/";
    _ = try rig.world.apply(hello);
    rig.world.advance(3000);
    const cursor = &rig.world.server.replicas.pulls;
    try testing.expect(cursor.failing);
    try testing.expect(cursor.failures > 0);
    try testing.expectEqual(codes.Code.E0201, cursor.failure.code.?);
    try testing.expectEqual(@as(u32, 2), rig.world.running_count("hello"));
    rig.world.switched.down_write_prefix = null;
    rig.world.advance(constants.pulls_retry_ms + 3000);
    try testing.expect(!cursor.failing);
    try testing.expectEqual(@as(u64, 1), cursor.dropped);
}

fn job_json(rig: *Rig, name: []const u8, image: []const u8) ![]const u8 {
    const submit_by = rig.world.now_ms() + 30_000;
    return std.fmt.allocPrint(rig.parsed.allocator(),
        \\{{"name":"{s}","image":"{s}","command":["sh","-c","cat"],"env":[["API_TOKEN","s3cr3t"]],
    ++
        \\"deadline_ms":60000,"submit_by_ms":{d},"input":"top secret","input_env":"PAYLOAD",
    ++
        \\"labels":[["team","x"]]}}
    , .{ name, image, submit_by });
}

fn post_job(rig: *Rig, path: []const u8, body: []const u8) api_mod.Response {
    return rig.call(.{ .method = "POST", .path = path, .body = body });
}

test "a job body that does not parse says why, under ZC-E0104" {
    var rig = try Rig.start(1);
    defer rig.stop();
    const head = "{\"name\":\"x\",\"image\":\"i\",\"command\":[\"a\"],\"deadline_ms\":1,";
    const cases = [_]struct { body: []const u8, text: []const u8 }{
        .{
            .body = head ++ "\"submit_by_ms\":1,\"surprise\":1}",
            .text = "field the API does not know",
        },
        .{ .body = "{\"name\":\"x\"}", .text = "required field is missing" },
        .{ .body = head ++ "\"submit_by_ms\":\"soon\"}", .text = "wrong type, or a number" },
        .{ .body = head ++ "\"submit_by_ms\":-1}", .text = "wrong type, or a number" },
        .{ .body = head ++ "\"submit_by_ms\":1", .text = "ends too soon" },
        .{ .body = "nonsense", .text = "not valid JSON" },
    };
    for (cases) |case| {
        const response = post_job(&rig, "/v1/jobs", case.body);
        try rig.refused(response, 400, "ZC-E0104");
        if (std.mem.indexOf(u8, response.body, case.text) == null) {
            std.debug.print("want {s} in {s}\n", .{ case.text, response.body });
            return error.TestExpectedEqual;
        }
    }
}

test "the job routes: 201, 200, 409, GET without secrets, list, cancel 202, why" {
    // Goal: the status table of the b1 brief and the secrecy of env values and the input.
    var rig = try Rig.start(1);
    defer rig.stop();
    const body = try job_json(&rig, "nightly", "b3:51aa9c03");
    const created = post_job(&rig, "/v1/jobs", body);
    try testing.expectEqual(@as(u16, 201), created.status);
    try testing.expectEqual(@as(u16, 200), post_job(&rig, "/v1/jobs", body).status);
    const other = try job_json(&rig, "nightly", "b3:51aa9c04");
    try rig.refused(post_job(&rig, "/v1/jobs", other), 409, "ZC-E0131");
    const late = try std.fmt.allocPrint(rig.parsed.allocator(),
        \\{{"name":"late","image":"b3:51aa9c03","command":["true"],"deadline_ms":1,
    ++
        \\"submit_by_ms":1}}
    , .{});
    try rig.refused(post_job(&rig, "/v1/jobs", late), 410, "ZC-E0134");
    const unknown = "{\"name\":\"x\",\"image\":\"i\",\"command\":[\"a\"],\"deadline_ms\":1," ++
        "\"submit_by_ms\":1,\"surprise\":1}";
    try rig.refused(post_job(&rig, "/v1/jobs", unknown), 400, "ZC-E0104");

    const got = rig.get("/v1/jobs/nightly", "");
    try testing.expect(std.mem.indexOf(u8, got.body, "s3cr3t") == null);
    try testing.expect(std.mem.indexOf(u8, got.body, "top secret") == null);
    const view = try rig.json(got);
    const names = field(field(view, "job"), "env_names");
    try testing.expectEqualStrings("API_TOKEN", names.array.items[0].string);
    try testing.expectEqualStrings("pending", field(view, "state").string);
    try rig.refused(rig.get("/v1/jobs/nope", ""), 404, "ZC-E0133");

    const listed = try rig.ok("/v1/jobs", "label=team%3Dx");
    try testing.expectEqual(@as(usize, 1), field(listed, "jobs").array.items.len);
    try rig.refused(rig.get("/v1/jobs", "state=bogus"), 400, "ZC-E0104");

    const cancel = post_job(&rig, "/v1/jobs/nightly/cancel", "");
    try testing.expectEqual(@as(u16, 202), cancel.status);
    try rig.refused(post_job(&rig, "/v1/jobs/nope/cancel", ""), 404, "ZC-E0133");
    const why = try rig.ok("/v1/why/job/nightly", "");
    try testing.expect(why.object.count() > 0);
}

test "a read-only list shows no job env value and no job input" {
    var rig = try Rig.start(1);
    defer rig.stop();
    const created = post_job(&rig, "/v1/jobs", try job_json(&rig, "nightly", "b3:51aa9c03"));
    try testing.expectEqual(@as(u16, 201), created.status);
    const listed = rig.get("/v1/list", "prefix=%2Fjob");
    try testing.expectEqual(@as(u16, 200), listed.status);
    try testing.expect(std.mem.indexOf(u8, listed.body, "s3cr3t") == null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "dG9wIHNlY3JldA") == null);
}

test "the replies that change nothing carry the job's state, not pending" {
    // Goal: a client that retries a create after the job ended is told how it ended.
    var rig = try Rig.start(1);
    defer rig.stop();
    const body = try job_json(&rig, "short", "b3:51aa9c03");
    try testing.expectEqual(@as(u16, 201), post_job(&rig, "/v1/jobs", body).status);
    const ctx = rig.world.controller_context();
    const status: records.JobStatus = .{
        .state = .exited,
        .ended_at_ms = 1,
        .end = .{ .kind = .exited, .code = 0 },
        .reported_at_ms = 1,
    };
    var batch: controller.Batch = .{};
    const key = records.job_status_key("short");
    batch.put(try controller.key_copy(&ctx, &key), try records.encode(ctx.arena, status, ctx.diag));
    _ = try controller.commit(&ctx, .job_controller, &batch);
    const same = post_job(&rig, "/v1/jobs", body);
    try testing.expectEqual(@as(u16, 200), same.status);
    try testing.expectEqualStrings("exited", field(try rig.json(same), "state").string);
    const ended = post_job(&rig, "/v1/jobs/short/cancel", "");
    try testing.expectEqual(@as(u16, 200), ended.status);
    try testing.expectEqualStrings("exited", field(try rig.json(ended), "state").string);
    // Goal of the next lines: `state=ended` lists every terminal state and no other.
    const live = try job_json(&rig, "live", "b3:51aa9c03");
    try testing.expectEqual(@as(u16, 201), post_job(&rig, "/v1/jobs", live).status);
    const only_ended = try rig.ok("/v1/jobs", "state=ended");
    const rows = field(only_ended, "jobs").array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("short", field(rows[0], "name").string);
    const pending_rows = field(try rig.ok("/v1/jobs", "state=pending"), "jobs").array.items;
    try testing.expectEqual(@as(usize, 1), pending_rows.len);
    // A job without a status is pending in all three replies.
    const fresh = try job_json(&rig, "fresh", "b3:51aa9c03");
    try testing.expectEqual(@as(u16, 201), post_job(&rig, "/v1/jobs", fresh).status);
    const cancelled = post_job(&rig, "/v1/jobs/fresh/cancel", "");
    try testing.expectEqualStrings("pending", field(try rig.json(cancelled), "state").string);
    const again = post_job(&rig, "/v1/jobs/fresh/cancel", "");
    try testing.expectEqual(@as(u16, 202), again.status);
    try testing.expectEqualStrings("pending", field(try rig.json(again), "state").string);
}

test "a relay array filling the whole body is refused by name, without building it" {
    // Goal: `relay` is skipped, not parsed into a value 37 times its size, so the answer is
    // ZC-E0130 naming relay, not ZC-E0207 (the arena is spent).
    var rig = try Rig.start(1);
    defer rig.stop();
    const head = "{\"name\":\"big\",\"image\":\"b3:51aa9c03\",\"command\":[\"true\"]," ++
        "\"deadline_ms\":1000,\"submit_by_ms\":9999999999999,\"relay\":[";
    const tail = "0]}";
    const body = try rig.parsed.allocator().alloc(u8, constants.job_request_bytes_max);
    @memset(body, '0');
    @memcpy(body[0..head.len], head);
    var at: usize = head.len;
    while (at + 2 < body.len - tail.len) : (at += 2) {
        body[at] = '0';
        body[at + 1] = ',';
    }
    const rest = body.len - tail.len;
    @memset(body[at..rest], ' ');
    @memcpy(body[rest..], tail);
    // The parse runs in an arena of its own: every byte it took, chunk overhead included, is at
    // most what the production request arena allows.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = rig.world.controller_context();
    ctx.arena = arena.allocator();
    const response = rig.api.handle(&ctx, .{ .method = "POST", .path = "/v1/jobs", .body = body });
    try rig.refused(response, 400, "ZC-E0130");
    try testing.expect(std.mem.indexOf(u8, response.body, "relay") != null);
    try testing.expect(arena.queryCapacity() <= constants.request_arena_bytes_max);
}

test "the jobs watch decodes statuses, filters by label and refuses the name watch" {
    // Goal: api.md, "GET /v1/jobs/watch": status events with the decoded value, a label that
    // keeps only the matching jobs, 400 for a missing `from`, and no job named `watch`.
    var rig = try Rig.start(1);
    defer rig.stop();
    const body = try job_json(&rig, "short", "b3:51aa9c03");
    try testing.expectEqual(@as(u16, 201), post_job(&rig, "/v1/jobs", body).status);
    const ctx = rig.world.controller_context();
    const status: records.JobStatus = .{
        .state = .exited,
        .epoch = 9,
        .ended_at_ms = 1,
        .end = .{ .kind = .exited, .code = 0 },
        .reported_at_ms = 1,
    };
    var batch: controller.Batch = .{};
    const key = records.job_status_key("short");
    batch.put(try controller.key_copy(&ctx, &key), try records.encode(ctx.arena, status, ctx.diag));
    _ = try controller.commit(&ctx, .job_controller, &batch);

    const all = try rig.ok("/v1/jobs/watch", "from=1&timeout=0");
    const events = field(all, "events").array.items;
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqualStrings("put", field(events[0], "type").string);
    try testing.expectEqualStrings("short", field(events[0], "name").string);
    const got = field(events[0], "status");
    try testing.expectEqualStrings("exited", field(got, "state").string);
    try testing.expectEqual(@as(i64, 9), field(got, "epoch").integer);
    try testing.expectEqual(@as(i64, 1), field(got, "ended_at_ms").integer);
    const head = field(all, "revision").integer;

    // A label no job carries keeps nothing, and the bookmark still moves.
    const none = try rig.ok("/v1/jobs/watch", "from=1&timeout=0&label=team%3Dnobody");
    try testing.expectEqual(@as(usize, 0), field(none, "events").array.items.len);
    try testing.expectEqual(head, field(none, "revision").integer);
    // A revision the store has not reached is the generic watch's 400.
    try rig.refused(rig.get("/v1/jobs/watch", "timeout=0&from=1000000"), 400, "ZC-E0204");
    try rig.refused(rig.get("/v1/jobs/watch", "timeout=0"), 400, "ZC-E0104");
    const named = try job_json(&rig, "watch", "b3:51aa9c03");
    try rig.refused(post_job(&rig, "/v1/jobs", named), 400, "ZC-E0130");
}

/// A job body with the given extra members (JSON text, starting with a comma or empty).
fn relay_body(rig: *Rig, name: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(rig.parsed.allocator(),
        \\{{"name":"{s}","image":"b3:51aa9c03","command":["true"],"deadline_ms":60000,
    ++
        \\"submit_by_ms":{d}{s}}}
    , .{ name, rig.world.now_ms() + 30_000, extra });
}

test "a job names a relay the server configures; any other name or an env override is refused" {
    // Goal: B3 admission. A configured name is admitted, shown by name and keeps the address out
    // of the spec view; an unknown name, a non-string, and a job that sets ZCUBE_RELAY itself
    // are ZC-E0130 naming the field.
    var rig = try Rig.start(1);
    defer rig.stop();
    const table = [_]records.JobRelay{.{ .name = "botpike", .address = "127.0.0.1:9" }};
    rig.api.relays = &table;
    const good = try relay_body(&rig, "r1", ",\"relay\":\"botpike\"");
    try testing.expectEqual(@as(u16, 201), post_job(&rig, "/v1/jobs", good).status);
    try testing.expectEqual(@as(u16, 200), post_job(&rig, "/v1/jobs", good).status);
    const got = rig.call(.{ .method = "GET", .path = "/v1/jobs/r1" });
    try testing.expect(std.mem.indexOf(u8, got.body, "\"relay\":\"botpike\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "127.0.0.1") == null);

    const cases = [_]struct { extra: []const u8, field: []const u8 }{
        .{ .extra = ",\"relay\":\"nope\"", .field = "relay" },
        .{ .extra = ",\"relay\":3", .field = "relay" },
        .{ .extra = ",\"relay\":\"botpike\",\"env\":[[\"ZCUBE_RELAY\",\"x\"]]", .field = "env" },
        .{ .extra = ",\"env\":[[\"ZCUBE_RELAY\",\"x\"]]", .field = "env" },
        // The input is given in a variable too: it must not be the relay's, relayed or not.
        .{
            .extra = ",\"relay\":\"botpike\",\"input\":\"x\",\"input_env\":\"ZCUBE_RELAY\"",
            .field = "input_env",
        },
        .{ .extra = ",\"input\":\"x\",\"input_env\":\"ZCUBE_RELAY\"", .field = "input_env" },
    };
    for (cases, 0..) |case, index| {
        var name: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "bad{d}", .{index});
        const response = post_job(&rig, "/v1/jobs", try relay_body(&rig, text, case.extra));
        try rig.refused(response, 400, "ZC-E0130");
        try testing.expect(std.mem.indexOf(u8, response.body, case.field) != null);
    }
}

// ---- Rollouts and history (C3 slice 11) --------------------------------------------------------

/// Puts a rollout of `hello` as the rollout controller would (slice 7 is not in this build: the
/// tests hold the record contract of slices 5 and 6, docs/keys.md).
fn put_rollout(rig: *Rig, phase: records.RolloutPhase, created: ?u64) !void {
    const ctx = rig.world.controller_context();
    const service = try ctx.store.get(ctx.arena, "/services/hello", null, ctx.diag);
    const rollout: records.Rollout = .{
        .service = "hello",
        .service_created = created orelse service.kv.?.create_revision,
        .from = 1,
        .to = 2,
        .phase = phase,
        .started_at_ms = sim_world.epoch_ms,
        .deadline_at_ms = sim_world.epoch_ms + 600_000,
        .budget = .{ .start = 1, .retire = 1 },
    };
    const bytes = try records.encode(ctx.arena, rollout, ctx.diag);
    const op: store.Op = .{ .put = .{ .key = "/rollouts/hello", .value = bytes } };
    _ = try writers.txn(ctx.store, .rollout_controller, .{ .on_success = &.{op} }, ctx.diag);
}

fn rollout_post(rig: *Rig, verb: []const u8, body: []const u8) !api_mod.Response {
    const arena = rig.parsed.allocator();
    const path = try std.fmt.allocPrint(arena, "/v1/services/hello/rollout/{s}", .{verb});
    return rig.call(.{ .method = "POST", .path = path, .body = body });
}

test "GET /v1/services/{name}/history lists the generations newest first, env redacted" {
    var rig = try Rig.start(31);
    defer rig.stop();
    _ = try rig.json(post(&rig, "", hello_json));
    const changed = try std.mem.replaceOwned(u8, rig.parsed.allocator(), hello_json, "9c03", "9c04");
    _ = try rig.json(post(&rig, "", changed));
    const body = try rig.ok("/v1/services/hello/history", "");
    try testing.expectEqual(@as(i64, 2), field(body, "generation").integer);
    const generations = field(body, "generations").array.items;
    try testing.expectEqual(@as(usize, 2), generations.len);
    try testing.expectEqual(@as(i64, 2), field(generations[0], "generation").integer);
    try testing.expectEqual(@as(i64, 1), field(generations[1], "generation").integer);
    const value = field(generations[0], "value");
    try testing.expectEqualStrings("b3:51aa9c04", field(value, "image").string);
    const env = field(value, "env").array.items;
    try testing.expectEqualStrings("API_TOKEN", env[0].array.items[0].string);
    try testing.expect(env[0].array.items[1] == .null);
    try rig.refused(rig.get("/v1/services/nope/history", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/services/hello/other", ""), 404, "ZC-E0101");
}

test "GET .../rollout answers null, then the record; pause and resume write it, ZC-E0129 else" {
    // Goal: docs/api.md, "Rollouts and history": status is a read, pause and resume are writes
    // to the rollout record by the rollout controller's role (rollout_steer.zig).
    var rig = try Rig.start(32);
    defer rig.stop();
    _ = try rig.json(post(&rig, "", hello_json));
    const none = try rig.ok("/v1/services/hello/rollout", "");
    try testing.expect(field(none, "rollout") == .null);
    try testing.expectEqual(@as(i64, 2), field(none, "replicas").integer);
    try rig.refused(try rollout_post(&rig, "pause", ""), 409, "ZC-E0129");

    try put_rollout(&rig, .progressing, null);
    const running = try rig.ok("/v1/services/hello/rollout", "");
    try testing.expectEqualStrings("progressing", field(field(running, "rollout"), "phase").string);

    const paused = try rollout_post(&rig, "pause", "{\"applied_by\":\"alex@laptop\"}");
    const paused_body = try rig.json(paused);
    try testing.expectEqual(@as(u16, 200), paused.status);
    try testing.expectEqualStrings("pause", field(paused_body, "action").string);
    try testing.expectEqualStrings("paused", field(paused_body, "phase").string);
    try testing.expectEqualStrings("progressing → paused", field(paused_body, "change").string);
    try testing.expect(field(paused_body, "decision").string.len > 0);
    const record = field(try rig.ok("/v1/services/hello/rollout", ""), "rollout");
    try testing.expectEqualStrings("user", field(record, "paused_by").string);
    try testing.expectEqual(@as(i64, 0), field(field(record, "budget"), "start").integer);

    const again = try rig.json(try rollout_post(&rig, "pause", ""));
    try testing.expectEqualStrings("none", field(again, "action").string);
    const resumed = try rig.json(try rollout_post(&rig, "resume", ""));
    try testing.expectEqualStrings("progressing", field(resumed, "phase").string);

    try put_rollout(&rig, .complete, null);
    try rig.refused(try rollout_post(&rig, "resume", ""), 409, "ZC-E0129");
    try put_rollout(&rig, .progressing, 999_999);
    const stale = try rig.ok("/v1/services/hello/rollout", "");
    try testing.expect(field(stale, "rollout") == .null);
    try rig.refused(try rollout_post(&rig, "pause", ""), 409, "ZC-E0129");
    try rig.refused(try rollout_post(&rig, "stop", ""), 404, "ZC-E0101");
    try rig.refused(try rollout_post(&rig, "pause", "[1]"), 400, "ZC-E0104");
    const missing = rig.call(.{ .method = "POST", .path = "/v1/services/nope/rollout/pause" });
    try rig.refused(missing, 404, "ZC-E0101");
}

test "POST /v1/apply takes health and rollout, and refuses invalid ones" {
    var rig = try Rig.start(33);
    defer rig.stop();
    const with_policy =
        \\{"name":"hello","image":"b3:51aa9c03","replicas":2,"command":["sh"],
        \\ "health":{"command":["true"],"interval_ms":1000,"timeout_ms":500,
        \\  "failure_threshold":3,"success_threshold":1},"rollout":{"max_surge":2}}
    ;
    const applied = post(&rig, "", with_policy);
    if (applied.status != 200) std.debug.print("{s}\n", .{applied.body});
    try testing.expectEqual(@as(u16, 200), applied.status);
    const status = try rig.ok("/v1/services/hello/rollout", "");
    try testing.expectEqual(@as(i64, 2), field(field(status, "policy"), "max_surge").integer);
    const bad =
        \\{"name":"hello","image":"b3:51aa9c03","replicas":2,"command":["sh"],
        \\ "rollout":{"max_surge":0,"max_unavailable":0}}
    ;
    try rig.refused(post(&rig, "", bad), 400, "ZC-E0126");
}
