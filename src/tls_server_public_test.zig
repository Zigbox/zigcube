//! Tests for the TLS server's public path (`tls_server.zig`, `init_public`; docs/briefs/c5.md,
//! "Public TLS"): the scripted client of `tls_testclient.zig` on the public path, the SNI table,
//! ALPN, each refusal with its alert and reason, Chromium's recorded ClientHello, and the teeth.
//! Core code: runs under WASI too.

const std = @import("std");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const schedule = @import("tls_schedule.zig");
const tls_server = @import("tls_server.zig");
const testclient = @import("tls_testclient.zig");
const wire = @import("tls_wire.zig");
const x509 = @import("x509.zig");
const x509_test = @import("x509_test.zig");
const p256 = @import("x509_p256.zig");
const p256_test = @import("x509_p256_test.zig");

const Diag = diag_mod.Diag;
const Event = tls_server.Event;
const PublicRefusal = tls_server.PublicRefusal;
const testing = std.testing;

const buffer_bytes = 4 * constants.tls_handshake_flight_bytes_max;
/// Sorted, as `PublicTable.init` requires.
const hosts = [_][]const u8{ "a.example.org", "hello.test", "www.hello.test" };

/// Chromium's ClientHello record (src/testdata/tls/README.md).
const chromium_hello = @embedFile("testdata/tls/client_hello_chromium.bin");

/// A public server with one chain per host in `hosts`, a scripted client and the bytes between
/// them. Each host's leaf has its own key; `hello.test` sends a third, opaque certificate.
const Rig = struct {
    server: tls_server.Server,
    client: testclient.Client,
    diag: Diag,
    root: p256.KeyPair,
    root_certificate: x509.Der,
    keys: [hosts.len]p256.KeyPair,
    leaves: [hosts.len]x509.Der,
    certificates: [hosts.len][3][]const u8,
    chains: [hosts.len]tls_server.PublicChain,
    table: tls_server.PublicTable,
    sent: [buffer_bytes]u8,
    sent_length: u32,
    input: [buffer_bytes]u8,
    data_events: u32,

    /// Opaque bytes standing in for an intermediate: the server must send them as given.
    const opaque_intermediate = "an intermediate this server never parses";

    fn setup(rig: *Rig, public: testclient.Public, faults: testclient.Faults) !void {
        rig.diag.reset();
        rig.root = try p256_test.ca_key();
        try p256.issue_ca(&rig.root_certificate, rig.root, x509_test.window);
        for (hosts, 0..) |host, index| {
            rig.keys[index] = try p256_test.key(@intCast(0x30 + index));
            try p256.issue_server(&rig.leaves[index], rig.root, &.{
                .dns_name = host,
                .sans = &.{},
                .subject_key = p256.point_of(rig.keys[index]),
                .lifetime = x509_test.window,
            });
            rig.certificates[index] = .{
                rig.leaves[index].slice(),
                rig.root_certificate.slice(),
                opaque_intermediate,
            };
            const count: usize = if (std.mem.eql(u8, host, "hello.test")) 3 else 2;
            rig.chains[index] = .{
                .host = host,
                .key = &rig.keys[index],
                .certificates = rig.certificates[index][0..count],
            };
        }
        rig.table = try tls_server.PublicTable.init(&rig.chains);
        rig.server.init_public(&.{
            .random = @splat(0x31),
            .secret = @splat(0x32),
            .table = &rig.table,
        });
        var adjusted = public;
        adjusted.root = rig.root;
        var client_faults = faults;
        if (client_faults.hello.signature_algorithms == .ed25519) {
            client_faults.hello.signature_algorithms = .chrome;
        }
        const ca = try x509_test.ca_pair();
        try rig.client.init(.{ .ca = ca, .public = adjusted, .faults = client_faults });
        rig.sent_length = 0;
        rig.data_events = 0;
    }

    fn collect(rig: *Rig) void {
        const output = rig.server.output();
        @memcpy(rig.sent[rig.sent_length..][0..output.len], output);
        rig.sent_length += @intCast(output.len);
        rig.server.drain();
    }

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

    fn hello(rig: *Rig, chunk: usize) !void {
        const record = rig.client.hello(&rig.input);
        const event = try rig.feed(record, chunk);
        try testing.expect(event == .none);
        try rig.client.accept_flight(rig.sent[0..rig.sent_length]);
        rig.sent_length = 0;
    }

    fn handshake(rig: *Rig, chunk: usize) !Event {
        try rig.hello(chunk);
        const flight = rig.client.flight(&rig.input);
        return rig.feed(flight, chunk);
    }

    /// The fatal alert the server sent in the clear in answer to the ClientHello.
    fn hello_alert(rig: *const Rig) ?u8 {
        if (rig.sent_length != 7) return null;
        if (rig.sent[0] != @backingInt(schedule.ContentType.alert)) return null;
        return rig.sent[6];
    }
};

