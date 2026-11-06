//! A seeded fuzzer for the TLS client's handshake (`tls_client.zig`, docs/mtls.md): a server's
//! flight (with or without a request for the client's certificate, the request itself damaged in a
//! third of the runs), damaged in one of thirteen ways, cut into pieces of random size; in a
//! quarter of the runs one of EncryptedExtensions, Certificate, CertificateVerify and Finished
//! has its content damaged and is sealed and hashed as damaged, so only its parse can refuse it.
//! A flight left intact is followed by a random script of data, KeyUpdates, tickets and alerts
//! both ways, and of handshake records that may not follow a handshake (a KeyUpdate of the wrong
//! length or value, an empty ticket, an unknown type, bytes behind a KeyUpdate), which must end
//! the connection with a code.
//! The properties: no crash; the client is `connected` (at
//! any step, whatever follows) only when the flight was a correct one and the server accepts the
//! client's whole last flight, certificate included; a chain the pinned CA did not sign never
//! connects; after a refusal the client reads nothing and writes nothing more than the one
//! alert; every refusal carries a code and a cause. Seeds and replay are in `fuzz_seeds.zig`.

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

const iterations_default = 600;
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
    sent: [4096]u8,
    sent_length: u32,
    /// What the client had sent when it reported `connected`.
    connected_bytes: u32,
    client_key: Ed25519.KeyPair,
    client_certificate: x509.Der,
    client_chain: [1][]const u8,
    /// What the server must make of the client's last flight, when the run is clean.
    expect: testpeer.ClientFlight,
    flight: [flight_bytes_max]u8,
    damaged: [flight_bytes_max + 1024]u8,
    clean: bool,
    has_identity: bool,
    require_auth: bool,
    context: [8]u8,
    context_length: u8,
    schemes: [4]u16,
    /// The application data the server just sent.
    expected: [128]u8,
    /// The CertificateRequest was damaged: the client may refuse it, answer it as it stands, or
    /// connect; what it must never do is connect against a verdict the peer cannot accept.
    request_damaged: bool,
    /// One of the server's EncryptedExtensions, Certificate, CertificateVerify and Finished was
    /// damaged in its content: the client must not connect.
    message_damaged: bool,
    /// The client reported `connected` at some step although the flight was not a correct one
    /// or the server would not accept the client's Finished.
    false_connect: bool,
    /// The run ended in a refusal (so a check of the final outcome alone would pass).
    refused: bool,
};

/// `message_damaged` runs get no field fault: the damage must be the only thing between the
/// client and its connection, so that the run reaches the damaged message.
fn random_faults(
    random: std.Random,
    world: *World,
    chain: Chain,
    message_damaged: bool,
) testpeer.Faults {
    var faults: testpeer.Faults = .{};
    world.clean = chain == .good;
    faults.record_per_message = random.boolean();
    faults.no_ccs = random.boolean();
    if (message_damaged or random.uintLessThan(u8, 3) != 0) return faults;
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
    const message_damaged = random.uintLessThan(u8, 4) == 0;
    if (chain == .tampered) world.leaf.bytes[world.leaf.bytes.len - 1] ^= 1;
    world.certificates[0] = world.leaf.slice();
    world.peer = testpeer.Peer.init(.{
        .certificates = world.certificates[0..1],
        .key = key,
        .random = random_bytes(random),
        .secret = random_bytes(random),
        .faults = random_faults(random, world, chain, message_damaged),
        .client_auth = auth_config(random, world, ca),
    });
    world.client.init(&.{
        .anchor = ca.public_key.toBytes(),
        .server_name = server_name,
        .now_ms = x509_test.now,
        .random = random_bytes(random),
        .session_id = random_bytes(random),
        .secret = random_bytes(random),
        .client_auth = client_auth(world),
    });
    world.sent_length = 0;
    world.request_damaged = false;
    world.message_damaged = false;
    if (message_damaged) {
        world.peer.config.faults.message_damage = 1 + random.uintLessThan(u32, 1 << 16);
        world.message_damaged = true;
        world.clean = false;
    }
    if (world.peer.config.client_auth != null and random.uintLessThan(u8, 3) == 0) {
        world.peer.config.faults.request_damage = 1 + random.uintLessThan(u32, 1 << 20);
        world.request_damaged = true;
    }
}

fn client_auth(world: *World) tls_client.ClientAuth {
    if (!world.has_identity) return .none;
    const identity: tls_client.Identity = .{
        .certificates = &world.client_chain,
        .signer = tls_client.key_pair_signer(&world.client_key),
    };
    return if (world.require_auth) .{ .required = identity } else .{ .optional = identity };
}

