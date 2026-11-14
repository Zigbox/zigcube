//! The dnf repository writer, for one `$basearch` tree: the rpms and `repodata/` with
//! `primary.xml.gz`, `filelists.xml.gz`, `other.xml.gz` and `repomd.xml`, every sum SHA-256. The
//! metadata files are named by their checksum, as `createrepo_c` names them. `repomd.xml.asc` is
//! signed by the owner's gpg and placed by the caller.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const model = @import("model.zig");
const archive = @import("archive.zig");
const rpm = @import("rpm.zig");

const Allocator = std.mem.Allocator;
const Output = std.Io.Writer.Allocating;
pub const Error = model.Error;

const xml_header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";

fn put(writer: *std.Io.Writer, bytes: []const u8) Error!void {
    writer.writeAll(bytes) catch return error.WriteFailed;
}

/// Text content or attribute value, escaped.
fn put_escaped(writer: *std.Io.Writer, text: []const u8) Error!void {
    for (text) |byte| switch (byte) {
        '&' => try put(writer, "&amp;"),
        '<' => try put(writer, "&lt;"),
        '>' => try put(writer, "&gt;"),
        '"' => try put(writer, "&quot;"),
        else => try put(writer, &.{byte}),
    };
}

fn print(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) Error!void {
    writer.print(format, args) catch return error.WriteFailed;
}

