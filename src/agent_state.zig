//! What the node agent persists, behind an interface so that the cluster simulation can crash
//! it. Core code. The shell's implementation is a directory of files (`fake_files.zig`,
//! `DirState`); `SimState` here models what those files guarantee and nothing more.
//!
//! **The guarantees** (what `fake_files.write_atomic` and `DirState` do, and the model's limit):
//!
//! * `put_atomic` writes `<name>.tmp`, fsyncs it, renames it over `<name>`, then fsyncs the
//!   directory (and, when it had to create the directory, the ancestors). After *any* crash,
//!   process or host, at any point inside it, a reader finds the old file or the new one, whole,
//!   plus perhaps a stray `<name>.tmp`, which readers ignore and the next put replaces. Once the
//!   call has returned the new file is durable.
//! * `remove` unlinks and fsyncs the directory. A crash inside it leaves the file or not; a
//!   returned call is durable.
//! * `append` guarantees nothing about durability. A *process* crash keeps what earlier appends
//!   wrote, and a prefix of the one it died in. A *host* crash can lose the unsynced tail of any
//!   file: possibly every append since the file was last put, not only the last. (`DirState`
//!   implements an append as a whole-file put, which is stronger; nothing may depend on that, and
//!   nothing in production appends yet. Whatever must survive a host crash uses `put_atomic`.)
//! * A reader never sees an empty file that a put or an append of non-empty data produced, unless
//!   a host crash cut an append's file down to nothing; readers treat an empty file as absent.
//!
//! Every mutation has write points, numbered from 1 as the simulator arms a crash: a put has two
//! (the temporary file is complete and synced; the rename has landed, before the directory sync),
//! an append one, a remove one. A crash at a write point makes the call fail with
//! `error.Crashed`, and every call after it until `restart`. `crash_now` crashes between calls,
//! at a step boundary, which a write point cannot express.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

/// `Crashed` is the simulated crash and only that. `Io` is the host refusing a real operation
/// (a full disk, a permission): the caller turns it into its own coded diagnostic.
pub const Error = error{ Absent, Crashed, Io, TooBig, OutOfMemory };

