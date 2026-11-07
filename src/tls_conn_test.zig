//! Tests for the TLS client connection (`tls_conn.zig`) over real sockets against the scripted
//! server in `tls_testpeer.zig`. Native only: sockets, threads and the real clock.
//!
//! Each test is a pair of functions, a server body that runs on a concurrent task and a client
//! function that runs on the test's own thread, over a `socketpair`. The certificates are issued
//! around the real wall clock, because the connection reads the real clock.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const peer_stream = @import("peer_stream.zig");
const schedule = @import("tls_schedule.zig");
const testpeer = @import("tls_testpeer.zig");
const tls_client = @import("tls_client.zig");
const tls_conn = @import("tls_conn.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const Code = @import("diag/codes.zig").Code;
const Conn = tls_conn.Conn;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const linux = std.os.linux;

const server_name = "broker.botpike.com";
const deadline_ms: u64 = 5000;

// ---- The server side ----

const FixtureOptions = struct {
    /// The server asks for a client certificate.
    ask: bool = false,
    /// The server's certificate is signed by a CA the client does not pin.
    other_ca: bool = false,
};

/// Everything both sides need: keys, certificates and the scripted server.
const Fixture = struct {
    ca: Ed25519.KeyPair,
    server_key: Ed25519.KeyPair,
    client_key: Ed25519.KeyPair,
    leaf: x509.Der,
    client_certificate: x509.Der,
    certificates: [1][]const u8,
    client_chain: [1][]const u8,
    peer: testpeer.Peer,
    now: u64,
    ask: bool,
    /// The length of the server's first flight, learned by the server.
    flight_length: u32,
    /// A number for the scenario: where to cut, how many records were seen.
    param: u32,

    fn init(f: *Fixture, io: std.Io, setup: FixtureOptions) !void {
        f.now = peer_stream.wall_ms(io);
        f.ask = setup.ask;
        f.flight_length = 0;
        f.param = 0;
        const window: x509.Lifetime = .{
            .not_before_ms = f.now - x509_test.hour,
            .not_after_ms = f.now + x509_test.hour,
        };
        f.ca = try x509_test.ca_pair();
        f.server_key = try Ed25519.KeyPair.generateDeterministic(@splat(5));
        f.client_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
        var signer = f.ca;
        if (setup.other_ca) signer = try Ed25519.KeyPair.generateDeterministic(@splat(0xCB));
        const request: x509.ServerRequest = .{
            .dns_name = server_name,
            .subject_key = f.server_key.public_key.toBytes(),
            .lifetime = window,
        };
        try x509.issue_server(&f.leaf, signer, &request);
        var workload = x509_test.workload_request(f.client_key.public_key.toBytes());
        workload.lifetime = window;
        try x509.issue_workload(&f.client_certificate, f.ca, &workload);
        f.certificates = .{f.leaf.slice()};
        f.client_chain = .{f.client_certificate.slice()};
        f.reset_peer();
    }

    /// A fresh server, as at the start of a connection.
    fn reset_peer(f: *Fixture) void {
        f.peer = testpeer.Peer.init(.{
            .certificates = &f.certificates,
            .key = f.server_key,
            .random = @splat(0x77),
            .secret = @splat(0x55),
            .client_auth = if (!f.ask) null else .{
                .anchor = f.ca.public_key.toBytes(),
                .now_ms = f.now,
            },
        });
    }

    fn options(f: *Fixture, io: std.Io, fd: std.posix.fd_t) tls_conn.Options {
        return .{
            .io = io,
            .fd = fd,
            .anchor = f.ca.public_key.toBytes(),
            .server_name = server_name,
        };
    }

    fn identity(f: *Fixture) tls_client.Identity {
        return .{
            .certificates = &f.client_chain,
            .signer = tls_client.key_pair_signer(&f.client_key),
        };
    }
};

fn end_in(io: std.Io, ms: u64) u64 {
    return peer_stream.boot_ms(io) + ms;
}

/// One TLS record, header and body, into `buffer`.
fn read_record(io: std.Io, fd: std.posix.fd_t, buffer: []u8) ![]u8 {
    const end = end_in(io, deadline_ms);
    try peer_stream.read_exact(io, fd, buffer[0..constants.tls_record_header_bytes], end);
    const length = std.mem.readInt(u16, buffer[3..5], .big);
    const total = constants.tls_record_header_bytes + length;
    try peer_stream.read_exact(io, fd, buffer[constants.tls_record_header_bytes..total], end);
    return buffer[0..total];
}

/// The ClientHello in, the server's whole first flight made but not yet sent.
fn make_flight(io: std.Io, fd: std.posix.fd_t, f: *Fixture, out: []u8) ![]u8 {
    var hello: [constants.tls_client_hello_bytes_max]u8 = undefined;
    const record = try read_record(io, fd, &hello);
    const flight = f.peer.respond(record, out);
    f.flight_length = @intCast(flight.len);
    return flight;
}

/// The client's last flight: an optional change_cipher_spec, then `records` handshake records.
fn read_client_flight(io: std.Io, fd: std.posix.fd_t, f: *Fixture, records: u32) !void {
    var bytes: [constants.tls_output_bytes_max]u8 = undefined;
    var length: usize = 0;
    var count: u32 = 0;
    while (count < records) {
        const record = try read_record(io, fd, bytes[length..]);
        length += record.len;
        if (record[0] != @backingInt(schedule.ContentType.change_cipher_spec)) count += 1;
    }
    const result = f.peer.accept_client_flight(bytes[0..length]);
    if (result != .ok) return error.ClientFlightRefused;
}

fn server_handshake(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var out: [8192]u8 = undefined;
    const flight = try make_flight(io, fd, f, &out);
    try peer_stream.write_all(io, fd, flight, end_in(io, deadline_ms));
    try read_client_flight(io, fd, f, if (f.ask) 3 else 1);
}

fn send_app(io: std.Io, fd: std.posix.fd_t, f: *Fixture, content: []const u8) !void {
    var out: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
    try peer_stream.write_all(io, fd, f.peer.application(&out, content), end_in(io, deadline_ms));
}

fn send_raw(io: std.Io, fd: std.posix.fd_t, record: []const u8) !void {
    try peer_stream.write_all(io, fd, record, end_in(io, deadline_ms));
}

/// The next record from the client, opened. The content lives in `buffer`.
fn read_open(io: std.Io, fd: std.posix.fd_t, f: *Fixture, buffer: []u8) !schedule.Opened {
    return f.peer.open(try read_record(io, fd, buffer));
}

fn expect_app(io: std.Io, fd: std.posix.fd_t, f: *Fixture, text: []const u8) !void {
    var buffer: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
    const opened = try read_open(io, fd, f, &buffer);
    try std.testing.expectEqual(schedule.ContentType.application_data, opened.content_type);
    try std.testing.expectEqualStrings(text, opened.content);
}

fn expect_close_notify(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var buffer: [64]u8 = undefined;
    const opened = try read_open(io, fd, f, &buffer);
    try std.testing.expectEqual(schedule.ContentType.alert, opened.content_type);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, opened.content);
}

