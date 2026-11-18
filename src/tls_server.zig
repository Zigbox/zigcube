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
//! The browser path (docs/decisions/2026-11-14-b7-slice6-console-over-tls.md): a server given a
//! `Browser` identity answers a ClientHello that does not list ed25519 but lists
//! ecdsa_secp256r1_sha256 with its P-256 certificate, and then takes only a client certificate
//! the cluster's browser CA signed (`x509_p256.zig`). The two paths never mix: the scheme the
//! ClientHello picks decides the CA, the certificates and the signatures of the whole handshake.
//!
//! The rules it keeps, the client's: a plaintext change_cipher_spec is dropped before `open`
//! ever sees it; a failed `open` wipes the record buffer and the keys; bytes behind a key change
//! in one record are refused; after a fatal error nothing more is produced but the one alert.
//!
//! The public path (docs/briefs/c5.md, "Public TLS";
//! docs/decisions/2026-11-15-c5-public-tls-mode.md): a server set up with `init_public` faces the
//! internet. It sends no CertificateRequest and takes no client certificate; the handshake ends at
//! the client's Finished. It picks the certificate chain by the canonical server name (SNI) from a
//! `PublicTable` of P-256 keys, leaves and opaque intermediates, refuses a ClientHello with no
//! server name or an unknown one (`unrecognized_name`), and one whose ALPN list lacks http/1.1
//! (`no_application_protocol`). Its CertificateVerify is ECDSA P-256 with the chain's key. Neither
//! cluster path is reachable from it.
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
const p256 = @import("x509_p256.zig");
const edge_host = @import("edge_host.zig");

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
    /// The browser path; null on every listener but the API's.
    browser: ?Browser = null,
};

/// The browser path's identity: the browser CA, the P-256 server certificate and its key.
pub const Browser = struct {
    /// The browser CA's public key: the only issuer a browser client certificate may have.
    anchor: p256.Point,
    /// The P-256 server certificate (and optionally the browser CA's after it). Copied by `init`.
    certificates: []const []const u8,
    /// The server certificate's key; it must outlive the connection.
    key: *const p256.KeyPair,
};

/// The client the handshake authenticated.
pub const Peer = struct {
    kind: x509.Kind,
    /// The certificate's SPIFFE URI (a workload) or DNS name.
    name: []const u8,
    /// A client certificate's scope; null for every other kind.
    scope: ?x509.Scope,
    /// The certificate's validity, for the checks after the handshake (B7 slice 5).
    not_before_ms: u64,
    not_after_ms: u64,
};

/// One host's chain on the public path.
pub const PublicChain = struct {
    /// The canonical host name (`edge_host.canonicalize`).
    host: []const u8,
    /// The leaf's key; it must outlive every handshake that may pick this chain.
    key: *const p256.KeyPair,
    /// The leaf first, then the intermediates, sent as given: this server never parses them.
    certificates: []const []const u8,
};

/// The public path's chains, sorted by host with no two the same, so that `find` is a binary
/// search. A server reads it only while it answers a ClientHello, so a shell may swap tables
/// between connections.
pub const PublicTable = struct {
    chains: []const PublicChain,

    pub const TableError = error{
        TooManyHosts,
        NotCanonical,
        Unsorted,
        ChainEmpty,
        ChainTooLong,
        CertificateTooLarge,
        ChainTooLarge,
    };

    /// Checks every rule above and the bounds of `constants.edge_*`.
    pub fn init(chains: []const PublicChain) TableError!PublicTable {
        if (chains.len > constants.edge_hosts_max) return error.TooManyHosts;
        for (chains, 0..) |chain, index| {
            var canonical: edge_host.Name = undefined;
            const host = edge_host.canonicalize(&canonical, chain.host) catch
                return error.NotCanonical;
            if (!std.mem.eql(u8, host, chain.host)) return error.NotCanonical;
            if (index > 0) {
                const before = chains[index - 1].host;
                if (std.mem.order(u8, before, chain.host) != .lt) return error.Unsorted;
            }
            try check_chain(chain.certificates);
        }
        return .{ .chains = chains };
    }

    fn check_chain(certificates: []const []const u8) TableError!void {
        if (certificates.len == 0) return error.ChainEmpty;
        if (certificates.len > constants.edge_chain_certificates_max) return error.ChainTooLong;
        var total: u32 = 0;
        for (certificates) |certificate| {
            if (certificate.len == 0) return error.ChainEmpty;
            if (certificate.len > constants.edge_certificate_bytes_max) {
                return error.CertificateTooLarge;
            }
            total += @intCast(certificate.len);
        }
        if (total > constants.edge_chain_bytes_max) return error.ChainTooLarge;
    }

    /// The chain for a canonical host name, or null.
    pub fn find(self: *const PublicTable, host: []const u8) ?*const PublicChain {
        var low: usize = 0;
        var high: usize = self.chains.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.chains[middle].host, host)) {
                .eq => return &self.chains[middle],
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }
};

