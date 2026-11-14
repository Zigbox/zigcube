//! `zig build packages-check`: every placed file of the output tree agrees with the metadata that
//! names it (apt `Release` and `Packages`, dnf `repomd.xml` and `primary.xml`), and, once the
//! tree is signed, every signature file is there and signs the bytes beside it. With the test key
//! the signatures are checked by recomputing them (Ed25519 is deterministic and the signature
//! time is fixed).
//! The files come from a `Source`, so a test can use memory and the tool can use the disk.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");
const package = @import("package.zig");
const model = package.model;
const rpm = package.rpm;
const openpgp = package.openpgp;
const apt = package.apt;
const release = @import("package_release.zig");

pub const Options = struct {
    /// The tree is expected to carry every signature file (a signed release).
    signatures_required: bool,
    /// Recompute the signatures with the fixed test key and compare.
    test_key: bool,
    /// The tree holds only this architecture's packages (`--arch`, a CI build); null is both.
    only: ?model.Architecture = null,
};

pub const Error = error{CheckFailed} || release.Error;

/// Where the files of the tree come from: `read_fn(context, path)` is the bytes or null, and
/// `list_fn(context, memory)`, when the source has it, is every file the tree holds, so that a
/// file no metadata names (a stray `.deb`, an old rpm) is refused too.
pub const Source = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, path: []const u8) ?[]const u8,
    list_fn: ?*const fn (context: *anyopaque, memory: Allocator) ?[]const []const u8 = null,
};

const Checker = struct {
    source: Source,
    memory: Allocator,
    log: *std.Io.Writer,
    /// The tool's name on each line: `packages-check`, or `packages` when the builder checks.
    name: []const u8 = "packages-check",
    failures: u32 = 0,
    files_checked: u32 = 0,
    /// The issuer fingerprint of the first signature seen: every signature must be by this key.
    first_key: ?[20]u8 = null,
    /// Every rpm must carry a header signature (a signed release is being checked).
    headers_required: bool = false,
    only: ?model.Architecture = null,
    /// Every path the check read: with a listing, any other file is a stray.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn fail(self: *Checker, comptime format: []const u8, arguments: anytype) void {
        self.failures += 1;
        // Nowhere else to report a failed log write.
        self.log.print("{s}: " ++ format ++ "\n", .{self.name} ++ arguments) catch {};
    }

    /// The bytes at `path`, or null, and the path is recorded as one the tree may hold.
    fn fetch(self: *Checker, path: []const u8) error{OutOfMemory}!?[]const u8 {
        const bytes = self.source.read_fn(self.source.context, path) orelse return null;
        if (!self.seen.contains(path)) {
            try self.seen.put(self.memory, try self.memory.dupe(u8, path), {});
        }
        return bytes;
    }

    fn read(self: *Checker, path: []const u8) error{OutOfMemory}!?[]const u8 {
        const bytes = try self.fetch(path);
        if (bytes == null) self.fail("{s} is missing", .{path});
        return bytes;
    }

    fn join(self: *Checker, left: []const u8, right: []const u8) Error![]u8 {
        return std.fmt.allocPrint(self.memory, "{s}{s}", .{ left, right }) catch
            return error.OutOfMemory;
    }

    /// The file at `path` has the digest (and size, when given) the metadata records.
    fn check_file(
        self: *Checker,
        path: []const u8,
        digest: []const u8,
        size: ?u64,
    ) error{OutOfMemory}!?[]const u8 {
        const bytes = try self.read(path) orelse return null;
        self.files_checked += 1;
        if (!std.mem.eql(u8, &model.digest_hex(bytes), digest)) {
            self.fail("{s} does not match its recorded sha256", .{path});
        }
        if (size) |expected| {
            if (expected != bytes.len) self.fail("{s} is not its recorded size", .{path});
        }
        return bytes;
    }
};

fn field(line: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    return line[name.len..];
}

