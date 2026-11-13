//! Tests for the TLS 1.3 server handshake (`tls_server.zig`): against the real client in
//! `tls_client.zig`, and against the scripted client in `tls_testclient.zig` for the near misses
//! and the teeth. Core code: runs under WASI too.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const schedule = @import("tls_schedule.zig");
const tls_client = @import("tls_client.zig");
const tls_server = @import("tls_server.zig");
const testclient = @import("tls_testclient.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");

const Diag = diag_mod.Diag;
const Code = @import("diag/codes.zig").Code;
const Ed25519 = std.crypto.sign.Ed25519;
const Event = tls_server.Event;

const server_name = "broker.botpike.com";
const buffer_bytes = 3 * constants.tls_handshake_flight_bytes_max;

/// A server, a scripted client and the bytes between them.
const Rig = struct {
    server: tls_server.Server,
    client: testclient.Client,
    diag: Diag,
    ca: Ed25519.KeyPair,
    server_key: Ed25519.KeyPair,
    server_certificate: x509.Der,
    ca_certificate: x509.Der,
    chain: [2][]const u8,
    /// What the server sent.
    sent: [buffer_bytes]u8,
    sent_length: u32,
    /// What the client sends next.
    input: [buffer_bytes]u8,
    /// Data events the server passed on.
    data_events: u32,

    fn setup(rig: *Rig, faults: testclient.Faults) !void {
        try rig.setup_server(.workload);
        try rig.client.init(.{ .ca = rig.ca, .faults = faults });
    }

    fn setup_server(rig: *Rig, kind: x509.Kind) !void {
        rig.diag.reset();
        rig.ca = try x509_test.ca_pair();
        rig.server_key = try Ed25519.KeyPair.generateDeterministic(@splat(0x21));
        try x509.issue_server(&rig.server_certificate, rig.ca, &.{
            .dns_name = server_name,
            .subject_key = rig.server_key.public_key.toBytes(),
            .lifetime = x509_test.window,
        });
        try x509.issue_ca(&rig.ca_certificate, rig.ca, x509_test.window);
        rig.chain = .{ rig.server_certificate.slice(), rig.ca_certificate.slice() };
        rig.server.init(&.{
            .anchor = rig.ca.public_key.toBytes(),
            .now_ms = x509_test.now,
            .random = @splat(0x31),
            .secret = @splat(0x32),
            .identity = .{
                .certificates = &rig.chain,
                .signer = tls_server.key_pair_signer(&rig.server_key),
            },
            .client_kind = kind,
        });
        rig.sent_length = 0;
        rig.data_events = 0;
    }

    fn collect(rig: *Rig) void {
        const output = rig.server.output();
        @memcpy(rig.sent[rig.sent_length..][0..output.len], output);
        rig.sent_length += @intCast(output.len);
        rig.server.drain();
    }

    /// Feeds `bytes` to the server in pieces of at most `chunk` bytes. Returns the last event
    /// that was not `none` or data; stops at the first error.
    fn feed(rig: *Rig, bytes: []const u8, chunk: usize) tls_server.Error!Event {
        var event: Event = .none;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + chunk);
            const step = rig.server.receive(bytes[offset..end], &rig.diag) catch |err| {
                rig.collect();
                return err;
            };
            rig.collect();
            offset += step.consumed;
            switch (step.event) {
                .none => {},
                .data => rig.data_events += 1,
                else => event = step.event,
            }
        }
        return event;
    }

    /// The ClientHello, then the server's flight read by the client.
    fn hello(rig: *Rig, chunk: usize) !void {
        const record = rig.client.hello(&rig.input);
        const event = try rig.feed(record, chunk);
        try std.testing.expect(event == .none);
        try rig.client.accept_flight(rig.sent[0..rig.sent_length]);
        rig.sent_length = 0;
    }

    fn handshake(rig: *Rig, chunk: usize) !Event {
        try rig.hello(chunk);
        const flight = rig.client.flight(&rig.input);
        return rig.feed(flight, chunk);
    }

    fn expect_code(rig: *const Rig, code: Code) !void {
        try std.testing.expectEqual(code, rig.diag.code.?);
    }

    /// The fatal alert the server queued: a plain record before the server's keys, else sealed.
    fn sent_alert(rig: *Rig) ?u8 {
        if (rig.sent_length == 0) return null;
        const record = rig.sent[0..rig.sent_length];
        if (record[0] == @backingInt(schedule.ContentType.alert)) return record[6];
        const opened = rig.client.read.open(record) catch {
            // The server's write side moved to application keys after its flight; the client
            // still reads the handshake keys only if it never saw the Finished.
            return null;
        };
        if (opened.content_type != .alert) return null;
        return opened.content[1];
    }
};

