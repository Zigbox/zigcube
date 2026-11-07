//! The TLS 1.3 client handshake (docs/briefs/mtls-client.md, slices 4 and 5): ClientHello to
//! Finished, pinning the server's certificate against the cluster CA, and answering a server's
//! `CertificateRequest` with the caller's workload certificate and a signature made by a callback.
//! A pure state machine: bytes in, bytes out, one event per step. It opens no socket and reads
//! no clock or random source; the shell passes in the randomness, the x25519 secret and the time.
//!
//! The cuts, recorded in docs/decisions/2026-11-05-tls-client-part-1.md and -part-2.md:
//!   - Post-handshake authentication is never offered, so a later `CertificateRequest` is refused.
//!   - `seal_application` starts a KeyUpdate itself when the write keys reach their record limit.
//!     A received KeyUpdate is answered when it asks.
//!   - The server name is a DNS name (the foreign-server profile is not wired here).
//!
//! The rules the code keeps, from the slice 3 handoff: a plaintext change_cipher_spec is dropped
//! before `open` ever sees it; a failed `open` wipes the record buffer and the keys; a received
//! KeyUpdate rekeys the receive direction; after a fatal error nothing more is produced.
//!
//! Core code: no allocation, no clock, no randomness, no I/O.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const schedule = @import("tls_schedule.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");

const Diag = diag_mod.Diag;
const Code = @import("diag/codes.zig").Code;
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;

const header_bytes: u32 = constants.tls_record_header_bytes;

pub const Error = error{
    /// The connection failed: the diagnostic is raised and an alert may be waiting in `output`.
    Refused,
    /// The connection is over (failed or closed); nothing more is read or produced.
    Closed,
};

pub const Config = struct {
    /// The pinned CA public key.
    anchor: [32]u8,
    /// The DNS name connected to: sent as `server_name` and compared to the certificate.
    server_name: []const u8,
    now_ms: u64,
    random: [32]u8,
    session_id: [32]u8,
    /// The ephemeral x25519 secret.
    secret: [32]u8,
    client_auth: ClientAuth = .none,
};

/// Whether and how the client authenticates. A required authentication always has an identity, so
/// the state "required, with nothing to present" cannot be written.
pub const ClientAuth = union(enum) {
    /// Server authentication only: a request is answered with an empty Certificate.
    none,
    /// Presents the identity when the server asks; a server that does not ask is not an error.
    optional: Identity,
    /// Presents the identity, and fails (ZC-E0814) if the server does not ask for it.
    required: Identity,
};

/// Signs `message` with the key of the identity's certificate: Ed25519, 64 bytes. Null means the
/// signer failed (a key behind a boundary that did not answer). The key never enters the client.
pub const Signer = struct {
    context: *const anyopaque,
    sign: *const fn (context: *const anyopaque, message: []const u8) ?[64]u8,
};

pub const Identity = struct {
    /// DER certificates, the workload's first and optionally the CA's after it. Copied by `init`.
    certificates: []const []const u8,
    signer: Signer,
};

/// A `Signer` for a key pair the caller holds; `key_pair` must outlive the connection.
pub fn key_pair_signer(key_pair: *const Ed25519.KeyPair) Signer {
    return .{ .context = key_pair, .sign = sign_with_key_pair };
}

fn sign_with_key_pair(context: *const anyopaque, message: []const u8) ?[64]u8 {
    const key_pair: *const Ed25519.KeyPair = @ptrCast(@alignCast(context));
    const signature = key_pair.sign(message, null) catch return null;
    return signature.toBytes();
}

pub const Event = union(enum) {
    none,
    /// The handshake is done: the server's Finished verified, application keys are live.
    connected,
    /// Application data, in the client's record buffer; valid until the next `receive`.
    data: []const u8,
    /// The peer sent close_notify.
    closed,
};

pub const Step = struct { consumed: u32, event: Event };

const State = enum {
    idle,
    wait_server_hello,
    wait_encrypted_extensions,
    wait_certificate,
    wait_certificate_verify,
    wait_finished,
    connected,
    closed,
    failed,
};

/// Test-only faults for the teeth tests: each skips one security check. Compiled out of every
/// build but a test, as `x509.set_test_fault` is.
pub const TestFault = enum {
    certificate_verify,
    finished,
    transcript_encrypted_extensions,
    /// The client sends no Certificate when the server never asked and it was required.
    required_client_auth,
    /// The client answers a request that does not list Ed25519.
    request_scheme,
    /// A server's certificate alert is reported as a plain E0813.
    certificate_alert,
    /// The client's Certificate and CertificateVerify stay out of its own transcript.
    transcript_client_auth,
    /// The client signs with the server's context string.
    verify_context,
    /// The client sends an empty request context.
    echo_context,
    /// The client's Finished leaves its Certificate and CertificateVerify out of its hash.
    finished_omits_auth,
};
var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

