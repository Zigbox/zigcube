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
const assert = std.debug.assert;
const net = std.Io.net;
const agent_mod = @import("agent.zig");
const agent_peer = @import("agent_peer.zig");
const clock_mod = @import("agent_clock.zig");
const codes = @import("diag/codes.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const http = @import("agent_http.zig");
const private_dir = @import("testing/private_dir.zig");
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
    /// Null while no server runs: between a stop and a start that failed, so that teardown
    /// never stops one server twice.
    server: ?*server_mod.Server,
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
        errdefer rig.stop_server();
        rig.http_transport = .{
            .client = .{ .io = rig.io, .address = rig.live().address() },
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
        rig.stop_server();
        testing.allocator.free(rig.path);
        rig.tmp.cleanup();
        rig.test_io.stop();
        testing.allocator.destroy(rig);
    }

    /// The server stops and starts again over the same file: the store is the only state. The
    /// agent's client is pointed at the new port.
    fn restart_server(rig: *Rig) !void {
        try rig.restart_server_on(.{ .sqlite = rig.path }, false, null);
    }

    /// Stops the server and starts one over `store_config`. If the start fails, no server runs
    /// and `stop` still tears the rig down.
    fn restart_server_on(
        rig: *Rig,
        store_config: config_mod.Store,
        create: bool,
        diag: ?*Diag,
    ) !void {
        rig.stop_server();
        try rig.start_server_again(store_config, create, diag);
    }

    /// Starts a server after `stop_server`, and points the agent's client at its port. With
    /// `diag`, a failure is the caller's to check and nothing is printed.
    fn start_server_again(
        rig: *Rig,
        store_config: config_mod.Store,
        create: bool,
        diag: ?*Diag,
    ) !void {
        assert(rig.server == null);
        rig.server = if (diag) |into|
            try start_server_diag(rig.io, store_config, create, into)
        else
            try start_server_on(rig.io, store_config, create);
        assert(rig.server != null);
        rig.http_transport.client.address = rig.live().address();
    }

    /// Stops the server if one runs; stopping none is allowed, so teardown may always call it.
    fn stop_server(rig: *Rig) void {
        if (rig.server) |server| server.stop();
        rig.server = null;
    }

    /// The running server; a test that reaches for it while none runs is a bug in the test.
    fn live(rig: *Rig) *server_mod.Server {
        return rig.server.?;
    }

    /// A request to the public API, for the things a person does (apply).
    fn post(rig: *Rig, path: []const u8, body: []const u8) !u16 {
        const client: http.Client = .{ .io = rig.io, .address = rig.live().address() };
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
    return start_server_on(io, .{ .sqlite = path }, create);
}

fn start_server_on(io: std.Io, store_config: config_mod.Store, create: bool) !*server_mod.Server {
    var diag: Diag = undefined;
    diag.reset();
    return start_server_diag(io, store_config, create, &diag) catch |err| {
        if (diag.code) |code| std.debug.print("server did not start: {s}\n", .{@tagName(code)});
        return err;
    };
}

/// Starts a server; a failure leaves its diagnostic in `diag` and prints nothing.
fn start_server_diag(
    io: std.Io,
    store_config: config_mod.Store,
    create: bool,
    diag: *Diag,
) !*server_mod.Server {
    var parse_diag: Diag = undefined;
    parse_diag.reset();
    const config: config_mod.Config = .{
        .listen = config_mod.parse_listen("127.0.0.1:0", &parse_diag) catch unreachable, // A literal.
        .store = store_config,
        .create_store = create,
        .verbose = false,
        .quiet = true,
    };
    try private_dir.state_dir(io, config);
    return server_mod.Server.start(testing.allocator, io, config, .{
        .version = "0.0.0-test",
        .report_failures = false,
        .log_requests = false,
    }, diag);
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
    const direct = rig.live().shared.store;
    const got = try direct.get(arena_state.allocator(), "/nodes/node1", null, &diag);
    try testing.expectEqual(lease.id, got.kv.?.lease);

    // The server grants its own ttl whatever is asked; a revoked lease is a lease that ended.
    const short = try remote.lease_grant(constants.lease_ttl_ms_min, &diag);
    try testing.expectEqual(constants.lease_ttl_ms, short.ttl_ms);
    _ = try direct.lease_revoke(short.id, &diag);
    diag.reset();
    try testing.expectError(error.LeaseNotFound, remote.lease_keepalive(short.id, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0205), diag.code);

    // A ttl outside the store's range is refused by the `Store` wrapper before anything is sent;
    // the server's own refusal of it (ZC-E0206) is in agent_api_test.zig.
    diag.reset();
    try testing.expectError(error.TooLarge, remote.lease_grant(5, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0206), diag.code);
}

test "a server that cannot start again leaves the rig safe to stop" {
    // Goal: teardown after a partial start. A restart stops the server and then fails to start
    // one; the rig must not stop the old server a second time. Method: restart over a SQLite
    // path whose directory lies under the store file, so the state directory cannot be made;
    // the restart fails, and the deferred `stop` must run cleanly (it used to segfault).
    var rig = try Rig.start();
    defer rig.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const path = try std.fmt.allocPrint(arena_state.allocator(), "{s}/state/store.db", .{
        rig.path,
    });
    var diag: Diag = undefined;
    diag.reset();
    if (rig.restart_server_on(.{ .sqlite = path }, true, &diag)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expectEqual(@as(?codes.Code, .E0201), diag.code);
    try testing.expect(rig.server == null);
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

    rig.stop_server();
    try testing.expectError(error.BackendFailed, remote.lease_grant(10_000, &diag));
    try testing.expectEqual(@as(?codes.Code, .E0503), diag.code);
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "127.0.0.1") != null);

    try rig.start_server_again(.{ .sqlite = rig.path }, false, null);
    diag.reset();
    const renewed = try remote.lease_keepalive(lease.id, &diag);
    try testing.expectEqual(lease.id, renewed.id);
}

