//! `zig build packages` and `zig build packages-check`: write the apt and dnf trees of the
//! Zigcube packages under one directory, or check a tree that was written. Build-host tool; it
//! never runs `gpg` (STYLE.md): it prints the commands the owner runs, in two rounds.
//!
//!   package_main --version V --zigbox-version V --bin DIR --assets DIR --license PATH --out DIR
//!                [--signatures DIR | --test-key] [--signed-at SECONDS] [--arch ARCH] [--check]
//!   package_main --redate --out DIR --signed-at SECONDS
//!
//! `--arch x86_64|aarch64` builds (or checks) one architecture only: CI's subset, since a runner
//! builds only its own server. A release builds both. `--redate` rewrites only the `Date` and
//! `Valid-Until` lines of DIR's apt `Release` and removes its two stale signatures (the refresh).
//!
//! `--bin` holds `zcube-<arch>`, `zcube-agent-<arch>`, `zcube-server-sqlite-<arch>` and
//! `zcube-server-postgres-<arch>` (`<arch>` is `x86_64` or `aarch64`); `--assets` is `packaging/`.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const model = @import("package.zig").model;
const apt = @import("package.zig").apt;
const release = @import("package_release.zig");
const check_tree = @import("package_check.zig");

const Arguments = struct {
    version: []const u8 = "",
    zigbox_version: []const u8 = "",
    bin: []const u8 = "",
    assets: []const u8 = "",
    license: []const u8 = "",
    out: []const u8 = "",
    signatures: ?[]const u8 = null,
    test_key: bool = false,
    check: bool = false,
    signed_at: ?u64 = null,
    only: ?model.Architecture = null,
    redate: bool = false,
};

const usage_text =
    "usage: package_main --version V --zigbox-version V --bin DIR --assets DIR --license PATH " ++
    "--out DIR [--signatures DIR | --test-key] [--signed-at SECONDS] [--arch x86_64|aarch64] " ++
    "[--check]\n" ++
    "       package_main --redate --out DIR --signed-at SECONDS\n";

/// A value follows each of these flags; the rest take none.
fn parse_arguments(iterator: anytype) ?Arguments {
    var arguments: Arguments = .{};
    while (iterator.next()) |flag| {
        if (std.mem.eql(u8, flag, "--test-key")) {
            arguments.test_key = true;
        } else if (std.mem.eql(u8, flag, "--check")) {
            arguments.check = true;
        } else if (std.mem.eql(u8, flag, "--redate")) {
            arguments.redate = true;
        } else {
            const value = iterator.next() orelse return null;
            if (!set_value(&arguments, flag, value)) return null;
        }
    }
    if (arguments.out.len == 0) return null;
    if (arguments.test_key and arguments.signatures != null) return null;
    if (arguments.redate) {
        if (arguments.check or arguments.test_key or arguments.signatures != null) return null;
        if (arguments.signed_at == null or arguments.only != null) return null;
        return arguments;
    }
    if (arguments.check) return arguments;
    if (arguments.version.len == 0 or arguments.license.len == 0) return null;
    if (arguments.zigbox_version.len == 0) return null;
    if (arguments.bin.len == 0 or arguments.assets.len == 0) return null;
    return arguments;
}

fn set_value(arguments: *Arguments, flag: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, flag, "--version")) {
        arguments.version = value;
    } else if (std.mem.eql(u8, flag, "--zigbox-version")) {
        arguments.zigbox_version = value;
    } else if (std.mem.eql(u8, flag, "--bin")) {
        arguments.bin = value;
    } else if (std.mem.eql(u8, flag, "--assets")) {
        arguments.assets = value;
    } else if (std.mem.eql(u8, flag, "--license")) {
        arguments.license = value;
    } else if (std.mem.eql(u8, flag, "--out")) {
        arguments.out = value;
    } else if (std.mem.eql(u8, flag, "--signatures")) {
        arguments.signatures = value;
    } else if (std.mem.eql(u8, flag, "--signed-at")) {
        arguments.signed_at = std.fmt.parseInt(u64, value, 10) catch return false;
    } else if (std.mem.eql(u8, flag, "--arch")) {
        arguments.only = for (release.architectures) |architecture| {
            if (std.mem.eql(u8, value, architecture.rpm_name())) break architecture;
        } else return false;
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
    const done = if (arguments.redate)
        run_redate(init.io, memory, &arguments, log)
    else if (arguments.check)
        run_check(init.io, memory, &arguments, log)
    else
        run_build(init.io, memory, &arguments, log);
    done catch |err| {
        if (err != error.Refused) {
            log.print("packages: {s}\n", .{@errorName(err)}) catch {}; // Same.
        }
        return constants.exit_environment;
    };
    return constants.exit_ok;
}

