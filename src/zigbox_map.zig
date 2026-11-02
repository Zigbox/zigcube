//! The mapping between Zigbox's types and Zigcube's `Runtime` types, with no I/O: C2 slice 1,
//! the pure part of `ZigboxRuntime` (docs/briefs/c2-1.md). Shell code (it imports the `zigbox`
//! runtime, which reads files), but every function here takes values and returns values, so
//! every variant has a table test and the I/O parts that use it stay thin.
//!
//! What maps to what:
//!
//!   - `zigbox.ExitReason` to `runtime.ExitReason`: `exited`, `signaled`, `oom` and `pid_limit`
//!     keep their meaning (what PID 1 did on top of an OOM or a pid limit is dropped; Zigcube
//!     records the reason). `start_failed` carries the diagnostic across (`from_diag`). `lost`
//!     becomes `lost` with no diagnostic: a list entry does not keep Zigbox's explanation, and
//!     the contract allows null.
//!   - A list `Entry` to a `Status`: `running` is `running`, `lost` is `stopped(lost)`, and a
//!     stopped container's reason is read from its record. A `start_failed` record prefers the
//!     diagnostic JSON line the record kept over the code-only one `exit_reason_of` makes.
//!   - A record's labels to `runtime.Label`, copied into the caller's arena.
//!   - `runtime.Limits` to `zigbox.Limits` (same fields, same units).

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const runtime = @import("runtime.zig");
const diag_mod = @import("diag.zig");
const Diagnostic = diag_mod.Diagnostic;

const records = zigbox.records;

/// `out` receives the reason; it is written in place because a `Diagnostic` is several kilobytes.
pub fn exit_reason(out: *runtime.ExitReason, reason: *const zigbox.ExitReason) void {
    switch (reason.*) {
        .exited => |code| out.* = .{ .exited = code },
        .signaled => |number| out.* = .{ .signaled = number },
        .oom => out.* = .oom,
        .pid_limit => out.* = .pid_limit,
        .lost => out.* = .{ .lost = null },
        .start_failed => |*diag| {
            out.* = .{ .start_failed = undefined };
            zigbox.diagnostic.from_diag(&out.start_failed, diag);
            assert(out.start_failed.code.len > 0);
        },
    }
}

/// The status of a listed container. A stopped container whose record kept a diagnostic line
/// for a failed start gets that diagnostic, with its causes and fixes, not only its code.
pub fn status(out: *runtime.Status, entry: *const zigbox.Entry) void {
    assert(entry.record.name_len > 0);
    switch (entry.state) {
        .running => out.* = .running,
        .lost => out.* = .{ .stopped = .{ .lost = null } },
        .stopped => {
            out.* = .{ .stopped = undefined };
            stopped_reason(&out.stopped, &entry.record);
        },
    }
}

fn stopped_reason(out: *runtime.ExitReason, record: *const records.Parsed) void {
    const reason = zigbox.lifecycle.exit_reason_of(record);
    exit_reason(out, &reason);
    if (reason != .start_failed) return;
    const line = record.diagnostic_slice();
    if (line.len == 0) return;
    var parsed: Diagnostic = undefined;
    zigbox.diagnostic.parse_json(&parsed, line) catch return; // Keep the code-only diagnostic.
    if (parsed.code.len == 0) return;
    out.start_failed = parsed;
}

/// The record's labels, copied into `arena`. Null if the arena is out of memory.
pub fn labels(arena: std.mem.Allocator, record: *const records.Parsed) ?[]const runtime.Label {
    const count: u32 = record.labels_count;
    const result = arena.alloc(runtime.Label, count) catch return null;
    for (result, 0..) |*label, index| {
        const pair = record.label(@intCast(index));
        const key = arena.dupe(u8, pair[0]) catch return null;
        const value = arena.dupe(u8, pair[1]) catch return null;
        label.* = .{ .key = key, .value = value };
    }
    return result;
}

pub fn limits(source: runtime.Limits) zigbox.Limits {
    return .{
        .memory_bytes = source.memory_bytes,
        .pids = source.pids,
        .cpu_millis = source.cpu_millis,
    };
}

/// Why a `runtime.Spec` cannot be given to Zigbox as it is. Zigcube's limits are Zigbox's since
/// C2 slice 1 (P3), so `runtime.spec_problem` catches the counts; what is left is what Zigbox
/// bounds that Zigcube's spec check does not.
pub const Refusal = enum {
    env_name_empty,
    env_name_too_long,
    env_value_too_long,
    name_too_long,
    command_too_long,
};