/// `Release` sums every `Packages` file; each `Packages` stanza sums its pool file.
fn check_apt(checker: *Checker, valid_until_required: bool) Error!void {
    const text = try checker.read(release.apt_release_path) orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_sums = false;
    var date: ?[]const u8 = null;
    var valid_until: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "SHA256:")) {
            in_sums = true;
        } else if (field(line, "Date: ")) |value| {
            date = value;
        } else if (field(line, "Valid-Until: ")) |value| {
            valid_until = value;
        } else if (in_sums and line.len > 0 and line[0] == ' ') {
            try check_release_line(checker, line);
        }
    }
    if (!in_sums) checker.fail("{s} has no SHA256 section", .{release.apt_release_path});
    check_validity(checker, date, valid_until, valid_until_required);
}

/// A `Release` with `Valid-Until` has a `Date`, both in the one form the writer uses, and the
/// second is exactly `apt_valid_seconds` after the first. Without `Valid-Until` apt takes the
/// metadata as valid for ever, so a tree checked with the owner's signatures must have it; only
/// the test key and an unsigned round-one tree may lack it (a build with no `-Dsigned-at`).
fn check_validity(
    checker: *Checker,
    date: ?[]const u8,
    valid_until: ?[]const u8,
    required: bool,
) void {
    const until_text = valid_until orelse {
        if (required) {
            checker.fail("{s} has no Valid-Until; build with -Dsigned-at", .{
                release.apt_release_path,
            });
        }
        return;
    };
    const date_text = date orelse
        return checker.fail("{s} has Valid-Until but no Date", .{release.apt_release_path});
    const start = apt.parse_date(date_text) orelse
        return checker.fail("the Release Date is not a date the writer makes", .{});
    const end = apt.parse_date(until_text) orelse
        return checker.fail("the Release Valid-Until is not a date the writer makes", .{});
    if (end != start + constants.apt_valid_seconds) {
        checker.fail("the Release Valid-Until is not 21 days after its Date", .{});
    }
}

fn check_release_line(checker: *Checker, line: []const u8) Error!void {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const digest = words.next() orelse return checker.fail("a Release line is empty", .{});
    const size_text = words.next() orelse
        return checker.fail("a Release line has no size", .{});
    const name = words.next() orelse return checker.fail("a Release line has no name", .{});
    const size = std.fmt.parseInt(u64, size_text, 10) catch
        return checker.fail("a Release size is not a number: {s}", .{size_text});
    const path = try checker.join("apt/dists/zigcube/", name);
    const bytes = try checker.check_file(path, digest, size) orelse return;
    if (std.mem.endsWith(u8, name, "/Packages")) try check_packages(checker, bytes);
}

fn check_packages(checker: *Checker, text: []const u8) Error!void {
    var stanzas = std.mem.splitSequence(u8, text, "\n\n");
    while (stanzas.next()) |stanza| {
        if (std.mem.trim(u8, stanza, "\n").len == 0) continue;
        try check_stanza(checker, stanza);
    }
}

fn check_stanza(checker: *Checker, stanza: []const u8) Error!void {
    var filename: ?[]const u8 = null;
    var size: ?u64 = null;
    var digest: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stanza, '\n');
    while (lines.next()) |line| {
        if (field(line, "Filename: ")) |value| filename = value;
        if (field(line, "SHA256: ")) |value| digest = value;
        if (field(line, "Size: ")) |value| size = std.fmt.parseInt(u64, value, 10) catch null;
    }
    const name = filename orelse return checker.fail("a Packages stanza has no Filename", .{});
    const path = try checker.join("apt/", name);
    if (digest == null or size == null) {
        return checker.fail("the Packages stanza for {s} lacks Size or SHA256", .{path});
    }
    _ = try checker.check_file(path, digest.?, size.?);
}