/// Whether the server asks for a certificate, and whether the client has one. Only the
/// combinations a correct server accepts (the others are the client tests' business).
fn auth_config(random: std.Random, world: *World, ca: Ed25519.KeyPair) ?testpeer.ClientAuth {
    world.has_identity = false;
    world.require_auth = false;
    world.expect = .ok;
    const ask = random.boolean();
    world.has_identity = random.boolean();
    if (ask and world.has_identity) world.require_auth = random.boolean();
    if (world.has_identity) {
        world.client_key = Ed25519.KeyPair.generateDeterministic(random_bytes(random)) catch
            unreachable; // A seed of 32 bytes is always a key.
        const request = x509_test.workload_request(world.client_key.public_key.toBytes());
        x509.issue_workload(&world.client_certificate, ca, &request) catch unreachable; // Fits.
        world.client_chain = .{world.client_certificate.slice()};
    }
    if (!ask) return null;
    // The request lists one to four schemes, Ed25519 among them or not: a client without
    // Ed25519 answers with an empty Certificate (docs/mtls.md).
    const count = 1 + random.uintLessThan(usize, world.schemes.len);
    var usable = false;
    for (world.schemes[0..count]) |*scheme| {
        scheme.* = if (random.uintLessThan(u8, 3) == 0) 0x0807 else random_scheme(random);
        usable = usable or scheme.* == 0x0807;
    }
    const answers = world.has_identity and usable;
    if (!answers) world.expect = .ok_without_certificate;
    var context: [8]u8 = undefined;
    const length = random.uintAtMost(usize, context.len);
    random.bytes(context[0..length]);
    world.context = context;
    world.context_length = @intCast(length);
    return .{
        .anchor = ca.public_key.toBytes(),
        .now_ms = x509_test.now,
        .context = world.context[0..length],
        .schemes = world.schemes[0..count],
        .require = answers,
        .authorities = random.boolean(),
    };
}

fn random_scheme(random: std.Random) u16 {
    const known = [_]u16{ 0x0403, 0x0804, 0x0805, 0x0806, 0x0401, 0x0601, 0x0000, 0xFFFF };
    return known[random.uintLessThan(usize, known.len)];
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
    world.connected_bytes = world.sent_length;
    const flight = world.peer.accept_client_flight(world.sent[0..world.sent_length]);
    if (world.request_damaged) {
        // The peer's view of the request is no longer the client's (the context it checks the
        // echo against, the schemes), so only this holds: a client that must authenticate never
        // connects having sent an empty Certificate.
        const empty = flight == .ok_without_certificate or flight == .no_certificate;
        if (world.require_auth and empty) world.false_connect = true;
    } else if (flight != world.expect) world.false_connect = true;
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
    try testing.expect(sent - world.connected_bytes <= 64 + 5 + 40);
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
    world.connected_bytes = 0;
    try setup(world, random);
    world.client.start();
    collect(world);
    const hello = world.sent[0..world.sent_length];
    const answer = world.peer.respond(hello, &world.flight);
    world.sent_length = 0;
    // A damaged message gets no record-level mutation either: it must be what refuses the run.
    const kind: Mutation = if (world.message_damaged or random.uintLessThan(u8, 3) == 0)
        .none
    else
        random.enumValue(Mutation);
    const length = mutate(random, &world.peer, kind, answer, &world.damaged);
    _ = try feed(world, random, world.damaged[0..length]);
    if (world.message_damaged) {
        // A valid record, MAC and transcript around a damaged message has one correct outcome.
        // Connecting is a false connect (the teeth test turns a check off and counts those);
        // neither connecting nor refusing is a client left waiting.
        if (world.client.is_connected()) {
            world.false_connect = true;
        } else {
            try testing.expect(world.refused);
        }
    }
    const intact = kind == .none and !world.request_damaged and !world.refused and
        !world.message_damaged;
    if (intact and world.client.is_connected() and !world.false_connect) {
        try after_connect(world, random);
    }
    refused.* = world.refused;
    return world.false_connect;
}

/// What the connected client does with data, KeyUpdates (asked for or not), tickets and alerts
/// the server sends, and what it seals: a random script of up to eight steps against the peer,
/// whose keys move with the client's. Data must arrive whole and in order, an answer to a
/// request must open under the peer's keys, and an alert must end the connection.
fn after_connect(world: *World, random: std.Random) !void {
    var record: [512]u8 = undefined;
    var plain: [128]u8 = undefined;
    var out: [tls_client.Client.application_bytes_max(plain.len)]u8 = undefined;
    for (0..1 + random.uintLessThan(u8, 8)) |_| {
        const length = random.uintAtMost(usize, plain.len);
        random.bytes(plain[0..length]);
        world.sent_length = 0;
        switch (random.uintLessThan(u8, 12)) {
            0, 1 => {
                const sealed = world.peer.application(&record, plain[0..length]);
                @memcpy(world.expected[0..length], plain[0..length]);
                const data = try receive_all(world, sealed);
                try testing.expectEqual(length, data);
                try testing.expectEqual(@as(usize, 0), world.client.output().len);
            },
            2 => {
                const request = random.boolean();
                _ = try receive_all(world, world.peer.key_update(&record, request));
                collect(world);
                try testing.expectEqual(request, world.sent_length != 0);
                if (request) try open_key_update(world);
            },
            3 => {
                const sealed = world.peer.session_ticket(&record);
                _ = try receive_all(world, sealed);
            },
            4 => {
                const sealed = try world.client.seal_application(
                    plain[0..length],
                    &out,
                    &world.diag,
                );
                const opened = try world.peer.open(sealed);
                try testing.expectEqualSlices(u8, plain[0..length], opened.content);
            },
            5 => {
                try world.client.send_key_update(random.boolean(), &world.diag);
                collect(world);
                try open_key_update(world);
            },
            6 => return try end_by_alert(world, world.peer.close_notify(&record)),
            8, 9, 10, 11 => return try damaged_post_handshake(world, random, &record),
            else => return try end_by_alert(world, world.peer.alert(&record, random.int(u8))),
        }
    }
    // A script that did not end the connection ends it with a damaged record: every intact run
    // reaches that step once.
    try damaged_post_handshake(world, random, &record);
}

