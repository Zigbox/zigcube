//! The `.deb` writer: an `ar` archive of `debian-binary`, `control.tar.gz` and `data.tar.gz`.
//! Control files follow deb-control(5); `md5sums` is the one place MD5 appears, because dpkg
//! reads it that way.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const model = @import("model.zig");
const archive = @import("archive.zig");

const Allocator = std.mem.Allocator;
const Output = std.Io.Writer.Allocating;
pub const Error = model.Error;

/// The file name apt expects in the pool: `<name>_<version>_<arch>.deb`.
pub fn file_name(memory: Allocator, package: *const model.Package) Error![]u8 {
    return std.fmt.allocPrint(memory, "{s}_{s}_{s}.deb", .{
        package.name, package.version, package.architecture.deb_name(),
    }) catch return error.OutOfMemory;
}

/// The control file's text. `Installed-Size` is in KiB, rounded up.
pub fn control_text(memory: Allocator, package: *const model.Package) Error![]u8 {
    var out = Output.init(memory);
    const writer = &out.writer;
    // 1024 is not zero, so the division cannot fail.
    const size_kib = std.math.divCeil(u64, model.content_bytes(package), 1024) catch unreachable;
    writer.print("Package: {s}\nVersion: {s}\nArchitecture: {s}\nMaintainer: {s}\n", .{
        package.name, package.version, package.architecture.deb_name(), package.maintainer,
    }) catch return error.WriteFailed;
    writer.print("Installed-Size: {d}\n", .{size_kib}) catch return error.WriteFailed;
    try relation_line(writer, "Depends", package.depends_deb);
    try relation_line(writer, "Conflicts", package.conflicts);
    try relation_line(writer, "Replaces", package.replaces);
    try relation_line(writer, "Provides", package.provides);
    if (package.recommends_deb.len > 0) {
        writer.writeAll("Recommends: ") catch return error.WriteFailed;
        for (package.recommends_deb, 0..) |name, index| {
            if (index > 0) writer.writeAll(", ") catch return error.WriteFailed;
            writer.writeAll(name) catch return error.WriteFailed;
        }
        writer.writeByte('\n') catch return error.WriteFailed;
    }
    writer.print("Section: admin\nPriority: optional\nHomepage: {s}\n", .{
        package.homepage,
    }) catch return error.WriteFailed;
    writer.print("Description: {s}\n", .{package.summary}) catch return error.WriteFailed;
    var lines = std.mem.splitScalar(u8, package.description, '\n');
    while (lines.next()) |line| {
        // A blank line of a long description is a single dot (deb-control(5)).
        const text = if (line.len == 0) "." else line;
        writer.print(" {s}\n", .{text}) catch return error.WriteFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// `Field: a, b (>= 1)` for a non-empty list; nothing for an empty one.
fn relation_line(
    writer: *std.Io.Writer,
    field: []const u8,
    relations: []const model.Relation,
) Error!void {
    if (relations.len == 0) return;
    writer.print("{s}: ", .{field}) catch return error.WriteFailed;
    for (relations, 0..) |relation, index| {
        if (index > 0) writer.writeAll(", ") catch return error.WriteFailed;
        writer.writeAll(relation.name) catch return error.WriteFailed;
        const operator: []const u8 = switch (relation.sense) {
            .any => continue,
            .ge => ">=",
            .eq => "=",
        };
        writer.print(" ({s} {s})", .{ operator, relation.version }) catch {
            return error.WriteFailed;
        };
    }
    writer.writeByte('\n') catch return error.WriteFailed;
}

/// The `conffiles` list: one absolute path per line, or null when no file is a config file.
fn conffiles_text(memory: Allocator, package: *const model.Package) Error!?[]u8 {
    var out = Output.init(memory);
    for (package.files) |file| {
        if (!file.config) continue;
        out.writer.print("{s}\n", .{file.path}) catch return error.WriteFailed;
    }
    if (out.writer.end == 0) return null;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn md5sums_text(memory: Allocator, package: *const model.Package) Error![]u8 {
    var out = Output.init(memory);
    for (package.files) |file| {
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(file.bytes, &digest, .{});
        out.writer.print("{x}  {s}\n", .{ &digest, file.path[1..] }) catch {
            return error.WriteFailed;
        };
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn dotted(memory: Allocator, path: []const u8, directory: bool) Error![]u8 {
    const suffix: []const u8 = if (directory) "/" else "";
    return std.fmt.allocPrint(memory, ".{s}{s}", .{ path, suffix }) catch error.OutOfMemory;
}

fn data_tar(memory: Allocator, package: *const model.Package) Error![]u8 {
    const entries = try model.layout(memory, package, false);
    const tar_entries = try memory.alloc(archive.TarEntry, entries.len + 1);
    tar_entries[0] = .{
        .name = "./",
        .mode = model.directory_mode,
        .bytes = "",
        .directory = true,
    };
    for (entries, 1..) |entry, index| {
        const directory = entry.file == null;
        tar_entries[index] = .{
            .name = try dotted(memory, entry.path, directory),
            .mode = if (entry.file) |file| file.mode else model.directory_mode,
            .bytes = if (entry.file) |file| file.bytes else "",
            .directory = directory,
        };
    }
    return archive.tar_write(memory, tar_entries);
}

/// The whole `.deb`, for a validated package.
pub fn write(memory: Allocator, package: *const model.Package) Error![]u8 {
    try model.validate(package);
    const control = try control_text(memory, package);
    const md5sums = try md5sums_text(memory, package);
    var control_entries: std.ArrayList(archive.TarEntry) = .empty;
    try control_entries.appendSlice(memory, &.{
        .{ .name = "./", .mode = model.directory_mode, .bytes = "", .directory = true },
        .{ .name = "./control", .mode = 0o644, .bytes = control, .directory = false },
    });
    if (package.files.len > 0) {
        try control_entries.append(
            memory,
            .{ .name = "./md5sums", .mode = 0o644, .bytes = md5sums, .directory = false },
        );
    }
    if (try conffiles_text(memory, package)) |conffiles| {
        try control_entries.append(
            memory,
            .{ .name = "./conffiles", .mode = 0o644, .bytes = conffiles, .directory = false },
        );
    }
    const control_tar = try archive.tar_write(memory, control_entries.items);
    const control_gz = try archive.gzip(memory, control_tar);
    const data_gz = try archive.gzip(memory, try data_tar(memory, package));
    return archive.ar_write(memory, &.{
        .{ .name = "debian-binary", .bytes = "2.0\n" },
        .{ .name = "control.tar.gz", .bytes = control_gz },
        .{ .name = "data.tar.gz", .bytes = data_gz },
    });
}

/// A small fixed package for tests and the golden files.
pub const sample: model.Package = .{
    .name = "sample",
    .version = "1.2.3",
    .architecture = .x86_64,
    .summary = "A small sample package",
    .description = "First line of the description.\n\nSecond paragraph.",
    .license = "MIT",
    .homepage = "https://example.invalid/sample",
    .maintainer = "Sample Maintainer <sample@example.invalid>",
    .recommends_deb = &.{ "uidmap", "passt" },
    .recommends_rpm = &.{ "shadow-utils", "passt" },
    .files = &.{
        .{ .path = "/usr/bin/sample", .mode = 0o755, .bytes = "#!/bin/sh\necho sample\n" },
        .{ .path = "/usr/share/doc/sample/copyright", .mode = 0o644, .bytes = "MIT licence\n" },
    },
};

test "the control text follows deb-control" {
    // Goal: the fields, the dotted blank line and the rounded-up size.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try control_text(arena.allocator(), &sample);
    try std.testing.expectEqualStrings(
        "Package: sample\nVersion: 1.2.3\nArchitecture: amd64\n" ++
            "Maintainer: Sample Maintainer <sample@example.invalid>\nInstalled-Size: 1\n" ++
            "Recommends: uidmap, passt\nSection: admin\nPriority: optional\n" ++
            "Homepage: https://example.invalid/sample\n" ++
            "Description: A small sample package\n First line of the description.\n .\n" ++
            " Second paragraph.\n",
        text,
    );
}

test "the sample deb matches the golden bytes checked with dpkg-deb" {
    // Goal: pin the whole file. `testdata/sample.deb` was written by this module and read back in
    // this container with `dpkg-deb -I` and `-c`; their output is in `testdata/sample.deb.txt`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try write(arena.allocator(), &sample);
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/sample.deb"), bytes);
    const second = try write(arena.allocator(), &sample);
    try std.testing.expectEqualSlices(u8, bytes, second);
}
