//! Sealed store records (C5, docs/briefs/c5.md "Sealing and the key's lifecycle"). Core: no
//! files, no randomness, no clock; the shell (`server_seal.zig`) holds the key and draws nonces.
//!
//! A sealed value is one printable envelope, `zcseal1.<key id>.<base64url(nonce, ciphertext,
//! tag)>`: XChaCha20-Poly1305 with a random 24-byte nonce, the associated data being the
//! envelope's header and the store key path. So a record cannot be moved to another path, nor
//! relabelled with another key id, without failing to open. A record can still be replaced by an
//! older sealed version of the same path; only a store writer can do that, and store writers are
//! trusted (accepted, not defended).
//!
//! The key id is the first 8 bytes of SHA-256 over a domain tag and the key, in hex: enough to
//! tell which key a record expects (ZC-E0824 names it) and nothing about the key itself.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.url_safe_no_pad;

pub const key_bytes = Aead.key_length;
pub const nonce_bytes = Aead.nonce_length;
pub const tag_bytes = Aead.tag_length;
pub const key_id_bytes: u32 = 16;

/// The envelope's first bytes; a new format gets a new number and this one stays readable.
pub const magic = "zcseal1.";
pub const header_bytes: u32 = magic.len + key_id_bytes + 1;

/// The prefixes whose records hold an envelope (docs/keys.md): what the start-up check opens.
pub const sealed_prefixes = [_][]const u8{ "/edge-certs/", "/acme-account/" };

/// What `--discard-sealed` deletes: the sealed records, and the orders that were made for them
/// with an account that goes too.
pub const discarded_prefixes = sealed_prefixes ++ [_][]const u8{"/acme-orders/"};

/// The envelope for a plaintext of `plain_bytes`.
pub fn envelope_bytes(plain_bytes: u32) u32 {
    assert(plain_bytes <= constants.seal_plaintext_bytes_max);
    const raw = nonce_bytes + plain_bytes + tag_bytes;
    const encoded: u32 = @intCast(base64.Encoder.calcSize(raw));
    return header_bytes + encoded;
}

pub const envelope_bytes_max = envelope_bytes_comptime(constants.seal_plaintext_bytes_max);

fn envelope_bytes_comptime(comptime plain_bytes: u32) u32 {
    const encoded = std.base64.url_safe_no_pad.Encoder.calcSize(
        nonce_bytes + plain_bytes + tag_bytes,
    );
    return header_bytes + @as(u32, @intCast(encoded));
}

comptime {
    assert(envelope_bytes_max > header_bytes);
    assert(envelope_bytes_max <= constants.store_value_bytes_max);
}

pub const KeyId = [key_id_bytes]u8;

pub const Key = struct {
    bytes: [key_bytes]u8,

    /// The key's id: printable, the same for the same key, and no help in guessing it.
    pub fn id(key: *const Key) KeyId {
        var digest: [Sha256.digest_length]u8 = undefined;
        var hash = Sha256.init(.{});
        hash.update("zcube seal key id\x00");
        hash.update(&key.bytes);
        hash.final(&digest);
        var out: KeyId = undefined;
        const hex = std.fmt.bytesToHex(digest[0..@divExact(key_id_bytes, 2)].*, .lower);
        @memcpy(&out, &hex);
        assert(is_key_id(&out));
        return out;
    }

    pub fn wipe(key: *Key) void {
        std.crypto.secureZero(u8, &key.bytes);
    }
};

pub const OpenError = error{
    /// Not an envelope of this format: no magic, a bad key id, bad base64 or too short.
    Malformed,
    /// Sealed with another key (the ids differ).
    WrongKey,
    /// The ids agree but the tag does not: the record was altered, moved to this path, or
    /// sealed with another key whose id collides.
    Forged,
};

/// Seals `plaintext` for the record at `path` into `out` (at least `envelope_bytes` long) and
/// returns the envelope. `nonce` must be fresh from a secure random source.
pub fn seal(
    key: *const Key,
    path: []const u8,
    plaintext: []const u8,
    nonce: [nonce_bytes]u8,
    out: []u8,
) []const u8 {
    assert(path.len > 0);
    assert(path[0] == '/');
    assert(plaintext.len <= constants.seal_plaintext_bytes_max);
    const length = envelope_bytes(@intCast(plaintext.len));
    assert(out.len >= length);
    const key_id = key.id();
    @memcpy(out[0..magic.len], magic);
    @memcpy(out[magic.len..][0..key_id_bytes], &key_id);
    out[header_bytes - 1] = '.';

    var raw: [nonce_bytes + constants.seal_plaintext_bytes_max + tag_bytes]u8 = undefined;
    const sealed = raw[0 .. nonce_bytes + plaintext.len + tag_bytes];
    @memcpy(sealed[0..nonce_bytes], &nonce);
    const ciphertext = sealed[nonce_bytes..][0..plaintext.len];
    const tag = sealed[nonce_bytes + plaintext.len ..][0..tag_bytes];
    var ad: AssociatedData = .{};
    Aead.encrypt(ciphertext, tag, plaintext, ad.of(out[0..header_bytes], path), nonce, key.bytes);
    const encoded = base64.Encoder.encode(out[header_bytes..length], sealed);
    assert(encoded.len == length - header_bytes);
    assert(key_id_of(out[0..length]) != null);
    return out[0..length];
}

