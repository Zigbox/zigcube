//! A scripted TLS 1.3 server for tests (docs/briefs/mtls-client.md, slice 4). It builds the
//! server's flight from the same key schedule the client uses, so a test can make it right or
//! break one thing at a time. It is a test fixture: only test roots import it, and a real server
//! never does.
//!
//! The peer is written independently of `tls_client.zig` in one respect that matters: it takes
//! every transcript hash from its own `Transcript`, so a client that drops a message from its own
//! hash disagrees with it and is refused.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const schedule = @import("tls_schedule.zig");
const wire = @import("tls_wire.zig");

const x509 = @import("x509.zig");

const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;

/// What to get wrong. The default is a correct OpenSSL-like server in compatibility mode.
pub const Faults = struct {
    /// The CertificateVerify signature is flipped.
    bad_certificate_verify: bool = false,
    /// The CertificateVerify names a scheme other than ed25519.
    wrong_scheme: bool = false,
    /// The Finished verify_data is flipped.
    bad_finished: bool = false,
    /// The peer leaves EncryptedExtensions out of its own transcript.
    skip_encrypted_extensions_in_transcript: bool = false,
    /// The peer sends a HelloRetryRequest instead of a ServerHello.
    hello_retry: bool = false,
    /// The ServerHello carries the TLS 1.2 downgrade marker.
    downgrade: bool = false,
    /// The ServerHello has no supported_versions extension: a TLS 1.2 server.
    tls12: bool = false,
    wrong_suite: bool = false,
    wrong_group: bool = false,
    wrong_session_id: bool = false,
    /// An extension the client never offered, in the ServerHello.
    extra_extension: bool = false,
    /// No compatibility change_cipher_spec.
    no_ccs: bool = false,
    /// A CertificateRequest with no extensions at all (no signature_algorithms) after
    /// EncryptedExtensions: malformed. A real request is `Config.client_auth`.
    certificate_request: bool = false,
    /// A second CertificateRequest right after the first: not allowed.
    second_request: bool = false,
    /// One record for each handshake message; otherwise all of them share one.
    record_per_message: bool = true,
    /// Damages the CertificateRequest of `Config.client_auth` after it is built (not zero): the
    /// value picks how and where (see `damage_request`). The record around it stays valid, so
    /// what fails is the request's own parse.
    request_damage: u32 = 0,
    /// Damages one of EncryptedExtensions, Certificate, CertificateVerify and Finished (not
    /// zero): the value picks which, how and where (see `damage_message`). The message is
    /// damaged before it is sealed and enters the transcript as damaged, so the record, the
    /// MAC and the transcript are all valid and what fails is the message's own content.
    message_damage: u32 = 0,
};

/// Asks the client for a certificate and checks what it sends.
pub const ClientAuth = struct {
    /// The CA key the client's certificate must be signed by.
    anchor: [32]u8,
    now_ms: u64,
    /// The `certificate_request_context` the client must echo.
    context: []const u8 = &.{},
    /// The schemes the request lists.
    schemes: []const u16 = &.{wire.scheme_ed25519},
    /// An empty client Certificate is refused (certificate_required).
    require: bool = true,
    /// A `certificate_authorities` extension holding one name, which a client skips.
    authorities: bool = false,
    /// The `signature_algorithms_cert` extension, when set, lists these.
    cert_schemes: ?[]const u16 = null,
};

/// What the peer made of the client's last flight.
pub const ClientFlight = enum {
    /// Everything verified (and, if a certificate was required, it came).
    ok,
    /// The client sent an empty Certificate and none was required.
    ok_without_certificate,
    no_certificate,
    bad_context,
    bad_certificate,
    bad_verify,
    bad_finished,
    malformed,
};

pub const Config = struct {
    /// The certificates to send: the leaf first.
    certificates: []const []const u8,
    /// The key the leaf's CertificateVerify is signed with.
    key: Ed25519.KeyPair,
    random: [32]u8,
    secret: [32]u8,
    faults: Faults = .{},
    client_auth: ?ClientAuth = null,
};