/// `repomd.xml` sums each metadata file; `primary.xml` sums each rpm.
fn check_dnf(checker: *Checker, index: usize) Error!void {
    const arch = release.architectures[index].rpm_name();
    const base = try std.fmt.allocPrint(checker.memory, "rpm/zigcube/{s}/", .{arch});
    const path = try checker.join(base, "repodata/repomd.xml");
    const text = try checker.read(path) orelse return;
    var digest: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        const open = "<checksum type=\"sha256\">";
        if (std.mem.startsWith(u8, line, open)) {
            const end = std.mem.indexOf(u8, line, "</checksum>") orelse continue;
            digest = line[open.len..end];
        }
        const location = "<location href=\"";
        if (std.mem.startsWith(u8, line, location)) {
            const end = std.mem.indexOfPos(u8, line, location.len, "\"") orelse continue;
            const name = try checker.join(base, line[location.len..end]);
            const bytes = try checker.check_file(name, digest, null) orelse continue;
            if (std.mem.endsWith(u8, name, "-primary.xml.gz")) {
                try check_primary(checker, base, bytes);
            }
        }
    }
    if (digest.len == 0) checker.fail("{s} records no checksum", .{path});
}

fn check_primary(checker: *Checker, base: []const u8, gzipped: []const u8) Error!void {
    var input: std.Io.Reader = .fixed(gzipped);
    var window: [constants.package_gzip_window_bytes]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    const text = decompress.reader.allocRemaining(
        checker.memory,
        .limited(constants.repo_metadata_bytes_max),
    ) catch return checker.fail("{s}primary.xml.gz does not decompress", .{base});
    const marker = "pkgid=\"YES\">";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, marker)) |at| {
        const start = at + marker.len;
        const digest = text[start..@min(text.len, start + 64)];
        const location = "<location href=\"";
        const where = std.mem.indexOfPos(u8, text, start, location) orelse
            return checker.fail("a primary.xml package has no location", .{});
        const name_start = where + location.len;
        const name_end = std.mem.indexOfPos(u8, text, name_start, "\"") orelse
            return checker.fail("a primary.xml location is not closed", .{});
        const path = try checker.join(base, text[name_start..name_end]);
        if (try checker.check_file(path, digest, null)) |found| try check_rpm(checker, path, found);
        from = name_end;
    }
}

fn check_rpm(checker: *Checker, path: []const u8, bytes: []const u8) error{OutOfMemory}!void {
    const parts = rpm.split(bytes) orelse return checker.fail("{s} is not an rpm", .{path});
    if (!std.mem.endsWith(u8, path, ".rpm")) checker.fail("{s} is not named .rpm", .{path});
    if (parts.payload.len == 0) checker.fail("{s} has no payload", .{path});
    try check_header_signature(checker, path, parts);
}

/// An rpm's header signature (RPMSIGTAG_OPENPGP, 268) signs this rpm's main header, which
/// `to-sign/<rpm>.header` holds, and is by the same key as every other signature. A missing tag
/// is refused only when a signed release is expected; a tag that signs other bytes always is.
fn check_header_signature(
    checker: *Checker,
    path: []const u8,
    parts: rpm.Parts,
) error{OutOfMemory}!void {
    // The builder writes every rpm's header for round 1, signed or not.
    const name = std.fs.path.basename(path);
    const header_path = try std.fmt.allocPrint(checker.memory, "to-sign/{s}.header", .{name});
    const header = try checker.fetch(header_path) orelse
        return checker.fail("{s} is missing", .{header_path});
    if (!std.mem.eql(u8, header, parts.main_header)) {
        return checker.fail("{s} is not the header of {s}", .{ header_path, path });
    }
    const signature = rpm.binary_tag(parts.signature_header, rpm.sig_tag.rsa) orelse {
        if (checker.headers_required) {
            checker.fail("{s} has no header signature (sign round 1 is missing)", .{path});
        }
        return;
    };
    switch (openpgp.bound_binary(signature, header)) {
        .stale => checker.fail(
            "the header signature in {s} does not sign its header (stale or swapped " ++
                ".header.sig?); sign round 1 again into an empty signatures directory",
            .{path},
        ),
        .several => checker.fail(
            "the header signature in {s} holds more than one signature; sign with one key",
            .{path},
        ),
        .unsupported => checker.fail(
            "the header signature in {s} is not a v4 signature with a SHA-2 digest; use a " ++
                "v4 key (not Ed448) and not SHA-1",
            .{path},
        ),
        .bound => |bound| note_key(checker, path, bound.fingerprint),
    }
}

