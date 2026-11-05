//! The cluster CA as the control-plane core sees it (docs/peer.md, "Trust model"): a signing key,
//! the list of removed nodes, and a wall clock. The shell (`server_ca.zig`) loads or makes the key
//! and reads the `revoked` file; this file only decides whether to sign, and signs. No file, no
//! randomness, no clock of its own: the clock is the `Clock` it is given.
//!
//! The CA is not a store writer (authority.md): it signs credentials and writes no key.

const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const Edwards25519 = std.crypto.ecc.Edwards25519;
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const peer = @import("peer.zig");
const records = @import("records.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

/// The names of removed nodes: one per line, `#` starts a comment, blank lines are ignored.
pub const Revoked = struct {
    names: [constants.peer_revoked_max][peer.name_bytes_max]u8 = undefined,
    lengths: [constants.peer_revoked_max]u8 = undefined,
    count: u32 = 0,
    /// After a failed `parse`, the 1-based line that was refused.
    bad_line: u32 = 0,

    pub const ParseError = error{ TooMany, BadName };

    /// Replaces the list with `text`'s names. A name that is not a node name, or more than
    /// `peer_revoked_max` names, is refused whole (and the list is then empty).
    pub fn parse(revoked: *Revoked, text: []const u8) ParseError!void {
        revoked.count = 0;
        revoked.bad_line = 0;
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_number += 1;
            const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
            const line = std.mem.trim(u8, raw[0..hash], " \t\r");
            if (line.len == 0) continue;
            revoked.bad_line = line_number;
            if (records.name_problem(line, peer.name_bytes_max) != null) {
                revoked.count = 0;
                return error.BadName;
            }
            if (revoked.count == constants.peer_revoked_max) {
                revoked.count = 0;
                return error.TooMany;
            }
            const slot = revoked.count;
            revoked.names[slot] = @splat(0);
            @memcpy(revoked.names[slot][0..line.len], line);
            revoked.lengths[slot] = @intCast(line.len);
            revoked.count += 1;
        }
        revoked.bad_line = 0;
    }

    pub fn contains(revoked: *const Revoked, node: []const u8) bool {
        assert(revoked.count <= constants.peer_revoked_max);
        for (0..revoked.count) |index| {
            const name = revoked.names[index][0..revoked.lengths[index]];
            if (std.mem.eql(u8, name, node)) return true;
        }
        return false;
    }
};

pub const Ca = struct {
    key: Ed25519.KeyPair,
    revoked: Revoked,
    /// Unix milliseconds (the real clock, in the shell): credentials start at its `now`.
    wall: Clock,

    pub const IssueError = error{ Removed, BadKey };

    pub fn public(ca: *const Ca) [32]u8 {
        return ca.key.public_key.toBytes();
    }

    /// Signs `node_key` as `node`'s key for `peer_credential_ttl_ms` from now. A removed node is
    /// refused (ZC-E0807 is the caller's to raise), and so is a key that is not a valid Ed25519
    /// public key, which no handshake could use. The caller has checked the node's name.
    pub fn issue(ca: *const Ca, node: []const u8, node_key: [32]u8) IssueError!peer.Credential {
        assert(records.name_problem(node, peer.name_bytes_max) == null);
        if (ca.revoked.contains(node)) return error.Removed;
        // On the curve and in the prime-order subgroup: a small-order or mixed-order point is
        // refused, so no credential vouches for a key no honest node holds.
        const point = Edwards25519.fromBytes(node_key) catch return error.BadKey;
        point.rejectUnexpectedSubgroup() catch return error.BadKey;
        const now_ms = ca.wall.now_ms();
        const credential = peer.issue(
            ca.key,
            node,
            node_key,
            now_ms,
            now_ms + constants.peer_credential_ttl_ms,
        );
        assert(credential.not_after_ms > credential.not_before_ms);
        return credential;
    }

    /// The self-signed CA certificate for this key, valid from now for `ttl_ms` (at most
    /// `x509_ca_ttl_ms_max`). A lifetime over the bound is `IssueLifetime`.
    pub fn issue_ca_certificate(
        ca: *const Ca,
        out: *x509.Der,
        ttl_ms: u64,
    ) CertificateError!void {
        const lifetime = try lifetime_from(ca.wall.now_ms(), ttl_ms);
        try x509.issue_ca(out, ca.key, lifetime);
        assert(out.slice().len <= constants.x509_cert_bytes_max);
    }

    /// A client certificate for `request.service` in `request.cluster`, valid from now for
    /// `request.ttl_ms` (at most `x509_leaf_ttl_ms_max`). The workload's private key stays with
    /// the caller; only its public half is certified, and a point that no honest key is (off the
    /// curve, or in a small subgroup) is `BadKey`, as for a node credential.
    pub fn issue_workload_certificate(
        ca: *const Ca,
        out: *x509.Der,
        request: *const WorkloadArgs,
    ) CertificateError!void {
        try check_subject_key(request.subject_key);
        const lifetime = try lifetime_from(ca.wall.now_ms(), request.ttl_ms);
        try x509.issue_workload(out, ca.key, &.{
            .cluster = request.cluster,
            .service = request.service,
            .subject_key = request.subject_key,
            .identity = request.identity,
            .lifetime = lifetime,
        });
        assert(out.slice().len <= constants.x509_cert_bytes_max);
    }

    /// A server certificate for the DNS name `request.dns_name`, valid from now for
    /// `request.ttl_ms` (at most `x509_leaf_ttl_ms_max`). Same key rule as the workload's.
    pub fn issue_server_certificate(
        ca: *const Ca,
        out: *x509.Der,
        request: *const ServerArgs,
    ) CertificateError!void {
        try check_subject_key(request.subject_key);
        const lifetime = try lifetime_from(ca.wall.now_ms(), request.ttl_ms);
        try x509.issue_server(out, ca.key, &.{
            .dns_name = request.dns_name,
            .subject_key = request.subject_key,
            .lifetime = lifetime,
        });
        assert(out.slice().len <= constants.x509_cert_bytes_max);
    }
};

