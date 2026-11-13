//! `zig build mac-release`: the macOS release of `zcube`, in steps that stop at the first one
//! that fails. It follows Zigbox's tool of the same name (Zigbox `src/mac_release.zig`), with
//! `zcube` for `zbx` and no entitlements (the command line asks for no protected resource). It is
//! run by the build with the two ReleaseSafe binaries:
//!
//!   1. `lipo -create` the arm64 and the x86_64 binary into one universal binary in a staging
//!      directory in the output directory, and check with `lipo -archs` that it holds both;
//!   2. `codesign` it with the hardened runtime and a secure timestamp (each slice gets its own
//!      signature);
//!   3. `codesign --verify --strict`, shown;
//!   4. `ditto` the binary, alone at the top of the archive, into
//!      `zcube-<version>-macos-universal.zip` (a zip, because `notarytool` takes a zip and
//!      Homebrew unpacks one; a bare Mach-O cannot be stapled, so it travels in an archive), and
//!      check that the archive holds the same signed code;
//!   5. with `--notarize`: `xcrun notarytool submit --keychain-profile <profile> --wait`. No
//!      profile, or one the keychain does not have, is refused before anything is built;
//!   6. write `<archive>.sha256` and `zcube-resource.rb`, the lines that add `zcube` to Zigbox's
//!      `zigbox` formula, with the version, URL and hash filled in (docs/macos.md).
//!
//! `--keychain FILE` makes `codesign` and `notarytool` use that keychain file instead of the login
//! keychain.
//!
//! The identity `-` signs ad hoc (no timestamp, no certificate: for trying the script). Nothing
//! secret is read, printed or logged: the keychain holds the certificate and the notary profile,
//! and this tool passes only their names.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

pub const default_identity = "Developer ID Application: Alex Zuzin (56A872L679)";
/// Zigbox's profile: one Apple account notarizes both commands, so the owner stores it once.
pub const default_profile = "zbx-notary";
const release_url = "https://github.com/Zigbox/zigcube/releases/download";

/// The two architectures of the universal binary, in the order `lipo -archs` prints them for the
/// file this tool makes (it sorts them, so the tests compare sets, not order).
pub const architectures = [_][]const u8{ "arm64", "x86_64" };

const Arguments = struct {
    binary_arm64: []const u8 = "",
    binary_x86_64: []const u8 = "",
    formula: []const u8 = "",
    out: []const u8 = "",
    version: []const u8 = "",
    identity: []const u8 = default_identity,
    profile: []const u8 = default_profile,
    /// A keychain file to sign and notarize with instead of the login keychain; empty is the
    /// login keychain.
    keychain: []const u8 = "",
    notarize: bool = false,
};

pub fn archive_name(buffer: []u8, version: []const u8) []const u8 {
    assert(version.len > 0);
    // Cannot fail: a version of at most 32 bytes and fixed words fit the buffer.
    return std.fmt.bufPrint(buffer, "zcube-{s}-macos-universal.zip", .{version}) catch unreachable;
}

/// True when `lipo -archs` output names exactly the architectures of the release, each once, in
/// either order: a universal binary missing a slice, or holding a third, is not a release.
pub fn archs_are_universal(output: []const u8) bool {
    var seen: [architectures.len]bool = @splat(false);
    var words = std.mem.tokenizeAny(u8, output, " \t\r\n");
    while (words.next()) |word| {
        var known = false;
        for (architectures, 0..) |name, index| {
            if (!std.mem.eql(u8, word, name)) continue;
            if (seen[index]) return false;
            seen[index] = true;
            known = true;
        }
        if (!known) return false;
    }
    for (seen) |present| if (!present) return false;
    return true;
}

/// The words `codesign -dvvv` is run with to read the code directory of one slice of a
/// universal binary: without `--architecture` it reports the slice that matches the host.
pub fn cdhash_arguments(
    architecture: []const u8,
    path: []const u8,
    out: *[4][]const u8,
) []const []const u8 {
    assert(architecture.len > 0);
    assert(path.len > 0);
    out.* = .{ "-dvvv", "--architecture", architecture, path };
    return out[0..4];
}

/// True for the ad-hoc identity, which has no certificate and so no secure timestamp.
pub fn is_ad_hoc(identity: []const u8) bool {
    return std.mem.eql(u8, identity, "-");
}

