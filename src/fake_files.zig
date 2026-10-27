//! The files of one `FakeRuntime` container, and the few helpers that read and write them. Shell
//! code: files. The agent and the container's supervisor are different processes that meet only
//! here, so every format is written down and every write is atomic (a temporary file renamed over
//! the name), which means a reader sees a whole file or none.
//!
//! A container is a directory `<state>/containers/<name>/`:
//!
//!   spec.json        what the agent asked for, written before the supervisor starts
//!   lock             held (flock) by the supervisor for as long as it lives
//!   supervisor.pid   the supervisor's pid, which is also its process group and session
//!   child.pid        the command's pid, written once it runs
//!   forced           "oom" or "pid_limit", put there by a test fault before the kill
//!   run.json         how the command ended; the supervisor writes it last
//!
//! `run.json` is the truth about how a container ended (docs/contracts-review.md, item 12): it
//! survives an agent restart because the supervisor, not the agent, writes it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const file_spec = "spec.json";
pub const file_run = "run.json";
pub const file_child = "child.pid";
pub const file_supervisor = "supervisor.pid";
pub const file_lock = "lock";
pub const file_forced = "forced";

pub const Pair = [2][]const u8;

/// `spec.json`: the `runtime.Spec` the container was started with, and when.
pub const SpecFile = struct {
    name: []const u8,
    image: []const u8,
    command: []const []const u8,
    env: []const Pair = &.{},
    labels: []const Pair = &.{},
    started_at_ms: u64,
};

pub const RunKind = enum { exited, signaled, oom, pid_limit, start_failed, lost };

/// Whose fault a start that failed was, so that the agent can blame correctly.
pub const Blame = enum { user, environment };

/// `run.json`.
pub const RunFile = struct {
    kind: RunKind,
    code: ?u8 = null,
    signal: ?u8 = null,
    /// For `start_failed`: what the host said, in one sentence.
    cause: ?[]const u8 = null,
    blame: ?Blame = null,
};

pub const WriteError = error{WriteFailed};
pub const ReadError = error{ Absent, Unreadable, OutOfMemory };

/// Writes `data` as `name` in `dir`, whole or not at all.
pub fn write_atomic(io: std.Io, dir: Dir, name: []const u8, data: []const u8) WriteError!void {
    assert(name.len > 0);
    assert(name.len + ".tmp".len <= temp_name_bytes_max);
    if (data.len > constants.fake_file_bytes_max) return error.WriteFailed;
    var temp: [temp_name_bytes_max]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp, "{s}.tmp", .{name}) catch unreachable; // Sized.
    dir.writeFile(io, .{ .sub_path = temp_name, .data = data }) catch return error.WriteFailed;
    dir.rename(temp_name, dir, name, io) catch return error.WriteFailed;
}

const temp_name_bytes_max: u32 = 32;

pub fn write_json(io: std.Io, dir: Dir, name: []const u8, value: anytype) WriteError!void {
    var buffer: [constants.fake_file_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    std.json.Stringify.value(value, options, &writer) catch return error.WriteFailed;
    try write_atomic(io, dir, name, writer.buffered());
}

/// The file's bytes in `arena`, `Absent` if there is no such file.
pub fn read_bytes(io: std.Io, dir: Dir, name: []const u8, arena: Allocator) ReadError![]const u8 {
    const limit: std.Io.Limit = .limited(constants.fake_file_bytes_max);
    return dir.readFileAlloc(io, name, arena, limit) catch |err| switch (err) {
        error.FileNotFound => error.Absent,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

pub fn read_json(
    comptime T: type,
    io: std.Io,
    dir: Dir,
    name: []const u8,
    arena: Allocator,
) ReadError!T {
    const bytes = try read_bytes(io, dir, name, arena);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    return std.json.parseFromSliceLeaky(T, arena, bytes, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

/// A pid file: decimal digits and a newline.
pub fn read_pid(io: std.Io, dir: Dir, name: []const u8) ReadError!i32 {
    var buffer: [32]u8 = undefined;
    const bytes = dir.readFile(io, name, &buffer) catch |err| switch (err) {
        error.FileNotFound => return error.Absent,
        else => return error.Unreadable,
    };
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, bytes, "\n "), 10) catch
        return error.Unreadable;
    if (pid <= 1) return error.Unreadable; // 0 and 1 are never a container's process.
    return pid;
}

pub fn write_pid(io: std.Io, dir: Dir, name: []const u8, pid: i32) WriteError!void {
    assert(pid > 1);
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}\n", .{pid}) catch unreachable; // 32 bytes hold it.
    try write_atomic(io, dir, name, text);
}

/// True if the file exists.
pub fn exists(io: std.Io, dir: Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

const testing = std.testing;

test "a file is written whole, read back, and absent when it was never written" {
    // Goal: the atomic write and the three read shapes. Method: a temporary directory, write a
    // run record and a pid, read both, read a name that is not there, and corrupt one file.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const run: RunFile = .{ .kind = .signaled, .signal = 9 };
    try write_json(io, tmp.dir, file_run, run);
    const back = try read_json(RunFile, io, tmp.dir, file_run, arena);
    try testing.expectEqual(RunKind.signaled, back.kind);
    try testing.expectEqual(@as(?u8, 9), back.signal);
    try testing.expect(!exists(io, tmp.dir, "run.json.tmp"));

    try write_pid(io, tmp.dir, file_child, 4242);
    try testing.expectEqual(@as(i32, 4242), try read_pid(io, tmp.dir, file_child));
    try testing.expectError(error.Absent, read_pid(io, tmp.dir, file_supervisor));
    try testing.expectError(error.Absent, read_json(RunFile, io, tmp.dir, "nothing", arena));

    try tmp.dir.writeFile(io, .{ .sub_path = file_spec, .data = "not json" });
    try testing.expectError(error.Unreadable, read_json(SpecFile, io, tmp.dir, file_spec, arena));
    try tmp.dir.writeFile(io, .{ .sub_path = file_child, .data = "1\n" });
    try testing.expectError(error.Unreadable, read_pid(io, tmp.dir, file_child));
}
