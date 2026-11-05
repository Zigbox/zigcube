//! A seeded fuzzer for the TLS client's handshake (`tls_client.zig`, docs/mtls.md): a server's
//! flight, damaged in one of thirteen ways, cut into pieces of random size. The properties: no
//! crash; the client is `connected` (at any step, whatever follows) only when the flight was a
//! correct one and the server accepts the client's Finished; a chain the pinned CA did not sign never connects; after a refusal the
//! client reads nothing and writes nothing more than the one alert; every refusal carries a
//! code and a cause. Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const diag_mod = @import("diag.zig");
const seeds = @import("fuzz_seeds.zig");
const testpeer = @import("tls_testpeer.zig");
const tls_client = @import("tls_client.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const assert = std.debug.assert;
const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

const iterations_default = 400;
const server_name = "broker.botpike.com";
const flight_bytes_max = 8192;

const Mutation = enum {
    none,
    flip_bit,
    truncate,
    drop_record,
    duplicate_record,
    swap_records,
    insert_alert,
    insert_random_record,
    overlong_header,
    random_bytes,
    replay_record,
    /// A plaintext alert at a random record boundary.
    alert_at_boundary,
    /// An alert sealed under the handshake keys at a random record boundary.
    sealed_alert_at_boundary,
};

const Chain = enum { good, other_ca, tampered };

/// The offsets of the records of `flight`: `starts[i]..starts[i + 1]`.
fn record_starts(flight: []const u8, starts: *[64]u32) u32 {
    var count: u32 = 0;
    var offset: usize = 0;
    while (offset + 5 <= flight.len and count < 63) {
        starts[count] = @intCast(offset);
        count += 1;
        offset += 5 + std.mem.readInt(u16, flight[offset + 3 ..][0..2], .big);
    }
    starts[count] = @intCast(@min(offset, flight.len));
    return count;
}

fn copy_records(
    out: []u8,
    flight: []const u8,
    starts: *const [64]u32,
    order: []const u32,
) usize {
    var length: usize = 0;
    for (order) |index| {
        const piece = flight[starts[index]..starts[index + 1]];
        @memcpy(out[length..][0..piece.len], piece);
        length += piece.len;
    }
    return length;
}

/// Writes the damaged flight to `out` and returns its length.
fn mutate(
    random: std.Random,
    peer: *testpeer.Peer,
    kind: Mutation,
    flight: []const u8,
    out: []u8,
) usize {
    var starts: [64]u32 = undefined;
    const count = record_starts(flight, &starts);
    var order: [64]u32 = undefined;
    for (0..count) |i| order[i] = @intCast(i);
    var used: usize = count;
    const pick = random.uintLessThan(u32, count);
    switch (kind) {
        .none, .flip_bit, .truncate, .overlong_header, .random_bytes, .insert_alert => {},
        .insert_random_record => {},
        .drop_record => {
            _ = std.mem.copyForwards(u32, order[pick .. used - 1], order[pick + 1 .. used]);
            used -= 1;
        },
        .duplicate_record => {
            std.mem.copyBackwards(u32, order[pick + 1 .. used + 1], order[pick..used]);
            used += 1;
        },
        .swap_records => std.mem.swap(u32, &order[pick], &order[random.uintLessThan(u32, count)]),
        .replay_record => {
            // Any record, protected ones included, at any position.
            const at = random.uintLessThan(u32, count + 1);
            std.mem.copyBackwards(u32, order[at + 1 .. used + 1], order[at..used]);
            order[at] = order[pick];
            used += 1;
        },
        .alert_at_boundary, .sealed_alert_at_boundary => {},
    }
    if (kind == .alert_at_boundary or kind == .sealed_alert_at_boundary) {
        return alert_at_boundary(random, peer, kind, flight, out, &starts, count);
    }
    var length = copy_records(out, flight, &starts, order[0..used]);
    length = damage_bytes(random, kind, out, length, starts[pick]);
    return length;
}

/// The flight with one alert (plain or sealed under the handshake keys) between two records.
fn alert_at_boundary(
    random: std.Random,
    peer: *testpeer.Peer,
    kind: Mutation,
    flight: []const u8,
    out: []u8,
    starts: *const [64]u32,
    count: u32,
) usize {
    const at = random.uintLessThan(u32, count + 1);
    const before = starts[at];
    @memcpy(out[0..before], flight[0..before]);
    var alert: [64]u8 = undefined;
    const description = random.int(u8);
    // A HelloRetryRequest peer has no handshake keys to seal with.
    const sealed = kind == .sealed_alert_at_boundary and !peer.config.faults.hello_retry;
    const bytes = if (sealed)
        peer.handshake_alert(&alert, description)
    else
        testpeer.plain_alert(&alert, description);
    @memcpy(out[before..][0..bytes.len], bytes);
    const rest = flight[before..];
    @memcpy(out[before + bytes.len ..][0..rest.len], rest);
    return flight.len + bytes.len;
}

fn damage_bytes(random: std.Random, kind: Mutation, out: []u8, length_in: usize, at: u32) usize {
    var length = length_in;
    switch (kind) {
        .flip_bit => out[random.uintLessThan(usize, length)] ^= @as(u8, 1) << random.int(u3),
        .truncate => length = random.uintLessThan(usize, length),
        .overlong_header => {
            const header = @min(at, length - 5);
            out[header + 3] = 0x40 + random.uintLessThan(u8, 0x40);
        },
        .random_bytes => {
            length = 1 + random.uintLessThan(usize, 600);
            random.bytes(out[0..length]);
        },
        .insert_alert => {
            const alert = testpeer.plain_alert(out[length..], random.int(u8));
            length += alert.len;
        },
        .insert_random_record => {
            const body = random.uintAtMost(u16, 64);
            out[length] = random.int(u8);
            std.mem.writeInt(u16, out[length + 1 ..][0..2], 0x0303, .big);
            std.mem.writeInt(u16, out[length + 3 ..][0..2], body, .big);
            random.bytes(out[length + 5 ..][0..body]);
            length += 5 + body;
        },
        else => {},
    }
    return length;
}

const World = struct {
    client: tls_client.Client,
    peer: testpeer.Peer,
    diag: diag_mod.Diag,
    leaf: x509.Der,
    second: x509.Der,
    certificates: [2][]const u8,
    sent: [1024]u8,
    sent_length: u32,
    flight: [flight_bytes_max]u8,
    damaged: [flight_bytes_max + 1024]u8,
    clean: bool,
    /// The client reported `connected` at some step although the flight was not a correct one
    /// or the server would not accept the client's Finished.
    false_connect: bool,
    /// The run ended in a refusal (so a check of the final outcome alone would pass).
    refused: bool,
};

fn random_faults(random: std.Random, world: *World, chain: Chain) testpeer.Faults {
    var faults: testpeer.Faults = .{};
    world.clean = chain == .good;
    faults.record_per_message = random.boolean();
    faults.no_ccs = random.boolean();
    if (random.uintLessThan(u8, 3) != 0) return faults;
    const field = random.uintLessThan(u8, 11);
    world.clean = false;
    switch (field) {
        0 => faults.bad_certificate_verify = true,
        1 => faults.wrong_scheme = true,
        2 => faults.bad_finished = true,
        3 => faults.skip_encrypted_extensions_in_transcript = true,
        4 => faults.hello_retry = true,
        5 => faults.downgrade = true,
        6 => faults.tls12 = true,
        7 => faults.wrong_suite = true,
        8 => faults.wrong_group = true,
        9 => faults.wrong_session_id = true,
        else => faults.certificate_request = true,
    }
    return faults;
}

fn setup(world: *World, random: std.Random) !void {
    world.diag.reset();
    const ca = try x509_test.ca_pair();
    const chain = random.enumValue(Chain);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(5));
    const signer = if (chain == .other_ca)
        try Ed25519.KeyPair.generateDeterministic(@splat(0xCB))
    else
        ca;
    try x509.issue_server(&world.leaf, signer, &.{
        .dns_name = server_name,
        .subject_key = key.public_key.toBytes(),
        .lifetime = x509_test.window,
    });
    if (chain == .tampered) world.leaf.bytes[world.leaf.bytes.len - 1] ^= 1;
    world.certificates[0] = world.leaf.slice();
    world.peer = testpeer.Peer.init(.{
        .certificates = world.certificates[0..1],
        .key = key,
        .random = random_bytes(random),
        .secret = random_bytes(random),
        .faults = random_faults(random, world, chain),
    });
    world.client.init(&.{
        .anchor = ca.public_key.toBytes(),
        .server_name = server_name,
        .now_ms = x509_test.now,
        .random = random_bytes(random),
        .session_id = random_bytes(random),
        .secret = random_bytes(random),
    });
    world.sent_length = 0;
}

