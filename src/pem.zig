//! PEM text for the cluster's files: one CERTIFICATE block (a certificate of the cluster profile)
//! or one PRIVATE KEY block (an Ed25519 key as PKCS#8, RFC 8410), each in exactly the form
//! `encode` writes: 64 base64 characters a line, a newline after each. `decode` accepts that
//! form and nothing looser, so a file that is not ours is replaced, never half read. Core code:
//! no I/O.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Label = enum {
    certificate,
    private_key,

    fn begin(label: Label) []const u8 {
        return switch (label) {
            .certificate => "-----BEGIN CERTIFICATE-----\n",
            .private_key => "-----BEGIN PRIVATE KEY-----\n",
        };
    }

    fn end(label: Label) []const u8 {
        return switch (label) {
            .certificate => "-----END CERTIFICATE-----\n",
            .private_key => "-----END PRIVATE KEY-----\n",
        };
    }
};

const line_bytes = 64;
const base64_bytes_max = (constants.x509_cert_bytes_max + 2) / 3 * 4;

/// The longest PEM text: the base64 of `x509_cert_bytes_max` bytes with a newline per line, and
/// the lines around it, plus one byte, so that a reader bounded by it can say "too long".
pub const bytes_max = Label.certificate.begin().len + Label.certificate.end().len +
    base64_bytes_max + constants.x509_cert_bytes_max / 45 + 2;

comptime {
    assert(Label.private_key.begin().len <= Label.certificate.begin().len);
    assert(Label.private_key.end().len <= Label.certificate.end().len);
}

/// The PKCS#8 prefix of an Ed25519 private key (RFC 8410 section 7); the 32-byte seed follows.
const pkcs8_prefix = [_]u8{
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
};
pub const pkcs8_bytes = pkcs8_prefix.len + 32;

/// `bytes` as one PEM block of `label`.
pub fn encode(out: *[bytes_max]u8, label: Label, bytes: []const u8) []const u8 {
    assert(bytes.len > 0);
    assert(bytes.len <= constants.x509_cert_bytes_max);
    var base64: [base64_bytes_max]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&base64, bytes);
    var writer: std.Io.Writer = .fixed(out);
    writer.writeAll(label.begin()) catch unreachable; // `bytes_max` holds it.
    var at: usize = 0;
    while (at < encoded.len) : (at += line_bytes) {
        const line = encoded[at..@min(at + line_bytes, encoded.len)];
        writer.print("{s}\n", .{line}) catch unreachable; // Sized by `bytes_max`.
    }
    writer.writeAll(label.end()) catch unreachable; // Sized by `bytes_max`.
    return writer.buffered();
}

/// The bytes inside a PEM block of `label` exactly as `encode` writes it, or null: any other
/// text (extra blocks, other line lengths, trailing bytes) is not ours.
pub fn decode(
    text: []const u8,
    label: Label,
    out: *[constants.x509_cert_bytes_max]u8,
) ?[]const u8 {
    if (text.len >= bytes_max) return null;
    if (!std.mem.startsWith(u8, text, label.begin())) return null;
    if (!std.mem.endsWith(u8, text, label.end())) return null;
    if (text.len < label.begin().len + label.end().len) return null;
    const body = text[label.begin().len .. text.len - label.end().len];
    var base64: [base64_bytes_max]u8 = undefined;
    var length: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > line_bytes) return null;
        if (length + line.len > base64.len) return null;
        @memcpy(base64[length..][0..line.len], line);
        length += line.len;
    }
    const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(base64[0..length]) catch
        return null;
    if (decoded_length == 0) return null;
    if (decoded_length > out.len) return null;
    std.base64.standard.Decoder.decode(out, base64[0..length]) catch return null;
    var again: [bytes_max]u8 = undefined;
    if (!std.mem.eql(u8, encode(&again, label, out[0..decoded_length]), text)) return null;
    return out[0..decoded_length];
}

/// An Ed25519 seed as a PKCS#8 PRIVATE KEY block, the form `openssl` and the JDK read.
pub fn encode_key(out: *[bytes_max]u8, seed: *const [32]u8) []const u8 {
    var der: [pkcs8_bytes]u8 = pkcs8_prefix ++ @as([32]u8, @splat(0));
    defer std.crypto.secureZero(u8, &der);
    @memcpy(der[pkcs8_prefix.len..], seed);
    return encode(out, .private_key, &der);
}

/// The seed of a PRIVATE KEY block `encode_key` wrote, or null.
pub fn decode_key(text: []const u8, seed: *[32]u8) bool {
    var der: [constants.x509_cert_bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &der);
    const bytes = decode(text, .private_key, &der) orelse return false;
    if (bytes.len != pkcs8_bytes) return false;
    if (!std.mem.eql(u8, bytes[0..pkcs8_prefix.len], &pkcs8_prefix)) return false;
    @memcpy(seed, bytes[pkcs8_prefix.len..]);
    return true;
}

test "PEM text round trips only in the exact form written" {
    // Goal: `decode` accepts what `encode` writes and nothing looser. Method: encode lengths
    // around a line boundary, decode, then damage the text five ways.
    var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    var source: [constants.x509_cert_bytes_max]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var text: [bytes_max]u8 = undefined;
    for ([_]usize{ 1, 47, 48, 49, 200, constants.x509_cert_bytes_max }) |length| {
        const pem = encode(&text, .certificate, source[0..length]);
        const back = decode(pem, .certificate, &der_buffer).?;
        try std.testing.expectEqualSlices(u8, source[0..length], back);
        try std.testing.expect(decode(pem, .private_key, &der_buffer) == null);
    }
    const pem = encode(&text, .certificate, source[0..100]);
    try std.testing.expect(decode(pem[0 .. pem.len - 1], .certificate, &der_buffer) == null);
    try std.testing.expect(decode(pem[1..], .certificate, &der_buffer) == null);
    var other: [bytes_max]u8 = undefined;
    @memcpy(other[0..pem.len], pem);
    other[Label.certificate.begin().len + 3] = '!';
    try std.testing.expect(decode(other[0..pem.len], .certificate, &der_buffer) == null);
    try std.testing.expect(decode("", .certificate, &der_buffer) == null);
}

test "an Ed25519 key round trips as PKCS#8 and nothing else reads as one" {
    // Goal: the key file holds the RFC 8410 form and only that. Method: encode a seed and check
    // the DER prefix; decode it back; a certificate block and a longer key are refused.
    const seed: [32]u8 = @splat(0x42);
    var text: [bytes_max]u8 = undefined;
    const written = encode_key(&text, &seed);
    try std.testing.expect(std.mem.startsWith(u8, written, "-----BEGIN PRIVATE KEY-----\nMC4C"));
    var back: [32]u8 = undefined;
    try std.testing.expect(decode_key(written, &back));
    try std.testing.expectEqualSlices(u8, &seed, &back);
    var other: [bytes_max]u8 = undefined;
    const certificate = encode(&other, .certificate, &(pkcs8_prefix ++ seed));
    try std.testing.expect(!decode_key(certificate, &back));
    const longer = encode(&other, .private_key, &(pkcs8_prefix ++ seed ++ [_]u8{0}));
    try std.testing.expect(!decode_key(longer, &back));
}
