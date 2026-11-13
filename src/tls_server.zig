//! The TLS 1.3 server handshake (docs/briefs/b7.md, slice 1): ClientHello, the server's flight
//! with a CertificateRequest, then the client's Certificate, CertificateVerify and Finished, and
//! application data with KeyUpdate both ways. The client must present a certificate this
//! cluster's CA signed, of the kind the server was configured for; there is no other way in.
//! A pure state machine like `tls_client.zig`, whose record layer, key schedule and wire code it
//! shares: bytes in, bytes out, one event per step. It opens no socket and reads no clock or
//! random source; the shell passes in the randomness, the x25519 secret and the time.
//!
//! The scope (docs/decisions/2026-11-13-in-house-tls-server.md): TLS 1.3 only, x25519,
//! TLS_AES_128_GCM_SHA256 and Ed25519, no HelloRetryRequest, no session tickets, no PSK, no early
//! data, client authentication always required, and only this cluster's CA.
//!
//! The rules it keeps, the client's: a plaintext change_cipher_spec is dropped before `open`
//! ever sees it; a failed `open` wipes the record buffer and the keys; bytes behind a key change
//! in one record are refused; after a fatal error nothing more is produced but the one alert.
//!
//! Core code: no allocation, no clock, no randomness, no I/O.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const schedule = @import("tls_schedule.zig");
const tls_client = @import("tls_client.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");

const Diag = diag_mod.Diag;
const Code = @import("diag/codes.zig").Code;
const X25519 = std.crypto.dh.X25519;

const header_bytes: u32 = constants.tls_record_header_bytes;

pub const Error = tls_client.Error;
pub const Event = tls_client.Event;
pub const Step = tls_client.Step;
pub const Identity = tls_client.Identity;
pub const Signer = tls_client.Signer;
pub const key_pair_signer = tls_client.key_pair_signer;

pub const Config = struct {
    /// The cluster CA's public key: the only issuer a client certificate may have.
    anchor: [32]u8,
    now_ms: u64,
    random: [32]u8,
    /// The ephemeral x25519 secret.
    secret: [32]u8,
    /// The server's certificate (and optionally the CA's after it) and its signer.
    identity: Identity,
    /// The kinds of certificate a client may present: a workload's for a sidecar, a node's and
    /// a client's for the API (docs/decisions/2026-11-13-api-listener-cert-kinds.md). Required:
    /// a listener that forgot it fails to compile instead of taking a default kind.
    client_kinds: x509.Kinds,
};

/// The client the handshake authenticated.
pub const Peer = struct {
    kind: x509.Kind,
    /// The certificate's SPIFFE URI (a workload) or DNS name.
    name: []const u8,
    /// A client certificate's scope; null for every other kind.
    scope: ?x509.Scope,
};

const peer_name_bytes_max: u32 =
    @max(constants.x509_spiffe_bytes_max, constants.x509_dns_name_bytes_max);

/// The server's flight after ServerHello, as one sealed record: EncryptedExtensions,
/// CertificateRequest, Certificate, CertificateVerify and Finished.
const flight_content_bytes_max: u32 = wire.encrypted_extensions_message.len +
    wire.certificate_request_message.len + wire.certificate_bytes_max +
    wire.certificate_verify_bytes + 4 + schedule.hash_bytes;

/// What one step writes at most: the ServerHello record, the change_cipher_spec and the flight.
pub const output_bytes_max: u32 = header_bytes + wire.server_hello_bytes_max + (header_bytes + 1) +
    header_bytes + flight_content_bytes_max + 1 + schedule.tag_bytes;

comptime {
    assert(flight_content_bytes_max <= constants.tls_record_plaintext_bytes_max);
    assert(output_bytes_max >= schedule.sealed_bytes(flight_content_bytes_max));
    assert(output_bytes_max >= schedule.sealed_bytes(schedule.key_update_bytes));
}

const State = enum {
    wait_client_hello,
    wait_certificate,
    wait_certificate_verify,
    wait_finished,
    connected,
    closed,
    failed,
};

/// Test-only faults for the teeth tests: each skips one security check. Compiled out of every
/// build but a test, as `tls_client.set_test_fault` is.
pub const TestFault = enum {
    /// A client chain is not verified against the CA (only parsed).
    client_chain,
    /// A client certificate of another kind is taken.
    client_kind,
    /// An empty client Certificate is taken, and the handshake goes on unauthenticated.
    required_certificate,
    /// The client's CertificateVerify signature is not checked.
    certificate_verify,
    /// The client's CertificateVerify is checked with the server's context string.
    verify_context,
    /// The client's Finished is not checked.
    finished,
    /// The client's Certificate and CertificateVerify stay out of the server's transcript.
    transcript_client_auth,
    /// Application data before the client's Finished is passed on.
    early_application_data,
    /// Bytes behind the client's Finished, in the same record, are read on.
    key_change_boundary,
};
var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

