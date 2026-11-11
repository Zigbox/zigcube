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
/// Endings `job watch` remembers, to print each once across a
/// relist: the server keeps at most this many ended jobs, so a relist cannot return more.
const seen_max = constants.job_admitted_window_max;

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
    if (spec.relay) |name| {
        try writer.writeAll(",\"relay\":");
        try string(name, .{}, writer);
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
    // The limit fails a file that reaches it, so one byte more lets exactly the maximum through.
    const limit: std.Io.Limit = .limited(constants.job_input_bytes_max + 1);
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
    report.diag.while_("reading the input file of job run", .{});
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

/// Listings `watch` restarts after the server compacted past one, before it calls it broken.
const relists_max: u32 = 8;

fn read_rows(
    env: *const Env,
    client: *Client,
    state: ?[]const u8,
    label: ?[]const u8,
    gone_ok: bool,
    report: *Report,
) Error!?Rows {
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
        const reply = if (gone_ok)
            try client.attempt("GET", path.written(), "", report)
        else
            try client.get(path.written(), report);
        if (gone_ok and reply.status == 410) return null; // Compacted past this listing's `at`.
        if (reply.status < 200 or reply.status >= 300) return client.fail(reply, report);
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
    const found = (try read_rows(env, client, filter.state, filter.label, false, report)).?;
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
    var request: Writer.Allocating = .init(arena);
    request.writer.writeAll("{\"applied_by\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(by, .{}, &request.writer) catch return error.OutOfMemory;
    request.writer.writeByte('}') catch return error.OutOfMemory;
    const body = request.written();
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

/// The endings already printed, oldest first: a placed ending's `(name, epoch)` or an unplaced
/// ending's `(name, ended_at_ms)` is hashed (docs/api.md). The
/// array holds `seen_max` keys, the most a relist can return, so a listing never evicts a key it
/// still has to look up.
const Seen = struct {
    keys: [seen_max]u64 = @splat(0),
    count: u32 = 0,
    next: u32 = 0,

    /// True if the ending was seen; otherwise remembers it. A placed ending (`epoch` non-zero, a
    /// store revision) is told by its epoch alone; an unplaced one has no epoch (0 here), so
    /// `ended_at_ms` is what tells two endings of a reused name apart.
    fn seen(ring: *Seen, name: []const u8, epoch: u64, ended_at_ms: u64) bool {
        const time: u64 = if (epoch != 0) 0 else ended_at_ms;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(name);
        hasher.update(std.mem.asBytes(&epoch));
        hasher.update(std.mem.asBytes(&time));
        const key = hasher.final() | 1;
        for (ring.keys[0..ring.count]) |known| {
            if (known == key) return true;
        }
        ring.keys[ring.next] = key;
        ring.next = (ring.next + 1) % seen_max;
        ring.count = @min(ring.count + 1, seen_max);
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
    var ring: Seen = .{};
    var from: u64 = from_option orelse try head(env, client, report) + 1;
    const rounds = env.job_rounds_max orelse std.math.maxInt(u32);
    for (0..rounds) |_| {
        // Everything one round allocates (the path, the answer, its parse) is freed with it, so a
        // watch that runs for days holds the same memory as one that has just begun.
        // A failure ends the command and its report may point into the round's memory, so only a
        // round that succeeded frees it.
        var round_arena: std.heap.ArenaAllocator = .init(env.round_backing);
        var round_env = env.*;
        round_env.arena = round_arena.allocator();
        var round_client = client.*;
        round_client.env = &round_env;
        from = try watch_round(&round_env, &round_client, options, &ring, from, report);
        round_client.env = env;
        client.* = round_client;
        round_arena.deinit();
    }
}

/// One request of the watch and what it prints; returns the revision to ask from next.
fn watch_round(
    env: *const Env,
    client: *Client,
    options: Options,
    ring: *Seen,
    from: u64,
    report: *Report,
) Error!u64 {
    const path = try std.fmt.allocPrint(
        env.arena,
        "/v1/jobs/watch?from={d}&timeout={d}",
        .{ from, env.job_watch_hold_ms },
    );
    const reply = try client.attempt("GET", path, "", report);
    var next: u64 = undefined;
    if (reply.status == 410) {
        next = try relist(env, client, options, ring, report) + 1;
    } else if (reply.status < 200 or reply.status >= 300) {
        return client.fail(reply, report);
    } else {
        const printed = try print_events(env, options, ring, reply, report);
        next = printed.revision + 1;
        if (!printed.any) return next;
    }
    try resume_line(env, next, report);
    return next;
}

/// Tells the user where to pick the watch up again: stderr, so the endings on stdout keep their
/// shape (`--output json` too), after every answer that carried an ending or a relist.
fn resume_line(env: *const Env, next: u64, report: *Report) Error!void {
    const line = try std.fmt.allocPrint(env.arena, "watching: resume with --from {d}\n", .{next});
    try cli_commands.emit(env, .stderr, line, report);
}

/// The store revision now.
fn head(env: *const Env, client: *Client, report: *Report) Error!u64 {
    const reply = try client.get("/v1/jobs?limit=1", report);
    const body = try cli_data.parse(env.arena, reply, report);
    return cli_data.number(body, "revision") orelse
        cli_data.contract(report, reply.request_id, "has no revision");
}

/// Prints the endings in a watch answer. `revision` is the answer's bookmark; `any` is whether
/// the answer held events.
const Printed = struct { revision: u64, any: bool };

fn print_events(
    env: *const Env,
    options: Options,
    ring: *Seen,
    reply: cli_http.Reply,
    report: *Report,
) Error!Printed {
    const body = try cli_data.parse(env.arena, reply, report);
    const revision = cli_data.number(body, "revision") orelse
        return cli_data.contract(report, reply.request_id, "has no revision");
    const events = cli_data.array(body, "events") orelse &.{};
    for (events) |event| {
        const status = cli_data.member(event, "status") orelse continue;
        const name = cli_data.text(event, "name") orelse continue;
        try print_ending(env, options, ring, name, status, report);
    }
    return .{ .revision = revision, .any = events.len > 0 };
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
    const epoch = cli_data.number(status, "epoch") orelse 0;
    const ended_at_ms = cli_data.number(status, "ended_at_ms") orelse 0;
    if (ring.seen(name, epoch, ended_at_ms)) return;
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
    var tries: u32 = 0;
    const found = while (tries < relists_max) : (tries += 1) {
        if (try read_rows(env, client, "ended", null, true, report)) |rows| break rows;
    } else return cli_data.contract(report, report.request_id.slice(), "keeps being compacted");
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
        // The path lives in the round's memory, which the command frees: keep a copy.
        const kept = script.arena.dupe(u8, path) catch unreachable; // The test arena has room.
        script.paths.append(script.arena, kept) catch unreachable; // The test arena has room.
        if (std.mem.startsWith(u8, path, "/v1/jobs?limit=1")) {
            return script.reply(200, "{\"revision\":10,\"jobs\":[]}");
        }
        if (std.mem.eql(u8, path[0..@min(path.len, 28)], "/v1/jobs/watch?from=11&timeo")) {
            return script.reply(410, "{\"request_id\":\"r\",\"diagnostics\":[]}");
        }
        if (std.mem.startsWith(u8, path, "/v1/jobs?limit=500&state=ended")) {
            return script.reply(200,
                \\{"revision":20,"jobs":[{"name":"a","state":"exited","node":"n1","epoch":3,
                \\"ended_at_ms":900,"end":{"kind":"exited","code":0}}]}
            );
        }
        return script.reply(200,
            \\{"revision":22,"events":[
            \\{"type":"put","name":"a","revision":21,"status":{"state":"exited","node":"n1",
            \\"epoch":3,"ended_at_ms":900,"end":{"kind":"exited","code":0}}},
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
        .round_backing = testing.allocator,
        .transport = .{ .context = &script, .exchange = Script.exchange },
    };
    try testing.expectEqual(@as(u8, 0), @import("cli.zig").run(&env, &.{ "job", "watch" }));
    const expected = "a  exited (code 0)  n1\nb  failed (oom)  n2\n";
    try testing.expectEqualStrings(expected, stdout.written());
    // stderr tells where to resume: after the relist (revision 20) and after the batch (22).
    const resumed = "watching: resume with --from 21\nwatching: resume with --from 23\n";
    try testing.expectEqualStrings(resumed, stderr.written());
    try testing.expectEqual(@as(usize, 4), script.paths.items.len);
    try testing.expect(std.mem.startsWith(u8, script.paths.items[3], "/v1/jobs/watch?from=21&"));
}

/// A scripted server for the tests below: a listing of `total` endings in pages of 500, a watch
/// that is gone `gone_watches` times, a first listing that is gone once at its second page when
/// `gone_midway`, and every body that was posted.
const Big = struct {
    arena: Allocator,
    total: u32,
    gone_watches: u32,
    gone_midway: bool = false,
    watches: u32 = 0,
    lists: u32 = 0,
    posted: std.ArrayList([]const u8) = .empty,
    /// The answer to `GET /v1/jobs/x`, when not empty.
    job_body: []const u8 = "",

    fn exchange(
        context: *anyopaque,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) ?[]const u8 {
        const big: *Big = @ptrCast(@alignCast(context));
        var script: Script = .{ .arena = big.arena };
        if (std.mem.eql(u8, method, "POST")) {
            big.posted.append(big.arena, body) catch unreachable; // The test arena has room.
            return script.reply(200, "{\"state\":\"cancelled\"}");
        }
        if (std.mem.startsWith(u8, path, "/v1/jobs?limit=1")) {
            return script.reply(200, "{\"revision\":10,\"jobs\":[]}");
        }
        if (std.mem.startsWith(u8, path, "/v1/jobs/watch?")) {
            big.watches += 1;
            if (big.watches <= big.gone_watches) return script.reply(410, "{}");
            return script.reply(200, "{\"revision\":30,\"events\":[]}");
        }
        if (big.job_body.len > 0 and std.mem.startsWith(u8, path, "/v1/jobs/x")) {
            return script.reply(200, big.job_body);
        }
        return big.page(path);
    }

    fn page(big: *Big, path: []const u8) []const u8 {
        var script: Script = .{ .arena = big.arena };
        const marker = "&continue=p";
        const first: u32 = if (std.mem.indexOf(u8, path, marker)) |at|
            std.fmt.parseInt(u32, path[at + marker.len ..], 10) catch unreachable // Our token.
        else
            0;
        if (first == 0) big.lists += 1;
        if (big.gone_midway and big.lists == 1 and first == 500) return script.reply(410, "{}");
        var out: Writer.Allocating = .init(big.arena);
        out.writer.writeAll("{\"revision\":20,\"jobs\":[") catch unreachable; // The arena has room.
        const last = @min(first + 500, big.total);
        for (first..last) |index| {
            if (index > first) out.writer.writeByte(',') catch unreachable; // The arena has room.
            out.writer.print(
                "{{\"name\":\"j{d}\",\"state\":\"exited\",\"node\":\"n\",\"epoch\":1," ++
                    "\"end\":{{\"kind\":\"exited\",\"code\":0}}}}",
                .{index},
            ) catch unreachable; // The arena has room.
        }
        out.writer.writeByte(']') catch unreachable; // The arena has room.
        if (last < big.total) out.writer.print(",\"continue\":\"p{d}\"", .{last}) catch
            unreachable; // The arena has room.
        out.writer.writeByte('}') catch unreachable; // The arena has room.
        return script.reply(200, out.written());
    }
};

fn big_run(
    arena: Allocator,
    big: *Big,
    words: []const []const u8,
    user: []const u8,
    rounds: u32,
    stdout: *Writer.Allocating,
) !u8 {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("ZCUBE_SERVER", "127.0.0.1:1");
    try environ.put("USER", user);
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
        .job_rounds_max = rounds,
        .round_backing = testing.allocator,
        .transport = .{ .context = big, .exchange = Big.exchange },
    };
    return @import("cli.zig").run(&env, words);
}

test "a relist of more endings than 1,024 prints each ending once, however often it repeats" {
    // Goal: exactly-once across relists (api.md). Method: 2,000 endings in four pages; the first
    // listing is gone at its second page and restarts, then the watch is gone twice more, so
    // the endings are listed three times; each prints once.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var big: Big = .{ .arena = arena, .total = 2000, .gone_watches = 3, .gone_midway = true };
    var stdout: Writer.Allocating = .init(arena);
    const words: []const []const u8 = &.{ "job", "watch" };
    try testing.expectEqual(@as(u8, 0), try big_run(arena, &big, words, "u", 4, &stdout));
    try testing.expectEqual(@as(u32, 4), big.lists); // A restart, then two more listings.
    var lines = std.mem.splitScalar(u8, stdout.written(), '\n');
    var names: std.StringHashMapUnmanaged(void) = .empty;
    var count: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        const name = line[0..std.mem.indexOfScalar(u8, line, ' ').?];
        try testing.expect(!names.contains(name));
        try names.put(arena, name, {});
    }
    try testing.expectEqual(@as(u32, 2000), count);
}

test "a watch of many empty answers does not grow the command's memory" {
    // Goal: RB-S13, a long watch runs in constant memory. Method: 300 empty answers; the
    // command's arena stays where the first request left it.
    var server_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer server_state.deinit();
    var env_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer env_state.deinit();
    var big: Big = .{ .arena = server_state.allocator(), .total = 0, .gone_watches = 0 };
    var stdout: Writer.Allocating = .init(server_state.allocator());
    const words: []const []const u8 = &.{ "job", "watch" };
    const code = try big_run(env_state.allocator(), &big, words, "u", 300, &stdout);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(env_state.queryCapacity() < 16 * 1024);
}

test "two unplaced endings of a reused name differ by ended_at_ms, one ending repeats" {
    // Goal: docs/api.md's dedupe key. Method: the key of a cancelled-before-claim job (no epoch)
    // is the same for a reused name unless `ended_at_ms` is part of it; a repeat of one ending
    // (a watch event after the list) is still seen.
    var ring: Seen = .{};
    try testing.expect(!ring.seen("a", 0, 1_000));
    try testing.expect(ring.seen("a", 0, 1_000));
    try testing.expect(!ring.seen("a", 0, 4_000_000));
    try testing.expect(!ring.seen("a", 7, 1_000));
    // A placed ending is one key whether or not the row carries `ended_at_ms`.
    try testing.expect(ring.seen("a", 7, 0));
    try testing.expect(ring.seen("a", 7, 5));
    try testing.expect(!ring.seen("b", 0, 1_000));
}

test "job cancel escapes the user in its body" {
    // Goal: USER='CORP\jdoe' can cancel. Method: the body the server is sent is JSON that parses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var big: Big = .{ .arena = arena, .total = 0, .gone_watches = 0 };
    var stdout: Writer.Allocating = .init(arena);
    const user = "CORP\\jdo\"e";
    const words: []const []const u8 = &.{ "job", "cancel", "j1" };
    try testing.expectEqual(@as(u8, 0), try big_run(arena, &big, words, user, 1, &stdout));
    try testing.expectEqual(@as(usize, 1), big.posted.items.len);
    const parsed = try std.json.parseFromSliceLeaky(
        struct { applied_by: []const u8 },
        arena,
        big.posted.items[0],
        .{},
    );
    try testing.expect(std.mem.startsWith(u8, parsed.applied_by, "CORP\\jdo\"e@"));
}

test "an input file of exactly 64 KiB is read, one byte more is refused" {
    // Goal: the server's `<=` (job_api.zig). Method: two files in a scratch directory.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exact = try arena.alloc(u8, constants.job_input_bytes_max);
    @memset(exact, 'a');
    const over = try arena.alloc(u8, constants.job_input_bytes_max + 1);
    @memset(over, 'a');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "exact", .data = exact });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "over", .data = over });
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var stdout: Writer.Allocating = .init(arena);
    const env: Env = .{
        .io = testing.io,
        .arena = arena,
        .environ = &environ,
        .stdout = &stdout.writer,
        .stderr = &stdout.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .deterministic_ids = true,
    };
    var report: Report = undefined;
    report.reset();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    const text = try read_input(&env, try std.fmt.allocPrint(arena, "{s}exact", .{root}), &report);
    try testing.expectEqual(@as(usize, constants.job_input_bytes_max), text.len);
    const over_path = try std.fmt.allocPrint(arena, "{s}over", .{root});
    try testing.expectError(error.Failed, read_input(&env, over_path, &report));
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0111), report.diag.code);
}

