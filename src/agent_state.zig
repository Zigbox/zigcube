//! What the node agent persists, behind an interface so that the cluster simulation can crash
//! it. Core code. The shell's implementation is a directory of files (`fake_files.zig`,
//! `DirState`);
//! `SimState` here models what those files guarantee and nothing more:
//!
//! * `put_atomic` writes `<name>.tmp` and renames it over `<name>`. A reader sees the old file or
//!   the new one, never half of one. A crash between the two steps leaves the old file and a
//!   stray `<name>.tmp`, which readers ignore and the next write replaces.
//! * `append` can lose its tail: a crash keeps only a prefix of what the last append wrote.
//! * Neither syncs. Against the *agent process* dying that is enough (the page cache survives).
//!   Against the *host* dying, a rename that was not followed by an fsync of the directory may be
//!   undone, and the new file may even be empty: `SimState.crash_host` models that, and it is the
//!   one place where `fake_files.write_atomic` is not crash-safe (docs/agent.md).
//!
//! Every mutation has write points, numbered from 1 as the simulator arms a crash: a put has two
//! (the temporary file, then the rename), an append one, a remove one. A crash at a write point
//! makes the call fail with `error.Crashed`, and every call after it until `restart`.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ Absent, Crashed, TooBig, OutOfMemory };

pub const name_bytes_max: u32 = 96;
pub const file_bytes_max: u32 = constants.fake_file_bytes_max;
pub const files_max: u32 = 256;

pub const AgentState = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put_atomic: *const fn (context: *anyopaque, name: []const u8, data: []const u8) Error!void,
        append: *const fn (context: *anyopaque, name: []const u8, data: []const u8) Error!void,
        read: *const fn (context: *anyopaque, arena: Allocator, name: []const u8) Error![]const u8,
        remove: *const fn (context: *anyopaque, name: []const u8) Error!void,
        list: *const fn (
            context: *anyopaque,
            arena: Allocator,
            prefix: []const u8,
        ) Error![]const []const u8,
    };

    /// Whole or not at all, even if the agent dies in the middle.
    pub fn put_atomic(state: AgentState, name: []const u8, data: []const u8) Error!void {
        assert(name.len > 0);
        assert(name.len <= name_bytes_max);
        return state.vtable.put_atomic(state.context, name, data);
    }

    /// Adds to the end of `name`, creating it. A crash may keep only part of `data`.
    pub fn append(state: AgentState, name: []const u8, data: []const u8) Error!void {
        assert(name.len > 0);
        assert(name.len <= name_bytes_max);
        return state.vtable.append(state.context, name, data);
    }

    pub fn read(state: AgentState, arena: Allocator, name: []const u8) Error![]const u8 {
        assert(name.len > 0);
        return state.vtable.read(state.context, arena, name);
    }

    pub fn remove(state: AgentState, name: []const u8) Error!void {
        assert(name.len > 0);
        return state.vtable.remove(state.context, name);
    }

    /// The names that start with `prefix`, in byte order, stray temporary files included.
    pub fn list(state: AgentState, arena: Allocator, prefix: []const u8) Error![]const []const u8 {
        return state.vtable.list(state.context, arena, prefix);
    }
};

pub const temp_suffix = ".tmp";

pub fn is_temp(name: []const u8) bool {
    return std.mem.endsWith(u8, name, temp_suffix);
}

const File = struct {
    name: []u8,
    data: []u8,
};

/// Which kind of crash `SimState` imitates when it fires.
pub const CrashKind = enum { process, host };

