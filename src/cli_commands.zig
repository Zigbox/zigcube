//! The commands that are not a listing: `why`, `apply`, `delete`, `explain`. Each returns the
//! text for standard output (or writes it, for the ones that ask a question in the middle); the
//! orchestrator (`cli.zig`) prints it and decides what a failure looks like.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const cli_args = @import("cli_args.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_get = @import("cli_get.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const cli_service = @import("cli_service.zig");
const cli_view = @import("cli_view.zig");
const codes = @import("diag/codes.zig");
const runtime_codes = @import("runtime_codes.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Options = cli_args.Options;
const Report = cli_report.Report;

// ---- why ---------------------------------------------------------------------------------------

pub fn why(
    env: *const Env,
    client: *Client,
    options: Options,
    subject: cli_args.Subject,
    report: *Report,
) Error![]const u8 {
    const arena = env.arena;
    report.subject = subject;
    const encoded = try cli_data.percent_encode(arena, subject.name);
    const path = try std.fmt.allocPrint(
        arena,
        "/v1/why/{s}/{s}",
        .{ @tagName(subject.kind), encoded },
    );
    const reply = try client.get(path, report);
    const body = try cli_data.parse(arena, reply, report);
    report.revision = cli_data.number(body, "revision");
    if (options.output == .json) return std.fmt.allocPrint(
        arena,
        "{s}\n",
        .{std.mem.trimEnd(u8, reply.body, "\n")},
    );
    return cli_view.why_text(arena, body, options.verbose, report, reply.request_id);
}

// ---- apply and delete --------------------------------------------------------------------------

/// Who the change is recorded as: `user@host`, printable ASCII, at most 64 bytes. The server
/// checks only that it is printable; it proves nothing until auth exists (docs/api.md).
pub fn applied_by(env: *const Env) Allocator.Error![]const u8 {
    const user = env.getenv("USER") orelse env.getenv("LOGNAME") orelse "user";
    var host_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&host_buffer) catch "host";
    var out: std.ArrayList(u8) = .empty;
    const joined = try std.fmt.allocPrint(env.arena, "{s}@{s}", .{ user, host });
    for (joined) |byte| {
        if (out.items.len == constants.cli_user_bytes_max) break;
        try out.append(env.arena, if (byte >= 0x21 and byte < 0x7f) byte else '_');
    }
    return out.items;
}

pub fn apply(
    env: *const Env,
    client: *Client,
    options: Options,
    file: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    const service = try cli_service.load(env, file, report);
    const body = try cli_service.body_json(arena, service, try applied_by(env));
    const plan_reply = try client.send("POST", "/v1/apply?dry_run=1", body, report);
    const plan_body = try cli_data.parse(arena, plan_reply, report);
    const plan = try cli_view.read_write_reply(plan_body, plan_reply.request_id, report);
    if (options.output != .json) {
        try emit(env, .stdout, try cli_view.change_text(arena, plan, options.verbose), report);
    }
    if (std.mem.eql(u8, plan.action, "none")) {
        if (options.output == .json) try emit(
            env,
            .stdout,
            try json_line(arena, plan_reply.body),
            report,
        );
        return;
    }
    if (options.dry_run) {
        if (options.output == .json) try emit(
            env,
            .stdout,
            try json_line(arena, plan_reply.body),
            report,
        );
        return;
    }
    const again = try std.fmt.allocPrint(arena, "zcube apply --yes {s}", .{file});
    try confirm(env, options, "apply", again, report);
    const reply = try client.send("POST", "/v1/apply", body, report);
    const reply_body = try cli_data.parse(arena, reply, report);
    const done = try cli_view.read_write_reply(reply_body, reply.request_id, report);
    if (options.output == .json) return emit(
        env,
        .stdout,
        try json_line(arena, reply.body),
        report,
    );
    try emit(env, .stdout, try done_text(arena, "applied", done, options.verbose), report);
}