/// Wraps a server body so a task returns whether it finished without an error.
fn Task(comptime body: anytype) type {
    return struct {
        fn run(io: std.Io, fd: std.posix.fd_t, f: *Fixture) bool {
            body(io, fd, f) catch return false;
            return true;
        }
    };
}

const Pair = struct {
    fds: [2]std.posix.fd_t,

    fn make() !Pair {
        var fds: [2]i32 = undefined;
        const made = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(made));
        return .{ .fds = fds };
    }

    fn close(pair: Pair) void {
        for (pair.fds) |fd| _ = linux.close(fd);
    }
};

/// Runs `server` on a task and `client` here, over one socket pair. The client's end is shut
/// when it returns, so a server still waiting on it ends and does not run into its deadline.
/// Returns the server's verdict beside the client's error, so both are always joined.
fn run(comptime server: anytype, comptime client: anytype, f: *Fixture) !void {
    const io = std.testing.io;
    const pair = try Pair.make();
    defer pair.close();
    var future = try io.concurrent(Task(server).run, .{ io, pair.fds[1], f });
    const result = client(io, pair.fds[0], f);
    _ = linux.shutdown(pair.fds[0], 2);
    const server_ok = future.await(io);
    try result;
    try std.testing.expect(server_ok);
}

/// Like `run`, when the server is expected to fail (it is cut off by the client).
fn run_lenient(comptime server: anytype, comptime client: anytype, f: *Fixture) !void {
    const io = std.testing.io;
    const pair = try Pair.make();
    defer pair.close();
    var future = try io.concurrent(Task(server).run, .{ io, pair.fds[1], f });
    const result = client(io, pair.fds[0], f);
    _ = linux.shutdown(pair.fds[0], 2);
    _ = future.await(io);
    try result;
}

