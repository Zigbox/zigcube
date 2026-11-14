//! A PKCS#12 file (RFC 7292) holding one browser client certificate and its P-256 key, for
//! `zcube-server ca issue-client --p12` (B7 slice 6,
//! docs/decisions/2026-11-14-b7-slice6-console-over-tls.md): what a browser imports.
//!
//! The layout is what OpenSSL 3 writes by default, minus the encryption of the certificate bag,
//! which protects nothing secret:
//!
//! - the AuthenticatedSafe holds two `data` ContentInfos: a SafeContents with the certBag, and
//!   one with the pkcs8ShroudedKeyBag; both bags carry the same localKeyId (the first 20 bytes
//!   of SHA-256 of the certificate), which is how an importer pairs them;
//! - the key is a PKCS#8 PrivateKeyInfo (ecPublicKey, prime256v1, with the public key) under
//!   PBES2: PBKDF2-HMAC-SHA256 with a 16-byte salt, and AES-256-CBC;
//! - the MAC is HMAC-SHA256, its key from the PKCS#12 KDF (Appendix B, ID 3) over the password
//!   as a BMPString, with a 16-byte salt and the same iteration count.
//!
//! Pure: the salts and the IV are the caller's (random in the command, fixed in tests), so the
//! bytes are a function of the input and a golden pins them.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const der = @import("x509_der.zig");
const p256 = @import("x509_p256.zig");

const Allocator = std.mem.Allocator;
const Aes256 = std.crypto.core.aes.Aes256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The certificate and the key fit with room to spare.
pub const bytes_max = constants.x509_cert_bytes_max + 1024;
/// PBKDF2 and the MAC's KDF: OWASP's count for PBKDF2-HMAC-SHA256. The MAC's KDF takes the same
/// count, or the MAC would be the cheaper way to test a guessed password.
pub const iterations_default: u32 = 600_000;

/// `NoSpace` and `Malformed` come from the DER writer and mean a bug (the sizes are fixed).
pub const Error = der.Error || error{ BadPassword, OutOfMemory };

pub const Input = struct {
    certificate: []const u8,
    key: p256.KeyPair,
    /// UTF-8, not empty.
    password: []const u8,
    iterations: u32 = iterations_default,
    mac_salt: [16]u8,
    key_salt: [16]u8,
    iv: [16]u8,
};

const oid = struct {
    const data = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01 };
    const bag_prefix = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01 };
    const shrouded_key_bag = bag_prefix ++ [_]u8{0x02};
    const cert_bag = bag_prefix ++ [_]u8{0x03};
    const x509_certificate = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01 };
    const local_key_id = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15 };
    const pbes2 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D };
    const pbkdf2 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C };
    const hmac_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09 };
    const aes256_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A };
    const sha256 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
    const ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
    const prime256v1 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
};

const tag_null: u8 = 0x05;
const tag_context_0: u8 = 0xA0;
const tag_context_1: u8 = 0xA1;

/// The PKCS#12 file in `out`. `gpa` holds the password's BMPString while the MAC key is made.
pub fn write(out: *[bytes_max]u8, gpa: Allocator, input: *const Input) Error![]const u8 {
    assert(input.iterations > 0);
    if (input.password.len == 0) return error.BadPassword;
    if (!std.unicode.utf8ValidateSlice(input.password)) return error.BadPassword;
    var key_id: [20]u8 = undefined;
    var digest: [32]u8 = undefined;
    Sha256.hash(input.certificate, &digest, .{});
    key_id = digest[0..20].*;

    var safe_buffer: [bytes_max]u8 = undefined;
    var safe = der.Writer.init(&safe_buffer);
    const safe_end = safe.mark();
    var key_bag_buffer: [1024]u8 = undefined;
    const key_bag = try shrouded_key_contents(&key_bag_buffer, input, &key_id);
    try content_info_data(&safe, key_bag);
    var cert_bag_buffer: [bytes_max]u8 = undefined;
    const cert_bag = try cert_bag_contents(&cert_bag_buffer, input.certificate, &key_id);
    try content_info_data(&safe, cert_bag);
    try safe.close(der.tag_sequence, safe_end);
    const authenticated_safe = safe.written();

    var mac_key = try mac_key_of(gpa, input.password, &input.mac_salt, input.iterations);
    defer std.crypto.secureZero(u8, &mac_key);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, authenticated_safe, &mac_key);

    var writer = der.Writer.init(out);
    const end = writer.mark();
    // MacData ::= SEQUENCE { DigestInfo, macSalt, iterations }
    const mac_end = writer.mark();
    try writer.unsigned(input.iterations);
    try writer.element(der.tag_octet_string, &input.mac_salt);
    const digest_end = writer.mark();
    try writer.element(der.tag_octet_string, &mac);
    try algorithm(&writer, &oid.sha256, true);
    try writer.close(der.tag_sequence, digest_end);
    try writer.close(der.tag_sequence, mac_end);
    try content_info_data(&writer, authenticated_safe);
    try writer.unsigned(3);
    try writer.close(der.tag_sequence, end);
    return writer.written();
}

