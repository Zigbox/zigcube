//! Tests for the TLS 1.3 client handshake (`tls_client.zig`) against the scripted server in
//! `tls_testpeer.zig`. Core code: runs under WASI too.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const schedule = @import("tls_schedule.zig");
const tls_client = @import("tls_client.zig");
const testpeer = @import("tls_testpeer.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const Event = tls_client.Event;

const server_name = "broker.botpike.com";

/// Client authentication for a test: what the server asks and what the client has.
const Auth = struct {
    /// The server sends a CertificateRequest.
    ask: bool = false,
    context: []const u8 = "",
    schemes: []const u16 = &.{wire.scheme_ed25519},
    cert_schemes: ?[]const u16 = null,
    authorities: bool = false,
    /// The server refuses an empty Certificate.
    server_requires: bool = true,
    /// The client has a workload identity.
    identity: bool = false,
    /// The client fails unless asked.
    require: bool = false,
    /// With the CA certificate after the workload's.
    with_ca: bool = false,
    certificate: enum { good, other_ca, expired } = .good,
    /// The signer returns nothing.
    broken_signer: bool = false,
};

fn broken_sign(context: *const anyopaque, message: []const u8) ?[64]u8 {
    _ = context;
    _ = message;
    return null;
}

const CertKind = enum { good, other_ca, expired, wrong_name, workload, tampered, none, three };

/// A client, a scripted server and the bytes between them.
const Rig = struct {
    client: tls_client.Client,
    peer: testpeer.Peer,
    diag: Diag,
    server_key: Ed25519.KeyPair,
    leaf: x509.Der,
    second: x509.Der,
    certificates: [3][]const u8,
    client_key: Ed25519.KeyPair,
    client_certificate: x509.Der,
    client_chain: [2][]const u8,
    ca_certificate: x509.Der,
    sent: [4096]u8,
    sent_length: u32,
    flight: [8192]u8,
    flight_length: u32,

    fn setup(rig: *Rig, kind: CertKind, faults: testpeer.Faults) !void {
        return rig.setup_auth(kind, faults, .{});
    }

    fn setup_auth(rig: *Rig, kind: CertKind, faults: testpeer.Faults, auth: Auth) !void {
        rig.diag.reset();
        rig.server_key = try Ed25519.KeyPair.generateDeterministic(@splat(5));
        const ca = try x509_test.ca_pair();
        var signer = ca;
        var window = x509_test.window;
        var name: []const u8 = server_name;
        switch (kind) {
            .other_ca => signer = try Ed25519.KeyPair.generateDeterministic(@splat(0xCB)),
            .expired => window = .{
                .not_before_ms = x509_test.now - 3 * x509_test.hour,
                .not_after_ms = x509_test.now - 2 * x509_test.hour,
            },
            .wrong_name => name = "other.botpike.com",
            else => {},
        }
        const request: x509.ServerRequest = .{
            .dns_name = name,
            .subject_key = rig.server_key.public_key.toBytes(),
            .lifetime = window,
        };
        if (kind == .workload) {
            const workload = x509_test.workload_request(rig.server_key.public_key.toBytes());
            try x509.issue_workload(&rig.leaf, ca, &workload);
        } else {
            try x509.issue_server(&rig.leaf, signer, &request);
        }
        try x509.issue_ca(&rig.second, ca, x509_test.window);
        var count: u32 = 1;
        rig.certificates[0] = rig.leaf.slice();
        if (kind == .three) {
            rig.certificates[1] = rig.second.slice();
            rig.certificates[2] = rig.second.slice();
            count = 3;
        }
        if (kind == .none) count = 0;
        if (kind == .tampered) {
            // The last byte is the end of the signature: the certificate no longer verifies.
            rig.leaf.bytes[rig.leaf.bytes.len - 1] ^= 1;
        }
        try rig.issue_client(ca, auth);
        rig.start_peer_and_client(ca, faults, auth, count);
    }

    fn start_peer_and_client(
        rig: *Rig,
        ca: Ed25519.KeyPair,
        faults: testpeer.Faults,
        auth: Auth,
        count: u32,
    ) void {
        var identity: ?tls_client.Identity = null;
        if (auth.identity) {
            identity = .{
                .certificates = rig.client_chain[0..if (auth.with_ca) 2 else 1],
                .signer = if (auth.broken_signer)
                    .{ .context = &rig.client_key, .sign = broken_sign }
                else
                    tls_client.key_pair_signer(&rig.client_key),
            };
        }
        rig.peer = testpeer.Peer.init(.{
            .certificates = rig.certificates[0..count],
            .key = rig.server_key,
            .random = @splat(0x77),
            .secret = @splat(0x55),
            .faults = faults,
            .client_auth = if (!auth.ask) null else .{
                .anchor = ca.public_key.toBytes(),
                .now_ms = x509_test.now,
                .context = auth.context,
                .schemes = auth.schemes,
                .cert_schemes = auth.cert_schemes,
                .authorities = auth.authorities,
                .require = auth.server_requires,
            },
        });
        rig.client.init(&.{
            .anchor = ca.public_key.toBytes(),
            .server_name = server_name,
            .now_ms = x509_test.now,
            .random = @splat(0x11),
            .session_id = @splat(0x22),
            .secret = @splat(0x33),
            .identity = identity,
            .require_client_auth = auth.require,
        });
        rig.sent_length = 0;
        rig.flight_length = 0;
    }

    /// The client's workload certificate, from the CA or another, and its CA certificate.
    fn issue_client(rig: *Rig, ca: Ed25519.KeyPair, auth: Auth) !void {
        rig.client_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
        var signer = ca;
        var request = x509_test.workload_request(rig.client_key.public_key.toBytes());
        switch (auth.certificate) {
            .good => {},
            .other_ca => signer = try Ed25519.KeyPair.generateDeterministic(@splat(0xCC)),
            .expired => request.lifetime = .{
                .not_before_ms = x509_test.now - 3 * x509_test.hour,
                .not_after_ms = x509_test.now - 2 * x509_test.hour,
            },
        }
        try x509.issue_workload(&rig.client_certificate, signer, &request);
        try x509.issue_ca(&rig.ca_certificate, ca, x509_test.window);
        rig.client_chain = .{ rig.client_certificate.slice(), rig.ca_certificate.slice() };
    }

    /// Takes what the client has ready, so the next step may run.
    fn collect(rig: *Rig) void {
        const output = rig.client.output();
        @memcpy(rig.sent[rig.sent_length..][0..output.len], output);
        rig.sent_length += @intCast(output.len);
        rig.client.drain();
    }

    /// Feeds `bytes` in pieces of at most `chunk` bytes. Returns the last event that was not
    /// `none`; stops at the first error.
    fn feed(rig: *Rig, bytes: []const u8, chunk: usize) tls_client.Error!Event {
        var event: Event = .none;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + chunk);
            const step = rig.client.receive(bytes[offset..end], &rig.diag) catch |err| {
                rig.collect();
                return err;
            };
            rig.collect();
            offset += step.consumed;
            if (step.event != .none) event = step.event;
        }
        return event;
    }

    /// The ClientHello and the server's answer to it.
    fn hello(rig: *Rig) void {
        rig.client.start();
        rig.collect();
        const record = rig.sent[0..rig.sent_length];
        const answer = rig.peer.respond(record, &rig.flight);
        rig.flight_length = @intCast(answer.len);
        rig.sent_length = 0;
    }

    fn handshake(rig: *Rig, chunk: usize) tls_client.Error!Event {
        rig.hello();
        return rig.feed(rig.flight[0..rig.flight_length], chunk);
    }

    fn expect_code(rig: *const Rig, code: @import("diag/codes.zig").Code) !void {
        try std.testing.expectEqual(code, rig.diag.code.?);
    }
};

