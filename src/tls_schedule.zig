//! TLS 1.3 (RFC 8446) key schedule, transcript hash and record protection for the one suite the
//! mTLS client offers, TLS_AES_128_GCM_SHA256 (docs/briefs/mtls-client.md, slice 3). The
//! handshake state machine (slices 4 and 5) is built on this; nothing here knows what a message
//! means, only how its bytes are hashed, keyed and sealed.
//!
//! Core code: no allocation, no randomness, no clock, no `std.Io`. Every function is a pure
//! function of its arguments and the state it is given, so a fuzzer or a simulation can drive it
//! from a seed. The RFC 8448 trace checks every derived secret, key and IV and the protection of
//! its records (the tests at the end of this file).
//!
//! A secret that has served its purpose is wiped (`std.crypto.secureZero`), and a direction that
//! failed to open a record is dead: RFC 8446 section 5.2 makes that failure fatal, and a dead
//! direction refuses everything after it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

pub const hash_bytes: u32 = Sha256.digest_length;
pub const key_bytes: u32 = Aes128Gcm.key_length;
pub const iv_bytes: u32 = Aes128Gcm.nonce_length;
pub const tag_bytes: u32 = Aes128Gcm.tag_length;

/// Every secret in the schedule is one hash long.
pub const Secret = [hash_bytes]u8;
pub const Hash = [hash_bytes]u8;

comptime {
    assert(hash_bytes == 32);
    assert(key_bytes == 16);
    assert(iv_bytes == 12);
    assert(tag_bytes == 16);
    assert(Hkdf.prk_length == hash_bytes);
}

/// What can refuse a record or a key. Each maps to the alert the client sends (RFC 8446 section
/// 6.2) and to ZC-E0815 for the record faults; slice 4 does the mapping.
pub const Error = error{
    /// A record longer than the protocol allows: `record_overflow`.
    RecordOverflow,
    /// A record too short to hold its inner type and tag: `decode_error`.
    DecodeError,
    /// The tag does not verify: `bad_record_mac`. The direction is dead afterwards.
    BadRecordMac,
    /// An unknown content type, or a record of nothing but padding: `unexpected_message`.
    UnexpectedMessage,
    /// The sender used its records and the next one is not the `KeyUpdate`; or a receiver's
    /// sequence number is about to wrap.
    KeyLimit,
    /// The peer updated its keys more often than `tls_key_updates_per_connection_max`.
    TooManyKeyUpdates,
    /// An earlier record failed; nothing more goes through this direction.
    Dead,
    /// The Diffie-Hellman output is all zero (a low-order public key): `illegal_parameter`.
    ZeroSharedSecret,
};

// ---- HKDF-Expand-Label and Derive-Secret (RFC 8446 section 7.1) -------------------------------

const label_prefix = "tls13 ";
/// The longest label (without the prefix) and context that the one-byte lengths allow.
const label_bytes_max: u32 = 255 - label_prefix.len;
const context_bytes_max: u32 = 255;
pub const hkdf_label_bytes_max: u32 = 2 + 1 + 255 + 1 + context_bytes_max;

/// Writes the `HkdfLabel` structure of RFC 8446 section 7.1 into `buffer` and returns the bytes
/// used: the output length (u16), then the prefixed label and the context, each behind a
/// one-byte length. Public so the tests can show the layout against the RFC's `info` strings.
pub fn hkdf_label(
    buffer: *[hkdf_label_bytes_max]u8,
    label: []const u8,
    context: []const u8,
    length: u16,
) []const u8 {
    assert(label.len <= label_bytes_max);
    assert(context.len <= context_bytes_max);
    assert(length > 0);
    std.mem.writeInt(u16, buffer[0..2], length, .big);
    buffer[2] = @intCast(label_prefix.len + label.len);
    var end: usize = 3;
    @memcpy(buffer[end..][0..label_prefix.len], label_prefix);
    end += label_prefix.len;
    @memcpy(buffer[end..][0..label.len], label);
    end += label.len;
    buffer[end] = @intCast(context.len);
    end += 1;
    @memcpy(buffer[end..][0..context.len], context);
    end += context.len;
    assert(end == 2 + 1 + label_prefix.len + label.len + 1 + context.len);
    return buffer[0..end];
}

/// HKDF-Expand-Label(secret, label, context, length).
pub fn expand_label(
    secret: *const Secret,
    label: []const u8,
    context: []const u8,
    comptime length: u16,
) [length]u8 {
    var buffer: [hkdf_label_bytes_max]u8 = undefined;
    const info = hkdf_label(&buffer, label, context, length);
    var out: [length]u8 = undefined;
    Hkdf.expand(&out, info, secret.*);
    return out;
}