pub const PublicConfig = struct {
    random: [32]u8,
    /// The ephemeral x25519 secret.
    secret: [32]u8,
    /// Read only while the ClientHello is answered.
    table: *const PublicTable,
};

/// Why the public path refused a handshake, for the edge's `edge_handshakes_refused{reason}`.
pub const PublicRefusal = enum {
    server_name_missing,
    server_name_unknown,
    alpn,
    /// x25519 listed without a key share: it would take a HelloRetryRequest, which this server
    /// does not send (docs/briefs/c5.md, "Public TLS").
    x25519_without_share,
    /// The client ended the handshake itself, with a fatal alert or an early close_notify (a
    /// browser that does not trust the chain, say): not a hello this server refused.
    client_alert,
    other,
};

const Mode = enum { cluster, public };

/// The most certificates either path sends.
const chain_certificates_max: u32 =
    @max(constants.tls_chain_certificates_max, constants.edge_chain_certificates_max);

const peer_name_bytes_max: u32 =
    @max(constants.x509_spiffe_bytes_max, constants.x509_dns_name_bytes_max);

/// The server's flight after ServerHello, as one sealed record: EncryptedExtensions,
/// CertificateRequest, Certificate, CertificateVerify and Finished.
/// The public path sends a longer EncryptedExtensions and chain, and no CertificateRequest.
const flight_content_bytes_max: u32 = @max(
    wire.encrypted_extensions_message.len + wire.certificate_request_message.len +
        wire.certificate_bytes_max,
    wire.encrypted_extensions_public_alpn.len + wire.certificate_request_message.len +
        wire.certificate_public_bytes_max,
) + wire.certificate_verify_bytes_max + 4 + schedule.hash_bytes;

/// What one step writes at most: the ServerHello record, the change_cipher_spec and the flight.
pub const output_bytes_max: u32 = header_bytes + wire.server_hello_bytes_max + (header_bytes + 1) +
    header_bytes + flight_content_bytes_max + 1 + schedule.tag_bytes;