fn expect_connected(rig: *Rig, chunk: usize) !void {
    const event = try rig.handshake(chunk);
    try std.testing.expect(event == .connected);
    try std.testing.expect(rig.server.is_connected());
    const peer = rig.server.peer().?;
    try std.testing.expectEqual(x509.Kind.workload, peer.kind);
    try std.testing.expectEqualStrings(x509_test.workload_uri, peer.name);
}

test "the scripted client connects, whatever the size of the pieces" {
    // Goal: a correct client flight is accepted, read in any split. Method: pieces of 1, 5, 7,
    // 100 and 4096 bytes; the flight in one record and in one record per message; with and
    // without the compatibility change_cipher_spec.
    var rig: Rig = undefined;
    for ([_]usize{ 1, 5, 7, 100, 4096 }) |chunk| {
        for ([_]bool{ true, false }) |one_record| {
            for ([_]u32{ 0, 1 }) |ccs| {
                try rig.setup(.{ .one_record = one_record, .ccs = ccs });
                try expect_connected(&rig, chunk);
            }
        }
    }
}

test "without a session id the server sends no change_cipher_spec" {
    var rig: Rig = undefined;
    try rig.setup(.{ .hello = .{ .session_id = false }, .ccs = 0 });
    const record = rig.client.hello(&rig.input);
    _ = try rig.feed(record, 4096);
    var rest: []u8 = rig.sent[0..rig.sent_length];
    const server_hello = testclient.take_record(&rest).?;
    try std.testing.expectEqual(@as(u8, 22), server_hello[0]);
    try std.testing.expectEqual(@as(u8, 23), rest[0]); // The flight comes at once, sealed.
    try rig.client.accept_flight(rig.sent[0..rig.sent_length]);
    rig.sent_length = 0;
    try std.testing.expect(try rig.feed(rig.client.flight(&rig.input), 4096) == .connected);
}

test "application data and KeyUpdate go both ways after the handshake" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    try expect_connected(&rig, 4096);
    var buffer: [512]u8 = undefined;
    // Client to server, across a KeyUpdate that asks for one back.
    _ = try rig.feed(rig.client.seal(&buffer, .application_data, "ping"), 4096);
    try std.testing.expectEqual(@as(u32, 1), rig.data_events);
    _ = try rig.feed(rig.client.key_update(&buffer, true), 4096);
    try std.testing.expect(rig.sent_length > 0); // The answer.
    const answer = try rig.client.open(rig.sent[0..rig.sent_length]);
    try std.testing.expectEqual(schedule.ContentType.handshake, answer.content_type);
    try std.testing.expectEqualSlices(u8, &.{ 24, 0, 0, 1, 0 }, answer.content);
    try rig.client.read.rekey();
    rig.sent_length = 0;
    _ = try rig.feed(rig.client.seal(&buffer, .application_data, "pong"), 4096);
    try std.testing.expectEqual(@as(u32, 2), rig.data_events);
    // Server to client, under its updated keys, then after one it sends unasked.
    var out: [512]u8 = undefined;
    const sealed = try rig.server.seal_application("hello", &out, &rig.diag);
    const opened = try rig.client.open(sealed);
    try std.testing.expectEqualStrings("hello", opened.content);
    try rig.server.send_key_update(false, &rig.diag);
    rig.collect();
    _ = try rig.client.open(rig.sent[0..rig.sent_length]);
    try rig.client.read.rekey();
    rig.sent_length = 0;
    const again = try rig.server.seal_application("again", &out, &rig.diag);
    try std.testing.expectEqualStrings("again", (try rig.client.open(again)).content);
    // A KeyUpdate that does not ask is not answered.
    _ = try rig.feed(rig.client.key_update(&buffer, false), 4096);
    try std.testing.expectEqual(@as(u32, 0), rig.sent_length);
    _ = try rig.feed(rig.client.seal(&buffer, .application_data, "after"), 4096);
    try std.testing.expectEqual(@as(u32, 3), rig.data_events);
}

