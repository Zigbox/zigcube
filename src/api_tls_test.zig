//! The API over TLS end to end (B7 slice 3, docs/mtls.md): a real `Server` with both listeners
//! and certificates its CA issued, called through `api_tls_client` as an admin client, a `jobs`
//! client and a node's agent. Test code: real sockets, files and threads.

const std = @import("std");
const api_tls_client = @import("api_tls_client.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const peer_stream = @import("peer_stream.zig");
const pem = @import("pem.zig");
const server_ca = @import("server_ca.zig");
const secure_random = @import("secure_random.zig");
const server_mod = @import("server.zig");
const server_static = @import("server_static.zig");
const x509 = @import("x509.zig");

const testing = std.testing;
const net = std.Io.net;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

const Kind = enum { node, jobs, admin };

/// Issues a certificate of `kind` for `name` with the server's CA and writes `<name>.crt` and
/// `<name>.key` into `dir`.
fn issue(
    io: std.Io,
    dir: std.Io.Dir,
    ca: *const peer_ca.Ca,
    kind: Kind,
    name: []const u8,
) !void {
    var seed = try secure_random.random_seed(io);
    defer std.crypto.secureZero(u8, &seed);
    const key = try Ed25519.KeyPair.generateDeterministic(seed);
    var der: x509.Der = .{};
    const ttl_ms = constants.x509_leaf_ttl_ms_max;
    switch (kind) {
        .node => try ca.issue_node_certificate(&der, &.{
            .node = name,
            .subject_key = key.public_key.toBytes(),
            .lifetime = try ca.window(ttl_ms),
        }),
        .jobs, .admin => try ca.issue_client_certificate(&der, &.{
            .client = name,
            .scope = if (kind == .jobs) .jobs else .admin,
            .subject_key = key.public_key.toBytes(),
            .ttl_ms = ttl_ms,
        }),
    }
    var text: [pem.bytes_max]u8 = undefined;
    var file_name: [64]u8 = undefined;
    const crt = try std.fmt.bufPrint(&file_name, "{s}.crt", .{name});
    const certificate = pem.encode(&text, .certificate, der.slice());
    try dir.writeFile(io, .{ .sub_path = crt, .data = certificate });
    const key_name = try std.fmt.bufPrint(&file_name, "{s}.key", .{name});
    const file = try dir.createFile(io, key_name, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, pem.encode_key(&text, &seed));
}

const Rig = struct {
    io: std.Io,
    threaded: std.Io.Threaded,
    tmp: testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8,
    path_length: u32,
    server: *server_mod.Server,
    arena: std.heap.ArenaAllocator,

    fn start(rig: *Rig) !void {
        const room = constants.http_connections_max + constants.server_threads_extra + 8;
        rig.threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(room) });
        rig.io = rig.threaded.io();
        rig.tmp = testing.tmpDir(.{});
        rig.path_length = @intCast(try rig.tmp.dir.realPath(rig.io, &rig.path_buffer));
        rig.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const arena = rig.arena.allocator();
        var diag: Diag = undefined;
        diag.reset();
        const database = try std.fmt.allocPrint(arena, "{s}/z.db", .{rig.dir()});
        const config: config_mod.Config = .{
            .listen = try config_mod.parse_listen("127.0.0.1:0", &diag),
            .insecure_listen = try config_mod.parse_listen("127.0.0.1:0", &diag),
            .store = .{ .sqlite = database },
            .create_store = true,
            .state_dir = rig.dir(),
            .verbose = false,
            .quiet = true,
        };
        rig.server = server_mod.Server.start(testing.allocator, rig.io, config, .{
            .version = "0.0.0-test",
            .report_failures = false,
            .log_requests = false,
        }, &diag) catch |err| {
            if (diag.code) |code| std.debug.print("server did not start: {s}\n", .{@tagName(code)});
            return err;
        };
        try issue(rig.io, rig.tmp.dir, &rig.server.ca, .admin, "ops");
        try issue(rig.io, rig.tmp.dir, &rig.server.ca, .jobs, "app");
        try issue(rig.io, rig.tmp.dir, &rig.server.ca, .node, "node1");
    }

    fn stop(rig: *Rig) void {
        rig.server.stop();
        rig.arena.deinit();
        rig.tmp.cleanup();
        rig.threaded.deinit();
    }

    /// The CA certificate's name in the state directory: one per store (`server_ca`).
    fn ca_file(rig: *Rig) ![]const u8 {
        const server = rig.server;
        var name: [server_ca.key_name_bytes_max]u8 = undefined;
        const key = server.ca_name_buffer[0..server.ca_name_length];
        return rig.arena.allocator().dupe(u8, server_ca.cert_name_for(key, &name));
    }

    fn dir(rig: *const Rig) []const u8 {
        return rig.path_buffer[0..rig.path_length];
    }

    fn load(rig: *Rig, name: []const u8, credentials: *api_tls_client.Credentials) !void {
        const arena = rig.arena.allocator();
        var diag: Diag = undefined;
        diag.reset();
        credentials.load(rig.io, .{
            .ca = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rig.dir(), try rig.ca_file() }),
            .cert = try std.fmt.allocPrint(arena, "{s}/{s}.crt", .{ rig.dir(), name }),
            .key = try std.fmt.allocPrint(arena, "{s}/{s}.key", .{ rig.dir(), name }),
        }, &diag) catch |err| {
            std.debug.print("load {s}: {s}\n", .{ name, @tagName(diag.code.?) });
            return err;
        };
    }

    /// The status of one request over TLS as the holder of `credentials`.
    fn status(
        rig: *Rig,
        credentials: *api_tls_client.Credentials,
        method: []const u8,
        path: []const u8,
    ) !u16 {
        const reply = try rig.call(credentials, method, path);
        const code = try std.fmt.parseInt(u16, reply[9..12], 10);
        if (code == 400) std.debug.print("{s} {s}: {s}\n", .{ method, path, reply });
        return code;
    }

    /// The whole reply, head and body, to one request over TLS as the holder of `credentials`.
    fn call(
        rig: *Rig,
        credentials: *api_tls_client.Credentials,
        method: []const u8,
        path: []const u8,
    ) ![]const u8 {
        const stream = try rig.server.tls_address().connect(rig.io, .{ .mode = .stream });
        defer stream.close(rig.io);
        const body = if (std.mem.eql(u8, method, "GET")) "" else "{}";
        const head = try std.fmt.allocPrint(
            rig.arena.allocator(),
            "{s} {s} HTTP/1.1\r\nHost: zcube-server\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ method, path, body.len, body },
        );
        var diag: Diag = undefined;
        diag.reset();
        const end_ms = peer_stream.boot_ms(rig.io) + 10_000;
        const got = api_tls_client.exchange(
            credentials,
            rig.io,
            stream.socket.handle,
            rig.arena.allocator(),
            &.{head},
            1 << 20,
            api_tls_client.reply_is_whole,
            end_ms,
            &diag,
        ) catch |err| return err;
        if (got.ending != .done) {
            std.debug.print("{s} {s}: {t} {?t}\n", .{ method, path, got.ending, diag.code });
            return error.TestUnexpectedResult;
        }
        return got.reply;
    }
};

