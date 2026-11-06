//! Test runner of `zig build mtls-teeth`. Zig's own runner passes when a filter selects nothing, so
//! a renamed or mistyped filter would turn the step into a silent pass. This runner counts the
//! selected tests named `teeth:` and fails unless there are at least `teeth_tests_min` of them,
//! then runs each one and fails on the first failure.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Fewer than this many `teeth:` tests means the filter or the test roots broke. The count today
/// is above it; raise it when teeth tests are added.
const teeth_tests_min = 13;

pub fn main(init: std.process.Init.Minimal) !void {
    var count: usize = 0;
    for (builtin.test_functions) |t| {
        if (std.mem.indexOf(u8, t.name, "teeth:") != null) count += 1;
    }
    if (count < teeth_tests_min) {
        std.debug.print("mtls-teeth: only {d} teeth tests selected, expected at least {d}\n", .{
            count, teeth_tests_min,
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
            failed += 1;
        };
        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() != 0) failed += 1;
    }
    if (failed != 0) std.process.exit(1);
    std.debug.print("mtls-teeth: {d} teeth tests passed\n", .{count});
}
