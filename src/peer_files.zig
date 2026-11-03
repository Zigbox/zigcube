//! The key and credential files of docs/peer.md, shared by the server (`ca.key`, `revoked`) and
//! the agent (`peer.key`, `peer.cred`, `ca.pub`). Shell code: it reads and writes files.
//!
//! A secret is the 32-byte Ed25519 seed as one line of 64 hex digits, mode 0600. It is read only
//! if no other user can read it (ZC-E0806), and written whole or not at all: a temporary file in
//! the same directory, `fsync`, rename, `fsync` of the directory. Nothing here ever prints one.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const diag_mod = @import("diag.zig");

const Diag = diag_mod.Diag;
const Dir = std.Io.Dir;

pub const Error = error{Failed};

/// ZC-E0806 for `name` in the directory `where`: `verb` is "read", "write", "parse" and so on.
pub fn unusable(
    diag: *Diag,
    where: []const u8,
    name: []const u8,
    verb: []const u8,
    why: []const u8,
) Error {
    assert(diag.code == null);
    diag.raise(.E0806);
    diag.cause("can't {s} {s} in {s}: {s}", .{ verb, name, where, why });
    const sentence = "fix the file's owner or mode (0600), or delete it so it is made again";
    diag.fix(.{ .sentence = sentence });
    return error.Failed;
}

/// The file's bytes in `buffer`, null if there is no such file. A file that does not fit is
/// refused (it is not ours). When `secret`, a file readable by group or others is refused too.
pub fn read(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    secret: bool,
    buffer: []u8,
    diag: *Diag,
) Error!?[]u8 {
    assert(buffer.len > 0);
    assert(buffer.len <= constants.peer_file_bytes_max + 1);
    const file = dir.openFile(io, name, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return unusable(diag, where, name, "read", @errorName(err));
    };
    defer file.close(io);
    if (secret) {
        const stat = file.stat(io) catch |err| {
            return unusable(diag, where, name, "read", @errorName(err));
        };
        if (stat.permissions.toMode() & 0o077 != 0) {
            return unusable(diag, where, name, "use", "other users can read it");
        }
    }
    const length = file.readPositionalAll(io, buffer, 0) catch |err| {
        return unusable(diag, where, name, "read", @errorName(err));
    };
    if (length == buffer.len) return unusable(diag, where, name, "read", "it is too long");
    return buffer[0..length];
}

/// A secret seed from `name`: 64 hex digits and a newline. Null if the file is absent.
pub fn read_seed(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    diag: *Diag,
) Error!?[32]u8 {
    var buffer: [128]u8 = undefined;
    const bytes = try read(io, dir, where, name, true, &buffer, diag) orelse return null;
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    var seed: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&seed, text) catch
        return unusable(diag, where, name, "parse", "it is not 64 hex digits");
    if (decoded.len != seed.len) {
        return unusable(diag, where, name, "parse", "it is not 64 hex digits");
    }
    return seed;
}

/// Writes `text` as `name`, mode 0600, whole or not at all.
pub fn write(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    text: []const u8,
    diag: *Diag,
) Error!void {
    assert(name.len > 0);
    assert(name.len + ".tmp".len <= 64);
    var temp: [64]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp, "{s}.tmp", .{name}) catch unreachable; // Sized.
    {
        const file = dir.createFile(io, temp_name, .{
            .permissions = .fromMode(0o600),
        }) catch |err| return unusable(diag, where, name, "write", @errorName(err));
        defer file.close(io);
        file.writeStreamingAll(io, text) catch |err| {
            return unusable(diag, where, name, "write", @errorName(err));
        };
        file.sync(io) catch |err| return unusable(diag, where, name, "write", @errorName(err));
    }
    dir.rename(temp_name, dir, name, io) catch |err| {
        return unusable(diag, where, name, "write", @errorName(err));
    };
    // The directory is synced through a read-only handle, which POSIX allows.
    const handle = dir.openFile(io, ".", .{}) catch |err| {
        return unusable(diag, where, name, "write", @errorName(err));
    };
    defer handle.close(io);
    handle.sync(io) catch |err| return unusable(diag, where, name, "write", @errorName(err));
}

/// Writes a secret seed as `name`.
pub fn write_seed(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    seed: [32]u8,
    diag: *Diag,
) Error!void {
    var line: [65]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{x}\n", .{&seed}) catch
        unreachable; // 64 digits and "\n".
    return write(io, dir, where, name, text, diag);
}

test "a seed is written 0600, read back, and a loose file is refused" {
    // Goal: the secret file rules of docs/peer.md. Method: write, read, widen the mode, read
    // again, then damage the text; each refusal is ZC-E0806 and none prints the seed.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    const seed: [32]u8 = @splat(0xab);
    try write_seed(io, tmp.dir, "tmp", "k", seed, &diag);
    const back = try read_seed(io, tmp.dir, "tmp", "k", &diag);
    try std.testing.expectEqualSlices(u8, &seed, &back.?);
    const file = try tmp.dir.openFile(io, "k", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expect((try read_seed(io, tmp.dir, "tmp", "absent", &diag)) == null);

    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.Failed, read_seed(io, tmp.dir, "tmp", "k", &diag));
    try std.testing.expectEqual(codes.Code.E0806, diag.code.?);
    diag.reset();
    try file.setPermissions(io, .fromMode(0o600));
    try tmp.dir.writeFile(io, .{ .sub_path = "k", .data = "not hex\n" });
    try file.setPermissions(io, .fromMode(0o600));
    try std.testing.expectError(error.Failed, read_seed(io, tmp.dir, "tmp", "k", &diag));
    try std.testing.expectEqual(codes.Code.E0806, diag.code.?);
}
