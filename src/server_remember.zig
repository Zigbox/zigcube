//! The server's remembered `(revision, hash)` pair on disk (`store_verified.zig`). Shell code:
//! files.
//!
//! Where: `<state dir>/remembered`. The state directory is `--state-dir` / `.state_dir`; unset,
//! it is the directory of the SQLite file for a SQLite store and `zcube-state` in the working
//! directory for Postgres (a memory store remembers nothing across a restart and has no file).
//! Why a directory of the server's own and not the store: the point is to outlive a store that
//! was restored, failed over or replaced, so it must not live in it, and a Postgres store has
//! no directory the server could use.
//!
//! Format (text, one line each, nothing else):
//!
//!     zcube-remembered 1
//!     revision 412
//!     hash <64 lowercase hex digits>
//!
//! Written crash-safe: a temporary file in the same directory, `fsync`, rename over the name,
//! `fsync` of the directory. A reader sees the old pair or the new one. A file that is present
//! and does not parse is `ZC-E0216`, never "no file": a server that forgot would accept
//! whatever store it finds.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const verified = @import("store_verified.zig");

const Diag = diag_mod.Diag;
const Dir = std.Io.Dir;

pub const file_name = "remembered";
const temp_name = "remembered.tmp";
const magic = "zcube-remembered 1\n";
const bytes_max = 256;

pub const Remembered = struct {
    io: std.Io,
    /// The state directory as the operator named it (for messages), and the open handle.
    path: []const u8,
    dir: Dir,
    mutex: std.Io.Mutex = .init,

    /// Opens (creating, with parents) the state directory.
    pub fn open(io: std.Io, path: []const u8, diag: *Diag) error{BadState}!Remembered {
        assert(diag.code == null);
        const cwd = Dir.cwd();
        cwd.createDirPath(io, path) catch |err| return unusable(diag, path, "create", err);
        const dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err|
            return unusable(diag, path, "open", err);
        return .{ .io = io, .path = path, .dir = dir };
    }

    pub fn close(remembered: *Remembered) void {
        remembered.dir.close(remembered.io);
    }

    pub fn interface(remembered: *Remembered) verified.Remember {
        return .{ .context = remembered, .save_fn = save_impl };
    }

    /// The pair in the file, null if there is no file.
    pub fn load(remembered: *Remembered, diag: *Diag) error{BadState}!?verified.Pair {
        assert(diag.code == null);
        var buffer: [bytes_max]u8 = undefined;
        const bytes = remembered.dir.readFile(remembered.io, file_name, &buffer) catch |err| {
            if (err == error.FileNotFound) return null;
            return unusable(diag, remembered.path, "read", err);
        };
        return parse(bytes) orelse
            unusable(diag, remembered.path, "parse", error.InvalidData);
    }

    fn save_impl(context: *anyopaque, pair: verified.Pair) bool {
        const remembered: *Remembered = @ptrCast(@alignCast(context));
        remembered.mutex.lockUncancelable(remembered.io);
        defer remembered.mutex.unlock(remembered.io);
        return remembered.write(pair);
    }

    fn write(remembered: *Remembered, pair: verified.Pair) bool {
        const io = remembered.io;
        var buffer: [bytes_max]u8 = undefined;
        const text = format(&buffer, pair);
        const file = remembered.dir.createFile(io, temp_name, .{
            .permissions = .fromMode(0o600),
        }) catch return false;
        defer file.close(io);
        file.writeStreamingAll(io, text) catch return false;
        file.sync(io) catch return false;
        remembered.dir.rename(temp_name, remembered.dir, file_name, io) catch return false;
        // `iterate` opens a real descriptor (not O_PATH), which can be fsynced.
        const flags: std.Io.File.Flags = .{ .nonblocking = false };
        const handle: std.Io.File = .{ .handle = remembered.dir.handle, .flags = flags };
        handle.sync(io) catch return false;
        return true;
    }
};

pub fn format(buffer: []u8, pair: verified.Pair) []const u8 {
    const hex = std.fmt.bytesToHex(pair.hash, .lower);
    return std.fmt.bufPrint(buffer, "{s}revision {d}\nhash {s}\n", .{
        magic, pair.revision, hex,
    }) catch unreachable; // `bytes_max` holds the longest line set.
}

/// The pair in `text`, null if it is not exactly what `format` writes.
pub fn parse(text: []const u8) ?verified.Pair {
    if (!std.mem.startsWith(u8, text, magic)) return null;
    var lines = std.mem.splitScalar(u8, text[magic.len..], '\n');
    const revision_line = lines.next() orelse return null;
    const hash_line = lines.next() orelse return null;
    const rest = lines.next() orelse return null;
    if (rest.len != 0) return null;
    if (lines.next() != null) return null;
    if (!std.mem.startsWith(u8, revision_line, "revision ")) return null;
    if (!std.mem.startsWith(u8, hash_line, "hash ")) return null;
    const revision = std.fmt.parseInt(u64, revision_line["revision ".len..], 10) catch return null;
    const hex = hash_line["hash ".len..];
    var pair: verified.Pair = .{ .revision = revision, .hash = undefined };
    if (hex.len != pair.hash.len * 2) return null;
    _ = std.fmt.hexToBytes(&pair.hash, hex) catch return null;
    return pair;
}

fn unusable(diag: *Diag, path: []const u8, action: []const u8, err: anyerror) error{BadState} {
    var where: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&where, "{s}/{s}", .{ path, file_name }) catch path;
    _ = failures.remembered_unusable(diag, full, action, @errorName(err)) catch {};
    return error.BadState;
}

test "the format round-trips and refuses anything else" {
    // Goal: a pair survives the file, and a damaged file is not mistaken for another pair.
    // Method: format, parse; then damage each part.
    var buffer: [bytes_max]u8 = undefined;
    const pair: verified.Pair = .{ .revision = 412, .hash = @splat(0xa1) };
    const text = format(&buffer, pair);
    try std.testing.expect(parse(text).?.eql(pair));
    try std.testing.expect(parse(text[0 .. text.len - 1]) == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("zcube-remembered 2\nrevision 1\nhash 00\n") == null);
    var bad: [bytes_max]u8 = undefined;
    @memcpy(bad[0..text.len], text);
    bad[text.len - 3] = 'g';
    try std.testing.expect(parse(bad[0..text.len]) == null);
}
