//! Tests of the agent's side of HTTP (`agent_remote.zig`, `agent_http.zig`) against a live server:
//! `Server` in this process on a port the system picks, with the SQLite store in a temporary
//! file, the real clock and real threads, as `server_test.zig` does. Test code, so it may sleep.
//!
//! What they cover: the `Store` calls the agent core makes, one by one, against the real
//! endpoints; the wait between steps; the failures (a server that is not there, a lease that has
//! ended, a call the agent does not make); and, last, the agent core itself over HTTP, with the
//! simulated runtime: the whole path of C0 except real processes, which `agent-smoke` covers.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;
const agent_mod = @import("agent.zig");
const clock_mod = @import("agent_clock.zig");
const codes = @import("diag/codes.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const http = @import("agent_http.zig");
const records = @import("records.zig");
const remote_mod = @import("agent_remote.zig");
const server_mod = @import("server.zig");
const sim_runtime = @import("sim_runtime.zig");
const store = @import("store.zig");

const Diag = diag_mod.Diag;

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

/// A live server on SQLite in a temporary directory.
const Rig = struct {
    test_io: TestIo,
    io: std.Io,
    tmp: testing.TmpDir,
    path: []u8,
    server: *server_mod.Server,
    http_transport: remote_mod.HttpTransport,
    remote: remote_mod.RemoteStore,
    clock_source: clock_mod.RealClock,

    fn start() !*Rig {
        const rig = try testing.allocator.create(Rig);
        errdefer testing.allocator.destroy(rig);
        rig.io = rig.test_io.start();
        errdefer rig.test_io.stop();
        rig.tmp = testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        var buffer: [constants.state_path_bytes_max]u8 = undefined;
        const length = try rig.tmp.dir.realPath(rig.io, &buffer);
        rig.path = try std.fmt.allocPrint(testing.allocator, "{s}/store.db", .{buffer[0..length]});
        errdefer testing.allocator.free(rig.path);
        rig.server = try start_server(rig.io, rig.path, true);
        errdefer rig.server.stop();
        rig.http_transport = .{
            .client = .{ .io = rig.io, .address = rig.server.address() },
        };
        rig.remote = remote_mod.RemoteStore.init(
            testing.allocator,
            rig.http_transport.transport(),
            "node1",
        );
        rig.clock_source = .{ .io = rig.io };
        return rig;
    }

    fn stop(rig: *Rig) void {
        rig.server.stop();
        testing.allocator.free(rig.path);
        rig.tmp.cleanup();
        rig.test_io.stop();
        testing.allocator.destroy(rig);
    }

    /// The server stops and starts again over the same file: the store is the only state. The
    /// agent's client is pointed at the new port.
    fn restart_server(rig: *Rig) !void {
        rig.server.stop();
        rig.server = try start_server(rig.io, rig.path, false);
        rig.http_transport.client.address = rig.server.address();
    }

    /// A request to the public API, for the things a person does (apply).
    fn post(rig: *Rig, path: []const u8, body: []const u8) !u16 {
        const client: http.Client = .{ .io = rig.io, .address = rig.server.address() };
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var diag: Diag = undefined;
        diag.reset();
        const reply = try client.call(arena_state.allocator(), .{
            .method = "POST",
            .target = path,
            .body = body,
        }, &diag);
        return reply.status;
    }

    fn apply(rig: *Rig, replicas: u32) !void {
        var body: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &body,
            "{{\"name\":\"hello\",\"image\":\"b3:51aa9c03\",\"replicas\":{d}," ++
                "\"command\":[\"sh\",\"-c\",\"sleep 1\"],\"env\":[[\"TOKEN\",\"s3cr3t\"]]}}",
            .{replicas},
        );
        try testing.expectEqual(@as(u16, 200), try rig.post("/v1/apply", text));
    }

    /// Polls until `check` is true, up to ten seconds.
    fn wait_for(rig: *Rig, comptime check: fn (*Rig) anyerror!bool) !void {
        for (0..1000) |_| {
            if (try check(rig)) return;
            try rig.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.TimedOut;
    }
};

fn start_server(io: std.Io, path: []const u8, create: bool) !*server_mod.Server {
    var diag: Diag = undefined;
    diag.reset();
    const config: config_mod.Config = .{
        .listen = config_mod.parse_listen("127.0.0.1:0", &diag) catch unreachable, // A literal.
        .store = .{ .sqlite = path },
        .create_store = create,
        .verbose = false,
        .quiet = true,
    };
    return server_mod.Server.start(testing.allocator, io, config, .{
        .version = "0.0.0-test",
        .report_failures = false,
        .log_requests = false,
    }, &diag) catch |err| {
        if (diag.code) |code| std.debug.print("server did not start: {s}\n", .{@tagName(code)});
        return err;
    };
}

fn register_op(lease: store.LeaseId) store.Op {
    return .{ .put = .{ .key = "/nodes/node1", .value = node_json, .lease = lease } };
}

const node_json = "{\"v\":1,\"name\":\"node1\",\"agent_version\":\"0.0.0\",\"address\":\"\"," ++
    "\"capacity\":{\"cpu_millis\":4000,\"memory_bytes\":8589934592}}";

test "a node joins: lease, registration, keepalive, and a lease that has ended" {
    // Goal: the join of docs/api.md through HTTP and the SQLite store, as the core makes the
    // calls. Method: grant, register on the lease (the key must carry it), renew, then let a
    // short lease run out: its renewal is `LeaseNotFound`, which is what makes the core grant
    // again.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var diag: Diag = undefined;
    diag.reset();
    const lease = try remote.lease_grant(10_000, &diag);
    try testing.expect(lease.id != store.lease_none);
    try testing.expectEqual(@as(u32, 10_000), lease.ttl_ms);
    const put = register_op(lease.id);
    const done = try remote.txn(.{ .on_success = &.{put} }, &diag);
    try testing.expect(done.succeeded);
    try testing.expect(done.revision > 0);
    const renewed = try remote.lease_keepalive(lease.id, &diag);
    try testing.expectEqual(lease.id, renewed.id);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const direct = rig.server.shared.store;
    const got = try direct.get(arena_state.allocator(), "/nodes/node1", null, &diag);
    try testing.expectEqual(lease.id, got.kv.?.lease);

    const short = try remote.lease_grant(constants.lease_ttl_ms_min, &diag);
    try rig.io.sleep(.fromMilliseconds(constants.lease_ttl_ms_min + 200), .awake);
    diag.reset();
    try testing.expectError(error.LeaseNotFound, remote.lease_keepalive(short.id, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0205), diag.code);

    // A ttl outside the store's range is refused by the `Store` wrapper before anything is sent;
    // the server's own refusal of it (ZC-E0206) is in agent_api_test.zig.
    diag.reset();
    try testing.expectError(error.TooLarge, remote.lease_grant(5, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0206), diag.code);
}

test "a server that is not there is ZC-E0503, and the same store works when it returns" {
    // Goal: the failure the agent lives with while the server restarts. Method: stop the server
    // (its port is closed), make a call, start it again over the same file and make the call
    // again; the lease granted before the stop is still the store's.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var diag: Diag = undefined;
    diag.reset();
    const lease = try remote.lease_grant(10_000, &diag);

    rig.server.stop();
    try testing.expectError(error.BackendFailed, remote.lease_grant(10_000, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0503), diag.code);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "127.0.0.1") != null);

    rig.server = try start_server(rig.io, rig.path, false);
    rig.http_transport.client.address = rig.server.address();
    diag.reset();
    const renewed = try remote.lease_keepalive(lease.id, &diag);
    try testing.expectEqual(lease.id, renewed.id);
}

