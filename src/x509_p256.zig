//! X.509 v3 certificates on the browser path, ECDSA P-256 with SHA-256 only (B7 slice 6, decision
//! file 2026-11-14-b7-slice6-console-over-tls.md; docs/mtls.md, "The browser path"). Browsers
//! offer no Ed25519 in TLS, so each cluster keeps a second CA, the browser CA, beside the
//! Ed25519 cluster CA. Core code, as `x509.zig`: no allocation, no clock value, no randomness.
//!
//! The browser profile has three kinds, `ca`, `server` and `client`, and no other. There is no
//! node or workload kind: a browser-CA certificate can never be a node certificate, and this
//! parser refuses every Ed25519 certificate (its algorithm), so an Ed25519 client certificate
//! never chains to the browser CA. The CAs never sign across paths.
//!
//! Exact bytes, as the `cluster` profile: the parser reads the fields, writes the certificate
//! again with the signature it carries, and refuses it unless that gives back the input. The
//! signature itself is strict DER (`signature_parse`): minimal positive INTEGERs, 1 <= r, s < n,
//! and in a certificate a low S (s <= n / 2). The writer always makes a low S.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const constants = @import("constants.zig");
const der = @import("x509_der.zig");
const identity_mod = @import("x509_identity.zig");
const x509 = @import("x509.zig");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Span = der.Span;

pub const Error = x509.Error;
pub const Der = x509.Der;
pub const Lifetime = x509.Lifetime;
pub const Scope = identity_mod.Scope;
pub const KeyPair = Ecdsa.KeyPair;

/// A P-256 public key as `x || y`, 32 bytes each (the uncompressed point without its 0x04).
pub const Point = [64]u8;

pub const Kind = enum { ca, server, client };
pub const Kinds = std.EnumSet(Kind);

// ---- Fixed encodings ---------------------------------------------------------------------------

/// AlgorithmIdentifier { ecdsa-with-SHA256 }, parameters absent (RFC 5758).
const algorithm_ecdsa_sha256 = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02,
};
/// SubjectPublicKeyInfo's header for id-ecPublicKey on prime256v1, up to the 0x04 of an
/// uncompressed point; the 64 point bytes follow (RFC 5480).
const spki_prefix = [_]u8{
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08,
    0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
};
const oid_common_name = [_]u8{ 0x55, 0x04, 0x03 };
const oid_basic_constraints = [_]u8{ 0x55, 0x1D, 0x13 };
const oid_key_usage = [_]u8{ 0x55, 0x1D, 0x0F };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1D, 0x25 };
const oid_subject_alt_name = [_]u8{ 0x55, 0x1D, 0x11 };
const basic_ca = [_]u8{ 0x30, 0x06, 0x01, 0x01, 0xFF, 0x02, 0x01, 0x00 };
const basic_leaf = [_]u8{ 0x30, 0x00 };
const usage_ca = [_]u8{ 0x03, 0x02, 0x02, 0x04 };
const usage_leaf = [_]u8{ 0x03, 0x02, 0x07, 0x80 };
const usage_client = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02,
};
const usage_server = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01,
};
const version_v3 = [_]u8{ 0xA0, 0x03, 0x02, 0x01, 0x02 };
const tag_context_0: u8 = 0xA0;
const tag_context_3: u8 = 0xA3;
pub const tag_san_dns: u8 = 0x82;
pub const tag_san_uri: u8 = 0x86;
pub const tag_san_ip: u8 = 0x87;

/// The group order n of P-256, big-endian.
const order = [32]u8{
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
};
/// floor(n / 2): the largest low S.
const order_half = [32]u8{
    0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42, 0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
};

/// A DER ECDSA-Sig-Value is at most 72 bytes: two 33-byte INTEGERs with headers in a SEQUENCE.
pub const signature_der_bytes_max = 72;

pub const ca_cn_prefix = "zcube-browser-ca-";
pub const ca_cn_bytes = ca_cn_prefix.len + 16;

comptime {
    assert(ca_cn_bytes <= constants.x509_cn_bytes_max);
    assert(spki_prefix.len + 64 == 91);
    assert(signature_der_bytes_max == Ecdsa.Signature.der_encoded_length_max);
}

