//! How a command fails. A `Report` collects what went wrong: the diagnostic the command raised
//! itself (a `Diag`) or the ones the server sent (`Diagnostic`s, relayed unchanged, so a failure on
//! the other side of the API looks the same here, DIAGNOSTICS.md principle 6). At the boundary the
//! orchestrator (`cli.zig`) renders them in the mode asked for and picks the exit code from their
//! blame; nothing below formats text for the user.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const cli_args = @import("cli_args.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const text_util = @import("text.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Writer = std.Io.Writer;

/// What a command function returns: `Failed` has its reason in the `Report`; running out of
/// memory is reported at the boundary (ZC-E0120).
pub const Error = error{ Failed, OutOfMemory };

pub const RequestId = text_util.Bounded(constants.request_id_bytes_max);

pub const Report = struct {
    /// What the command line raised itself.
    diag: Diag,
    /// What the server raised, then (after `seal`) everything, in the order to show.
    diagnostics: [constants.cli_diagnostics_max]Diagnostic,
    count: u32,
    /// Diagnostics past the bound, not kept.
    dropped: u32,
    /// The request that failed, for verbose output and bundles. Empty for none.
    request_id: RequestId,
    /// What the failing command was about, for `zcube bundle --last`.
    subject: ?cli_args.Subject,
    /// The store revision the failing answer was read at, if it said.
    revision: ?u64,

    /// Initialises in place: a report is several kilobytes.
    pub fn reset(report: *Report) void {
        report.diag.reset();
        report.count = 0;
        report.dropped = 0;
        report.request_id = .{};
        report.subject = null;
        report.revision = null;
        assert(report.diag.code == null);
        assert(report.count == 0);
    }

    pub fn failed(report: *const Report) bool {
        return report.diag.code != null or report.count > 0;
    }

    /// Keeps a diagnostic the server sent.
    pub fn relay(report: *Report, diagnostic: *const Diagnostic) void {
        assert(diagnostic.code.len > 0);
        if (report.count == report.diagnostics.len) {
            report.dropped += 1;
            return;
        }
        report.diagnostics[report.count] = diagnostic.*;
        report.count += 1;
        assert(report.count <= report.diagnostics.len);
    }

    /// Puts the diagnostic the command raised itself first, so `diagnostics[0..count]` is all of
    /// them. Calling it again does nothing: the collector is emptied.
    pub fn seal(report: *Report) void {
        if (report.diag.code == null) return;
        var own: Diagnostic = undefined;
        diag_mod.to_diagnostic(&own, &report.diag);
        report.diag.code = null;
        if (report.count == report.diagnostics.len) {
            report.dropped += 1;
            report.count -= 1;
        }
        var index = report.count;
        while (index > 0) : (index -= 1) report.diagnostics[index] = report.diagnostics[index - 1];
        report.diagnostics[0] = own;
        report.count += 1;
        assert(report.count <= report.diagnostics.len);
        assert(report.diag.code == null);
    }

    pub fn shown(report: *const Report) []const Diagnostic {
        assert(report.diag.code == null); // Sealed.
        return report.diagnostics[0..report.count];
    }

    /// The exit code: the blame of the first diagnostic decides (docs/api.md, "Errors").
    pub fn exit_code(report: *const Report) u8 {
        const list = report.shown();
        if (list.len == 0) return constants.exit_ok;
        return codes.exit_code(list[0].blame);
    }

    pub fn has_bug(report: *const Report) bool {
        for (report.shown()) |diagnostic| {
            if (diagnostic.severity == .bug) return true;
        }
        return false;
    }
};

pub const Mode = zigbox.render.Mode;

/// Writes every diagnostic to `writer`: text blocks separated by a blank line, or one JSON
/// object per line. Returns false if the writer failed (the caller has nowhere to say so).
pub fn render_all(report: *const Report, mode: Mode, color: bool, writer: *Writer) bool {
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    for (report.shown(), 0..) |*diagnostic, index| {
        if (index > 0 and mode != .json) writer.writeByte('\n') catch return false;
        const text = diag_mod.render(diagnostic, mode, color and mode != .json, &buffer);
        writer.writeAll(text) catch return false;
    }
    if (report.dropped > 0 and mode != .json) {
        writer.print("\n({d} more not shown)\n", .{report.dropped}) catch return false;
    }
    writer.flush() catch return false;
    return true;
}

