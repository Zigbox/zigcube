//! Tests of the API handlers (`api.zig`) against the simulation world: a real controller, a real
//! agent and the memory store behind the API, so each answer is the answer to a real state. The
//! requests are bytes in, and the answers are parsed back from the bytes that come out.

const std = @import("std");
const testing = std.testing;
const api_mod = @import("api.zig");
const apply_mod = @import("apply.zig");
const codes = @import("diag/codes.zig");
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
    try testing.expectEqualStrings("ZBX-E0501", field(failure, "code").string);
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
    try testing.expectEqual(@as(u16, 410), api_mod.status_for(.E0203, .user));
    try testing.expectEqual(@as(u16, 400), api_mod.status_for(.E0204, .user));
    try testing.expectEqual(@as(u16, 503), api_mod.status_for(.E0207, .environment));
    try testing.expectEqual(@as(u16, 503), api_mod.status_for(.E0201, .external));
    try testing.expectEqual(@as(u16, 502), api_mod.status_for(.E0202, .external));
    try testing.expectEqual(@as(u16, 500), api_mod.status_for(.B0001, .internal));
}

test "codes lists both registries and the placeholders; explain prints what the CLI prints" {
    // Goal: api.md, "GET /v1/codes and /v1/explain": Zigcube's codes, Zigbox's, and the
    // placeholder ZBX-E0501; the long text is the CLI's text.
    var rig = try Rig.start(9);
    defer rig.stop();
    const listed = try rig.ok("/v1/codes", "");
    var seen_zc = false;
    var seen_placeholder = false;
    for (field(listed, "codes").array.items) |entry| {
        const code = field(entry, "code").string;
        if (std.mem.eql(u8, code, "ZC-E0101")) seen_zc = true;
        if (std.mem.eql(u8, code, "ZBX-E0501")) seen_placeholder = true;
    }
    try testing.expect(seen_zc and seen_placeholder);

    const explained = try rig.ok("/v1/explain/ZC-E0203", "");
    const text = field(explained, "explanation").string;
    const head = "ZC-E0203: that revision was compacted away\n";
    try testing.expect(std.mem.startsWith(u8, text, head));
    var buffer: [@import("constants.zig").diag_output_bytes_max]u8 = undefined;
    const cli = @import("diag.zig").explain(.E0203, &buffer);
    try testing.expectEqualStrings(cli, text);

    const runtime_text = try rig.ok("/v1/explain/ZBX-E0501", "");
    const placeholder = field(runtime_text, "explanation").string;
    try testing.expect(std.mem.indexOf(u8, placeholder, "image") != null);
    try rig.refused(rig.get("/v1/explain/ZC-E9999", ""), 404, "ZC-E0101");
    try rig.refused(rig.get("/v1/explain/ZBX-E9999", ""), 404, "ZC-E0101");
}