fn done_text(
    arena: Allocator,
    verb: []const u8,
    reply: cli_view.WriteReply,
    verbose: bool,
) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print(
        "{s} service {s}: {s}\n",
        .{ verb, reply.name, reply.change },
    ) catch return error.OutOfMemory;
    if (verbose) {
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

pub fn delete(
    env: *const Env,
    client: *Client,
    options: Options,
    name: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    report.subject = .{ .kind = .service, .name = name };
    const rows = try cli_get.services(arena, client, name, report);
    assert(rows.len == 1);
    if (options.output != .json) {
        const row = rows[0];
        const line = try std.fmt.allocPrint(
            arena,
            "service {s}: {d}/{d} running; its replicas will be stopped\n",
            .{ row.name, row.running, row.desired },
        );
        try emit(env, .stdout, line, report);
    }
    const again = try std.fmt.allocPrint(arena, "zcube delete service {s} --yes", .{name});
    try confirm(env, options, "delete", again, report);
    const encoded = try cli_data.percent_encode(arena, name);
    const path = try std.fmt.allocPrint(
        arena,
        "/v1/services/{s}?applied_by={s}",
        .{ encoded, try cli_data.percent_encode(arena, try applied_by(env)) },
    );
    const reply = try client.send("DELETE", path, "", report);
    if (options.output == .json) return emit(
        env,
        .stdout,
        try json_line(arena, reply.body),
        report,
    );
    const body = try cli_data.parse(arena, reply, report);
    const done = try cli_view.read_write_reply(body, reply.request_id, report);
    try emit(env, .stdout, try done_text(arena, "deleted", done, options.verbose), report);
}

/// `zcube store accept-rollback --confirm`: tells the server to remember the store as it is.
pub fn accept_rollback(
    env: *const Env,
    client: *Client,
    options: Options,
    report: *Report,
) Error!void {
    const arena = env.arena;
    assert(options.confirm); // The parser requires it.
    const reply = try client.send("POST", "/v1/store/accept-rollback?confirm=true", "", report);
    if (options.output == .json) {
        return emit(env, .stdout, try json_line(arena, reply.body), report);
    }
    const Pair = struct { revision: ?u64 = null, hash: ?[]const u8 = null };
    const Body = struct { old: Pair, new: Pair };
    const body = std.json.parseFromSliceLeaky(Body, arena, reply.body, .{
        .ignore_unknown_fields = true,
    }) catch return cli_data.contract(report, reply.request_id, "is not an accepted rollback");
    const was = if (body.old.revision) |revision|
        try std.fmt.allocPrint(arena, "{d} ({s})", .{ revision, short(body.old.hash) })
    else
        "none";
    const text = try std.fmt.allocPrint(
        arena,
        "accepted: the server now remembers revision {d} ({s}); it remembered {s}\n",
        .{ body.new.revision orelse 0, short(body.new.hash), was },
    );
    try emit(env, .stdout, text, report);
}

fn short(hash: ?[]const u8) []const u8 {
    const text = hash orelse return "none";
    return text[0..@min(text.len, 8)];
}

fn json_line(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\n", .{std.mem.trimEnd(u8, body, "\n")});
}

/// Asks before a change unless `--yes`. Without a terminal there is nobody to ask: that is
/// `ZC-E0113`, never a hang and never a guess.
fn confirm(
    env: *const Env,
    options: Options,
    verb: []const u8,
    again: []const u8,
    report: *Report,
) Error!void {
    if (options.yes) return;
    if (!env.stdin_is_terminal) return no_terminal(report, verb, again);
    const input = env.stdin orelse return no_terminal(report, verb, again);
    env.stderr.print("{s}? [y/N] ", .{verb}) catch return write_failed(report, "standard error");
    env.stderr.flush() catch return write_failed(report, "standard error");
    const line = input.takeDelimiter('\n') catch {
        return declined(report, verb, again, "the answer could not be read");
    };
    const answer = std.mem.trim(u8, line orelse "", " \t\r");
    if (answer.len <= constants.cli_answer_bytes_max) {
        if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes")) return;
    }
    return declined(report, verb, again, "the answer was not yes");
}

fn no_terminal(report: *Report, verb: []const u8, again: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0113);
    report.diag.while_("asking whether to {s}", .{verb});
    report.diag.cause("standard input is not a terminal, so there is nobody to ask", .{});
    report.diag.fix_with("answer in advance:", "{s}", .{again});
    return error.Failed;
}

fn declined(report: *Report, verb: []const u8, again: []const u8, why_text: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0114);
    report.diag.while_("asking whether to {s}", .{verb});
    report.diag.cause("{s}; nothing was changed", .{why_text});
    report.diag.fix_with("do it without being asked:", "{s}", .{again});
    return error.Failed;
}

// ---- Output ------------------------------------------------------------------------------------

pub const Stream = enum { stdout, stderr };

/// Writes `text` to a stream and flushes. A stream that can't be written is `ZC-E0115`.
pub fn emit(env: *const Env, stream: Stream, text: []const u8, report: *Report) Error!void {
    const writer = switch (stream) {
        .stdout => env.stdout,
        .stderr => env.stderr,
    };
    writer.writeAll(text) catch return write_failed(report, @tagName(stream));
    writer.flush() catch return write_failed(report, @tagName(stream));
}

