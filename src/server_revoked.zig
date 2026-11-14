//! The server's watch of its `revoked` file (B7 slice 5, docs/mtls.md "Revocation"). Shell code:
//! the HTTP watchdog calls `tick` every `http_watchdog_ms`, and a tick that finds the file
//! changed (its inode, size or modification time) reads it again and swaps the new set into the
//! CA, without a restart. The decision file is
//! docs/decisions/2026-11-14-b7-slice5-runtime-cert-checks.md.
//!
//! The rules:
//! - A change is read once it has held for one tick, so a file caught half written is not read
//!   (an editor that truncates and then writes would otherwise un-revoke every name for a tick).
//! - A file that does not parse, or cannot be read, keeps the set the server has and logs one
//!   line; it is not tried again until it changes again. It never empties the set.
//! - An absent file is an empty set, as at start: deleting the file un-revokes every name.
//! - The swap takes the API's write lock with `tryLock`, so a long store write never stalls the
//!   watchdog: a busy lock leaves the new set pending for the next tick. It then takes the TLS
//!   setup's lock, under which the per-request checks read the set.
//!
//! The file system is behind `Source`, so the tests drive every rule with no files and no clock.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const server_ca = @import("server_ca.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

/// Test-only fault for the teeth test: a changed file is never swapped in.
pub const TestFault = enum { reload };
var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// What one look at the file found. Two looks that are equal mean the file has not changed.
pub const Look = union(enum) {
    absent,
    present: struct { inode: u64, size: u64, mtime_ns: i96 },
    /// It could not be looked at; the error's number, so that the same failure is equal.
    unreadable: u16,
};

/// The file system, or a test's stand-in for it.
pub const Source = struct {
    context: *anyopaque,
    look: *const fn (context: *anyopaque) Look,
    /// Fills `into` from the file (empty when there is none). On failure `diag` says why.
    load: *const fn (context: *anyopaque, into: *peer_ca.Revoked, diag: *Diag) error{Failed}!void,
};

/// The real file: `<state dir>/revoked`.
pub const FileSource = struct {
    gpa: Allocator,
    io: std.Io,
    state_dir: []const u8,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_length: u32 = 0,

    pub fn init(source: *FileSource, gpa: Allocator, io: std.Io, state_dir: []const u8) void {
        source.* = .{ .gpa = gpa, .io = io, .state_dir = state_dir };
        const path = std.fmt.bufPrint(&source.path_buffer, "{s}/{s}", .{
            state_dir, server_ca.revoked_file,
        }) catch "";
        source.path_length = @intCast(path.len);
    }

    pub fn interface(source: *FileSource) Source {
        return .{ .context = source, .look = look, .load = load };
    }

    fn look(context: *anyopaque) Look {
        const source: *FileSource = @ptrCast(@alignCast(context));
        if (source.path_length == 0) return .{ .unreadable = @intFromError(error.NameTooLong) };
        const path = source.path_buffer[0..source.path_length];
        const stat = std.Io.Dir.cwd().statFile(source.io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return .absent;
            return .{ .unreadable = @intFromError(err) };
        };
        return .{ .present = .{
            .inode = @intCast(stat.inode),
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        } };
    }

    fn load(context: *anyopaque, into: *peer_ca.Revoked, diag: *Diag) error{Failed}!void {
        const source: *FileSource = @ptrCast(@alignCast(context));
        var dir = std.Io.Dir.cwd().openDir(source.io, source.state_dir, .{}) catch |err| {
            diag.raise(.E0806);
            diag.cause("can't open {s}: {s}", .{ source.state_dir, @errorName(err) });
            return error.Failed;
        };
        defer dir.close(source.io);
        server_ca.load_revoked(into, source.gpa, source.io, dir, source.state_dir, diag) catch |err|
            {
                if (diag.code == null) {
                    diag.raise(.E0806);
                    diag.cause("can't read {s}: {s}", .{ server_ca.revoked_file, @errorName(err) });
                }
                return error.Failed;
            };
    }
};

const line_bytes_max = 512;

