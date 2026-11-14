//! A scripted TLS 1.3 client for the server's tests (docs/briefs/b7.md, slice 1). It builds its
//! ClientHello and its last flight from the key schedule, so a test can make them right or break
//! one thing at a time, every other message still signed and hashed correctly. It is a test
//! fixture: only test roots import it, and a real client never does.
//!
//! It takes every transcript hash from its own `Transcript` and writes its ClientHello with its
//! own code, not `tls_wire.write_client_hello`, so a server that drops a message from its hash or
//! reads the hello the way the client writes it, and no other way, is caught.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const schedule = @import("tls_schedule.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const header_bytes = constants.tls_record_header_bytes;

/// What the ClientHello gets wrong. The default is a correct client in compatibility mode.
pub const Hello = struct {
    /// supported_versions lists TLS 1.3 (else only TLS 1.2).
    tls13: bool = true,
    /// No extensions at all: a TLS 1.2 hello.
    extensions: bool = true,
    /// The suites offered include TLS_AES_128_GCM_SHA256 (else only TLS_AES_256_GCM_SHA384).
    suite: bool = true,
    /// The key share is x25519 (else secp256r1 only).
    x25519: bool = true,
    /// The length of the x25519 key.
    key_bytes: u16 = 32,
    /// The x25519 key is all zero: a low-order point.
    low_order: bool = false,
    signature_algorithms: enum { ed25519, other, absent } = .ed25519,
    /// The one compression method offered.
    compression: u8 = 0,
    session_id: bool = true,
    /// supported_versions appears twice.
    duplicate: bool = false,
    /// early_data is offered.
    early_data: bool = false,
    /// A pre_shared_key that is not the last extension.
    psk_not_last: bool = false,
    /// The key share lists x25519 twice.
    duplicate_group: bool = false,
    /// supported_groups is sent (a key_share needs it, RFC 8446 section 9.2).
    supported_groups: bool = true,
    /// The start of a Certificate (its header, announcing 256 bytes) follows the ClientHello in
    /// its record.
    trailing: bool = false,
};

pub const Chain = enum { good, none, other_ca, expired, server_kind, three, tampered };
pub const Verify = enum { good, omit, wrong_key, server_context, bad_scheme, flipped };
pub const Finished = enum { good, bad, omit };

/// What the client's last flight gets wrong.
pub const Faults = struct {
    hello: Hello = .{},
    /// change_cipher_spec records sent before the protected flight.
    ccs: u32 = 1,
    /// The change_cipher_spec's one byte.
    ccs_byte: u8 = 1,
    chain: Chain = .good,
    /// The certificate_request_context the Certificate echoes.
    context: []const u8 = "",
    verify: Verify = .good,
    finished: Finished = .good,
    /// A KeyUpdate follows the Finished in the same record.
    trailing: bool = false,
    /// An application_data record goes before the Finished.
    early_application_data: bool = false,
    /// Every message of the flight in one record (else one record each).
    one_record: bool = true,
    /// Certificate and CertificateVerify swap places.
    swapped: bool = false,
    /// Certificate and CertificateVerify stay out of the client's transcript: its signature and
    /// its Finished do not cover them, as if they were swapped in after the client signed.
    unbound_auth: bool = false,
};

pub const Config = struct {
    ca: Ed25519.KeyPair,
    now_ms: u64 = x509_test.now,
    random: [32]u8 = @splat(0x44),
    secret: [32]u8 = @splat(0x55),
    faults: Faults = .{},
};

pub const Error = error{BadFlight};

