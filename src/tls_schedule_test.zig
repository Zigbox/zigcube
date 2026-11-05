//! Tests for `tls_schedule.zig`. The RFC 8448 section 3 trace is the authority: every secret,
//! key and IV the schedule derives, the Finished values and the protection of each record in the
//! trace must come out byte for byte. The rest checks the record layer's refusals, the limits
//! and the key update, which the RFC trace does not reach. No file, clock or environment, so it
//! runs under WASI as well (`core.zig`).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const schedule = @import("tls_schedule.zig");
const vectors = @import("tls_schedule_vectors.zig");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const X25519 = std.crypto.dh.X25519;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// Every byte of a buffer starts as this, so a test that expects bytes written sees a difference.
const fill: u8 = 0xa5;

fn transcript_of(messages: []const []const u8) schedule.Hash {
    var transcript = schedule.Transcript.init();
    for (messages) |message| transcript.add(message);
    return transcript.hash();
}

test "RFC 8448: the x25519 exchange gives the shared secret, from either side" {
    // Goal: the ECDHE input of the trace is what x25519 makes of its keys, so the vectors and the
    // primitives agree before the schedule is blamed. Method: both directions, and the public
    // keys from the private ones.
    const client_public = X25519.recoverPublicKey(vectors.client_private);
    try expectEqualSlices(u8, &vectors.client_public, &client_public);
    const server_public = X25519.recoverPublicKey(vectors.server_private);
    try expectEqualSlices(u8, &vectors.server_public, &server_public);
    const from_client = try X25519.scalarmult(vectors.client_private, vectors.server_public);
    const from_server = try X25519.scalarmult(vectors.server_private, vectors.client_public);
    try expectEqualSlices(u8, &vectors.ecdhe_shared, &from_client);
    try expectEqualSlices(u8, &vectors.ecdhe_shared, &from_server);
}

test "RFC 8448: HkdfLabel is laid out as the RFC's info strings" {
    // Goal: the label bytes, which every derived value depends on, match the trace's `info`
    // fields. Method: the three shapes in it: an empty context (key), a hash context (derived)
    // and the longest label.
    var buffer: [schedule.hkdf_label_bytes_max]u8 = undefined;
    const key_info = schedule.hkdf_label(&buffer, "key", "", 16);
    const label_info = [_]u8{ 0, 0x10, 9, 0x74, 0x6c, 0x73, 0x31, 0x33, 0x20, 0x6b, 0x65, 0x79, 0 };
    try expectEqualSlices(u8, &label_info, key_info);
    const iv_info = schedule.hkdf_label(&buffer, "iv", "", 12);
    try expectEqualSlices(u8, &.{ 0, 0x0c, 8, 't', 'l', 's', '1', '3', ' ', 'i', 'v', 0 }, iv_info);
    const finished_info = schedule.hkdf_label(
        &buffer,
        "finished",
        "",
        32,
    );
    try expectEqualSlices(u8, &.{
        0,   0x20, 0x0e, 't', 'l', 's', '1', '3', ' ',
        'f', 'i',  'n',  'i', 's', 'h', 'e', 'd', 0,
    }, finished_info);
    const hash: schedule.Hash = @splat(7);
    const derived_info = schedule.hkdf_label(
        &buffer,
        "derived",
        &hash,
        32,
    );
    try expectEqual(@as(usize, 49), derived_info.len);
    try expectEqualSlices(u8, &.{ 0, 0x20, 0x0d }, derived_info[0..3]);
    try expectEqual(@as(u8, 32), derived_info[16]);
    try expectEqualSlices(u8, &hash, derived_info[17..]);
}

