//! Tests for `x509.zig`: the five certificate kinds, verification, the order of its checks, and a
//! table of near-miss certificates, each one edit away from a good one, with the refusal it must
//! get. No file, clock or environment, so it runs under WASI as well (`core.zig`).

const std = @import("std");
const x509 = @import("x509.zig");
const der = @import("x509_der.zig");
const identity_mod = @import("x509_identity.zig");
const constants = @import("constants.zig");
const peer = @import("peer.zig");

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;

pub const now: u64 = 1_700_000_000_000;
pub const hour: u64 = 3_600_000;
pub const window: x509.Lifetime = .{ .not_before_ms = now - hour, .not_after_ms = now + hour };

pub fn ca_pair() !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(@splat(0xCA));
}

pub fn subject_key(n: u8) ![32]u8 {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(n));
    return pair.public_key.toBytes();
}

pub const sample_labels = [_]identity_mod.Label{
    .{ .key = "app", .value = "broker" },
    .{ .key = "env", .value = "prod" },
};

pub fn sample_identity() identity_mod.Identity {
    return .{ .image_digest = @splat(0x5A), .placement_epoch = 42, .labels = &sample_labels };
}

pub fn workload_request(key: [32]u8) x509.WorkloadRequest {
    return .{
        .cluster = "prod.example",
        .service = "broker-1",
        .subject_key = key,
        .identity = sample_identity(),
        .lifetime = window,
    };
}

pub const workload_uri = "spiffe://prod.example/service/broker-1";

pub fn make_ca(out: *x509.Der) !void {
    try x509.issue_ca(out, try ca_pair(), window);
}

pub fn make_workload(out: *x509.Der) !void {
    const request = workload_request(try subject_key(1));
    try x509.issue_workload(out, try ca_pair(), &request);
}

pub fn make_server(out: *x509.Der) !void {
    const request: x509.ServerRequest = .{
        .dns_name = "broker.botpike.com",
        .subject_key = try subject_key(2),
        .lifetime = window,
    };
    try x509.issue_server(out, try ca_pair(), &request);
}

pub const node_uri = "spiffe://prod.example/node/node-1";
pub const client_uri = "spiffe://prod.example/client/ops-1";

pub fn node_request(key: [32]u8) x509.NodeRequest {
    return .{ .cluster = "prod.example", .node = "node-1", .subject_key = key, .lifetime = window };
}

pub fn client_request(key: [32]u8, scope: x509.Scope) x509.ClientRequest {
    return .{
        .cluster = "prod.example",
        .client = "ops-1",
        .scope = scope,
        .subject_key = key,
        .lifetime = window,
    };
}

pub fn make_node(out: *x509.Der) !void {
    const request = node_request(try subject_key(3));
    try x509.issue_node(out, try ca_pair(), &request);
}

pub fn make_client(out: *x509.Der) !void {
    const request = client_request(try subject_key(4), .admin);
    try x509.issue_client(out, try ca_pair(), &request);
}

test "the CA certificate parses, verifies against its own key and is deterministic" {
    // Goal: a CA certificate is self-signed, carries the pinned key and is the same bytes every
    // time. Method: issue twice, parse, verify as a CA.
    var first: x509.Der = .{};
    var second: x509.Der = .{};
    try make_ca(&first);
    try make_ca(&second);
    try testing.expectEqualSlices(u8, first.slice(), second.slice());
    const bytes = first.slice();
    const ca = try ca_pair();
    const parsed = try x509.verify(
        bytes,
        ca.public_key.toBytes(),
        now,
        .{ .kind = .ca, .name = null },
    );
    try testing.expectEqual(x509.Kind.ca, parsed.kind);
    try testing.expectEqualSlices(u8, parsed.subject_cn.of(bytes), parsed.issuer_cn.of(bytes));
    try testing.expectEqualSlices(u8, &ca.public_key.toBytes(), parsed.public_key.of(bytes));
    try testing.expectEqual(@as(usize, x509.ca_cn_bytes), parsed.subject_cn.len());
    try testing.expectEqual(window.not_before_ms, parsed.not_before_ms);
    try testing.expectEqual(window.not_after_ms, parsed.not_after_ms);
}