fn expect_connected(rig: *Rig, chunk: usize) !void {
    const event = try rig.handshake(chunk);
    try std.testing.expect(event == .connected);
    try std.testing.expect(rig.client.is_connected());
    try std.testing.expect(rig.peer.accept_client_finished(rig.sent[0..rig.sent_length]));
    rig.sent_length = 0;
}

fn expect_refused(rig: *Rig, kind: CertKind, faults: testpeer.Faults, code: anytype) !void {
    try rig.setup(kind, faults);
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(code);
    try std.testing.expect(!rig.client.is_connected());
    // Every secret is gone, and nothing more is read.
    try std.testing.expect(rig.client.read.dead);
    try std.testing.expect(rig.client.write.dead);
    try std.testing.expectError(error.Closed, rig.client.receive("x", &rig.diag));
}

test "the handshake connects, whatever the size of the pieces" {
    // Goal: a correct server's flight is accepted, and the client's last flight verifies at the
    // server. Method: feed the flight in pieces of 1, 5, 7, 100 and 4096 bytes, one record per
    // message and then all messages in one record.
    var rig: Rig = undefined;
    for ([_]usize{ 1, 5, 7, 100, 4096 }) |chunk| {
        for ([_]bool{ true, false }) |per_message| {
            try rig.setup(.good, .{ .record_per_message = per_message });
            try expect_connected(&rig, chunk);
        }
    }
}

test "the handshake connects with no compatibility change_cipher_spec" {
    // Goal: the change_cipher_spec is optional. Method: a server that sends none.
    var rig: Rig = undefined;
    try rig.setup(.good, .{ .no_ccs = true });
    try expect_connected(&rig, 4096);
}

test "application data goes both ways under fresh keys" {
    // Goal: after the handshake both directions carry data under the application keys. Method:
    // the server sends a record, the client sends one, the server opens it.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    try expect_connected(&rig, 4096);
    var buffer: [256]u8 = undefined;
    const record = rig.peer.application(&buffer, "hello client");
    const event = try rig.feed(record, 4096);
    try std.testing.expectEqualStrings("hello client", event.data);
    var out: [256]u8 = undefined;
    const sealed = try rig.client.seal_application("hello server", &out);
    const opened = try rig.peer.open(sealed);
    try std.testing.expectEqual(schedule.ContentType.application_data, opened.content_type);
    try std.testing.expectEqualStrings("hello server", opened.content);
}

