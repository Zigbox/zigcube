//! A seeded fuzzer for the TLS server's handshake (`tls_server.zig`, docs/mtls.md): a scripted
//! client (`tls_testclient.zig`) sends a ClientHello and a last flight, either correct or wrong in
//! one of its knobs (the hello's, the chain, the CertificateVerify, the Finished, the context, the
//! records around them), and in a part of the runs the hello or the flight is then damaged at the
//! record level in one of eleven ways and fed to the server in pieces of random size. A flight
//! that connects is followed by a random script of data and KeyUpdates both ways.
//!
//! The properties: no crash; the server is `connected` (at any step) only when the hello reached
//! it whole, the knobs were all correct, and the records it read up to its connect were the
//! client's protected records in order with at most one well-formed change_cipher_spec among them
//! (a correct client's flight left whole always connects); every refusal carries a code and a
//! cause; after a refusal the server writes nothing more than the one alert and reads nothing.
//! Seeds and replay are in `fuzz_seeds.zig`.

const std = @import("std");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const seeds = @import("fuzz_seeds.zig");
const schedule = @import("tls_schedule.zig");
const testclient = @import("tls_testclient.zig");
const tls_server = @import("tls_server.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const assert = std.debug.assert;
const testing = std.testing;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

const iterations_default = 400;
const server_name = "broker.botpike.com";
const buffer_bytes = 3 * constants.tls_handshake_flight_bytes_max;
const header_bytes = constants.tls_record_header_bytes;
const records_max = 32;
const content_ccs: u8 = @backingInt(schedule.ContentType.change_cipher_spec);

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
    /// A change_cipher_spec record at a random record boundary.
    insert_ccs,
};

const World = struct {
    server: tls_server.Server,
    client: testclient.Client,
    diag: Diag,
    ca: Ed25519.KeyPair,
    server_key: Ed25519.KeyPair,
    server_certificate: x509.Der,
    ca_certificate: x509.Der,
    chain: [2][]const u8,
    sent: [buffer_bytes]u8,
    sent_length: u32,
    original: [buffer_bytes]u8,
    damaged: [buffer_bytes]u8,
    /// The client's knobs are all correct (or only those a server must take: no session id, no
    /// change_cipher_spec, one record per message).
    knobs_good: bool,
    /// The one wrong knob is in the flight's change_cipher_spec records (too many, or a wrong
    /// byte), which `flight_whole` judges from the bytes sent: a damage that cuts or mends such a
    /// record leaves a flight the server must take.
    knobs_ccs: bool,
    /// What the server may connect to: set before the flight is fed.
    legit: bool,
    false_connect: bool,
    refused: bool,
    data_events: u32,
};

/// The offsets of the whole records of `bytes`: `starts[i]..starts[i + 1]`.
fn record_starts(bytes: []const u8, starts: *[records_max + 1]u32) u32 {
    var count: u32 = 0;
    var offset: usize = 0;
    while (offset + header_bytes <= bytes.len and count < records_max) {
        const total = header_bytes + std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .big);
        if (offset + total > bytes.len) break;
        starts[count] = @intCast(offset);
        count += 1;
        offset += total;
    }
    starts[count] = @intCast(offset);
    return count;
}

fn copy_records(out: []u8, bytes: []const u8, starts: []const u32, order: []const u32) usize {
    var length: usize = 0;
    for (order) |index| {
        const piece = bytes[starts[index]..starts[index + 1]];
        @memcpy(out[length..][0..piece.len], piece);
        length += piece.len;
    }
    return length;
}