/// The words `codesign` is run with, after the program name.
pub fn sign_arguments(
    identity: []const u8,
    binary: []const u8,
    keychain: []const u8,
    out: *[10][]const u8,
) []const []const u8 {
    assert(identity.len > 0);
    assert(binary.len > 0);
    const timestamp: []const u8 = if (is_ad_hoc(identity)) "--timestamp=none" else "--timestamp";
    // Options first, the binary last: `codesign` takes what follows the options as paths. The
    // hardened runtime is what notarization requires; zcube needs no entitlement under it.
    const words = [_][]const u8{
        "--force", "--options", "runtime", timestamp, "--sign", identity,
    };
    @memcpy(out[0..words.len], &words);
    var count: usize = words.len;
    if (keychain.len > 0) {
        out[count] = "--keychain";
        out[count + 1] = keychain;
        count += 2;
    }
    out[count] = binary;
    count += 1;
    assert(count <= out.len);
    return out[0..count];
}

/// The words `notarytool` is run with, after the program name, for a submission or the profile
/// check: `verb` is `submit` (with the archive and `--wait`) or `history`.
pub fn notary_arguments(
    verb: []const u8,
    archive: []const u8,
    profile: []const u8,
    keychain: []const u8,
    out: *[8][]const u8,
) []const []const u8 {
    assert(profile.len > 0);
    const submit = std.mem.eql(u8, verb, "submit");
    if (!submit) assert(std.mem.eql(u8, verb, "history"));
    var count: usize = 0;
    out[count] = "notarytool";
    out[count + 1] = verb;
    count += 2;
    if (submit) {
        assert(archive.len > 0);
        out[count] = archive;
        count += 1;
    }
    out[count] = "--keychain-profile";
    out[count + 1] = profile;
    count += 2;
    if (keychain.len > 0) {
        out[count] = "--keychain";
        out[count + 1] = keychain;
        count += 2;
    }
    if (submit) {
        out[count] = "--wait";
        count += 1;
    }
    assert(count <= out.len);
    return out[0..count];
}

/// The `CDHash=` line of `codesign -dvvv` output: the identity of the signed code.
pub fn cdhash_of(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CDHash=")) return line["CDHash=".len..];
    }
    return null;
}

/// The one line said when `codesign` cannot use the key: it is a failure of the session, not of
/// the script or the certificate.
pub const keychain_message =
    "mac_release: codesign cannot use the signing key (errSecInternalComponent). " ++
    "Run the release from a logged-in graphical session with an unlocked login keychain " ++
    "(your own Terminal, or a runner with that keychain unlocked), " ++
    "never from an ssh or sandboxed session.\n";

/// Fills `@VERSION@`, `@URL@` and `@SHA256@` in the formula template.
pub fn fill_formula(
    arena: std.mem.Allocator,
    template: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
) ![]u8 {
    assert(sha256.len == 64);
    const first = try std.mem.replaceOwned(u8, arena, template, "@VERSION@", version);
    const second = try std.mem.replaceOwned(u8, arena, first, "@URL@", url);
    return std.mem.replaceOwned(u8, arena, second, "@SHA256@", sha256);
}

