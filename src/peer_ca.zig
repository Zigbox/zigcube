//! The cluster CA as the control-plane core sees it (docs/peer.md, "Trust model"): a signing key,
//! the list of removed nodes, and a wall clock. The shell (`server_ca.zig`) loads or makes the key
//! and reads the `revoked` file; this file only decides whether to sign, and signs. No file, no
//! randomness, no clock of its own: the clock is the `Clock` it is given.
//!
//! The CA is not a store writer (authority.md): it signs credentials and writes no key.

const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const Edwards25519 = std.crypto.ecc.Edwards25519;
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const peer = @import("peer.zig");
const records = @import("records.zig");

/// The names of removed nodes: one per line, `#` starts a comment, blank lines are ignored.
pub const Revoked = struct {
    names: [constants.peer_revoked_max][peer.name_bytes_max]u8 = undefined,
    lengths: [constants.peer_revoked_max]u8 = undefined,
    count: u32 = 0,
    /// After a failed `parse`, the 1-based line that was refused.
    bad_line: u32 = 0,

    pub const ParseError = error{ TooMany, BadName };

    /// Replaces the list with `text`'s names. A name that is not a node name, or more than
    /// `peer_revoked_max` names, is refused whole (and the list is then empty).
    pub fn parse(revoked: *Revoked, text: []const u8) ParseError!void {
        revoked.count = 0;
        revoked.bad_line = 0;
        var line_number: u32 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            line_number += 1;
            const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
            const line = std.mem.trim(u8, raw[0..hash], " \t\r");
            if (line.len == 0) continue;
            revoked.bad_line = line_number;
            if (records.name_problem(line, peer.name_bytes_max) != null) {
                revoked.count = 0;
                return error.BadName;
            }
            if (revoked.count == constants.peer_revoked_max) {
                revoked.count = 0;
                return error.TooMany;
            }
            const slot = revoked.count;
            revoked.names[slot] = @splat(0);
            @memcpy(revoked.names[slot][0..line.len], line);
            revoked.lengths[slot] = @intCast(line.len);
            revoked.count += 1;
        }
        revoked.bad_line = 0;
    }

    pub fn contains(revoked: *const Revoked, node: []const u8) bool {
        assert(revoked.count <= constants.peer_revoked_max);
        for (0..revoked.count) |index| {
            const name = revoked.names[index][0..revoked.lengths[index]];
            if (std.mem.eql(u8, name, node)) return true;
        }
        return false;
    }
};

pub const Ca = struct {
    key: Ed25519.KeyPair,
    revoked: Revoked,
    /// Unix milliseconds (the real clock, in the shell): credentials start at its `now`.
    wall: Clock,

    pub const IssueError = error{ Removed, BadKey };

    pub fn public(ca: *const Ca) [32]u8 {
        return ca.key.public_key.toBytes();
    }

    /// Signs `node_key` as `node`'s key for `peer_credential_ttl_ms` from now. A removed node is
    /// refused (ZC-E0807 is the caller's to raise), and so is a key that is not a valid Ed25519
    /// public key, which no handshake could use. The caller has checked the node's name.
    pub fn issue(ca: *const Ca, node: []const u8, node_key: [32]u8) IssueError!peer.Credential {
        assert(records.name_problem(node, peer.name_bytes_max) == null);
        if (ca.revoked.contains(node)) return error.Removed;
        // On the curve and in the prime-order subgroup: a small-order or mixed-order point is
        // refused, so no credential vouches for a key no honest node holds.
        const point = Edwards25519.fromBytes(node_key) catch return error.BadKey;
        point.rejectUnexpectedSubgroup() catch return error.BadKey;
        const now_ms = ca.wall.now_ms();
        const credential = peer.issue(
            ca.key,
            node,
            node_key,
            now_ms,
            now_ms + constants.peer_credential_ttl_ms,
        );
        assert(credential.not_after_ms > credential.not_before_ms);
        return credential;
    }
};

test "the revoked list: names, comments, blanks, and refusals" {
    // Goal: the file's format is exactly as docs/peer.md says. Method: parse good and bad text.
    var revoked: Revoked = .{};
    try revoked.parse("# removed\nnode3\n\n  node4  # moved\r\n");
    try std.testing.expectEqual(@as(u32, 2), revoked.count);
    try std.testing.expect(revoked.contains("node3"));
    try std.testing.expect(revoked.contains("node4"));
    try std.testing.expect(!revoked.contains("node"));
    try std.testing.expect(!revoked.contains("node5"));
    try std.testing.expectError(error.BadName, revoked.parse("node3\nBad Name\n"));
    try std.testing.expectEqual(@as(u32, 2), revoked.bad_line);
    try std.testing.expectEqual(@as(u32, 0), revoked.count);
    try revoked.parse("");
    try std.testing.expectEqual(@as(u32, 0), revoked.count);
}

test "the revoked list holds peer_revoked_max names and refuses one more" {
    // Goal: the bound is a refusal, not a silent cut. Method: fill it, then add one.
    const line_bytes = 7; // "n00000\n"
    var buffer: [(constants.peer_revoked_max + 1) * line_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (0..constants.peer_revoked_max + 1) |index| {
        writer.print("n{d:0>5}\n", .{index}) catch unreachable; // Sized above.
    }
    var revoked: Revoked = .{};
    const full = constants.peer_revoked_max * line_bytes;
    try revoked.parse(buffer[0..full]);
    try std.testing.expectEqual(constants.peer_revoked_max, revoked.count);
    try std.testing.expectError(error.TooMany, revoked.parse(writer.buffered()));
}

const TestClock = struct {
    ms: u64,

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    fn now(context: *anyopaque) u64 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        return self.ms;
    }
};

test "the CA signs for a live node, refuses a removed one and a bad key" {
    // Goal: issuance follows the rules in docs/peer.md. Method: issue, verify with the public
    // key at the issue time, then try a removed node and a key that is not on the curve.
    var clock: TestClock = .{ .ms = 1_000_000 };
    var ca: Ca = .{
        .key = try Ed25519.KeyPair.generateDeterministic(@splat(7)),
        .revoked = .{},
        .wall = clock.clock(),
    };
    try ca.revoked.parse("gone\n");
    const node_pair = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const node_key = node_pair.public_key.toBytes();
    const credential = try ca.issue("node1", node_key);
    try std.testing.expectEqual(@as(u64, 1_000_000), credential.not_before_ms);
    try std.testing.expectEqual(
        1_000_000 + constants.peer_credential_ttl_ms,
        credential.not_after_ms,
    );
    try peer.verify(&credential, ca.public(), 1_000_000, "node1");
    try std.testing.expectError(error.Removed, ca.issue("gone", node_key));
    // 32 bytes of 0xff is not a point on the curve.
    const off_curve: [32]u8 = @splat(0xff);
    try std.testing.expectError(error.BadKey, ca.issue("node1", off_curve));
}
