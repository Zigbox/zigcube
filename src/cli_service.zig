//! A service file (`hello.zon`, HANDOFF's example) read into the JSON body of `POST /v1/apply`.
//! Every way the file can be wrong is a coded diagnostic that says where: `ZC-E0109` when it can't
//! be read, `ZC-E0110` when it isn't a service, with `file:line:column` of the first problem and
//! the line itself. Nothing is sent to the server before the file is valid.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const cli_env = @import("cli_env.zig");
const cli_report = @import("cli_report.zig");

const Allocator = std.mem.Allocator;
const Env = cli_env.Env;
const Report = cli_report.Report;
const Error = cli_report.Error;

/// What a service file may hold. Unknown fields are refused, so a typo is not silently ignored.
pub const Service = struct {
    name: []const u8,
    image: []const u8,
    replicas: u32,
    command: []const []const u8,
    env: []const records.Pair = &.{},
    limits: records.Limits = .{},
};

/// Reads and parses `path`. The strings of the result live in `env.arena`.
pub fn load(env: *const Env, path: []const u8, report: *Report) Error!Service {
    const source = try read(env, path, report);
    return parse(env.arena, source, path, report);
}

fn read(env: *const Env, path: []const u8, report: *Report) Error![:0]const u8 {
    const limit: std.Io.Limit = .limited(constants.service_file_bytes_max);
    const cwd = std.Io.Dir.cwd();
    return cwd.readFileAllocOptions(env.io, path, env.arena, limit, .of(u8), 0) catch |err| {
        return unreadable(report, path, reason(err));
    };
}

fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "it is a directory",
        error.StreamTooLong => "it is larger than a service file may be (32 KiB)",
        error.NotDir => "a part of the path is not a directory",
        error.NameTooLong => "the path is too long",
        else => "the system could not read it",
    };
}

fn unreadable(report: *Report, path: []const u8, why: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0109);
    report.diag.while_("reading the service file", .{});
    report.diag.cause("{s}: {s}", .{ path, why });
    report.diag.context("file", "{s}", .{path});
    report.diag.fix(.{
        .sentence = "check the path; the file is a ZON service, for example:",
        .command = "zcube apply hello.zon",
    });
    return error.Failed;
}

/// Parses `source` as a service. `path` only names the file in messages.
pub fn parse(
    arena: Allocator,
    source: [:0]const u8,
    path: []const u8,
    report: *Report,
) Error!Service {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const options: std.zon.parse.Options = .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    };
    const service = std.zon.parse.fromSlice(Service, options) catch |err| switch (err) {
        error.OutOfMemory => return out_of_memory(report, path),
        error.ParseZon => return invalid(report, path, source, &diagnostics),
    };
    return service;
}

fn out_of_memory(report: *Report, path: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0109);
    report.diag.while_("reading the service file", .{});
    report.diag.cause("{s}: the file needs more memory than zcube may use", .{path});
    report.diag.fix(.{ .sentence = "use a smaller file" });
    return error.Failed;
}

/// The first problem is the context and the last cause (the one default output shows); the
/// others come before it, newest problem first, as the cause chain reads.
fn invalid(
    report: *Report,
    path: []const u8,
    source: []const u8,
    diagnostics: *const std.zon.parse.Diagnostics,
) Error {
    assert(report.diag.code == null);
    assert(diagnostics.errors.len > 0);
    report.diag.raise(.E0110);
    report.diag.while_("reading the service file {s}", .{path});
    const shown = @min(diagnostics.errors.len, constants.diag_causes_count_max - 1);
    var index = shown;
    while (index > 0) {
        index -= 1;
        const found = diagnostics.errors[index];
        report.diag.cause(
            "{s}:{d}:{d}: {s}",
            .{ path, found.loc.line + 1, found.loc.column + 1, found.msg },
        );
    }
    if (diagnostics.errors.len > shown) {
        report.diag.cause("{d} more problems follow", .{diagnostics.errors.len - shown});
    }
    const first = diagnostics.errors[0];
    report.diag.context("at", "{s}:{d}:{d}", .{ path, first.loc.line + 1, first.loc.column + 1 });
    report.diag.context("line", "{s}", .{line_of(source, first.loc.line)});
    report.diag.fix(.{
        .sentence = "a service has .name, .image, .replicas and .command; see the example:",
        .command = "zcube explain E0110",
    });
    return error.Failed;
}

