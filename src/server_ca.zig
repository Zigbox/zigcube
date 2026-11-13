//! The server's half of the cluster CA (docs/peer.md, "Trust model"). Shell code: it reads and
//! writes the state directory. The core's half, what to sign and for whom, is `peer_ca.zig`.
//!
//! `ca.key` is the Ed25519 seed, made on the first start (mode 0600) and loaded afterwards. A
//! server with no state directory (a memory store) makes a fresh CA in memory each start and
//! says so on stderr: its agents join again. `revoked` is read once, at start.

const std = @import("std");
const secure_random = @import("secure_random.zig");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const peer_ca = @import("peer_ca.zig");
const x509 = @import("x509.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const key_file = "ca.key";
pub const revoked_file = "revoked";
pub const key_name_bytes_max = 64;
pub const cert_extension = ".crt";

const pem_begin = "-----BEGIN CERTIFICATE-----\n";
const pem_end = "-----END CERTIFICATE-----\n";
const pem_line_bytes = 64;
/// The longest PEM file of a CA certificate: its base64 with a newline per line, and the lines
/// around it. One more byte than the file `files.read` accepts, so that it can say "too long".
const pem_bytes_max = pem_begin.len + pem_end.len +
    (constants.x509_cert_bytes_max + 2) / 3 * 4 + constants.x509_cert_bytes_max / 45 + 2;

pub const Error = files.Error || error{ OutOfMemory, Canceled };

/// A CA certificate with less than this left is made again at the next start.
const renew_ahead_ms: u64 = 30 * 24 * 60 * 60 * 1000;

pub const memory_notice = "zcube-server: no state directory, so the peer CA key lives in memory " ++
    "only; agents will join again after a restart\n";

/// What `open` needs to know about the store it serves.
pub const Options = struct {
    /// The key's file in the state directory. One per store (`key_name_for`): two stores that
    /// share a directory must not share a CA, or a node of one could join the other.
    key_name: []const u8 = key_file,
    /// True when the state directory holds nothing of this store yet (no remembered pair): only
    /// then is a missing key made without being asked. Anywhere else a missing key means the
    /// directory was damaged, and a new CA would silently lock out every agent for up to a day.
    first_start: bool = true,
    /// `--new-ca`: make a new CA although the store has run before.
    accept_new: bool = false,
    /// Say nothing on stderr (tests).
    quiet: bool = false,
};

/// The key file for a store: `ca.key` for a store with no file of its own (memory, Postgres), or
/// `ca-<16 hex digits of a hash of the database's absolute path>.key`, the way the remembered
/// file is keyed (`server_remember.zig`). The name is in `buffer`.
pub fn key_name_for(database: ?[]const u8, buffer: *[key_name_bytes_max]u8) []const u8 {
    const path = database orelse return std.fmt.bufPrint(buffer, "{s}", .{key_file}) catch
        unreachable; // 6 bytes.
    assert(std.fs.path.isAbsolute(path));
    return std.fmt.bufPrint(buffer, "ca-{x:0>16}.key", .{std.hash.Wyhash.hash(0, path)}) catch
        unreachable; // 3 + 16 + 4 bytes.
}

/// The CA certificate's file beside the key: `<key name without ".key">.crt`, so `ca.key` has
/// `ca.crt` and `ca-<hash>.key` has `ca-<hash>.crt`. The name is in `buffer`.
pub fn cert_name_for(key_name: []const u8, buffer: *[key_name_bytes_max]u8) []const u8 {
    assert(std.mem.endsWith(u8, key_name, ".key"));
    const stem = key_name[0 .. key_name.len - ".key".len];
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ stem, cert_extension }) catch
        unreachable; // The key name fits `key_name_bytes_max` and `.crt` is as long as `.key`.
}

/// A CA key for a server with no state directory: from the kernel only (ZC-E0821 if it fails).
fn memory_key(io: std.Io, diag: *Diag) Error!Ed25519.KeyPair {
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    // A seed that gives the identity element has a chance of about 2^-250; draw another.
    while (true) {
        secure_random.fill(io, &seed, diag, "the CA key") catch |err| return switch (err) {
            error.Unavailable => error.Failed,
            error.Canceled => error.Canceled,
        };
        return Ed25519.KeyPair.generateDeterministic(seed) catch continue;
    }
}