/// Writes `bytes` damaged by `kind` into `out` and returns its length.
fn mutate(random: std.Random, kind: Mutation, bytes: []const u8, out: []u8) usize {
    var starts: [records_max + 1]u32 = undefined;
    const count = record_starts(bytes, &starts);
    var order: [records_max + 1]u32 = undefined;
    for (0..count) |index| order[index] = @intCast(index);
    const at = random.uintLessThan(u32, count + 1);
    switch (kind) {
        .none => {
            @memcpy(out[0..bytes.len], bytes);
            return bytes.len;
        },
        .flip_bit, .overlong_header, .random_bytes => {
            @memcpy(out[0..bytes.len], bytes);
            damage_bytes(random, kind, out[0..bytes.len], &starts, count);
            return bytes.len;
        },
        .truncate => {
            const length = random.uintLessThan(usize, bytes.len);
            @memcpy(out[0..length], bytes[0..length]);
            return length;
        },
        .drop_record => {
            if (count == 0) return 0;
            const drop = random.uintLessThan(u32, count);
            std.mem.copyForwards(u32, order[drop .. count - 1], order[drop + 1 .. count]);
            return copy_records(out, bytes, &starts, order[0 .. count - 1]);
        },
        .duplicate_record => {
            if (count == 0) return 0;
            const twice = random.uintLessThan(u32, count);
            std.mem.copyBackwards(u32, order[at + 1 .. count + 1], order[at..count]);
            order[at] = twice;
            return copy_records(out, bytes, &starts, order[0 .. count + 1]);
        },
        .swap_records => {
            if (count < 2) return copy_records(out, bytes, &starts, order[0..count]);
            const first = random.uintLessThan(u32, count);
            const second = random.uintLessThan(u32, count);
            std.mem.swap(u32, &order[first], &order[second]);
            return copy_records(out, bytes, &starts, order[0..count]);
        },
        .insert_alert, .insert_random_record, .insert_ccs => {
            const before = copy_records(out, bytes, &starts, order[0..at]);
            const extra = extra_record(random, kind, out[before..]);
            const after = copy_records(out[before + extra ..], bytes, &starts, order[at..count]);
            return before + extra + after;
        },
    }
}

fn damage_bytes(
    random: std.Random,
    kind: Mutation,
    out: []u8,
    starts: *const [records_max + 1]u32,
    count: u32,
) void {
    if (out.len == 0) return;
    switch (kind) {
        .flip_bit => {
            const index = random.uintLessThan(usize, out.len);
            out[index] ^= @as(u8, 1) << random.int(u3);
        },
        .overlong_header => {
            if (count == 0) return;
            const start = starts[random.uintLessThan(u32, count)];
            const length = random.intRangeAtMost(u16, 0x4000, 0xffff);
            std.mem.writeInt(u16, out[start + 3 ..][0..2], length, .big);
        },
        .random_bytes => {
            const start = random.uintLessThan(usize, out.len);
            const length = @min(out.len - start, random.intRangeAtMost(usize, 1, 16));
            random.bytes(out[start..][0..length]);
        },
        else => unreachable, // `mutate` passes only these three.
    }
}

fn extra_record(random: std.Random, kind: Mutation, out: []u8) usize {
    var body: [64]u8 = undefined;
    const content: []const u8 = switch (kind) {
        .insert_alert => blk: {
            body[0] = 2;
            body[1] = random.int(u8);
            break :blk body[0..2];
        },
        .insert_ccs => blk: {
            body[0] = if (random.uintLessThan(u8, 4) == 0) random.int(u8) else 1;
            break :blk body[0..1];
        },
        else => blk: {
            const length = random.uintLessThan(usize, body.len);
            random.bytes(body[0..length]);
            break :blk body[0..length];
        },
    };
    const content_type: schedule.ContentType = switch (kind) {
        .insert_alert => .alert,
        .insert_ccs => .change_cipher_spec,
        else => random.enumValue(schedule.ContentType),
    };
    return schedule.write_plain(out, content_type, 0x0303, content).len;
}

/// Two records alike to the server: the same type and body (a plaintext record's version is not
/// read; a protected record's is authenticated, so a changed one cannot pass for its original).
fn same_record(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a[0] != b[0]) return false;
    return std.mem.eql(u8, a[header_bytes..], b[header_bytes..]);
}

fn is_good_ccs(record: []const u8) bool {
    return record[0] == content_ccs and record.len == header_bytes + 1 and
        record[header_bytes] == 1;
}

/// The hello the server read is the client's: the same records, the same order, then at most
/// one well-formed change_cipher_spec (which a client may send before its flight) and nothing
/// else. Returns how many change_cipher_spec records followed, or null when the hello is not whole.
fn hello_whole(original: []const u8, damaged: []const u8) ?u32 {
    var original_starts: [records_max + 1]u32 = undefined;
    var damaged_starts: [records_max + 1]u32 = undefined;
    const count = record_starts(original, &original_starts);
    const damaged_count = record_starts(damaged, &damaged_starts);
    if (damaged_count < count) return null;
    if (damaged_starts[damaged_count] != damaged.len) return null;
    for (0..count) |index| {
        const a = original[original_starts[index]..original_starts[index + 1]];
        const b = damaged[damaged_starts[index]..damaged_starts[index + 1]];
        if (!same_record(a, b)) return null;
    }
    const ccs = damaged_count - count;
    if (ccs > constants.tls_change_cipher_spec_records_max) return null;
    for (count..damaged_count) |index| {
        if (!is_good_ccs(damaged[damaged_starts[index]..damaged_starts[index + 1]])) return null;
    }
    return ccs;
}