/// Derive-Secret(secret, label, messages) with the transcript hash of `messages` given.
pub fn derive_secret(
    secret: *const Secret,
    label: []const u8,
    transcript_hash: *const Hash,
) Secret {
    return expand_label(secret, label, transcript_hash, hash_bytes);
}

/// The hash of no messages, the context of the "derived" steps.
fn empty_hash() Hash {
    var out: Hash = undefined;
    Sha256.hash("", &out, .{});
    return out;
}

// ---- The transcript ---------------------------------------------------------------------------

/// The running hash of the handshake messages, each in the form it has on the wire, record
/// headers excluded (RFC 8446 section 4.4.1). `hash` can be taken at any point and the transcript
/// goes on, which is what "the hash up to here" means at each step of the handshake.
pub const Transcript = struct {
    state: Sha256,

    pub fn init() Transcript {
        return .{ .state = Sha256.init(.{}) };
    }

    /// Adds one whole handshake message: type, three length bytes and body.
    pub fn add(self: *Transcript, message: []const u8) void {
        assert(message.len >= 4);
        self.state.update(message);
    }

    pub fn hash(self: *const Transcript) Hash {
        return self.state.peek();
    }
};

// ---- The key schedule -------------------------------------------------------------------------

pub const HandshakeSecrets = struct { client: Secret, server: Secret };
pub const ApplicationSecrets = struct { client: Secret, server: Secret };

/// The three stages of RFC 8446 figure 1 without a PSK: early, handshake and master. Each step
/// moves forward and the stage it leaves is gone, so a step called twice or out of order is an
/// assertion, not a quietly wrong key.
pub const Schedule = struct {
    stage: enum { early, handshake, finished },
    secret: Secret,

    /// The early secret: HKDF-Extract(0, 0). No pre-shared key is ever offered.
    pub fn init() Schedule {
        const zero: Secret = @splat(0);
        return .{ .stage = .early, .secret = Hkdf.extract(&zero, &zero) };
    }

    /// Mixes in the x25519 output and returns both handshake traffic secrets. `hello_hash` is
    /// the transcript hash of ClientHello..ServerHello. An all-zero `ecdhe` (std's x25519 refuses
    /// it already) is refused here too, so the schedule cannot be keyed by a low-order point.
    pub fn to_handshake(
        self: *Schedule,
        ecdhe: *const [32]u8,
        hello_hash: *const Hash,
    ) Error!HandshakeSecrets {
        assert(self.stage == .early);
        const zero: [32]u8 = @splat(0);
        if (std.crypto.timing_safe.eql([32]u8, ecdhe.*, zero)) return error.ZeroSharedSecret;
        const empty = empty_hash();
        var derived = derive_secret(&self.secret, "derived", &empty);
        defer std.crypto.secureZero(u8, &derived);
        std.crypto.secureZero(u8, &self.secret);
        self.secret = Hkdf.extract(&derived, ecdhe);
        self.stage = .handshake;
        return .{
            .client = derive_secret(&self.secret, "c hs traffic", hello_hash),
            .server = derive_secret(&self.secret, "s hs traffic", hello_hash),
        };
    }

    /// Moves to the master secret and returns both application traffic secrets. `finished_hash`
    /// is the transcript hash of ClientHello..server Finished (not the client's). The schedule is
    /// finished and wiped: nothing here uses the exporter or resumption secrets.
    pub fn to_application(self: *Schedule, finished_hash: *const Hash) ApplicationSecrets {
        assert(self.stage == .handshake);
        const empty = empty_hash();
        var derived = derive_secret(&self.secret, "derived", &empty);
        defer std.crypto.secureZero(u8, &derived);
        const zero: Secret = @splat(0);
        var master = Hkdf.extract(&derived, &zero);
        defer std.crypto.secureZero(u8, &master);
        std.crypto.secureZero(u8, &self.secret);
        self.stage = .finished;
        return .{
            .client = derive_secret(&master, "c ap traffic", finished_hash),
            .server = derive_secret(&master, "s ap traffic", finished_hash),
        };
    }

    /// Wipes the schedule, for a handshake that ends before the master secret.
    pub fn wipe(self: *Schedule) void {
        std.crypto.secureZero(u8, &self.secret);
        self.stage = .finished;
    }
};

