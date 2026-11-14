//! OpenPGP (RFC 4880, v4 packets) for the checked-in package test key: Ed25519 signatures in the
//! legacy EdDSA form (algorithm 22) that gpg, apt's sqv and rpm all read, and ASCII armor.
//!
//! This is the test key only. It signs what the unit tests and the VM check serve, so that the
//! signature code is exercised end to end. It vouches for nothing: a release is signed by the
//! owner's gpg key, in the two-round flow of `docs/releases/packaging.md`, and this module never
//! sees that key.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha1 = std.crypto.hash.Sha1;
const Output = std.Io.Writer.Allocating;

pub const Error = error{ OutOfMemory, WriteFailed, BadSignature };

/// The seed of the test key. It is public: anyone can sign as this key, which is why nothing
/// trusts it outside the tests and the VM check.
pub const test_seed = [32]u8{
    0xa0, 0x29, 0xd9, 0x0e, 0x65, 0xcf, 0x37, 0x50, 0x38, 0x7b, 0xcc, 0x76, 0xb9, 0x92, 0x5d, 0x5c,
    0x8e, 0xf9, 0x1d, 0x01, 0x88, 0x1f, 0xe5, 0x75, 0x3e, 0x34, 0xc4, 0x0a, 0x8d, 0xe1, 0x15, 0x7e,
};

const algorithm_eddsa: u8 = 22;
const hash_sha256: u8 = 8;
/// The curve OID of Ed25519 in OpenPGP, 1.3.6.1.4.1.11591.15.1, as stored (length, then bytes).
const ed25519_oid = [_]u8{ 0x09, 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01 };

const packet_signature: u8 = 2;
const packet_public_key: u8 = 6;
const packet_user_id: u8 = 13;

pub const SignatureKind = enum(u8) {
    binary = 0x00,
    text = 0x01,
    positive_certification = 0x13,
};

pub fn test_key() Ed25519.KeyPair {
    // Fixed seed: a valid key, checked by the tests.
    return Ed25519.KeyPair.generateDeterministic(test_seed) catch unreachable;
}

fn put(writer: *std.Io.Writer, bytes: []const u8) Error!void {
    writer.writeAll(bytes) catch return error.WriteFailed;
}

fn put_int(writer: *std.Io.Writer, comptime T: type, value: T) Error!void {
    writer.writeInt(T, value, .big) catch return error.WriteFailed;
}

/// An OpenPGP multiprecision integer: bit count, then the value without leading zero bytes.
fn put_mpi(writer: *std.Io.Writer, value: []const u8) Error!void {
    var start: usize = 0;
    while (start < value.len and value[start] == 0) start += 1;
    const significant = value[start..];
    assert(significant.len > 0);
    const top_bits: u32 = 8 - @clz(significant[0]);
    try put_int(writer, u16, @intCast((significant.len - 1) * 8 + top_bits));
    try put(writer, significant);
}

/// The body of the public-key packet: version, creation time, algorithm, OID and the point.
fn public_key_body(public: [32]u8) [1 + 4 + 1 + ed25519_oid.len + 2 + 33]u8 {
    var body: [1 + 4 + 1 + ed25519_oid.len + 2 + 33]u8 = undefined;
    var at: usize = 0;
    body[at] = 4;
    at += 1;
    std.mem.writeInt(u32, body[at..][0..4], @intCast(constants.package_source_date_epoch), .big);
    at += 4;
    body[at] = algorithm_eddsa;
    at += 1;
    @memcpy(body[at..][0..ed25519_oid.len], &ed25519_oid);
    at += ed25519_oid.len;
    std.mem.writeInt(u16, body[at..][0..2], 263, .big); // 0x40 prefix + 32 bytes: 263 bits.
    at += 2;
    body[at] = 0x40; // Native point format marker.
    @memcpy(body[at + 1 ..][0..32], &public);
    at += 33;
    assert(at == body.len);
    return body;
}

/// The v4 fingerprint: SHA-1 of 0x99, the two-byte length and the public-key body.
pub fn fingerprint(public: [32]u8) [20]u8 {
    const body = public_key_body(public);
    var hash = Sha1.init(.{});
    hash.update(&[_]u8{ 0x99, 0, body.len });
    hash.update(&body);
    return hash.finalResult();
}

pub fn key_id(public: [32]u8) [8]u8 {
    return fingerprint(public)[12..20].*;
}