fn note_key(checker: *Checker, path: []const u8, print: ?[20]u8) void {
    const found = print orelse {
        if (checker.headers_required) {
            checker.fail("{s} has a signature that names no issuer fingerprint", .{path});
        }
        return;
    };
    const first = checker.first_key orelse {
        checker.first_key = found;
        return;
    };
    if (!std.mem.eql(u8, &first, &found)) {
        checker.fail("{s} was signed by a different key than the other signatures", .{path});
    }
}

/// A signed release has all four round-2 signature files, each a signature over the bytes it
/// sits beside (`openpgp.bound_to`), all by one key. With `required` false a missing file is
/// skipped: the builder checks the files the owner has placed so far.
fn check_signature_files(checker: *Checker, required: bool) Error!void {
    const release_bytes = try checker.fetch(release.apt_release_path);
    const apt_files = [_]struct { []const u8, openpgp.Form }{
        .{ release.apt_in_release_path, .clearsigned },
        .{ release.apt_release_gpg_path, .armored_detached },
    };
    for (apt_files) |entry| {
        const signed = release.apt_release_path;
        try check_bound(checker, entry[0], signed, release_bytes, entry[1], required);
    }
    for (0..release.architectures.len) |index| {
        if (!release.included(checker.only, index)) continue;
        const repomd = try release.repomd_path(checker.memory, index);
        const bytes = try checker.fetch(repomd);
        const path = try checker.join(repomd, ".asc");
        try check_bound(checker, path, repomd, bytes, .armored_detached, required);
    }
}

fn check_bound(
    checker: *Checker,
    path: []const u8,
    signed_path: []const u8,
    signed: ?[]const u8,
    form: openpgp.Form,
    required: bool,
) Error!void {
    const file = try checker.fetch(path) orelse {
        if (required) checker.fail("{s} is missing", .{path});
        return;
    };
    const bytes = signed orelse return; // The signed file's own absence is reported elsewhere.
    switch (try openpgp.bound_to(checker.memory, form, file, bytes)) {
        .stale => checker.fail(
            "{s} is not a signature of {s} (stale or swapped?); sign again into an empty " ++
                "signatures directory",
            .{ path, signed_path },
        ),
        .several => checker.fail(
            "{s} holds more than one signature; sign with one key (one -u)",
            .{path},
        ),
        .unsupported => checker.fail(
            "{s} is not a v4 signature with a SHA-2 digest; use a v4 key (not Ed448), not SHA-1",
            .{path},
        ),
        .bound => |bound| note_key(checker, path, bound.fingerprint),
    }
}

/// The signature files the owner placed, checked while the builder still holds the tree in
/// memory: nothing is written when one of them signs other bytes.
pub fn check_placed_signatures(
    files: []const model.TreeFile,
    memory: Allocator,
    log: *std.Io.Writer,
) Error!void {
    var tree: TreeSource = .{ .files = files };
    var checker: Checker = .{
        .source = tree.source(),
        .memory = memory,
        .log = log,
        .name = "packages",
    };
    try check_placed_headers(&checker, files);
    try check_signature_files(&checker, false);
    if (checker.failures > 0) return error.CheckFailed;
}

fn is_rpm_path(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "rpm/") and std.mem.endsWith(u8, path, ".rpm");
}

/// The rpms of the tree being built: a signature on one binds to its header, and once any
/// signature is placed (a header signature, or a round-2 file) every rpm must have one.
fn check_placed_headers(checker: *Checker, files: []const model.TreeFile) Error!void {
    var any = false;
    for (files) |file| {
        if (!is_rpm_path(file.path)) continue;
        const parts = rpm.split(file.bytes) orelse continue;
        if (rpm.binary_tag(parts.signature_header, rpm.sig_tag.rsa) != null) any = true;
    }
    for (files) |file| {
        const name = std.fs.path.basename(file.path);
        if (std.mem.eql(u8, name, "InRelease") or std.mem.eql(u8, name, "Release.gpg") or
            std.mem.endsWith(u8, name, ".xml.asc")) any = true;
    }
    checker.headers_required = any;
    for (files) |file| {
        if (!is_rpm_path(file.path)) continue;
        const parts = rpm.split(file.bytes) orelse continue;
        check_header_signature(checker, file.path, parts) catch return error.OutOfMemory;
    }
}

