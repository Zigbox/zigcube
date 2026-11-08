//! What `zcube job` prints: a job as lines, a listing as a table, an ending as one line, and the
//! exit code `job get --wait` ends with. Pure functions from the server's JSON to text, so each is
//! a snapshot test. **Nothing here prints an environment value or the input**: the server's reads
//! carry names and sizes only, and this file prints those and nothing it was not given.

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const cli_data = @import("cli_data.zig");
const cli_report = @import("cli_report.zig");
const cli_view = @import("cli_view.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Error = cli_report.Error;
const Output = cli_args.Output;
const Value = cli_data.Value;
const Writer = std.Io.Writer;

/// A job that has ended: nothing more will happen to it.
pub fn terminal(state: []const u8) bool {
    return std.mem.eql(u8, state, "exited") or
        std.mem.eql(u8, state, "failed") or
        std.mem.eql(u8, state, "cancelled");
}

/// The exit code `job get --wait` ends with for a job in `state`: null while it has not ended.
pub fn outcome(state: []const u8, end: ?Value) ?u8 {
    if (std.mem.eql(u8, state, "failed")) return constants.exit_job_failed;
    if (std.mem.eql(u8, state, "cancelled")) return constants.exit_job_cancelled;
    if (!std.mem.eql(u8, state, "exited")) return null;
    const found = end orelse return constants.exit_job_exited;
    const code = cli_data.number(found, "code") orelse return constants.exit_job_exited;
    return if (code == 0) constants.exit_ok else constants.exit_job_exited;
}

/// `exited (code 0)`, `exited (signal 9)`, `failed (deadline)`, `cancelled`; empty for no end.
pub fn end_text(arena: Allocator, end: ?Value) Allocator.Error![]const u8 {
    const found = end orelse return "";
    const kind = cli_data.text(found, "kind") orelse return "";
    if (cli_data.number(found, "code")) |code| {
        return std.fmt.allocPrint(arena, "{s} (code {d})", .{ kind, code });
    }
    if (cli_data.number(found, "signal")) |signal| {
        return std.fmt.allocPrint(arena, "{s} (signal {d})", .{ kind, signal });
    }
    if (cli_data.text(found, "cause")) |cause| {
        return std.fmt.allocPrint(arena, "{s} ({s})", .{ kind, cause });
    }
    return kind;
}

/// A word as a shell would need it, so a printed command can be pasted back.
fn write_word(writer: *Writer, word: []const u8) Writer.Error!void {
    const plain = word.len > 0 and for (word) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(
            u8,
            "_@%+=:,./-",
            byte,
        ) != null;
        if (!safe) break false;
    } else true;
    if (plain) return writer.writeAll(word);
    try writer.writeByte('\'');
    for (word) |byte| {
        if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

fn write_names(writer: *Writer, label: []const u8, items: []const Value) Writer.Error!void {
    try writer.print("  {s}:", .{label});
    for (items, 0..) |item, index| {
        if (item != .string) continue;
        try writer.print("{s}{s}", .{ if (index == 0) " " else ", ", item.string });
    }
    try writer.writeByte('\n');
}

fn write_pairs(writer: *Writer, items: []const Value) Writer.Error!void {
    try writer.writeAll("  labels:");
    for (items, 0..) |item, index| {
        const sep = if (index == 0) " " else ", ";
        if (item != .array or item.array.items.len != 2) continue;
        const pair = item.array.items;
        if (pair[0] != .string or pair[1] != .string) continue;
        try writer.print("{s}{s}={s}", .{ sep, pair[0].string, pair[1].string });
    }
    try writer.writeByte('\n');
}

/// `GET /v1/jobs/{name}` as lines. Environment variables are listed by name, the input by the
/// variable it is given in and its size.
pub fn job_text(
    arena: Allocator,
    body: Value,
    request_id: []const u8,
    report: *cli_report.Report,
) Error![]const u8 {
    const job = cli_data.member(body, "job") orelse
        return cli_data.contract(report, request_id, "has no job");
    const state = cli_data.text(body, "state") orelse
        return cli_data.contract(report, request_id, "has no state");
    const name = cli_data.text(job, "name") orelse
        return cli_data.contract(report, request_id, "has no job name");
    var out: Writer.Allocating = .init(arena);
    write_job(&out.writer, job, name, state, cli_data.member(body, "status")) catch
        return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn write_job(
    writer: *Writer,
    job: Value,
    name: []const u8,
    state: []const u8,
    status: ?Value,
) Writer.Error!void {
    try writer.print("job {s}: {s}\n", .{ name, state });
    const known = status orelse Value{ .null = {} };
    if (cli_data.text(known, "node")) |node| try writer.print("  node: {s}\n", .{node});
    if (cli_data.number(known, "epoch")) |epoch| try writer.print("  epoch: {d}\n", .{epoch});
    var scratch: [128]u8 = undefined;
    var fixed = Writer.fixed(&scratch);
    try write_end(&fixed, cli_data.member(known, "end"));
    if (fixed.buffered().len > 0) try writer.print("  end: {s}\n", .{fixed.buffered()});
    if (cli_data.text(job, "image")) |image| try writer.print("  image: {s}\n", .{image});
    try writer.writeAll("  command:");
    for (cli_data.array(job, "command") orelse &.{}) |word| {
        if (word != .string) continue;
        try writer.writeByte(' ');
        try write_word(writer, word.string);
    }
    try writer.writeByte('\n');
    if (cli_data.number(job, "deadline_ms")) |ms| {
        try writer.print("  deadline: {d} s\n", .{ms / 1000});
    }
    try write_job_inputs(writer, job);
}

fn write_end(writer: *Writer, end: ?Value) Writer.Error!void {
    const found = end orelse return;
    const kind = cli_data.text(found, "kind") orelse return;
    try writer.writeAll(kind);
    if (cli_data.number(found, "code")) |code| try writer.print(" (code {d})", .{code});
    if (cli_data.number(found, "signal")) |signal| try writer.print(" (signal {d})", .{signal});
    if (cli_data.text(found, "cause")) |cause| try writer.print(" ({s})", .{cause});
}

fn write_job_inputs(writer: *Writer, job: Value) Writer.Error!void {
    const names = cli_data.array(job, "env_names") orelse &.{};
    if (names.len > 0) try write_names(writer, "env (names only)", names);
    if (cli_data.text(job, "input_env")) |variable| {
        const bytes = cli_data.number(job, "input_bytes") orelse 0;
        try writer.print("  input: {d} bytes, given as {s}\n", .{ bytes, variable });
    }
    const labels = cli_data.array(job, "labels") orelse &.{};
    if (labels.len > 0) try write_pairs(writer, labels);
    // The server sends the request itself, `{"at_ms","by"}`, and nothing when there was none.
    if (cli_data.member(job, "cancel_requested")) |request| {
        if (request == .object) {
            try writer.writeAll("  cancel requested");
            if (cli_data.text(request, "by")) |by| {
                if (by.len > 0) try writer.print(" by {s}", .{by});
            }
            try writer.writeAll("\n");
        }
    }
}

/// A row of `GET /v1/jobs` as the cells of the table; the wide columns add the image, labels and
/// deadline.
fn row_cells(
    arena: Allocator,
    row: Value,
    output: Output,
    cells: *[7][]const u8,
) Allocator.Error![]const []const u8 {
    cells[0] = cli_data.text(row, "name") orelse "-";
    cells[1] = cli_data.text(row, "state") orelse "-";
    cells[2] = cli_data.text(row, "node") orelse "-";
    const end = try end_text(arena, cli_data.member(row, "end"));
    cells[3] = if (end.len > 0) end else "-";
    if (output != .wide) return cells[0..4];
    cells[4] = cli_data.text(row, "image") orelse "-";
    cells[5] = try labels_text(arena, cli_data.array(row, "labels") orelse &.{});
    const ms = cli_data.number(row, "deadline_ms") orelse 0;
    cells[6] = try std.fmt.allocPrint(arena, "{d}s", .{ms / 1000});
    return cells[0..7];
}

fn labels_text(arena: Allocator, items: []const Value) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    for (items) |item| {
        if (item != .array or item.array.items.len != 2) continue;
        const pair = item.array.items;
        if (pair[0] != .string or pair[1] != .string) continue;
        out.writer.print("{s}{s}={s}", .{
            if (out.writer.end == 0) "" else ",", pair[0].string, pair[1].string,
        }) catch return error.OutOfMemory;
    }
    const text = out.toOwnedSlice() catch return error.OutOfMemory;
    return if (text.len == 0) "-" else text;
}

/// The rows of one or more pages as a table; an empty listing says so.
pub fn list_text(arena: Allocator, rows: []const Value, output: Output) Error![]const u8 {
    if (rows.len == 0) return "no jobs\n";
    const header_narrow = [_][]const u8{ "NAME", "STATE", "NODE", "END" };
    const header_wide = [_][]const u8{
        "NAME", "STATE", "NODE", "END", "IMAGE", "LABELS", "DEADLINE",
    };
    const header: []const []const u8 = if (output == .wide) &header_wide else &header_narrow;
    const table = try arena.alloc([]const []const u8, rows.len);
    for (rows, table) |row, *line| {
        const cells = try arena.create([7][]const u8);
        line.* = try row_cells(arena, row, output, cells);
    }
    var out: Writer.Allocating = .init(arena);
    cli_view.write_table(&out.writer, header, table) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// One ending as a line: `NAME  exited (code 0)  node1`. `status` is the job's status.
pub fn ending_line(arena: Allocator, name: []const u8, status: Value) Allocator.Error![]const u8 {
    const end = try end_text(arena, cli_data.member(status, "end"));
    const node = cli_data.text(status, "node") orelse "-";
    const what = if (end.len > 0) end else cli_data.text(status, "state") orelse "-";
    return std.fmt.allocPrint(arena, "{s}  {s}  {s}\n", .{ name, what, node });
}

/// The same ending as one JSON object per line: `{"name":..., "status":{...}}`.
pub fn ending_json(arena: Allocator, name: []const u8, status: Value) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.writeAll("{\"name\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(name, .{}, writer) catch return error.OutOfMemory;
    writer.writeAll(",\"status\":") catch return error.OutOfMemory;
    std.json.Stringify.value(status, .{}, writer) catch return error.OutOfMemory;
    writer.writeAll("}\n") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const testing = std.testing;

fn parse_json(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "an ending reads as a word, and --wait's exit code follows it" {
    // Goal: the brief's exit codes. Method: each kind of end, through `outcome` and `end_text`.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zero = try parse_json(arena, "{\"kind\":\"exited\",\"code\":0}");
    const three = try parse_json(arena, "{\"kind\":\"exited\",\"code\":3}");
    const killed = try parse_json(arena, "{\"kind\":\"exited\",\"signal\":9}");
    const late = try parse_json(arena, "{\"kind\":\"failed\",\"cause\":\"deadline\"}");
    try testing.expectEqual(@as(?u8, 0), outcome("exited", zero));
    try testing.expectEqual(@as(?u8, 10), outcome("exited", three));
    try testing.expectEqual(@as(?u8, 10), outcome("exited", killed));
    try testing.expectEqual(@as(?u8, 11), outcome("failed", late));
    try testing.expectEqual(@as(?u8, 12), outcome("cancelled", null));
    try testing.expectEqual(@as(?u8, null), outcome("running", null));
    try testing.expectEqualStrings("exited (code 3)", try end_text(arena, three));
    try testing.expectEqualStrings("exited (signal 9)", try end_text(arena, killed));
    try testing.expectEqualStrings("failed (deadline)", try end_text(arena, late));
    try testing.expectEqualStrings("", try end_text(arena, null));
}

test "a job prints its env by name and its input by size, never their values" {
    // Goal: "never print env values or the input". Method: a body as the server sends it, which
    // has names only, printed; the text holds the names, the size, and a quoted command.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: cli_report.Report = undefined;
    report.reset();
    const body = try parse_json(arena,
        \\{"revision":9,"state":"running","job":{"name":"etl","image":"b3:aa",
        \\"command":["sh","-c","exit 3"],"env_names":["TOKEN","MODE"],"input_env":"DATA",
        \\"input_digest":"b3:bb","input_bytes":12,"labels":[["team","x"]],"deadline_ms":600000,
        \\"cancel_requested":{"at_ms":5000,"by":"ann@host"}},
        \\"status":{"state":"running","node":"node1","epoch":4}}
    );
    const text = try job_text(arena, body, "zc-1", &report);
    const want =
        \\job etl: running
        \\  node: node1
        \\  epoch: 4
        \\  image: b3:aa
        \\  command: sh -c 'exit 3'
        \\  deadline: 600 s
        \\  env (names only): TOKEN, MODE
        \\  input: 12 bytes, given as DATA
        \\  labels: team=x
        \\  cancel requested by ann@host
        \\
    ;
    try testing.expectEqualStrings(want, text);
}

test "a listing is a table, wide adds the image, labels and deadline, empty says so" {
    // Goal: `job list`. Method: two rows in both widths.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try parse_json(arena,
        \\{"jobs":[{"name":"a","image":"b3:1","state":"exited","node":"n1","labels":[["k","v"]],
        \\"deadline_ms":60000,"end":{"kind":"exited","code":0}},
        \\{"name":"bb","image":"b3:2","state":"pending","labels":[],"deadline_ms":1000}]}
    );
    const rows = cli_data.array(body, "jobs").?;
    try testing.expectEqualStrings(
        \\NAME  STATE    NODE  END
        \\a     exited   n1    exited (code 0)
        \\bb    pending  -     -
        \\
    , try list_text(arena, rows, .text));
    try testing.expectEqualStrings(
        \\NAME  STATE    NODE  END              IMAGE  LABELS  DEADLINE
        \\a     exited   n1    exited (code 0)  b3:1   k=v     60s
        \\bb    pending  -     -                b3:2   -       1s
        \\
    , try list_text(arena, rows, .wide));
    try testing.expectEqualStrings("no jobs\n", try list_text(arena, &.{}, .text));
}

test "an ending is one line, and one JSON object" {
    // Goal: `job watch` output. Method: a status, both forms.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status = try parse_json(
        arena,
        "{\"state\":\"failed\",\"node\":\"n2\",\"end\":{\"kind\":\"failed\",\"cause\":\"oom\"}}",
    );
    try testing.expectEqualStrings("a  failed (oom)  n2\n", try ending_line(arena, "a", status));
    const json = try ending_json(arena, "a", status);
    try testing.expect(std.mem.startsWith(u8, json, "{\"name\":\"a\",\"status\":{\"state\""));
    try testing.expect(std.mem.endsWith(u8, json, "}}\n"));
}
