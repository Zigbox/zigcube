//! Table tests for the agent's check before each API connection (B7 slice 5, part A:
//! `api_tls_guard.zig`): a certificate in its window, near its expiry, expired with and without
//! a usable `--cert`, and not yet valid. The clock is manual and the certificates are issued in
//! memory, so every case is deterministic; the teeth switch the check off.

const std = @import("std");
const testing = std.testing;
const api_tls_client = @import("api_tls_client.zig");
const api_tls_guard = @import("api_tls_guard.zig");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const x509 = @import("x509.zig");

const Credentials = api_tls_client.Credentials;
const Diag = diag_mod.Diag;
const Code = @import("diag/codes.zig").Code;
const Ed25519 = std.crypto.sign.Ed25519;
const ManualClock = @import("clock.zig").ManualClock;

const day_ms: u64 = 24 * 3_600_000;
const born_ms: u64 = 1_700_000_000_000;

/// A certificate issued in memory, with its key.
const Issued = struct {
    der: x509.Der = .{},
    key: Ed25519.KeyPair = undefined,
};

/// `--cert` held in memory: what `FileFallback` reads from its files.
const MemoryFallback = struct {
    issued: ?*const Issued,
    loads: u32 = 0,

    fn fallback(memory: *MemoryFallback) api_tls_guard.Fallback {
        return .{ .context = memory, .load = load };
    }

    fn load(context: *anyopaque, trial: *Credentials, now_ms: u64) ?[]const u8 {
        const memory: *MemoryFallback = @ptrCast(@alignCast(context));
        memory.loads += 1;
        const issued = memory.issued orelse return "it does not exist";
        return trial.present(&issued.der, issued.key, "node1", now_ms);
    }
};

const Rig = struct {
    clock: ManualClock = .{ .ms = born_ms },
    ca: peer_ca.Ca = undefined,
    credentials: Credentials = undefined,
    stored: Issued = .{},
    memory: MemoryFallback = .{ .issued = null },
    guard: api_tls_guard.Guard = undefined,
    diag: Diag = undefined,

    /// The agent presents `stored`, valid one day from `born_ms`; `--cert` is `cert` if any.
    fn start(rig: *Rig, cert: ?*const Issued, with_fallback: bool) !void {
        rig.ca = .{
            .key = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA)),
            .revoked = .{},
            .wall = rig.clock.clock(),
        };
        try rig.issue(&rig.stored, 1, born_ms, born_ms + day_ms);
        rig.credentials.anchor = rig.ca.public();
        rig.credentials.server_name = api_tls_client.server_name_default;
        rig.credentials.certificate = .{};
        try testing.expectEqual(@as(?[]const u8, null), rig.credentials.present(
            &rig.stored.der,
            rig.stored.key,
            "node1",
            born_ms,
        ));
        rig.memory = .{ .issued = cert };
        rig.guard = .{
            .io = testing.io,
            .wall = rig.clock.clock(),
            .fallback = if (with_fallback) rig.memory.fallback() else null,
            .silent = true,
        };
    }

    fn issue(rig: *Rig, out: *Issued, seed: u8, not_before_ms: u64, not_after_ms: u64) !void {
        out.key = try Ed25519.KeyPair.generateDeterministic(@splat(seed));
        try rig.ca.issue_node_certificate(&out.der, &.{
            .node = "node1",
            .subject_key = out.key.public_key.toBytes(),
            .lifetime = .{ .not_before_ms = not_before_ms, .not_after_ms = not_after_ms },
        });
    }

    /// The check at `now_ms`: null when it passes, else the code it raised.
    fn check(rig: *Rig, now_ms: u64) ?Code {
        rig.clock.ms = now_ms;
        rig.diag.reset();
        rig.guard.check(&rig.credentials, &rig.diag) catch return rig.diag.code.?;
        return null;
    }

    fn has_cause(rig: *const Rig, text: []const u8) bool {
        var index: u32 = 0;
        while (index < rig.diag.causes.count) : (index += 1) {
            const cause = rig.diag.causes.items[index].slice();
            if (std.mem.indexOf(u8, cause, text) != null) return true;
        }
        return false;
    }

    fn presents(rig: *const Rig, issued: *const Issued) bool {
        return std.mem.eql(u8, rig.credentials.certificate.slice(), issued.der.slice());
    }
};

test "guard: a certificate in its window passes, with no line" {
    var rig: Rig = .{};
    try rig.start(null, false);
    try testing.expectEqual(@as(?Code, null), rig.check(born_ms + 3_600_000));
    try testing.expectEqual(@as(?Code, null), rig.check(born_ms + day_ms / 2));
    try testing.expectEqual(@as(u32, 0), rig.guard.lines);
}