pub fn main(init: std.process.Init) !u8 {
    var buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const log = &file_writer.interface;
    defer log.flush() catch {};
    const arguments = parse_arguments(init) orelse {
        try log.print("mac_release: usage: --binary-aarch64 F --binary-x86_64 F " ++
            "--formula F --out DIR --version V [--identity NAME|-] [--profile NAME] " ++
            "[--keychain FILE] " ++
            "[--notarize]\n", .{});
        return 2;
    };
    run(init, &arguments, log) catch |err| {
        try log.print("mac_release: stopped: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn parse_arguments(init: std.process.Init) ?Arguments {
    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    var result: Arguments = .{};
    while (iterator.next()) |name| {
        if (std.mem.eql(u8, name, "--notarize")) {
            result.notarize = true;
            continue;
        }
        const value = iterator.next() orelse return null;
        if (std.mem.eql(u8, name, "--binary-aarch64")) result.binary_arm64 = value;
        if (std.mem.eql(u8, name, "--binary-x86_64")) result.binary_x86_64 = value;
        if (std.mem.eql(u8, name, "--formula")) result.formula = value;
        if (std.mem.eql(u8, name, "--out")) result.out = value;
        if (std.mem.eql(u8, name, "--version")) result.version = value;
        if (std.mem.eql(u8, name, "--identity")) result.identity = value;
        if (std.mem.eql(u8, name, "--profile")) result.profile = value;
        if (std.mem.eql(u8, name, "--keychain")) result.keychain = value;
    }
    if (result.binary_arm64.len == 0 or result.binary_x86_64.len == 0) return null;
    if (result.out.len == 0 or result.version.len == 0) return null;
    if (result.formula.len == 0) return null;
    return result;
}

fn exec(io: Io, log: *Io.Writer, argv: []const []const u8) !void {
    assert(argv.len > 0);
    try log.print("mac_release: {s}", .{argv[0]});
    for (argv[1..]) |word| try log.print(" {s}", .{word});
    try log.print("\n", .{});
    try log.flush();
    var child = try std.process.spawn(io, .{ .argv = argv });
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

/// Runs `codesign` to sign; its words are shown, and a key it cannot use is said in one line.
fn sign(io: Io, arena: std.mem.Allocator, log: *Io.Writer, argv: []const []const u8) !void {
    try log.print("mac_release: {s}", .{argv[0]});
    for (argv[1..]) |word| try log.print(" {s}", .{word});
    try log.print("\n", .{});
    const result = try std.process.run(arena, io, .{ .argv = argv });
    try log.writeAll(result.stderr);
    try log.writeAll(result.stdout);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (std.mem.indexOf(u8, result.stderr, "errSecInternalComponent") != null) {
        try log.writeAll(keychain_message);
        return error.KeychainUnavailable;
    }
    return error.CommandFailed;
}

fn cdhash_at(
    io: Io,
    arena: std.mem.Allocator,
    architecture: []const u8,
    path: []const u8,
) ![]const u8 {
    var words: [4][]const u8 = undefined;
    const tail = cdhash_arguments(architecture, path, &words);
    var argv: [5][]const u8 = undefined;
    argv[0] = "/usr/bin/codesign";
    @memcpy(argv[1 .. 1 + tail.len], tail);
    const result = try std.process.run(arena, io, .{ .argv = argv[0 .. 1 + tail.len] });
    const found = cdhash_of(result.stderr) orelse return error.NoCodeDirectoryHash;
    return arena.dupe(u8, found);
}

/// The binary and the one inside the archive are the same signed code: for each architecture
/// their CDHash is equal.
fn same_code(
    io: Io,
    arena: std.mem.Allocator,
    log: *Io.Writer,
    binary: []const u8,
    archive: []const u8,
    out: []const u8,
) !void {
    const check = try std.fmt.allocPrint(arena, "{s}/check", .{out});
    try Io.Dir.cwd().createDirPath(io, check);
    try exec(io, log, &.{ "/usr/bin/ditto", "-x", "-k", archive, check });
    const inside = try std.fmt.allocPrint(arena, "{s}/zcube", .{check});
    for (architectures) |architecture| {
        const first = try cdhash_at(io, arena, architecture, binary);
        const second = try cdhash_at(io, arena, architecture, inside);
        if (!std.mem.eql(u8, first, second)) {
            const said = "mac_release: the archive holds other {s} code than the binary " ++
                "({s} and {s})\n";
            try log.print(said, .{ architecture, first, second });
            return error.ArchiveDiffers;
        }
        try log.print("mac_release: the archive's {s} zcube has the binary's CDHash {s}\n", .{
            architecture, first,
        });
    }
    try Io.Dir.cwd().deleteTree(io, check);
}

/// Combines the two single-architecture binaries into the universal one, and checks that it holds
/// exactly both: `lipo -create` would also make a file of one slice if given the same twice.
fn make_universal(
    io: Io,
    arena: std.mem.Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
    universal: []const u8,
) !void {
    const lipo = "/usr/bin/lipo";
    try exec(io, log, &.{
        lipo,                   "-create",               "-output", universal,
        arguments.binary_arm64, arguments.binary_x86_64,
    });
    const result = try std.process.run(arena, io, .{ .argv = &.{ lipo, "-archs", universal } });
    try log.print("mac_release: lipo -archs: {s}", .{result.stdout});
    if (!archs_are_universal(result.stdout)) {
        try log.print("mac_release: the universal binary does not hold exactly arm64 and " ++
            "x86_64\n", .{});
        return error.NotUniversal;
    }
}

/// What `notarytool history` says of a notary profile in the keychain, in three states:
/// `present` (it exits 0), `missing` (it fails and prints that no keychain item was found, so the
/// profile was never stored) and `unknown` (any other failure: it could not run, Apple or the
/// network is down, the key was revoked). Only `missing` is a known absence.
const ProfileState = enum { present, missing, unknown };

/// Runs `notarytool history` for the profile and sorts the outcome into a `ProfileState`. A
/// missing profile is told apart from any other failure by the text notarytool prints.
fn profile_state(
    io: Io,
    arena: std.mem.Allocator,
    profile: []const u8,
    keychain: []const u8,
) ProfileState {
    var words: [8][]const u8 = undefined;
    const tail = notary_arguments("history", "", profile, keychain, &words);
    var argv: [10][]const u8 = undefined;
    argv[0] = "/usr/bin/xcrun";
    argv[1] = "--no-cache"; // no per-user lookup cache that another process could have edited
    @memcpy(argv[2 .. 2 + tail.len], tail);
    const run_argv = argv[0 .. 2 + tail.len];
    const result = std.process.run(arena, io, .{ .argv = run_argv }) catch return .unknown;
    switch (result.term) {
        .exited => |code| if (code == 0) return .present,
        else => {},
    }
    const missing = profile_is_missing(result.stderr) or profile_is_missing(result.stdout);
    return if (missing) .missing else .unknown;
}

fn profile_is_missing(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "No Keychain password item found") != null;
}

/// Refused before anything is built or signed: a release that cannot be notarized is not worth
/// signing for.
fn check_notarization(
    io: Io,
    arena: std.mem.Allocator,
    arguments: *const Arguments,
    log: *Io.Writer,
) !void {
    assert(arguments.notarize);
    // Refused before anything is built or signed: a release that cannot be notarized is not
    // worth signing for.
    if (arguments.profile.len == 0 or is_ad_hoc(arguments.identity)) {
        try log.print("mac_release: notarization needs a signing identity and a keychain " ++
            "profile (--profile, default {s}); " ++
            "an ad-hoc signature cannot be notarized\n", .{default_profile});
        return error.NotarizationRefused;
    }
    switch (profile_state(io, arena, arguments.profile, arguments.keychain)) {
        .present => {},
        .missing => {
            try log.print("mac_release: the keychain has no notary profile '{s}'. Store one " ++
                "with: xcrun notarytool store-credentials {s} (it asks for the Apple ID and " ++
                "an app-specific password, or an API key, and keeps them in the keychain)\n", .{
                arguments.profile, arguments.profile,
            });
            return error.NotarizationRefused;
        },
        .unknown => {
            try log.print("mac_release: could not query notary profile '{s}' (Apple or the " ++
                "network may be down, or the key revoked); it is not known to be missing\n", .{
                arguments.profile,
            });
            return error.NotarizationRefused;
        },
    }
}

fn run(init: std.process.Init, arguments: *const Arguments, log: *Io.Writer) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    if (arguments.notarize) try check_notarization(io, arena, arguments, log);
    const dir = Io.Dir.cwd();
    // One run, one set of files: nothing of an earlier run stays beside this one's.
    dir.deleteTree(io, arguments.out) catch {};
    try dir.createDirPath(io, arguments.out);
    // The archive holds the binary alone, at its top: it is made from this directory's contents.
    const stage = try std.fmt.allocPrint(arena, "{s}/stage", .{arguments.out});
    try dir.createDirPath(io, stage);
    const signed = try std.fmt.allocPrint(arena, "{s}/zcube", .{stage});
    try make_universal(io, arena, log, arguments, signed);
    var words: [10][]const u8 = undefined;
    const tail = sign_arguments(arguments.identity, signed, arguments.keychain, &words);
    var argv: [11][]const u8 = undefined;
    argv[0] = "/usr/bin/codesign";
    @memcpy(argv[1 .. 1 + tail.len], tail);
    try sign(io, arena, log, argv[0 .. 1 + tail.len]);
    try exec(io, log, &.{ "/usr/bin/codesign", "--verify", "--strict", "--verbose=2", signed });

    var name_buffer: [96]u8 = undefined;
    const name = archive_name(&name_buffer, arguments.version);
    const archive = try std.fmt.allocPrint(arena, "{s}/{s}", .{ arguments.out, name });
    try exec(io, log, &.{ "/usr/bin/ditto", "-c", "-k", "--norsrc", stage, archive });
    try same_code(io, arena, log, signed, archive, arguments.out);
    if (arguments.notarize) {
        var notary_words: [8][]const u8 = undefined;
        const notary = notary_arguments(
            "submit",
            archive,
            arguments.profile,
            arguments.keychain,
            &notary_words,
        );
        var notary_argv: [10][]const u8 = undefined;
        notary_argv[0] = "/usr/bin/xcrun";
        notary_argv[1] = "--no-cache"; // see profile_state
        @memcpy(notary_argv[2 .. 2 + notary.len], notary);
        try exec(io, log, notary_argv[0 .. 2 + notary.len]);
        // A Mach-O on its own cannot be stapled, and the archive is not a bundle either: the
        // ticket stays with Apple, and Gatekeeper asks for it the first time a quarantined copy
        // runs. Nothing is stapled.
        try log.print("mac_release: notarized; the ticket is not stapled (a bare binary has no " ++
            "place for one)\n", .{});
    }
    try write_checksum_and_formula(io, arena, log, arguments, archive, name);
}

/// The archive's sha256 beside it, and the formula with the version, URL and hash filled in.
fn write_checksum_and_formula(
    io: Io,
    arena: std.mem.Allocator,
    log: *Io.Writer,
    arguments: *const Arguments,
    archive: []const u8,
    name: []const u8,
) !void {
    const dir = Io.Dir.cwd();
    const bytes = try dir.readFileAlloc(io, archive, arena, .limited(1 << 30));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const sum_path = try std.fmt.allocPrint(arena, "{s}.sha256", .{archive});
    const sum_line = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ &hex, name });
    try dir.writeFile(io, .{ .sub_path = sum_path, .data = sum_line });
    const template = try dir.readFileAlloc(io, arguments.formula, arena, .limited(1 << 20));
    const tag = arguments.version;
    const url = try std.fmt.allocPrint(arena, "{s}/v{s}/{s}", .{ release_url, tag, name });
    const formula = try fill_formula(arena, template, arguments.version, url, &hex);
    const formula_path = try std.fmt.allocPrint(arena, "{s}/zcube-resource.rb", .{
        arguments.out,
    });
    try dir.writeFile(io, .{ .sub_path = formula_path, .data = formula });
    try log.print("mac_release: {s}\nmac_release: sha256 {s}\n", .{ archive, &hex });
    try log.print("mac_release: formula {s}\n", .{formula_path});
}

