//! What a package is, as its caller describes it, and the directory entries that follow from its
//! files. Nothing here knows about `zbx`: a package is a name, a version, files and text.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

/// The two architectures zbx ships for. Each has a Debian name and an rpm name.
pub const Architecture = enum {
    x86_64,
    aarch64,

    pub fn deb_name(architecture: Architecture) []const u8 {
        return switch (architecture) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
        };
    }

    pub fn rpm_name(architecture: Architecture) []const u8 {
        return switch (architecture) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
        };
    }

    /// rpm's capability for the architecture's ABI (`zigbox(x86-64)`).
    pub fn rpm_abi(architecture: Architecture) []const u8 {
        return switch (architecture) {
            .x86_64 => "x86-64",
            .aarch64 => "aarch-64",
        };
    }
};

/// One regular file. `path` is absolute (`/usr/bin/zbx`), `mode` the permission bits (0o755).
pub const File = struct {
    path: []const u8,
    mode: u32,
    bytes: []const u8,
    /// A configuration file the administrator edits: deb lists it in `conffiles`, rpm marks it
    /// `%config(noreplace)`. An upgrade keeps an edited copy.
    config: bool = false,
};

/// How a relation compares versions. `any` names the package with no version.
pub const Sense = enum { any, ge, eq };

/// One entry of `Depends`, `Conflicts`, `Replaces` (rpm: `Obsoletes`) or `Provides`.
pub const Relation = struct {
    name: []const u8,
    sense: Sense = .any,
    /// For rpm the full `version-release`; for deb the version.
    version: []const u8 = "",
};

/// A package, described by its caller. Strings are borrowed for the call.
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    /// The distribution revision (`1`); rpm's Release, and the deb version's suffix is not used.
    revision: []const u8 = "1",
    architecture: Architecture,
    summary: []const u8,
    description: []const u8,
    license: []const u8,
    homepage: []const u8,
    maintainer: []const u8,
    recommends_deb: []const []const u8 = &.{},
    recommends_rpm: []const []const u8 = &.{},
    /// `Depends` for each format; names and versions differ (`libpq5`, `libpq`).
    depends_deb: []const Relation = &.{},
    depends_rpm: []const Relation = &.{},
    /// Packages this one cannot be installed beside, and the ones it replaces (rpm: Obsoletes).
    conflicts: []const Relation = &.{},
    replaces: []const Relation = &.{},
    /// Virtual names this package stands for besides its own.
    provides: []const Relation = &.{},
    /// A package with no files is a metapackage: only its dependencies.
    files: []const File = &.{},
};

pub const Error = error{
    /// A name, version or revision has a byte outside `[A-Za-z0-9.+~_-]`, or is empty or long.
    BadName,
    /// Text has a control byte (other than newline in a description) or is empty or long.
    BadText,
    /// A path is not absolute, has `.`, `..` or empty parts, or does not fit a tar name.
    BadPath,
    /// A mode has bits outside 0o7777 or a file is not a regular file mode.
    BadMode,
    /// Two files share a path, or a file's path is also another file's directory.
    DuplicatePath,
    TooManyFiles,
    FileTooLarge,
    PayloadTooLarge,
    TooManyRecommends,
    /// A relation has a bad name or version, a version where `any` needs none, or too many.
    BadRelation,
    OutOfMemory,
    /// The writer ran out of room or hit a bound the caller's data should not reach.
    WriteFailed,
};

/// One line saying what a package problem is, for the build tool to print after `package: `.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.BadName => "a name, version or revision has an unusable byte or length " ++
            "(a version has no - or _)",
        error.BadText => "a summary, description, licence, homepage or maintainer is empty, " ++
            "too long or has a control byte",
        error.BadPath => "a file path is not an absolute path of plain parts that fits a tar name",
        error.BadMode => "a file mode has bits outside 0o7777",
        error.DuplicatePath => "two entries share a path",
        error.TooManyFiles => "the package has more files than the bound allows",
        error.FileTooLarge => "a file is larger than the bound allows",
        error.PayloadTooLarge => "the files together are larger than the bound allows",
        error.TooManyRecommends => "the package names more weak dependencies than the bound allows",
        error.BadRelation => "a dependency, conflict, replace or provide names a bad package or " ++
            "version, or the package lists more than the bound allows",
        error.OutOfMemory => "out of memory",
        error.WriteFailed => "an output buffer could not grow",
    };
}