comptime {
    // The CA key signs credentials and X.509 TBS bytes (docs/decisions/2026-11-05-ca-key-shared-
    // with-x509.md): the first bytes differ, so the two sets of signed messages are disjoint.
    const tbs_first_byte: u8 = 0x30; // DER SEQUENCE.
    assert(peer.credential_domain[0] != tbs_first_byte);
}

/// Why a certificate could not be issued: `x509.Error` (a bad name, label or lifetime) or a
/// subject key that is not a usable Ed25519 public key.
pub const CertificateError = x509.Error || error{BadKey};

pub const WorkloadArgs = struct {
    cluster: []const u8,
    service: []const u8,
    subject_key: [32]u8,
    identity: x509_identity.Identity,
    ttl_ms: u64,
};

pub const ServerArgs = struct {
    dns_name: []const u8,
    subject_key: [32]u8,
    ttl_ms: u64,
};

/// The window `[now_ms, now_ms + ttl_ms)`; a sum that overflows is a lifetime out of range.
fn lifetime_from(now_ms: u64, ttl_ms: u64) CertificateError!x509.Lifetime {
    const not_after_ms = std.math.add(u64, now_ms, ttl_ms) catch return error.IssueLifetime;
    return .{ .not_before_ms = now_ms, .not_after_ms = not_after_ms };
}

/// On the curve and in the prime-order subgroup, as `Ca.issue` requires of a node key.
fn check_subject_key(key: [32]u8) error{BadKey}!void {
    const point = Edwards25519.fromBytes(key) catch return error.BadKey;
    point.rejectUnexpectedSubgroup() catch return error.BadKey;
}

test "the revoked list: names, comments, blanks, and refusals" {
    // Goal: the file's format is exactly as docs/peer.md says. Method: parse good and bad text.
    var revoked: Revoked = .{};
    try revoked.parse("# removed\nnode3\n\n  node4  # moved\r\n");
    try std.testing.expectEqual(@as(u32, 2), revoked.count);
    try std.testing.expect(revoked.contains("node3"));
    try std.testing.expect(revoked.contains("node4"));
    try std.testing.expect(!revoked.contains("node"));
    try std.testing.expect(!revoked.contains("node5"));
    try std.testing.expectError(error.BadName, revoked.parse("node3\nBad Name\n"));
    try std.testing.expectEqual(@as(u32, 2), revoked.bad_line);
    try std.testing.expectEqual(@as(u32, 0), revoked.count);
    try revoked.parse("");
    try std.testing.expectEqual(@as(u32, 0), revoked.count);
}