test "a KeyUpdate moves the receive keys, and one that asks is answered" {
    // Goal: RFC 8446 section 4.6.3. Method: the server updates without a request, then with one;
    // data keeps flowing, and the client's answer opens under the server's old read keys.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    try expect_connected(&rig, 4096);
    var buffer: [256]u8 = undefined;
    _ = try rig.feed(rig.peer.key_update(&buffer, false), 4096);
    try std.testing.expectEqual(@as(usize, 0), rig.sent_length);
    var data: [256]u8 = undefined;
    const event = try rig.feed(rig.peer.application(&data, "after one"), 4096);
    try std.testing.expectEqualStrings("after one", event.data);

    _ = try rig.feed(rig.peer.key_update(&buffer, true), 4096);
    const answer = rig.sent[0..rig.sent_length];
    const opened = try rig.peer.open(answer);
    try std.testing.expectEqual(schedule.ContentType.handshake, opened.content_type);
    try std.testing.expectEqualSlices(u8, &.{ 24, 0, 0, 1, 0 }, opened.content);
    try rig.peer.read.rekey();
    var out: [256]u8 = undefined;
    const sealed = try rig.client.seal_application("new keys", &out);
    try std.testing.expectEqualStrings("new keys", (try rig.peer.open(sealed)).content);
}

test "a NewSessionTicket is read past and close_notify ends the connection" {
    // Goal: no resumption is offered, so a ticket is dropped; the peer's close_notify is
    // answered and later end of input is not an error. Method: both in turn.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    try expect_connected(&rig, 4096);
    var buffer: [256]u8 = undefined;
    _ = try rig.feed(rig.peer.session_ticket(&buffer), 4096);
    try std.testing.expect(rig.client.is_connected());
    const event = try rig.feed(rig.peer.close_notify(&buffer), 4096);
    try std.testing.expect(event == .closed);
    try std.testing.expect(rig.sent_length > 0);
    try rig.client.end_of_input(&rig.diag);
}

test "a server that breaks the handshake is refused with the code that names it" {
    // Goal: each way a server can break the handshake ends in a refusal, a coded diagnostic and
    // a client that is dead. Method: one fault at a time.
    var rig: Rig = undefined;
    const table = [_]struct { faults: testpeer.Faults, code: @import("diag/codes.zig").Code }{
        .{ .faults = .{ .bad_certificate_verify = true }, .code = .E0813 },
        .{ .faults = .{ .bad_finished = true }, .code = .E0813 },
        .{ .faults = .{ .wrong_session_id = true }, .code = .E0813 },
        .{ .faults = .{ .extra_extension = true }, .code = .E0813 },
        .{ .faults = .{ .certificate_request = true }, .code = .E0813 },
        .{ .faults = .{ .skip_encrypted_extensions_in_transcript = true }, .code = .E0813 },
        .{ .faults = .{ .wrong_scheme = true }, .code = .E0818 },
        .{ .faults = .{ .hello_retry = true }, .code = .E0818 },
        .{ .faults = .{ .downgrade = true }, .code = .E0818 },
        .{ .faults = .{ .tls12 = true }, .code = .E0818 },
        .{ .faults = .{ .wrong_suite = true }, .code = .E0818 },
        .{ .faults = .{ .wrong_group = true }, .code = .E0818 },
    };
    for (table) |row| try expect_refused(&rig, .good, row.faults, row.code);
}

test "a certificate the pinned CA did not vouch for is refused" {
    // Goal: pinning. Method: certificates from another CA, expired, for another name, of the
    // wrong kind, with a damaged signature, and chains of the wrong length.
    var rig: Rig = undefined;
    try expect_refused(&rig, .other_ca, .{}, .E0810);
    try expect_refused(&rig, .tampered, .{}, .E0810);
    try expect_refused(&rig, .none, .{}, .E0810);
    try expect_refused(&rig, .three, .{}, .E0810);
    try expect_refused(&rig, .expired, .{}, .E0811);
    try expect_refused(&rig, .wrong_name, .{}, .E0812);
    try expect_refused(&rig, .workload, .{}, .E0819);
}

