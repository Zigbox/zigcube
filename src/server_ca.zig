//! The server's half of the cluster CA (docs/peer.md, "Trust model"). Shell code: it reads and
//! writes the state directory. The core's half, what to sign and for whom, is `peer_ca.zig`.
//!
//! `ca.key` is the Ed25519 seed, made on the first start (mode 0600) and loaded afterwards. A
//! server with no state directory (a memory store) makes a fresh CA in memory each start and
//! says so on stderr: its agents join again. `revoked` is read once, at start.

const std = @import("std");
const assert = std.debug.assert;
const Ed25519 = std.crypto.sign.Ed25519;
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const peer_ca = @import("peer_ca.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const key_file = "ca.key";
pub const revoked_file = "revoked";
pub const key_name_bytes_max = 64;

pub const Error = files.Error || error{OutOfMemory};

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
        ca.key = Ed25519.KeyPair.generate(io);
        if (options.quiet) return;
        std.Io.File.stderr().writeStreamingAll(io, memory_notice) catch {}; // Nowhere else.
        return;
    };
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, path) catch |err| {
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
    try read_revoked(ca, gpa, io, dir, path, diag);
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
        io.random(&seed);
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

    try dir.tmp.dir.writeFile(io, .{ .sub_path = revoked_file, .data = "# out\nnode3\n" });
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

const FixedClock = struct {
    fn clock(self: *FixedClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    fn now(_: *anyopaque) u64 {
        return 1_000_000;
    }
};