test "the node's replicas come back with env values, and its reports go in and out" {
    // Goal: list and txn through the real endpoints and the real store. Method: apply a service
    // with a secret and let the server's controller place its replicas on node1 (a node must be
    // registered first); list them; report one observed record and delete another; read back.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var diag: Diag = undefined;
    diag.reset();
    const lease = try remote.lease_grant(10_000, &diag);
    const put = register_op(lease.id);
    _ = try remote.txn(.{ .on_success = &.{put} }, &diag);
    try rig.apply(2);

    const Ready = struct {
        fn two(inner: *Rig) anyerror!bool {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            var local: Diag = undefined;
            local.reset();
            const page = try inner.remote.interface().list(arena_state.allocator(), .{
                .prefix = records.prefix_replicas,
                .limit = constants.store_list_limit_max,
            }, &local);
            return page.kvs.len == 2;
        }
    };
    try rig.wait_for(Ready.two);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page = try remote.list(arena, .{
        .prefix = records.prefix_replicas,
        .limit = constants.store_list_limit_max,
    }, &diag);
    try testing.expectEqual(@as(usize, 2), page.kvs.len);
    try testing.expect(page.revision > 0);
    try testing.expect(std.mem.startsWith(u8, page.kvs[0].key, "/replicas/hello/hello-"));
    try testing.expect(std.mem.indexOf(u8, page.kvs[0].value, "s3cr3t") != null);
    const replica = try records.read(records.Replica, arena, page.kvs[0], &diag);
    try testing.expectEqualStrings("node1", replica.node);

    const first = "{\"v\":1,\"replica\":\"hello-1\",\"node\":\"node1\",\"generation\":1," ++
        "\"status\":\"running\",\"started_at_ms\":1,\"reported_at_ms\":2}";
    const second = "{\"v\":1,\"replica\":\"hello-2\",\"node\":\"node1\",\"generation\":1," ++
        "\"status\":\"running\",\"reported_at_ms\":2}";
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/observed/node1/hello-1", .value = first } },
        .{ .put = .{ .key = "/observed/node1/hello-2", .value = second } },
    };
    _ = try remote.txn(.{ .on_success = &ops }, &diag);
    const prefix = records.observed_prefix("node1");
    var seen = try remote.list(arena, .{ .prefix = prefix.slice(), .limit = 500 }, &diag);
    try testing.expectEqual(@as(usize, 2), seen.kvs.len);
    const drop = [_]store.Op{.{ .delete = "/observed/node1/hello-1" }};
    _ = try remote.txn(.{ .on_success = &drop }, &diag);
    seen = try remote.list(arena, .{ .prefix = prefix.slice(), .limit = 500 }, &diag);
    try testing.expectEqual(@as(usize, 1), seen.kvs.len);
    try testing.expectEqualStrings("/observed/node1/hello-2", seen.kvs[0].key);
}