/// Opens `envelope`, read from the record at `path`, into `out` and returns the plaintext. The
/// caller wipes `out` when done with it.
pub fn open(
    key: *const Key,
    path: []const u8,
    envelope: []const u8,
    out: []u8,
) OpenError![]u8 {
    assert(path.len > 0);
    assert(out.len >= constants.seal_plaintext_bytes_max);
    const expected = key_id_of(envelope) orelse return error.Malformed;
    const own = key.id();
    if (!std.mem.eql(u8, &expected, &own)) return error.WrongKey;
    const body = envelope[header_bytes..];
    const raw_bytes = base64.Decoder.calcSizeForSlice(body) catch return error.Malformed;
    if (raw_bytes < nonce_bytes + tag_bytes) return error.Malformed;
    if (raw_bytes > nonce_bytes + constants.seal_plaintext_bytes_max + tag_bytes) {
        return error.Malformed;
    }
    var raw: [nonce_bytes + constants.seal_plaintext_bytes_max + tag_bytes]u8 = undefined;
    base64.Decoder.decode(raw[0..raw_bytes], body) catch return error.Malformed;
    const plain_bytes = raw_bytes - nonce_bytes - tag_bytes;
    const nonce = raw[0..nonce_bytes].*;
    const ciphertext = raw[nonce_bytes..][0..plain_bytes];
    const tag = raw[nonce_bytes + plain_bytes ..][0..tag_bytes].*;
    var ad: AssociatedData = .{};
    const plaintext = out[0..plain_bytes];
    const associated = ad.of(envelope[0..header_bytes], path);
    Aead.decrypt(plaintext, ciphertext, tag, associated, nonce, key.bytes) catch {
        std.crypto.secureZero(u8, plaintext);
        return error.Forged;
    };
    assert(plaintext.len == plain_bytes);
    return plaintext;
}

/// The key id an envelope names, or null if `envelope` is not exactly one envelope.
pub fn key_id_of(envelope: []const u8) ?KeyId {
    if (envelope.len <= header_bytes) return null;
    if (!std.mem.startsWith(u8, envelope, magic)) return null;
    if (envelope[header_bytes - 1] != '.') return null;
    const id = envelope[magic.len..][0..key_id_bytes];
    if (!is_key_id(id)) return null;
    for (envelope[header_bytes..]) |byte| {
        if (!is_base64url(byte)) return null;
    }
    return id.*;
}

/// The envelope inside a record's value (a JSON string member, in later slices), or null if the
/// value holds none. It ends at the first byte that cannot be part of one. A value that holds
/// the magic but is cut short gives what follows it, which `open` refuses as `Malformed`: a
/// damaged envelope is never mistaken for a record with nothing sealed.
pub fn find(value: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, magic) orelse return null;
    var end = start + header_bytes;
    if (end > value.len) return value[start..];
    while (end < value.len) : (end += 1) {
        if (!is_base64url(value[end])) break;
    }
    const envelope = value[start..end];
    assert(std.mem.startsWith(u8, envelope, magic));
    return envelope;
}

pub fn is_key_id(text: []const u8) bool {
    if (text.len != key_id_bytes) return false;
    for (text) |byte| {
        const digit = byte >= '0' and byte <= '9';
        const letter = byte >= 'a' and byte <= 'f';
        if (!digit and !letter) return false;
    }
    return true;
}