fn expect_connected(rig: *Rig, host: []const u8) !void {
    try testing.expect(rig.server.is_connected());
    try testing.expectEqualStrings(host, rig.server.server_name().?);
    try testing.expect(rig.server.peer() == null); // No client certificate on this path.
    try testing.expect(rig.server.public_refusal() == null);
    try testing.expect(rig.server.public_table == null); // The table is not held.
}

test "public: a browser-like client connects, whatever the size of the pieces" {
    // Goal: the public flight carries no CertificateRequest, an ECDSA CertificateVerify by the
    // chain's key, ALPN http/1.1, and ends at the client's Finished. Method: the scripted client
    // checks each message with its own code; pieces of 1, 7, 100 and 4096 bytes.
    var rig: Rig = undefined;
    for ([_]usize{ 1, 7, 100, 4096 }) |chunk| {
        for ([_]u32{ 0, 1 }) |ccs| {
            try rig.setup(.{ .root = undefined }, .{ .ccs = ccs });
            try testing.expect(try rig.handshake(chunk) == .connected);
            try testing.expect(rig.client.alpn_selected);
            try expect_connected(&rig, "hello.test");
        }
    }
}

test "public: application data goes both ways after the handshake" {
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    try testing.expect(try rig.handshake(4096) == .connected);
    var buffer: [512]u8 = undefined;
    _ = try rig.feed(rig.client.seal(&buffer, .application_data, "GET / HTTP/1.1\r\n"), 4096);
    try testing.expectEqual(@as(u32, 1), rig.data_events);
    var out: [512]u8 = undefined;
    const sealed = try rig.server.seal_application("HTTP/1.1 200 OK\r\n", &out, &rig.diag);
    const opened = try rig.client.open(sealed);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", opened.content);
}

test "public: the server name picks the chain, canonicalized as Host is" {
    // Goal: each host gets its own leaf and key, and SNI is compared after canonicalization (case
    // and one trailing dot). Method: the client checks the leaf names the host it expects.
    var rig: Rig = undefined;
    const cases = [_]struct { sent: []const u8, host: []const u8 }{
        .{ .sent = "a.example.org", .host = "a.example.org" },
        .{ .sent = "WWW.Hello.Test.", .host = "www.hello.test" },
        .{ .sent = "hello.test", .host = "hello.test" },
    };
    for (cases) |case| {
        const public: testclient.Public = .{
            .root = undefined,
            .server_name = case.sent,
            .expect_host = case.host,
        };
        try rig.setup(public, .{});
        try testing.expect(try rig.handshake(4096) == .connected);
        try expect_connected(&rig, case.host);
    }
}

test "public: the intermediates go out as given, never parsed" {
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    try rig.hello(4096);
    const received = rig.client.received[0..rig.client.received_length];
    try testing.expect(std.mem.indexOf(u8, received, Rig.opaque_intermediate) != null);
}

test "public: a client without ALPN connects, and none is selected" {
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined, .alpn = .absent }, .{});
    try testing.expect(try rig.handshake(4096) == .connected);
    try testing.expect(!rig.client.alpn_selected);
    try expect_connected(&rig, "hello.test");
}

const Refusal = struct {
    name: []const u8,
    public: testclient.Public = .{ .root = undefined },
    faults: testclient.Faults = .{},
    alert: wire.Alert,
    reason: PublicRefusal,
};