test "the archive is named for the version and the ad-hoc identity has no timestamp" {
    // Goal: the two small rules of the script. Method: a name, and the codesign words for each
    // kind of identity.
    var buffer: [96]u8 = undefined;
    const name = archive_name(&buffer, "0.1.0");
    try std.testing.expectEqualStrings("zcube-0.1.0-macos-universal.zip", name);
    var words: [10][]const u8 = undefined;
    const ad_hoc = sign_arguments("-", "zcube", "", &words);
    try std.testing.expectEqualStrings("--timestamp=none", ad_hoc[3]);
    const real = sign_arguments(default_identity, "zcube", "", &words);
    try std.testing.expectEqualStrings("--options", real[1]);
    try std.testing.expectEqualStrings("runtime", real[2]);
    try std.testing.expectEqualStrings("--timestamp", real[3]);
    try std.testing.expectEqualStrings(default_identity, real[5]);
    try std.testing.expectEqualStrings("zcube", real[6]);
    try std.testing.expectEqual(@as(usize, 7), real.len);
    for (real) |word| try std.testing.expect(!std.mem.eql(u8, word, "--entitlements"));
    try std.testing.expect(is_ad_hoc("-"));
    try std.testing.expect(!is_ad_hoc(default_identity));
}

test "--keychain is passed to codesign and notarytool, and only when given" {
    // Goal: the keychain reaches both tools when set and neither when unset, so the owner's
    // login-keychain path is unchanged. Method: the words built with and without a keychain.
    var words: [10][]const u8 = undefined;
    const plain = sign_arguments("id", "zcube", "", &words);
    try std.testing.expectEqual(@as(usize, 7), plain.len);
    try std.testing.expectEqualStrings("zcube", plain[plain.len - 1]);
    const keyed = sign_arguments("id", "zcube", "/tmp/k.keychain-db", &words);
    try std.testing.expectEqual(@as(usize, 9), keyed.len);
    try std.testing.expectEqualStrings("--keychain", keyed[6]);
    try std.testing.expectEqualStrings("/tmp/k.keychain-db", keyed[7]);
    try std.testing.expectEqualStrings("zcube", keyed[8]);

    var notary_words: [8][]const u8 = undefined;
    const submit = notary_arguments("submit", "a.zip", "prof", "", &notary_words);
    try std.testing.expectEqual(@as(usize, 6), submit.len);
    try std.testing.expectEqualStrings("--wait", submit[submit.len - 1]);
    const submit_keyed = notary_arguments("submit", "a.zip", "prof", "/k", &notary_words);
    try std.testing.expectEqual(@as(usize, 8), submit_keyed.len);
    try std.testing.expectEqualStrings("--keychain", submit_keyed[5]);
    try std.testing.expectEqualStrings("/k", submit_keyed[6]);
    try std.testing.expectEqualStrings("--wait", submit_keyed[7]);
    const history = notary_arguments("history", "", "prof", "/k", &notary_words);
    try std.testing.expectEqual(@as(usize, 6), history.len);
    try std.testing.expectEqualStrings("history", history[1]);
    try std.testing.expectEqualStrings("/k", history[5]);
}

