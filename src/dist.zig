//! `dist`: a build tool. It writes the release tarball `zig build dist` installs: the executables
//! and the Jepsen deployment recipe (`ops/jepsen/`) under one top directory, gzip-compressed, and
//! its SHA-256 in the format `sha256sum -c` reads.
//!
//! The tarball is a function of its inputs: entries are written in the order given, with mtime 0,
//! uid and gid 0, no user or group names, and a gzip header with no time or name in it, so the
//! same executables and files give the same bytes. The top directory and the file names carry the
//! version and the commit (`git rev-parse HEAD` in the build root, `+dirty` when the tracked files
//! differ from it); the commit is also in the file `COMMIT`.
//!
//! The out directory (`zig-out/dist`) is made if missing, and a tarball or checksum an earlier
//! run left there (any `zigcube-*` file) is deleted first, so it holds this build's two files only.
//!
//! usage: dist <out-dir> <build-root> <version> <archive-path>=<source-path>...

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The entries `build.zig` passes: four executables and the recipe's files, with room to spare.
const entries_max: u32 = 64;
const platform = "x86_64-linux";
const commit_short_len = 12;
/// How many entries of the out directory the tool looks at before it refuses: a directory with
/// more is not one this tool made.
const out_entries_max: u32 = 64;

const Entry = struct { archive_path: []const u8, source_path: []const u8 };

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_user;
    if (args.len < 5) return fail(init.io, "usage: dist <out-dir> <build-root> <version> A=S...");
    if (args.len - 4 > entries_max) return fail(init.io, "dist: too many entries");
    var entries: [entries_max]Entry = undefined;
    for (args[4..], 0..) |arg, index| {
        const split = std.mem.indexOfScalar(u8, arg, '=') orelse
            return fail(init.io, "dist: an entry is not <archive-path>=<source-path>");
        entries[index] = .{ .archive_path = arg[0..split], .source_path = arg[split + 1 ..] };
    }
    run(init, args[1], args[2], args[3], entries[0 .. args.len - 4]) catch |err| {
        const text = std.fmt.allocPrint(arena, "dist: {s}", .{@errorName(err)}) catch "dist";
        return fail(init.io, text);
    };
    return constants.exit_ok;
}

fn fail(io: std.Io, text: []const u8) u8 {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    return constants.exit_user;
}

/// The commit of the build root, `+dirty` appended when tracked files differ from it, or
/// `unknown` when the source is not a git checkout (a source tarball).
fn commit_of(init: std.process.Init, root: []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    const head = git(init, &.{ "git", "-C", root, "rev-parse", "HEAD" }) orelse return "unknown";
    assert(head.len >= commit_short_len);
    const porcelain = &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" };
    const status = git(init, porcelain) orelse return error.GitStatusFailed;
    const dirty: []const u8 = if (status.len > 0) "+dirty" else "";
    return std.fmt.allocPrint(arena, "{s}{s}", .{ head, dirty });
}

fn git(init: std.process.Init, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(init.arena.allocator(), init.io, .{ .argv = argv }) catch
        return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, result.stdout, " \n");
}

fn run(
    init: std.process.Init,
    out_path: []const u8,
    root: []const u8,
    version: []const u8,
    entries: []const Entry,
) !void {
    assert(entries.len > 0);
    const arena = init.arena.allocator();
    const io = init.io;
    const commit = try commit_of(init, root);
    const short = commit[0..@min(commit.len, commit_short_len)];
    const dirty: []const u8 = if (std.mem.endsWith(u8, commit, "+dirty")) "-dirty" else "";
    const top = try std.fmt.allocPrint(arena, "zigcube-{s}-{s}{s}-{s}", .{
        version, short, dirty, platform,
    });
    const tarball = try std.fmt.allocPrint(arena, "{s}.tar.gz", .{top});
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{ .open_options = .{
        .iterate = true,
    } });
    defer out.close(io);
    try remove_earlier(io, out);
    const digest = try write_tarball(init, out, tarball, top, commit, entries);
    const hex = std.fmt.bytesToHex(digest, .lower);
    // `sha256sum -c` reads "<hex>  <name>": two spaces, text mode.
    const line = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ &hex, tarball });
    const sum_name = try std.fmt.allocPrint(arena, "{s}.sha256", .{tarball});
    try out.writeFile(io, .{ .sub_path = sum_name, .data = line });
}

/// Deletes the files an earlier run wrote (`zigcube-*`); anything else is left alone.
fn remove_earlier(io: std.Io, out: std.Io.Dir) !void {
    var names: [out_entries_max][std.Io.Dir.max_name_bytes]u8 = undefined;
    var lengths: [out_entries_max]usize = undefined;
    var count: u32 = 0;
    var iterator = out.iterate();
    while (try iterator.next(io)) |entry| {
        if (count == out_entries_max) return error.OutDirectoryFull;
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "zigcube-")) continue;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lengths[count] = entry.name.len;
        count += 1;
    }
    assert(count <= out_entries_max);
    for (names[0..count], lengths[0..count]) |*name, length| {
        try out.deleteFile(io, name[0..length]);
    }
}

/// Writes the tarball into `out` and returns the SHA-256 of its bytes, hashed as they are written.
fn write_tarball(
    init: std.process.Init,
    out: std.Io.Dir,
    name: []const u8,
    top: []const u8,
    commit: []const u8,
    entries: []const Entry,
) ![Sha256.digest_length]u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const file = try out.createFile(io, name, .{});
    defer file.close(io);
    const file_buffer = try arena.alloc(u8, 64 * 1024);
    var file_writer = file.writer(io, file_buffer);
    const hashed_buffer = try arena.alloc(u8, 64 * 1024);
    var hashed: std.Io.Writer.Hashed(Sha256) = .init(&file_writer.interface, hashed_buffer);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    const compress = try arena.create(std.compress.flate.Compress);
    compress.* = try .init(&hashed.writer, window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compress.writer };
    try tar.setRoot(top);
    const commit_line = try std.fmt.allocPrint(arena, "{s}\n", .{commit});
    try tar.writeFileBytes("COMMIT", commit_line, .{ .mode = 0o644, .mtime = 0 });
    for (entries) |entry| try write_entry(init, &tar, entry);
    try tar.finishPedantically();
    try compress.finish();
    try hashed.writer.flush();
    try file_writer.interface.flush();
    return hashed.hasher.finalResult();
}

/// One file, as `entry.archive_path` under the top directory: mode 0755 for an executable
/// (`bin/`) or a script (`.sh`), 0644 for anything else.
fn write_entry(init: std.process.Init, tar: *std.tar.Writer, entry: Entry) !void {
    assert(entry.archive_path.len > 0);
    assert(entry.archive_path[0] != '/');
    const io = init.io;
    const executable = std.mem.startsWith(u8, entry.archive_path, "bin/") or
        std.mem.endsWith(u8, entry.archive_path, ".sh");
    const mode: u32 = if (executable) 0o755 else 0o644;
    const file = try std.Io.Dir.cwd().openFile(io, entry.source_path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const size = try reader.getSize();
    try tar.writeFileStream(entry.archive_path, size, &reader.interface, .{
        .mode = mode,
        .mtime = 0,
    });
}