test "the API over TLS: an admin, a jobs client and a node, each held to its scope (B7)" {
    // Goal: docs/mtls.md "The API over TLS" end to end. Method: start a server with both
    // listeners on SQLite; issue three certificates with its CA; call over TLS as each and check
    // that the server named the caller from the certificate: allowed calls answered, refused
    // ones 403.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var admin: api_tls_client.Credentials = undefined;
    try rig.load("ops", &admin);
    defer admin.deinit();
    var jobs: api_tls_client.Credentials = undefined;
    try rig.load("app", &jobs);
    defer jobs.deinit();
    var node: api_tls_client.Credentials = undefined;
    try rig.load("node1", &node);
    defer node.deinit();

    try testing.expectEqual(@as(u16, 200), try rig.status(&admin, "GET", "/v1/status"));
    try testing.expectEqual(@as(u16, 403), try rig.status(&jobs, "GET", "/v1/status"));
    try testing.expectEqual(@as(u16, 200), try rig.status(&jobs, "GET", "/v1/jobs"));
    try testing.expectEqual(@as(u16, 403), try rig.status(&node, "GET", "/v1/jobs"));
    const own = try rig.status(&node, "GET", "/v1/agent/nodes/node1/replicas");
    try testing.expect(own != 403);
    const other = try rig.status(&node, "PUT", "/v1/agent/nodes/node2");
    try testing.expectEqual(@as(u16, 403), other);
    // Teeth (B7 slice 3, `ca issue-node`): a node certificate for node1 cannot join as node2.
    const join = try rig.status(&node, "POST", "/v1/agent/nodes/node2/credential");
    try testing.expectEqual(@as(u16, 403), join);
}