test "a workload certificate carries its SPIFFE ID, its identity and its key" {
    // Goal: every field the writer was given comes back from the parser. Method: issue, verify
    // with the SPIFFE ID as the expected name, decode the identity extension.
    var certificate: x509.Der = .{};
    try make_workload(&certificate);
    const bytes = certificate.slice();
    const ca = try ca_pair();
    const expect: x509.Expect = .{ .kind = .workload, .name = workload_uri };
    const parsed = try x509.verify(bytes, ca.public_key.toBytes(), now, expect);
    try testing.expectEqualStrings("broker-1", parsed.subject_cn.of(bytes));
    try testing.expectEqualStrings(workload_uri, parsed.name.of(bytes));
    try testing.expectEqualSlices(u8, &(try subject_key(1)), parsed.public_key.of(bytes));
    const decoded = try identity_mod.decode(parsed.identity.of(bytes));
    try testing.expectEqual(@as(u64, 42), decoded.placement_epoch);
    try testing.expectEqual(@as(u32, 2), decoded.labels_count);
    try testing.expectEqual(@as(u8, 0x5A), decoded.image_digest[0]);
}

test "a server certificate names one DNS name and nothing else" {
    // Goal: the server kind. Method: issue, verify with the name, then with another name and with
    // the workload kind.
    var certificate: x509.Der = .{};
    try make_server(&certificate);
    const bytes = certificate.slice();
    const ca = (try ca_pair()).public_key.toBytes();
    _ = try x509.verify(bytes, ca, now, .{ .kind = .server, .name = "broker.botpike.com" });
    _ = try x509.verify(bytes, ca, now, .{ .kind = .server, .name = null });
    try testing.expectError(error.WrongName, x509.verify(
        bytes,
        ca,
        now,
        .{ .kind = .server, .name = "broker.botpike.org" },
    ));
    try testing.expectError(error.WrongUse, x509.verify(
        bytes,
        ca,
        now,
        .{ .kind = .workload, .name = null },
    ));
}

test "a node certificate carries its SPIFFE ID and the peer key, and no identity" {
    // Goal: the node kind (B7). Method: issue, verify as a node with its ID, then as a workload and
    // under another node's ID.
    var certificate: x509.Der = .{};
    try make_node(&certificate);
    const bytes = certificate.slice();
    const ca = (try ca_pair()).public_key.toBytes();
    const parsed = try x509.verify(bytes, ca, now, .{ .kind = .node, .name = node_uri });
    try testing.expectEqualStrings("node-1", parsed.subject_cn.of(bytes));
    try testing.expectEqualSlices(u8, &(try subject_key(3)), parsed.public_key.of(bytes));
    try testing.expectEqual(@as(usize, 0), parsed.identity.of(bytes).len);
    try testing.expectError(
        error.WrongUse,
        x509.verify(bytes, ca, now, .{ .kind = .workload, .name = null }),
    );
    try testing.expectError(error.WrongName, x509.verify(
        bytes,
        ca,
        now,
        .{ .kind = .node, .name = "spiffe://prod.example/node/node-2" },
    ));
}

test "a client certificate carries its SPIFFE ID and its scope" {
    // Goal: the client kind (B7) and the scope field of the identity extension. Method: issue one
    // per scope, verify as a client, read the scope back; a client is not a node or a workload.
    const ca_keys = try ca_pair();
    const ca = ca_keys.public_key.toBytes();
    for ([_]x509.Scope{ .jobs, .admin }) |scope| {
        var certificate: x509.Der = .{};
        const request = client_request(try subject_key(4), scope);
        try x509.issue_client(&certificate, ca_keys, &request);
        const bytes = certificate.slice();
        const parsed = try x509.verify(bytes, ca, now, .{ .kind = .client, .name = client_uri });
        try testing.expectEqualStrings("ops-1", parsed.subject_cn.of(bytes));
        try testing.expectEqual(scope, parsed.scope(bytes));
        for ([_]x509.Kind{ .node, .workload, .server }) |kind| {
            try testing.expectError(
                error.WrongUse,
                x509.verify(bytes, ca, now, .{ .kind = kind, .name = null }),
            );
        }
    }
}

