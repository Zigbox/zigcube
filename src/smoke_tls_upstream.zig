//! agent-smoke's relay upstream over TLS (B4 slice 2): a thread on a loopback port that serves
//! each connection with the scripted server of `tls_testpeer.zig`, under a server certificate of
//! a CA of its own (written as PEM for the server's `server_ca`), pinning the cluster CA (the
//! agent's `ca.pub`) and the job's SPIFFE ID as a stock server would. It answers the first
//! record with `echo:` and its bytes, then closes, and keeps what the last client certificate
//! said for the smoke to check. One connection at a time (`tls_testpeer` keeps global buffers).

const std = @import("std");
const constants = @import("constants.zig");
const peer_stream = @import("peer_stream.zig");
const schedule = @import("tls_schedule.zig");
const testpeer = @import("tls_testpeer.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const linux = std.os.linux;
const fd_t = linux.fd_t;

pub const server_name = "upstream.smoke.test";
pub const cluster = "smoke.test";
const deadline_ms: u64 = 5000;
const hour_ms: u64 = 60 * 60 * 1000;

pub const Seen = struct {
    /// How the last handshake's client flight ended; null before the first.
    flight: ?testpeer.ClientFlight = null,
    uri: [128]u8 = undefined,
    uri_length: u32 = 0,
    image_digest: [32]u8 = @splat(0),
    placement_epoch: u64 = 0,
    connections: u32 = 0,
};

pub const Upstream = struct {
    io: std.Io,
    fd: fd_t,
    /// The agent's `ca.pub` (64 hex digits): the cluster CA, read at each connection.
    ca_path: []const u8,
    /// The SPIFFE ID the client's certificate must carry.
    job_uri: []const u8,
    key: Ed25519.KeyPair,
    leaf: x509.Der = .{},
    chain: [1][]const u8 = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    seen: Seen = .{},

    /// Makes the upstream's CA and leaf; writes the CA's certificate as PEM to `pem_path`.
    pub fn init(upstream: *Upstream, pem_path: []const u8) !void {
        const ca = try Ed25519.KeyPair.generateDeterministic(@splat(0x71));
        upstream.key = try Ed25519.KeyPair.generateDeterministic(@splat(0x72));
        const now = peer_stream.wall_ms(upstream.io);
        const lifetime: x509.Lifetime = .{
            .not_before_ms = now - hour_ms,
            .not_after_ms = now + 24 * hour_ms,
        };
        var ca_der: x509.Der = .{};
        try x509.issue_ca(&ca_der, ca, lifetime);
        try x509.issue_server(&upstream.leaf, ca, &.{
            .dns_name = server_name,
            .subject_key = upstream.key.public_key.toBytes(),
            .lifetime = lifetime,
        });
        upstream.chain = .{upstream.leaf.slice()};
        var base64: [(constants.x509_cert_bytes_max + 2) / 3 * 4]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&base64, ca_der.slice());
        var text: [base64.len + 64]u8 = undefined;
        const pem = try std.fmt.bufPrint(
            &text,
            "-----BEGIN CERTIFICATE-----\n{s}\n-----END CERTIFICATE-----\n",
            .{encoded},
        );
        try std.Io.Dir.cwd().writeFile(upstream.io, .{ .sub_path = pem_path, .data = pem });
    }

    pub fn run(upstream: *Upstream) void {
        while (!upstream.stopping.load(.acquire)) {
            var fds = [1]linux.pollfd{
                .{ .fd = upstream.fd, .events = linux.POLL.IN, .revents = 0 },
            };
            if (linux.poll(&fds, 1, 50) <= 0) continue;
            const accepted = linux.accept4(upstream.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) continue;
            const peer: fd_t = @intCast(accepted);
            defer _ = linux.close(peer);
            upstream.serve(peer) catch {}; // What it saw is in `seen`.
        }
    }

    /// A copy of what the last connection's client certificate said.
    pub fn last(upstream: *Upstream) Seen {
        while (!upstream.mutex.tryLock()) std.atomic.spinLoopHint();
        defer upstream.mutex.unlock();
        return upstream.seen;
    }

    fn serve(upstream: *Upstream, fd: fd_t) !void {
        const io = upstream.io;
        var anchor: [32]u8 = undefined;
        var ca_text: [128]u8 = undefined;
        const ca_hex = try std.Io.Dir.cwd().readFile(io, upstream.ca_path, &ca_text);
        _ = try std.fmt.hexToBytes(&anchor, std.mem.trimEnd(u8, ca_hex, "\n"));
        var peer = testpeer.Peer.init(.{
            .certificates = &upstream.chain,
            .key = upstream.key,
            .random = @splat(0x77),
            .secret = @splat(0x55),
            .client_auth = .{
                .anchor = anchor,
                .now_ms = peer_stream.wall_ms(io),
                .name = upstream.job_uri,
            },
        });
        var hello: [constants.tls_client_hello_bytes_max]u8 = undefined;
        var out: [8192]u8 = undefined;
        const flight = peer.respond(try read_record(io, fd, &hello), &out);
        try peer_stream.write_all(io, fd, flight, end_ms(io));
        var bytes: [constants.tls_output_bytes_max]u8 = undefined;
        var length: usize = 0;
        var count: u32 = 0;
        while (count < 3) {
            const record = try read_record(io, fd, bytes[length..]);
            length += record.len;
            if (record[0] != @backingInt(schedule.ContentType.change_cipher_spec)) count += 1;
        }
        const result = peer.accept_client_flight(bytes[0..length]);
        upstream.note(result, peer.client_leaf());
        if (result != .ok) return;
        var buffer: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
        const opened = try peer.open(try read_record(io, fd, &buffer));
        if (opened.content_type != .application_data) return;
        var answer: [72]u8 = undefined;
        @memcpy(answer[0..5], "echo:");
        const take = @min(opened.content.len, answer.len - 5);
        @memcpy(answer[5..][0..take], opened.content[0..take]);
        var sealed: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
        const reply = peer.application(&sealed, answer[0 .. 5 + take]);
        try peer_stream.write_all(io, fd, reply, end_ms(io));
        try peer_stream.write_all(io, fd, peer.close_notify(&sealed), end_ms(io));
    }

    fn note(upstream: *Upstream, flight: testpeer.ClientFlight, leaf: []const u8) void {
        while (!upstream.mutex.tryLock()) std.atomic.spinLoopHint();
        defer upstream.mutex.unlock();
        const seen = &upstream.seen;
        seen.connections += 1;
        seen.flight = flight;
        seen.uri_length = 0;
        var detail: x509.Detail = .{};
        const parsed = x509.parse_profile(leaf, .cluster, &detail) catch return;
        const uri = parsed.name.of(leaf);
        if (uri.len > seen.uri.len) return;
        @memcpy(seen.uri[0..uri.len], uri);
        seen.uri_length = @intCast(uri.len);
        const decoded = x509_identity.decode(parsed.identity.of(leaf)) catch return;
        seen.image_digest = decoded.image_digest;
        seen.placement_epoch = decoded.placement_epoch;
    }
};

fn end_ms(io: std.Io) u64 {
    return peer_stream.boot_ms(io) + deadline_ms;
}

fn read_record(io: std.Io, fd: fd_t, buffer: []u8) ![]u8 {
    const end = end_ms(io);
    try peer_stream.read_exact(io, fd, buffer[0..constants.tls_record_header_bytes], end);
    const length = std.mem.readInt(u16, buffer[3..5], .big);
    const total = constants.tls_record_header_bytes + length;
    if (total > buffer.len) return error.TooLong;
    try peer_stream.read_exact(io, fd, buffer[constants.tls_record_header_bytes..total], end);
    return buffer[0..total];
}
