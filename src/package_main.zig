//! `zig build packages` and `zig build packages-check`: write the apt and dnf trees of the
//! Zigcube packages under one directory, or check a tree that was written. Build-host tool; it
//! never runs `gpg` (STYLE.md): it prints the commands the owner runs, in two rounds.
//!
//!   package_main --version V --zigbox-version V --bin DIR --assets DIR --license PATH --out DIR
//!                [--signatures DIR | --test-key] [--check]
//!
//! `--bin` holds `zcube-<arch>`, `zcube-agent-<arch>`, `zcube-server-sqlite-<arch>` and
//! `zcube-server-postgres-<arch>` (`<arch>` is `x86_64` or `aarch64`); `--assets` is `packaging/`.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const model = @import("package.zig").model;
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
};

const usage_text =
    "usage: package_main --version V --zigbox-version V --bin DIR --assets DIR --license PATH " ++
    "--out DIR [--signatures DIR | --test-key] [--check]\n";

/// A value follows each of these flags; the rest take none.
fn parse_arguments(iterator: anytype) ?Arguments {
    var arguments: Arguments = .{};
    while (iterator.next()) |flag| {
        if (std.mem.eql(u8, flag, "--test-key")) {
            arguments.test_key = true;
        } else if (std.mem.eql(u8, flag, "--check")) {
            arguments.check = true;
        } else {
            const value = iterator.next() orelse return null;
            if (!set_value(&arguments, flag, value)) return null;
        }
    }
    if (arguments.out.len == 0) return null;
    if (arguments.test_key and arguments.signatures != null) return null;
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
    const done = if (arguments.check)
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
) !release.Signatures {
    var signatures: release.Signatures = .{};
    for (0..release.architectures.len) |index| {
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
    var options: release.Options = .{ .test_key = arguments.test_key };
    if (arguments.signatures) |directory| {
        options.signatures = try load_signatures(io, memory, log, directory, &inputs);
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
    for (options.signatures.header) |signature| {
        if (signature == null) headers_done = false;
    }
    if (!headers_done) return print_round_one(log, inputs, memory, arguments.out);
    return print_round_two(log, files, arguments.out);
}

fn print_round_one(
    log: *Io.Writer,
    inputs: *const release.Inputs,
    memory: Allocator,
    out: []const u8,
) !void {
    try log.writeAll("packages: round 1, sign each rpm's header (binary, no --armor):\n");
    for (0..release.architectures.len) |index| {
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

fn print_round_two(log: *Io.Writer, files: []const model.TreeFile, out: []const u8) !void {
    if (release.round_of(files) == .done) {
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
    for (release.architectures) |architecture| {
        try log.print(
            "  gpg --batch -abs -u $KEY -o $SIGNATURES/repomd.{s}.xml.asc " ++
                "{s}/rpm/" ++ release.rpm_directory ++ "/{s}/repodata/repomd.xml\n",
            .{ architecture.rpm_name(), out, architecture.rpm_name() },
        );
    }
    try log.writeAll("packages: then run again with -Dsignatures=$SIGNATURES\n");
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

    fn source(self: *DiskSource) check_tree.Source {
        return .{ .context = self, .read_fn = read };
    }
};

fn run_check(io: Io, memory: Allocator, arguments: *const Arguments, log: *Io.Writer) !void {
    var source: DiskSource = .{ .io = io, .memory = memory, .out = arguments.out };
    check_tree.check(source.source(), memory, log, .{
        .signatures_required = arguments.test_key or arguments.signatures != null,
        .test_key = arguments.test_key,
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