pub const Server = struct {
    state: State,
    anchor: [32]u8,
    now_ms: u64,
    random: [32]u8,
    secret: [32]u8,
    public_key: [32]u8,
    client_kinds: x509.Kinds,
    identity: [constants.tls_chain_certificates_max][constants.x509_cert_bytes_max]u8,
    identity_lengths: [constants.tls_chain_certificates_max]u32,
    identity_count: u32,
    signer: Signer,
    schedule: schedule.Schedule,
    transcript: schedule.Transcript,
    read: schedule.Direction,
    write: schedule.Direction,
    /// The client's application secret, held from the server's Finished to the client's.
    read_next: schedule.Secret,
    read_protected: bool,
    ccs_dropped: u32,
    leaf_key: [32]u8,
    peer_kind: x509.Kind,
    peer_name: [peer_name_bytes_max]u8,
    peer_name_length: u32,
    peer_scope: ?x509.Scope,
    authenticated: bool,
    record: [schedule.sealed_bytes_max]u8,
    record_length: u32,
    record_total: u32,
    flight: [constants.tls_handshake_flight_bytes_max]u8,
    flight_length: u32,
    out: [output_bytes_max]u8,
    out_length: u32,

    /// Sets the server up in place (it is large), waiting for a ClientHello.
    pub fn init(self: *Server, config: *const Config) void {
        const certificates = config.identity.certificates;
        assert(certificates.len >= 1);
        assert(certificates.len <= constants.tls_chain_certificates_max);
        self.state = .wait_client_hello;
        self.anchor = config.anchor;
        self.now_ms = config.now_ms;
        self.random = config.random;
        self.secret = config.secret;
        self.public_key = X25519.recoverPublicKey(config.secret);
        assert(config.client_kinds.count() >= 1);
        assert(!config.client_kinds.contains(.ca));
        self.client_kinds = config.client_kinds;
        self.identity_lengths = @splat(0);
        for (certificates, 0..) |certificate, index| {
            assert(certificate.len > 0);
            assert(certificate.len <= constants.x509_cert_bytes_max);
            @memcpy(self.identity[index][0..certificate.len], certificate);
            self.identity_lengths[index] = @intCast(certificate.len);
        }
        self.identity_count = @intCast(certificates.len);
        self.signer = config.identity.signer;
        self.schedule = schedule.Schedule.init();
        self.transcript = schedule.Transcript.init();
        self.read_next = @splat(0);
        self.read_protected = false;
        self.ccs_dropped = 0;
        self.leaf_key = @splat(0);
        self.peer_kind = first_kind(config.client_kinds);
        self.peer_name_length = 0;
        self.peer_scope = null;
        self.authenticated = false;
        self.record_length = 0;
        self.record_total = 0;
        self.flight_length = 0;
        self.out_length = 0;
        self.read.wipe();
        self.write.wipe();
        assert(self.read.dead);
        assert(self.write.dead);
    }

    /// What is ready to send. The caller sends it all and calls `drain` before the next step.
    pub fn output(self: *const Server) []const u8 {
        return self.out[0..self.out_length];
    }

    pub fn drain(self: *Server) void {
        self.out_length = 0;
    }

    pub fn is_connected(self: *const Server) bool {
        return self.state == .connected;
    }

    /// The client the handshake authenticated; null before `connected`.
    pub fn peer(self: *const Server) ?Peer {
        if (self.state != .connected) return null;
        if (!self.authenticated) return null;
        return .{
            .kind = self.peer_kind,
            .name = self.peer_name[0..self.peer_name_length],
            .scope = self.peer_scope,
        };
    }

    /// How many more bytes complete the record being read: 0 once the connection is over.
    pub fn wants(self: *const Server) u32 {
        switch (self.state) {
            .closed, .failed => return 0,
            else => {},
        }
        if (self.record_length < header_bytes) return header_bytes - self.record_length;
        assert(self.record_total >= header_bytes);
        assert(self.record_total > self.record_length);
        return self.record_total - self.record_length;
    }

    /// Takes at most `wants()` bytes of `input` and, when a record is complete, acts on it. The
    /// output of the previous step must have been drained.
    pub fn receive(self: *Server, input: []const u8, diag: *Diag) Error!Step {
        assert(self.out_length == 0);
        assert(input.len > 0);
        switch (self.state) {
            .closed, .failed => return error.Closed,
            else => {},
        }
        const take: u32 = @intCast(@min(@as(usize, self.wants()), input.len));
        assert(take > 0);
        @memcpy(self.record[self.record_length..][0..take], input[0..take]);
        self.record_length += take;
        if (self.record_length >= header_bytes and self.record_total == 0) {
            try self.frame_record(diag);
        }
        if (self.record_total == 0) return .{ .consumed = take, .event = .none };
        if (self.record_length < self.record_total) return .{ .consumed = take, .event = .none };
        assert(self.record_length == self.record_total);
        const event = try self.dispatch(diag);
        self.record_length = 0;
        self.record_total = 0;
        return .{ .consumed = take, .event = event };
    }

    /// The transport ended. Not an error after close_notify; anywhere else the data may be cut.
    pub fn end_of_input(self: *Server, diag: *Diag) Error!void {
        if (self.state == .closed) return;
        if (self.state == .failed) return error.Closed;
        diag.raise(.E0816);
        if (self.state == .connected) {
            diag.cause("the client's connection ended without close_notify", .{});
        } else {
            diag.cause("the client's connection ended before the handshake finished", .{});
        }
        add_fix(diag, .E0816);
        return self.refuse(diag, null);
    }

    // ---- Sending ------------------------------------------------------------------------------

    /// The most bytes `seal_application` writes for `plain_length` bytes of data.
    pub const application_bytes_max = tls_client.Client.application_bytes_max;

    /// Protects application data as one record into `out` and returns what to send; a KeyUpdate
    /// goes first when the write keys are at their record limit (RFC 8446 section 5.5).
    pub fn seal_application(
        self: *Server,
        plain: []const u8,
        out: []u8,
        diag: *Diag,
    ) Error![]u8 {
        assert(self.state == .connected);
        assert(self.out_length == 0); // The caller drained the last step's output.
        assert(plain.len <= constants.tls_record_plaintext_bytes_max);
        assert(out.len >= application_bytes_max(plain.len));
        var used: usize = 0;
        if (self.write.update_due()) used = try self.seal_key_update(out, false, diag);
        const record = self.write.seal(out[used..], .application_data, plain) catch |err|
            return self.fail_send(diag, err);
        return out[0 .. used + record.len];
    }

    /// Sends close_notify and ends the connection.
    pub fn close_notify(self: *Server) void {
        assert(self.state == .connected);
        assert(self.out_length == 0); // The caller drained the last step's output.
        self.queue_alert(1, .close_notify);
        self.wipe_secrets();
        self.state = .closed;
    }

    /// Sends a KeyUpdate and moves the write keys on (RFC 8446 section 4.6.3).
    pub fn send_key_update(self: *Server, request: bool, diag: *Diag) Error!void {
        assert(self.state == .connected);
        assert(self.out_length == 0);
        const sealed = try self.seal_key_update(self.out[0..], request, diag);
        self.out_length = @intCast(sealed);
    }

    fn seal_key_update(self: *Server, out: []u8, request: bool, diag: *Diag) Error!usize {
        const message = [_]u8{ schedule.key_update_type, 0, 0, 1, @intFromBool(request) };
        const sealed = self.write.seal(out, .handshake, &message) catch |err|
            return self.fail_send(diag, err);
        self.write.rekey() catch |err| return self.fail_send(diag, err);
        return sealed.len;
    }

    fn fail_send(self: *Server, diag: *Diag, err: schedule.Error) Error {
        switch (err) {
            error.Dead => {
                self.fail_silently();
                return error.Closed;
            },
            error.KeyLimit => diag.raise(.E0815),
            error.TooManyKeyUpdates => diag.raise(.E0815),
            else => unreachable, // Sealing fails only on these three.
        }
        if (err == error.KeyLimit) {
            diag.cause("the write keys reached their record limit without a KeyUpdate", .{});
        } else {
            diag.cause("this server updated its write keys over {d} times", .{
                constants.tls_key_updates_per_connection_max,
            });
        }
        add_fix(diag, .E0815);
        return self.refuse(diag, null);
    }

    // ---- Records ------------------------------------------------------------------------------

    fn frame_record(self: *Server, diag: *Diag) Error!void {
        assert(self.record_length >= header_bytes);
        assert(self.record_total == 0);
        const protection: schedule.Protection = if (self.read_protected) .protected else .plain;
        const header = schedule.Header.parse(self.record[0..header_bytes], protection) catch |err|
            return self.record_failure(diag, err);
        self.record_total = header_bytes + header.length;
        assert(self.record_total <= schedule.sealed_bytes_max);
    }

    fn dispatch(self: *Server, diag: *Diag) Error!Event {
        const protection: schedule.Protection = if (self.read_protected) .protected else .plain;
        const header = schedule.Header.parse(self.record[0..header_bytes], protection) catch
            unreachable; // `frame_record` parsed the same bytes.
        const body = self.record[header_bytes..self.record_total];
        assert(body.len == header.length);
        if (header.content_type == .change_cipher_spec) return self.on_change_cipher_spec(diag);
        if (!self.read_protected) return self.on_plain(diag, header.content_type);
        if (header.content_type == .alert and self.plain_alert_allowed()) {
            return self.on_alert(diag, body);
        }
        if (header.content_type != .application_data) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
        const opened = self.read.open(self.record[0..self.record_total]) catch |err|
            return self.record_failure(diag, err);
        return self.on_content(diag, opened.content_type, opened.content);
    }

    /// A client that could not read the ServerHello has no keys: its alert comes in the clear,
    /// before any protected record.
    fn plain_alert_allowed(self: *const Server) bool {
        if (self.state != .wait_certificate) return false;
        if (self.flight_length != 0) return false;
        return self.read.sequence == 0;
    }

    fn on_plain(self: *Server, diag: *Diag, kind: schedule.ContentType) Error!Event {
        assert(!self.read_protected);
        assert(self.state == .wait_client_hello);
        const body = self.record[header_bytes..self.record_total];
        if (body.len == 0) return self.record_failure(diag, error.UnexpectedMessage);
        if (kind == .alert and self.flight_length != 0) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
        return switch (kind) {
            .handshake => self.on_handshake_bytes(diag, body),
            .alert => self.on_alert(diag, body),
            else => self.record_failure(diag, error.UnexpectedMessage),
        };
    }

    fn on_content(
        self: *Server,
        diag: *Diag,
        kind: schedule.ContentType,
        content: []const u8,
    ) Error!Event {
        if (kind != .handshake) {
            if (self.flight_length != 0) return self.record_failure(diag, error.UnexpectedMessage);
        }
        switch (kind) {
            .handshake => return self.on_handshake_bytes(diag, content),
            .alert => return self.on_alert(diag, content),
            .application_data => {
                if (self.state != .connected and !fault_on(.early_application_data)) {
                    return self.fail(
                        diag,
                        .E0813,
                        .unexpected_message,
                        "the client sent application data before its Finished",
                        .{},
                    );
                }
                return .{ .data = content };
            },
            .change_cipher_spec => return self.record_failure(diag, error.UnexpectedMessage),
        }
    }

    /// RFC 8446 appendix D.4: a client in compatibility mode sends one plaintext
    /// change_cipher_spec before its second flight. It is dropped here, never passed to `open`.
    fn on_change_cipher_spec(self: *Server, diag: *Diag) Error!Event {
        const body = self.record[header_bytes..self.record_total];
        switch (self.state) {
            .wait_certificate, .wait_certificate_verify, .wait_finished => {},
            else => return self.record_failure(diag, error.UnexpectedMessage),
        }
        if (self.flight_length != 0) return self.record_failure(diag, error.UnexpectedMessage);
        if (self.ccs_dropped >= constants.tls_change_cipher_spec_records_max) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
        if (body.len != 1) return self.record_failure(diag, error.UnexpectedMessage);
        if (body[0] != 1) return self.record_failure(diag, error.UnexpectedMessage);
        self.ccs_dropped += 1;
        return .none;
    }

    fn on_alert(self: *Server, diag: *Diag, content: []const u8) Error!Event {
        if (content.len != 2) {
            return self.fail(diag, .E0813, .decode_error, "the client sent a malformed alert", .{});
        }
        // The level (content[0]) is ignored on purpose: in TLS 1.3 every alert but close_notify
        // (and user_canceled) ends the connection whatever its level (RFC 8446 section 6).
        const code = content[1];
        if (code == @backingInt(wire.Alert.close_notify)) {
            if (self.state != .connected) {
                diag.raise(.E0816);
                diag.cause("the client closed the connection before the handshake finished", .{});
                add_fix(diag, .E0816);
                return self.refuse(diag, null);
            }
            self.queue_alert(1, .close_notify);
            self.wipe_secrets();
            self.state = .closed;
            return .closed;
        }
        diag.raise(.E0813);
        diag.cause("the client sent the fatal alert {s} ({d})", .{ wire.alert_name(code), code });
        add_fix(diag, .E0813);
        return self.refuse(diag, null);
    }

    // ---- Handshake messages -------------------------------------------------------------------

    fn on_handshake_bytes(self: *Server, diag: *Diag, content: []const u8) Error!Event {
        const room = constants.tls_handshake_flight_bytes_max - self.flight_length;
        if (content.len > room) {
            return self.fail(diag, .E0813, .decode_error, "the client's handshake is over {d} B", .{
                constants.tls_handshake_flight_bytes_max,
            });
        }
        @memcpy(self.flight[self.flight_length..][0..content.len], content);
        self.flight_length += @intCast(content.len);
        var event: Event = .none;
        while (self.flight_length >= 4) {
            const body_length = std.mem.readInt(u24, self.flight[1..4], .big);
            // Widened first: a u24 length of 0xFFFFFD or more overflows `4 + body_length`.
            const total: u32 = 4 + @as(u32, body_length);
            if (total > constants.tls_handshake_message_bytes_max) {
                return self.fail(
                    diag,
                    .E0813,
                    .decode_error,
                    "the client's {s} of {d} bytes is over the {d} B this server reads",
                    .{
                        message_name(self.flight[0]),
                        total,
                        constants.tls_handshake_message_bytes_max,
                    },
                );
            }
            if (self.flight_length < total) break;
            const kind = self.flight[0];
            const keys_change = self.changes_keys(kind);
            const message_event = try self.on_message(diag, kind, total);
            if (message_event != .none) event = message_event;
            std.mem.copyForwards(u8, &self.flight, self.flight[total..self.flight_length]);
            self.flight_length -= total;
            if (keys_change and self.flight_length != 0 and !fault_on(.key_change_boundary)) {
                // The bytes behind a key change belong under the new keys, not this record.
                return self.fail(
                    diag,
                    .E0813,
                    .unexpected_message,
                    "handshake data follows a key change in the same record",
                    .{},
                );
            }
        }
        return event;
    }

    /// Whether the message just read moves the read direction to new keys, so nothing may
    /// follow it in the record that carried it.
    fn changes_keys(self: *const Server, kind: u8) bool {
        return switch (self.state) {
            .wait_client_hello, .wait_finished => true,
            .connected => kind == wire.handshake_key_update,
            else => false,
        };
    }

    fn on_message(self: *Server, diag: *Diag, kind: u8, total: u32) Error!Event {
        const message = self.flight[0..total];
        switch (self.state) {
            .wait_client_hello => try self.on_client_hello(diag, kind, message),
            .wait_certificate => try self.on_certificate(diag, kind, message),
            .wait_certificate_verify => try self.on_certificate_verify(diag, kind, message),
            .wait_finished => return self.on_finished(diag, kind, message),
            .connected => try self.on_post_handshake(diag, kind, message[4..]),
            .closed, .failed => unreachable, // `receive` returns before reading.
        }
        return .none;
    }

    fn expect_kind(self: *Server, diag: *Diag, kind: u8, wanted: u8, name: []const u8) Error!void {
        if (kind == wanted) return;
        return self.fail(
            diag,
            .E0813,
            .unexpected_message,
            "expected {s} from the client, got handshake type {d}",
            .{ name, kind },
        );
    }

    fn on_client_hello(self: *Server, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_client_hello, "ClientHello");
        const hello = wire.parse_client_hello(message[4..]) catch |err|
            return self.wire_failure(diag, err, "ClientHello");
        if (hello.early_data) {
            return self.fail(
                diag,
                .E0818,
                .illegal_parameter,
                "the client offers early data; this server takes none",
                .{},
            );
        }
        self.transcript.add(message);
        var shared = X25519.scalarmult(self.secret, hello.public_key) catch {
            return self.fail(
                diag,
                .E0813,
                .illegal_parameter,
                "the client's key share is a low-order point",
                .{},
            );
        };
        defer std.crypto.secureZero(u8, &shared);
        std.crypto.secureZero(u8, &self.secret);
        var hello_buffer: [wire.server_hello_bytes_max]u8 = undefined;
        const session_id = hello.session_id;
        const server_hello =
            wire.write_server_hello(&hello_buffer, &self.random, session_id, &self.public_key);
        self.transcript.add(server_hello);
        const hello_hash = self.transcript.hash();
        var secrets = self.schedule.to_handshake(&shared, &hello_hash) catch {
            return self.fail(
                diag,
                .E0813,
                .illegal_parameter,
                "the key exchange produced an all-zero secret",
                .{},
            );
        };
        defer std.crypto.secureZero(u8, &secrets.client);
        defer std.crypto.secureZero(u8, &secrets.server);
        assert(self.out_length == 0);
        const record = schedule.write_plain(&self.out, .handshake, 0x0303, server_hello);
        self.out_length = @intCast(record.len);
        if (hello.session_id.len > 0) {
            // Compatibility mode (RFC 8446 appendix D.4): the client sent a session id.
            const rest = self.out[self.out_length..];
            const ccs = schedule.write_plain(rest, .change_cipher_spec, 0x0303, &.{1});
            self.out_length += @intCast(ccs.len);
        }
        self.read = schedule.Direction.init(&secrets.client);
        self.write = schedule.Direction.init(&secrets.server);
        self.read_protected = true;
        try self.send_flight(diag);
        self.state = .wait_certificate;
    }

    /// EncryptedExtensions, CertificateRequest, Certificate, CertificateVerify and Finished in one
    /// record under the server's handshake keys; then the write side moves to the application
    /// keys, and the client's application secret waits for the client's Finished.
    fn send_flight(self: *Server, diag: *Diag) Error!void {
        var content: [flight_content_bytes_max]u8 = undefined;
        defer std.crypto.secureZero(u8, &content);
        var length: u32 = 0;
        length += self.append(&content, length, &wire.encrypted_extensions_message);
        length += self.append(&content, length, &wire.certificate_request_message);
        var chain: [constants.tls_chain_certificates_max][]const u8 = undefined;
        for (0..self.identity_count) |index| {
            chain[index] = self.identity[index][0..self.identity_lengths[index]];
        }
        const chain_used = chain[0..self.identity_count];
        const certificate = wire.write_certificate(content[length..], chain_used);
        self.transcript.add(certificate);
        length += @intCast(certificate.len);
        const certificate_hash = self.transcript.hash();
        const verify_content = schedule.certificate_verify_content(.server, &certificate_hash);
        const signature = self.signer.sign(self.signer.context, &verify_content) orelse {
            return self.fail(
                diag,
                .E0820,
                .internal_error,
                "the signer holding the server certificate's key did not sign",
                .{},
            );
        };
        length += self.append(&content, length, &wire.write_certificate_verify(&signature));
        const verify_hash = self.transcript.hash();
        var verify_data = schedule.finished_verify_data(&self.write.secret, &verify_hash);
        defer std.crypto.secureZero(u8, &verify_data);
        const finished_header = [4]u8{ wire.handshake_finished, 0, 0, schedule.hash_bytes };
        @memcpy(content[length..][0..4], &finished_header);
        @memcpy(content[length + 4 ..][0..schedule.hash_bytes], &verify_data);
        self.transcript.add(content[length..][0 .. 4 + schedule.hash_bytes]);
        length += 4 + schedule.hash_bytes;
        assert(length <= flight_content_bytes_max);
        const into = self.out[self.out_length..];
        const sealed = self.write.seal(into, .handshake, content[0..length]) catch |err|
            return self.record_failure(diag, err);
        self.out_length += @intCast(sealed.len);
        const finished_hash = self.transcript.hash();
        var application = self.schedule.to_application(&finished_hash);
        defer std.crypto.secureZero(u8, &application.client);
        defer std.crypto.secureZero(u8, &application.server);
        self.write = schedule.Direction.init(&application.server);
        self.read_next = application.client;
        assert(self.out_length <= output_bytes_max);
    }

    /// Copies a whole handshake message into the flight, adds it to the transcript, and returns
    /// its length.
    fn append(self: *Server, content: []u8, at: u32, message: []const u8) u32 {
        assert(message.len >= 4);
        @memcpy(content[at..][0..message.len], message);
        self.transcript.add(message);
        return @intCast(message.len);
    }

    fn on_certificate(self: *Server, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_certificate, "Certificate");
        if (wire.certificate_is_empty(message[4..])) {
            if (!fault_on(.required_certificate)) return self.fail_no_certificate(diag);
            self.transcript.add(message);
            self.state = .wait_finished;
            return;
        }
        const chain = wire.parse_certificate(message[4..]) catch |err| switch (err) {
            error.ChainShape => return self.fail(
                diag,
                .E0810,
                .bad_certificate,
                "the client sent more than {d} certificates",
                .{constants.tls_chain_certificates_max},
            ),
            else => return self.wire_failure(diag, err, "Certificate"),
        };
        var detail: x509.Detail = .{};
        const parsed = self.verify_client(chain.leaf, &detail) catch |err| {
            x509.raise(diag, err, "the client", &detail);
            return self.refuse(diag, tls_client.certificate_alert(err));
        };
        assert(parsed.public_key.of(chain.leaf).len == 32);
        self.leaf_key = parsed.public_key.of(chain.leaf)[0..32].*;
        const name = parsed.name.of(chain.leaf);
        assert(name.len <= peer_name_bytes_max);
        @memcpy(self.peer_name[0..name.len], name);
        self.peer_name_length = @intCast(name.len);
        self.peer_kind = parsed.kind;
        self.peer_scope = if (parsed.kind == .client) parsed.scope(chain.leaf) else null;
        if (!fault_on(.transcript_client_auth)) self.transcript.add(message);
        self.state = .wait_certificate_verify;
    }

    /// The client's leaf against the cluster CA, the window and the configured kind. The faults
    /// take what the check would refuse.
    fn verify_client(
        self: *const Server,
        leaf: []const u8,
        detail: *x509.Detail,
    ) x509.Error!x509.Parsed {
        const kind = self.expected_kind(leaf);
        const expect: x509.Expect = .{ .kind = kind, .name = null };
        detail.kinds_expected = self.client_kinds;
        const now = self.now_ms;
        const parsed = x509.verify_detailed(leaf, self.anchor, now, expect, detail) catch |err| {
            if (fault_on(.client_chain)) return x509.parse(leaf);
            if (err == error.WrongUse and fault_on(.client_kind)) return x509.parse(leaf);
            return err;
        };
        if (!fault_on(.client_kind)) {
            if (!fault_on(.client_chain)) assert(parsed.kind == kind);
        }
        return parsed;
    }

    /// The kind the leaf is checked against: its own when the server takes it, else the first
    /// the server takes, so the check refuses it (ZC-E0819 names every kind taken). One check
    /// against the set, not one handshake per kind.
    fn expected_kind(self: *const Server, leaf: []const u8) x509.Kind {
        const parsed = x509.parse(leaf) catch return first_kind(self.client_kinds);
        if (self.client_kinds.contains(parsed.kind)) return parsed.kind;
        return first_kind(self.client_kinds);
    }

    fn fail_no_certificate(self: *Server, diag: *Diag) Error {
        diag.raise(.E0814);
        diag.cause(
            "the client sent no certificate; this server requires one from the cluster CA",
            .{},
        );
        add_fix(diag, .E0814);
        return self.refuse(diag, .certificate_required);
    }

    fn on_certificate_verify(self: *Server, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_certificate_verify, "CertificateVerify");
        const signature = wire.parse_certificate_verify(message[4..]) catch |err|
            return self.wire_failure(diag, err, "CertificateVerify");
        // The signature covers the transcript up to and including Certificate, so it is checked
        // before this message joins the transcript.
        const hash = self.transcript.hash();
        const role: schedule.CertificateRole = if (fault_on(.verify_context)) .server else .client;
        const content = schedule.certificate_verify_content(role, &hash);
        if (!fault_on(.certificate_verify)) {
            if (!tls_client.ed25519_verifies(&self.leaf_key, &content, signature)) {
                return self.fail(
                    diag,
                    .E0813,
                    .decrypt_error,
                    "the client's CertificateVerify does not verify against its certificate's key",
                    .{},
                );
            }
        }
        if (!fault_on(.transcript_client_auth)) self.transcript.add(message);
        self.authenticated = true;
        self.state = .wait_finished;
    }

    fn on_finished(self: *Server, diag: *Diag, kind: u8, message: []const u8) Error!Event {
        try self.expect_kind(diag, kind, wire.handshake_finished, "Finished");
        const hash = self.transcript.hash();
        if (!fault_on(.finished)) {
            if (!schedule.finished_matches(&self.read.secret, &hash, message[4..])) {
                return self.fail(
                    diag,
                    .E0813,
                    .decrypt_error,
                    "the client's Finished does not verify: the handshake was altered " ++
                        "or the client lacks the keys",
                    .{},
                );
            }
        }
        self.read = schedule.Direction.init(&self.read_next);
        std.crypto.secureZero(u8, &self.read_next);
        self.state = .connected;
        return .connected;
    }

    fn on_post_handshake(self: *Server, diag: *Diag, kind: u8, body: []const u8) Error!void {
        if (kind != wire.handshake_key_update) {
            return self.fail(
                diag,
                .E0813,
                .unexpected_message,
                "the client sent handshake type {d} after the handshake",
                .{kind},
            );
        }
        const requested = wire.parse_key_update(body) catch |err|
            return self.wire_failure(diag, err, "KeyUpdate");
        self.read.rekey() catch |err| return self.record_failure(diag, err);
        if (!requested) return;
        // Every request is answered with an update of our own write keys, so a peer that keeps
        // asking drives the write limit. That is the client's doing, not this server's.
        if (self.write.updates >= constants.tls_key_updates_per_connection_max) {
            diag.raise(.E0815);
            diag.cause("the write keys reached their limit of {d} updates answering KeyUpdates", .{
                constants.tls_key_updates_per_connection_max,
            });
            add_fix(diag, .E0815);
            return self.refuse(diag, tls_client.record_alert(error.TooManyKeyUpdates));
        }
        try self.send_key_update(false, diag);
    }

    // ---- Failing ------------------------------------------------------------------------------

    fn fail(
        self: *Server,
        diag: *Diag,
        code: Code,
        alert: wire.Alert,
        comptime format: []const u8,
        args: anytype,
    ) Error {
        diag.raise(code);
        diag.cause(format, args);
        add_fix(diag, code);
        return self.refuse(diag, alert);
    }

    fn wire_failure(self: *Server, diag: *Diag, err: wire.Error, message: []const u8) Error {
        const code: Code = switch (err) {
            error.ProtocolVersion, error.CipherSuite, error.Group, error.SignatureScheme => .E0818,
            else => .E0813,
        };
        diag.raise(code);
        switch (err) {
            error.ProtocolVersion => diag.cause("the client does not offer TLS 1.3", .{}),
            error.CipherSuite => diag.cause(
                "the client does not offer TLS_AES_128_GCM_SHA256",
                .{},
            ),
            error.Group => diag.cause("the client sent no x25519 key share", .{}),
            error.SignatureScheme => diag.cause(
                "the client's {s} does not use ed25519",
                .{message},
            ),
            error.HelloRetryRequest => unreachable, // Only a ServerHello is one.
            else => diag.cause("the client's {s} is {s}", .{
                message, tls_client.wire_reason(err),
            }),
        }
        add_fix(diag, code);
        return self.refuse(diag, server_wire_alert(err, message));
    }

    fn record_failure(self: *Server, diag: *Diag, err: schedule.Error) Error {
        assert(err != error.Dead); // A dead direction ends the connection at the first failure.
        diag.raise(.E0815);
        switch (err) {
            error.RecordOverflow => diag.cause("a record is longer than the protocol allows", .{}),
            error.DecodeError => diag.cause(
                "a protected record is too short to hold its type and tag",
                .{},
            ),
            error.BadRecordMac => diag.cause(
                "a record did not authenticate: it was altered, or the keys differ",
                .{},
            ),
            error.UnexpectedMessage => diag.cause(
                "a record of a type that is not allowed here",
                .{},
            ),
            error.KeyLimit => diag.cause("the record counter reached its limit", .{}),
            error.TooManyKeyUpdates => diag.cause("the client updated its keys over {d} times", .{
                constants.tls_key_updates_per_connection_max,
            }),
            error.ZeroSharedSecret => diag.cause(
                "the key exchange produced an all-zero secret",
                .{},
            ),
            error.Dead => unreachable,
        }
        add_fix(diag, .E0815);
        return self.refuse(diag, tls_client.record_alert(err));
    }

    /// Ends the connection: queues the alert (if any), wipes every secret and the record buffer,
    /// and stops all further input and output. Always returns `error.Refused`.
    fn refuse(self: *Server, diag: *Diag, alert: ?wire.Alert) Error {
        self.out_length = 0;
        if (alert) |description| {
            self.queue_alert(wire.alert_level_fatal, description);
            if (self.out_length > 0) {
                diag.context("sent", "alert {s} ({d})", .{
                    @tagName(description), @backingInt(description),
                });
            }
        }
        self.wipe_secrets();
        self.state = .failed;
        assert(self.read.dead);
        assert(self.write.dead);
        return error.Refused;
    }

    fn fail_silently(self: *Server) void {
        self.out_length = 0;
        self.wipe_secrets();
        self.state = .failed;
    }

    fn wipe_secrets(self: *Server) void {
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.leaf_key);
        std.crypto.secureZero(u8, &self.read_next);
        std.crypto.secureZero(u8, &self.record);
        std.crypto.secureZero(u8, &self.flight);
        self.schedule.wipe();
        self.read.wipe();
        self.write.wipe();
        self.record_length = 0;
        self.record_total = 0;
        self.flight_length = 0;
    }

    /// An alert goes out under the write keys once there are any; before the ServerHello it is
    /// plain. After a refusal of the ClientHello the client has no keys, so it is plain too.
    fn queue_alert(self: *Server, level: u8, alert: wire.Alert) void {
        const content = [2]u8{ level, @backingInt(alert) };
        self.out_length = 0;
        if (!self.write.dead) {
            const sealed = self.write.seal(self.out[0..], .alert, &content) catch return;
            self.out_length = @intCast(sealed.len);
        } else {
            const record = schedule.write_plain(&self.out, .alert, 0x0303, &content);
            self.out_length = @intCast(record.len);
        }
        assert(self.out_length <= output_bytes_max);
    }
};