const refusals = [_]Refusal{
    .{
        .name = "no server name",
        .public = .{ .root = undefined, .server_name = null },
        .alert = .unrecognized_name,
        .reason = .server_name_missing,
    },
    .{
        .name = "an unknown name",
        .public = .{ .root = undefined, .server_name = "other.test" },
        .alert = .unrecognized_name,
        .reason = .server_name_unknown,
    },
    .{
        .name = "a parent of a known name",
        .public = .{ .root = undefined, .server_name = "test.x" },
        .alert = .unrecognized_name,
        .reason = .server_name_unknown,
    },
    .{
        .name = "an IP literal",
        .public = .{ .root = undefined, .server_name = "192.0.2.1" },
        .alert = .unrecognized_name,
        .reason = .server_name_unknown,
    },
    .{
        .name = "localhost",
        .public = .{ .root = undefined, .server_name = "localhost" },
        .alert = .unrecognized_name,
        .reason = .server_name_unknown,
    },
    .{
        .name = "a wildcard",
        .public = .{ .root = undefined, .server_name = "*.hello.test" },
        .alert = .unrecognized_name,
        .reason = .server_name_unknown,
    },
    .{
        .name = "ALPN without http/1.1",
        .public = .{ .root = undefined, .alpn = .h2_only },
        .alert = .no_application_protocol,
        .reason = .alpn,
    },
    .{
        .name = "x25519 listed without a share",
        .public = .{ .root = undefined, .x25519_without_share = true },
        .alert = .handshake_failure,
        .reason = .x25519_without_share,
    },
    .{
        .name = "no ECDSA P-256 signatures",
        .faults = .{ .hello = .{ .signature_algorithms = .rsa_pss } },
        .alert = .handshake_failure,
        .reason = .other,
    },
    .{
        .name = "early data",
        .faults = .{ .hello = .{ .early_data = true } },
        .alert = .illegal_parameter,
        .reason = .other,
    },
    .{
        .name = "TLS 1.2",
        .faults = .{ .hello = .{ .tls13 = false } },
        .alert = .protocol_version,
        .reason = .other,
    },
};

test "public: each refused ClientHello ends with its alert and its reason" {
    // Goal: every refusal of the public path names its reason for the edge's counter and sends
    // the alert a browser understands (unrecognized_name, no_application_protocol). Method: one
    // near miss per row, everything else a correct browser hello.
    var rig: Rig = undefined;
    for (refusals) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        try rig.setup(row.public, row.faults);
        const record = rig.client.hello(&rig.input);
        try testing.expectError(error.Refused, rig.feed(record, 4096));
        try testing.expectEqual(@backingInt(row.alert), rig.hello_alert().?);
        try testing.expectEqual(row.reason, rig.server.public_refusal().?);
        try testing.expect(rig.diag.code != null);
        // The name is known once the table had it: refusals after the chain is picked name it.
        const named = row.reason == .alpn or std.mem.eql(u8, row.name, "early data");
        try testing.expectEqual(named, rig.server.server_name() != null);
    }
}

test "public: Chromium's recorded ClientHello is answered with hello.test's chain" {
    // Goal: a real browser's hello (X25519MLKEM768 and x25519 shares, GREASE, ECH GREASE, h2
    // and http/1.1) is taken on the x25519 share. Method: the fixture fed whole and in 1-byte
    // pieces; the server answers with a ServerHello and its sealed flight.
    var rig: Rig = undefined;
    for ([_]usize{ 1, 4096 }) |chunk| {
        try rig.setup(.{ .root = undefined }, .{});
        try testing.expect(try rig.feed(chromium_hello, chunk) == .none);
        try testing.expect(rig.sent_length > 0);
        try testing.expectEqual(@backingInt(schedule.ContentType.handshake), rig.sent[0]);
        try testing.expectEqualStrings("hello.test", rig.server.server_name().?);
        try testing.expect(rig.server.public_refusal() == null);
        try testing.expect(rig.server.alpn_http11);
    }
    const parsed = try wire.parse_client_hello_public(chromium_hello[5..][4..]);
    try testing.expectEqualStrings("hello.test", parsed.server_name.?);
    try testing.expectEqual(wire.Alpn.http11, parsed.alpn);
    try testing.expect(parsed.hello.ecdsa_p256);
    try testing.expect(!parsed.hello.ed25519);
}

test "public: a client that cannot read the ServerHello may answer with a plain alert" {
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    _ = try rig.feed(rig.client.hello(&rig.input), 4096);
    const alert = [_]u8{ 21, 3, 3, 0, 2, 2, @backingInt(wire.Alert.bad_certificate) };
    try testing.expectError(error.Refused, rig.feed(&alert, 4096));
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0813), rig.diag.code);
    // The client's own alert is counted apart from the hellos this server refuses.
    try testing.expectEqual(PublicRefusal.client_alert, rig.server.public_refusal().?);
}

test "public: a client that closes before its Finished is counted as its own end" {
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    try rig.hello(4096);
    try testing.expect(rig.server.public_refusal() == null);
    const close = [_]u8{ 21, 3, 3, 0, 2, 1, @backingInt(wire.Alert.close_notify) };
    try testing.expectError(error.Refused, rig.feed(&close, 4096));
    try testing.expectEqual(PublicRefusal.client_alert, rig.server.public_refusal().?);
}