test "the revoked list holds peer_revoked_max names and refuses one more" {
    // Goal: the bound is a refusal, not a silent cut. Method: fill it, then add one.
    const line_bytes = 7; // "n00000\n"
    var buffer: [(constants.peer_revoked_max + 1) * line_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (0..constants.peer_revoked_max + 1) |index| {
        writer.print("n{d:0>5}\n", .{index}) catch unreachable; // Sized above.
    }
    var revoked: Revoked = .{};
    const full = constants.peer_revoked_max * line_bytes;
    try revoked.parse(buffer[0..full]);
    try std.testing.expectEqual(constants.peer_revoked_max, revoked.count);
    try std.testing.expectError(error.TooMany, revoked.parse(writer.buffered()));
}

const TestClock = struct {
    ms: u64,

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    fn now(context: *anyopaque) u64 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        return self.ms;
    }
};

test "the CA signs for a live node, refuses a removed one and a bad key" {
    // Goal: issuance follows the rules in docs/peer.md. Method: issue, verify with the public
    // key at the issue time, then try a removed node and a key that is not on the curve.
    var clock: TestClock = .{ .ms = 1_000_000 };
    var ca: Ca = .{
        .key = try Ed25519.KeyPair.generateDeterministic(@splat(7)),
        .revoked = .{},
        .wall = clock.clock(),
    };
    try ca.revoked.parse("gone\n");
    const node_pair = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const node_key = node_pair.public_key.toBytes();
    const credential = try ca.issue("node1", node_key);
    try std.testing.expectEqual(@as(u64, 1_000_000), credential.not_before_ms);
    try std.testing.expectEqual(
        1_000_000 + constants.peer_credential_ttl_ms,
        credential.not_after_ms,
    );
    try peer.verify(&credential, ca.public(), 1_000_000, "node1");
    try std.testing.expectError(error.Removed, ca.issue("gone", node_key));
    // 32 bytes of 0xff is not a point on the curve.
    const off_curve: [32]u8 = @splat(0xff);
    try std.testing.expectError(error.BadKey, ca.issue("node1", off_curve));
}

test "the CA refuses a small-order key and the identity point" {
    // Goal: finding 8b. Method: the identity (order 1) and the point (0, -1) (order 2) are on
    // the curve and decode, but are in a small subgroup: both are refused as BadKey.
    var clock: TestClock = .{ .ms = 1_000_000 };
    var ca: Ca = .{
        .key = try Ed25519.KeyPair.generateDeterministic(@splat(7)),
        .revoked = .{},
        .wall = clock.clock(),
    };
    var identity: [32]u8 = @splat(0);
    identity[0] = 1; // y = 1, x = 0.
    try std.testing.expectError(error.BadKey, ca.issue("node1", identity));
    var order_two: [32]u8 = @splat(0xff);
    order_two[0] = 0xec; // y = p - 1 = -1, x = 0.
    order_two[31] = 0x7f;
    try std.testing.expectError(error.BadKey, ca.issue("node1", order_two));
}

fn test_ca(clock: *TestClock) !Ca {
    return .{
        .key = try Ed25519.KeyPair.generateDeterministic(@splat(7)),
        .revoked = .{},
        .wall = clock.clock(),
    };
}

fn test_key(seed_byte: u8) ![32]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(seed_byte));
    return pair.public_key.toBytes();
}

const test_identity: x509_identity.Identity = .{
    .image_digest = @splat(0x5a),
    .placement_epoch = 3,
    .labels = &.{.{ .key = "tier", .value = "gold" }},
};

