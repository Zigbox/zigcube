//! `dist`: a build tool. It writes the tarballs `zig build dist` and `zig build release` make.
//!
//! - `jepsen` mode (`zig build dist`): the executables and the Jepsen deployment recipe
//!   (`ops/jepsen/`) for x86_64 Linux under one top directory, gzip-compressed, and its SHA-256 in
//!   the format `sha256sum -c` reads. The top directory and the file names carry the version and
//!   the commit (`git rev-parse HEAD` in the build root, `+dirty` when the tracked files differ
//!   from it).
//! - `release` mode (`zig build release`, docs/releases/automation.md): one tarball per
//!   `--platform=`, named `zigcube-<version>-<platform>.tar.gz` with no commit in the name, and one
//!   `SHA256SUMS` over them all. It refuses a dirty tree, and a build root with no `.git`: a
//!   release's `COMMIT` must name the commit it was built from.
//!
//! The tarball is a function of its inputs: entries are written in the order given, with mtime 0,
//! uid and gid 0, no user or group names, and a gzip header with no time or name in it, so the
//! same executables and files give the same bytes. The commit is also in the file `COMMIT`.
//!
//! The out directory is made if missing, and what an earlier run left there (any `zigcube-*` file
//! and `SHA256SUMS`) is deleted first, so it holds this build's files only.
//!
//! usage: dist jepsen <out-dir> <build-root> <version> <archive-path>=<source-path>...
//!        dist release <out-dir> <build-root> <version> (--platform=<p> <a>=<s>...)...

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The arguments after the version `build.zig` passes: four executables and the recipe's files
/// (jepsen), or two platforms of four entries each (release), with room to spare.
const entries_max: u32 = 64;
/// The platforms of one release run: `build.zig`'s `release_arches`, with room to spare.
const platforms_max: u32 = 4;
const jepsen_platform = "x86_64-linux";
const sums_name = "SHA256SUMS";
const commit_short_len = 12;
/// How many entries of the out directory the tool looks at before it refuses: a directory with
/// more is not one this tool made.
const out_entries_max: u32 = 64;

const Entry = struct { archive_path: []const u8, source_path: []const u8 };
const Mode = enum { jepsen, release };
/// One tarball: its platform, such as `x86_64-linux`, and its entries.
const Package = struct { platform: []const u8, entries: []const Entry };
const Plan = struct {
    out_path: []const u8,
    root: []const u8,
    version: []const u8,
    packages: []const Package,
};

const usage = "usage: dist jepsen|release <out-dir> <build-root> <version> " ++
    "[--platform=P] A=S...";

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_user;
    if (args.len < 6) return fail(init.io, usage);
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return fail(init.io, usage);
    if (args.len - 5 > entries_max) return fail(init.io, "dist: too many entries");
    var entries: [entries_max]Entry = undefined;
    var packages: [platforms_max]Package = undefined;
    const count = parse(mode, args[5..], &entries, &packages) catch |err| {
        const text = std.fmt.allocPrint(arena, "dist: {s}", .{parse_message(err)}) catch "dist";
        return fail(init.io, text);
    };
    const plan: Plan = .{
        .out_path = args[2],
        .root = args[3],
        .version = args[4],
        .packages = packages[0..count],
    };
    const result = switch (mode) {
        .jepsen => run_jepsen(init, plan),
        .release => run_release(init, plan),
    };
    result catch |err| {
        // A failure that names its path or command has been printed already.
        if (err == error.Reported) return constants.exit_user;
        const text = std.fmt.allocPrint(arena, "dist: {s}", .{@errorName(err)}) catch "dist";
        return fail(init.io, text);
    };
    return constants.exit_ok;
}

/// Why `parse` refused the arguments; `parse_message` says it in words.
const ParseError = error{
    JepsenPlatform,
    PlatformMissing,
    PlatformEmpty,
    PlatformBad,
    PlatformTwice,
    PlatformsTooMany,
    EntryBad,
};

fn parse_message(err: ParseError) []const u8 {
    return switch (err) {
        error.JepsenPlatform => "jepsen mode takes no --platform",
        error.PlatformMissing => "release mode needs --platform= first",
        error.PlatformEmpty => "a platform is empty",
        error.PlatformBad => "a platform is not lowercase letters, digits, '_' and '-'",
        error.PlatformTwice => "a platform is named twice",
        error.PlatformsTooMany => "too many platforms",
        error.EntryBad => "an entry is not <archive-path>=<source-path>",
    };
}