/// Fills `ca` from `state_dir` (created if needed), or makes one in memory when it is null and
/// writes `memory_notice` to stderr unless quiet. On failure `diag` says why (ZC-E0806).
pub fn open(
    ca: *peer_ca.Ca,
    gpa: Allocator,
    io: std.Io,
    state_dir: ?[]const u8,
    wall: Clock,
    options: Options,
    diag: *Diag,
) Error!void {
    assert(diag.code == null);
    ca.wall = wall;
    ca.revoked = .{};
    const path = state_dir orelse {
        ca.key = try memory_key(io, diag);
        if (options.quiet) return;
        std.Io.File.stderr().writeStreamingAll(io, memory_notice) catch {}; // Nowhere else.
        return;
    };
    const cwd = std.Io.Dir.cwd();
    files.make_dir(io, path) catch |err| {
        const verb = "create the directory for";
        return files.unusable(diag, path, options.key_name, verb, @errorName(err));
    };
    var dir = cwd.openDir(io, path, .{}) catch |err| {
        const verb = "open the directory of";
        return files.unusable(diag, path, options.key_name, verb, @errorName(err));
    };
    defer dir.close(io);
    try files.check_dir(io, dir, path, options.key_name, diag);
    ca.key = try load_or_make_key(io, dir, path, options, diag);
    try ensure_certificate(ca, io, dir, path, options.key_name, diag);
    try read_revoked(ca, gpa, io, dir, path, diag);
}

/// Makes sure `<key name>.crt` holds this key's CA certificate, valid now: a file that is absent,
/// is not our PEM, names another key (after `--new-ca`) or has expired or
/// will within `renew_ahead_ms` is made again. The file is
/// derived from the key, so there is nothing to lose by replacing it; but it is a trust anchor
/// for the services that pin it, so it is read and written under the key's rule (a directory
/// others cannot write, mode 0600; ZC-E0806). Nothing reads it back for the server's own use.
fn ensure_certificate(
    ca: *const peer_ca.Ca,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    key_name: []const u8,
    diag: *Diag,
) Error!void {
    var name_buffer: [key_name_bytes_max]u8 = undefined;
    const name = cert_name_for(key_name, &name_buffer);
    var text: [pem_bytes_max]u8 = undefined;
    // A file too long for a certificate of ours is not ours: it is replaced, like any other text.
    const found = try files.read_bounded(io, dir, path, name, .secret, &text, diag);
    if (found == .bytes) {
        const existing = found.bytes;
        var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
        if (pem_decode(existing, &der_buffer)) |bytes| {
            // Judged a month ahead, so a certificate near its end is made again while services
            // that pin it still have time to take the new file.
            const later_ms = ca.wall.now_ms() +| renew_ahead_ms;
            _ = x509.verify(bytes, ca.public(), later_ms, .{ .kind = .ca, .name = null }) catch {
                return write_certificate(ca, io, dir, path, name, diag);
            };
            return;
        }
    }
    return write_certificate(ca, io, dir, path, name, diag);
}

fn write_certificate(
    ca: *const peer_ca.Ca,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    name: []const u8,
    diag: *Diag,
) Error!void {
    var certificate: x509.Der = .{};
    ca.issue_ca_certificate(&certificate, constants.x509_ca_ttl_ms_max) catch |err| {
        diag.raise(peer_ca.code_of(err));
        diag.cause("can't make the CA certificate {s} in {s}: {s}", .{
            name, path, peer_ca.reason(err),
        });
        diag.fix(.{ .sentence = "set the clock; the certificate is made again at the next start" });
        return error.Failed;
    };
    var text: [pem_bytes_max]u8 = undefined;
    const pem = pem_encode(&text, certificate.slice());
    return files.write(io, dir, path, name, pem, 0o600, diag);
}

/// `bytes` as one PEM CERTIFICATE block: 64 base64 characters a line, a newline after each.
fn pem_encode(out: *[pem_bytes_max]u8, bytes: []const u8) []const u8 {
    assert(bytes.len > 0);
    assert(bytes.len <= constants.x509_cert_bytes_max);
    var base64: [(constants.x509_cert_bytes_max + 2) / 3 * 4]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&base64, bytes);
    var writer: std.Io.Writer = .fixed(out);
    writer.writeAll(pem_begin) catch unreachable; // `pem_bytes_max` holds it.
    var at: usize = 0;
    while (at < encoded.len) : (at += pem_line_bytes) {
        const line = encoded[at..@min(at + pem_line_bytes, encoded.len)];
        writer.print("{s}\n", .{line}) catch unreachable; // Sized by `pem_bytes_max`.
    }
    writer.writeAll(pem_end) catch unreachable; // Sized by `pem_bytes_max`.
    return writer.buffered();
}

