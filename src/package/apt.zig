//! The apt repository writer: `pool/main/<initial>/<name>/<name>_<version>_<arch>.deb`, a
//! `Packages` and `Packages.gz` per architecture and the `Release` file that lists their SHA-256
//! sums. The signed forms, `InRelease` and `Release.gpg`, are not made here: the owner's gpg (or
//! the test key, in tests) signs `Release`, and the caller places the results beside it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const model = @import("model.zig");
const archive = @import("archive.zig");
const deb = @import("deb.zig");

const Allocator = std.mem.Allocator;
const Output = std.Io.Writer.Allocating;
pub const Error = model.Error;

pub const suite = "zigcube";
pub const component = "main";

fn built_less(_: void, left: model.Built, right: model.Built) bool {
    const by_name = std.mem.order(u8, left.package.name, right.package.name);
    if (by_name != .eq) return by_name == .lt;
    return std.mem.order(u8, left.package.version, right.package.version) == .lt;
}

/// The pool path of a package's deb, relative to the repository root.
pub fn pool_path(memory: Allocator, package: *const model.Package) Error![]u8 {
    const file = try deb.file_name(memory, package);
    return std.fmt.allocPrint(memory, "pool/{s}/{c}/{s}/{s}", .{
        component, package.name[0], package.name, file,
    }) catch return error.OutOfMemory;
}

fn stanza(memory: Allocator, built: model.Built) Error![]u8 {
    const control = try deb.control_text(memory, built.package);
    var md5: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(built.bytes, &md5, .{});
    return std.fmt.allocPrint(
        memory,
        "{s}Filename: {s}\nSize: {d}\nMD5sum: {x}\nSHA256: {s}\n",
        .{
            control,
            try pool_path(memory, built.package),
            built.bytes.len,
            &md5,
            &model.digest_hex(built.bytes),
        },
    ) catch return error.OutOfMemory;
}

/// `Packages` for one architecture: stanzas in name and version order, blank-line separated.
fn packages_text(
    memory: Allocator,
    sorted: []const model.Built,
    architecture: model.Architecture,
) Error![]u8 {
    var out = Output.init(memory);
    var first = true;
    for (sorted) |built| {
        if (built.package.architecture != architecture) continue;
        if (!first) out.writer.writeByte('\n') catch return error.WriteFailed;
        first = false;
        out.writer.writeAll(try stanza(memory, built)) catch return error.WriteFailed;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn date_text(memory: Allocator) Error![]u8 {
    const calendar = model.Calendar.from_epoch(constants.package_source_date_epoch);
    return std.fmt.allocPrint(memory, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        model.weekday_names[calendar.weekday],
        calendar.day,
        model.month_names[calendar.month - 1],
        calendar.year,
        calendar.seconds_of_day / 3600,
        calendar.seconds_of_day % 3600 / 60,
        calendar.seconds_of_day % 60,
    }) catch return error.OutOfMemory;
}

const architectures = [_]model.Architecture{ .x86_64, .aarch64 };

fn has_architecture(built: []const model.Built, architecture: model.Architecture) bool {
    for (built) |item| {
        if (item.package.architecture == architecture) return true;
    }
    return false;
}

/// The whole tree except the signatures: pool, Packages, Packages.gz and Release.
pub fn write(memory: Allocator, built: []const model.Built) Error![]model.TreeFile {
    if (built.len == 0 or built.len > constants.repo_packages_max) return error.TooManyFiles;
    const sorted = try memory.dupe(model.Built, built);
    std.mem.sort(model.Built, sorted, {}, built_less);
    var files: std.ArrayList(model.TreeFile) = .empty;
    var release = Output.init(memory);
    var sums = Output.init(memory);
    var names: std.ArrayList(u8) = .empty;
    for (sorted) |item| {
        try files.append(
            memory,
            .{ .path = try pool_path(memory, item.package), .bytes = item.bytes },
        );
    }
    for (architectures) |architecture| {
        if (!has_architecture(sorted, architecture)) continue;
        const arch_name = architecture.deb_name();
        if (names.items.len > 0) try names.append(memory, ' ');
        try names.appendSlice(memory, arch_name);
        const text = try packages_text(memory, sorted, architecture);
        const gzipped = try archive.gzip(memory, text);
        const base = try std.fmt.allocPrint(memory, "dists/{s}/{s}/binary-{s}/Packages", .{
            suite, component, arch_name,
        });
        try files.append(memory, .{ .path = base, .bytes = text });
        try files.append(
            memory,
            .{ .path = try std.fmt.allocPrint(memory, "{s}.gz", .{base}), .bytes = gzipped },
        );
        const relative = base[("dists/" ++ suite ++ "/").len..];
        for ([_][]const u8{ text, gzipped }, [_][]const u8{ "", ".gz" }) |bytes, suffix| {
            sums.writer.print(" {s} {d:>16} {s}{s}\n", .{
                &model.digest_hex(bytes), bytes.len, relative, suffix,
            }) catch return error.WriteFailed;
        }
    }
    release.writer.print(
        "Origin: Zigbox\nLabel: Zigbox\nSuite: {s}\nCodename: {s}\nDate: {s}\n" ++
            "Architectures: {s}\nComponents: {s}\nDescription: Zigcube packages\nSHA256:\n{s}",
        .{ suite, suite, try date_text(memory), names.items, component, sums.written() },
    ) catch return error.WriteFailed;
    const release_path = "dists/" ++ suite ++ "/Release";
    try files.append(memory, .{ .path = release_path, .bytes = try release.toOwnedSlice() });
    assert(files.items.len <= constants.repo_files_max);
    return files.items;
}

const filename_line = "Filename: pool/main/s/sample/sample_1.2.3_amd64.deb";

test "the tree has the pool, a Packages pair per architecture and a Release that sums them" {
    // Goal: the layout and every sum in Release equal the placed bytes.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try deb.write(memory, &deb.sample);
    const built = [_]model.Built{.{ .package = &deb.sample, .bytes = bytes }};
    const files = try write(memory, &built);
    try std.testing.expectEqual(@as(usize, 4), files.len);
    try std.testing.expectEqualStrings("pool/main/s/sample/sample_1.2.3_amd64.deb", files[0].path);
    const release = files[files.len - 1];
    try std.testing.expectEqualStrings("dists/zigcube/Release", release.path);
    for (files[1..3]) |file| {
        const relative = file.path["dists/zigcube/".len..];
        var line: [200]u8 = undefined;
        const expected = try std.fmt.bufPrint(&line, " {s} {d:>16} {s}\n", .{
            &model.digest_hex(file.bytes), file.bytes.len, relative,
        });
        try std.testing.expect(std.mem.indexOf(u8, release.bytes, expected) != null);
    }
    try std.testing.expect(
        std.mem.indexOf(u8, release.bytes, "Date: Tue, 01 Jan 1980 00:00:00 UTC\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, files[1].bytes, filename_line) != null,
    );
}