/// ContentInfo ::= SEQUENCE { contentType data, [0] EXPLICIT OCTET STRING content }
fn content_info_data(writer: *der.Writer, content: []const u8) Error!void {
    const end = writer.mark();
    const explicit = writer.mark();
    try writer.element(der.tag_octet_string, content);
    try writer.close(tag_context_0, explicit);
    try writer.element(der.tag_oid, &oid.data);
    try writer.close(der.tag_sequence, end);
}

/// AlgorithmIdentifier with an absent or a NULL parameter.
fn algorithm(writer: *der.Writer, identifier: []const u8, null_parameter: bool) Error!void {
    const end = writer.mark();
    if (null_parameter) try writer.element(tag_null, "");
    try writer.element(der.tag_oid, identifier);
    try writer.close(der.tag_sequence, end);
}

/// SET OF Attribute with the one localKeyId.
fn bag_attributes(writer: *der.Writer, key_id: *const [20]u8) Error!void {
    const set_end = writer.mark();
    const attribute_end = writer.mark();
    const values_end = writer.mark();
    try writer.element(der.tag_octet_string, key_id);
    try writer.close(der.tag_set, values_end);
    try writer.element(der.tag_oid, &oid.local_key_id);
    try writer.close(der.tag_sequence, attribute_end);
    try writer.close(der.tag_set, set_end);
}

/// SafeContents with one certBag.
fn cert_bag_contents(
    buffer: []u8,
    certificate: []const u8,
    key_id: *const [20]u8,
) Error![]const u8 {
    var writer = der.Writer.init(buffer);
    const contents_end = writer.mark();
    const bag_end = writer.mark();
    try bag_attributes(&writer, key_id);
    const value_end = writer.mark();
    const cert_bag_end = writer.mark();
    const explicit = writer.mark();
    try writer.element(der.tag_octet_string, certificate);
    try writer.close(tag_context_0, explicit);
    try writer.element(der.tag_oid, &oid.x509_certificate);
    try writer.close(der.tag_sequence, cert_bag_end);
    try writer.close(tag_context_0, value_end);
    try writer.element(der.tag_oid, &oid.cert_bag);
    try writer.close(der.tag_sequence, bag_end);
    try writer.close(der.tag_sequence, contents_end);
    return writer.written();
}

/// SafeContents with one pkcs8ShroudedKeyBag.
fn shrouded_key_contents(
    buffer: []u8,
    input: *const Input,
    key_id: *const [20]u8,
) Error![]const u8 {
    var plain_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &plain_buffer);
    const plain = try private_key_info(&plain_buffer, input.key);
    var sealed_buffer: [256 + 16]u8 = undefined;
    const sealed = encrypt(&sealed_buffer, plain, input);

    var writer = der.Writer.init(buffer);
    const contents_end = writer.mark();
    const bag_end = writer.mark();
    try bag_attributes(&writer, key_id);
    const value_end = writer.mark();
    // EncryptedPrivateKeyInfo ::= SEQUENCE { PBES2 AlgorithmIdentifier, OCTET STRING }
    const info_end = writer.mark();
    try writer.element(der.tag_octet_string, sealed);
    try pbes2_algorithm(&writer, input);
    try writer.close(der.tag_sequence, info_end);
    try writer.close(tag_context_0, value_end);
    try writer.element(der.tag_oid, &oid.shrouded_key_bag);
    try writer.close(der.tag_sequence, bag_end);
    try writer.close(der.tag_sequence, contents_end);
    return writer.written();
}

