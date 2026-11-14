//! Tests of the browser path's certificates (`x509_p256.zig`): the exact bytes of each kind, the
//! near-miss table, the rows of the rule that the two CAs never sign across paths, the ECDSA
//! signature's strict DER and low S, a seeded fuzzer and the teeth. No file or clock: runs under
//! WASI too, except the fuzzer, which reads its seed from the environment.

const std = @import("std");
const builtin = @import("builtin");
const p256 = @import("x509_p256.zig");
const x509 = @import("x509.zig");
const t = @import("x509_test.zig");
const constants = @import("constants.zig");

const testing = std.testing;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const now = t.now;
pub const hour = t.hour;
pub const cluster = "prod";

pub fn key(seed_byte: u8) !p256.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(@splat(seed_byte));
}

pub fn ca_key() !p256.KeyPair {
    return key(0xB0);
}

pub const leaf_lifetime: p256.Lifetime = .{
    .not_before_ms = now - hour,
    .not_after_ms = now + hour,
};

pub fn make_ca(out: *p256.Der) !void {
    try p256.issue_ca(out, try ca_key(), .{
        .not_before_ms = now - hour,
        .not_after_ms = now + 24 * hour,
    });
}

const loopback = [_]u8{ 127, 0, 0, 1 };
const sans = [_]p256.San{ .{ .dns = "zcube.example" }, .{ .ip = &loopback } };

pub fn make_server(out: *p256.Der) !void {
    try p256.issue_server(out, try ca_key(), &.{
        .dns_name = "localhost",
        .sans = &sans,
        .subject_key = p256.point_of(try key(0xB1)),
        .lifetime = leaf_lifetime,
    });
}

pub fn make_client(out: *p256.Der) !void {
    try p256.issue_client(out, try ca_key(), &.{
        .cluster = cluster,
        .client = "alice",
        .scope = .jobs,
        .subject_key = p256.point_of(try key(0xB2)),
        .lifetime = leaf_lifetime,
    });
}

fn digest_hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "browser templates: each kind's exact bytes are fixed" {
    // Goal: the writer's output is a template, so any change to it is seen. Method: SHA-256 of
    // each kind's certificate from fixed keys (ECDSA here is deterministic, RFC 6979 style).
    var certificates: [3]p256.Der = @splat(.{});
    try make_ca(&certificates[0]);
    try make_server(&certificates[1]);
    try make_client(&certificates[2]);
    const expected = [3][]const u8{ golden_ca, golden_server, golden_client };
    for (&certificates, expected) |*certificate, golden| {
        try testing.expectEqualStrings(golden, &digest_hex(certificate.slice()));
    }
}

const golden_ca = "d0c2790e734c1e63b834728ae6b17e210f1873e160145b91b1afc53f09e8aa78";
const golden_server = "f5cacbc6c8e86bf65841139a72e1f0eaf4ecfd19efdce04191b5d88d48d04ba3";
const golden_client = "f32f9e17ad71ad0b69d6b298c94f20e3bd47a520a02e8a2e1b8eee04ca1f7223";

test "browser certificates parse, verify and give back their own bytes" {
    // Goal: each kind round-trips and verifies against the browser CA. Method: issue, verify
    // with the expected kind and name, reencode.
    var ca: p256.Der = .{};
    var server: p256.Der = .{};
    var client: p256.Der = .{};
    try make_ca(&ca);
    try make_server(&server);
    try make_client(&client);
    const anchor = p256.point_of(try ca_key());
    const parsed_ca = try p256.verify(ca.slice(), anchor, now, .{ .kind = .ca, .name = null });
    try testing.expectEqual(p256.Kind.ca, parsed_ca.kind);
    const expect_server: p256.Expect = .{ .kind = .server, .name = "localhost" };
    const parsed_server = try p256.verify(server.slice(), anchor, now, expect_server);
    const server_point = parsed_server.point(server.slice());
    try testing.expectEqualSlices(u8, &p256.point_of(try key(0xB1)), &server_point);
    const uri = "spiffe://prod/client/alice";
    const parsed = try p256.verify(client.slice(), anchor, now, .{ .kind = .client, .name = uri });
    try testing.expectEqual(x509.Scope.jobs, parsed.scope(client.slice()));
    for ([_]*const p256.Der{ &ca, &server, &client }) |certificate| {
        const bytes = certificate.slice();
        var again: p256.Der = .{};
        try p256.reencode(&again, bytes, &(try p256.parse(bytes)));
        try testing.expectEqualSlices(u8, bytes, again.slice());
    }
}

