//! Copied from Zigbox 74df642 (src/release_assets_main.zig), adapted for Zigcube's executables.
//!
//! `zig build release-assets`: write the release assets that are not signed packages, then
//! `SHA256SUMS` over every asset. Build-host tool; it never runs `gpg`: the release script signs
//! `SHA256SUMS`.
//!
//!   release_assets_main assets --version V --bin DIR [--arch x86_64|aarch64] --license PATH
//!       --license-id SPDX --zig-version Z [--source-date-epoch N] --out DIR
//!       (--packages DIR | --no-packages) [--extra PATH]...
//!
//! `--bin` holds `zcube-<arch>`, `zcube-agent-<arch>`, `zcube-server-sqlite-<arch>` and
//! `zcube-server-postgres-<arch>`, the files `package_main --bin` reads; without `--arch` both
//! architectures are needed. `assets` writes DIR's tarballs and SBOM, copies the debs and rpms
//! from the package tree and each `--extra` file (the repository archive) into it, then writes
//! `SHA256SUMS`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const assets = @import("release_assets.zig");
const release = @import("package_release.zig");

const extra_max = 8;

const Arguments = struct {
    version: []const u8 = "",
    bin: []const u8 = "",
    /// One architecture only; none means every one.
    arch: ?assets.Architecture = null,
    license: []const u8 = "",
    license_id: []const u8 = "",
    zig_version: []const u8 = "",
    source_date_epoch: u64 = constants.package_source_date_epoch,
    out: []const u8 = "",
    packages: ?[]const u8 = null,
    no_packages: bool = false,
    extra: [extra_max][]const u8 = undefined,
    extra_count: u32 = 0,
};

const usage_text =
    "usage: release_assets_main assets --version V --bin DIR [--arch x86_64|aarch64] " ++
    "--license PATH --license-id SPDX --zig-version Z [--source-date-epoch N] --out DIR " ++
    "(--packages DIR | --no-packages) [--extra PATH]...\n";

fn parse_arguments(iterator: anytype) ?Arguments {
    var arguments: Arguments = .{};
    const command = iterator.next() orelse return null;
    if (!std.mem.eql(u8, command, "assets")) return null;
    while (iterator.next()) |flag| {
        if (std.mem.eql(u8, flag, "--no-packages")) {
            arguments.no_packages = true;
        } else {
            const value = iterator.next() orelse return null;
            if (!set_value(&arguments, flag, value)) return null;
        }
    }
    if (arguments.out.len == 0 or arguments.bin.len == 0) return null;
    if (arguments.version.len == 0 or arguments.license.len == 0) return null;
    if (arguments.license_id.len == 0 or arguments.zig_version.len == 0) return null;
    if (arguments.no_packages == (arguments.packages != null)) return null;
    return arguments;
}

fn set_value(arguments: *Arguments, flag: []const u8, value: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, flag, "--version")) {
        arguments.version = value;
    } else if (eql(u8, flag, "--bin")) {
        arguments.bin = value;
    } else if (eql(u8, flag, "--arch")) {
        arguments.arch = std.meta.stringToEnum(assets.Architecture, value) orelse return false;
    } else if (eql(u8, flag, "--license")) {
        arguments.license = value;
    } else if (eql(u8, flag, "--license-id")) {
        arguments.license_id = value;
    } else if (eql(u8, flag, "--zig-version")) {
        arguments.zig_version = value;
    } else if (eql(u8, flag, "--source-date-epoch")) {
        arguments.source_date_epoch = std.fmt.parseInt(u64, value, 10) catch return false;
    } else if (eql(u8, flag, "--out")) {
        arguments.out = value;
    } else if (eql(u8, flag, "--packages")) {
        arguments.packages = value;
    } else if (eql(u8, flag, "--extra")) {
        if (arguments.extra_count == extra_max) return false;
        arguments.extra[arguments.extra_count] = value;
        arguments.extra_count += 1;
    } else {
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) !u8 {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const log = &file_writer.interface;
    defer log.flush() catch {}; // Nowhere else to report.

    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    const arguments = parse_arguments(&iterator) orelse {
        log.writeAll(usage_text) catch {}; // Same.
        return constants.exit_user;
    };
    const memory = init.arena.allocator();
    run_assets(init.io, memory, &arguments, log) catch |err| {
        // Same: nowhere else to report.
        if (err != error.Refused) log.print("release-assets: {s}\n", .{@errorName(err)}) catch {};
        return constants.exit_environment;
    };
    return constants.exit_ok;
}