/// The longest name, whole path included ("containers/<name>/supervisor.pid"). `DirState` writes
/// the last part through `write_atomic`, whose buffer is sized from this.
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

    /// The entries of one directory whose names start with `prefix`: the directory is the part
    /// of `prefix` up to its last slash, and the entries are full names, in byte order, stray
    /// temporary files included. A subdirectory is listed once, as its name and a slash
    /// ("containers/a/"). A directory with nothing in it, or one that was never created, lists
    /// nothing.
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
    /// How many leading bytes a host crash cannot take away: what the last put synced.
    synced_len: u32,
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
        };
    }

    pub fn deinit(state: *SimState) void {
        for (state.files.items) |file| state.free_file(file);
        state.files.deinit(state.gpa);
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

    /// The crash happens now, between two calls: the agent dies at a step boundary.
    pub fn crash_now(state: *SimState, kind: CrashKind) void {
        assert(!state.crashed);
        state.crash_in = null;
        state.crashed = true;
        if (kind == .host) state.lose_unsynced();
        state.settle();
    }

    /// The agent has been started again: the files are as the crash left them.
    pub fn restart(state: *SimState) void {
        state.crashed = false;
        state.crash_in = null;
    }

    // ---- The crash ----

    /// Counts a write point; true if the crash fires here. The caller finishes whatever the
    /// crash leaves half done and returns `error.Crashed`.
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
        if (state.crash_kind == .host) state.lose_unsynced();
        return true;
    }

    /// A host crash keeps, of each file, everything up to its last sync and a random part of the
    /// rest: the unsynced tail may be gone, all of it.
    fn lose_unsynced(state: *SimState) void {
        for (state.files.items) |*file| {
            if (file.data.len <= file.synced_len) continue;
            const kept = state.prng.random().intRangeAtMost(usize, file.synced_len, file.data.len);
            file.data = state.gpa.realloc(file.data, kept) catch file.data[0..kept];
        }
    }

    /// What survived a crash is on disk now.
    fn settle(state: *SimState) void {
        for (state.files.items) |*file| file.synced_len = @intCast(file.data.len);
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

    /// Replaces or creates `name` with a copy of `data`, synced or not; the old bytes are freed.
    fn store(state: *SimState, name: []const u8, data: []const u8, synced: bool) Error!void {
        const copy = try state.gpa.dupe(u8, data);
        errdefer state.gpa.free(copy);
        const synced_len: u32 = if (synced) @intCast(data.len) else 0;
        if (state.find(name)) |index| {
            state.gpa.free(state.files.items[index].data);
            state.files.items[index].data = copy;
            state.files.items[index].synced_len = synced_len;
            return;
        }
        if (state.files.items.len >= files_max) return error.TooBig;
        const owned = try state.gpa.dupe(u8, name);
        errdefer state.gpa.free(owned);
        try state.files.append(state.gpa, .{
            .name = owned,
            .data = copy,
            .synced_len = synced_len,
        });
    }

    fn drop(state: *SimState, name: []const u8) void {
        const index = state.find(name) orelse return;
        state.free_file(state.files.items[index]);
        _ = state.files.orderedRemove(index);
    }

    fn put_atomic_impl(context: *anyopaque, name: []const u8, data: []const u8) Error!void {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        if (data.len > file_bytes_max) return error.TooBig;
        var temp_buffer: [name_bytes_max + temp_suffix.len]u8 = undefined;
        const temp = std.fmt.bufPrint(&temp_buffer, "{s}{s}", .{ name, temp_suffix }) catch
            unreachable; // The buffer holds the longest name and the suffix.
        // Write point 1: the temporary file is complete and synced, the rename has not happened.
        try state.store(temp, data, true);
        if (state.point()) return error.Crashed;
        // Write point 2: the rename has landed whole, the directory has not been synced.
        const old: ?[]u8 = if (state.find(name)) |index|
            try state.gpa.dupe(u8, state.files.items[index].data)
        else
            null;
        defer if (old) |bytes| state.gpa.free(bytes);
        try state.store(name, data, true);
        state.drop(temp);
        if (!state.point()) return;
        // The rename may not have reached the disk: the old file (whole) or none, and the
        // temporary file is back. Or it did. Either way every file is whole.
        if (state.crash_kind != .host) return error.Crashed;
        if (!state.prng.random().boolean()) return error.Crashed;
        if (old) |bytes| try state.store(name, bytes, true) else state.drop(name);
        try state.store(temp, data, true);
        return error.Crashed;
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
        // The point may have cut the file's unsynced tail (a host crash): append to what is left.
        const base = state.find(name);
        const have: usize = if (base) |i| state.files.items[i].data.len else 0;
        const synced: u32 = if (base) |i| state.files.items[i].synced_len else 0;
        const joined = try state.gpa.alloc(u8, have + kept);
        defer state.gpa.free(joined);
        if (base) |i| @memcpy(joined[0..have], state.files.items[i].data);
        @memcpy(joined[have..], data[0..kept]);
        try state.store(name, joined, false);
        state.files.items[state.find(name).?].synced_len = synced; // Stored just above.
        if (crashes) {
            state.settle();
            return error.Crashed;
        }
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
        if (state.find(name) == null) return error.Absent;
        state.drop(name);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        prefix: []const u8,
    ) Error![]const []const u8 {
        const state = from(context);
        if (state.crashed) return error.Crashed;
        const cut = if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |i| i + 1 else 0;
        var names: std.ArrayList([]const u8) = .empty;
        for (state.files.items) |file| {
            if (!std.mem.startsWith(u8, file.name, prefix)) continue;
            const entry = if (std.mem.indexOfScalar(u8, file.name[cut..], '/')) |slash|
                file.name[0 .. cut + slash + 1]
            else
                file.name;
            try names.append(arena, try arena.dupe(u8, entry));
        }
        std.mem.sort([]const u8, names.items, {}, name_less);
        var unique: usize = 0;
        for (names.items) |entry| {
            if (unique > 0) {
                if (std.mem.eql(u8, names.items[unique - 1], entry)) continue;
            }
            names.items[unique] = entry;
            unique += 1;
        }
        return names.items[0..unique];
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

test "list shows a subdirectory once, as its name and a slash" {
    // Goal: the directory semantics `DirState` shares. Method: files in two subdirectories and at
    // the top, listed by a directory prefix and by a name prefix.
    var state = SimState.init(testing.allocator, 1);
    defer state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent = state.interface();
    try agent.put_atomic("containers/a/spec.json", "1");
    try agent.put_atomic("containers/a/run.json", "2");
    try agent.put_atomic("containers/b/spec.json", "3");
    try agent.put_atomic("other", "4");
    const dirs = try agent.list(arena, "containers/");
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings("containers/a/", dirs[0]);
    try testing.expectEqualStrings("containers/b/", dirs[1]);
    const inside = try agent.list(arena, "containers/a/s");
    try testing.expectEqual(@as(usize, 1), inside.len);
    try testing.expectEqualStrings("containers/a/spec.json", inside[0]);
    try testing.expectEqual(@as(usize, 0), (try agent.list(arena, "nothing/")).len);
}

test "a put is whole after every crash, at every write point, of both kinds" {
    // Goal: the narrowed model. Method: for each write point of a put over an old file and each
    // crash kind, over many seeds: the file is the old bytes or the new ones, never empty or
    // torn; a host crash can undo the rename (old again) and a process crash never does; both
    // outcomes occur. A put into an empty state leaves the new file or none.
    var seen_new_after_rename = false;
    var seen_undone = false;
    for (0..64) |seed| {
        for ([_]CrashKind{ .process, .host }) |kind| {
            for (1..3) |at| {
                var state = SimState.init(testing.allocator, seed);
                defer state.deinit();
                var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const agent = state.interface();
                try agent.put_atomic("run.json", "old");
                state.arm_crash(@intCast(at), kind);
                try testing.expectError(error.Crashed, agent.put_atomic("run.json", "new"));
                state.restart();
                const text = try agent.read(arena, "run.json");
                const is_old = std.mem.eql(u8, text, "old");
                try testing.expect(is_old or std.mem.eql(u8, text, "new"));
                if (at == 1) try testing.expect(is_old); // The rename had not happened.
                if (at == 2) {
                    if (kind == .process) try testing.expect(!is_old);
                    if (!is_old) seen_new_after_rename = true;
                    if (is_old) seen_undone = true;
                }
                var blank = SimState.init(testing.allocator, seed);
                defer blank.deinit();
                blank.arm_crash(@intCast(at), kind);
                try testing.expectError(
                    error.Crashed,
                    blank.interface().put_atomic("run.json", "new"),
                );
                blank.restart();
                if (blank.interface().read(arena, "run.json")) |only| {
                    try testing.expectEqualStrings("new", only);
                } else |err| try testing.expectEqual(error.Absent, err);
            }
        }
    }
    try testing.expect(seen_new_after_rename);
    try testing.expect(seen_undone);
}

test "a host crash can lose every append since the last put, a process crash none" {
    // Goal: the unsynced tail. Method: put a file, append three times, crash between calls with
    // `crash_now`, over many seeds: a host crash leaves a prefix of the appended text, at least
    // the put's bytes, and every length from none of the appends to all of them occurs; a
    // process crash keeps all of it.
    var lengths: [4]bool = @splat(false);
    for (0..64) |seed| {
        var state = SimState.init(testing.allocator, seed);
        defer state.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const agent = state.interface();
        try agent.put_atomic("log", "base;");
        try agent.append("log", "a;");
        try agent.append("log", "b;");
        try agent.append("log", "c;");
        state.crash_now(.host);
        try testing.expectError(error.Crashed, agent.read(arena, "log"));
        state.restart();
        const text = try agent.read(arena, "log");
        const full = "base;a;b;c;";
        try testing.expect(text.len >= "base;".len);
        try testing.expect(text.len <= full.len);
        try testing.expectEqualStrings(full[0..text.len], text);
        lengths[(text.len - "base;".len) / 2 + @intFromBool((text.len - "base;".len) % 2 != 0)] =
            true;
        // Whatever survived is durable: a second host crash changes nothing.
        state.crash_now(.host);
        state.restart();
        try testing.expectEqualStrings(text, try agent.read(arena, "log"));
    }
    try testing.expect(lengths[0]);
    try testing.expect(lengths[3]);
    var state = SimState.init(testing.allocator, 9);
    defer state.deinit();
    const agent = state.interface();
    try agent.put_atomic("log", "base;");
    try agent.append("log", "a;");
    state.crash_now(.process);
    state.restart();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("base;a;", try agent.read(arena_state.allocator(), "log"));
}