fn new_diag() Diag {
    var diag: Diag = undefined;
    diag.reset();
    return diag;
}

fn expect_code(diag: *const Diag, code: Code) !void {
    try std.testing.expect(diag.code != null);
    try std.testing.expectEqual(code, diag.code.?);
}

// ---- A request and an answer, and a goodbye ----

fn echo_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    try expect_app(io, fd, f, "ping");
    try send_app(io, fd, f, "pong");
    try expect_close_notify(io, fd, f);
}

fn echo_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    // No flush: a write leaves at once, or the server never answers.
    try conn.write("ping", end, &diag);
    var out: [16]u8 = undefined;
    const got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("pong", out[0..got]);
    try conn.close(end, &diag);
    try std.testing.expect(diag.code == null);
    try std.testing.expectError(error.Closed, conn.read(&out, end, &diag));
    try std.testing.expectError(error.Closed, conn.write("x", end, &diag));
}

test "a request goes out and an answer comes back, and close sends close_notify" {
    // Goal: the whole life of a connection over a real socket: handshake, one record each way
    // and the goodbye, with no diagnostic. Method: the scripted server checks the plaintext it
    // reads and the close_notify; the client checks the answer and what is refused afterwards.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(echo_body, echo_client, &f);
}

// ---- Client authentication ----

fn auth_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    var options = f.options(io, fd);
    options.client_auth = .{ .required = f.identity() };
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    try conn.write("ping", end, &diag);
    try conn.flush(end, &diag);
    var out: [16]u8 = undefined;
    const got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("pong", out[0..got]);
    try conn.close(end, &diag);
    try std.testing.expect(diag.code == null);
}

test "the shell presents the workload certificate when the server asks" {
    // Goal: `Options.client_auth` reaches the client and the server verifies the chain and the
    // signature. Method: a server that requires a certificate, a required identity, and a check
    // that the key the server verified is the client's.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{ .ask = true });
    try run(echo_body, auth_client, &f);
    try std.testing.expect(f.peer.client_key != null);
    try std.testing.expectEqualSlices(u8, &f.client_key.public_key.toBytes(), &f.peer.client_key.?);
}

// ---- Server-sent events ----

const event_count: u32 = 6;
const padding: [1200]u8 = @splat('x');

fn event_text(buffer: []u8, index: u32) []const u8 {
    const pad: usize = index * 200;
    assert(pad <= padding.len);
    const format = "event: tick\ndata: {d} {s}\n\n";
    return std.fmt.bufPrint(buffer, format, .{ index, padding[0..pad] }) catch
        unreachable; // The buffer holds the longest event.
}