/// A new-format packet header: the tag and a one- or two-octet length (all ours are short).
fn put_packet(writer: *std.Io.Writer, tag_number: u8, body: []const u8) Error!void {
    assert(body.len < 8384);
    try put(writer, &.{0xc0 | tag_number});
    if (body.len < 192) {
        try put(writer, &.{@intCast(body.len)});
    } else {
        const adjusted = body.len - 192;
        const high: u8 = @intCast(adjusted >> 8);
        try put(writer, &.{ high + 192, @intCast(adjusted & 0xff) });
    }
    try put(writer, body);
}

/// The hashed part of a signature, from the version through the hashed subpackets.
fn signature_prefix(memory: Allocator, kind: SignatureKind, public: [32]u8) Error![]u8 {
    var out = Output.init(memory);
    const writer = &out.writer;
    try put(writer, &.{ 4, @backingInt(kind), algorithm_eddsa, hash_sha256 });
    const print = fingerprint(public);
    // Creation time (type 2) and issuer fingerprint (type 33), both hashed; a certification
    // also says what the key may do (key flags, type 27: certify and sign).
    const flags_bytes: u16 = if (kind == .positive_certification) 3 else 0;
    try put_int(writer, u16, 6 + 23 + flags_bytes);
    try put(writer, &.{ 5, 2 });
    try put_int(writer, u32, @intCast(constants.package_source_date_epoch));
    try put(writer, &.{ 22, 33, 4 });
    try put(writer, &print);
    if (kind == .positive_certification) try put(writer, &.{ 2, 27, 0x03 });
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// SHA-256 over the signed material, the signature prefix and the v4 trailer.
fn signature_digest(material: []const []const u8, prefix: []const u8) [32]u8 {
    var hash = Sha256.init(.{});
    for (material) |part| hash.update(part);
    hash.update(prefix);
    hash.update(&.{ 0x04, 0xff });
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(prefix.len), .big);
    hash.update(&length);
    return hash.finalResult();
}