pub const Peer = struct {
    config: Config,
    transcript: schedule.Transcript,
    secrets: schedule.Schedule,
    read: schedule.Direction,
    write: schedule.Direction,
    /// The server's handshake keys at sequence 0, for an alert sent in place of the flight.
    handshake_write: schedule.Direction,
    client_handshake_secret: schedule.Secret,
    client_application_secret: schedule.Secret,
    /// The transcript hash through the server's Finished: the application keys come from it.
    finished_hash: schedule.Hash,
    /// The public key of the client certificate that verified, when one did.
    client_key: ?[32]u8,

    pub fn init(config: Config) Peer {
        var peer: Peer = undefined;
        peer.config = config;
        peer.transcript = schedule.Transcript.init();
        peer.secrets = schedule.Schedule.init();
        peer.client_key = null;
        return peer;
    }

    /// Answers the ClientHello `record` with the server's whole first flight, ready to send.
    pub fn respond(self: *Peer, record: []const u8, out: []u8) []u8 {
        assert(record.len > constants.tls_record_header_bytes);
        const hello_message = record[constants.tls_record_header_bytes..];
        const hello = read_client_hello(hello_message);
        self.transcript.add(hello_message);
        var length: usize = 0;
        var hello_buffer: [256]u8 = undefined;
        const server_hello = self.server_hello_message(&hello, &hello_buffer);
        if (self.config.faults.hello_retry) {
            const plain = schedule.write_plain(out, .handshake, 0x0303, server_hello);
            return plain;
        }
        self.transcript.add(server_hello);
        length = schedule.write_plain(out, .handshake, 0x0303, server_hello).len;
        if (!self.config.faults.no_ccs) {
            length += schedule.write_plain(out[length..], .change_cipher_spec, 0x0303, &.{1}).len;
        }
        self.derive(&hello);
        length += self.handshake_flight(out[length..]);
        return out[0..length];
    }

    fn derive(self: *Peer, hello: *const ClientHello) void {
        // The test peer's buffers are sized for it.
        const shared = X25519.scalarmult(self.config.secret, hello.public_key) catch unreachable;
        const hash = self.transcript.hash();
        // The test peer's buffers are sized for it.
        const secrets = self.secrets.to_handshake(&shared, &hash) catch unreachable;
        self.write = schedule.Direction.init(&secrets.server);
        self.handshake_write = self.write;
        self.read = schedule.Direction.init(&secrets.client);
        self.client_handshake_secret = secrets.client;
    }

    fn server_hello_message(self: *Peer, hello: *const ClientHello, out: []u8) []const u8 {
        const faults = self.config.faults;
        var length: usize = 4;
        std.mem.writeInt(u16, out[length..][0..2], 0x0303, .big);
        length += 2;
        var random = self.config.random;
        if (faults.downgrade) @memcpy(random[24..], "DOWNGRD\x01");
        if (faults.hello_retry) random = hello_retry_random;
        @memcpy(out[length..][0..32], &random);
        length += 32;
        out[length] = 32;
        var echoed = hello.session_id;
        if (faults.wrong_session_id) echoed[0] ^= 0xFF;
        @memcpy(out[length + 1 ..][0..32], &echoed);
        length += 33;
        const suite: u16 = if (faults.wrong_suite) 0x1302 else wire.suite_aes_128_gcm_sha256;
        std.mem.writeInt(u16, out[length..][0..2], suite, .big);
        out[length + 2] = 0;
        length += 3;
        const extensions_at = length;
        length += 2;
        if (!faults.tls12) length += put_extension(out[length..], 43, &.{ 0x03, 0x04 });
        const group: u16 = if (faults.wrong_group) 0x0017 else wire.group_x25519;
        var share: [4 + 32]u8 = undefined;
        std.mem.writeInt(u16, share[0..2], group, .big);
        std.mem.writeInt(u16, share[2..4], 32, .big);
        const public = X25519.recoverPublicKey(self.config.secret);
        @memcpy(share[4..], &public);
        if (faults.hello_retry) {
            // A real HelloRetryRequest (RFC 8446 section 4.1.4): the key_share names only the
            // group (section 4.2.8), and a cookie asks for an echo.
            length += put_extension(out[length..], 51, share[0..2]);
            length += put_extension(out[length..], 44, &.{ 0, 4, 0xC0, 0x0C, 0x1E, 0xED });
        } else {
            length += put_extension(out[length..], 51, &share);
        }
        if (faults.extra_extension) length += put_extension(out[length..], 0x00FF, &.{0});
        std.mem.writeInt(
            u16,
            out[extensions_at..][0..2],
            @intCast(length - extensions_at - 2),
            .big,
        );
        out[0] = wire.handshake_server_hello;
        std.mem.writeInt(u24, out[1..4], @intCast(length - 4), .big);
        return out[0..length];
    }

    /// Everything from EncryptedExtensions to Finished, sealed under the handshake keys, and the
    /// switch of the write side to application keys.
    fn handshake_flight(self: *Peer, out: []u8) usize {
        const faults = self.config.faults;
        var scratch: [constants.tls_handshake_flight_bytes_max]u8 = undefined;
        var length: u32 = 0;
        var used: usize = 0;
        const encrypted_extensions = [_]u8{ wire.handshake_encrypted_extensions, 0, 0, 2, 0, 0 };
        used += self.message(
            out[used..],
            &scratch,
            &length,
            self.damaged(0, &encrypted_extensions),
            !faults.skip_encrypted_extensions_in_transcript,
        );
        if (faults.certificate_request) {
            const request = [_]u8{ wire.handshake_certificate_request, 0, 0, 3, 0, 0, 0 };
            used += self.message(out[used..], &scratch, &length, &request, true);
        }
        if (self.config.client_auth) |auth| {
            const request = request_message(&auth, faults.request_damage);
            used += self.message(out[used..], &scratch, &length, request, true);
            if (faults.second_request) {
                used += self.message(out[used..], &scratch, &length, request, true);
            }
        }
        used += self.message(
            out[used..],
            &scratch,
            &length,
            self.damaged(1, self.certificate_message(&scratch)),
            true,
        );
        const verify = self.damaged(2, self.verify_message(&scratch));
        used += self.message(out[used..], &scratch, &length, verify, true);
        const finished = self.damaged(3, self.finished_message(&scratch));
        used += self.message(out[used..], &scratch, &length, finished, true);
        if (!faults.record_per_message) used += self.flush(out[used..], scratch[0..length]);
        self.finished_hash = self.transcript.hash();
        const secrets = self.secrets.to_application(&self.finished_hash);
        self.write = schedule.Direction.init(&secrets.server);
        self.client_application_secret = secrets.client;
        return used;
    }

    /// `bytes` as it is, or damaged when `Faults.message_damage` picks message number `which`.
    fn damaged(self: *Peer, which: u32, bytes: []const u8) []const u8 {
        const damage = self.config.faults.message_damage;
        if (damage == 0 or damage % 4 != which) return bytes;
        return damage_message(bytes, damage);
    }

    /// Adds one message to the transcript and either seals it alone or holds it for `flush`.
    fn message(
        self: *Peer,
        out: []u8,
        pending: []u8,
        pending_length: *u32,
        bytes: []const u8,
        in_transcript: bool,
    ) usize {
        if (in_transcript) self.transcript.add(bytes);
        if (self.config.faults.record_per_message) {
            // The test peer's buffers are sized for it.
            const sealed = self.write.seal(out, .handshake, bytes) catch unreachable;
            return sealed.len;
        }
        @memcpy(pending[pending_length.*..][0..bytes.len], bytes);
        pending_length.* += @intCast(bytes.len);
        return 0;
    }

    fn flush(self: *Peer, out: []u8, bytes: []const u8) usize {
        // The test peer's buffers are sized for it.
        const sealed = self.write.seal(out, .handshake, bytes) catch unreachable;
        return sealed.len;
    }

    fn certificate_message(self: *Peer, scratch_unused: []u8) []const u8 {
        _ = scratch_unused;
        const buffer = &certificate_buffer;
        var length: usize = 4;
        buffer[length] = 0; // request context
        length += 1;
        const list_at = length;
        length += 3;
        for (self.config.certificates) |certificate| {
            std.mem.writeInt(u24, buffer[length..][0..3], @intCast(certificate.len), .big);
            @memcpy(buffer[length + 3 ..][0..certificate.len], certificate);
            length += 3 + certificate.len;
            std.mem.writeInt(u16, buffer[length..][0..2], 0, .big);
            length += 2;
        }
        std.mem.writeInt(u24, buffer[list_at..][0..3], @intCast(length - list_at - 3), .big);
        buffer[0] = wire.handshake_certificate;
        std.mem.writeInt(u24, buffer[1..4], @intCast(length - 4), .big);
        return buffer[0..length];
    }

    fn verify_message(self: *Peer, scratch_unused: []u8) []const u8 {
        _ = scratch_unused;
        const hash = self.transcript.hash();
        const content = schedule.certificate_verify_content(.server, &hash);
        // The test peer's buffers are sized for it.
        const signature = self.config.key.sign(&content, null) catch unreachable;
        var bytes = signature.toBytes();
        if (self.config.faults.bad_certificate_verify) bytes[0] ^= 1;
        const buffer = &verify_buffer;
        buffer[0] = wire.handshake_certificate_verify;
        std.mem.writeInt(u24, buffer[1..4], 2 + 2 + 64, .big);
        const scheme: u16 = if (self.config.faults.wrong_scheme) 0x0804 else wire.scheme_ed25519;
        std.mem.writeInt(u16, buffer[4..6], scheme, .big);
        std.mem.writeInt(u16, buffer[6..8], 64, .big);
        @memcpy(buffer[8..72], &bytes);
        return buffer[0..72];
    }

    fn finished_message(self: *Peer, scratch_unused: []u8) []const u8 {
        _ = scratch_unused;
        const hash = self.transcript.hash();
        var data = schedule.finished_verify_data(&self.write.secret, &hash);
        if (self.config.faults.bad_finished) data[0] ^= 1;
        const buffer = &finished_buffer;
        buffer[0] = wire.handshake_finished;
        std.mem.writeInt(u24, buffer[1..4], schedule.hash_bytes, .big);
        @memcpy(buffer[4..], &data);
        return buffer[0 .. 4 + schedule.hash_bytes];
    }

    // ---- After the server's flight ------------------------------------------------------------

    /// Reads the client's last flight with no client authentication asked for: an optional
    /// compatibility change_cipher_spec and its Finished. Returns whether it verified.
    pub fn accept_client_finished(self: *Peer, bytes: []u8) bool {
        assert(self.config.client_auth == null);
        return self.accept_client_flight(bytes) == .ok;
    }

    /// Reads the client's last flight: an optional change_cipher_spec, then, when the peer asked,
    /// Certificate and CertificateVerify, then Finished, each in a record of its own. On success
    /// the peer reads application data from the client. The checks are the ones a stock server
    /// makes: the context is echoed, the chain verifies under the anchor, the signature covers the
    /// transcript through the Certificate, and the Finished covers everything.
    pub fn accept_client_flight(self: *Peer, bytes: []u8) ClientFlight {
        var rest = bytes;
        if (rest.len > 0 and rest[0] == @backingInt(schedule.ContentType.change_cipher_spec)) {
            if (rest.len < 6) return .malformed;
            rest = rest[6..];
        }
        var result: ClientFlight = .ok;
        if (self.config.client_auth) |auth| {
            result = self.accept_certificate(&auth, &rest);
            if (result != .ok and result != .ok_without_certificate) return result;
        }
        const finished = self.next_message(&rest) orelse return .malformed;
        if (rest.len != 0) return .malformed;
        if (finished.len != 4 + schedule.hash_bytes) return .malformed;
        if (finished[0] != wire.handshake_finished) return .malformed;
        const hash = self.transcript.hash();
        if (!schedule.finished_matches(&self.client_handshake_secret, &hash, finished[4..])) {
            return .bad_finished;
        }
        self.read = schedule.Direction.init(&self.client_application_secret);
        return result;
    }

    /// Opens the next record of `rest` and returns its handshake message.
    fn next_message(self: *Peer, rest: *[]u8) ?[]u8 {
        if (rest.len < constants.tls_record_header_bytes) return null;
        const length = std.mem.readInt(u16, rest.*[3..5], .big);
        const total = constants.tls_record_header_bytes + length;
        if (rest.len < total) return null;
        const opened = self.read.open(rest.*[0..total]) catch return null;
        rest.* = rest.*[total..];
        if (opened.content_type != .handshake) return null;
        return opened.content;
    }

    fn accept_certificate(self: *Peer, auth: *const ClientAuth, rest: *[]u8) ClientFlight {
        const body = self.next_message(rest) orelse return .malformed;
        if (body.len < 4 or body[0] != wire.handshake_certificate) return .malformed;
        var reader = wire.Reader.init(body[4..]);
        const context = reader.vector8() catch return .malformed;
        if (!std.mem.eql(u8, context, auth.context)) return .bad_context;
        var list = wire.Reader.init(reader.vector24() catch return .malformed);
        reader.finish() catch return .malformed;
        if (list.remaining() == 0) {
            if (auth.require) return .no_certificate;
            self.transcript.add(body);
            return .ok_without_certificate;
        }
        const leaf = list.vector24() catch return .malformed;
        _ = list.vector16() catch return .malformed;
        var detail: x509.Detail = .{};
        const parsed = x509.verify_detailed(leaf, auth.anchor, auth.now_ms, .{
            .kind = .workload,
            .name = null,
        }, &detail) catch return .bad_certificate;
        self.transcript.add(body);
        const hash = self.transcript.hash();
        const verify = self.next_message(rest) orelse return .malformed;
        if (verify.len != 4 + 2 + 2 + 64) return .malformed;
        if (verify[0] != wire.handshake_certificate_verify) return .malformed;
        if (std.mem.readInt(u16, verify[4..6], .big) != wire.scheme_ed25519) return .malformed;
        const content = schedule.certificate_verify_content(.client, &hash);
        const key = parsed.public_key.of(leaf)[0..32].*;
        const public = Ed25519.PublicKey.fromBytes(key) catch return .bad_certificate;
        const signature = Ed25519.Signature.fromBytes(verify[8..][0..64].*);
        signature.verify(&content, public) catch return .bad_verify;
        self.transcript.add(verify);
        self.client_key = key;
        return .ok;
    }

    /// One protected record of `kind` and `content` under the server's current write keys.
    pub fn seal(
        self: *Peer,
        out: []u8,
        kind: schedule.ContentType,
        content: []const u8,
    ) []u8 {
        // The test peer's buffers are sized for it.
        return self.write.seal(out, kind, content) catch unreachable;
    }

    pub fn application(self: *Peer, out: []u8, content: []const u8) []u8 {
        return self.seal(out, .application_data, content);
    }

    /// A KeyUpdate record, then the write keys move on.
    pub fn key_update(self: *Peer, out: []u8, request: bool) []u8 {
        const bytes = [_]u8{ schedule.key_update_type, 0, 0, 1, @intFromBool(request) };
        const sealed = self.seal(out, .handshake, &bytes);
        self.write.rekey() catch unreachable; // The test peer's buffers are sized for it.
        return sealed;
    }

    /// A NewSessionTicket record of arbitrary content.
    pub fn session_ticket(self: *Peer, out: []u8) []u8 {
        const bytes = [_]u8{ wire.handshake_new_session_ticket, 0, 0, 4, 1, 2, 3, 4 };
        return self.seal(out, .handshake, &bytes);
    }

    pub fn alert(self: *Peer, out: []u8, description: u8) []u8 {
        return self.seal(out, .alert, &.{ wire.alert_level_fatal, description });
    }

    /// A fatal alert under the handshake keys at sequence 0: what a server sends instead of
    /// its flight, once the client has only read the ServerHello.
    pub fn handshake_alert(self: *Peer, out: []u8, description: u8) []u8 {
        const content = [_]u8{ wire.alert_level_fatal, description };
        return self.handshake_write.seal(out, .alert, &content) catch unreachable; // Fits.
    }

    pub fn close_notify(self: *Peer, out: []u8) []u8 {
        return self.seal(out, .alert, &.{ 1, 0 });
    }

    /// Opens a record the client sent after the handshake.
    pub fn open(self: *Peer, record: []u8) schedule.Error!schedule.Opened {
        return self.read.open(record);
    }
};

