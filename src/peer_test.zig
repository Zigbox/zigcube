//! Tests of `peer.zig` (docs/peer.md): the credential, the three handshake messages and the
//! record layer. Core code: it runs natively and under WASI (`zig build wasm-test`), so it uses
//! no environment variable, file or clock. The seeded decoder fuzzer is `peer_fuzz.zig`.

const std = @import("std");
const peer = @import("peer.zig");
const diag_mod = @import("diag.zig");
const constants = @import("constants.zig");

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const now: u64 = 1_700_000_000_000;
const hour: u64 = 3_600_000;

fn seed(n: u8) [32]u8 {
    return @splat(n);
}

fn ca_pair(n: u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed(n));
}

fn identity_of(ca: Ed25519.KeyPair, name: []const u8, n: u8, nb: u64, na: u64) !peer.Identity {
    const key = try Ed25519.KeyPair.generateDeterministic(seed(n));
    return .{
        .key = key,
        .credential = peer.issue(ca, name, key.public_key.toBytes(), nb, na),
        .ca_public = ca.public_key.toBytes(),
    };
}

/// Two nodes of one cluster, valid from an hour ago for a day.
const Fixture = struct {
    ca: Ed25519.KeyPair,
    client: peer.Identity,
    server: peer.Identity,

    fn init() !Fixture {
        const ca = try ca_pair(0xCA);
        return .{
            .ca = ca,
            .client = try identity_of(ca, "node1", 1, now - hour, now + 23 * hour),
            .server = try identity_of(ca, "node2", 2, now - hour, now + 23 * hour),
        };
    }
};

const Pair = struct { client: peer.Session, server: peer.Session };

fn connect(client: *const peer.Identity, server: *const peer.Identity, expected: []const u8) !Pair {
    var initiator = peer.Initiator.init(client, expected, seed(11), now);
    var responder = peer.Responder.init(server, seed(12), now);
    const m1 = initiator.first();
    const m2 = try responder.first(&m1);
    const done = try initiator.second(&m2);
    const session = try responder.second(&done.m3);
    return .{ .client = done.session, .server = session };
}

test "a handshake between two nodes of one cluster opens a session both ways" {
    // Goal: the happy path, and the authenticated names. Method: connect, check each side sees
    // the other's name, then send records both ways, several, and read them back.
    const f = try Fixture.init();
    var pair = try connect(&f.client, &f.server, "node2");
    try testing.expectEqualStrings("node2", pair.client.peer_name());
    try testing.expectEqualStrings("node1", pair.server.peer_name());
    var wire: [peer.record_bytes_max]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    for (0..5) |i| {
        const text = "chunk request";
        const record = try pair.client.seal(text, &wire);
        try testing.expectEqualStrings(text, try pair.server.open(record, &plain));
        const reply = try pair.server.seal(text[0 .. i + 1], &wire);
        try testing.expectEqualStrings(text[0 .. i + 1], try pair.client.open(reply, &plain));
    }
    // An empty record is a record.
    const empty = try pair.client.seal("", &wire);
    try testing.expectEqual(@as(usize, peer.record_overhead_bytes), empty.len);
    try testing.expectEqual(@as(usize, 0), (try pair.server.open(empty, &plain)).len);
}

test "the credential encodes to its documented size and decodes to what was issued" {
    // Goal: the wire format of docs/peer.md. Method: issue, encode, decode, compare each field;
    // the verify of the decoded copy still passes, so nothing was lost.
    const f = try Fixture.init();
    const bytes = peer.encode(&f.server.credential);
    try testing.expectEqual(@as(usize, 185), bytes.len);
    const back = try peer.decode(&bytes);
    try testing.expectEqualStrings("node2", back.name());
    try testing.expectEqual(f.server.credential.not_after_ms, back.not_after_ms);
    try testing.expectEqual(f.server.credential.node_key, back.node_key);
    try peer.verify(&back, f.ca.public_key.toBytes(), now, "node2");
}

