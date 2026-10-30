//! `check <zig> <user>`: the last step of `zig build check`, which has already built, tested,
//! tidied, checked the error pages, compiled and run the WASM core and the console module, and
//! run the store conformance suite on memory and SQLite when this runs (they are its
//! dependencies, so any failure stops the build before here). It adds the gates a dependency
//! cannot express:
//!
//!   - The conformance suite on Postgres, when `ZCUBE_TEST_POSTGRES` is set. Unset is not a
//!     failure; the PASS line names the backends that ran.
//!   - `sim-c0` with a fresh seed, native against WASM, as CI's second sim step does. A failure
//!     prints the seed in the `sim-c0: seed N` line above it.
//!   - The one gate a root build container cannot see: CI runs `zig build test` as an ordinary
//!     user. When this runs as root and <user> is not "-", the committed tree is checked out into
//!     a scratch worktree owned by <user> and tested as that user, with its own cache.
//!
//! Then it prints the line a report quotes:
//!
//!     check: PASS 1a2b3c4d5e6f (build test tidy errors-site wasm-check wasm-test console-wasm
//!     store:memory,sqlite sim-c0, test as tester)
//!
//! It also says when the build cache has grown past `cache_note_bytes`, with the command that
//! empties it, because a full disk costs more than a rebuild.
//!
//! "+dirty" after the commit means the working tree had uncommitted changes, which the build-step
//! gates saw and the user test did not. Not in `check`: `agent-smoke` and `demo-c0`, which CI runs
//! (they are slow and start servers). Build-host tool, run by build.zig from the repository root.

const std = @import("std");
const Io = std.Io;

const scratch = ".zig-cache/zcube-check-tree";
const cache_note_bytes: u64 = 6 << 30;
const sim_operations = "200";
const gates = "build test tidy errors-site wasm-check wasm-test console-wasm";

