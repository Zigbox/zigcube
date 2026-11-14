//! The archive formats the packages are made of: `ar` (a .deb's envelope), ustar `tar` (its
//! control and data members), cpio `newc` (an rpm's payload) and gzip. All output is a pure
//! function of the arguments: every time is `constants.package_source_date_epoch`, every owner is
//! `root:root`, and gzip's header carries no time or name.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Output = std.Io.Writer.Allocating;
pub const Error = model.Error;

/// A member of an `ar` archive.
pub const Member = struct { name: []const u8, bytes: []const u8 };

/// The global header and members of a Debian-style `ar` archive: 16-byte names, decimal fields,
/// mode 100644, owner 0:0, the fixed time, and a newline after an odd-sized member.
pub fn ar_write(memory: Allocator, members: []const Member) Error![]u8 {
    // The member is the payload plus tar headers and compression overhead: not bounded by
    // `validate`, so it is refused here, before anything is allocated.
    for (members) |member| {
        if (member.bytes.len > constants.package_payload_bytes_max) return error.PayloadTooLarge;
    }
    var out = Output.init(memory);
    const writer = &out.writer;
    writer.writeAll("!<arch>\n") catch return error.WriteFailed;
    for (members) |member| {
        assert(member.name.len <= 16);
        writer.print("{s: <16}{d: <12}{d: <6}{d: <6}{o: <8}{d: <10}`\n", .{
            member.name, constants.package_source_date_epoch, 0, 0, 0o100644, member.bytes.len,
        }) catch return error.WriteFailed;
        writer.writeAll(member.bytes) catch return error.WriteFailed;
        if (member.bytes.len % 2 == 1) writer.writeByte('\n') catch return error.WriteFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// One tar entry: a directory (`bytes` empty, name ending in `/`) or a regular file.
pub const TarEntry = struct { name: []const u8, mode: u32, bytes: []const u8, directory: bool };

fn tar_header(entry: TarEntry) Error!std.tar.Writer.Header {
    var header = std.tar.Writer.Header.init(if (entry.directory) .directory else .regular);
    // The defaults are octal digits ('0000664'); a short number would leave them in place.
    @memset(&header.mode, '0');
    header.setPath("", entry.name) catch return error.BadPath;
    header.setMode(entry.mode) catch return error.BadMode;
    header.setSize(entry.bytes.len) catch return error.FileTooLarge;
    header.setMtime(constants.package_source_date_epoch) catch return error.WriteFailed;
    @memcpy(header.uname[0..4], "root");
    @memcpy(header.gname[0..4], "root");
    if (entry.directory) assert(entry.bytes.len == 0);
    assert(header.uname[0] == 'r');
    return header;
}

/// A ustar archive of the entries in the order given, ending with two zero blocks.
pub fn tar_write(memory: Allocator, entries: []const TarEntry) Error![]u8 {
    var out = Output.init(memory);
    const writer = &out.writer;
    for (entries) |entry| {
        var header = try tar_header(entry);
        header.write(writer) catch return error.WriteFailed;
        writer.writeAll(entry.bytes) catch return error.WriteFailed;
        const tail = entry.bytes.len % 512;
        if (tail != 0) writer.splatByteAll(0, 512 - tail) catch return error.WriteFailed;
    }
    writer.splatByteAll(0, 1024) catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// One cpio entry; `name` is as stored (`./usr/bin/zbx`), `mode` includes the file type bits.
pub const CpioEntry = struct { name: []const u8, mode: u32, bytes: []const u8, inode: u32 };

/// A cpio `newc` ("070701") archive: 13 eight-digit hex fields, the name with its NUL, data, each
/// padded to four bytes, then `TRAILER!!!`.
pub fn cpio_write(memory: Allocator, entries: []const CpioEntry) Error![]u8 {
    var out = Output.init(memory);
    const writer = &out.writer;
    for (entries) |entry| try cpio_member(writer, entry);
    try cpio_member(writer, .{ .name = "TRAILER!!!", .mode = 0, .bytes = "", .inode = 0 });
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn cpio_member(writer: *std.Io.Writer, entry: CpioEntry) Error!void {
    assert(entry.bytes.len <= constants.package_file_bytes_max);
    const name_size: u32 = @intCast(entry.name.len + 1);
    const nlink: u32 = if (entry.mode & 0o170000 == 0o040000) 2 else 1;
    writer.print("070701{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
        entry.inode,     entry.mode, 0, 0, nlink, constants.package_source_date_epoch,
        entry.bytes.len,
    }) catch return error.WriteFailed;
    writer.print("{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
        0, 0, 0, 0, name_size, 0,
    }) catch return error.WriteFailed;
    writer.writeAll(entry.name) catch return error.WriteFailed;
    writer.writeByte(0) catch return error.WriteFailed;
    // The header (110 bytes) and the name are padded together to a multiple of four.
    const head_pad = (4 - (110 + name_size) % 4) % 4;
    writer.splatByteAll(0, head_pad) catch return error.WriteFailed;
    writer.writeAll(entry.bytes) catch return error.WriteFailed;
    const data_pad = (4 - entry.bytes.len % 4) % 4;
    writer.splatByteAll(0, data_pad) catch return error.WriteFailed;
}

/// gzip with the fixed header (no time, no name, OS Unix) and std's deflate at its best level.
pub fn gzip(memory: Allocator, bytes: []const u8) Error![]u8 {
    var out = Output.initCapacity(memory, 4096 + bytes.len / 2) catch return error.OutOfMemory;
    const window = memory.alloc(u8, constants.package_gzip_window_bytes) catch {
        return error.OutOfMemory;
    };
    defer memory.free(window);
    var compress = std.compress.flate.Compress.init(
        &out.writer,
        window,
        .gzip,
        .best,
    ) catch return error.WriteFailed;
    compress.writer.writeAll(bytes) catch return error.WriteFailed;
    compress.finish() catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "an ar member over the payload bound is refused, not asserted" {
    // Goal: tar headers and compression can push a valid payload's data.tar.gz past the bound;
    // that is an error the caller prints, not a panic. The bytes are never touched.
    const size = constants.package_payload_bytes_max + 1;
    const huge = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(huge);
    try std.testing.expectError(
        error.PayloadTooLarge,
        ar_write(std.testing.allocator, &.{.{ .name = "data.tar.gz", .bytes = huge }}),
    );
}

test "ar matches the format ar itself reads" {
    // Goal: pin the ar layout against the system `ar t` and `ar p` in a pair test below; here the
    // bytes of one odd and one even member.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try ar_write(arena.allocator(), &.{
        .{ .name = "debian-binary", .bytes = "2.0\n" },
        .{ .name = "odd", .bytes = "abc" },
    });
    try std.testing.expectEqualStrings("!<arch>\n", bytes[0..8]);
    try std.testing.expectEqualStrings("debian-binary ", bytes[8..22]);
    try std.testing.expectEqual(@as(usize, 8 + 60 + 4 + 60 + 3 + 1), bytes.len);
    try std.testing.expectEqualStrings("`\n", bytes[8 + 58 .. 8 + 60]);
    try std.testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
}

test "tar entries round trip through std's reader with root ownership" {
    // Goal: our tar is read back by std.tar (names, modes, sizes), a one-digit mode keeps no
    // stale digits, and the two end blocks are present.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try tar_write(arena.allocator(), &.{
        .{ .name = "./usr/", .mode = 0o755, .bytes = "", .directory = true },
        .{ .name = "./usr/x", .mode = 0o5, .bytes = "hello", .directory = false },
    });
    try std.testing.expectEqual(@as(usize, 512 * 3 + 1024), bytes.len);
    var reader: std.Io.Reader = .fixed(bytes);
    var name_buffer: [100]u8 = undefined;
    var link_buffer: [100]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    const first = (try iterator.next()).?;
    try std.testing.expectEqualStrings("./usr/", first.name);
    const second = (try iterator.next()).?;
    try std.testing.expectEqualStrings("./usr/x", second.name);
    try std.testing.expectEqual(@as(u64, 5), second.size);
    try std.testing.expectEqual(@as(u32, 0o5), second.mode);
    try std.testing.expectEqualStrings("0000005\x00", bytes[512 + 100 .. 512 + 108]);
}