pub const Watch = struct {
    io: std.Io,
    source: Source,
    ca: *peer_ca.Ca,
    /// The API's write lock: the core's node renewal reads the set under it.
    api_mutex: *std.Io.Mutex,
    /// The TLS setup's lock, when there is a TLS listener: its checks read the set under it.
    tls_mutex: ?*std.Io.Mutex,
    /// Log nothing (tests).
    silent: bool,
    /// The file whose names are in effect, or whose failure was logged.
    applied: Look,
    /// What the last tick found.
    seen: Look,
    /// A set read and parsed, waiting for the API lock.
    pending: bool = false,
    scratch: peer_ca.Revoked = .{},
    /// How many lines were logged, and the last one: what the tests read.
    lines: u32 = 0,
    line_buffer: [line_bytes_max]u8 = undefined,
    line_length: u32 = 0,

    /// Looks at the file now: the server reads it at start right after this, so a change made
    /// in between is seen by the first ticks.
    pub fn init(
        watch: *Watch,
        io: std.Io,
        source: Source,
        ca: *peer_ca.Ca,
        api_mutex: *std.Io.Mutex,
        silent: bool,
    ) void {
        const now = source.look(source.context);
        watch.* = .{
            .io = io,
            .source = source,
            .ca = ca,
            .api_mutex = api_mutex,
            .tls_mutex = null,
            .silent = silent,
            .applied = now,
            .seen = now,
        };
    }

    /// One watchdog tick. Never blocks on the API lock.
    pub fn tick(watch: *Watch) void {
        if (watch.pending) return watch.apply();
        const now = watch.source.look(watch.source.context);
        const settled = std.meta.eql(now, watch.seen);
        watch.seen = now;
        if (!settled) return; // Changed since the last tick: read it once it holds.
        if (std.meta.eql(now, watch.applied)) return;
        watch.applied = now;
        switch (now) {
            .unreadable => |number| {
                const err = @errorFromInt(number);
                return watch.log("zcube-server: can't look at the revoked file ({s}); " ++
                    "keeping the {d} revoked names it had", .{ @errorName(err), watch.count() });
            },
            .absent, .present => {},
        }
        var diag: Diag = undefined;
        diag.reset();
        watch.source.load(watch.source.context, &watch.scratch, &diag) catch {
            return watch.log("zcube-server: the revoked file was not reloaded ({s}: {s}); " ++
                "keeping the {d} revoked names it had", .{
                if (diag.code) |code| @tagName(code) else "?",
                diag.last_cause() orelse "no detail",
                watch.count(),
            });
        };
        watch.pending = true;
        watch.apply();
    }

    /// The `tick` of `server_http.Tick`.
    pub fn tick_any(context: *anyopaque) void {
        const watch: *Watch = @ptrCast(@alignCast(context));
        watch.tick();
    }

    fn apply(watch: *Watch) void {
        assert(watch.pending);
        if (fault_on(.reload)) return;
        if (!watch.api_mutex.tryLock()) return; // A write is under way: the next tick.
        defer watch.api_mutex.unlock(watch.io);
        if (watch.tls_mutex) |mutex| mutex.lockUncancelable(watch.io);
        defer if (watch.tls_mutex) |mutex| mutex.unlock(watch.io);
        watch.ca.revoked = watch.scratch;
        watch.pending = false;
        watch.log("zcube-server: the revoked file was reloaded: {d} revoked names", .{
            watch.ca.revoked.count,
        });
    }

    /// The names in effect. Read by the watchdog only, which is the only writer.
    fn count(watch: *const Watch) u32 {
        return watch.ca.revoked.count;
    }

    fn log(watch: *Watch, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&watch.line_buffer, format ++ "\n", args) catch
            watch.line_buffer[0..];
        watch.line_length = @intCast(text.len);
        watch.lines += 1;
        if (watch.silent) return;
        std.Io.File.stderr().writeStreamingAll(watch.io, text) catch {}; // Nowhere else to say it.
    }

    /// The last line logged, without its newline: for the tests.
    pub fn last_line(watch: *const Watch) []const u8 {
        return std.mem.trimEnd(u8, watch.line_buffer[0..watch.line_length], "\n");
    }
};

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;
const Ed25519 = std.crypto.sign.Ed25519;
const ManualClock = @import("clock.zig").ManualClock;

