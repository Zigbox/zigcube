//! Peer identity and the handshake (docs/peer.md, C2 slice 6a). Core code: bytes in, bytes out,
//! no socket, no file, no clock value (the wall time is an argument) and no randomness source
//! (ephemeral seeds are arguments). The shell runs it over a stream (`peer_stream.zig`, slice 6b).
//!
//! **Interim.** A small SIGMA-style exchange built from std's X25519, Ed25519, SHA-256 / HKDF and
//! ChaCha20-Poly1305, because the pinned std has a TLS client only. Real mTLS replaces it; the
//! release documentation says so. Integrity of image data never rests on it (BLAKE3 does).
//!
//! The flow is in docs/peer.md. In short: M1 carries the client's ephemeral key; M2 the server's
//! ephemeral key and, sealed, its credential and a signature over the transcript; M3 the client's
//! sealed credential and signature. Each side checks the other's credential against the cluster
//! CA before it says anything more. Every failure is a typed `Error` and ends the handshake; the
//! caller closes the stream and raises the diagnostic with `raise`.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// Why a peer was refused. `code_of` maps each to its `ZC-E08xx`.
pub const Error = error{
    /// The credential's key id is not the CA this node holds.
    UnknownCa,
    /// The credential's signature does not verify under the CA key.
    BadSignature,
    Expired,
    NotYetValid,
    /// The server's credential names another node than the one asked for.
    WrongNode,
    /// A malformed, cut, altered or unauthenticated handshake message, or a weak key.
    HandshakeFailed,
    /// A record failed authentication, was too long, or the session already failed.
    RecordRejected,
    /// A direction reached `peer_record_counter_max`.
    RecordExhausted,
};

pub const version: u8 = 1;
const label = "zcube-peer-v1";

// ---- The credential --------------------------------------------------------------------------

pub const name_bytes_max = constants.node_name_bytes_max;
pub const credential_body_bytes = 1 + 8 + 1 + name_bytes_max + 32 + 8 + 8;
pub const credential_bytes = credential_body_bytes + Ed25519.Signature.encoded_length;
const credential_domain = "zcube-peer-cred-v1\x00";

comptime {
    assert(credential_body_bytes == 121);
    assert(credential_bytes == 185);
}

pub const Credential = struct {
    ca_key_id: [8]u8,
    name_buffer: [name_bytes_max]u8,
    name_length: u8,
    node_key: [32]u8,
    not_before_ms: u64,
    not_after_ms: u64,
    signature: [64]u8,

    pub fn name(credential: *const Credential) []const u8 {
        return credential.name_buffer[0..credential.name_length];
    }
};

/// The first 8 bytes of SHA-256 of the CA's public key.
pub fn ca_key_id(ca_public: [32]u8) [8]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&ca_public, &digest, .{});
    return digest[0..8].*;
}

fn body_of(credential: *const Credential) [credential_body_bytes]u8 {
    var out: [credential_body_bytes]u8 = @splat(0);
    out[0] = version;
    out[1..9].* = credential.ca_key_id;
    out[9] = credential.name_length;
    out[10 .. 10 + name_bytes_max].* = credential.name_buffer;
    out[73..105].* = credential.node_key;
    std.mem.writeInt(u64, out[105..113], credential.not_before_ms, .little);
    std.mem.writeInt(u64, out[113..121], credential.not_after_ms, .little);
    return out;
}

const signed_bytes = credential_domain.len + credential_body_bytes;

fn signed_message(body: *const [credential_body_bytes]u8) [signed_bytes]u8 {
    var message: [signed_bytes]u8 = undefined;
    @memcpy(message[0..credential_domain.len], credential_domain);
    @memcpy(message[credential_domain.len..], body);
    return message;
}