/// The records of `damaged` begin with the protected records of `original`, in order, with at
/// most one well-formed change_cipher_spec among them and the `ccs_before` the hello carried,
/// and nothing else.
fn flight_whole(original: []const u8, damaged: []const u8, ccs_before: u32) bool {
    var original_starts: [records_max + 1]u32 = undefined;
    var damaged_starts: [records_max + 1]u32 = undefined;
    const original_count = record_starts(original, &original_starts);
    const damaged_count = record_starts(damaged, &damaged_starts);
    var next: u32 = 0;
    var ccs_seen: u32 = ccs_before;
    for (0..damaged_count) |index| {
        while (next < original_count and original[original_starts[next]] == content_ccs) {
            next += 1;
        }
        if (next == original_count) return true;
        const record = damaged[damaged_starts[index]..damaged_starts[index + 1]];
        if (record[0] == content_ccs) {
            if (!is_good_ccs(record)) return false;
            ccs_seen += 1;
            if (ccs_seen > constants.tls_change_cipher_spec_records_max) return false;
            continue;
        }
        const expected = original[original_starts[next]..original_starts[next + 1]];
        if (!same_record(expected, record)) return false;
        next += 1;
    }
    while (next < original_count and original[original_starts[next]] == content_ccs) next += 1;
    return next == original_count;
}

fn setup(world: *World, random: std.Random) !void {
    world.diag.reset();
    world.ca = try x509_test.ca_pair();
    world.server_key = try Ed25519.KeyPair.generateDeterministic(@splat(0x21));
    try x509.issue_server(&world.server_certificate, world.ca, &.{
        .dns_name = server_name,
        .subject_key = world.server_key.public_key.toBytes(),
        .lifetime = x509_test.window,
    });
    try x509.issue_ca(&world.ca_certificate, world.ca, x509_test.window);
    world.chain = .{ world.server_certificate.slice(), world.ca_certificate.slice() };
    var server_random: [32]u8 = undefined;
    var server_secret: [32]u8 = undefined;
    random.bytes(&server_random);
    random.bytes(&server_secret);
    world.server.init(&.{
        .anchor = world.ca.public_key.toBytes(),
        .now_ms = x509_test.now,
        .random = server_random,
        .secret = server_secret,
        .identity = .{
            .certificates = &world.chain,
            .signer = tls_server.key_pair_signer(&world.server_key),
        },
        .client_kinds = .initOne(.workload),
    });
    var client_random: [32]u8 = undefined;
    var client_secret: [32]u8 = undefined;
    random.bytes(&client_random);
    random.bytes(&client_secret);
    const faults = random_faults(random, &world.knobs_good, &world.knobs_ccs);
    try world.client.init(.{
        .ca = world.ca,
        .random = client_random,
        .secret = client_secret,
        .faults = faults,
    });
    world.sent_length = 0;
    world.false_connect = false;
    world.refused = false;
    world.legit = false;
    world.data_events = 0;
}

