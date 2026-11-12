//! X.509 v3 certificates, Ed25519 only (docs/briefs/mtls-client.md, "X.509 v3"; docs/mtls.md): a
//! deterministic writer, a strict parser that returns offsets into its input, and the
//! verification of a certificate against one pinned anchor key. Core code: no allocation, no
//! recursion, no clock value (the wall time is an argument) and no randomness source.
//!
//! Two profiles (decision file 2026-11-04-x509-two-profiles.md):
//!
//! - `cluster`: the certificates this cluster's CA writes, and nothing more. A certificate has one
//!   of three kinds, each with its extensions in one fixed order and its exact bytes; anything
//!   else (a stock tool's extra extensions included) is refused. So "parse, then write again"
//!   gives back the input, which `x509_fuzz.zig` checks.
//! - `foreign_server`: a server leaf signed directly by a pinned Ed25519 anchor of another CA
//!   (an openssl-made one, say). Any issuer and subject Name, a serial of up to 20 bytes, key
//!   identifiers, extensions in any order; but no extension twice, no unknown critical one, and
//!   exactly one DNS name or SPIFFE ID. Still DER only, Ed25519 only, signed by the anchor.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const constants = @import("constants.zig");
const der = @import("x509_der.zig");
const diag_mod = @import("diag.zig");
const identity_mod = @import("x509_identity.zig");
const peer = @import("peer.zig");
const records = @import("records.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Span = der.Span;
const Identity = identity_mod.Identity;

/// Why a certificate was refused or could not be made. `code_of` maps each to its `ZC-E08xx`.
pub const Error = error{
    // ---- ZC-E0809: malformed or outside the bounds ----
    /// Not DER: a form this parser does not accept, or a value cut short.
    Malformed,
    /// More than `x509_cert_bytes_max` bytes.
    TooLarge,
    /// A version other than v3.
    BadVersion,
    /// A signature or key algorithm other than Ed25519, or the two copies differ.
    BadAlgorithm,
    /// An issuer or subject unique ID.
    UniqueId,
    BadSerial,
    /// An issuer or subject that is not a single commonName of the expected form.
    BadName,
    BadTime,
    /// `not_after` is not after `not_before`.
    BadValidity,
    /// A lifetime over the kind's bound.
    LifetimeTooLong,
    /// A critical extension this parser does not know.
    UnknownCritical,
    DuplicateExtension,
    /// An extension that the certificate's kind does not carry, or in the wrong place.
    UnexpectedExtension,
    /// A required extension is absent.
    MissingExtension,
    /// A known extension with a wrong criticality or a wrong value.
    BadExtension,
    /// A subjectAltName that is not exactly one SPIFFE URI or one DNS name for the kind.
    BadSan,
    /// The private identity extension is malformed or breaks its bounds.
    BadIdentity,
    // ---- ZC-E0810: not signed by the pinned anchor ----
    WrongIssuer,
    BadSignature,
    // ---- ZC-E0819 ----
    /// The certificate is of another kind than the use asks for (a client certificate presented
    /// as a server's, say).
    WrongUse,
    // ---- ZC-E0811 ----
    Expired,
    NotYetValid,
    // ---- ZC-E0812 ----
    WrongName,
    // ---- ZC-E0817: an identity could not be issued ----
    NoSpace,
    TooManyLabels,
    LabelTooLong,
    LabelsTooLarge,
    LabelsNotSorted,
    BadLabel,
    BadCluster,
    BadServiceName,
    BadSpiffe,
    BadDnsName,
    /// A lifetime that is empty, over the kind's bound or outside the years 1970..9999.
    IssueLifetime,
};

pub fn code_of(err: Error) @import("diag/codes.zig").Code {
    return switch (err) {
        error.Malformed, error.TooLarge, error.BadVersion, error.BadAlgorithm => .E0809,
        error.UniqueId, error.BadSerial, error.BadName, error.BadTime => .E0809,
        error.BadValidity, error.LifetimeTooLong, error.UnknownCritical => .E0809,
        error.DuplicateExtension, error.UnexpectedExtension, error.MissingExtension => .E0809,
        error.BadExtension, error.BadSan, error.BadIdentity => .E0809,
        error.WrongIssuer, error.BadSignature => .E0810,
        error.WrongUse => .E0819,
        error.Expired, error.NotYetValid => .E0811,
        error.WrongName => .E0812,
        error.NoSpace, error.TooManyLabels, error.LabelTooLong => .E0817,
        error.LabelsTooLarge, error.LabelsNotSorted, error.BadLabel => .E0817,
        error.BadCluster, error.BadServiceName, error.BadSpiffe, error.BadDnsName => .E0817,
        error.IssueLifetime => .E0817,
    };
}

pub const Kind = enum { ca, workload, server };

pub const Profile = enum {
    /// What this cluster's CA writes, byte for byte.
    cluster,
    /// A server leaf under a pinned anchor of another CA (docs/mtls.md).
    foreign_server,
};

/// Where a refusal was found, for the cause line: the parser moves it as it reads.
pub const Field = enum {
    certificate,
    version,
    serial,
    signature_algorithm,
    issuer,
    validity,
    subject,
    public_key,
    extensions,
    basic_constraints,
    key_usage,
    ext_key_usage,
    subject_alt_name,
    identity,
    key_identifier,
    signature,

    pub fn text(field: Field) []const u8 {
        return switch (field) {
            .certificate => "outer structure",
            .version => "version",
            .serial => "serial number",
            .signature_algorithm => "signature algorithm",
            .issuer => "issuer",
            .validity => "validity",
            .subject => "subject",
            .public_key => "public key",
            .extensions => "extension list",
            .basic_constraints => "basicConstraints",
            .key_usage => "keyUsage",
            .ext_key_usage => "extKeyUsage",
            .subject_alt_name => "subjectAltName",
            .identity => "identity extension",
            .key_identifier => "key identifier",
            .signature => "signature",
        };
    }
};

/// What a refusal's diagnostic shows besides the error: the field, the window and the time, the
/// names or the kinds. `verify` fills what it got to; the rest keeps its default.
pub const Detail = struct {
    field: Field = .certificate,
    not_before_ms: u64 = 0,
    not_after_ms: u64 = 0,
    now_ms: u64 = 0,
    /// Slices of the caller's name and of the certificate: valid while both are.
    name_expected: []const u8 = "",
    name_found: []const u8 = "",
    kind_expected: Kind = .server,
    kind_found: Kind = .server,
};

/// A certificate in DER, built back to front: the bytes are `bytes[start..]`.
pub const Der = struct {
    bytes: [constants.x509_cert_bytes_max]u8 = undefined,
    start: u32 = constants.x509_cert_bytes_max,

    pub fn slice(certificate: *const Der) []const u8 {
        assert(certificate.start <= certificate.bytes.len);
        return certificate.bytes[certificate.start..];
    }
};

// ---- Fixed encodings ---------------------------------------------------------------------------

const oid_ed25519 = [_]u8{ 0x2B, 0x65, 0x70 };
/// AlgorithmIdentifier { id-Ed25519 }, parameters absent (RFC 8410).
const algorithm_ed25519 = [_]u8{ 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70 };
const oid_common_name = [_]u8{ 0x55, 0x04, 0x03 };
const oid_basic_constraints = [_]u8{ 0x55, 0x1D, 0x13 };
const oid_key_usage = [_]u8{ 0x55, 0x1D, 0x0F };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1D, 0x25 };
const oid_subject_alt_name = [_]u8{ 0x55, 0x1D, 0x11 };
const oid_subject_key_id = [_]u8{ 0x55, 0x1D, 0x0E };
const oid_authority_key_id = [_]u8{ 0x55, 0x1D, 0x23 };
const oid_identity = identity_mod.oid;
/// id-kp-serverAuth, 1.3.6.1.5.5.7.3.1.
const oid_server_auth = [_]u8{ 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01 };