test "a memory-store server restarts under the agent: nothing is refused, nothing is kept" {
    // Goal: M1 of the slice 10b review. A memory store starts empty each time, and the server
    // says so (`"verified": false` in `chain`), so the agent neither refuses its answers as a
    // rollback nor keeps a pair to compare. Method: register against a memory server, check the
    // agent keeps nothing and notes it once, start a fresh memory server and call it again: the
    // revision went back to the start, and the call is answered.
    var rig = try Rig.start();
    defer rig.stop();
    try rig.restart_server_on(.memory, false, null);
    const remote = rig.remote.interface();
    var diag: Diag = undefined;
    diag.reset();
    for (0..3) |_| {
        const lease = try remote.lease_grant(10_000, &diag);
        const done = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, &diag);
        try testing.expect(done.succeeded);
    }
    try testing.expect(rig.remote.known == null);
    try testing.expectEqual(@as(?remote_mod.client.Notice, .unverified), rig.remote.take_notice());

    try rig.restart_server_on(.memory, false, null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    diag.reset();
    const options: store.ListOptions = .{ .prefix = records.prefix_replicas, .limit = 10 };
    const page = try remote.list(arena_state.allocator(), options, &diag);
    try testing.expectEqual(@as(usize, 0), page.kvs.len);
    const lease = try remote.lease_grant(10_000, &diag);
    const done = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, &diag);
    try testing.expect(done.succeeded);
    try testing.expectEqual(@as(?codes.Code, null), diag.code);
    try testing.expect(rig.remote.known == null);
    try testing.expectEqual(@as(?remote_mod.client.Notice, null), rig.remote.take_notice());
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
    const joined = try remote.txn(.{ .on_success = &.{put} }, &diag);
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
    try testing.expectEqualStrings("hello", replica.service);

    // A record names the tenure of the request that carries it.
    const first = try std.fmt.allocPrint(arena, "{{\"v\":1,\"replica\":\"hello-1\"," ++
        "\"node\":\"node1\",\"generation\":1,\"status\":\"running\",\"started_at_ms\":1," ++
        "\"reported_at_ms\":2,\"tenure\":{d}}}", .{joined.revision});
    const second = try std.fmt.allocPrint(arena, "{{\"v\":1,\"replica\":\"hello-2\"," ++
        "\"node\":\"node1\",\"generation\":1,\"status\":\"running\",\"reported_at_ms\":2," ++
        "\"tenure\":{d}}}", .{joined.revision});
    const ops = [_]store.Op{
        .{ .put = .{ .key = "/observed/node1/hello-1", .value = first } },
        .{ .put = .{ .key = "/observed/node1/hello-2", .value = second } },
    };
    const tenure = [_]store.Compare{.{ .key = "/nodes/node1", .mod_revision = joined.revision }};
    _ = try remote.txn(.{ .compares = &tenure, .on_success = &ops }, &diag);
    const prefix = records.observed_prefix("node1");
    var seen = try remote.list(arena, .{ .prefix = prefix.slice(), .limit = 500 }, &diag);
    try testing.expectEqual(@as(usize, 2), seen.kvs.len);
    const drop = [_]store.Op{.{ .delete = "/observed/node1/hello-1" }};
    _ = try remote.txn(.{ .compares = &tenure, .on_success = &drop }, &diag);
    seen = try remote.list(arena, .{ .prefix = prefix.slice(), .limit = 500 }, &diag);
    try testing.expectEqual(@as(usize, 1), seen.kvs.len);
    try testing.expectEqualStrings("/observed/node1/hello-2", seen.kvs[0].key);
}

