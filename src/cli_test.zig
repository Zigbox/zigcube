//! End-to-end tests of the `zcube` command line against a live `zcube-server` on SQLite: real
//! sockets, real threads, the real clock. The command line runs in-process through `cli.run` with
//! an `Env` over buffers (the same code the binary runs), a simulated node agent over the same
//! store keeps the replicas running (the real agent is a different slice's), and the output is
//! compared with HANDOFF's demo. Test code, so it may use threads (docs/STYLE.md).
//!
//! What this is not: `demo-c0`. The demo runs the three real binaries and a real agent.

const std = @import("std");
const testing = std.testing;
const agent_mod = @import("agent.zig");
const cli = @import("cli.zig");
const cli_env = @import("cli_env.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const server_mod = @import("server.zig");
const server_store = @import("server_store.zig");
const sim_runtime = @import("sim_runtime.zig");
const store_mod = @import("store.zig");

const Diag = diag_mod.Diag;
const Writer = std.Io.Writer;

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

/// The part of the cluster that is not the server: a simulated node agent, stepped by the test.
const Node = struct {
    agent: *agent_mod.Agent,
    runtime: *sim_runtime.SimRuntime,
    arena: std.heap.ArenaAllocator,
    store: store_mod.Store,
    real: server_store.RealClock,
    diag: Diag,

    fn start(io: std.Io, store: store_mod.Store) !*Node {
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

/// A server on a fresh SQLite file, a node, and the command line pointed at them.
const World = struct {
    test_io: TestIo,
    io: std.Io,
    tmp: testing.TmpDir,
    server: *server_mod.Server,
    node: *Node,
    arena_state: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    stdout: Writer.Allocating,
    stderr: Writer.Allocating,
    /// "127.0.0.1:port" of the server.
    address: []const u8,
    /// Where files for `apply` live, relative to the working directory.
    dir: []const u8,
    stdin_text: []const u8 = "",
    stdin_terminal: bool = false,
    reply_timeout_ms: u32 = constants.cli_reply_timeout_ms,

    fn start(world: *World) !void {
        // `world` is `undefined` before this: the defaults of the fields are set here.
        world.stdin_text = "";
        world.stdin_terminal = false;
        world.reply_timeout_ms = constants.cli_reply_timeout_ms;
        world.io = world.test_io.start();
        world.tmp = testing.tmpDir(.{});
        world.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = world.arena_state.allocator();
        world.dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{world.tmp.sub_path});
        const database = try std.fmt.allocPrint(arena, "{s}/zcube.db", .{world.dir});
        var diag: Diag = undefined;
        diag.reset();
        const listen = try config_mod.parse_listen("127.0.0.1:0", &diag);
        world.server = try server_mod.Server.start(testing.allocator, world.io, .{
            .listen = listen,
            .store = .{ .sqlite = database },
            .create_store = true,
            .verbose = false,
            .quiet = true,
        }, .{ .version = "0.0.0-test", .report_failures = false, .log_requests = false }, &diag);
        world.node = try Node.start(world.io, world.server.backend.handle());
        world.address = try std.fmt.allocPrint(arena, "{f}", .{world.server.address()});
        world.environ = std.process.Environ.Map.init(testing.allocator);
        const absolute = try std.process.currentPathAlloc(world.io, arena);
        const state = try std.fmt.allocPrint(arena, "{s}/{s}/state", .{ absolute, world.dir });
        try world.environ.put("XDG_STATE_HOME", state);
        try world.environ.put("USER", "tester");
        try world.environ.put("ZCUBE_SERVER", world.address);
        world.stdout = .init(testing.allocator);
        world.stderr = .init(testing.allocator);
    }

    fn stop(world: *World) void {
        world.stdout.deinit();
        world.stderr.deinit();
        world.environ.deinit();
        world.node.stop();
        world.server.stop();
        world.arena_state.deinit();
        world.tmp.cleanup();
        world.test_io.stop();
    }

    /// Runs `zcube args...`; the output is in `out()` and `err()` until the next run.
    fn run(world: *World, args: []const []const u8) u8 {
        world.stdout.clearRetainingCapacity();
        world.stderr.clearRetainingCapacity();
        var input = std.Io.Reader.fixed(world.stdin_text);
        const env: cli_env.Env = .{
            .io = world.io,
            .arena = world.arena_state.allocator(),
            .environ = &world.environ,
            .stdout = &world.stdout.writer,
            .stderr = &world.stderr.writer,
            .stdin = &input,
            .stdin_is_terminal = world.stdin_terminal,
            .stderr_is_terminal = false,
            .version = "0.0.0-test",
            .deterministic_ids = true,
            .reply_timeout_ms = world.reply_timeout_ms,
        };
        return cli.run(&env, args);
    }

    fn out(world: *World) []const u8 {
        return world.stdout.written();
    }

    fn err(world: *World) []const u8 {
        return world.stderr.written();
    }

    /// Writes a service file and returns its path.
    fn file(world: *World, name: []const u8, text: []const u8) ![]const u8 {
        try world.tmp.dir.writeFile(world.io, .{ .sub_path = name, .data = text });
        return std.fmt.allocPrint(world.arena_state.allocator(), "{s}/{s}", .{ world.dir, name });
    }

    /// Steps the agent until `zcube get service <name>` shows `ready`.
    fn converge(world: *World, name: []const u8, ready: []const u8) !void {
        for (0..200) |_| {
            try world.node.step();
            if (world.run(&.{ "get", "service", name }) == 0) {
                if (std.mem.indexOf(u8, world.out(), ready) != null) return;
            }
            try world.io.sleep(.fromMilliseconds(25), .awake);
        }
        std.debug.print("never reached {s}: {s}{s}\n", .{ ready, world.out(), world.err() });
        return error.NeverConverged;
    }
};

fn hello_zon(replicas: u32) ![]const u8 {
    const format =
        \\.{{
        \\    .name = "hello",
        \\    .image = "b3:51aa9c03",
        \\    .replicas = {d},
        \\    .command = .{{ "sh", "-c", "while true; do sleep 1; done" }},
        \\}}
        \\
    ;
    return std.fmt.allocPrint(testing.allocator, format, .{replicas});
}

fn expect_contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedContains;
}

/// Lets the simulated agent act for a while, so that a change is carried out.
fn settle(world: *World) !void {
    for (0..20) |_| {
        try world.node.step();
        try world.io.sleep(.fromMilliseconds(25), .awake);
    }
}

/// Applies `hello` with `replicas` replicas from `path`, without being asked.
fn apply_hello(world: *World, path: []const u8, replicas: u32) !void {
    const text = try hello_zon(replicas);
    defer testing.allocator.free(text);
    _ = try world.file("hello.zon", text);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes" }));
}

test "apply, get, why, scale and delete against a live server on SQLite" {
    // Goal: HANDOFF C0 demo steps 1, 3 and 4 through the real command line. Method: apply
    // `hello` with 3 replicas, let the simulated agent run them, read them back with `get`, scale
    // to 5 and back to 2, explain `broken`, then delete `hello`. Output is compared with the
    // demo's wording.
    var world: World = undefined;
    try world.start();
    defer world.stop();

    const arena = world.arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "{s}/hello.zon", .{world.dir});
    try apply_hello(&world, path, 3);
    try testing.expectEqualStrings(
        "service hello: would create\napplied service hello: created\n",
        world.out(),
    );
    try testing.expectEqualStrings("", world.err());
    try world.converge("hello", "3/3");
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "get", "service", "hello" }));
    try testing.expectEqualStrings("NAME   READY  IMAGE\nhello  3/3    b3:51aa9c03\n", world.out());

    // The same file again is no change: it is said and nothing is asked.
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path }));
    try testing.expectEqualStrings("service hello: unchanged\n", world.out());

    try testing.expectEqual(@as(u8, 0), world.run(&.{ "get", "replicas", "hello", "-o", "wide" }));
    const header = "REPLICA  SERVICE  NODE   STATUS   AGE  GEN  IMAGE        DETAIL\n";
    try expect_contains(world.out(), header);
    try expect_contains(world.out(), "hello-1  hello    node1  running");

    // Scale up and down: a count change keeps the replicas that run (docs/keys.md).
    try apply_hello(&world, path, 5);
    try expect_contains(world.out(), "service hello: would update\n  replicas 3 \u{2192} 5\n");
    try expect_contains(world.out(), "applied service hello: replicas 3 \u{2192} 5\n");
    try world.converge("hello", "5/5");
    try apply_hello(&world, path, 2);
    try world.converge("hello", "2/2");

    try check_broken_chain(&world);
    try check_delete(&world);
}

