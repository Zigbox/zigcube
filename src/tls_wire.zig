//! TLS 1.3 wire formats for the client (docs/briefs/mtls-client.md, slice 4): a bounded reader,
//! the one ClientHello the client ever sends, and parsers for the server's messages. Nothing here
//! keeps state or touches a key; `tls_client.zig` decides what a refusal means.
//!
//! Core code: no allocation, no clock, no randomness. A parser returns slices into the bytes it
//! was given and never reads past them: every read is checked against the bytes left.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// Why a message was refused. `tls_client.zig` maps each to an alert and a diagnostic.
pub const Error = error{
    /// Cut short, longer than its length says, or a length that does not add up: `decode_error`.
    Malformed,
    /// A value the protocol does not allow in this place: `illegal_parameter`.
    IllegalParameter,
    /// An extension this client never offered: `unsupported_extension`.
    UnexpectedExtension,
    /// An extension twice in one message: `illegal_parameter`.
    DuplicateExtension,
    /// An extension the message needs and lacks: `missing_extension`.
    MissingExtension,
    /// A `Certificate` with no certificate in it, or more than the pinned shape allows.
    ChainShape,
    // Things this client never offers (ZC-E0818).
    HelloRetryRequest,
    /// TLS 1.2 or older, or the downgrade sentinel in the server's random.
    ProtocolVersion,
    CipherSuite,
    Group,
    SignatureScheme,
};

// ---- Constants of the protocol ----------------------------------------------------------------

pub const handshake_client_hello: u8 = 1;
pub const handshake_server_hello: u8 = 2;
pub const handshake_new_session_ticket: u8 = 4;
pub const handshake_encrypted_extensions: u8 = 8;
pub const handshake_certificate: u8 = 11;
pub const handshake_certificate_request: u8 = 13;
pub const handshake_certificate_verify: u8 = 15;
pub const handshake_finished: u8 = 20;
pub const handshake_key_update: u8 = 24;

/// TLS_AES_128_GCM_SHA256, the only suite offered.
pub const suite_aes_128_gcm_sha256: u16 = 0x1301;
/// x25519, the only group offered.
pub const group_x25519: u16 = 0x001d;
/// ed25519, the only signature scheme offered.
pub const scheme_ed25519: u16 = 0x0807;
pub const version_tls13: u16 = 0x0304;
pub const version_tls12: u16 = 0x0303;

const ext_server_name: u16 = 0;
const ext_supported_groups: u16 = 10;
const ext_signature_algorithms: u16 = 13;
const ext_supported_versions: u16 = 43;
const ext_key_share: u16 = 51;
const ext_signature_algorithms_cert: u16 = 50;

/// The random that marks a HelloRetryRequest (RFC 8446 section 4.1.3): SHA-256 of
/// "HelloRetryRequest".
const hello_retry_random = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};
/// The last eight bytes of a server's random when it negotiates TLS 1.2 (or 1.1) while it can
/// speak TLS 1.3 (RFC 8446 section 4.1.3): a downgrade the client must refuse.
const downgrade_tls12 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x01 };
const downgrade_tls11 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x00 };

// ---- Alerts (RFC 8446 section 6) --------------------------------------------------------------

pub const alert_level_fatal: u8 = 2;

pub const Alert = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    record_overflow = 22,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    missing_extension = 109,
    unsupported_extension = 110,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    unknown_psk_identity = 115,
    certificate_required = 116,
    no_application_protocol = 120,
};

/// The name of an alert a peer sent; a code outside the registry is named as unknown, never
/// guessed.
pub fn alert_name(code: u8) []const u8 {
    const known = std.enums.fromInt(Alert, code) orelse return "unknown_alert";
    return @tagName(known);
}

// ---- A bounded reader -------------------------------------------------------------------------