fn sse_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    var text: [2048]u8 = undefined;
    for (0..event_count) |index| {
        // The event leaves only once the client has said it is waiting for it, so a client that
        // held its read until more data came would deadlock here and not pass.
        try expect_app(io, fd, f, "go");
        try send_app(io, fd, f, event_text(&text, @intCast(index)));
    }
    try expect_close_notify(io, fd, f);
}

fn sse_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    var text: [2048]u8 = undefined;
    var out: [2048]u8 = undefined;
    for (0..event_count) |index| {
        const end = end_in(io, deadline_ms);
        try conn.write("go", end, &diag);
        try conn.flush(end, &diag);
        const expected = event_text(&text, @intCast(index));
        if (index + 1 < event_count) {
            // One read returns the whole event: it is one record, and nothing waits for more.
            const got = try conn.read(&out, end, &diag);
            try std.testing.expectEqualStrings(expected, out[0..got]);
        } else {
            // The last is read in pieces of seven bytes: what a small buffer leaves is kept.
            var at: usize = 0;
            while (at < expected.len) {
                const got = try conn.read(out[0..7], end, &diag);
                try std.testing.expect(got <= 7);
                try std.testing.expectEqualStrings(expected[at..][0..got], out[0..got]);
                at += got;
            }
        }
    }
    try conn.close(end_in(io, deadline_ms), &diag);
    try std.testing.expect(diag.code == null);
}

test "each event is readable as soon as its record arrives" {
    // Goal: the SSE pattern of the brief: a long-lived reader sees every event on its own, the
    // moment it comes, and a short buffer leaves the rest for the next read. Method: the server
    // sends event i only after the client's i-th request, so a read that waited for more bytes
    // than one record would block until its deadline and fail.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(sse_body, sse_client, &f);
}

// ---- Many records ----

const bulk_bytes: u32 = 40_000;

fn bulk_byte(at: usize) u8 {
    return @intCast(at % 251);
}

fn bulk_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    var buffer: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
    var seen: usize = 0;
    var records: u32 = 0;
    while (seen < bulk_bytes) {
        const opened = try read_open(io, fd, f, &buffer);
        for (opened.content, 0..) |byte, at| {
            try std.testing.expectEqual(bulk_byte(seen + at), byte);
        }
        seen += opened.content.len;
        records += 1;
    }
    try std.testing.expectEqual(bulk_bytes, seen);
    f.param = records;
    var reply: [bulk_bytes]u8 = undefined;
    for (&reply, 0..) |*byte, at| byte.* = bulk_byte(at);
    var sent: usize = 0;
    while (sent < reply.len) {
        const count = @min(reply.len - sent, 7000);
        try send_app(io, fd, f, reply[sent..][0..count]);
        sent += count;
    }
}

fn bulk_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    var piece: [1000]u8 = undefined;
    var sent: usize = 0;
    while (sent < bulk_bytes) {
        for (&piece, 0..) |*byte, at| byte.* = bulk_byte(sent + at);
        try conn.write(&piece, end, &diag);
        sent += piece.len;
    }
    try conn.flush(end, &diag);
    var back: [bulk_bytes]u8 = undefined;
    var got: usize = 0;
    while (got < bulk_bytes) got += try conn.read(back[got..], end, &diag);
    for (back, 0..) |byte, at| try std.testing.expectEqual(bulk_byte(at), byte);
    try std.testing.expect(diag.code == null);
}

test "forty thousand bytes cross as one record per write and come back in pieces" {
    // Goal: each write leaves as records of its own and the reader reassembles several.
    // Method: 40 writes of 1000 bytes; the server counts the records it opens (one per write)
    // and answers in 7000-byte records.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(bulk_body, bulk_client, &f);
    try std.testing.expectEqual(@as(u32, 40), f.param);
}

// ---- A read that times out ----

fn late_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    try expect_app(io, fd, f, "now");
    try send_app(io, fd, f, "late");
}

