//! A test-only listener for `tools/public_tls_check.mjs` (docs/briefs/c5.md, slice 1): the TLS
//! server's public path over a real socket, so a real browser can complete a handshake with it.
//! It makes a test P-256 CA and a leaf for `hello.test` (seeded keys, valid for an hour around
//! now), writes the CA certificate (DER) to `--ca-out FILE`, listens on 127.0.0.1 on a free
//! port, prints `listening PORT`, and serves connections one at a time until killed: each one
//! that completes a handshake and sends a request gets `200 OK` with a body naming the server
//! name, the ALPN result and the connection number. A refused handshake prints its code and
//! cause on stderr and the listener goes on. Never shipped: `zig build public-tls-check` builds
//! it.

const std = @import("std");
const linux = std.os.linux;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const tls_server = @import("tls_server.zig");
const x509 = @import("x509.zig");
const p256 = @import("x509_p256.zig");
const secure_random = @import("secure_random.zig");

const Diag = diag_mod.Diag;
const net = std.Io.net;
const host = "hello.test";
const hour_ms: u64 = 3_600_000;

const Identity = struct {
    root: p256.KeyPair,
    key: p256.KeyPair,
    root_certificate: x509.Der,
    leaf: x509.Der,
    certificates: [2][]const u8,
    chains: [1]tls_server.PublicChain,
    table: tls_server.PublicTable,

    fn init(identity: *Identity, now_ms: u64) !void {
        identity.root = try p256.KeyPair.generateDeterministic(@splat(0xB1));
        identity.key = try p256.KeyPair.generateDeterministic(@splat(0xB2));
        const lifetime: x509.Lifetime = .{
            .not_before_ms = now_ms - hour_ms,
            .not_after_ms = now_ms + hour_ms,
        };
        identity.root_certificate = .{};
        identity.leaf = .{};
        try p256.issue_ca(&identity.root_certificate, identity.root, lifetime);
        try p256.issue_server(&identity.leaf, identity.root, &.{
            .dns_name = host,
            .sans = &.{},
            .subject_key = p256.point_of(identity.key),
            .lifetime = lifetime,
        });
        identity.certificates = .{ identity.leaf.slice(), identity.root_certificate.slice() };
        identity.chains = .{.{
            .host = host,
            .key = &identity.key,
            .certificates = &identity.certificates,
        }};
        identity.table = try tls_server.PublicTable.init(&identity.chains);
    }
};

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.debug.print("public-tls-listener: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const flag = args.next() orelse return error.Usage;
    if (!std.mem.eql(u8, flag, "--ca-out")) return error.Usage;
    const ca_out = args.next() orelse return error.Usage;
    const now_ms: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    const identity = try init.gpa.create(Identity);
    defer init.gpa.destroy(identity);
    try identity.init(now_ms);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ca_out,
        .data = identity.root_certificate.slice(),
    });
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    std.debug.print("listening {d}\n", .{listener.socket.address.getPort()});
    const server = try init.gpa.create(tls_server.Server);
    defer init.gpa.destroy(server);
    var number: u32 = 0;
    while (true) {
        var stream = try listener.accept(io);
        defer stream.close(io);
        number += 1;
        var diag: Diag = undefined;
        diag.reset();
        var random: [32]u8 = undefined;
        var secret: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret);
        try secure_random.fill(io, &random, &diag, "the TLS handshake random");
        try secure_random.fill(io, &secret, &diag, "the TLS handshake secret");
        server.init_public(&.{ .random = random, .secret = secret, .table = &identity.table });
        serve(server, stream.socket.handle, number, &diag) catch {
            if (diag.code) |code| {
                std.debug.print("connection {d}: ZC-{t}: {s}\n", .{
                    number, code, diag.last_cause() orelse "",
                });
            } else {
                std.debug.print("connection {d}: ended\n", .{number});
            }
        };
    }
}

/// Runs one connection: the handshake, one request, one answer, close_notify.
fn serve(server: *tls_server.Server, fd: linux.fd_t, number: u32, diag: *Diag) !void {
    var input: [constants.tls_record_plaintext_bytes_max + 512]u8 = undefined;
    while (true) {
        const want = server.wants();
        const got = linux.read(fd, &input, want);
        if (@as(isize, @bitCast(got)) <= 0) {
            try server.end_of_input(diag);
            return error.Ended;
        }
        const step = server.receive(input[0..got], diag) catch |err| {
            try send(fd, server.output());
            server.drain();
            return err;
        };
        try send(fd, server.output());
        server.drain();
        switch (step.event) {
            .data => return answer(server, fd, number, diag),
            .closed => return error.Ended,
            .none, .connected => {},
        }
    }
}

fn answer(server: *tls_server.Server, fd: linux.fd_t, number: u32, diag: *Diag) !void {
    var body: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&body, "public tls: host={s} alpn={s} connection={d}\n", .{
        server.server_name().?,
        if (server.alpn_http11) "http/1.1" else "none",
        number,
    });
    var response: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &response,
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ text.len, text },
    );
    var sealed: [1024]u8 = undefined;
    try send(fd, try server.seal_application(head, &sealed, diag));
    server.close_notify();
    try send(fd, server.output());
    server.drain();
    std.debug.print("connection {d}: answered {s}", .{ number, text });
}

fn send(fd: linux.fd_t, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const wrote = linux.write(fd, bytes[at..].ptr, bytes.len - at);
        if (@as(isize, @bitCast(wrote)) <= 0) return error.Ended;
        at += wrote;
    }
}
