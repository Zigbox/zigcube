//! The server's remembered `(revision, hash)` pair on disk (`store_verified.zig`). Shell code:
//! files.
//!
//! Where: `<state dir>/<db file name>.<hash of the db's absolute path>.remembered` for a SQLite
//! store (one file per database path, so two databases do not share a pair even with one file
//! name and one `--state-dir`), `<state dir>/remembered` for Postgres. The path is made absolute
//! lexically (the working directory plus the name, no symlinks resolved): a database restored
//! under a new path starts with no file and is not checked (docs/operations.md).
//! The state directory is `--state-dir` / `.state_dir`; unset, it is the directory of the SQLite
//! file. A Postgres store has no such directory: `--state-dir` is required (`ZC-E0106`), and one
//! directory serves one Postgres database. A memory store remembers nothing across a restart
//! and has no file.
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

/// The file of a Postgres store, and the suffix of a SQLite store's.
pub const file_name = "remembered";
const name_bytes_max = 300;
const temp_suffix = ".tmp";
const magic = "zcube-remembered 1\n";
const bytes_max = 256;

pub const Remembered = struct {
    io: std.Io,
    /// The state directory as the operator named it (for messages), and the open handle.
    path: []const u8,
    dir: Dir,
    mutex: std.Io.Mutex = .init,
    name_buffer: [name_bytes_max]u8 = undefined,
    name_length: u16 = 0,

    /// The file's name in the state directory.
    pub fn name(remembered: *const Remembered) []const u8 {
        return remembered.name_buffer[0..remembered.name_length];
    }

    /// The name of the file for a store: for SQLite (`database` is its absolute path, null for
    /// the others) `<database file name>.<16 hex digits of a hash of its path>.remembered`,
    /// so that two databases keep two pairs even when they share a file name and a state
    /// directory. Null if the name does not fit (`open` needs room for its `.tmp`).
    pub fn file_for(database: ?[]const u8, buffer: *[name_bytes_max]u8) ?[]const u8 {
        const path = database orelse return file_name;
        assert(std.fs.path.isAbsolute(path));
        const base = std.fs.path.basename(path);
        const text = std.fmt.bufPrint(buffer, "{s}.{x:0>16}.{s}", .{
            base, std.hash.Wyhash.hash(0, path), file_name,
        }) catch return null;
        if (text.len + temp_suffix.len > name_bytes_max) return null;
        return text;
    }

    /// Opens (creating, with parents) the state directory; the pair lives in `file`.
    pub fn open(
        io: std.Io,
        path: []const u8,
        file: []const u8,
        diag: *Diag,
    ) error{BadState}!Remembered {
        assert(diag.code == null);
        assert(file.len > 0);
        assert(file.len + temp_suffix.len <= name_bytes_max);
        const cwd = Dir.cwd();
        var opened: Remembered = .{ .io = io, .path = path, .dir = undefined };
        @memcpy(opened.name_buffer[0..file.len], file);
        opened.name_length = @intCast(file.len);
        cwd.createDirPath(io, path) catch |err| return unusable(diag, &opened, "create", err);
        opened.dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err|
            return unusable(diag, &opened, "open", err);
        return opened;
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
        const dir = remembered.dir;
        const bytes = dir.readFile(remembered.io, remembered.name(), &buffer) catch |err| {
            if (err == error.FileNotFound) return null;
            return unusable(diag, remembered, "read", err);
        };
        return parse(bytes) orelse unusable(diag, remembered, "parse", error.InvalidData);
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
        var temp_buffer: [name_bytes_max]u8 = undefined;
        const temp_name = std.fmt.bufPrint(&temp_buffer, "{s}{s}", .{
            remembered.name(), temp_suffix,
        }) catch
            unreachable; // `open` checked that the name and the suffix fit.
        const file = remembered.dir.createFile(io, temp_name, .{
            .permissions = .fromMode(0o600),
        }) catch return false;
        defer file.close(io);
        file.writeStreamingAll(io, text) catch return false;
        file.sync(io) catch return false;
        remembered.dir.rename(temp_name, remembered.dir, remembered.name(), io) catch return false;
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

fn unusable(
    diag: *Diag,
    remembered: *const Remembered,
    action: []const u8,
    err: anyerror,
) error{BadState} {
    var where: [512 + name_bytes_max]u8 = undefined;
    const path = remembered.path;
    const full = std.fmt.bufPrint(&where, "{s}/{s}", .{ path, remembered.name() }) catch path;
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

test "a SQLite store's file is keyed by its absolute path; a long name is refused" {
    // Goal: two databases never share a pair, and `open`'s size assert cannot fire. Method: the
    // same file name in two directories; names around the limit.
    var one_buffer: [name_bytes_max]u8 = undefined;
    var two_buffer: [name_bytes_max]u8 = undefined;
    const one = Remembered.file_for("/srv/a/zcube.db", &one_buffer).?;
    const two = Remembered.file_for("/srv/b/zcube.db", &two_buffer).?;
    try std.testing.expect(!std.mem.eql(u8, one, two));
    try std.testing.expect(std.mem.startsWith(u8, one, "zcube.db."));
    try std.testing.expect(std.mem.endsWith(u8, one, ".remembered"));
    try std.testing.expectEqualStrings(one, Remembered.file_for("/srv/a/zcube.db", &two_buffer).?);
    try std.testing.expectEqualStrings("remembered", Remembered.file_for(null, &one_buffer).?);

    // The longest base that fits: name = base + "." + 16 hex + ".remembered", plus ".tmp".
    const overhead = 1 + 16 + 1 + file_name.len + temp_suffix.len;
    var long: [1 + name_bytes_max]u8 = @splat('x');
    long[0] = '/';
    const fits = long[0 .. 1 + name_bytes_max - overhead];
    const name = Remembered.file_for(fits, &one_buffer).?;
    try std.testing.expect(name.len + temp_suffix.len <= name_bytes_max);
    try std.testing.expect(Remembered.file_for(long[0 .. fits.len + 1], &two_buffer) == null);
}