/// The record of the last failure, `{"v":1,...}` on one line, for `zcube bundle --last` and the
/// automatic bundle of a bug. `diagnostics` holds the diagnostics' JSON, one per line.
pub fn failure_json(
    arena: Allocator,
    report: *const Report,
    command_line: []const u8,
    server: []const u8,
    at_ms: u64,
) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;
    write_failure(writer, report, command_line, server, at_ms) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write_failure(
    writer: *Writer,
    report: *const Report,
    command_line: []const u8,
    server: []const u8,
    at_ms: u64,
) Writer.Error!void {
    try writer.print("{{\"v\":1,\"at_ms\":{d},\"command\":", .{at_ms});
    try std.json.Stringify.encodeJsonString(command_line, .{}, writer);
    try writer.writeAll(",\"server\":");
    try std.json.Stringify.encodeJsonString(server, .{}, writer);
    try writer.writeAll(",\"request_id\":");
    try std.json.Stringify.encodeJsonString(report.request_id.slice(), .{}, writer);
    if (report.subject) |subject| {
        try writer.print(",\"kind\":\"{s}\",\"name\":", .{@tagName(subject.kind)});
        try std.json.Stringify.encodeJsonString(subject.name, .{}, writer);
    }
    if (report.revision) |revision| try writer.print(",\"revision\":{d}", .{revision});
    try writer.writeAll(",\"diagnostics\":[");
    for (report.shown(), 0..) |*diagnostic, index| {
        if (index > 0) try writer.writeByte(',');
        var line: [constants.diag_output_bytes_max]u8 = undefined;
        var fixed = Writer.fixed(&line);
        try zigbox.diagnostic.write_json(&fixed, diagnostic);
        try writer.writeAll(std.mem.trimEnd(u8, fixed.buffered(), "\n"));
    }
    try writer.writeAll("]}\n");
}

/// What the panic handler prints: a `bug` diagnostic, whose internal message only `--verbose` and
/// JSON show. Pure, so a test can see the text without panicking.
pub fn panic_text(message: []const u8, mode: Mode, buffer: []u8) []const u8 {
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.B0001);
    diag.cause("{s}", .{message});
    var diagnostic: Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    return diag_mod.render(&diagnostic, mode, false, buffer);
}

const testing = std.testing;

fn sample_report() Report {
    var report: Report = undefined;
    report.reset();
    report.diag.raise(.E0102);
    report.diag.cause("connection refused", .{});
    report.diag.fix(.{ .sentence = "start the server" });
    report.request_id.print("zc-0001", .{});
    return report;
}

test "a sealed report puts its own diagnostic first, then the server's" {
    // Goal: order and exit code. Method: relay one, then seal the report's own; the first
    // diagnostic decides the exit code (environment, 2), and a second seal changes nothing.
    var report = sample_report();
    var relayed: Diagnostic = undefined;
    diag_mod.to_diagnostic(&relayed, &blk: {
        var other: Diag = undefined;
        other.reset();
        other.raise(.E0201);
        other.cause("the store is down", .{});
        other.fix(.{ .sentence = "start it" });
        break :blk other;
    });
    report.relay(&relayed);
    try testing.expect(report.failed());
    report.seal();
    report.seal();
    try testing.expectEqual(@as(usize, 2), report.shown().len);
    try testing.expectEqualStrings("ZC-E0102", report.shown()[0].code.slice());
    try testing.expectEqualStrings("ZC-E0201", report.shown()[1].code.slice());
    try testing.expectEqual(constants.exit_environment, report.exit_code());
    try testing.expect(!report.has_bug());
}

test "diagnostics past the bound are counted, and the report's own is never the one dropped" {
    // Goal: the limit on diagnostics is visible. Method: fill the report from the server, then
    // seal the report's own: it is first and one of the server's is dropped and counted.
    var report = sample_report();
    var relayed: Diagnostic = undefined;
    var other: Diag = undefined;
    other.reset();
    other.raise(.E0201);
    other.cause("down", .{});
    other.fix(.{ .sentence = "start it" });
    diag_mod.to_diagnostic(&relayed, &other);
    for (0..constants.cli_diagnostics_max + 2) |_| report.relay(&relayed);
    try testing.expectEqual(@as(u32, 2), report.dropped);
    report.seal();
    try testing.expectEqual(@as(u32, constants.cli_diagnostics_max), report.count);
    try testing.expectEqual(@as(u32, 3), report.dropped);
    try testing.expectEqualStrings("ZC-E0102", report.shown()[0].code.slice());
}

test "text blocks are separated by a blank line and JSON has one object per line" {
    // Goal: DIAGNOSTICS.md, "A command may report several diagnostics". Method: render two.
    var report = sample_report();
    var relayed: Diagnostic = undefined;
    var other: Diag = undefined;
    other.reset();
    other.raise(.E0201);
    other.cause("down", .{});
    other.fix(.{ .sentence = "start it" });
    diag_mod.to_diagnostic(&relayed, &other);
    report.relay(&relayed);
    report.seal();
    var buffer: [8192]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try testing.expect(render_all(&report, .text, false, &writer));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\n\nerror[ZC-E0201]") != null);
    writer = Writer.fixed(&buffer);
    try testing.expect(render_all(&report, .json, false, &writer));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, writer.buffered(), "\n"));
}

test "the failure record is one JSON line that parses" {
    // Goal: `bundle --last` reads this back. Method: write it, parse it as a JSON value, and
    // look at the members it promises.
    var report = sample_report();
    report.subject = .{ .kind = .service, .name = "hello" };
    report.revision = 41;
    report.seal();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try failure_json(arena, &report, "zcube why service hello", "127.0.0.1:7070", 5);
    try testing.expect(std.mem.endsWith(u8, text, "\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    try testing.expectEqualStrings("hello", value.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 41), value.object.get("revision").?.integer);
    const first = value.object.get("diagnostics").?.array.items[0];
    try testing.expectEqualStrings("ZC-E0102", first.object.get("code").?.string);
}