test "the browser server certificate carries every --tls-san, the first DNS name first" {
    // Goal: the SAN list is the tls-name, then each --tls-san in order, IPs as 4 or 16 bytes.
    // Method: issue with a DNS name and an IPv4 address and read the GeneralNames back.
    var server: p256.Der = .{};
    try make_server(&server);
    const bytes = server.slice();
    const parsed = try p256.parse(bytes);
    const names = parsed.names.of(bytes);
    const want = [_]u8{0x82} ++ [_]u8{9} ++ "localhost".* ++ [_]u8{ 0x82, 13 } ++
        "zcube.example".* ++ [_]u8{ 0x87, 4, 127, 0, 0, 1 };
    try testing.expectEqualSlices(u8, &want, names);
    var out: p256.Der = .{};
    const bad_ip = [_]p256.San{.{ .ip = &.{ 1, 2, 3 } }};
    const ca = try ca_key();
    const point = p256.point_of(try key(0xB1));
    try testing.expectError(error.BadDnsName, p256.issue_server(&out, ca, &.{
        .dns_name = "localhost",
        .sans = &bad_ip,
        .subject_key = point,
        .lifetime = leaf_lifetime,
    }));
    const bad_dns = [_]p256.San{.{ .dns = "no spaces" }};
    try testing.expectError(error.BadDnsName, p256.issue_server(&out, ca, &.{
        .dns_name = "localhost",
        .sans = &bad_dns,
        .subject_key = point,
        .lifetime = leaf_lifetime,
    }));
}

/// `bytes` with the first `needle` replaced by `replacement` (same length).
fn edited(buffer: []u8, bytes: []const u8, needle: []const u8, replacement: []const u8) []u8 {
    std.debug.assert(needle.len == replacement.len);
    @memcpy(buffer[0..bytes.len], bytes);
    const at = std.mem.indexOf(u8, bytes, needle) orelse @panic("needle not found");
    @memcpy(buffer[at..][0..needle.len], replacement);
    return buffer[0..bytes.len];
}

const NearMiss = struct {
    name: []const u8,
    kind: p256.Kind,
    needle: []const u8,
    replacement: []const u8,
    want: x509.Error,
};

const ecdsa_sha256_oid_tail = [_]u8{ 0x3D, 0x04, 0x03, 0x02 };
const p256_curve_oid = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };

const near_misses = [_]NearMiss{
    .{
        .name = "ecdsa-with-SHA384",
        .kind = .client,
        .needle = &ecdsa_sha256_oid_tail,
        .replacement = &.{ 0x3D, 0x04, 0x03, 0x03 },
        .want = error.BadAlgorithm,
    },
    .{
        .name = "another curve",
        .kind = .client,
        .needle = &p256_curve_oid,
        .replacement = &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x08 },
        .want = error.BadAlgorithm,
    },
    .{
        .name = "server relabelled clientAuth",
        .kind = .server,
        .needle = &.{ 0x05, 0x07, 0x03, 0x01 },
        .replacement = &.{ 0x05, 0x07, 0x03, 0x02 },
        .want = error.BadSan,
    },
    .{
        .name = "client relabelled serverAuth",
        .kind = .client,
        .needle = &.{ 0x05, 0x07, 0x03, 0x02 },
        .replacement = &.{ 0x05, 0x07, 0x03, 0x01 },
        .want = error.BadSan,
    },
    .{
        .name = "no extended key usage purpose",
        .kind = .client,
        .needle = &.{ 0x05, 0x07, 0x03, 0x02 },
        .replacement = &.{ 0x05, 0x07, 0x03, 0x04 },
        .want = error.BadExtension,
    },
    .{
        .name = "issuer not a browser CA name",
        .kind = .client,
        .needle = "zcube-browser-ca-",
        .replacement = "zcube-browsex-ca-",
        .want = error.BadName,
    },
    .{
        .name = "issuer the cluster CA's name",
        .kind = .client,
        .needle = "zcube-browser-ca-",
        .replacement = "zcube-ca-12345678",
        .want = error.BadName,
    },
    .{
        .name = "a node's SPIFFE path",
        .kind = .client,
        .needle = "/client/alice",
        .replacement = "/node/aaalice",
        .want = error.BadSan,
    },
    .{
        .name = "subject not the SPIFFE name",
        .kind = .client,
        .needle = "alice",
        .replacement = "alicf",
        .want = error.BadName,
    },
    .{
        .name = "a scope that does not exist",
        .kind = .client,
        .needle = &.{ 0x0A, 0x01, 0x01 },
        .replacement = &.{ 0x0A, 0x01, 0x07 },
        .want = error.BadIdentity,
    },
    .{
        .name = "a SAN DNS name with a space",
        .kind = .server,
        .needle = "zcube.example",
        .replacement = "zcube example",
        .want = error.BadSan,
    },
    .{
        .name = "an IP of 3 bytes and a DNS of 2",
        .kind = .server,
        .needle = &.{ 0x87, 4, 127, 0 },
        .replacement = &.{ 0x87, 3, 0x82, 0x01 },
        .want = error.BadSan,
    },
    .{
        .name = "a version of v2",
        .kind = .ca,
        .needle = &.{ 0xA0, 0x03, 0x02, 0x01, 0x02 },
        .replacement = &.{ 0xA0, 0x03, 0x02, 0x01, 0x01 },
        .want = error.Malformed,
    },
    .{
        .name = "a non-critical basicConstraints",
        .kind = .ca,
        .needle = &.{ 0x01, 0x01, 0xFF, 0x04, 0x08 },
        .replacement = &.{ 0x01, 0x01, 0x00, 0x04, 0x08 },
        .want = error.Malformed,
    },
};