pub const Client = struct {
    state: State,
    anchor: [32]u8,
    now_ms: u64,
    name: [constants.tls_server_name_bytes_max]u8,
    name_length: u32,
    session_id: [32]u8,
    secret: [32]u8,
    public_key: [32]u8,
    random: [32]u8,
    schedule: schedule.Schedule,
    transcript: schedule.Transcript,
    read: schedule.Direction,
    write: schedule.Direction,
    read_protected: bool,
    write_protected: bool,
    ccs_dropped: u32,
    leaf_key: [32]u8,
    identity: [constants.tls_chain_certificates_max][constants.x509_cert_bytes_max]u8,
    identity_lengths: [constants.tls_chain_certificates_max]u32,
    identity_count: u32,
    signer: ?Signer,
    require_auth: bool,
    /// The server sent a CertificateRequest; its context is held for the echo.
    request_seen: bool,
    /// The request can be answered with the identity: it lists Ed25519.
    request_answerable: bool,
    request_context: [constants.tls_request_context_bytes_max]u8,
    request_context_length: u32,
    /// A Certificate message, empty or not, went to the server: a certificate alert after it is
    /// the server's answer to what the client showed (ZC-E0814), not a broken handshake.
    certificate_sent: bool,
    record: [schedule.sealed_bytes_max]u8,
    record_length: u32,
    record_total: u32,
    flight: [constants.tls_handshake_flight_bytes_max]u8,
    flight_length: u32,
    out: [constants.tls_output_bytes_max]u8,
    out_length: u32,

    /// Sets the client up in place (it is large). `start` makes the ClientHello.
    pub fn init(self: *Client, config: *const Config) void {
        assert(config.server_name.len > 0);
        assert(config.server_name.len <= constants.tls_server_name_bytes_max);
        self.state = .idle;
        self.anchor = config.anchor;
        self.now_ms = config.now_ms;
        self.name_length = @intCast(config.server_name.len);
        @memcpy(self.name[0..config.server_name.len], config.server_name);
        self.session_id = config.session_id;
        self.secret = config.secret;
        self.random = config.random;
        self.public_key = X25519.recoverPublicKey(config.secret);
        self.schedule = schedule.Schedule.init();
        self.transcript = schedule.Transcript.init();
        self.read_protected = false;
        self.write_protected = false;
        self.ccs_dropped = 0;
        self.record_length = 0;
        self.record_total = 0;
        self.flight_length = 0;
        self.out_length = 0;
        self.leaf_key = @splat(0);
        self.init_identity(config);
        self.read.wipe();
        self.write.wipe();
        assert(self.read.dead);
        assert(self.write.dead);
    }

    fn init_identity(self: *Client, config: *const Config) void {
        self.identity_count = 0;
        self.identity_lengths = @splat(0);
        self.signer = null;
        self.require_auth = config.client_auth == .required;
        self.request_seen = false;
        self.request_answerable = false;
        self.request_context_length = 0;
        self.certificate_sent = false;
        const presented: ?Identity = switch (config.client_auth) {
            .none => null,
            .optional, .required => |identity| identity,
        };
        if (presented) |identity| {
            assert(identity.certificates.len >= 1);
            assert(identity.certificates.len <= constants.tls_chain_certificates_max);
            for (identity.certificates, 0..) |certificate, index| {
                assert(certificate.len > 0);
                assert(certificate.len <= constants.x509_cert_bytes_max);
                @memcpy(self.identity[index][0..certificate.len], certificate);
                self.identity_lengths[index] = @intCast(certificate.len);
            }
            self.identity_count = @intCast(identity.certificates.len);
            self.signer = identity.signer;
        }
        if (self.require_auth) assert(self.identity_count > 0);
    }

    /// Makes the ClientHello record; the caller sends `output()` and calls `drain`.
    pub fn start(self: *Client) void {
        assert(self.state == .idle);
        assert(self.out_length == 0);
        const input: wire.HelloInput = .{
            .random = self.random,
            .session_id = self.session_id,
            .public_key = self.public_key,
            .server_name = self.name[0..self.name_length],
        };
        const message = wire.write_client_hello(&self.flight, &input);
        self.transcript.add(message);
        const record = schedule.write_plain(&self.out, .handshake, 0x0301, message);
        self.out_length = @intCast(record.len);
        self.state = .wait_server_hello;
        assert(self.out_length <= constants.tls_client_hello_bytes_max);
    }

    /// What is ready to send. The caller sends it all and calls `drain` before the next step.
    pub fn output(self: *const Client) []const u8 {
        return self.out[0..self.out_length];
    }

    pub fn drain(self: *Client) void {
        self.out_length = 0;
    }

    pub fn is_connected(self: *const Client) bool {
        return self.state == .connected;
    }

    /// How many more bytes complete the record being read: 0 once the connection is over.
    pub fn wants(self: *const Client) u32 {
        switch (self.state) {
            .closed, .failed, .idle => return 0,
            else => {},
        }
        if (self.record_length < header_bytes) return header_bytes - self.record_length;
        assert(self.record_total >= header_bytes);
        assert(self.record_total > self.record_length);
        return self.record_total - self.record_length;
    }

    /// Takes at most `wants()` bytes of `input` and, when a record is complete, acts on it. The
    /// output of the previous step must have been drained.
    pub fn receive(self: *Client, input: []const u8, diag: *Diag) Error!Step {
        assert(self.out_length == 0);
        assert(input.len > 0);
        switch (self.state) {
            .closed, .failed => return error.Closed,
            .idle => unreachable, // `start` comes first.
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
    pub fn end_of_input(self: *Client, diag: *Diag) Error!void {
        if (self.state == .closed) return;
        if (self.state == .failed) return error.Closed;
        assert(self.state != .idle);
        if (self.state == .connected) {
            diag.raise(.E0816);
            diag.cause("the server's connection ended without close_notify", .{});
        } else {
            diag.raise(.E0816);
            diag.cause("the server's connection ended before the handshake finished", .{});
        }
        self.add_fix(diag, .E0816);
        return self.refuse(diag, null);
    }

    // ---- Sending ------------------------------------------------------------------------------

    /// The most bytes `seal_application` writes for `plain_length` bytes of data: the record, and
    /// before it a KeyUpdate when the write keys have reached their limit.
    pub fn application_bytes_max(plain_length: usize) usize {
        const key_update = schedule.sealed_bytes(schedule.key_update_bytes);
        return schedule.sealed_bytes(plain_length) + key_update;
    }

    /// Protects application data as one record into `out` and returns what to send. When the
    /// write keys are at their record limit the KeyUpdate goes first, in the same slice, so the
    /// caller needs no other step to stay inside the limit (RFC 8446 section 5.5). A direction
    /// that cannot move on is a refusal with a diagnostic (ZC-E0815). The caller has sent
    /// `output()` first: an answer queued by `receive` is sealed under the keys from before.
    pub fn seal_application(
        self: *Client,
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
    pub fn close_notify(self: *Client) void {
        assert(self.state == .connected);
        assert(self.out_length == 0); // The caller drained the last step's output.
        self.queue_alert(1, .close_notify);
        self.wipe_secrets();
        self.state = .closed;
    }

    /// Sends a KeyUpdate and moves the write keys on (RFC 8446 section 4.6.3). `seal_application`
    /// does it by itself at the limit; a connection layer may also call it to rotate keys sooner.
    pub fn send_key_update(self: *Client, request: bool, diag: *Diag) Error!void {
        assert(self.state == .connected);
        assert(self.out_length == 0);
        const sealed = try self.seal_key_update(self.out[0..], request, diag);
        self.out_length = @intCast(sealed);
    }

    /// Seals a KeyUpdate under the old keys into `out`, moves on, and returns its length.
    fn seal_key_update(self: *Client, out: []u8, request: bool, diag: *Diag) Error!usize {
        const message = [_]u8{ schedule.key_update_type, 0, 0, 1, @intFromBool(request) };
        const sealed = self.write.seal(out, .handshake, &message) catch |err|
            return self.fail_send(diag, err);
        self.write.rekey() catch |err| return self.fail_send(diag, err);
        return sealed.len;
    }

    /// The write side cannot go on. A dead direction means the connection is already over and
    /// diagnosed; the other two are the limits of the write keys.
    fn fail_send(self: *Client, diag: *Diag, err: schedule.Error) Error {
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
            diag.cause("this client updated its write keys over {d} times", .{
                constants.tls_key_updates_per_connection_max,
            });
        }
        self.add_fix(diag, .E0815);
        return self.refuse(diag, null);
    }

    // ---- Records ------------------------------------------------------------------------------

    fn frame_record(self: *Client, diag: *Diag) Error!void {
        assert(self.record_length >= header_bytes);
        assert(self.record_total == 0);
        const protection: schedule.Protection = if (self.read_protected) .protected else .plain;
        const header = schedule.Header.parse(self.record[0..header_bytes], protection) catch |err|
            return self.record_failure(diag, err);
        self.record_total = header_bytes + header.length;
        assert(self.record_total <= schedule.sealed_bytes_max);
    }

    fn dispatch(self: *Client, diag: *Diag) Error!Event {
        const protection: schedule.Protection = if (self.read_protected) .protected else .plain;
        const header = schedule.Header.parse(self.record[0..header_bytes], protection) catch
            unreachable; // `frame_record` parsed the same bytes.
        const body = self.record[header_bytes..self.record_total];
        assert(body.len == header.length);
        if (header.content_type == .change_cipher_spec) return self.on_change_cipher_spec(diag);
        if (!self.read_protected) return self.on_plain(diag, header.content_type);
        if (header.content_type != .application_data) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
        const opened = self.read.open(self.record[0..self.record_total]) catch |err|
            return self.record_failure(diag, err);
        return self.on_content(diag, opened.content_type, opened.content);
    }

    fn on_plain(self: *Client, diag: *Diag, kind: schedule.ContentType) Error!Event {
        assert(!self.read_protected);
        const body = self.record[header_bytes..self.record_total];
        if (self.state != .wait_server_hello) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
        if (body.len == 0) return self.record_failure(diag, error.UnexpectedMessage);
        // An alert between two halves of a ServerHello is not a server speaking cleanly.
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
        self: *Client,
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
                if (self.state != .connected) {
                    return self.record_failure(diag, error.UnexpectedMessage);
                }
                return .{ .data = content };
            },
            .change_cipher_spec => return self.record_failure(diag, error.UnexpectedMessage),
        }
    }

    /// RFC 8446 appendix D.4: a server in compatibility mode sends one plaintext
    /// change_cipher_spec after its ServerHello. It is dropped here, never passed to `open`.
    fn on_change_cipher_spec(self: *Client, diag: *Diag) Error!Event {
        const body = self.record[header_bytes..self.record_total];
        switch (self.state) {
            .wait_encrypted_extensions, .wait_certificate => {},
            .wait_certificate_verify, .wait_finished => {},
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

    fn on_alert(self: *Client, diag: *Diag, content: []const u8) Error!Event {
        if (content.len != 2) {
            return self.fail(diag, .E0813, .decode_error, "the server sent a malformed alert", .{});
        }
        // The level (content[0]) is ignored on purpose: in TLS 1.3 every alert but close_notify
        // (and user_canceled) ends the connection whatever its level (RFC 8446 section 6).
        const code = content[1];
        if (code == @backingInt(wire.Alert.close_notify)) {
            if (self.state != .connected) {
                diag.raise(.E0816);
                diag.cause("the server closed the connection before the handshake finished", .{});
                self.add_fix(diag, .E0816);
                return self.refuse(diag, null);
            }
            self.queue_alert(1, .close_notify);
            self.wipe_secrets();
            self.state = .closed;
            return .closed;
        }
        if (self.certificate_sent and refuses_certificate(code) and !fault_on(.certificate_alert)) {
            return self.fail_refused(diag, code);
        }
        diag.raise(.E0813);
        diag.cause("the server sent the fatal alert {s} ({d})", .{ wire.alert_name(code), code });
        self.add_fix(diag, .E0813);
        return self.refuse(diag, null);
    }

    // ---- Handshake messages -------------------------------------------------------------------

    fn on_handshake_bytes(self: *Client, diag: *Diag, content: []const u8) Error!Event {
        const room = constants.tls_handshake_flight_bytes_max - self.flight_length;
        if (content.len > room) {
            return self.fail(diag, .E0813, .decode_error, "the server's handshake is over {d} B", .{
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
                    "the server's {s} of {d} bytes is over the {d} B this client reads",
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
            if (keys_change and self.flight_length != 0) {
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

    /// Whether the message just read moves a direction to new keys, so nothing may follow it in
    /// the record that carried it.
    fn changes_keys(self: *const Client, kind: u8) bool {
        return switch (self.state) {
            .wait_server_hello, .wait_finished => true,
            .connected => kind == wire.handshake_key_update,
            else => false,
        };
    }

    fn on_message(self: *Client, diag: *Diag, kind: u8, total: u32) Error!Event {
        const message = self.flight[0..total];
        const body = message[4..];
        switch (self.state) {
            .wait_server_hello => try self.on_server_hello(diag, kind, message),
            .wait_encrypted_extensions => try self.on_encrypted_extensions(diag, kind, message),
            .wait_certificate => try self.on_certificate(diag, kind, message),
            .wait_certificate_verify => try self.on_certificate_verify(diag, kind, message),
            .wait_finished => return self.on_finished(diag, kind, message),
            .connected => try self.on_post_handshake(diag, kind, body),
            else => unreachable,
        }
        return .none;
    }

    fn expect_kind(self: *Client, diag: *Diag, kind: u8, wanted: u8, name: []const u8) Error!void {
        if (kind == wanted) return;
        return self.fail(
            diag,
            .E0813,
            .unexpected_message,
            "expected {s} from the server, got handshake type {d}",
            .{ name, kind },
        );
    }

    fn on_server_hello(self: *Client, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_server_hello, "ServerHello");
        const hello = wire.parse_server_hello(message[4..], &self.session_id) catch |err|
            return self.wire_failure(diag, err, "ServerHello");
        self.transcript.add(message);
        var shared = X25519.scalarmult(self.secret, hello.public_key) catch {
            return self.fail(
                diag,
                .E0813,
                .illegal_parameter,
                "the server's key share is a low-order point",
                .{},
            );
        };
        defer std.crypto.secureZero(u8, &shared);
        std.crypto.secureZero(u8, &self.secret);
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
        self.read = schedule.Direction.init(&secrets.server);
        self.write = schedule.Direction.init(&secrets.client);
        self.read_protected = true;
        self.write_protected = true;
        self.state = .wait_encrypted_extensions;
    }

    fn on_encrypted_extensions(
        self: *Client,
        diag: *Diag,
        kind: u8,
        message: []const u8,
    ) Error!void {
        try self.expect_kind(
            diag,
            kind,
            wire.handshake_encrypted_extensions,
            "EncryptedExtensions",
        );
        wire.parse_encrypted_extensions(message[4..]) catch |err|
            return self.wire_failure(diag, err, "EncryptedExtensions");
        if (!fault_on(.transcript_encrypted_extensions)) self.transcript.add(message);
        self.state = .wait_certificate;
    }

    fn on_certificate(self: *Client, diag: *Diag, kind: u8, message: []const u8) Error!void {
        if (kind == wire.handshake_certificate_request and !self.request_seen) {
            return self.on_certificate_request(diag, message);
        }
        if (kind == wire.handshake_certificate and self.require_auth and !self.request_seen) {
            if (!fault_on(.required_client_auth)) return self.fail_not_asked(diag);
        }
        try self.expect_kind(diag, kind, wire.handshake_certificate, "Certificate");
        const chain = wire.parse_certificate(message[4..]) catch |err| switch (err) {
            error.ChainShape => return self.fail_chain(diag),
            else => return self.wire_failure(diag, err, "Certificate"),
        };
        const name = self.name[0..self.name_length];
        var detail: x509.Detail = .{};
        const parsed = x509.verify_detailed(chain.leaf, self.anchor, self.now_ms, .{
            .kind = .server,
            .name = name,
        }, &detail) catch |err| {
            x509.raise(diag, err, name, &detail);
            return self.refuse(diag, certificate_alert(err));
        };
        assert(parsed.public_key.of(chain.leaf).len == 32);
        self.leaf_key = parsed.public_key.of(chain.leaf)[0..32].*;
        self.transcript.add(message);
        self.state = .wait_certificate_verify;
    }

    /// CertificateRequest (RFC 8446 section 4.3.2): remembers the context for the echo and whether
    /// the identity can answer. A server that asks for something the identity cannot give is
    /// refused when authentication is required, and otherwise answered with an empty Certificate.
    fn on_certificate_request(self: *Client, diag: *Diag, message: []const u8) Error!void {
        const request = wire.parse_certificate_request(message[4..]) catch |err|
            return self.wire_failure(diag, err, "CertificateRequest");
        const answerable = request.accepts_ed25519 or fault_on(.request_scheme);
        if (!answerable and self.require_auth) {
            diag.raise(.E0814);
            diag.cause(
                "the server's certificate request does not list Ed25519, the only scheme " ++
                    "this client signs and presents",
                .{},
            );
            self.fix_e0814(diag, "Configure the server at {s} to accept Ed25519 in " ++
                "signature_algorithms and signature_algorithms_cert for client certificates.");
            return self.refuse(diag, .handshake_failure);
        }
        self.transcript.add(message);
        self.request_seen = true;
        self.request_answerable = answerable and self.identity_count > 0;
        assert(request.context.len <= constants.tls_request_context_bytes_max);
        self.request_context_length = @intCast(request.context.len);
        @memcpy(self.request_context[0..request.context.len], request.context);
    }

    fn fail_not_asked(self: *Client, diag: *Diag) Error {
        diag.raise(.E0814);
        diag.cause(
            "the server did not ask for a client certificate, and this connection must " ++
                "present one",
            .{},
        );
        self.fix_e0814(diag, "Check that the server at {s} is configured to request client " ++
            "certificates (needClientAuth on a JVM, -Verify on OpenSSL) and trusts the cluster " ++
            "CA.");
        return self.refuse(diag, .handshake_failure);
    }

    /// The server's certificate alert, after the client's Certificate went out.
    fn fail_refused(self: *Client, diag: *Diag, code: u8) Error {
        diag.raise(.E0814);
        if (self.request_answerable) {
            diag.cause("the server refused the client certificate with the alert {s} ({d})", .{
                wire.alert_name(code), code,
            });
            self.fix_e0814(diag, "Check that the server at {s} trusts the cluster CA, and that " ++
                "this workload's certificate is current and was issued by it.");
        } else {
            diag.cause(
                "the server answered the client's empty Certificate ({s}) with the alert " ++
                    "{s} ({d})",
                .{ self.empty_reason(), wire.alert_name(code), code },
            );
            self.fix_e0814(diag, "Give this connection a workload certificate from the cluster " ++
                "CA that the server at {s} can verify; it requires one.");
        }
        return self.refuse(diag, null);
    }

    fn empty_reason(self: *const Client) []const u8 {
        if (self.identity_count == 0) return "this connection has no workload certificate";
        return "the server's request does not list Ed25519";
    }

    fn fix_e0814(self: *const Client, diag: *Diag, comptime format: []const u8) void {
        var buffer: [constants.tls_server_name_bytes_max + 240]u8 = undefined;
        // The buffer holds the longest name and the longest of the sentences.
        const sentence = std.fmt.bufPrint(&buffer, format, .{
            self.name[0..self.name_length],
        }) catch unreachable; // Sized above for the longest name and sentence.
        diag.fix(.{ .sentence = sentence });
    }

    fn fail_chain(self: *Client, diag: *Diag) Error {
        diag.raise(.E0810);
        diag.cause("the server sent no certificate, or more than {d}", .{
            constants.tls_chain_certificates_max,
        });
        self.add_fix(diag, .E0810);
        return self.refuse(diag, .bad_certificate);
    }

    fn on_certificate_verify(self: *Client, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_certificate_verify, "CertificateVerify");
        const signature = wire.parse_certificate_verify(message[4..]) catch |err|
            return self.wire_failure(diag, err, "CertificateVerify");
        // The signature covers the transcript up to and including Certificate, so it is checked
        // before this message joins the transcript.
        const hash = self.transcript.hash();
        const content = schedule.certificate_verify_content(.server, &hash);
        if (!fault_on(.certificate_verify)) {
            if (!ed25519_verifies(&self.leaf_key, &content, signature)) {
                return self.fail(
                    diag,
                    .E0813,
                    .decrypt_error,
                    "the server's CertificateVerify does not verify against its certificate's key",
                    .{},
                );
            }
        }
        self.transcript.add(message);
        self.state = .wait_finished;
    }

    fn on_finished(self: *Client, diag: *Diag, kind: u8, message: []const u8) Error!Event {
        try self.expect_kind(diag, kind, wire.handshake_finished, "Finished");
        const hash = self.transcript.hash();
        if (!fault_on(.finished)) {
            if (!schedule.finished_matches(&self.read.secret, &hash, message[4..])) {
                return self.fail(
                    diag,
                    .E0813,
                    .decrypt_error,
                    "the server's Finished does not verify: the handshake was altered " ++
                        "or the server lacks the keys",
                    .{},
                );
            }
        }
        self.transcript.add(message);
        // The application keys come from the transcript up to the server's Finished; the client's
        // own messages follow it and are not part of that hash (RFC 8446 section 7.1).
        const finished_hash = self.transcript.hash();
        try self.send_final_flight(diag);
        var application = self.schedule.to_application(&finished_hash);
        defer std.crypto.secureZero(u8, &application.client);
        defer std.crypto.secureZero(u8, &application.server);
        self.read = schedule.Direction.init(&application.server);
        self.write = schedule.Direction.init(&application.client);
        self.state = .connected;
        return .connected;
    }

    /// The compatibility change_cipher_spec, the client's Certificate and CertificateVerify when
    /// the server asked, then the client Finished, all under the handshake keys.
    fn send_final_flight(self: *Client, diag: *Diag) Error!void {
        assert(self.out_length == 0);
        const ccs = schedule.write_plain(&self.out, .change_cipher_spec, 0x0303, &.{1});
        self.out_length = @intCast(ccs.len);
        const server_view = self.transcript;
        if (self.request_seen) try self.send_authentication(diag);
        // Covers the client Certificate and CertificateVerify when they were sent.
        const hash = if (fault_on(.finished_omits_auth))
            server_view.hash()
        else
            self.transcript.hash();
        var verify_data = schedule.finished_verify_data(&self.write.secret, &hash);
        defer std.crypto.secureZero(u8, &verify_data);
        var finished: [4 + schedule.hash_bytes]u8 = undefined;
        finished[0] = wire.handshake_finished;
        std.mem.writeInt(u24, finished[1..4], schedule.hash_bytes, .big);
        @memcpy(finished[4..], &verify_data);
        defer std.crypto.secureZero(u8, &finished);
        try self.seal_handshake(diag, &finished);
        assert(self.out_length <= constants.tls_output_bytes_max);
    }

    fn seal_handshake(self: *Client, diag: *Diag, message: []const u8) Error!void {
        const sealed = self.write.seal(self.out[self.out_length..], .handshake, message) catch |err|
            return self.record_failure(diag, err);
        self.out_length += @intCast(sealed.len);
    }

    /// RFC 8446 section 4.4.2 and 4.4.3: Certificate with the echoed context, and, when there is a
    /// certificate to prove, CertificateVerify over the transcript through that Certificate.
    /// Nothing is sealed until the signer has answered: a signer that fails leaves the write
    /// sequence where the server expects it, so the alert that follows authenticates.
    fn send_authentication(self: *Client, diag: *Diag) Error!void {
        assert(self.request_seen);
        var buffer: [constants.tls_client_certificate_bytes_max]u8 = undefined;
        const certificate = self.certificate_message(&buffer);
        if (!fault_on(.transcript_client_auth)) self.transcript.add(certificate);
        if (!self.request_answerable) {
            try self.seal_handshake(diag, certificate);
            self.certificate_sent = true;
            return;
        }
        const hash = self.transcript.hash();
        const role: schedule.CertificateRole = if (fault_on(.verify_context)) .server else .client;
        const content = schedule.certificate_verify_content(role, &hash);
        const signer = self.signer.?;
        const signature = signer.sign(signer.context, &content) orelse {
            return self.fail(
                diag,
                .E0820,
                .internal_error,
                "the signer holding the client certificate's key did not sign",
                .{},
            );
        };
        var verify: [constants.tls_client_verify_bytes]u8 = undefined;
        verify[0] = wire.handshake_certificate_verify;
        std.mem.writeInt(u24, verify[1..4], 2 + 2 + 64, .big);
        std.mem.writeInt(u16, verify[4..6], wire.scheme_ed25519, .big);
        std.mem.writeInt(u16, verify[6..8], 64, .big);
        @memcpy(verify[8..], &signature);
        if (!fault_on(.transcript_client_auth)) self.transcript.add(&verify);
        try self.seal_handshake(diag, certificate);
        self.certificate_sent = true;
        try self.seal_handshake(diag, &verify);
    }

    /// The Certificate message: the context echoed, and the identity's certificates, or none when
    /// the identity cannot answer this request.
    fn certificate_message(self: *const Client, buffer: []u8) []const u8 {
        assert(buffer.len >= constants.tls_client_certificate_bytes_max);
        const echo = if (fault_on(.echo_context)) 0 else self.request_context_length;
        var length: u32 = 4;
        buffer[length] = @intCast(echo);
        @memcpy(buffer[length + 1 ..][0..echo], self.request_context[0..echo]);
        length += 1 + echo;
        const list_at = length;
        length += 3;
        const count = if (self.request_answerable) self.identity_count else 0;
        for (0..count) |index| {
            const size = self.identity_lengths[index];
            std.mem.writeInt(u24, buffer[length..][0..3], @intCast(size), .big);
            @memcpy(buffer[length + 3 ..][0..size], self.identity[index][0..size]);
            std.mem.writeInt(u16, buffer[length + 3 + size ..][0..2], 0, .big); // No extensions.
            length += 3 + size + 2;
        }
        std.mem.writeInt(u24, buffer[list_at..][0..3], @intCast(length - list_at - 3), .big);
        buffer[0] = wire.handshake_certificate;
        std.mem.writeInt(u24, buffer[1..4], @intCast(length - 4), .big);
        return buffer[0..length];
    }

    fn on_post_handshake(self: *Client, diag: *Diag, kind: u8, body: []const u8) Error!void {
        switch (kind) {
            wire.handshake_new_session_ticket => {
                // No resumption is offered; the ticket is read past and dropped.
                if (body.len == 0) {
                    return self.fail(diag, .E0813, .decode_error, "an empty NewSessionTicket", .{});
                }
            },
            wire.handshake_key_update => try self.on_key_update(diag, body),
            else => return self.fail(
                diag,
                .E0813,
                .unexpected_message,
                "handshake type {d} after the handshake",
                .{kind},
            ),
        }
    }

    fn on_key_update(self: *Client, diag: *Diag, body: []const u8) Error!void {
        const requested = wire.parse_key_update(body) catch |err|
            return self.wire_failure(diag, err, "KeyUpdate");
        self.read.rekey() catch |err| return self.record_failure(diag, err);
        if (!requested) return;
        // Every request is answered with an update of our own write keys, so a peer that keeps
        // asking drives the write limit. That is the server's doing, not this client's.
        if (self.write.updates >= constants.tls_key_updates_per_connection_max) {
            diag.raise(.E0815);
            diag.cause("the server asked for a KeyUpdate over {d} times", .{
                constants.tls_key_updates_per_connection_max,
            });
            self.add_fix(diag, .E0815);
            return self.refuse(diag, record_alert(error.TooManyKeyUpdates));
        }
        try self.send_key_update(false, diag);
    }

    // ---- Failing ------------------------------------------------------------------------------

    fn fail(
        self: *Client,
        diag: *Diag,
        code: Code,
        alert: wire.Alert,
        comptime format: []const u8,
        args: anytype,
    ) Error {
        diag.raise(code);
        diag.cause(format, args);
        self.add_fix(diag, code);
        return self.refuse(diag, alert);
    }

    fn wire_failure(self: *Client, diag: *Diag, err: wire.Error, message: []const u8) Error {
        const code: Code = switch (err) {
            error.HelloRetryRequest, error.ProtocolVersion => .E0818,
            error.CipherSuite, error.Group, error.SignatureScheme => .E0818,
            else => .E0813,
        };
        diag.raise(code);
        switch (err) {
            error.HelloRetryRequest => diag.cause(
                "the server answered with a HelloRetryRequest; " ++
                    "zcube offers one key share and no retry",
                .{},
            ),
            error.ProtocolVersion => diag.cause(
                "the server does not speak TLS 1.3 " ++
                    "(version or downgrade marker in its ServerHello)",
                .{},
            ),
            error.CipherSuite => diag.cause(
                "the server chose a cipher suite other than TLS_AES_128_GCM_SHA256",
                .{},
            ),
            error.Group => diag.cause(
                "the server chose a key exchange group other than x25519",
                .{},
            ),
            error.SignatureScheme => diag.cause(
                "the server signed with a scheme other than ed25519",
                .{},
            ),
            else => diag.cause("the server's {s} is {s}", .{ message, wire_reason(err) }),
        }
        self.add_fix(diag, code);
        return self.refuse(diag, wire_alert(err));
    }

    fn record_failure(self: *Client, diag: *Diag, err: schedule.Error) Error {
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
            error.TooManyKeyUpdates => diag.cause("the server updated its keys over {d} times", .{
                constants.tls_key_updates_per_connection_max,
            }),
            error.ZeroSharedSecret => diag.cause(
                "the key exchange produced an all-zero secret",
                .{},
            ),
            error.Dead => unreachable,
        }
        self.add_fix(diag, .E0815);
        return self.refuse(diag, record_alert(err));
    }

    /// The fix line. For a server that is wrong or offers something else, it names the server:
    /// the client's main use is a relay to a broker that is not a zcube server.
    fn add_fix(self: *const Client, diag: *Diag, code: Code) void {
        var buffer: [constants.tls_server_name_bytes_max + 160]u8 = undefined;
        const sentence = switch (code) {
            .E0810, .E0813, .E0818 => std.fmt.bufPrint(
                &buffer,
                "Check that the server at {s} is the one this connection is configured for, " ++
                    "and that it offers TLS 1.3 with an Ed25519 certificate from the pinned CA.",
                .{self.name[0..self.name_length]},
            ) catch unreachable, // The buffer holds the longest name and the sentence.
            else => fix_sentence(code),
        };
        diag.fix(.{ .sentence = sentence });
    }

    /// Ends the connection: queues the alert (if any), wipes every secret and the record buffer,
    /// and stops all further input and output. Always returns `error.Refused`.
    fn refuse(self: *Client, diag: *Diag, alert: ?wire.Alert) Error {
        self.out_length = 0;
        if (alert) |description| {
            self.queue_alert(wire.alert_level_fatal, description);
            // The diagnostic shows both alerts: the server's (its cause) and ours.
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

    /// Ends the connection without a diagnostic, for a send that failed on a dead direction.
    fn fail_silently(self: *Client) void {
        self.out_length = 0;
        self.wipe_secrets();
        self.state = .failed;
    }

    fn wipe_secrets(self: *Client) void {
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.leaf_key);
        std.crypto.secureZero(u8, &self.record);
        std.crypto.secureZero(u8, &self.flight);
        self.schedule.wipe();
        self.read.wipe();
        self.write.wipe();
        self.record_length = 0;
        self.record_total = 0;
        self.flight_length = 0;
    }

    fn queue_alert(self: *Client, level: u8, alert: wire.Alert) void {
        const content = [2]u8{ level, @backingInt(alert) };
        self.out_length = 0;
        if (self.write_protected and !self.write.dead) {
            const sealed = self.write.seal(self.out[0..], .alert, &content) catch return;
            self.out_length = @intCast(sealed.len);
        } else {
            const record = schedule.write_plain(&self.out, .alert, 0x0303, &content);
            self.out_length = @intCast(record.len);
        }
        assert(self.out_length <= constants.tls_output_bytes_max);
    }
};

fn message_name(kind: u8) []const u8 {
    return switch (kind) {
        wire.handshake_server_hello => "ServerHello",
        wire.handshake_encrypted_extensions => "EncryptedExtensions",
        wire.handshake_certificate => "Certificate",
        wire.handshake_certificate_request => "CertificateRequest",
        wire.handshake_certificate_verify => "CertificateVerify",
        wire.handshake_finished => "Finished",
        wire.handshake_new_session_ticket => "NewSessionTicket",
        wire.handshake_key_update => "KeyUpdate",
        else => "handshake message",
    };
}

fn ed25519_verifies(key: *const [32]u8, content: []const u8, signature: *const [64]u8) bool {
    const public_key = Ed25519.PublicKey.fromBytes(key.*) catch return false;
    const parsed = Ed25519.Signature.fromBytes(signature.*);
    parsed.verify(content, public_key) catch return false;
    return true;
}

/// The alerts a server sends about the certificate it was shown (RFC 8446 section 6.2).
fn refuses_certificate(code: u8) bool {
    const alert = std.enums.fromInt(wire.Alert, code) orelse return false;
    return switch (alert) {
        .bad_certificate,
        .unsupported_certificate,
        .certificate_revoked,
        .certificate_expired,
        .certificate_unknown,
        .unknown_ca,
        .access_denied,
        .certificate_required,
        => true,
        else => false,
    };
}

fn certificate_alert(err: x509.Error) wire.Alert {
    return switch (err) {
        error.WrongIssuer, error.BadSignature => .unknown_ca,
        error.Expired, error.NotYetValid => .certificate_expired,
        error.WrongUse => .unsupported_certificate,
        else => .bad_certificate,
    };
}

fn wire_alert(err: wire.Error) wire.Alert {
    return switch (err) {
        error.Malformed => .decode_error,
        error.IllegalParameter,
        error.DuplicateExtension,
        error.SignatureScheme,
        => .illegal_parameter,
        error.UnexpectedExtension => .unsupported_extension,
        error.MissingExtension => .missing_extension,
        error.ChainShape => .bad_certificate,
        error.ProtocolVersion => .protocol_version,
        error.HelloRetryRequest, error.CipherSuite, error.Group => .handshake_failure,
    };
}

fn record_alert(err: schedule.Error) wire.Alert {
    return switch (err) {
        error.BadRecordMac => .bad_record_mac,
        error.RecordOverflow => .record_overflow,
        error.DecodeError => .decode_error,
        error.UnexpectedMessage, error.TooManyKeyUpdates => .unexpected_message,
        error.KeyLimit => .internal_error,
        error.ZeroSharedSecret => .illegal_parameter,
        error.Dead => unreachable,
    };
}

fn wire_reason(err: wire.Error) []const u8 {
    return switch (err) {
        error.Malformed => "malformed (cut short or a length that does not add up)",
        error.IllegalParameter => "not allowed here (an illegal value)",
        error.UnexpectedExtension => "carrying an extension that was not asked for",
        error.DuplicateExtension => "carrying an extension twice",
        error.MissingExtension => "missing an extension it needs",
        error.ChainShape => "an unexpected certificate chain",
        else => unreachable, // The other errors have causes of their own.
    };
}

fn fix_sentence(code: Code) []const u8 {
    return switch (code) {
        .E0815 => "Reconnect; if it repeats, check the network path between the two machines.",
        .E0816 => "Retry the request: what arrived before the break may be incomplete.",
        .E0820 => "Check that the process or device holding this workload's key is running and " ++
            "reachable, then reconnect.",
        else => unreachable,
    };
}