var request_buffer: [512]u8 = undefined;
var damage_buffer: [constants.tls_handshake_message_bytes_max + 1]u8 = undefined;

/// A handshake message with its content damaged and its length field made to match: the last
/// body byte gone, one byte more, one body byte flipped, or no body. `damage / 4 % 4` picks
/// how. The flip reads its position from `damage / 16` and its mask from `damage / 64` (so the
/// two overlap in bits); the extra byte is `damage / 16`; the other two read nothing more. The
/// result is always different from `bytes`.
fn damage_message(bytes: []const u8, damage: u32) []const u8 {
    assert(bytes.len >= 4 + 1);
    assert(bytes.len <= constants.tls_handshake_message_bytes_max);
    const buffer = &damage_buffer;
    @memcpy(buffer[0..bytes.len], bytes);
    var length = bytes.len;
    switch ((damage / 4) % 4) {
        0 => length -= 1,
        1 => {
            buffer[length] = @truncate(damage / 16);
            length += 1;
        },
        2 => {
            const flip: u8 = 1 + @as(u8, @truncate(damage / 64)) % 255;
            buffer[4 + (damage / 16) % (bytes.len - 4)] ^= flip;
        },
        else => length = 4,
    }
    std.mem.writeInt(u24, buffer[1..4], @intCast(length - 4), .big);
    return buffer[0..length];
}

