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

/// What `write` adds to a name for its temporary file: a dot, 16 hex digits and ".tmp".
const temp_suffix_bytes = 1 + 16 + 4;

/// Who may touch a file we read: `secret` is ours alone (no group or other access); `anchor`
/// is public but a trust anchor, so nobody else may write it; `plain` is not checked.
pub const Guard = enum { plain, anchor, secret };

/// ZC-E0806 for `name` in the directory `where`: `verb` is "read", "write", "parse" and so on.
pub fn unusable(
    diag: *Diag,
    where: []const u8,
    name: []const u8,
    verb: []const u8,
    why: []const u8,
) Error {
    const sentence = "fix the file's owner or mode (0600), or delete it so it is made again";
    return unusable_fix(diag, where, name, verb, why, sentence);
}

/// `unusable` with a fix of its own, for a file that is not a secret (a list of names).
pub fn unusable_fix(
    diag: *Diag,
    where: []const u8,
    name: []const u8,
    verb: []const u8,
    why: []const u8,
    fix: []const u8,
) Error {
    assert(diag.code == null);
    diag.raise(.E0806);
    diag.cause("can't {s} {s} in {s}: {s}", .{ verb, name, where, why });
    diag.fix(.{ .sentence = fix });
    return error.Failed;
}

/// Refuses a directory that group or others can write into: they could replace a trust anchor or
/// a secret's temporary file. ZC-E0806.
pub fn check_dir(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    diag: *Diag,
) Error!void {
    const stat = dir.stat(io) catch |err| {
        return unusable(diag, where, name, "use the directory of", @errorName(err));
    };
    if (stat.permissions.toMode() & 0o022 != 0) {
        const why = "other users can write into the directory";
        return unusable(diag, where, name, "use the directory of", why);
    }
}

/// What `read_bounded` found.
pub const Found = union(enum) {
    absent,
    /// The file fills the whole buffer, so it may be longer than the caller accepts.
    too_long,
    bytes: []u8,
};

/// The file's bytes in `buffer`, null if there is no such file. A file that does not fit is
/// refused (it is not ours). `guard` says which owner and mode checks apply.
pub fn read(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    guard: Guard,
    buffer: []u8,
    diag: *Diag,
) Error!?[]u8 {
    switch (try read_bounded(io, dir, where, name, guard, buffer, diag)) {
        .absent => return null,
        .too_long => return unusable(diag, where, name, "read", "it is too long"),
        .bytes => |bytes| return bytes,
    }
}

