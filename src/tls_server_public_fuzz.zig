//! A seeded fuzzer for the TLS server's public path (`tls_server.zig`, `init_public`;
//! docs/briefs/c5.md, "Public TLS"): the scripted client of `tls_testclient.zig` on the public
//! path sends a ClientHello and its Finished, either correct or wrong in one knob (the hello's,
//! the server name, ALPN, the key share, the Finished, the change_cipher_spec records), and in a
//! part of the runs the hello or the flight is damaged at the record level with
//! `tls_server_fuzz.zig`'s mutations and fed in pieces of random size.
//!
//! The properties: no crash; the server is `connected` only when the hello reached it whole, the
//! knobs were all correct and the flight was the client's records in order (a correct client's
//! flight left whole always connects, and then names the host it asked for); every refusal
//! carries a code and a cause; after a refusal the server writes nothing more than the one alert
//! and reads nothing. Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const fuzz = @import("tls_server_fuzz.zig");
const seeds = @import("fuzz_seeds.zig");
const testclient = @import("tls_testclient.zig");
const tls_server = @import("tls_server.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");
const p256 = @import("x509_p256.zig");
const p256_test = @import("x509_p256_test.zig");

const testing = std.testing;
const Diag = diag_mod.Diag;
const Mutation = fuzz.Mutation;

const iterations_default = 200;
const buffer_bytes = 3 * constants.tls_handshake_flight_bytes_max;
/// Sorted, as `PublicTable.init` requires.
const hosts = [_][]const u8{ "a.example.org", "hello.test" };

const World = struct {
    server: tls_server.Server,
    client: testclient.Client,
    diag: Diag,
    root: p256.KeyPair,
    root_certificate: x509.Der,
    keys: [hosts.len]p256.KeyPair,
    leaves: [hosts.len]x509.Der,
    certificates: [hosts.len][2][]const u8,
    chains: [hosts.len]tls_server.PublicChain,
    table: tls_server.PublicTable,
    /// The host the client asks for, as the table has it.
    host: []const u8,
    sent: [buffer_bytes]u8,
    sent_length: u32,
    original: [buffer_bytes]u8,
    damaged: [buffer_bytes]u8,
    /// The client's knobs are all correct (or only those a server must take).
    knobs_good: bool,
    /// The one wrong knob is in the flight's change_cipher_spec records, which
    /// `tls_server_fuzz.flight_whole` judges from the bytes sent.
    knobs_ccs: bool,
    legit: bool,
    false_connect: bool,
    refused: bool,
};

fn setup(world: *World, random: std.Random) !void {
    world.diag.reset();
    world.root = try p256_test.ca_key();
    try p256.issue_ca(&world.root_certificate, world.root, x509_test.window);
    for (hosts, 0..) |host, index| {
        world.keys[index] = try p256_test.key(@intCast(0x50 + index));
        try p256.issue_server(&world.leaves[index], world.root, &.{
            .dns_name = host,
            .sans = &.{},
            .subject_key = p256.point_of(world.keys[index]),
            .lifetime = x509_test.window,
        });
        world.certificates[index] = .{
            world.leaves[index].slice(),
            world.root_certificate.slice(),
        };
        world.chains[index] = .{
            .host = host,
            .key = &world.keys[index],
            .certificates = &world.certificates[index],
        };
    }
    world.table = try tls_server.PublicTable.init(&world.chains);
    var server_random: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;
    random.bytes(&server_random);
    random.bytes(&server_secret);
    world.server.init_public(&.{
        .random = server_random,
        .secret = server_secret,
        .table = &world.table,
    });
    world.host = hosts[random.uintLessThan(usize, hosts.len)];
    var public: testclient.Public = .{ .root = world.root, .expect_host = world.host };
    const faults = random_faults(random, &public, world.host, world);
    var client_random: [32]u8 = undefined;
    var client_secret: [32]u8 = undefined;
    random.bytes(&client_random);
    random.bytes(&client_secret);
    try world.client.init(.{
        .ca = try x509_test.ca_pair(),
        .public = public,
        .random = client_random,
        .secret = client_secret,
        .faults = faults,
    });
    world.sent_length = 0;
    world.false_connect = false;
    world.refused = false;
    world.legit = false;
}

/// The client's knobs: those a server must take drawn freely (the name's case and trailing
/// dot, either signature list with ecdsa_secp256r1_sha256, ALPN or none, a session id, a
/// change_cipher_spec); in half the runs one more is wrong, which no server may take.
fn random_faults(
    random: std.Random,
    public: *testclient.Public,
    host: []const u8,
    world: *World,
) testclient.Faults {
    world.knobs_ccs = false;
    var faults: testclient.Faults = .{ .ccs = random.uintLessThan(u32, 2) };
    faults.hello.session_id = random.boolean();
    faults.hello.signature_algorithms = if (random.boolean()) .chrome else .other;
    public.alpn = if (random.boolean()) .h2_and_http11 else .absent;
    public.server_name = if (random.boolean()) host else odd_spelling(random, host);
    world.knobs_good = random.boolean();
    if (world.knobs_good) return faults;
    const knob = random.uintLessThan(u32, 18);
    if (knob < 12) {
        // `browser` true: `.other` is ecdsa_secp256r1_sha256 alone, which this path takes.
        fuzz.wrong_hello(random, true, knob, &faults.hello, &world.knobs_good);
        return faults;
    }
    switch (knob) {
        12 => {
            faults.ccs = random.intRangeAtMost(u32, 2, 3);
            world.knobs_ccs = true;
        },
        13 => {
            faults.ccs_byte = random.intRangeAtMost(u8, 2, 255);
            faults.ccs = 1;
            world.knobs_ccs = true;
        },
        14 => {
            faults.finished = random.enumValue(testclient.Finished);
            world.knobs_good = faults.finished == .good;
        },
        15 => {
            const names = [_]?[]const u8{ null, "other.test", "192.0.2.1", "localhost", "test" };
            public.server_name = names[random.uintLessThan(usize, names.len)];
        },
        16 => public.alpn = .h2_only,
        else => public.x25519_without_share = true,
    }
    return faults;
}