/// A one-chain table for `host` with `certificates`, all under one key.
fn table_one(host: []const u8, certificates: []const []const u8) !void {
    const key = try p256_test.key(0x41);
    const chains = [_]tls_server.PublicChain{
        .{ .host = host, .key = &key, .certificates = certificates },
    };
    _ = try tls_server.PublicTable.init(&chains);
}

/// A table of `names` in the order given, each with a one-certificate chain.
fn table_of(
    chains: []tls_server.PublicChain,
    key: *const p256.KeyPair,
    names: []const []const u8,
) !tls_server.PublicTable {
    for (names, 0..) |name, index| {
        chains[index] = .{ .host = name, .key = key, .certificates = &.{"leaf"} };
    }
    return tls_server.PublicTable.init(chains[0..names.len]);
}

test "public: the table refuses what it cannot serve" {
    const big: [constants.edge_certificate_bytes_max + 1]u8 = @splat(1);
    const third: [constants.edge_chain_bytes_max / 3 + 1]u8 = @splat(1);
    const leaf: []const u8 = "leaf";
    try testing.expectError(error.NotCanonical, table_one("A.test", &.{leaf}));
    try testing.expectError(error.NotCanonical, table_one("a.test.", &.{leaf}));
    try testing.expectError(error.NotCanonical, table_one("localhost", &.{leaf}));
    try testing.expectError(error.ChainEmpty, table_one("a.test", &.{}));
    try testing.expectError(error.ChainEmpty, table_one("a.test", &.{""}));
    try testing.expectError(error.ChainTooLong, table_one("a.test", &.{ leaf, leaf, leaf, leaf }));
    try testing.expectError(error.CertificateTooLarge, table_one("a.test", &.{&big}));
    try testing.expectError(error.ChainTooLarge, table_one("a.test", &.{ &third, &third, &third }));
    try table_one("a.test", &.{ leaf, &third, &third });

    const key = try p256_test.key(0x41);
    var chains: [3]tls_server.PublicChain = undefined;
    try testing.expectError(error.Unsorted, table_of(&chains, &key, &.{ "b.test", "a.test" }));
    try testing.expectError(error.Unsorted, table_of(&chains, &key, &.{ "a.test", "a.test" }));
    const table = try table_of(&chains, &key, &.{ "a.test", "b.test", "c.test" });
    try testing.expectEqualStrings("a.test", table.find("a.test").?.host);
    try testing.expectEqualStrings("b.test", table.find("b.test").?.host);
    try testing.expectEqualStrings("c.test", table.find("c.test").?.host);
    try testing.expect(table.find("d.test") == null);
    try testing.expect(table.find("") == null);
    const empty = try table_of(&chains, &key, &.{});
    try testing.expect(empty.find("a.test") == null);
}

// ---- Teeth: each check skipped lets a refused client through ------------------------------------

test "teeth: skip_sni_check: an unknown name is served the first chain" {
    var rig: Rig = undefined;
    const public: testclient.Public = .{
        .root = undefined,
        .server_name = "other.test",
        .expect_host = hosts[0],
    };
    try rig.setup(public, .{});
    try testing.expectError(error.Refused, rig.feed(rig.client.hello(&rig.input), 4096));
    tls_server.set_test_fault(.sni_check, true);
    defer tls_server.set_test_fault(.sni_check, false);
    try rig.setup(public, .{});
    try testing.expect(try rig.handshake(4096) == .connected);
}

test "teeth: skip_alpn_check: a client without http/1.1 connects" {
    var rig: Rig = undefined;
    const public: testclient.Public = .{ .root = undefined, .alpn = .h2_only };
    try rig.setup(public, .{});
    try testing.expectError(error.Refused, rig.feed(rig.client.hello(&rig.input), 4096));
    tls_server.set_test_fault(.alpn_check, true);
    defer tls_server.set_test_fault(.alpn_check, false);
    try rig.setup(public, .{});
    try testing.expect(try rig.handshake(4096) == .connected);
}

/// Whether the server's decrypted flight (as the scripted client opened it) holds a handshake
/// message of type `kind`: a walk of the message headers, whatever the client made of them.
fn flight_holds(rig: *const Rig, kind: u8) bool {
    const flight = rig.client.received[0..rig.client.received_length];
    var at: usize = 0;
    while (at + 4 <= flight.len) {
        if (flight[at] == kind) return true;
        at += 4 + std.mem.readInt(u24, flight[at + 1 ..][0..3], .big);
    }
    return false;
}

