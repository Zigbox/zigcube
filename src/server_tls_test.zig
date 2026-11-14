//! Tests for the API server's check before each request on a TLS connection (B7 slice 5,
//! `server_tls.Setup.recheck`): a peer whose certificate expired, or whose name was revoked,
//! after its handshake is refused with the handshake's codes. The clock and the revoked set are
//! the test's, so every case is deterministic. The teeth switch each check off.

const std = @import("std");
const testing = std.testing;
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const server_tls = @import("server_tls.zig");
const tls_server = @import("tls_server.zig");
const x509_identity = @import("x509_identity.zig");
const constants = @import("constants.zig");

const Diag = diag_mod.Diag;
const Code = @import("diag/codes.zig").Code;
const Ed25519 = std.crypto.sign.Ed25519;
const ManualClock = @import("clock.zig").ManualClock;

const minute_ms: u64 = 60 * 1000;
const hour_ms: u64 = 60 * minute_ms;
/// The client certificate's window in the tests: one hour from `born_ms`.
const born_ms: u64 = 1_700_000_000_000;
const dies_ms: u64 = born_ms + hour_ms;

const Rig = struct {
    clock: ManualClock = .{ .ms = born_ms },
    ca: peer_ca.Ca = undefined,
    setup: server_tls.Setup = undefined,
    spiffe: [constants.x509_spiffe_bytes_max]u8 = undefined,
    diag: Diag = undefined,

    fn start(rig: *Rig) !void {
        rig.ca = .{
            .key = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA)),
            .revoked = .{},
            .wall = rig.clock.clock(),
        };
        rig.diag.reset();
        try rig.setup.init(testing.io, &rig.ca, "api.test", &rig.diag);
    }

    fn stop(rig: *Rig) void {
        rig.setup.deinit();
    }

    /// The peer a handshake would have authenticated: `kind`'s certificate for `name`.
    fn peer(rig: *Rig, kind: enum { node, client }, name: []const u8) !tls_server.Peer {
        const cluster = rig.setup.cluster_buffer[0..rig.setup.cluster_length];
        return switch (kind) {
            .node => .{
                .kind = .node,
                .name = try x509_identity.spiffe_write(&rig.spiffe, .node, cluster, name),
                .scope = null,
                .not_before_ms = born_ms,
                .not_after_ms = dies_ms,
            },
            .client => .{
                .kind = .client,
                .name = try x509_identity.spiffe_write(&rig.spiffe, .client, cluster, name),
                .scope = .jobs,
                .not_before_ms = born_ms,
                .not_after_ms = dies_ms,
            },
        };
    }

    /// The check before a request at `now_ms`: null when it passes, else the code it raised.
    fn check(rig: *Rig, client: tls_server.Peer, now_ms: u64) ?Code {
        rig.clock.ms = now_ms;
        rig.diag.reset();
        if (rig.setup.recheck_peer(client, &rig.diag)) {
            std.debug.assert(rig.diag.code == null);
            return null;
        }
        return rig.diag.code.?;
    }

    fn revoke(rig: *Rig, text: []const u8) !void {
        try rig.ca.revoked.parse(text);
    }
};

test "recheck: the certificate's window, with the clock skew allowed on each side" {
    // Goal: part B's expiry check uses the handshake's rule (x509.window): valid from
    // not_before - 60 s to not_after + 60 s. Method: a table of clock readings.
    var rig: Rig = .{};
    try rig.start();
    defer rig.stop();
    const peer = try rig.peer(.client, "ops");
    const skew = constants.peer_clock_skew_ms;
    const rows = [_]struct { now_ms: u64, code: ?Code }{
        .{ .now_ms = born_ms - skew - 1, .code = .E0811 },
        .{ .now_ms = born_ms - skew, .code = null },
        .{ .now_ms = born_ms + 10 * minute_ms, .code = null },
        .{ .now_ms = dies_ms + skew - 1, .code = null },
        .{ .now_ms = dies_ms + skew, .code = .E0811 },
        .{ .now_ms = dies_ms + 2 * hour_ms, .code = .E0811 },
    };
    for (rows) |row| {
        try testing.expectEqual(row.code, rig.check(peer, row.now_ms));
    }
}

test "recheck: a certificate that expires mid-connection is refused, and the cause says so" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.stop();
    try testing.expect(expiry_caught(&rig));
    try testing.expect(std.mem.indexOf(u8, rig.diag.last_cause().?, "closed") != null);
}

test "recheck: a name revoked mid-connection is refused, by kind" {
    // Goal: part B's revocation check reads the CA's current set, with the file's kind rule:
    // `node/NAME` refuses only the node, a bare name refuses both.
    var rig: Rig = .{};
    try rig.start();
    defer rig.stop();
    const node = try rig.peer(.node, "node1");
    const now_ms = born_ms + minute_ms;
    try testing.expectEqual(@as(?Code, null), rig.check(node, now_ms));
    try rig.revoke("client/node1\n");
    try testing.expectEqual(@as(?Code, null), rig.check(node, now_ms));
    try rig.revoke("node/node1\n");
    try testing.expectEqual(@as(?Code, .E0819), rig.check(node, now_ms));
    try testing.expect(std.mem.indexOf(u8, rig.diag.last_cause().?, "revoked after") != null);
    try rig.revoke("");
    try testing.expectEqual(@as(?Code, null), rig.check(node, now_ms));
    try testing.expect(revocation_caught(&rig));
}

/// The check the expiry tooth breaks: a connection whose certificate expires is refused.
fn expiry_caught(rig: *Rig) bool {
    const peer = rig.peer(.client, "ops") catch unreachable; // "ops" is a valid name.
    if (rig.check(peer, born_ms + minute_ms) != null) return false;
    return rig.check(peer, dies_ms + hour_ms) == .E0811;
}

/// The check the revocation tooth breaks: a client revoked by bare name is refused.
fn revocation_caught(rig: *Rig) bool {
    const peer = rig.peer(.client, "ops") catch unreachable; // "ops" is a valid name.
    if (rig.check(peer, born_ms + minute_ms) != null) return false;
    rig.revoke("ops\n") catch unreachable; // One valid name.
    defer rig.revoke("") catch unreachable; // Empty text always parses.
    return rig.check(peer, born_ms + minute_ms) == .E0819;
}

test "teeth: with the expiry recheck skipped an expired connection is served" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.stop();
    server_tls.set_test_fault(.recheck_expiry, true);
    defer server_tls.set_test_fault(.recheck_expiry, false);
    try testing.expect(!expiry_caught(&rig));
}

test "teeth: with the revocation recheck skipped a revoked connection is served" {
    var rig: Rig = .{};
    try rig.start();
    defer rig.stop();
    server_tls.set_test_fault(.recheck_revoked, true);
    defer server_tls.set_test_fault(.recheck_revoked, false);
    try testing.expect(!revocation_caught(&rig));
}