fn name_byte_ok(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '.', '+', '~', '_', '-' => true,
        else => false,
    };
}

fn check_name(name: []const u8) Error!void {
    if (name.len == 0) return error.BadName;
    if (name.len > constants.package_name_bytes_max) return error.BadName;
    for (name) |byte| {
        if (!name_byte_ok(byte)) return error.BadName;
    }
}

/// A version or revision: a name without `-` (rpm splits NEVRA there, and dpkg starts the
/// revision) or `_`, which dpkg refuses.
fn check_version(version: []const u8) Error!void {
    try check_name(version);
    for (version) |byte| {
        if (byte == '-' or byte == '_') return error.BadName;
    }
}

fn check_text(text: []const u8, newlines: bool, bytes_max: u32) Error!void {
    if (text.len == 0) return error.BadText;
    if (text.len > bytes_max) return error.BadText;
    for (text) |byte| {
        if (byte == '\n' and newlines) continue;
        if (byte < 0x20 or byte == 0x7f) return error.BadText;
    }
}

/// A path is absolute, made of non-empty parts that are not `.` or `..`, and has no byte a
/// control file, a tar name or an rpm list could misread.
pub fn check_path(path: []const u8) Error!void {
    if (path.len < 2) return error.BadPath;
    if (path.len > constants.package_path_bytes_max - 2) return error.BadPath; // "./" in tar.
    if (path[0] != '/') return error.BadPath;
    if (path[path.len - 1] == '/') return error.BadPath;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.BadPath;
        if (std.mem.eql(u8, part, ".")) return error.BadPath;
        if (std.mem.eql(u8, part, "..")) return error.BadPath;
    }
    for (path) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return error.BadPath;
    }
}

fn check_relations(relations: []const Relation) Error!void {
    if (relations.len > constants.package_relations_max) return error.BadRelation;
    for (relations) |relation| {
        check_name(relation.name) catch return error.BadRelation;
        switch (relation.sense) {
            .any => if (relation.version.len != 0) return error.BadRelation,
            .ge, .eq => {
                // A version may hold `-` here (an rpm's `version-release`) and `:` (an epoch).
                check_name(relation.version) catch return error.BadRelation;
            },
        }
    }
}

/// Refuses a package the writers could not describe faithfully. Pure: no allocation.
pub fn validate(package: *const Package) Error!void {
    try check_name(package.name);
    try check_version(package.version);
    if (!std.ascii.isDigit(package.version[0])) return error.BadName; // dpkg wants a digit first.
    try check_version(package.revision);
    try check_text(package.summary, false, constants.package_summary_bytes_max);
    try check_text(package.description, true, constants.package_description_bytes_max);
    try check_text(package.license, false, constants.package_name_bytes_max);
    try check_text(package.homepage, false, constants.package_summary_bytes_max);
    try check_text(package.maintainer, false, constants.package_summary_bytes_max);
    if (package.recommends_deb.len > constants.package_recommends_max) {
        return error.TooManyRecommends;
    }
    if (package.recommends_rpm.len > constants.package_recommends_max) {
        return error.TooManyRecommends;
    }
    for (package.recommends_deb) |name| try check_name(name);
    for (package.recommends_rpm) |name| try check_name(name);
    try check_relations(package.depends_deb);
    try check_relations(package.depends_rpm);
    try check_relations(package.conflicts);
    try check_relations(package.replaces);
    try check_relations(package.provides);
    if (package.files.len > constants.package_files_max / 2) return error.TooManyFiles;
    var payload_bytes: u64 = 0;
    for (package.files) |file| {
        try check_path(file.path);
        if (file.mode > 0o7777) return error.BadMode;
        if (file.bytes.len > constants.package_file_bytes_max) return error.FileTooLarge;
        payload_bytes += file.bytes.len;
    }
    if (payload_bytes > constants.package_payload_bytes_max) return error.PayloadTooLarge;
}