test "teeth: cert_request_sent: the public flight asks for a client certificate" {
    // The property is asserted on the flight's bytes, so a laxer client parse cannot hide it.
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    try rig.hello(4096);
    try testing.expect(!flight_holds(&rig, wire.handshake_certificate_request));
    try testing.expect(flight_holds(&rig, wire.handshake_certificate));
    try testing.expect(try rig.feed(rig.client.flight(&rig.input), 4096) == .connected);
    tls_server.set_test_fault(.cert_request_sent, true);
    defer tls_server.set_test_fault(.cert_request_sent, false);
    try rig.setup(.{ .root = undefined }, .{});
    _ = try rig.feed(rig.client.hello(&rig.input), 4096);
    const flight = rig.sent[0..rig.sent_length];
    try testing.expectError(error.BadFlight, rig.client.accept_flight(flight));
    try testing.expect(flight_holds(&rig, wire.handshake_certificate_request));
}

// ---- The public ClientHello's extension readers, byte by byte ---------------------------------

/// One extension of a hand-built ClientHello: its type and its data as sent.
const Extension = struct { kind: u16, data: []const u8 };

const x25519_share = [_]u8{ 0, 36, 0, 0x1d, 0, 32 } ++ @as([32]u8, @splat(9));

/// A correct browser ClientHello's extensions, in this order.
const base_extensions = [_]Extension{
    .{ .kind = 0, .data = &[_]u8{ 0, 13, 0, 0, 10 } ++ "hello.test".* },
    .{ .kind = 10, .data = &.{ 0, 2, 0, 0x1d } },
    .{ .kind = 13, .data = &.{ 0, 2, 0x04, 0x03 } },
    .{ .kind = 16, .data = &[_]u8{ 0, 9, 8 } ++ "http/1.1".* },
    .{ .kind = 43, .data = &.{ 2, 0x03, 0x04 } },
    .{ .kind = 51, .data = &x25519_share },
};

/// A ClientHello record (TLS 1.3, TLS_AES_128_GCM_SHA256, no session id) carrying `extensions`.
fn hello_record(out: []u8, extensions: []const Extension) []const u8 {
    var length: usize = 5 + 4;
    const fixed = [_]u8{ 3, 3 } ++ @as([32]u8, @splat(0x5a)) ++ [_]u8{ 0, 0, 2, 0x13, 0x01, 1, 0 };
    @memcpy(out[length..][0..fixed.len], &fixed);
    length += fixed.len;
    const extensions_at = length;
    length += 2;
    for (extensions) |extension| {
        std.mem.writeInt(u16, out[length..][0..2], extension.kind, .big);
        std.mem.writeInt(u16, out[length + 2 ..][0..2], @intCast(extension.data.len), .big);
        @memcpy(out[length + 4 ..][0..extension.data.len], extension.data);
        length += 4 + extension.data.len;
    }
    std.mem.writeInt(u16, out[extensions_at..][0..2], @intCast(length - extensions_at - 2), .big);
    out[0] = @backingInt(schedule.ContentType.handshake);
    std.mem.writeInt(u16, out[1..3], 0x0301, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(length - 5), .big);
    out[5] = wire.handshake_client_hello;
    std.mem.writeInt(u24, out[6..9], @intCast(length - 9), .big);
    return out[0..length];
}

/// `base_extensions` with the extension of type `kind` replaced by `data` (dropped when null),
/// and `extra` appended.
fn extensions_with(
    out: *[base_extensions.len + 1]Extension,
    kind: u16,
    data: ?[]const u8,
    extra: ?Extension,
) []const Extension {
    var count: usize = 0;
    for (base_extensions) |extension| {
        if (extension.kind == kind) {
            const replaced = data orelse continue;
            out[count] = .{ .kind = kind, .data = replaced };
        } else {
            out[count] = extension;
        }
        count += 1;
    }
    if (extra) |extension| {
        out[count] = extension;
        count += 1;
    }
    return out[0..count];
}

const name_256 = [_]u8{ 1, 3, 0, 1, 0 } ++ @as([256]u8, @splat('a'));
const two_names = [_]u8{ 0, 26, 0, 0, 10 } ++ "hello.test".* ++ [_]u8{ 0, 0, 10 } ++ "other.test".*;