fn expect_signature(
    checker: *Checker,
    path: []const u8,
    expected: []const u8,
) error{OutOfMemory}!void {
    const found = try checker.read(path) orelse return;
    if (!std.mem.eql(u8, found, expected)) {
        checker.fail("{s} is not the test key's signature", .{path});
    }
}

fn check_test_signatures(checker: *Checker) Error!void {
    const key = openpgp.test_key();
    const memory = checker.memory;
    const text = try checker.read(release.apt_release_path) orelse return;
    const detached = try openpgp.sign_detached(memory, key, text);
    const in_release = try openpgp.clearsign(memory, key, text);
    try expect_signature(checker, release.apt_in_release_path, in_release);
    const release_gpg = try openpgp.armor(memory, "PGP SIGNATURE", detached);
    try expect_signature(checker, release.apt_release_gpg_path, release_gpg);
    for (0..release.architectures.len) |index| {
        if (!release.included(checker.only, index)) continue;
        const path = try release.repomd_path(memory, index);
        const repomd = try checker.read(path) orelse continue;
        const signed = try openpgp.sign_detached(memory, key, repomd);
        const armored = try openpgp.armor(memory, "PGP SIGNATURE", signed);
        try expect_signature(checker, try checker.join(path, ".asc"), armored);
    }
}

/// The test key's public files are the fixed key's, and only a test-key tree has them: a garbage
/// key file, or the test key beside the owner's signatures, is refused.
fn check_test_key_files(checker: *Checker, test_key: bool) Error!void {
    const public = try openpgp.public_key_packets(checker.memory, openpgp.test_key());
    const armored = try openpgp.armor(checker.memory, "PGP PUBLIC KEY BLOCK", public);
    const files = [_]struct { []const u8, []const u8 }{
        .{ release.test_key_binary_path, public },
        .{ release.test_key_armored_path, armored },
    };
    for (files) |entry| {
        if (test_key) {
            const found = try checker.read(entry[0]) orelse continue;
            if (!std.mem.eql(u8, found, entry[1])) {
                checker.fail("{s} is not the test key", .{entry[0]});
            }
        } else if (try checker.fetch(entry[0]) != null) {
            checker.fail("{s} is the test key's file, and the tree is not test-signed", .{
                entry[0],
            });
        }
    }
}

/// With a listing, every file of the tree is one the check read: a `.deb` or `.rpm` no metadata
/// names, or any other file the builder does not write, is refused.
fn check_strays(checker: *Checker) void {
    const list_fn = checker.source.list_fn orelse return;
    const paths = list_fn(checker.source.context, checker.memory) orelse
        return checker.fail("the tree cannot be listed", .{});
    for (paths) |path| {
        if (checker.seen.contains(path)) continue;
        checker.fail("{s} is not part of the tree (a stray file? rebuild into an empty " ++
            "directory)", .{path});
    }
}

/// Checks a whole tree. Every problem is one line on `log`; `error.CheckFailed` when any.
pub fn check(
    source: Source,
    memory: Allocator,
    log: *std.Io.Writer,
    options: Options,
) Error!void {
    var checker: Checker = .{
        .source = source,
        .memory = memory,
        .log = log,
        .headers_required = options.signatures_required,
        .only = options.only,
    };
    try check_apt(&checker, options.signatures_required and !options.test_key);
    for (0..release.architectures.len) |index| {
        if (release.included(options.only, index)) try check_dnf(&checker, index);
    }
    // Signature files a round-one tree already holds are checked too, required or not.
    try check_signature_files(&checker, options.signatures_required);
    if (options.test_key) try check_test_signatures(&checker);
    try check_test_key_files(&checker, options.test_key);
    check_strays(&checker);
    if (checker.files_checked == 0) assert(checker.failures > 0);
    if (checker.failures > 0) return error.CheckFailed;
}