test "cpio newc entries are aligned and end in the trailer" {
    // Goal: the header is 110 bytes, name and data pad to four, and the trailer closes it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try cpio_write(arena.allocator(), &.{
        .{ .name = "./a", .mode = 0o100644, .bytes = "xyz", .inode = 1 },
    });
    try std.testing.expectEqualStrings("070701", bytes[0..6]);
    try std.testing.expectEqual(@as(usize, 0), bytes.len % 4);
    const trailer = std.mem.indexOf(u8, bytes, "TRAILER!!!").?;
    try std.testing.expectEqual(@as(usize, bytes.len), trailer + 10 + 1 + (4 - (110 + 11) % 4) % 4);
    // "./a" + NUL is 4 bytes after 110: 114 pads to 116; "xyz" pads to 4.
    try std.testing.expectEqualStrings("xyz", bytes[116..119]);
}

test "gzip output is identical on every run and inflates to the input" {
    // Goal: determinism (two runs equal), the fixed header, and a round trip through std's
    // decompressor.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var input: [5000]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @intCast((index * 7) % 13);
    const first = try gzip(arena.allocator(), &input);
    const second = try gzip(arena.allocator(), &input);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 }, first[0..10]);
    var reader: std.Io.Reader = .fixed(first);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .gzip, &window);
    var back: [5000]u8 = undefined;
    try decompress.reader.readSliceAll(&back);
    try std.testing.expectEqualSlices(u8, &input, &back);
}