test "what the agent never does is a bug report, not a wrong answer" {
    // Goal: the adapter refuses calls outside the agent's few, with ZC-B0001 and nothing sent.
    // Method: get, status, watch, a transaction with a compare, a write outside the node's keys.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectError(error.BackendFailed, remote.status(&diag));
    try testing.expectEqual(@as(?codes.Code, .B0001), diag.code);
    diag.reset();
    try testing.expectError(
        error.BackendFailed,
        remote.get(arena_state.allocator(), "/services/x", null, &diag),
    );
    diag.reset();
    const compare: store.Compare = .{ .key = "/observed/node1/a", .mod_revision = 0 };
    const put: store.Op = .{ .put = .{ .key = "/observed/node1/a", .value = "{}" } };
    try testing.expectError(error.BackendFailed, remote.txn(.{
        .compares = &.{compare},
        .on_success = &.{put},
    }, &diag));
    diag.reset();
    const stray: store.Op = .{ .put = .{ .key = "/services/x", .value = "{}" } };
    try testing.expectError(error.BackendFailed, remote.txn(.{ .on_success = &.{stray} }, &diag));
    try testing.expectEqual(@as(?codes.Code, .B0001), diag.code);
}

test "the wait ends at once for a change and holds to its time when there is none" {
    // Goal: `watch_once`, the wait between steps. Method: before any list it says "changed" (it
    // cannot know); after a list it holds for the time given; after an apply and the controller's
    // placing of replicas it says "changed" well inside its time.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expect(try rig.remote.watch_once(100, &diag));
    const lease = try remote.lease_grant(10_000, &diag);
    const put = register_op(lease.id);
    _ = try remote.txn(.{ .on_success = &.{put} }, &diag);
    _ = try remote.list(arena_state.allocator(), .{
        .prefix = records.prefix_replicas,
        .limit = constants.store_list_limit_max,
    }, &diag);

    const began = std.Io.Clock.real.now(rig.io);
    try testing.expect(!try rig.remote.watch_once(300, &diag));
    const quiet_ms = began.durationTo(std.Io.Clock.real.now(rig.io)).toMilliseconds();
    try testing.expect(quiet_ms >= 250);

    try rig.apply(1);
    const woke = std.Io.Clock.real.now(rig.io);
    try testing.expect(try rig.remote.watch_once(5000, &diag));
    const woke_ms = woke.durationTo(std.Io.Clock.real.now(rig.io)).toMilliseconds();
    try testing.expect(woke_ms < 4000);
}