test "guard: past 3/4 of its life it warns once, naming the expiry and the renewal error" {
    var rig: Rig = .{};
    try rig.start(null, false);
    const late_ms = born_ms + day_ms - day_ms / 4;
    try testing.expectEqual(@as(?Code, null), rig.check(late_ms - 1));
    try testing.expectEqual(@as(u32, 0), rig.guard.lines);
    var failed: Diag = undefined;
    failed.reset();
    failed.raise(.E0802);
    failed.cause("the server refused the renewal", .{});
    rig.guard.renewal_failed(&failed);
    try testing.expectEqual(@as(?Code, null), rig.check(late_ms));
    try testing.expectEqual(@as(u32, 1), rig.guard.lines);
    const line = rig.guard.last_line();
    try testing.expect(std.mem.indexOf(u8, line, "3/4") != null);
    try testing.expect(std.mem.indexOf(u8, line, "2023-11-15T22:13:20Z") != null);
    try testing.expect(std.mem.indexOf(u8, line, "ZC-E0802: the server refused") != null);
    try testing.expectEqual(@as(?Code, null), rig.check(late_ms + 60_000));
    try testing.expectEqual(@as(u32, 1), rig.guard.lines); // Once.
    // A renewal: a new certificate arms the line again, and the renewal error is gone.
    var renewed: Issued = .{};
    try rig.issue(&renewed, 2, late_ms, late_ms + day_ms);
    rig.guard.renewed();
    try testing.expectEqual(@as(?[]const u8, null), rig.credentials.present(
        &renewed.der,
        renewed.key,
        "node1",
        late_ms,
    ));
    try testing.expectEqual(@as(?Code, null), rig.check(late_ms + day_ms - day_ms / 4));
    try testing.expectEqual(@as(u32, 2), rig.guard.lines);
    try testing.expect(std.mem.indexOf(u8, rig.guard.last_line(), "error: none") != null);
}

test "guard: expired with no --cert fails with E0811, naming expiry, renewal error and --cert" {
    var rig: Rig = .{};
    try rig.start(null, false);
    try testing.expect(expired_refused(&rig));
    try testing.expect(rig.has_cause("has expired"));
    try testing.expect(rig.has_cause("last renewal error: none"));
    try testing.expect(rig.has_cause("--cert was not given"));
    try testing.expect(rig.diag.fixes.count >= 2);
    // Every later check fails the same way: nothing is presented that has expired.
    try testing.expectEqual(@as(?Code, .E0811), rig.check(born_ms + 3 * day_ms));
    try testing.expect(rig.presents(&rig.stored));
}

/// The check the tooth breaks: an expired certificate is refused, the skew allowed first.
fn expired_refused(rig: *Rig) bool {
    const skew_ms = @import("constants.zig").peer_clock_skew_ms;
    if (rig.check(born_ms + day_ms + skew_ms - 1) != null) return false;
    return rig.check(born_ms + day_ms + skew_ms) == .E0811;
}

test "guard: expired with a valid --cert presents it, with one note" {
    var rig: Rig = .{};
    var cert: Issued = .{};
    try rig.start(&cert, true);
    try rig.issue(&cert, 3, born_ms + day_ms / 2, born_ms + 3 * day_ms);
    const after_ms = born_ms + day_ms + 120_000;
    try testing.expectEqual(@as(?Code, null), rig.check(after_ms));
    try testing.expect(rig.presents(&cert));
    try testing.expectEqual(@as(u32, 1), rig.guard.lines);
    try testing.expect(std.mem.indexOf(u8, rig.guard.last_line(), "presenting --cert") != null);
    try testing.expectEqual(@as(?Code, null), rig.check(after_ms + 60_000));
    try testing.expectEqual(@as(u32, 1), rig.guard.lines);
    try testing.expectEqual(@as(u32, 1), rig.memory.loads); // Read once, when needed.
}

test "guard: expired with an expired or absent --cert fails, naming why --cert was not used" {
    var rig: Rig = .{};
    var cert: Issued = .{};
    try rig.start(&cert, true);
    try rig.issue(&cert, 4, born_ms, born_ms + day_ms / 2);
    try testing.expectEqual(@as(?Code, .E0811), rig.check(born_ms + 2 * day_ms));
    try testing.expect(rig.has_cause("--cert was not used: it has expired"));
    try testing.expect(rig.presents(&rig.stored));
    rig.memory.issued = null;
    try testing.expectEqual(@as(?Code, .E0811), rig.check(born_ms + 2 * day_ms));
    try testing.expect(rig.has_cause("--cert was not used: it does not exist"));
    try testing.expectEqual(@as(u32, 0), rig.guard.lines);
}

test "guard: a certificate not yet valid (the clock went back) is not presented" {
    var rig: Rig = .{};
    try rig.start(null, false);
    const skew_ms = @import("constants.zig").peer_clock_skew_ms;
    try testing.expectEqual(@as(?Code, null), rig.check(born_ms - skew_ms));
    try testing.expectEqual(@as(?Code, .E0811), rig.check(born_ms - skew_ms - 1));
    try testing.expect(rig.has_cause("is not valid yet"));
}

test "teeth: with the agent's check skipped an expired certificate is presented" {
    var rig: Rig = .{};
    try rig.start(null, false);
    api_tls_guard.set_test_fault(.check, true);
    defer api_tls_guard.set_test_fault(.check, false);
    try testing.expect(!expired_refused(&rig));
}