test "the API over TLS: a server certificate for another name is refused, naming both (B7)" {
    // Goal: a client checks the server's certificate against its --tls-name. Method: load the
    // admin's credentials with the name `api.example.com`; the server's certificate names
    // `zcube-server`; the handshake must fail with ZC-E0812 and say both names.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const arena = rig.arena.allocator();
    var credentials: api_tls_client.Credentials = undefined;
    var diag: Diag = undefined;
    diag.reset();
    try credentials.load(rig.io, .{
        .ca = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rig.dir(), try rig.ca_file() }),
        .cert = try std.fmt.allocPrint(arena, "{s}/ops.crt", .{rig.dir()}),
        .key = try std.fmt.allocPrint(arena, "{s}/ops.key", .{rig.dir()}),
        .server_name = "api.example.com",
    }, &diag);
    defer credentials.deinit();
    const stream = try rig.server.tls_address().connect(rig.io, .{ .mode = .stream });
    defer stream.close(rig.io);
    const head = "GET /v1/status HTTP/1.1\r\nHost: zcube-server\r\nContent-Length: 0\r\n\r\n";
    const got = try api_tls_client.exchange(
        &credentials,
        rig.io,
        stream.socket.handle,
        arena,
        &.{head},
        1 << 20,
        api_tls_client.reply_is_whole,
        peer_stream.boot_ms(rig.io) + 10_000,
        &diag,
    );
    try testing.expect(got.ending != .done);
    try testing.expectEqual(@import("diag/codes.zig").Code.E0812, diag.code.?);
    const cause = diag.last_cause().?;
    try testing.expect(std.mem.indexOf(u8, cause, "api.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, cause, "zcube-server") != null);
}

test "the API over TLS: plain HTTP on the TLS port gets no answer, and the loopback one does" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const io = rig.io;
    const request = "GET /v1/status HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    {
        const stream = try rig.server.tls_address().connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        var read_buffer: [256]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const raw = reader.interface.allocRemaining(testing.allocator, .limited(4096)) catch "";
        defer if (raw.len > 0) testing.allocator.free(raw);
        try testing.expect(!std.mem.startsWith(u8, raw, "HTTP/1.1 200"));
    }
    {
        const stream = try rig.server.address().connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        var read_buffer: [256]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const raw = try reader.interface.allocRemaining(testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(raw);
        try testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200"));
    }
}

test "an agent bootstraps with a node certificate for its own node only (B7 slice 3)" {
    // Goal: no admin bootstrap, and no bootstrap as another node. Method: an admin certificate
    // and node1's certificate are each checked as an agent's --cert for node1 and node2.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var admin: api_tls_client.Credentials = undefined;
    try rig.load("ops", &admin);
    defer admin.deinit();
    var node: api_tls_client.Credentials = undefined;
    try rig.load("node1", &node);
    defer node.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const now_ms = wall_ms(rig.io);
    try node.require_node("node1.crt", "node1", now_ms, &diag);
    const other = node.require_node("node1.crt", "node2", now_ms, &diag);
    try testing.expectError(error.Failed, other);
    diag.reset();
    try testing.expectError(error.Failed, admin.require_node("ops.crt", "node1", now_ms, &diag));
    // An expired --cert is refused at start-up too, naming the recovery (MUST 2).
    diag.reset();
    const later_ms = now_ms + constants.x509_leaf_ttl_ms_max + 3_600_000;
    const expired = node.require_node("node1.crt", "node1", later_ms, &diag);
    try testing.expectError(error.Failed, expired);
    try testing.expect(diag.fixes.count > 0);
    const fix = diag.fixes.items[0];
    const named = std.mem.indexOf(u8, fix.sentence.slice(), "issue-node") != null or
        std.mem.indexOf(u8, fix.command.slice(), "issue-node") != null;
    try testing.expect(named);
}

fn wall_ms(io: std.Io) u64 {
    return @intCast(std.Io.Clock.real.now(io).toMilliseconds());
}

/// A node certificate for `node` with `lifetime`, and its key pair, as the agent stores them.
fn node_certificate(
    io: std.Io,
    ca: *const peer_ca.Ca,
    node: []const u8,
    lifetime: x509.Lifetime,
    out: *x509.Der,
) !Ed25519.KeyPair {
    var seed = try secure_random.random_seed(io);
    defer std.crypto.secureZero(u8, &seed);
    const key = try Ed25519.KeyPair.generateDeterministic(seed);
    try ca.issue_node_certificate(out, &.{
        .node = node,
        .subject_key = key.public_key.toBytes(),
        .lifetime = lifetime,
    });
    return key;
}