/// Signs a credential binding `node_key` to `node` for `[not_before_ms, not_after_ms)`. The
/// caller has validated the name and the window (assertions here): the issuer is our own code.
pub fn issue(
    ca: Ed25519.KeyPair,
    node: []const u8,
    node_key: [32]u8,
    not_before_ms: u64,
    not_after_ms: u64,
) Credential {
    assert(records.name_problem(node, name_bytes_max) == null);
    assert(not_after_ms > not_before_ms);
    assert(not_after_ms - not_before_ms <= constants.peer_credential_ttl_ms_max);
    var credential: Credential = .{
        .ca_key_id = ca_key_id(ca.public_key.toBytes()),
        .name_buffer = @splat(0),
        .name_length = @intCast(node.len),
        .node_key = node_key,
        .not_before_ms = not_before_ms,
        .not_after_ms = not_after_ms,
        .signature = @splat(0),
    };
    @memcpy(credential.name_buffer[0..node.len], node);
    const message = signed_message(&body_of(&credential));
    // A key pair from `generateDeterministic` or `generate` always signs; only a hand-built one
    // with a mismatched public half fails, and nothing here builds one.
    const signature = ca.sign(&message, null) catch unreachable;
    credential.signature = signature.toBytes();
    return credential;
}

pub fn encode(credential: *const Credential) [credential_bytes]u8 {
    var out: [credential_bytes]u8 = undefined;
    out[0..credential_body_bytes].* = body_of(credential);
    out[credential_body_bytes..].* = credential.signature;
    assert(out[0] == version);
    return out;
}

/// Decodes the canonical form only: the version, a valid node name with zero padding, a window
/// that is positive and at most `peer_credential_ttl_ms_max`. The signature is not checked here.
pub fn decode(bytes: *const [credential_bytes]u8) Error!Credential {
    if (bytes[0] != version) return error.HandshakeFailed;
    const length = bytes[9];
    if (length == 0) return error.HandshakeFailed;
    if (length > name_bytes_max) return error.HandshakeFailed;
    const name_field = bytes[10 .. 10 + name_bytes_max];
    for (name_field[length..]) |byte| {
        if (byte != 0) return error.HandshakeFailed;
    }
    if (records.name_problem(name_field[0..length], name_bytes_max) != null) {
        return error.HandshakeFailed;
    }
    const not_before_ms = std.mem.readInt(u64, bytes[105..113], .little);
    const not_after_ms = std.mem.readInt(u64, bytes[113..121], .little);
    if (not_after_ms <= not_before_ms) return error.HandshakeFailed;
    if (not_after_ms - not_before_ms > constants.peer_credential_ttl_ms_max) {
        return error.HandshakeFailed;
    }
    const credential: Credential = .{
        .ca_key_id = bytes[1..9].*,
        .name_buffer = name_field.*,
        .name_length = length,
        .node_key = bytes[73..105].*,
        .not_before_ms = not_before_ms,
        .not_after_ms = not_after_ms,
        .signature = bytes[credential_body_bytes..][0..64].*,
    };
    assert(credential.name().len == length);
    return credential;
}

/// The test-only fault of the teeth test: skip the credential signature check. A test build
/// (`builtin.is_test`) can switch it on with `set_test_fault`; in every other build the setter does
/// nothing and the condition in `verify` is comptime false. It is not a public declaration
/// because the core's reference walk (`core.reference_all`) cannot take a variable at comptime.
var fault_skip_signature: bool = false;

pub fn set_test_fault(on: bool) void {
    if (builtin.is_test) fault_skip_signature = on;
}

/// Checks a decoded credential against the CA this node holds, at wall time `now_ms`, and (when
/// `expected_node` is given) that it names that node. The order is the order of docs/peer.md.
pub fn verify(
    credential: *const Credential,
    ca_public: [32]u8,
    now_ms: u64,
    expected_node: ?[]const u8,
) Error!void {
    if (!std.mem.eql(u8, &credential.ca_key_id, &ca_key_id(ca_public))) return error.UnknownCa;
    const skip = builtin.is_test and fault_skip_signature;
    if (!skip) {
        const public = Ed25519.PublicKey.fromBytes(ca_public) catch return error.UnknownCa;
        const message = signed_message(&body_of(credential));
        const signature = Ed25519.Signature.fromBytes(credential.signature);
        signature.verify(&message, public) catch return error.BadSignature;
    }
    const skew = constants.peer_clock_skew_ms;
    if (credential.not_before_ms > now_ms +| skew) return error.NotYetValid;
    if (now_ms >= credential.not_after_ms +| skew) return error.Expired;
    if (expected_node) |node| {
        if (!std.mem.eql(u8, credential.name(), node)) return error.WrongNode;
    }
}