fn make_kind(out: *p256.Der, kind: p256.Kind) !void {
    switch (kind) {
        .ca => try make_ca(out),
        .server => try make_server(out),
        .client => try make_client(out),
    }
}

test "browser near misses: each one-edit certificate gets its own refusal" {
    // Goal: the parser refuses each near miss for the named reason. Method: one same-length edit
    // of a good certificate per row; parse comes before the signature, so the signature stays.
    for (near_misses) |row| {
        var good: p256.Der = .{};
        try make_kind(&good, row.kind);
        var buffer: [constants.x509_cert_bytes_max]u8 = undefined;
        const bad = edited(&buffer, good.slice(), row.needle, row.replacement);
        if (p256.parse(bad)) |_| {
            std.debug.print("near miss accepted: {s}\n", .{row.name});
            return error.NearMissAccepted;
        } else |err| {
            if (err != row.want) std.debug.print("{s}: {t}\n", .{ row.name, err });
            try testing.expectEqual(row.want, err);
        }
    }
}

test "browser near misses: a trailing byte, a short read and a negative serial" {
    // Goal: the outer shape is strict. Method: append, truncate, and set the serial's sign bit.
    var good: p256.Der = .{};
    try make_client(&good);
    const bytes = good.slice();
    var buffer: [constants.x509_cert_bytes_max + 1]u8 = undefined;
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    try testing.expectError(error.Malformed, p256.parse(buffer[0 .. bytes.len + 1]));
    try testing.expectError(error.Malformed, p256.parse(bytes[0 .. bytes.len - 1]));
    const parsed = try p256.parse(bytes);
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[parsed.serial.start] |= 0x80;
    try testing.expectError(error.BadSerial, p256.parse(buffer[0..bytes.len]));
}

test "cross path: the browser and cluster profiles refuse each other's certificates" {
    // Goal: the CAs never sign across paths (decision 2026-11-14). Method: an Ed25519 client and
    // node certificate fed to the browser parser, a browser client fed to the cluster parser,
    // and a browser server verified as a client.
    var cluster_client: x509.Der = .{};
    try t.make_client(&cluster_client);
    try testing.expectError(error.BadAlgorithm, p256.parse(cluster_client.slice()));
    var cluster_node: x509.Der = .{};
    try t.make_node(&cluster_node);
    try testing.expectError(error.BadAlgorithm, p256.parse(cluster_node.slice()));
    var browser_client: p256.Der = .{};
    try make_client(&browser_client);
    try testing.expectError(error.BadAlgorithm, x509.parse(browser_client.slice()));
    const cluster_anchor = (try t.ca_pair()).public_key.toBytes();
    const as_node: x509.Expect = .{ .kind = .node, .name = null };
    try testing.expectError(
        error.BadAlgorithm,
        x509.verify(browser_client.slice(), cluster_anchor, now, as_node),
    );
    var server: p256.Der = .{};
    try make_server(&server);
    const anchor = p256.point_of(try ca_key());
    const as_client: p256.Expect = .{ .kind = .client, .name = null };
    try testing.expectError(error.WrongUse, p256.verify(server.slice(), anchor, now, as_client));
}