test "a refusal queues an alert that the server can read, and nothing after it" {
    // Goal: a fatal error sends one alert and then the client is silent. Method: a bad
    // Finished is answered by decrypt_error under the handshake keys.
    var rig: Rig = undefined;
    try rig.setup(.good, .{ .bad_finished = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try std.testing.expect(rig.sent_length > 0);
    try std.testing.expectEqual(@as(u8, 23), rig.sent[0]); // protected: application_data outside
    const opened = try rig.peer.open(rig.sent[0..rig.sent_length]);
    try std.testing.expectEqual(schedule.ContentType.alert, opened.content_type);
    try std.testing.expectEqualSlices(u8, &.{ 2, 51 }, opened.content); // fatal decrypt_error
    try std.testing.expectEqual(@as(usize, 0), rig.client.output().len);
}

test "a plaintext alert from the server is named in the diagnostic" {
    // Goal: the server's alert is shown by name, and the client sends none back. Method: a
    // handshake_failure before any keys, then an unknown code.
    var rig: Rig = undefined;
    var buffer: [16]u8 = undefined;
    try rig.setup(.good, .{});
    rig.client.start();
    rig.collect();
    rig.sent_length = 0;
    try std.testing.expectError(error.Refused, rig.feed(testpeer.plain_alert(&buffer, 40), 4096));
    try rig.expect_code(.E0813);
    try std.testing.expect(
        std.mem.indexOf(u8, rig.diag.last_cause().?, "handshake_failure") != null,
    );
    try std.testing.expectEqual(@as(usize, 0), rig.sent_length);

    try rig.setup(.good, .{});
    rig.client.start();
    rig.collect();
    rig.sent_length = 0;
    try std.testing.expectError(error.Refused, rig.feed(testpeer.plain_alert(&buffer, 200), 4096));
    try std.testing.expect(std.mem.indexOf(u8, rig.diag.last_cause().?, "unknown_alert") != null);
}

test "a protected alert is read and named" {
    // Goal: an alert under the handshake keys is opened and named. Method: the server sends
    // bad_certificate after its ServerHello.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.hello();
    const hello_end = 5 + std.mem.readInt(u16, rig.flight[3..5], .big);
    _ = try rig.feed(rig.flight[0..hello_end], 4096);
    var buffer: [64]u8 = undefined;
    const record = rig.peer.handshake_alert(&buffer, 42);
    try std.testing.expectError(error.Refused, rig.feed(record, 4096));
    try rig.expect_code(.E0813);
    try std.testing.expect(std.mem.indexOf(u8, rig.diag.last_cause().?, "bad_certificate") != null);
}

test "a record that does not authenticate ends the connection and wipes it" {
    // Goal: the slice 3 handoff: a failed open wipes the record buffer and the keys. Method:
    // flip one bit in the first protected record.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.hello();
    const hello_end = 5 + std.mem.readInt(u16, rig.flight[3..5], .big);
    const first = hello_end + 6; // behind the change_cipher_spec record
    rig.flight[first + 8] ^= 1;
    try std.testing.expectError(error.Refused, rig.feed(rig.flight[0..rig.flight_length], 4096));
    try rig.expect_code(.E0815);
    const zero: [64]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zero, rig.client.record[0..64]);
    try std.testing.expect(rig.client.read.dead);
}

test "a record longer than the protocol allows is refused at its header" {
    // Goal: no byte of an overlong body is read. Method: a plaintext header with a length of
    // 16,385.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.client.start();
    rig.collect();
    rig.sent_length = 0;
    const header = [_]u8{ 22, 3, 3, 0x40, 0x01 };
    try std.testing.expectError(error.Refused, rig.feed(&header, 4096));
    try rig.expect_code(.E0815);
}

test "a change_cipher_spec is dropped once, only where it belongs" {
    // Goal: RFC 8446 appendix D.4 and the slice 3 handoff. Method: a second one, one before the
    // ServerHello and one with the wrong body are each refused.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.hello();
    const hello_end = 5 + std.mem.readInt(u16, rig.flight[3..5], .big);
    _ = try rig.feed(rig.flight[0 .. hello_end + 6], 4096);
    const ccs = [_]u8{ 20, 3, 3, 0, 1, 1 };
    try std.testing.expectError(error.Refused, rig.feed(&ccs, 4096));
    try rig.expect_code(.E0815);

    try rig.setup(.good, .{});
    rig.client.start();
    rig.collect();
    rig.sent_length = 0;
    try std.testing.expectError(error.Refused, rig.feed(&ccs, 4096));

    try rig.setup(.good, .{});
    rig.hello();
    _ = try rig.feed(rig.flight[0..hello_end], 4096);
    const wrong = [_]u8{ 20, 3, 3, 0, 1, 2 };
    try std.testing.expectError(error.Refused, rig.feed(&wrong, 4096));
}

test "the transport ending is an error unless the server said close_notify" {
    // Goal: ZC-E0816. Method: end of input mid-handshake and after connecting.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.client.start();
    rig.collect();
    try std.testing.expectError(error.Refused, rig.client.end_of_input(&rig.diag));
    try rig.expect_code(.E0816);

    try rig.setup(.good, .{});
    try expect_connected(&rig, 4096);
    rig.diag.reset();
    try std.testing.expectError(error.Refused, rig.client.end_of_input(&rig.diag));
    try rig.expect_code(.E0816);
}

test "handshake data behind a key change in one record is refused" {
    // Goal: keys must not change in the middle of a record. Method: the ServerHello and the
    // EncryptedExtensions in one plaintext record.
    var rig: Rig = undefined;
    try rig.setup(.good, .{});
    rig.hello();
    const hello_end = 5 + std.mem.readInt(u16, rig.flight[3..5], .big);
    const body = rig.flight[5..hello_end];
    var joined: [300]u8 = undefined;
    @memcpy(joined[0..body.len], body);
    @memcpy(joined[body.len..][0..6], &[_]u8{ 8, 0, 0, 2, 0, 0 });
    const bytes = schedule.write_plain(&rig.flight, .handshake, 0x0303, joined[0 .. body.len + 6]);
    try std.testing.expectError(error.Refused, rig.feed(bytes, 4096));
    try rig.expect_code(.E0813);
}

// ---- ServerHello layouts, the sent alert and the fix line --------------------------------------

/// A ServerHello body: the fixed fields, then `extensions` behind a length (or nothing at all
/// when `block` is false, as a TLS 1.2 server may send).
fn hello_body(
    out: []u8,
    random: *const [32]u8,
    extensions: []const u8,
    block: bool,
) []const u8 {
    var length: usize = 0;
    std.mem.writeInt(u16, out[0..2], 0x0303, .big);
    @memcpy(out[2..34], random);
    out[34] = 32;
    @memset(out[35..67], 0x22);
    std.mem.writeInt(u16, out[67..69], wire.suite_aes_128_gcm_sha256, .big);
    out[69] = 0;
    length = 70;
    if (block) {
        std.mem.writeInt(u16, out[70..72], @intCast(extensions.len), .big);
        @memcpy(out[72..][0..extensions.len], extensions);
        length = 72 + extensions.len;
    }
    return out[0..length];
}

const hrr_random = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

test "a HelloRetryRequest in the RFC 8446 layout is named, not called malformed" {
    // Goal: MUST-1 of the slice 4 review. A real HRR's key_share holds only the group (section
    // 4.2.8), which the extension parser rejects; the random must decide first. Method: the
    // layout of section 4.1.4 (supported_versions, key_share with the group alone, a cookie).
    var buffer: [128]u8 = undefined;
    const extensions = [_]u8{
        0, 43, 0, 2, 3, 4, // supported_versions
        0, 51, 0, 2, 0, 0x1d, // key_share: selected_group only
        0, 44, 0, 6, 0, 4, 1, 2, 3, 4, // cookie
    };
    const body = hello_body(&buffer, &hrr_random, &extensions, true);
    const session: [32]u8 = @splat(0x22);
    try std.testing.expectError(error.HelloRetryRequest, wire.parse_server_hello(body, &session));
}

test "a TLS 1.2 ServerHello without extensions is a version problem, not a decode error" {
    // Goal: SHOULD-3. A TLS 1.2 server may end its ServerHello after the compression method.
    // Method: no extensions block; then a block holding a damaged extension beside a
    // supported_versions that names TLS 1.2.
    var buffer: [128]u8 = undefined;
    const random: [32]u8 = @splat(0x77);
    const session: [32]u8 = @splat(0x22);
    const bare = hello_body(&buffer, &random, "", false);
    try std.testing.expectError(error.ProtocolVersion, wire.parse_server_hello(bare, &session));
    const old = [_]u8{ 0, 43, 0, 2, 3, 3, 0, 0xFF, 0, 9, 1 }; // The last extension is cut short.
    const body = hello_body(&buffer, &random, &old, true);
    try std.testing.expectError(error.ProtocolVersion, wire.parse_server_hello(body, &session));
}

test "an unknown extension is not mistaken for a repeat of a known one" {
    // Goal: the NIT in the review. Kind 0x2B00 shares a slot with supported_versions (43) in a
    // folded table. Method: both in one ServerHello; the refusal is the unknown extension.
    var buffer: [128]u8 = undefined;
    const random: [32]u8 = @splat(0x77);
    const session: [32]u8 = @splat(0x22);
    const extensions = [_]u8{ 0x2B, 0, 0, 0, 0, 43, 0, 2, 3, 4 };
    const body = hello_body(&buffer, &random, &extensions, true);
    try std.testing.expectError(
        error.UnexpectedExtension,
        wire.parse_server_hello(body, &session),
    );
}

test "a certificate entry with extensions is an extension nobody asked for" {
    // Goal: RFC 8446 section 4.2: an extension in a response that the request lacked is
    // unsupported_extension. Method: one entry with an empty-looking extension.
    const body = [_]u8{ 0, 0, 0, 12, 0, 0, 3, 1, 2, 3, 0, 4, 0, 0xFF, 0, 0 };
    try std.testing.expectError(error.UnexpectedExtension, wire.parse_certificate(&body));
}

test "a plaintext alert between two halves of a ServerHello is refused" {
    // Goal: an alert may not interleave with a handshake message. Method: the first bytes of a
    // ServerHello in one record, then a plaintext alert.
    var rig: Rig = undefined;
    var buffer: [16]u8 = undefined;
    try rig.setup(.good, .{});
    rig.hello();
    const half = schedule.write_plain(&rig.flight, .handshake, 0x0303, &.{ 2, 0, 0, 80, 3, 3 });
    _ = try rig.feed(half, 4096);
    try std.testing.expectError(error.Refused, rig.feed(testpeer.plain_alert(&buffer, 40), 4096));
    try rig.expect_code(.E0815);
}

fn expect_context(diag: *const Diag, key: []const u8, value: []const u8) !void {
    for (diag.pairs.slice()) |pair| {
        if (!std.mem.eql(u8, pair.key_slice(), key)) continue;
        try std.testing.expectEqualStrings(value, pair.value.slice());
        return;
    }
    return error.TestExpectedEqual;
}

test "the diagnostic names the alert the client sent, and the fix names the server" {
    // Goal: SHOULD-1 and SHOULD-2. Method: a bad Finished (decrypt_error), a ServerHello the
    // client cannot use (handshake_failure), a certificate from another CA (unknown_ca).
    var rig: Rig = undefined;
    try rig.setup(.good, .{ .bad_finished = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try expect_context(&rig.diag, "sent", "alert decrypt_error (51)");
    const fix = rig.diag.fixes.slice()[0].sentence.slice();
    try std.testing.expect(std.mem.indexOf(u8, fix, "server at broker.botpike.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, fix, "pinned CA") != null);
    try std.testing.expect(std.mem.indexOf(u8, fix, "zcube server") == null);

    try rig.setup(.good, .{ .wrong_suite = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0818);
    try expect_context(&rig.diag, "sent", "alert handshake_failure (40)");
    const fix_818 = rig.diag.fixes.slice()[0].sentence.slice();
    try std.testing.expect(std.mem.indexOf(u8, fix_818, "zcube server") == null);

    try rig.setup(.other_ca, .{});
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try expect_context(&rig.diag, "sent", "alert unknown_ca (48)");
}

// ---- Client authentication ----------------------------------------------------------------------

/// Runs the handshake and returns what the peer made of the client's last flight.
fn connect_auth(rig: *Rig, chunk: usize) !testpeer.ClientFlight {
    const event = try rig.handshake(chunk);
    try std.testing.expect(event == .connected);
    try std.testing.expect(rig.client.is_connected());
    const result = rig.peer.accept_client_flight(rig.sent[0..rig.sent_length]);
    rig.sent_length = 0;
    return result;
}

const asked: Auth = .{ .ask = true, .identity = true };

test "a client with a certificate answers a request, whatever the size of the pieces" {
    // Goal: the client's Certificate, CertificateVerify and Finished verify at the server.
    // Method: one chain and then two, empty and long contexts, authorities, in all chunk sizes.
    var rig: Rig = undefined;
    const long: [255]u8 = @splat(0xAB);
    for ([_]usize{ 1, 5, 100, 4096 }) |chunk| {
        for ([_]bool{ true, false }) |per_message| {
            const variants = [_]Auth{
                asked,
                .{ .ask = true, .identity = true, .with_ca = true },
                .{ .ask = true, .identity = true, .context = "ctx" },
                .{ .ask = true, .identity = true, .context = &long, .authorities = true },
                .{ .ask = true, .identity = true, .require = true },
                .{ .ask = true, .identity = true, .server_requires = false },
                .{ .ask = true, .identity = true, .cert_schemes = &.{wire.scheme_ed25519} },
            };
            for (variants) |auth| {
                try rig.setup_auth(.good, .{ .record_per_message = per_message }, auth);
                const flight = try connect_auth(&rig, chunk);
                try std.testing.expectEqual(testpeer.ClientFlight.ok, flight);
                try std.testing.expect(rig.peer.client_key != null);
            }
        }
    }
}

test "application data and key updates work after client authentication" {
    // Goal: the keys after a client-auth handshake are the right ones. Method: data both ways,
    // then a KeyUpdate each way, then close_notify from the client.
    var rig: Rig = undefined;
    try rig.setup_auth(.good, .{}, asked);
    try std.testing.expectEqual(testpeer.ClientFlight.ok, try connect_auth(&rig, 4096));
    var buffer: [256]u8 = undefined;
    const event = try rig.feed(rig.peer.application(&buffer, "hello"), 4096);
    try std.testing.expect(event == .data);
    _ = try rig.feed(rig.peer.key_update(&buffer, true), 4096);
    // The answer to the request is a KeyUpdate the peer reads under the old keys.
    try std.testing.expect(rig.sent_length > 0);
    _ = try rig.peer.open(rig.sent[0..rig.sent_length]);
    rig.peer.read.rekey() catch unreachable; // Keys never run out here.
    rig.sent_length = 0;
    _ = try rig.feed(rig.peer.application(&buffer, "again"), 4096);
    try rig.client.send_key_update(false);
    rig.collect();
    const opened = try rig.peer.open(rig.sent[0..rig.sent_length]);
    try std.testing.expect(opened.content_type == .handshake);
    rig.sent_length = 0;
    rig.peer.read.rekey() catch unreachable; // Keys never run out here.
    rig.client.close_notify();
    rig.collect();
    const closing = try rig.peer.open(rig.sent[0..rig.sent_length]);
    try std.testing.expect(closing.content_type == .alert);
}

test "a client without a usable certificate says so when the server asks" {
    // Goal: no identity, or a request that cannot be answered, is an empty Certificate when
    // authentication is optional; the server may accept or refuse it.
    var rig: Rig = undefined;
    try rig.setup_auth(.good, .{}, .{ .ask = true, .server_requires = false });
    var flight = try connect_auth(&rig, 4096);
    try std.testing.expectEqual(testpeer.ClientFlight.ok_without_certificate, flight);
    try rig.setup_auth(.good, .{}, .{ .ask = true });
    flight = try connect_auth(&rig, 4096);
    try std.testing.expectEqual(testpeer.ClientFlight.no_certificate, flight);
    try rig.setup_auth(.good, .{}, .{
        .ask = true,
        .identity = true,
        .server_requires = false,
        .schemes = &.{0x0804},
    });
    flight = try connect_auth(&rig, 4096);
    try std.testing.expectEqual(testpeer.ClientFlight.ok_without_certificate, flight);
    try rig.setup_auth(.good, .{}, .{
        .ask = true,
        .identity = true,
        .server_requires = false,
        .cert_schemes = &.{0x0804},
    });
    flight = try connect_auth(&rig, 4096);
    try std.testing.expectEqual(testpeer.ClientFlight.ok_without_certificate, flight);
}

test "required client authentication refuses a server that does not ask or cannot be answered" {
    // Goal: a client that must authenticate never connects without doing so. Method: no
    // request, and requests it cannot answer.
    var rig: Rig = undefined;
    try rig.setup_auth(.good, .{}, .{ .identity = true, .require = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0814);
    try expect_context(&rig.diag, "sent", "alert handshake_failure (40)");
    try rig.setup_auth(.good, .{}, .{
        .ask = true,
        .identity = true,
        .require = true,
        .schemes = &.{0x0804},
    });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0814);
    // A client that need not authenticate connects when the server does not ask.
    try rig.setup_auth(.good, .{}, .{ .identity = true });
    try expect_connected(&rig, 4096);
}

test "a malformed or repeated certificate request is refused" {
    var rig: Rig = undefined;
    try expect_refused(&rig, .good, .{ .certificate_request = true }, .E0813);
    try rig.setup_auth(.good, .{ .second_request = true }, asked);
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0813);
}

test "the server's refusal of the certificate is named after the handshake" {
    // Goal: a server refuses the certificate after the client's flight; the client reports
    // E0814 and not a broken handshake.
    var rig: Rig = undefined;
    var buffer: [64]u8 = undefined;
    for ([_]u8{ 42, 43, 44, 45, 46, 48, 49, 116 }) |code| {
        try rig.setup_auth(.good, .{}, asked);
        try std.testing.expectEqual(testpeer.ClientFlight.ok, try connect_auth(&rig, 4096));
        try std.testing.expectError(error.Refused, rig.feed(rig.peer.alert(&buffer, code), 4096));
        try rig.expect_code(.E0814);
    }
    // Another alert is the server breaking the protocol, not a refusal of the certificate.
    try rig.setup_auth(.good, .{}, asked);
    try std.testing.expectEqual(testpeer.ClientFlight.ok, try connect_auth(&rig, 4096));
    try std.testing.expectError(error.Refused, rig.feed(rig.peer.alert(&buffer, 50), 4096));
    try rig.expect_code(.E0813);
    // With no certificate sent, bad_certificate is not about the client's.
    try rig.setup_auth(.good, .{}, .{ .ask = true, .server_requires = false });
    _ = try connect_auth(&rig, 4096);
    try std.testing.expectError(error.Refused, rig.feed(rig.peer.alert(&buffer, 42), 4096));
    try rig.expect_code(.E0813);
}

test "the peer refuses a certificate from another CA or an expired one" {
    var rig: Rig = undefined;
    for ([_]@TypeOf(asked.certificate){ .other_ca, .expired }) |kind| {
        try rig.setup_auth(.good, .{}, .{ .ask = true, .identity = true, .certificate = kind });
        const flight = try connect_auth(&rig, 4096);
        try std.testing.expectEqual(testpeer.ClientFlight.bad_certificate, flight);
    }
}

test "a signer that fails is refused with E0814" {
    var rig: Rig = undefined;
    try rig.setup_auth(.good, .{}, .{ .ask = true, .identity = true, .broken_signer = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0814);
    try expect_context(&rig.diag, "sent", "alert internal_error (80)");
}

fn expect_flight(auth: Auth, want: testpeer.ClientFlight) !void {
    var rig: Rig = undefined;
    try rig.setup_auth(.good, .{}, auth);
    try std.testing.expectEqual(want, try connect_auth(&rig, 4096));
}

test "teeth: each client-auth rule, broken, is seen at the server" {
    // Goal: evidence that the client's signing, echo and transcript rules are load-bearing.
    // Method: the client with one rule broken is refused by the peer.
    const auth: Auth = .{ .ask = true, .identity = true, .context = "c" };
    const cases = [_]struct { fault: tls_client.TestFault, want: testpeer.ClientFlight }{
        .{ .fault = .verify_context, .want = .bad_verify },
        .{ .fault = .echo_context, .want = .bad_context },
        .{ .fault = .transcript_client_auth, .want = .bad_verify },
        .{ .fault = .finished_omits_auth, .want = .bad_finished },
    };
    for (cases) |case| {
        try expect_flight(auth, .ok);
        tls_client.set_test_fault(case.fault, true);
        defer tls_client.set_test_fault(case.fault, false);
        try expect_flight(auth, case.want);
    }
}

test "teeth: without the required-auth check a client connects unauthenticated" {
    var rig: Rig = undefined;
    tls_client.set_test_fault(.required_client_auth, true);
    defer tls_client.set_test_fault(.required_client_auth, false);
    try rig.setup_auth(.good, .{}, .{ .identity = true, .require = true });
    try expect_connected(&rig, 4096);
}

test "teeth: without the scheme check a request without Ed25519 is answered" {
    var rig: Rig = undefined;
    tls_client.set_test_fault(.request_scheme, true);
    defer tls_client.set_test_fault(.request_scheme, false);
    try rig.setup_auth(.good, .{}, .{
        .ask = true,
        .identity = true,
        .server_requires = false,
        .schemes = &.{0x0804},
    });
    const flight = try connect_auth(&rig, 4096);
    try std.testing.expect(flight != .ok_without_certificate);
}

test "teeth: without the refusal check an alert about the certificate is a protocol error" {
    var rig: Rig = undefined;
    tls_client.set_test_fault(.certificate_alert, true);
    defer tls_client.set_test_fault(.certificate_alert, false);
    try rig.setup_auth(.good, .{}, asked);
    _ = try connect_auth(&rig, 4096);
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.Refused, rig.feed(rig.peer.alert(&buffer, 42), 4096));
    try rig.expect_code(.E0813);
}

// ---- Teeth: each security check, reverted, lets a refused handshake through ---------------------

test "teeth: without the CertificateVerify check a forged signature connects" {
    // Goal: evidence that the check is load-bearing. Method: the refused scenario, with the
    // client's check skipped, connects.
    var rig: Rig = undefined;
    tls_client.set_test_fault(.certificate_verify, true);
    defer tls_client.set_test_fault(.certificate_verify, false);
    try rig.setup(.good, .{ .bad_certificate_verify = true });
    try expect_connected(&rig, 4096);
}

test "teeth: without the Finished check a bad Finished connects" {
    var rig: Rig = undefined;
    tls_client.set_test_fault(.finished, true);
    defer tls_client.set_test_fault(.finished, false);
    try rig.setup(.good, .{ .bad_finished = true });
    const event = try rig.handshake(4096);
    try std.testing.expect(event == .connected);
}

test "teeth: a transcript missing a message is refused, and agreed missing it connects" {
    // Goal: the transcript hash binds every message. Method: a client that leaves out
    // EncryptedExtensions meets a server that includes it (refused), and one that leaves it out
    // too (connects).
    var rig: Rig = undefined;
    tls_client.set_test_fault(.transcript_encrypted_extensions, true);
    defer tls_client.set_test_fault(.transcript_encrypted_extensions, false);
    try rig.setup(.good, .{});
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0813);
    try rig.setup(.good, .{ .skip_encrypted_extensions_in_transcript = true });
    try expect_connected(&rig, 4096);
}

test "teeth: without the pin check a damaged certificate connects" {
    // Goal: the signature check in x509 is what pins the server to the CA. Method: the
    // damaged-signature scenario, with x509's signature check skipped, connects.
    var rig: Rig = undefined;
    x509.set_test_fault(.signature, true);
    defer x509.set_test_fault(.signature, false);
    try rig.setup(.tampered, .{});
    try expect_connected(&rig, 4096);
}

test "teeth: without the name check a certificate for another name connects" {
    // Goal: evidence that the name check is what ties the server to the name dialled. Method:
    // the refused wrong-name scenario, with x509's name check skipped, connects.
    var rig: Rig = undefined;
    x509.set_test_fault(.name, true);
    defer x509.set_test_fault(.name, false);
    try rig.setup(.wrong_name, .{});
    try expect_connected(&rig, 4096);
}

test "teeth: without the window check an expired certificate connects" {
    // Goal: as above, for the validity window. Method: the refused expired scenario, with
    // x509's window check skipped, connects.
    var rig: Rig = undefined;
    x509.set_test_fault(.window, true);
    defer x509.set_test_fault(.window, false);
    try rig.setup(.expired, .{});
    try expect_connected(&rig, 4096);
}