/// A tree in memory: the builder checks it before writing, and the tests use it.
pub const TreeSource = struct {
    files: []const model.TreeFile,

    fn read(context: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *TreeSource = @ptrCast(@alignCast(context));
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.bytes;
        }
        return null;
    }

    fn list(context: *anyopaque, memory: Allocator) ?[]const []const u8 {
        const self: *TreeSource = @ptrCast(@alignCast(context));
        const paths = memory.alloc([]const u8, self.files.len) catch return null;
        for (self.files, paths) |file, *path| path.* = file.path;
        return paths;
    }

    pub fn source(self: *TreeSource) Source {
        return .{ .context = self, .read_fn = read, .list_fn = list };
    }
};

const test_inputs = release.sample_inputs;
test "a built tree passes, and flipping one byte of a placed rpm fails" {
    // Goal: the check accepts what the builder writes and notices a changed file.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const files = try release.build(memory, &test_inputs, .{ .test_key = true });
    var sink: std.Io.Writer.Allocating = .init(memory);
    var source: TreeSource = .{ .files = files };
    const strict: Options = .{ .signatures_required = true, .test_key = true };
    try check(source.source(), memory, &sink.writer, strict);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);

    const tampered = try memory.dupe(model.TreeFile, files);
    for (tampered) |*file| {
        if (std.mem.endsWith(u8, file.path, ".rpm")) {
            const copy = try memory.dupe(u8, file.bytes);
            copy[copy.len - 1] ^= 1;
            file.bytes = copy;
            break;
        }
    }
    source = .{ .files = tampered };
    try std.testing.expectError(
        error.CheckFailed,
        check(source.source(), memory, &sink.writer, strict),
    );
    const message = "does not match its recorded sha256";
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
}

test "an unsigned tree passes unless signatures are required" {
    // Goal: round one's output is checkable, and a release without its signatures is refused.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const files = try release.build(memory, &test_inputs, .{});
    var sink: std.Io.Writer.Allocating = .init(memory);
    var source: TreeSource = .{ .files = files };
    const loose: Options = .{ .signatures_required = false, .test_key = false };
    try check(source.source(), memory, &sink.writer, loose);
    const strict: Options = .{ .signatures_required = true, .test_key = false };
    try std.testing.expectError(
        error.CheckFailed,
        check(source.source(), memory, &sink.writer, strict),
    );
    const message = "apt/dists/zigcube/InRelease is missing";
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
}

/// The signatures a test-key build made, as the owner's `Signatures` input: the repository trees
/// embed the header signatures, so the round-2 signatures only match a build that has them too.
fn signatures_of(memory: Allocator, files: []const model.TreeFile) !release.Signatures {
    var signatures: release.Signatures = .{};
    for (files) |file| {
        if (std.mem.startsWith(u8, file.path, "to-sign/")) {
            for (0..release.architectures.len * release.kinds.len) |index| {
                const kind = release.kinds[index % release.kinds.len];
                const name = try release.rpm_file_name(
                    memory,
                    &test_inputs,
                    kind,
                    index / release.kinds.len,
                );
                const want = try std.fmt.allocPrint(memory, "to-sign/{s}.header", .{name});
                if (!std.mem.eql(u8, file.path, want)) continue;
                signatures.header[index] =
                    try openpgp.sign_detached(memory, openpgp.test_key(), file.bytes);
            }
        }
        if (std.mem.eql(u8, file.path, release.apt_in_release_path)) {
            signatures.in_release = file.bytes;
        }
        if (std.mem.eql(u8, file.path, release.apt_release_gpg_path)) {
            signatures.release_gpg = file.bytes;
        }
        for (0..release.architectures.len) |index| {
            var buffer: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&buffer, "rpm/zigcube/{s}/repodata/repomd.xml.asc", .{
                release.architectures[index].rpm_name(),
            }) catch unreachable; // A fixed short name.
            if (std.mem.eql(u8, file.path, name)) signatures.repomd_asc[index] = file.bytes;
        }
    }
    return signatures;
}