/// The DER inside a PEM block exactly as `pem_encode` writes it, or null: any other text
/// (extra blocks, other line lengths, trailing bytes) is not ours and is replaced.
fn pem_decode(text: []const u8, out: *[constants.x509_cert_bytes_max]u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, pem_begin)) return null;
    if (!std.mem.endsWith(u8, text, pem_end)) return null;
    const body = text[pem_begin.len .. text.len - pem_end.len];
    var base64: [(constants.x509_cert_bytes_max + 2) / 3 * 4]u8 = undefined;
    var length: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len > pem_line_bytes) return null;
        if (length + line.len > base64.len) return null;
        @memcpy(base64[length..][0..line.len], line);
        length += line.len;
    }
    const decoded_length = std.base64.standard.Decoder.calcSizeForSlice(base64[0..length]) catch
        return null;
    if (decoded_length == 0) return null;
    if (decoded_length > out.len) return null;
    std.base64.standard.Decoder.decode(out, base64[0..length]) catch return null;
    var again: [pem_bytes_max]u8 = undefined;
    if (!std.mem.eql(u8, pem_encode(&again, out[0..decoded_length]), text)) return null;
    return out[0..decoded_length];
}

fn load_or_make_key(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    options: Options,
    diag: *Diag,
) Error!Ed25519.KeyPair {
    const name = options.key_name;
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (try files.read_seed(io, dir, path, name, diag)) |loaded| {
        seed = loaded;
        return Ed25519.KeyPair.generateDeterministic(seed) catch
            return files.unusable(diag, path, name, "use", "it is not a usable key seed");
    }
    if (!options.first_start and !options.accept_new) {
        diag.raise(.E0806);
        diag.cause("can't find the CA key {s} in {s}", .{ name, path });
        diag.cause("this store has run here before: a new CA would lock out every agent", .{});
        diag.fix(.{
            .sentence = "put the key back from a backup, or accept a new CA on purpose " ++
                "(every agent then joins again)",
            .command = "zcube-server --new-ca",
        });
        return error.Failed;
    }
    // A seed that gives the identity element has a chance of about 2^-250; draw another.
    while (true) {
        secure_random.fill(io, &seed, diag, "the CA key") catch |err| return switch (err) {
            error.Unavailable => error.Failed,
            error.Canceled => error.Canceled,
        };
        const key = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        try files.write_seed(io, dir, path, name, seed, diag);
        return key;
    }
}

fn read_revoked(
    ca: *peer_ca.Ca,
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    diag: *Diag,
) Error!void {
    const buffer = try gpa.alloc(u8, constants.peer_file_bytes_max + 1);
    defer gpa.free(buffer);
    const text = try files.read(io, dir, path, revoked_file, .anchor, buffer, diag) orelse return;
    ca.revoked.parse(text) catch |err| {
        const why = switch (err) {
            error.BadName => "a line is not a node name",
            error.TooMany => "it names more nodes than the server keeps",
        };
        var line_buffer: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&line_buffer, "line {d}: {s}", .{
            ca.revoked.bad_line, why,
        }) catch why;
        const fix = "write one node name per line in revoked, or delete the file";
        return files.unusable_fix(diag, path, revoked_file, "parse", detail, fix);
    };
}

const TestDir = struct {
    tmp: std.testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_length: u32 = 0,

    fn make(io: std.Io) !TestDir {
        var dir: TestDir = .{ .tmp = std.testing.tmpDir(.{}) };
        // `tmpDir` makes the directory under the runner's umask: under 002 (a user's login
        // umask with a private group) it is group-writable, which `check_dir` refuses. Set the
        // mode a state directory is meant to have, so no test depends on the umask.
        try dir.tmp.dir.setFilePermissions(io, ".", .fromMode(0o700), .{});
        dir.path_length = @intCast(try dir.tmp.dir.realPath(io, &dir.path_buffer));
        return dir;
    }

    fn path(dir: *const TestDir) []const u8 {
        return dir.path_buffer[0..dir.path_length];
    }
};

