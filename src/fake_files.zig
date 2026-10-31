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
const agent_records = @import("agent_records.zig");
const agent_state = @import("agent_state.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const file_spec = agent_records.file_spec;
pub const file_run = agent_records.file_run;
pub const file_child = agent_records.file_child;
pub const file_supervisor = agent_records.file_supervisor;
pub const file_lock = agent_records.file_lock;
pub const file_forced = agent_records.file_forced;

pub const Pair = agent_records.Pair;
pub const SpecFile = agent_records.SpecFile;
pub const RunKind = agent_records.RunKind;
pub const Blame = agent_records.Blame;
pub const RunFile = agent_records.RunFile;

pub const WriteError = error{WriteFailed};
pub const ReadError = error{ Absent, Unreadable, OutOfMemory };

/// Writes `data` as `name` in `dir`, whole or not at all, and durably: the temporary file is
/// fsynced before the rename (so a host crash cannot leave the new name on empty contents) and
/// the directory after it (so the rename itself survives). Names are at most
/// `agent_state.name_bytes_max` long, the same limit `SimState` enforces.
pub fn write_atomic(io: std.Io, dir: Dir, name: []const u8, data: []const u8) WriteError!void {
    assert(name.len > 0);
    assert(name.len <= agent_state.name_bytes_max);
    if (data.len > constants.fake_file_bytes_max) return error.WriteFailed;
    var temp: [temp_name_bytes_max]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp, "{s}.tmp", .{name}) catch unreachable; // Sized.
    {
        const file = dir.createFile(io, temp_name, .{}) catch return error.WriteFailed;
        defer file.close(io);
        file.writeStreamingAll(io, data) catch return error.WriteFailed;
        file.sync(io) catch return error.WriteFailed;
    }
    dir.rename(temp_name, dir, name, io) catch return error.WriteFailed;
    sync_dir(io, dir) catch return error.WriteFailed;
}

/// fsync of a directory: opened read-only like a file, which POSIX allows, then synced.
pub fn sync_dir(io: std.Io, dir: Dir) error{WriteFailed}!void {
    const handle = dir.openFile(io, ".", .{}) catch return error.WriteFailed;
    defer handle.close(io);
    handle.sync(io) catch return error.WriteFailed;
}

const temp_name_bytes_max: u32 = agent_state.name_bytes_max + ".tmp".len;

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