const Refused = error{Refused};

fn refuse(log: *Io.Writer, comptime format: []const u8, arguments: anytype) Refused {
    log.print("release-assets: " ++ format ++ "\n", arguments) catch {}; // Nowhere else to report.
    return error.Refused;
}

fn read_file(io: Io, memory: Allocator, log: *Io.Writer, path: []const u8, max: u32) ![]u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(max + 1)) catch |err| {
        if (err == error.FileNotFound) return refuse(log, "{s} is missing", .{path});
        return refuse(log, "cannot read {s}: {s}", .{ path, @errorName(err) });
    };
    if (bytes.len > max) return refuse(log, "{s} is larger than {d} bytes", .{ path, max });
    return bytes;
}

fn write_file(
    io: Io,
    log: *Io.Writer,
    directory: []const u8,
    name: []const u8,
    bytes: []const u8,
    memory: Allocator,
) !void {
    const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ directory, name });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err|
        return refuse(log, "cannot write {s}: {s}", .{ path, @errorName(err) });
}

/// The executables of each wanted architecture, read from `--bin`: the first missing one stops
/// the run with its path.
fn read_builds(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
) ![]assets.Build {
    var builds: std.ArrayList(assets.Build) = .empty;
    for (assets.architectures) |architecture| {
        if (arguments.arch) |only| {
            if (only != architecture) continue;
        }
        var build: assets.Build = .{ .architecture = architecture, .files = undefined };
        for (assets.executables, 0..) |name, index| {
            const path = try std.fmt.allocPrint(memory, "{s}/{s}-{s}", .{
                arguments.bin, name, architecture.rpm_name(),
            });
            const limit = constants.package_file_bytes_max;
            build.files[index] = try read_file(io, memory, log, path, limit);
        }
        try builds.append(memory, build);
    }
    return builds.items;
}

fn run_assets(io: Io, memory: Allocator, arguments: *const Arguments, log: *Io.Writer) !void {
    var inputs: assets.Inputs = .{
        .version = arguments.version,
        .builds = try read_builds(io, memory, log, arguments),
        .license = undefined,
        .license_id = arguments.license_id,
        .zig_version = arguments.zig_version,
        .source_date_epoch = arguments.source_date_epoch,
    };
    const license_max = constants.release_license_bytes_max;
    inputs.license = try read_file(io, memory, log, arguments.license, license_max);
    const dir = Io.Dir.cwd();
    dir.deleteTree(io, arguments.out) catch |err|
        return refuse(log, "cannot clear {s}: {s}", .{ arguments.out, @errorName(err) });
    dir.createDirPath(io, arguments.out) catch |err|
        return refuse(log, "cannot create {s}: {s}", .{ arguments.out, @errorName(err) });
    for (inputs.builds, 0..) |build, index| {
        const name = try assets.tarball_name(memory, inputs.version, build.architecture);
        const bytes = assets.tarball(memory, &inputs, index) catch |err|
            return refuse(log, "{s}: {s}", .{ name, assets.describe(err) });
        try write_file(io, log, arguments.out, name, bytes, memory);
    }
    const sbom_name = try assets.sbom_name(memory, inputs.version);
    const sbom = assets.sbom(memory, &inputs) catch |err|
        return refuse(log, "{s}: {s}", .{ sbom_name, assets.describe(err) });
    try write_file(io, log, arguments.out, sbom_name, sbom, memory);
    if (arguments.packages) |tree| try copy_packages(io, memory, log, arguments, &inputs, tree);
    for (arguments.extra[0..arguments.extra_count]) |path| {
        const bytes = try read_file(io, memory, log, path, constants.release_asset_bytes_max);
        try write_file(io, log, arguments.out, std.fs.path.basename(path), bytes, memory);
    }
    try write_sums(io, memory, log, arguments.out, "SHA256SUMS");
}