fn open_test(dir: *const TestDir, ca: *peer_ca.Ca, options: Options, diag: *Diag) Error!void {
    var clock = FixedClock{};
    const io = std.testing.io;
    return open(ca, std.testing.allocator, io, dir.path(), clock.clock(), options, diag);
}

test "the CA key is made once, kept across a restart, and a bad revoked file is refused" {
    // Goal: persistence and the refusals of docs/peer.md. Method: open twice over one directory
    // and compare keys; remove a node by file; then break the file.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var first: peer_ca.Ca = undefined;
    try open_test(&dir, &first, .{ .quiet = true }, &diag);
    var second: peer_ca.Ca = undefined;
    try open_test(&dir, &second, .{ .quiet = true, .first_start = false }, &diag);
    try std.testing.expectEqualSlices(u8, &first.public(), &second.public());
    try std.testing.expectEqual(@as(u32, 0), second.revoked.count);

    // Made 0600 whatever the umask: `read` refuses a revoked file other users can write.
    const secret: std.Io.Dir.CreateFileOptions = .{ .permissions = .fromMode(0o600) };
    try dir.tmp.dir.writeFile(io, .{
        .sub_path = revoked_file,
        .data = "# out\nnode3\n",
        .flags = secret,
    });
    try open_test(&dir, &second, .{ .quiet = true }, &diag);
    try std.testing.expect(second.revoked.contains("node3"));

    try dir.tmp.dir.writeFile(io, .{ .sub_path = revoked_file, .data = "node3\nNOT A NAME\n" });
    try std.testing.expectError(error.Failed, open_test(&dir, &second, .{ .quiet = true }, &diag));
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0806, diag.code.?);
}

test "two stores in one state directory get two CAs" {
    // Goal: finding 2 of the 6a review. Method: name the keys the way the server does, for two
    // databases; open both over one directory; the keys differ, and each is kept by its name.
    // Reverting `key_name_for` to one name makes the keys equal and this test fail.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var name_a: [key_name_bytes_max]u8 = undefined;
    var name_b: [key_name_bytes_max]u8 = undefined;
    const a = key_name_for("/srv/prod.db", &name_a);
    const b = key_name_for("/srv/staging.db", &name_b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    var ca_a: peer_ca.Ca = undefined;
    var ca_b: peer_ca.Ca = undefined;
    try open_test(&dir, &ca_a, .{ .key_name = a, .quiet = true }, &diag);
    try open_test(&dir, &ca_b, .{ .key_name = b, .quiet = true }, &diag);
    try std.testing.expect(!std.mem.eql(u8, &ca_a.public(), &ca_b.public()));
    var again: peer_ca.Ca = undefined;
    try open_test(&dir, &again, .{ .key_name = a, .first_start = false, .quiet = true }, &diag);
    try std.testing.expectEqualSlices(u8, &ca_a.public(), &again.public());
}

test "a lost CA key is refused unless a new CA is asked for, and a loose directory is refused" {
    // Goal: findings 2 and 5. Method: make a key, delete it, open as a store that has run before;
    // then with `accept_new`; then widen the directory's mode.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var first: peer_ca.Ca = undefined;
    try open_test(&dir, &first, .{ .quiet = true }, &diag);
    try dir.tmp.dir.deleteFile(io, key_file);
    var lost: peer_ca.Ca = undefined;
    const used: Options = .{ .quiet = true, .first_start = false };
    try std.testing.expectError(error.Failed, open_test(&dir, &lost, used, &diag));
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0806, diag.code.?);
    try std.testing.expectError(error.FileNotFound, dir.tmp.dir.access(io, key_file, .{}));
    diag.reset();
    try open_test(&dir, &lost, .{ .quiet = true, .first_start = false, .accept_new = true }, &diag);
    try std.testing.expect(!std.mem.eql(u8, &first.public(), &lost.public()));

    try dir.tmp.dir.setFilePermissions(io, ".", .fromMode(0o775), .{});
    try std.testing.expectError(error.Failed, open_test(&dir, &lost, used, &diag));
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0806, diag.code.?);
    diag.reset();
    try dir.tmp.dir.setFilePermissions(io, ".", .fromMode(0o700), .{});
    // A key file that is not a key is refused as well, and not replaced.
    try dir.tmp.dir.writeFile(io, .{ .sub_path = key_file, .data = "xyz\n" });
    const file = try dir.tmp.dir.openFile(io, key_file, .{});
    try file.setPermissions(io, .fromMode(0o600));
    file.close(io);
    try std.testing.expectError(error.Failed, open_test(&dir, &lost, used, &diag));
    diag.reset();
    const loose = try dir.tmp.dir.openFile(io, key_file, .{});
    defer loose.close(io);
    try loose.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.Failed, open_test(&dir, &lost, used, &diag));
}