const Refused = error{Refused};

fn refuse(log: *Io.Writer, comptime format: []const u8, arguments: anytype) Refused {
    log.print("packages: " ++ format ++ "\n", arguments) catch {}; // Nowhere else to report.
    return error.Refused;
}

fn read_input(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    path: []const u8,
    bytes_max: u32,
) ![]u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, memory, .limited(bytes_max + 1)) catch |err|
        return refuse(log, "cannot read {s}: {s}", .{ path, @errorName(err) });
    if (bytes.len > bytes_max) {
        return refuse(log, "{s} is larger than {d} bytes", .{ path, bytes_max });
    }
    return bytes;
}

/// The signature files the owner placed in the signatures directory, when each exists. A missing
/// file is not an error here: it means that round has not happened yet.
fn read_signature(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    directory: []const u8,
    name: []const u8,
) !?[]u8 {
    const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ directory, name });
    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        memory,
        .limited(constants.repo_metadata_bytes_max),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return refuse(log, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    if (bytes.len == 0) return refuse(log, "{s} is empty", .{path});
    return bytes;
}

fn load_signatures(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    directory: []const u8,
    inputs: *const release.Inputs,
    only: ?model.Architecture,
) !release.Signatures {
    var signatures: release.Signatures = .{};
    for (0..release.architectures.len) |index| {
        if (!release.included(only, index)) continue;
        for (release.kinds) |kind| {
            const rpm_file = try release.rpm_file_name(memory, inputs, kind, index);
            const name = try release.header_signature_name(memory, rpm_file);
            const slot = &signatures.header[index * release.kinds.len + @backingInt(kind)];
            slot.* = try read_signature(io, memory, log, directory, name);
            if (slot.*) |bytes| try check_header_signature(log, name, bytes);
        }
        const repomd = try release.repomd_signature_name(memory, index);
        signatures.repomd_asc[index] = try read_signature(io, memory, log, directory, repomd);
    }
    signatures.in_release = try read_signature(io, memory, log, directory, "InRelease");
    signatures.release_gpg = try read_signature(io, memory, log, directory, "Release.gpg");
    return signatures;
}

/// An rpm header signature is one binary OpenPGP packet; `gpg --armor` would write text, which
/// rpm cannot read from its signature tag.
fn check_header_signature(log: *Io.Writer, name: []const u8, bytes: []const u8) Refused!void {
    if (bytes.len > constants.openpgp_signature_bytes_max) {
        return refuse(log, "{s} is larger than {d} bytes, the most a signature here may be", .{
            name, constants.openpgp_signature_bytes_max,
        });
    }
    if (bytes[0] & 0x80 == 0) {
        return refuse(log, "{s} is armored text; sign with gpg --detach-sign, no --armor", .{name});
    }
}

const asset_bytes_max: u32 = 64 * 1024;

/// The four executables of one architecture, read from `--bin`.
fn read_binaries(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
    inputs: *release.Inputs,
) !void {
    const names = [_]struct { stem: []const u8, field: *[release.architectures.len][]const u8 }{
        .{ .stem = "zcube", .field = &inputs.zcube },
        .{ .stem = "zcube-agent", .field = &inputs.agent },
        .{ .stem = "zcube-server-sqlite", .field = &inputs.server_sqlite },
        .{ .stem = "zcube-server-postgres", .field = &inputs.server_postgres },
    };
    for (names) |entry| {
        for (release.architectures, 0..) |architecture, index| {
            entry.field[index] = "";
            if (!release.included(arguments.only, index)) continue;
            const path = try std.fmt.allocPrint(memory, "{s}/{s}-{s}", .{
                arguments.bin, entry.stem, architecture.rpm_name(),
            });
            entry.field[index] = try read_input(
                io,
                memory,
                log,
                path,
                constants.package_file_bytes_max,
            );
        }
    }
}

fn read_asset(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
    name: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ arguments.assets, name });
    return read_input(io, memory, log, path, asset_bytes_max);
}