/// The browser CA's subject: `zcube-browser-ca-` and 16 hex digits of SHA-256 of its point.
/// A different prefix from the cluster CA's, so neither CA's name can stand for the other.
pub fn ca_cn(ca_public: Point) [ca_cn_bytes]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&ca_public, &digest, .{});
    var out: [ca_cn_bytes]u8 = undefined;
    @memcpy(out[0..ca_cn_prefix.len], ca_cn_prefix);
    out[ca_cn_prefix.len..][0..16].* = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return out;
}

/// The point of a key pair, as `x || y`.
pub fn point_of(key: KeyPair) Point {
    const sec1 = key.public_key.toUncompressedSec1();
    assert(sec1[0] == 0x04);
    return sec1[1..65].*;
}

fn public_key_of(point: Point) Error!Ecdsa.PublicKey {
    var sec1: [65]u8 = undefined;
    sec1[0] = 0x04;
    sec1[1..65].* = point;
    return Ecdsa.PublicKey.fromSec1(&sec1) catch error.BadSignature;
}

// ---- Signatures --------------------------------------------------------------------------------

pub const SignatureRule = enum {
    /// In a certificate this profile writes: s <= n / 2.
    low_s,
    /// In TLS's CertificateVerify: any s in 1..n-1 (browsers do not normalise S; docs/mtls.md).
    any_s,
};