test "close_notify from the client is answered and ends the connection" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    try expect_connected(&rig, 4096);
    var buffer: [64]u8 = undefined;
    const event = try rig.feed(rig.client.seal(&buffer, .alert, &.{ 1, 0 }), 4096);
    try std.testing.expect(event == .closed);
    const answer = try rig.client.open(rig.sent[0..rig.sent_length]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, answer.content);
    try rig.server.end_of_input(&rig.diag);
    try std.testing.expectError(error.Closed, rig.server.receive("x", &rig.diag));
}

test "the transport ending without close_notify is E0816" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    try expect_connected(&rig, 4096);
    try std.testing.expectError(error.Refused, rig.server.end_of_input(&rig.diag));
    try rig.expect_code(.E0816);
    // A client whose Finished never comes is cut off the same way.
    try rig.setup(.{ .finished = .omit });
    try std.testing.expect(try rig.handshake(4096) == .none);
    try std.testing.expectError(error.Refused, rig.server.end_of_input(&rig.diag));
    try rig.expect_code(.E0816);
}

// ---- The real client against the server --------------------------------------------------------

const Pair = struct {
    rig: Rig,
    client: tls_client.Client,
    client_key: Ed25519.KeyPair,
    client_certificate: x509.Der,
    client_chain: [2][]const u8,
    outbox: [buffer_bytes]u8,
    outbox_length: u32,
    client_diag: Diag,

    fn setup(pair: *Pair) !void {
        try pair.rig.setup_server(.workload);
        pair.client_key = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
        const request = x509_test.workload_request(pair.client_key.public_key.toBytes());
        try x509.issue_workload(&pair.client_certificate, pair.rig.ca, &request);
        pair.client_chain = .{ pair.client_certificate.slice(), pair.rig.ca_certificate.slice() };
        pair.client_diag.reset();
        pair.outbox_length = 0;
        pair.client.init(&.{
            .anchor = pair.rig.ca.public_key.toBytes(),
            .server_name = server_name,
            .now_ms = x509_test.now,
            .random = @splat(0x11),
            .session_id = @splat(0x22),
            .secret = @splat(0x33),
            .client_auth = .{ .required = .{
                .certificates = &pair.client_chain,
                .signer = tls_client.key_pair_signer(&pair.client_key),
            } },
        });
    }

    fn collect_client(pair: *Pair) void {
        const output = pair.client.output();
        @memcpy(pair.outbox[pair.outbox_length..][0..output.len], output);
        pair.outbox_length += @intCast(output.len);
        pair.client.drain();
    }

    /// Feeds the server's output to the client in pieces; returns the client's last event.
    fn to_client(pair: *Pair, chunk: usize) !tls_client.Event {
        var event: tls_client.Event = .none;
        var offset: usize = 0;
        const bytes = pair.rig.sent[0..pair.rig.sent_length];
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + chunk);
            const step = try pair.client.receive(bytes[offset..end], &pair.client_diag);
            pair.collect_client();
            offset += step.consumed;
            if (step.event != .none) event = step.event;
        }
        pair.rig.sent_length = 0;
        return event;
    }

    fn to_server(pair: *Pair, chunk: usize) !Event {
        const event = try pair.rig.feed(pair.outbox[0..pair.outbox_length], chunk);
        pair.outbox_length = 0;
        return event;
    }

    fn connect(pair: *Pair, chunk: usize) !void {
        pair.client.start();
        pair.collect_client();
        try std.testing.expect(try pair.to_server(chunk) == .none);
        try std.testing.expect(try pair.to_client(chunk) == .connected);
        try std.testing.expect(try pair.to_server(chunk) == .connected);
        try std.testing.expectEqualStrings(x509_test.workload_uri, pair.rig.server.peer().?.name);
    }
};