/// Zigbox's bounds (its `constants.zig`, which the `zigbox` module does not export: a gap to
/// report). The values are those of Zigbox 0.2.1; a start that exceeds one of them would be
/// refused by Zigbox anyway, this makes the refusal Zigcube's, with a coded diagnostic.
pub const bounds = struct {
    pub const container_name_bytes_max: usize = 63;
    pub const env_name_bytes_max: usize = 64;
    pub const env_value_bytes_max: usize = 4096;
    pub const record_command_bytes_max: usize = 2048;
};

pub fn refusal(spec: *const runtime.Spec) ?Refusal {
    const constants = bounds;
    if (spec.name.len > constants.container_name_bytes_max) return .name_too_long;
    for (spec.env) |pair| {
        if (pair.name.len == 0) return .env_name_empty;
        if (pair.name.len > constants.env_name_bytes_max) return .env_name_too_long;
        if (pair.value.len > constants.env_value_bytes_max) return .env_value_too_long;
    }
    var bytes: usize = 0;
    for (spec.command) |word| bytes += word.len + 1;
    if (bytes > constants.record_command_bytes_max) return .command_too_long;
    return null;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const repeat = @import("test_util.zig").repeat;

test "every Zigbox exit reason maps to the matching Zigcube one" {
    // Goal: no variant is dropped or crossed. Method: one row per variant.
    var out: runtime.ExitReason = undefined;
    exit_reason(&out, &.{ .exited = 3 });
    try testing.expectEqual(@as(u8, 3), out.exited);
    exit_reason(&out, &.{ .signaled = 9 });
    try testing.expectEqual(@as(u8, 9), out.signaled);
    exit_reason(&out, &.{ .oom = .{ .limit_bytes = 1 << 20, .ended = .{ .signaled = 9 } } });
    try testing.expect(out == .oom);
    exit_reason(&out, &.{ .pid_limit = .{ .limit = 8, .ended = .{ .exited = 1 } } });
    try testing.expect(out == .pid_limit);
    exit_reason(&out, &.lost);
    try testing.expect(out == .lost);
    try testing.expect(out.lost == null);
}

test "a failed start carries its Zigbox diagnostic across" {
    // Goal: the code, the blame and the summary of Zigbox's registry arrive unchanged.
    var diag: zigbox.diag.Diag = undefined;
    diag.reset();
    diag.raise(.E0410);
    diag.cause("no tree in the store has a digest that starts with 'b3:00ff'", .{});
    const reason: zigbox.ExitReason = .{ .start_failed = diag };
    var out: runtime.ExitReason = undefined;
    exit_reason(&out, &reason);
    try testing.expectEqualStrings("ZBX-E0410", out.start_failed.code.slice());
    try testing.expectEqualStrings("no tree with that digest", out.start_failed.summary.slice());
    try testing.expectEqual(@as(usize, 1), out.start_failed.causes.slice().len);
}

fn record_of(exit: records.Exit, reason: records.EndReason) records.Parsed {
    var record: records.Parsed = undefined;
    record.version = 1;
    record.name_len = 3;
    @memcpy(record.name[0..3], "web");
    record.exit = exit;
    record.reason = reason;
    record.limits = .{ .memory_bytes = 1 << 20, .pids = 8 };
    record.diagnostic_len = 0;
    record.labels_count = 0;
    record.labels_len = 0;
    return record;
}

fn entry_of(state: zigbox.lifecycle.State, record: records.Parsed) zigbox.Entry {
    return .{ .state = state, .has_record = true, .record = record };
}

test "a listed container's state and record give the status" {
    // Goal: running, lost, and each way a record can say a container ended.
    var out: runtime.Status = undefined;
    var entry = entry_of(.running, record_of(.running, .none));
    status(&out, &entry);
    try testing.expect(out == .running);

    entry = entry_of(.lost, record_of(.running, .none));
    status(&out, &entry);
    try testing.expect(out.stopped == .lost);
    try testing.expect(out.stopped.lost == null);

    entry = entry_of(.stopped, record_of(.{ .exited = 0 }, .exited));
    status(&out, &entry);
    try testing.expectEqual(@as(u8, 0), out.stopped.exited);

    entry = entry_of(.stopped, record_of(.{ .signaled = 15 }, .signal));
    status(&out, &entry);
    try testing.expectEqual(@as(u8, 15), out.stopped.signaled);

    entry = entry_of(.stopped, record_of(.{ .signaled = 9 }, .oom));
    status(&out, &entry);
    try testing.expect(out.stopped == .oom);

    entry = entry_of(.stopped, record_of(.{ .exited = 1 }, .pid_limit));
    status(&out, &entry);
    try testing.expect(out.stopped == .pid_limit);

    entry = entry_of(.stopped, record_of(.lost, .none));
    status(&out, &entry);
    try testing.expect(out.stopped == .lost);
}

test "a failed-start record prefers the diagnostic line it kept" {
    // Goal: the code-only diagnostic of `exit_reason_of` is replaced by the stored one, and a
    // damaged line falls back to the code-only one.
    var record = record_of(.{ .start_failed = .E0410 }, .none);
    var out: runtime.Status = undefined;
    var entry = entry_of(.stopped, record);
    status(&out, &entry);
    try testing.expectEqualStrings("ZBX-E0410", out.stopped.start_failed.code.slice());
    try testing.expectEqual(@as(usize, 1), out.stopped.start_failed.causes.slice().len);

    const line = "{\"code\":\"ZBX-E0410\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"no tree with that digest\"," ++
        "\"causes\":[\"first\",\"second\"],\"while\":[],\"context\":{}," ++
        "\"fixes\":[],\"omitted\":{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}}";
    @memcpy(record.diagnostic[0..line.len], line);
    record.diagnostic_len = line.len;
    entry = entry_of(.stopped, record);
    status(&out, &entry);
    try testing.expectEqual(@as(usize, 2), out.stopped.start_failed.causes.slice().len);

    @memcpy(record.diagnostic[0..3], "{{{");
    record.diagnostic_len = 3;
    entry = entry_of(.stopped, record);
    status(&out, &entry);
    try testing.expectEqual(@as(usize, 1), out.stopped.start_failed.causes.slice().len);
}

test "labels come out of a record in order and are copied" {
    var record = record_of(.running, .none);
    const text = "zcube.replica\x00hello-1\x00zcube.image\x00b3:51aa9c03\x00";
    @memcpy(record.labels[0..text.len], text);
    record.labels_len = text.len;
    record.labels_count = 2;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = labels(arena_state.allocator(), &record).?;
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("zcube.replica", result[0].key);
    try testing.expectEqualStrings("hello-1", result[0].value);
    try testing.expectEqualStrings("b3:51aa9c03", result[1].value);

    record.labels_count = 0;
    try testing.expectEqual(@as(usize, 0), labels(arena_state.allocator(), &record).?.len);
}

test "limits keep their fields and units" {
    const mapped = limits(.{ .cpu_millis = 500, .memory_bytes = 1 << 28, .pids = 64 });
    try testing.expectEqual(@as(?u32, 500), mapped.cpu_millis);
    try testing.expectEqual(@as(?u64, 1 << 28), mapped.memory_bytes);
    try testing.expectEqual(@as(?u32, 64), mapped.pids);
    const none = limits(.{});
    try testing.expect(!none.any());
}

test "refusal names what Zigbox bounds and Zigcube's spec check does not" {
    const base: runtime.Spec = .{
        .name = "hello-1",
        .image = "b3:51aa9c03",
        .command = &.{ "sh", "-c", "true" },
        .labels = &.{.{ .key = runtime.label_replica, .value = "hello-1" }},
    };
    try testing.expect(refusal(&base) == null);

    var spec = base;
    spec.env = &.{.{ .name = "", .value = "x" }};
    try testing.expectEqual(Refusal.env_name_empty, refusal(&spec).?);
    const long_name = repeat('A', bounds.env_name_bytes_max + 1);
    spec.env = &.{.{ .name = long_name, .value = "x" }};
    try testing.expectEqual(Refusal.env_name_too_long, refusal(&spec).?);
    const long_value = repeat('v', bounds.env_value_bytes_max + 1);
    spec.env = &.{.{ .name = "K", .value = long_value }};
    try testing.expectEqual(Refusal.env_value_too_long, refusal(&spec).?);

    spec = base;
    const word = repeat('w', 1024);
    spec.command = &.{ word, word, word };
    try testing.expectEqual(Refusal.command_too_long, refusal(&spec).?);
}