fn run_build(io: Io, memory: Allocator, arguments: *const Arguments, log: *Io.Writer) !void {
    var inputs: release.Inputs = undefined;
    inputs.version = arguments.version;
    inputs.zigbox_version = arguments.zigbox_version;
    try read_binaries(io, memory, log, arguments, &inputs);
    inputs.license = try read_input(io, memory, log, arguments.license, asset_bytes_max);
    inputs.server_unit = try read_asset(io, memory, log, arguments, "zcube-server.service");
    inputs.agent_unit = try read_asset(io, memory, log, arguments, "zcube-agent.service");
    inputs.server_sqlite_config = try read_asset(io, memory, log, arguments, "server-sqlite.zon");
    inputs.server_postgres_config =
        try read_asset(io, memory, log, arguments, "server-postgres.zon");
    inputs.agent_config = try read_asset(io, memory, log, arguments, "agent.zon");
    var options: release.Options = .{
        .test_key = arguments.test_key,
        .signed_at = arguments.signed_at,
        .only = arguments.only,
    };
    if (arguments.signatures) |directory| {
        options.signatures =
            try load_signatures(io, memory, log, directory, &inputs, arguments.only);
    }
    const files = release.build(memory, &inputs, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.WriteFailed, error.BadSignature => {
            return refuse(log, "a writer failed on its bounds", .{});
        },
        else => return refuse(log, "{s}", .{model.describe(@errorCast(err))}),
    };
    // A placed signature that signs other bytes (stale, or swapped) stops the run before it writes.
    check_tree.check_placed_signatures(files, memory, log) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refuse(log, "a signature does not match the tree; nothing was written", .{}),
    };
    const dir = Io.Dir.cwd();
    // One run, one set of files: nothing of an earlier run stays beside this one's.
    for ([_][]const u8{ "apt", "rpm", "to-sign" }) |sub| {
        const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ arguments.out, sub });
        dir.deleteTree(io, path) catch |err| {
            return refuse(log, "cannot clear {s}: {s}", .{ path, @errorName(err) });
        };
    }
    for ([_][]const u8{ release.test_key_armored_path, release.test_key_binary_path }) |name| {
        const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ arguments.out, name });
        dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return refuse(log, "cannot clear {s}: {s}", .{ path, @errorName(err) }),
        };
    }
    for (files) |file| try write_file(io, memory, log, arguments.out, file);
    try log.print("packages: wrote {d} files under {s}\n", .{ files.len, arguments.out });
    try print_next(log, arguments, files, &options, &inputs, memory);
}

fn write_file(
    io: Io,
    memory: Allocator,
    log: *Io.Writer,
    out: []const u8,
    file: model.TreeFile,
) !void {
    const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ out, file.path });
    const dir = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(io, parent) catch |err|
            return refuse(log, "cannot create {s}: {s}", .{ parent, @errorName(err) });
    }
    dir.writeFile(io, .{ .sub_path = path, .data = file.bytes }) catch |err|
        return refuse(log, "cannot write {s}: {s}", .{ path, @errorName(err) });
}

/// What the owner does next: the two rounds of `gpg`, or the check.
fn print_next(
    log: *Io.Writer,
    arguments: *const Arguments,
    files: []const model.TreeFile,
    options: *const release.Options,
    inputs: *const release.Inputs,
    memory: Allocator,
) !void {
    if (arguments.test_key) {
        return log.writeAll("packages: signed with the test key (it vouches for nothing)\n");
    }
    var headers_done = true;
    for (options.signatures.header, 0..) |signature, slot| {
        if (!release.included(arguments.only, slot / release.kinds.len)) continue;
        if (signature == null) headers_done = false;
    }
    if (!headers_done) return print_round_one(log, inputs, memory, arguments);
    return print_round_two(log, files, arguments);
}

fn print_round_one(
    log: *Io.Writer,
    inputs: *const release.Inputs,
    memory: Allocator,
    arguments: *const Arguments,
) !void {
    const out = arguments.out;
    try log.writeAll("packages: round 1, sign each rpm's header (binary, no --armor):\n");
    for (0..release.architectures.len) |index| {
        if (!release.included(arguments.only, index)) continue;
        for (release.kinds) |kind| {
            const rpm_file = try release.rpm_file_name(memory, inputs, kind, index);
            try log.print(
                "  gpg --batch --detach-sign -u $KEY -o $SIGNATURES/{s}.header.sig " ++
                    "{s}/to-sign/{s}.header\n",
                .{ rpm_file, out, rpm_file },
            );
        }
    }
    try log.writeAll("packages: then run again with -Dsignatures=$SIGNATURES\n");
}