test "the CDHash is read from codesign's output, and the keychain message is one line" {
    // Goal: the two small texts the check and the refusal depend on. Method: output as codesign
    // writes it.
    const output = "Executable=/x/zcube\nIdentifier=zcube\nCDHash=0123abcd\nSignature size=8970\n";
    try std.testing.expectEqualStrings("0123abcd", cdhash_of(output).?);
    try std.testing.expect(cdhash_of("not signed") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, keychain_message, "\n"));
}

test "the formula template is filled in all three places" {
    // Goal: no placeholder is left in the formula. Method: a template that uses each twice.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const template = "@VERSION@ @URL@ @SHA256@ @VERSION@";
    const arena = arena_state.allocator();
    const filled = try fill_formula(arena, template, "1.2.3", "https://x/y.zip", sha);
    try std.testing.expectEqualStrings("1.2.3 https://x/y.zip " ++ sha ++ " 1.2.3", filled);
    try std.testing.expect(std.mem.indexOfScalar(u8, filled, '@') == null);
}

test "a universal binary holds exactly arm64 and x86_64, once each, in either order" {
    // Goal: `lipo -archs` output is accepted only for the two release architectures. Method: the
    // output as lipo prints it (one line, a space between names), then each way it can be wrong:
    // a missing slice, a repeated one, a third architecture, a prefix of a name, and nothing.
    try std.testing.expect(archs_are_universal("x86_64 arm64\n"));
    try std.testing.expect(archs_are_universal("arm64 x86_64\n"));
    try std.testing.expect(!archs_are_universal("arm64\n"));
    try std.testing.expect(!archs_are_universal("x86_64\n"));
    try std.testing.expect(!archs_are_universal("arm64 arm64\n"));
    try std.testing.expect(!archs_are_universal("arm64 x86_64 arm64e\n"));
    try std.testing.expect(!archs_are_universal("arm64e x86_64\n"));
    try std.testing.expect(!archs_are_universal(""));
}

test "the code directory of each slice is read with --architecture, the path last" {
    // Goal: both slices of the archive are compared with the binary's. Method: the words built
    // for each architecture.
    var words: [4][]const u8 = undefined;
    for (architectures) |architecture| {
        const built = cdhash_arguments(architecture, "stage/zcube", &words);
        try std.testing.expectEqual(@as(usize, 4), built.len);
        try std.testing.expectEqualStrings("--architecture", built[1]);
        try std.testing.expectEqualStrings(architecture, built[2]);
        try std.testing.expectEqualStrings("stage/zcube", built[3]);
    }
}

test "only notarytool's missing-profile text counts as a missing profile" {
    const missing = "Error: No Keychain password item found for profile: p\n";
    const offline = "Error: The Internet connection appears to be offline.\n";
    try std.testing.expect(profile_is_missing(missing));
    try std.testing.expect(!profile_is_missing(offline));
    try std.testing.expect(!profile_is_missing(""));
}
