//! What the commands print: tables for `get`, the chain for `why`, the diff for `apply`. Pure
//! functions from rows (or the server's JSON) to text, so each is a snapshot test. The sentences
//! of `why` come from the server (`state.text`, `step.text`): every client prints the same words
//! (docs/api.md), and this file only lays them out.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const cli_args = @import("cli_args.zig");
const cli_data = @import("cli_data.zig");
const cli_get = @import("cli_get.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Error = cli_report.Error;
const Output = cli_args.Output;
const Report = cli_report.Report;
const Value = cli_data.Value;
const Writer = std.Io.Writer;

const arrow = "\u{2190}";

// ---- Tables ------------------------------------------------------------------------------------

/// Left-aligned columns, two spaces apart, the last one unpadded.
fn write_table(
    writer: *Writer,
    header: []const []const u8,
    rows: []const []const []const u8,
) Writer.Error!void {
    var widths: [8]usize = @splat(0);
    assert(header.len <= widths.len);
    for (header, 0..) |cell, column| widths[column] = cell.len;
    for (rows) |row| {
        for (row, 0..) |cell, column| widths[column] = @max(widths[column], cell.len);
    }
    try write_row(writer, header, &widths);
    for (rows) |row| try write_row(writer, row, &widths);
}

fn write_row(writer: *Writer, row: []const []const u8, widths: *const [8]usize) Writer.Error!void {
    // The last cell that holds text ends the line: no trailing spaces.
    var last: usize = row.len;
    while (last > 1 and row[last - 1].len == 0) last -= 1;
    for (row[0..last], 0..) |cell, column| {
        try writer.writeAll(cell);
        if (column + 1 == last) break;
        try writer.splatByteAll(' ', widths[column] - cell.len + 2);
    }
    try writer.writeByte('\n');
}

pub fn services_text(
    arena: Allocator,
    rows: []const cli_get.ServiceRow,
    output: Output,
) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    if (output == .json) return json_text(arena, .{ .kind = "service", .items = rows });
    const wide = output == .wide;
    if (rows.len == 0) return "no services\n";
    var cells: std.ArrayList([]const []const u8) = .empty;
    for (rows) |row| {
        const ready = std.fmt.allocPrint(
            arena,
            "{d}/{d}",
            .{ row.running, row.desired },
        ) catch return error.OutOfMemory;
        const generation = std.fmt.allocPrint(
            arena,
            "{d}",
            .{row.generation},
        ) catch return error.OutOfMemory;
        const line: []const []const u8 = if (wide)
            &.{ row.name, ready, row.image, generation, row.applied_by, cut(row.command, 40) }
        else
            &.{ row.name, ready, row.image };
        const copy = arena.dupe([]const u8, line) catch return error.OutOfMemory;
        cells.append(arena, copy) catch return error.OutOfMemory;
    }
    const header: []const []const u8 = if (wide)
        &.{ "NAME", "READY", "IMAGE", "GEN", "APPLIED-BY", "COMMAND" }
    else
        &.{ "NAME", "READY", "IMAGE" };
    write_table(writer, header, cells.items) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

pub fn replicas_text(
    arena: Allocator,
    rows: []const cli_get.ReplicaRow,
    now_ms: u64,
    output: Output,
) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    if (output == .json) return json_text(arena, .{ .kind = "replicas", .items = rows });
    const wide = output == .wide;
    if (rows.len == 0) return "no replicas\n";
    var cells: std.ArrayList([]const []const u8) = .empty;
    for (rows) |row| {
        const age = age_text(arena, row.started_at_ms, now_ms) catch return error.OutOfMemory;
        const generation = std.fmt.allocPrint(
            arena,
            "{d}",
            .{row.generation},
        ) catch return error.OutOfMemory;
        const node = if (row.node.len == 0) "-" else row.node;
        const line: []const []const u8 = if (wide)
            &.{ row.id, row.service, node, row.status, age, generation, row.image, row.detail }
        else
            &.{ row.id, row.service, node, row.status, age };
        const copy = arena.dupe([]const u8, line) catch return error.OutOfMemory;
        cells.append(arena, copy) catch return error.OutOfMemory;
    }
    const header: []const []const u8 = if (wide)
        &.{ "REPLICA", "SERVICE", "NODE", "STATUS", "AGE", "GEN", "IMAGE", "DETAIL" }
    else
        &.{ "REPLICA", "SERVICE", "NODE", "STATUS", "AGE" };
    write_table(writer, header, cells.items) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn cut(text: []const u8, length: usize) []const u8 {
    return text[0..@min(text.len, length)];
}

/// `12s`, `3m`, `2h`, `5d`; `-` for a replica that has not started.
pub fn age_text(arena: Allocator, started_ms: ?u64, now_ms: u64) Allocator.Error![]const u8 {
    const started = started_ms orelse return "-";
    const seconds = if (now_ms > started) @divFloor(now_ms - started, 1000) else 0;
    if (seconds < 60) return std.fmt.allocPrint(arena, "{d}s", .{seconds});
    if (seconds < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divFloor(seconds, 60)});
    if (seconds < 86400) return std.fmt.allocPrint(arena, "{d}h", .{@divFloor(seconds, 3600)});
    return std.fmt.allocPrint(arena, "{d}d", .{@divFloor(seconds, 86400)});
}