pub const Client = struct {
    config: Config,
    key: Ed25519.KeyPair,
    transcript: schedule.Transcript,
    secrets: schedule.Schedule,
    read: schedule.Direction,
    write: schedule.Direction,
    client_application: schedule.Secret,
    server_key: [32]u8,
    received: [constants.tls_handshake_flight_bytes_max]u8,
    received_length: u32,
    finished_seen: bool,
    leaf: x509.Der,
    ca_certificate: x509.Der,

    pub fn init(self: *Client, config: Config) !void {
        self.config = config;
        self.key = try Ed25519.KeyPair.generateDeterministic(@splat(0x66));
        self.transcript = schedule.Transcript.init();
        self.secrets = schedule.Schedule.init();
        self.received_length = 0;
        self.finished_seen = false;
        try self.issue();
    }

    fn issue(self: *Client) !void {
        const ca = self.config.ca;
        var signer = ca;
        var request = x509_test.workload_request(self.key.public_key.toBytes());
        switch (self.config.faults.chain) {
            .other_ca => signer = try Ed25519.KeyPair.generateDeterministic(@splat(0xCC)),
            .expired => request.lifetime = .{
                .not_before_ms = x509_test.now - 3 * x509_test.hour,
                .not_after_ms = x509_test.now - 2 * x509_test.hour,
            },
            else => {},
        }
        if (self.config.faults.chain == .server_kind) {
            try x509.issue_server(&self.leaf, ca, &.{
                .dns_name = "client.botpike.com",
                .subject_key = self.key.public_key.toBytes(),
                .lifetime = x509_test.window,
            });
        } else {
            try x509.issue_workload(&self.leaf, signer, &request);
        }
        if (self.config.faults.chain == .tampered) {
            const bytes = self.leaf.bytes[self.leaf.start..];
            bytes[bytes.len - 10] ^= 0x01; // Inside the signature.
        }
        try x509.issue_ca(&self.ca_certificate, ca, x509_test.window);
    }

    // ---- The ClientHello ----------------------------------------------------------------------

    /// The ClientHello record.
    pub fn hello(self: *Client, out: []u8) []u8 {
        const message = self.hello_message(out[header_bytes..]);
        self.transcript.add(message);
        var length = message.len;
        if (self.config.faults.hello.trailing) {
            const tail = [4]u8{ wire.handshake_certificate, 0, 1, 0 };
            @memcpy(out[header_bytes + length ..][0..tail.len], &tail);
            length += tail.len;
        }
        out[0] = @backingInt(schedule.ContentType.handshake);
        std.mem.writeInt(u16, out[1..3], 0x0301, .big);
        std.mem.writeInt(u16, out[3..5], @intCast(length), .big);
        return out[0 .. header_bytes + length];
    }

    fn hello_message(self: *Client, out: []u8) []u8 {
        const knobs = self.config.faults.hello;
        var w: Writer = .{ .buffer = out };
        w.u8_(wire.handshake_client_hello);
        w.bytes(&.{ 0, 0, 0 });
        w.u16_(0x0303);
        w.bytes(&self.config.random);
        if (knobs.session_id) {
            w.u8_(32);
            w.bytes(&@as([32]u8, @splat(0x77)));
        } else {
            w.u8_(0);
        }
        if (knobs.suite) {
            w.bytes(&.{ 0, 4, 0x13, 0x02, 0x13, 0x01 });
        } else {
            w.bytes(&.{ 0, 2, 0x13, 0x02 });
        }
        w.bytes(&.{ 1, knobs.compression });
        if (knobs.extensions) {
            const at = w.open16();
            self.hello_extensions(&w);
            w.close16(at);
        }
        std.mem.writeInt(u24, out[1..4], @intCast(w.length - 4), .big);
        return out[0..w.length];
    }

    fn hello_extensions(self: *Client, w: *Writer) void {
        const knobs = self.config.faults.hello;
        // server_name, supported_groups: read past by the server.
        w.bytes(&.{ 0, 0, 0, 9, 0, 7, 0, 0, 4, 'z', 'c', '.', 'x' });
        if (knobs.supported_groups) w.bytes(&.{ 0, 10, 0, 4, 0, 2, 0, 0x1d });
        switch (knobs.signature_algorithms) {
            .ed25519 => w.bytes(&.{ 0, 13, 0, 6, 0, 4, 0x04, 0x03, 0x08, 0x07 }),
            .other => w.bytes(&.{ 0, 13, 0, 4, 0, 2, 0x04, 0x03 }),
            .absent => {},
        }
        const version: u8 = if (knobs.tls13) 0x04 else 0x03;
        w.bytes(&.{ 0, 43, 0, 3, 2, 0x03, version });
        if (knobs.duplicate) w.bytes(&.{ 0, 43, 0, 3, 2, 0x03, version });
        if (knobs.early_data) w.bytes(&.{ 0, 42, 0, 0 });
        self.key_share(w);
        if (knobs.psk_not_last) w.bytes(&.{ 0, 41, 0, 0 });
        if (knobs.psk_not_last) w.bytes(&.{ 0, 45, 0, 2, 1, 1 });
    }

    fn key_share(self: *Client, w: *Writer) void {
        const knobs = self.config.faults.hello;
        var public = X25519.recoverPublicKey(self.config.secret);
        if (knobs.low_order) public = @splat(0);
        w.u16_(51);
        const extension = w.open16();
        const list = w.open16();
        if (!knobs.x25519) {
            w.bytes(&.{ 0, 23, 0, 1, 4 }); // secp256r1, a stub key
        } else {
            const copies: u32 = if (knobs.duplicate_group) 2 else 1;
            for (0..copies) |_| {
                w.u16_(wire.group_x25519);
                w.u16_(knobs.key_bytes);
                var key: [64]u8 = @splat(0);
                @memcpy(key[0..32], &public);
                w.bytes(key[0..knobs.key_bytes]);
            }
        }
        w.close16(list);
        w.close16(extension);
    }

    // ---- The server's flight ------------------------------------------------------------------

    /// Reads the server's whole first flight: ServerHello, maybe a change_cipher_spec, then the
    /// protected EncryptedExtensions, CertificateRequest, Certificate, CertificateVerify and
    /// Finished. Checks them as a stock client would.
    pub fn accept_flight(self: *Client, bytes: []u8) Error!void {
        var rest = bytes;
        const hello_record = take_record(&rest) orelse return error.BadFlight;
        if (hello_record[0] != @backingInt(schedule.ContentType.handshake)) return error.BadFlight;
        const server_hello = hello_record[header_bytes..];
        const public = server_key_share(server_hello) orelse return error.BadFlight;
        self.transcript.add(server_hello);
        const shared = X25519.scalarmult(self.config.secret, public) catch return error.BadFlight;
        const hash = self.transcript.hash();
        const secrets = self.secrets.to_handshake(&shared, &hash) catch return error.BadFlight;
        self.read = schedule.Direction.init(&secrets.server);
        self.write = schedule.Direction.init(&secrets.client);
        while (rest.len > 0) {
            const record = take_record(&rest) orelse return error.BadFlight;
            if (record[0] == @backingInt(schedule.ContentType.change_cipher_spec)) continue;
            const opened = self.read.open(record) catch return error.BadFlight;
            if (opened.content_type != .handshake) return error.BadFlight;
            @memcpy(self.received[self.received_length..][0..opened.content.len], opened.content);
            self.received_length += @intCast(opened.content.len);
        }
        try self.read_messages();
        if (!self.finished_seen) return error.BadFlight;
    }

    fn read_messages(self: *Client) Error!void {
        var at: u32 = 0;
        var expected: u8 = wire.handshake_encrypted_extensions;
        while (at < self.received_length) {
            if (self.received_length - at < 4) return error.BadFlight;
            const length = std.mem.readInt(u24, self.received[at + 1 ..][0..3], .big);
            if (self.received_length - at < 4 + length) return error.BadFlight;
            const message = self.received[at..][0 .. 4 + length];
            if (message[0] != expected) return error.BadFlight;
            expected = try self.read_message(message);
            at += 4 + length;
        }
    }

    /// Checks one message of the server's flight and returns the type of the next.
    fn read_message(self: *Client, message: []const u8) Error!u8 {
        const body = message[4..];
        switch (message[0]) {
            wire.handshake_encrypted_extensions => {
                wire.parse_encrypted_extensions(body) catch return error.BadFlight;
                self.transcript.add(message);
                return wire.handshake_certificate_request;
            },
            wire.handshake_certificate_request => {
                const request = wire.parse_certificate_request(body) catch return error.BadFlight;
                if (request.context.len != 0) return error.BadFlight;
                self.transcript.add(message);
                return wire.handshake_certificate;
            },
            wire.handshake_certificate => {
                const chain = wire.parse_certificate(body) catch return error.BadFlight;
                const anchor = self.config.ca.public_key.toBytes();
                const parsed = x509.verify(chain.leaf, anchor, self.config.now_ms, .{
                    .kind = .server,
                    .name = null,
                }) catch return error.BadFlight;
                self.server_key = parsed.public_key.of(chain.leaf)[0..32].*;
                self.transcript.add(message);
                return wire.handshake_certificate_verify;
            },
            wire.handshake_certificate_verify => {
                const signature = wire.parse_certificate_verify(body) catch return error.BadFlight;
                const hash = self.transcript.hash();
                const content = schedule.certificate_verify_content(.server, &hash);
                const key = Ed25519.PublicKey.fromBytes(self.server_key) catch
                    return error.BadFlight;
                const parsed = Ed25519.Signature.fromBytes(signature.*);
                parsed.verify(&content, key) catch return error.BadFlight;
                self.transcript.add(message);
                return wire.handshake_finished;
            },
            wire.handshake_finished => {
                const hash = self.transcript.hash();
                const secret = &self.read.secret;
                if (!schedule.finished_matches(secret, &hash, body)) return error.BadFlight;
                self.transcript.add(message);
                const finished_hash = self.transcript.hash();
                const application = self.secrets.to_application(&finished_hash);
                self.read = schedule.Direction.init(&application.server);
                self.client_application = application.client;
                self.finished_seen = true;
                return 0;
            },
            else => return error.BadFlight,
        }
    }

    // ---- The client's flight ------------------------------------------------------------------

    /// The client's last flight, faults and all. Afterwards the write side holds the
    /// application keys.
    pub fn flight(self: *Client, out: []u8) []u8 {
        assert(self.finished_seen);
        const faults = self.config.faults;
        var length: usize = 0;
        for (0..faults.ccs) |_| {
            const ccs = [1]u8{faults.ccs_byte};
            length += schedule.write_plain(out[length..], .change_cipher_spec, 0x0303, &ccs).len;
        }
        var messages: [3][]const u8 = undefined;
        var buffers: [3][constants.tls_handshake_message_bytes_max]u8 = undefined;
        var count: u32 = 0;
        const certificate = self.certificate_message(&buffers[0]);
        if (!faults.unbound_auth) self.transcript.add(certificate);
        const verify = self.verify_message(&buffers[1]);
        if (verify) |message| {
            if (!faults.unbound_auth) self.transcript.add(message);
        }
        if (faults.swapped) {
            if (verify) |message| append(&messages, &count, message);
            append(&messages, &count, certificate);
        } else {
            append(&messages, &count, certificate);
            if (verify) |message| append(&messages, &count, message);
        }
        if (faults.early_application_data) {
            length += self.seal(out[length..], .application_data, "early").len;
        }
        const finished = self.finished_message(&buffers[2]);
        if (finished) |message| append(&messages, &count, message);
        length += self.seal_messages(out[length..], messages[0..count]);
        self.write = schedule.Direction.init(&self.client_application);
        return out[0..length];
    }

    fn seal_messages(self: *Client, out: []u8, messages: []const []const u8) usize {
        const faults = self.config.faults;
        var content: [constants.tls_handshake_flight_bytes_max]u8 = undefined;
        var content_length: usize = 0;
        var length: usize = 0;
        for (messages) |message| {
            @memcpy(content[content_length..][0..message.len], message);
            content_length += message.len;
            if (!faults.one_record) {
                length += self.seal(out[length..], .handshake, content[0..content_length]).len;
                content_length = 0;
            }
        }
        if (faults.trailing) {
            const update = [_]u8{ schedule.key_update_type, 0, 0, 1, 0 };
            @memcpy(content[content_length..][0..update.len], &update);
            content_length += update.len;
        }
        if (content_length > 0) {
            length += self.seal(out[length..], .handshake, content[0..content_length]).len;
        }
        return length;
    }

    fn certificate_message(self: *Client, out: []u8) []const u8 {
        const faults = self.config.faults;
        var w: Writer = .{ .buffer = out };
        w.bytes(&.{ wire.handshake_certificate, 0, 0, 0 });
        w.u8_(@intCast(faults.context.len));
        w.bytes(faults.context);
        const list_at = w.length;
        w.bytes(&.{ 0, 0, 0 });
        const leaf = self.leaf.slice();
        const ca = self.ca_certificate.slice();
        const chain: []const []const u8 = switch (faults.chain) {
            .none => &.{},
            .three => &.{ leaf, ca, ca },
            else => &.{ leaf, ca },
        };
        for (chain) |certificate| {
            w.u24_(@intCast(certificate.len));
            w.bytes(certificate);
            w.u16_(0);
        }
        std.mem.writeInt(u24, out[list_at..][0..3], @intCast(w.length - list_at - 3), .big);
        std.mem.writeInt(u24, out[1..4], @intCast(w.length - 4), .big);
        return out[0..w.length];
    }

    fn verify_message(self: *Client, out: []u8) ?[]const u8 {
        const faults = self.config.faults;
        if (faults.verify == .omit) return null;
        const role: schedule.CertificateRole =
            if (faults.verify == .server_context) .server else .client;
        const content = schedule.certificate_verify_content(role, &self.transcript.hash());
        var key = self.key;
        if (faults.verify == .wrong_key) {
            key = Ed25519.KeyPair.generateDeterministic(@splat(0x99)) catch unreachable; // Fixed.
        }
        const signature = key.sign(&content, null) catch unreachable; // A fixed key.
        var bytes = signature.toBytes();
        if (faults.verify == .flipped) bytes[3] ^= 0x10;
        var message = wire.write_certificate_verify(&bytes);
        if (faults.verify == .bad_scheme) std.mem.writeInt(u16, message[4..6], 0x0403, .big);
        @memcpy(out[0..message.len], &message);
        return out[0..message.len];
    }

    fn finished_message(self: *Client, out: []u8) ?[]const u8 {
        const faults = self.config.faults;
        if (faults.finished == .omit) return null;
        const hash = self.transcript.hash();
        var verify_data = schedule.finished_verify_data(&self.write.secret, &hash);
        if (faults.finished == .bad) verify_data[0] ^= 0x01;
        out[0] = wire.handshake_finished;
        std.mem.writeInt(u24, out[1..4], schedule.hash_bytes, .big);
        @memcpy(out[4..][0..schedule.hash_bytes], &verify_data);
        return out[0 .. 4 + schedule.hash_bytes];
    }

    // ---- After the handshake ------------------------------------------------------------------

    pub fn seal(self: *Client, out: []u8, kind: schedule.ContentType, content: []const u8) []u8 {
        return self.write.seal(out, kind, content) catch unreachable; // The fixture's sizes fit.
    }

    pub fn open(self: *Client, record: []u8) schedule.Error!schedule.Opened {
        return self.read.open(record);
    }

    /// A KeyUpdate record, then the write keys move on.
    pub fn key_update(self: *Client, out: []u8, request: bool) []u8 {
        const bytes = [_]u8{ schedule.key_update_type, 0, 0, 1, @intFromBool(request) };
        const sealed = self.seal(out, .handshake, &bytes);
        self.write.rekey() catch unreachable; // The fixture updates far below the limit.
        return sealed;
    }
};

