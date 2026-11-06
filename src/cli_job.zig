//! `zcube job run | get | list | cancel | watch`: the commands over the job API (docs/api.md,
//! "Jobs"). Parsing is `cli_job_args.zig`, the text is `cli_job_view.zig`; this file makes the
//! requests. `get --wait` polls (a held watch per waiting client would use up the server's
//! `http_holds_max`); `watch` holds one request at a time and survives a 410 by listing.
//!
//! **No environment value and no input is printed, logged or put in a diagnostic**: a refusal
//! names the flag or the file, never the text, and the command line a failure records has its
//! `--env` values blanked (`cli.zig`).

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const cli_commands = @import("cli_commands.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_job_args = @import("cli_job_args.zig");
const cli_job_view = @import("cli_job_view.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Options = cli_args.Options;
const Report = cli_report.Report;
const Value = cli_data.Value;
const Writer = std.Io.Writer;

/// Pages of a listing one command reads before it calls the server's answer broken.
const pages_max: u32 = 1024;
/// Endings `job watch` remembers, to print each `(name, epoch)` once across a relist.
const seen_max = 1024;

pub fn run(
    env: *const Env,
    client: *Client,
    options: Options,
    job: *const cli_job_args.Job,
    report: *Report,
) Error!void {
    switch (job.*) {
        .run => |*spec| try submit(env, client, options, spec, report),
        .get => |what| try get(env, client, options, what.name, what.wait, report),
        .list => |filter| try list(env, client, options, filter, report),
        .cancel => |name| try cancel(env, client, options, name, report),
        .watch => |from| try watch(env, client, options, from, report),
    }
}

fn emit_json(env: *const Env, body: []const u8, report: *Report) Error!void {
    const line = try cli_commands.json_line(env.arena, body);
    return cli_commands.emit(env, .stdout, line, report);
}

fn subject(report: *Report, name: []const u8) void {
    report.subject = .{ .kind = .job, .name = name };
}

fn job_path(arena: Allocator, name: []const u8, suffix: []const u8) Allocator.Error![]const u8 {
    const encoded = try cli_data.percent_encode(arena, name);
    return std.fmt.allocPrint(arena, "/v1/jobs/{s}{s}", .{ encoded, suffix });
}

// ---- run ---------------------------------------------------------------------------------

fn submit(
    env: *const Env,
    client: *Client,
    options: Options,
    spec: *const cli_job_args.Run,
    report: *Report,
) Error!void {
    const arena = env.arena;
    subject(report, spec.name);
    const body = try body_json(env, spec, report);
    const reply = try client.send("POST", "/v1/jobs", body, report);
    if (options.output == .json) {
        return emit_json(env, reply.body, report);
    }
    const parsed = try cli_data.parse(arena, reply, report);
    const state = cli_data.text(parsed, "state") orelse "pending";
    const created = reply.status == 201;
    var out: Writer.Allocating = .init(arena);
    out.writer.print("job {s}: {s}\n", .{
        spec.name,
        if (created) "submitted" else "unchanged",
    }) catch return error.OutOfMemory;
    if (!created) out.writer.print("  already submitted, {s}\n", .{state}) catch
        return error.OutOfMemory;
    if (options.verbose) {
        if (cli_data.number(parsed, "revision")) |revision| out.writer.print(
            "  revision {d}\n",
            .{revision},
        ) catch return error.OutOfMemory;
    }
    try cli_commands.emit(env, .stdout, out.written(), report);
}

fn body_json(env: *const Env, spec: *const cli_job_args.Run, report: *Report) Error![]const u8 {
    const arena = env.arena;
    var input: ?[]const u8 = null;
    if (spec.input_file) |path| input = try read_input(env, path, report);
    var out: Writer.Allocating = .init(arena);
    write_body(&out.writer, env, spec, input) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn write_body(
    writer: *Writer,
    env: *const Env,
    spec: *const cli_job_args.Run,
    input: ?[]const u8,
) (Writer.Error || Allocator.Error)!void {
    const string = std.json.Stringify.encodeJsonString;
    try writer.writeAll("{\"name\":");
    try string(spec.name, .{}, writer);
    try writer.writeAll(",\"image\":");
    try string(spec.image, .{}, writer);
    try writer.writeAll(",\"command\":[");
    for (spec.command.slice(), 0..) |word, index| {
        if (index > 0) try writer.writeByte(',');
        try string(word, .{}, writer);
    }
    try writer.print("],\"deadline_ms\":{d},\"submit_by_ms\":{d}", .{
        spec.deadline_ms, env.now_ms() + spec.submit_within_ms,
    });
    try write_pairs(writer, "env", spec.env.slice());
    try write_pairs(writer, "labels", spec.labels.slice());
    if (input) |text| {
        try writer.writeAll(",\"input\":");
        try string(text, .{}, writer);
        try writer.writeAll(",\"input_env\":");
        try string(spec.input_env orelse "", .{}, writer);
    }
    try writer.writeAll(",\"applied_by\":");
    try string(try cli_commands.applied_by(env), .{}, writer);
    try writer.writeByte('}');
}

fn write_pairs(
    writer: *Writer,
    key: []const u8,
    pairs: []const cli_job_args.Pair,
) Writer.Error!void {
    if (pairs.len == 0) return;
    const string = std.json.Stringify.encodeJsonString;
    try writer.print(",\"{s}\":[", .{key});
    for (pairs, 0..) |pair, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('[');
        try string(pair.key, .{}, writer);
        try writer.writeByte(',');
        try string(pair.value, .{}, writer);
        try writer.writeByte(']');
    }
    try writer.writeByte(']');
}

/// The input file: UTF-8 text of at most `job_input_bytes_max`. A refusal names the file and
/// never its content.
fn read_input(env: *const Env, path: []const u8, report: *Report) Error![]const u8 {
    const limit: std.Io.Limit = .limited(constants.job_input_bytes_max);
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(env.io, path, env.arena, limit) catch |err| {
        if (err == error.StreamTooLong) return cli_args.refuse(
            &report.diag,
            "the input file {s} is larger than 64 KiB",
            .{path},
        );
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return unreadable(report, path, switch (err) {
            error.FileNotFound => "no such file",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.IsDir => "it is a directory",
            else => "the system could not read it",
        });
    };
    if (!std.unicode.utf8ValidateSlice(text)) return cli_args.refuse(
        &report.diag,
        "the input file {s} is not UTF-8 text",
        .{path},
    );
    return text;
}

fn unreadable(report: *Report, path: []const u8, why: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0109);
    report.diag.while_("reading the input file", .{});
    report.diag.cause("{s}: {s}", .{ path, why });
    report.diag.context("file", "{s}", .{path});
    report.diag.fix(.{ .sentence = "check the path of --input-file" });
    return error.Failed;
}

// ---- get ---------------------------------------------------------------------------------

fn get(
    env: *const Env,
    client: *Client,
    options: Options,
    name: []const u8,
    wait: bool,
    report: *Report,
) Error!void {
    const arena = env.arena;
    subject(report, name);
    const path = try job_path(arena, name, "");
    const rounds = env.job_rounds_max orelse std.math.maxInt(u32);
    for (1..@as(usize, rounds) + 1) |round| {
        const reply = try client.get(path, report);
        const body = try cli_data.parse(arena, reply, report);
        const state = cli_data.text(body, "state") orelse
            return cli_data.contract(report, reply.request_id, "has no state");
        const ended = cli_job_view.terminal(state);
        if (wait and !ended and round < rounds) {
            env.io.sleep(.fromMilliseconds(env.job_poll_ms), .awake) catch {}; // Cancel.
            continue;
        }
        if (options.output == .json) {
            return emit_json(env, reply.body, report);
        }
        const text = try cli_job_view.job_text(arena, body, reply.request_id, report);
        try cli_commands.emit(env, .stdout, text, report);
        if (wait) {
            const status = cli_data.member(body, "status") orelse Value{ .null = {} };
            report.outcome = cli_job_view.outcome(state, cli_data.member(status, "end")) orelse
                constants.exit_ok;
        }
        return;
    }
}

// ---- list --------------------------------------------------------------------------------

/// Every row of `GET /v1/jobs` for a filter, page after page at the revision of the first.
const Rows = struct { revision: u64, rows: []const Value };

fn read_rows(
    env: *const Env,
    client: *Client,
    state: ?[]const u8,
    label: ?[]const u8,
    report: *Report,
) Error!Rows {
    const arena = env.arena;
    var rows: std.ArrayList(Value) = .empty;
    var revision: u64 = 0;
    var after: ?[]const u8 = null;
    for (0..pages_max) |page| {
        var path: Writer.Allocating = .init(arena);
        path.writer.print("/v1/jobs?limit={d}", .{constants.api_list_limit_max}) catch
            return error.OutOfMemory;
        if (state) |text| path.writer.print("&state={s}", .{text}) catch return error.OutOfMemory;
        if (label) |text| path.writer.print("&label={s}", .{
            try cli_data.percent_encode(arena, text),
        }) catch return error.OutOfMemory;
        if (after) |token| path.writer.print("&at={d}&continue={s}", .{
            revision, try cli_data.percent_encode(arena, token),
        }) catch return error.OutOfMemory;
        const reply = try client.get(path.written(), report);
        const body = try cli_data.parse(arena, reply, report);
        if (page == 0) revision = cli_data.number(body, "revision") orelse
            return cli_data.contract(report, reply.request_id, "has no revision");
        const found = cli_data.array(body, "jobs") orelse
            return cli_data.contract(report, reply.request_id, "has no jobs");
        try rows.appendSlice(arena, found);
        after = cli_data.text(body, "continue") orelse
            return .{ .revision = revision, .rows = rows.items };
    }
    return cli_data.contract(report, report.request_id.slice(), "does not end");
}

fn list(
    env: *const Env,
    client: *Client,
    options: Options,
    filter: cli_job_args.List,
    report: *Report,
) Error!void {
    const arena = env.arena;
    const found = try read_rows(env, client, filter.state, filter.label, report);
    if (options.output == .json) {
        var out: Writer.Allocating = .init(arena);
        const whole = .{ .revision = found.revision, .jobs = found.rows };
        std.json.Stringify.value(whole, .{}, &out.writer) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        return cli_commands.emit(env, .stdout, out.written(), report);
    }
    try cli_commands.emit(
        env,
        .stdout,
        try cli_job_view.list_text(arena, found.rows, options.output),
        report,
    );
}

// ---- cancel ------------------------------------------------------------------------------

fn cancel(
    env: *const Env,
    client: *Client,
    options: Options,
    name: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    subject(report, name);
    const by = try cli_commands.applied_by(env);
    const body = try std.fmt.allocPrint(arena, "{{\"applied_by\":\"{s}\"}}", .{by});
    const reply = try client.send("POST", try job_path(arena, name, "/cancel"), body, report);
    if (options.output == .json) {
        return emit_json(env, reply.body, report);
    }
    const parsed = try cli_data.parse(arena, reply, report);
    const end = try cli_job_view.end_text(arena, cli_data.member(parsed, "end"));
    const text = if (end.len > 0)
        try std.fmt.allocPrint(arena, "job {s}: already ended, {s}\n", .{ name, end })
    else
        try std.fmt.allocPrint(arena, "job {s}: cancel requested\n", .{name});
    try cli_commands.emit(env, .stdout, text, report);
}

// ---- watch -------------------------------------------------------------------------------

/// The endings already printed, newest over oldest: a `(name, epoch)` is hashed, and a hash
/// that is in the ring is not printed again.
const Seen = struct {
    keys: [seen_max]u64 = @splat(0),
    next: u32 = 0,

    /// True if `(name, epoch)` was seen; otherwise remembers it.
    fn seen(ring: *Seen, name: []const u8, epoch: u64) bool {
        const key = std.hash.Wyhash.hash(epoch, name) | 1;
        for (ring.keys) |known| {
            if (known == key) return true;
        }
        ring.keys[ring.next] = key;
        ring.next = (ring.next + 1) % seen_max;
        return false;
    }
};

fn watch(
    env: *const Env,
    client: *Client,
    options: Options,
    from_option: ?u64,
    report: *Report,
) Error!void {
    const arena = env.arena;
    var ring: Seen = .{};
    var from: u64 = from_option orelse try head(env, client, report) + 1;
    const rounds = env.job_rounds_max orelse std.math.maxInt(u32);
    for (0..rounds) |_| {
        const path = try std.fmt.allocPrint(
            arena,
            "/v1/jobs/watch?from={d}&timeout={d}",
            .{ from, env.job_watch_hold_ms },
        );
        const reply = try client.attempt("GET", path, "", report);
        if (reply.status == 410) {
            from = try relist(env, client, options, &ring, report) + 1;
        } else if (reply.status < 200 or reply.status >= 300) {
            return client.fail(reply, report);
        } else {
            from = try print_events(env, options, &ring, reply, report) + 1;
        }
    }
}

/// The store revision now.
fn head(env: *const Env, client: *Client, report: *Report) Error!u64 {
    const reply = try client.get("/v1/jobs?limit=1", report);
    const body = try cli_data.parse(env.arena, reply, report);
    return cli_data.number(body, "revision") orelse
        cli_data.contract(report, reply.request_id, "has no revision");
}

/// Prints the endings in a watch answer and returns its revision, the bookmark.
fn print_events(
    env: *const Env,
    options: Options,
    ring: *Seen,
    reply: cli_http.Reply,
    report: *Report,
) Error!u64 {
    const body = try cli_data.parse(env.arena, reply, report);
    const revision = cli_data.number(body, "revision") orelse
        return cli_data.contract(report, reply.request_id, "has no revision");
    for (cli_data.array(body, "events") orelse &.{}) |event| {
        const status = cli_data.member(event, "status") orelse continue;
        const name = cli_data.text(event, "name") orelse continue;
        try print_ending(env, options, ring, name, status, report);
    }
    return revision;
}

fn print_ending(
    env: *const Env,
    options: Options,
    ring: *Seen,
    name: []const u8,
    status: Value,
    report: *Report,
) Error!void {
    const state = cli_data.text(status, "state") orelse return;
    if (!cli_job_view.terminal(state)) return;
    if (ring.seen(name, cli_data.number(status, "epoch") orelse 0)) return;
    const arena = env.arena;
    const line = if (options.output == .json)
        try cli_job_view.ending_json(arena, name, status)
    else
        try cli_job_view.ending_line(arena, name, status);
    try cli_commands.emit(env, .stdout, line, report);
}

/// The server no longer has the revisions asked for: list every ending, print those not seen,
/// and return the list's revision.
fn relist(
    env: *const Env,
    client: *Client,
    options: Options,
    ring: *Seen,
    report: *Report,
) Error!u64 {
    const found = try read_rows(env, client, "ended", null, report);
    for (found.rows) |row| {
        const name = cli_data.text(row, "name") orelse continue;
        try print_ending(env, options, ring, name, row, report);
    }
    return found.revision;
}

const testing = std.testing;

const Script = struct {
    arena: Allocator,
    paths: std.ArrayList([]const u8) = .empty,

    fn reply(script: *Script, status: u16, body: []const u8) []const u8 {
        const format = "HTTP/1.1 {d} Reply\r\nContent-Length: {d}\r\n" ++
            "X-Request-Id: r-0000001\r\n\r\n{s}";
        return std.fmt.allocPrint(script.arena, format, .{ status, body.len, body }) catch
            unreachable; // The test arena has room.
    }

    fn exchange(
        context: *anyopaque,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) ?[]const u8 {
        _ = method;
        _ = body;
        const script: *Script = @ptrCast(@alignCast(context));
        script.paths.append(script.arena, path) catch unreachable; // The test arena has room.
        if (std.mem.startsWith(u8, path, "/v1/jobs?limit=1")) {
            return script.reply(200, "{\"revision\":10,\"jobs\":[]}");
        }
        if (std.mem.eql(u8, path[0..@min(path.len, 28)], "/v1/jobs/watch?from=11&timeo")) {
            return script.reply(410, "{\"request_id\":\"r\",\"diagnostics\":[]}");
        }
        if (std.mem.startsWith(u8, path, "/v1/jobs?limit=500&state=ended")) {
            return script.reply(200,
                \\{"revision":20,"jobs":[{"name":"a","state":"exited","node":"n1","epoch":3,
                \\"end":{"kind":"exited","code":0}}]}
            );
        }
        return script.reply(200,
            \\{"revision":22,"events":[
            \\{"type":"put","name":"a","revision":21,"status":{"state":"exited","node":"n1",
            \\"epoch":3,"end":{"kind":"exited","code":0}}},
            \\{"type":"put","name":"c","revision":21,"status":{"state":"running","epoch":6}},
            \\{"type":"put","name":"b","revision":22,"status":{"state":"failed","node":"n2",
            \\"epoch":5,"end":{"kind":"failed","cause":"oom"}}}]}
        );
    }
};

test "a watch that is told 410 lists the endings, skips the ones it printed, and goes on" {
    // Goal: docs/api.md's watch contract. Method: a scripted server: the head is 10, the first
    // watch is refused with 410, the listing holds `a`, the next watch repeats `a` and adds `b`
    // (and a job still running, which is no ending). `a` is printed once, from the list.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var script: Script = .{ .arena = arena };
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("ZCUBE_SERVER", "127.0.0.1:1");
    var stdout: Writer.Allocating = .init(arena);
    var stderr: Writer.Allocating = .init(arena);
    const env: Env = .{
        .io = testing.io,
        .arena = arena,
        .environ = &environ,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .deterministic_ids = true,
        .job_rounds_max = 2,
        .transport = .{ .context = &script, .exchange = Script.exchange },
    };
    try testing.expectEqual(@as(u8, 0), @import("cli.zig").run(&env, &.{ "job", "watch" }));
    const expected = "a  exited (code 0)  n1\nb  failed (oom)  n2\n";
    try testing.expectEqualStrings(expected, stdout.written());
    try testing.expectEqualStrings("", stderr.written());
    try testing.expectEqual(@as(usize, 4), script.paths.items.len);
    try testing.expect(std.mem.startsWith(u8, script.paths.items[3], "/v1/jobs/watch?from=21&"));
}