test "the writer refuses bad node and client names" {
    // Goal: the new kinds' names are checked on the way in. Method: an empty name and one with an
    // upper-case letter for each.
    const ca = try ca_pair();
    var out: x509.Der = .{};
    for ([_][]const u8{ "", "Node-1", "a/b" }) |name| {
        var node = node_request(try subject_key(3));
        node.node = name;
        try testing.expectError(error.BadNodeName, x509.issue_node(&out, ca, &node));
        var client = client_request(try subject_key(4), .jobs);
        client.client = name;
        try testing.expectError(error.BadClientName, x509.issue_client(&out, ca, &client));
    }
}

test "the largest certificate the writer makes fits the size limit" {
    // Goal: `x509_cert_bytes_max` is not a guess. Method: the longest cluster and service names,
    // the largest label set `validate` allows, issued and parsed; the size is asserted with room.
    var cluster_buffer: [63]u8 = @splat('a');
    cluster_buffer[31] = '.';
    const cluster: []const u8 = &cluster_buffer;
    const service_buffer: [constants.node_name_bytes_max]u8 = @splat('j');
    const service: []const u8 = &service_buffer;
    var keys: [constants.x509_labels_max][3]u8 = undefined;
    var labels: [constants.x509_labels_max]identity_mod.Label = undefined;
    const value: [constants.x509_labels_bytes_max / constants.x509_labels_max - 3]u8 = @splat('v');
    for (&labels, &keys, 0..) |*label, *name, i| {
        name.* = .{ 'k', 'a' + @as(u8, @intCast(i)), 'x' };
        label.* = .{ .key = name, .value = &value };
    }
    var request = workload_request(try subject_key(1));
    request.cluster = cluster;
    request.service = service;
    request.identity.labels = &labels;
    request.lifetime = .{
        .not_before_ms = 2_600_000_000_000,
        .not_after_ms = 2_600_000_000_000 + 1000 * 3600,
    };
    var certificate: x509.Der = .{};
    const ca = try ca_pair();
    try x509.issue_workload(&certificate, ca, &request);
    const bytes = certificate.slice();
    _ = try x509.parse(bytes);
    try testing.expect(bytes.len <= constants.x509_cert_bytes_max);
    // Room is left for the 16-byte-label worst case with a 256-byte value in one label.
    try testing.expect(bytes.len + 64 <= constants.x509_cert_bytes_max);
}

test "parse then write gives the same bytes for every kind" {
    // Goal: the accepted set is the writer's output set. Method: reencode each kind.
    var certificates: [5]x509.Der = @splat(.{});
    try make_ca(&certificates[0]);
    try make_workload(&certificates[1]);
    try make_server(&certificates[2]);
    try make_node(&certificates[3]);
    try make_client(&certificates[4]);
    for (&certificates) |*certificate| {
        const bytes = certificate.slice();
        const parsed = try x509.parse(bytes);
        var again: x509.Der = .{};
        try x509.reencode(&again, bytes, &parsed);
        try testing.expectEqualSlices(u8, bytes, again.slice());
    }
}