/// Step 4 of the demo: a digest that is not in the fixtures, and the chain that explains it.
fn check_broken_chain(world: *World) !void {
    const broken =
        \\.{
        \\    .name = "broken",
        \\    .image = "b3:00ff7be1",
        \\    .replicas = 1,
        \\    .command = .{ "true" },
        \\}
    ;
    const path = try world.file("broken.zon", broken);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes" }));
    try settle(world);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "why", "service", "broken" }));
    try testing.expectEqualStrings(
        "service broken: 0/1 running\n" ++
            "  \u{2190} replica broken-1 failed to start on node1; it was not replaced " ++
            "because a new one would fail the same way\n" ++
            "  \u{2190} error[ZBX-E0501]: image not found\n" ++
            "      cause  digest b3:00ff7be1 is not in this node's store\n" ++
            "      fix    check the digest in the service file, or pull the image first\n" ++
            "      more   zbx explain E0501 \u{b7} rerun with --verbose for the full cause " ++
            "chain\n" ++
            "      docs   https://zigbox.github.io/zigbox/errors/E0501.html\n",
        world.out(),
    );
}

/// Delete asks first, and with --yes removes the service and stops its replicas.
fn check_delete(world: *World) !void {
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "delete", "service", "hello", "--yes" }));
    try expect_contains(
        world.out(),
        "service hello: 2/2 running; its replicas will be stopped\ndeleted service hello:",
    );
    try settle(world);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "get", "replicas" }));
    try testing.expect(std.mem.indexOf(u8, world.out(), "hello-") == null);
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "get", "service", "hello" }));
    try expect_contains(world.err(), "error[ZC-E0101]: no such resource");
}