test "a pull record goes in under the tenure; a stale tenure is refused" {
    // Goal: RemoteStore.pull reaches agent_api.pull over real HTTP and the real store. Method: join
    // node1, put a pull record under the tenure and read it back; the same put under a tenure that
    // has ended is not applied and leaves the store as it was.
    var rig = try Rig.start();
    defer rig.stop();
    const remote = rig.remote.interface();
    var diag: Diag = undefined;
    diag.reset();
    const lease = try remote.lease_grant(10_000, &diag);
    const joined = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, &diag);
    // Stamped now: the server's pull retention would drop a record dated 1970.
    const finished_ms = std.Io.Clock.real.now(rig.io).toMilliseconds();
    var body_buffer: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"v\":1,\"node\":\"node1\",\"tree\":\"b3:aa\",\"registry_bytes\":9," ++
            "\"started_at_ms\":{d},\"finished_at_ms\":{d}}}",
        .{ finished_ms - 5, finished_ms },
    );
    const put: store.Op = .{ .put = .{ .key = "/pulls/node1/b3:aa", .value = body } };
    const ended = joined.revision + 50;
    const stale = [_]store.Compare{.{ .key = "/nodes/node1", .mod_revision = ended }};
    const refused = try remote.txn(.{ .compares = &stale, .on_success = &.{put} }, &diag);
    try testing.expect(!refused.succeeded);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const held = [_]store.Compare{.{ .key = "/nodes/node1", .mod_revision = joined.revision }};
    const done = try remote.txn(.{ .compares = &held, .on_success = &.{put} }, &diag);
    try testing.expect(done.succeeded);
    const direct = rig.live().shared.store;
    const page = try direct.list(arena, .{ .prefix = "/pulls/node1/", .limit = 10 }, &diag);
    try testing.expectEqual(@as(usize, 1), page.kvs.len);
    const record = try records.read(records.Pull, arena, page.kvs[0], &diag);
    try testing.expectEqual(@as(u64, 9), record.registry_bytes);
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
    const page = try rig.live().shared.store.list(arena_state.allocator(), .{
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
    const page = try rig.live().shared.store.list(arena_state.allocator(), .{
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

/// A node is issued a credential only while registered under a live lease (finding 3): refused
/// unregistered and under another lease; then registers and returns the lease.
fn register_after_refusals(
    rig: *Rig,
    identity: *agent_peer.Peer,
    arena: std.mem.Allocator,
    wall: u64,
    diag: *Diag,
) !store.Lease {
    try testing.expectError(
        error.Failed,
        identity.step(rig.http_transport.transport(), arena, 1, wall, 3000, diag),
    );
    // The agent reports the server's refusal, which carries E0205 in its cause.
    try testing.expectEqual(@as(?codes.Code, .E0504), diag.code);
    try testing.expect(identity.credential == null);
    diag.reset();
    const remote = rig.remote.interface();
    const lease = try remote.lease_grant(10_000, diag);
    _ = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, diag);
    identity.retry_at_ms = 0; // The refusal above set a pause.
    try testing.expectError(
        error.Failed,
        identity.step(rig.http_transport.transport(), arena, lease.id + 1, wall, 3000, diag),
    );
    diag.reset();
    identity.retry_at_ms = 0;
    return lease;
}

/// Writes the server's `revoked` file in `state_dir`, 0600 whatever the umask: the server refuses
/// a revoked file other users can write.
fn write_revoked(io: std.Io, state_dir: []const u8, data: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, state_dir, .{});
    defer dir.close(io);
    const flags: std.Io.Dir.CreateFileOptions = .{ .permissions = .fromMode(0o600) };
    try dir.writeFile(io, .{ .sub_path = "revoked", .data = data, .flags = flags });
}

test "a node joins the CA, keeps its pair, renews at half life, is refused once removed" {
    // Goal: docs/peer.md's issuance, persistence, renewal and removal through real HTTP and the
    // real files. Method: join; restart the server (the CA key is the same) and the peer (the
    // stored pair is reused, nothing is due); step at the renewal time; then list the node as
    // removed (the server's `revoked` file, read at start) and see ZC-E0807, the old pair kept.
    var rig = try Rig.start();
    defer rig.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var base: [constants.state_path_bytes_max]u8 = undefined;
    const base_length = try rig.tmp.dir.realPath(rig.io, &base);
    const state_dir = try std.fmt.allocPrint(arena, "{s}/agent", .{base[0..base_length]});

    var identity = try agent_peer.Peer.open(rig.io, state_dir, "node1", &diag);
    defer identity.close();
    try testing.expect(identity.credential == null);
    const wall = rig.clock_source.clock().now_ms();
    const lease = try register_after_refusals(rig, &identity, arena, wall, &diag);
    try identity.step(rig.http_transport.transport(), arena, lease.id, wall, 3000, &diag);
    const first = identity.credential.?;
    try testing.expect(identity.ca_public != null);
    const life_ms = first.not_after_ms - first.not_before_ms;
    try testing.expectEqual(@as(u64, constants.peer_credential_ttl_ms), life_ms);
    for ([_][]const u8{ "peer.key", "peer.cred", "ca.pub" }) |name| {
        var dir = try std.Io.Dir.cwd().openDir(rig.io, state_dir, .{});
        defer dir.close(rig.io);
        const file = try dir.openFile(rig.io, name, .{});
        defer file.close(rig.io);
        const stat = try file.stat(rig.io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    try testing.expect(!identity.due(wall + 1000));

    // The server restarts over the same state directory: the same CA, so the stored pair holds.
    try rig.restart_server();
    var again = try agent_peer.Peer.open(rig.io, state_dir, "node1", &diag);
    defer again.close();
    try testing.expectEqualSlices(u8, &first.node_key, &again.credential.?.node_key);
    try testing.expectEqual(identity.ca_public.?, again.ca_public.?);
    try testing.expect(!again.due(wall + 1000));

    // Renewal at half the life: a new credential, signed by the same CA.
    const renew_at = again.renew_at_ms;
    try testing.expect(again.due(renew_at));
    try again.step(rig.http_transport.transport(), arena, lease.id, renew_at, 3000, &diag);
    try testing.expect(again.credential.?.not_before_ms >= first.not_before_ms);
    try testing.expect(!std.mem.eql(u8, &first.signature, &again.credential.?.signature));
    try testing.expect(again.renew_at_ms > renew_at);
    try testing.expectEqual(identity.ca_public.?, again.ca_public.?);

    // Removal: the file is read at start, and then the node is refused, not stopped.
    try write_revoked(rig.io, base[0..base_length], "# gone\nnode1\n");
    try rig.restart_server();
    const kept = again.credential.?;
    try testing.expectError(
        error.Failed,
        again.step(rig.http_transport.transport(), arena, lease.id, again.renew_at_ms, 3000, &diag),
    );
    try testing.expectEqual(@as(?codes.Code, .E0807), diag.code);
    try testing.expectEqualSlices(u8, &kept.signature, &again.credential.?.signature);
    try testing.expect(!again.due(again.retry_at_ms - 1));
}

test "the credential endpoint refuses what it should: a bad key, a big body, a wrong method" {
    // Goal: docs/api.md's refusals for the credential call. Method: send each wrong request to a
    // live server and read the status; none may issue anything.
    var rig = try Rig.start();
    defer rig.stop();
    const path = "/v1/agent/nodes/node1/credential";
    try testing.expectEqual(@as(u16, 400), try rig.post(path, "{\"node_key\":\"zz\"}"));
    try testing.expectEqual(@as(u16, 400), try rig.post(path, "{\"node_key\":\"00\"}"));
    try testing.expectEqual(@as(u16, 400), try rig.post(path, "{}"));
    const all_f = "ffffffffffffffffffffffffffffffffffffffffffffffff";
    const off_curve = "{\"node_key\":\"" ++ all_f ++ all_f[0..16] ++ "\"}";
    try testing.expectEqual(@as(u16, 400), try rig.post(path, off_curve));
    var big: [constants.peer_join_request_bytes_max + 8]u8 = @splat(' ');
    // A body over the cap is refused before it is read: a status, or the connection closed.
    const refused = rig.post(path, &big) catch 400;
    try testing.expect(refused >= 400);
    const bad_name = "/v1/agent/nodes/Bad%20Name/credential";
    try testing.expectEqual(@as(u16, 400), try rig.post(bad_name, off_curve));
}

test "a memory-store server that restarts has a new CA, and the agent joins it within one retry" {
    // Goal: finding 1. Method: join a memory-store server, restart it (a new CA, an empty
    // store), let the agent read one answer, and see its credential dropped and ZC-E0801 shown
    // once; then it registers again and holds a credential from the new CA.
    var test_io: TestIo = undefined;
    const io = test_io.start();
    defer test_io.stop();
    // Optional, as in `Rig`: a restart that fails must not leave the old server to stop twice.
    var server: ?*server_mod.Server = try start_server_on(io, .memory, true);
    defer if (server) |running| running.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var http_transport: remote_mod.HttpTransport = .{
        .client = .{ .io = io, .address = server.?.address() },
    };
    var remote_store = remote_mod.RemoteStore.init(
        testing.allocator,
        http_transport.transport(),
        "node1",
    );
    const remote = remote_store.interface();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var base: [constants.state_path_bytes_max]u8 = undefined;
    const base_length = try tmp.dir.realPath(io, &base);
    const state_dir = try std.fmt.allocPrint(arena, "{s}/agent", .{base[0..base_length]});
    var clock_source: clock_mod.RealClock = .{ .io = io };
    const wall = clock_source.clock().now_ms();

    var identity = try agent_peer.Peer.open(io, state_dir, "node1", &diag);
    defer identity.close();
    var lease = try remote.lease_grant(10_000, &diag);
    _ = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, &diag);
    try identity.step(http_transport.transport(), arena, lease.id, wall, 3000, &diag);
    const old_ca = identity.ca_public.?;
    try testing.expect(remote_store.ca_key_id != null);
    try testing.expect(!identity.observe_ca(remote_store.ca_key_id.?));

    server.?.stop();
    server = null;
    server = try start_server_on(io, .memory, true);
    http_transport.client.address = server.?.address();
    lease = try remote.lease_grant(10_000, &diag);
    _ = try remote.txn(.{ .on_success = &.{register_op(lease.id)} }, &diag);
    try testing.expect(identity.observe_ca(remote_store.ca_key_id.?));
    try testing.expect(identity.credential == null);
    try testing.expect(identity.due(wall));
    try identity.step(http_transport.transport(), arena, lease.id, wall, 3000, &diag);
    try testing.expect(!std.mem.eql(u8, &old_ca, &identity.ca_public.?));
    try testing.expect(!identity.observe_ca(remote_store.ca_key_id.?));
}

test "the agent reads more than store_list_limit_max retained observations of its node" {
    // Goal: runs are retained until their retention ends, so a node can hold up to
    // `job_admitted_window_max` observations, far more than one list page. Method: put 600 into
    // the server's store, then read them the way `agent_jobs.pass` does: `controller.list_all`
    // over the agent's `RemoteStore`. Before paging, the server answered all 600 to a request
    // for 500 and the client refused the reply (ZC-E0504), so every pass of a node failed.
    var rig = try Rig.start();
    defer rig.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const direct = rig.live().shared.store;
    const lease = try direct.lease_grant(10_000, &diag);
    const registered = register_op(lease.id);
    _ = try direct.txn(.{ .on_success = &.{registered} }, &diag);
    const total = constants.store_list_limit_max + 100;
    for (0..total) |number| {
        const name = try std.fmt.allocPrint(arena, "old{d:0>4}", .{number});
        const seen: records.JobObserved = .{
            .run = try std.fmt.allocPrint(arena, "{s}-job", .{name}),
            .node = "node1",
            .tenure = 1,
            .assignment = 1,
            .status = .stopped,
            .exit = .{ .kind = .lost },
            .reported_at_ms = 1,
        };
        const key = records.job_observed_key("node1", name);
        const value = try records.encode(arena, seen, &diag);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = value } };
        _ = try direct.txn(.{ .on_success = &.{op} }, &diag);
    }
    var manual: @import("clock.zig").ManualClock = .{ .ms = 1 };
    const ctx: @import("controller.zig").Context = .{
        .store = rig.remote.interface(),
        .clock = manual.clock(),
        .arena = arena,
        .diag = &diag,
    };
    const prefix = records.job_observed_prefix("node1");
    const listed = try @import("controller.zig").list_all(
        records.JobObserved,
        &ctx,
        prefix.slice(),
        null,
        constants.job_admitted_window_max,
    );
    try testing.expectEqual(@as(usize, total), listed.items.len);
    try testing.expectEqualStrings("old0000-job", listed.items[0].rec.run);
    try testing.expectEqualStrings("old0599-job", listed.items[total - 1].rec.run);
    // A caller that asks for less than a page gets that much and resumes after the last.
    const small = try rig.remote.interface().list(arena, .{
        .prefix = prefix.slice(),
        .limit = 3,
    }, &diag);
    try testing.expectEqual(@as(usize, 3), small.kvs.len);
    try testing.expectEqualStrings(small.kvs[2].key, small.continue_after.?);
}
