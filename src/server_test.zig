//! Tests of `zcube-server` as a running server: real sockets on 127.0.0.1, real threads, the real
//! clock. They start `Server` in-process on a port the system picks, talk to it with plain
//! HTTP/1.1 over a socket, and stop it. Test code, so it may use threads (docs/STYLE.md).
//!
//! What they cover: routing (the API, the console, what is neither), request ids, the limits of
//! constants.zig (body, head, connections), and the acceptance criterion of HANDOFF C0, that
//! restarting `zcube-server` changes nothing because the store is the only state, on SQLite,
//! with a simulated agent keeping a service running while the server restarts.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;
const agent_mod = @import("agent.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const server_mod = @import("server.zig");
const server_store = @import("server_store.zig");
const sim_runtime = @import("sim_runtime.zig");

const Diag = diag_mod.Diag;
const Json = std.json.Value;

/// A threaded `Io` with room for a server's tasks, owned by the test.
const TestIo = struct {
    threaded: std.Io.Threaded,

    fn start(self: *TestIo) std.Io {
        const room = constants.http_connections_max + constants.http_refusals_max +
            constants.server_threads_extra + 8;
        self.threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(room) });
        return self.threaded.io();
    }

    fn stop(self: *TestIo) void {
        self.threaded.deinit();
    }
};

fn config_for(store: config_mod.Store, create: bool) config_mod.Config {
    var diag: Diag = undefined;
    diag.reset();
    return .{
        .listen = config_mod.parse_listen("127.0.0.1:0", &diag) catch unreachable, // A literal.
        .store = store,
        .create_store = create,
        .verbose = false,
        .quiet = true,
    };
}

fn start_server(io: std.Io, config: config_mod.Config) !*server_mod.Server {
    var diag: Diag = undefined;
    diag.reset();
    return server_mod.Server.start(testing.allocator, io, config, .{
        .version = "0.0.0-test",
        .report_failures = false,
        .log_requests = false,
    }, &diag) catch |err| {
        if (diag.code) |code| std.debug.print("server did not start: {s}\n", .{@tagName(code)});
        return err;
    };
}

// ---- A client: one request per connection, read to the end --------------------------------------

const Reply = struct {
    status: u16,
    /// Everything before the blank line.
    head: []const u8,
    body: []const u8,
    raw: []u8,

    fn header(reply: Reply, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, reply.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }

    fn free(reply: Reply) void {
        testing.allocator.free(reply.raw);
    }

    fn json(reply: Reply, arena: std.mem.Allocator) !Json {
        return std.json.parseFromSliceLeaky(Json, arena, reply.body, .{});
    }
};

fn exchange(io: std.Io, address: net.IpAddress, request: []const u8) !Reply {
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const raw = try reader.interface.allocRemaining(testing.allocator, .limited(16 * 1024 * 1024));
    errdefer testing.allocator.free(raw);
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse return error.NoHead;
    return .{
        .status = try std.fmt.parseInt(u16, raw[9..12], 10),
        .head = raw[0..split],
        .body = raw[split + 4 ..],
        .raw = raw,
    };
}

fn get(io: std.Io, address: net.IpAddress, path: []const u8) !Reply {
    var buffer: [1024]u8 = undefined;
    const format = "GET {s} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n";
    return exchange(io, address, try std.fmt.bufPrint(&buffer, format, .{path}));
}