/// BasicConstraints { cA TRUE, pathLenConstraint 0 }, and `{}` for a leaf (cA FALSE is the DER
/// default and is omitted).
const basic_ca = [_]u8{ 0x30, 0x06, 0x01, 0x01, 0xFF, 0x02, 0x01, 0x00 };
const basic_leaf = [_]u8{ 0x30, 0x00 };
/// KeyUsage BIT STRING: keyCertSign (bit 5), digitalSignature (bit 0).
const usage_ca = [_]u8{ 0x03, 0x02, 0x02, 0x04 };
const usage_leaf = [_]u8{ 0x03, 0x02, 0x07, 0x80 };
/// ExtKeyUsage { id-kp-clientAuth } and { id-kp-serverAuth }.
const usage_client = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02,
};
const usage_server = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01,
};
const version_v3 = [_]u8{ 0xA0, 0x03, 0x02, 0x01, 0x02 };

const tag_context_0: u8 = 0xA0;
const tag_context_3: u8 = 0xA3;
/// issuerUniqueID `[1] IMPLICIT BIT STRING` and subjectUniqueID `[2]`: primitive tags.
const tag_issuer_unique_id: u8 = 0x81;
const tag_subject_unique_id: u8 = 0x82;
const tag_san_dns: u8 = 0x82;
const tag_san_uri: u8 = 0x86;

pub const ca_cn_prefix = "zcube-ca-";
pub const ca_cn_bytes = ca_cn_prefix.len + 16;

comptime {
    assert(ca_cn_bytes <= constants.x509_cn_bytes_max);
    assert(oid_identity.len == 20);
}

/// The CA's subject: `zcube-ca-` and the 16 hex digits of its key id.
pub fn ca_cn(ca_public: [32]u8) [ca_cn_bytes]u8 {
    var out: [ca_cn_bytes]u8 = undefined;
    @memcpy(out[0..ca_cn_prefix.len], ca_cn_prefix);
    const id = peer.ca_key_id(ca_public);
    const hex = std.fmt.bytesToHex(id, .lower);
    out[ca_cn_prefix.len..][0..16].* = hex;
    return out;
}

fn ca_cn_is_valid(text: []const u8) bool {
    if (text.len != ca_cn_bytes) return false;
    if (!std.mem.startsWith(u8, text, ca_cn_prefix)) return false;
    for (text[ca_cn_prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

// ---- Time ------------------------------------------------------------------------------------

const seconds_max: u64 = 253_402_300_799; // 9999-12-31T23:59:59Z
const utc_time_year_max: u32 = 2049;

const Civil = struct { year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32 };

/// Days since 1970-01-01 of a civil date (proleptic Gregorian), after H. Hinnant.
fn days_from_civil(year_in: u32, month: u32, day: u32) u64 {
    assert(month >= 1);
    assert(month <= 12);
    const year: i64 = @as(i64, year_in) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(year, 400);
    const year_of_era: i64 = year - era * 400;
    const month_shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_shifted + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    assert(days >= 0);
    return @intCast(days);
}

fn civil_from_seconds(seconds: u64) Civil {
    assert(seconds <= seconds_max);
    const days: i64 = @intCast(seconds / 86400);
    const rest: u32 = @intCast(seconds % 86400);
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) -
            @divFloor(day_of_era, 146096),
        365,
    );
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100));
    const month_shifted = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_shifted + 2, 5) + 1;
    const month = if (month_shifted < 10) month_shifted + 3 else month_shifted - 9;
    const year = year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = rest / 3600,
        .minute = rest % 3600 / 60,
        .second = rest % 60,
    };
}

fn days_in_month(year: u32, month: u32) u32 {
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leap) 29 else 28,
        else => unreachable, // callers check 1..12 first
    };
}

fn digits(text: []const u8) ?u32 {
    var value: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        value = value * 10 + (byte - '0');
    }
    return value;
}

/// UTCTime `YYMMDDHHMMSSZ` for the years 1970..2049, GeneralizedTime `YYYYMMDDHHMMSSZ` after.
/// Public for `x509_test.zig`'s boundary rows.
pub fn write_time(writer: *der.Writer, seconds: u64) Error!void {
    const civil = civil_from_seconds(seconds);
    var text: [15]u8 = undefined;
    if (civil.year <= utc_time_year_max) {
        const printed = std.fmt.bufPrint(&text, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
            civil.year % 100, civil.month, civil.day, civil.hour, civil.minute, civil.second,
        }) catch unreachable; // 13 bytes always fit in 15
        assert(printed.len == 13);
        return writer.element(der.tag_utc_time, printed);
    }
    const printed = std.fmt.bufPrint(&text, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.second,
    }) catch unreachable; // 15 bytes fit exactly
    assert(printed.len == 15);
    return writer.element(der.tag_generalized_time, printed);
}