/// A tree the owner signed carries Valid-Until, so these trees are built with a signing time.
const stamp: u64 = 1_800_000_000;

test "a swapped or stale round-2 signature is refused, a matching one is placed" {
    // Goal: the owner's signature files are tied to the bytes they sign. Signatures made over
    // another release, or the two repomd signatures swapped, are refused with one line each.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const signed = try release.build(memory, &test_inputs, .{
        .test_key = true,
        .signed_at = stamp,
    });
    var sink: std.Io.Writer.Allocating = .init(memory);

    const good = try signatures_of(memory, signed);
    const placed = try release.build(memory, &test_inputs, .{
        .signatures = good,
        .signed_at = stamp,
    });
    try check_placed_signatures(placed, memory, &sink.writer);
    var tree: TreeSource = .{ .files = placed };
    const strict: Options = .{ .signatures_required = true, .test_key = false };
    try check(tree.source(), memory, &sink.writer, strict);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);

    var swapped = good;
    swapped.repomd_asc = .{ good.repomd_asc[1], good.repomd_asc[0] };
    const crossed = try release.build(memory, &test_inputs, .{
        .signatures = swapped,
        .signed_at = stamp,
    });
    try std.testing.expectError(
        error.CheckFailed,
        check_placed_signatures(crossed, memory, &sink.writer),
    );
    const message = "rpm/zigcube/x86_64/repodata/repomd.xml.asc is not a signature of " ++
        "rpm/zigcube/x86_64/repodata/repomd.xml (stale or swapped?)";
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
    tree = .{ .files = crossed };
    const refused = check(tree.source(), memory, &sink.writer, strict);
    try std.testing.expectError(error.CheckFailed, refused);

    var other = test_inputs;
    other.version = "1.2.4";
    other.license = "x\n";
    const stale = try release.build(memory, &other, .{
        .signatures = good,
        .signed_at = stamp,
    });
    try std.testing.expectError(
        error.CheckFailed,
        check_placed_signatures(stale, memory, &sink.writer),
    );
}

test "swapped, missing or half-placed rpm header signatures are refused" {
    // Goal: round 1 is bound like round 2. Header signatures swapped between the rpms, or none
    // beside signed round-2 files, give a refusal before anything is written, and the same tree
    // fails `check`. This test failed before the fix: both were reported as signed.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const signed = try release.build(memory, &test_inputs, .{
        .test_key = true,
        .signed_at = stamp,
    });
    var sink: std.Io.Writer.Allocating = .init(memory);
    const good = try signatures_of(memory, signed);
    const strict: Options = .{ .signatures_required = true, .test_key = false };

    var swapped = good;
    swapped.header = good.header;
    std.mem.swap(?[]const u8, &swapped.header[0], &swapped.header[1]);
    const crossed = try release.build(memory, &test_inputs, .{
        .signatures = swapped,
        .signed_at = stamp,
    });
    try std.testing.expectError(
        error.CheckFailed,
        check_placed_signatures(crossed, memory, &sink.writer),
    );
    const message = "does not sign its header (stale or swapped .header.sig?)";
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
    var tree: TreeSource = .{ .files = crossed };
    const refused = check(tree.source(), memory, &sink.writer, strict);
    try std.testing.expectError(error.CheckFailed, refused);

    sink.clearRetainingCapacity();
    var none = good;
    none.header = @splat(null);
    const unsigned = try release.build(memory, &test_inputs, .{
        .signatures = none,
        .signed_at = stamp,
    });
    try std.testing.expectError(
        error.CheckFailed,
        check_placed_signatures(unsigned, memory, &sink.writer),
    );
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "has no header signature") != null);
    tree = .{ .files = unsigned };
    const refused_again = check(tree.source(), memory, &sink.writer, strict);
    try std.testing.expectError(error.CheckFailed, refused_again);

    sink.clearRetainingCapacity();
    var half: release.Signatures = .{};
    half.header[0] = good.header[0];
    const partial = try release.build(memory, &test_inputs, .{
        .signatures = half,
        .signed_at = stamp,
    });
    try std.testing.expectError(
        error.CheckFailed,
        check_placed_signatures(partial, memory, &sink.writer),
    );
    // Round 1 alone, every header signed and no round-2 file yet, is the normal first state.
    sink.clearRetainingCapacity();
    var round_one: release.Signatures = .{};
    round_one.header = good.header;
    const first = try release.build(memory, &test_inputs, .{
        .signatures = round_one,
        .signed_at = stamp,
    });
    try check_placed_signatures(first, memory, &sink.writer);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}

