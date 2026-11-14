//! The `.rpm` writer. Layout (rpm.org's "File Format"): a 96-byte lead, a signature header padded
//! to eight bytes, the main header, and the gzip'd cpio payload. A header is the magic
//! `8e ad e8 01`, four reserved bytes, the entry and data counts, sorted 16-byte index entries
//! and a data store; both headers carry an "immutable region" trailer, as rpmbuild writes.
//!
//! The tag set is the one rpmbuild 4.18 writes for a plain binary package, less what only a
//! build host knows (colors, classes). The payload digest is SHA-256 of the compressed payload
//! (`RPMTAG_PAYLOADDIGEST`); file digests are SHA-256. A header signature (`RPMSIGTAG_RSA`, 268)
//! goes in the signature header only, so it changes neither the main header nor its digest.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const model = @import("model.zig");
const archive = @import("archive.zig");

const Allocator = std.mem.Allocator;
const Output = std.Io.Writer.Allocating;
pub const Error = model.Error;

const tag_type = struct {
    const int16: u32 = 3;
    const int32: u32 = 4;
    const string: u32 = 6;
    const binary: u32 = 7;
    const string_array: u32 = 8;
    const i18n_string: u32 = 9;
};

/// Tag numbers (rpm's `rpmtag.h`). Signature-header tags are in `sig_tag`.
const tag = struct {
    const header_i18n_table: u32 = 100;
    const name: u32 = 1000;
    const version: u32 = 1001;
    const release: u32 = 1002;
    const summary: u32 = 1004;
    const description: u32 = 1005;
    const build_time: u32 = 1006;
    const build_host: u32 = 1007;
    const size: u32 = 1009;
    const license: u32 = 1014;
    const group: u32 = 1016;
    const url: u32 = 1020;
    const os: u32 = 1021;
    const arch: u32 = 1022;
    const file_sizes: u32 = 1028;
    const file_modes: u32 = 1030;
    const file_rdevs: u32 = 1033;
    const file_mtimes: u32 = 1034;
    const file_digests: u32 = 1035;
    const file_link_tos: u32 = 1036;
    const file_flags: u32 = 1037;
    const file_user_names: u32 = 1039;
    const file_group_names: u32 = 1040;
    const source_rpm: u32 = 1044;
    const file_verify_flags: u32 = 1045;
    const provide_name: u32 = 1047;
    const require_flags: u32 = 1048;
    const require_name: u32 = 1049;
    const require_version: u32 = 1050;
    const conflict_flags: u32 = 1053;
    const conflict_name: u32 = 1054;
    const conflict_version: u32 = 1055;
    const obsolete_name: u32 = 1090;
    const file_devices: u32 = 1095;
    const file_inodes: u32 = 1096;
    const file_langs: u32 = 1097;
    const provide_flags: u32 = 1112;
    const provide_version: u32 = 1113;
    const obsolete_flags: u32 = 1114;
    const obsolete_version: u32 = 1115;
    const base_names: u32 = 1117;
    const dir_names: u32 = 1118;
    const dir_indexes: u32 = 1116;
    const payload_format: u32 = 1124;
    const payload_compressor: u32 = 1125;
    const payload_flags: u32 = 1126;
    const platform: u32 = 1132;
    const file_digest_algo: u32 = 5011;
    const recommend_name: u32 = 5046;
    const recommend_version: u32 = 5047;
    const recommend_flags: u32 = 5048;
    const encoding: u32 = 5062;
    const payload_digest: u32 = 5092;
    const payload_digest_algo: u32 = 5093;
};

pub const sig_tag = struct {
    pub const size: u32 = 1000;
    pub const md5: u32 = 1004;
    pub const payload_size: u32 = 1007;
    pub const rsa: u32 = 268;
    pub const sha256: u32 = 273;
};

/// The build host every package names, so that the file does not depend on the machine.
pub const build_host = "zigbox-build";