test "the real client connects with its certificate, whatever the size of the pieces" {
    var pair: Pair = undefined;
    for ([_]usize{ 1, 3, 64, 4096 }) |chunk| {
        try pair.setup();
        try pair.connect(chunk);
    }
}

test "the real client and the server exchange data and KeyUpdates both ways" {
    var pair: Pair = undefined;
    try pair.setup();
    try pair.connect(4096);
    var out: [256]u8 = undefined;
    for (0..3) |round| {
        // Client to server, then a KeyUpdate that asks for one back.
        const sealed = try pair.client.seal_application("ping", &out, &pair.client_diag);
        @memcpy(pair.outbox[0..sealed.len], sealed);
        pair.outbox_length = @intCast(sealed.len);
        _ = try pair.to_server(7);
        try std.testing.expectEqual(@as(u32, @intCast(round + 1)), pair.rig.data_events);
        try pair.client.send_key_update(true, &pair.client_diag);
        pair.collect_client();
        _ = try pair.to_server(4096);
        try std.testing.expect(pair.rig.sent_length > 0);
        _ = try pair.to_client(4096);
        // Server to client, then a KeyUpdate of the server's own.
        const reply = try pair.rig.server.seal_application("pong", &out, &pair.rig.diag);
        @memcpy(pair.rig.sent[0..reply.len], reply);
        pair.rig.sent_length = @intCast(reply.len);
        const event = try pair.to_client(5);
        try std.testing.expectEqualStrings("pong", event.data);
        try pair.rig.server.send_key_update(false, &pair.rig.diag);
        pair.rig.collect();
        _ = try pair.to_client(4096);
    }
    try std.testing.expectEqual(@as(u32, 6), pair.rig.server.write.updates);
    try std.testing.expectEqual(@as(u32, 3), pair.rig.server.read.updates);
    pair.client.close_notify();
    pair.collect_client();
    try std.testing.expect(try pair.to_server(4096) == .closed);
    try std.testing.expect(pair.rig.sent_length > 0); // The server's close_notify back.
}

// ---- Near misses: each breaks one thing in the client's hello or flight ------------------------

const NearMiss = struct {
    name: []const u8,
    faults: testclient.Faults,
    code: Code,
    /// The alert the server sends, when it can.
    alert: ?wire.Alert,
};

const hello_misses = [_]NearMiss{
    .{
        .name = "TLS 1.2 only",
        .code = .E0818,
        .alert = .protocol_version,
        .faults = .{ .hello = .{ .tls13 = false } },
    },
    .{
        .name = "no extensions",
        .code = .E0818,
        .alert = .protocol_version,
        .faults = .{ .hello = .{ .extensions = false } },
    },
    .{
        .name = "another suite",
        .code = .E0818,
        .alert = .handshake_failure,
        .faults = .{ .hello = .{ .suite = false } },
    },
    .{
        .name = "another group",
        .code = .E0818,
        .alert = .handshake_failure,
        .faults = .{ .hello = .{ .x25519 = false } },
    },
    .{
        .name = "short key",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .key_bytes = 31 } },
    },
    .{
        .name = "low-order key",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .low_order = true } },
    },
    .{
        .name = "no Ed25519",
        .code = .E0818,
        .alert = .handshake_failure,
        .faults = .{ .hello = .{ .signature_algorithms = .other } },
    },
    .{
        .name = "no signature_algorithms",
        .code = .E0813,
        .alert = .missing_extension,
        .faults = .{ .hello = .{ .signature_algorithms = .absent } },
    },
    .{
        .name = "compression",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .compression = 1 } },
    },
    .{
        .name = "repeated extension",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .duplicate = true } },
    },
    .{
        .name = "repeated group",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .duplicate_group = true } },
    },
    .{
        .name = "early data",
        .code = .E0818,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .early_data = true } },
    },
    .{
        .name = "psk not last",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .hello = .{ .psk_not_last = true } },
    },
};