test "job get --wait exits 0, 10, 11 or 12 by how the job ended" {
    // Goal: the brief's exit codes, golden-tested. Method: a job that has ended each way, as the
    // server states it; the exit code and the first line of the text are compared.
    const Case = struct { state: []const u8, end: []const u8, code: u8 };
    const exited = "{\"kind\":\"exited\",\"code\":";
    const cases = [_]Case{
        .{ .state = "exited", .end = exited ++ "0}", .code = 0 },
        .{ .state = "exited", .end = exited ++ "3}", .code = 10 },
        .{ .state = "failed", .end = "{\"kind\":\"failed\",\"cause\":\"oom\"}", .code = 11 },
        .{ .state = "cancelled", .end = "{\"kind\":\"cancelled\"}", .code = 12 },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        const format = "{{\"revision\":5,\"job\":{{\"name\":\"x\"}},\"state\":\"{s}\"," ++
            "\"status\":{{\"state\":\"{s}\",\"epoch\":1,\"end\":{s}}}}}";
        var big: Big = .{ .arena = arena, .total = 0, .gone_watches = 0 };
        big.job_body = try std.fmt.allocPrint(arena, format, .{ case.state, case.state, case.end });
        var stdout: Writer.Allocating = .init(arena);
        const words: []const []const u8 = &.{ "job", "get", "x", "--wait" };
        try testing.expectEqual(case.code, try big_run(arena, &big, words, "u", 1, &stdout));
        try testing.expect(std.mem.indexOf(u8, stdout.written(), case.state) != null);
    }
}