/// One signature packet over `material`, signed by `pair`.
fn signature_packet(
    memory: Allocator,
    pair: Ed25519.KeyPair,
    kind: SignatureKind,
    material: []const []const u8,
) Error![]u8 {
    const public = pair.public_key.toBytes();
    const prefix = try signature_prefix(memory, kind, public);
    const digest = signature_digest(material, prefix);
    // EdDSA in OpenPGP signs the hash digest itself as the message.
    const signature = (pair.sign(&digest, null) catch return error.BadSignature).toBytes();
    var body = Output.init(memory);
    const writer = &body.writer;
    try put(writer, prefix);
    try put_int(writer, u16, 10); // Unhashed: the issuer key id (type 16).
    try put(writer, &.{ 9, 16 });
    try put(writer, &key_id(public));
    try put(writer, digest[0..2]);
    try put_mpi(writer, signature[0..32]);
    try put_mpi(writer, signature[32..64]);
    var out = Output.init(memory);
    try put_packet(&out.writer, packet_signature, body.written());
    assert(out.written().len <= constants.openpgp_signature_bytes_max);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// A binary detached signature (what `gpg --detach-sign` writes) over `data`.
pub fn sign_detached(memory: Allocator, pair: Ed25519.KeyPair, data: []const u8) Error![]u8 {
    return signature_packet(memory, pair, .binary, &.{data});
}

/// The public key as a transferable key: key packet, user id, self-certification.
pub fn public_key_packets(memory: Allocator, pair: Ed25519.KeyPair) Error![]u8 {
    const public = pair.public_key.toBytes();
    const body = public_key_body(public);
    const user = constants.package_test_key_user_id;
    var out = Output.init(memory);
    try put_packet(&out.writer, packet_public_key, &body);
    try put_packet(&out.writer, packet_user_id, user);
    var key_head: [3]u8 = .{ 0x99, 0, body.len };
    var user_head: [5]u8 = undefined;
    user_head[0] = 0xb4;
    std.mem.writeInt(u32, user_head[1..5], user.len, .big);
    const certification = try signature_packet(memory, pair, .positive_certification, &.{
        &key_head, &body, &user_head, user,
    });
    try put(&out.writer, certification);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const crc24_init: u32 = 0xb704ce;
const crc24_poly: u32 = 0x1864cfb;

fn crc24(bytes: []const u8) u32 {
    var crc: u32 = crc24_init;
    for (bytes) |byte| {
        crc ^= @as(u32, byte) << 16;
        for (0..8) |_| {
            crc <<= 1;
            if (crc & 0x1000000 != 0) crc ^= crc24_poly;
        }
    }
    return crc & 0xffffff;
}

/// ASCII armor with the given label (`PGP SIGNATURE`, `PGP PUBLIC KEY BLOCK`).
pub fn armor(memory: Allocator, label: []const u8, bytes: []const u8) Error![]u8 {
    assert(bytes.len <= constants.repo_metadata_bytes_max);
    var out = Output.init(memory);
    const writer = &out.writer;
    writer.print("-----BEGIN {s}-----\n\n", .{label}) catch return error.WriteFailed;
    const raw_per_line = constants.armor_line_bytes / 4 * 3;
    var at: usize = 0;
    while (at < bytes.len) : (at += raw_per_line) {
        const chunk = bytes[at..@min(bytes.len, at + raw_per_line)];
        var line: [constants.armor_line_bytes]u8 = undefined;
        writer.print("{s}\n", .{std.base64.standard.Encoder.encode(&line, chunk)}) catch
            return error.WriteFailed;
    }
    const crc = crc24(bytes);
    const crc_bytes = [3]u8{
        @intCast(crc >> 16),
        @intCast((crc >> 8) & 0xff),
        @intCast(crc & 0xff),
    };
    var crc_line: [4]u8 = undefined;
    writer.print("={s}\n-----END {s}-----\n", .{
        std.base64.standard.Encoder.encode(&crc_line, &crc_bytes), label,
    }) catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// `gpg --clearsign`: the text, dash-escaped, then a text signature over its canonical form
/// (lines end CRLF with trailing blanks stripped; the last line ending is not signed).
pub fn clearsign(memory: Allocator, pair: Ed25519.KeyPair, text: []const u8) Error![]u8 {
    var canonical = Output.init(memory);
    var shown = Output.init(memory);
    try put(&shown.writer, "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n");
    var body = text;
    if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try put(&canonical.writer, "\r\n");
        first = false;
        try put(&canonical.writer, std.mem.trimEnd(u8, line, " \t\r"));
        if (line.len > 0 and line[0] == '-') try put(&shown.writer, "- ");
        try put(&shown.writer, line);
        try put(&shown.writer, "\n");
    }
    const packet = try signature_packet(memory, pair, .text, &.{canonical.written()});
    try put(&shown.writer, try armor(memory, "PGP SIGNATURE", packet));
    return shown.toOwnedSlice() catch return error.OutOfMemory;
}

/// The fields of a v4 signature packet that tell what it signed.
const Parsed = struct {
    /// The hashed part, from the version through the hashed subpackets.
    prefix: []const u8,
    hashed_subpackets: []const u8,
    public_algorithm: u8,
    hash_algorithm: u8,
    /// The first 16 bits of the digest, which the packet records.
    left: [2]u8,
    /// The algorithm-specific signature data, checked to be well formed for its algorithm.
    material: []const u8,
};

/// The OpenPGP public-key algorithm numbers (RFC 4880 9.1, RFC 9580 9.1) a signature may use.
const algorithm_rsa: u8 = 1;
const algorithm_rsa_sign_only: u8 = 3;
const algorithm_dsa: u8 = 17;
const algorithm_ecdsa: u8 = 19;
const algorithm_ed25519_native: u8 = 27;

/// One multiprecision integer at `at`: a two-octet bit count, then the value's bytes. Null when
/// the count is zero, the value runs past `bytes` or starts with a zero byte (not minimal, RFC
/// 4880 3.2); on success `at` is past the value.
fn read_mpi(bytes: []const u8, at: *usize) ?[]const u8 {
    if (at.* + 2 > bytes.len) return null;
    const bits = std.mem.readInt(u16, bytes[at.*..][0..2], .big);
    if (bits == 0) return null;
    const length = (@as(usize, bits) + 7) / 8;
    const start = at.* + 2;
    if (length > bytes.len - start) return null;
    if (bytes[start] == 0) return null;
    at.* = start + length;
    return bytes[start..][0..length];
}

/// How many MPIs the signature data of `algorithm` holds: RSA one, DSA, ECDSA and legacy EdDSA
/// two. Null for an algorithm we do not read; Ed25519 (27) is raw bytes, not an MPI.
fn mpi_count(algorithm: u8) ?usize {
    return switch (algorithm) {
        algorithm_rsa, algorithm_rsa_sign_only => 1,
        algorithm_dsa, algorithm_ecdsa, algorithm_eddsa => 2,
        else => null,
    };
}

/// Whether `material` is exactly the signature data its algorithm defines.
fn material_valid(algorithm: u8, material: []const u8) bool {
    if (algorithm == algorithm_ed25519_native) return material.len == 64;
    const count = mpi_count(algorithm) orelse return false;
    var at: usize = 0;
    for (0..count) |_| {
        _ = read_mpi(material, &at) orelse return false;
    }
    return at == material.len;
}

/// The body of a signature packet in either header format: gpg writes the old one (`0x89`), this
/// module the new one (`0xc2`).
fn packet_body(packet: []const u8) ?[]const u8 {
    const split = packet_split(packet) orelse return null;
    if (split.total != packet.len) return null;
    return split.body;
}

const Split = struct { body: []const u8, total: usize };

/// The first signature packet of `packet`: its body and its whole length with the header.
fn packet_split(packet: []const u8) ?Split {
    if (packet.len < 2 or packet[0] & 0x80 == 0) return null;
    var at: usize = 1;
    var length: usize = 0;
    if (packet[0] & 0x40 != 0) {
        if (packet[0] & 0x3f != packet_signature) return null;
        if (packet[1] < 192) {
            length = packet[1];
            at = 2;
        } else if (packet[1] < 224 and packet.len >= 3) {
            length = (@as(usize, packet[1] - 192) << 8) + packet[2] + 192;
            at = 3;
        } else return null; // Five-octet and partial lengths: never a signature of ours or gpg's.
    } else {
        if ((packet[0] >> 2) & 0x0f != packet_signature) return null;
        const width: usize = switch (packet[0] & 3) {
            0 => 1,
            1 => 2,
            2 => 4,
            else => return null,
        };
        if (packet.len < 1 + width) return null;
        for (packet[1..][0..width]) |byte| length = (length << 8) | byte;
        at = 1 + width;
    }
    if (length > packet.len - at) return null;
    return .{ .body = packet[at..][0..length], .total = at + length };
}

fn parse(packet: []const u8) ?Parsed {
    const body = packet_body(packet) orelse return null;
    if (body.len < 6 or body[0] != 4) return null;
    const hashed_length = std.mem.readInt(u16, body[4..6], .big);
    const prefix_end = 6 + @as(usize, hashed_length);
    if (prefix_end + 2 > body.len) return null;
    const unhashed_length = std.mem.readInt(u16, body[prefix_end..][0..2], .big);
    var cursor = prefix_end + 2 + @as(usize, unhashed_length);
    if (cursor + 2 > body.len) return null;
    const left = body[cursor..][0..2].*;
    cursor += 2;
    const material = body[cursor..];
    if (!material_valid(body[2], material)) return null;
    return .{
        .prefix = body[0..prefix_end],
        .hashed_subpackets = body[6..prefix_end],
        .public_algorithm = body[2],
        .hash_algorithm = body[3],
        .left = left,
        .material = material,
    };
}

/// One subpacket length at the front of `rest` (RFC 4880 5.2.3.1): one octet below 192, two
/// octets below 255, else five. Null when it runs past `rest`.
fn subpacket_length(rest: []const u8, at: *usize) ?usize {
    if (rest.len == 0) return null;
    const first = rest[0];
    if (first < 192) {
        at.* = 1;
        return first;
    }
    if (first < 255) {
        if (rest.len < 2) return null;
        at.* = 2;
        return ((@as(usize, first) - 192) << 8) + rest[1] + 192;
    }
    if (rest.len < 5) return null;
    at.* = 5;
    return std.mem.readInt(u32, rest[1..5], .big);
}

/// The issuer fingerprint (subpacket 33) in the hashed part of a signature, when it has one.
pub fn issuer_fingerprint(packet: []const u8) ?[20]u8 {
    const parsed = parse(packet) orelse return null;
    var rest = parsed.hashed_subpackets;
    while (rest.len > 0) {
        var header: usize = 0;
        const length = subpacket_length(rest, &header) orelse return null;
        if (length == 0 or length > rest.len - header) return null;
        const body = rest[header..][0..length];
        if (body[0] & 0x7f == 33 and body.len == 22 and body[1] == 4) return body[2..22].*;
        rest = rest[header + length ..];
    }
    return null;
}

fn left_of(comptime Hash: type, material: []const []const u8, prefix: []const u8) [2]u8 {
    var hash = Hash.init(.{});
    for (material) |part| hash.update(part);
    hash.update(prefix);
    hash.update(&.{ 0x04, 0xff });
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(prefix.len), .big);
    hash.update(&length);
    return hash.finalResult()[0..2].*;
}

/// Whether the packet's recorded 16 digest bits are those of `material`: a swapped or stale
/// signature fails this, short of one chance in 65536. It is not a signature check (that needs
/// the public key, which the owner's `gpg --verify` has); it ties a signature file to its bytes.
fn digest_matches(packet: []const u8, material: []const []const u8) bool {
    const parsed = parse(packet) orelse return false;
    const left = switch (parsed.hash_algorithm) {
        8 => left_of(Sha256, material, parsed.prefix),
        9 => left_of(std.crypto.hash.sha2.Sha384, material, parsed.prefix),
        10 => left_of(std.crypto.hash.sha2.Sha512, material, parsed.prefix),
        11 => left_of(std.crypto.hash.sha2.Sha224, material, parsed.prefix),
        else => return false,
    };
    return std.mem.eql(u8, &left, &parsed.left);
}

/// The binary packets of the first armored block of `text` (`-----BEGIN ...` to `-----END`).
fn dearmor(memory: Allocator, text: []const u8) Error!?[]u8 {
    const begin = std.mem.indexOf(u8, text, "-----BEGIN PGP SIGNATURE-----") orelse return null;
    var lines = std.mem.splitScalar(u8, text[begin..], '\n');
    _ = lines.next();
    var base64: std.ArrayList(u8) = .empty;
    var in_headers = true;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (in_headers) {
            if (line.len == 0) in_headers = false;
            continue;
        }
        if (line.len == 0 or line[0] == '=' or line[0] == '-') break;
        try base64.appendSlice(memory, line);
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64.items) catch return null;
    const out = try memory.alloc(u8, size);
    decoder.decode(out, base64.items) catch return null;
    return out;
}