pub const Reader = struct {
    bytes: []const u8,
    position: u32,

    pub fn init(bytes: []const u8) Reader {
        assert(bytes.len <= std.math.maxInt(u32));
        return .{ .bytes = bytes, .position = 0 };
    }

    pub fn remaining(reader: *const Reader) u32 {
        assert(reader.position <= reader.bytes.len);
        return @intCast(reader.bytes.len - reader.position);
    }

    pub fn take(reader: *Reader, count: u32) Error![]const u8 {
        if (count > reader.remaining()) return error.Malformed;
        const taken = reader.bytes[reader.position..][0..count];
        reader.position += count;
        assert(reader.position <= reader.bytes.len);
        return taken;
    }

    pub fn read_u8(reader: *Reader) Error!u8 {
        return (try reader.take(1))[0];
    }

    pub fn read_u16(reader: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try reader.take(2))[0..2], .big);
    }

    pub fn read_u24(reader: *Reader) Error!u32 {
        return std.mem.readInt(u24, (try reader.take(3))[0..3], .big);
    }

    /// A vector behind a one-byte length.
    pub fn vector8(reader: *Reader) Error![]const u8 {
        return reader.take(try reader.read_u8());
    }

    /// A vector behind a two-byte length.
    pub fn vector16(reader: *Reader) Error![]const u8 {
        return reader.take(try reader.read_u16());
    }

    /// A vector behind a three-byte length.
    pub fn vector24(reader: *Reader) Error![]const u8 {
        return reader.take(try reader.read_u24());
    }

    /// The end of a message: nothing may follow what the grammar ends with.
    pub fn finish(reader: *const Reader) Error!void {
        if (reader.remaining() != 0) return error.Malformed;
    }
};

// ---- A bounded writer -------------------------------------------------------------------------

const Writer = struct {
    buffer: []u8,
    length: u32,

    fn put_u8(writer: *Writer, value: u8) void {
        assert(writer.length < writer.buffer.len);
        writer.buffer[writer.length] = value;
        writer.length += 1;
    }

    fn put_u16(writer: *Writer, value: u16) void {
        writer.put_u8(@intCast(value >> 8));
        writer.put_u8(@truncate(value));
    }

    fn put_bytes(writer: *Writer, bytes: []const u8) void {
        assert(bytes.len <= writer.buffer.len - writer.length);
        @memcpy(writer.buffer[writer.length..][0..bytes.len], bytes);
        writer.length += @intCast(bytes.len);
    }

    /// Reserves a two-byte length and returns where it is, for `close16`.
    fn open16(writer: *Writer) u32 {
        const at = writer.length;
        writer.put_u16(0);
        return at;
    }

    /// Fills the length reserved at `at` with the bytes written since.
    fn close16(writer: *Writer, at: u32) void {
        const length = writer.length - at - 2;
        assert(length <= std.math.maxInt(u16));
        std.mem.writeInt(u16, writer.buffer[at..][0..2], @intCast(length), .big);
    }
};

// ---- The ClientHello --------------------------------------------------------------------------

pub const hello_session_id_bytes: u32 = 32;

pub const HelloInput = struct {
    random: [32]u8,
    /// Echoed by the server; a random value in compatibility mode (RFC 8446 appendix D.4).
    session_id: [hello_session_id_bytes]u8,
    /// The x25519 public key of the ephemeral secret.
    public_key: [32]u8,
    /// The DNS name for `server_name`; empty sends no such extension.
    server_name: []const u8,
};

/// Writes the ClientHello handshake message (type, length and body, no record header) into `out`
/// and returns it. The layout is fixed: one suite, one group, one signature scheme, TLS 1.3
/// only, no PSK, no early data, no cookie. Only the server name varies in length.
pub fn write_client_hello(out: []u8, input: *const HelloInput) []const u8 {
    assert(input.server_name.len <= constants.tls_server_name_bytes_max);
    assert(out.len >= constants.tls_client_hello_bytes_max);
    var writer: Writer = .{ .buffer = out, .length = 0 };
    writer.put_u8(handshake_client_hello);
    writer.put_bytes(&.{ 0, 0, 0 }); // The length, filled below.
    writer.put_u16(version_tls12); // legacy_version
    writer.put_bytes(&input.random);
    writer.put_u8(hello_session_id_bytes);
    writer.put_bytes(&input.session_id);
    writer.put_u16(2);
    writer.put_u16(suite_aes_128_gcm_sha256);
    writer.put_bytes(&.{ 1, 0 }); // legacy_compression_methods: null only
    const extensions = writer.open16();
    write_name_extension(&writer, input.server_name);
    write_extension(&writer, ext_supported_groups, &.{ 0, 2, 0x00, 0x1d });
    write_extension(&writer, ext_signature_algorithms, &.{ 0, 2, 0x08, 0x07 });
    write_extension(&writer, ext_signature_algorithms_cert, &.{ 0, 2, 0x08, 0x07 });
    write_extension(&writer, ext_supported_versions, &.{ 2, 0x03, 0x04 });
    writer.put_u16(ext_key_share);
    writer.put_u16(2 + 2 + 2 + 32);
    writer.put_u16(2 + 2 + 32); // client_shares
    writer.put_u16(group_x25519);
    writer.put_u16(32);
    writer.put_bytes(&input.public_key);
    writer.close16(extensions);
    const body_length = writer.length - 4;
    std.mem.writeInt(u24, writer.buffer[1..4], @intCast(body_length), .big);
    assert(
        writer.length <= constants.tls_client_hello_bytes_max - constants.tls_record_header_bytes,
    );
    assert(out[0] == handshake_client_hello);
    return out[0..writer.length];
}

