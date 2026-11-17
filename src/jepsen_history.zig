//! One line of a Jepsen history, as zcube-jepsen-client writes it (docs/jepsen.md, "The
//! history"): a JSON object on one line, its members always in the order below, a member that
//! does not apply left out, and `value` always present (null when the operation has none).
//!
//! The encoder is pure: no clock, no file. The golden files under `src/testdata/jepsen/` fix its
//! output byte for byte, since the harness parses it.

const std = @import("std");
const assert = std.debug.assert;

const Writer = std.Io.Writer;

/// What Jepsen calls the operation's type: `:invoke` before, then exactly one of the others.
pub const Type = enum {
    invoke,
    /// It happened, and `value` says what it saw or wrote.
    ok,
    /// It did not happen: refused, or never sent.
    fail,
    /// It may or may not have happened (a write whose answer was lost, or ZC-E0213).
    info,
};

pub const Op = enum { apply, get, delete, watch };

/// One event of a watch, filtered to the operation's service key.
pub const Event = struct {
    put: bool,
    mod_revision: u64,
    /// The service's `replicas` after a put; null for a delete.
    replicas: ?u32,
};

pub const Value = union(enum) {
    /// JSON null: the operation has no value, or (for `get`) the service does not exist.
    nil,
    /// `apply`: the count asked for; `get`: the count read.
    count: u32,
    /// `watch`: the events seen, in revision order.
    events: []const Event,
};

pub const Line = struct {
    type: Type,
    f: Op,
    /// The Jepsen process (the harness's worker number).
    process: u32,
    /// Nanoseconds of the boot clock (`CLOCK_BOOTTIME`): monotonic on one host, untouched by
    /// `date -s`, so a clock fault on the control host cannot reorder its own history.
    time_ns: u64,
    service: []const u8,
    value: Value = .nil,
    /// `watch`: the revision it watched from.
    from: ?u64 = null,
    /// The store revision the answer names (an apply that wrote nothing has none).
    revision: ?u64 = null,
    /// `get`: the service key's `mod_revision`, when it exists.
    mod_revision: ?u64 = null,
    /// `apply` and `delete`: the server's `action` (`create`, `update`, `none`, `delete`).
    action: ?[]const u8 = null,
    /// The HTTP status, when a reply came.
    status: ?u16 = null,
    /// The diagnostic code of a failure: the server's first, or the client's own.
    code: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    /// The newest cause of a failure, in words.
    @"error": ?[]const u8 = null,
};

/// A history line is cut to this many bytes at most by the caller's buffer; a watch reply is
/// bounded (`cli_reply_bytes_max`), so its events are too.
pub const line_bytes_max = 1024 * 1024;

/// Writes `line` and a newline.
pub fn write(line: Line, writer: *Writer) Writer.Error!void {
    assert(line.time_ns > 0);
    assert(line.service.len > 0);
    if (line.type == .invoke) {
        assert(line.status == null);
        assert(line.code == null);
    }
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write(@tagName(line.type));
    try json.objectField("f");
    try json.write(@tagName(line.f));
    try json.objectField("process");
    try json.write(line.process);
    try json.objectField("time");
    try json.write(line.time_ns);
    try json.objectField("service");
    try json.write(line.service);
    try json.objectField("value");
    try write_value(&json, line.value);
    try optional(&json, "from", line.from);
    try optional(&json, "revision", line.revision);
    try optional(&json, "mod_revision", line.mod_revision);
    try optional(&json, "action", line.action);
    try optional(&json, "status", line.status);
    try optional(&json, "code", line.code);
    try optional(&json, "request_id", line.request_id);
    try optional(&json, "error", line.@"error");
    try json.endObject();
    try writer.writeByte('\n');
}

fn optional(json: *std.json.Stringify, name: []const u8, member: anytype) Writer.Error!void {
    const present = member orelse return;
    try json.objectField(name);
    try json.write(present);
}

fn write_value(json: *std.json.Stringify, value: Value) Writer.Error!void {
    switch (value) {
        .nil => try json.write(null),
        .count => |count| try json.write(count),
        .events => |events| {
            try json.beginArray();
            for (events) |event| {
                try json.beginObject();
                try json.objectField("type");
                try json.write(if (event.put) "put" else "delete");
                try json.objectField("mod_revision");
                try json.write(event.mod_revision);
                try json.objectField("replicas");
                try json.write(event.replicas);
                try json.endObject();
            }
            try json.endArray();
        },
    }
}

fn expect_golden(line: Line, golden: []const u8) !void {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try write(line, &text.writer);
    try std.testing.expectEqualStrings(golden, text.written());
}

test "history lines match their goldens" {
    try expect_golden(.{
        .type = .invoke,
        .f = .apply,
        .process = 1,
        .time_ns = 10,
        .service = "r1",
        .value = .{ .count = 3 },
    }, @embedFile("testdata/jepsen/invoke_apply.jsonl"));
    try expect_golden(.{
        .type = .ok,
        .f = .get,
        .process = 2,
        .time_ns = 20,
        .service = "r1",
        .value = .nil,
        .revision = 5,
        .status = 200,
        .request_id = "zc-1",
    }, @embedFile("testdata/jepsen/ok_get_absent.jsonl"));
    try expect_golden(.{
        .type = .ok,
        .f = .watch,
        .process = 3,
        .time_ns = 30,
        .service = "r1",
        .from = 2,
        .revision = 9,
        .status = 200,
        .value = .{ .events = &.{
            .{ .put = true, .mod_revision = 4, .replicas = 2 },
            .{ .put = false, .mod_revision = 8, .replicas = null },
        } },
    }, @embedFile("testdata/jepsen/ok_watch.jsonl"));
    try expect_golden(.{
        .type = .info,
        .f = .delete,
        .process = 4,
        .time_ns = 40,
        .service = "r1",
        .status = 503,
        .code = "ZC-E0213",
        .@"error" = "quote \" backslash \\ newline \n tab \t",
    }, @embedFile("testdata/jepsen/info_escaped.jsonl"));
}