/// The client's knobs: those a server must take drawn freely; in half the runs one more is
/// wrong, which no server may take.
fn random_faults(random: std.Random, good: *bool, ccs_only: *bool) testclient.Faults {
    ccs_only.* = false;
    var faults: testclient.Faults = .{
        .ccs = random.uintLessThan(u32, 2),
        .one_record = random.boolean(),
    };
    faults.hello.session_id = random.boolean();
    good.* = random.boolean();
    if (good.*) return faults;
    // A wrong knob drawn as its correct value (a key of 32 bytes, a `good` enum) changes nothing.
    switch (random.uintLessThan(u32, 21)) {
        0 => faults.hello.tls13 = false,
        1 => faults.hello.extensions = false,
        2 => faults.hello.suite = false,
        3 => faults.hello.x25519 = false,
        4 => {
            faults.hello.key_bytes = random.uintLessThan(u16, 64);
            good.* = faults.hello.key_bytes == 32;
        },
        5 => faults.hello.low_order = true,
        6 => faults.hello.signature_algorithms = if (random.boolean()) .other else .absent,
        7 => faults.hello.compression = random.intRangeAtMost(u8, 1, 255),
        8 => faults.hello.duplicate = true,
        9 => faults.hello.early_data = true,
        10 => faults.hello.psk_not_last = true,
        11 => faults.hello.duplicate_group = true,
        12 => {
            faults.ccs = random.intRangeAtMost(u32, 2, 3);
            ccs_only.* = true;
        },
        13 => {
            // A wrong byte matters only in a change_cipher_spec that is sent.
            faults.ccs_byte = random.intRangeAtMost(u8, 2, 255);
            faults.ccs = 1;
            ccs_only.* = true;
        },
        14 => {
            faults.chain = random.enumValue(testclient.Chain);
            good.* = faults.chain == .good;
        },
        15 => faults.context = "x",
        16 => {
            // A high S is a valid ECDSA signature the browser path accepts, and changes nothing
            // on the Ed25519 path: neither is a fault.
            faults.verify = random.enumValue(testclient.Verify);
            good.* = faults.verify == .good or faults.verify == .high_s;
        },
        17 => {
            faults.finished = random.enumValue(testclient.Finished);
            good.* = faults.finished == .good;
        },
        18 => {
            // Bytes behind the Finished in its own record; in a record of their own they are a
            // KeyUpdate after the handshake, which is no fault.
            faults.trailing = true;
            faults.one_record = true;
        },
        19 => faults.early_application_data = true,
        else => faults.swapped = true,
    }
    return faults;
}

fn collect(world: *World) void {
    const output = world.server.output();
    @memcpy(world.sent[world.sent_length..][0..output.len], output);
    world.sent_length += @intCast(output.len);
    world.server.drain();
}

/// Feeds `bytes` in random pieces. Stops at the first refusal, which must carry a code, a cause
/// and at most one record of alert, and after which the server reads nothing.
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
        if (step.event == .data) world.data_events += 1;
    }
}

fn refused(world: *World, sent_before: u32) !void {
    world.refused = true;
    try testing.expect(world.diag.code != null);
    try testing.expect(world.diag.last_cause() != null);
    try testing.expect(!world.server.is_connected());
    const alert = world.sent[sent_before..world.sent_length];
    if (alert.len > 0) {
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
    const hello_length = mutate(random, hello_kind, hello, &world.damaged);
    const hello_ccs = hello_whole(hello, world.damaged[0..hello_length]);
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
        // The server read a hello the client did not send, or refused the hello in the client's
        // terms (the knobs): it must not have produced a flight the client takes.
        try testing.expect(hello_ccs == null or !world.knobs_good);
        return;
    };
    world.sent_length = 0;
    const flight = world.client.flight(&world.original);
    const kind: Mutation = if (random.boolean()) random.enumValue(Mutation) else .none;
    const length = mutate(random, kind, flight, &world.damaged);
    const damaged = world.damaged[0..length];
    world.legit = (world.knobs_good or world.knobs_ccs) and hello_ccs != null and
        flight_whole(flight, damaged, hello_ccs orelse 0);
    if (length > 0) try feed(world, random, damaged);
    const whole = hello_kind == .none and kind == .none and world.knobs_good;
    if (whole) {
        // A correct client's flight left whole must connect.
        try testing.expect(world.server.is_connected());
        try after_connect(world, random);
    }
}

/// A random script of data and KeyUpdates both ways: data must arrive, a KeyUpdate that asks
/// must be answered and one that does not must not, and the server's records must open under
/// the client's keys as they move.
fn after_connect(world: *World, random: std.Random) !void {
    var record: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var plain: [64]u8 = undefined;
    const steps = random.intRangeAtMost(u32, 1, 8);
    for (0..steps) |_| {
        world.sent_length = 0;
        const length = random.intRangeAtMost(usize, 1, plain.len);
        random.bytes(plain[0..length]);
        switch (random.uintLessThan(u32, 4)) {
            0 => {
                const events = world.data_events;
                const sealed = world.client.seal(&record, .application_data, plain[0..length]);
                try feed(world, random, sealed);
                try testing.expectEqual(events + 1, world.data_events);
            },
            1 => {
                const request = random.boolean();
                try feed(world, random, world.client.key_update(&record, request));
                if (!request) {
                    try testing.expectEqual(@as(u32, 0), world.sent_length);
                    continue;
                }
                const answer = try world.client.open(world.sent[0..world.sent_length]);
                try testing.expectEqual(schedule.ContentType.handshake, answer.content_type);
                try testing.expectEqualSlices(u8, &.{ 24, 0, 0, 1, 0 }, answer.content);
                try world.client.read.rekey();
            },
            2 => {
                const sealed =
                    try world.server.seal_application(plain[0..length], &out, &world.diag);
                const opened = try world.client.open(sealed);
                try testing.expectEqualSlices(u8, plain[0..length], opened.content);
            },
            else => {
                try world.server.send_key_update(false, &world.diag);
                collect(world);
                const update = try world.client.open(world.sent[0..world.sent_length]);
                try testing.expectEqual(schedule.ContentType.handshake, update.content_type);
                try world.client.read.rekey();
            },
        }
        try testing.expect(world.server.is_connected());
        try testing.expect(!world.refused);
    }
}