const flight_misses = [_]NearMiss{
    .{
        .name = "two change_cipher_spec",
        .code = .E0815,
        .alert = .unexpected_message,
        .faults = .{ .ccs = 2 },
    },
    .{
        .name = "change_cipher_spec of 2",
        .code = .E0815,
        .alert = .unexpected_message,
        .faults = .{ .ccs_byte = 2 },
    },
    .{
        .name = "no certificate",
        .code = .E0814,
        .alert = .certificate_required,
        .faults = .{ .chain = .none, .verify = .omit },
    },
    .{
        .name = "another CA",
        .code = .E0810,
        .alert = .unknown_ca,
        .faults = .{ .chain = .other_ca },
    },
    .{
        .name = "expired",
        .code = .E0811,
        .alert = .certificate_expired,
        .faults = .{ .chain = .expired },
    },
    .{
        .name = "a server certificate",
        .code = .E0819,
        .alert = .unsupported_certificate,
        .faults = .{ .chain = .server_kind },
    },
    .{
        .name = "three certificates",
        .code = .E0810,
        .alert = .bad_certificate,
        .faults = .{ .chain = .three },
    },
    .{
        .name = "a damaged signature",
        .code = .E0810,
        .alert = .unknown_ca,
        .faults = .{ .chain = .tampered },
    },
    .{
        .name = "a request context",
        .code = .E0813,
        .alert = .illegal_parameter,
        .faults = .{ .context = "x" },
    },
    .{
        .name = "no CertificateVerify",
        .code = .E0813,
        .alert = .unexpected_message,
        .faults = .{ .verify = .omit },
    },
    .{
        .name = "another key signed",
        .code = .E0813,
        .alert = .decrypt_error,
        .faults = .{ .verify = .wrong_key },
    },
    .{
        .name = "the server's context",
        .code = .E0813,
        .alert = .decrypt_error,
        .faults = .{ .verify = .server_context },
    },
    .{
        .name = "a flipped signature",
        .code = .E0813,
        .alert = .decrypt_error,
        .faults = .{ .verify = .flipped },
    },
    .{
        .name = "another scheme",
        .code = .E0818,
        .alert = .illegal_parameter,
        .faults = .{ .verify = .bad_scheme },
    },
    .{
        .name = "a bad Finished",
        .code = .E0813,
        .alert = .decrypt_error,
        .faults = .{ .finished = .bad },
    },
    .{
        .name = "bytes after Finished",
        .code = .E0813,
        .alert = .unexpected_message,
        .faults = .{ .trailing = true },
    },
    .{
        .name = "data before Finished",
        .code = .E0813,
        .alert = .unexpected_message,
        .faults = .{ .early_application_data = true },
    },
    .{
        .name = "out of order",
        .code = .E0813,
        .alert = .unexpected_message,
        .faults = .{ .swapped = true },
    },
};

