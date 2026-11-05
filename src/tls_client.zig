//! The TLS 1.3 client handshake (docs/briefs/mtls-client.md, slice 4): ClientHello to Finished,
//! no client authentication yet (slice 5), pinning the server's certificate against the cluster
//! CA. A pure state machine: bytes in, bytes out, one event per step. It opens no socket and reads
//! no clock or random source; the shell passes in the randomness, the x25519 secret and the time.
//!
//! The cuts, each recorded in docs/decisions/2026-11-05-tls-client-part-1.md:
//!   - A server `CertificateRequest` is refused (ZC-E0813): client authentication is slice 5.
//!   - The client never starts a KeyUpdate by itself; `send_key_update` is there for slice 6 to
//!     call when `update_due` says so. A received KeyUpdate is answered when it asks.
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
};

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
pub const TestFault = enum { certificate_verify, finished, transcript_encrypted_extensions };
var faults: [3]bool = @splat(false);

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
        self.read.wipe();
        self.write.wipe();
        assert(self.read.dead);
        assert(self.write.dead);
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
        diag.fix(.{ .sentence = fix_sentence(.E0816) });
        return self.refuse(null);
    }

    // ---- Sending ------------------------------------------------------------------------------

    /// Protects application data as one record into `out` and returns it.
    pub fn seal_application(self: *Client, plain: []const u8, out: []u8) Error![]u8 {
        assert(self.state == .connected);
        assert(plain.len <= constants.tls_record_plaintext_bytes_max);
        assert(out.len >= schedule.sealed_bytes(plain.len));
        return self.write.seal(out, .application_data, plain) catch |err| {
            self.fail_silently();
            switch (err) {
                error.KeyLimit, error.Dead => return error.Closed,
                else => unreachable,
            }
        };
    }

    /// Sends close_notify and ends the connection.
    pub fn close_notify(self: *Client) void {
        assert(self.state == .connected);
        self.queue_alert(1, .close_notify);
        self.wipe_secrets();
        self.state = .closed;
    }

    /// Sends a KeyUpdate and moves the write keys on (RFC 8446 section 4.6.3); slice 6 calls it
    /// when `write.update_due()`.
    pub fn send_key_update(self: *Client, request: bool) Error!void {
        assert(self.state == .connected);
        assert(self.out_length == 0);
        const message = [_]u8{ schedule.key_update_type, 0, 0, 1, @intFromBool(request) };
        const sealed = self.write.seal(self.out[0..], .handshake, &message) catch {
            self.fail_silently();
            return error.Closed;
        };
        self.out_length = @intCast(sealed.len);
        self.write.rekey() catch {
            self.fail_silently();
            return error.Closed;
        };
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
        const code = content[1];
        if (code == @backingInt(wire.Alert.close_notify)) {
            if (self.state != .connected) {
                diag.raise(.E0816);
                diag.cause("the server closed the connection before the handshake finished", .{});
                diag.fix(.{ .sentence = fix_sentence(.E0816) });
                return self.refuse(null);
            }
            self.queue_alert(1, .close_notify);
            self.wipe_secrets();
            self.state = .closed;
            return .closed;
        }
        diag.raise(.E0813);
        diag.cause("the server sent the fatal alert {s} ({d})", .{ wire.alert_name(code), code });
        diag.fix(.{ .sentence = fix_sentence(.E0813) });
        return self.refuse(null);
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
            const total = 4 + body_length;
            if (total > constants.tls_handshake_message_bytes_max) {
                return self.fail(
                    diag,
                    .E0813,
                    .decode_error,
                    "a handshake message of {d} bytes is too long",
                    .{total},
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
        if (kind == wire.handshake_certificate_request) {
            return self.fail(
                diag,
                .E0813,
                .unexpected_message,
                "the server asked for a client certificate; client authentication is not built yet",
                .{},
            );
        }
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
            return self.refuse(certificate_alert(err));
        };
        assert(parsed.public_key.of(chain.leaf).len == 32);
        self.leaf_key = parsed.public_key.of(chain.leaf)[0..32].*;
        self.transcript.add(message);
        self.state = .wait_certificate_verify;
    }

    fn fail_chain(self: *Client, diag: *Diag) Error {
        diag.raise(.E0810);
        diag.cause("the server sent no certificate, or more than {d}", .{
            constants.tls_chain_certificates_max,
        });
        diag.fix(.{ .sentence = "Check that the server is a zcube server of this cluster." });
        return self.refuse(.bad_certificate);
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
        const finished_hash = self.transcript.hash();
        var verify_data = schedule.finished_verify_data(&self.write.secret, &finished_hash);
        defer std.crypto.secureZero(u8, &verify_data);
        var finished: [4 + schedule.hash_bytes]u8 = undefined;
        finished[0] = wire.handshake_finished;
        std.mem.writeInt(u24, finished[1..4], schedule.hash_bytes, .big);
        @memcpy(finished[4..], &verify_data);
        try self.send_final_flight(diag, &finished);
        var application = self.schedule.to_application(&finished_hash);
        defer std.crypto.secureZero(u8, &application.client);
        defer std.crypto.secureZero(u8, &application.server);
        self.read = schedule.Direction.init(&application.server);
        self.write = schedule.Direction.init(&application.client);
        self.state = .connected;
        return .connected;
    }

    /// The compatibility change_cipher_spec, then the client Finished under the handshake keys.
    fn send_final_flight(self: *Client, diag: *Diag, finished: []const u8) Error!void {
        assert(self.out_length == 0);
        const ccs = schedule.write_plain(&self.out, .change_cipher_spec, 0x0303, &.{1});
        const used: u32 = @intCast(ccs.len);
        const sealed = self.write.seal(self.out[used..], .handshake, finished) catch |err|
            return self.record_failure(diag, err);
        self.out_length = used + @as(u32, @intCast(sealed.len));
        assert(self.out_length <= constants.tls_output_bytes_max);
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
        if (requested) self.send_key_update(false) catch return self.refuse(null);
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
        diag.fix(.{ .sentence = fix_sentence(code) });
        return self.refuse(alert);
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
        diag.fix(.{ .sentence = fix_sentence(code) });
        return self.refuse(wire_alert(err));
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
        diag.fix(.{ .sentence = fix_sentence(.E0815) });
        return self.refuse(record_alert(err));
    }

    /// Ends the connection: queues the alert (if any), wipes every secret and the record buffer,
    /// and stops all further input and output. Always returns `error.Refused`.
    fn refuse(self: *Client, alert: ?wire.Alert) Error {
        self.out_length = 0;
        if (alert) |description| self.queue_alert(wire.alert_level_fatal, description);
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

fn ed25519_verifies(key: *const [32]u8, content: []const u8, signature: *const [64]u8) bool {
    const public_key = Ed25519.PublicKey.fromBytes(key.*) catch return false;
    const parsed = Ed25519.Signature.fromBytes(signature.*);
    parsed.verify(content, public_key) catch return false;
    return true;
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
        .E0813 => "Check that the address is a zcube server of this cluster, then retry.",
        .E0815 => "Reconnect; if it repeats, check the network path between the two machines.",
        .E0816 => "Retry the request: what arrived before the break may be incomplete.",
        .E0818 => "Connect to a zcube server: zcube offers no other TLS settings.",
        else => unreachable,
    };
}