/// The verify_data of a Finished message (RFC 8446 section 4.4.4): an HMAC, under a key derived
/// from the sender's handshake traffic secret, of the transcript hash up to the message before it.
pub fn finished_verify_data(base: *const Secret, transcript_hash: *const Hash) Hash {
    var key = expand_label(base, "finished", "", hash_bytes);
    defer std.crypto.secureZero(u8, &key);
    var out: Hash = undefined;
    Hmac.create(&out, transcript_hash, &key);
    return out;
}

/// Whether a received Finished body is the expected verify_data; the comparison takes the same
/// time wherever the bytes differ.
pub fn finished_matches(
    base: *const Secret,
    transcript_hash: *const Hash,
    received: []const u8,
) bool {
    if (received.len != hash_bytes) return false;
    const expected = finished_verify_data(base, transcript_hash);
    return std.crypto.timing_safe.eql(Hash, expected, received[0..hash_bytes].*);
}

pub const CertificateRole = enum { server, client };

pub const certificate_verify_bytes: u32 = 64 + 33 + 1 + hash_bytes;

/// The bytes a CertificateVerify signs (RFC 8446 section 4.4.3): 64 spaces, the context string
/// of the signer's role, a zero byte and the transcript hash up to the Certificate message.
pub fn certificate_verify_content(
    role: CertificateRole,
    transcript_hash: *const Hash,
) [certificate_verify_bytes]u8 {
    const context = switch (role) {
        .server => "TLS 1.3, server CertificateVerify",
        .client => "TLS 1.3, client CertificateVerify",
    };
    comptime assert(context.len == 33);
    var out: [certificate_verify_bytes]u8 = undefined;
    @memset(out[0..64], 0x20);
    @memcpy(out[64..][0..context.len], context);
    out[64 + context.len] = 0;
    @memcpy(out[64 + context.len + 1 ..][0..hash_bytes], transcript_hash);
    return out;
}

// ---- Traffic keys and key update --------------------------------------------------------------

pub const Keys = struct { key: [key_bytes]u8, iv: [iv_bytes]u8 };

/// [sender]_write_key and [sender]_write_iv of RFC 8446 section 7.3.
pub fn traffic_keys(secret: *const Secret) Keys {
    const keys: Keys = .{
        .key = expand_label(secret, "key", "", key_bytes),
        .iv = expand_label(secret, "iv", "", iv_bytes),
    };
    // A key of nothing but zeros means the expansion did not run (a 2^-128 event otherwise).
    assert(!std.mem.allEqual(u8, &keys.key, 0));
    assert(!std.mem.allEqual(u8, &keys.iv, 0));
    return keys;
}

/// application_traffic_secret_N+1 (RFC 8446 section 7.2).
pub fn next_traffic_secret(secret: *const Secret) Secret {
    return expand_label(secret, "traffic upd", "", hash_bytes);
}

/// The handshake message type of a KeyUpdate, and its whole length: type, length 1, request.
pub const key_update_type: u8 = 24;
pub const key_update_bytes: u32 = 5;

// ---- Records (RFC 8446 section 5) -------------------------------------------------------------

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const Protection = enum { plain, protected };

pub const Header = struct {
    content_type: ContentType,
    /// The legacy version, kept because RFC 8446 section 5.1 says to ignore it: it is not
    /// checked here, and a protected record authenticates the bytes as they arrived.
    legacy_version: u16,
    /// Bytes after the header.
    length: u16,

    /// Reads a record header. A record longer than its kind allows, and a type that is not one
    /// of the four, are refused before any body byte is read.
    pub fn parse(
        bytes: *const [constants.tls_record_header_bytes]u8,
        protection: Protection,
    ) Error!Header {
        const content_type = std.enums.fromInt(ContentType, bytes[0]) orelse
            return error.UnexpectedMessage;
        const length = std.mem.readInt(u16, bytes[3..5], .big);
        const length_max = switch (protection) {
            .plain => constants.tls_record_plaintext_bytes_max,
            .protected => constants.tls_record_ciphertext_bytes_max,
        };
        if (length > length_max) return error.RecordOverflow;
        assert(length <= constants.tls_record_ciphertext_bytes_max);
        return .{
            .content_type = content_type,
            .legacy_version = std.mem.readInt(u16, bytes[1..3], .big),
            .length = length,
        };
    }
};

/// Bytes a sealed record takes for `content_len` bytes of content: header, content, the inner
/// type byte and the tag. No padding is ever added.
pub fn sealed_bytes(content_len: usize) usize {
    assert(content_len <= constants.tls_record_plaintext_bytes_max);
    return constants.tls_record_header_bytes + content_len + 1 + tag_bytes;
}

pub const sealed_bytes_max: usize = constants.tls_record_header_bytes +
    constants.tls_record_ciphertext_bytes_max;