test "a credential that is not in canonical form does not decode" {
    // Goal: the decoder takes one encoding of each credential and nothing else. Method: start
    // from a good one and break each rule once.
    const f = try Fixture.init();
    const good = peer.encode(&f.server.credential);
    var bad = good;
    bad[0] = 2; // Another version.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    bad[9] = 0; // An empty name.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    bad[9] = 64; // A name longer than the field.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    bad[10 + 5] = 'x'; // Padding that is not zero.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    bad[10] = 'N'; // A character no node name has.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    std.mem.writeInt(u64, bad[113..121], now - 2 * hour, .little); // Ends before it starts.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
    bad = good;
    std.mem.writeInt(u64, bad[113..121], now + 30 * 24 * hour, .little); // Longer than the cap.
    try testing.expectError(error.HandshakeFailed, peer.decode(&bad));
}

test "the validity window is checked with the documented skew, and in the documented order" {
    // Goal: the edges of the window and which error wins. Method: a credential for [now, now+1h);
    // check one millisecond inside and outside each edge of the skew, then a wrong CA with a
    // wrong name and a wrong window, which must say the CA.
    const f = try Fixture.init();
    const skew = constants.peer_clock_skew_ms;
    const public = f.ca.public_key.toBytes();
    const key = f.server.key.public_key.toBytes();
    const credential = peer.issue(f.ca, "node2", key, now, now + hour);
    const verify = peer.verify;
    try verify(&credential, public, now - skew, null);
    try testing.expectError(error.NotYetValid, verify(&credential, public, now - skew - 1, null));
    try verify(&credential, public, now + hour + skew - 1, null);
    try testing.expectError(error.Expired, verify(&credential, public, now + hour + skew, null));
    try testing.expectError(error.WrongNode, verify(&credential, public, now, "node3"));
    const strange = (try ca_pair(0xCB)).public_key.toBytes();
    try testing.expectError(error.UnknownCa, verify(&credential, strange, now + 99 * hour, "x"));
}

test "a forged or altered credential is refused" {
    // Goal: only the CA makes credentials. Method: flip each byte of the signed body and of the
    // signature in turn (the key id byte gives UnknownCa, the rest BadSignature), and sign with a
    // key that is not the CA's.
    const f = try Fixture.init();
    const public = f.ca.public_key.toBytes();
    const good = peer.encode(&f.server.credential);
    for (0..peer.credential_bytes) |i| {
        var bytes = good;
        bytes[i] ^= 1;
        const credential = peer.decode(&bytes) catch continue; // Not canonical: refused already.
        const result = peer.verify(&credential, public, now, "node2");
        if (i >= 1 and i < 9) {
            try testing.expectError(error.UnknownCa, result);
        } else if (i >= 10 and i < 10 + peer.name_bytes_max) {
            // A name byte changed: the signature or the name no longer holds.
            try testing.expect(std.meta.isError(result));
        } else {
            try testing.expectError(error.BadSignature, result);
        }
    }
    const rogue = try ca_pair(0xEE);
    const key = f.server.key.public_key.toBytes();
    var forged = peer.issue(rogue, "node2", key, now - hour, now + hour);
    forged.ca_key_id = f.server.credential.ca_key_id; // Claims to be the cluster's CA.
    try testing.expectError(error.BadSignature, peer.verify(&forged, public, now, "node2"));
}

test "a handshake is refused for each reason a peer can be wrong" {
    // Goal: every refusal path of the handshake, with the error a caller maps to ZC-E0801..4.
    // Method: one fixture per reason, started from the same two good nodes.
    const f = try Fixture.init();
    const other_ca = try ca_pair(0xCB);

    // The server holds a credential from another CA.
    const strange = try identity_of(other_ca, "node2", 2, now - hour, now + hour);
    var stranger = strange;
    stranger.ca_public = f.server.ca_public; // It trusts our CA but carries another's credential.
    try testing.expectError(error.UnknownCa, connect(&f.client, &stranger, "node2"));

    // The server's credential has expired, or is not yet valid.
    const old = try identity_of(f.ca, "node2", 2, now - 3 * hour, now - 2 * hour);
    try testing.expectError(error.Expired, connect(&f.client, &old, "node2"));
    const future = try identity_of(f.ca, "node2", 2, now + 2 * hour, now + 3 * hour);
    try testing.expectError(error.NotYetValid, connect(&f.client, &future, "node2"));

    // The client asked for node3 and got node2.
    try testing.expectError(error.WrongNode, connect(&f.client, &f.server, "node3"));

    // A credential carried by a node that does not hold its key.
    var thief = f.server;
    thief.key = try Ed25519.KeyPair.generateDeterministic(seed(77));
    try testing.expectError(error.HandshakeFailed, connect(&f.client, &thief, "node2"));

    // The same three on the other side: the server refuses a bad client at M3.
    const wrong_ca = try identity_of(other_ca, "node1", 1, now - hour, now + hour);
    try testing.expectError(error.UnknownCa, connect(&wrong_ca, &f.server, "node2"));
    const client_old = try identity_of(f.ca, "node1", 1, now - 3 * hour, now - 2 * hour);
    try testing.expectError(error.Expired, connect(&client_old, &f.server, "node2"));
    var client_thief = f.client;
    client_thief.key = try Ed25519.KeyPair.generateDeterministic(seed(78));
    try testing.expectError(error.HandshakeFailed, connect(&client_thief, &f.server, "node2"));
}