/// A file in memory: its text, and a stamp the test moves to say it changed.
const FakeFile = struct {
    text: ?[]const u8 = "",
    version: u64 = 1,
    unreadable: bool = false,
    loads: u32 = 0,

    fn interface(file: *FakeFile) Source {
        return .{ .context = file, .look = look, .load = load };
    }

    fn look(context: *anyopaque) Look {
        const file: *FakeFile = @ptrCast(@alignCast(context));
        if (file.unreadable) return .{ .unreadable = @intFromError(error.AccessDenied) };
        const text = file.text orelse return .absent;
        return .{ .present = .{ .inode = 7, .size = text.len, .mtime_ns = file.version } };
    }

    fn load(context: *anyopaque, into: *peer_ca.Revoked, diag: *Diag) error{Failed}!void {
        const file: *FakeFile = @ptrCast(@alignCast(context));
        file.loads += 1;
        into.* = .{};
        const text = file.text orelse return;
        into.parse(text) catch {
            diag.raise(.E0806);
            diag.cause("line {d} does not parse", .{into.bad_line});
            return error.Failed;
        };
    }

    fn write(file: *FakeFile, text: ?[]const u8) void {
        file.text = text;
        file.version += 1;
    }
};

const Rig = struct {
    clock: ManualClock = .{ .ms = 1_700_000_000_000 },
    ca: peer_ca.Ca = undefined,
    api_mutex: std.Io.Mutex = .init,
    file: FakeFile = .{},
    watch: Watch = undefined,

    fn start(rig: *Rig, text: ?[]const u8) !void {
        rig.ca = .{
            .key = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA)),
            .revoked = .{},
            .wall = rig.clock.clock(),
        };
        rig.file.text = text;
        if (text) |names| try rig.ca.revoked.parse(names);
        rig.watch.init(testing.io, rig.file.interface(), &rig.ca, &rig.api_mutex, true);
    }

    /// Ticks until the watch has had the chance to see the file hold for one tick.
    fn settle(rig: *Rig) void {
        rig.watch.tick();
        rig.watch.tick();
    }
};

test "an edited revoked file is read once it holds, and the next node renewal sees it" {
    // Goal: part C of B7 slice 5. Method: a CA with no names revoked; the file gains node2.
    // The first tick sees the change and waits; the second swaps it in. The CA then refuses to
    // issue node2 a certificate (the core's renewal), and nothing is read while the file holds.
    var rig: Rig = .{};
    try rig.start("");
    try testing.expect(!rig.ca.revoked.contains(.node, "node2"));
    rig.file.write("node2\n");
    rig.watch.tick();
    try testing.expect(!rig.ca.revoked.contains(.node, "node2"));
    try testing.expectEqual(@as(u32, 0), rig.file.loads);
    rig.watch.tick();
    try testing.expect(rig.ca.revoked.contains(.node, "node2"));
    try testing.expectEqual(@as(u32, 1), rig.watch.lines);
    try testing.expect(std.mem.indexOf(u8, rig.watch.last_line(), "reloaded: 1") != null);
    var der: @import("x509.zig").Der = .{};
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    try testing.expectError(error.Removed, rig.ca.issue_node_certificate(&der, &.{
        .node = "node2",
        .subject_key = key.public_key.toBytes(),
        .lifetime = .{ .not_before_ms = 0, .not_after_ms = 1 },
    }));
    rig.settle();
    try testing.expectEqual(@as(u32, 1), rig.file.loads);
}

