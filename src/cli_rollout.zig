//! `zcube rollout status|pause|resume <service>` and `zcube history <service>` (docs/cli.md,
//! C3 slice 11), over `GET /v1/services/{name}/rollout`, `POST .../rollout/pause|resume` and
//! `GET /v1/services/{name}/history` (docs/api.md, "Rollouts and history"). Status and history
//! are reads; pause and resume are writes the server makes as the rollout controller
//! (src/rollout_steer.zig). The text functions are pure, so each shape is a unit test.

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const cli_commands = @import("cli_commands.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const cli_view = @import("cli_view.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Options = cli_args.Options;
const Report = cli_report.Report;
const Value = cli_data.Value;
const Writer = std.Io.Writer;

pub const Action = enum { status, pause, @"resume" };

/// An image longer than this is shortened in the history table: `b3:` and 12 hex digits, then
/// three dots, as `stats pull` does.
const image_shown_bytes = 15;

pub fn rollout(
    env: *const Env,
    client: *Client,
    options: Options,
    action: Action,
    name: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    report.subject = .{ .kind = .service, .name = name };
    const base = try service_path(arena, name, "/rollout");
    const command = try std.fmt.allocPrint(arena, "zcube rollout {s}", .{@tagName(action)});
    const reply = switch (action) {
        .status => try ask(client, "GET", base, "", command, report),
        .pause, .@"resume" => try ask(client, "POST", try std.fmt.allocPrint(arena, "{s}/{s}", .{
            base, @tagName(action),
        }), try steer_body(env), command, report),
    };
    if (options.output == .json) return emit_json(env, reply.body, report);
    const body = try cli_data.parse(arena, reply, report);
    if (cli_data.number(body, "revision")) |revision| report.revision = revision;
    const out = switch (action) {
        .status => status_text(arena, body, env.now_ms()),
        .pause, .@"resume" => steer_text(arena, body),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Contract => return cli_data.contract(report, reply.request_id, "is not a rollout"),
    };
    try cli_commands.emit(env, .stdout, out, report);
}

pub fn history(
    env: *const Env,
    client: *Client,
    options: Options,
    name: []const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    report.subject = .{ .kind = .service, .name = name };
    const path = try service_path(arena, name, "/history");
    const reply = try ask(client, "GET", path, "", "zcube history", report);
    if (options.output == .json) return emit_json(env, reply.body, report);
    const body = try cli_data.parse(arena, reply, report);
    if (cli_data.number(body, "revision")) |revision| report.revision = revision;
    const out = history_text(arena, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Contract => return cli_data.contract(report, reply.request_id, "is not a history"),
    };
    try cli_commands.emit(env, .stdout, out, report);
}

/// One request whose refusal is relayed, unless it is the refusal of a server older than these
/// routes (C3 slice 11): that is said as such, so an operator who upgraded the command first
/// is told to upgrade the server (docs/cli.md, "Upgrading").
fn ask(
    client: *Client,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    command: []const u8,
    report: *Report,
) Error!cli_http.Reply {
    const reply = try client.attempt(method, path, body, report);
    if (reply.status >= 200 and reply.status < 300) return reply;
    if (!older_server(reply)) return client.fail(reply, report);
    assert(report.diag.code == null);
    report.diag.raise(.E0101);
    report.diag.while_("asking zcube-server for {s} {s}", .{ method, path });
    report.diag.cause("zcube-server does not serve `{s}`: it is older than this zcube", .{
        command,
    });
    report.diag.fix(.{ .sentence = "upgrade zcube-server first, then the command line" });
    return error.Failed;
}

/// The refusals a server from before C3 slice 11 gives these routes: a read is 404 "the API
/// serves nothing at ...", and a POST under /v1/services is 400 naming the paths POST is
/// accepted at, which then did not include /v1/services.
pub fn older_server(reply: cli_http.Reply) bool {
    const body = reply.body;
    if (reply.status == 404) return std.mem.indexOf(u8, body, "the API serves nothing at") != null;
    if (reply.status != 400) return false;
    const where = "POST is accepted at /v1/apply";
    const at = std.mem.indexOf(u8, body, where) orelse return false;
    const rest = body[at..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
    return std.mem.indexOf(u8, rest[0..end], "/v1/services") == null;
}

fn service_path(arena: Allocator, name: []const u8, suffix: []const u8) Error![]const u8 {
    const encoded = try cli_data.percent_encode(arena, name);
    return std.fmt.allocPrint(arena, "/v1/services/{s}{s}", .{ encoded, suffix });
}

fn steer_body(env: *const Env) Error![]const u8 {
    const by = try cli_commands.applied_by(env);
    var request: Writer.Allocating = .init(env.arena);
    request.writer.writeAll("{\"applied_by\":") catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(by, .{}, &request.writer) catch return error.OutOfMemory;
    request.writer.writeByte('}') catch return error.OutOfMemory;
    return request.written();
}

fn emit_json(env: *const Env, body: []const u8, report: *Report) Error!void {
    const line = try std.fmt.allocPrint(env.arena, "{s}\n", .{std.mem.trimEnd(u8, body, "\n")});
    try cli_commands.emit(env, .stdout, line, report);
}

pub const TextError = error{ OutOfMemory, Contract };

/// `hello: generation 2, 3 replicas`, the rollout (or `no rollout`), then the policy.
pub fn status_text(arena: Allocator, body: Value, now_ms: u64) TextError![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    const name = cli_data.text(body, "service") orelse return error.Contract;
    const generation = cli_data.number(body, "generation") orelse return error.Contract;
    const replicas = cli_data.number(body, "replicas") orelse return error.Contract;
    w.print("{s}: generation {d}, {d} replicas\n", .{ name, generation, replicas }) catch
        return error.OutOfMemory;
    const record = cli_data.member(body, "rollout") orelse return error.Contract;
    if (record == .null) {
        w.writeAll("no rollout\n") catch return error.OutOfMemory;
    } else {
        try rollout_lines(arena, w, record, now_ms);
    }
    try policy_line(arena, w, cli_data.member(body, "policy") orelse return error.Contract);
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn rollout_lines(arena: Allocator, w: *Writer, record: Value, now_ms: u64) TextError!void {
    const oom = error.OutOfMemory;
    const from = cli_data.number(record, "from") orelse return error.Contract;
    const to = cli_data.number(record, "to") orelse return error.Contract;
    const phase = cli_data.text(record, "phase") orelse return error.Contract;
    const started = cli_data.number(record, "started_at_ms") orelse return error.Contract;
    const deadline = cli_data.number(record, "deadline_at_ms") orelse return error.Contract;
    const reason = cli_data.text(record, "reason") orelse "apply";
    w.print("rollout {d} → {d} ({s}): {s}, started {s} ago\n", .{
        from, to, reason, phase, try cli_view.age_text(arena, started, now_ms),
    }) catch return oom;
    w.print("  {d} new ready, {d} old retired", .{
        cli_data.number(record, "ready_new") orelse 0,
        cli_data.number(record, "retired_old") orelse 0,
    }) catch return oom;
    const active = std.mem.eql(u8, phase, "progressing") or std.mem.eql(u8, phase, "rolling_back");
    if (active) {
        const left = if (deadline > now_ms) "in " else "passed ";
        const at = if (deadline > now_ms)
            try cli_view.age_text(arena, now_ms, deadline)
        else
            try cli_view.age_text(arena, deadline, now_ms);
        w.print(", deadline {s}{s}{s}", .{ left, at, if (deadline > now_ms) "" else " ago" }) catch
            return oom;
    }
    w.writeByte('\n') catch return oom;
    if (std.mem.eql(u8, phase, "paused")) {
        const by = cli_data.text(record, "paused_by") orelse "failure";
        const at = cli_data.number(record, "paused_at_ms") orelse started;
        w.print("  paused by {s} {s} ago; zcube rollout resume continues it\n", .{
            by, try cli_view.age_text(arena, at, now_ms),
        }) catch return oom;
    }
}

fn policy_line(arena: Allocator, w: *Writer, policy: Value) TextError!void {
    const strategy = cli_data.text(policy, "strategy") orelse return error.Contract;
    const on_failure = cli_data.text(policy, "on_failure") orelse return error.Contract;
    const surge = cli_data.number(policy, "max_surge") orelse return error.Contract;
    const unavailable = cli_data.number(policy, "max_unavailable") orelse return error.Contract;
    const min_ready = cli_data.number(policy, "min_ready_ms") orelse return error.Contract;
    const deadline = cli_data.number(policy, "progress_deadline_ms") orelse
        return error.Contract;
    w.print("policy: {s}, surge {d}, unavailable {d}, min ready {s}, deadline {s}, " ++
        "on failure {s}\n", .{
        strategy,
        surge,
        unavailable,
        try seconds(arena, min_ready),
        try seconds(arena, deadline),
        on_failure,
    }) catch return error.OutOfMemory;
}

/// `cli_view.seconds_text`, whose only failure is running out of memory.
fn seconds(arena: Allocator, ms: u64) TextError![]const u8 {
    return cli_view.seconds_text(arena, ms) catch error.OutOfMemory;
}

/// `hello: progressing → paused (decision d-...)`, or `hello: already paused, no change`.
pub fn steer_text(arena: Allocator, body: Value) TextError![]const u8 {
    const name = cli_data.text(body, "name") orelse return error.Contract;
    const action = cli_data.text(body, "action") orelse return error.Contract;
    const phase = cli_data.text(body, "phase") orelse return error.Contract;
    if (std.mem.eql(u8, action, "none")) {
        return std.fmt.allocPrint(arena, "{s}: already {s}, no change\n", .{ name, phase });
    }
    const change = cli_data.text(body, "change") orelse return error.Contract;
    const decision = cli_data.text(body, "decision") orelse return error.Contract;
    return std.fmt.allocPrint(arena, "{s}: {s} (decision {s})\n", .{ name, change, decision });
}

/// One row per stored generation, newest first; `*` marks the one the service runs now.
pub fn history_text(arena: Allocator, body: Value) TextError![]const u8 {
    const current = cli_data.number(body, "generation") orelse return error.Contract;
    const items = cli_data.array(body, "generations") orelse return error.Contract;
    if (items.len == 0) return "no generations are stored\n";
    var cells: std.ArrayList([]const []const u8) = .empty;
    for (items) |item| try cells.append(arena, try history_row(arena, item, current));
    var out: Writer.Allocating = .init(arena);
    const head: []const []const u8 = &.{ "GEN", "IMAGE", "REASON", "APPLIED BY", "REQUEST" };
    cli_view.write_table(&out.writer, head, cells.items) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn history_row(arena: Allocator, item: Value, current: u64) TextError![]const []const u8 {
    const generation = cli_data.number(item, "generation") orelse return error.Contract;
    const value = cli_data.member(item, "value") orelse return error.Contract;
    const image = cli_data.text(value, "image") orelse return error.Contract;
    const reason = cli_data.text(value, "reason") orelse return error.Contract;
    const by = cli_data.text(value, "applied_by") orelse "";
    const request = cli_data.text(value, "request_id") orelse "";
    const shown = if (image.len > image_shown_bytes)
        try std.fmt.allocPrint(arena, "{s}...", .{image[0..image_shown_bytes]})
    else
        image;
    const row = try arena.alloc([]const u8, 5);
    row[0] = try std.fmt.allocPrint(arena, "{d}{s}", .{
        generation, if (generation == current) "*" else "",
    });
    row[1] = shown;
    row[2] = if (cli_data.number(value, "restores")) |restores|
        try std.fmt.allocPrint(arena, "{s} of {d}", .{ reason, restores })
    else
        reason;
    row[3] = if (by.len > 0) by else "-";
    row[4] = if (request.len > 0) request else "-";
    return row;
}

const testing = std.testing;

fn parse_test(arena: Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{});
}

const policy_json =
    \\"policy":{"strategy":"rolling","max_surge":1,"max_unavailable":0,"min_ready_ms":5000,
    \\"ready_timeout_ms":120000,"progress_deadline_ms":600000,"grace_ms":10000,
    \\"on_failure":"rollback"}
;

test "rollout status: none, progressing, paused by a user" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = try parse_test(arena, "{\"service\":\"hello\",\"generation\":1,\"replicas\":3," ++
        "\"rollout\":null," ++ policy_json ++ "}");
    try testing.expectEqualStrings(
        \\hello: generation 1, 3 replicas
        \\no rollout
        \\policy: rolling, surge 1, unavailable 0, min ready 5s, deadline 600s, on failure rollback
        \\
    , try status_text(arena, none, 0));
    const running = try parse_test(arena, "{\"service\":\"hello\",\"generation\":2," ++
        "\"replicas\":3,\"rollout\":{\"from\":1,\"to\":2,\"phase\":\"progressing\"," ++
        "\"started_at_ms\":1000,\"deadline_at_ms\":601000,\"ready_new\":1}," ++ policy_json ++ "}");
    const text = try status_text(arena, running, 181_000);
    try testing.expect(std.mem.startsWith(u8, text,
        \\hello: generation 2, 3 replicas
        \\rollout 1 → 2 (apply): progressing, started 3m ago
        \\  1 new ready, 0 old retired, deadline in 7m
        \\
    ));
    const paused = try parse_test(arena, "{\"service\":\"hello\",\"generation\":2," ++
        "\"replicas\":3,\"rollout\":{\"from\":1,\"to\":2,\"phase\":\"paused\",\"reason\":" ++
        "\"apply\",\"started_at_ms\":1000,\"deadline_at_ms\":601000,\"paused_at_ms\":61000," ++
        "\"paused_by\":\"user\"}," ++ policy_json ++ "}");
    const paused_text = try status_text(arena, paused, 121_000);
    const line = "  paused by user 1m ago; zcube rollout resume continues it\n";
    try testing.expect(std.mem.indexOf(u8, paused_text, line) != null);
    const broken = try parse_test(arena, "{\"service\":\"hello\"}");
    try testing.expectError(error.Contract, status_text(arena, broken, 0));
}

test "rollout pause and resume: the change, or no change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paused = try parse_test(arena, "{\"name\":\"hello\",\"action\":\"pause\"," ++
        "\"phase\":\"paused\",\"change\":\"progressing → paused\",\"decision\":\"d-7\"}");
    try testing.expectEqualStrings(
        "hello: progressing → paused (decision d-7)\n",
        try steer_text(arena, paused),
    );
    const again = try parse_test(arena, "{\"name\":\"hello\",\"action\":\"none\"," ++
        "\"phase\":\"paused\",\"change\":\"no change\"}");
    try testing.expectEqualStrings(
        "hello: already paused, no change\n",
        try steer_text(arena, again),
    );
}

test "history: newest first, the current generation marked, long images shortened, reasons" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try parse_test(arena,
        \\{"service":"hello","generation":2,"generations":[
        \\{"generation":3,"value":{"image":"b3:51aa9c03","reason":"rollback","restores":1}},
        \\{"generation":2,"value":{"image":"b3:0123456789abcdef0123","reason":"apply",
        \\ "applied_by":"alex@laptop","request_id":"r-0000002"}},
        \\{"generation":1,"value":{"image":"b3:51aa9c03","reason":"apply"}}]}
    );
    const text = try history_text(arena, body);
    try testing.expect(std.mem.indexOf(u8, text, "2*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "b3:0123456789ab...") != null);
    try testing.expect(std.mem.indexOf(u8, text, "alex@laptop") != null);
    try testing.expect(std.mem.indexOf(u8, text, "r-0000002") != null);
    try testing.expect(std.mem.indexOf(u8, text, "b3:51aa9c03") != null);
    try testing.expect(std.mem.indexOf(u8, text, "rollback of 1") != null);
    const empty = try parse_test(arena, "{\"generation\":1,\"generations\":[]}");
    try testing.expectEqualStrings("no generations are stored\n", try history_text(arena, empty));
}