test "an agent presents its stored node.crt only while it is valid and its own (B7 slice 3)" {
    // Goal: review MUST 2. A stored node.crt that expired, is not yet valid, names another node
    // or is not of the key beside it is not presented, so `open_tls` falls back to --cert.
    // Method: issue each with the server's CA and offer it to `present` for node1; the
    // credentials must keep presenting --cert. Then a valid one is taken.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var node: api_tls_client.Credentials = undefined;
    try rig.load("node1", &node);
    defer node.deinit();
    const before = node.certificate;
    const now_ms = wall_ms(rig.io);
    const day_ms: u64 = 24 * 3_600_000;
    const ca = &rig.server.ca;
    var der: x509.Der = .{};
    const past: x509.Lifetime = .{
        .not_before_ms = now_ms - 3 * day_ms,
        .not_after_ms = now_ms - day_ms,
    };
    const expired_key = try node_certificate(rig.io, ca, "node1", past, &der);
    try testing.expect(node.present(&der, expired_key, "node1", now_ms) != null);
    const future: x509.Lifetime = .{
        .not_before_ms = now_ms + day_ms,
        .not_after_ms = now_ms + 2 * day_ms,
    };
    const early_key = try node_certificate(rig.io, ca, "node1", future, &der);
    try testing.expect(node.present(&der, early_key, "node1", now_ms) != null);
    const window = try ca.window(constants.x509_leaf_ttl_ms_max);
    const other_key = try node_certificate(rig.io, ca, "node2", window, &der);
    const why = node.present(&der, other_key, "node1", now_ms).?;
    try testing.expect(std.mem.indexOf(u8, why, "another node") != null);
    try testing.expect(node.present(&der, early_key, "node2", now_ms) != null); // Not its key.
    try testing.expectEqualSlices(u8, before.slice(), node.certificate.slice());
    // The node's own certificate, in its window, of its key, is taken.
    try testing.expect(node.present(&der, other_key, "node2", now_ms) == null);
    try testing.expectEqualSlices(u8, der.slice(), node.certificate.slice());
}

test "the API over TLS: replies larger than the server's write buffer arrive whole (B7)" {
    // Goal: review MUST 1, the TLS writer's drain consumed only its buffer, so a reply longer
    // than it spun. Method: GET a console file of 64 KiB or more and the 25 KB stylesheet over
    // TLS and compare each body with the file the server embeds.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var admin: api_tls_client.Credentials = undefined;
    try rig.load("ops", &admin);
    defer admin.deinit();
    const paths = [_][]const u8{ "/mock/codes.js", "/css/console.css", "/console/js/main.js" };
    for (paths) |path| {
        const asset = server_static.find(path).?;
        const reply = try rig.call(&admin, "GET", path);
        try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200"));
        const split = std.mem.indexOf(u8, reply, "\r\n\r\n").?;
        try testing.expectEqualSlices(u8, asset.bytes, reply[split + 4 ..]);
    }
    try testing.expect(server_static.find("/mock/codes.js").?.bytes.len >= 64 * 1024);
    try testing.expect(server_static.find("/css/console.css").?.bytes.len >= 25_000);
}

test "TLS clients fill at most their slots, and the loopback listener is still served (B7)" {
    // Goal: the loopback reserve (docs/decisions/2026-11-14-loopback-slot-reserve.md). Method:
    // open TCP connections to the TLS port that never start a handshake until the server holds
    // its TLS share of the slots; one more is closed unserved; a plain GET on the loopback
    // listener still answers 200.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const io = rig.io;
    const share = constants.http_connections_max - constants.http_loopback_reserved;
    try testing.expectEqual(share, rig.server.shared.tls_slots);
    var streams: [share + 1]net.Stream = undefined;
    var opened: usize = 0;
    defer for (streams[0..opened]) |stream| stream.close(io);
    for (&streams) |*stream| {
        stream.* = try rig.server.tls_address().connect(io, .{ .mode = .stream });
        opened += 1;
    }
    var waited: u32 = 0;
    while (rig.server.shared.connections() < share and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(share, rig.server.shared.connections());
    // The one past the share was closed without a slot: reading it ends at once.
    var read_buffer: [64]u8 = undefined;
    var reader = streams[share].reader(io, &read_buffer);
    const got = reader.interface.allocRemaining(testing.allocator, .limited(64)) catch "";
    defer if (got.len > 0) testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);

    const stream = try rig.server.address().connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(
        "GET /v1/status HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    try writer.interface.flush();
    var buffer: [256]u8 = undefined;
    var plain = stream.reader(io, &buffer);
    const raw = try plain.interface.allocRemaining(testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200"));
}