/// CertificateRequest (RFC 8446 section 4.3.2): the context and the extensions the config names.
fn request_message(auth: *const ClientAuth, damage: u32) []const u8 {
    const buffer = &request_buffer;
    var length: usize = 4;
    buffer[length] = @intCast(auth.context.len);
    @memcpy(buffer[length + 1 ..][0..auth.context.len], auth.context);
    length += 1 + auth.context.len;
    const extensions_at = length;
    length += 2;
    length += put_schemes(buffer[length..], 13, auth.schemes);
    if (auth.cert_schemes) |schemes| length += put_schemes(buffer[length..], 50, schemes);
    if (auth.authorities) {
        // One DistinguishedName of three bytes, in a two-byte-length list.
        const names = [_]u8{ 0, 5, 0, 3, 0x30, 0x01, 0x00 };
        length += put_extension(buffer[length..], 47, &names);
    }
    const extensions_length: u16 = @intCast(length - extensions_at - 2);
    std.mem.writeInt(u16, buffer[extensions_at..][0..2], extensions_length, .big);
    buffer[0] = wire.handshake_certificate_request;
    std.mem.writeInt(u24, buffer[1..4], @intCast(length - 4), .big);
    if (damage != 0) length = damage_request(buffer, length, extensions_at, damage);
    return buffer[0..length];
}