fn late_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    var out: [16]u8 = undefined;
    // Nothing is coming until the client asks, so this read can only time out.
    try std.testing.expectError(
        error.Timeout,
        conn.read(&out, end_in(io, 50), &diag),
    );
    try std.testing.expect(diag.code == null);
    const end = end_in(io, deadline_ms);
    try conn.write("now", end, &diag);
    try conn.flush(end, &diag);
    const got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("late", out[0..got]);
}

test "a read that times out leaves the connection usable" {
    // Goal: a read deadline is not a failure. Method: a read 50 ms long while the server waits
    // for the client; then the request and the answer on the same connection.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(late_body, late_client, &f);
}

// ---- The server's goodbye, and no goodbye ----

fn bye_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    try send_app(io, fd, f, "bye");
    var out: [64]u8 = undefined;
    try send_raw(io, fd, f.peer.close_notify(&out));
}

fn bye_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    var out: [16]u8 = undefined;
    const got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("bye", out[0..got]);
    try std.testing.expectEqual(@as(usize, 0), try conn.read(&out, end, &diag));
    try std.testing.expectEqual(@as(usize, 0), try conn.read(&out, end, &diag));
    try std.testing.expectError(error.Closed, conn.write("x", end, &diag));
    try std.testing.expect(diag.code == null);
}

test "close_notify ends the stream, and nothing is written after it" {
    // Goal: a clean end is a zero read, repeatable, and is not an error. Method: the server
    // sends data and close_notify and the client reads to the end.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(bye_body, bye_client, &f);
}

fn drop_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    try send_app(io, fd, f, "cut");
    _ = linux.shutdown(fd, 1);
}

fn drop_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    var out: [16]u8 = undefined;
    const got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("cut", out[0..got]);
    try std.testing.expectError(error.Refused, conn.read(&out, end, &diag));
    try expect_code(&diag, .E0816);
    // RA-N7: a call on the dead connection is Closed, and it carries a coded line.
    var later = new_diag();
    try std.testing.expectError(error.Closed, conn.read(&out, end, &later));
    try expect_code(&later, .E0816);
    var again = new_diag();
    try std.testing.expectError(error.Closed, conn.write("x", end, &again));
    try expect_code(&again, .E0816);
}

test "a stream that ends without close_notify is ZC-E0816, never an end of data" {
    // Goal: truncation is told from a goodbye. Method: the server sends a record and shuts its
    // end without close_notify; the client reads the record, then the end.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(drop_body, drop_client, &f);
}

// ---- Key updates ----

fn update_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    var out: [64]u8 = undefined;
    try send_app(io, fd, f, "one");
    try send_raw(io, fd, f.peer.key_update(&out, true));
    try send_app(io, fd, f, "two");
    // The client answers the request under its old keys, then goes on under new ones.
    var buffer: [64]u8 = undefined;
    const answer = try read_open(io, fd, f, &buffer);
    try std.testing.expectEqual(schedule.ContentType.handshake, answer.content_type);
    try std.testing.expectEqual(schedule.key_update_type, answer.content[0]);
    try f.peer.read.rekey();
    try expect_app(io, fd, f, "ack");
}

fn update_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    var out: [16]u8 = undefined;
    var got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("one", out[0..got]);
    got = try conn.read(&out, end, &diag);
    try std.testing.expectEqualStrings("two", out[0..got]);
    try conn.write("ack", end, &diag);
    try conn.flush(end, &diag);
    try std.testing.expect(diag.code == null);
}

test "a KeyUpdate the server asks for is answered before the next write" {
    // Goal: the answer the client queues in a read step is sent at once. Method: the server
    // requests an update, then expects the client's KeyUpdate and, under the new keys, data.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(update_body, update_client, &f);
}

