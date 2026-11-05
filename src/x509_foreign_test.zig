//! Tests for the `foreign_server` profile of `x509.zig`: server leaves that OpenSSL made under an
//! anchor of another CA (`testdata/x509/gen.sh` made them; nothing runs OpenSSL here), and the
//! near-miss table for that profile. No file, clock or environment, so it runs under WASI too.

const std = @import("std");
const x509 = @import("x509.zig");
const t = @import("x509_test.zig");

const testing = std.testing;

const anchor: [32]u8 = @embedFile("testdata/x509/anchor.pub").*;
const other: [32]u8 = @embedFile("testdata/x509/other.pub").*;
const minimal = @embedFile("testdata/x509/minimal.der");
const defaults = @embedFile("testdata/x509/defaults.der");
const client = @embedFile("testdata/x509/client.der");
const ca_true = @embedFile("testdata/x509/ca_true.der");
const unknown_critical = @embedFile("testdata/x509/unknown_critical.der");
const two_unknown = @embedFile("testdata/x509/two_unknown.der");
const serial21 = @embedFile("testdata/x509/serial21.der");

const name = "broker.botpike.com";

/// An hour into the fixture's window: the fixtures carry the dates of the day `gen.sh` ran.
fn inside(bytes: []const u8) !u64 {
    var detail: x509.Detail = .{};
    const parsed = try x509.parse_profile(bytes, .foreign_server, &detail);
    return parsed.not_before_ms + t.hour;
}

fn verify(bytes: []const u8, key: [32]u8, now_ms: u64, expected: []const u8) x509.Error!void {
    var detail: x509.Detail = .{};
    _ = try x509.verify_foreign_server(bytes, key, now_ms, expected, &detail);
}

test "foreign profile: a minimal OpenSSL leaf and one with OpenSSL's usual extras verify" {
    // Goal: the profile accepts what another CA really writes: any issuer and subject Name, a
    // 20-byte serial, the key identifiers, extensions in OpenSSL's order. Method: verify the two
    // committed fixtures under their anchor an hour into their window.
    for ([_][]const u8{ minimal, defaults }) |bytes| {
        try verify(bytes, anchor, try inside(bytes), name);
        var detail: x509.Detail = .{};
        const parsed = try x509.parse_profile(bytes, .foreign_server, &detail);
        try testing.expectEqual(x509.Kind.server, parsed.kind);
        try testing.expectEqualStrings(name, parsed.name.of(bytes));
    }
}

test "foreign profile: the strict cluster profile refuses the OpenSSL leaves" {
    // Goal: the two profiles stay apart; the cluster profile does not drift toward OpenSSL.
    // Method: parse both fixtures under `cluster`.
    for ([_][]const u8{ minimal, defaults }) |bytes| {
        if (x509.parse(bytes)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "foreign profile: this cluster's own server certificate passes it too" {
    // Goal: the cluster profile is a subset of the foreign one for server leaves. Method: issue a
    // server certificate and verify it with `verify_foreign_server` under the CA's key.
    var server: x509.Der = .{};
    try t.make_server(&server);
    const ca = try t.ca_pair();
    try verify(server.slice(), ca.public_key.toBytes(), t.now, name);
}

test "foreign profile: near misses get the refusal they must" {
    // Goal: each row is one edit from `minimal.der` (or a fixture made one edit away) and must be
    // refused with exactly this error. Method: the table below; the duplicate row renames OID
    // 1.2.3.5 to 1.2.3.4 in `two_unknown.der`, which the parse refuses before the signature.
    const now_ms = try inside(minimal);
    var detail: x509.Detail = .{};
    const parsed = try x509.parse_profile(minimal, .foreign_server, &detail);
    const skew = @import("constants.zig").peer_clock_skew_ms;
    var duplicate: [two_unknown.len]u8 = two_unknown.*;
    rename_oid(&duplicate);
    var tampered: [minimal.len]u8 = minimal.*;
    tamper_subject(&tampered);
    const Row = struct {
        bytes: []const u8,
        key: [32]u8 = anchor,
        now: u64,
        name: []const u8 = name,
        err: x509.Error,
    };
    const late = parsed.not_after_ms + skew;
    const rows = [_]Row{
        .{ .bytes = minimal, .key = other, .now = now_ms, .err = error.BadSignature },
        .{ .bytes = &tampered, .now = now_ms, .err = error.BadSignature },
        .{ .bytes = minimal, .now = late, .err = error.Expired },
        .{ .bytes = minimal, .now = now_ms, .name = "other.botpike.com", .err = error.WrongName },
        .{ .bytes = client, .now = now_ms, .err = error.WrongUse },
        .{ .bytes = ca_true, .now = now_ms, .err = error.WrongUse },
        .{ .bytes = unknown_critical, .now = now_ms, .err = error.UnknownCritical },
        .{ .bytes = &duplicate, .now = now_ms, .err = error.DuplicateExtension },
        .{ .bytes = serial21, .now = now_ms, .err = error.BadSerial },
    };
    for (rows, 0..) |row, index| {
        verify(row.bytes, row.key, row.now, row.name) catch |err| {
            if (err == row.err) continue;
            std.debug.print("row {d}: got {t}, want {t}\n", .{ index, err, row.err });
            return error.TestUnexpectedResult;
        };
        std.debug.print("row {d}: accepted, want {t}\n", .{ index, row.err });
        return error.TestUnexpectedResult;
    }
    // The control: the unedited fixture with two unknown non-critical extensions is accepted.
    try verify(two_unknown, anchor, now_ms, name);
}

fn rename_oid(bytes: []u8) void {
    const from = [_]u8{ 0x06, 0x03, 0x2A, 0x03, 0x05 };
    const at = std.mem.indexOf(u8, bytes, &from).?; // gen.sh writes 1.2.3.5 into two_unknown.der.
    bytes[at + 4] = 0x04;
}

/// One letter of the subject's commonName: the shape still parses, the signature must not.
fn tamper_subject(bytes: []u8) void {
    const subject = [_]u8{ 0x0C, 0x12 } ++ "broker.botpike.com";
    const at = std.mem.indexOf(u8, bytes, subject).?; // The subject CN of minimal.der.
    bytes[at + 2] = 'c';
}