/// Splits the arguments into packages: in `jepsen` mode one, for x86_64 Linux, with no
/// `--platform=`; in `release` mode one per `--platform=`, which must come first, each with at
/// least one entry and none named twice (two tarballs of one name would overwrite each other,
/// and SHA256SUMS would list it twice). Returns how many packages it filled. Pure: the caller
/// reports the error.
fn parse(
    mode: Mode,
    args: []const []const u8,
    entries: *[entries_max]Entry,
    packages: *[platforms_max]Package,
) ParseError!u32 {
    assert(args.len > 0);
    assert(args.len <= entries_max);
    const marker = "--platform=";
    var count: u32 = 0;
    var entry_count: u32 = 0;
    var first: u32 = 0;
    if (mode == .jepsen) packages[0] = .{ .platform = jepsen_platform, .entries = &.{} };
    if (mode == .jepsen) count = 1;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, marker)) {
            if (mode == .jepsen) return error.JepsenPlatform;
            if (count > 0) packages[count - 1].entries = entries[first..entry_count];
            if (count > 0 and first == entry_count) return error.PlatformEmpty;
            if (count == platforms_max) return error.PlatformsTooMany;
            const platform = arg[marker.len..];
            if (!platform_valid(platform)) return error.PlatformBad;
            for (packages[0..count]) |package| {
                if (std.mem.eql(u8, package.platform, platform)) return error.PlatformTwice;
            }
            packages[count] = .{ .platform = platform, .entries = &.{} };
            count += 1;
            first = entry_count;
            continue;
        }
        if (count == 0) return error.PlatformMissing;
        const split = std.mem.indexOfScalar(u8, arg, '=') orelse return error.EntryBad;
        entries[entry_count] = .{ .archive_path = arg[0..split], .source_path = arg[split + 1 ..] };
        entry_count += 1;
    }
    if (first == entry_count) return error.PlatformEmpty;
    packages[count - 1].entries = entries[first..entry_count];
    assert(count <= platforms_max);
    return count;
}