/// Damages a built request, keeping the message header's length true to what follows: a byte
/// flipped, the body cut short, junk appended, or the extension list's length replaced.
fn damage_request(buffer: []u8, length_in: usize, extensions_at: usize, damage: u32) usize {
    var length = length_in;
    const pick = damage / 4;
    switch (damage % 4) {
        0 => buffer[4 + pick % (length - 4)] ^= @as(u8, 1) << @intCast(pick / 64 % 8),
        1 => length -= 1 + pick % (length - 4),
        2 => {
            const extra = 1 + pick % 8;
            @memset(buffer[length..][0..extra], @truncate(pick));
            length += extra;
        },
        else => std.mem.writeInt(u16, buffer[extensions_at..][0..2], @truncate(pick), .big),
    }
    std.mem.writeInt(u24, buffer[1..4], @intCast(length - 4), .big);
    return length;
}

fn put_schemes(out: []u8, kind: u16, schemes: []const u16) usize {
    var data: [64]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], @intCast(schemes.len * 2), .big);
    for (schemes, 0..) |scheme, index| {
        std.mem.writeInt(u16, data[2 + index * 2 ..][0..2], scheme, .big);
    }
    return put_extension(out, kind, data[0 .. 2 + schemes.len * 2]);
}

var certificate_buffer: [constants.tls_handshake_message_bytes_max]u8 = undefined;
var verify_buffer: [72]u8 = undefined;
var finished_buffer: [4 + schedule.hash_bytes]u8 = undefined;

