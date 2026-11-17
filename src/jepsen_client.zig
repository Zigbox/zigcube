//! zcube-jepsen-client's work: one operation against zcube-server, recorded as two history lines,
//! the invocation and its completion (docs/jepsen.md, "The client"). A test-only tool: the shipped
//! `zcube` does not grow for it, and the operator never runs it.
//!
//! Each operation acts on one service, a register whose value is its `replicas` count:
//! `apply` writes a count, `get` reads it (null when the service does not exist), `delete`
//! removes the service and `watch` holds one long poll on its key from a revision.
//!
//! How an outcome is classified is the point of the tool (docs/jepsen.md, "ok, fail and info"):
//! a write is `info` whenever the server may have acted on it and said nothing certain, as
//! ZC-E0213 is recorded in `test-store-faults`; a read is never `info`, since it changes nothing.

const std = @import("std");
const assert = std.debug.assert;
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const history = @import("jepsen_history.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Env = cli_env.Env;
const Client = cli_http.Client;
const Reply = cli_http.Reply;
const Report = cli_report.Report;
const Line = history.Line;
const Op = history.Op;
const Value = history.Value;

/// The image every `apply` names. The store only checks its length; a node that runs the replicas
/// is not what the battery tests.
pub const image_default = "jepsen:1";
/// How long a `watch` holds when it has nothing to report, by default and at most. The most is
/// the CLI's own hold, under its reply timeout, so an idle answer arrives before the client
/// gives up on it.
pub const hold_ms_default: u32 = 5_000;
pub const hold_ms_max: u32 = constants.cli_job_watch_hold_ms;

pub const Args = struct {
    op: Op,
    history: []const u8,
    process: u32,
    service: []const u8,
    /// `apply`: the replicas count to write.
    value: ?u32 = null,
    /// `watch`: the revision to watch from.
    from: ?u64 = null,
    hold_ms: u32 = hold_ms_default,
    image: []const u8 = image_default,
    server: ?[]const u8 = null,
    tls: cli_http.TlsFlags = .{},
};

pub const usage =
    \\usage: zcube-jepsen-client --op apply|get|delete|watch --history FILE --process N
    \\         --service NAME [--value N] [--from REVISION] [--hold-ms N] [--image DIGEST]
    \\         [--server HOST:PORT] [--ca FILE --cert FILE --key FILE [--tls-name NAME]]
    \\
    \\One operation against zcube-server, appended to FILE as two JSON lines (the invocation and
    \\its completion; docs/jepsen.md). The completion is also printed. Exit 0: ok, 1: fail,
    \\2: info (unknown), 64: bad arguments, 74: FILE cannot be written. A test-only tool of the
    \\Jepsen battery.
    \\
;

const image_problem = "--image is empty or holds a quote, a backslash or a control character";

/// Reads the arguments (without the program name). A bad one is a sentence in `problem`.
pub fn parse(arguments: []const []const u8, problem: *[]const u8) error{Usage}!Args {
    var op: ?Op = null;
    var file: ?[]const u8 = null;
    var process: ?u32 = null;
    var service: ?[]const u8 = null;
    var args: Args = .{ .op = .get, .history = "", .process = 0, .service = "" };
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        const flag = arguments[index];
        if (index + 1 == arguments.len) return refuse(problem, "a flag has no value");
        if (repeated(arguments, index)) return refuse(problem, "a flag is given twice");
        const text = arguments[index + 1];
        if (eql(flag, "--op")) {
            op = std.meta.stringToEnum(Op, text) orelse return refuse(problem, "unknown --op");
        } else if (eql(flag, "--history")) {
            file = text;
        } else if (eql(flag, "--process")) {
            process = number(u32, text) orelse return refuse(problem, "bad --process");
        } else if (eql(flag, "--service")) {
            if (records.name_problem(text, constants.service_name_bytes_max) != null) {
                return refuse(problem, "--service is not a service name");
            }
            service = text;
        } else if (eql(flag, "--value")) {
            args.value = number(u32, text) orelse return refuse(problem, "bad --value");
        } else if (eql(flag, "--from")) {
            args.from = number(u64, text) orelse return refuse(problem, "bad --from");
        } else if (eql(flag, "--hold-ms")) {
            args.hold_ms = number(u32, text) orelse return refuse(problem, "bad --hold-ms");
            if (args.hold_ms > hold_ms_max) return refuse(problem, "--hold-ms is over 20000");
        } else if (eql(flag, "--image")) {
            if (!plain(text)) return refuse(problem, image_problem);
            args.image = text;
        } else if (eql(flag, "--server")) {
            args.server = text;
        } else if (eql(flag, "--ca")) {
            args.tls.ca = text;
        } else if (eql(flag, "--cert")) {
            args.tls.cert = text;
        } else if (eql(flag, "--key")) {
            args.tls.key = text;
        } else if (eql(flag, "--tls-name")) {
            args.tls.tls_name = text;
        } else {
            return refuse(problem, "unknown flag");
        }
    }
    args.op = op orelse return refuse(problem, "--op is required");
    args.history = file orelse return refuse(problem, "--history is required");
    args.process = process orelse return refuse(problem, "--process is required");
    args.service = service orelse return refuse(problem, "--service is required");
    try check_op_flags(args, problem);
    return args;
}

