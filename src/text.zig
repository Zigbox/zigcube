//! Small text helpers: bounded strings without allocation, and the printable-ASCII rule that
//! keeps terminal escapes out of diagnostics. The same shape as Zigbox's `src/text.zig`, so the
//! diagnostic shim (`diag.zig`) can be replaced by Zigbox's `Diag` without touching callers.

const std = @import("std");
const assert = std.debug.assert;

pub fn is_printable(byte: u8) bool {
    if (byte < 0x20) return false;
    if (byte >= 0x7f) return false;
    return true;
}

/// A fixed-capacity string. Appending past the capacity truncates and ends the text in "...",
/// so a message is always well formed and never overflows.
pub fn Bounded(comptime capacity: u32) type {
    comptime assert(capacity >= 8);
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = undefined,
        len: u32 = 0,
        truncated: bool = false,

        pub fn slice(self: *const Self) []const u8 {
            assert(self.len <= capacity);
            return self.bytes[0..self.len];
        }

        pub fn print(self: *Self, comptime format: []const u8, args: anytype) void {
            assert(self.len <= capacity);
            if (self.truncated) return;
            var writer = std.Io.Writer.fixed(self.bytes[self.len..]);
            writer.print(format, args) catch {
                self.len += @intCast(writer.buffered().len);
                self.truncate();
                return;
            };
            self.len += @intCast(writer.buffered().len);
            assert(self.len <= capacity);
        }

        fn truncate(self: *Self) void {
            self.truncated = true;
            self.len = @min(self.len, capacity);
            if (self.len < 3) self.len = 3;
            @memcpy(self.bytes[self.len - 3 .. self.len], "...");
            assert(self.len <= capacity);
        }
    };
}

test "a bounded string ends in a marker when it overflows and stays that way" {
    // Goal: the boundary where valid becomes invalid. Method: fill a field exactly, then one
    // byte past; the exact fill is untouched and the overflow is cut with "..." and sticks.
    var exact: Bounded(8) = .{};
    exact.print("{s}", .{"12345678"});
    try std.testing.expectEqualStrings("12345678", exact.slice());
    try std.testing.expect(!exact.truncated);

    var over: Bounded(8) = .{};
    over.print("{s}", .{"123456789"});
    try std.testing.expectEqualStrings("12345...", over.slice());
    over.print("{s}", .{"more"});
    try std.testing.expectEqualStrings("12345...", over.slice());
}