fn limit_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    // The client's write keys have sealed all but one record of their limit; the nonce follows
    // the sequence, so the server's read keys stand at the same number.
    f.peer.read.sequence = constants.tls_records_per_key_max - 1;
    try expect_app(io, fd, f, "last");
    var buffer: [64]u8 = undefined;
    const update = try read_open(io, fd, f, &buffer);
    try std.testing.expectEqual(schedule.ContentType.handshake, update.content_type);
    try std.testing.expectEqual(schedule.key_update_type, update.content[0]);
    try f.peer.read.rekey();
    try expect_app(io, fd, f, "first");
}

fn limit_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const end = end_in(io, deadline_ms);
    conn.client.write.sequence = constants.tls_records_per_key_max - 1;
    try conn.write("last", end, &diag);
    try conn.flush(end, &diag);
    try std.testing.expect(conn.client.write.update_due());
    try conn.write("first", end, &diag);
    try conn.flush(end, &diag);
    try std.testing.expect(diag.code == null);
    try std.testing.expect(conn.client.write.sequence < constants.tls_records_per_key_max);
}

test "the writer crosses the record limit by sending a KeyUpdate first" {
    // Goal: the shell stays inside the keys' record limit without a step of its own. Method:
    // set both directions one record short of the limit; the server must see the last record,
    // a KeyUpdate and then the first record under the new keys.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(limit_body, limit_client, &f);
}

// ---- Deadlines ----

fn silent_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    _ = f;
    var hello: [constants.tls_client_hello_bytes_max]u8 = undefined;
    _ = try read_record(io, fd, &hello);
    // Say nothing: the client's deadline is the only way out.
    peer_stream.wait_ready(io, fd, std.posix.POLL.IN, end_in(io, deadline_ms)) catch {};
}

fn dribble_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var out: [8192]u8 = undefined;
    const flight = try make_flight(io, fd, f, &out);
    for (flight) |*byte| {
        // One byte every 20 ms: a server that is never silent for long, and never finishes.
        peer_stream.wait_ready(io, fd, std.posix.POLL.IN, end_in(io, 20)) catch {};
        peer_stream.write_all(io, fd, byte[0..1], end_in(io, 100)) catch return;
    }
}

fn timeout_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    var options = f.options(io, fd);
    options.handshake_timeout_ms = 200;
    const started = peer_stream.boot_ms(io);
    try std.testing.expectError(error.Refused, conn.open(&options, &diag));
    const took = peer_stream.boot_ms(io) - started;
    try expect_code(&diag, .E0816);
    try std.testing.expect(took >= 200);
    try std.testing.expect(took < deadline_ms);
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.Closed, conn.read(&out, end_in(io, 50), &diag));
}

test "a server that stays silent ends the handshake at its deadline" {
    // Goal: the handshake has a deadline that is a diagnostic, not a hang. Method: a server
    // that reads the ClientHello and says nothing, with a 200 ms limit.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(silent_body, timeout_client, &f);
}

test "a server that dribbles bytes cannot hold the handshake past its deadline" {
    // Goal: the deadline is one for the whole handshake, not for each read. Method: a server
    // that sends its flight a byte every 20 ms, with a 200 ms limit.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run_lenient(dribble_body, timeout_client, &f);
}

fn idle_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    // Reads nothing after the handshake: the client's writes fill the socket.
    try server_handshake(io, fd, f);
}

fn stall_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    const big = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 0x5a);
    try std.testing.expectError(error.Timeout, conn.write(big, end_in(io, 200), &diag));
    // A record may be half sent: the connection is over.
    try std.testing.expectError(error.Closed, conn.write("x", end_in(io, 200), &diag));
    try std.testing.expect(diag.code == null);
}

test "a peer that stops reading ends a write in a timeout" {
    // Goal: a write has a deadline too. Method: a server that finishes the handshake and then
    // never reads, and 4 MiB written against a socket that holds far less.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(idle_body, stall_client, &f);
}

// ---- Refusals ----

