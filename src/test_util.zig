//! Helpers for tests only.

const std = @import("std");
const assert = std.debug.assert;

/// A comptime string of `count` copies of `byte`, for boundary tests (exact-limit inputs).
/// Zig 0.17 has no `**` array repetition operator, so this stands in for it.
pub fn repeat(comptime byte: u8, comptime count: usize) *const [count:0]u8 {
    comptime assert(count <= 1 << 20); // Tests need small strings; this bounds compile time.
    const storage = comptime blk: {
        var array: [count:0]u8 = undefined;
        @memset(&array, byte);
        const final = array;
        break :blk final;
    };
    return &storage;
}

test "repeat builds exact-length, NUL-terminated strings" {
    // Goal: lengths are exact at 0, 1 and a larger size, so boundary tests are trustworthy.
    try std.testing.expectEqual(@as(usize, 0), repeat('x', 0).len);
    try std.testing.expectEqualStrings("x", repeat('x', 1));
    try std.testing.expectEqual(@as(usize, 300), repeat('y', 300).len);
}