fn write_extension(writer: *Writer, kind: u16, data: []const u8) void {
    writer.put_u16(kind);
    writer.put_u16(@intCast(data.len));
    writer.put_bytes(data);
}

fn write_name_extension(writer: *Writer, name: []const u8) void {
    if (name.len == 0) return;
    writer.put_u16(ext_server_name);
    writer.put_u16(@intCast(2 + 1 + 2 + name.len));
    writer.put_u16(@intCast(1 + 2 + name.len)); // server_name_list
    writer.put_u8(0); // host_name
    writer.put_u16(@intCast(name.len));
    writer.put_bytes(name);
}

// ---- The ServerHello --------------------------------------------------------------------------

pub const ServerHello = struct {
    /// The server's x25519 public key.
    public_key: [32]u8,
};

/// Reads a ServerHello body (after the four-byte handshake header). Everything this client
/// never offers is named: a HelloRetryRequest, TLS 1.2 or a downgrade, another suite or group.
/// The order of the checks puts "the server speaks another protocol" before "a field is wrong",
/// so a TLS 1.2 server is told apart from a broken TLS 1.3 one.
pub fn parse_server_hello(body: []const u8, session_id: *const [32]u8) Error!ServerHello {
    var reader = Reader.init(body);
    const legacy_version = try reader.read_u16();
    const random = (try reader.take(32))[0..32];
    const echoed = try reader.vector8();
    const suite = try reader.read_u16();
    const compression = try reader.read_u8();
    var extensions = Reader.init(try reader.vector16());
    try reader.finish();

    var parsed: HelloExtensions = .{};
    try read_hello_extensions(&extensions, &parsed);

    if (std.mem.eql(u8, random, &hello_retry_random)) return error.HelloRetryRequest;
    const tail = random[24..32];
    if (std.mem.eql(u8, tail, &downgrade_tls12)) return error.ProtocolVersion;
    if (std.mem.eql(u8, tail, &downgrade_tls11)) return error.ProtocolVersion;
    if (legacy_version != version_tls12) return error.ProtocolVersion;
    if (parsed.version != version_tls13) return error.ProtocolVersion;
    if (suite != suite_aes_128_gcm_sha256) return error.CipherSuite;
    if (parsed.unexpected) return error.UnexpectedExtension;
    if (!std.mem.eql(u8, echoed, session_id)) return error.IllegalParameter;
    if (compression != 0) return error.IllegalParameter;
    if (parsed.group == null) return error.MissingExtension;
    if (parsed.group.? != group_x25519) return error.Group;
    const key = parsed.key orelse return error.MissingExtension;
    assert(key.len == 32);
    return .{ .public_key = key[0..32].* };
}

const HelloExtensions = struct {
    /// supported_versions: the one version the server chose; null if the extension is absent,
    /// which in a ServerHello is the mark of TLS 1.2.
    version: ?u16 = null,
    group: ?u16 = null,
    key: ?[]const u8 = null,
    /// Some extension that is not in a ServerHello of this client's conversation. Held, not
    /// raised at once, so that a TLS 1.2 server with its own extensions is called what it is.
    unexpected: bool = false,
};