test "RFC 8448: the schedule, from the early secret to the application secrets" {
    // Goal: each secret of figure 1 equals the trace's. Method: feed the trace's ClientHello and
    // ServerHello to the transcript, its shared secret to the schedule, and compare the
    // transcript hashes and the secrets at every step, in order.
    const hello_hash = transcript_of(&.{ &vectors.client_hello, &vectors.server_hello });
    try expectEqualSlices(u8, &vectors.hello_hash, &hello_hash);

    var state = schedule.Schedule.init();
    try expectEqualSlices(u8, &vectors.early_secret, &state.secret);
    const handshake = try state.to_handshake(&vectors.ecdhe_shared, &hello_hash);
    try expectEqualSlices(u8, &vectors.handshake_secret, &state.secret);
    try expectEqualSlices(u8, &vectors.client_handshake_secret, &handshake.client);
    try expectEqualSlices(u8, &vectors.server_handshake_secret, &handshake.server);

    const finished_hash = transcript_of(&.{
        &vectors.client_hello,         &vectors.server_hello,
        &vectors.encrypted_extensions, &vectors.certificate,
        &vectors.certificate_verify,   &vectors.server_finished,
    });
    try expectEqualSlices(u8, &vectors.server_finished_hash, &finished_hash);
    const application = state.to_application(&finished_hash);
    try expectEqualSlices(u8, &vectors.client_application_secret, &application.client);
    try expectEqualSlices(u8, &vectors.server_application_secret, &application.server);
    // The schedule is spent and wiped: nothing of the master secret stays behind.
    try expectEqualSlices(u8, &@as(schedule.Secret, @splat(0)), &state.secret);
}

test "RFC 8448: the derived secret between the stages" {
    // Goal: the two "derived" values (early to handshake, handshake to master) equal the trace's.
    // Method: derive them directly with the empty-message hash.
    var empty: schedule.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &empty, .{});
    const early = schedule.derive_secret(&vectors.early_secret, "derived", &empty);
    try expectEqualSlices(u8, &vectors.derived_for_handshake, &early);
    const handshake = schedule.derive_secret(&vectors.handshake_secret, "derived", &empty);
    try expectEqualSlices(u8, &vectors.derived_for_master, &handshake);
    const master = std.crypto.kdf.hkdf.HkdfSha256.extract(&handshake, &@as([32]u8, @splat(0)));
    try expectEqualSlices(u8, &vectors.master_secret, &master);
}

test "RFC 8448: traffic keys and IVs, handshake and application, both directions" {
    // Goal: the key and IV derived from each traffic secret equal the trace's. Method: the four
    // pairs the trace prints.
    const pairs = [_]struct { secret: *const schedule.Secret, key: []const u8, iv: []const u8 }{
        .{
            .secret = &vectors.server_handshake_secret,
            .key = &vectors.server_handshake_key,
            .iv = &vectors.server_handshake_iv,
        },
        .{
            .secret = &vectors.client_handshake_secret,
            .key = &vectors.client_handshake_key,
            .iv = &vectors.client_handshake_iv,
        },
        .{
            .secret = &vectors.server_application_secret,
            .key = &vectors.server_application_key,
            .iv = &vectors.server_application_iv,
        },
        .{
            .secret = &vectors.client_application_secret,
            .key = &vectors.client_application_key,
            .iv = &vectors.client_application_iv,
        },
    };
    for (pairs) |pair| {
        const keys = schedule.traffic_keys(pair.secret);
        try expectEqualSlices(u8, pair.key, &keys.key);
        try expectEqualSlices(u8, pair.iv, &keys.iv);
    }
}