test "a declined apply and a dry run write nothing, and a missing terminal never hangs" {
    // Goal: the confirmation of the brief. Method: change `hello`; a dry run shows the change
    // and stops; no terminal without --yes is ZC-E0113; a terminal answering n is ZC-E0114; a
    // terminal answering y applies. After each refusal the store still says 3 replicas.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    const three = try hello_zon(3);
    defer testing.allocator.free(three);
    const path = try world.file("hello.zon", three);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes" }));
    const four = try hello_zon(4);
    defer testing.allocator.free(four);
    _ = try world.file("hello.zon", four);

    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--dry-run" }));
    try testing.expectEqualStrings(
        "service hello: would update\n  replicas 3 \u{2192} 4\n",
        world.out(),
    );

    try testing.expectEqual(@as(u8, 1), world.run(&.{ "apply", path }));
    try expect_contains(
        world.err(),
        "error[ZC-E0113]: apply needs an answer and there is no terminal",
    );

    world.stdin_terminal = true;
    world.stdin_text = "n\n";
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "apply", path }));
    try expect_contains(world.err(), "error[ZC-E0114]: the apply was declined");
    world.stdin_text = "";
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "apply", path }));
    try expect_contains(world.err(), "error[ZC-E0114]"); // End of input is a no, not a hang.

    try testing.expectEqual(@as(u8, 0), world.run(&.{ "get", "service", "hello" }));
    try expect_contains(world.out(), "0/3");
    world.stdin_text = "yes\n";
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path }));
    try expect_contains(world.out(), "applied service hello: replicas 3 \u{2192} 4");
    try expect_contains(world.err(), "apply? [y/N] ");
}

test "--output json prints JSON on stdout and one JSON object per line on stderr" {
    // Goal: DIAGNOSTICS.md output modes for scripts. Method: success output of get, why and
    // apply parses; a failure's stderr is one object per line and parses; stdout stays empty.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    const three = try hello_zon(3);
    defer testing.allocator.free(three);
    const path = try world.file("hello.zon", three);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes", "-o", "json" }));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const applied = try std.json.parseFromSliceLeaky(std.json.Value, arena, world.out(), .{});
    try testing.expectEqualStrings("create", applied.object.get("action").?.string);
    try testing.expectEqualStrings("", world.err());

    const commands = [_][]const []const u8{
        &.{ "get", "service", "-o", "json" },
        &.{ "get", "replicas", "--output", "json" },
        &.{ "why", "service", "hello", "--output", "json" },
        &.{ "explain", "E0102", "-o", "json" },
    };
    for (commands) |args| {
        try testing.expectEqual(@as(u8, 0), world.run(args));
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, world.out(), .{});
        try testing.expect(parsed == .object);
        try testing.expectEqualStrings("", world.err());
    }
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "why", "service", "nosuch", "-o", "json" }));
    try testing.expectEqualStrings("", world.out());
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, world.err(), "\n"), '\n');
    var count: u32 = 0;
    while (lines.next()) |line| : (count += 1) {
        const diagnostic = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try testing.expectEqualStrings("ZC-E0101", diagnostic.object.get("code").?.string);
    }
    try testing.expectEqual(@as(u32, 1), count);
}