test "the CA issues a CA, a workload and a server certificate that verify at the issue time" {
    // Goal: the three issuers produce what `x509.verify` accepts, from the clock the Ca holds.
    // Method: issue each at a fixed clock, verify under the CA's public key with the expected
    // kind and name, and read the window back.
    var clock: TestClock = .{ .ms = 1_800_000_000_000 };
    const ca = try test_ca(&clock);
    var ca_der: x509.Der = .{};
    try ca.issue_ca_certificate(&ca_der, constants.x509_ca_ttl_ms_max);
    const parsed_ca = try x509.verify(ca_der.slice(), ca.public(), clock.ms, .{
        .kind = .ca,
        .name = null,
    });
    try std.testing.expectEqual(clock.ms, parsed_ca.not_before_ms);
    try std.testing.expectEqual(clock.ms + constants.x509_ca_ttl_ms_max, parsed_ca.not_after_ms);

    var workload_der: x509.Der = .{};
    try ca.issue_workload_certificate(&workload_der, &.{
        .cluster = "prod.example",
        .service = "broker-1",
        .subject_key = try test_key(9),
        .identity = test_identity,
        .ttl_ms = constants.x509_leaf_ttl_ms_max,
    });
    const uri = "spiffe://prod.example/service/broker-1";
    _ = try x509.verify(workload_der.slice(), ca.public(), clock.ms, .{
        .kind = .workload,
        .name = uri,
    });

    var server_der: x509.Der = .{};
    try ca.issue_server_certificate(&server_der, &.{
        .dns_name = "broker.example.com",
        .subject_key = try test_key(10),
        .ttl_ms = 60_000,
    });
    const parsed_server = try x509.verify(server_der.slice(), ca.public(), clock.ms, .{
        .kind = .server,
        .name = "broker.example.com",
    });
    try std.testing.expectEqual(clock.ms + 60_000, parsed_server.not_after_ms);
    // A leaf is not a CA and the other way round: the kinds are not interchangeable.
    try std.testing.expectError(error.WrongUse, x509.verify(
        workload_der.slice(),
        ca.public(),
        clock.ms,
        .{ .kind = .server, .name = null },
    ));
}

test "the CA refuses lifetimes over the bound, overflow, bad names and bad subject keys" {
    // Goal: every refusal is an error, never a certificate that outlives its bound. Method:
    // one case per kind at the bound and one past it; the clock near u64 max; a name that is not
    // a service name; the identity point and an off-curve key as subject.
    var clock: TestClock = .{ .ms = 1_800_000_000_000 };
    const ca = try test_ca(&clock);
    var out: x509.Der = .{};
    try ca.issue_ca_certificate(&out, constants.x509_ca_ttl_ms_max);
    try std.testing.expectError(
        error.IssueLifetime,
        ca.issue_ca_certificate(&out, constants.x509_ca_ttl_ms_max + 1000),
    );
    try std.testing.expectError(error.IssueLifetime, ca.issue_ca_certificate(&out, 0));
    var args: WorkloadArgs = .{
        .cluster = "prod.example",
        .service = "broker-1",
        .subject_key = try test_key(9),
        .identity = test_identity,
        .ttl_ms = constants.x509_leaf_ttl_ms_max,
    };
    try ca.issue_workload_certificate(&out, &args);
    args.ttl_ms += 1000;
    try std.testing.expectError(error.IssueLifetime, ca.issue_workload_certificate(&out, &args));
    args.ttl_ms = 1000;
    args.service = "Bad Name";
    try std.testing.expectError(error.BadServiceName, ca.issue_workload_certificate(&out, &args));
    args.service = "broker-1";
    args.subject_key = @splat(0xff); // Not a point on the curve.
    try std.testing.expectError(error.BadKey, ca.issue_workload_certificate(&out, &args));
    var identity_point: [32]u8 = @splat(0);
    identity_point[0] = 1; // y = 1: the identity, order 1.
    const server_args: ServerArgs = .{
        .dns_name = "broker.example.com",
        .subject_key = identity_point,
        .ttl_ms = 1000,
    };
    try std.testing.expectError(error.BadKey, ca.issue_server_certificate(&out, &server_args));
    var late: TestClock = .{ .ms = std.math.maxInt(u64) - 10 };
    const late_ca = try test_ca(&late);
    try std.testing.expectError(error.IssueLifetime, late_ca.issue_ca_certificate(&out, 1000));
}

test "the peer credential is byte for byte what it was before X.509 shared the key" {
    // Goal: the 185-byte format is untouched. Method: issue with fixed inputs and compare the
    // whole encoding with a golden captured from the code before this change (git show
    // a9782bf:src/peer.zig is identical to today's); check each field's offset and the signed
    // message's layout.
    const ca_pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const node_key = try test_key(9);
    const ttl_ms = constants.peer_credential_ttl_ms;
    const credential = peer.issue(ca_pair, "node1", node_key, 1_000_000, 1_000_000 + ttl_ms);
    const bytes = peer.encode(&credential);
    try std.testing.expectEqual(@as(usize, 185), bytes.len);
    try std.testing.expectEqual(@as(u8, 1), bytes[0]);
    const key_id = peer.ca_key_id(ca_pair.public_key.toBytes());
    try std.testing.expectEqualSlices(u8, &key_id, bytes[1..9]);
    try std.testing.expectEqual(@as(u8, 5), bytes[9]);
    try std.testing.expectEqualSlices(u8, "node1", bytes[10..15]);
    for (bytes[15..73]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const golden =
        "01fe812c12f3ab4ce6056e6f64653100000000000000000000000000000000000000000000000000" ++
        "000000000000000000000000000000000000000000000000000000000000000000fd1724385aa0c7" ++
        "5b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f61840420f0000000000409e3505000000" ++
        "007cb98e5092d78bd5cf0cbdb0652a55487d075bbf11dc702a51c4441fbad8d3c5ca24748c458fab" ++
        "d43869f73338d81b233ed24ef37224ed70881f1debe04e1505";
    var hex: [370]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{&bytes});
    try std.testing.expectEqualStrings(golden, &hex);
}