const BadExtension = struct {
    name: []const u8,
    kind: u16,
    data: ?[]const u8 = null,
    extra: ?Extension = null,
    alert: wire.Alert,
};

const bad_extensions = [_]BadExtension{
    .{ .name = "two server names", .kind = 0, .data = &two_names, .alert = .decode_error },
    .{
        .name = "a name of type 1",
        .kind = 0,
        .data = &[_]u8{ 0, 13, 1, 0, 10 } ++ "hello.test".*,
        .alert = .illegal_parameter,
    },
    .{ .name = "an empty name", .kind = 0, .data = &.{ 0, 3, 0, 0, 0 }, .alert = .decode_error },
    .{ .name = "a name of 256 bytes", .kind = 0, .data = &name_256, .alert = .illegal_parameter },
    .{
        .name = "bytes after the name list",
        .kind = 0,
        .data = &[_]u8{ 0, 13, 0, 0, 10 } ++ "hello.test".* ++ [_]u8{0},
        .alert = .decode_error,
    },
    .{ .name = "an empty name list", .kind = 0, .data = &.{ 0, 0 }, .alert = .decode_error },
    .{
        .name = "a repeated server_name",
        .kind = 0,
        .extra = base_extensions[0],
        .data = base_extensions[0].data,
        .alert = .illegal_parameter,
    },
    .{ .name = "an empty ALPN list", .kind = 16, .data = &.{ 0, 0 }, .alert = .decode_error },
    .{
        .name = "an empty protocol",
        .kind = 16,
        .data = &[_]u8{ 0, 10, 8 } ++ "http/1.1".* ++ [_]u8{0},
        .alert = .decode_error,
    },
    .{
        .name = "bytes after the ALPN list",
        .kind = 16,
        .data = &[_]u8{ 0, 9, 8 } ++ "http/1.1".* ++ [_]u8{0},
        .alert = .decode_error,
    },
    .{
        .name = "a protocol longer than its list",
        .kind = 16,
        .data = &[_]u8{ 0, 9, 9 } ++ "http/1.1".*,
        .alert = .decode_error,
    },
    .{
        .name = "a repeated ALPN",
        .kind = 16,
        .extra = base_extensions[3],
        .data = base_extensions[3].data,
        .alert = .illegal_parameter,
    },
    .{ .name = "empty supported_groups", .kind = 10, .data = &.{ 0, 0 }, .alert = .decode_error },
    .{
        .name = "odd supported_groups",
        .kind = 10,
        .data = &.{ 0, 3, 0, 0x1d, 0 },
        .alert = .decode_error,
    },
    .{
        .name = "bytes after supported_groups",
        .kind = 10,
        .data = &.{ 0, 2, 0, 0x1d, 0 },
        .alert = .decode_error,
    },
    .{
        .name = "an x25519 share for a group not listed",
        .kind = 10,
        .data = &.{ 0, 2, 0, 0x17 },
        .alert = .illegal_parameter,
    },
};

test "public: the hand-built ClientHello is a correct one" {
    // Goal: the table below varies one extension of a hello the server takes. Method: the base
    // hello, unchanged, gets a ServerHello and the name it asks for.
    var rig: Rig = undefined;
    try rig.setup(.{ .root = undefined }, .{});
    var record_bytes: [2048]u8 = undefined;
    const record = hello_record(&record_bytes, &base_extensions);
    try testing.expect(try rig.feed(record, 4096) == .none);
    try testing.expect(rig.hello_alert() == null);
    try testing.expectEqualStrings("hello.test", rig.server.server_name().?);
    try testing.expect(rig.server.alpn_http11);
}

test "public: each malformed server_name, ALPN or supported_groups is refused with its alert" {
    // Goal: every strict check of the public extension readers is reached, not only the
    // well-formed names the fuzzer varies. Method: the correct hello with one extension broken.
    var rig: Rig = undefined;
    for (bad_extensions) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        try rig.setup(.{ .root = undefined }, .{});
        var extensions: [base_extensions.len + 1]Extension = undefined;
        var record_bytes: [2048]u8 = undefined;
        const used = extensions_with(&extensions, row.kind, row.data, row.extra);
        const record = hello_record(&record_bytes, used);
        try testing.expectError(error.Refused, rig.feed(record, 4096));
        try testing.expectEqual(@backingInt(row.alert), rig.hello_alert().?);
        try testing.expectEqual(PublicRefusal.other, rig.server.public_refusal().?);
        try testing.expect(rig.server.server_name() == null);
        try testing.expect(rig.diag.code != null);
    }
}