/// An entry of the installed tree in the order packages list them: bytewise by path, a
/// directory before what it holds.
pub const Entry = struct {
    path: []const u8,
    /// Null for a directory.
    file: ?*const File,
};

fn entry_less(_: void, left: Entry, right: Entry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

/// Every file plus every directory above one, sorted by path, as `Entry` values in `memory`.
/// With `owned_only`, directories the base system owns (`/usr`, `/usr/bin`, ...) are left out,
/// as rpm lists only what a package owns. Asserts the package was validated.
pub fn layout(
    memory: std.mem.Allocator,
    package: *const Package,
    owned_only: bool,
) Error![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    for (package.files) |*file| {
        try entries.append(memory, .{ .path = file.path, .file = file });
        var end: usize = file.path.len;
        while (std.mem.lastIndexOfScalar(u8, file.path[0..end], '/')) |slash| {
            end = slash;
            if (slash == 0) break;
            const dir = file.path[0..slash];
            if (owned_only and is_system_directory(dir)) continue;
            if (find_path(entries.items, dir)) |existing| {
                // A file whose path is also another file's directory cannot be installed.
                if (existing.file != null) return error.DuplicatePath;
                continue;
            }
            try entries.append(memory, .{ .path = dir, .file = null });
        }
    }
    if (entries.items.len > constants.package_files_max) return error.TooManyFiles;
    std.mem.sort(Entry, entries.items, {}, entry_less);
    if (entries.items.len < 2) return entries.items;
    for (entries.items[1..], 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, entries.items[index].path)) return error.DuplicatePath;
    }
    return entries.items;
}