/// Unix seconds of a UTCTime or GeneralizedTime element in its canonical form only. Public for
/// `x509_test.zig`'s boundary rows.
pub fn read_time(content: []const u8, tag: u8) Error!u64 {
    var year: u32 = undefined;
    var rest: []const u8 = undefined;
    if (tag == der.tag_utc_time) {
        if (content.len != 13) return error.BadTime;
        const short = digits(content[0..2]) orelse return error.BadTime;
        year = if (short < 50) 2000 + short else 1900 + short;
        if (year < 1970) return error.BadTime;
        rest = content[2..];
    } else {
        if (content.len != 15) return error.BadTime;
        year = digits(content[0..4]) orelse return error.BadTime;
        // GeneralizedTime is canonical only where UTCTime cannot reach.
        if (year <= utc_time_year_max) return error.BadTime;
        rest = content[4..];
    }
    if (rest[10] != 'Z') return error.BadTime;
    const month = digits(rest[0..2]) orelse return error.BadTime;
    const day = digits(rest[2..4]) orelse return error.BadTime;
    const hour = digits(rest[4..6]) orelse return error.BadTime;
    const minute = digits(rest[6..8]) orelse return error.BadTime;
    const second = digits(rest[8..10]) orelse return error.BadTime;
    if (month < 1 or month > 12) return error.BadTime;
    if (day < 1 or day > days_in_month(year, month)) return error.BadTime;
    if (hour > 23 or minute > 59 or second > 59) return error.BadTime;
    const days = days_from_civil(year, month, day);
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn lifetime_bound_ms(kind: Kind) u64 {
    return switch (kind) {
        .ca => constants.x509_ca_ttl_ms_max,
        .workload, .server => constants.x509_leaf_ttl_ms_max,
    };
}

// ---- Writer ----------------------------------------------------------------------------------

/// Everything a certificate says, in the form the writer takes. `parse` produces the same fields
/// as offsets; `reencode` turns those back into a `Tbs`.
const Tbs = struct {
    kind: Kind,
    serial: []const u8,
    issuer_cn: []const u8,
    subject_cn: []const u8,
    not_before_s: u64,
    not_after_s: u64,
    public_key: [32]u8,
    /// The SPIFFE URI or the DNS name; empty for a CA.
    name: []const u8,
    /// The identity extension's value (DER); empty unless a workload.
    identity: []const u8,
};

fn write_name(writer: *der.Writer, cn: []const u8) Error!void {
    const outer = writer.mark();
    const set = writer.mark();
    const pair = writer.mark();
    try writer.element(der.tag_utf8_string, cn);
    try writer.element(der.tag_oid, &oid_common_name);
    try writer.close(der.tag_sequence, pair);
    try writer.close(der.tag_set, set);
    try writer.close(der.tag_sequence, outer);
}

/// Closes an extension whose value has been written since `since`.
fn close_extension(writer: *der.Writer, oid: []const u8, critical: bool, since: u32) Error!void {
    try writer.close(der.tag_octet_string, since);
    if (critical) try writer.prepend(&.{ der.tag_boolean, 0x01, 0xFF });
    try writer.element(der.tag_oid, oid);
    try writer.close(der.tag_sequence, since);
}

fn write_extension(
    writer: *der.Writer,
    oid: []const u8,
    critical: bool,
    value: []const u8,
) Error!void {
    const since = writer.mark();
    try writer.prepend(value);
    try close_extension(writer, oid, critical, since);
}

fn write_extensions(writer: *der.Writer, tbs: *const Tbs) Error!void {
    const outer = writer.mark();
    const list = writer.mark();
    // Back to front: the last extension in the fixed order is written first.
    switch (tbs.kind) {
        .ca => {
            try write_extension(writer, &oid_key_usage, true, &usage_ca);
            try write_extension(writer, &oid_basic_constraints, true, &basic_ca);
        },
        .workload, .server => {
            const is_workload = tbs.kind == .workload;
            if (is_workload) try write_extension(writer, &oid_identity, false, tbs.identity);
            const since = writer.mark();
            try writer.element(if (is_workload) tag_san_uri else tag_san_dns, tbs.name);
            try writer.close(der.tag_sequence, since);
            try close_extension(writer, &oid_subject_alt_name, false, since);
            const usage = if (is_workload) &usage_client else &usage_server;
            try write_extension(writer, &oid_ext_key_usage, true, usage);
            try write_extension(writer, &oid_key_usage, true, &usage_leaf);
            try write_extension(writer, &oid_basic_constraints, true, &basic_leaf);
        },
    }
    try writer.close(der.tag_sequence, list);
    try writer.close(tag_context_3, outer);
}

fn write_tbs(writer: *der.Writer, tbs: *const Tbs) Error!void {
    const outer = writer.mark();
    try write_extensions(writer, tbs);
    const key = writer.mark();
    try writer.prepend(&tbs.public_key);
    try writer.prepend(&.{0x00});
    try writer.close(der.tag_bit_string, key);
    try writer.prepend(&algorithm_ed25519);
    try writer.close(der.tag_sequence, key);
    try write_name(writer, tbs.subject_cn);
    const validity = writer.mark();
    try write_time(writer, tbs.not_after_s);
    try write_time(writer, tbs.not_before_s);
    try writer.close(der.tag_sequence, validity);
    try write_name(writer, tbs.issuer_cn);
    try writer.prepend(&algorithm_ed25519);
    try writer.element(der.tag_integer, tbs.serial);
    try writer.prepend(&version_v3);
    try writer.close(der.tag_sequence, outer);
}

/// What signs the TBS: the CA's key, or signature bytes already made (for `reencode`).
const Signer = union(enum) {
    key: Ed25519.KeyPair,
    bytes: [64]u8,
};

fn write_certificate(out: *Der, tbs: *const Tbs, signer: Signer) Error!void {
    assert(tbs.serial.len >= 1);
    assert(tbs.serial.len <= constants.x509_serial_bytes_max);
    var writer = der.Writer.init(&out.bytes);
    const outer = writer.mark();
    // The signature goes in last in the file and first in this writer: a placeholder now,
    // signed over the TBS once that is in place.
    const bits = writer.mark();
    try writer.prepend(&@as([65]u8, @splat(0)));
    try writer.close(der.tag_bit_string, bits);
    const signature_at = writer.buffer.len - 64;
    try writer.prepend(&algorithm_ed25519);
    const tbs_end = writer.mark();
    try write_tbs(&writer, tbs);
    const signed = writer.buffer[writer.position..tbs_end];
    const signature: [64]u8 = switch (signer) {
        .bytes => |bytes| bytes,
        // Signing cannot fail with a key pair made by std and no noise.
        .key => |key| (key.sign(signed, null) catch unreachable).toBytes(),
    };
    @memcpy(writer.buffer[signature_at..][0..64], &signature);
    try writer.close(der.tag_sequence, outer);
    out.start = writer.position;
    assert(out.slice().len <= constants.x509_cert_bytes_max);
}

/// The serial: SHA-256 over every other field of the TBS (kind, issuer, subject, validity, key,
/// name, identity), each length-prefixed so that no two field splits hash alike. Two certificates
/// that differ in any of them, even for the same key in the same second, differ in serial.
fn serial_of(tbs: *const Tbs) [constants.x509_serial_bytes_max]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{@backingInt(tbs.kind)});
    const fields = [_][]const u8{ tbs.issuer_cn, tbs.subject_cn, tbs.name, tbs.identity };
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
    // Positive (top bit clear) and never short (bit 6 set), so the DER INTEGER is exactly 16
    // bytes with no padding zero.
    serial[0] = (serial[0] & 0x7F) | 0x40;
    return serial;
}

/// Seconds for a lifetime, or `IssueLifetime`.
fn lifetime_seconds(kind: Kind, not_before_ms: u64, not_after_ms: u64) Error![2]u64 {
    const before = not_before_ms / 1000;
    const after = not_after_ms / 1000;
    if (after > seconds_max) return error.IssueLifetime;
    if (after <= before) return error.IssueLifetime;
    if ((after - before) * 1000 > lifetime_bound_ms(kind)) return error.IssueLifetime;
    return .{ before, after };
}

pub const Lifetime = struct {
    not_before_ms: u64,
    not_after_ms: u64,
};