/// Runs `argv` (in `cwd` if given) with its errors on stderr; fails unless it exits 0.
fn run(io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

/// Runs `argv` and returns its standard output, trimmed; fails unless it exits 0.
fn output(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return std.mem.trim(u8, result.stdout, " \n");
}

/// Whether `argv` exits 0 (for `id` and `pgrep`, whose exit status is their answer).
fn succeeds(io: Io, argv: []const []const u8) bool {
    run(io, argv, null) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !u8 {
    var buffer: [512]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const err = &file_writer.interface;
    defer err.flush() catch {};
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const zig = arguments.next() orelse return usage(err);
    const user = arguments.next() orelse return usage(err);
    const io = init.io;
    const gpa = init.arena.allocator();
    const commit = try output(gpa, io, &.{ "git", "rev-parse", "--short=12", "HEAD" });
    const porcelain = [_][]const u8{ "git", "status", "--porcelain", "--untracked-files=no" };
    const dirty: []const u8 = if ((try output(gpa, io, &porcelain)).len > 0) "+dirty" else "";
    const label = try std.fmt.allocPrint(gpa, "{s}{s}", .{ commit, dirty });
    const as_user = !std.mem.eql(u8, user, "-") and std.os.linux.geteuid() == 0;
    // Before the slow gates: a missing user is the operator's to fix, and says how.
    if (as_user and !succeeds(io, &.{ "id", "-u", user })) {
        try err.print("check: FAIL {s} (user {s} does not exist: useradd -m {s}, or " ++
            "-Dcheck-user=-)\n", .{ label, user, user });
        return 1;
    }
    const postgres = init.environ_map.get("ZCUBE_TEST_POSTGRES") != null;
    if (postgres and !succeeds(io, &.{ zig, "build", "test-store", "-Dbackend=postgres" })) {
        try err.print("check: FAIL {s} (zig build test-store -Dbackend=postgres)\n", .{label});
        return 1;
    }
    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const seed = std.mem.readInt(u64, &seed_bytes, .little);
    try err.print("sim-c0: seed {d}\n", .{seed});
    try err.flush();
    const seed_option = try std.fmt.allocPrint(gpa, "-Dseed={d}", .{seed});
    const sim = [_][]const u8{
        zig,         "build",                    "sim-c0",
        seed_option, "-Dops=" ++ sim_operations, "-Doptimize=ReleaseSafe",
    };
    run(io, &sim, null) catch {
        try err.print("check: FAIL {s} (zig build sim-c0: its seed is the sim-c0 line above)\n", .{
            label,
        });
        return 1;
    };
    if (as_user) {
        test_as(gpa, io, zig, user, err) catch {
            try err.print("check: FAIL {s} (zig build test as {s})\n", .{ label, user });
            return 1;
        };
    }
    const tail: []const u8 = if (as_user)
        try std.fmt.allocPrint(gpa, ", test as {s}", .{user})
    else
        "";
    note_cache(gpa, io, err);
    const stores = if (postgres) "store:memory,sqlite,postgres" else "store:memory,sqlite";
    try err.print("check: PASS {s} ({s} {s} sim-c0{s})\n", .{ label, gates, stores, tail });
    return 0;
}

/// Says so when `.zig-cache/o` is past `cache_note_bytes`. Every rebuild of a changed binary
/// adds a copy and nothing removes the old ones; emptying it costs one full rebuild.
fn note_cache(gpa: std.mem.Allocator, io: Io, err: *Io.Writer) void {
    const text = output(gpa, io, &.{ "du", "-sb", ".zig-cache/o" }) catch return;
    const end = std.mem.indexOfAny(u8, text, " \t") orelse return;
    const bytes = std.fmt.parseInt(u64, text[0..end], 10) catch return;
    if (bytes < cache_note_bytes) return;
    err.print("check: note: .zig-cache/o holds {d} MiB; outside a build, rm -rf .zig-cache\n", .{
        bytes >> 20,
    }) catch {};
}

/// `zig build test` as `user` in a scratch worktree of HEAD that `user` owns. Then checks that
/// the run was real: it built `zcube-agent` (the FakeRuntime tests skip without it) and left no
/// supervisor of `user` running.
fn test_as(
    gpa: std.mem.Allocator,
    io: Io,
    zig: []const u8,
    user: []const u8,
    err: *Io.Writer,
) !void {
    try run(io, &.{ "git", "worktree", "prune" }, null);
    if (Io.Dir.cwd().access(io, scratch, .{})) |_| {
        try run(io, &.{ "git", "worktree", "remove", "--force", scratch }, null);
    } else |_| {}
    try run(io, &.{ "git", "worktree", "add", "--quiet", "--detach", scratch, "HEAD" }, null);
    defer run(io, &.{ "git", "worktree", "remove", "--force", scratch }, null) catch {};
    const absolute = try Io.Dir.cwd().realPathFileAlloc(io, scratch, gpa);
    const global = try std.fmt.allocPrint(gpa, "{s}/.zig-global", .{absolute});
    try seed_packages(gpa, io, zig, global);
    try run(io, &.{ "chown", "-R", user, scratch }, null);
    const cache = try std.fmt.allocPrint(gpa, "ZIG_GLOBAL_CACHE_DIR={s}", .{global});
    const home = try std.fmt.allocPrint(gpa, "HOME={s}", .{absolute});
    const argv = [_][]const u8{
        "runuser", "-u", user, "--", "env", cache, home, zig, "build", "test",
    };
    try run(io, &argv, scratch);
    const agent = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/zcube-agent", .{absolute});
    Io.Dir.cwd().access(io, agent, .{}) catch {
        try err.print("check: the test run as {s} did not build zcube-agent\n", .{user});
        return error.AgentMissing;
    };
    if (succeeds(io, &.{ "pgrep", "-u", user, "-f", "[z]cube-agent supervise" })) {
        try err.print("check: the test run as {s} left zcube-agent supervisors running\n", .{
            user,
        });
        return error.LeftRunning;
    }
}

/// The scratch cache starts empty, so the pinned `zigbox` package would be fetched again. Copy
/// the packages the invoking user's cache already holds, which the build just used.
fn seed_packages(gpa: std.mem.Allocator, io: Io, zig: []const u8, global: []const u8) !void {
    const env = try output(gpa, io, &.{ zig, "env" });
    const key = ".global_cache_dir = \"";
    const start = (std.mem.indexOf(u8, env, key) orelse return) + key.len;
    const length = std.mem.indexOfScalar(u8, env[start..], '"') orelse return;
    const packages = try std.fmt.allocPrint(gpa, "{s}/p", .{env[start..][0..length]});
    Io.Dir.cwd().access(io, packages, .{}) catch return;
    try run(io, &.{ "mkdir", "-p", global }, null);
    try run(io, &.{ "cp", "-a", packages, global }, null);
}

fn usage(err: *Io.Writer) !u8 {
    try err.print("usage: check <zig> <user|->\n", .{});
    return 2;
}
