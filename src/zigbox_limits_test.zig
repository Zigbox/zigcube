//! Shell-side test (not in `core.zig`: it reads the pinned `zigbox` package's file): each
//! `constants.job_limit_*` is the bound Zigbox's runtime enforces, so a pin bump that moves one
//! fails here instead of drifting (a job accepted at submit and refused when it starts).
//!
//! The `zigbox` module does not export its `constants.zig`, and a file cannot belong to two
//! modules, so the build embeds the pinned file as text (`zigbox_constants_text`) and this test
//! reads the six `limit_*` declarations out of it.

const std = @import("std");
const constants = @import("constants.zig");

const text = @embedFile("zigbox_constants_text");

/// The value of `pub const <name>: <type> = <expression>;` where the expression is integer
/// literals joined by `*` or `<<`, read left to right (as Zigbox writes them).
fn zigbox_value(name: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " ;:");
        if (!std.mem.eql(u8, parts.next() orelse "", "pub")) continue;
        if (!std.mem.eql(u8, parts.next() orelse "", "const")) continue;
        if (!std.mem.eql(u8, parts.next() orelse "", name)) continue;
        _ = parts.next(); // the type
        if (!std.mem.eql(u8, parts.next() orelse "", "=")) return error.Unreadable;
        var value = try number(parts.next() orelse return error.Unreadable);
        while (parts.next()) |operator| {
            const operand = try number(parts.next() orelse return error.Unreadable);
            if (std.mem.eql(u8, operator, "*")) {
                value *= operand;
            } else if (std.mem.eql(u8, operator, "<<")) {
                value <<= @intCast(operand);
            } else return error.Unreadable;
        }
        return value;
    }
    return error.Missing;
}

fn number(word: []const u8) !u64 {
    return std.fmt.parseInt(u64, word, 10); // underscores are accepted
}

test "each job_limit_* equals the bound of the pinned zigbox runtime" {
    // Goal: RA-N1 (#180). Method: read Zigbox's `limit_*` constants from the pinned file and
    // compare. All six have a counterpart; none is left without one.
    const pairs = [_]struct { name: []const u8, ours: u64 }{
        .{ .name = "limit_cpu_millis_min", .ours = constants.job_limit_cpu_millis_min },
        .{ .name = "limit_cpu_millis_max", .ours = constants.job_limit_cpu_millis_max },
        .{ .name = "limit_memory_bytes_min", .ours = constants.job_limit_memory_bytes_min },
        .{ .name = "limit_memory_bytes_max", .ours = constants.job_limit_memory_bytes_max },
        .{ .name = "limit_pids_min", .ours = constants.job_limit_pids_min },
        .{ .name = "limit_pids_max", .ours = constants.job_limit_pids_max },
    };
    for (pairs) |pair| {
        try std.testing.expectEqual(try zigbox_value(pair.name), pair.ours);
    }
}

test "the reader of zigbox's constants reads products and shifts, and reports a missing name" {
    const min = try zigbox_value("limit_memory_bytes_min");
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), min);
    try std.testing.expectEqual(@as(u64, 1 << 40), try zigbox_value("limit_memory_bytes_max"));
    try std.testing.expectError(error.Missing, zigbox_value("limit_no_such_bound"));
}