test "an unreachable server is a coded diagnostic with a fix, in every output mode" {
    // Goal: "the server is unreachable is a ZC- diagnostic with a fix, not a socket error".
    // Method: point the command at a port nobody listens on, in default, verbose and JSON; exit
    // 2 each time, and no raw error anywhere.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    // Port 1 is reserved and nothing listens there: the connection is refused at once.
    try world.environ.put("ZCUBE_SERVER", "127.0.0.1:1");

    try testing.expectEqual(constants.exit_environment, world.run(&.{ "get", "service" }));
    try expect_contains(world.err(), "error[ZC-E0102]: can't reach zcube-server");
    try expect_contains(world.err(), "cause  connection refused: nothing is listening there");
    try expect_contains(world.err(), "zcube-server --store sqlite:zcube.db --create-store");
    try testing.expectEqualStrings("", world.out());
    try testing.expectEqual(constants.exit_environment, world.run(&.{ "-v", "get", "service" }));
    try expect_contains(world.err(), "reqid  zc-test-0001");
    try expect_contains(world.err(), "while  sending a request to zcube-server");
    try testing.expectEqual(
        constants.exit_environment,
        world.run(&.{ "get", "service", "--output", "json" }),
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        std.mem.trimEnd(u8, world.err(), "\n"),
        .{},
    );
    try testing.expectEqualStrings("ZC-E0102", parsed.object.get("code").?.string);
    try testing.expectEqualStrings("environment", parsed.object.get("blame").?.string);

    // A bad address is the user's, and is said before any connection.
    try world.environ.put("ZCUBE_SERVER", "not-an-address");
    try testing.expectEqual(constants.exit_user, world.run(&.{ "get", "service" }));
    try expect_contains(world.err(), "error[ZC-E0112]: the server address can't be used");
}

/// The files of a bundle, by name, read back with std's gzip and tar readers.
const Unpacked = struct {
    names: std.ArrayList([]const u8) = .empty,
    contents: std.ArrayList([]const u8) = .empty,

    fn find(unpacked: *const Unpacked, suffix: []const u8) ?[]const u8 {
        for (unpacked.names.items, unpacked.contents.items) |name, content| {
            if (std.mem.endsWith(u8, name, suffix)) return content;
        }
        return null;
    }
};

fn unpack(world: *World, path: []const u8) !Unpacked {
    const arena = world.arena_state.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        world.io,
        path,
        arena,
        .limited(constants.bundle_gz_bytes_max),
    );
    var input = std.Io.Reader.fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = std.compress.flate.Decompress.init(&input, .gzip, &window);
    var name_buffer: [256]u8 = undefined;
    var link_buffer: [256]u8 = undefined;
    var iterator = std.tar.Iterator.init(
        &gzip.reader,
        .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer },
    );
    var unpacked: Unpacked = .{};
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        var content: Writer.Allocating = .init(arena);
        try iterator.streamRemaining(entry, &content.writer);
        try unpacked.names.append(arena, try arena.dupe(u8, entry.name));
        try unpacked.contents.append(arena, content.written());
    }
    return unpacked;
}

/// The path printed by `zcube bundle`.
fn bundle_path(world: *World) ![]const u8 {
    const prefix = "bundle saved: ";
    const start = std.mem.indexOf(u8, world.out(), prefix) orelse return error.NoBundle;
    const rest = world.out()[start + prefix.len ..];
    return rest[0..std.mem.indexOfScalar(u8, rest, '\n').?];
}

/// Values that look like secrets and must never reach a bundle with redaction on.
const fakes = [_][]const u8{
    "ghp_FAKEFAKEFAKEFAKEFAKEFAKE0123456789",
    "fake-db-password-8c1d",
    "plainly-named-value-77ab",
    "env-secret-in-service-91ef",
    "innocent-env-value-in-service-3d2c",
};