test "a Release without Valid-Until is refused under the owner's signatures only" {
    // Goal: a release signed without -Dsigned-at cannot pass packages-check; the test key may.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const files = try release.build(memory, &test_inputs, .{});
    var sink: std.Io.Writer.Allocating = .init(memory);
    var source: TreeSource = .{ .files = files };
    const owner: Options = .{ .signatures_required = true, .test_key = false };
    const refused = check(source.source(), memory, &sink.writer, owner);
    try std.testing.expectError(error.CheckFailed, refused);
    const message = "has no Valid-Until; build with -Dsigned-at";
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
    const loose: Options = .{ .signatures_required = false, .test_key = false };
    sink.clearRetainingCapacity();
    try check(source.source(), memory, &sink.writer, loose);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}

fn expect_refused(
    memory: Allocator,
    files: []const model.TreeFile,
    options: Options,
    message: []const u8,
) !void {
    var sink: std.Io.Writer.Allocating = .init(memory);
    var source: TreeSource = .{ .files = files };
    const refused = check(source.source(), memory, &sink.writer, options);
    try std.testing.expectError(error.CheckFailed, refused);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), message) != null);
}

test "a stray package, a garbage test key, or the test key beside the owner's are refused" {
    // Goal: packages-check reads the whole tree. A .deb or .rpm no metadata names, a
    // zigbox-test-key.asc that is not the test key, and a test key file in a tree that is not
    // test-signed each fail with a line naming the file. Before the fix all three passed.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const strict: Options = .{ .signatures_required = true, .test_key = true };
    const files = try release.build(memory, &test_inputs, .{ .test_key = true });
    for ([_][]const u8{ "apt/pool/main/z/zcube/old.deb", "rpm/zigcube/x86_64/old.rpm" }) |path| {
        var stray: std.ArrayList(model.TreeFile) = .empty;
        try stray.appendSlice(memory, files);
        try stray.append(memory, .{ .path = path, .bytes = "x" });
        try expect_refused(memory, stray.items, strict, "is not part of the tree");
    }
    const garbage = try memory.dupe(model.TreeFile, files);
    for (garbage) |*file| {
        if (std.mem.eql(u8, file.path, release.test_key_armored_path)) file.bytes = "garbage";
    }
    try expect_refused(memory, garbage, strict, "zigbox-test-key.asc is not the test key");

    var unsigned: std.ArrayList(model.TreeFile) = .empty;
    try unsigned.appendSlice(memory, try release.build(memory, &test_inputs, .{}));
    for (files) |file| {
        if (std.mem.startsWith(u8, file.path, "zigbox-test-key")) try unsigned.append(memory, file);
    }
    const loose: Options = .{ .signatures_required = false, .test_key = false };
    try expect_refused(memory, unsigned.items, loose, "the tree is not test-signed");
}

test "a one-architecture tree checks with --arch, and fails as a whole release" {
    // Goal: CI builds only the runner's architecture; the check accepts that tree when told,
    // and a release (no --arch) still needs both.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const files = try release.build(memory, &test_inputs, .{ .test_key = true, .only = .x86_64 });
    var sink: std.Io.Writer.Allocating = .init(memory);
    var source: TreeSource = .{ .files = files };
    const one: Options = .{ .signatures_required = true, .test_key = true, .only = .x86_64 };
    try check(source.source(), memory, &sink.writer, one);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
    const whole: Options = .{ .signatures_required = true, .test_key = true };
    try expect_refused(memory, files, whole, "rpm/zigcube/aarch64/repodata/repomd.xml is missing");
}