// ---- Keys ------------------------------------------------------------------------------------

/// What a node is, to its peers: its signing key, its credential, and the CA it trusts.
pub const Identity = struct {
    key: Ed25519.KeyPair,
    credential: Credential,
    ca_public: [32]u8,
};

fn hash_pair(first: []const u8, second: []const u8) [32]u8 {
    var state = Sha256.init(.{});
    state.update(first);
    state.update(second);
    return state.finalResult();
}

const HandshakeKeys = struct { server: [32]u8, client: [32]u8 };

fn handshake_keys(shared: [32]u8, h2: [32]u8) HandshakeKeys {
    const prk = Hkdf.extract(&h2, &shared);
    var keys: HandshakeKeys = undefined;
    Hkdf.expand(&keys.server, label ++ " hs server", prk);
    Hkdf.expand(&keys.client, label ++ " hs client", prk);
    return keys;
}

fn transport_keys(shared: [32]u8, h4: [32]u8) HandshakeKeys {
    const prk = Hkdf.extract(&h4, &shared);
    var keys: HandshakeKeys = undefined;
    Hkdf.expand(&keys.client, label ++ " c2s", prk); // Client to server.
    Hkdf.expand(&keys.server, label ++ " s2c", prk); // Server to client.
    return keys;
}

fn nonce_of(counter: u64) [Aead.nonce_length]u8 {
    var nonce: [Aead.nonce_length]u8 = @splat(0);
    std.mem.writeInt(u64, nonce[4..12], counter, .little);
    return nonce;
}

// ---- The messages ----------------------------------------------------------------------------

pub const m1_bytes = 2 + X25519.public_length;
const proof_bytes = credential_bytes + Ed25519.Signature.encoded_length;
const sealed_proof_bytes = proof_bytes + Aead.tag_length;
pub const m2_bytes = 2 + X25519.public_length + sealed_proof_bytes;
pub const m3_bytes = 2 + sealed_proof_bytes;

const type_m1: u8 = 1;
const type_m2: u8 = 2;
const type_m3: u8 = 3;

comptime {
    assert(m1_bytes == 34);
    assert(m2_bytes == 299);
    assert(m3_bytes == 267);
}

fn header_ok(message: []const u8, wanted: u8) bool {
    assert(message.len >= 2);
    return message[0] == version and message[1] == wanted;
}

/// What a side signs: a hash of the label, its role, the transcript and its credential bytes.
fn proof_message(role: []const u8, transcript: *const [32]u8, credential: []const u8) [32]u8 {
    assert(role.len == 6);
    assert(credential.len == credential_bytes);
    var digest: [32]u8 = undefined;
    var state = Sha256.init(.{});
    state.update(label);
    state.update(" ");
    state.update(role);
    state.update(transcript);
    state.update(credential);
    state.final(&digest);
    return digest;
}

/// The sealed credential and transcript signature one side sends.
fn make_proof(
    identity: *const Identity,
    role: []const u8,
    transcript: *const [32]u8,
    key: [32]u8,
) [sealed_proof_bytes]u8 {
    const credential = encode(&identity.credential);
    const message = proof_message(role, transcript, &credential);
    // As in `issue`: a key pair made by this module's callers always signs.
    const signature = identity.key.sign(&message, null) catch unreachable;
    var plain: [proof_bytes]u8 = undefined;
    plain[0..credential_bytes].* = credential;
    plain[credential_bytes..].* = signature.toBytes();
    var sealed: [sealed_proof_bytes]u8 = undefined;
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(sealed[0..proof_bytes], &tag, &plain, transcript, nonce_of(0), key);
    sealed[proof_bytes..].* = tag;
    return sealed;
}