/// Puts the fakes in the environment of the command line and in a service's env, and applies it.
fn plant_secrets(world: *World) !void {
    try world.environ.put("GITHUB_TOKEN", fakes[0]);
    try world.environ.put("DB_PASSWORD", fakes[1]);
    try world.environ.put("MY_PLAIN_SETTING", fakes[2]);
    const text = try std.fmt.allocPrint(testing.allocator,
        \\.{{
        \\    .name = "hello",
        \\    .image = "b3:51aa9c03",
        \\    .replicas = 1,
        \\    .command = .{{ "true" }},
        \\    .env = .{{ .{{ "API_KEY", "{s}" }}, .{{ "GREETING", "{s}" }} }},
        \\}}
    , .{ fakes[3], fakes[4] });
    defer testing.allocator.free(text);
    const path = try world.file("hello.zon", text);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes" }));
}

fn expect_no_fakes(unpacked: *const Unpacked) !void {
    for (unpacked.contents.items) |content| {
        for (fakes) |fake| try testing.expect(std.mem.indexOf(u8, content, fake) == null);
    }
}

test "bundle --last collects the failure, and redaction leaves no fake secret anywhere" {
    // Goal: DIAGNOSTICS.md, "Bundle check: a CI test creates a bundle with fake secrets in the
    // environment and fails if any appear unredacted", and the contents the brief lists. Method:
    // fake secrets in the environment (secret-named and not) and in a service's env; fail a
    // command; bundle it; read the .tar.gz back and look for every fake value in every file.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    try plant_secrets(&world);
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "why", "service", "nosuch" }));

    try testing.expectEqual(@as(u8, 0), world.run(&.{ "bundle", "--last" }));
    try expect_contains(world.out(), "zcube diagnostic bundle ");
    const unpacked = try unpack(&world, try bundle_path(&world));
    try expect_no_fakes(&unpacked);
    try testing.expect(unpacked.find("/MANIFEST.txt") != null);
    try expect_contains(unpacked.find("/diagnostic.json").?, "\"code\":\"ZC-E0101\"");
    const command = unpacked.find("/command.txt").?;
    try expect_contains(command, "zcube why service nosuch");
    try expect_contains(command, "request id: zc-test-0001");
    try expect_contains(unpacked.find("/status.json").?, "\"backend\":\"sqlite\"");
    const environment = unpacked.find("/environment.txt").?;
    try expect_contains(environment, "GITHUB_TOKEN=[redacted:env]\n");
    try expect_contains(environment, "MY_PLAIN_SETTING=[redacted:env]\n");
    try expect_contains(unpacked.find("/MANIFEST.txt").?, "redaction: on");

    try check_subject_bundle(&world);
    try check_unredacted_bundle(&world);
}

/// A subject bundle has the store keys; the env values in them are gone, the names stay.
fn check_subject_bundle(world: *World) !void {
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "bundle", "service", "hello" }));
    const subject = try unpack(world, try bundle_path(world));
    try expect_no_fakes(&subject);
    try expect_contains(subject.find("/keys/service.json").?, "\"API_KEY\"");
    try expect_contains(subject.find("/why.json").?, "service hello");
    const decisions = subject.find("/keys/decisions.json").?;
    try expect_contains(decisions, "decisions-by-subject/service/hello");
}

/// --no-redact warns, and keeps what it was told to keep.
fn check_unredacted_bundle(world: *World) !void {
    const args = [_][]const u8{ "bundle", "service", "hello", "--no-redact" };
    try testing.expectEqual(@as(u8, 0), world.run(&args));
    const warning = "warning[ZC-W0119]: --no-redact keeps secrets in the bundle";
    try expect_contains(world.err(), warning);
    const raw = try unpack(world, try bundle_path(world));
    try expect_contains(raw.find("/environment.txt").?, fakes[2]);
    try expect_contains(raw.find("/MANIFEST.txt").?, "redaction: OFF");
}

test "bundle --last without a record says so, and with a dead server still works" {
    // Goal: ZC-E0117, and that the evidence is best effort. Method: bundle --last in a fresh
    // state directory; then fail against a dead address and bundle it: the notes name what could
    // not be had.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "bundle", "--last" }));
    try expect_contains(world.err(), "error[ZC-E0117]: there is no failure to bundle");

    try world.environ.put("ZCUBE_SERVER", "127.0.0.1:1");
    try testing.expectEqual(constants.exit_environment, world.run(&.{ "get", "service", "hello" }));
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "bundle", "--last" }));
    const unpacked = try unpack(&world, try bundle_path(&world));
    try expect_contains(unpacked.find("/diagnostic.json").?, "ZC-E0102");
    try expect_contains(unpacked.find("/status.unavailable.txt").?, "ZC-E0102");
    try expect_contains(unpacked.find("/MANIFEST.txt").?, "status.unavailable.txt");
}