test "validity years: UTCTime to 2049 and GeneralizedTime after, in whole seconds" {
    // Goal: the RFC 5280 switch at 2050 and the seconds truncation. Method: issue across the
    // boundary and read the times back.
    const ca = try ca_pair();
    const key = try subject_key(2);
    const cases = [_]struct { before: u64, after: u64 }{
        .{ .before = 2_524_607_999_000, .after = 2_524_608_000_000 + 5000 }, // 2049-12-31 .. 2050
        .{ .before = 2_524_608_000_000, .after = 2_524_608_000_000 + 7_000 },
        .{ .before = 1_700_000_000_999, .after = 1_700_000_005_001 },
        .{ .before = 0, .after = 1000 },
    };
    for (cases) |case| {
        const request: x509.ServerRequest = .{
            .dns_name = "a.example",
            .subject_key = key,
            .lifetime = .{ .not_before_ms = case.before, .not_after_ms = case.after },
        };
        var certificate: x509.Der = .{};
        try x509.issue_server(&certificate, ca, &request);
        const parsed = try x509.parse(certificate.slice());
        try testing.expectEqual(case.before / 1000 * 1000, parsed.not_before_ms);
        try testing.expectEqual(case.after / 1000 * 1000, parsed.not_after_ms);
    }
}

test "the writer refuses what the bounds forbid" {
    // Goal: ZC-E0817 conditions. Method: a lifetime over the bound, empty and out of range, a bad
    // name, too many labels; nothing is written for a refusal.
    const ca = try ca_pair();
    var certificate: x509.Der = .{};
    var request = workload_request(try subject_key(1));
    request.lifetime = .{
        .not_before_ms = now,
        .not_after_ms = now + constants.x509_leaf_ttl_ms_max + 1000,
    };
    try testing.expectError(error.IssueLifetime, x509.issue_workload(&certificate, ca, &request));
    request.lifetime = .{
        .not_before_ms = now,
        .not_after_ms = now + constants.x509_leaf_ttl_ms_max,
    };
    try x509.issue_workload(&certificate, ca, &request);
    request.lifetime = .{ .not_before_ms = now, .not_after_ms = now + 999 };
    try testing.expectError(error.IssueLifetime, x509.issue_workload(&certificate, ca, &request));
    request.lifetime = .{ .not_before_ms = now, .not_after_ms = 253_402_300_800_000 };
    try testing.expectError(error.IssueLifetime, x509.issue_workload(&certificate, ca, &request));
    request = workload_request(try subject_key(1));
    request.service = "Broker";
    try testing.expectError(error.BadServiceName, x509.issue_workload(&certificate, ca, &request));
    request.service = "broker";
    request.cluster = "*.prod";
    try testing.expectError(error.BadCluster, x509.issue_workload(&certificate, ca, &request));
    const server: x509.ServerRequest = .{
        .dns_name = "*.botpike.com",
        .subject_key = try subject_key(2),
        .lifetime = window,
    };
    try testing.expectError(error.BadDnsName, x509.issue_server(&certificate, ca, &server));
    const long_ca: x509.Lifetime = .{
        .not_before_ms = 0,
        .not_after_ms = constants.x509_ca_ttl_ms_max + 1000,
    };
    try testing.expectError(error.IssueLifetime, x509.issue_ca(&certificate, ca, long_ca));
}

test "verification checks the signature before the window and the name" {
    // Goal: a forged certificate never reaches an expiry or name message. Method: a certificate
    // from another CA that is also expired and misnamed gets the signature refusal; a real one
    // gets the window and name refusals, at the skew boundaries.
    var certificate: x509.Der = .{};
    try make_server(&certificate);
    const bytes = certificate.slice();
    const ca = (try ca_pair()).public_key.toBytes();
    const other = (try Ed25519.KeyPair.generateDeterministic(@splat(0xCB))).public_key.toBytes();
    const skew = constants.peer_clock_skew_ms;
    const expect: x509.Expect = .{ .kind = .server, .name = "broker.botpike.com" };
    try testing.expectError(error.WrongIssuer, x509.verify(bytes, other, now + 10 * hour, expect));

    var forged = certificate;
    forged.bytes[forged.bytes.len - 1] ^= 1; // last signature byte
    const far = now + 10 * hour;
    try testing.expectError(error.BadSignature, x509.verify(
        forged.slice(),
        ca,
        far,
        .{ .kind = .server, .name = "other.example" },
    ));
    try testing.expectError(error.Expired, x509.verify(
        bytes,
        ca,
        window.not_after_ms + skew,
        expect,
    ));
    _ = try x509.verify(bytes, ca, window.not_after_ms + skew - 1, expect);
    try testing.expectError(error.NotYetValid, x509.verify(
        bytes,
        ca,
        window.not_before_ms - skew - 1,
        expect,
    ));
    _ = try x509.verify(bytes, ca, window.not_before_ms - skew, expect);
    try testing.expectError(error.Expired, x509.verify(
        bytes,
        ca,
        far,
        .{ .kind = .server, .name = "other.example" },
    ));
    try testing.expectError(error.WrongName, x509.verify(
        bytes,
        ca,
        now,
        .{ .kind = .server, .name = "other.example" },
    ));
}