test "a client trusting another CA refuses the server it was told to dial" {
    // Goal: the trust is the CA the node holds, not what the peer presents. Method: both nodes
    // are valid in their own cluster; the client holds the other cluster's CA key.
    const f = try Fixture.init();
    const other_ca = try ca_pair(0xCB);
    var client = f.client;
    client.ca_public = other_ca.public_key.toBytes();
    try testing.expectError(error.UnknownCa, connect(&client, &f.server, "node2"));
}

test "a weak ephemeral key or a wrong message type is refused" {
    // Goal: the first message is read defensively. Method: an all-zero ephemeral key (a
    // low-order point) and a wrong type byte or version.
    const f = try Fixture.init();
    var initiator = peer.Initiator.init(&f.client, "node2", seed(11), now);
    var m1 = initiator.first();
    var weak = m1;
    @memset(weak[2..], 0);
    var responder = peer.Responder.init(&f.server, seed(12), now);
    try testing.expectError(error.HandshakeFailed, responder.first(&weak));
    responder = peer.Responder.init(&f.server, seed(12), now);
    m1[1] = 2;
    try testing.expectError(error.HandshakeFailed, responder.first(&m1));
    responder = peer.Responder.init(&f.server, seed(12), now);
    m1[1] = 1;
    m1[0] = 2;
    try testing.expectError(error.HandshakeFailed, responder.first(&m1));
}

/// Runs a whole handshake with one bit flipped in message `which` (1..3) at `position`, or
/// untouched for `which == 0`. Returns the first error.
fn run_flipped(f: *const Fixture, which: u8, position: usize) peer.Error!void {
    const bit: u8 = @as(u8, 1) << @intCast(position % 8);
    var initiator = peer.Initiator.init(&f.client, "node2", seed(11), now);
    var responder = peer.Responder.init(&f.server, seed(12), now);
    var m1 = initiator.first();
    if (which == 1) m1[position] ^= bit;
    var m2 = try responder.first(&m1);
    if (which == 2) m2[position] ^= bit;
    const done = try initiator.second(&m2);
    var m3 = done.m3;
    if (which == 3) m3[position] ^= bit;
    _ = try responder.second(&m3);
}

test "an altered handshake message fails at every byte position" {
    // Goal: no byte of M1, M2 or M3 can change without the handshake failing. Method: one bit
    // flipped per position (the bit is the position mod 8, so all eight are used across a
    // message), each in a full run; the untouched run must pass first. The X25519 key's top bit,
    // which the function ignores, is still caught because the transcript hash covers it.
    const f = try Fixture.init();
    try run_flipped(&f, 0, 0);
    for (0..peer.m1_bytes) |i| try testing.expect(std.meta.isError(run_flipped(&f, 1, i)));
    for (0..peer.m2_bytes) |i| try testing.expect(std.meta.isError(run_flipped(&f, 2, i)));
    for (0..peer.m3_bytes) |i| try testing.expect(std.meta.isError(run_flipped(&f, 3, i)));
    // The top bit of each ephemeral key in particular.
    try testing.expect(std.meta.isError(run_flippedbit(&f, 1, 33, 0x80)));
    try testing.expect(std.meta.isError(run_flippedbit(&f, 2, 33, 0x80)));
}