/// A handshake record the server could never send after the handshake, sealed under its current
/// keys: a KeyUpdate with two body bytes, none or a value over 1, an empty NewSessionTicket, a
/// type the client does not take (a CertificateRequest among them), or a KeyUpdate with bytes
/// behind it in the same record. The client must refuse it with a code and a cause, send at most
/// one alert and then read and write nothing.
fn damaged_post_handshake(world: *World, random: std.Random, record: []u8) !void {
    const wire = @import("tls_wire.zig");
    var message: [24]u8 = undefined;
    var length: usize = 0;
    const key_update = wire.handshake_key_update;
    switch (random.uintLessThan(u8, 6)) {
        0 => length = put_message(&message, key_update, &.{ random.int(u8), random.int(u8) }),
        1 => length = put_message(&message, key_update, &.{}),
        2 => length = put_message(&message, key_update, &.{2 + random.uintLessThan(u8, 254)}),
        3 => length = put_message(&message, wire.handshake_new_session_ticket, &.{}),
        4 => {
            // Not 4 (NewSessionTicket) and not 24 (KeyUpdate); 13 is a CertificateRequest.
            const types = [_]u8{ 1, 2, 8, 11, 13, 15, 20, 25, 254 };
            var body: [8]u8 = undefined;
            random.bytes(&body);
            const types_pick = types[random.uintLessThan(usize, types.len)];
            length = put_message(&message, types_pick, body[0..random.uintAtMost(usize, 8)]);
        },
        else => {
            length = put_message(&message, key_update, &.{random.uintLessThan(u8, 2)});
            const extra = 1 + random.uintLessThan(usize, 8);
            random.bytes(message[length..][0..extra]);
            length += extra;
        },
    }
    const sealed = world.peer.seal(record, .handshake, message[0..length]);
    world.sent_length = 0;
    const accepted = receive_all(world, sealed);
    collect(world);
    if (accepted) |_| return error.DamagedMessageAccepted else |err| {
        if (err == error.Closed) return error.DamagedMessageAccepted;
    }
    try expect_refusal(world);
    try testing.expectError(error.Closed, world.client.receive("x", &world.diag));
    try testing.expectEqual(@as(usize, 0), world.client.output().len);
    try testing.expect(world.sent_length <= 64);
}

/// A handshake message of `kind` with `body` at the start of `out`; returns its length.
fn put_message(out: []u8, kind: u8, body: []const u8) usize {
    out[0] = kind;
    std.mem.writeInt(u24, out[1..4], @intCast(body.len), .big);
    @memcpy(out[4..][0..body.len], body);
    return 4 + body.len;
}

/// Feeds `bytes` until the client has consumed them all; returns the bytes of application data
/// the client handed out (the data itself is checked against `world.expected`).
fn receive_all(world: *World, bytes: []const u8) !usize {
    var offset: usize = 0;
    var data: usize = 0;
    while (offset < bytes.len) {
        const step = try world.client.receive(bytes[offset..], &world.diag);
        try testing.expect(step.consumed > 0);
        offset += step.consumed;
        if (step.event == .data) {
            const got = step.event.data;
            try testing.expectEqualSlices(u8, world.expected[data..][0..got.len], got);
            data += step.event.data.len;
        }
    }
    return data;
}

/// The client's last output is a KeyUpdate under the peer's current read keys; the peer moves on.
fn open_key_update(world: *World) !void {
    const opened = try world.peer.open(world.sent[0..world.sent_length]);
    try testing.expectEqual(@import("tls_schedule.zig").ContentType.handshake, opened.content_type);
    try testing.expectEqual(@as(usize, 5), opened.content.len);
    try world.peer.read.rekey();
}

/// An alert from the server ends the connection: a refusal with a diagnostic, or a plain close.
fn end_by_alert(world: *World, alert: []u8) !void {
    world.sent_length = 0;
    _ = receive_all(world, alert) catch |err| {
        if (err == error.Closed) return;
        try expect_refusal(world);
        return;
    };
    try testing.expect(!world.client.is_connected());
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