const region_signatures: u32 = 62;
const region_immutable: u32 = 63;
const header_magic = [8]u8{ 0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0 };
const lead_bytes: u32 = 96;
/// `RPMSENSE_EQUAL`, and `RPMSENSE_RPMLIB | RPMSENSE_LESS | RPMSENSE_EQUAL`.
const sense_equal: u32 = 8;
const sense_greater_equal: u32 = 4 | 8;
/// RPMFILE_CONFIG | RPMFILE_NOREPLACE: an edited file is kept on upgrade, the new one is `.rpmnew`.
const file_config_noreplace: u32 = 1 | 16;
const sense_rpmlib_less_equal: u32 = 0x0100_0000 | 0x0a;
/// The digest algorithm number of SHA-256 in rpm (PGPHASHALGO_SHA256).
const digest_sha256: u32 = 8;
const verify_all: u32 = 0xffff_ffff;

const Entry = struct { tag: u32, kind: u32, count: u32, start: u32, length: u32 };

/// Collects one header's entries and data, then serializes them sorted by tag.
const Header = struct {
    memory: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    data: Output,

    fn init(memory: Allocator) Header {
        return .{ .memory = memory, .data = Output.init(memory) };
    }

    fn begin(h: *Header, kind: u32, count: u32, tag_number: u32) Error!void {
        const alignment: usize = switch (kind) {
            tag_type.int16 => 2,
            tag_type.int32 => 4,
            else => 1,
        };
        const writer = &h.data.writer;
        const pad = (alignment - writer.end % alignment) % alignment;
        writer.splatByteAll(0, pad) catch return error.WriteFailed;
        if (h.entries.items.len >= constants.rpm_header_entries_max) return error.WriteFailed;
        h.entries.append(h.memory, .{
            .tag = tag_number,
            .kind = kind,
            .count = count,
            .start = @intCast(writer.end),
            .length = 0,
        }) catch return error.OutOfMemory;
    }

    fn done(h: *Header) Error!void {
        const entry = &h.entries.items[h.entries.items.len - 1];
        entry.length = @as(u32, @intCast(h.data.writer.end)) - entry.start;
        if (h.data.writer.end > constants.rpm_header_bytes_max) return error.WriteFailed;
    }

    fn string(h: *Header, tag_number: u32, kind: u32, text: []const u8) Error!void {
        try h.begin(kind, 1, tag_number);
        h.data.writer.writeAll(text) catch return error.WriteFailed;
        h.data.writer.writeByte(0) catch return error.WriteFailed;
        try h.done();
    }

    fn strings(h: *Header, tag_number: u32, items: []const []const u8) Error!void {
        try h.begin(tag_type.string_array, @intCast(items.len), tag_number);
        for (items) |item| {
            h.data.writer.writeAll(item) catch return error.WriteFailed;
            h.data.writer.writeByte(0) catch return error.WriteFailed;
        }
        try h.done();
    }

    fn int32s(h: *Header, tag_number: u32, items: []const u32) Error!void {
        try h.begin(tag_type.int32, @intCast(items.len), tag_number);
        for (items) |item| h.data.writer.writeInt(u32, item, .big) catch return error.WriteFailed;
        try h.done();
    }

    fn int16s(h: *Header, tag_number: u32, items: []const u16) Error!void {
        try h.begin(tag_type.int16, @intCast(items.len), tag_number);
        for (items) |item| h.data.writer.writeInt(u16, item, .big) catch return error.WriteFailed;
        try h.done();
    }

    fn binary(h: *Header, tag_number: u32, bytes: []const u8) Error!void {
        try h.begin(tag_type.binary, @intCast(bytes.len), tag_number);
        h.data.writer.writeAll(bytes) catch return error.WriteFailed;
        try h.done();
    }

    /// The header as stored: intro, the region entry, the sorted entries, the data, the region
    /// trailer. `region` is 62 for the signature header and 63 for the main one.
    fn finish(h: *Header, region: u32) Error![]u8 {
        const entries = h.entries.items;
        std.mem.sort(Entry, entries, {}, entry_less);
        // rpm requires data offsets to rise with the sorted index, so lay the data out again in
        // tag order rather than in the order the entries were added.
        const source = h.data.written();
        var store = Output.init(h.memory);
        for (entries) |*entry| {
            const alignment: usize = switch (entry.kind) {
                tag_type.int16 => 2,
                tag_type.int32 => 4,
                else => 1,
            };
            const pad = (alignment - store.writer.end % alignment) % alignment;
            store.writer.splatByteAll(0, pad) catch return error.WriteFailed;
            const bytes = source[entry.start..][0..entry.length];
            entry.start = @intCast(store.writer.end);
            store.writer.writeAll(bytes) catch return error.WriteFailed;
        }
        const trailer_offset: u32 = @intCast(store.writer.end);
        const count: u32 = @intCast(entries.len + 1);
        var out = Output.init(h.memory);
        const writer = &out.writer;
        writer.writeAll(&header_magic) catch return error.WriteFailed;
        writer.writeInt(u32, count, .big) catch return error.WriteFailed;
        writer.writeInt(u32, trailer_offset + 16, .big) catch return error.WriteFailed;
        try index_entry(writer, region, tag_type.binary, trailer_offset, 16);
        for (entries) |entry| try index_entry(
            writer,
            entry.tag,
            entry.kind,
            entry.start,
            entry.count,
        );
        writer.writeAll(store.written()) catch return error.WriteFailed;
        // The trailer is an index entry whose offset is minus the bytes of entries it covers.
        const covered: i32 = -@as(i32, @intCast((entries.len + 1) * 16));
        try index_entry(writer, region, tag_type.binary, @bitCast(covered), 16);
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

fn entry_less(_: void, left: Entry, right: Entry) bool {
    return left.tag < right.tag;
}

fn index_entry(
    writer: *std.Io.Writer,
    tag_number: u32,
    kind: u32,
    offset: u32,
    count: u32,
) Error!void {
    writer.writeInt(u32, tag_number, .big) catch return error.WriteFailed;
    writer.writeInt(u32, kind, .big) catch return error.WriteFailed;
    writer.writeInt(u32, offset, .big) catch return error.WriteFailed;
    writer.writeInt(u32, count, .big) catch return error.WriteFailed;
}

/// The file list as rpm's parallel arrays, owned by `memory`.
const Files = struct {
    sizes: []u32,
    modes: []u16,
    zeros16: []u16,
    mtimes: []u32,
    inodes: []u32,
    flags: []u32,
    digests: [][]const u8,
    blanks: [][]const u8,
    roots: [][]const u8,
    base_names: [][]const u8,
    dir_names: [][]const u8,
    dir_indexes: []u32,
    verify: []u32,
    ones: []u32,
    cpio: []archive.CpioEntry,
};

fn file_arrays(memory: Allocator, package: *const model.Package) Error!Files {
    const entries = try model.layout(memory, package, true);
    const count = entries.len;
    var f: Files = undefined;
    f.sizes = try memory.alloc(u32, count);
    f.modes = try memory.alloc(u16, count);
    f.zeros16 = try memory.alloc(u16, count);
    f.mtimes = try memory.alloc(u32, count);
    f.inodes = try memory.alloc(u32, count);
    f.verify = try memory.alloc(u32, count);
    f.flags = try memory.alloc(u32, count);
    f.ones = try memory.alloc(u32, count);
    f.digests = try memory.alloc([]const u8, count);
    f.blanks = try memory.alloc([]const u8, count);
    f.roots = try memory.alloc([]const u8, count);
    f.base_names = try memory.alloc([]const u8, count);
    f.dir_indexes = try memory.alloc(u32, count);
    f.cpio = try memory.alloc(archive.CpioEntry, count);
    var dir_names: std.ArrayList([]const u8) = .empty;
    for (entries, 0..) |entry, index| {
        const slash = std.mem.lastIndexOfScalar(u8, entry.path, '/').?;
        const dir = try std.fmt.allocPrint(memory, "{s}/", .{entry.path[0..slash]});
        f.dir_indexes[index] = try dir_index(memory, &dir_names, dir);
        f.base_names[index] = entry.path[slash + 1 ..];
        const bytes: []const u8 = if (entry.file) |file| file.bytes else "";
        const mode: u32 = if (entry.file) |file|
            0o100000 | file.mode
        else
            0o040000 | model.directory_mode;
        f.sizes[index] = @intCast(bytes.len);
        f.modes[index] = @intCast(mode);
        f.zeros16[index] = 0;
        f.mtimes[index] = @intCast(constants.package_source_date_epoch);
        f.inodes[index] = @intCast(index + 1);
        f.verify[index] = verify_all;
        f.flags[index] = if (entry.file) |file|
            (if (file.config) file_config_noreplace else 0)
        else
            0;
        f.ones[index] = 1;
        f.digests[index] = if (entry.file == null) "" else try memory.dupe(
            u8,
            &model.digest_hex(bytes),
        );
        f.blanks[index] = "";
        f.roots[index] = "root";
        const name = try std.fmt.allocPrint(memory, ".{s}", .{entry.path});
        const inode: u32 = @intCast(index + 1);
        f.cpio[index] = .{ .name = name, .mode = mode, .bytes = bytes, .inode = inode };
    }
    f.dir_names = dir_names.items;
    return f;
}

fn dir_index(memory: Allocator, names: *std.ArrayList([]const u8), dir: []const u8) Error!u32 {
    for (names.items, 0..) |name, index| {
        if (std.mem.eql(u8, name, dir)) return @intCast(index);
    }
    names.append(memory, dir) catch return error.OutOfMemory;
    return @intCast(names.items.len - 1);
}

fn file_tags(h: *Header, f: *const Files) Error!void {
    if (f.sizes.len == 0) return; // A metapackage lists no files and no directories.
    try h.int32s(tag.file_sizes, f.sizes);
    try h.int16s(tag.file_modes, f.modes);
    try h.int16s(tag.file_rdevs, f.zeros16);
    try h.int32s(tag.file_mtimes, f.mtimes);
    try h.strings(tag.file_digests, f.digests);
    try h.strings(tag.file_link_tos, f.blanks);
    try h.int32s(tag.file_flags, f.flags);
    try h.strings(tag.file_user_names, f.roots);
    try h.strings(tag.file_group_names, f.roots);
    try h.int32s(tag.file_verify_flags, f.verify);
    try h.int32s(tag.file_devices, f.ones);
    try h.int32s(tag.file_inodes, f.inodes);
    try h.strings(tag.file_langs, f.blanks);
    try h.strings(tag.base_names, f.base_names);
    try h.strings(tag.dir_names, f.dir_names);
    try h.int32s(tag.dir_indexes, f.dir_indexes);
}

fn sense_flags(sense: model.Sense) u32 {
    return switch (sense) {
        .any => 0,
        .ge => sense_greater_equal,
        .eq => sense_equal,
    };
}

/// One dependency kind as the three parallel arrays rpm keeps: names, flags and versions.
fn relation_tags(
    h: *Header,
    memory: Allocator,
    tags: [3]u32,
    relations: []const model.Relation,
) Error!void {
    if (relations.len == 0) return;
    const names = try memory.alloc([]const u8, relations.len);
    const flags = try memory.alloc(u32, relations.len);
    const versions = try memory.alloc([]const u8, relations.len);
    for (relations, 0..) |relation, index| {
        names[index] = relation.name;
        flags[index] = sense_flags(relation.sense);
        versions[index] = relation.version;
    }
    try h.strings(tags[0], names);
    try h.int32s(tags[1], flags);
    try h.strings(tags[2], versions);
}

fn dependency_tags(h: *Header, memory: Allocator, package: *const model.Package) Error!void {
    const nevr = try std.fmt.allocPrint(memory, "{s}-{s}", .{ package.version, package.revision });
    const abi = try std.fmt.allocPrint(memory, "{s}({s})", .{
        package.name, package.architecture.rpm_abi(),
    });
    var provides: std.ArrayList(model.Relation) = .empty;
    try provides.append(memory, .{ .name = package.name, .sense = .eq, .version = nevr });
    try provides.append(memory, .{ .name = abi, .sense = .eq, .version = nevr });
    try provides.appendSlice(memory, package.provides);
    const provide_tags = [3]u32{ tag.provide_name, tag.provide_flags, tag.provide_version };
    try relation_tags(h, memory, provide_tags, provides.items);
    var requires: std.ArrayList(model.Relation) = .empty;
    try requires.appendSlice(memory, package.depends_rpm);
    const rpmlib = [_][]const u8{
        "rpmlib(CompressedFileNames)", "rpmlib(FileDigests)", "rpmlib(PayloadFilesHavePrefix)",
    };
    const rpmlib_versions = [_][]const u8{ "3.0.4-1", "4.6.0-1", "4.0-1" };
    var require_senses: std.ArrayList(u32) = .empty;
    for (package.depends_rpm) |relation| {
        try require_senses.append(memory, sense_flags(relation.sense));
    }
    for (rpmlib) |_| try require_senses.append(memory, sense_rpmlib_less_equal);
    const names = try memory.alloc([]const u8, requires.items.len + rpmlib.len);
    const versions = try memory.alloc([]const u8, names.len);
    for (requires.items, 0..) |relation, index| {
        names[index] = relation.name;
        versions[index] = relation.version;
    }
    for (rpmlib, rpmlib_versions, requires.items.len..) |name, version, index| {
        names[index] = name;
        versions[index] = version;
    }
    try h.strings(tag.require_name, names);
    try h.int32s(tag.require_flags, require_senses.items);
    try h.strings(tag.require_version, versions);
    const conflict_tags = [3]u32{ tag.conflict_name, tag.conflict_flags, tag.conflict_version };
    try relation_tags(h, memory, conflict_tags, package.conflicts);
    const obsolete_tags = [3]u32{ tag.obsolete_name, tag.obsolete_flags, tag.obsolete_version };
    try relation_tags(h, memory, obsolete_tags, package.replaces);
    const weak = package.recommends_rpm;
    if (weak.len == 0) return;
    const weak_senses = try memory.alloc(u32, weak.len);
    @memset(weak_senses, 0);
    const weak_versions = try memory.alloc([]const u8, weak.len);
    @memset(weak_versions, "");
    try h.strings(tag.recommend_name, weak);
    try h.strings(tag.recommend_version, weak_versions);
    try h.int32s(tag.recommend_flags, weak_senses);
}

/// The main header's bytes: what the header digest covers and a header signature signs.
fn main_header(
    memory: Allocator,
    package: *const model.Package,
    files: *const Files,
    payload: Payload,
) Error![]u8 {
    var h = Header.init(memory);
    const nevr = try std.fmt.allocPrint(
        memory,
        "{s}-{s}-{s}.src.rpm",
        .{ package.name, package.version, package.revision },
    );
    const platform = try std.fmt.allocPrint(
        memory,
        "{s}-linux",
        .{package.architecture.rpm_name()},
    );
    try h.strings(tag.header_i18n_table, &.{"C"});
    try h.string(tag.name, tag_type.string, package.name);
    try h.string(tag.version, tag_type.string, package.version);
    try h.string(tag.release, tag_type.string, package.revision);
    try h.string(tag.summary, tag_type.i18n_string, package.summary);
    try h.string(tag.description, tag_type.i18n_string, package.description);
    try h.int32s(tag.build_time, &.{@intCast(constants.package_source_date_epoch)});
    try h.string(tag.build_host, tag_type.string, build_host);
    try h.int32s(tag.size, &.{@intCast(model.content_bytes(package))});
    try h.string(tag.license, tag_type.string, package.license);
    try h.string(tag.group, tag_type.i18n_string, "Unspecified");
    try h.string(tag.url, tag_type.string, package.homepage);
    try h.string(tag.os, tag_type.string, "linux");
    try h.string(tag.arch, tag_type.string, package.architecture.rpm_name());
    try h.string(tag.source_rpm, tag_type.string, nevr);
    try file_tags(&h, files);
    try dependency_tags(&h, memory, package);
    try h.string(tag.payload_format, tag_type.string, "cpio");
    try h.string(tag.payload_compressor, tag_type.string, "gzip");
    try h.string(tag.payload_flags, tag_type.string, "9");
    try h.string(tag.platform, tag_type.string, platform);
    try h.int32s(tag.file_digest_algo, &.{digest_sha256});
    try h.string(tag.encoding, tag_type.string, "utf-8");
    try h.strings(tag.payload_digest, &.{payload.digest_hex});
    try h.int32s(tag.payload_digest_algo, &.{digest_sha256});
    return h.finish(region_immutable);
}

const Payload = struct { cpio_bytes: usize, digest_hex: []const u8 };

fn signature_header(
    memory: Allocator,
    main: []const u8,
    compressed: []const u8,
    cpio_bytes: usize,
    header_signature: ?[]const u8,
) Error![]u8 {
    var h = Header.init(memory);
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(main);
    md5.update(compressed);
    var md5_digest: [16]u8 = undefined;
    md5.final(&md5_digest);
    const total: u32 = @intCast(main.len + compressed.len);
    try h.int32s(sig_tag.size, &.{total});
    try h.binary(sig_tag.md5, &md5_digest);
    try h.int32s(sig_tag.payload_size, &.{@intCast(cpio_bytes)});
    try h.string(sig_tag.sha256, tag_type.string, &model.digest_hex(main));
    if (header_signature) |signature| {
        assert(signature.len <= constants.openpgp_signature_bytes_max);
        try h.binary(sig_tag.rsa, signature);
    }
    const bytes = try h.finish(region_signatures);
    // The signature header is padded so that the main header starts on an eight-byte boundary.
    const pad = (8 - bytes.len % 8) % 8;
    const padded = try memory.alloc(u8, bytes.len + pad);
    @memcpy(padded[0..bytes.len], bytes);
    @memset(padded[bytes.len..], 0);
    return padded;
}

/// The lead's name field is 66 bytes with its NUL.
const lead_name_bytes_max = 65;

fn lead(package: *const model.Package) [lead_bytes]u8 {
    var bytes: [lead_bytes]u8 = @splat(0);
    @memcpy(bytes[0..4], &[4]u8{ 0xed, 0xab, 0xee, 0xdb });
    bytes[4] = 3; // Major.
    bytes[5] = 0; // Minor.
    // Type 0 is a binary package; rpm's `arch_canon` table (rpmrc.in) gives x86_64 1, aarch64 19.
    const archnum: u16 = switch (package.architecture) {
        .x86_64 => 1,
        .aarch64 => 19,
    };
    std.mem.writeInt(u16, bytes[8..10], archnum, .big);
    // The name is a NUL-terminated char[66] that nothing reads back; rpm itself cuts it at 65
    // bytes (rpmlead.c), and so do we: validate allows 64 bytes each of name, version, revision.
    var full: [3 * constants.package_name_bytes_max + 2]u8 = undefined;
    const text = std.fmt.bufPrint(&full, "{s}-{s}-{s}", .{
        package.name, package.version, package.revision,
    }) catch unreachable; // Three names at their bound and two dashes fit `full`.
    const length = @min(text.len, lead_name_bytes_max);
    @memcpy(bytes[10..][0..length], text[0..length]);
    std.mem.writeInt(u16, bytes[76..78], 1, .big); // osnum: Linux.
    std.mem.writeInt(u16, bytes[78..80], 5, .big); // signature type: header-style.
    return bytes;
}

/// Where the parts of an rpm lie, for tests, the signer and the repository writer.
pub const Parts = struct {
    signature_header: []const u8,
    main_header: []const u8,
    payload: []const u8,
    /// The offsets of the main header in the whole file (rpm's header-range).
    header_start: u32,
    header_end: u32,
};

fn header_length(bytes: []const u8) ?usize {
    if (bytes.len < 16) return null;
    if (!std.mem.eql(u8, bytes[0..8], &header_magic)) return null;
    const entries = std.mem.readInt(u32, bytes[8..12], .big);
    const data = std.mem.readInt(u32, bytes[12..16], .big);
    const total = 16 + @as(u64, entries) * 16 + data;
    if (total > bytes.len) return null;
    return @intCast(total);
}

/// Splits an rpm into its parts; null when it is not one this writer could have made.
pub fn split(bytes: []const u8) ?Parts {
    if (bytes.len < lead_bytes) return null;
    if (!std.mem.eql(u8, bytes[0..4], &[4]u8{ 0xed, 0xab, 0xee, 0xdb })) return null;
    const sig_length = header_length(bytes[lead_bytes..]) orelse return null;
    const sig_end = lead_bytes + std.mem.alignForward(usize, sig_length, 8);
    if (sig_end > bytes.len) return null;
    const main_length = header_length(bytes[sig_end..]) orelse return null;
    const main_end = sig_end + main_length;
    return .{
        .signature_header = bytes[lead_bytes..sig_end],
        .main_header = bytes[sig_end..main_end],
        .payload = bytes[main_end..],
        .header_start = @intCast(sig_end),
        .header_end = @intCast(main_end),
    };
}

/// The bytes of a binary tag (type 7) in a header, such as the OpenPGP signature (268) in a
/// signature header; null when the tag is absent or the header is damaged.
pub fn binary_tag(header: []const u8, wanted: u32) ?[]const u8 {
    const length = header_length(header) orelse return null;
    const entries = std.mem.readInt(u32, header[8..12], .big);
    const data_start = 16 + @as(usize, entries) * 16;
    const data = header[data_start..length];
    for (0..entries) |index| {
        const entry = header[16 + index * 16 ..][0..16];
        if (std.mem.readInt(u32, entry[0..4], .big) != wanted) continue;
        if (std.mem.readInt(u32, entry[4..8], .big) != tag_type.binary) return null;
        const offset: usize = std.mem.readInt(u32, entry[8..12], .big);
        const count: usize = std.mem.readInt(u32, entry[12..16], .big);
        if (offset > data.len or count > data.len - offset) return null;
        return data[offset..][0..count];
    }
    return null;
}

pub const Options = struct {
    /// An OpenPGP signature (binary packet) over `header_bytes`, to place in the signature header.
    header_signature: ?[]const u8 = null,
};

/// The file name dnf expects: `<name>-<version>-<revision>.<arch>.rpm`.
pub fn file_name(memory: Allocator, package: *const model.Package) Error![]u8 {
    return std.fmt.allocPrint(memory, "{s}-{s}-{s}.{s}.rpm", .{
        package.name, package.version, package.revision, package.architecture.rpm_name(),
    }) catch return error.OutOfMemory;
}

/// The main header's bytes: the data a header signature covers.
pub fn header_bytes(memory: Allocator, package: *const model.Package) Error![]u8 {
    const parts = split(try write(memory, package, .{})).?;
    return memory.dupe(u8, parts.main_header) catch return error.OutOfMemory;
}

/// The whole `.rpm`, for a validated package.
pub fn write(memory: Allocator, package: *const model.Package, options: Options) Error![]u8 {
    try model.validate(package);
    const files = try file_arrays(memory, package);
    const cpio = try archive.cpio_write(memory, files.cpio);
    const compressed = try archive.gzip(memory, cpio);
    const digest = try memory.dupe(u8, &model.digest_hex(compressed));
    const main = try main_header(
        memory,
        package,
        &files,
        .{ .cpio_bytes = cpio.len, .digest_hex = digest },
    );
    const signature = try signature_header(
        memory,
        main,
        compressed,
        cpio.len,
        options.header_signature,
    );
    const lead_block = lead(package);
    const parts = [_][]const u8{ &lead_block, signature, main, compressed };
    return std.mem.concat(memory, u8, &parts) catch return error.OutOfMemory;
}

test "the sample rpm matches the golden bytes captured from rpm 4.18" {
    // Goal: pin the whole file. `testdata/sample.rpm` was written by this module, then checked in
    // this container with `rpm -K` (digests OK), `rpm -qpi`, `rpm -qp --dump`, and an install
    // under `--root` followed by `rpm -V`; their output is in `testdata/sample.rpm.txt`.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try write(arena.allocator(), &@import("deb.zig").sample, .{});
    try std.testing.expectEqualSlices(u8, @embedFile("testdata/sample.rpm"), bytes);
}

test "the lead's name is cut at 65 bytes and keeps its NUL, at the bound and one past" {
    // Goal: a name-version-revision of any length validate allows never overruns the 66-byte lead
    // name. 65 bytes fit whole; 66 and the 194 of three 64-byte names are cut to 65 bytes.
    const n30: [30]u8 = @splat('n');
    const v30: [30]u8 = @splat('1');
    const r3: [3]u8 = @splat('r');
    const r4: [4]u8 = @splat('r');
    var package = @import("deb.zig").sample;
    package.name = &n30;
    package.version = &v30;
    package.revision = &r3; // 30 + 1 + 30 + 1 + 3 = 65.
    var expected: [65]u8 = undefined;
    _ = try std.fmt.bufPrint(&expected, "{s}-{s}-{s}", .{ n30, v30, r3 });
    var bytes = lead(&package);
    try std.testing.expectEqualSlices(u8, &expected, bytes[10..75]);
    try std.testing.expectEqual(@as(u8, 0), bytes[75]);
    package.revision = &r4; // 66 bytes: the last one is dropped.
    bytes = lead(&package);
    try std.testing.expectEqualSlices(u8, &expected, bytes[10..75]);
    try std.testing.expectEqual(@as(u8, 0), bytes[75]);
    const n64: [64]u8 = @splat('n');
    const v64: [64]u8 = @splat('1');
    const r64: [64]u8 = @splat('r');
    package.name = &n64;
    package.version = &v64;
    package.revision = &r64;
    try model.validate(&package);
    bytes = lead(&package);
    try std.testing.expectEqual(@as(u8, 0), bytes[75]);
    try std.testing.expectEqualSlices(u8, &n64, bytes[10..74]);
    try std.testing.expectEqual(@as(u8, '-'), bytes[74]);
    package.architecture = .aarch64;
    try std.testing.expectEqual(@as(u16, 19), std.mem.readInt(u16, lead(&package)[8..10], .big));
}

test "two builds are byte-identical" {
    // Goal: reproducibility; no clock, no hash-map order, no allocator address in the output.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const first = try write(arena.allocator(), &@import("deb.zig").sample, .{});
    const second = try write(arena.allocator(), &@import("deb.zig").sample, .{});
    try std.testing.expectEqualSlices(u8, first, second);
}

test "a header signature leaves the main header and its digest unchanged" {
    // Goal: signing is a second round that only grows the signature header, so the digests that
    // rpm and the repository metadata record do not move.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const plain = split(try write(memory, &@import("deb.zig").sample, .{})).?;
    const fake_signature: [70]u8 = @splat(0xaa);
    const signed_bytes = try write(memory, &@import("deb.zig").sample, .{
        .header_signature = &fake_signature,
    });
    const signed = split(signed_bytes).?;
    try std.testing.expectEqualSlices(u8, plain.main_header, signed.main_header);
    try std.testing.expectEqualSlices(u8, plain.payload, signed.payload);
    try std.testing.expect(signed.signature_header.len > plain.signature_header.len);
    try std.testing.expectEqualStrings(
        &model.digest_hex(plain.main_header),
        &model.digest_hex(signed.main_header),
    );
}

/// The size of the uncompressed payload (the cpio archive), which dnf's metadata records.
pub fn archive_bytes(memory: Allocator, package: *const model.Package) Error!u64 {
    const files = try file_arrays(memory, package);
    return (try archive.cpio_write(memory, files.cpio)).len;
}