fn run_flippedbit(f: *const Fixture, which: u8, position: usize, mask: u8) peer.Error!void {
    var initiator = peer.Initiator.init(&f.client, "node2", seed(11), now);
    var responder = peer.Responder.init(&f.server, seed(12), now);
    var m1 = initiator.first();
    if (which == 1) m1[position] ^= mask;
    var m2 = try responder.first(&m1);
    if (which == 2) m2[position] ^= mask;
    const done = try initiator.second(&m2);
    _ = try responder.second(&done.m3);
}

test "a message replayed from another handshake does not open" {
    // Goal: M2 and M3 are bound to the exchange they belong to. Method: record the M2 of one
    // handshake and play it to a client in another (different ephemeral key), then the same for
    // M3 against a different responder.
    const f = try Fixture.init();
    var first_client = peer.Initiator.init(&f.client, "node2", seed(11), now);
    var first_server = peer.Responder.init(&f.server, seed(12), now);
    const m1 = first_client.first();
    const m2 = try first_server.first(&m1);
    const done = try first_client.second(&m2);

    var second_client = peer.Initiator.init(&f.client, "node2", seed(21), now);
    _ = second_client.first();
    try testing.expectError(error.HandshakeFailed, second_client.second(&m2));

    var other_server = peer.Responder.init(&f.server, seed(22), now);
    const other_m1 = peer.Initiator.init(&f.client, "node2", seed(21), now);
    var again = other_m1;
    const m1b = again.first();
    _ = try other_server.first(&m1b);
    try testing.expectError(error.HandshakeFailed, other_server.second(&done.m3));
}

fn established() !Pair {
    const f = try Fixture.init();
    return connect(&f.client, &f.server, "node2");
}

test "a replayed, reordered, reflected or altered record kills the session" {
    // Goal: the counter is the nonce and the order. Method: seal three records; open the second
    // first (refused, dead); on a fresh pair open one twice (refused); a record reflected to its
    // sender (refused); every byte of a record flipped (refused each time, then dead).
    var wire: [3][peer.record_bytes_max]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    var pair = try established();
    _ = try pair.client.seal("one", &wire[0]);
    const second = try pair.client.seal("two", &wire[1]);
    try testing.expectError(error.RecordRejected, pair.server.open(second, &plain));
    const first_record = wire[0][0 .. 2 + 3 + 16];
    try testing.expectError(error.RecordRejected, pair.server.open(first_record, &plain));

    pair = try established();
    const record = try pair.client.seal("one", &wire[0]);
    _ = try pair.server.open(record, &plain);
    try testing.expectError(error.RecordRejected, pair.server.open(record, &plain));

    pair = try established();
    const out = try pair.client.seal("one", &wire[0]);
    try testing.expectError(error.RecordRejected, pair.client.open(out, &plain));

    for (0..2 + 3 + 16) |i| {
        pair = try established();
        var copy: [2 + 3 + 16]u8 = undefined;
        @memcpy(&copy, try pair.client.seal("one", &wire[0]));
        copy[i] ^= 0x40;
        try testing.expectError(error.RecordRejected, pair.server.open(&copy, &plain));
        // Dead: even the right record is now refused.
        const right = try pair.client.seal("two", &wire[1]);
        try testing.expectError(error.RecordRejected, pair.server.open(right, &plain));
    }
}

test "a record is bounded in both directions" {
    // Goal: nothing longer than the limit is sealed or accepted. Method: the largest record
    // round-trips; headers announcing too little or too much, and a cut record, are refused.
    var pair = try established();
    var wire: [peer.record_bytes_max]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    const big: [constants.peer_record_bytes_max]u8 = @splat(0x5a);
    const record = try pair.client.seal(&big, &wire);
    try testing.expectEqual(@as(usize, peer.record_bytes_max), record.len);
    try testing.expectEqual(big.len, (try pair.server.open(record, &plain)).len);

    try testing.expectEqual(@as(?u16, null), peer.Session.body_length(&.{ 0, 15 }));
    try testing.expectEqual(@as(?u16, 16), peer.Session.body_length(&.{ 0, 16 }));
    const largest: u16 = constants.peer_record_bytes_max + 16;
    try testing.expectEqual(@as(?u16, null), peer.Session.body_length(&.{ 0xff, 0xff }));
    var header: [2]u8 = undefined;
    std.mem.writeInt(u16, &header, largest, .big);
    try testing.expectEqual(@as(?u16, largest), peer.Session.body_length(&header));
    std.mem.writeInt(u16, &header, largest + 1, .big);
    try testing.expectEqual(@as(?u16, null), peer.Session.body_length(&header));

    pair = try established();
    const cut = try pair.client.seal("hello", &wire);
    try testing.expectError(error.RecordRejected, pair.server.open(cut[0 .. cut.len - 1], &plain));
    pair = try established();
    try testing.expectError(error.RecordRejected, pair.server.open(&.{ 0, 1 }, &plain));
}