test "RFC 8448: Finished keys and verify data, server and client" {
    // Goal: the finished key and the verify_data equal the trace's, and a received value is
    // accepted only if it is whole and exact. Method: the server's over the transcript up to its
    // CertificateVerify, the client's over the one through the server's Finished.
    const server_hash = transcript_of(&.{
        &vectors.client_hello,         &vectors.server_hello,
        &vectors.encrypted_extensions, &vectors.certificate,
        &vectors.certificate_verify,
    });
    const server_data = schedule.finished_verify_data(
        &vectors.server_handshake_secret,
        &server_hash,
    );
    try expectEqualSlices(u8, &vectors.server_finished_data, &server_data);
    const server_key = schedule.expand_label(&vectors.server_handshake_secret, "finished", "", 32);
    try expectEqualSlices(u8, &vectors.server_finished_key, &server_key);
    try expect(
        schedule.finished_matches(&vectors.server_handshake_secret, &server_hash, &server_data),
    );
    // The Finished message is type 20, length 32 and the verify_data.
    try expectEqualSlices(u8, vectors.server_finished[4..], &server_data);

    const client_data = schedule.finished_verify_data(
        &vectors.client_handshake_secret,
        &vectors.server_finished_hash,
    );
    try expectEqualSlices(u8, &vectors.client_finished_data, &client_data);
    const client_key = schedule.expand_label(&vectors.client_handshake_secret, "finished", "", 32);
    try expectEqualSlices(u8, &vectors.client_finished_key, &client_key);
    try expectEqualSlices(u8, vectors.client_finished[4..], &client_data);

    // Negative space: one flipped bit, one byte short and one byte long are all refused.
    var bad = server_data;
    bad[31] ^= 1;
    try expect(!schedule.finished_matches(&vectors.server_handshake_secret, &server_hash, &bad));
    try expect(
        !schedule.finished_matches(
            &vectors.server_handshake_secret,
            &server_hash,
            server_data[0..31],
        ),
    );
    var longer: [33]u8 = undefined;
    @memcpy(longer[0..32], &server_data);
    longer[32] = 0;
    try expect(!schedule.finished_matches(&vectors.server_handshake_secret, &server_hash, &longer));
    // The same data over another transcript does not match either.
    try expect(
        !schedule.finished_matches(
            &vectors.server_handshake_secret,
            &vectors.hello_hash,
            &server_data,
        ),
    );
}

test "CertificateVerify signs 64 spaces, the context, a zero and the hash" {
    // Goal: the signed bytes of RFC 8446 section 4.4.3 for each role. Method: compare every part
    // of the layout; the roles differ in the context string and nothing else.
    const hash: schedule.Hash = @splat(0x42);
    const server = schedule.certificate_verify_content(.server, &hash);
    const client = schedule.certificate_verify_content(.client, &hash);
    try expectEqual(@as(usize, 130), server.len);
    for (server[0..64]) |byte| try expectEqual(@as(u8, 0x20), byte);
    try expectEqualSlices(u8, "TLS 1.3, server CertificateVerify", server[64..97]);
    try expectEqualSlices(u8, "TLS 1.3, client CertificateVerify", client[64..97]);
    try expectEqual(@as(u8, 0), server[97]);
    try expectEqualSlices(u8, &hash, server[98..]);
    try expectEqualSlices(u8, server[0..64], client[0..64]);
    try expectEqualSlices(u8, server[97..], client[97..]);
    try expect(!std.mem.eql(u8, &server, &client));
}

test "zero shared secrets are refused, and the early secret is not spent by it" {
    // Goal: a low-order public key cannot key the schedule. Method: an all-zero ECDHE value.
    var state = schedule.Schedule.init();
    const zero: [32]u8 = @splat(0);
    try expectError(error.ZeroSharedSecret, state.to_handshake(&zero, &vectors.hello_hash));
    try expectEqualSlices(u8, &vectors.early_secret, &state.secret);
    try expect(state.stage == .early);
}

/// Seals `plaintext` with the next record of `direction` and compares it to the trace's record.
fn expect_seals_to(
    direction: *schedule.Direction,
    content_type: schedule.ContentType,
    plaintext: []const u8,
    record: []const u8,
) !void {
    var out: [schedule.sealed_bytes_max]u8 = undefined;
    @memset(&out, fill);
    const sealed = try direction.seal(&out, content_type, plaintext);
    try expectEqualSlices(u8, record, sealed);
}

/// Opens a copy of the trace's record with the next record of `direction` and compares.
fn expect_opens_to(
    direction: *schedule.Direction,
    content_type: schedule.ContentType,
    plaintext: []const u8,
    record: []const u8,
) !void {
    var buffer: [schedule.sealed_bytes_max]u8 = undefined;
    @memset(&buffer, fill);
    @memcpy(buffer[0..record.len], record);
    const opened = try direction.open(buffer[0..record.len]);
    try expect(opened.content_type == content_type);
    try expectEqualSlices(u8, plaintext, opened.content);
}