/// PBES2 { PBKDF2 { salt, iterations, prf hmacWithSHA256 }, aes256-CBC { iv } }
fn pbes2_algorithm(writer: *der.Writer, input: *const Input) Error!void {
    const end = writer.mark();
    const parameters_end = writer.mark();
    const scheme_end = writer.mark();
    try writer.element(der.tag_octet_string, &input.iv);
    try writer.element(der.tag_oid, &oid.aes256_cbc);
    try writer.close(der.tag_sequence, scheme_end);
    const kdf_end = writer.mark();
    const kdf_parameters_end = writer.mark();
    try algorithm(writer, &oid.hmac_sha256, true);
    try writer.unsigned(input.iterations);
    try writer.element(der.tag_octet_string, &input.key_salt);
    try writer.close(der.tag_sequence, kdf_parameters_end);
    try writer.element(der.tag_oid, &oid.pbkdf2);
    try writer.close(der.tag_sequence, kdf_end);
    try writer.close(der.tag_sequence, parameters_end);
    try writer.element(der.tag_oid, &oid.pbes2);
    try writer.close(der.tag_sequence, end);
}

/// PrivateKeyInfo { 0, { ecPublicKey, prime256v1 }, ECPrivateKey { 1, d, [1] public key } }
fn private_key_info(buffer: []u8, key: p256.KeyPair) Error![]const u8 {
    var inner_buffer: [160]u8 = undefined;
    defer std.crypto.secureZero(u8, &inner_buffer);
    var inner = der.Writer.init(&inner_buffer);
    const inner_end = inner.mark();
    const public_end = inner.mark();
    const point = key.public_key.toUncompressedSec1();
    try inner.element(der.tag_bit_string, &([1]u8{0} ++ point));
    try inner.close(tag_context_1, public_end);
    var secret = key.secret_key.toBytes();
    defer std.crypto.secureZero(u8, &secret);
    try inner.element(der.tag_octet_string, &secret);
    try inner.unsigned(1);
    try inner.close(der.tag_sequence, inner_end);

    var writer = der.Writer.init(buffer);
    const end = writer.mark();
    try writer.element(der.tag_octet_string, inner.written());
    const algorithm_end = writer.mark();
    try writer.element(der.tag_oid, &oid.prime256v1);
    try writer.element(der.tag_oid, &oid.ec_public_key);
    try writer.close(der.tag_sequence, algorithm_end);
    try writer.unsigned(0);
    try writer.close(der.tag_sequence, end);
    return writer.written();
}

/// AES-256-CBC with PKCS#7 padding, the key from PBKDF2-HMAC-SHA256 over the UTF-8 password.
fn encrypt(out: []u8, plain: []const u8, input: *const Input) []const u8 {
    const padded_length = (plain.len / 16 + 1) * 16;
    assert(out.len >= padded_length);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    const salt = &input.key_salt;
    std.crypto.pwhash.pbkdf2(&key, input.password, salt, input.iterations, HmacSha256) catch
        unreachable; // At least one round, and 32 bytes is one block of output.
    const context = Aes256.initEnc(key);
    var previous = input.iv;
    var block_index: usize = 0;
    while (block_index * 16 < padded_length) : (block_index += 1) {
        var block: [16]u8 = undefined;
        for (&block, 0..) |*byte, offset| {
            const at = block_index * 16 + offset;
            const pad: u8 = @intCast(padded_length - plain.len);
            byte.* = (if (at < plain.len) plain[at] else pad) ^ previous[offset];
        }
        context.encrypt(out[block_index * 16 ..][0..16], &block);
        previous = out[block_index * 16 ..][0..16].*;
        std.crypto.secureZero(u8, &block);
    }
    return out[0..padded_length];
}