/// Opens a peer's proof and checks the credential (against the CA and, for a server, the node
/// asked for) and the transcript signature. Returns the credential.
fn check_proof(
    identity: *const Identity,
    role: []const u8,
    transcript: *const [32]u8,
    key: [32]u8,
    sealed: *const [sealed_proof_bytes]u8,
    options: struct { now_ms: u64, expected_node: ?[]const u8 },
) Error!Credential {
    var plain: [proof_bytes]u8 = undefined;
    const tag = sealed[proof_bytes..][0..Aead.tag_length].*;
    Aead.decrypt(&plain, sealed[0..proof_bytes], tag, transcript, nonce_of(0), key) catch
        return error.HandshakeFailed;
    const credential = try decode(plain[0..credential_bytes]);
    try verify(&credential, identity.ca_public, options.now_ms, options.expected_node);
    const message = proof_message(role, transcript, plain[0..credential_bytes]);
    const public = Ed25519.PublicKey.fromBytes(credential.node_key) catch
        return error.HandshakeFailed;
    const signature = Ed25519.Signature.fromBytes(plain[credential_bytes..][0..64].*);
    signature.verify(&message, public) catch return error.HandshakeFailed;
    return credential;
}

// ---- The two ends ----------------------------------------------------------------------------

pub const Initiator = struct {
    identity: *const Identity,
    expected_node: []const u8,
    now_ms: u64,
    ephemeral: X25519.KeyPair,
    h1: [32]u8 = @splat(0),
    stage: enum { new, sent_m1, done } = .new,

    pub fn init(
        identity: *const Identity,
        expected_node: []const u8,
        ephemeral_seed: [32]u8,
        now_ms: u64,
    ) Initiator {
        assert(records.name_problem(expected_node, name_bytes_max) == null);
        return .{
            .identity = identity,
            .expected_node = expected_node,
            .now_ms = now_ms,
            .ephemeral = X25519.KeyPair.generateDeterministic(ephemeral_seed),
        };
    }

    pub fn first(initiator: *Initiator) [m1_bytes]u8 {
        assert(initiator.stage == .new);
        var m1: [m1_bytes]u8 = undefined;
        m1[0] = version;
        m1[1] = type_m1;
        m1[2..].* = initiator.ephemeral.public_key;
        initiator.h1 = hash_pair(label, &m1);
        initiator.stage = .sent_m1;
        return m1;
    }

    pub const Done = struct { m3: [m3_bytes]u8, session: Session };

    /// Reads M2, checks the server (CA, window, name, signature) and answers with M3.
    pub fn second(initiator: *Initiator, m2: *const [m2_bytes]u8) Error!Done {
        assert(initiator.stage == .sent_m1);
        initiator.stage = .done;
        if (!header_ok(m2, type_m2)) return error.HandshakeFailed;
        const server_public = m2[2..][0..32].*;
        const shared = X25519.scalarmult(initiator.ephemeral.secret_key, server_public) catch
            return error.HandshakeFailed;
        const h2 = hash_pair(&initiator.h1, &server_public);
        const keys = handshake_keys(shared, h2);
        const sealed = m2[2 + 32 ..][0..sealed_proof_bytes];
        const server = try check_proof(initiator.identity, "server", &h2, keys.server, sealed, .{
            .now_ms = initiator.now_ms,
            .expected_node = initiator.expected_node,
        });
        const h3 = hash_pair(&h2, m2[2 + 32 ..]);
        var m3: [m3_bytes]u8 = undefined;
        m3[0] = version;
        m3[1] = type_m3;
        m3[2..].* = make_proof(initiator.identity, "client", &h3, keys.client);
        const h4 = hash_pair(&h3, m3[2..]);
        const transport = transport_keys(shared, h4);
        return .{
            .m3 = m3,
            .session = Session.init(transport.client, transport.server, server),
        };
    }
};