fn send(
    io: std.Io,
    address: net.IpAddress,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !Reply {
    const request = try std.fmt.allocPrint(
        testing.allocator,
        "{s} {s} HTTP/1.1\r\nHost: test\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method, path, body.len, body },
    );
    defer testing.allocator.free(request);
    return exchange(io, address, request);
}

fn expect_diagnostic(reply: Reply, status: u16, code: []const u8) !void {
    if (reply.status != status) std.debug.print("{s}\n", .{reply.raw});
    try testing.expectEqual(status, reply.status);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const body = try reply.json(arena_state.allocator());
    const first = body.object.get("diagnostics").?.array.items[0];
    try testing.expectEqualStrings(code, first.object.get("code").?.string);
    const id = body.object.get("request_id").?.string;
    try testing.expectEqualStrings(id, reply.header("x-request-id").?);
}

const hello_json =
    \\{"name":"hello","image":"b3:51aa9c03","replicas":2,"command":["sh","-c","sleep 1"]}
;

// ---- Tests --------------------------------------------------------------------------------------

test "the server routes the API and the console, and every reply has a request id" {
    // Goal: docs/api.md "Request ID" and the route table of the shell. Method: start on the memory
    // store; ask for status, the page, a script, the module, a path that is nothing, a wrong method
    // on the page and on the API; send a request id of our own and a bad one.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const server = try start_server(io, config_for(.memory, false));
    defer server.stop();
    const address = server.address();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const status = try get(io, address, "/v1/status");
    defer status.free();
    try testing.expectEqual(@as(u16, 200), status.status);
    try testing.expectEqualStrings("application/json", status.header("content-type").?);
    try testing.expect(status.header("x-request-id").?.len >= constants.request_id_bytes_min);
    const body = try status.json(arena_state.allocator());
    const backend = body.object.get("store").?.object.get("backend").?;
    try testing.expectEqualStrings("memory", backend.string);

    const page = try get(io, address, "/");
    defer page.free();
    try testing.expectEqual(@as(u16, 200), page.status);
    try testing.expect(std.mem.startsWith(u8, page.header("content-type").?, "text/html"));
    const policy = page.header("content-security-policy").?;
    try testing.expect(std.mem.indexOf(u8, policy, "default-src 'self'") != null);
    const console = try get(io, address, "/console/");
    defer console.free();
    try testing.expectEqualStrings(page.body, console.body);
    const script = try get(io, address, "/console/js/main.js");
    defer script.free();
    try testing.expectEqual(@as(u16, 200), script.status);
    const module = try get(io, address, "/console/sim/zcube_console.wasm");
    defer module.free();
    try testing.expectEqualStrings("application/wasm", module.header("content-type").?);
    try testing.expectEqualSlices(u8, "\x00asm", module.body[0..4]);

    const nothing = try get(io, address, "/nothing");
    defer nothing.free();
    try expect_diagnostic(nothing, 404, "ZC-E0101");
    const wrong_page = try send(io, address, "POST", "/", "{}");
    defer wrong_page.free();
    try expect_diagnostic(wrong_page, 405, "ZC-E0104");
    const wrong_api = try send(io, address, "PUT", "/v1/apply", hello_json);
    defer wrong_api.free();
    try expect_diagnostic(wrong_api, 400, "ZC-E0104");

    const own = "GET /v1/status HTTP/1.1\r\nConnection: close\r\n" ++
        "X-Request-Id: my-request-0001\r\n\r\n";
    const echoed = try exchange(io, address, own);
    defer echoed.free();
    try testing.expectEqualStrings("my-request-0001", echoed.header("x-request-id").?);
    const bad = "GET /v1/status HTTP/1.1\r\nConnection: close\r\nX-Request-Id: no good\r\n\r\n";
    const refused = try exchange(io, address, bad);
    defer refused.free();
    try expect_diagnostic(refused, 400, "ZC-E0104");
    try testing.expect(!std.mem.eql(u8, "no good", refused.header("x-request-id").?));
}

test "the limits of constants.zig are enforced with a coded reply" {
    // Goal: body, head and connection limits each end in a registered diagnostic, not a hang or a
    // bare status. Method: a body over the limit, a head over the limit, a chunked body, then
    // `http_connections_max` idle connections and one more.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const server = try start_server(io, config_for(.memory, false));
    defer server.stop();
    const address = server.address();

    const too_big = "POST /v1/apply HTTP/1.1\r\nConnection: close\r\nContent-Length: 65537\r\n\r\n";
    const big = try exchange(io, address, too_big);
    defer big.free();
    try expect_diagnostic(big, 413, "ZC-E0108");

    const chunked = "POST /v1/apply HTTP/1.1\r\nConnection: close\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n";
    const unsized = try exchange(io, address, chunked);
    defer unsized.free();
    try expect_diagnostic(unsized, 411, "ZC-E0104");

    const padding = try testing.allocator.alloc(u8, constants.http_head_bytes_max);
    defer testing.allocator.free(padding);
    @memset(padding, 'a');
    const long_head = try std.fmt.allocPrint(
        testing.allocator,
        "GET /v1/status HTTP/1.1\r\nConnection: close\r\nX-Padding: {s}\r\n\r\n",
        .{padding},
    );
    defer testing.allocator.free(long_head);
    const oversize = try exchange(io, address, long_head);
    defer oversize.free();
    try expect_diagnostic(oversize, 431, "ZC-E0108");

    // Fill every slot with a connection that sends nothing; the next one is told so and closed.
    var idle: [constants.http_connections_max]net.Stream = undefined;
    for (&idle) |*stream| stream.* = try address.connect(io, .{ .mode = .stream });
    defer for (idle) |stream| stream.close(io);
    var tries: u32 = 0;
    while (server.connections() < constants.http_connections_max) : (tries += 1) {
        try testing.expect(tries < 500);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const full = try get(io, address, "/v1/status");
    defer full.free();
    try expect_diagnostic(full, 503, "ZC-E0108");
}

test "a client that goes quiet is closed by the watchdog, not kept for ever" {
    // Goal: a slow client cannot hold a slot for ever. Method: connect, send half a head, wait for
    // the idle timeout, and see the server close the connection and free the slot. Takes about
    // `http_idle_timeout_ms` plus a watchdog period.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const server = try start_server(io, config_for(.memory, false));
    defer server.stop();
    var stream = try server.address().connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /v1/sta");
    try writer.interface.flush();
    var tries: u32 = 0;
    while (server.connections() == 0) : (tries += 1) {
        try testing.expect(tries < 500);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const limit_ms = constants.http_idle_timeout_ms + 3 * constants.http_watchdog_ms;
    var waited_ms: u32 = 0;
    while (server.connections() > 0) : (waited_ms += 50) {
        try testing.expect(waited_ms <= limit_ms + 2000);
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    const earliest = constants.http_idle_timeout_ms - 2 * constants.http_watchdog_ms;
    try testing.expect(waited_ms >= earliest);
}

test "a held watch ends when a key under its prefix changes, and times out empty otherwise" {
    // Goal: the long poll of docs/api.md through the real shell. Method: hold a watch on
    // /services/ for 5 s on one thread and apply a service from another; the answer arrives with
    // the event, long before 5 s. A watch on another prefix is held to its timeout and is empty.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const server = try start_server(io, config_for(.memory, false));
    defer server.stop();
    const address = server.address();

    const Held = struct {
        fn ask(h_io: std.Io, h_address: net.IpAddress, path: []const u8, out: *?Reply) void {
            out.* = get(h_io, h_address, path) catch null;
        }
    };
    var answer: ?Reply = null;
    const path = "/v1/watch?from=1&timeout=5000&prefix=%2Fservices%2F";
    var future = try io.concurrent(Held.ask, .{ io, address, path, &answer });
    var tries: u32 = 0;
    while (server.holds() == 0) : (tries += 1) {
        try testing.expect(tries < 500);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const started = std.Io.Clock.real.now(io);
    const applied = try send(io, address, "POST", "/v1/apply", hello_json);
    defer applied.free();
    try testing.expectEqual(@as(u16, 200), applied.status);
    future.await(io);
    defer if (answer) |reply| reply.free();
    const took_ms = started.durationTo(std.Io.Clock.real.now(io)).toMilliseconds();
    try testing.expect(took_ms < 2000);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const body = try answer.?.json(arena_state.allocator());
    const events = body.object.get("events").?.array.items;
    try testing.expect(events.len > 0);
    const first_key = events[0].object.get("kv").?.object.get("key").?;
    try testing.expectEqualStrings("/services/hello", first_key.string);

    const quiet = try get(io, address, "/v1/watch?from=999&timeout=0");
    defer quiet.free();
    try expect_diagnostic(quiet, 400, "ZC-E0204");
    const idle_start = std.Io.Clock.real.now(io);
    const idle = try get(io, address, "/v1/watch?from=1&timeout=700&prefix=%2Fnodes%2F");
    defer idle.free();
    try testing.expectEqual(@as(u16, 200), idle.status);
    const idle_ms = idle_start.durationTo(std.Io.Clock.real.now(io)).toMilliseconds();
    try testing.expect(idle_ms >= 600);
    try testing.expect(std.mem.indexOf(u8, idle.body, "\"events\":[]") != null);
    try testing.expectEqual(@as(u32, 0), server.holds());
}

test "held watches are bounded: one past http_holds_max is a 503 with a coded reply" {
    // Goal: the limit on concurrent long polls. Method: hold `http_holds_max` watches, ask for one
    // more and get ZC-E0108; a write ends every hold and the slots are free again.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const server = try start_server(io, config_for(.memory, false));
    defer server.stop();
    const address = server.address();

    const Held = struct {
        fn ask(h_io: std.Io, h_address: net.IpAddress, out: *?Reply) void {
            const path = "/v1/watch?from=1&timeout=20000&prefix=%2Fservices%2F";
            out.* = get(h_io, h_address, path) catch null;
        }
    };
    var answers: [constants.http_holds_max]?Reply = @splat(null);
    defer for (answers) |answer| if (answer) |reply| reply.free();
    var futures: [constants.http_holds_max]std.Io.Future(void) = undefined;
    for (&futures, &answers) |*future, *answer| {
        future.* = try io.concurrent(Held.ask, .{ io, address, answer });
    }
    var tries: u32 = 0;
    while (server.holds() < constants.http_holds_max) : (tries += 1) {
        try testing.expect(tries < 1000);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const over = try get(io, address, "/v1/watch?from=1&timeout=20000&prefix=%2Fservices%2F");
    defer over.free();
    try expect_diagnostic(over, 503, "ZC-E0108");

    const applied = try send(io, address, "POST", "/v1/apply", hello_json);
    defer applied.free();
    for (&futures) |*future| future.await(io);
    for (answers) |answer| {
        try testing.expectEqual(@as(u16, 200), answer.?.status);
        try testing.expect(std.mem.indexOf(u8, answer.?.body, "/services/hello") != null);
    }
    try testing.expectEqual(@as(u32, 0), server.holds());
}

test "a port in use, and a store that is not there, are coded start-up failures" {
    // Goal: DIAGNOSTICS for start-up. Method: start a server, start another on its port (ZC-E0107,
    // environment); open a SQLite file that does not exist without --create-store (ZC-E0201).
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    const first = try start_server(io, config_for(.memory, false));
    defer first.stop();
    var taken = config_for(.memory, false);
    taken.listen = first.address();
    var diag: Diag = undefined;
    diag.reset();
    const options: server_mod.Options = .{ .version = "0.0.0-test" };
    const in_use = server_mod.Server.start(testing.allocator, io, taken, options, &diag);
    try testing.expectError(error.StartFailed, in_use);
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0107), diag.code);
    try testing.expectEqual(constants.exit_environment, diag.exit_code());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const format = ".zig-cache/tmp/{s}/missing.db";
    const path = try std.fmt.bufPrint(&path_buffer, format, .{tmp.sub_path});
    diag.reset();
    const missing = config_for(.{ .sqlite = path }, false);
    const absent = server_mod.Server.start(testing.allocator, io, missing, options, &diag);
    try testing.expectError(error.StartFailed, absent);
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0201), diag.code);
}

// ---- Restart safety (HANDOFF C0 acceptance) -----------------------------------------------------

/// The part of the cluster that is not the server: a simulated node agent over the same store,
/// stepped by the test, so a service really runs while the server starts and stops.
const Node = struct {
    agent: *agent_mod.Agent,
    runtime: *sim_runtime.SimRuntime,
    arena: std.heap.ArenaAllocator,
    store: @import("store.zig").Store,
    /// The node's own clock: it outlives any one server, so it cannot be a server's.
    real: server_store.RealClock,
    diag: Diag,

    fn start(io: std.Io, store: @import("store.zig").Store) !*Node {
        const node = try testing.allocator.create(Node);
        node.real = .{ .io = io };
        node.agent = try testing.allocator.create(agent_mod.Agent);
        node.runtime = try testing.allocator.create(sim_runtime.SimRuntime);
        node.runtime.init(testing.allocator, node.real.clock(), 1, &sim_runtime.default_fixtures);
        node.agent.init(.{
            .node = "node1",
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
            .address = "10.0.0.5:7070",
        });
        node.arena = std.heap.ArenaAllocator.init(testing.allocator);
        node.store = store;
        node.diag.reset();
        return node;
    }

    fn stop(node: *Node) void {
        node.arena.deinit();
        node.runtime.deinit();
        testing.allocator.destroy(node.runtime);
        testing.allocator.destroy(node.agent);
        testing.allocator.destroy(node);
    }

    /// One step of the agent. A store that fails the step is the test's to see in the result.
    fn step(node: *Node) !void {
        _ = node.arena.reset(.retain_capacity);
        node.diag.reset();
        const ctx: agent_mod.Context = .{
            .store = node.store,
            .runtime = node.runtime.interface(),
            .clock = node.real.clock(),
            .arena = node.arena.allocator(),
            .diag = &node.diag,
        };
        _ = node.agent.reconcile(&ctx) catch return error.AgentStepFailed;
    }
};

/// The keys and modification revisions under `/`, as one string: what "nothing changed" compares.
fn fingerprint(io: std.Io, address: net.IpAddress, arena: std.mem.Allocator) ![]const u8 {
    const reply = try get(io, address, "/v1/list?prefix=%2F&limit=500");
    defer reply.free();
    try testing.expectEqual(@as(u16, 200), reply.status);
    const body = try reply.json(arena);
    var text: std.ArrayList(u8) = .empty;
    try text.print(arena, "rev={d}\n", .{body.object.get("revision").?.integer});
    for (body.object.get("kvs").?.array.items) |kv| {
        try text.print(arena, "{s} {d}\n", .{
            kv.object.get("key").?.string, kv.object.get("mod_revision").?.integer,
        });
    }
    return text.items;
}

test "restarting the server changes nothing: apply, run, restart, compare (SQLite)" {
    // Goal: HANDOFF C0 acceptance, "restarting zcube-server mid-demo changes nothing", for the
    // real server on the real SQLite store. Method: start a server on a new file, apply `hello`
    // with 2 replicas over HTTP, let a simulated agent run them, record every key and revision,
    // stop the server, start another on the same file, let both controllers settle, and compare.
    // The second server must also have run controller steps, or "nothing changed" proves nothing.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/zcube.db", .{tmp.sub_path});
    const store_spec: config_mod.Store = .{ .sqlite = path };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try start_server(io, config_for(store_spec, true));
    var first_open = true;
    defer if (first_open) first.stop();
    const node = try Node.start(io, first.backend.handle());
    defer node.stop();

    const status = try get(io, first.address(), "/v1/status");
    defer status.free();
    const status_body = try status.json(arena);
    const store_part = status_body.object.get("store").?;
    try testing.expectEqualStrings("sqlite", store_part.object.get("backend").?.string);
    try testing.expect(store_part.object.get("ok").?.bool);

    const applied = try send(io, first.address(), "POST", "/v1/apply", hello_json);
    defer applied.free();
    try testing.expectEqual(@as(u16, 200), applied.status);
    try run_until_running(io, first, node, 2);

    const listed = try get(io, first.address(), "/v1/list?prefix=%2Fservices%2F");
    defer listed.free();
    const listed_body = try listed.json(arena);
    try testing.expectEqual(@as(usize, 1), listed_body.object.get("kvs").?.array.items.len);
    const before = try fingerprint(io, first.address(), arena);

    // The restart: the server goes away and a new process-worth of server opens the same file.
    // The agent, which is not part of the server, keeps its containers.
    const containers = node.runtime.containers.items.len;
    first.stop();
    first_open = false;
    const second = try start_server(io, config_for(store_spec, false));
    defer second.stop();
    node.store = second.backend.handle();
    for (0..40) |_| {
        try node.step();
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expect(second.steps() > 0);
    const after = try fingerprint(io, second.address(), arena);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(containers, node.runtime.containers.items.len);
    try testing.expectEqual(@as(u32, 2), node.runtime.running_count());
}

/// Steps the agent until the service shows `count` replicas running, through the API's own
/// `why`, or fails after a few seconds.
fn run_until_running(io: std.Io, server: *server_mod.Server, node: *Node, count: u32) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var expected: [64]u8 = undefined;
    const format = "service hello: {d}/{d} running";
    const want = try std.fmt.bufPrint(&expected, format, .{ count, count });
    for (0..200) |_| {
        try node.step();
        const reply = try get(io, server.address(), "/v1/why/service/hello");
        defer reply.free();
        if (reply.status == 200) {
            const body = try reply.json(arena_state.allocator());
            const text = body.object.get("state").?.object.get("text").?.string;
            if (std.mem.eql(u8, text, want)) return;
        }
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.NeverConverged;
}

test "request ids are not issued twice across server starts" {
    // Goal: DIAGNOSTICS, "every API request gets a request ID" so a client's error can be matched
    // to a log: a restart must not repeat the ids of the start before it. Method: start, ask, stop,
    // start again, ask; the first ids differ, and so do the counters' first values.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    var seen: [2][64]u8 = undefined;
    var lengths: [2]usize = undefined;
    for (&seen, &lengths) |*buffer, *length| {
        const server = try start_server(io, config_for(.memory, false));
        defer server.stop();
        const reply = try get(io, server.address(), "/v1/status");
        defer reply.free();
        const id = reply.header("x-request-id").?;
        @memcpy(buffer[0..id.len], id);
        length.* = id.len;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(!std.mem.eql(u8, seen[0][0..lengths[0]], seen[1][0..lengths[1]]));
}
