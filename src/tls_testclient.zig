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
const p256 = @import("x509_p256.zig");
const p256_test = @import("x509_p256_test.zig");

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
    /// `chrome` is Chromium's list, which has ecdsa_secp256r1_sha256 and no ed25519.
    signature_algorithms: enum { ed25519, other, absent, chrome, rsa_pss } = .ed25519,
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

/// The client's chain: `good` is a workload's; `server_kind`, `node_kind` and `client_kind` a good
/// leaf of that kind.
pub const Chain = enum {
    good,
    none,
    other_ca,
    expired,
    server_kind,
    node_kind,
    client_kind,
    three,
    tampered,
    /// A browser client certificate (P-256, from the browser CA) on the Ed25519 path.
    browser_client,
};
/// `high_s`: the browser path's ECDSA signature with S replaced by n - S, as a browser may send.
pub const Verify = enum { good, omit, wrong_key, server_context, bad_scheme, flipped, high_s };
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

/// The public path (docs/briefs/c5.md, "Public TLS"): the client sends a server name and ALPN,
/// takes no CertificateRequest, checks the server's P-256 leaf against `root` and the host, and
/// sends only its Finished, as a browser does.
pub const Public = struct {
    /// The key of the CA that signed the server's leaf.
    root: p256.KeyPair,
    /// The server name sent; null sends no server_name extension.
    server_name: ?[]const u8 = "hello.test",
    /// The DNS name the server's leaf must carry.
    expect_host: []const u8 = "hello.test",
    alpn: Alpn = .h2_and_http11,
    /// supported_groups lists x25519 and the key share has only secp256r1: a HelloRetryRequest
    /// would be needed.
    x25519_without_share: bool = false,

    pub const Alpn = enum { absent, h2_and_http11, h2_only };
};