fn fuzz_once(seed: u64) !void {
    var refusal = false;
    try testing.expect(!try run_once(seed, &refusal));
}

test "fuzz: a damaged client flight never connects falsely and never crashes" {
    // Goal: the server connects only to a client that holds a certificate the CA signed and its
    // key, over the transcript both sides saw. Method: a scripted client, correct or wrong in one
    // knob; its hello (an eighth of the runs) or its flight (half) damaged in one of eleven ways
    // and fed in random pieces. A failure prints the seed.
    try seeds.run("tls server fuzz", iterations_default, fuzz_once);
}

test "fuzz: the record oracle" {
    // Goal: the fuzzer's own judge of a whole flight is right, so a false connect it reports is
    // one. Method: a two-record flight with a change_cipher_spec, against each way it can differ.
    var flight: [64]u8 = undefined;
    var length: usize = schedule.write_plain(&flight, .change_cipher_spec, 0x0303, &.{1}).len;
    length += schedule.write_plain(flight[length..], .application_data, 0x0303, "abc").len;
    const original = flight[0..length];
    try testing.expect(flight_whole(original, original, 0));
    try testing.expect(flight_whole(original, original[header_bytes + 1 ..], 0));
    var copy: [64]u8 = undefined;
    @memcpy(copy[0..length], original);
    copy[length - 1] ^= 1;
    try testing.expect(!flight_whole(original, copy[0..length], 0));
    @memcpy(copy[0..length], original);
    copy[1] ^= 1; // A change_cipher_spec's version is not read.
    try testing.expect(flight_whole(original, copy[0..length], 0));
    copy[header_bytes] = 2;
    try testing.expect(!flight_whole(original, copy[0..length], 0));
    var twice: [64]u8 = undefined;
    const ccs_bytes = header_bytes + 1;
    @memcpy(twice[0..ccs_bytes], original[0..ccs_bytes]);
    @memcpy(twice[ccs_bytes..][0..length], original);
    try testing.expect(!flight_whole(original, twice[0 .. ccs_bytes + length], 0));
    try testing.expect(!flight_whole(original, original[0 .. length - 1], 0));
    // A change_cipher_spec the hello carried counts against the flight's.
    try testing.expect(!flight_whole(original, original, 1));
    try testing.expect(flight_whole(original, original[header_bytes + 1 ..], 1));
}

test "fuzz: the hello oracle" {
    // Goal: a hello followed by one good change_cipher_spec is whole, as the server reads it.
    // Method: a one-record hello against each tail it can carry.
    var hello: [64]u8 = undefined;
    var length: usize = schedule.write_plain(&hello, .handshake, 0x0301, "abc").len;
    const original = hello[0..length];
    try testing.expectEqual(@as(?u32, 0), hello_whole(original, original));
    try testing.expectEqual(@as(?u32, null), hello_whole(original, original[0 .. length - 1]));
    length += schedule.write_plain(hello[length..], .change_cipher_spec, 0x0303, &.{1}).len;
    try testing.expectEqual(@as(?u32, 1), hello_whole(original, hello[0..length]));
    const one = length;
    length += schedule.write_plain(hello[length..], .change_cipher_spec, 0x0303, &.{1}).len;
    try testing.expectEqual(@as(?u32, null), hello_whole(original, hello[0..length]));
    hello[one - 1] = 2;
    try testing.expectEqual(@as(?u32, null), hello_whole(original, hello[0..one]));
}