fn is_base64url(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

/// The associated data: the envelope's header, a zero byte, then the store key path.
const AssociatedData = struct {
    bytes: [header_bytes + 1 + constants.store_key_bytes_max]u8 = undefined,

    fn of(ad: *AssociatedData, header: []const u8, path: []const u8) []const u8 {
        assert(header.len == header_bytes);
        assert(path.len <= constants.store_key_bytes_max);
        @memcpy(ad.bytes[0..header_bytes], header);
        ad.bytes[header_bytes] = 0;
        @memcpy(ad.bytes[header_bytes + 1 ..][0..path.len], path);
        return ad.bytes[0 .. header_bytes + 1 + path.len];
    }
};

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

fn test_key(byte: u8) Key {
    return .{ .bytes = @splat(byte) };
}

test "a sealed record opens at its own path with its own key, and round-trips every length" {
    // Goal: the round trip of the brief's tests. Method: seal plaintexts from empty to the bound
    // at one path, check the envelope's shape and length, open each and compare.
    const key = test_key(0x11);
    var plain: [constants.seal_plaintext_bytes_max]u8 = undefined;
    for (&plain, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 3);
    var out: [envelope_bytes_max]u8 = undefined;
    var opened: [constants.seal_plaintext_bytes_max]u8 = @splat(0xee);
    const lengths = [_]u32{ 0, 1, 2, 3, 32, 121, constants.seal_plaintext_bytes_max };
    for (lengths) |length| {
        const nonce: [nonce_bytes]u8 = @splat(@truncate(length));
        const envelope = seal(&key, "/edge-certs/a.example", plain[0..length], nonce, &out);
        try testing.expectEqual(envelope_bytes(length), @as(u32, @intCast(envelope.len)));
        try testing.expectEqualSlices(u8, &key.id(), &key_id_of(envelope).?);
        try testing.expectEqualStrings(envelope, find(envelope).?);
        const back = try open(&key, "/edge-certs/a.example", envelope, &opened);
        try testing.expectEqualSlices(u8, plain[0..length], back);
    }
}

test "a moved record, a tampered byte, a relabelled key id and another key are refused" {
    // Goal: the brief's "a moved record refused" and "a tampered byte refused". Method: seal at
    // one path; open at another (Forged); flip each byte of the envelope in turn (never opens);
    // put another key's id in the header (Forged: the id is bound); open with another key.
    const key = test_key(0x22);
    const plain = "the leaf key";
    var out: [envelope_bytes_max]u8 = undefined;
    const nonce: [nonce_bytes]u8 = @splat(5);
    const envelope = seal(&key, "/edge-certs/a.example", plain, nonce, &out);
    var opened: [constants.seal_plaintext_bytes_max]u8 = undefined;
    try testing.expectError(error.Forged, open(&key, "/edge-certs/b.example", envelope, &opened));
    try testing.expectError(error.Forged, open(&key, "/acme-account/a", envelope, &opened));

    var copy: [envelope_bytes_max]u8 = undefined;
    for (0..envelope.len) |index| {
        @memcpy(copy[0..envelope.len], envelope);
        copy[index] = if (copy[index] == 'A') 'B' else 'A';
        const result = open(&key, "/edge-certs/a.example", copy[0..envelope.len], &opened);
        if (result) |_| return error.TamperedRecordOpened else |_| {}
    }

    const other = test_key(0x33);
    const path = "/edge-certs/a.example";
    try testing.expectError(error.WrongKey, open(&other, path, envelope, &opened));
    @memcpy(copy[0..envelope.len], envelope);
    @memcpy(copy[magic.len..][0..key_id_bytes], &other.id());
    const relabelled = copy[0..envelope.len];
    try testing.expectError(error.Forged, open(&other, path, relabelled, &opened));
}

test "envelopes are found inside a record's value, and junk is not one" {
    // Goal: the start-up check's parser. Method: an envelope inside JSON is found whole; values
    // without one, or with a damaged header, are refused by `find` or `key_id_of`.
    const key = test_key(0x44);
    var out: [envelope_bytes_max]u8 = undefined;
    const envelope = seal(&key, "/acme-account/0123", "account", @splat(9), &out);
    var value_buffer: [envelope_bytes_max + 64]u8 = undefined;
    const value = try std.fmt.bufPrint(&value_buffer, "{{\"key\":\"{s}\",\"x\":1}}", .{envelope});
    try testing.expectEqualStrings(envelope, find(value).?);
    try testing.expect(find("{\"key\":\"plain\"}") == null);
    try testing.expectEqualStrings("zcseal1.0123", find("zcseal1.0123").?);
    try testing.expect(key_id_of(find("zcseal1.0123").?) == null);
    try testing.expect(key_id_of("zcseal1.0123456789ABCDEF.AAAA") == null);
    try testing.expect(key_id_of("zcseal1.0123456789abcdef-AAAA") == null);
    try testing.expect(key_id_of("zcseal1.0123456789abcdef.") == null);
    try testing.expect(key_id_of("zcseal1.0123456789abcdef.AA=A") == null);
    try testing.expect(key_id_of("zcseal1.0123456789abcdef.AAAA") != null);
    var opened: [constants.seal_plaintext_bytes_max]u8 = undefined;
    var short_buffer: [header_bytes + 4]u8 = undefined;
    const short = try std.fmt.bufPrint(&short_buffer, "{s}{s}.AAAA", .{ magic, &key.id() });
    try testing.expectError(error.Malformed, open(&key, "/edge-certs/x", short, &opened));
}

test "key ids differ between keys and do not contain the key" {
    // Goal: E0824 may print an id without exposing the key. Method: two keys, two ids; the id is
    // not the key's leading hex.
    const a = test_key(0x01);
    const b = test_key(0x02);
    try testing.expect(!std.mem.eql(u8, &a.id(), &b.id()));
    const hex = std.fmt.bytesToHex(a.bytes, .lower);
    try testing.expect(std.mem.indexOf(u8, &hex, &a.id()) == null);
}