fn json_text(arena: Allocator, value: anytype) Error![]const u8 {
    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;
    return std.fmt.allocPrint(arena, "{s}\n", .{text}) catch error.OutOfMemory;
}

// ---- why ---------------------------------------------------------------------------------------

/// The chain as HANDOFF shows it: the state line, then `<-` and each step, a step that carries a
/// diagnostic as the full diagnostic block under its arrow.
pub fn why_text(
    arena: Allocator,
    body: Value,
    verbose: bool,
    report: *Report,
    request_id: []const u8,
) Error![]const u8 {
    const state = cli_data.member(
        body,
        "state",
    ) orelse return cli_data.contract(report, request_id, "has no state");
    const headline = cli_data.text(
        state,
        "text",
    ) orelse return cli_data.contract(report, request_id, "has no state text");
    const steps = cli_data.array(
        body,
        "steps",
    ) orelse return cli_data.contract(report, request_id, "has no steps");
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print("{s}\n", .{headline}) catch return error.OutOfMemory;
    for (steps) |step| {
        try write_step(arena, writer, step, verbose, report, request_id);
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn write_step(
    arena: Allocator,
    writer: *Writer,
    step: Value,
    verbose: bool,
    report: *Report,
    request_id: []const u8,
) Error!void {
    const sentence = cli_data.text(
        step,
        "text",
    ) orelse return cli_data.contract(report, request_id, "has a step without text");
    if (cli_data.member(step, "diagnostic")) |raw| {
        if (try write_diagnostic_step(arena, writer, raw, verbose)) return;
    }
    writer.print("  " ++ arrow ++ " {s}\n", .{sentence}) catch return error.OutOfMemory;
    if (!verbose) return;
    const decision = cli_data.member(step, "decision") orelse return;
    const id = cli_data.text(decision, "id") orelse return;
    const actor = cli_data.text(decision, "actor") orelse "?";
    const action = cli_data.text(decision, "action") orelse "?";
    writer.print(
        "      decision {s} by {s}: {s}\n",
        .{ id, actor, action },
    ) catch return error.OutOfMemory;
}

/// The diagnostic of a step, laid out as the step's block; false if the value is not a
/// diagnostic (the caller prints the sentence).
fn write_diagnostic_step(arena: Allocator, writer: *Writer, raw: Value, verbose: bool) Error!bool {
    const text = std.json.Stringify.valueAlloc(arena, raw, .{}) catch return error.OutOfMemory;
    var diagnostic: diag_mod.Diagnostic = undefined;
    zigbox.diagnostic.parse_json(&diagnostic, text) catch return false;
    cli_http.set_docs(&diagnostic);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const block = diag_mod.render(&diagnostic, if (verbose) .verbose else .text, false, &buffer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        const prefix = if (first) "  " ++ arrow ++ " " else "    ";
        writer.print("{s}{s}\n", .{ prefix, line }) catch return error.OutOfMemory;
        first = false;
    }
    return true;
}

// ---- apply and delete -------------------------------------------------------------------

pub const WriteReply = struct {
    action: []const u8,
    name: []const u8,
    change: []const u8,
    generation: ?u64,
    revision: ?u64,
    decision: ?[]const u8,
    dry_run: bool,
};

pub fn read_write_reply(body: Value, request_id: []const u8, report: *Report) Error!WriteReply {
    return .{
        .action = cli_data.text(
            body,
            "action",
        ) orelse return cli_data.contract(report, request_id, "has no action"),
        .name = cli_data.text(
            body,
            "name",
        ) orelse return cli_data.contract(report, request_id, "has no name"),
        .change = cli_data.text(body, "change") orelse "",
        .generation = cli_data.number(body, "generation"),
        .revision = cli_data.number(body, "revision"),
        .decision = cli_data.text(body, "decision"),
        .dry_run = if (cli_data.member(
            body,
            "dry_run",
        )) |flag| flag == .bool and flag.bool else false,
    };
}

/// What an apply would do (a dry run): the action, then the change when it says more than the
/// action does.
pub fn change_text(arena: Allocator, reply: WriteReply, verbose: bool) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    if (std.mem.eql(u8, reply.action, "none")) {
        writer.print("service {s}: unchanged\n", .{reply.name}) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
    const verb = if (reply.dry_run) "would " else "";
    writer.print(
        "service {s}: {s}{s}\n",
        .{ reply.name, verb, reply.action },
    ) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, reply.change, "created")) {
        writer.print("  {s}\n", .{reply.change}) catch return error.OutOfMemory;
    }
    if (!reply.dry_run and verbose) {
        if (reply.revision) |revision| writer.print(
            "  revision {d}\n",
            .{revision},
        ) catch return error.OutOfMemory;
        if (reply.decision) |decision| writer.print(
            "  decision {s}\n",
            .{decision},
        ) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const testing = std.testing;

test "services print as a table, with the wide columns on request" {
    // Goal: the demo's `zcube get service hello`. Method: two rows, narrow and wide.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = [_]cli_get.ServiceRow{
        .{
            .name = "hello",
            .image = "b3:51aa9c03",
            .desired = 3,
            .running = 3,
            .generation = 1,
            .applied_by = "alex@laptop",
            .command = "sh -c while true; do sleep 1; done",
        },
        .{
            .name = "broken",
            .image = "b3:00ff7be1",
            .desired = 1,
            .running = 0,
            .generation = 2,
            .applied_by = "alex@laptop",
            .command = "true",
        },
    };
    try testing.expectEqualStrings(
        "NAME    READY  IMAGE\n" ++
            "hello   3/3    b3:51aa9c03\n" ++
            "broken  0/1    b3:00ff7be1\n",
        try services_text(arena, &rows, .text),
    );
    const wide = try services_text(arena, &rows, .wide);
    try testing.expect(std.mem.startsWith(
        u8,
        wide,
        "NAME    READY  IMAGE        GEN  APPLIED-BY   COMMAND\n",
    ));
    try testing.expectEqualStrings("no services\n", try services_text(arena, &.{}, .text));
}

test "replicas print with their age, and a dash where there is no node or start" {
    // Goal: `zcube get replicas -o wide`. Method: a running replica and a pending one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = [_]cli_get.ReplicaRow{
        .{
            .id = "hello-1",
            .service = "hello",
            .node = "node1",
            .generation = 1,
            .image = "b3:51aa9c03",
            .status = "running",
            .detail = "",
            .started_at_ms = 1_000,
        },
        .{
            .id = "hello-2",
            .service = "hello",
            .node = "",
            .generation = 1,
            .image = "b3:51aa9c03",
            .status = "pending",
            .detail = "",
            .started_at_ms = null,
        },
    };
    try testing.expectEqualStrings(
        "REPLICA  SERVICE  NODE   STATUS   AGE\n" ++
            "hello-1  hello    node1  running  2m\n" ++
            "hello-2  hello    -      pending  -\n",
        try replicas_text(arena, &rows, 121_000, .text),
    );
    try testing.expectEqualStrings("12s", try age_text(arena, 1_000, 13_999));
    try testing.expectEqualStrings("2h", try age_text(arena, 0, 2 * 3600 * 1000 + 5));
    try testing.expectEqualStrings("3d", try age_text(arena, 0, 3 * 86400 * 1000));
    try testing.expectEqualStrings("0s", try age_text(arena, 5_000, 1_000));
}