/// The MAC key: the PKCS#12 KDF (RFC 7292 Appendix B.2) with ID 3 and SHA-256, over the
/// password as a BMPString (UTF-16 big-endian with a two-byte zero terminator).
fn mac_key_of(
    gpa: Allocator,
    password: []const u8,
    salt: *const [16]u8,
    iterations: u32,
) Error![32]u8 {
    const v = Sha256.block_length;
    const units = std.unicode.utf8ToUtf16LeAlloc(gpa, password) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.BadPassword,
    };
    defer gpa.free(units);
    const bmp_length = units.len * 2 + 2;
    const password_length = v * ((bmp_length + v - 1) / v);
    const salt_length = v * ((salt.len + v - 1) / v);
    const input = try gpa.alloc(u8, salt_length + password_length);
    defer {
        std.crypto.secureZero(u8, input);
        gpa.free(input);
    }
    for (input[0..salt_length], 0..) |*byte, index| byte.* = salt[index % salt.len];
    var bmp = try gpa.alloc(u8, bmp_length);
    defer {
        std.crypto.secureZero(u8, bmp);
        gpa.free(bmp);
    }
    for (units, 0..) |unit, index| std.mem.writeInt(u16, bmp[index * 2 ..][0..2], unit, .big);
    bmp[bmp_length - 2] = 0;
    bmp[bmp_length - 1] = 0;
    for (input[salt_length..], 0..) |*byte, index| byte.* = bmp[index % bmp_length];
    std.crypto.secureZero(u16, units);

    const diversifier: [v]u8 = @splat(3);
    var hash = Sha256.init(.{});
    hash.update(&diversifier);
    hash.update(input);
    var result: [32]u8 = hash.finalResult();
    var round: u32 = 1;
    while (round < iterations) : (round += 1) Sha256.hash(&result, &result, .{});
    return result;
}

const testing = std.testing;
const p256_test = @import("x509_p256_test.zig");

fn sample(out: *[bytes_max]u8, certificate: *p256.Der) ![]const u8 {
    try p256_test.make_client(certificate);
    const input: Input = .{
        .certificate = certificate.slice(),
        .key = try p256_test.key(0xB2),
        .password = "correct horse",
        .iterations = 2048,
        .mac_salt = @splat(0x11),
        .key_salt = @splat(0x22),
        .iv = @splat(0x33),
    };
    return write(out, testing.allocator, &input);
}

test "pkcs12: the file's exact bytes are fixed" {
    // Goal: the layout cannot drift unseen. Method: fixed salts, IV and key; a SHA-256 of the
    // bytes. `openssl pkcs12 -info -passin pass:'correct horse'` read this file (see the
    // decision file): MAC verified, PBES2 with PBKDF2 and AES-256-CBC, the certificate and key
    // paired by localKeyId.
    var out: [bytes_max]u8 = undefined;
    var certificate: p256.Der = .{};
    const bytes = try sample(&out, &certificate);
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    // The bytes on a mismatch, for `xxd -r -p | openssl pkcs12 -info`.
    if (!std.mem.eql(u8, golden, &hex)) std.debug.print("pkcs12 bytes: {x}\n", .{bytes});
    try testing.expectEqualStrings(golden, &hex);
}

test "pkcs12: an empty or non-UTF-8 password is refused" {
    var out: [bytes_max]u8 = undefined;
    var certificate: p256.Der = .{};
    try p256_test.make_client(&certificate);
    var input: Input = .{
        .certificate = certificate.slice(),
        .key = try p256_test.key(0xB2),
        .password = "",
        .iterations = 1,
        .mac_salt = @splat(0),
        .key_salt = @splat(0),
        .iv = @splat(0),
    };
    try testing.expectError(error.BadPassword, write(&out, testing.allocator, &input));
    input.password = "\xff\xfe";
    try testing.expectError(error.BadPassword, write(&out, testing.allocator, &input));
}

const golden = "6b5e64a1443d16b7d94e1f74344f30d287a7e7531a655415c8f75b4f4d60ea52";