/// Writes an unprotected record (ClientHello, and any record before keys exist) and returns it.
/// `version` is the legacy record version: 0x0301 is allowed for a first ClientHello, otherwise
/// 0x0303.
pub fn write_plain(
    out: []u8,
    content_type: ContentType,
    version: u16,
    content: []const u8,
) []u8 {
    assert(content.len <= constants.tls_record_plaintext_bytes_max);
    const total = constants.tls_record_header_bytes + content.len;
    assert(out.len >= total);
    out[0] = @backingInt(content_type);
    std.mem.writeInt(u16, out[1..3], version, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(content.len), .big);
    @memcpy(out[constants.tls_record_header_bytes..][0..content.len], content);
    return out[0..total];
}

/// A record opened: its inner content type and the content, which lives in the record buffer.
/// The last sequence number a receiver opens; one more would make the counter wrap.
pub const receive_sequence_max: u64 = std.math.maxInt(u64) - 1;

pub const Opened = struct { content_type: ContentType, content: []u8 };

/// One direction of protected traffic: the traffic secret, the keys made from it, the record
/// sequence number and how often the keys changed.
pub const Direction = struct {
    secret: Secret,
    keys: Keys,
    /// The next record's sequence number. It restarts at zero with every key and never wraps:
    /// sealing stops at `tls_records_per_key_max`, and opening refuses the last value
    /// (`receive_sequence_max`) so that the counter cannot overflow.
    sequence: u64,
    updates: u32,
    dead: bool,

    pub fn init(secret: *const Secret) Direction {
        return .{
            .secret = secret.*,
            .keys = traffic_keys(secret),
            .sequence = 0,
            .updates = 0,
            .dead = false,
        };
    }

    pub fn wipe(self: *Direction) void {
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.keys.key);
        std.crypto.secureZero(u8, &self.keys.iv);
        self.dead = true;
    }

    /// True once the keys have sealed `tls_records_per_key_max` records: the next record sent
    /// must be a KeyUpdate. The limit binds the sender only (RFC 8446 section 5.5); a received
    /// direction has none, because a peer updates at its own point or never.
    pub fn update_due(self: *const Direction) bool {
        return self.sequence >= constants.tls_records_per_key_max;
    }

    /// Moves to the next keys: sends of a KeyUpdate call it after sealing the message under the
    /// old keys, receives of one call it after opening it (RFC 8446 section 4.6.3).
    pub fn rekey(self: *Direction) Error!void {
        if (self.dead) return error.Dead;
        if (self.updates >= constants.tls_key_updates_per_connection_max) {
            self.wipe();
            return error.TooManyKeyUpdates;
        }
        var next = next_traffic_secret(&self.secret);
        defer std.crypto.secureZero(u8, &next);
        self.wipe();
        self.secret = next;
        self.keys = traffic_keys(&self.secret);
        self.sequence = 0;
        self.updates += 1;
        self.dead = false;
        assert(self.updates <= constants.tls_key_updates_per_connection_max);
    }

    /// Protects `content` as one record into `out` and returns the record. `out` must be at
    /// least `sealed_bytes(content.len)` and must not overlap `content`. Past the limit only a
    /// KeyUpdate may be sealed.
    pub fn seal(
        self: *Direction,
        out: []u8,
        content_type: ContentType,
        content: []const u8,
    ) Error![]u8 {
        if (self.dead) return error.Dead;
        assert(content.len <= constants.tls_record_plaintext_bytes_max);
        const total = sealed_bytes(content.len);
        assert(out.len >= total);
        try self.check_limit(content_type, content);
        assert(self.sequence < constants.tls_records_per_key_max +
            constants.tls_records_per_key_slack);

        const inner_len = content.len + 1;
        const body_len: u16 = @intCast(inner_len + tag_bytes);
        const header = out[0..constants.tls_record_header_bytes];
        header[0] = @backingInt(ContentType.application_data);
        std.mem.writeInt(u16, header[1..3], 0x0303, .big);
        std.mem.writeInt(u16, header[3..5], body_len, .big);
        const inner = out[constants.tls_record_header_bytes..][0..inner_len];
        @memcpy(inner[0..content.len], content);
        inner[content.len] = @backingInt(content_type);
        const tag = out[constants.tls_record_header_bytes + inner_len ..][0..tag_bytes];
        Aes128Gcm.encrypt(inner, tag, inner, header, self.nonce(), self.keys.key);
        self.sequence += 1;
        assert(inner_len <= constants.tls_record_ciphertext_bytes_max - tag_bytes);
        assert(out[0] == @backingInt(ContentType.application_data));
        return out[0..total];
    }

    /// Opens `record`, a whole record (header and body) as `Header.parse` framed it, in place:
    /// the content is left in the buffer and returned. A failure leaves the direction dead.
    ///
    /// The caller must drop, before calling, a plaintext change_cipher_spec record (type 0x14,
    /// body one byte 0x01) received during the handshake: RFC 8446 appendix D.4 has servers
    /// send one for middlebox compatibility (OpenSSL does, right after ServerHello). It is
    /// neither protected nor counted, and `open` would take it for a fault and kill the
    /// direction. Slice 4 does that dropping in its record reader.
    pub fn open(self: *Direction, record: []u8) Error!Opened {
        if (self.dead) return error.Dead;
        assert(record.len >= constants.tls_record_header_bytes);
        const opened = self.open_checked(record) catch |err| {
            self.wipe();
            return err;
        };
        assert(self.sequence < receive_sequence_max);
        self.sequence += 1;
        return opened;
    }

    fn open_checked(self: *Direction, record: []u8) Error!Opened {
        const header = try Header.parse(record[0..constants.tls_record_header_bytes], .protected);
        assert(record.len == constants.tls_record_header_bytes + header.length);
        // No per-key limit on received records: it binds the sender (RFC 8446 section 5.5). Only
        // a counter that would wrap is refused.
        if (self.sequence >= receive_sequence_max) return error.KeyLimit;
        return self.open_body(record, header);
    }

    fn open_body(self: *Direction, record: []u8, header: Header) Error!Opened {
        if (header.content_type != .application_data) return error.UnexpectedMessage;
        if (header.length < 1 + tag_bytes) return error.DecodeError;
        assert(header.length <= constants.tls_record_ciphertext_bytes_max);
        assert(record.len == constants.tls_record_header_bytes + header.length);
        const inner_len = header.length - tag_bytes;
        const body = record[constants.tls_record_header_bytes..];
        const tag = body[inner_len..][0..tag_bytes].*;
        Aes128Gcm.decrypt(
            body[0..inner_len],
            body[0..inner_len],
            tag,
            record[0..constants.tls_record_header_bytes],
            self.nonce(),
            self.keys.key,
        ) catch return error.BadRecordMac;
        // The inner type is the last non-zero byte; zeros after it are padding.
        var end: usize = inner_len;
        while (end > 0) : (end -= 1) {
            if (body[end - 1] != 0) break;
        }
        if (end == 0) return error.UnexpectedMessage;
        const content_type = std.enums.fromInt(ContentType, body[end - 1]) orelse
            return error.UnexpectedMessage;
        const content_len = end - 1;
        // RFC 8446 sections 5.1 and 5.4: handshake and alert records are never empty.
        if (content_len == 0 and content_type != .application_data) return error.UnexpectedMessage;
        if (content_len > constants.tls_record_plaintext_bytes_max) return error.RecordOverflow;
        assert(content_len < inner_len);
        return .{ .content_type = content_type, .content = body[0..content_len] };
    }

    /// The record about to be sealed is number `sequence`. At and past the limit the one record
    /// allowed is the KeyUpdate (type, length 00 00 01, request 0 or 1); nothing after that.
    fn check_limit(
        self: *const Direction,
        content_type: ContentType,
        content: []const u8,
    ) Error!void {
        const limit = constants.tls_records_per_key_max;
        if (self.sequence < limit) return;
        if (self.sequence >= limit + constants.tls_records_per_key_slack) return error.KeyLimit;
        comptime assert(key_update_bytes == 5);
        if (content_type != .handshake) return error.KeyLimit;
        if (content.len != key_update_bytes) return error.KeyLimit;
        if (content[0] != key_update_type) return error.KeyLimit;
        if (!std.mem.eql(u8, content[1..4], &.{ 0, 0, 1 })) return error.KeyLimit;
        if (content[4] > 1) return error.KeyLimit;
    }

    /// The per-record nonce: the IV with the sequence number, big-endian in its last eight
    /// bytes, XORed in (RFC 8446 section 5.3).
    pub fn nonce(self: *const Direction) [iv_bytes]u8 {
        var out = self.keys.iv;
        const iv_head: [4]u8 = out[0..4].*;
        var sequence_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &sequence_bytes, self.sequence, .big);
        for (sequence_bytes, 0..) |byte, index| out[iv_bytes - 8 + index] ^= byte;
        assert(std.mem.eql(u8, out[0..4], &iv_head)); // the first four IV bytes are never touched
        return out;
    }
};