/// `text` as a text-mode signature hashes it: lines end CRLF, trailing blanks stripped, and the
/// last line ending is not part of it.
fn canonical_text(memory: Allocator, text: []const u8) Error![]u8 {
    var out = Output.init(memory);
    var body = text;
    if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try put(&out.writer, "\r\n");
        first = false;
        try put(&out.writer, std.mem.trimEnd(u8, line, " \t\r"));
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// What a signature file says about the bytes it sits beside.
pub const Binding = union(enum) {
    /// Not a signature over those bytes (stale, swapped or damaged).
    stale,
    /// More than one signature packet (a rotation signed with two keys): one key is expected.
    several,
    /// A signature packet version this module does not read (RFC 9580 v5 and v6).
    unsupported,
    bound: Bound,
};

pub const Form = enum {
    /// `gpg --clearsign`: the text and its signature in one file.
    clearsigned,
    /// `gpg -abs`: an armored signature over a file.
    armored_detached,
};

/// Whether `file` is a signature (in `form`) over exactly `signed`; the answer is the signature's
/// issuer fingerprint when it names one.
pub fn bound_to(
    memory: Allocator,
    form: Form,
    file: []const u8,
    signed: []const u8,
) Error!Binding {
    var packet: []u8 = undefined;
    var canonical: []const u8 = signed;
    switch (form) {
        .armored_detached => packet = (try dearmor(memory, file)) orelse return .stale,
        .clearsigned => {
            const header = "-----BEGIN PGP SIGNED MESSAGE-----";
            if (!std.mem.startsWith(u8, file, header)) return .stale;
            const blank = std.mem.indexOf(u8, file, "\n\n") orelse return .stale;
            const end = std.mem.indexOf(u8, file, "\n-----BEGIN PGP SIGNATURE-----") orelse
                return .stale;
            if (end < blank + 2) return .stale;
            var shown = Output.init(memory);
            var lines = std.mem.splitScalar(u8, file[blank + 2 .. end], '\n');
            while (lines.next()) |line| {
                const plain = if (std.mem.startsWith(u8, line, "- ")) line[2..] else line;
                try put(&shown.writer, plain);
                try put(&shown.writer, "\n");
            }
            const shown_canonical = try canonical_text(memory, shown.written());
            const signed_canonical = try canonical_text(memory, signed);
            if (!std.mem.eql(u8, shown_canonical, signed_canonical)) return .stale;
            canonical = signed_canonical;
            packet = (try dearmor(memory, file[end..])) orelse return .stale;
        },
    }
    return bound_binary(packet, canonical);
}

pub const Bound = struct { fingerprint: ?[20]u8 };

/// Whether `packet` (one binary signature packet, an rpm header signature) signs exactly
/// `data`. `.bound` carries its issuer fingerprint when it names one; `.several` is more than
/// one signature packet; `.unsupported` is a version other than 4 or a digest other than SHA-2;
/// anything else that is not a signature over `data` is `.stale`.
pub fn bound_binary(packet: []const u8, data: []const u8) Binding {
    const split = packet_split(packet) orelse return .stale;
    if (split.total < packet.len) {
        // Bytes after the packet are a second signature only when they parse as one.
        return if (packet_split(packet[split.total..]) != null) .several else .stale;
    }
    if (split.body.len == 0 or split.body[0] != 4) return .unsupported;
    const parsed = parse(packet) orelse return .stale;
    if (parsed.hash_algorithm < 8 or parsed.hash_algorithm > 11) return .unsupported;
    if (!digest_matches(packet, &.{data})) return .stale;
    return .{ .bound = .{ .fingerprint = issuer_fingerprint(packet) } };
}

/// Whether `packet` is a valid signature by `public` over `data` (binary kind) or over the
/// canonical text (`text` kind); checks with `std.crypto.sign.Ed25519`.
pub fn verify(packet: []const u8, material: []const []const u8, public: [32]u8) bool {
    const parsed = parse(packet) orelse return false;
    if (parsed.public_algorithm != algorithm_eddsa) return false;
    var at: usize = 0;
    const r = read_mpi(parsed.material, &at) orelse return false;
    const s = read_mpi(parsed.material, &at) orelse return false;
    if (r.len > 32 or s.len > 32) return false;
    var both: [64]u8 = @splat(0);
    @memcpy(both[32 - r.len .. 32], r);
    @memcpy(both[64 - s.len ..], s);
    const digest = signature_digest(material, parsed.prefix);
    const key = Ed25519.PublicKey.fromBytes(public) catch return false;
    const signature = Ed25519.Signature.fromBytes(both);
    signature.verify(&digest, key) catch return false;
    return true;
}

test "the test key signs and std's Ed25519 verifies over the OpenPGP hash input" {
    // Goal: the signature is what RFC 4880 hashes: data, the signature prefix and the trailer.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const pair = test_key();
    const public = pair.public_key.toBytes();
    const data = "Release file bytes\n";
    const packet = try sign_detached(memory, pair, data);
    try std.testing.expect(verify(packet, &.{data}, public));
    try std.testing.expect(!verify(packet, &.{"Release file bytez\n"}, public));
    var damaged = try memory.dupe(u8, packet);
    damaged[damaged.len - 3] ^= 1;
    try std.testing.expect(!verify(damaged, &.{data}, public));
    try std.testing.expectEqualSlices(u8, try sign_detached(memory, pair, data), packet);
}

test "armor ends in the CRC-24 of RFC 4880 and wraps at the line width" {
    // Goal: the one published CRC-24 check value, and a block that gpg can dearmor.
    try std.testing.expectEqual(@as(u32, 0x21cf02), crc24("123456789"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const long: [100]u8 = @splat(0x5a);
    const text = try armor(arena.allocator(), "PGP SIGNATURE", &long);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("-----BEGIN PGP SIGNATURE-----", lines.next().?);
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(@as(usize, constants.armor_line_bytes), lines.next().?.len);
    try std.testing.expectEqual(@as(usize, constants.armor_line_bytes), lines.next().?.len);
    try std.testing.expectEqual(@as(usize, 8), lines.next().?.len); // 100 bytes: 48 + 48 + 4.
    try std.testing.expect(lines.next().?[0] == '=');
    try std.testing.expectEqualStrings("-----END PGP SIGNATURE-----", lines.next().?);
}

const fixture_text = @embedFile("testdata/gpg/text.txt");
const fixture_rsa_fingerprint = [20]u8{
    0x3c, 0x71, 0x78, 0x72, 0x88, 0xe4, 0x52, 0xc4, 0xc5, 0x21,
    0x5c, 0x22, 0x58, 0xeb, 0x3a, 0xdc, 0x53, 0x6d, 0x1a, 0xb1,
};
const fixture_ed25519_fingerprint = [20]u8{
    0xa8, 0xc6, 0x24, 0x8d, 0x62, 0xb4, 0x25, 0x75, 0x22, 0x07,
    0x27, 0x93, 0x6b, 0x6c, 0xee, 0xf8, 0xee, 0x3b, 0xd7, 0x28,
};

fn expect_bound(binding: Binding, print: [20]u8) !void {
    try std.testing.expect(binding == .bound);
    try std.testing.expectEqualSlices(u8, &print, &binding.bound.fingerprint.?);
}

test "real gpg signatures (RSA 4096 and Ed25519) bind to their text, in every form" {
    // Goal: checked against real output. The fixtures are `gpg 2.4.4` output for a fixed text,
    // one RSA 4096 key and one Ed25519 key (SHA-512): binary, armored detached and clearsigned.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const keys = .{
        .{ "rsa4096", fixture_rsa_fingerprint },
        .{ "ed25519", fixture_ed25519_fingerprint },
    };
    inline for (keys) |key| {
        const binary = @embedFile("testdata/gpg/" ++ key[0] ++ ".bin.sig");
        try expect_bound(bound_binary(binary, fixture_text), key[1]);
        try std.testing.expect(bound_binary(binary, "other text\n") == .stale);
        const armored = @embedFile("testdata/gpg/" ++ key[0] ++ ".asc");
        try expect_bound(try bound_to(memory, .armored_detached, armored, fixture_text), key[1]);
        const clear = @embedFile("testdata/gpg/" ++ key[0] ++ ".clear");
        try expect_bound(try bound_to(memory, .clearsigned, clear, fixture_text), key[1]);
        const stale = try bound_to(memory, .clearsigned, clear, "other text\n");
        try std.testing.expect(stale == .stale);
    }
    // The RSA 4096 signature is the case the bound was raised for: more than 512, within 1024.
    const rsa = @embedFile("testdata/gpg/rsa4096.bin.sig");
    try std.testing.expect(rsa.len > 512 and rsa.len <= constants.openpgp_signature_bytes_max);
    // A signature over the digest of different text is not bound: swap the two keys' files.
    const swapped = bound_binary(@embedFile("testdata/gpg/rsa4096.bin.sig"), "swapped\n");
    try std.testing.expect(swapped == .stale);
}

test "a clearsign by two keys and a v5 packet are named, not called stale" {
    // Goal: two refusals that are not "stale or swapped": a rotation signature, a packet version.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const both = @embedFile("testdata/gpg/both.clear");
    try std.testing.expect(try bound_to(memory, .clearsigned, both, fixture_text) == .several);
    const rsa = @embedFile("testdata/gpg/rsa4096.asc");
    var packet = (try dearmor(memory, rsa)).?;
    const body_at = packet_split(packet).?.total - packet_split(packet).?.body.len;
    packet[body_at] = 5;
    const armored = try armor(memory, "PGP SIGNATURE", packet);
    const binding = try bound_to(memory, .armored_detached, armored, fixture_text);
    try std.testing.expect(binding == .unsupported);
}

test "a subpacket of 192 bytes or more does not hide the issuer fingerprint" {
    // Goal: two-octet and five-octet subpacket lengths are skipped, not given up on. A long
    // notation sits before the issuer fingerprint; the real gpg one (notation fixture) is by key
    // Ed25519, and a hand-built hashed area covers the five-octet form.
    const notation = @embedFile("testdata/gpg/ed25519-notation.bin.sig");
    try std.testing.expectEqualSlices(
        u8,
        &fixture_ed25519_fingerprint,
        &issuer_fingerprint(notation).?,
    );
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const print: [20]u8 = @splat(0x77);
    const forms = [_][]const u8{ // The long subpacket's length octets: two-octet, five-octet.
        &.{ 192 + 1, 4 }, // 1 * 256 + 4 + 192 = 452 bytes.
        &.{ 255, 0, 0, 1, 200 }, // 456 bytes.
    };
    for (forms) |length_octets| {
        var area: std.ArrayList(u8) = .empty;
        try area.appendSlice(memory, length_octets);
        const long_length: usize = if (length_octets.len == 2) 452 else 456;
        try area.appendNTimes(memory, 20, long_length); // Subpacket type 20, then padding.
        try area.appendSlice(memory, &.{ 22, 33, 4 });
        try area.appendSlice(memory, &print);
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(memory, &.{ 4, 0, algorithm_rsa, 10 });
        const area_length: u16 = @intCast(area.items.len);
        const area_high: u8 = @intCast(area_length >> 8);
        try body.appendSlice(memory, &.{ area_high, @intCast(area_length & 0xff) });
        try body.appendSlice(memory, area.items);
        try body.appendSlice(memory, &.{ 0, 0, 0x12, 0x34, 0, 8, 0xff }); // One 8-bit MPI.
        var packet: std.ArrayList(u8) = .empty;
        const adjusted = body.items.len - 192; // A two-octet packet length.
        const high: u8 = @intCast(192 + (adjusted >> 8));
        try packet.appendSlice(memory, &.{ 0xc2, high, @intCast(adjusted & 0xff) });
        try packet.appendSlice(memory, body.items);
        try std.testing.expectEqualSlices(u8, &print, &issuer_fingerprint(packet.items).?);
    }
}

/// A v4 signature packet (new-format header) with no subpackets and `material` after the 16
/// digest bits, which are those of `text` when `left` is null.
fn tiny_packet(
    memory: Allocator,
    algorithm: u8,
    hash: u8,
    left: ?[2]u8,
    material: []const u8,
) ![]u8 {
    const prefix = [_]u8{ 4, 0, algorithm, hash, 0, 0 };
    const digest = left orelse left_of(Sha256, &.{fixture_text}, &prefix);
    const length: u8 = @intCast(prefix.len + 2 + 2 + material.len);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(memory, &.{ 0xc2, length });
    try out.appendSlice(memory, &prefix);
    try out.appendSlice(memory, &.{ 0, 0 });
    try out.appendSlice(memory, &digest);
    try out.appendSlice(memory, material);
    return out.items;
}

test "read_mpi refuses a zero count, an overrun and a leading zero byte" {
    // Goal: every branch of read_mpi, including the position it leaves behind.
    var at: usize = 0;
    try std.testing.expect(read_mpi(&.{ 0, 8, 0xff }, &at).?.len == 1);
    try std.testing.expect(at == 3);
    at = 0;
    try std.testing.expect(read_mpi(&.{0}, &at) == null); // No room for the count.
    try std.testing.expect(read_mpi(&.{ 0, 0 }, &at) == null); // Zero bits.
    try std.testing.expect(read_mpi(&.{ 0, 16, 0xff }, &at) == null); // Overrun.
    try std.testing.expect(read_mpi(&.{ 0, 9, 0x00, 0xff }, &at) == null); // Leading zero.
    try std.testing.expect(at == 0);
}

test "material_valid is exact for each algorithm" {
    // Goal: counts of MPIs per algorithm, trailing bytes, and 64 raw bytes for algorithm 27.
    const one = [_]u8{ 0, 8, 0xff };
    const two = one ++ one;
    try std.testing.expect(material_valid(algorithm_rsa, &one));
    try std.testing.expect(!material_valid(algorithm_rsa, &two)); // Trailing bytes.
    try std.testing.expect(!material_valid(algorithm_rsa, &.{ 0, 0 })); // bits = 0.
    try std.testing.expect(!material_valid(algorithm_rsa, &.{ 0, 16, 0xff })); // Overrun.
    try std.testing.expect(!material_valid(algorithm_rsa, &.{})); // Nothing at all.
    for ([_]u8{ algorithm_dsa, algorithm_ecdsa, algorithm_eddsa }) |algorithm| {
        try std.testing.expect(material_valid(algorithm, &two));
        try std.testing.expect(!material_valid(algorithm, &one)); // One MPI short.
        try std.testing.expect(!material_valid(algorithm, &(two ++ [_]u8{0}))); // Trailing.
    }
    const raw: [65]u8 = @splat(1);
    try std.testing.expect(!material_valid(algorithm_ed25519_native, raw[0..63]));
    try std.testing.expect(material_valid(algorithm_ed25519_native, raw[0..64]));
    try std.testing.expect(!material_valid(algorithm_ed25519_native, raw[0..65]));
    try std.testing.expect(!material_valid(99, &one)); // An algorithm we do not read.
}

test "bound_binary names each refusal and binds an algorithm 27 signature" {
    // Goal: the header path gets the same one-case-one-answer as the detached path.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const raw: [64]u8 = @splat(1);
    const good = try tiny_packet(memory, algorithm_ed25519_native, hash_sha256, null, &raw);
    try std.testing.expect(bound_binary(good, fixture_text) == .bound);
    try std.testing.expect(bound_binary(good, "other\n") == .stale);
    // Two signatures in a row are several; bytes that are no packet are only stale.
    const twice = try std.mem.concat(memory, u8, &.{ good, good });
    try std.testing.expect(bound_binary(twice, fixture_text) == .several);
    const trailing = try std.mem.concat(memory, u8, &.{ good, "xyz" });
    try std.testing.expect(bound_binary(trailing, fixture_text) == .stale);
    // Version 5, SHA-1 and an unreadable algorithm are named, not stale.
    const v5 = try memory.dupe(u8, good);
    v5[2] = 5;
    try std.testing.expect(bound_binary(v5, fixture_text) == .unsupported);
    const sha1 = try tiny_packet(memory, algorithm_ed25519_native, 2, null, &raw);
    try std.testing.expect(bound_binary(sha1, fixture_text) == .unsupported);
    const short = try tiny_packet(memory, algorithm_ed25519_native, hash_sha256, null, raw[0..63]);
    try std.testing.expect(bound_binary(short, fixture_text) == .stale);
}