/// The debs and rpms the package tool wrote, copied under their own names. A missing one is an
/// error: a release without them would have a `SHA256SUMS` that silently leaves them out.
fn copy_packages(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
    inputs: *const assets.Inputs,
    tree: []const u8,
) !void {
    for (inputs.builds) |build| {
        for (release.kinds) |kind| {
            const name = kind.name();
            const paths = [_][]const u8{
                try assets.deb_tree_path(memory, name, inputs.version, build.architecture),
                try assets.rpm_tree_path(memory, name, inputs.version, build.architecture),
            };
            for (paths) |relative| {
                const from = try std.fmt.allocPrint(memory, "{s}/{s}", .{ tree, relative });
                const limit = constants.release_asset_bytes_max;
                const bytes = read_file(io, memory, log, from, limit) catch |err| {
                    if (err == error.Refused) {
                        try log.print("release-assets: sign first, or -Dno-packages\n", .{});
                    }
                    return err;
                };
                const base = std.fs.path.basename(relative);
                try write_file(io, log, arguments.out, base, bytes, memory);
            }
        }
    }
}

/// `SHA256SUMS` over every regular file of `directory` except the sums files themselves.
fn write_sums(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    directory: []const u8,
    name: []const u8,
) !void {
    var opened = Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err|
        return refuse(log, "cannot open {s}: {s}", .{ directory, @errorName(err) });
    defer opened.close(io);
    var list: std.ArrayList(assets.Asset) = .empty;
    var iterator = opened.iterate();
    while (iterator.next(io) catch |err| {
        return refuse(log, "cannot read {s}: {s}", .{ directory, @errorName(err) });
    }) |entry| {
        if (entry.kind != .file) {
            return refuse(log, "{s}/{s} is not a plain file", .{ directory, entry.name });
        }
        if (std.mem.startsWith(u8, entry.name, "SHA256SUMS")) continue;
        if (list.items.len == constants.release_assets_max) {
            const more = "{s} holds more than {d} assets";
            return refuse(log, more, .{ directory, constants.release_assets_max });
        }
        const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ directory, entry.name });
        const bytes = try read_file(io, memory, log, path, constants.release_asset_bytes_max);
        try list.append(memory, .{ .name = try memory.dupe(u8, entry.name), .bytes = bytes });
    }
    const text = assets.sums(memory, list.items) catch |err|
        return refuse(log, "{s}: {s}", .{ name, assets.describe(err) });
    try write_file(io, log, directory, name, text, memory);
    try log.print("release-assets: {s}: {d} assets\n", .{ name, list.items.len });
}

const TestIterator = struct {
    words: []const []const u8,
    at: u32 = 0,

    fn next(self: *TestIterator) ?[]const u8 {
        if (self.at == self.words.len) return null;
        self.at += 1;
        return self.words[self.at - 1];
    }
};

test "release_assets_main: a full assets line parses; each missing piece or conflict is refused" {
    // Goal: the flags the build step passes are accepted; incomplete lines, both or neither of
    // --packages and --no-packages, an unknown architecture and subcommand are usage errors.
    const full = [_][]const u8{
        "assets",        "--version",     "1.2.3",     "--bin", "b",
        "--arch",        "aarch64",       "--license", "L",     "--license-id",
        "Apache-2.0",    "--zig-version", "0.17.0",    "--out", "out",
        "--no-packages",
    };
    var iterator: TestIterator = .{ .words = &full };
    const parsed = parse_arguments(&iterator).?;
    try std.testing.expectEqualStrings("1.2.3", parsed.version);
    try std.testing.expectEqual(assets.Architecture.aarch64, parsed.arch.?);
    try std.testing.expect(parsed.no_packages);
    var short: TestIterator = .{ .words = full[0 .. full.len - 1] };
    try std.testing.expect(parse_arguments(&short) == null);
    const both = full ++ [_][]const u8{ "--packages", "p" };
    var conflict: TestIterator = .{ .words = &both };
    try std.testing.expect(parse_arguments(&conflict) == null);
    const riscv = full ++ [_][]const u8{ "--arch", "riscv64" };
    var unknown_arch: TestIterator = .{ .words = &riscv };
    try std.testing.expect(parse_arguments(&unknown_arch) == null);
    var unknown: TestIterator = .{ .words = &.{ "publish", "--out", "o" } };
    try std.testing.expect(parse_arguments(&unknown) == null);
}

test {
    _ = @import("release_assets.zig");
}