fn print_round_two(
    log: *Io.Writer,
    files: []const model.TreeFile,
    arguments: *const Arguments,
) !void {
    const out = arguments.out;
    if (release.round_of(files, arguments.only) == .done) {
        return log.writeAll("packages: signed; run packages-check with the same options\n");
    }
    try log.writeAll("packages: round 2, sign the repository metadata:\n");
    try log.print(
        "  gpg --batch --clearsign -u $KEY -o $SIGNATURES/InRelease {s}/{s}\n",
        .{ out, release.apt_release_path },
    );
    try log.print(
        "  gpg --batch -abs -u $KEY -o $SIGNATURES/Release.gpg {s}/{s}\n",
        .{ out, release.apt_release_path },
    );
    for (release.architectures, 0..) |architecture, index| {
        if (!release.included(arguments.only, index)) continue;
        try log.print(
            "  gpg --batch -abs -u $KEY -o $SIGNATURES/repomd.{s}.xml.asc " ++
                "{s}/rpm/" ++ release.rpm_directory ++ "/{s}/repodata/repomd.xml\n",
            .{ architecture.rpm_name(), out, architecture.rpm_name() },
        );
    }
    try log.writeAll("packages: then run again with -Dsignatures=$SIGNATURES\n");
}

/// Re-dates `Release` in a tree on disk and removes the two signatures of the old one. The
/// packages, the `Packages` files and the rpm side are not touched: `Release` names them by sum,
/// and only its two date lines change.
fn run_redate(io: Io, memory: Allocator, arguments: *const Arguments, log: *Io.Writer) !void {
    const signed_at = arguments.signed_at.?;
    const path = try std.fmt.allocPrint(memory, "{s}/{s}", .{
        arguments.out, release.apt_release_path,
    });
    const old = try read_input(io, memory, log, path, constants.repo_metadata_bytes_max);
    const new = apt.redate(memory, old, signed_at) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refuse(log, "{s}: {s}", .{ path, model.describe(err) }),
    };
    const dir = Io.Dir.cwd();
    dir.writeFile(io, .{ .sub_path = path, .data = new }) catch |err|
        return refuse(log, "cannot write {s}: {s}", .{ path, @errorName(err) });
    for ([_][]const u8{ release.apt_in_release_path, release.apt_release_gpg_path }) |stale| {
        const stale_path = try std.fmt.allocPrint(memory, "{s}/{s}", .{ arguments.out, stale });
        dir.deleteFile(io, stale_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return refuse(log, "cannot remove {s}: {s}", .{ stale_path, @errorName(err) }),
        };
    }
    try log.print("packages: re-dated {s}; sign it again\n", .{path});
    assert(old.len > 0);
    assert(new.len > 0);
}

/// The files of a written tree, read from disk.
const DiskSource = struct {
    io: Io,
    memory: Allocator,
    out: []const u8,

    fn read(context: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *DiskSource = @ptrCast(@alignCast(context));
        const full = std.fmt.allocPrint(self.memory, "{s}/{s}", .{ self.out, path }) catch
            return null;
        const limit: Io.Limit = .limited(constants.package_file_bytes_max + 1);
        return Io.Dir.cwd().readFileAlloc(self.io, full, self.memory, limit) catch null;
    }

    /// Every file under the output directory, by path relative to it; null when it cannot be
    /// walked (the check then fails).
    fn list(context: *anyopaque, memory: Allocator) ?[]const []const u8 {
        const self: *DiskSource = @ptrCast(@alignCast(context));
        var dir = Io.Dir.cwd().openDir(self.io, self.out, .{ .iterate = true }) catch
            return null;
        defer dir.close(self.io);
        var walker = dir.walk(memory) catch return null;
        defer walker.deinit();
        var paths: std.ArrayList([]const u8) = .empty;
        while (walker.next(self.io) catch return null) |entry| {
            if (entry.kind == .directory) continue;
            const path = memory.dupe(u8, entry.path) catch return null;
            paths.append(memory, path) catch return null;
        }
        return paths.items;
    }

    fn source(self: *DiskSource) check_tree.Source {
        return .{ .context = self, .read_fn = read, .list_fn = list };
    }
};