pub const Config = struct {
    ca: Ed25519.KeyPair,
    /// When set, the client takes the public path; `browser` and the client chain are unused.
    public: ?Public = null,
    /// The browser CA: when set, the client takes the browser path with a P-256 certificate.
    /// `client_kind` and `node_kind` then present the cluster CA's Ed25519 certificates (the
    /// cross path), `server_kind` a browser server certificate.
    browser: ?p256.KeyPair = null,
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
    /// Big enough for the public path's flight, whose chain is up to `edge_chain_bytes_max`.
    received: [constants.tls_record_plaintext_bytes_max]u8,
    /// The public path's EncryptedExtensions selected http/1.1.
    alpn_selected: bool,
    received_length: u32,
    finished_seen: bool,
    leaf: x509.Der,
    ca_certificate: x509.Der,
    p256_key: p256.KeyPair,
    server_point: p256.Point,

    pub fn init(self: *Client, config: Config) !void {
        self.config = config;
        self.key = try Ed25519.KeyPair.generateDeterministic(@splat(0x66));
        self.transcript = schedule.Transcript.init();
        self.secrets = schedule.Schedule.init();
        self.received_length = 0;
        self.alpn_selected = false;
        self.finished_seen = false;
        self.p256_key = try p256_test.key(0x67);
        self.server_point = @splat(0);
        if (config.public != null) return; // The public path presents no certificate.
        if (config.browser) |browser| return self.issue_browser(browser);
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
        const key = self.key.public_key.toBytes();
        switch (self.config.faults.chain) {
            .server_kind => try x509.issue_server(&self.leaf, ca, &.{
                .dns_name = "client.botpike.com",
                .subject_key = key,
                .lifetime = x509_test.window,
            }),
            .node_kind => try x509.issue_node(&self.leaf, ca, &x509_test.node_request(key)),
            .client_kind => {
                const client = x509_test.client_request(key, .jobs);
                try x509.issue_client(&self.leaf, ca, &client);
            },
            .browser_client => try p256.issue_client(&self.leaf, try p256_test.ca_key(), &.{
                .cluster = "prod",
                .client = "alice",
                .scope = .jobs,
                .subject_key = p256.point_of(try p256_test.key(0x67)),
                .lifetime = p256_test.leaf_lifetime,
            }),
            else => try x509.issue_workload(&self.leaf, signer, &request),
        }
        if (self.config.faults.chain == .tampered) {
            const bytes = self.leaf.bytes[self.leaf.start..];
            bytes[bytes.len - 10] ^= 0x01; // Inside the signature.
        }
        try x509.issue_ca(&self.ca_certificate, ca, x509_test.window);
    }

    fn issue_browser(self: *Client, ca: p256.KeyPair) !void {
        const point = p256.point_of(self.p256_key);
        var signer = ca;
        var lifetime = p256_test.leaf_lifetime;
        switch (self.config.faults.chain) {
            .other_ca => signer = try p256_test.key(0xCD),
            .expired => lifetime = .{
                .not_before_ms = x509_test.now - 3 * x509_test.hour,
                .not_after_ms = x509_test.now - 2 * x509_test.hour,
            },
            else => {},
        }
        const ed25519_key = self.key.public_key.toBytes();
        switch (self.config.faults.chain) {
            .server_kind => try p256.issue_server(&self.leaf, ca, &.{
                .dns_name = "client.botpike.com",
                .sans = &.{},
                .subject_key = point,
                .lifetime = lifetime,
            }),
            .node_kind => {
                const cluster_ca = self.config.ca;
                try x509.issue_node(&self.leaf, cluster_ca, &x509_test.node_request(ed25519_key));
            },
            .client_kind => {
                const client = x509_test.client_request(ed25519_key, .jobs);
                try x509.issue_client(&self.leaf, self.config.ca, &client);
            },
            else => try p256.issue_client(&self.leaf, signer, &.{
                .cluster = "prod",
                .client = "alice",
                .scope = .jobs,
                .subject_key = point,
                .lifetime = lifetime,
            }),
        }
        if (self.config.faults.chain == .tampered) {
            const bytes = self.leaf.bytes[self.leaf.start..];
            bytes[bytes.len - 10] ^= 0x01; // Inside the signature.
        }
        try p256.issue_ca(&self.ca_certificate, ca, x509_test.window);
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
        if (self.config.public) |public| {
            hello_public_extensions(w, public);
        } else {
            // server_name: read past by the cluster paths.
            w.bytes(&.{ 0, 0, 0, 9, 0, 7, 0, 0, 4, 'z', 'c', '.', 'x' });
        }
        if (knobs.supported_groups) w.bytes(&.{ 0, 10, 0, 4, 0, 2, 0, 0x1d });
        switch (knobs.signature_algorithms) {
            .ed25519 => w.bytes(&.{ 0, 13, 0, 6, 0, 4, 0x04, 0x03, 0x08, 0x07 }),
            .other => w.bytes(&.{ 0, 13, 0, 4, 0, 2, 0x04, 0x03 }),
            .rsa_pss => w.bytes(&.{ 0, 13, 0, 4, 0, 2, 0x08, 0x04 }),
            .chrome => w.bytes(&.{
                0,    13,   0,    18,   0,    16,
                0x04, 0x03, 0x08, 0x04, 0x04, 0x01,
                0x05, 0x03, 0x08, 0x05, 0x05, 0x01,
                0x08, 0x06, 0x06, 0x01,
            }),
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

    /// server_name and ALPN, written here, not with the server's code.
    fn hello_public_extensions(w: *Writer, public: Public) void {
        if (public.server_name) |name| {
            w.u16_(0); // server_name
            const extension = w.open16();
            const list = w.open16();
            w.u8_(0); // host_name
            w.u16_(@intCast(name.len));
            w.bytes(name);
            w.close16(list);
            w.close16(extension);
        }
        const names: []const []const u8 = switch (public.alpn) {
            .absent => return,
            .h2_and_http11 => &.{ "h2", "http/1.1" },
            .h2_only => &.{"h2"},
        };
        w.u16_(16); // application_layer_protocol_negotiation
        const extension = w.open16();
        const list = w.open16();
        for (names) |name| {
            w.u8_(@intCast(name.len));
            w.bytes(name);
        }
        w.close16(list);
        w.close16(extension);
    }

    fn key_share(self: *Client, w: *Writer) void {
        const knobs = self.config.faults.hello;
        var public = X25519.recoverPublicKey(self.config.secret);
        if (knobs.low_order) public = @splat(0);
        w.u16_(51);
        const extension = w.open16();
        const list = w.open16();
        const without_share = if (self.config.public) |path| path.x25519_without_share else false;
        if (!knobs.x25519 or without_share) {
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
                if (self.config.public != null) {
                    try self.read_public_extensions(body);
                    self.transcript.add(message);
                    return wire.handshake_certificate; // A CertificateRequest is refused.
                }
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
            wire.handshake_certificate => return self.read_certificate(message),
            wire.handshake_certificate_verify => {
                if (self.config.browser != null) return self.read_browser_verify(message);
                if (self.config.public != null) return self.read_browser_verify(message);
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

    /// The server's Certificate: the public path, the browser path or the cluster's.
    fn read_certificate(self: *Client, message: []const u8) Error!u8 {
        const body = message[4..];
        if (self.config.public) |public| {
            return self.read_public_certificate(public, message);
        }
        const chain = wire.parse_certificate(body) catch return error.BadFlight;
        if (self.config.browser) |browser| {
            const anchor = p256.point_of(browser);
            const parsed = p256.verify(chain.leaf, anchor, self.config.now_ms, .{
                .kind = .server,
                .name = null,
            }) catch return error.BadFlight;
            self.server_point = parsed.point(chain.leaf);
            self.transcript.add(message);
            return wire.handshake_certificate_verify;
        }
        const anchor = self.config.ca.public_key.toBytes();
        const parsed = x509.verify(chain.leaf, anchor, self.config.now_ms, .{
            .kind = .server,
            .name = null,
        }) catch return error.BadFlight;
        self.server_key = parsed.public_key.of(chain.leaf)[0..32].*;
        self.transcript.add(message);
        return wire.handshake_certificate_verify;
    }

    /// The public path's EncryptedExtensions, parsed here: an empty server_name at most, and ALPN
    /// only if offered, selecting exactly http/1.1.
    fn read_public_extensions(self: *Client, body: []const u8) Error!void {
        const public = self.config.public.?;
        if (body.len < 2) return error.BadFlight;
        if (std.mem.readInt(u16, body[0..2], .big) != body.len - 2) return error.BadFlight;
        var at: usize = 2;
        while (at < body.len) {
            if (body.len - at < 4) return error.BadFlight;
            const kind = std.mem.readInt(u16, body[at..][0..2], .big);
            const length = std.mem.readInt(u16, body[at + 2 ..][0..2], .big);
            if (body.len - at - 4 < length) return error.BadFlight;
            const data = body[at + 4 ..][0..length];
            switch (kind) {
                0 => if (length != 0) return error.BadFlight,
                16 => {
                    if (public.alpn == .absent) return error.BadFlight;
                    if (self.alpn_selected) return error.BadFlight;
                    const selected = [_]u8{ 0, 9, 8 } ++ "http/1.1".*;
                    if (!std.mem.eql(u8, data, &selected)) return error.BadFlight;
                    self.alpn_selected = true;
                },
                else => return error.BadFlight,
            }
            at += 4 + length;
        }
    }

    /// The public path's Certificate: the leaf checked against `root` and the host; whatever
    /// follows it is passed over, as a browser builds its own path.
    fn read_public_certificate(self: *Client, public: Public, message: []const u8) Error!u8 {
        const body = message[4..];
        if (body.len < 4 + 3 or body[0] != 0) return error.BadFlight;
        const leaf_length = std.mem.readInt(u24, body[4..7], .big);
        if (body.len < 7 + leaf_length) return error.BadFlight;
        const leaf = body[7..][0..leaf_length];
        const anchor = p256.point_of(public.root);
        const parsed = p256.verify(leaf, anchor, self.config.now_ms, .{
            .kind = .server,
            .name = public.expect_host,
        }) catch return error.BadFlight;
        self.server_point = parsed.point(leaf);
        self.transcript.add(message);
        return wire.handshake_certificate_verify;
    }

    /// The browser path's server CertificateVerify: ECDSA P-256, strict DER, and a low S (this
    /// server normalises it, so a high one is a server bug).
    fn read_browser_verify(self: *Client, message: []const u8) Error!u8 {
        const signature = wire.parse_certificate_verify_p256(message[4..]) catch
            return error.BadFlight;
        const hash = self.transcript.hash();
        const content = schedule.certificate_verify_content(.server, &hash);
        p256.signature_verify(self.server_point, &content, signature, .low_s) catch
            return error.BadFlight;
        self.transcript.add(message);
        return wire.handshake_finished;
    }

    // ---- The client's flight ------------------------------------------------------------------

    /// The client's last flight, faults and all. Afterwards the write side holds the
    /// application keys.
    pub fn flight(self: *Client, out: []u8) []u8 {
        assert(self.finished_seen);
        if (self.config.public != null) return self.public_flight(out);
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

    /// The public path's last flight: a change_cipher_spec, then the Finished alone.
    fn public_flight(self: *Client, out: []u8) []u8 {
        const faults = self.config.faults;
        var length: usize = 0;
        for (0..faults.ccs) |_| {
            const ccs = [1]u8{faults.ccs_byte};
            length += schedule.write_plain(out[length..], .change_cipher_spec, 0x0303, &ccs).len;
        }
        var buffer: [4 + schedule.hash_bytes]u8 = undefined;
        if (self.finished_message(&buffer)) |finished| {
            length += self.seal(out[length..], .handshake, finished).len;
        }
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
        if (self.config.browser != null) return self.verify_message_p256(out);
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

    fn verify_message_p256(self: *Client, out: []u8) []const u8 {
        const faults = self.config.faults;
        const role: schedule.CertificateRole =
            if (faults.verify == .server_context) .server else .client;
        const content = schedule.certificate_verify_content(role, &self.transcript.hash());
        var key = self.p256_key;
        if (faults.verify == .wrong_key) {
            key = p256_test.key(0x99) catch unreachable; // A fixed seed.
        }
        var signature = p256.sign(key, &content);
        if (faults.verify == .high_s) signature.s = p256.negate(signature.s);
        if (faults.verify == .flipped) signature.r[20] ^= 0x10;
        var der: [p256.signature_der_bytes_max]u8 = undefined;
        const encoded = p256.signature_write(&der, signature);
        var buffer: [wire.certificate_verify_bytes_max]u8 = undefined;
        const message = wire.write_certificate_verify_p256(&buffer, encoded);
        @memcpy(out[0..message.len], message);
        if (faults.verify == .bad_scheme) std.mem.writeInt(u16, out[4..6], 0x0807, .big);
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
