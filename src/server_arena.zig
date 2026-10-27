//! The arena of one request or one controller step, with the size limit STYLE.md asks for: past
//! `limit_bytes` an allocation fails, and the core reports that as ZC-E0207 ("the memory set aside
//! for this request ran out") instead of the process growing without bound. Shell code only
//! because it wraps the process allocator; the core is handed the `Allocator` and never sees this.

const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

/// The allocator interface's own length type, which it fixes.
const Length = usize;

pub const BoundedArena = struct {
    arena: std.heap.ArenaAllocator,
    /// Bytes requested since the last reset (freed bytes are not given back: an arena frees whole).
    used_bytes: u64,
    limit_bytes: u64,

    pub fn init(gpa: Allocator, limit_bytes: u64) BoundedArena {
        assert(limit_bytes > 0);
        return .{ .arena = .init(gpa), .used_bytes = 0, .limit_bytes = limit_bytes };
    }

    pub fn deinit(bounded: *BoundedArena) void {
        bounded.arena.deinit();
        bounded.* = undefined;
    }

    /// Frees everything handed out, keeping the memory for the next use.
    pub fn reset(bounded: *BoundedArena) void {
        _ = bounded.arena.reset(.retain_capacity);
        bounded.used_bytes = 0;
        assert(bounded.used_bytes <= bounded.limit_bytes);
    }

    pub fn allocator(bounded: *BoundedArena) Allocator {
        return .{ .ptr = bounded, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn from(context: *anyopaque) *BoundedArena {
        return @ptrCast(@alignCast(context));
    }

    fn alloc(context: *anyopaque, len: Length, alignment: std.mem.Alignment, ret: Length) ?[*]u8 {
        const bounded = from(context);
        if (len > bounded.limit_bytes - bounded.used_bytes) return null;
        const memory = bounded.arena.allocator().rawAlloc(len, alignment, ret) orelse return null;
        bounded.used_bytes += len;
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Length,
        ret: Length,
    ) bool {
        const bounded = from(context);
        if (new_len > memory.len) {
            if (new_len - memory.len > bounded.limit_bytes - bounded.used_bytes) return false;
        }
        if (!bounded.arena.allocator().rawResize(memory, alignment, new_len, ret)) return false;
        if (new_len > memory.len) bounded.used_bytes += new_len - memory.len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: Length,
        ret: Length,
    ) ?[*]u8 {
        const bounded = from(context);
        if (new_len > memory.len) {
            if (new_len - memory.len > bounded.limit_bytes - bounded.used_bytes) return null;
        }
        const moved = bounded.arena.allocator().rawRemap(memory, alignment, new_len, ret) orelse
            return null;
        if (new_len > memory.len) bounded.used_bytes += new_len - memory.len;
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: Length) void {
        const bounded = from(context);
        bounded.arena.allocator().rawFree(memory, alignment, ret);
    }
};

const testing = std.testing;

test "an allocation past the limit fails, and a reset gives the room back" {
    // Goal: the named limit is real. Method: fill to the limit, fail one byte over, reset, fill
    // again; growth by resize counts too.
    var bounded = BoundedArena.init(testing.allocator, 100);
    defer bounded.deinit();
    const arena = bounded.allocator();
    const first = try arena.alloc(u8, 60);
    try testing.expectEqual(@as(usize, 60), first.len);
    try testing.expectError(error.OutOfMemory, arena.alloc(u8, 41));
    _ = try arena.alloc(u8, 40);
    try testing.expectError(error.OutOfMemory, arena.alloc(u8, 1));
    bounded.reset();
    const again = try arena.alloc(u8, 100);
    try testing.expect(!arena.resize(again, 101));
}