fn random_bytes(random: std.Random) [32]u8 {
    var out: [32]u8 = undefined;
    random.bytes(&out);
    return out;
}

fn collect(world: *World) void {
    const output = world.client.output();
    @memcpy(world.sent[world.sent_length..][0..output.len], output);
    world.sent_length += @intCast(output.len);
    world.client.drain();
}

const Outcome = enum { open, refused, closed };

/// The property, at the moment of `connected`: only a correct flight, and only if the server
/// accepts the client's answer. What follows (an alert, a replayed record) cannot undo it.
fn check_connected(world: *World) void {
    if (!world.clean) world.false_connect = true;
    if (!world.client.is_connected()) world.false_connect = true;
    if (!world.peer.accept_client_finished(world.sent[0..world.sent_length])) {
        world.false_connect = true;
    }
}

/// Feeds the damaged flight in random pieces; checks the properties that hold at every step.
fn feed(world: *World, random: std.Random, bytes: []const u8) !Outcome {
    const outcome: Outcome = .open;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const piece = @min(bytes.len - offset, 1 + random.uintLessThan(usize, 300));
        const step = world.client.receive(bytes[offset..][0..piece], &world.diag) catch |err| {
            collect(world);
            if (err == error.Closed) return if (outcome == .refused) .refused else .closed;
            try expect_refusal(world);
            world.refused = true;
            return try after_refusal(world);
        };
        collect(world);
        offset += step.consumed;
        if (step.event == .connected) check_connected(world);
    }
    return outcome;
}