/// A platform is a file-name part: lowercase letters, digits, `_` and `-`, not empty.
fn platform_valid(platform: []const u8) bool {
    if (platform.len == 0) return false;
    for (platform) |c| {
        const ok = std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn fail(io: std.Io, text: []const u8) u8 {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    return constants.exit_user;
}

/// Prints `dist: ` and the formatted text, and returns `error.Reported`.
fn report(init: std.process.Init, comptime format: []const u8, args: anytype) error{Reported} {
    const text = std.fmt.allocPrint(init.arena.allocator(), "dist: " ++ format, args) catch
        "dist: out of memory while reporting a failure";
    _ = fail(init.io, text);
    return error.Reported;
}

/// The commit of the build root, `+dirty` appended when tracked files differ from it, or
/// `unknown` when the build root has no `.git` (a source tarball). Inside a checkout, a git that
/// fails (not installed, or refusing a checkout another user owns) fails the build with its
/// reason: a tarball named `unknown` would hide which commit, and whether a dirty tree, it holds.
fn commit_of(init: std.process.Init, root: []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    const dot_git = try std.fs.path.join(arena, &.{ root, ".git" });
    std.Io.Dir.cwd().access(init.io, dot_git, .{}) catch |err| switch (err) {
        error.FileNotFound => return "unknown",
        else => return report(init, "can't read {s}: {t}", .{ dot_git, err }),
    };
    const head = try git(init, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    if (head.len < commit_short_len) return report(init, "git rev-parse HEAD said '{s}'", .{head});
    const porcelain = &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" };
    const status = try git(init, porcelain);
    const dirty: []const u8 = if (status.len > 0) "+dirty" else "";
    return std.fmt.allocPrint(arena, "{s}{s}", .{ head, dirty });
}

/// git's standard output, trimmed. A git that cannot run or exits other than 0 is reported with
/// its command and what it wrote on standard error.
fn git(init: std.process.Init, argv: []const []const u8) ![]const u8 {
    assert(argv.len >= 4);
    const command = argv[3];
    const result = std.process.run(init.arena.allocator(), init.io, .{ .argv = argv }) catch |err|
        return report(init, "git {s} did not run: {t}", .{ command, err });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const said = std.mem.trim(u8, result.stderr, " \n");
        return report(init, "git {s} in {s} failed: {s}", .{ command, argv[2], said });
    }
    return std.mem.trim(u8, result.stdout, " \n");
}

fn run_jepsen(init: std.process.Init, plan: Plan) !void {
    assert(plan.packages.len == 1);
    const arena = init.arena.allocator();
    const io = init.io;
    const commit = try commit_of(init, plan.root);
    const short = commit[0..@min(commit.len, commit_short_len)];
    const dirty: []const u8 = if (std.mem.endsWith(u8, commit, "+dirty")) "-dirty" else "";
    const top = try std.fmt.allocPrint(arena, "zigcube-{s}-{s}{s}-{s}", .{
        plan.version, short, dirty, plan.packages[0].platform,
    });
    const tarball = try std.fmt.allocPrint(arena, "{s}.tar.gz", .{top});
    var out = try open_out(io, plan.out_path);
    defer out.close(io);
    const digest = try write_tarball(init, out, tarball, top, commit, plan.packages[0].entries);
    const line = try sum_line(arena, digest, tarball);
    const sum_name = try std.fmt.allocPrint(arena, "{s}.sha256", .{tarball});
    try out.writeFile(io, .{ .sub_path = sum_name, .data = line });
}

fn run_release(init: std.process.Init, plan: Plan) !void {
    assert(plan.packages.len > 0);
    assert(plan.packages.len <= platforms_max);
    const arena = init.arena.allocator();
    const io = init.io;
    const commit = try commit_of(init, plan.root);
    if (std.mem.eql(u8, commit, "unknown")) {
        return report(init, "a release is built from a git checkout; {s} has no .git", .{
            plan.root,
        });
    }
    if (std.mem.endsWith(u8, commit, "+dirty")) {
        return report(init, "a release is never built from a dirty tree ({s})", .{commit});
    }
    var out = try open_out(io, plan.out_path);
    defer out.close(io);
    var sums: std.ArrayList(u8) = .empty;
    for (plan.packages) |package| {
        const top = try std.fmt.allocPrint(arena, "zigcube-{s}-{s}", .{
            plan.version, package.platform,
        });
        const tarball = try std.fmt.allocPrint(arena, "{s}.tar.gz", .{top});
        const digest = try write_tarball(init, out, tarball, top, commit, package.entries);
        try sums.appendSlice(arena, try sum_line(arena, digest, tarball));
    }
    try out.writeFile(io, .{ .sub_path = sums_name, .data = sums.items });
}

/// Opens the out directory, made if missing, with what an earlier run left there deleted.
fn open_out(io: std.Io, out_path: []const u8) !std.Io.Dir {
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{ .open_options = .{
        .iterate = true,
    } });
    errdefer out.close(io);
    try remove_earlier(io, out);
    return out;
}

/// `sha256sum -c` reads "<hex>  <name>": two spaces, text mode.
fn sum_line(
    arena: std.mem.Allocator,
    digest: [Sha256.digest_length]u8,
    name: []const u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(arena, "{s}  {s}\n", .{ &hex, name });
}

/// Deletes the files an earlier run wrote (`zigcube-*` and `SHA256SUMS`); anything else is left
/// alone.
fn remove_earlier(io: std.Io, out: std.Io.Dir) !void {
    var names: [out_entries_max][std.Io.Dir.max_name_bytes]u8 = undefined;
    var lengths: [out_entries_max]usize = undefined;
    var count: u32 = 0;
    var iterator = out.iterate();
    while (try iterator.next(io)) |entry| {
        if (count == out_entries_max) return error.OutDirectoryFull;
        if (entry.kind != .file) continue;
        const ours = std.mem.startsWith(u8, entry.name, "zigcube-") or
            std.mem.eql(u8, entry.name, sums_name);
        if (!ours) continue;
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
    var hashed: std.Io.Writer.Hashed(Sha256) =
        .initHasher(&file_writer.interface, .init(.{}), hashed_buffer);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    const compress = try arena.create(std.compress.flate.Compress);
    compress.* = try .init(&hashed.writer, window, .gzip, .default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compress.writer };
    // `setRoot`, with the directory's mode given: its default is 0775.
    try tar.writeDir(top, .{ .mode = 0o755, .mtime = 0 });
    tar.prefix = top;
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
    const file = std.Io.Dir.cwd().openFile(io, entry.source_path, .{}) catch |err|
        return report(init, "can't open {s} (for {s}): {t}", .{
            entry.source_path, entry.archive_path, err,
        });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const size = reader.getSize() catch |err|
        return report(init, "can't read the size of {s}: {t}", .{ entry.source_path, err });
    try tar.writeFileStream(entry.archive_path, size, &reader.interface, .{
        .mode = mode,
        .mtime = 0,
    });
}

const testing = std.testing;

/// `parse` over `args`, split at spaces; the packages' platforms and entry counts on success.
fn parse_text(mode: Mode, text: []const u8) ParseError!struct { count: u32, sizes: [4]usize } {
    var args_buffer: [entries_max][]const u8 = undefined;
    var args_count: u32 = 0;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| : (args_count += 1) args_buffer[args_count] = word;
    var entries: [entries_max]Entry = undefined;
    var packages: [platforms_max]Package = undefined;
    const count = try parse(mode, args_buffer[0..args_count], &entries, &packages);
    var sizes: [4]usize = .{ 0, 0, 0, 0 };
    for (packages[0..count], 0..) |package, index| sizes[index] = package.entries.len;
    return .{ .count = count, .sizes = sizes };
}

test "dist parse: valid release and jepsen arguments" {
    const two = try parse_text(.release, "--platform=x86_64-linux a=b c=d " ++
        "--platform=aarch64-linux e=f");
    try testing.expectEqual(@as(u32, 2), two.count);
    try testing.expectEqual([4]usize{ 2, 1, 0, 0 }, two.sizes);
    const four = try parse_text(.release, "--platform=a x=y --platform=b x=y " ++
        "--platform=c x=y --platform=d x=y");
    try testing.expectEqual(@as(u32, platforms_max), four.count);
    const jepsen = try parse_text(.jepsen, "bin/zcube=/x share/a=/y");
    try testing.expectEqual(@as(u32, 1), jepsen.count);
    try testing.expectEqual([4]usize{ 2, 0, 0, 0 }, jepsen.sizes);
    // The source path may hold `=`: only the first one splits.
    _ = try parse_text(.release, "--platform=x a=b=c");
}

test "dist parse: refusals" {
    const cases = [_]struct { mode: Mode, text: []const u8, err: ParseError }{
        .{ .mode = .release, .text = "--platform=x --platform=y a=b", .err = error.PlatformEmpty },
        .{ .mode = .release, .text = "--platform=x a=b --platform=y", .err = error.PlatformEmpty },
        .{ .mode = .release, .text = "--platform=x", .err = error.PlatformEmpty },
        .{ .mode = .release, .text = "a=b --platform=x c=d", .err = error.PlatformMissing },
        .{ .mode = .jepsen, .text = "a=b --platform=x c=d", .err = error.JepsenPlatform },
        .{ .mode = .release, .text = "--platform=X a=b", .err = error.PlatformBad },
        .{ .mode = .release, .text = "--platform=x/y a=b", .err = error.PlatformBad },
        .{ .mode = .release, .text = "--platform= a=b", .err = error.PlatformBad },
        .{ .mode = .release, .text = "--platform=x ab", .err = error.EntryBad },
        .{ .mode = .jepsen, .text = "ab", .err = error.EntryBad },
        .{
            .mode = .release,
            .text = "--platform=x a=b --platform=x c=d",
            .err = error.PlatformTwice,
        },
        .{
            .mode = .release,
            .text = "--platform=a x=y --platform=b x=y --platform=c x=y --platform=d x=y " ++
                "--platform=e x=y",
            .err = error.PlatformsTooMany,
        },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parse_text(case.mode, case.text));
        try testing.expect(parse_message(case.err).len > 0);
    }
}

test "dist platform_valid: the boundary" {
    try testing.expect(platform_valid("x86_64-linux"));
    try testing.expect(platform_valid("a"));
    try testing.expect(platform_valid("0-_"));
    try testing.expect(!platform_valid(""));
    try testing.expect(!platform_valid("Linux"));
    try testing.expect(!platform_valid("a.b"));
    try testing.expect(!platform_valid("a/b"));
    try testing.expect(!platform_valid("a b"));
    try testing.expect(!platform_valid("a=b"));
}
