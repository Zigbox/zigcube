//! Tests of the API handlers (`api.zig`) against the simulation world: a real controller, a real
//! agent and the memory store behind the API, so each answer is the answer to a real state. The
//! requests are bytes in, and the answers are parsed back from the bytes that come out.

const std = @import("std");
const testing = std.testing;
const api_mod = @import("api.zig");
const apply_mod = @import("apply.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
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
    try testing.expectEqual(codes.Code.E0201, cursor.failure_code.?);
    try testing.expectEqual(@as(u32, 2), rig.world.running_count("hello"));
    rig.world.switched.down_write_prefix = null;
    rig.world.advance(constants.pulls_retry_ms + 3000);
    try testing.expect(!cursor.failing);
    try testing.expectEqual(@as(u64, 1), cursor.dropped);
}