fn check_op_flags(args: Args, problem: *[]const u8) error{Usage}!void {
    if ((args.op == .apply) != (args.value != null)) {
        return refuse(problem, "--value goes with --op apply, and only with it");
    }
    if ((args.op == .watch) != (args.from != null)) {
        return refuse(problem, "--from goes with --op watch, and only with it");
    }
    if (args.from) |from| {
        if (from == 0) return refuse(problem, "--from starts at 1");
    }
}

/// The flag at `index` was given before it (the last would win, unseen).
fn repeated(arguments: []const []const u8, index: usize) bool {
    assert(index % 2 == 0);
    var earlier: usize = 0;
    while (earlier < index) : (earlier += 2) {
        if (eql(arguments[earlier], arguments[index])) return true;
    }
    return false;
}

/// Text that goes into the apply body's JSON string as it is: nothing to escape.
fn plain(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte == '"' or byte == '\\' or byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn refuse(problem: *[]const u8, sentence: []const u8) error{Usage} {
    problem.* = sentence;
    return error.Usage;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn number(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch null;
}

/// The invocation line, before the request is sent.
pub fn invocation(args: Args, time_ns: u64) Line {
    assert(args.service.len > 0);
    return .{
        .type = .invoke,
        .f = args.op,
        .process = args.process,
        .time_ns = time_ns,
        .service = args.service,
        .value = if (args.value) |count| .{ .count = count } else .nil,
        .from = args.from,
    };
}

const Request = struct { method: []const u8, path: []const u8, body: []const u8 };

fn request(arena: Allocator, args: Args) error{OutOfMemory}!Request {
    const name = args.service;
    return switch (args.op) {
        .apply => .{
            .method = "POST",
            .path = "/v1/apply",
            .body = try std.fmt.allocPrint(arena,
                \\{{"name":"{s}","image":"{s}","replicas":{d},"command":["sleep","1000000"],
            ++
                \\"applied_by":"jepsen"}}
            , .{ name, args.image, args.value.? }),
        },
        .get => .{
            .method = "GET",
            // The service's own key sorts first under its prefix: one key is enough.
            .path = try std.fmt.allocPrint(arena, "/v1/list?prefix=/services/{s}&limit=1", .{name}),
            .body = "",
        },
        .delete => .{
            .method = "DELETE",
            .path = try std.fmt.allocPrint(arena, "/v1/services/{s}?applied_by=jepsen", .{name}),
            .body = "",
        },
        .watch => .{
            .method = "GET",
            .path = try std.fmt.allocPrint(
                arena,
                "/v1/watch?prefix=/services/{s}&from={d}&timeout={d}",
                .{ name, args.from.?, args.hold_ms },
            ),
            .body = "",
        },
    };
}

fn writes(op: Op) bool {
    return switch (op) {
        .apply, .delete => true,
        .get, .watch => false,
    };
}

/// Sends the operation and returns its completion line, stamped with `time_ns` by the caller.
/// `invoke` is the line written before it; the completion repeats its value when it has no
/// other (a failure, a delete).
pub fn perform(env: *const Env, client: *Client, args: Args, invoke: Line) Line {
    assert(invoke.type == .invoke);
    var line = invoke;
    line.type = .fail;
    const wanted = request(env.arena, args) catch return local(line, "out of memory");
    var report: Report = undefined;
    report.reset();
    const reply = client.attempt(wanted.method, wanted.path, wanted.body, &report) catch {
        return no_reply(env.arena, client, &report, line);
    };
    line.status = reply.status;
    line.request_id = reply.request_id;
    if (reply.status >= 200 and reply.status < 300) return answered(env.arena, args, reply, line);
    return refused(env.arena, args.op, reply, line);
}

fn local(line: Line, why: []const u8) Line {
    var failed = line;
    failed.type = .fail;
    failed.@"error" = why;
    return failed;
}

/// No reply: a request that never reached a connection did not happen; one that did is unknown
/// when it writes, and a failed read either way. The verdict rests on `sent` alone, never on
/// which diagnostic (if any) the transport raised. The line keeps the id the request was sent
/// with, so the server's log can be searched for a write left open.
fn no_reply(arena: Allocator, client: *const Client, report: *const Report, line: Line) Line {
    var failed = line;
    failed.type = if (client.sent and writes(line.f)) .info else .fail;
    const id = report.request_id.slice();
    if (id.len > 0) failed.request_id = arena.dupe(u8, id) catch null;
    if (report.diag.code) |code| failed.code = codes.full_name(code);
    const cause = report.diag.last_cause() orelse "no reply";
    failed.@"error" = arena.dupe(u8, cause) catch "out of memory";
    return failed;
}

/// A non-2xx reply. A read that was refused saw nothing. A write was refused before it wrote
/// on a 4xx, and on a 503 with ZC-E0201 (the store could not be reached; a commit that may have
/// landed is ZC-E0213, src/store_faults.zig); any other answer (ZC-E0213, a 500, a 502) is
/// unknown.
fn refused(arena: Allocator, op: Op, reply: Reply, line: Line) Line {
    var failed = line;
    failed.type = .fail;
    const first = first_diagnostic(arena, reply.body);
    if (first) |diagnostic| {
        failed.code = diagnostic.code;
        failed.@"error" = diagnostic.cause;
    }
    if (!writes(op)) return failed;
    if (reply.status >= 400 and reply.status < 500) return failed;
    const store_down = reply.status == 503 and
        first != null and eql(first.?.code, codes.full_name(.E0201));
    if (!store_down) failed.type = .info;
    return failed;
}

const First = struct { code: []const u8, cause: ?[]const u8 };

fn first_diagnostic(arena: Allocator, body: []const u8) ?First {
    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const list = member(json, "diagnostics") orelse return null;
    if (list != .array or list.array.items.len == 0) return null;
    const first = list.array.items[0];
    const code = member(first, "code") orelse return null;
    if (code != .string) return null;
    var cause: ?[]const u8 = null;
    if (member(first, "causes")) |causes| {
        if (causes == .array and causes.array.items.len > 0) {
            const last = causes.array.items[causes.array.items.len - 1];
            if (last == .string) cause = last.string;
        }
    }
    return .{ .code = code.string, .cause = cause };
}

fn member(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

/// A 2xx reply. One the client cannot read is unknown for a write (it was answered, so it was
/// acted on, but the client cannot say how) and a failed read.
fn answered(arena: Allocator, args: Args, reply: Reply, line: Line) Line {
    var done = line;
    done.type = .ok;
    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, .{}) catch {
        return unreadable(done);
    };
    const shaped = switch (args.op) {
        .apply, .delete => read_write(&done, json),
        .get => read_get(&done, json, args.service),
        .watch => read_watch(arena, &done, json, args.service),
    };
    if (!shaped) return unreadable(done);
    assert(done.type == .ok);
    return done;
}

fn unreadable(line: Line) Line {
    var failed = line;
    failed.type = if (writes(line.f)) .info else .fail;
    failed.code = codes.full_name(.E0103);
    failed.@"error" = "the reply is not the JSON the API describes";
    return failed;
}

fn unsigned(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    if (present != .integer or present.integer < 0) return null;
    return @intCast(present.integer);
}

fn read_write(line: *Line, json: std.json.Value) bool {
    const action = member(json, "action") orelse return false;
    if (action != .string) return false;
    line.action = action.string;
    // `none` wrote nothing and names no revision.
    if (member(json, "revision")) |_| {
        line.revision = unsigned(member(json, "revision")) orelse return false;
    }
    return true;
}

fn read_get(line: *Line, json: std.json.Value, service: []const u8) bool {
    line.revision = unsigned(member(json, "revision")) orelse return false;
    line.value = .nil;
    const kvs = member(json, "kvs") orelse return false;
    if (kvs != .array) return false;
    for (kvs.array.items) |kv| {
        const key = member(kv, "key") orelse return false;
        if (key != .string) return false;
        if (!is_service_key(key.string, service)) continue;
        line.mod_revision = unsigned(member(kv, "mod_revision")) orelse return false;
        const value = member(kv, "value") orelse return false;
        const count = unsigned(member(value, "replicas")) orelse return false;
        line.value = .{ .count = std.math.cast(u32, count) orelse return false };
    }
    return true;
}

fn is_service_key(key: []const u8, service: []const u8) bool {
    const prefix = records.prefix_services;
    if (!std.mem.startsWith(u8, key, prefix)) return false;
    return eql(key[prefix.len..], service);
}

fn read_watch(arena: Allocator, line: *Line, json: std.json.Value, service: []const u8) bool {
    line.revision = unsigned(member(json, "revision")) orelse return false;
    const events = member(json, "events") orelse return false;
    if (events != .array) return false;
    var kept: std.ArrayList(history.Event) = .empty;
    for (events.array.items) |event| {
        const kind = member(event, "type") orelse return false;
        const kv = member(event, "kv") orelse return false;
        const key = member(kv, "key") orelse return false;
        if (kind != .string or key != .string) return false;
        if (!is_service_key(key.string, service)) continue;
        const put = eql(kind.string, "put");
        if (!put and !eql(kind.string, "delete")) return false;
        var replicas: ?u32 = null;
        if (put) {
            const count = unsigned(member(member(kv, "value") orelse return false, "replicas"));
            replicas = std.math.cast(u32, count orelse return false) orelse return false;
        }
        const mod_revision = unsigned(member(kv, "mod_revision")) orelse return false;
        const kept_event: history.Event = .{
            .put = put,
            .mod_revision = mod_revision,
            .replicas = replicas,
        };
        kept.append(arena, kept_event) catch return false;
    }
    line.value = .{ .events = kept.items };
    return true;
}

/// The process exit code for a completion.
pub fn exit_code(line: Line) u8 {
    return switch (line.type) {
        .ok => 0,
        .fail => 1,
        .info => 2,
        .invoke => unreachable, // A completion is never an invocation.
    };
}
