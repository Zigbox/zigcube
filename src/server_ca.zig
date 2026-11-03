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

pub const Error = files.Error || error{OutOfMemory};

pub const memory_notice = "zcube-server: no state directory, so the peer CA key lives in memory " ++
    "only; agents will join again after a restart\n";

/// Fills `ca` from `state_dir` (created if needed), or makes one in memory when it is null and
/// writes `memory_notice` to stderr. On failure `diag` says why (ZC-E0806).
pub fn open(
    ca: *peer_ca.Ca,
    gpa: Allocator,
    io: std.Io,
    state_dir: ?[]const u8,
    wall: Clock,
    diag: *Diag,
) Error!void {
    assert(diag.code == null);
    ca.wall = wall;
    ca.revoked = .{};
    const path = state_dir orelse {
        ca.key = Ed25519.KeyPair.generate(io);
        std.Io.File.stderr().writeStreamingAll(io, memory_notice) catch {}; // Nowhere else.
        return;
    };
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, path) catch |err| {
        return files.unusable(diag, path, key_file, "create the directory for", @errorName(err));
    };
    var dir = cwd.openDir(io, path, .{}) catch |err| {
        return files.unusable(diag, path, key_file, "open the directory of", @errorName(err));
    };
    defer dir.close(io);
    ca.key = try load_or_make_key(io, dir, path, diag);
    try read_revoked(ca, gpa, io, dir, path, diag);
}

fn load_or_make_key(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    diag: *Diag,
) Error!Ed25519.KeyPair {
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (try files.read_seed(io, dir, path, key_file, diag)) |loaded| {
        seed = loaded;
        return Ed25519.KeyPair.generateDeterministic(seed) catch
            return files.unusable(diag, path, key_file, "use", "it is not a usable key seed");
    }
    // A seed that gives the identity element has a chance of about 2^-250; draw another.
    while (true) {
        io.random(&seed);
        const key = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
        try files.write_seed(io, dir, path, key_file, seed, diag);
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
    const text = try files.read(io, dir, path, revoked_file, false, buffer, diag) orelse return;
    ca.revoked.parse(text) catch |err| {
        const why = switch (err) {
            error.BadName => "a line is not a node name",
            error.TooMany => "it names more nodes than the server keeps",
        };
        var line_buffer: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&line_buffer, "line {d}: {s}", .{
            ca.revoked.bad_line, why,
        }) catch why;
        return files.unusable(diag, path, revoked_file, "parse", detail);
    };
}

test "the CA key is made once, kept across a restart, and a bad revoked file is refused" {
    // Goal: persistence and the refusals of docs/peer.md. Method: open twice over one directory
    // and compare keys; remove a node by file; then break the file.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const path = path_buffer[0..length];
    var clock = FixedClock{};
    var diag: Diag = undefined;
    diag.reset();
    var first: peer_ca.Ca = undefined;
    try open(&first, gpa, io, path, clock.clock(), &diag);
    var second: peer_ca.Ca = undefined;
    try open(&second, gpa, io, path, clock.clock(), &diag);
    try std.testing.expectEqualSlices(u8, &first.public(), &second.public());
    try std.testing.expectEqual(@as(u32, 0), second.revoked.count);

    try tmp.dir.writeFile(io, .{ .sub_path = revoked_file, .data = "# out\nnode3\n" });
    try open(&second, gpa, io, path, clock.clock(), &diag);
    try std.testing.expect(second.revoked.contains("node3"));

    try tmp.dir.writeFile(io, .{ .sub_path = revoked_file, .data = "node3\nNOT A NAME\n" });
    try std.testing.expectError(error.Failed, open(&second, gpa, io, path, clock.clock(), &diag));
    try std.testing.expectEqual(@import("diag/codes.zig").Code.E0806, diag.code.?);
}

const FixedClock = struct {
    fn clock(self: *FixedClock) Clock {
        return .{ .context = self, .now_ms_fn = now };
    }

    fn now(_: *anyopaque) u64 {
        return 1_000_000;
    }
};