test "the agent core over HTTP: start, replace a killed replica, survive a server restart" {
    // Goal: C0's loop across the real boundary, with the simulated runtime in place of processes.
    // Method: a live server (its controller runs), the agent core with `RemoteStore`; apply 2,
    // step until two run; kill one in the runtime; step until a replacement runs; restart the
    // server over the same file; a few more steps change nothing.
    var rig = try Rig.start();
    defer rig.stop();
    var sim: sim_runtime.SimRuntime = undefined;
    sim.init(testing.allocator, rig.clock_source.clock(), 7, &sim_runtime.default_fixtures);
    defer sim.deinit();
    const agent = try testing.allocator.create(agent_mod.Agent);
    defer testing.allocator.destroy(agent);
    agent.init(.{
        .node = "node1",
        .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
    });
    try rig.apply(2);

    try step_until(rig, agent, &sim, 2);
    try testing.expectEqual(@as(u32, 2), sim.running_count());
    var names: [2]runtime_name = undefined;
    try running_names(rig, &names);
    try sim.inject(names[0].slice(), .{ .signal = 9 });
    try step_until(rig, agent, &sim, 2);
    var after: [2]runtime_name = undefined;
    try running_names(rig, &after);
    try testing.expect(!std.mem.eql(u8, names[0].slice(), after[0].slice()) or
        !std.mem.eql(u8, names[0].slice(), after[1].slice()));

    try rig.restart_server();
    for (0..10) |_| {
        const acted = try step(rig, agent, &sim);
        try testing.expectEqual(@as(u32, 0), acted);
        try rig.io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expectEqual(@as(u32, 2), sim.running_count());
}

const runtime_name = struct {
    bytes: [63]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const runtime_name) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One step of the agent core against the live server; the number of transactions it made.
fn step(rig: *Rig, agent: *agent_mod.Agent, sim: *sim_runtime.SimRuntime) !u32 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: agent_mod.Context = .{
        .store = rig.remote.interface(),
        .runtime = sim.interface(),
        .clock = rig.clock_source.clock(),
        .arena = arena_state.allocator(),
        .diag = &diag,
    };
    const wake = agent.reconcile(&ctx) catch |err| {
        if (diag.code) |code| std.debug.print("agent step: {s}\n", .{@tagName(code)});
        return err;
    };
    return wake.acted;
}

/// Steps until `count` containers run and the last step did nothing, up to ten seconds.
fn step_until(
    rig: *Rig,
    agent: *agent_mod.Agent,
    sim: *sim_runtime.SimRuntime,
    count: u32,
) !void {
    for (0..500) |_| {
        const acted = try step(rig, agent, sim);
        const observed = try observed_running(rig);
        if (acted == 0 and sim.running_count() == count and observed == count) return;
        try rig.io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.TimedOut;
}

fn observed_running(rig: *Rig) !u32 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const page = try rig.server.shared.store.list(arena_state.allocator(), .{
        .prefix = "/observed/node1/",
        .limit = constants.store_list_limit_max,
    }, &diag);
    var running: u32 = 0;
    for (page.kvs) |kv| {
        if (std.mem.indexOf(u8, kv.value, "\"status\":\"running\"") != null) running += 1;
    }
    return running;
}

fn running_names(rig: *Rig, out: *[2]runtime_name) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const page = try rig.server.shared.store.list(arena_state.allocator(), .{
        .prefix = "/observed/node1/",
        .limit = constants.store_list_limit_max,
    }, &diag);
    var found: usize = 0;
    for (page.kvs) |kv| {
        if (std.mem.indexOf(u8, kv.value, "\"status\":\"running\"") == null) continue;
        const name = kv.key["/observed/node1/".len..];
        out[found].len = @intCast(name.len);
        @memcpy(out[found].bytes[0..name.len], name);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 2), found);
}