test "a memory CA with a failing random source is ZC-E0821, not a weaker key" {
    // Goal: RB-N9 on the no-state-dir path. Method: an Io whose `randomSecure` fails.
    var vtable: std.Io.VTable = undefined;
    const io = secure_random.failing_io(std.testing.io, &vtable);
    var clock = FixedClock{};
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.Failed,
        open(&ca, gpa, io, null, clock.clock(), .{ .quiet = true }, &diag),
    );
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0821, diag.code.?);
}

test "a cancelled task is Canceled with no diagnostic, in memory and on a first start" {
    // Goal: a cancel while the CA key is drawn is passed on, not a diagnostic and not a panic in
    // the caller. Method: an Io whose `randomSecure` is cancelled, no directory, then a new one.
    var vtable: std.Io.VTable = undefined;
    const io = secure_random.canceled_io(std.testing.io, &vtable);
    var clock = FixedClock{};
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    const gpa = std.testing.allocator;
    const quiet: Options = .{ .quiet = true };
    try std.testing.expectError(
        error.Canceled,
        open(&ca, gpa, io, null, clock.clock(), quiet, &diag),
    );
    try std.testing.expect(diag.code == null);
    var dir = try TestDir.make(std.testing.io);
    defer dir.tmp.cleanup();
    try std.testing.expectError(
        error.Canceled,
        open(&ca, gpa, io, dir.path(), clock.clock(), quiet, &diag),
    );
    try std.testing.expect(diag.code == null);
}

test "a memory CA is made again each time and says nothing when quiet" {
    // Goal: the memory store's CA. Method: two opens with no directory give two keys.
    const io = std.testing.io;
    var clock = FixedClock{};
    var diag: Diag = undefined;
    diag.reset();
    var one: peer_ca.Ca = undefined;
    var two: peer_ca.Ca = undefined;
    const gpa = std.testing.allocator;
    try open(&one, gpa, io, null, clock.clock(), .{ .quiet = true }, &diag);
    try open(&two, gpa, io, null, clock.clock(), .{ .quiet = true }, &diag);
    try std.testing.expect(!std.mem.eql(u8, &one.public(), &two.public()));
}

test "the CA certificate is a PEM file beside the key, 0600, kept, and made again when stale" {
    // Goal: `ca-<hash>.crt` follows the key file's rule and tracks the key. Method: open and read
    // the file back as a CA certificate for the key; reopen and find the same bytes; plant
    // garbage, a certificate of another key and an expired one, each replaced; widen the mode and
    // find ZC-E0806; check the names for a keyed store.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    try open_test(&dir, &ca, .{ .quiet = true }, &diag);
    var text: [pem_bytes_max]u8 = undefined;
    const first = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expect(std.mem.startsWith(u8, first, pem_begin));
    var first_copy: [pem_bytes_max]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);
    var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    const bytes = pem_decode(first_copy[0..first.len], &der_buffer).?;
    const parsed = try x509.verify(bytes, ca.public(), 1_000_000, .{ .kind = .ca, .name = null });
    try std.testing.expectEqual(@as(u64, 1_000_000), parsed.not_before_ms);
    {
        const file = try dir.tmp.dir.openFile(io, "ca.crt", .{});
        defer file.close(io);
        const mode = (try file.stat(io)).permissions.toMode() & 0o777;
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), mode);
    }
    // A restart keeps the file as it is.
    var again: peer_ca.Ca = undefined;
    try open_test(&dir, &again, .{ .quiet = true, .first_start = false }, &diag);
    const kept = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expectEqualSlices(u8, first_copy[0..first.len], kept);

    // Text that is not ours is replaced by the certificate of the key we hold.
    const plant = try dir.tmp.dir.createFile(io, "ca.crt", .{ .permissions = .fromMode(0o600) });
    try plant.writeStreamingAll(io, "not a certificate\n");
    plant.close(io);
    try open_test(&dir, &again, .{ .quiet = true, .first_start = false }, &diag);
    const replaced = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expectEqualSlices(u8, first_copy[0..first.len], replaced);

    // An expired certificate (the clock is past its end) is replaced; so is one of another key
    // (`--new-ca` after the key was lost makes a new key under the same file name).
    var later = LaterClock{};
    try open(&again, std.testing.allocator, io, dir.path(), later.clock(), .{
        .quiet = true,
        .first_start = false,
    }, &diag);
    const renewed = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expect(!std.mem.eql(u8, first_copy[0..first.len], renewed));
    const old_public = again.public();
    try dir.tmp.dir.deleteFile(io, "ca.key");
    const new_ca: Options = .{ .quiet = true, .accept_new = true, .first_start = false };
    try open_test(&dir, &again, new_ca, &diag);
    try std.testing.expect(!std.mem.eql(u8, &old_public, &again.public()));
    const same_key = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    var again_bytes: [constants.x509_cert_bytes_max]u8 = undefined;
    const decoded = pem_decode(same_key, &again_bytes).?;
    _ = try x509.verify(decoded, again.public(), 1_000_000, .{ .kind = .ca, .name = null });
}