test "RFC 8448: the server's protected records seal and open to the trace's bytes" {
    // Goal: the server direction (handshake flight, then NewSessionTicket, application data and
    // the close_notify alert) produces and accepts the trace's records, sequence numbers
    // included. Method: one direction per side and key set, sealing and opening each record in
    // order; the application keys' first record is the ticket.
    var sealer = schedule.Direction.init(&vectors.server_handshake_secret);
    try expect_seals_to(
        &sealer,
        .handshake,
        &vectors.server_flight_plaintext,
        &vectors.server_flight_record,
    );
    try expectEqual(@as(u64, 1), sealer.sequence);
    var opener = schedule.Direction.init(&vectors.server_handshake_secret);
    try expect_opens_to(
        &opener,
        .handshake,
        &vectors.server_flight_plaintext,
        &vectors.server_flight_record,
    );

    var sealer_ap = schedule.Direction.init(&vectors.server_application_secret);
    try expect_seals_to(&sealer_ap, .handshake, &vectors.ticket_plaintext, &vectors.ticket_record);
    try expect_seals_to(
        &sealer_ap,
        .application_data,
        &vectors.server_data_plaintext,
        &vectors.server_data_record,
    );
    try expect_seals_to(
        &sealer_ap,
        .alert,
        &vectors.server_alert_plaintext,
        &vectors.server_alert_record,
    );
    var opener_ap = schedule.Direction.init(&vectors.server_application_secret);
    try expect_opens_to(&opener_ap, .handshake, &vectors.ticket_plaintext, &vectors.ticket_record);
    try expect_opens_to(
        &opener_ap,
        .application_data,
        &vectors.server_data_plaintext,
        &vectors.server_data_record,
    );
    try expect_opens_to(
        &opener_ap,
        .alert,
        &vectors.server_alert_plaintext,
        &vectors.server_alert_record,
    );
    try expectEqual(@as(u64, 3), opener_ap.sequence);
}

test "RFC 8448: the client's protected records seal and open to the trace's bytes" {
    // Goal: the client direction: its Finished under the handshake keys, then application data
    // and an alert under the application keys. Method: as for the server.
    var finished = schedule.Direction.init(&vectors.client_handshake_secret);
    try expect_seals_to(
        &finished,
        .handshake,
        &vectors.client_finished,
        &vectors.client_finished_record,
    );
    var finished_in = schedule.Direction.init(&vectors.client_handshake_secret);
    try expect_opens_to(
        &finished_in,
        .handshake,
        &vectors.client_finished,
        &vectors.client_finished_record,
    );

    var sealer = schedule.Direction.init(&vectors.client_application_secret);
    try expect_seals_to(
        &sealer,
        .application_data,
        &vectors.client_data_plaintext,
        &vectors.client_data_record,
    );
    try expect_seals_to(
        &sealer,
        .alert,
        &vectors.client_alert_plaintext,
        &vectors.client_alert_record,
    );
    var opener = schedule.Direction.init(&vectors.client_application_secret);
    try expect_opens_to(
        &opener,
        .application_data,
        &vectors.client_data_plaintext,
        &vectors.client_data_record,
    );
    try expect_opens_to(
        &opener,
        .alert,
        &vectors.client_alert_plaintext,
        &vectors.client_alert_record,
    );
}

