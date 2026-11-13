//! Test runner of `zig build mtls-teeth`. Zig's own runner passes when a filter selects nothing, so
//! a renamed or mistyped filter would turn the step into a silent pass. This runner counts the
//! selected tests named `teeth:` and fails unless there are exactly `teeth_tests` of them, then
//! runs each one and fails if any fails. A test that skips (`error.SkipZigTest`) counts as a
//! failure on purpose: a skipped tooth proves nothing.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The exact number of `teeth:` tests. Fewer means the filter or the test roots broke, more means
/// this constant is stale; change it in the same commit that adds or removes a tooth.
const teeth_tests = 26;

pub fn main(init: std.process.Init.Minimal) !void {
    var count: usize = 0;
    for (builtin.test_functions) |t| {
        if (std.mem.indexOf(u8, t.name, "teeth:") != null) count += 1;
    }
    if (count != teeth_tests) {
        std.debug.print("mtls-teeth: {d} teeth tests selected, expected exactly {d}\n", .{
            count, teeth_tests,
        });
        std.process.exit(1);
    }
    var failed: usize = 0;
    for (builtin.test_functions) |t| {
        if (std.mem.indexOf(u8, t.name, "teeth:") == null) continue;
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;
        std.testing.log_level = .warn;
        t.func() catch |err| {
            std.debug.print("FAIL {s} ({t})\n", .{ t.name, err });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            failed += 1;
        };
        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() != 0) failed += 1;
    }
    if (failed != 0) std.process.exit(1);
    std.debug.print("mtls-teeth: {d} teeth tests passed\n", .{count});
}