/// Sends the flight and reads what the client sends back, whatever it is.
fn refuse_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var out: [8192]u8 = undefined;
    const flight = try make_flight(io, fd, f, &out);
    try peer_stream.write_all(io, fd, flight, end_in(io, deadline_ms));
    var buffer: [constants.tls_output_bytes_max]u8 = undefined;
    // Either the client's alert or its end; the diagnostic is the client's business.
    f.param = if (read_record(io, fd, &buffer)) |record| @intCast(record.len) else |_| 0;
}

fn untrusted_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try std.testing.expectError(error.Refused, conn.open(&options, &diag));
    try expect_code(&diag, .E0810);
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.Closed, conn.read(&out, end_in(io, 50), &diag));
}

test "a server certificate from another CA is refused and the alert is sent" {
    // Goal: a refusal is one diagnostic and the client says goodbye with an alert. Method: a
    // server certificate signed by another key; the server must see a record from the client.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{ .other_ca = true });
    try run(refuse_body, untrusted_client, &f);
    try std.testing.expect(f.param > 0);
}

fn failing_sign(context: *const anyopaque, message: []const u8) ?[64]u8 {
    _ = context;
    _ = message;
    return null;
}

fn signer_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    var options = f.options(io, fd);
    var identity = f.identity();
    identity.signer = .{ .context = &f.client_key, .sign = failing_sign };
    options.client_auth = .{ .required = identity };
    try std.testing.expectError(error.Refused, conn.open(&options, &diag));
    try expect_code(&diag, .E0820);
}

test "a signer that fails is ZC-E0820 through the shell" {
    // Goal: the shell passes the identity's signer on and surfaces its failure. Method: a
    // required identity whose signer returns nothing, against a server that asks.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{ .ask = true });
    try run(refuse_body, signer_client, &f);
}

// ---- A cut at every byte ----

fn cut_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var out: [8192]u8 = undefined;
    const flight = try make_flight(io, fd, f, &out);
    try peer_stream.write_all(io, fd, flight[0..f.param], end_in(io, deadline_ms));
    _ = linux.shutdown(fd, 1);
}

fn cut_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try std.testing.expectError(error.Refused, conn.open(&options, &diag));
    try expect_code(&diag, .E0816);
}

fn learn_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    try expect_close_notify(io, fd, f);
}

fn learn_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    try conn.close(end_in(io, deadline_ms), &diag);
}

test "the server's flight cut at every byte is a refusal, never a connection" {
    // Goal: no prefix of the server's first flight ends in an open connection or a hang, and
    // each is ZC-E0816. Method: one whole run learns the flight's length; then, for every
    // shorter length, the server sends that many bytes and shuts its end. (A cut of the client's
    // own flight is not observable from here: the client has finished by then.)
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(learn_body, learn_client, &f);
    const length = f.flight_length;
    try std.testing.expect(length > 300); // A real certificate chain is in it.
    var cut: u32 = 0;
    while (cut < length) : (cut += 1) {
        f.reset_peer();
        f.param = cut;
        try run_lenient(cut_body, cut_client, &f);
    }
}

// ---- Sends made on a read's behalf ----

/// Fills the client's send buffer with junk, outside the connection, until the socket refuses.
/// Nothing the client sends next can leave. Junk is fine: these tests end at the client.
fn fill_socket(fd: std.posix.fd_t) !void {
    const junk: [4096]u8 = @splat(0xa5);
    for ([_]usize{ junk.len, 1 }) |size| {
        var sent: usize = 0;
        while (true) {
            const wrote = linux.sendto(fd, &junk, size, linux.MSG.DONTWAIT, null, 0);
            switch (linux.errno(wrote)) {
                .SUCCESS => sent += wrote,
                .AGAIN => break,
                else => return error.TestUnexpectedResult,
            }
            if (sent > (64 << 20)) return error.TestUnexpectedResult; // Never fills.
        }
    }
}

fn full_update_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    var out: [64]u8 = undefined;
    try send_raw(io, fd, f.peer.key_update(&out, true));
}