fn read_hello_extensions(reader: *Reader, parsed: *HelloExtensions) Error!void {
    var seen: [std.math.maxInt(u8) + 1]bool = @splat(false);
    var count: u32 = 0;
    while (reader.remaining() > 0) {
        const kind = try reader.read_u16();
        const data = try reader.vector16();
        count += 1;
        assert(count <= constants.tls_handshake_message_bytes_max); // Each takes four bytes.
        // Extension types of interest are small; a repeated type of any size is a repeat.
        const slot: u8 = @truncate(kind ^ (kind >> 8));
        if (seen[slot]) {
            if (known_hello_extension(kind)) return error.DuplicateExtension;
        }
        seen[slot] = true;
        switch (kind) {
            ext_supported_versions => {
                if (data.len != 2) return error.Malformed;
                if (parsed.version != null) return error.DuplicateExtension;
                parsed.version = std.mem.readInt(u16, data[0..2], .big);
            },
            ext_key_share => try read_server_key_share(data, parsed),
            else => parsed.unexpected = true,
        }
    }
}

fn known_hello_extension(kind: u16) bool {
    return kind == ext_supported_versions or kind == ext_key_share;
}

fn read_server_key_share(data: []const u8, parsed: *HelloExtensions) Error!void {
    if (parsed.group != null) return error.DuplicateExtension;
    var reader = Reader.init(data);
    parsed.group = try reader.read_u16();
    const key = try reader.vector16();
    try reader.finish();
    if (parsed.group.? == group_x25519) {
        if (key.len != 32) return error.IllegalParameter;
        parsed.key = key;
    }
}

// ---- The other server messages ----------------------------------------------------------------

/// EncryptedExtensions (RFC 8446 section 4.3.1): the extensions of the handshake the server
/// may send without being asked, which are only the two this client can have provoked:
/// an empty `server_name` acknowledging its own, and `supported_groups`.
pub fn parse_encrypted_extensions(body: []const u8) Error!void {
    var reader = Reader.init(body);
    var extensions = Reader.init(try reader.vector16());
    try reader.finish();
    var seen_name = false;
    var seen_groups = false;
    while (extensions.remaining() > 0) {
        const kind = try extensions.read_u16();
        const data = try extensions.vector16();
        switch (kind) {
            ext_server_name => {
                if (seen_name) return error.DuplicateExtension;
                seen_name = true;
                if (data.len != 0) return error.IllegalParameter;
            },
            ext_supported_groups => {
                if (seen_groups) return error.DuplicateExtension;
                seen_groups = true;
                var groups = Reader.init(data);
                const list = try groups.vector16();
                try groups.finish();
                if (list.len == 0) return error.Malformed;
                if (list.len % 2 != 0) return error.Malformed;
            },
            else => return error.UnexpectedExtension,
        }
    }
}

pub const Chain = struct {
    /// The server's certificate, in DER, inside the message.
    leaf: []const u8,
    /// One or two certificates were sent; the second is never read.
    count: u32,
};

/// Certificate (RFC 8446 section 4.4.2) from a server: an empty request context, then one or two
/// certificates, each without extensions (none was asked for).
pub fn parse_certificate(body: []const u8) Error!Chain {
    var reader = Reader.init(body);
    const context = try reader.vector8();
    if (context.len != 0) return error.IllegalParameter;
    var list = Reader.init(try reader.vector24());
    try reader.finish();
    var count: u32 = 0;
    var leaf: []const u8 = "";
    while (list.remaining() > 0) {
        const certificate = try list.vector24();
        const extensions = try list.vector16();
        if (extensions.len != 0) return error.IllegalParameter;
        count += 1;
        if (count > constants.tls_chain_certificates_max) return error.ChainShape;
        if (count == 1) leaf = certificate;
    }
    if (count == 0) return error.ChainShape;
    if (leaf.len == 0) return error.Malformed;
    return .{ .leaf = leaf, .count = count };
}

/// CertificateVerify (RFC 8446 section 4.4.3): the scheme, which must be the one offered, and a
/// 64-byte Ed25519 signature.
pub fn parse_certificate_verify(body: []const u8) Error!*const [64]u8 {
    var reader = Reader.init(body);
    const scheme = try reader.read_u16();
    const signature = try reader.vector16();
    try reader.finish();
    if (scheme != scheme_ed25519) return error.SignatureScheme;
    if (signature.len != 64) return error.Malformed;
    return signature[0..64];
}

/// KeyUpdate (RFC 8446 section 4.6.3): one byte, `update_not_requested` (0) or
/// `update_requested` (1). Returns whether the peer asked for an update in return.
pub fn parse_key_update(body: []const u8) Error!bool {
    if (body.len != 1) return error.Malformed;
    if (body[0] > 1) return error.IllegalParameter;
    return body[0] == 1;
}
