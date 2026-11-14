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

/// RFC 5322 text of a UTC time, as apt reads `Date` and `Valid-Until`.
fn date_text(memory: Allocator, epoch: u64) Error![]u8 {
    const text = date_text_buffered(epoch) orelse return error.WriteFailed;
    return memory.dupe(u8, text.slice()) catch return error.OutOfMemory;
}

const architectures = [_]model.Architecture{ .x86_64, .aarch64 };

fn has_architecture(built: []const model.Built, architecture: model.Architecture) bool {
    for (built) |item| {
        if (item.package.architecture == architecture) return true;
    }
    return false;
}

/// The `Date` and `Valid-Until` lines of a `Release`. With no signing time (tests, the test key)
/// the date is the fixed build epoch and there is no `Valid-Until`, which apt accepts for ever.
fn date_lines(memory: Allocator, signed_at: ?u64) Error![]u8 {
    const at = signed_at orelse {
        const text = try date_text(memory, constants.package_source_date_epoch);
        return std.fmt.allocPrint(memory, "Date: {s}\n", .{text}) catch return error.OutOfMemory;
    };
    if (at < constants.apt_signed_at_min) return error.BadRelease;
    if (at > constants.apt_signed_at_max) return error.BadRelease;
    const until = at + constants.apt_valid_seconds;
    return std.fmt.allocPrint(memory, "Date: {s}\nValid-Until: {s}\n", .{
        try date_text(memory, at), try date_text(memory, until),
    }) catch return error.OutOfMemory;
}

/// `release` with its `Date` and `Valid-Until` lines replaced by those of `signed_at`; every
/// other byte is kept, so the `Packages` sums in it still hold. The refresh path
/// (docs/releases/packaging.md) uses it to re-date a published release without rebuilding.
pub fn redate(memory: Allocator, release: []const u8, signed_at: u64) Error![]u8 {
    const lines = try date_lines(memory, signed_at);
    var out = Output.init(memory);
    var found = false;
    var rest = release;
    while (rest.len > 0) {
        const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |at| at + 1 else rest.len;
        const line = rest[0..end];
        rest = rest[end..];
        const is_date = std.mem.startsWith(u8, line, "Date:");
        if (std.mem.startsWith(u8, line, "Valid-Until:")) continue;
        if (is_date and !found) {
            found = true;
            out.writer.writeAll(lines) catch return error.WriteFailed;
        } else if (!is_date) {
            out.writer.writeAll(line) catch return error.WriteFailed;
        }
    }
    if (!found) return error.BadRelease;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// The seconds since the epoch of a `Date` or `Valid-Until` value written by `date_text`
/// (`Tue, 01 Jan 1980 00:00:00 UTC`), or null for any other text: the check reads back only what
/// this writer can write.
pub fn parse_date(text: []const u8) ?u64 {
    if (text.len != 29) return null;
    if (!std.mem.endsWith(u8, text, " UTC")) return null;
    const day = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const year = std.fmt.parseInt(u16, text[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[23..25], 10) catch return null;
    if (text[3] != ',' or text[4] != ' ' or text[7] != ' ' or text[11] != ' ') return null;
    if (text[16] != ' ' or text[19] != ':' or text[22] != ':' or text[25] != ' ') return null;
    if (hour > 23 or minute > 59 or second > 59 or day < 1 or day > 31) return null;
    const month = for (model.month_names, 1..) |name, number| {
        if (std.mem.eql(u8, name, text[8..11])) break number;
    } else return null;
    if (year < 1970) return null;
    var days: u64 = 0;
    for (1970..year) |each| days += std.time.epoch.getDaysInYear(@intCast(each));
    for (1..month) |each| {
        days += std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(each)));
    }
    const clock = @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
    const seconds = (days + day - 1) * 86_400 + clock;
    // The weekday and day-of-month must agree: a round trip through `date_text` is the grammar.
    const again = date_text_buffered(seconds) orelse return null;
    if (!std.mem.eql(u8, again.slice(), text)) return null;
    return seconds;
}