test "a revoked file that does not parse keeps the old set and logs one line" {
    // Goal: the bad-file rule. Method: node1 revoked; the file is replaced by one with a bad
    // line. After many ticks node1 is still revoked, the file was read once and one line names
    // the line. A fixed file is then swapped in.
    var rig: Rig = .{};
    try rig.start("node1\n");
    rig.file.write("node1\nnot a name!\n");
    for (0..10) |_| rig.watch.tick();
    try testing.expect(rig.ca.revoked.contains(.node, "node1"));
    try testing.expectEqual(@as(u32, 1), rig.ca.revoked.count);
    try testing.expectEqual(@as(u32, 1), rig.file.loads);
    try testing.expectEqual(@as(u32, 1), rig.watch.lines);
    const line = rig.watch.last_line();
    try testing.expect(std.mem.indexOf(u8, line, "not reloaded") != null);
    try testing.expect(std.mem.indexOf(u8, line, "line 2") != null);
    try testing.expect(std.mem.indexOf(u8, line, "keeping the 1") != null);
    rig.file.write("node1\nnode3\n");
    rig.settle();
    try testing.expect(rig.ca.revoked.contains(.node, "node3"));
    try testing.expectEqual(@as(u32, 2), rig.watch.lines);
}

test "a revoked file that can't be looked at keeps the old set; an absent one empties it" {
    var rig: Rig = .{};
    try rig.start("client/ops\n");
    rig.file.unreadable = true;
    for (0..5) |_| rig.watch.tick();
    try testing.expect(rig.ca.revoked.contains(.client, "ops"));
    try testing.expectEqual(@as(u32, 1), rig.watch.lines);
    try testing.expect(std.mem.indexOf(u8, rig.watch.last_line(), "AccessDenied") != null);
    rig.file.unreadable = false;
    rig.file.write(null);
    rig.settle();
    try testing.expect(!rig.ca.revoked.contains(.client, "ops"));
    try testing.expectEqual(@as(u32, 0), rig.ca.revoked.count);
}

test "a file still changing is not read until it holds for a tick" {
    // Goal: a file caught half written (an editor truncating, then writing) is not swapped in.
    var rig: Rig = .{};
    try rig.start("node1\n");
    for (0..5) |_| {
        rig.file.write(""); // Truncated...
        rig.watch.tick();
        rig.file.write("node1\n"); // ...and written again, before the next tick.
        rig.watch.tick();
    }
    try testing.expectEqual(@as(u32, 0), rig.file.loads);
    try testing.expect(rig.ca.revoked.contains(.node, "node1"));
}

test "a reload waits while the API lock is held, and is applied on the next free tick" {
    var rig: Rig = .{};
    try rig.start("");
    rig.file.write("node4\n");
    rig.watch.tick();
    try testing.expect(rig.api_mutex.tryLock());
    rig.watch.tick();
    rig.watch.tick();
    try testing.expect(rig.watch.pending);
    try testing.expect(!rig.ca.revoked.contains(.node, "node4"));
    rig.api_mutex.unlock(testing.io);
    rig.watch.tick();
    try testing.expect(!rig.watch.pending);
    try testing.expect(rig.ca.revoked.contains(.node, "node4"));
    try testing.expectEqual(@as(u32, 1), rig.file.loads);
}

test "the real file: an edit in a state directory is seen by its watch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &path_buffer);
    const state_dir = path_buffer[0..length];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "revoked", .data = "node1\n" });
    var rig: Rig = .{};
    try rig.start("node1\n");
    var source: FileSource = undefined;
    source.init(testing.allocator, testing.io, state_dir);
    rig.watch.init(testing.io, source.interface(), &rig.ca, &rig.api_mutex, true);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "revoked", .data = "node1\nnode22\n" });
    rig.settle();
    try testing.expect(rig.ca.revoked.contains(.node, "node22"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "revoked", .data = "node1\n/bad\n" });
    rig.settle();
    try testing.expect(rig.ca.revoked.contains(.node, "node22"));
    try testing.expect(std.mem.indexOf(u8, rig.watch.last_line(), "E0806") != null);
}

test "teeth: with the reload skipped an edited revoked file is never applied" {
    set_test_fault(.reload, true);
    defer set_test_fault(.reload, false);
    try testing.expect(!try edited_file_applied());
}

/// The check the tooth breaks: an edit is applied within two ticks.
fn edited_file_applied() !bool {
    var rig: Rig = .{};
    try rig.start("");
    rig.file.write("node2\n");
    rig.settle();
    return rig.ca.revoked.contains(.node, "node2");
}

test "an edited file is applied within two ticks" {
    try testing.expect(try edited_file_applied());
}