pub fn write_failed(report: *Report, stream: []const u8) Error {
    if (report.diag.code != null) return error.Failed; // Keep the first reason.
    report.diag.raise(.E0115);
    report.diag.while_(
        "writing to standard {s}",
        .{if (std.mem.eql(u8, stream, "stdout")) "output" else "error"},
    );
    report.diag.cause("the stream is closed or full", .{});
    report.diag.fix(.{
        .sentence = "write to something that has room, or check what the command did:",
        .command = "zcube get service",
    });
    return error.Failed;
}

// ---- explain -----------------------------------------------------------------------------------

/// `zcube explain <code>`: offline, from the registries. `E0201` and `ZC-E0201` are Zigcube's;
/// `ZBX-E0501` is Zigbox's, from the linked module.
pub fn explain(
    arena: Allocator,
    options: Options,
    text: []const u8,
    report: *Report,
) Error![]const u8 {
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    if (std.ascii.startsWithIgnoreCase(text, "ZBX-")) {
        if (find_placeholder(text)) |entry| {
            if (options.output == .json) return explain_json(arena, placeholder_entry(entry));
            return arena.dupe(u8, placeholder_text(entry, &buffer));
        }
        const code = zigbox.codes.parse(text) orelse return unknown(report, text);
        if (options.output == .json) return explain_json(arena, zigbox_entry(code));
        return arena.dupe(u8, zigbox.explain.render(code, &buffer));
    }
    const code = codes.parse(text) orelse return unknown(report, text);
    if (options.output == .json) return explain_json(arena, zcube_entry(code));
    return arena.dupe(u8, diag_mod.explain(code, &buffer));
}

/// A `ZBX-` code Zigbox's registry does not have yet but the fake runtime raises
/// (docs/runtime-codes.md). Matched by the code as typed, in any letter case.
fn find_placeholder(text: []const u8) ?*const runtime_codes.Entry {
    for (&runtime_codes.placeholders) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.full_name, text)) return entry;
    }
    return null;
}

fn placeholder_text(entry: *const runtime_codes.Entry, buffer: []u8) []const u8 {
    var exit_buffer: [zigbox.codes.exit_text_bytes_max]u8 = undefined;
    const exit_text = std.fmt.bufPrint(&exit_buffer, "{d}", .{codes.exit_code(entry.blame)});
    return zigbox.explain.render_entry(.{
        .full_name = entry.full_name,
        .severity = entry.severity,
        .blame = entry.blame,
        .summary = entry.summary,
        .explanation = entry.explanation,
        // Cannot fail: an exit code is at most three digits, and the buffer holds forty bytes.
        .exit_text = exit_text catch unreachable,
    }, buffer);
}

fn placeholder_entry(entry: *const runtime_codes.Entry) Entry {
    return .{
        .code = entry.full_name,
        .severity = @tagName(entry.severity),
        .blame = @tagName(entry.blame),
        .summary = entry.summary,
        .explanation = entry.explanation,
        .exit_code = codes.exit_code(entry.blame),
    };
}

const Entry = struct {
    code: []const u8,
    severity: []const u8,
    blame: []const u8,
    summary: []const u8,
    explanation: []const u8,
    exit_code: u8,
};

fn zcube_entry(code: codes.Code) Entry {
    const found = codes.entry(code);
    return .{
        .code = codes.full_name(code),
        .severity = @tagName(found.severity),
        .blame = @tagName(found.blame),
        .summary = found.summary,
        .explanation = found.explanation,
        .exit_code = codes.exit_code(found.blame),
    };
}

fn zigbox_entry(code: zigbox.codes.Code) Entry {
    const found = zigbox.codes.entry(code);
    return .{
        .code = zigbox.codes.full_name(code),
        .severity = @tagName(found.severity),
        .blame = @tagName(found.blame),
        .summary = found.summary,
        .explanation = found.explanation,
        .exit_code = zigbox.codes.exit_code(found.blame),
    };
}

fn explain_json(arena: Allocator, entry: Entry) Error![]const u8 {
    const text = try std.json.Stringify.valueAlloc(arena, entry, .{});
    return std.fmt.allocPrint(arena, "{s}\n", .{text});
}

fn unknown(report: *Report, text: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0118);
    report.diag.while_("looking up a diagnostic code", .{});
    report.diag.cause(
        "{s} is not a code in Zigcube's registry or Zigbox's",
        .{text[0..@min(text.len, 40)]},
    );
    report.diag.fix(
        .{
            .sentence = "codes look like E0201, ZC-E0201 or ZBX-E0501; every ZC- code is at " ++
                "https://zigbox.github.io/zigcube/errors/",
        },
    );
    return error.Failed;
}