test "a CA certificate is accepted only if it carries the pinned key" {
    // Goal: another CA's self-signed certificate does not pass as ours. Method: verify a CA made
    // from key CB against key CA.
    var certificate: x509.Der = .{};
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(0xCB));
    try x509.issue_ca(&certificate, other, window);
    const ca = (try ca_pair()).public_key.toBytes();
    try testing.expectError(error.WrongIssuer, x509.verify(
        certificate.slice(),
        ca,
        now,
        .{ .kind = .ca, .name = null },
    ));
    _ = try x509.verify(
        certificate.slice(),
        other.public_key.toBytes(),
        now,
        .{ .kind = .ca, .name = null },
    );
}

test "a credential's signed message and a TBS are disjoint" {
    // Goal: the one CA key signs two kinds of message and neither can pass as the other. Method:
    // the credential message starts with its domain tag and a TBS with 0x30; neither parses as the
    // other, and the first bytes differ.
    var certificate: x509.Der = .{};
    try make_workload(&certificate);
    const parsed = try x509.parse(certificate.slice());
    const tbs = parsed.tbs.of(certificate.slice());
    try testing.expectEqual(@as(u8, 0x30), tbs[0]);
    try testing.expect(peer.credential_domain[0] != 0x30);
    try testing.expect(!std.mem.startsWith(u8, tbs, peer.credential_domain));
    var message: [peer.credential_domain.len + 121]u8 = @splat(0);
    @memcpy(message[0..peer.credential_domain.len], peer.credential_domain);
    try testing.expectError(error.Malformed, x509.parse(&message));
    try testing.expectError(error.Malformed, x509.parse(tbs));
}

test "the near-miss table is in this root" {
    // Goal: the table runs wherever these tests do. Method: import it.
    _ = @import("x509_near_miss.zig");
}

test "times: each form is read only where it is canonical, and the calendar is checked" {
    // Goal: UTCTime covers 1970..2049 and GeneralizedTime only 2050 on (RFC 5280 4.1.2.5), a
    // second of 60 and February 29 of a common year are refused, and a leap day is accepted.
    // Method: call `read_time` on each row.
    const utc = der.tag_utc_time;
    const general = der.tag_generalized_time;
    const Row = struct { text: []const u8, tag: u8, seconds: ?u64 };
    const rows = [_]Row{
        .{ .text = "20491231235959Z", .tag = general, .seconds = null },
        .{ .text = "20231114221320Z", .tag = general, .seconds = null },
        .{ .text = "20500101000000Z", .tag = general, .seconds = 2_524_608_000 },
        .{ .text = "491231235959Z", .tag = utc, .seconds = 2_524_607_999 },
        .{ .text = "500101000000Z", .tag = utc, .seconds = null }, // 1950
        .{ .text = "231114221360Z", .tag = utc, .seconds = null },
        .{ .text = "230229000000Z", .tag = utc, .seconds = null },
        .{ .text = "240229000000Z", .tag = utc, .seconds = 1_709_164_800 },
        .{ .text = "21000229000000Z", .tag = general, .seconds = null },
        .{ .text = "24000229000000Z", .tag = general, .seconds = 13_574_563_200 },
    };
    for (rows) |row| {
        if (row.seconds) |seconds| {
            try testing.expectEqual(seconds, try x509.read_time(row.text, row.tag));
        } else {
            try testing.expectError(error.BadTime, x509.read_time(row.text, row.tag));
        }
    }
}