test "cross path: a browser certificate from another browser CA is refused" {
    // Goal: each cluster's browser CA is its own anchor. Method: issue under another key with
    // the same names; verify against this cluster's anchor.
    var other: p256.Der = .{};
    try p256.issue_client(&other, try key(0xC0), &.{
        .cluster = cluster,
        .client = "alice",
        .scope = .admin,
        .subject_key = p256.point_of(try key(0xB2)),
        .lifetime = leaf_lifetime,
    });
    const anchor = p256.point_of(try ca_key());
    const expect: p256.Expect = .{ .kind = .client, .name = null };
    try testing.expectError(error.WrongIssuer, p256.verify(other.slice(), anchor, now, expect));
}

/// A certificate signed by `forger` that names this cluster's browser CA as its issuer.
fn forged_client(out: *p256.Der, forger: p256.KeyPair) !void {
    var good: p256.Der = .{};
    try make_client(&good);
    const bytes = good.slice();
    const parsed = try p256.parse(bytes);
    var signature_buffer: [p256.signature_der_bytes_max]u8 = undefined;
    const signature = p256.sign(forger, parsed.tbs.of(bytes));
    const der_bytes = p256.signature_write(&signature_buffer, signature);
    try p256.reencode_signed(out, bytes, &parsed, der_bytes);
}

/// Forged signature, server as client, expired: each must be refused.
fn verification_checks() !void {
    const anchor = p256.point_of(try ca_key());
    const expect: p256.Expect = .{ .kind = .client, .name = null };
    var forged: p256.Der = .{};
    try forged_client(&forged, try key(0xC1));
    if (p256.verify(forged.slice(), anchor, now, expect)) |_| return error.Forged else |_| {}
    var server: p256.Der = .{};
    try make_server(&server);
    if (p256.verify(server.slice(), anchor, now, expect)) |_| return error.Kind else |_| {}
    var client: p256.Der = .{};
    try make_client(&client);
    _ = try p256.verify(client.slice(), anchor, now, expect);
    const late = now + 3 * hour;
    if (p256.verify(client.slice(), anchor, late, expect)) |_| return error.Expired else |_| {}
}

test "browser verification: a forged signature, the wrong kind and an expired one are refused" {
    // Goal: verify checks issuer signature, kind and window. Method: `verification_checks`.
    try verification_checks();
}

test "teeth: with a browser certificate check skipped a bad certificate verifies" {
    // Goal: each check in `p256.verify` has teeth. Method: skip each in turn; the checks fail.
    for (std.enums.values(p256.TestFault)) |fault| {
        p256.set_test_fault(fault, true);
        defer p256.set_test_fault(fault, false);
        try testing.expect(std.meta.isError(verification_checks()));
    }
}

test "ECDSA: low S is required in certificates, and every non-canonical DER is refused" {
    // Goal: no second encoding of a signature is accepted, where std's `fromDer` and `verify`
    // accept some (a padded INTEGER; a high S). Method: find a high-S signature from std, check
    // both rules on it and on its low twin, then hand-made non-canonical encodings.
    const signer = try key(0xD0);
    var high: ?Ecdsa.Signature = null;
    var message: [1]u8 = undefined;
    for (0..64) |index| {
        message[0] = @intCast(index);
        const raw = try signer.sign(&message, null);
        if (!std.mem.eql(u8, &p256.low_s(raw).s, &raw.s)) {
            high = raw;
            break;
        }
    }
    const raw = high orelse return error.NoHighS;
    var buffer: [p256.signature_der_bytes_max]u8 = undefined;
    const high_der = p256.signature_write(&buffer, raw);
    const point = p256.point_of(signer);
    try raw.verify(&message, signer.public_key); // std accepts the high S.
    try testing.expectError(error.BadSignature, p256.signature_parse(high_der, .low_s));
    try p256.signature_verify(point, &message, high_der, .any_s);
    var low_buffer: [p256.signature_der_bytes_max]u8 = undefined;
    const low_der = p256.signature_write(&low_buffer, p256.low_s(raw));
    try p256.signature_verify(point, &message, low_der, .low_s);

    // A needless leading zero on r: std's `fromDer` takes it, strict DER does not.
    var padded: [p256.signature_der_bytes_max + 1]u8 = undefined;
    const r_len = low_der[3];
    if (low_der[4] & 0x80 == 0) {
        padded[0] = 0x30;
        padded[1] = low_der[1] + 1;
        padded[2] = 0x02;
        padded[3] = r_len + 1;
        padded[4] = 0x00;
        @memcpy(padded[5..][0 .. low_der.len - 4], low_der[4..]);
        const bad = padded[0 .. low_der.len + 1];
        try testing.expectError(error.BadSignature, p256.signature_parse(bad, .any_s));
    }
    const zero = [_]u8{ 0x30, 0x06, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01 };
    try testing.expectError(error.BadSignature, p256.signature_parse(&zero, .any_s));
    const negative = [_]u8{ 0x30, 0x06, 0x02, 0x01, 0x81, 0x02, 0x01, 0x01 };
    try testing.expectError(error.BadSignature, p256.signature_parse(&negative, .any_s));
    const trailing = [_]u8{ 0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x00 };
    try testing.expectError(error.BadSignature, p256.signature_parse(&trailing, .any_s));
}