pub const Responder = struct {
    identity: *const Identity,
    now_ms: u64,
    ephemeral: X25519.KeyPair,
    shared: [32]u8 = @splat(0),
    keys: HandshakeKeys = undefined,
    h3: [32]u8 = @splat(0),
    stage: enum { new, sent_m2, done } = .new,

    pub fn init(identity: *const Identity, ephemeral_seed: [32]u8, now_ms: u64) Responder {
        return .{
            .identity = identity,
            .now_ms = now_ms,
            .ephemeral = X25519.KeyPair.generateDeterministic(ephemeral_seed),
        };
    }

    /// Reads M1 (any 32 bytes of key are accepted but a weak one) and answers with M2.
    pub fn first(responder: *Responder, m1: *const [m1_bytes]u8) Error![m2_bytes]u8 {
        assert(responder.stage == .new);
        responder.stage = .done; // Until M2 is out; a failure ends it.
        if (!header_ok(m1, type_m1)) return error.HandshakeFailed;
        responder.shared = X25519.scalarmult(responder.ephemeral.secret_key, m1[2..][0..32].*) catch
            return error.HandshakeFailed;
        const h1 = hash_pair(label, m1);
        const h2 = hash_pair(&h1, &responder.ephemeral.public_key);
        responder.keys = handshake_keys(responder.shared, h2);
        var m2: [m2_bytes]u8 = undefined;
        m2[0] = version;
        m2[1] = type_m2;
        m2[2..][0..32].* = responder.ephemeral.public_key;
        m2[2 + 32 ..][0..sealed_proof_bytes].* =
            make_proof(responder.identity, "server", &h2, responder.keys.server);
        responder.h3 = hash_pair(&h2, m2[2 + 32 ..]);
        responder.stage = .sent_m2;
        return m2;
    }

    /// Reads M3, checks the client (CA, window, signature) and opens the session.
    pub fn second(responder: *Responder, m3: *const [m3_bytes]u8) Error!Session {
        assert(responder.stage == .sent_m2);
        responder.stage = .done;
        if (!header_ok(m3, type_m3)) return error.HandshakeFailed;
        const sealed = m3[2..][0..sealed_proof_bytes];
        const client = try check_proof(
            responder.identity,
            "client",
            &responder.h3,
            responder.keys.client,
            sealed,
            .{ .now_ms = responder.now_ms, .expected_node = null },
        );
        const h4 = hash_pair(&responder.h3, m3[2..]);
        const transport = transport_keys(responder.shared, h4);
        std.crypto.secureZero(u8, &responder.shared);
        return Session.init(transport.server, transport.client, client);
    }
};

// ---- Records ---------------------------------------------------------------------------------

pub const record_header_bytes = 2;
pub const record_overhead_bytes = record_header_bytes + Aead.tag_length;
pub const record_bytes_max = constants.peer_record_bytes_max + record_overhead_bytes;