pub const SimState = struct {
    gpa: Allocator,
    files: std.ArrayList(File),
    prng: std.Random.DefaultPrng,
    /// Write points left before the crash; null when none is armed.
    crash_in: ?u32,
    crash_kind: CrashKind,
    crashed: bool,
    /// Write points passed since `init`, which tells a test how many there are to crash at.
    points: u32,
    /// The last rename that has not been synced, for a host crash to undo.
    unsynced: ?Unsynced,

    const Unsynced = struct { name: []u8, old: ?[]u8 };

    const vtable: AgentState.VTable = .{
        .put_atomic = put_atomic_impl,
        .append = append_impl,
        .read = read_impl,
        .remove = remove_impl,
        .list = list_impl,
    };

    pub fn init(gpa: Allocator, seed: u64) SimState {
        return .{
            .gpa = gpa,
            .files = .empty,
            .prng = .init(seed),
            .crash_in = null,
            .crash_kind = .process,
            .crashed = false,
            .points = 0,
            .unsynced = null,
        };
    }

    pub fn deinit(state: *SimState) void {
        for (state.files.items) |file| state.free_file(file);
        state.files.deinit(state.gpa);
        state.forget_unsynced();
        state.* = undefined;
    }

    pub fn interface(state: *SimState) AgentState {
        return .{ .context = state, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *SimState {
        return @ptrCast(@alignCast(context));
    }

    /// The crash fires at the `after`th write point from now (1 is the next one).
    pub fn arm_crash(state: *SimState, after: u32, kind: CrashKind) void {
        assert(after > 0);
        assert(!state.crashed);
        state.crash_in = after;
        state.crash_kind = kind;
    }

    /// The agent has been started again: the files are as the crash left them.
    pub fn restart(state: *SimState) void {
        state.crashed = false;
        state.crash_in = null;
        state.forget_unsynced();
    }

    // ---- The crash ----

    /// Counts a write point; true if the crash fires here.
    fn point(state: *SimState) bool {
        assert(!state.crashed);
        state.points += 1;
        const left = state.crash_in orelse return false;
        if (left > 1) {
            state.crash_in = left - 1;
            return false;
        }
        state.crash_in = null;
        state.crashed = true;
        if (state.crash_kind == .host) state.undo_unsynced();
        return true;
    }

    /// A host crash may undo the last rename, or leave the new name empty: the rename was in the
    /// page cache, the data possibly not on disk.
    fn undo_unsynced(state: *SimState) void {
        const pending = state.unsynced orelse return;
        const index = state.find(pending.name) orelse return;
        const empty = state.prng.random().boolean();
        const file = &state.files.items[index];
        if (pending.old) |old| {
            if (!empty) {
                // Best effort: if the copy fails the new file stays, which is also allowed.
                const copy = state.gpa.dupe(u8, old) catch return;
                state.gpa.free(file.data);
                file.data = copy;
                return;
            }
        } else if (!empty) {
            state.free_file(file.*);
            _ = state.files.orderedRemove(index);
            return;
        }
        state.gpa.free(file.data);
        file.data = &.{};
    }

    fn forget_unsynced(state: *SimState) void {
        const pending = state.unsynced orelse return;
        state.gpa.free(pending.name);
        if (pending.old) |old| state.gpa.free(old);
        state.unsynced = null;
    }

    // ---- The files ----

    fn free_file(state: *SimState, file: File) void {
        state.gpa.free(file.name);
        state.gpa.free(file.data);
    }

    fn find(state: *const SimState, name: []const u8) ?usize {
        for (state.files.items, 0..) |file, index| {
            if (std.mem.eql(u8, file.name, name)) return index;
        }
        return null;
    }

    /// Replaces or creates `name` with a copy of `data`; the old bytes are freed.
    fn store(state: *SimState, name: []const u8, data: []const u8) Error!void {
        const copy = try state.gpa.dupe(u8, data);
        errdefer state.gpa.free(copy);
        if (state.find(name)) |index| {
            state.gpa.free(state.files.items[index].data);
            state.files.items[index].data = copy;
            return;
        }
        if (state.files.items.len >= files_max) return error.TooBig;
        const owned = try state.gpa.dupe(u8, name);
        errdefer state.gpa.free(owned);
        try state.files.append(state.gpa, .{ .name = owned, .data = copy });
    }

    fn put_atomic_impl(context: *anyopaque, name: []const u8, data: []const u8) Error!void {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        if (data.len > file_bytes_max) return error.TooBig;
        var temp_buffer: [name_bytes_max + temp_suffix.len]u8 = undefined;
        const temp = std.fmt.bufPrint(&temp_buffer, "{s}{s}", .{ name, temp_suffix }) catch
            unreachable; // The buffer holds the longest name and the suffix.
        // Write point 1: the temporary file is complete, the rename has not happened.
        try state.store(temp, data);
        if (state.point()) return error.Crashed;
        // Write point 2: the rename lands the new file whole.
        const old: ?[]u8 = if (state.find(name)) |index|
            try state.gpa.dupe(u8, state.files.items[index].data)
        else
            null;
        errdefer if (old) |bytes| state.gpa.free(bytes);
        try state.store(name, data);
        const temp_index = state.find(temp).?; // Stored above and not removed since.
        state.free_file(state.files.items[temp_index]);
        _ = state.files.orderedRemove(temp_index);
        state.forget_unsynced();
        state.unsynced = .{ .name = try state.gpa.dupe(u8, name), .old = old };
        if (state.point()) return error.Crashed;
    }

    fn append_impl(context: *anyopaque, name: []const u8, data: []const u8) Error!void {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        const index = state.find(name);
        const before: usize = if (index) |i| state.files.items[i].data.len else 0;
        if (before + data.len > file_bytes_max) return error.TooBig;
        // One write point. If the crash fires here, a prefix of `data` got to the file.
        const crashes = state.point();
        const kept = if (crashes) state.prng.random().uintAtMost(usize, data.len) else data.len;
        const joined = try state.gpa.alloc(u8, before + kept);
        defer state.gpa.free(joined);
        if (index) |i| @memcpy(joined[0..before], state.files.items[i].data);
        @memcpy(joined[before..], data[0..kept]);
        try state.store(name, joined);
        if (crashes) return error.Crashed;
    }

    fn read_impl(context: *anyopaque, arena: Allocator, name: []const u8) Error![]const u8 {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        const index = state.find(name) orelse return error.Absent;
        return arena.dupe(u8, state.files.items[index].data);
    }

    fn remove_impl(context: *anyopaque, name: []const u8) Error!void {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        if (state.point()) return error.Crashed;
        const index = state.find(name) orelse return error.Absent;
        state.free_file(state.files.items[index]);
        _ = state.files.orderedRemove(index);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        prefix: []const u8,
    ) Error![]const []const u8 {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        var names: std.ArrayList([]const u8) = .empty;
        for (state.files.items) |file| {
            if (!std.mem.startsWith(u8, file.name, prefix)) continue;
            try names.append(arena, try arena.dupe(u8, file.name));
        }
        std.mem.sort([]const u8, names.items, {}, name_less);
        return names.items;
    }

    fn name_less(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

const testing = std.testing;

test "a put is whole, an append can lose its tail, and a stray temporary file is listed" {
    // Goal: the guarantees the model gives. Method: put, read, append, remove; then crash a put at
    // its first write point (old file and a stray temporary) and an append (a prefix).
    var state = SimState.init(testing.allocator, 1);
    defer state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent = state.interface();

    try agent.put_atomic("containers/a/spec.json", "one");
    try testing.expectEqualStrings("one", try agent.read(arena, "containers/a/spec.json"));
    try testing.expectError(error.Absent, agent.read(arena, "nothing"));

    state.arm_crash(1, .process);
    try testing.expectError(error.Crashed, agent.put_atomic("containers/a/spec.json", "two"));
    try testing.expectError(error.Crashed, agent.read(arena, "containers/a/spec.json"));
    state.restart();
    try testing.expectEqualStrings("one", try agent.read(arena, "containers/a/spec.json"));
    const names = try agent.list(arena, "containers/a/");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expect(is_temp(names[1]));
    try agent.put_atomic("containers/a/spec.json", "three");
    try testing.expectEqualStrings("three", try agent.read(arena, "containers/a/spec.json"));

    try agent.append("log", "abc");
    state.arm_crash(1, .process);
    try testing.expectError(error.Crashed, agent.append("log", "defgh"));
    state.restart();
    const kept = try agent.read(arena, "log");
    try testing.expect(kept.len >= 3 and kept.len <= 8);
    try testing.expectEqualStrings("abc", kept[0..3]);
    try testing.expectEqualStrings("defgh"[0 .. kept.len - 3], kept[3..]);
    try agent.remove("log");
    try testing.expectError(error.Absent, agent.remove("log"));
}

test "a host crash may undo the last rename; a process crash never does" {
    // Goal: the one place the files are not crash-safe. Method: put twice, crash the host at the
    // next write point over many seeds and see old, empty and new all occur; a process crash
    // after the rename always leaves the new bytes.
    var saw_old = false;
    var saw_empty = false;
    for (0..64) |seed| {
        var state = SimState.init(testing.allocator, seed);
        defer state.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const agent = state.interface();
        try agent.put_atomic("run.json", "old");
        try agent.put_atomic("run.json", "new");
        state.arm_crash(1, .host);
        try testing.expectError(error.Crashed, agent.append("other", "x"));
        state.restart();
        const text = try agent.read(arena_state.allocator(), "run.json");
        if (std.mem.eql(u8, text, "old")) saw_old = true;
        if (text.len == 0) saw_empty = true;
        try testing.expect(std.mem.eql(u8, text, "old") or std.mem.eql(u8, text, "new") or
            text.len == 0);
    }
    try testing.expect(saw_old);
    try testing.expect(saw_empty);
    var state = SimState.init(testing.allocator, 3);
    defer state.deinit();
    const agent = state.interface();
    try agent.put_atomic("run.json", "old");
    try agent.put_atomic("run.json", "new");
    state.arm_crash(1, .process);
    try testing.expectError(error.Crashed, agent.remove("other"));
    state.restart();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("new", try agent.read(arena_state.allocator(), "run.json"));
}