/// A refused ClientHello offers what this server does not take: a handshake failure, or a
/// protocol version alert for a client that does not speak TLS 1.3 (RFC 8446 section 4.2.1).
fn server_wire_alert(err: wire.Error, message: []const u8) wire.Alert {
    if (std.mem.eql(u8, message, "ClientHello")) {
        switch (err) {
            error.CipherSuite, error.Group, error.SignatureScheme => return .handshake_failure,
            error.MissingExtension => return .missing_extension,
            else => {},
        }
    }
    return tls_client.wire_alert(err);
}

fn first_kind(kinds: x509.Kinds) x509.Kind {
    var copy = kinds;
    var iterator = copy.iterator();
    return iterator.next().?; // `init` asserts the set is not empty.
}

fn message_name(kind: u8) []const u8 {
    if (kind == wire.handshake_client_hello) return "ClientHello";
    return tls_client.message_name(kind);
}

/// The fix line: the server's side of each code. The other end is a client of this cluster, so
/// the fix names what it must bring.
fn add_fix(diag: *Diag, code: Code) void {
    const sentence = switch (code) {
        .E0810, .E0813, .E0818 => "Check that the client is a zcube workload or node of this " ++
            "cluster, offering TLS 1.3 with x25519, TLS_AES_128_GCM_SHA256 and an Ed25519 " ++
            "certificate from the cluster CA.",
        .E0814 => "Give the client a certificate from this cluster's CA (zcube issues one to " ++
            "each workload); this server requires one.",
        .E0815 => "Reconnect; if it repeats, check the network path between the two machines.",
        .E0816 => "The client went away mid-connection; if it repeats, check the client and " ++
            "the network path to it.",
        .E0820 => "Check that the process or device holding this server's key is running and " ++
            "reachable, then restart the server.",
        else => unreachable,
    };
    diag.fix(.{ .sentence = sentence });
}