fn expect_miss(rig: *Rig, miss: *const NearMiss, refused: anytype) !void {
    std.testing.expectError(error.Refused, refused) catch |err| {
        std.debug.print("near miss \"{s}\" was not refused\n", .{miss.name});
        return err;
    };
    if (rig.diag.code.? != miss.code) {
        std.debug.print("near miss \"{s}\": {s}, want {s}\n", .{
            miss.name, @tagName(rig.diag.code.?), @tagName(miss.code),
        });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(rig.diag.last_cause() != null);
    try std.testing.expect(!rig.server.is_connected());
    try std.testing.expect(rig.server.read.dead);
    try std.testing.expect(rig.server.write.dead);
    try std.testing.expectError(error.Closed, rig.server.receive("x", &rig.diag));
}

test "each near miss in the ClientHello is refused with its code and alert" {
    var rig: Rig = undefined;
    for (&hello_misses) |*miss| {
        try rig.setup(miss.faults);
        const record = rig.client.hello(&rig.input);
        try expect_miss(&rig, miss, rig.feed(record, 4096));
        // Before the ServerHello the client has no keys: the alert is plain.
        try std.testing.expectEqual(@as(u32, 7), rig.sent_length);
        try std.testing.expectEqual(@backingInt(miss.alert.?), rig.sent[6]);
    }
}

test "each near miss in the client's flight is refused with its code and alert" {
    var rig: Rig = undefined;
    var failures: u32 = 0;
    for (&flight_misses) |*miss| {
        try rig.setup(miss.faults);
        try expect_miss(&rig, miss, rig.handshake(4096));
        // The alert goes under the server's application keys, which the client holds.
        const opened = try rig.client.read.open(rig.sent[0..rig.sent_length]);
        try std.testing.expectEqual(schedule.ContentType.alert, opened.content_type);
        if (opened.content[1] != @backingInt(miss.alert.?)) {
            std.debug.print("near miss \"{s}\": alert {d}\n", .{ miss.name, opened.content[1] });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failures);
}

test "a client certificate of the configured kind only is taken" {
    // A server for workloads refuses a server certificate; one for servers takes it.
    var rig: Rig = undefined;
    try rig.setup_server(.server);
    try rig.client.init(.{ .ca = rig.ca, .faults = .{ .chain = .server_kind } });
    const event = try rig.handshake(4096);
    try std.testing.expect(event == .connected);
    try std.testing.expectEqual(x509.Kind.server, rig.server.peer().?.kind);
    try std.testing.expectEqualStrings("client.botpike.com", rig.server.peer().?.name);
}

test "client_kind: a server takes a client certificate of its configured kind and no other" {
    // Goal: the four leaf kinds a client can present (B7 adds node and client) are told apart.
    // Method: every pair of configured and presented kind; equal pairs connect and name the peer,
    // the others are refused with ZC-E0819 and unsupported_certificate.
    const kinds = [_]x509.Kind{ .workload, .server, .node, .client };
    const chains = [_]testclient.Chain{ .good, .server_kind, .node_kind, .client_kind };
    const names = [_][]const u8{
        x509_test.workload_uri,
        "client.botpike.com",
        x509_test.node_uri,
        x509_test.client_uri,
    };
    var failures: u32 = 0;
    for (kinds) |configured| {
        for (kinds, chains, names) |presented, chain, name| {
            var rig: Rig = undefined;
            try rig.setup_server(configured);
            try rig.client.init(.{ .ca = rig.ca, .faults = .{ .chain = chain } });
            const result = rig.handshake(4096);
            if (configured == presented) {
                const event = try result;
                try std.testing.expect(event == .connected);
                try std.testing.expectEqual(presented, rig.server.peer().?.kind);
                try std.testing.expectEqualStrings(name, rig.server.peer().?.name);
                continue;
            }
            try std.testing.expectError(error.Refused, result);
            if (rig.diag.code != Code.E0819 or rig.sent_alert() !=
                @backingInt(wire.Alert.unsupported_certificate))
            {
                std.debug.print("client_kind {t} took {t}\n", .{ configured, presented });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failures);
}

test "a fatal alert from the client is named, plain before its keys and sealed after" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    try rig.hello(4096);
    var buffer: [64]u8 = undefined;
    const sealed = rig.client.seal(&buffer, .alert, &.{ 2, 42 });
    try std.testing.expectError(error.Refused, rig.feed(sealed, 4096));
    try rig.expect_code(.E0813);
    try std.testing.expect(std.mem.indexOf(u8, rig.diag.last_cause().?, "bad_certificate") != null);
    // A client that could not read the ServerHello has no keys: its alert comes in the clear.
    try rig.setup(.{});
    try rig.hello(4096);
    const plain = [_]u8{ 21, 3, 3, 0, 2, 2, 70 };
    try std.testing.expectError(error.Refused, rig.feed(&plain, 4096));
    const cause = rig.diag.last_cause().?;
    try std.testing.expect(std.mem.indexOf(u8, cause, "protocol_version") != null);
}

test "a client handshake message over the limit is refused, not buffered" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    var record: [9]u8 = .{ 22, 3, 1, 0, 4, 1, 0, 0x10, 0x01 }; // A ClientHello of 4097 bytes.
    try std.testing.expectError(error.Refused, rig.feed(&record, 4096));
    try rig.expect_code(.E0813);
    record = .{ 22, 3, 1, 0, 4, 1, 0xFF, 0xFF, 0xFF }; // Near 2^24: widened, not overflowed.
    try rig.setup(.{});
    try std.testing.expectError(error.Refused, rig.feed(&record, 4096));
    try rig.expect_code(.E0813);
}

test "a record that does not authenticate ends the connection and wipes it" {
    var rig: Rig = undefined;
    try rig.setup(.{});
    try rig.hello(4096);
    const flight = rig.client.flight(&rig.input);
    flight[flight.len - 1] ^= 0x01;
    try std.testing.expectError(error.Refused, rig.feed(flight, 4096));
    try rig.expect_code(.E0815);
    try std.testing.expect(rig.server.read.dead);
    for (rig.server.record) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

// ---- Teeth: each security check, skipped, lets a refused client through ------------------------

fn expect_tooth(fault: tls_server.TestFault, faults: testclient.Faults) !void {
    var rig: Rig = undefined;
    try rig.setup(faults);
    try std.testing.expectError(error.Refused, rig.handshake(4096)); // Negative half.
    tls_server.set_test_fault(fault, true);
    defer tls_server.set_test_fault(fault, false);
    try rig.setup(faults);
    const event = try rig.handshake(4096);
    try std.testing.expect(event == .connected);
}

test "teeth: without the chain check a certificate from another CA connects" {
    try expect_tooth(.client_chain, .{ .chain = .other_ca });
}

test "teeth: without the chain check a damaged certificate connects" {
    try expect_tooth(.client_chain, .{ .chain = .tampered });
}

test "teeth: without the kind check a server certificate connects as a client" {
    try expect_tooth(.client_kind, .{ .chain = .server_kind });
}

test "teeth: without the required-certificate check a client with none connects" {
    try expect_tooth(.required_certificate, .{ .chain = .none, .verify = .omit });
}

test "teeth: without the CertificateVerify check another key's signature connects" {
    try expect_tooth(.certificate_verify, .{ .verify = .wrong_key });
}

test "teeth: with the server's context a CertificateVerify for a server connects" {
    try expect_tooth(.verify_context, .{ .verify = .server_context });
}

test "teeth: without the Finished check a bad Finished connects" {
    try expect_tooth(.finished, .{ .finished = .bad });
}

test "teeth: without the key-change boundary bytes after Finished are read" {
    try expect_tooth(.key_change_boundary, .{ .trailing = true });
}

test "teeth: a transcript without the client's certificate is refused by a correct client" {
    // Goal: the transcript binds the client's Certificate and CertificateVerify. Method: a
    // server that leaves them out disagrees with a correct client's Finished.
    var rig: Rig = undefined;
    try rig.setup(.{});
    try expect_connected(&rig, 4096);
    tls_server.set_test_fault(.transcript_client_auth, true);
    defer tls_server.set_test_fault(.transcript_client_auth, false);
    try rig.setup(.{});
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try rig.expect_code(.E0813);
}

test "teeth: without the early-data check data before Finished is passed on" {
    var rig: Rig = undefined;
    try rig.setup(.{ .early_application_data = true });
    try std.testing.expectError(error.Refused, rig.handshake(4096));
    try std.testing.expectEqual(@as(u32, 0), rig.data_events);
    tls_server.set_test_fault(.early_application_data, true);
    defer tls_server.set_test_fault(.early_application_data, false);
    try rig.setup(.{ .early_application_data = true });
    try std.testing.expect(try rig.handshake(4096) == .connected);
    try std.testing.expectEqual(@as(u32, 1), rig.data_events);
}
