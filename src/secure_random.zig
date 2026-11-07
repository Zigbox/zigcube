//! The operating system's secure randomness, for keys, nonces and seeds (RB-N9;
//! docs/decisions/2026-11-07-secure-randomness-code.md). Shell code: it takes a `std.Io`.
//!
//! `std.Io.random` seeds a generator in the process and falls back to a weaker source when the
//! system's fails. A key must never come from that fallback, so this asks `randomSecure`, which
//! always goes to the kernel and has no fallback. One failure is one diagnostic (ZC-E0821); there
//! is no retry and no other source. Names, temporary-file suffixes and request ids are not
//! secrets and keep using `std.Io.random`.

const std = @import("std");
const diag_mod = @import("diag.zig");

const Diag = diag_mod.Diag;

/// The OS could not give secure randomness; `diag` holds ZC-E0821.
pub const Error = error{Unavailable};

/// Fills `out` from the kernel, or raises ZC-E0821 and fails. `what` names the secret being made
/// ("the TLS key share"); it goes into the cause. On failure `out` is untouched.
pub fn fill(io: std.Io, out: []u8, diag: *Diag, what: []const u8) Error!void {
    io.randomSecure(out) catch |err| switch (err) {
        error.EntropyUnavailable => {
            raise(diag, what);
            return error.Unavailable;
        },
        // Not E0821: a cancelled task is not a broken kernel. Nothing in Zigcube cancels the
        // tasks that make keys (the handshake, the CA and the identity load run to the end), so
        // reaching this is a bug, and it stops here rather than blaming the environment.
        error.Canceled => unreachable,
    };
}

/// Raises ZC-E0821: `getrandom` failed while making `what`.
pub fn raise(diag: *Diag, what: []const u8) void {
    diag.raise(.E0821);
    diag.cause("getrandom returned an error while making {s}", .{what});
    diag.fix(.{
        .sentence = "Check that the kernel's getrandom works here: the seccomp profile and the " ++
            "container sandbox must allow it.",
    });
}

/// For tests of callers: `base` with a `randomSecure` that always fails. `vtable` is the copy
/// the result points to, so it must outlive the result.
pub fn failing_io(base: std.Io, vtable: *std.Io.VTable) std.Io {
    vtable.* = base.vtable.*;
    vtable.randomSecure = std.Io.failingRandomSecure;
    return .{ .userdata = base.userdata, .vtable = vtable };
}

test "a failing random source is ZC-E0821, and the buffer is left alone" {
    var diag: Diag = undefined;
    diag.reset();
    var out: [16]u8 = @splat(0xAB);
    try std.testing.expectError(error.Unavailable, fill(std.Io.failing, &out, &diag, "a test key"));
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0821, diag.code.?);
    try std.testing.expectEqual(@as(u8, 0xAB), out[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), out[15]);
}

test "the real source fills the buffer" {
    var diag: Diag = undefined;
    diag.reset();
    var out: [32]u8 = @splat(0);
    try fill(std.testing.io, &out, &diag, "a test key");
    try std.testing.expect(diag.code == null);
    const zero: [32]u8 = @splat(0);
    try std.testing.expect(!std.mem.eql(u8, &out, &zero)); // 2^-256 of failing by chance.
}