test "a direction stops at the counter limit and the nonce is never reused" {
    // Goal: the counter closes the session before it can wrap. Method: set both counters one
    // below the limit, send one record (accepted), then both ends refuse the next with
    // RecordExhausted, and the counters did not move.
    var pair = try established();
    const last = constants.peer_record_counter_max - 1;
    pair.client.send_counter = last;
    pair.server.receive_counter = last;
    var wire: [peer.record_bytes_max]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    const record = try pair.client.seal("last", &wire);
    try testing.expectEqualStrings("last", try pair.server.open(record, &plain));
    try testing.expectEqual(constants.peer_record_counter_max, pair.client.send_counter);
    try testing.expectError(error.RecordExhausted, pair.client.seal("more", &wire));
    try testing.expectError(error.RecordExhausted, pair.server.open(record, &plain));
    try testing.expectEqual(constants.peer_record_counter_max, pair.client.send_counter);
    try testing.expectEqual(constants.peer_record_counter_max, pair.server.receive_counter);
}

test "a wiped session refuses everything" {
    // Goal: after `wipe` the keys are zero and no call works. Method: wipe, then seal and open.
    var pair = try established();
    var wire: [peer.record_bytes_max]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    pair.client.wipe();
    try testing.expectError(error.RecordRejected, pair.client.seal("x", &wire));
    try testing.expectError(error.RecordRejected, pair.client.open(&wire, &plain));
    try testing.expectEqual(@as(u8, 0), pair.client.send_key[0]);
}

test "teeth: with signature checking skipped a forged credential gets in, so the tests have teeth" {
    // Goal: the refusal tests above would catch a verify that skips the CA signature. Method:
    // build a credential signed by a rogue key but carrying the cluster's key id; refused with
    // the check on, accepted end to end with the test-only fault on, refused again with it off.
    const f = try Fixture.init();
    const rogue = try ca_pair(0xEE);
    const key = f.server.key.public_key.toBytes();
    var forged = peer.issue(rogue, "node2", key, now - hour, now + hour);
    forged.ca_key_id = f.server.credential.ca_key_id;
    var impostor = f.server;
    impostor.credential = forged;

    try testing.expectError(error.BadSignature, connect(&f.client, &impostor, "node2"));
    peer.set_test_fault(true);
    defer peer.set_test_fault(false);
    var pair = try connect(&f.client, &impostor, "node2");
    try testing.expectEqualStrings("node2", pair.client.peer_name());
    peer.set_test_fault(false);
    try testing.expectError(error.BadSignature, connect(&f.client, &impostor, "node2"));
}

test "each refusal is a registered diagnostic with a cause that names the peer" {
    // Goal: the mapping to ZC-E0801..5 and the one-line causes. Method: raise every error and
    // read back the code and the cause; the codes are the documented ones.
    const errors = [_]peer.Error{
        error.UnknownCa, error.BadSignature,    error.Expired,        error.NotYetValid,
        error.WrongNode, error.HandshakeFailed, error.RecordRejected, error.RecordExhausted,
    };
    const codes = [_]@import("diag/codes.zig").Code{
        .E0801, .E0801, .E0802, .E0802, .E0803, .E0804, .E0805, .E0805,
    };
    for (errors, codes) |err, code| {
        var diag: diag_mod.Diag = undefined;
        diag.reset();
        peer.raise(&diag, err, "node7");
        try testing.expectEqual(code, diag.code.?);
        try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "node7") != null);
        try testing.expect(diag.fixes.count > 0);
    }
}