/// The self-signed CA certificate.
pub fn issue_ca(out: *Der, ca: Ed25519.KeyPair, lifetime: Lifetime) Error!void {
    const public = ca.public_key.toBytes();
    const seconds = try lifetime_seconds(.ca, lifetime.not_before_ms, lifetime.not_after_ms);
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
        .name = "",
        .identity = "",
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

pub const WorkloadRequest = struct {
    cluster: []const u8,
    /// Which kind of workload: a service or a run of a job (B4).
    path: identity_mod.Path = .service,
    /// The service or job name: the last part of the SPIFFE ID, and the subject's commonName.
    name: []const u8,
    /// The workload's public key: the caller holds the private half (it signs `CertificateVerify`).
    subject_key: [32]u8,
    identity: Identity,
    lifetime: Lifetime,
};

/// A client certificate for a workload, signed by the CA.
pub fn issue_workload(out: *Der, ca: Ed25519.KeyPair, request: *const WorkloadRequest) Error!void {
    var uri_buffer: [constants.x509_spiffe_bytes_max]u8 = undefined;
    const uri = try identity_mod.spiffe_write(
        &uri_buffer,
        request.cluster,
        request.path,
        request.name,
    );
    var identity_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    var identity_writer = der.Writer.init(&identity_buffer);
    try identity_mod.encode(&identity_writer, &request.identity);
    const lifetime = request.lifetime;
    const seconds = try lifetime_seconds(.workload, lifetime.not_before_ms, lifetime.not_after_ms);
    var serial: [constants.x509_serial_bytes_max]u8 = undefined;
    const issuer = ca_cn(ca.public_key.toBytes());
    const tbs: Tbs = .{
        .kind = .workload,
        .serial = &serial,
        .issuer_cn = &issuer,
        .subject_cn = request.name,
        .not_before_s = seconds[0],
        .not_after_s = seconds[1],
        .public_key = request.subject_key,
        .name = uri,
        .identity = identity_writer.written(),
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

pub const ServerRequest = struct {
    dns_name: []const u8,
    subject_key: [32]u8,
    lifetime: Lifetime,
};

/// A server certificate, for tests and for B7; signed by the CA.
pub fn issue_server(out: *Der, ca: Ed25519.KeyPair, request: *const ServerRequest) Error!void {
    if (identity_mod.dns_problem(request.dns_name, constants.x509_dns_name_bytes_max)) {
        return error.BadDnsName;
    }
    const lifetime = request.lifetime;
    const seconds = try lifetime_seconds(.server, lifetime.not_before_ms, lifetime.not_after_ms);
    var serial: [constants.x509_serial_bytes_max]u8 = undefined;
    const issuer = ca_cn(ca.public_key.toBytes());
    const tbs: Tbs = .{
        .kind = .server,
        .serial = &serial,
        .issuer_cn = &issuer,
        .subject_cn = request.dns_name,
        .not_before_s = seconds[0],
        .not_after_s = seconds[1],
        .public_key = request.subject_key,
        .name = request.dns_name,
        .identity = "",
    };
    serial = serial_of(&tbs);
    try write_certificate(out, &tbs, .{ .key = ca });
}

// ---- Parser ----------------------------------------------------------------------------------

/// A parsed certificate: offsets into the input, which the caller keeps alive.
pub const Parsed = struct {
    profile: Profile,
    /// Under `foreign_server`, the kind its extensions make it: `.ca` for basicConstraints cA or a
    /// CA key usage, `.workload` for an extKeyUsage without serverAuth, else `.server`.
    kind: Kind,
    /// The signed region: the TBSCertificate with its header.
    tbs: Span,
    /// The 64 signature bytes.
    signature: Span,
    serial: Span,
    /// The commonName's value; under `foreign_server`, the whole Name's content.
    issuer_cn: Span,
    subject_cn: Span,
    public_key: Span,
    not_before_ms: u64,
    not_after_ms: u64,
    /// The SPIFFE URI (workload) or DNS name (server); empty for a CA.
    name: Span,
    /// The identity extension's value; empty unless a workload.
    identity: Span,

    pub fn text(parsed: *const Parsed, span: Span, bytes: []const u8) []const u8 {
        _ = parsed;
        return span.of(bytes);
    }
};

fn mapped(err: der.Error) Error {
    return switch (err) {
        error.Malformed => error.Malformed,
        error.NoSpace => error.NoSpace,
    };
}

fn read_span_equal(bytes: []const u8, element: der.Element, expected: []const u8) bool {
    return std.mem.eql(u8, element.whole.of(bytes), expected);
}

/// The whole certificate, under the `cluster` profile.
pub fn parse(bytes: []const u8) Error!Parsed {
    var detail: Detail = .{};
    return parse_profile(bytes, .cluster, &detail);
}

/// The whole certificate: SEQUENCE { TBSCertificate, AlgorithmIdentifier, BIT STRING }. On a
/// refusal `detail.field` is where it was found.
pub fn parse_profile(bytes: []const u8, profile: Profile, detail: *Detail) Error!Parsed {
    detail.field = .certificate;
    if (bytes.len > constants.x509_cert_bytes_max) return error.TooLarge;
    var top = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const certificate = top.expect(der.tag_sequence) catch |err| return mapped(err);
    top.finish() catch |err| return mapped(err);
    var reader = der.Reader.init(bytes, certificate.value);
    const tbs = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    const algorithm = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    const bits = reader.expect(der.tag_bit_string) catch |err| return mapped(err);
    reader.finish() catch |err| return mapped(err);
    detail.field = .signature_algorithm;
    if (!read_span_equal(bytes, algorithm, &algorithm_ed25519)) return error.BadAlgorithm;
    detail.field = .signature;
    // 0 unused bits, then 64 signature bytes.
    if (bits.value.len() != 65) return error.Malformed;
    if (bits.value.of(bytes)[0] != 0) return error.Malformed;

    var parsed = try parse_tbs(bytes, tbs, profile, detail);
    parsed.signature = .{ .start = bits.value.start + 1, .end = bits.value.end };
    assert(parsed.profile == profile);
    return parsed;
}

fn parse_tbs(bytes: []const u8, tbs: der.Element, profile: Profile, detail: *Detail) Error!Parsed {
    var reader = der.Reader.init(bytes, tbs.value);
    detail.field = .version;
    const version = reader.next() catch |err| return mapped(err);
    if (version.tag != tag_context_0) return error.BadVersion;
    if (!read_span_equal(bytes, version, &version_v3)) return error.BadVersion;
    detail.field = .serial;
    const serial = reader.expect(der.tag_integer) catch |err| return mapped(err);
    try check_serial(serial.value.of(bytes), profile);
    detail.field = .signature_algorithm;
    const algorithm = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    if (!read_span_equal(bytes, algorithm, &algorithm_ed25519)) return error.BadAlgorithm;
    detail.field = .issuer;
    const issuer = try read_name_of(bytes, &reader, profile);
    detail.field = .validity;
    const validity = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    detail.field = .subject;
    const subject = try read_name_of(bytes, &reader, profile);
    detail.field = .public_key;
    const key = try read_public_key(bytes, &reader);

    var parsed: Parsed = .{
        .profile = profile,
        .kind = .ca,
        .tbs = tbs.whole,
        .signature = .{ .start = 0, .end = 0 },
        .serial = serial.value,
        .issuer_cn = issuer,
        .subject_cn = subject,
        .public_key = key,
        .not_before_ms = 0,
        .not_after_ms = 0,
        .name = .{ .start = 0, .end = 0 },
        .identity = .{ .start = 0, .end = 0 },
    };
    detail.field = .validity;
    try read_validity(bytes, validity, &parsed);
    detail.field = .extensions;
    const extensions = try read_extensions_element(bytes, &reader);
    switch (profile) {
        .cluster => {
            try read_extensions(bytes, extensions, &parsed, detail);
            try check_names(bytes, &parsed, detail);
        },
        .foreign_server => {
            try read_extensions_foreign(bytes, extensions, &parsed, detail);
            try check_foreign(bytes, &parsed, detail);
        },
    }
    return parsed;
}

/// A positive INTEGER, minimal, never zero. `cluster`: a magnitude of at most 16 bytes (what the
/// writer makes). `foreign_server`: at most 20 content bytes (RFC 5280, 4.1.2.2).
fn check_serial(content: []const u8, profile: Profile) Error!void {
    const magnitude = der.unsigned_magnitude(content) catch return error.BadSerial;
    assert(magnitude.len > 0);
    if (magnitude.len == 1 and magnitude[0] == 0) return error.BadSerial;
    switch (profile) {
        // The content, not the magnitude: a padding zero before 16 bytes would make 17, which
        // the writer never makes (`serial_of` keeps the top bit clear).
        .cluster => if (content.len > constants.x509_serial_bytes_max) return error.BadSerial,
        .foreign_server => {
            if (content.len > constants.x509_foreign_serial_bytes_max) return error.BadSerial;
        },
    }
}

fn read_name_of(bytes: []const u8, reader: *der.Reader, profile: Profile) Error!Span {
    return switch (profile) {
        .cluster => read_name(bytes, reader),
        .foreign_server => read_name_foreign(bytes, reader),
    };
}

/// Another CA's Name: SEQUENCE OF SET OF SEQUENCE { OID, one value }, at most
/// `x509_foreign_name_parts_max` sets and attributes together. The values are not interpreted:
/// the server is named by its subjectAltName. Returns the Name's content.
fn read_name_foreign(bytes: []const u8, reader: *der.Reader) Error!Span {
    const name = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    var sets = der.Reader.init(bytes, name.value);
    var parts: u32 = 0;
    while (!sets.finished()) {
        parts += 1;
        if (parts > constants.x509_foreign_name_parts_max) return error.BadName;
        const set = sets.expect(der.tag_set) catch return error.BadName;
        var attributes = der.Reader.init(bytes, set.value);
        if (attributes.finished()) return error.BadName;
        while (!attributes.finished()) {
            parts += 1;
            if (parts > constants.x509_foreign_name_parts_max) return error.BadName;
            const pair = attributes.expect(der.tag_sequence) catch return error.BadName;
            var inner = der.Reader.init(bytes, pair.value);
            _ = inner.expect(der.tag_oid) catch return error.BadName;
            _ = inner.next() catch return error.BadName;
            inner.finish() catch return error.BadName;
        }
    }
    return name.value;
}

fn read_name(bytes: []const u8, reader: *der.Reader) Error!Span {
    const name = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    var outer = der.Reader.init(bytes, name.value);
    const set = outer.expect(der.tag_set) catch return error.BadName;
    outer.finish() catch return error.BadName;
    var set_reader = der.Reader.init(bytes, set.value);
    const pair = set_reader.expect(der.tag_sequence) catch return error.BadName;
    set_reader.finish() catch return error.BadName;
    var pair_reader = der.Reader.init(bytes, pair.value);
    const oid = pair_reader.expect(der.tag_oid) catch return error.BadName;
    if (!std.mem.eql(u8, oid.value.of(bytes), &oid_common_name)) return error.BadName;
    const value = pair_reader.expect(der.tag_utf8_string) catch return error.BadName;
    pair_reader.finish() catch return error.BadName;
    if (value.value.len() == 0) return error.BadName;
    if (value.value.len() > constants.x509_cn_bytes_max) return error.BadName;
    return value.value;
}

fn read_public_key(bytes: []const u8, reader: *der.Reader) Error!Span {
    const info = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    var inner = der.Reader.init(bytes, info.value);
    const algorithm = inner.expect(der.tag_sequence) catch |err| return mapped(err);
    if (!read_span_equal(bytes, algorithm, &algorithm_ed25519)) return error.BadAlgorithm;
    const bits = inner.expect(der.tag_bit_string) catch |err| return mapped(err);
    inner.finish() catch |err| return mapped(err);
    if (bits.value.len() != 33) return error.Malformed;
    if (bits.value.of(bytes)[0] != 0) return error.Malformed;
    return .{ .start = bits.value.start + 1, .end = bits.value.end };
}

fn read_validity(bytes: []const u8, validity: der.Element, parsed: *Parsed) Error!void {
    var reader = der.Reader.init(bytes, validity.value);
    var seconds: [2]u64 = undefined;
    for (&seconds) |*slot| {
        const element = reader.next() catch |err| return mapped(err);
        const known = element.tag == der.tag_utc_time or element.tag == der.tag_generalized_time;
        if (!known) return error.BadTime;
        slot.* = try read_time(element.value.of(bytes), element.tag);
    }
    reader.finish() catch |err| return mapped(err);
    if (seconds[1] <= seconds[0]) return error.BadValidity;
    parsed.not_before_ms = seconds[0] * 1000;
    parsed.not_after_ms = seconds[1] * 1000;
}

/// After the key: no unique IDs, then `[3] EXPLICIT Extensions`, then the end.
fn read_extensions_element(bytes: []const u8, reader: *der.Reader) Error!Span {
    if (reader.finished()) return error.MissingExtension;
    const element = reader.next() catch |err| return mapped(err);
    const unique_id = element.tag == tag_issuer_unique_id or element.tag == tag_subject_unique_id;
    if (unique_id) return error.UniqueId;
    if (element.tag != tag_context_3) return error.Malformed;
    reader.finish() catch |err| return mapped(err);
    var wrapper = der.Reader.init(bytes, element.value);
    const list = wrapper.expect(der.tag_sequence) catch |err| return mapped(err);
    wrapper.finish() catch |err| return mapped(err);
    return list.value;
}

const Known = enum(u3) { basic, usage, ext_usage, san, identity, subject_key_id, authority_key_id };

fn classify(oid: []const u8) ?Known {
    if (std.mem.eql(u8, oid, &oid_basic_constraints)) return .basic;
    if (std.mem.eql(u8, oid, &oid_key_usage)) return .usage;
    if (std.mem.eql(u8, oid, &oid_ext_key_usage)) return .ext_usage;
    if (std.mem.eql(u8, oid, &oid_subject_alt_name)) return .san;
    if (std.mem.eql(u8, oid, &oid_identity)) return .identity;
    if (std.mem.eql(u8, oid, &oid_subject_key_id)) return .subject_key_id;
    if (std.mem.eql(u8, oid, &oid_authority_key_id)) return .authority_key_id;
    return null;
}

fn known_field(known: Known) Field {
    return switch (known) {
        .basic => .basic_constraints,
        .usage => .key_usage,
        .ext_usage => .ext_key_usage,
        .san => .subject_alt_name,
        .identity => .identity,
        .subject_key_id, .authority_key_id => .key_identifier,
    };
}

const Extension = struct {
    known: ?Known,
    critical: bool,
    oid: Span,
    value: Span,
};

/// One Extension: SEQUENCE { OID, BOOLEAN TRUE (only if critical), OCTET STRING }.
fn read_extension(bytes: []const u8, reader: *der.Reader) Error!Extension {
    const element = reader.expect(der.tag_sequence) catch |err| return mapped(err);
    var inner = der.Reader.init(bytes, element.value);
    const oid = inner.expect(der.tag_oid) catch |err| return mapped(err);
    var next = inner.next() catch |err| return mapped(err);
    var critical = false;
    if (next.tag == der.tag_boolean) {
        // DER writes TRUE as 0xFF and omits FALSE (the default).
        if (!std.mem.eql(u8, next.value.of(bytes), &.{0xFF})) return error.BadExtension;
        critical = true;
        next = inner.next() catch |err| return mapped(err);
    }
    if (next.tag != der.tag_octet_string) return error.Malformed;
    inner.finish() catch |err| return mapped(err);
    return .{
        .known = classify(oid.value.of(bytes)),
        .critical = critical,
        .oid = oid.value,
        .value = next.value,
    };
}

/// Reads the next extension and checks it is `want` and not seen before. The refusal says which
/// way it was wrong: unknown and critical, a repeat, or merely not here.
fn expect_extension(
    bytes: []const u8,
    reader: *der.Reader,
    seen: *u8,
    want: Known,
    critical: bool,
    detail: *Detail,
) Error!Span {
    detail.field = known_field(want);
    if (reader.finished()) return error.MissingExtension;
    const extension = try read_extension(bytes, reader);
    const known = extension.known orelse {
        if (extension.critical) return error.UnknownCritical;
        return error.UnexpectedExtension;
    };
    const bit = @as(u8, 1) << @backingInt(known);
    if (seen.* & bit != 0) return error.DuplicateExtension;
    if (known != want) return error.UnexpectedExtension;
    seen.* |= bit;
    if (extension.critical != critical) return error.BadExtension;
    return extension.value;
}

/// Anything left after the last extension is an extension that the kind does not carry.
fn expect_no_more(bytes: []const u8, reader: *der.Reader, seen: u8, detail: *Detail) Error!void {
    detail.field = .extensions;
    if (reader.finished()) return;
    const extension = try read_extension(bytes, reader);
    const known = extension.known orelse {
        if (extension.critical) return error.UnknownCritical;
        return error.UnexpectedExtension;
    };
    if (seen & (@as(u8, 1) << @backingInt(known)) != 0) return error.DuplicateExtension;
    return error.UnexpectedExtension;
}

fn read_extensions(bytes: []const u8, list: Span, parsed: *Parsed, detail: *Detail) Error!void {
    var reader = der.Reader.init(bytes, list);
    var seen: u8 = 0;
    const basic = try expect_extension(bytes, &reader, &seen, .basic, true, detail);
    if (std.mem.eql(u8, basic.of(bytes), &basic_ca)) {
        parsed.kind = .ca;
        const usage = try expect_extension(bytes, &reader, &seen, .usage, true, detail);
        if (!std.mem.eql(u8, usage.of(bytes), &usage_ca)) return error.BadExtension;
        return expect_no_more(bytes, &reader, seen, detail);
    }
    if (!std.mem.eql(u8, basic.of(bytes), &basic_leaf)) return error.BadExtension;
    const usage = try expect_extension(bytes, &reader, &seen, .usage, true, detail);
    if (!std.mem.eql(u8, usage.of(bytes), &usage_leaf)) return error.BadExtension;
    const ext_usage = try expect_extension(bytes, &reader, &seen, .ext_usage, true, detail);
    if (std.mem.eql(u8, ext_usage.of(bytes), &usage_client)) {
        parsed.kind = .workload;
    } else if (std.mem.eql(u8, ext_usage.of(bytes), &usage_server)) {
        parsed.kind = .server;
    } else return error.BadExtension;
    const san = try expect_extension(bytes, &reader, &seen, .san, false, detail);
    parsed.name = try read_san(bytes, san, parsed.kind);
    if (parsed.kind == .workload) {
        const value = try expect_extension(bytes, &reader, &seen, .identity, false, detail);
        _ = identity_mod.decode(value.of(bytes)) catch return error.BadIdentity;
        parsed.identity = value;
    }
    return expect_no_more(bytes, &reader, seen, detail);
}

/// A SAN with exactly one name of the kind's type, in the kind's shape.
fn read_san(bytes: []const u8, value: Span, kind: Kind) Error!Span {
    var outer = der.Reader.init(bytes, value);
    const sequence = outer.expect(der.tag_sequence) catch return error.BadSan;
    outer.finish() catch return error.BadSan;
    var reader = der.Reader.init(bytes, sequence.value);
    const name = reader.next() catch return error.BadSan;
    reader.finish() catch return error.BadSan;
    const text = name.value.of(bytes);
    if (kind == .workload) {
        if (name.tag != tag_san_uri) return error.BadSan;
        _ = identity_mod.spiffe_parse(text) catch return error.BadSan;
    } else {
        if (name.tag != tag_san_dns) return error.BadSan;
        if (identity_mod.dns_problem(text, constants.x509_dns_name_bytes_max)) return error.BadSan;
    }
    return name.value;
}

/// The names fit the kind: the issuer is always a CA name; the subject is the CA's own name, the
/// service or job in the SPIFFE ID, or the DNS name.
fn check_names(bytes: []const u8, parsed: *const Parsed, detail: *Detail) Error!void {
    const issuer = parsed.issuer_cn.of(bytes);
    const subject = parsed.subject_cn.of(bytes);
    detail.field = .issuer;
    if (!ca_cn_is_valid(issuer)) return error.BadName;
    detail.field = .subject;
    switch (parsed.kind) {
        .ca => {
            if (!std.mem.eql(u8, issuer, subject)) return error.BadName;
        },
        .workload => {
            // `read_san` already parsed this name with the same function, so it cannot fail here.
            const spiffe = identity_mod.spiffe_parse(parsed.name.of(bytes)) catch unreachable;
            if (!std.mem.eql(u8, spiffe.name, subject)) return error.BadName;
        },
        .server => {
            if (!std.mem.eql(u8, parsed.name.of(bytes), subject)) return error.BadName;
        },
    }
    detail.field = .validity;
    const lifetime = parsed.not_after_ms - parsed.not_before_ms;
    if (lifetime > lifetime_bound_ms(parsed.kind)) return error.LifetimeTooLong;
}

// ---- The foreign server profile -------------------------------------------------------------

/// What the extensions of a foreign server leaf said, as the loop reads them in any order.
const Foreign = struct {
    seen: u8 = 0,
    oids: [constants.x509_foreign_extensions_max]Span = undefined,
    count: u32 = 0,
    is_ca: bool = false,
    server_auth: bool = false,
};

/// Extensions in any order. Each OID at most once; an unknown one is skipped unless critical;
/// keyUsage, extKeyUsage and subjectAltName are required.
fn read_extensions_foreign(
    bytes: []const u8,
    list: Span,
    parsed: *Parsed,
    detail: *Detail,
) Error!void {
    var reader = der.Reader.init(bytes, list);
    var state: Foreign = .{};
    while (!reader.finished()) {
        detail.field = .extensions;
        if (state.count == state.oids.len) return error.TooLarge;
        const extension = try read_extension(bytes, &reader);
        for (state.oids[0..state.count]) |oid| {
            if (std.mem.eql(u8, oid.of(bytes), extension.oid.of(bytes))) {
                return error.DuplicateExtension;
            }
        }
        state.oids[state.count] = extension.oid;
        state.count += 1;
        const known = extension.known orelse {
            if (extension.critical) return error.UnknownCritical;
            continue;
        };
        detail.field = known_field(known);
        state.seen |= @as(u8, 1) << @backingInt(known);
        try read_extension_foreign(bytes, known, &extension, parsed, &state);
    }
    inline for (.{ Known.usage, Known.ext_usage, Known.san }) |required| {
        detail.field = known_field(required);
        if (state.seen & (@as(u8, 1) << @backingInt(required)) == 0) return error.MissingExtension;
    }
    parsed.kind = if (state.is_ca) .ca else if (state.server_auth) .server else .workload;
}

fn read_extension_foreign(
    bytes: []const u8,
    known: Known,
    extension: *const Extension,
    parsed: *Parsed,
    state: *Foreign,
) Error!void {
    switch (known) {
        .basic => state.is_ca = try read_basic_foreign(bytes, extension.value),
        .usage => state.is_ca = try read_key_usage_foreign(bytes, extension.value) or state.is_ca,
        .ext_usage => state.server_auth = try read_ext_usage_foreign(bytes, extension.value),
        .san => parsed.name = try read_san_foreign(bytes, extension.value),
        .subject_key_id, .authority_key_id => {
            // RFC 5280 4.2.1.1 and 4.2.1.2: never critical. Read for shape only.
            if (extension.critical) return error.BadExtension;
            const tag = if (known == .subject_key_id) der.tag_octet_string else der.tag_sequence;
            var reader = der.Reader.init(bytes, extension.value);
            _ = reader.expect(tag) catch return error.BadExtension;
            reader.finish() catch return error.BadExtension;
        },
        // This cluster's identity extension means nothing under another anchor: it is skipped
        // like any unknown extension, and refused if marked critical.
        .identity => if (extension.critical) return error.UnknownCritical,
    }
}

/// BasicConstraints: an empty SEQUENCE (cA FALSE), or cA TRUE with an optional path length.
/// Returns whether it says CA. An explicit FALSE is not DER.
fn read_basic_foreign(bytes: []const u8, value: Span) Error!bool {
    var outer = der.Reader.init(bytes, value);
    const sequence = outer.expect(der.tag_sequence) catch return error.BadExtension;
    outer.finish() catch return error.BadExtension;
    var reader = der.Reader.init(bytes, sequence.value);
    if (reader.finished()) return false;
    const flag = reader.expect(der.tag_boolean) catch return error.BadExtension;
    if (!std.mem.eql(u8, flag.value.of(bytes), &.{0xFF})) return error.BadExtension;
    if (!reader.finished()) {
        const path = reader.expect(der.tag_integer) catch return error.BadExtension;
        _ = der.unsigned_magnitude(path.value.of(bytes)) catch return error.BadExtension;
    }
    reader.finish() catch return error.BadExtension;
    return true;
}

/// KeyUsage: a DER named-bit BIT STRING (no trailing zero bits, unused bits zero) with
/// digitalSignature. Returns whether it also grants keyCertSign or cRLSign (a CA's usage).
fn read_key_usage_foreign(bytes: []const u8, value: Span) Error!bool {
    var outer = der.Reader.init(bytes, value);
    const bits = outer.expect(der.tag_bit_string) catch return error.BadExtension;
    outer.finish() catch return error.BadExtension;
    const content = bits.value.of(bytes);
    if (content.len < 2) return error.BadExtension;
    if (content.len > 3) return error.BadExtension;
    const unused = content[0];
    if (unused > 7) return error.BadExtension;
    const last = content[content.len - 1];
    if (last == 0) return error.BadExtension;
    if (last & ((@as(u8, 1) << @intCast(unused)) - 1) != 0) return error.BadExtension;
    if (last & (@as(u8, 1) << @intCast(unused)) == 0) return error.BadExtension;
    if (content[1] & 0x80 == 0) return error.BadExtension; // digitalSignature, bit 0
    return content[1] & 0x06 != 0; // keyCertSign (bit 5), cRLSign (bit 6)
}

/// ExtKeyUsage: 1..`x509_foreign_key_purposes_max` OIDs. Returns whether serverAuth is one.
fn read_ext_usage_foreign(bytes: []const u8, value: Span) Error!bool {
    var outer = der.Reader.init(bytes, value);
    const sequence = outer.expect(der.tag_sequence) catch return error.BadExtension;
    outer.finish() catch return error.BadExtension;
    var reader = der.Reader.init(bytes, sequence.value);
    if (reader.finished()) return error.BadExtension;
    var server_auth = false;
    var count: u32 = 0;
    while (!reader.finished()) {
        count += 1;
        if (count > constants.x509_foreign_key_purposes_max) return error.BadExtension;
        const oid = reader.expect(der.tag_oid) catch return error.BadExtension;
        if (std.mem.eql(u8, oid.value.of(bytes), &oid_server_auth)) server_auth = true;
    }
    return server_auth;
}

/// SubjectAltName: exactly one name, a DNS name or a SPIFFE ID, in the shapes `cluster` uses.
fn read_san_foreign(bytes: []const u8, value: Span) Error!Span {
    var outer = der.Reader.init(bytes, value);
    const sequence = outer.expect(der.tag_sequence) catch return error.BadSan;
    outer.finish() catch return error.BadSan;
    var reader = der.Reader.init(bytes, sequence.value);
    const name = reader.next() catch return error.BadSan;
    reader.finish() catch return error.BadSan;
    const text = name.value.of(bytes);
    switch (name.tag) {
        tag_san_dns => {
            const bound = constants.x509_dns_name_bytes_max;
            if (identity_mod.dns_problem(text, bound)) return error.BadSan;
        },
        tag_san_uri => _ = identity_mod.spiffe_parse(text) catch return error.BadSan,
        else => return error.BadSan,
    }
    return name.value;
}

fn check_foreign(bytes: []const u8, parsed: *const Parsed, detail: *Detail) Error!void {
    _ = bytes;
    detail.field = .issuer;
    if (parsed.issuer_cn.len() == 0) return error.BadName;
    detail.field = .validity;
    const lifetime = parsed.not_after_ms - parsed.not_before_ms;
    if (lifetime > constants.x509_foreign_ttl_ms_max) return error.LifetimeTooLong;
}

/// Writes a parsed certificate again, with its own signature. For every input `parse` accepts the
/// result is the input (`x509_fuzz.zig` checks it).
pub fn reencode(out: *Der, bytes: []const u8, parsed: *const Parsed) Error!void {
    assert(parsed.profile == .cluster);
    const tbs: Tbs = .{
        .kind = parsed.kind,
        .serial = parsed.serial.of(bytes),
        .issuer_cn = parsed.issuer_cn.of(bytes),
        .subject_cn = parsed.subject_cn.of(bytes),
        .not_before_s = parsed.not_before_ms / 1000,
        .not_after_s = parsed.not_after_ms / 1000,
        .public_key = parsed.public_key.of(bytes)[0..32].*,
        .name = parsed.name.of(bytes),
        .identity = parsed.identity.of(bytes),
    };
    try write_certificate(out, &tbs, .{ .bytes = parsed.signature.of(bytes)[0..64].* });
}

// ---- Verification ----------------------------------------------------------------------------

/// Test-only faults for the teeth tests, as in `peer.zig`: each skips one check.
pub const TestFault = enum { signature, window, name };
var faults: [3]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

pub const Expect = struct {
    kind: Kind,
    /// The SPIFFE URI or DNS name the certificate must carry, when the caller named one.
    name: ?[]const u8,
};

/// `verify_detailed` without the detail.
pub fn verify(bytes: []const u8, anchor: [32]u8, now_ms: u64, expect: Expect) Error!Parsed {
    var detail: Detail = .{};
    return verify_detailed(bytes, anchor, now_ms, expect, &detail);
}

/// Parses `bytes` under the `cluster` profile and checks it against the pinned CA key `anchor` at
/// wall time `now_ms`. The order is the order of `peer.verify`: shape, issuer, signature, use,
/// window, name; so a forged certificate never reaches an expiry message. Only certificates
/// signed directly by the CA are accepted.
pub fn verify_detailed(
    bytes: []const u8,
    anchor: [32]u8,
    now_ms: u64,
    expect: Expect,
    detail: *Detail,
) Error!Parsed {
    const parsed = try parse_profile(bytes, .cluster, detail);
    detail.field = .issuer;
    const expected_issuer = ca_cn(anchor);
    if (!std.mem.eql(u8, parsed.issuer_cn.of(bytes), &expected_issuer)) return error.WrongIssuer;
    if (parsed.kind == .ca) {
        // A CA certificate is its own issuer: it must carry the pinned key.
        if (!std.mem.eql(u8, parsed.public_key.of(bytes), &anchor)) return error.WrongIssuer;
    }
    try check_after_shape(bytes, &parsed, anchor, now_ms, expect, detail);
    return parsed;
}

/// Parses `bytes` under the `foreign_server` profile and checks it is a server certificate for
/// `name`, signed directly by `anchor`, valid at `now_ms`. Same order as `verify_detailed`; the
/// issuer is not compared by name, only by signature.
pub fn verify_foreign_server(
    bytes: []const u8,
    anchor: [32]u8,
    now_ms: u64,
    name: []const u8,
    detail: *Detail,
) Error!Parsed {
    assert(name.len > 0);
    const parsed = try parse_profile(bytes, .foreign_server, detail);
    const want: Expect = .{ .kind = .server, .name = name };
    try check_after_shape(bytes, &parsed, anchor, now_ms, want, detail);
    return parsed;
}

/// Signature, use, window, name: the checks both profiles share once the shape is accepted.
fn check_after_shape(
    bytes: []const u8,
    parsed: *const Parsed,
    anchor: [32]u8,
    now_ms: u64,
    expect: Expect,
    detail: *Detail,
) Error!void {
    detail.field = .signature;
    if (!fault_on(.signature)) {
        const public = Ed25519.PublicKey.fromBytes(anchor) catch return error.BadSignature;
        const signature = Ed25519.Signature.fromBytes(parsed.signature.of(bytes)[0..64].*);
        signature.verify(parsed.tbs.of(bytes), public) catch return error.BadSignature;
    }
    detail.kind_expected = expect.kind;
    detail.kind_found = parsed.kind;
    if (parsed.kind != expect.kind) return error.WrongUse;
    detail.field = .validity;
    detail.not_before_ms = parsed.not_before_ms;
    detail.not_after_ms = parsed.not_after_ms;
    detail.now_ms = now_ms;
    if (!fault_on(.window)) try check_window(parsed, now_ms);
    detail.field = .subject_alt_name;
    if (expect.name) |name| {
        detail.name_expected = name;
        detail.name_found = parsed.name.of(bytes);
        if (!fault_on(.name)) {
            if (!std.mem.eql(u8, parsed.name.of(bytes), name)) return error.WrongName;
        }
    }
}

/// Valid from `not_before - skew` (inclusive) to `not_after + skew` (exclusive): decision file
/// 2026-11-04-x509-validity-boundaries.md.
fn check_window(parsed: *const Parsed, now_ms: u64) Error!void {
    const skew = constants.peer_clock_skew_ms;
    if (parsed.not_before_ms > now_ms +| skew) return error.NotYetValid;
    if (now_ms >= parsed.not_after_ms +| skew) return error.Expired;
}

// ---- Diagnostics -----------------------------------------------------------------------------

/// The refusal in words, for the cause line (no Zig error name reaches a user).
pub fn reason(err: Error) []const u8 {
    return switch (err) {
        error.Malformed => "it is not strict DER",
        error.TooLarge => "it is over a size or count limit",
        error.BadVersion => "it is not X.509 v3",
        error.BadAlgorithm => "it uses an algorithm other than Ed25519",
        error.UniqueId => "it carries a unique ID",
        error.BadSerial => "its serial number is zero, negative, empty or too long",
        error.BadName => "its issuer or subject is not a Name of the expected form",
        error.BadTime => "a validity time is not in the canonical form",
        error.BadValidity => "it expires before it starts",
        error.LifetimeTooLong => "its lifetime is over the bound for its kind",
        error.UnknownCritical => "it has a critical extension this code does not know",
        error.DuplicateExtension => "it repeats an extension",
        error.UnexpectedExtension => "it has an extension its kind does not carry",
        error.MissingExtension => "it lacks an extension its kind needs",
        error.BadExtension => "an extension has the wrong flag or value",
        error.BadSan => "its subjectAltName is not exactly one name of the right shape",
        error.BadIdentity => "its identity extension is malformed or over a bound",
        error.WrongIssuer => "its issuer is not the pinned CA",
        error.BadSignature => "its signature does not verify under the pinned anchor key",
        error.WrongUse => "it is a certificate of another kind than this use needs",
        error.Expired => "it has expired",
        error.NotYetValid => "it is not valid yet",
        error.WrongName => "it names another subject than the one asked for",
        error.NoSpace => "it does not fit the certificate size limit",
        error.TooManyLabels => "there are more labels than the limit",
        error.LabelTooLong => "a label key or value is empty or over its limit",
        error.LabelsTooLarge => "the labels together are over the limit",
        error.LabelsNotSorted => "label keys are not sorted and unique",
        error.BadLabel => "a label has a byte or a character that is not allowed",
        error.BadCluster => "the cluster name is not a lowercase DNS name",
        error.BadServiceName => "the service or job name is not a valid name",
        error.BadSpiffe => "the SPIFFE ID is not spiffe://<cluster>/service/<name>" ++
            " or spiffe://<cluster>/job/<name>",
        error.BadDnsName => "the DNS name is not lowercase, has a wildcard or an all-digit label",
        error.IssueLifetime => "the lifetime is empty, over the bound or out of range",
    };
}

fn kind_text(kind: Kind) []const u8 {
    return switch (kind) {
        .ca => "a CA certificate",
        .workload => "a client certificate",
        .server => "a server certificate",
    };
}

/// RFC 3339 in UTC, to the second: `2023-11-14T22:13:20Z`. Times past year 9999 print as 9999.
fn format_time(buffer: *[20]u8, ms: u64) []const u8 {
    const civil = civil_from_seconds(@min(ms / 1000, seconds_max));
    const printed = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.second,
    }) catch unreachable; // 20 bytes fit exactly for the years 1970..9999
    assert(printed.len == 20);
    return printed;
}

/// Raises the diagnostic for a refusal: one line, what was refused and why, and a fix. `subject`
/// names what the certificate was for (a peer address, a service), for the cause; `detail` is
/// what `verify_detailed` or `parse_profile` left.
pub fn raise(diag: *Diag, err: Error, subject: []const u8, detail: *const Detail) void {
    const code = code_of(err);
    diag.raise(code);
    switch (code) {
        .E0809 => raise_shape(diag, err, subject, detail),
        .E0811 => raise_window(diag, err, subject, detail),
        .E0812 => diag.cause("{s}'s certificate names {s}, not {s}", .{
            subject, detail.name_found, detail.name_expected,
        }),
        .E0817 => diag.cause("no identity for {s}: {s}", .{ subject, reason(err) }),
        .E0819 => diag.cause("{s}'s certificate is {s}; this use needs {s}", .{
            subject, kind_text(detail.kind_found), kind_text(detail.kind_expected),
        }),
        else => diag.cause("{s}'s certificate was refused: {s}", .{ subject, reason(err) }),
    }
    diag.fix(.{ .sentence = fix_sentence(code), .command = fix_command(code) });
}

fn raise_shape(diag: *Diag, err: Error, subject: []const u8, detail: *const Detail) void {
    assert(code_of(err) == .E0809);
    const field = detail.field.text();
    if (err == error.Malformed) {
        diag.cause("{s}'s certificate was refused: its {s} is not strict DER", .{ subject, field });
    } else {
        diag.cause("{s}'s certificate was refused: {s} (field: {s})", .{
            subject, reason(err), field,
        });
    }
}

fn raise_window(diag: *Diag, err: Error, subject: []const u8, detail: *const Detail) void {
    assert(code_of(err) == .E0811);
    var before: [20]u8 = undefined;
    var after: [20]u8 = undefined;
    var now: [20]u8 = undefined;
    diag.cause("{s}'s certificate {s}: valid {s} to {s}, now {s} (allowing {d} s of skew)", .{
        subject,
        if (err == error.Expired) "has expired" else "is not valid yet",
        format_time(&before, detail.not_before_ms),
        format_time(&after, detail.not_after_ms),
        format_time(&now, detail.now_ms),
        constants.peer_clock_skew_ms / 1000,
    });
}

fn fix_sentence(code: @import("diag/codes.zig").Code) []const u8 {
    return switch (code) {
        .E0811 => "check the clocks on both sides, then ask for a new certificate",
        .E0812 => "connect to the name the certificate is for, " ++
            "or issue the server a certificate for the name asked for",
        .E0817 => "correct the name, labels or lifetime, then issue again",
        .E0819 => "give the peer a certificate issued for its role (docs/mtls.md)",
        else => "check that both sides use this cluster's CA or the pinned anchor (docs/mtls.md)",
    };
}

fn fix_command(code: @import("diag/codes.zig").Code) []const u8 {
    return if (code == .E0811) "timedatectl" else "";
}