/// `host` in upper case, with a trailing dot, or both: the same name to the table.
fn odd_spelling(random: std.Random, host: []const u8) []const u8 {
    const State = struct {
        var buffer: [constants.edge_host_bytes_max + 1]u8 = undefined;
    };
    const upper = random.boolean();
    for (host, 0..) |byte, index| {
        State.buffer[index] = if (upper) std.ascii.toUpper(byte) else byte;
    }
    const dot: usize = if (!upper or random.boolean()) 1 else 0;
    State.buffer[host.len] = '.';
    return State.buffer[0 .. host.len + dot];
}

fn collect(world: *World) void {
    const output = world.server.output();
    @memcpy(world.sent[world.sent_length..][0..output.len], output);
    world.sent_length += @intCast(output.len);
    world.server.drain();
}

/// Feeds `bytes` in random pieces; stops at the first refusal.
fn feed(world: *World, random: std.Random, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + random.intRangeAtMost(usize, 1, 700));
        const before = world.sent_length;
        const step = world.server.receive(bytes[offset..end], &world.diag) catch {
            collect(world);
            return refused(world, before);
        };
        collect(world);
        if (world.server.is_connected() and !world.legit) world.false_connect = true;
        offset += step.consumed;
    }
}

fn refused(world: *World, sent_before: u32) !void {
    world.refused = true;
    try testing.expect(world.diag.code != null);
    try testing.expect(world.diag.last_cause() != null);
    try testing.expect(!world.server.is_connected());
    if (world.sent_length > sent_before) {
        var rest: []u8 = world.sent[sent_before..world.sent_length];
        _ = testclient.take_record(&rest) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), rest.len);
    }
    const more = [_]u8{ 23, 3, 3, 0, 1, 0 };
    try testing.expectError(error.Closed, world.server.receive(&more, &world.diag));
    try testing.expectEqual(@as(usize, 0), world.server.output().len);
}

/// One run; true when the server connected falsely.
pub fn run_once(seed: u64, refusal: *bool) !bool {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const world = try testing.allocator.create(World);
    defer testing.allocator.destroy(world);
    try setup(world, random);
    const hello = world.client.hello(&world.original);
    const hello_kind: Mutation = if (random.uintLessThan(u32, 8) == 0)
        random.enumValue(Mutation)
    else
        .none;
    const hello_length = fuzz.mutate(random, hello_kind, hello, &world.damaged);
    const hello_ccs = fuzz.hello_whole(hello, world.damaged[0..hello_length]);
    if (hello_length > 0) try feed(world, random, world.damaged[0..hello_length]);
    if (!world.refused) try flight_stage(world, random, hello_ccs, hello_kind);
    if (!world.refused and !world.server.is_connected()) {
        const before = world.sent_length;
        if (world.server.end_of_input(&world.diag)) |_| {
            return error.TestUnexpectedResult; // Only close_notify ends a connection quietly.
        } else |_| {
            collect(world);
            try refused(world, before);
        }
    }
    refusal.* = world.refused;
    return world.false_connect;
}

fn flight_stage(world: *World, random: std.Random, hello_ccs: ?u32, hello_kind: Mutation) !void {
    world.client.accept_flight(world.sent[0..world.sent_length]) catch {
        // The server read a hello the client did not send, or took one it must refuse: it must
        // not have produced a flight the client takes.
        try testing.expect(hello_ccs == null or !world.knobs_good);
        return;
    };
    world.sent_length = 0;
    const flight = world.client.flight(&world.original);
    const kind: Mutation = if (random.boolean()) random.enumValue(Mutation) else .none;
    const length = fuzz.mutate(random, kind, flight, &world.damaged);
    const damaged = world.damaged[0..length];
    world.legit = (world.knobs_good or world.knobs_ccs) and hello_ccs != null and
        fuzz.flight_whole(flight, damaged, hello_ccs orelse 0);
    if (length > 0) try feed(world, random, damaged);
    if (hello_kind == .none and kind == .none and world.knobs_good) {
        // A correct client's flight left whole must connect, to the host it asked for.
        try testing.expect(world.server.is_connected());
        try testing.expectEqualStrings(world.host, world.server.server_name().?);
        var record: [256]u8 = undefined;
        var out: [256]u8 = undefined;
        const sealed = world.client.seal(&record, .application_data, "GET / HTTP/1.1\r\n");
        try feed(world, random, sealed);
        const answer = try world.server.seal_application("HTTP/1.1 200 OK\r\n", &out, &world.diag);
        const opened = try world.client.open(answer);
        try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", opened.content);
    }
}

fn fuzz_once(seed: u64) !void {
    var refusal = false;
    try testing.expect(!try run_once(seed, &refusal));
}

test "fuzz: a damaged public client never connects falsely and never crashes" {
    // Goal: the public path connects only to a client that asked for a host the table has, with
    // http/1.1 or no ALPN, and finished over the transcript both sides saw. Method: the public
    // client, correct or wrong in one knob; its hello (an eighth of the runs) or its flight
    // (half) damaged and fed in random pieces. A failure prints the seed.
    try seeds.run("tls server public fuzz", iterations_default, fuzz_once);
}