test "a CA certificate other users can read is refused, and names follow the key's" {
    // Goal: the certificate follows the key file's permission rule. Method: widen the mode of
    // the file made on first start and find ZC-E0806; check the names for a keyed store.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var again: peer_ca.Ca = undefined;
    try open_test(&dir, &again, .{ .quiet = true }, &diag);
    const file = try dir.tmp.dir.openFile(io, "ca.crt", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o644));
    const result = open_test(&dir, &again, .{ .quiet = true, .first_start = false }, &diag);
    try std.testing.expectError(error.Failed, result);
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0806, diag.code.?);

    var name_buffer: [key_name_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("ca.crt", cert_name_for("ca.key", &name_buffer));
    const keyed = "ca-0123456789abcdef.key";
    try std.testing.expectEqualStrings(
        "ca-0123456789abcdef.crt",
        cert_name_for(keyed, &name_buffer),
    );
}

test "PEM text round trips only in the exact form written" {
    // Goal: `pem_decode` accepts what `pem_encode` writes and nothing looser. Method: encode
    // lengths around a line boundary, decode, then damage the text four ways.
    var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
    var source: [constants.x509_cert_bytes_max]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var text: [pem_bytes_max]u8 = undefined;
    for ([_]usize{ 1, 47, 48, 49, 200, constants.x509_cert_bytes_max }) |length| {
        const pem = pem_encode(&text, source[0..length]);
        const back = pem_decode(pem, &der_buffer).?;
        try std.testing.expectEqualSlices(u8, source[0..length], back);
    }
    const pem = pem_encode(&text, source[0..100]);
    try std.testing.expect(pem_decode(pem[0 .. pem.len - 1], &der_buffer) == null);
    try std.testing.expect(pem_decode(pem[1..], &der_buffer) == null);
    var other: [pem_bytes_max]u8 = undefined;
    @memcpy(other[0..pem.len], pem);
    other[pem_begin.len + 3] = '!';
    try std.testing.expect(pem_decode(other[0..pem.len], &der_buffer) == null);
    try std.testing.expect(pem_decode("", &der_buffer) == null);
}