test "a credential's signed message and a certificate's are disjoint, and signatures do not cross" {
    // Goal: the argument in docs/decisions/2026-11-05-ca-key-shared-with-x509.md. Method: for
    // each kind of certificate the TBS starts 0x30 and not with the credential domain; the
    // credential's signed message starts with the domain and never 0x30; a credential signature put
    // in a certificate and a certificate signature put in a credential are each refused with
    // the bad-signature error of their own format.
    var clock: TestClock = .{ .ms = 1_800_000_000_000 };
    const ca = try test_ca(&clock);
    var ca_der: x509.Der = .{};
    var workload_der: x509.Der = .{};
    var server_der: x509.Der = .{};
    try ca.issue_ca_certificate(&ca_der, 1000);
    try ca.issue_workload_certificate(&workload_der, &.{
        .cluster = "prod.example",
        .service = "a",
        .subject_key = try test_key(9),
        .identity = test_identity,
        .ttl_ms = 1000,
    });
    try ca.issue_server_certificate(&server_der, &.{
        .dns_name = "a.b",
        .subject_key = try test_key(10),
        .ttl_ms = 1000,
    });
    const credential = try ca.issue("node1", try test_key(9));
    const body = peer.encode(&credential)[0..peer.credential_body_bytes];
    var message: [peer.credential_domain.len + peer.credential_body_bytes]u8 = undefined;
    @memcpy(message[0..peer.credential_domain.len], peer.credential_domain);
    @memcpy(message[peer.credential_domain.len..], body);
    try std.testing.expectEqual(@as(u8, 'z'), message[0]);
    try std.testing.expect(message[0] != 0x30);
    // The credential's signature is over exactly this message, so the layout above is the real one.
    const signature = Ed25519.Signature.fromBytes(credential.signature);
    try signature.verify(&message, ca.key.public_key);

    for ([_]*const x509.Der{ &ca_der, &workload_der, &server_der }) |certificate| {
        const parsed = try x509.parse(certificate.slice());
        const tbs = parsed.tbs.of(certificate.slice());
        try std.testing.expectEqual(@as(u8, 0x30), tbs[0]);
        try std.testing.expect(!std.mem.startsWith(u8, tbs, peer.credential_domain));
        try std.testing.expect(tbs.len > peer.credential_domain.len);
        // The certificate's signature is not valid over the credential message, nor the
        // credential's over this TBS.
        const cert_signature_bytes = parsed.signature.of(certificate.slice())[0..64].*;
        const cert_signature = Ed25519.Signature.fromBytes(cert_signature_bytes);
        const refused = error.SignatureVerificationFailed;
        try std.testing.expectError(refused, cert_signature.verify(&message, ca.key.public_key));
        try std.testing.expectError(refused, signature.verify(tbs, ca.key.public_key));
        // Swapped into the other format, each is refused as a bad signature of that format.
        var swapped = credential;
        swapped.signature = cert_signature.toBytes();
        const credential_result = peer.verify(&swapped, ca.public(), clock.ms, null);
        try std.testing.expectError(error.BadSignature, credential_result);
        var forged: x509.Der = .{};
        @memcpy(forged.bytes[0..certificate.slice().len], certificate.slice());
        forged.start = 0;
        const bytes = forged.bytes[0..certificate.slice().len];
        @memcpy(bytes[parsed.signature.start..parsed.signature.end], &credential.signature);
        try std.testing.expectError(error.BadSignature, x509.verify(bytes, ca.public(), clock.ms, .{
            .kind = parsed.kind,
            .name = null,
        }));
    }
}