/// An authenticated, encrypted stream in both directions. A failed `open` kills the session:
/// every later call is refused, so a desynchronised stream is never read on.
pub const Session = struct {
    send_key: [32]u8,
    receive_key: [32]u8,
    send_counter: u64 = 0,
    receive_counter: u64 = 0,
    failed: bool = false,
    peer: Credential,

    fn init(send_key: [32]u8, receive_key: [32]u8, peer: Credential) Session {
        return .{ .send_key = send_key, .receive_key = receive_key, .peer = peer };
    }

    /// The authenticated name of the node on the other end.
    pub fn peer_name(session: *const Session) []const u8 {
        return session.peer.name();
    }

    /// Zeroes the keys. The session is unusable afterwards.
    pub fn wipe(session: *Session) void {
        std.crypto.secureZero(u8, &session.send_key);
        std.crypto.secureZero(u8, &session.receive_key);
        session.failed = true;
    }

    /// The ciphertext-plus-tag length a record header announces, or null if it is out of bounds.
    pub fn body_length(header: *const [record_header_bytes]u8) ?u16 {
        const length = std.mem.readInt(u16, header, .big);
        if (length < Aead.tag_length) return null;
        if (length > constants.peer_record_bytes_max + Aead.tag_length) return null;
        return length;
    }

    /// Seals `plaintext` (at most `peer_record_bytes_max`) into `out` as one record and returns
    /// the bytes to send. `out` must hold `plaintext.len + record_overhead_bytes`.
    pub fn seal(session: *Session, plaintext: []const u8, out: []u8) Error![]const u8 {
        assert(plaintext.len <= constants.peer_record_bytes_max);
        assert(out.len >= plaintext.len + record_overhead_bytes);
        if (session.failed) return error.RecordRejected;
        if (session.send_counter >= constants.peer_record_counter_max) {
            return error.RecordExhausted;
        }
        const body: u16 = @intCast(plaintext.len + Aead.tag_length);
        std.mem.writeInt(u16, out[0..2], body, .big);
        var tag: [Aead.tag_length]u8 = undefined;
        const nonce = nonce_of(session.send_counter);
        const cipher = out[2..][0..plaintext.len];
        Aead.encrypt(cipher, &tag, plaintext, out[0..2], nonce, session.send_key);
        out[2 + plaintext.len ..][0..Aead.tag_length].* = tag;
        session.send_counter += 1;
        return out[0 .. plaintext.len + record_overhead_bytes];
    }

    /// Opens one whole record (header, ciphertext, tag) into `out` and returns the plaintext.
    /// Any failure kills the session.
    pub fn open(session: *Session, record: []const u8, out: []u8) Error![]const u8 {
        assert(out.len >= constants.peer_record_bytes_max);
        if (session.failed) return error.RecordRejected;
        if (session.receive_counter >= constants.peer_record_counter_max) {
            return error.RecordExhausted;
        }
        session.failed = true; // Until it opens.
        if (record.len < record_overhead_bytes) return error.RecordRejected;
        const announced = body_length(record[0..2]) orelse return error.RecordRejected;
        if (record.len != record_header_bytes + announced) return error.RecordRejected;
        const plain_length = announced - Aead.tag_length;
        const tag = record[record.len - Aead.tag_length ..][0..Aead.tag_length].*;
        const nonce = nonce_of(session.receive_counter);
        const cipher = record[2..][0..plain_length];
        const header = record[0..2];
        Aead.decrypt(out[0..plain_length], cipher, tag, header, nonce, session.receive_key) catch
            return error.RecordRejected;
        session.receive_counter += 1;
        session.failed = false;
        return out[0..plain_length];
    }
};

// ---- Diagnostics -----------------------------------------------------------------------------

/// The registered code a refusal is reported as.
pub fn code_of(err: Error) @import("diag/codes.zig").Code {
    return switch (err) {
        error.UnknownCa, error.BadSignature => .E0801,
        error.Expired, error.NotYetValid => .E0802,
        error.WrongNode => .E0803,
        error.HandshakeFailed => .E0804,
        error.RecordRejected, error.RecordExhausted => .E0805,
    };
}

/// Raises the diagnostic for a refusal: one line, what was refused and why, and a fix. `peer` is
/// the node name or address the caller was talking to, for the cause.
pub fn raise(diag: *Diag, err: Error, peer: []const u8) void {
    diag.raise(code_of(err));
    switch (err) {
        error.UnknownCa => diag.cause("{s}'s credential is from another CA", .{peer}),
        error.BadSignature => diag.cause("{s}'s credential signature does not verify", .{peer}),
        error.Expired => diag.cause("{s}'s credential has expired", .{peer}),
        error.NotYetValid => diag.cause("{s}'s credential is not valid yet", .{peer}),
        error.WrongNode => diag.cause("{s} answered with another node's credential", .{peer}),
        error.HandshakeFailed => diag.cause("the handshake with {s} did not complete", .{peer}),
        error.RecordRejected => diag.cause("a record from {s} failed authentication", .{peer}),
        error.RecordExhausted => diag.cause("the connection to {s} hit its record limit", .{peer}),
    }
    switch (err) {
        error.Expired, error.NotYetValid => diag.fix(.{
            .sentence = "check the clocks, then restart the agent so it renews",
            .command = "timedatectl",
        }),
        error.RecordExhausted => diag.fix(.{ .sentence = "reconnect; counters restart" }),
        else => diag.fix(.{
            .sentence = "check that both agents joined this cluster (docs/peer.md)",
            .command = "zcube get nodes",
        }),
    }
}

test {
    _ = @import("peer_test.zig");
}