fn append(messages: *[3][]const u8, count: *u32, message: []const u8) void {
    messages[count.*] = message;
    count.* += 1;
}

/// Cuts the next whole record from `rest`.
pub fn take_record(rest: *[]u8) ?[]u8 {
    if (rest.len < header_bytes) return null;
    const total = header_bytes + std.mem.readInt(u16, rest.*[3..5], .big);
    if (rest.len < total) return null;
    const record = rest.*[0..total];
    rest.* = rest.*[total..];
    return record;
}

/// The x25519 key of a ServerHello message, read independently of `tls_wire`.
fn server_key_share(message: []const u8) ?[32]u8 {
    var reader = wire.Reader.init(message);
    const kind = reader.read_u8() catch return null;
    if (kind != wire.handshake_server_hello) return null;
    _ = reader.read_u24() catch return null;
    if ((reader.read_u16() catch return null) != 0x0303) return null;
    _ = reader.take(32) catch return null;
    _ = reader.vector8() catch return null;
    if ((reader.read_u16() catch return null) != wire.suite_aes_128_gcm_sha256) return null;
    _ = reader.read_u8() catch return null;
    var extensions = wire.Reader.init(reader.vector16() catch return null);
    while (extensions.remaining() > 0) {
        const extension = extensions.read_u16() catch return null;
        var data = wire.Reader.init(extensions.vector16() catch return null);
        if (extension != 51) continue;
        if ((data.read_u16() catch return null) != wire.group_x25519) return null;
        const key = data.vector16() catch return null;
        if (key.len != 32) return null;
        return key[0..32].*;
    }
    return null;
}

const Writer = struct {
    buffer: []u8,
    length: u32 = 0,

    fn u8_(w: *Writer, value: u8) void {
        w.buffer[w.length] = value;
        w.length += 1;
    }

    fn u16_(w: *Writer, value: u16) void {
        std.mem.writeInt(u16, w.buffer[w.length..][0..2], value, .big);
        w.length += 2;
    }

    fn u24_(w: *Writer, value: u24) void {
        std.mem.writeInt(u24, w.buffer[w.length..][0..3], value, .big);
        w.length += 3;
    }

    fn bytes(w: *Writer, value: []const u8) void {
        @memcpy(w.buffer[w.length..][0..value.len], value);
        w.length += @intCast(value.len);
    }

    fn open16(w: *Writer) u32 {
        const at = w.length;
        w.length += 2;
        return at;
    }

    fn close16(w: *Writer, at: u32) void {
        std.mem.writeInt(u16, w.buffer[at..][0..2], @intCast(w.length - at - 2), .big);
    }
};