test "a server that accepts and says nothing is a timeout, not a hang and not a bug" {
    // Goal: the command line never waits for ever on a reply. Method: a listener that never
    // accepts (the connection sits in its backlog), a reply timeout of 200 ms; the answer is
    // ZC-E0102 with the cause "no reply", exit 2, in well under a second.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    var diag: Diag = undefined;
    diag.reset();
    const where = try config_mod.parse_listen("127.0.0.1:0", &diag);
    var listener = try where.listen(world.io, .{});
    defer listener.deinit(world.io);
    const arena = world.arena_state.allocator();
    const address = try std.fmt.allocPrint(arena, "{f}", .{listener.socket.address});
    try world.environ.put("ZCUBE_SERVER", address);
    world.reply_timeout_ms = 200;
    const started = std.Io.Clock.awake.now(world.io).toMilliseconds();
    try testing.expectEqual(constants.exit_environment, world.run(&.{ "-v", "get", "service" }));
    const elapsed = std.Io.Clock.awake.now(world.io).toMilliseconds() - started;
    try testing.expect(elapsed < 5000);
    try expect_contains(world.err(), "error[ZC-E0102]: can't reach zcube-server");
    try expect_contains(world.err(), "cause  no reply within 200 ms");
    try expect_contains(world.err(), "took the connection and sent");
}

/// Rewrites the record of the last failure so that it names a subject and a revision, as a
/// failure partway through a command that had read the store would.
fn record_revision(world: *World, revision: u64) !void {
    const arena = world.arena_state.allocator();
    const state = world.environ.get("XDG_STATE_HOME").?;
    const name = constants.last_failure_file_name;
    const path = try std.fmt.allocPrint(arena, "{s}/zcube/{s}", .{ state, name });
    const old = try std.Io.Dir.cwd().readFileAlloc(world.io, path, arena, .limited(64 * 1024));
    var record = try std.json.parseFromSliceLeaky(std.json.Value, arena, old, .{});
    try record.object.put(arena, "kind", .{ .string = "service" });
    try record.object.put(arena, "name", .{ .string = "hello" });
    try record.object.put(arena, "revision", .{ .integer = @intCast(revision) });
    const text = try std.json.Stringify.valueAlloc(arena, record, .{});
    try std.Io.Dir.cwd().writeFile(world.io, .{ .sub_path = path, .data = text });
}

test "bundle --last reads the store keys at the failing revision, and says when it can't" {
    // Goal: "the relevant store keys at the failing revision". Method: apply `hello`, fail a
    // command, give its record the revision the apply made; the keys are read `at` it and the
    // manifest says so. A record of a revision the store has not reached falls back to now, and
    // says that instead.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    const text = try hello_zon(1);
    defer testing.allocator.free(text);
    const path = try world.file("hello.zon", text);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "apply", path, "--yes" }));
    try testing.expectEqual(@as(u8, 1), world.run(&.{ "why", "service", "nosuch" }));

    try record_revision(&world, 1);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "bundle", "--last" }));
    const at = try unpack(&world, try bundle_path(&world));
    const manifest = at.find("/MANIFEST.txt").?;
    try expect_contains(manifest, "store keys under /services/hello at revision 1");
    try expect_contains(at.find("/keys/service.json").?, "\"name\":\"hello\"");

    try record_revision(&world, 999_999);
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "bundle", "--last" }));
    const now = try unpack(&world, try bundle_path(&world));
    const fallback = "as they are now (the failing revision is not known or is gone)";
    try expect_contains(now.find("/MANIFEST.txt").?, fallback);
    try expect_contains(now.find("/keys/service.json").?, "\"name\":\"hello\"");
}

test "--verbose lists every request with the id the server answered under" {
    // Goal: "request IDs shown in verbose output". Method: a verbose get; one line per request.
    var world: World = undefined;
    try world.start();
    defer world.stop();
    try testing.expectEqual(@as(u8, 0), world.run(&.{ "-v", "get", "service" }));
    const first = "request  zc-test-0001  GET /v1/list?prefix=%2Fservices%2F&limit=500  200\n";
    const third = "request  zc-test-0003  GET /v1/list?prefix=%2Fobserved%2F&limit=500  200\n";
    try expect_contains(world.err(), first);
    try expect_contains(world.err(), third);
    try testing.expectEqualStrings("no services\n", world.out());
}