/// `a < b` for big-endian numbers of the same length.
fn less(a: *const [32]u8, b: *const [32]u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn is_zero(a: *const [32]u8) bool {
    return std.mem.allEqual(u8, a, 0);
}

/// One INTEGER of an ECDSA-Sig-Value: minimal, positive, 1..n-1, at most 32 magnitude bytes.
fn signature_integer(bytes: []const u8, reader: *der.Reader) Error![32]u8 {
    const element = reader.expect(der.tag_integer) catch return error.BadSignature;
    const magnitude = der.unsigned_magnitude(element.value.of(bytes)) catch {
        return error.BadSignature;
    };
    if (magnitude.len > 32) return error.BadSignature;
    var value: [32]u8 = @splat(0);
    @memcpy(value[32 - magnitude.len ..], magnitude);
    if (is_zero(&value)) return error.BadSignature;
    if (!less(&value, &order)) return error.BadSignature;
    return value;
}

/// A DER ECDSA-Sig-Value under `rule`, strictly: one SEQUENCE of two INTEGERs and nothing after.
/// Refuses what std's `Signature.fromDer` lets through (a needless leading zero, a negative
/// integer, r or s of zero or at least n, trailing bytes), and a high S under `.low_s`.
pub fn signature_parse(bytes: []const u8, rule: SignatureRule) Error!Ecdsa.Signature {
    if (bytes.len > signature_der_bytes_max) return error.BadSignature;
    var top = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const sequence = top.expect(der.tag_sequence) catch return error.BadSignature;
    top.finish() catch return error.BadSignature;
    var reader = der.Reader.init(bytes, sequence.value);
    const r = try signature_integer(bytes, &reader);
    const s = try signature_integer(bytes, &reader);
    reader.finish() catch return error.BadSignature;
    if (rule == .low_s and less(&order_half, &s)) return error.BadSignature;
    return .{ .r = r, .s = s };
}

/// n - s, for a nonzero s < n.
pub fn negate(s: [32]u8) [32]u8 {
    assert(!is_zero(&s));
    assert(less(&s, &order));
    var out: [32]u8 = undefined;
    var borrow: u1 = 0;
    var index: usize = 32;
    while (index > 0) {
        index -= 1;
        const step = @subWithOverflow(order[index], s[index]);
        const step_borrow = @subWithOverflow(step[0], borrow);
        out[index] = step_borrow[0];
        borrow = step[1] | step_borrow[1];
    }
    assert(borrow == 0);
    return out;
}

/// `signature` with its S made low (s and n - s verify alike).
pub fn low_s(signature: Ecdsa.Signature) Ecdsa.Signature {
    if (!less(&order_half, &signature.s)) return signature;
    const result: Ecdsa.Signature = .{ .r = signature.r, .s = negate(signature.s) };
    assert(!less(&order_half, &result.s));
    return result;
}

fn write_signature_integer(writer: *der.Writer, value: *const [32]u8) Error!void {
    var skip: usize = 0;
    while (skip < 31 and value[skip] == 0) skip += 1;
    const since = writer.mark();
    try writer.prepend(value[skip..]);
    if (value[skip] & 0x80 != 0) try writer.prepend(&.{0x00});
    try writer.close(der.tag_integer, since);
}

/// The signature in strict DER, at the end of `buffer`.
pub fn signature_write(
    buffer: *[signature_der_bytes_max]u8,
    signature: Ecdsa.Signature,
) []const u8 {
    var writer = der.Writer.init(buffer);
    const outer = writer.mark();
    // Two INTEGERs of at most 35 bytes each and a 2-byte header fit in 72.
    write_signature_integer(&writer, &signature.s) catch unreachable;
    write_signature_integer(&writer, &signature.r) catch unreachable; // As above.
    writer.close(der.tag_sequence, outer) catch unreachable; // As above.
    assert(writer.written().len <= signature_der_bytes_max);
    return writer.written();
}

/// Signs `message` deterministically with a low S.
pub fn sign(key: KeyPair, message: []const u8) Ecdsa.Signature {
    const signature = key.sign(message, null) catch unreachable; // A std key pair always signs.
    return low_s(signature);
}

/// Verifies `signature` (strict DER under `rule`) over `message` by `point`.
pub fn signature_verify(
    point: Point,
    message: []const u8,
    signature_der: []const u8,
    rule: SignatureRule,
) Error!void {
    const signature = try signature_parse(signature_der, rule);
    const public = try public_key_of(point);
    signature.verify(message, public) catch return error.BadSignature;
}

// ---- Writer ------------------------------------------------------------------------------------

/// Everything a certificate says. `names` is the GeneralNames content (the SAN entries, DER),
/// empty for a CA; `identity` the client identity extension's value, empty otherwise.
const Tbs = struct {
    kind: Kind,
    serial: []const u8,
    issuer_cn: []const u8,
    subject_cn: []const u8,
    not_before_s: u64,
    not_after_s: u64,
    public_key: Point,
    names: []const u8,
    identity: []const u8,
};

fn write_name(writer: *der.Writer, cn: []const u8) Error!void {
    const outer = writer.mark();
    try writer.element(der.tag_utf8_string, cn);
    try writer.element(der.tag_oid, &oid_common_name);
    try writer.close(der.tag_sequence, outer);
    try writer.close(der.tag_set, outer);
    try writer.close(der.tag_sequence, outer);
}

fn write_extension(writer: *der.Writer, oid: []const u8, critical: bool, value: []const u8) !void {
    const since = writer.mark();
    try writer.prepend(value);
    try writer.close(der.tag_octet_string, since);
    if (critical) try writer.prepend(&.{ der.tag_boolean, 0x01, 0xFF });
    try writer.element(der.tag_oid, oid);
    try writer.close(der.tag_sequence, since);
}

fn write_extensions(writer: *der.Writer, tbs: *const Tbs) Error!void {
    const outer = writer.mark();
    // Back to front: basicConstraints, keyUsage, extKeyUsage, subjectAltName, identity.
    switch (tbs.kind) {
        .ca => {
            assert(tbs.names.len == 0);
            try write_extension(writer, &oid_key_usage, true, &usage_ca);
            try write_extension(writer, &oid_basic_constraints, true, &basic_ca);
        },
        .server, .client => {
            assert((tbs.kind == .client) == (tbs.identity.len > 0));
            assert(tbs.names.len > 0);
            if (tbs.identity.len > 0) {
                try write_extension(writer, &identity_mod.oid, false, tbs.identity);
            }
            const san = writer.mark();
            try writer.prepend(tbs.names);
            try writer.close(der.tag_sequence, san);
            try writer.close(der.tag_octet_string, san);
            try writer.element(der.tag_oid, &oid_subject_alt_name);
            try writer.close(der.tag_sequence, san);
            const usage = if (tbs.kind == .client) &usage_client else &usage_server;
            try write_extension(writer, &oid_ext_key_usage, true, usage);
            try write_extension(writer, &oid_key_usage, true, &usage_leaf);
            try write_extension(writer, &oid_basic_constraints, true, &basic_leaf);
        },
    }
    try writer.close(der.tag_sequence, outer);
    try writer.close(tag_context_3, outer);
}

fn write_tbs(writer: *der.Writer, tbs: *const Tbs) Error!void {
    const outer = writer.mark();
    try write_extensions(writer, tbs);
    try writer.prepend(&tbs.public_key);
    try writer.prepend(&spki_prefix);
    try write_name(writer, tbs.subject_cn);
    const validity = writer.mark();
    try x509.write_time(writer, tbs.not_after_s);
    try x509.write_time(writer, tbs.not_before_s);
    try writer.close(der.tag_sequence, validity);
    try write_name(writer, tbs.issuer_cn);
    try writer.prepend(&algorithm_ecdsa_sha256);
    try writer.element(der.tag_integer, tbs.serial);
    try writer.prepend(&version_v3);
    try writer.close(der.tag_sequence, outer);
}

/// What signs the TBS: the CA's key, or a DER signature already made (for `reencode`).
const Signer = union(enum) {
    key: KeyPair,
    bytes: []const u8,
};

fn write_certificate(out: *Der, tbs: *const Tbs, signer: Signer) Error!void {
    assert(tbs.serial.len >= 1);
    assert(tbs.serial.len <= constants.x509_serial_bytes_max);
    var tbs_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    var tbs_writer = der.Writer.init(&tbs_buffer);
    try write_tbs(&tbs_writer, tbs);
    const signed = tbs_writer.written();
    var signature_buffer: [signature_der_bytes_max]u8 = undefined;
    const signature = switch (signer) {
        .bytes => |bytes| bytes,
        .key => |key| signature_write(&signature_buffer, sign(key, signed)),
    };
    var writer = der.Writer.init(&out.bytes);
    const outer = writer.mark();
    try writer.prepend(signature);
    try writer.prepend(&.{0x00});
    try writer.close(der.tag_bit_string, outer);
    try writer.prepend(&algorithm_ecdsa_sha256);
    try writer.prepend(signed);
    try writer.close(der.tag_sequence, outer);
    out.start = writer.position;
    assert(out.slice().len <= constants.x509_cert_bytes_max);
}

/// As `x509.serial_of`: SHA-256 over every other field, length-prefixed; positive, 16 bytes.
fn serial_of(tbs: *const Tbs) [constants.x509_serial_bytes_max]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("zcube-browser");
    hasher.update(&.{@backingInt(tbs.kind)});
    const fields = [_][]const u8{ tbs.issuer_cn, tbs.subject_cn, tbs.names, tbs.identity };
    for (fields) |field| {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(field.len), .big);
        hasher.update(&length);
        hasher.update(field);
    }
    var times: [16]u8 = undefined;
    std.mem.writeInt(u64, times[0..8], tbs.not_before_s, .big);
    std.mem.writeInt(u64, times[8..16], tbs.not_after_s, .big);
    hasher.update(&times);
    hasher.update(&tbs.public_key);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var serial: [constants.x509_serial_bytes_max]u8 = digest[0..constants.x509_serial_bytes_max].*;
    serial[0] = (serial[0] & 0x7F) | 0x40;
    assert(serial[0] & 0x80 == 0);
    return serial;
}