/// `read`, but a file that does not fit is reported as `.too_long` and not raised, for a caller
/// that replaces a file it does not recognise. The owner and mode checks still raise.
pub fn read_bounded(
    io: std.Io,
    dir: Dir,
    where: []const u8,
    name: []const u8,
    guard: Guard,
    buffer: []u8,
    diag: *Diag,
) Error!Found {
    assert(buffer.len > 0);
    assert(buffer.len <= constants.peer_file_bytes_max + 1);
    const file = dir.openFile(io, name, .{}) catch |err| {
        if (err == error.FileNotFound) return .absent;
        return unusable(diag, where, name, "read", @errorName(err));
    };
    defer file.close(io);
    if (guard != .plain) {
        const stat = file.stat(io) catch |err| {
            return unusable(diag, where, name, "read", @errorName(err));
        };
        const mode = stat.permissions.toMode();
        if (guard == .secret and mode & 0o077 != 0) {
            return unusable(diag, where, name, "use", "other users can read it");
        }
        if (guard == .anchor and mode & 0o022 != 0) {
            return unusable(diag, where, name, "use", "other users can write it");
        }
    }
    const length = file.readPositionalAll(io, buffer, 0) catch |err| {
        return unusable(diag, where, name, "read", @errorName(err));
    };
    if (length == buffer.len) return .too_long;
    return .{ .bytes = buffer[0..length] };
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
    defer std.crypto.secureZero(u8, &buffer);
    const bytes = try read(io, dir, where, name, .secret, &buffer, diag) orelse return null;
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    var seed: [32]u8 = undefined;
    errdefer std.crypto.secureZero(u8, &seed);
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
    assert(name.len + temp_suffix_bytes <= 96);
    // A name of its own per write, so that two writers (two servers on one state directory) never
    // share a temporary file, and one that is planted or left by a killed run is never reused:
    // the file is made exclusively. Every failure removes ours again.
    var random: [8]u8 = undefined;
    io.random(&random);
    var temp: [96]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp, "{s}.{x}.tmp", .{ name, &random }) catch
        unreachable; // The name, a dot, 16 digits and ".tmp" fit 96 bytes (asserted above).
    errdefer dir.deleteFile(io, temp_name) catch {}; // Nothing more to do if this fails too.
    {
        const file = dir.createFile(io, temp_name, .{
            .permissions = .fromMode(0o600),
            .exclusive = true,
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
    defer std.crypto.secureZero(u8, &line);
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

test "a planted temporary file with a loose mode never receives the secret" {
    // Goal: finding 4. Method: plant `k.tmp` at 0644 holding text of its own, write a seed, and
    // find the result at 0600; the write uses a temporary of its own, so the planted file is
    // neither used nor removed, and the seed is not in it.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    try tmp.dir.writeFile(io, .{
        .sub_path = "k.tmp",
        .data = "planted\n",
        .flags = .{ .permissions = .fromMode(0o644) },
    });
    try tmp.dir.setFilePermissions(io, "k.tmp", .fromMode(0o644), .{});
    const seed: [32]u8 = @splat(0xcd);
    try write_seed(io, tmp.dir, "tmp", "k", seed, &diag);
    const file = try tmp.dir.openFile(io, "k", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    var planted: [16]u8 = undefined;
    const kept = try tmp.dir.readFile(io, "k.tmp", &planted);
    try std.testing.expectEqualStrings("planted\n", kept);
    const back = try read_seed(io, tmp.dir, "tmp", "k", &diag);
    try std.testing.expectEqualSlices(u8, &seed, &back.?);
}

fn count_entries(io: std.Io, dir: Dir) !u32 {
    var listing = try dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var iterator = listing.iterate();
    var count: u32 = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

test "two writes of one name leave a whole file and no temporary" {
    // Goal: finding 2 of the review of #89: no fixed temporary name, so interleaved writers
    // cannot mix their bytes. Method: two threads write different texts of one name many times;
    // the file is always one of the two whole texts and the directory holds that file alone.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Writer = struct {
        fn run(dir: Dir, text: []const u8, failed: *std.atomic.Value(bool)) void {
            var diag: Diag = undefined;
            diag.reset();
            for (0..50) |_| {
                write(std.testing.io, dir, "tmp", "ca.crt", text, &diag) catch {
                    failed.store(true, .release);
                };
            }
        }
    };
    const first: [3000]u8 = @splat('A');
    const second: [2000]u8 = @splat('B');
    var failed: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Writer.run, .{ tmp.dir, &first, &failed });
    Writer.run(tmp.dir, &second, &failed);
    thread.join();
    try std.testing.expect(!failed.load(.acquire));
    var buffer: [4096]u8 = undefined;
    const text = try tmp.dir.readFile(io, "ca.crt", &buffer);
    try std.testing.expect(std.mem.eql(u8, text, &first) or std.mem.eql(u8, text, &second));
    try std.testing.expectEqual(@as(u32, 1), try count_entries(io, tmp.dir));
}

test "a write that fails removes its temporary file" {
    // Goal: no leftover on failure. Method: make the target name a directory so the rename
    // fails, and find the directory holding only that entry afterwards.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "ca.crt", .default_dir);
    var diag: Diag = undefined;
    diag.reset();
    try std.testing.expectError(error.Failed, write(io, tmp.dir, "tmp", "ca.crt", "x", &diag));
    try std.testing.expectEqual(codes.Code.E0806, diag.code.?);
    try std.testing.expectEqual(@as(u32, 1), try count_entries(io, tmp.dir));
}