/// `AgentState` over a directory: the shell's implementation of the interface that `SimState`
/// models. A name is a path under `root` ("containers/a/spec.json"); a put is `write_atomic`.
/// An append reads the file and writes it back whole and synced, which is stronger than the model
/// allows (the model may lose an unsynced tail), so anything that survives the model survives
/// this. `list` reads one directory: the prefix's directory part, filtered by its last part, with
/// subdirectories shown once as `name/`. A real I/O failure is `error.Io`, never `Crashed`,
/// which only the simulation raises.
pub const DirState = struct {
    io: std.Io,
    root: Dir,

    const vtable: agent_state.AgentState.VTable = .{
        .put_atomic = put_atomic_impl,
        .append = append_impl,
        .read = read_impl,
        .remove = remove_impl,
        .list = list_impl,
    };

    pub fn interface(self: *DirState) agent_state.AgentState {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *DirState {
        return @ptrCast(@alignCast(context));
    }

    /// The directory of `name` (created if `create`) and its last part.
    fn locate(
        self: *DirState,
        name: []const u8,
        create: bool,
    ) agent_state.Error!struct { dir: Dir, base: []const u8, owned: bool } {
        assert(name.len > 0);
        assert(name.len <= agent_state.name_bytes_max);
        const cut = std.mem.lastIndexOfScalar(u8, name, '/') orelse
            return .{ .dir = self.root, .base = name, .owned = false };
        if (create) try self.make_path(name[0..cut]);
        const dir = self.root.openDir(self.io, name[0..cut], .{}) catch |err| switch (err) {
            error.FileNotFound => return error.Absent,
            else => return error.Io,
        };
        return .{ .dir = dir, .base = name[cut + 1 ..], .owned = true };
    }

    /// The directories of `path`, each made durable in its parent, so that a file written below
    /// them is not lost with a directory entry that never reached the disk.
    fn make_path(self: *DirState, path: []const u8) agent_state.Error!void {
        var end: usize = 0;
        while (end < path.len) {
            end = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
            self.root.createDirPath(self.io, path[0..end]) catch return error.Io;
            const cut = std.mem.lastIndexOfScalar(u8, path[0..end], '/');
            const parent = if (cut) |i| path[0..i] else "";
            if (parent.len == 0) {
                sync_dir(self.io, self.root) catch return error.Io;
            } else {
                const dir = self.root.openDir(self.io, parent, .{}) catch return error.Io;
                defer dir.close(self.io);
                sync_dir(self.io, dir) catch return error.Io;
            }
            end += 1;
        }
    }

    fn put_atomic_impl(
        context: *anyopaque,
        name: []const u8,
        data: []const u8,
    ) agent_state.Error!void {
        const self = from(context);
        if (data.len > agent_state.file_bytes_max) return error.TooBig;
        const place = try self.locate(name, true);
        defer if (place.owned) place.dir.close(self.io);
        write_atomic(self.io, place.dir, place.base, data) catch return error.Io;
    }

    fn append_impl(context: *anyopaque, name: []const u8, data: []const u8) agent_state.Error!void {
        const self = from(context);
        var buffer: [constants.fake_file_bytes_max]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const before = read_impl(context, fixed.allocator(), name) catch |err| switch (err) {
            error.Absent => @as([]const u8, ""),
            else => return err,
        };
        if (before.len + data.len > agent_state.file_bytes_max) return error.TooBig;
        const place = try self.locate(name, true);
        defer if (place.owned) place.dir.close(self.io);
        const joined = fixed.allocator().alloc(u8, before.len + data.len) catch return error.TooBig;
        @memcpy(joined[0..before.len], before);
        @memcpy(joined[before.len..], data);
        write_atomic(self.io, place.dir, place.base, joined) catch return error.Io;
    }

    fn read_impl(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) agent_state.Error![]const u8 {
        const self = from(context);
        const place = try self.locate(name, false);
        defer if (place.owned) place.dir.close(self.io);
        return read_bytes(self.io, place.dir, place.base, arena) catch |err| switch (err) {
            error.Absent => error.Absent,
            error.OutOfMemory => error.OutOfMemory,
            error.Unreadable => error.Io,
        };
    }

    fn remove_impl(context: *anyopaque, name: []const u8) agent_state.Error!void {
        const self = from(context);
        const place = try self.locate(name, false);
        defer if (place.owned) place.dir.close(self.io);
        place.dir.deleteFile(self.io, place.base) catch |err| switch (err) {
            error.FileNotFound => return error.Absent,
            else => return error.Io,
        };
        sync_dir(self.io, place.dir) catch return error.Io;
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        prefix: []const u8,
    ) agent_state.Error![]const []const u8 {
        const self = from(context);
        const cut = if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |i| i + 1 else 0;
        const parent = prefix[0..cut];
        var names: std.ArrayList([]const u8) = .empty;
        const open: Dir.OpenOptions = .{ .iterate = true };
        const dir = if (parent.len == 0) self.root else self.root.openDir(
            self.io,
            parent[0 .. parent.len - 1],
            open,
        ) catch return names.items;
        defer if (parent.len > 0) dir.close(self.io);
        var iterator = dir.iterate();
        for (0..constants.fake_dir_entries_max) |_| {
            const entry = (iterator.next(self.io) catch return error.Io) orelse break;
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, prefix[cut..])) continue;
            const slash = if (entry.kind == .directory) "/" else "";
            const full = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ parent, entry.name, slash });
            try names.append(arena, full);
        }
        std.mem.sort([]const u8, names.items, {}, name_less);
        return names.items;
    }

    fn name_less(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

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

test "DirState keeps the AgentState promises the model makes" {
    // Goal: the shell implementation and `SimState` answer the same way. Method: the same calls
    // through `DirState` on a temporary directory: put, read, absent, append, list, remove.
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state: DirState = .{ .io = io, .root = tmp.dir };
    const agent = state.interface();

    try agent.put_atomic("containers/a/spec.json", "one");
    try agent.put_atomic("containers/a/spec.json", "two");
    try testing.expectEqualStrings("two", try agent.read(arena, "containers/a/spec.json"));
    try testing.expectError(error.Absent, agent.read(arena, "containers/b/spec.json"));
    try agent.append("containers/a/log", "ab");
    try agent.append("containers/a/log", "cd");
    try testing.expectEqualStrings("abcd", try agent.read(arena, "containers/a/log"));
    const names = try agent.list(arena, "containers/a/");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("containers/a/log", names[0]);
    const dirs = try agent.list(arena, "containers/");
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expectEqualStrings("containers/a/", dirs[0]);
    try agent.remove("containers/a/log");
    try testing.expectError(error.Absent, agent.remove("containers/a/log"));
}