/// What `createrepo_c` puts in primary.xml: paths in `bin` directories and under `/etc`.
fn in_primary(path: []const u8) bool {
    const prefixes = [_][]const u8{ "/etc/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return std.mem.eql(u8, path, "/usr/lib/sendmail");
}

fn put_files(
    writer: *std.Io.Writer,
    entries: []const model.Entry,
    primary_only: bool,
    indent: []const u8,
) Error!void {
    for (entries) |entry| {
        if (primary_only and !in_primary(entry.path)) continue;
        try put(writer, indent);
        try put(writer, if (entry.file == null) "<file type=\"dir\">" else "<file>");
        try put_escaped(writer, entry.path);
        try put(writer, "</file>\n");
    }
}

fn provides_xml(
    memory: Allocator,
    writer: *std.Io.Writer,
    package: *const model.Package,
) Error!void {
    const abi = package.architecture.rpm_abi();
    const provided = [2][]const u8{
        package.name,
        try std.fmt.allocPrint(memory, "{s}({s})", .{ package.name, abi }),
    };
    try put(writer, "    <rpm:provides>\n");
    for (provided) |name| {
        try print(
            writer,
            "      <rpm:entry name=\"{s}\" flags=\"EQ\" epoch=\"0\" ver=\"{s}\" rel=\"{s}\"/>\n",
            .{ name, package.version, package.revision },
        );
    }
    for (package.provides) |relation| {
        try print(writer, "      <rpm:entry name=\"{s}\"/>\n", .{relation.name});
    }
    try put(writer, "    </rpm:provides>\n");
}

/// A dependency list as primary.xml writes it: `<rpm:requires>` and the like. A version is
/// `version-release` for an rpm; one without a `-` has no release.
fn relations_xml(
    writer: *std.Io.Writer,
    element: []const u8,
    relations: []const model.Relation,
) Error!void {
    if (relations.len == 0) return;
    try print(writer, "    <rpm:{s}>\n", .{element});
    for (relations) |relation| {
        try print(writer, "      <rpm:entry name=\"{s}\"", .{relation.name});
        const flag: []const u8 = switch (relation.sense) {
            .any => "",
            .ge => "GE",
            .eq => "EQ",
        };
        if (flag.len > 0) {
            const split = std.mem.lastIndexOfScalar(u8, relation.version, '-');
            const ver = if (split) |index| relation.version[0..index] else relation.version;
            try print(writer, " flags=\"{s}\" epoch=\"0\" ver=\"{s}\"", .{ flag, ver });
            if (split) |index| {
                try print(writer, " rel=\"{s}\"", .{relation.version[index + 1 ..]});
            }
        }
        try put(writer, "/>\n");
    }
    try print(writer, "    </rpm:{s}>\n", .{element});
}

fn package_xml(
    memory: Allocator,
    writer: *std.Io.Writer,
    built: model.Built,
    pkgid: []const u8,
) Error!void {
    const package = built.package;
    const parts = rpm.split(built.bytes) orelse
        unreachable; // `built.bytes` is an rpm this module just wrote.
    const entries = try model.layout(memory, package, true);
    const epoch = constants.package_source_date_epoch;
    const rpm_arch = package.architecture.rpm_name();
    try put(writer, "<package type=\"rpm\">\n  <name>");
    try put_escaped(writer, package.name);
    try print(writer, "</name>\n  <arch>{s}</arch>\n", .{rpm_arch});
    try print(
        writer,
        "  <version epoch=\"0\" ver=\"{s}\" rel=\"{s}\"/>\n",
        .{ package.version, package.revision },
    );
    try print(
        writer,
        "  <checksum type=\"sha256\" pkgid=\"YES\">{s}</checksum>\n  <summary>",
        .{pkgid},
    );
    try put_escaped(writer, package.summary);
    try put(writer, "</summary>\n  <description>");
    try put_escaped(writer, package.description);
    try put(writer, "</description>\n  <packager></packager>\n  <url>");
    try put_escaped(writer, package.homepage);
    try print(writer, "</url>\n  <time file=\"{d}\" build=\"{d}\"/>\n", .{ epoch, epoch });
    try print(writer, "  <size package=\"{d}\" installed=\"{d}\" archive=\"{d}\"/>\n", .{
        built.bytes.len, model.content_bytes(package), try rpm.archive_bytes(memory, package),
    });
    const file_name = try rpm.file_name(memory, package);
    try print(writer, "  <location href=\"{s}\"/>\n  <format>\n    <rpm:license>", .{file_name});
    try put_escaped(writer, package.license);
    try put(
        writer,
        "</rpm:license>\n    <rpm:vendor></rpm:vendor>\n    <rpm:group>Unspecified</rpm:group>\n",
    );
    try print(writer, "    <rpm:buildhost>{s}</rpm:buildhost>\n", .{rpm.build_host});
    try print(
        writer,
        "    <rpm:sourcerpm>{s}-{s}-{s}.src.rpm</rpm:sourcerpm>\n",
        .{ package.name, package.version, package.revision },
    );
    try print(
        writer,
        "    <rpm:header-range start=\"{d}\" end=\"{d}\"/>\n",
        .{ parts.header_start, parts.header_end },
    );
    try provides_xml(memory, writer, package);
    try relations_xml(writer, "requires", package.depends_rpm);
    try relations_xml(writer, "conflicts", package.conflicts);
    try relations_xml(writer, "obsoletes", package.replaces);
    if (package.recommends_rpm.len > 0) {
        try put(writer, "    <rpm:recommends>\n");
        for (package.recommends_rpm) |name| {
            try put(writer, "      <rpm:entry name=\"");
            try put_escaped(writer, name);
            try put(writer, "\"/>\n");
        }
        try put(writer, "    </rpm:recommends>\n");
    }
    try put_files(writer, entries, true, "    ");
    try put(writer, "  </format>\n</package>\n");
}

fn filelists_xml(
    memory: Allocator,
    writer: *std.Io.Writer,
    built: model.Built,
    pkgid: []const u8,
) Error!void {
    const package = built.package;
    try print(writer, "<package pkgid=\"{s}\" name=\"{s}\" arch=\"{s}\">\n", .{
        pkgid, package.name, package.architecture.rpm_name(),
    });
    try print(
        writer,
        "  <version epoch=\"0\" ver=\"{s}\" rel=\"{s}\"/>\n",
        .{ package.version, package.revision },
    );
    try put_files(writer, try model.layout(memory, package, true), false, "  ");
    try put(writer, "</package>\n");
}

fn other_xml(writer: *std.Io.Writer, built: model.Built, pkgid: []const u8) Error!void {
    const package = built.package;
    try print(writer, "<package pkgid=\"{s}\" name=\"{s}\" arch=\"{s}\">\n", .{
        pkgid, package.name, package.architecture.rpm_name(),
    });
    try print(
        writer,
        "  <version epoch=\"0\" ver=\"{s}\" rel=\"{s}\"/>\n</package>\n",
        .{ package.version, package.revision },
    );
}

const Document = enum { primary, filelists, other };

fn document(memory: Allocator, kind: Document, packages: []const model.Built) Error![]u8 {
    var out = Output.init(memory);
    const writer = &out.writer;
    try put(writer, xml_header);
    const count = packages.len;
    switch (kind) {
        .primary => try print(
            writer,
            "<metadata xmlns=\"http://linux.duke.edu/metadata/common\" " ++
                "xmlns:rpm=\"http://linux.duke.edu/metadata/rpm\" packages=\"{d}\">\n",
            .{count},
        ),
        .filelists => try print(
            writer,
            "<filelists xmlns=\"http://linux.duke.edu/metadata/filelists\" " ++
                "packages=\"{d}\">\n",
            .{count},
        ),
        .other => try print(writer, "<otherdata xmlns=\"http://linux.duke.edu/metadata/other\" " ++
            "packages=\"{d}\">\n", .{count}),
    }
    for (packages) |built| {
        const pkgid = &model.digest_hex(built.bytes);
        switch (kind) {
            .primary => try package_xml(memory, writer, built, pkgid),
            .filelists => try filelists_xml(memory, writer, built, pkgid),
            .other => try other_xml(writer, built, pkgid),
        }
    }
    try put(writer, switch (kind) {
        .primary => "</metadata>",
        .filelists => "</filelists>",
        .other => "</otherdata>",
    });
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn built_less(_: void, left: model.Built, right: model.Built) bool {
    const by_name = std.mem.order(u8, left.package.name, right.package.name);
    if (by_name != .eq) return by_name == .lt;
    return std.mem.order(u8, left.package.version, right.package.version) == .lt;
}

/// The tree of one architecture: paths are relative to `rpm/<basearch>/`.
pub fn write(
    memory: Allocator,
    architecture: model.Architecture,
    built: []const model.Built,
) Error![]model.TreeFile {
    if (built.len == 0 or built.len > constants.repo_packages_max) return error.TooManyFiles;
    const sorted = try memory.dupe(model.Built, built);
    std.mem.sort(model.Built, sorted, {}, built_less);
    var files: std.ArrayList(model.TreeFile) = .empty;
    var repomd = Output.init(memory);
    try put(&repomd.writer, xml_header ++
        "<repomd xmlns=\"http://linux.duke.edu/metadata/repo\" " ++
        "xmlns:rpm=\"http://linux.duke.edu/metadata/rpm\">\n");
    try print(
        &repomd.writer,
        "  <revision>{d}</revision>\n",
        .{constants.package_source_date_epoch},
    );
    for (sorted) |item| {
        assert(item.package.architecture == architecture);
        try files.append(
            memory,
            .{ .path = try rpm.file_name(memory, item.package), .bytes = item.bytes },
        );
    }
    for ([_]Document{ .primary, .filelists, .other }) |kind| {
        const plain = try document(memory, kind, sorted);
        const gzipped = try archive.gzip(memory, plain);
        const sum = try memory.dupe(u8, &model.digest_hex(gzipped));
        const href = try std.fmt.allocPrint(
            memory,
            "repodata/{s}-{s}.xml.gz",
            .{ sum, @tagName(kind) },
        );
        try files.append(memory, .{ .path = href, .bytes = gzipped });
        try print(&repomd.writer, "  <data type=\"{s}\">\n", .{@tagName(kind)});
        try print(&repomd.writer, "    <checksum type=\"sha256\">{s}</checksum>\n", .{sum});
        try print(
            &repomd.writer,
            "    <open-checksum type=\"sha256\">{s}</open-checksum>\n",
            .{&model.digest_hex(plain)},
        );
        try print(&repomd.writer, "    <location href=\"{s}\"/>\n", .{href});
        try print(
            &repomd.writer,
            "    <timestamp>{d}</timestamp>\n",
            .{constants.package_source_date_epoch},
        );
        try print(
            &repomd.writer,
            "    <size>{d}</size>\n    <open-size>{d}</open-size>\n  </data>\n",
            .{ gzipped.len, plain.len },
        );
    }
    try put(&repomd.writer, "</repomd>\n");
    try files.append(
        memory,
        .{ .path = "repodata/repomd.xml", .bytes = try repomd.toOwnedSlice() },
    );
    assert(files.items.len <= constants.repo_files_max);
    return files.items;
}

test "the tree has the rpm, three checksum-named metadata files and repomd.xml" {
    // Goal: layout, and every sum in repomd.xml equals the placed bytes.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const sample = &@import("deb.zig").sample;
    const bytes = try rpm.write(memory, sample, .{});
    const built = [_]model.Built{.{ .package = sample, .bytes = bytes }};
    const files = try write(memory, .x86_64, &built);
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try std.testing.expectEqualStrings("sample-1.2.3-1.x86_64.rpm", files[0].path);
    const repomd = files[4].bytes;
    for (files[1..4]) |file| {
        const sum = &model.digest_hex(file.bytes);
        try std.testing.expect(std.mem.indexOf(u8, repomd, sum) != null);
        try std.testing.expect(std.mem.indexOf(u8, file.path, sum) != null);
    }
}