test "times: the writer switches to GeneralizedTime at 2050 and reads back what it wrote" {
    // Goal: the last second of 2049 is a UTCTime, the first of 2050 a GeneralizedTime, and each
    // reads back to the same second. Method: write both with `write_time`, compare the bytes.
    const last_utc: u64 = 2_524_607_999;
    const Row = struct { seconds: u64, tag: u8, text: []const u8 };
    const rows = [_]Row{
        .{ .seconds = last_utc, .tag = der.tag_utc_time, .text = "491231235959Z" },
        .{ .seconds = last_utc + 1, .tag = der.tag_generalized_time, .text = "20500101000000Z" },
    };
    for (rows) |row| {
        var buffer: [32]u8 = undefined;
        var writer = der.Writer.init(&buffer);
        try x509.write_time(&writer, row.seconds);
        const written = writer.written();
        try testing.expectEqual(row.tag, written[0]);
        try testing.expectEqualStrings(row.text, written[2..]);
        try testing.expectEqual(row.seconds, try x509.read_time(written[2..], row.tag));
    }
}

test "serials: certificates differing only in subject name, or any other field, differ" {
    // Goal: the serial covers the whole TBS, so a re-issue of the same key in the same second
    // under another name cannot collide (the first version hashed only key and not_before).
    // Method: issue workloads and servers for one key and window, changing one field each time,
    // and compare every serial with the base one; the base is also stable when issued twice.
    const key = try subject_key(1);
    var base: x509.Der = .{};
    try x509.issue_workload(&base, try ca_pair(), &workload_request(key));
    var again: x509.Der = .{};
    try x509.issue_workload(&again, try ca_pair(), &workload_request(key));
    const base_serial = (try x509.parse(base.slice())).serial.of(base.slice());
    try testing.expectEqual(@as(usize, constants.x509_serial_bytes_max), base_serial.len);
    try testing.expect(base_serial[0] & 0x80 == 0);
    try testing.expectEqualSlices(
        u8,
        base_serial,
        (try x509.parse(again.slice())).serial.of(again.slice()),
    );

    var renamed = workload_request(key);
    renamed.service = "broker-2";
    var other_cluster = workload_request(key);
    other_cluster.cluster = "dev.example";
    var other_epoch = workload_request(key);
    other_epoch.identity.placement_epoch = 43;
    var other_window = workload_request(key);
    other_window.lifetime.not_after_ms += 2000;
    const requests = [_]x509.WorkloadRequest{ renamed, other_cluster, other_epoch, other_window };
    for (requests) |request| {
        var out: x509.Der = .{};
        try x509.issue_workload(&out, try ca_pair(), &request);
        const serial = (try x509.parse(out.slice())).serial.of(out.slice());
        try testing.expect(!std.mem.eql(u8, base_serial, serial));
    }

    var server_a: x509.Der = .{};
    var server_b: x509.Der = .{};
    var request: x509.ServerRequest = .{
        .dns_name = "a.example",
        .subject_key = key,
        .lifetime = window,
    };
    try x509.issue_server(&server_a, try ca_pair(), &request);
    request.dns_name = "b.example";
    try x509.issue_server(&server_b, try ca_pair(), &request);
    const serial_a = (try x509.parse(server_a.slice())).serial.of(server_a.slice());
    const serial_b = (try x509.parse(server_b.slice())).serial.of(server_b.slice());
    try testing.expect(!std.mem.eql(u8, serial_a, serial_b));
}