test "ECDSA: a certificate whose signature has a high S is refused" {
    // Goal: the certificate rule is low S (one encoding per certificate). Method: rewrite a good
    // client's signature with n - s; parse refuses it.
    var good: p256.Der = .{};
    try make_client(&good);
    const bytes = good.slice();
    const parsed = try p256.parse(bytes);
    const low = try p256.signature_parse(parsed.signature.of(bytes), .low_s);
    const high: Ecdsa.Signature = .{ .r = low.r, .s = p256.negate(low.s) };
    var buffer: [p256.signature_der_bytes_max]u8 = undefined;
    var out: p256.Der = .{};
    try p256.reencode_signed(&out, bytes, &parsed, p256.signature_write(&buffer, high));
    try testing.expectError(error.BadSignature, p256.parse(out.slice()));
}

/// The P-256 group order n, as the near misses below need it (`x509_p256.order` is private).
const order_bytes = [32]u8{
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
};

/// A DER signature of r and s, each 32 bytes written as a 33-byte INTEGER (a zero first: n's top
/// bit is set) or, when null, as the one-byte INTEGER 1.
fn signature_der(out: *[72]u8, r: ?[32]u8, s: ?[32]u8) []const u8 {
    var at: usize = 2;
    for ([_]?[32]u8{ r, s }) |value| {
        out[at] = 0x02;
        if (value) |v| {
            out[at + 1] = 33;
            out[at + 2] = 0x00;
            out[at + 3 ..][0..32].* = v;
            at += 35;
        } else {
            out[at + 1] = 1;
            out[at + 2] = 1;
            at += 3;
        }
    }
    out[0] = 0x30;
    out[1] = @intCast(at - 2);
    return out[0..at];
}

test "ECDSA: r or s equal to n or n + 1 is refused, though each is canonical DER" {
    // Goal: the range check (r and s below n) has teeth on its edge, where the DER itself is
    // canonical. Method: r = n, r = n + 1, s = n, s = n + 1 under the lenient rule; then n - 1,
    // which passes the parse (it is in range), so the rows fail only on the range.
    var n_plus_one = order_bytes;
    n_plus_one[31] += 1;
    var n_minus_one = order_bytes;
    n_minus_one[31] -= 1;
    var buffer: [72]u8 = undefined;
    for ([_][32]u8{ order_bytes, n_plus_one }) |edge| {
        const r_edge = signature_der(&buffer, edge, null);
        try testing.expectError(error.BadSignature, p256.signature_parse(r_edge, .any_s));
        const s_edge = signature_der(&buffer, null, edge);
        try testing.expectError(error.BadSignature, p256.signature_parse(s_edge, .any_s));
    }
    _ = try p256.signature_parse(signature_der(&buffer, n_minus_one, null), .any_s);
    _ = try p256.signature_parse(signature_der(&buffer, null, n_minus_one), .any_s);
}

test "browser near miss: a subject key with y off by one is no point, and is refused" {
    // Goal: the on-curve check of the SubjectPublicKeyInfo has teeth. Method: add one to the last
    // byte of a good client's y (no other change); parse refuses it as malformed.
    var good: p256.Der = .{};
    try make_client(&good);
    const parsed = try p256.parse(good.slice());
    var buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    const bytes = buffer[0..good.slice().len];
    @memcpy(bytes, good.slice());
    const last = parsed.public_key.end - 1;
    try testing.expect(bytes[last] != 0xFF); // One more is y + 1, with no carry.
    bytes[last] += 1;
    try testing.expectError(error.Malformed, p256.parse(bytes));
}