const DateBuffer = struct {
    bytes: [32]u8,
    len: u8,

    fn slice(self: *const DateBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn date_text_buffered(epoch: u64) ?DateBuffer {
    const calendar = model.Calendar.from_epoch(epoch);
    var result: DateBuffer = .{ .bytes = undefined, .len = 0 };
    const format = "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC";
    const text = std.fmt.bufPrint(&result.bytes, format, .{
        model.weekday_names[calendar.weekday],
        calendar.day,
        model.month_names[calendar.month - 1],
        calendar.year,
        calendar.seconds_of_day / 3600,
        calendar.seconds_of_day % 3600 / 60,
        calendar.seconds_of_day % 60,
    }) catch return null;
    result.len = @intCast(text.len);
    return result;
}

/// The whole tree except the signatures: pool, Packages, Packages.gz and Release. `signed_at` is
/// the signing time in seconds; null keeps the fixed build date and writes no `Valid-Until`.
pub fn write(memory: Allocator, built: []const model.Built, signed_at: ?u64) Error![]model.TreeFile {
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
        "Origin: Zigbox\nLabel: Zigbox\nSuite: {s}\nCodename: {s}\n{s}" ++
            "Architectures: {s}\nComponents: {s}\nDescription: Zigcube packages\nSHA256:\n{s}",
        .{
            suite,                             suite,
            try date_lines(memory, signed_at), names.items,
            component,                         sums.written(),
        },
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
    const files = try write(memory, &built, null);
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

test "a signing time gives Date and Valid-Until 21 days later, and redate keeps the sums" {
    // Goal: the signed Release carries both lines; redate changes those lines and no other byte;
    // parse_date reads back what the writer wrote, and nothing else.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const bytes = try deb.write(memory, &deb.sample);
    const built = [_]model.Built{.{ .package = &deb.sample, .bytes = bytes }};
    const at: u64 = 1_794_148_734; // 2026-11-08 14:38:54 UTC, a Sunday.
    const files = try write(memory, &built, at);
    const release = files[files.len - 1].bytes;
    const expected = "Date: Sun, 08 Nov 2026 14:38:54 UTC\n" ++
        "Valid-Until: Sun, 29 Nov 2026 14:38:54 UTC\n";
    try std.testing.expect(std.mem.indexOf(u8, release, expected) != null);
    const plain = (try write(memory, &built, null))[files.len - 1].bytes;
    try std.testing.expect(std.mem.indexOf(u8, plain, "Valid-Until") == null);
    const later = at + 7 * 86_400;
    const again = try redate(memory, release, later);
    try std.testing.expectEqualStrings(again, try redate(memory, plain, later));
    const rebuilt = (try write(memory, &built, later))[files.len - 1].bytes;
    try std.testing.expectEqualStrings(rebuilt, again);
    try std.testing.expectEqual(@as(?u64, at), parse_date("Sun, 08 Nov 2026 14:38:54 UTC"));
    const epoch = parse_date("Tue, 01 Jan 1980 00:00:00 UTC");
    try std.testing.expectEqual(@as(?u64, 315_532_800), epoch);
    try std.testing.expect(parse_date("Mon, 08 Nov 2026 14:38:54 UTC") == null); // Wrong weekday.
    try std.testing.expect(parse_date("Sun, 08 Nov 2026 14:38:54 GMT") == null);
    try std.testing.expect(parse_date("Sat, 31 Feb 2026 14:38:54 UTC") == null);
}

test "a signing time outside the bounds, and a Release with no Date, are refused" {
    // Goal: both bounds are exact, one second inside and one outside; negative space of redate.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const release = "Origin: Zigbox\nDate: Tue, 01 Jan 1980 00:00:00 UTC\nSHA256:\n";
    _ = try redate(memory, release, constants.apt_signed_at_min);
    _ = try redate(memory, release, constants.apt_signed_at_max);
    const low = redate(memory, release, constants.apt_signed_at_min - 1);
    try std.testing.expectError(error.BadRelease, low);
    const high = redate(memory, release, constants.apt_signed_at_max + 1);
    try std.testing.expectError(error.BadRelease, high);
    const no_date = redate(memory, "Origin: Zigbox\nSHA256:\n", constants.apt_signed_at_min);
    try std.testing.expectError(error.BadRelease, no_date);
}