/// The years 1970..9999, as `x509`'s writer.
const seconds_max: u64 = 253402300799;

fn lifetime_bound_ms(kind: Kind) u64 {
    return switch (kind) {
        .ca => constants.x509_ca_ttl_ms_max,
        .server, .client => constants.x509_leaf_ttl_ms_max,
    };
}

fn lifetime_seconds(kind: Kind, lifetime: Lifetime) Error![2]u64 {
    const before = lifetime.not_before_ms / 1000;
    const after = lifetime.not_after_ms / 1000;
    if (after > seconds_max) return error.IssueLifetime;
    if (after <= before) return error.IssueLifetime;
    if ((after - before) * 1000 > lifetime_bound_ms(kind)) return error.IssueLifetime;
    return .{ before, after };
}

/// The self-signed browser CA certificate.
pub fn issue_ca(out: *Der, ca: KeyPair, lifetime: Lifetime) Error!void {
    const public = point_of(ca);
    const seconds = try lifetime_seconds(.ca, lifetime);
    const subject = ca_cn(public);
    var serial: [constants.x509_serial_bytes_max]u8 = undefined;
    const tbs: Tbs = .{
        .kind = .ca,
        .serial = &serial,
        .issuer_cn = &subject,
        .subject_cn = &subject,
        .not_before_s = seconds[0],
        .not_after_s = seconds[1],
        .public_key = public,
        .names = "",
        .identity = "",
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

/// A server name: a DNS name, or an IPv4 or IPv6 address as its 4 or 16 bytes.
pub const San = union(enum) {
    dns: []const u8,
    ip: []const u8,
};

pub const ServerRequest = struct {
    /// The first DNS name, and the subject's CN (`--tls-name`).
    dns_name: []const u8,
    /// Further names (`--tls-san`), after `dns_name`, in order.
    sans: []const San,
    subject_key: Point,
    lifetime: Lifetime,
};

fn write_san(writer: *der.Writer, san: San) Error!void {
    switch (san) {
        .dns => |name| {
            if (identity_mod.dns_problem(name, constants.x509_dns_name_bytes_max)) {
                return error.BadDnsName;
            }
            try writer.element(tag_san_dns, name);
        },
        .ip => |address| {
            if (address.len != 4 and address.len != 16) return error.BadDnsName;
            try writer.element(tag_san_ip, address);
        },
    }
}

/// The browser path's server certificate, signed by the browser CA.
pub fn issue_server(out: *Der, ca: KeyPair, request: *const ServerRequest) Error!void {
    var names_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    var names = der.Writer.init(&names_buffer);
    var index = request.sans.len;
    while (index > 0) {
        index -= 1;
        try write_san(&names, request.sans[index]);
    }
    try write_san(&names, .{ .dns = request.dns_name });
    const seconds = try lifetime_seconds(.server, request.lifetime);
    var serial: [constants.x509_serial_bytes_max]u8 = undefined;
    const issuer = ca_cn(point_of(ca));
    const tbs: Tbs = .{
        .kind = .server,
        .serial = &serial,
        .issuer_cn = &issuer,
        .subject_cn = request.dns_name,
        .not_before_s = seconds[0],
        .not_after_s = seconds[1],
        .public_key = request.subject_key,
        .names = names.written(),
        .identity = "",
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

pub const ClientRequest = struct {
    cluster: []const u8,
    client: []const u8,
    scope: Scope,
    subject_key: Point,
    lifetime: Lifetime,
};

/// A browser's client certificate, signed by the browser CA: the same SPIFFE ID and identity
/// extension (version 2, the scope) as `x509.issue_client`'s.
pub fn issue_client(out: *Der, ca: KeyPair, request: *const ClientRequest) Error!void {
    var identity_buffer: [16]u8 = undefined;
    var identity_writer = der.Writer.init(&identity_buffer);
    try identity_mod.encode_client(&identity_writer, request.scope);
    var uri_buffer: [constants.x509_spiffe_bytes_max]u8 = undefined;
    const cluster = request.cluster;
    const uri = try identity_mod.spiffe_write(&uri_buffer, .client, cluster, request.client);
    var names_buffer: [constants.x509_spiffe_bytes_max + 4]u8 = undefined;
    var names = der.Writer.init(&names_buffer);
    try names.element(tag_san_uri, uri);
    const seconds = try lifetime_seconds(.client, request.lifetime);
    var serial: [constants.x509_serial_bytes_max]u8 = undefined;
    const issuer = ca_cn(point_of(ca));
    const tbs: Tbs = .{
        .kind = .client,
        .serial = &serial,
        .issuer_cn = &issuer,
        .subject_cn = request.client,
        .not_before_s = seconds[0],
        .not_after_s = seconds[1],
        .public_key = request.subject_key,
        .names = names.written(),
        .identity = identity_writer.written(),
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

// ---- Parser ------------------------------------------------------------------------------------

/// A parsed browser-profile certificate: offsets into the input.
pub const Parsed = struct {
    kind: Kind,
    tbs: Span,
    /// The DER ECDSA-Sig-Value.
    signature: Span,
    serial: Span,
    issuer_cn: Span,
    subject_cn: Span,
    /// The 64 point bytes.
    public_key: Span,
    not_before_ms: u64,
    not_after_ms: u64,
    /// The GeneralNames content; empty for a CA.
    names: Span,
    /// The SPIFFE URI (client) or the first DNS name (server); empty for a CA.
    name: Span,
    /// The identity extension's value (client only).
    identity: Span,

    pub fn point(parsed: *const Parsed, bytes: []const u8) Point {
        return parsed.public_key.of(bytes)[0..64].*;
    }

    pub fn scope(parsed: *const Parsed, bytes: []const u8) Scope {
        assert(parsed.kind == .client);
        // `parse` refused the certificate unless this value decoded.
        return identity_mod.decode_client(parsed.identity.of(bytes)) catch unreachable;
    }
};

const empty: Span = .{ .start = 0, .end = 0 };

fn read_cn(bytes: []const u8, reader: *der.Reader) Error!Span {
    const name = reader.expect(der.tag_sequence) catch return error.BadName;
    var outer = der.Reader.init(bytes, name.value);
    const set = outer.expect(der.tag_set) catch return error.BadName;
    var set_reader = der.Reader.init(bytes, set.value);
    const pair = set_reader.expect(der.tag_sequence) catch return error.BadName;
    var pair_reader = der.Reader.init(bytes, pair.value);
    _ = pair_reader.expect(der.tag_oid) catch return error.BadName;
    const value = pair_reader.expect(der.tag_utf8_string) catch return error.BadName;
    if (value.value.len() == 0) return error.BadName;
    if (value.value.len() > constants.x509_cn_bytes_max) return error.BadName;
    // The rest of the Name's shape is checked by writing it again.
    return value.value;
}

fn read_validity(bytes: []const u8, reader: *der.Reader, parsed: *Parsed) Error!void {
    const validity = reader.expect(der.tag_sequence) catch return error.BadTime;
    var times = der.Reader.init(bytes, validity.value);
    var seconds: [2]u64 = undefined;
    for (&seconds) |*slot| {
        const element = times.next() catch return error.BadTime;
        const known = element.tag == der.tag_utc_time or element.tag == der.tag_generalized_time;
        if (!known) return error.BadTime;
        slot.* = try x509.read_time(element.value.of(bytes), element.tag);
    }
    times.finish() catch return error.BadTime;
    if (seconds[1] <= seconds[0]) return error.BadValidity;
    parsed.not_before_ms = seconds[0] * 1000;
    parsed.not_after_ms = seconds[1] * 1000;
}

fn read_public_key(bytes: []const u8, reader: *der.Reader) Error!Span {
    const info = reader.expect(der.tag_sequence) catch return error.Malformed;
    const whole = info.whole.of(bytes);
    if (whole.len != spki_prefix.len + 64) return error.BadAlgorithm;
    if (!std.mem.eql(u8, whole[0..spki_prefix.len], &spki_prefix)) return error.BadAlgorithm;
    const span: Span = .{ .start = info.whole.end - 64, .end = info.whole.end };
    // A point off the curve is no key.
    _ = public_key_of(span.of(bytes)[0..64].*) catch return error.Malformed;
    return span;
}

/// The extension values the kinds use, by OID; anything else is refused by the rewrite.
const Values = struct {
    basic: Span = empty,
    ext_usage: Span = empty,
    san: Span = empty,
    identity: Span = empty,
};

fn read_extensions(bytes: []const u8, reader: *der.Reader) Error!Values {
    const wrapper = reader.expect(tag_context_3) catch return error.MissingExtension;
    reader.finish() catch return error.Malformed;
    var outer = der.Reader.init(bytes, wrapper.value);
    const list = outer.expect(der.tag_sequence) catch return error.Malformed;
    var extensions = der.Reader.init(bytes, list.value);
    var values: Values = .{};
    var count: u32 = 0;
    while (!extensions.finished()) {
        count += 1;
        if (count > 5) return error.UnexpectedExtension;
        const extension = extensions.expect(der.tag_sequence) catch return error.Malformed;
        var fields = der.Reader.init(bytes, extension.value);
        const oid = (fields.expect(der.tag_oid) catch return error.Malformed).value.of(bytes);
        var value = fields.next() catch return error.Malformed;
        if (value.tag == der.tag_boolean) value = fields.next() catch return error.Malformed;
        if (value.tag != der.tag_octet_string) return error.Malformed;
        if (std.mem.eql(u8, oid, &oid_basic_constraints)) values.basic = value.value;
        if (std.mem.eql(u8, oid, &oid_ext_key_usage)) values.ext_usage = value.value;
        if (std.mem.eql(u8, oid, &oid_subject_alt_name)) values.san = value.value;
        if (std.mem.eql(u8, oid, &identity_mod.oid)) values.identity = value.value;
    }
    return values;
}

fn kind_of(bytes: []const u8, values: *const Values) Error!Kind {
    if (std.mem.eql(u8, values.basic.of(bytes), &basic_ca)) return .ca;
    if (std.mem.eql(u8, values.ext_usage.of(bytes), &usage_server)) return .server;
    if (std.mem.eql(u8, values.ext_usage.of(bytes), &usage_client)) return .client;
    return error.BadExtension;
}

/// The SAN entries of a server (DNS names and IP addresses, the first a DNS name) or a client
/// (one SPIFFE URI, path `/client/`). Returns the first entry's value.
fn read_names(bytes: []const u8, names: Span, kind: Kind) Error!Span {
    assert(kind != .ca);
    var reader = der.Reader.init(bytes, names);
    if (reader.finished()) return error.BadSan;
    const first = reader.next() catch return error.BadSan;
    if (kind == .client) {
        reader.finish() catch return error.BadSan;
        if (first.tag != tag_san_uri) return error.BadSan;
        const spiffe = identity_mod.spiffe_parse(first.value.of(bytes)) catch return error.BadSan;
        if (spiffe.path != .client) return error.BadSan;
        return first.value;
    }
    if (first.tag != tag_san_dns) return error.BadSan;
    var entry = first;
    while (true) {
        const value = entry.value.of(bytes);
        switch (entry.tag) {
            tag_san_dns => {
                if (identity_mod.dns_problem(value, constants.x509_dns_name_bytes_max)) {
                    return error.BadSan;
                }
            },
            tag_san_ip => if (value.len != 4 and value.len != 16) return error.BadSan,
            else => return error.BadSan,
        }
        if (reader.finished()) break;
        entry = reader.next() catch return error.BadSan;
    }
    return first.value;
}

fn read_san_value(bytes: []const u8, san: Span) Error!Span {
    var outer = der.Reader.init(bytes, san);
    const sequence = outer.expect(der.tag_sequence) catch return error.BadSan;
    outer.finish() catch return error.BadSan;
    return sequence.value;
}

/// Reads the fields, then checks the names fit the kind.
fn parse_fields(bytes: []const u8, tbs: der.Element, parsed: *Parsed) Error!void {
    var reader = der.Reader.init(bytes, tbs.value);
    _ = reader.expect(tag_context_0) catch return error.BadVersion;
    parsed.serial = (reader.expect(der.tag_integer) catch return error.BadSerial).value;
    const serial = der.unsigned_magnitude(parsed.serial.of(bytes)) catch return error.BadSerial;
    if (serial.len > constants.x509_serial_bytes_max) return error.BadSerial;
    const inner = reader.expect(der.tag_sequence) catch return error.BadAlgorithm;
    if (!std.mem.eql(u8, inner.whole.of(bytes), &algorithm_ecdsa_sha256)) {
        return error.BadAlgorithm;
    }
    parsed.issuer_cn = try read_cn(bytes, &reader);
    try read_validity(bytes, &reader, parsed);
    parsed.subject_cn = try read_cn(bytes, &reader);
    parsed.public_key = try read_public_key(bytes, &reader);
    const values = try read_extensions(bytes, &reader);
    parsed.kind = try kind_of(bytes, &values);
    if (parsed.kind != .ca) {
        parsed.names = try read_san_value(bytes, values.san);
        parsed.name = try read_names(bytes, parsed.names, parsed.kind);
    }
    if (parsed.kind == .client) {
        _ = identity_mod.decode_client(values.identity.of(bytes)) catch return error.BadIdentity;
        parsed.identity = values.identity;
    }
}

fn check_names(bytes: []const u8, parsed: *const Parsed) Error!void {
    const issuer = parsed.issuer_cn.of(bytes);
    const subject = parsed.subject_cn.of(bytes);
    if (issuer.len != ca_cn_bytes) return error.BadName;
    if (!std.mem.startsWith(u8, issuer, ca_cn_prefix)) return error.BadName;
    switch (parsed.kind) {
        .ca => if (!std.mem.eql(u8, issuer, subject)) return error.BadName,
        .server => if (!std.mem.eql(u8, parsed.name.of(bytes), subject)) return error.BadName,
        .client => {
            // `read_names` parsed this URI with the same function.
            const spiffe = identity_mod.spiffe_parse(parsed.name.of(bytes)) catch unreachable;
            if (!std.mem.eql(u8, spiffe.name, subject)) return error.BadName;
        },
    }
    const lifetime = parsed.not_after_ms - parsed.not_before_ms;
    if (lifetime > lifetime_bound_ms(parsed.kind)) return error.LifetimeTooLong;
}

/// Parses `bytes` under the browser profile: its fields, a strict low-S signature, and exactly
/// the bytes this module's writer makes of those fields.
pub fn parse(bytes: []const u8) Error!Parsed {
    if (bytes.len > constants.x509_cert_bytes_max) return error.TooLarge;
    var top = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const certificate = top.expect(der.tag_sequence) catch return error.Malformed;
    top.finish() catch return error.Malformed;
    var reader = der.Reader.init(bytes, certificate.value);
    const tbs = reader.expect(der.tag_sequence) catch return error.Malformed;
    const algorithm = reader.expect(der.tag_sequence) catch return error.Malformed;
    const bits = reader.expect(der.tag_bit_string) catch return error.Malformed;
    reader.finish() catch return error.Malformed;
    if (!std.mem.eql(u8, algorithm.whole.of(bytes), &algorithm_ecdsa_sha256)) {
        return error.BadAlgorithm;
    }
    if (bits.value.len() < 1 or bits.value.of(bytes)[0] != 0) return error.Malformed;
    var parsed: Parsed = .{
        .kind = .ca,
        .tbs = tbs.whole,
        .signature = .{ .start = bits.value.start + 1, .end = bits.value.end },
        .serial = empty,
        .issuer_cn = empty,
        .subject_cn = empty,
        .public_key = empty,
        .not_before_ms = 0,
        .not_after_ms = 0,
        .names = empty,
        .name = empty,
        .identity = empty,
    };
    _ = try signature_parse(parsed.signature.of(bytes), .low_s);
    try parse_fields(bytes, tbs, &parsed);
    try check_names(bytes, &parsed);
    var again: Der = .{};
    try reencode(&again, bytes, &parsed);
    if (!std.mem.eql(u8, again.slice(), bytes)) return error.Malformed;
    return parsed;
}

/// Writes a parsed certificate again with its own signature: for every input `parse` accepts,
/// the input.
pub fn reencode(out: *Der, bytes: []const u8, parsed: *const Parsed) Error!void {
    try reencode_signed(out, bytes, parsed, parsed.signature.of(bytes));
}

/// `reencode` with another DER signature in place of the certificate's (the tests' near misses).
pub fn reencode_signed(
    out: *Der,
    bytes: []const u8,
    parsed: *const Parsed,
    signature: []const u8,
) Error!void {
    assert(signature.len <= signature_der_bytes_max);
    const tbs: Tbs = .{
        .kind = parsed.kind,
        .serial = parsed.serial.of(bytes),
        .issuer_cn = parsed.issuer_cn.of(bytes),
        .subject_cn = parsed.subject_cn.of(bytes),
        .not_before_s = parsed.not_before_ms / 1000,
        .not_after_s = parsed.not_after_ms / 1000,
        .public_key = parsed.point(bytes),
        .names = parsed.names.of(bytes),
        .identity = parsed.identity.of(bytes),
    };
    try write_certificate(out, &tbs, .{ .bytes = signature });
}

// ---- Verification ------------------------------------------------------------------------------

/// Test-only faults for the teeth tests: each skips one check.
pub const TestFault = enum { signature, kind, window };
var faults: [3]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

pub const Expect = struct {
    kind: Kind,
    /// The SPIFFE URI (client) or the first DNS name (server) it must carry, if named.
    name: ?[]const u8,
};

/// Parses `bytes` and checks it against the browser CA's point `anchor` at `now_ms`: shape,
/// issuer, signature, kind, window, name, in `x509.verify`'s order. Only certificates signed
/// directly by the browser CA are accepted.
pub fn verify(bytes: []const u8, anchor: Point, now_ms: u64, expect: Expect) Error!Parsed {
    const parsed = try parse(bytes);
    const expected_issuer = ca_cn(anchor);
    if (!std.mem.eql(u8, parsed.issuer_cn.of(bytes), &expected_issuer)) return error.WrongIssuer;
    if (parsed.kind == .ca and !std.mem.eql(u8, parsed.public_key.of(bytes), &anchor)) {
        return error.WrongIssuer;
    }
    if (!fault_on(.signature)) {
        const signature = parsed.signature.of(bytes);
        try signature_verify(anchor, parsed.tbs.of(bytes), signature, .low_s);
    }
    if (!fault_on(.kind) and parsed.kind != expect.kind) return error.WrongUse;
    const skew = constants.peer_clock_skew_ms;
    if (!fault_on(.window)) {
        if (parsed.not_before_ms > now_ms +| skew) return error.NotYetValid;
        if (now_ms >= parsed.not_after_ms +| skew) return error.Expired;
    }
    if (expect.name) |name| {
        if (!std.mem.eql(u8, parsed.name.of(bytes), name)) return error.WrongName;
    }
    return parsed;
}

/// A browser-path certificate's kind in `x509`'s terms, for the diagnostics.
pub fn cluster_kind(kind: Kind) x509.Kind {
    return switch (kind) {
        .ca => .ca,
        .server => .server,
        .client => .client,
    };
}