fn full_update_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    try fill_socket(fd);
    var out: [16]u8 = undefined;
    // The answer cannot leave: the write keys have moved on, so this is the end of the connection,
    // and the call that finds out says so, with a diagnostic, instead of `Timeout`.
    try std.testing.expectError(error.Refused, conn.read(&out, end_in(io, 200), &diag));
    try expect_code(&diag, .E0816);
    try std.testing.expectError(error.Closed, conn.read(&out, end_in(io, 200), &diag));
    try std.testing.expectError(error.Closed, conn.write("x", end_in(io, 200), &diag));
}

test "a KeyUpdate answer that times out ends the connection" {
    // Goal: a send made for a read is as fatal on timeout as a write: its keys cannot be undone.
    // Method: the client's send buffer is full when the server asks for a KeyUpdate.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(full_update_body, full_update_client, &f);
}

fn full_bye_body(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    try server_handshake(io, fd, f);
    var out: [64]u8 = undefined;
    try send_raw(io, fd, f.peer.close_notify(&out));
}

fn full_bye_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    try fill_socket(fd);
    var out: [16]u8 = undefined;
    // The reply to close_notify cannot leave; the stream has ended all the same, for every read.
    try std.testing.expectEqual(@as(usize, 0), try conn.read(&out, end_in(io, 200), &diag));
    try std.testing.expectEqual(@as(usize, 0), try conn.read(&out, end_in(io, 200), &diag));
    try std.testing.expectError(error.Closed, conn.write("x", end_in(io, 200), &diag));
    try conn.close(end_in(io, 200), &diag);
    try std.testing.expect(diag.code == null);
}

test "a close_notify whose reply cannot be sent still ends the stream" {
    // Goal: a repeated read after the peer's close_notify is end of stream, never a panic.
    // Method: the client's send buffer is full when the server says goodbye.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(full_bye_body, full_bye_client, &f);
}

fn seal_fail_client(io: std.Io, fd: std.posix.fd_t, f: *Fixture) !void {
    var conn: Conn = undefined;
    defer conn.deinit();
    var diag = new_diag();
    const options = f.options(io, fd);
    try conn.open(&options, &diag);
    // The write keys are at their record limit and cannot move on again.
    conn.client.write.sequence = constants.tls_records_per_key_max;
    conn.client.write.updates = constants.tls_key_updates_per_connection_max;
    try std.testing.expectError(error.Refused, conn.write("secret", end_in(io, 200), &diag));
    try expect_code(&diag, .E0815);
    // The bytes are gone, not queued, and the natural cleanup does not trip an assert.
    try std.testing.expectEqual(@as(u32, 0), conn.plain_length);
    try std.testing.expect(std.mem.allEqual(u8, conn.plain[0..6], 0));
    try conn.close(end_in(io, 200), &diag);
    try std.testing.expectError(error.Closed, conn.write("x", end_in(io, 200), &diag));
}

test "a seal that fails drops what was queued, so close afterwards is safe" {
    // Goal: `close` after a `Refused` write never panics. Method: the write keys cannot move on
    // (ZC-E0815), a write is refused, then the caller closes.
    var f: Fixture = undefined;
    try f.init(std.testing.io, .{});
    try run(idle_body, seal_fail_client, &f);
}

test "the answer to a KeyUpdate gets a budget of its own when the read's deadline is spent" {
    // Goal: a deadline that ticks by between the read and the answer does not skip the send.
    const flush: u64 = constants.tls_alert_flush_ms;
    try std.testing.expectEqual(@as(u64, 1000 + flush), tls_conn.reply_end_ms(1000, 1000));
    try std.testing.expectEqual(@as(u64, 1000 + flush), tls_conn.reply_end_ms(1000, 900));
    try std.testing.expectEqual(@as(u64, 9000), tls_conn.reply_end_ms(1000, 9000));
}
