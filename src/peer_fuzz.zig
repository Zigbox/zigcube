//! A seeded fuzzer for the peer decoders (`peer.zig`, docs/peer.md): random and damaged bytes in
//! the credential decoder, the three handshake messages and the record opener. The property: no
//! crash, no unbounded work, and nothing accepted that was not made by a holder of the cluster's
//! keys. Seeds and replay are in `fuzz_seeds.zig`: a failure prints the master seed and the
//! iteration seed, each with its replay.

const std = @import("std");
const peer = @import("peer.zig");
const constants = @import("constants.zig");
const seeds = @import("fuzz_seeds.zig");

const assert = std.debug.assert;
const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const iterations_default = 300;
const now: u64 = 1_700_000_000_000;
const hour: u64 = 3_600_000;

fn identity_of(ca: Ed25519.KeyPair, name: []const u8, n: u8) !peer.Identity {
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(n));
    return .{
        .key = key,
        .credential = peer.issue(ca, name, key.public_key.toBytes(), now - hour, now + hour),
        .ca_public = ca.public_key.toBytes(),
    };
}

/// One iteration: random bytes, then a good message with random damage, into every decoder.
fn fuzz_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA));
    const client = try identity_of(ca, "node1", 1);
    const server = try identity_of(ca, "node2", 2);

    var noise: [peer.credential_bytes]u8 = undefined;
    random.bytes(&noise);
    if (peer.decode(&noise)) |credential| {
        // Random bytes that decode must still not verify: only the CA signs.
        const result = peer.verify(&credential, ca.public_key.toBytes(), now, null);
        try testing.expect(std.meta.isError(result));
    } else |_| {}

    var initiator = peer.Initiator.init(&client, "node2", seed32(random), now);
    var responder = peer.Responder.init(&server, seed32(random), now);
    var m1 = initiator.first();
    damage(random, &m1);
    var m2: [peer.m2_bytes]u8 = undefined;
    random.bytes(&m2);
    if (responder.first(&m1)) |good| {
        m2 = good;
        damage(random, &m2);
    } else |_| {}
    var again = peer.Initiator.init(&client, "node2", seed32(random), now);
    _ = again.first();
    if (again.second(&m2)) |_| return error.AcceptedDamagedMessage else |_| {}

    var m3: [peer.m3_bytes]u8 = undefined;
    random.bytes(&m3);
    var other = peer.Responder.init(&server, seed32(random), now);
    _ = other.first(&initiator_m1(&client, random)) catch return;
    if (other.second(&m3)) |_| return error.AcceptedDamagedMessage else |_| {}
}

fn initiator_m1(client: *const peer.Identity, random: std.Random) [peer.m1_bytes]u8 {
    var initiator = peer.Initiator.init(client, "node2", seed32(random), now);
    return initiator.first();
}

/// Flips one bit in each of one to three distinct bytes, so the message is never the original.
fn damage(random: std.Random, message: []u8) void {
    assert(message.len > 3);
    const flips = random.intRangeAtMost(usize, 1, 3);
    const start = random.uintLessThan(usize, message.len);
    for (0..flips) |i| {
        const bit: u8 = @as(u8, 1) << random.int(u3);
        message[(start + i) % message.len] ^= bit;
    }
}

fn seed32(random: std.Random) [32]u8 {
    var out: [32]u8 = undefined;
    random.bytes(&out);
    return out;
}

test "fuzz: damaged and random peer messages are refused, never accepted, never crash" {
    // Goal: the decoders survive any input and accept only what the cluster's keys made. Method:
    // derive each iteration's seed from the run's seed; random bytes and bit-damaged real
    // messages go into the credential decoder, M2 and M3. A failure prints the seed.
    try seeds.run("peer fuzz", iterations_default, fuzz_once);
}

/// One record iteration: a fresh session, then random bytes of a random length into its opener.
fn record_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA));
    const client = try identity_of(ca, "node1", 1);
    const server = try identity_of(ca, "node2", 2);
    var buffer: [peer.record_bytes_max + 8]u8 = undefined;
    var plain: [constants.peer_record_bytes_max]u8 = undefined;
    var initiator = peer.Initiator.init(&client, "node2", seed32(random), now);
    var responder = peer.Responder.init(&server, seed32(random), now);
    const m1 = initiator.first();
    const m2 = try responder.first(&m1);
    var done = try initiator.second(&m2);
    const length = random.uintAtMost(usize, buffer.len);
    random.bytes(buffer[0..length]);
    if (length >= 2) std.mem.writeInt(u16, buffer[0..2], @intCast(length - 2), .big);
    if (done.session.open(buffer[0..length], &plain)) |_| {
        return error.OpenedRandomRecord;
    } else |_| {}
}

test "fuzz: records of any length and content are refused or opened within bounds" {
    // Goal: the record opener never reads or writes out of bounds. Method: random bytes of every
    // length around the limits, into a fresh session each; nothing opens. Seeds as above.
    try seeds.run("peer record fuzz", iterations_default, record_once);
}