test "every single-bit change to a sealed record is refused and kills the direction" {
    // Goal: no flipped bit anywhere in a record (header, body or tag) opens as content, and the
    // direction accepts nothing afterwards. Method: every bit of the trace's 72-byte record in
    // turn, on a fresh direction each time.
    const record = &vectors.server_data_record;
    var flips: u32 = 0;
    for (0..record.len * 8) |bit| {
        var buffer: [72]u8 = undefined;
        @memcpy(&buffer, record);
        buffer[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        var direction = schedule.Direction.init(&vectors.server_application_secret);
        direction.sequence = 1;
        // `open` takes a record framed by its own length field; a flipped length reframes it,
        // and one that no longer fits the 72 bytes is a short read, which the caller never opens.
        const length = std.mem.readInt(u16, buffer[3..5], .big);
        if (schedule.Header.parse(buffer[0..5], .protected)) |_| {} else |_| {
            flips += 1;
            continue;
        }
        if (5 + @as(usize, length) > buffer.len) {
            flips += 1;
            continue;
        }
        if (direction.open(buffer[0 .. 5 + @as(usize, length)])) |_| {
            return error.AFlippedRecordOpened;
        } else |_| {}
        try expect(direction.dead);
        // The good record is refused after the failure, and the sequence did not move.
        var again: [72]u8 = undefined;
        @memcpy(&again, record);
        try expectError(error.Dead, direction.open(&again));
        try expectEqual(@as(u64, 1), direction.sequence);
        flips += 1;
    }
    try expectEqual(@as(u32, 576), flips);
}

test "a record opened at the wrong sequence number or under the wrong keys fails" {
    // Goal: the nonce carries the sequence number and the keys are per direction. Method: the
    // trace's second server record at sequence 0 and 2, and under the client's keys.
    const cases = [_]struct { secret: *const schedule.Secret, sequence: u64 }{
        .{ .secret = &vectors.server_application_secret, .sequence = 0 },
        .{ .secret = &vectors.server_application_secret, .sequence = 2 },
        .{ .secret = &vectors.client_application_secret, .sequence = 1 },
        .{ .secret = &vectors.server_handshake_secret, .sequence = 1 },
    };
    for (cases) |case| {
        var buffer: [72]u8 = undefined;
        @memcpy(&buffer, &vectors.server_data_record);
        var direction = schedule.Direction.init(case.secret);
        direction.sequence = case.sequence;
        try expectError(error.BadRecordMac, direction.open(&buffer));
    }
}

test "headers: lengths, types and the ignored legacy version" {
    // Goal: a header is refused before its body is read when it is oversized or of an unknown
    // type, and the legacy version is passed through, not judged. Method: the boundary on each
    // side of both limits.
    const plain_max = constants.tls_record_plaintext_bytes_max;
    const protected_max = constants.tls_record_ciphertext_bytes_max;
    var bytes = [5]u8{ 22, 3, 3, 0, 0 };
    std.mem.writeInt(u16, bytes[3..5], plain_max, .big);
    const header = try schedule.Header.parse(&bytes, .plain);
    try expectEqual(@as(u16, plain_max), header.length);
    try expect(header.content_type == .handshake);
    std.mem.writeInt(u16, bytes[3..5], plain_max + 1, .big);
    try expectError(error.RecordOverflow, schedule.Header.parse(&bytes, .plain));
    _ = try schedule.Header.parse(&bytes, .protected);
    std.mem.writeInt(u16, bytes[3..5], protected_max, .big);
    _ = try schedule.Header.parse(&bytes, .protected);
    std.mem.writeInt(u16, bytes[3..5], protected_max + 1, .big);
    try expectError(error.RecordOverflow, schedule.Header.parse(&bytes, .protected));

    bytes = .{ 99, 3, 3, 0, 1 };
    try expectError(error.UnexpectedMessage, schedule.Header.parse(&bytes, .plain));
    bytes = .{ 23, 0x12, 0x34, 0, 1 };
    const odd = try schedule.Header.parse(&bytes, .protected);
    try expectEqual(@as(u16, 0x1234), odd.legacy_version);
}

test "a protected record with an overlong length is refused as an overflow" {
    // Goal: record_overflow for a body past 2^14 + 256 even when the buffer holds it. Method: a
    // header claiming one byte too many, then a body of exactly the maximum that does not
    // authenticate (an authentication failure, not an overflow).
    var buffer: [schedule.sealed_bytes_max + 1]u8 = undefined;
    @memset(&buffer, fill);
    buffer[0] = 23;
    buffer[1] = 3;
    buffer[2] = 3;
    std.mem.writeInt(u16, buffer[3..5], constants.tls_record_ciphertext_bytes_max + 1, .big);
    var direction = schedule.Direction.init(&vectors.server_application_secret);
    try expectError(error.RecordOverflow, direction.open(&buffer));
    try expect(direction.dead);

    var direction_max = schedule.Direction.init(&vectors.server_application_secret);
    std.mem.writeInt(u16, buffer[3..5], constants.tls_record_ciphertext_bytes_max, .big);
    try expectError(error.BadRecordMac, direction_max.open(buffer[0..schedule.sealed_bytes_max]));
}

/// Builds a record the way an adversary or a peer with padding would: any inner bytes.
fn forge(direction: *const schedule.Direction, out: []u8, inner: []const u8) []u8 {
    const body_len = inner.len + schedule.tag_bytes;
    out[0] = 23;
    out[1] = 3;
    out[2] = 3;
    std.mem.writeInt(u16, out[3..5], @intCast(body_len), .big);
    @memcpy(out[5..][0..inner.len], inner);
    Aes128Gcm.encrypt(
        out[5..][0..inner.len],
        out[5 + inner.len ..][0..schedule.tag_bytes],
        inner,
        out[0..5],
        direction.nonce(),
        direction.keys.key,
    );
    return out[0 .. 5 + body_len];
}

test "padding is stripped; a record of nothing but padding, or of an unknown type, is refused" {
    // Goal: RFC 8446 section 5.4: zeros after the inner type are padding, an all-zero inner
    // plaintext is `unexpected_message`, and so is a type that is not one of the four. Method:
    // forge records with the same keys and open them on a fresh direction.
    var out: [64]u8 = undefined;
    const peer = schedule.Direction.init(&vectors.client_application_secret);

    var direction = schedule.Direction.init(&vectors.client_application_secret);
    const padded = forge(&peer, &out, &.{ 'h', 'i', 23, 0, 0, 0, 0 });
    const opened = try direction.open(padded);
    try expect(opened.content_type == .application_data);
    try expectEqualSlices(u8, "hi", opened.content);

    var empty = schedule.Direction.init(&vectors.client_application_secret);
    const none = forge(&peer, &out, &.{22});
    const opened_empty = try empty.open(none);
    try expectEqual(@as(usize, 0), opened_empty.content.len);

    var zeros = schedule.Direction.init(&vectors.client_application_secret);
    try expectError(error.UnexpectedMessage, zeros.open(forge(&peer, &out, &.{ 0, 0, 0 })));
    var unknown = schedule.Direction.init(&vectors.client_application_secret);
    try expectError(error.UnexpectedMessage, unknown.open(forge(&peer, &out, &.{ 'x', 99 })));
    var short = schedule.Direction.init(&vectors.client_application_secret);
    const body: [16]u8 = @splat(fill);
    const header_only = [_]u8{ 23, 3, 3, 0, 16 } ++ body;
    var copy = header_only;
    try expectError(error.DecodeError, short.open(&copy));
}

test "content of 2^14 bytes seals; one more byte in the inner text is an overflow" {
    // Goal: the plaintext bound of RFC 8446 section 5.4: content past 2^14 is `record_overflow`
    // even when the tag verifies. Method: a full record round trip, then a forged record whose
    // content is one byte over.
    var sealer = schedule.Direction.init(&vectors.client_application_secret);
    var opener = schedule.Direction.init(&vectors.client_application_secret);
    var content: [constants.tls_record_plaintext_bytes_max]u8 = undefined;
    for (&content, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    var out: [schedule.sealed_bytes_max]u8 = undefined;
    @memset(&out, fill);
    const record = try sealer.seal(&out, .application_data, &content);
    try expectEqual(@as(usize, constants.tls_record_plaintext_bytes_max + 5 + 1 + 16), record.len);
    const opened = try opener.open(record);
    try expectEqualSlices(u8, &content, opened.content);

    var big: [constants.tls_record_plaintext_bytes_max + 2]u8 = undefined;
    @memset(&big, 'z');
    big[big.len - 1] = 23;
    var forged: [schedule.sealed_bytes_max + 8]u8 = undefined;
    const peer = schedule.Direction.init(&vectors.client_application_secret);
    var direction = schedule.Direction.init(&vectors.client_application_secret);
    try expectError(error.RecordOverflow, direction.open(forge(&peer, &forged, &big)));
}

test "round trips of every length class, both ways, with the sequence in step" {
    // Goal: seal and open are inverses for contents of 0, 1, block-boundary and maximum sizes,
    // over 300 records, each of the three content types, and the sequences stay equal. Method: a
    // fixed generator (this is a table, not a fuzzer; tls_fuzz.zig draws from seeds).
    var sealer = schedule.Direction.init(&vectors.server_application_secret);
    var opener = schedule.Direction.init(&vectors.server_application_secret);
    var prng = std.Random.DefaultPrng.init(0x7154_5c4e);
    const sizes = [_]usize{
        0, 1, 15, 16, 17, 255, 256, 1000, constants.tls_record_plaintext_bytes_max,
    };
    const types = [_]schedule.ContentType{ .handshake, .application_data, .alert };
    var content: [constants.tls_record_plaintext_bytes_max]u8 = undefined;
    var out: [schedule.sealed_bytes_max]u8 = undefined;
    for (0..300) |index| {
        const size = sizes[index % sizes.len];
        prng.random().bytes(content[0..size]);
        const content_type = types[index % types.len];
        @memset(&out, fill);
        const record = try sealer.seal(&out, content_type, content[0..size]);
        try expectEqual(schedule.sealed_bytes(size), record.len);
        const opened = try opener.open(record);
        try expect(opened.content_type == content_type);
        try expectEqualSlices(u8, content[0..size], opened.content);
        try expectEqual(sealer.sequence, opener.sequence);
    }
    try expectEqual(@as(u64, 300), sealer.sequence);
}

fn key_update_message() [schedule.key_update_bytes]u8 {
    return .{ schedule.key_update_type, 0, 0, 1, 0 };
}

test "KeyUpdate: both ends reach the same new keys, and the old ones stop working" {
    // Goal: RFC 8446 section 7.2: the next secret is HKDF-Expand-Label(secret, "traffic upd"),
    // the sequence restarts at zero, and a record under the old keys fails afterwards. Method: a
    // sender and a receiver, one update, then a record each way.
    var sender = schedule.Direction.init(&vectors.client_application_secret);
    var receiver = schedule.Direction.init(&vectors.client_application_secret);
    var out: [64]u8 = undefined;
    @memset(&out, fill);
    const message = key_update_message();
    const update = try sender.seal(&out, .handshake, &message);
    const opened = try receiver.open(update);
    try expect(opened.content_type == .handshake);
    try expectEqualSlices(u8, &message, opened.content);
    try sender.rekey();
    try receiver.rekey();

    const expected = schedule.expand_label(
        &vectors.client_application_secret,
        "traffic upd",
        "",
        32,
    );
    try expectEqualSlices(u8, &expected, &sender.secret);
    try expectEqual(@as(u64, 0), sender.sequence);
    try expectEqual(@as(u32, 1), sender.updates);
    try expectEqualSlices(u8, &sender.keys.key, &receiver.keys.key);
    const old_keys = schedule.traffic_keys(&vectors.client_application_secret);
    try expect(!std.mem.eql(u8, &old_keys.key, &sender.keys.key));

    var stale = schedule.Direction.init(&vectors.client_application_secret);
    stale.sequence = 0;
    var data: [64]u8 = undefined;
    const record = try sender.seal(&data, .application_data, "after");
    var copy: [64]u8 = undefined;
    @memcpy(copy[0..record.len], record);
    try expectError(error.BadRecordMac, stale.open(copy[0..record.len]));
    const fresh = try receiver.open(record);
    try expectEqualSlices(u8, "after", fresh.content);
}

test "the record limit allows exactly one KeyUpdate and nothing else" {
    // Goal: at tls_records_per_key_max the direction is due; the one record allowed is the
    // KeyUpdate, sealed or opened, and the one after is refused. Method: set the sequence at the
    // edge and walk across it for each of: data, a handshake message that is not a KeyUpdate and
    // a KeyUpdate.
    const limit = constants.tls_records_per_key_max;
    var out: [64]u8 = undefined;
    var direction = schedule.Direction.init(&vectors.client_application_secret);
    direction.sequence = limit - 1;
    try expect(!direction.update_due());
    _ = try direction.seal(&out, .application_data, "last data");
    try expect(direction.update_due());
    try expectError(error.KeyLimit, direction.seal(&out, .application_data, "one too many"));
    try expectError(error.KeyLimit, direction.seal(&out, .handshake, &.{ 20, 0, 0, 1, 0 }));
    try expectError(error.KeyLimit, direction.seal(&out, .handshake, &.{ 24, 0, 0, 1 }));
    try expectEqual(limit, direction.sequence);
    const message = key_update_message();
    const update = try direction.seal(&out, .handshake, &message);
    try expectEqual(limit + 1, direction.sequence);
    try expectError(error.KeyLimit, direction.seal(&out, .handshake, &message));

    // The receiver at the same edge accepts the KeyUpdate and then refuses anything else.
    var receiver = schedule.Direction.init(&vectors.client_application_secret);
    receiver.sequence = limit;
    var copy: [64]u8 = undefined;
    @memcpy(copy[0..update.len], update);
    var sender = schedule.Direction.init(&vectors.client_application_secret);
    sender.sequence = limit;
    const sealed_data = try sender.seal(&out, .handshake, &message);
    @memcpy(copy[0..sealed_data.len], sealed_data);
    _ = try receiver.open(copy[0..sealed_data.len]);
    try receiver.rekey();
    try expect(!receiver.update_due());

    var data_receiver = schedule.Direction.init(&vectors.client_application_secret);
    data_receiver.sequence = limit;
    var data_sender = schedule.Direction.init(&vectors.client_application_secret);
    data_sender.sequence = limit;
    var data_out: [64]u8 = undefined;
    // A sender that ignored the limit: forged, since seal() would refuse.
    const forged = forge(&data_sender, &data_out, &.{ 'd', 23 });
    try expectError(error.KeyLimit, data_receiver.open(forged));
    try expect(data_receiver.dead);
}

test "key updates are counted and a peer that never stops is refused" {
    // Goal: tls_key_updates_per_connection_max bounds a direction's updates; the update past it
    // fails and the direction is dead. Method: set the counter at the edge.
    var direction = schedule.Direction.init(&vectors.server_application_secret);
    direction.updates = constants.tls_key_updates_per_connection_max - 1;
    try direction.rekey();
    try expectEqual(constants.tls_key_updates_per_connection_max, direction.updates);
    try expectError(error.TooManyKeyUpdates, direction.rekey());
    try expect(direction.dead);
    var out: [64]u8 = undefined;
    try expectError(error.Dead, direction.seal(&out, .application_data, "x"));
    try expectError(error.Dead, direction.rekey());
}

test "wipe zeroes the secret and the keys and kills the direction" {
    // Goal: a finished direction leaves no key material behind. Method: wipe, then look.
    var direction = schedule.Direction.init(&vectors.server_application_secret);
    try expect(!std.mem.allEqual(u8, &direction.secret, 0));
    direction.wipe();
    try expect(std.mem.allEqual(u8, &direction.secret, 0));
    try expect(std.mem.allEqual(u8, &direction.keys.key, 0));
    try expect(std.mem.allEqual(u8, &direction.keys.iv, 0));
    var out: [64]u8 = undefined;
    try expectError(error.Dead, direction.seal(&out, .application_data, "x"));
}

test "plain records carry the header and the content, nothing else" {
    // Goal: write_plain frames an unprotected record (the ClientHello) and its header parses
    // back. Method: write, parse, compare.
    var out: [64]u8 = undefined;
    @memset(&out, fill);
    const record = schedule.write_plain(&out, .handshake, 0x0301, "hello");
    try expectEqualSlices(u8, &.{ 22, 3, 1, 0, 5, 'h', 'e', 'l', 'l', 'o' }, record);
    const header = try schedule.Header.parse(record[0..5], .plain);
    try expectEqual(@as(u16, 5), header.length);
    try expectEqual(@as(u16, 0x0301), header.legacy_version);
    try expectEqual(@as(u8, fill), out[record.len]);
}