/// A plaintext alert record, as a server sends before it has keys.
pub fn plain_alert(out: []u8, description: u8) []u8 {
    return schedule.write_plain(out, .alert, 0x0303, &.{ wire.alert_level_fatal, description });
}

const hello_retry_random = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

fn put_extension(out: []u8, kind: u16, data: []const u8) usize {
    std.mem.writeInt(u16, out[0..2], kind, .big);
    std.mem.writeInt(u16, out[2..4], @intCast(data.len), .big);
    @memcpy(out[4..][0..data.len], data);
    return 4 + data.len;
}

const ClientHello = struct { session_id: [32]u8, public_key: [32]u8 };

/// Reads the fields of the client's fixed-layout ClientHello message.
fn read_client_hello(message: []const u8) ClientHello {
    var reader = wire.Reader.init(message);
    _ = reader.take(4) catch unreachable; // The test peer's buffers are sized for it.
    _ = reader.take(2 + 32) catch unreachable; // The test peer's buffers are sized for it.
    const session = reader.vector8() catch unreachable; // The test peer's buffers are sized for it.
    _ = reader.vector16() catch unreachable; // The test peer's buffers are sized for it.
    _ = reader.vector8() catch unreachable; // The test peer's buffers are sized for it.
    var extensions = wire.Reader.init(reader.vector16() catch unreachable); // Test input.
    var found: ?[32]u8 = null;
    while (extensions.remaining() > 0) {
        // The test peer's buffers are sized for it.
        const kind = extensions.read_u16() catch unreachable;
        // The test peer's buffers are sized for it.
        const data = extensions.vector16() catch unreachable;
        if (kind == 51) found = data[6..38].*;
    }
    return .{ .session_id = session[0..32].*, .public_key = found.? };
}