comptime {
    assert(wire.certificate_request_message.len == wire.certificate_request_message_p256.len);
    assert(wire.certificate_verify_bytes <= wire.certificate_verify_bytes_max);
    assert(wire.encrypted_extensions_public.len <= wire.encrypted_extensions_public_alpn.len);
    assert(wire.encrypted_extensions_message.len <= wire.encrypted_extensions_public_alpn.len);
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
    /// Bytes behind a key change (the ClientHello, the client's Finished, a KeyUpdate), in the
    /// same record, are read on.
    key_change_boundary,
    /// Any number of change_cipher_spec records, of any one-byte body, are dropped.
    change_cipher_spec,
    /// An alert or application data between the pieces of a handshake message is read.
    interleave,
    /// A plaintext alert is read at any point, not only before the client's first protected
    /// record.
    plain_alert_window,
    /// A ClientHello that offers early data is taken.
    early_data,
    /// The client's KeyUpdates are not counted against the limit.
    key_update_limit,
    /// The public path serves its first chain for a missing or unknown server name.
    sni_check,
    /// The public path takes an ALPN list without http/1.1.
    alpn_check,
    /// The public path sends a CertificateRequest.
    cert_request_sent,
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
    mode: Mode,
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
    /// The scheme the ClientHello picked: ed25519 unless the client lists only the browser's.
    scheme: wire.Scheme,
    browser_enabled: bool,
    browser_anchor: p256.Point,
    browser_identity: [constants.tls_chain_certificates_max][constants.x509_cert_bytes_max]u8,
    browser_identity_lengths: [constants.tls_chain_certificates_max]u32,
    browser_identity_count: u32,
    browser_key: ?*const p256.KeyPair,
    /// The browser client certificate's P-256 key (the `ecdsa_p256` path's `leaf_key`).
    leaf_point: p256.Point,
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
    peer_not_before_ms: u64,
    peer_not_after_ms: u64,
    authenticated: bool,
    record: [schedule.sealed_bytes_max]u8,
    record_length: u32,
    record_total: u32,
    flight: [constants.tls_handshake_flight_bytes_max]u8,
    flight_length: u32,
    out: [output_bytes_max]u8,
    out_length: u32,
    /// The public path's table and the chain the server name picked: set only while the
    /// ClientHello is answered.
    public_table: ?*const PublicTable,
    public_chain: ?*const PublicChain,
    /// The client offered ALPN with http/1.1, so EncryptedExtensions selects it.
    alpn_http11: bool,
    /// The canonical server name the client asked for (public path).
    host: edge_host.Name,
    host_length: u32,
    refusal: ?PublicRefusal,

    /// Sets the server up in place (it is large), waiting for a ClientHello.
    pub fn init(self: *Server, config: *const Config) void {
        const certificates = config.identity.certificates;
        assert(certificates.len >= 1);
        assert(certificates.len <= constants.tls_chain_certificates_max);
        self.init_common(config.random, config.secret);
        self.mode = .cluster;
        self.anchor = config.anchor;
        self.now_ms = config.now_ms;
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
        self.init_browser(config.browser);
        self.peer_kind = first_kind(config.client_kinds);
    }

    /// Sets the server up in place for the public path, waiting for a ClientHello. The table
    /// must be valid (`PublicTable.init`).
    pub fn init_public(self: *Server, config: *const PublicConfig) void {
        assert(config.table.chains.len <= constants.edge_hosts_max);
        self.init_common(config.random, config.secret);
        self.mode = .public;
        self.anchor = @splat(0);
        self.now_ms = 0;
        // No client certificate is ever read, so no kind is taken.
        self.client_kinds = .empty;
        self.identity_lengths = @splat(0);
        self.identity_count = 0;
        self.signer = .{ .context = config.table, .sign = never_signs };
        self.init_browser(null);
        self.scheme = .ecdsa_p256;
        self.peer_kind = .client;
        self.public_table = config.table;
        assert(self.mode == .public);
        assert(!self.browser_enabled);
    }

    fn init_common(self: *Server, random: [32]u8, secret: [32]u8) void {
        self.state = .wait_client_hello;
        self.random = random;
        self.secret = secret;
        self.public_key = X25519.recoverPublicKey(secret);
        self.schedule = schedule.Schedule.init();
        self.transcript = schedule.Transcript.init();
        self.read_next = @splat(0);
        self.read_protected = false;
        self.ccs_dropped = 0;
        self.leaf_key = @splat(0);
        self.peer_name_length = 0;
        self.peer_scope = null;
        self.peer_not_before_ms = 0;
        self.peer_not_after_ms = 0;
        self.authenticated = false;
        self.record_length = 0;
        self.record_total = 0;
        self.flight_length = 0;
        self.out_length = 0;
        self.public_table = null;
        self.public_chain = null;
        self.alpn_http11 = false;
        self.host_length = 0;
        self.refusal = null;
        self.read.wipe();
        self.write.wipe();
        assert(self.read.dead);
        assert(self.write.dead);
    }

    /// What is ready to send. The caller sends it all and calls `drain` before the next step.
    fn init_browser(self: *Server, browser: ?Browser) void {
        self.scheme = .ed25519;
        self.browser_enabled = browser != null;
        self.browser_anchor = @splat(0);
        self.browser_identity_lengths = @splat(0);
        self.browser_identity_count = 0;
        self.browser_key = null;
        self.leaf_point = @splat(0);
        const identity = browser orelse return;
        // The browser path serves a client certificate's API; no other kind comes over it.
        assert(self.client_kinds.contains(.client));
        assert(identity.certificates.len >= 1);
        assert(identity.certificates.len <= constants.tls_chain_certificates_max);
        self.browser_anchor = identity.anchor;
        self.browser_key = identity.key;
        for (identity.certificates, 0..) |certificate, index| {
            assert(certificate.len > 0);
            assert(certificate.len <= constants.x509_cert_bytes_max);
            @memcpy(self.browser_identity[index][0..certificate.len], certificate);
            self.browser_identity_lengths[index] = @intCast(certificate.len);
        }
        self.browser_identity_count = @intCast(identity.certificates.len);
    }

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
            .not_before_ms = self.peer_not_before_ms,
            .not_after_ms = self.peer_not_after_ms,
        };
    }

    /// The canonical server name the public path served; null before the ClientHello is
    /// answered and on the cluster path.
    pub fn server_name(self: *const Server) ?[]const u8 {
        if (self.mode != .public) return null;
        if (self.host_length == 0) return null;
        return self.host[0..self.host_length];
    }

    /// Why the public path refused the handshake; null while it has not.
    pub fn public_refusal(self: *const Server) ?PublicRefusal {
        return self.refusal;
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
        const plain_alert = self.plain_alert_allowed() or fault_on(.plain_alert_window);
        if (header.content_type == .alert and plain_alert) {
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
        const after_flight: State = switch (self.mode) {
            .cluster => .wait_certificate,
            .public => .wait_finished,
        };
        if (self.state != after_flight) return false;
        if (self.flight_length != 0) return false;
        return self.read.sequence == 0;
    }

    fn on_plain(self: *Server, diag: *Diag, kind: schedule.ContentType) Error!Event {
        assert(!self.read_protected);
        assert(self.state == .wait_client_hello);
        const body = self.record[header_bytes..self.record_total];
        if (body.len == 0) return self.record_failure(diag, error.UnexpectedMessage);
        if (kind == .alert and self.flight_length != 0 and !fault_on(.interleave)) {
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
        if (kind != .handshake and !fault_on(.interleave)) {
            if (self.flight_length != 0) return self.record_failure(diag, error.UnexpectedMessage);
        }
        switch (kind) {
            .handshake => {
                // No zero-length handshake fragments (RFC 8446 section 5.1).
                if (content.len == 0) {
                    return self.fail(
                        diag,
                        .E0815,
                        .unexpected_message,
                        "the client sent a protected handshake record with no content",
                        .{},
                    );
                }
                return self.on_handshake_bytes(diag, content);
            },
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
        if (body.len != 1) return self.record_failure(diag, error.UnexpectedMessage);
        if (fault_on(.change_cipher_spec)) return .none;
        if (self.ccs_dropped >= constants.tls_change_cipher_spec_records_max) {
            return self.record_failure(diag, error.UnexpectedMessage);
        }
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
        if (self.mode == .public and self.state != .connected and self.refusal == null) {
            self.refusal = .client_alert;
        }
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
        self.add_fix_for_path(diag, .E0813);
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
            if (keys_change and self.flight_length > total and !fault_on(.key_change_boundary)) {
                // The bytes behind a key change belong under the new keys, not this record. The
                // check comes before the message is acted on, so a refused ClientHello leaves no
                // keys behind and its alert goes in the clear.
                return self.fail(
                    diag,
                    .E0813,
                    .unexpected_message,
                    "handshake data follows a key change in the same record",
                    .{},
                );
            }
            const message_event = try self.on_message(diag, kind, total);
            if (message_event != .none) event = message_event;
            std.mem.copyForwards(u8, &self.flight, self.flight[total..self.flight_length]);
            self.flight_length -= total;
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
        const hello = switch (self.mode) {
            .cluster => try self.read_hello(diag, message),
            .public => try self.read_public_hello(diag, message),
        };
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
        // The table is not read after this: a shell may swap it once the flight is out.
        self.public_table = null;
        self.public_chain = null;
        self.state = switch (self.mode) {
            .cluster => .wait_certificate,
            .public => .wait_finished,
        };
    }

    /// The cluster paths' ClientHello: ed25519, or the browser's scheme with a browser identity.
    fn read_hello(self: *Server, diag: *Diag, message: []const u8) Error!wire.ClientHello {
        assert(self.mode == .cluster);
        const hello = wire.parse_client_hello(message[4..]) catch |err|
            return self.wire_failure(diag, err, "ClientHello");
        // Early data is refused before the scheme is judged, as before the public path.
        try self.refuse_early_data(diag, hello);
        if (!hello.ed25519) {
            // The ClientHello lists the browser's scheme only; without a browser identity this
            // server has no certificate the client would take.
            if (!self.browser_enabled) {
                return self.wire_failure(diag, error.SignatureScheme, "ClientHello");
            }
            assert(hello.ecdsa_p256);
            self.scheme = .ecdsa_p256;
        }
        return hello;
    }

    /// The public path's ClientHello: ecdsa_secp256r1_sha256, a server name the table has, and
    /// http/1.1 among the ALPN protocols if the client offers any.
    fn read_public_hello(self: *Server, diag: *Diag, message: []const u8) Error!wire.ClientHello {
        assert(self.mode == .public);
        assert(self.scheme == .ecdsa_p256);
        const parsed = wire.parse_client_hello_public(message[4..]) catch |err| {
            if (err == error.HelloRetryRequest) {
                return self.refuse_public(
                    diag,
                    .x25519_without_share,
                    .handshake_failure,
                    "the client lists x25519 without a key share for it; this server sends " ++
                        "no HelloRetryRequest",
                    .{},
                );
            }
            self.refusal = .other;
            return self.wire_failure(diag, err, "ClientHello");
        };
        if (!parsed.hello.ecdsa_p256) {
            self.refusal = .other;
            return self.wire_failure(diag, error.SignatureScheme, "ClientHello");
        }
        try self.pick_chain(diag, parsed.server_name);
        switch (parsed.alpn) {
            .absent => {},
            .http11 => self.alpn_http11 = true,
            .other => if (!fault_on(.alpn_check)) {
                return self.refuse_public(
                    diag,
                    .alpn,
                    .no_application_protocol,
                    "the client's ALPN list does not include http/1.1",
                    .{},
                );
            },
        }
        try self.refuse_early_data(diag, parsed.hello);
        return parsed.hello;
    }

    /// 0-RTT is never taken (docs/mtls.md): a ClientHello that offers it is refused.
    fn refuse_early_data(self: *Server, diag: *Diag, hello: wire.ClientHello) Error!void {
        if (!hello.early_data) return;
        if (fault_on(.early_data)) return;
        return self.fail(
            diag,
            .E0818,
            .illegal_parameter,
            "the client offers early data; this server takes none",
            .{},
        );
    }

    /// The chain for the client's server name, canonicalized as `Host` is.
    fn pick_chain(self: *Server, diag: *Diag, name: ?[]const u8) Error!void {
        const table = self.public_table orelse unreachable; // Set by `init_public`.
        assert(self.public_chain == null);
        const given = name orelse {
            if (fault_on(.sni_check) and table.chains.len > 0) return self.serve(&table.chains[0]);
            return self.refuse_public(
                diag,
                .server_name_missing,
                .unrecognized_name,
                "the client sent no server name (SNI)",
                .{},
            );
        };
        var canonical: edge_host.Name = undefined;
        const host = edge_host.canonicalize(&canonical, given) catch |err| {
            if (fault_on(.sni_check) and table.chains.len > 0) return self.serve(&table.chains[0]);
            return self.refuse_public(
                diag,
                .server_name_unknown,
                .unrecognized_name,
                "the client's server name is not a host name: {s}",
                .{edge_host.describe(err)},
            );
        };
        const chain = table.find(host) orelse {
            if (fault_on(.sni_check) and table.chains.len > 0) return self.serve(&table.chains[0]);
            return self.refuse_public(
                diag,
                .server_name_unknown,
                .unrecognized_name,
                "no service here is public under the server name {s}",
                .{host},
            );
        };
        self.serve(chain);
        @memcpy(self.host[0..host.len], host);
        self.host_length = @intCast(host.len);
    }

    fn serve(self: *Server, chain: *const PublicChain) void {
        assert(chain.certificates.len >= 1);
        assert(chain.certificates.len <= constants.edge_chain_certificates_max);
        self.public_chain = chain;
    }

    fn refuse_public(
        self: *Server,
        diag: *Diag,
        reason: PublicRefusal,
        alert: wire.Alert,
        comptime format: []const u8,
        args: anytype,
    ) Error {
        assert(self.mode == .public);
        self.refusal = reason;
        return self.fail(diag, .E0818, alert, format, args);
    }

    /// EncryptedExtensions, CertificateRequest, Certificate, CertificateVerify and Finished in one
    /// record under the server's handshake keys; then the write side moves to the application
    /// keys, and the client's application secret waits for the client's Finished.
    fn send_flight(self: *Server, diag: *Diag) Error!void {
        var content: [flight_content_bytes_max]u8 = undefined;
        defer std.crypto.secureZero(u8, &content);
        var length: u32 = 0;
        length += self.append(&content, length, self.encrypted_extensions());
        if (self.mode == .cluster or fault_on(.cert_request_sent)) {
            const request = switch (self.scheme) {
                .ed25519 => &wire.certificate_request_message,
                .ecdsa_p256 => &wire.certificate_request_message_p256,
            };
            length += self.append(&content, length, request);
        }
        var chain: [chain_certificates_max][]const u8 = undefined;
        const chain_used = self.server_chain(&chain);
        const certificate = switch (self.mode) {
            .cluster => wire.write_certificate(content[length..], chain_used),
            .public => wire.write_certificate_public(content[length..], chain_used),
        };
        self.transcript.add(certificate);
        length += @intCast(certificate.len);
        const certificate_hash = self.transcript.hash();
        const verify_content = schedule.certificate_verify_content(.server, &certificate_hash);
        var verify_buffer: [wire.certificate_verify_bytes_max]u8 = undefined;
        const verify = try self.sign_certificate_verify(diag, &verify_buffer, &verify_content);
        length += self.append(&content, length, verify);
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

    /// The cluster paths send an empty EncryptedExtensions; the public path acknowledges the
    /// server name (RFC 6066 section 3) and selects http/1.1 when the client offered ALPN.
    fn encrypted_extensions(self: *const Server) []const u8 {
        return switch (self.mode) {
            .cluster => &wire.encrypted_extensions_message,
            .public => if (self.alpn_http11)
                &wire.encrypted_extensions_public_alpn
            else
                &wire.encrypted_extensions_public,
        };
    }

    /// The certificates this server presents on the handshake's path, leaf first.
    fn server_chain(
        self: *const Server,
        chain: *[chain_certificates_max][]const u8,
    ) []const []const u8 {
        if (self.mode == .public) {
            const picked = self.public_chain orelse unreachable; // Set by `pick_chain`.
            for (picked.certificates, 0..) |certificate, index| chain[index] = certificate;
            return chain[0..picked.certificates.len];
        }
        switch (self.scheme) {
            .ed25519 => {
                for (0..self.identity_count) |index| {
                    chain[index] = self.identity[index][0..self.identity_lengths[index]];
                }
                return chain[0..self.identity_count];
            },
            .ecdsa_p256 => {
                assert(self.browser_enabled);
                for (0..self.browser_identity_count) |index| {
                    const length = self.browser_identity_lengths[index];
                    chain[index] = self.browser_identity[index][0..length];
                }
                return chain[0..self.browser_identity_count];
            },
        }
    }

    /// The server's CertificateVerify on the handshake's path: Ed25519 through the signer, or
    /// ECDSA P-256 with the browser key (deterministic, low S, DER).
    fn sign_certificate_verify(
        self: *Server,
        diag: *Diag,
        out: *[wire.certificate_verify_bytes_max]u8,
        content: []const u8,
    ) Error![]const u8 {
        switch (self.scheme) {
            .ed25519 => {
                const signature = self.signer.sign(self.signer.context, content) orelse {
                    // The refusal drops the ServerHello queued before it, so the client holds no
                    // keys: the alert goes in the clear, which it can read.
                    self.write.wipe();
                    return self.fail(
                        diag,
                        .E0820,
                        .internal_error,
                        "the signer holding the server certificate's key did not sign",
                        .{},
                    );
                };
                const message = wire.write_certificate_verify(&signature);
                @memcpy(out[0..message.len], &message);
                return out[0..message.len];
            },
            .ecdsa_p256 => {
                const key = switch (self.mode) {
                    .cluster => self.browser_key orelse unreachable, // Set with browser_enabled.
                    .public => (self.public_chain orelse unreachable).key, // Set by `pick_chain`.
                };
                var der: [p256.signature_der_bytes_max]u8 = undefined;
                const signature = p256.signature_write(&der, p256.sign(key.*, content));
                return wire.write_certificate_verify_p256(out, signature);
            },
        }
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
        if (self.scheme == .ecdsa_p256) {
            return self.on_browser_certificate(diag, message, chain.leaf);
        }
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
        self.peer_not_before_ms = parsed.not_before_ms;
        self.peer_not_after_ms = parsed.not_after_ms;
        if (!fault_on(.transcript_client_auth)) self.transcript.add(message);
        self.state = .wait_certificate_verify;
    }

    /// The browser path's client certificate: a client's, from the browser CA, in its window.
    fn on_browser_certificate(
        self: *Server,
        diag: *Diag,
        message: []const u8,
        leaf: []const u8,
    ) Error!void {
        assert(self.scheme == .ecdsa_p256);
        const parsed = self.verify_browser_client(leaf) catch |err| {
            var detail: x509.Detail = .{};
            detail.kinds_expected = x509.Kinds.initOne(.client);
            x509.raise(diag, err, "the client", &detail);
            return self.refuse(diag, tls_client.certificate_alert(err));
        };
        // The kind is checked above, unless a test fault skipped that check.
        if (!fault_on(.client_kind) and !fault_on(.client_chain)) assert(parsed.kind == .client);
        self.leaf_point = parsed.point(leaf);
        const name = parsed.name.of(leaf);
        assert(name.len <= peer_name_bytes_max);
        @memcpy(self.peer_name[0..name.len], name);
        self.peer_name_length = @intCast(name.len);
        self.peer_kind = p256.cluster_kind(parsed.kind);
        self.peer_scope = if (parsed.kind == .client) parsed.scope(leaf) else null;
        // The window `Setup.recheck` judges before each request (B7 slice 5).
        self.peer_not_before_ms = parsed.not_before_ms;
        self.peer_not_after_ms = parsed.not_after_ms;
        if (!fault_on(.transcript_client_auth)) self.transcript.add(message);
        self.state = .wait_certificate_verify;
    }

    /// A browser leaf against the browser CA, the window and the client kind; the faults take
    /// what the check would refuse, as `verify_client`'s do.
    fn verify_browser_client(self: *const Server, leaf: []const u8) x509.Error!p256.Parsed {
        const expect: p256.Expect = .{ .kind = .client, .name = null };
        return p256.verify(leaf, self.browser_anchor, self.now_ms, expect) catch |err| {
            if (fault_on(.client_chain)) return p256.parse(leaf);
            if (err == error.WrongUse and fault_on(.client_kind)) return p256.parse(leaf);
            return err;
        };
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

    /// ZC-E0814, naming the CA of the handshake's path: a browser (no Ed25519 offered) needs a
    /// certificate of the browser CA, which only `ca issue-client --p12` makes.
    fn fail_no_certificate(self: *Server, diag: *Diag) Error {
        diag.raise(.E0814);
        switch (self.scheme) {
            .ed25519 => {
                diag.cause(
                    "the client sent no certificate; this server requires one from the cluster CA",
                    .{},
                );
                add_fix(diag, .E0814);
            },
            .ecdsa_p256 => {
                assert(self.browser_enabled);
                diag.cause("the client (a browser: it offered no Ed25519) sent no certificate; " ++
                    "this server requires one from the cluster's browser CA", .{});
                diag.fix(.{ .sentence = "Import a .p12 the browser CA signed into the " ++
                    "browser: zcube-server ca issue-client NAME --scope admin --p12 FILE " ++
                    "(docs/mtls.md, \"Browsers\")." });
            },
        }
        return self.refuse(diag, .certificate_required);
    }

    fn on_certificate_verify(self: *Server, diag: *Diag, kind: u8, message: []const u8) Error!void {
        try self.expect_kind(diag, kind, wire.handshake_certificate_verify, "CertificateVerify");
        // The signature covers the transcript up to and including Certificate, so it is checked
        // before this message joins the transcript.
        const hash = self.transcript.hash();
        const role: schedule.CertificateRole = if (fault_on(.verify_context)) .server else .client;
        const content = schedule.certificate_verify_content(role, &hash);
        const verifies = try self.client_signature_verifies(diag, message[4..], &content);
        if (!fault_on(.certificate_verify)) {
            if (!verifies) {
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

    /// Whether the client's CertificateVerify, of the handshake's scheme, verifies against its
    /// certificate's key. ECDSA takes any S here: browsers do not normalise it (the certificate
    /// path requires a low S; docs/decisions/2026-11-14-b7-slice6-console-over-tls.md).
    fn client_signature_verifies(
        self: *Server,
        diag: *Diag,
        body: []const u8,
        content: []const u8,
    ) Error!bool {
        switch (self.scheme) {
            .ed25519 => {
                const signature = wire.parse_certificate_verify(body) catch |err|
                    return self.wire_failure(diag, err, "CertificateVerify");
                return tls_client.ed25519_verifies(&self.leaf_key, content, signature);
            },
            .ecdsa_p256 => {
                const signature = wire.parse_certificate_verify_p256(body) catch |err|
                    return self.wire_failure(diag, err, "CertificateVerify");
                p256.signature_verify(self.leaf_point, content, signature, .any_s) catch
                    return false;
                return true;
            },
        }
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
        if (fault_on(.key_update_limit)) self.read.updates = 0; // The count is not kept.
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
        self.add_fix_for_path(diag, code);
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
            error.SignatureScheme => switch (self.mode) {
                .cluster => diag.cause("the client's {s} does not use ed25519", .{message}),
                .public => diag.cause(
                    "the client's {s} does not offer ecdsa_secp256r1_sha256",
                    .{message},
                ),
            },
            error.HelloRetryRequest => unreachable, // Only a ServerHello is one.
            else => diag.cause("the client's {s} is {s}", .{
                message, tls_client.wire_reason(err),
            }),
        }
        self.add_fix_for_path(diag, code);
        const hello = self.state == .wait_client_hello;
        return self.refuse(diag, server_wire_alert(err, hello));
    }

    /// The fix line for the handshake's own refusals: a cluster client must bring a cluster
    /// certificate, a public one only what a browser offers.
    fn add_fix_for_path(self: *const Server, diag: *Diag, code: Code) void {
        switch (self.mode) {
            .cluster => add_fix(diag, code),
            .public => add_public_fix(diag, code),
        }
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
        if (self.mode == .public and self.state != .connected and self.refusal == null) {
            self.refusal = .other;
        }
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
        std.crypto.secureZero(u8, &self.leaf_point);
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

    /// An alert goes out under the write keys while there are any, else plain: before the
    /// ServerHello, after a refused ClientHello, and when this server's own signer fails (the
    /// refusal drops the ServerHello, so the client holds no keys and `send_flight` wipes the
    /// write keys first).
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

/// A refused ClientHello (`hello`) offers what this server does not take: a handshake failure, or
/// a protocol version alert for a client that does not speak TLS 1.3 (RFC 8446 section 4.2.1).
fn server_wire_alert(err: wire.Error, hello: bool) wire.Alert {
    if (hello) {
        switch (err) {
            error.CipherSuite, error.Group, error.SignatureScheme => return .handshake_failure,
            error.MissingExtension => return .missing_extension,
            else => {},
        }
    }
    return tls_client.wire_alert(err);
}

/// The public path's signer slot: it signs with the chain's P-256 key, never through a signer.
fn never_signs(context: *const anyopaque, message: []const u8) ?[64]u8 {
    _ = context;
    _ = message;
    unreachable; // `sign_certificate_verify` takes the P-256 branch on the public path.
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

/// The public path's fix line: the other end is a browser or an HTTP client on the internet.
fn add_public_fix(diag: *Diag, code: Code) void {
    const sentence = switch (code) {
        .E0810, .E0813, .E0818 => "Check that the client asks, by server name (SNI), for a " ++
            "host this edge serves, and offers TLS 1.3 with x25519, TLS_AES_128_GCM_SHA256, " ++
            "ECDSA P-256 signatures and, if it uses ALPN, http/1.1.",
        else => return add_fix(diag, code),
    };
    diag.fix(.{ .sentence = sentence });
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