test "browser verification: a CA certificate with the anchor's name and another key is refused" {
    // Goal: a CA certificate must hold the anchor's own key, not only its name and signature.
    // Method: the anchor's CA certificate with another subject key, signed again by the anchor's
    // key (so name and signature are right); verify refuses it as the wrong issuer.
    var good: p256.Der = .{};
    try make_ca(&good);
    const original = try p256.parse(good.slice());
    var buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    const swapped = buffer[0..good.slice().len];
    @memcpy(swapped, good.slice());
    const other = p256.point_of(try key(0xB3));
    @memcpy(swapped[original.public_key.start..original.public_key.end], &other);
    const parsed = try p256.parse(swapped);
    var signature_buffer: [p256.signature_der_bytes_max]u8 = undefined;
    const signature = p256.sign(try ca_key(), parsed.tbs.of(swapped));
    var resigned: p256.Der = .{};
    const der_bytes = p256.signature_write(&signature_buffer, signature);
    try p256.reencode_signed(&resigned, swapped, &parsed, der_bytes);
    const anchor = p256.point_of(try ca_key());
    const expect: p256.Expect = .{ .kind = .ca, .name = null };
    _ = try p256.verify(good.slice(), anchor, now, expect);
    const result = p256.verify(resigned.slice(), anchor, now, expect);
    try testing.expectError(error.WrongIssuer, result);
}

test "browser verification: expiry is at not_after plus the skew, not a millisecond later" {
    // Goal: the window's end is exclusive (`now >= not_after + skew` is expired). Method: verify
    // a good client one millisecond before that instant and at it.
    var client: p256.Der = .{};
    try make_client(&client);
    const parsed = try p256.parse(client.slice());
    const anchor = p256.point_of(try ca_key());
    const expect: p256.Expect = .{ .kind = .client, .name = null };
    const end = parsed.not_after_ms + constants.peer_clock_skew_ms;
    _ = try p256.verify(client.slice(), anchor, end - 1, expect);
    try testing.expectError(error.Expired, p256.verify(client.slice(), anchor, end, expect));
}

// ---- Fuzz ----------------------------------------------------------------------------------

const seeds = if (builtin.os.tag == .wasi) struct {} else @import("fuzz_seeds.zig");

fn fuzz_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const kind = random.enumValue(p256.Kind);
    var good: p256.Der = .{};
    try make_kind(&good, kind);
    const original = good.slice();
    var buffer: [constants.x509_cert_bytes_max + 64]u8 = undefined;
    @memcpy(buffer[0..original.len], original);
    var length = original.len;
    for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
        if (length == 0) break; // Truncated to nothing: no byte is left to damage.
        switch (random.uintLessThan(u8, 3)) {
            0 => buffer[random.uintLessThan(usize, length)] ^= @as(u8, 1) << random.int(u3),
            1 => buffer[random.uintLessThan(usize, length)] = random.int(u8),
            else => length = random.uintLessThan(usize, length + 1),
        }
    }
    const damaged = buffer[0..length];
    const anchor = p256.point_of(try ca_key());
    if (p256.parse(damaged)) |parsed| {
        var again: p256.Der = .{};
        try p256.reencode(&again, damaged, &parsed);
        try testing.expectEqualSlices(u8, damaged, again.slice());
        if (!std.mem.eql(u8, damaged, original)) {
            const expect: p256.Expect = .{ .kind = kind, .name = null };
            if (p256.verify(damaged, anchor, now, expect)) |_|
                return error.AcceptedDamaged
            else |_| {}
        }
    } else |_| {}
    var noise: [128]u8 = undefined;
    random.bytes(&noise);
    if (p256.parse(noise[0..random.uintAtMost(usize, noise.len)])) |_| {
        return error.AcceptedNoise;
    } else |_| {}
}

test "fuzz: damaged browser certificates are refused, never accepted, never crash" {
    // Goal: whatever parses is the writer's own encoding, and nothing damaged verifies. Method:
    // seeded damage of good certificates of each kind (`fuzz_seeds.zig` prints the replay).
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    try seeds.run("x509_p256 fuzz", 200, fuzz_once);
}