const NearEndClock = struct {
    fn clock(self: *NearEndClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    /// A day before the end of a certificate made at `FixedClock`'s time.
    fn now(_: *anyopaque) u64 {
        return 1_000_000 + constants.x509_ca_ttl_ms_max - 24 * 60 * 60 * 1000;
    }
};

const FarClock = struct {
    fn clock(self: *FarClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    /// Past the year 9999, which no certificate can hold.
    fn now(_: *anyopaque) u64 {
        return 300_000_000_000_000;
    }
};

test "a CA certificate near its end is made again; an unmakeable one is one coded line" {
    // Goal: renewal ahead of time, and a certificate that cannot be made reports as ZC-E0817
    // with the reason in words (never a Zig error name). Method: open at the start, again a day
    // before the end (the file changes), then with a clock past the year 9999 on a new directory.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    try open_test(&dir, &ca, .{ .quiet = true }, &diag);
    var text: [pem_bytes_max]u8 = undefined;
    var before: [pem_bytes_max]u8 = undefined;
    const first = (try dir.tmp.dir.readFile(io, "ca.crt", &before)).len;
    var near = NearEndClock{};
    const options: Options = .{ .quiet = true, .first_start = false };
    try open(&ca, std.testing.allocator, io, dir.path(), near.clock(), options, &diag);
    const after = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expect(!std.mem.eql(u8, before[0..first], after));

    var far_dir = try TestDir.make(io);
    defer far_dir.tmp.cleanup();
    var far = FarClock{};
    const failed = open(&ca, std.testing.allocator, io, far_dir.path(), far.clock(), .{
        .quiet = true,
    }, &diag);
    try std.testing.expectError(error.Failed, failed);
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0817, diag.code.?);
    const cause = diag.last_cause().?;
    try std.testing.expect(std.mem.indexOf(u8, cause, "IssueLifetime") == null);
    try std.testing.expect(std.mem.indexOf(u8, cause, peer_ca.reason(error.IssueLifetime)) != null);
}

const LaterClock = struct {
    fn clock(self: *LaterClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    /// Past the end of a certificate made at `FixedClock`'s time, skew included.
    fn now(_: *anyopaque) u64 {
        return 1_000_000 + constants.x509_ca_ttl_ms_max + constants.peer_clock_skew_ms;
    }
};

const FixedClock = struct {
    fn clock(self: *FixedClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    fn now(_: *anyopaque) u64 {
        return 1_000_000;
    }
};

test "the CA tests hold under a umask of 002" {
    // Goal: no test here depends on the runner's umask; under 002 every one of them once failed
    // in `check_dir`. Method: set the umask to 002 (process-wide, restored on exit), make a test
    // directory and open a CA in it.
    const linux = std.os.linux;
    const umask_old = linux.syscall1(.umask, 0o002);
    defer _ = linux.syscall1(.umask, umask_old);
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    try open_test(&dir, &ca, .{ .quiet = true }, &diag);
    try std.testing.expect(diag.code == null);
}

test "a state directory the server creates is 0700 whatever the umask" {
    // Goal: under a umask of 002 the server once created its state directory 0775 and then
    // refused it (ZC-E0806). Method: under 002, open a CA in a directory two levels below the test
    // directory that does not exist yet; it must start, and both new directories must be 0700.
    const linux = std.os.linux;
    const umask_old = linux.syscall1(.umask, 0o002);
    defer _ = linux.syscall1(.umask, umask_old);
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state = try std.fmt.bufPrint(&path_buffer, "{s}/data/state", .{dir.path()});
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    var clock = FixedClock{};
    const gpa = std.testing.allocator;
    try open(&ca, gpa, io, state, clock.clock(), .{ .quiet = true }, &diag);
    try std.testing.expect(diag.code == null);
    for ([_][]const u8{ "data", "data/state" }) |sub_path| {
        const stat = try dir.tmp.dir.statFile(io, sub_path, .{});
        const mode = stat.permissions.toMode() & 0o777;
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), mode);
    }
}

test "a ca.crt one byte over the longest PEM is replaced, not fatal" {
    // Goal: a file too long to be ours does not stop the server. Method: open once to make the
    // file, overwrite it with `pem_bytes_max` bytes (the smallest size `read` calls too long),
    // reopen and find the first file's bytes again.
    const io = std.testing.io;
    var dir = try TestDir.make(io);
    defer dir.tmp.cleanup();
    var diag: Diag = undefined;
    diag.reset();
    var ca: peer_ca.Ca = undefined;
    try open_test(&dir, &ca, .{ .quiet = true }, &diag);
    var text: [pem_bytes_max]u8 = undefined;
    const first = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    var first_copy: [pem_bytes_max]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);
    const long: [pem_bytes_max]u8 = @splat('A');
    try dir.tmp.dir.writeFile(io, .{ .sub_path = "ca.crt", .data = &long });
    try dir.tmp.dir.setFilePermissions(io, "ca.crt", .fromMode(0o600), .{});
    var again: peer_ca.Ca = undefined;
    try open_test(&dir, &again, .{ .quiet = true, .first_start = false }, &diag);
    try std.testing.expect(diag.code == null);
    const replaced = try dir.tmp.dir.readFile(io, "ca.crt", &text);
    try std.testing.expectEqualSlices(u8, first_copy[0..first.len], replaced);
}