/// The text of line `number` (zero-based), cut to what fits a context field.
fn line_of(source: []const u8, number: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index != number) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        return trimmed[0..@min(trimmed.len, 100)];
    }
    return "";
}

/// The JSON of `POST /v1/apply`. `applied_by` is the name recorded for the audit trail.
pub fn body_json(
    arena: Allocator,
    service: Service,
    applied_by: []const u8,
) Allocator.Error![]const u8 {
    assert(applied_by.len > 0);
    const body = .{
        .name = service.name,
        .image = service.image,
        .replicas = service.replicas,
        .command = service.command,
        .env = service.env,
        .limits = service.limits,
        .applied_by = applied_by,
    };
    return std.json.Stringify.valueAlloc(arena, body, .{ .emit_null_optional_fields = false });
}

const testing = std.testing;

test "HANDOFF's example is a service, and becomes the body the API takes" {
    // Goal: the file of the demo parses and the JSON has the shape docs/api.md gives.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: Report = undefined;
    report.reset();
    const source =
        \\.{
        \\    .name = "hello",
        \\    .image = "b3:51aa9c03",
        \\    .replicas = 3,
        \\    .command = .{ "sh", "-c", "while true; do sleep 1; done" },
        \\    .env = .{ .{ "GREETING", "hi" } },
        \\    .limits = .{ .memory_bytes = 268435456 },
        \\}
    ;
    const service = try parse(arena, source, "hello.zon", &report);
    try testing.expectEqualStrings("hello", service.name);
    try testing.expectEqual(@as(u32, 3), service.replicas);
    const body = try body_json(arena, service, "alex@laptop");
    try testing.expectEqualStrings(
        "{\"name\":\"hello\",\"image\":\"b3:51aa9c03\",\"replicas\":3," ++
            "\"command\":[\"sh\",\"-c\",\"while true; do sleep 1; done\"]," ++
            "\"env\":[[\"GREETING\",\"hi\"]],\"limits\":{\"memory_bytes\":268435456}," ++
            "\"applied_by\":\"alex@laptop\"}",
        body,
    );
}

test "every way a file can be wrong points at its line" {
    // Goal: the acceptance of the brief, "every parse error a coded diagnostic that points at the
    // line". Method: a typo in a field name, a wrong type, a missing field and plain garbage.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { source: [:0]const u8, at: []const u8 }{
        .{ .source = ".{\n    .name = \"x\",\n    .imag = \"b3:1\",\n}", .at = "x.zon:3:" },
        .{
            .source = ".{\n    .name = \"x\",\n    .image = \"b3:1\",\n" ++
                "    .replicas = \"3\",\n    .command = .{},\n}",
            .at = "x.zon:4:",
        },
        .{ .source = ".{ .name = \"x\" }", .at = "x.zon:1:" },
        .{ .source = "this is not zon", .at = "x.zon:1:" },
        .{ .source = "", .at = "x.zon:1:" },
    };
    for (cases) |case| {
        var report: Report = undefined;
        report.reset();
        try testing.expectError(error.Failed, parse(arena, case.source, "x.zon", &report));
        try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0110), report.diag.code);
        const pair = report.diag.pairs.slice()[0];
        try testing.expectEqualStrings("at", pair.key_slice());
        try testing.expect(std.mem.startsWith(u8, pair.value.slice(), case.at));
        try testing.expect(std.mem.indexOf(u8, report.diag.last_cause().?, case.at) != null);
    }
}