fn run_check(io: Io, memory: Allocator, arguments: *const Arguments, log: *Io.Writer) !void {
    var source: DiskSource = .{ .io = io, .memory = memory, .out = arguments.out };
    check_tree.check(source.source(), memory, log, .{
        .signatures_required = arguments.test_key or arguments.signatures != null,
        .test_key = arguments.test_key,
        .only = arguments.only,
    }) catch |err| switch (err) {
        error.CheckFailed => {
            return refuse(log, "the tree under {s} does not check out", .{arguments.out});
        },
        error.OutOfMemory => return err,
        else => return refuse(log, "a check could not run: {s}", .{@errorName(err)}),
    };
    try log.print("packages-check: {s} is consistent\n", .{arguments.out});
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

test "arguments: a full build line parses, and each missing piece is refused" {
    // Goal: the flags the build step passes are accepted, and an incomplete or contradictory
    // line (no input, a test key together with a signatures directory) is a usage error.
    const full = [_][]const u8{
        "--version", "1.2.3", "--zigbox-version", "0.5.0", "--bin",      "b", "--assets", "a",
        "--license", "L",     "--out",            "out",   "--test-key",
    };
    var iterator: TestIterator = .{ .words = &full };
    const parsed = parse_arguments(&iterator).?;
    try std.testing.expectEqualStrings("1.2.3", parsed.version);
    try std.testing.expect(parsed.test_key);
    try std.testing.expect(!parsed.check);

    var short: TestIterator = .{ .words = full[0 .. full.len - 3] };
    try std.testing.expect(parse_arguments(&short) == null);
    const both = full ++ [_][]const u8{ "--signatures", "dir" };
    var conflict: TestIterator = .{ .words = &both };
    try std.testing.expect(parse_arguments(&conflict) == null);
    const checking = [_][]const u8{ "--out", "o", "--check" };
    var check_only: TestIterator = .{ .words = &checking };
    try std.testing.expect(parse_arguments(&check_only).?.check);
    const unknown = [_][]const u8{ "--out", "o", "--nope", "x" };
    var bad: TestIterator = .{ .words = &unknown };
    try std.testing.expect(parse_arguments(&bad) == null);
}

test "arguments: --arch names one architecture, --signed-at is seconds" {
    // Goal: the CI subset and the signing time parse, and a value that is neither is refused.
    const words = [_][]const u8{
        "--version", "1",       "--zigbox-version", "0.5.0",      "--bin", "b",
        "--assets",  "a",       "--license",        "L",          "--out", "o",
        "--arch",    "aarch64", "--signed-at",      "1800000000",
    };
    var iterator: TestIterator = .{ .words = &words };
    const parsed = parse_arguments(&iterator).?;
    try std.testing.expectEqual(@as(?model.Architecture, .aarch64), parsed.only);
    try std.testing.expectEqual(@as(?u64, 1_800_000_000), parsed.signed_at);
    var arm: TestIterator = .{ .words = &.{ "--out", "o", "--check", "--arch", "arm64" } };
    try std.testing.expect(parse_arguments(&arm) == null);
    var soon: TestIterator = .{ .words = &.{ "--out", "o", "--check", "--signed-at", "soon" } };
    try std.testing.expect(parse_arguments(&soon) == null);
}

test "arguments: redate needs a signing time and refuses every other mode" {
    // Goal: `--redate` is its own mode: out and signed-at only, and a bad time is a usage error.
    const ok_words = [_][]const u8{ "--redate", "--out", "o", "--signed-at", "1800000000" };
    var ok: TestIterator = .{ .words = &ok_words };
    try std.testing.expectEqual(@as(?u64, 1_800_000_000), parse_arguments(&ok).?.signed_at);
    var missing: TestIterator = .{ .words = &.{ "--redate", "--out", "o" } };
    try std.testing.expect(parse_arguments(&missing) == null);
    const mixed_words = [_][]const u8{ "--redate", "--out", "o", "--signed-at", "1", "--check" };
    var mixed: TestIterator = .{ .words = &mixed_words };
    try std.testing.expect(parse_arguments(&mixed) == null);
}

test "a header signature is accepted at the bound and refused one byte past it" {
    // Goal: `openpgp_signature_bytes_max` is exact, and the refusal names the bound.
    var bytes: [constants.openpgp_signature_bytes_max + 1]u8 = @splat(0x89);
    var sink: Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const name = "a.rpm.header.sig";
    const most = bytes[0..constants.openpgp_signature_bytes_max];
    try check_header_signature(&sink.writer, name, most);
    try std.testing.expectError(
        error.Refused,
        check_header_signature(&sink.writer, "a.rpm.header.sig", &bytes),
    );
    const message = "packages: a.rpm.header.sig is larger than 1024 bytes, " ++
        "the most a signature here may be\n";
    try std.testing.expectEqualStrings(message, sink.written());
}

test {
    _ = @import("package_release.zig");
    _ = @import("package_check.zig");
}
