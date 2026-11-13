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
const server_mod = @import("server.zig");
const x509 = @import("x509.zig");

const testing = std.testing;
const net = std.Io.net;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

const Kind = enum { node, jobs, admin };

/// Issues a certificate of `kind` for `name` with the server's CA and writes `<name>.crt` and
/// `<name>.key` into `dir`.
fn issue(io: std.Io, dir: std.Io.Dir, ca: *const peer_ca.Ca, kind: Kind, name: []const u8) !void {
    var seed: [32]u8 = undefined;
    io.random(&seed);
    const key = try Ed25519.KeyPair.generateDeterministic(seed);
    var der: x509.Der = .{};
    const ttl_ms = constants.x509_leaf_ttl_ms_max;
    switch (kind) {
        .node => try ca.issue_node_certificate(&der, &.{
            .node = name,
            .subject_key = key.public_key.toBytes(),
            .ttl_ms = ttl_ms,
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
    try dir.writeFile(io, .{ .sub_path = crt, .data = pem.encode(&text, .certificate, der.slice()) });
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
    path_length: usize,
    server: *server_mod.Server,
    arena: std.heap.ArenaAllocator,

    fn start(rig: *Rig) !void {
        const room = constants.http_connections_max + constants.server_threads_extra + 8;
        rig.threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(room) });
        rig.io = rig.threaded.io();
        rig.tmp = testing.tmpDir(.{});
        rig.path_length = try rig.tmp.dir.realPath(rig.io, &rig.path_buffer);
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

    fn dir(rig: *const Rig) []const u8 {
        return rig.path_buffer[0..rig.path_length];
    }

    fn load(rig: *Rig, name: []const u8, credentials: *api_tls_client.Credentials) !void {
        const arena = rig.arena.allocator();
        var diag: Diag = undefined;
        diag.reset();
        credentials.load(rig.io, .{
            .ca = try std.fmt.allocPrint(arena, "{s}/ca.crt", .{rig.dir()}),
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
        const stream = try rig.server.tls_address().connect(rig.io, .{ .mode = .stream });
        defer stream.close(rig.io);
        const head = try std.fmt.allocPrint(
            rig.arena.allocator(),
            "{s} {s} HTTP/1.1\r\nHost: zcube-server\r\nContent-Length: 2\r\n\r\n{{}}",
            .{ method, path },
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
        return std.fmt.parseInt(u16, got.reply[9..12], 10);
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