fn find_path(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

/// The directories every distribution's base packages own; a package never lists them.
const system_directories = [_][]const u8{
    "/usr",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/share",
    "/usr/share/doc",
    "/usr/share/man",
    "/usr/share/man/man1",
    "/usr/share/licenses",
    "/etc",
    "/usr/lib/systemd",
    "/usr/lib/systemd/system",
};

pub fn is_system_directory(path: []const u8) bool {
    for (system_directories) |dir| {
        if (std.mem.eql(u8, dir, path)) return true;
    }
    return false;
}

/// The mode a directory entry carries.
pub const directory_mode: u32 = 0o755;

/// Total bytes of file content (what `Installed-Size` and rpm's SIZE count).
pub fn content_bytes(package: *const Package) u64 {
    var total: u64 = 0;
    for (package.files) |file| total += file.bytes.len;
    return total;
}

pub fn digest_hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "validate refuses what the writers cannot describe" {
    // Goal: each field's boundary is refused with its own error, and a good package passes.
    const good: Package = .{
        .name = "zigbox",
        .version = "0.4.0",
        .architecture = .x86_64,
        .summary = "s",
        .description = "d\nmore",
        .license = "MIT",
        .homepage = "https://zigbox.org",
        .maintainer = "Zigbox <x@zigbox.org>",
        .files = &.{.{ .path = "/usr/bin/zbx", .mode = 0o755, .bytes = "x" }},
    };
    try validate(&good);
    var bad = good;
    bad.name = "Zig box";
    try std.testing.expectError(error.BadName, validate(&bad));
    for ([_][]const u8{ "0.4.0-rc.1", "0.4_0", "v0.4.0" }) |version| {
        bad = good;
        bad.version = version; // `-`, `_` and a leading letter break rpm or dpkg.
        try std.testing.expectError(error.BadName, validate(&bad));
    }
    bad = good;
    bad.revision = "1-2";
    try std.testing.expectError(error.BadName, validate(&bad));
    bad = good;
    bad.version = "0.4.0~rc.1";
    try validate(&bad);
    bad = good;
    bad.summary = "a\nb";
    try std.testing.expectError(error.BadText, validate(&bad));
    bad = good;
    bad.files = &.{.{ .path = "usr/bin/zbx", .mode = 0o755, .bytes = "x" }};
    try std.testing.expectError(error.BadPath, validate(&bad));
    bad.files = &.{.{ .path = "/usr/../bin/zbx", .mode = 0o755, .bytes = "x" }};
    try std.testing.expectError(error.BadPath, validate(&bad));
    bad.files = &.{.{ .path = "/usr/bin/zbx", .mode = 0o17777, .bytes = "x" }};
    try std.testing.expectError(error.BadMode, validate(&bad));
    var long: [constants.package_path_bytes_max]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '/';
    try std.testing.expectError(error.BadPath, check_path(&long));
    try check_path(long[0 .. constants.package_path_bytes_max - 2]);
}

test "layout lists directories first and refuses duplicates" {
    // Goal: sorted order, owned-only drops system directories, and a repeated path is refused.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]File{
        .{ .path = "/usr/share/licenses/zigbox/LICENSE", .mode = 0o644, .bytes = "l" },
        .{ .path = "/usr/bin/zbx", .mode = 0o755, .bytes = "b" },
    };
    const package: Package = .{
        .name = "zigbox",
        .version = "1",
        .architecture = .aarch64,
        .summary = "s",
        .description = "d",
        .license = "l",
        .homepage = "h",
        .maintainer = "m",
        .files = &files,
    };
    const all = try layout(arena.allocator(), &package, false);
    try std.testing.expectEqual(@as(usize, 7), all.len);
    try std.testing.expectEqualStrings("/usr", all[0].path);
    try std.testing.expect(all[0].file == null);
    const owned = try layout(arena.allocator(), &package, true);
    try std.testing.expectEqual(@as(usize, 3), owned.len);
    try std.testing.expectEqualStrings("/usr/bin/zbx", owned[0].path);
    try std.testing.expectEqualStrings("/usr/share/licenses/zigbox", owned[1].path);
    const twice = [_]File{ files[1], files[1] };
    var dup = package;
    dup.files = &twice;
    try std.testing.expectError(error.DuplicatePath, layout(arena.allocator(), &dup, false));
}

/// A file of a repository tree, by its path under the tree's root.
pub const TreeFile = struct {
    path: []const u8,
    bytes: []const u8,
};

/// A package and the bytes of its built file, as a repository writer takes them.
pub const Built = struct {
    package: *const Package,
    bytes: []const u8,
};

/// Calendar fields for a UTC time, so metadata dates need no clock.
pub const Calendar = struct {
    weekday: u3,
    day: u5,
    month: u4,
    year: u16,
    seconds_of_day: u17,

    pub fn from_epoch(seconds: u64) Calendar {
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
        const epoch_day = epoch_seconds.getEpochDay();
        const month_day = epoch_day.calculateYearDay().calculateMonthDay();
        return .{
            // 1970-01-01 was a Thursday; index 0 is Sunday.
            .weekday = @intCast((epoch_day.day + 4) % 7),
            .day = month_day.day_index + 1,
            .month = month_day.month.numeric(),
            .year = epoch_day.calculateYearDay().year,
            .seconds_of_day = epoch_seconds.getDaySeconds().secs,
        };
    }
};

pub const weekday_names = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
pub const month_names = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

test "calendar fields of the build epoch are 1980-01-01, a Tuesday" {
    // Goal: the Release date line is right without a clock.
    const calendar = Calendar.from_epoch(constants.package_source_date_epoch);
    try std.testing.expectEqual(@as(u16, 1980), calendar.year);
    try std.testing.expectEqual(@as(u4, 1), calendar.month);
    try std.testing.expectEqual(@as(u5, 1), calendar.day);
    try std.testing.expectEqualStrings("Tue", weekday_names[calendar.weekday]);
    const later = Calendar.from_epoch(1_794_149_934); // A Thursday, 2026-11-08 is a Sunday.
    try std.testing.expect(later.year >= 2026);
}