fn expect_refusal(world: *World) !void {
    try testing.expect(world.diag.code != null);
    try testing.expect(world.diag.last_cause() != null);
    try testing.expect(!world.client.is_connected());
}

/// Once refused, the client reads nothing and writes nothing.
fn after_refusal(world: *World) !Outcome {
    const sent = world.sent_length;
    try testing.expectError(error.Closed, world.client.receive("x", &world.diag));
    try testing.expectEqual(@as(usize, 0), world.client.output().len);
    try testing.expectEqual(sent, world.sent_length);
    // At most one alert record (the sealed alert is 24 bytes; a plain one 7).
    try testing.expect(sent <= 64 + 5 + 40);
    return .refused;
}

/// One run; true when the client connected falsely (see `World.false_connect`).
fn run_once(seed: u64, refused: *bool) !bool {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const world = try testing.allocator.create(World);
    defer testing.allocator.destroy(world);
    world.false_connect = false;
    world.refused = false;
    try setup(world, random);
    world.client.start();
    collect(world);
    const hello = world.sent[0..world.sent_length];
    const answer = world.peer.respond(hello, &world.flight);
    world.sent_length = 0;
    const kind = random.enumValue(Mutation);
    const length = mutate(random, &world.peer, kind, answer, &world.damaged);
    _ = try feed(world, random, world.damaged[0..length]);
    refused.* = world.refused;
    return world.false_connect;
}

fn fuzz_once(seed: u64) !void {
    var refused = false;
    try testing.expect(!try run_once(seed, &refused));
}

test "fuzz: a damaged server flight never connects falsely and never crashes" {
    // Goal: the handshake survives any flight and connects only to a server that holds the pinned
    // CA's chain and the right keys. Method: a scripted server (random correct or faulty, with a
    // chain the CA signed, another CA signed, or a damaged signature) answers; the flight is
    // damaged in one of thirteen ways and fed in random pieces. A failure prints the seed.
    try seeds.run("tls fuzz", iterations_default, fuzz_once);
}

test "teeth: the property catches a false connect that a later error hides" {
    // Goal: evidence that the check at the moment of `connected` is load-bearing. Method: with
    // the client's CertificateVerify check off, some seed connects to a forged flight and then
    // refuses a record that follows it: the run ends refused, so only the check at the step
    // sees it.
    tls_client.set_test_fault(.certificate_verify, true);
    defer tls_client.set_test_fault(.certificate_verify, false);
    var hidden: u32 = 0;
    var seed: u64 = 1;
    while (seed <= 3000) : (seed += 1) {
        var refused = false;
        if (try run_once(seed, &refused) and refused) hidden += 1;
    }
    try testing.expect(hidden > 0);
}
