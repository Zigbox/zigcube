//! zcube-jepsen-client's classification (docs/jepsen.md, "ok, fail and info") against a scripted
//! server: each case gives the raw HTTP reply (or none) and the completion line the client must
//! write, byte for byte. The encoder's own goldens are in `src/testdata/jepsen/`.

const std = @import("std");
const testing = std.testing;
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const history = @import("jepsen_history.zig");
const jepsen = @import("jepsen_client.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const linux = std.os.linux;
const net = std.Io.net;

/// Plays the server: answers every request with `raw` (null: the connection could not be made)
/// and keeps the last request it saw.
const Script = struct {
    raw: ?[]const u8,
    method: []const u8 = "",
    path: []const u8 = "",
    body: []const u8 = "",

    fn exchange(
        context: *anyopaque,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) ?[]const u8 {
        const script: *Script = @ptrCast(@alignCast(context));
        script.method = method;
        script.path = path;
        script.body = body;
        return script.raw;
    }
};

/// A raw reply with `status` and `body`, as `cli_http` reads it.
fn reply(arena: Allocator, status: u16, body: []const u8) []const u8 {
    return std.fmt.allocPrint(
        arena,
        "HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nX-Request-Id: zc-test-0001\r\n\r\n{s}",
        .{ status, body.len, body },
    ) catch unreachable; // The test arena has room.
}

const Case = struct {
    /// The arguments, without the program name and without `--history`.
    args: []const []const u8,
    /// The raw reply, or null for a connection that could not be made.
    raw: ?[]const u8,
    /// The completion line the client must write, newline included.
    expected: []const u8,
    /// The request the client must send: method and the start of its path.
    method: []const u8,
    path: []const u8,
};

/// Runs one case: parses the arguments, performs the operation over the script, encodes the
/// completion with a fixed time, and compares.
fn check(case: Case) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(arena, case.args);
    try arguments.appendSlice(arena, &.{ "--history", "unused.jsonl" });
    var problem: []const u8 = "";
    const args = try jepsen.parse(arguments.items, &problem);
    var script: Script = .{ .raw = case.raw };
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var stdout: Writer.Allocating = .init(arena);
    var stderr: Writer.Allocating = .init(arena);
    const env: cli_env.Env = .{
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
        .transport = .{ .context = &script, .exchange = Script.exchange },
    };
    var report: cli_report.Report = undefined;
    report.reset();
    var client: cli_http.Client = undefined;
    try client.init(&env, "127.0.0.1:1", .{}, &report);
    const invoke = jepsen.invocation(args, 100);
    var done = jepsen.perform(&env, &client, args, invoke);
    done.time_ns = 200;
    var text: Writer.Allocating = .init(arena);
    try history.write(done, &text.writer);
    // `expected` is one JSON line written over several source lines: its line breaks are
    // dropped (a history line holds none of its own), and the final one stands for the newline.
    const joined = try std.mem.replaceOwned(u8, arena, case.expected, "\n", "");
    const line = try std.mem.concat(arena, u8, &.{ joined, "\n" });
    try testing.expectEqualStrings(line, text.written());
    if (case.raw != null) {
        try testing.expectEqualStrings(case.method, script.method);
        try testing.expect(std.mem.startsWith(u8, script.path, case.path));
    }
}

test "an apply that the server answers is ok, with its revision and action" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "2", "--service", "r1", "--value", "3" },
        .raw = reply(arena, 200,
            \\{"request_id":"zc-test-0001","dry_run":false,"action":"create","name":"r1",
            \\"generation":1,"change":"created","revision":7,"decision":"d"}
        ),
        .expected =
        \\{"type":"ok","f":"apply","process":2,"time":200,"service":"r1","value":3,"revision":7,
        \\"action":"create","status":200,"request_id":"zc-test-0001"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply answered ZC-E0213 is info: the commit may have landed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "2", "--service", "r1", "--value", "3" },
        .raw = reply(arena, 503,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0213",
            \\"causes":["the connection was lost during COMMIT"]}]}
        ),
        .expected =
        \\{"type":"info","f":"apply","process":2,"time":200,"service":"r1","value":3,"status":503,
        \\"code":"ZC-E0213","request_id":"zc-test-0001",
        \\"error":"the connection was lost during COMMIT"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply refused 409 is fail: nothing was written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = reply(arena, 409,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0105",
            \\"causes":["the service changed"]}]}
        ),
        .expected =
        \\{"type":"fail","f":"apply","process":1,"time":200,"service":"r1","value":4,"status":409,
        \\"code":"ZC-E0105","request_id":"zc-test-0001","error":"the service changed"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply answered 503 ZC-E0201 is fail: the store was never reached" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = reply(arena, 503,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0201",
            \\"causes":["connection refused"]}]}
        ),
        .expected =
        \\{"type":"fail","f":"apply","process":1,"time":200,"service":"r1","value":4,"status":503,
        \\"code":"ZC-E0201","request_id":"zc-test-0001","error":"connection refused"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply answered 500 is info" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = reply(arena, 500,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-B0001",
            \\"causes":["panic"]}]}
        ),
        .expected =
        \\{"type":"info","f":"apply","process":1,"time":200,"service":"r1","value":4,"status":500,
        \\"code":"ZC-B0001","request_id":"zc-test-0001","error":"panic"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply with no connection is fail: nothing was sent" {
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = null,
        .expected =
        \\{"type":"fail","f":"apply","process":1,"time":200,"service":"r1","value":4,
        \\"code":"ZC-E0102","request_id":"zc-test-0001",
        \\"error":"connection refused: nothing is listening there"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply whose 200 is not JSON is info" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = reply(arena, 200,
            \\not json
        ),
        .expected =
        \\{"type":"info","f":"apply","process":1,"time":200,"service":"r1","value":4,"status":200,
        \\"code":"ZC-E0103","request_id":"zc-test-0001",
        \\"error":"the reply is not the JSON the API describes"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "an apply that changed nothing is ok without a revision" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "apply", "--process", "1", "--service", "r1", "--value", "4" },
        .raw = reply(arena, 200,
            \\{"request_id":"zc-test-0001","dry_run":false,"action":"none","name":"r1",
            \\"generation":1,"change":"none"}
        ),
        .expected =
        \\{"type":"ok","f":"apply","process":1,"time":200,"service":"r1","value":4,"action":"none",
        \\"status":200,"request_id":"zc-test-0001"}
        ,
        .method = "POST",
        .path = "/v1/apply",
    });
}

test "a get of an existing service reads its count and mod_revision" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "get", "--process", "3", "--service", "r1" },
        .raw = reply(arena, 200,
            \\{"revision":12,"kvs":[{"key":"/services/r1","value":{"name":"r1","replicas":5},
            \\"create_revision":2,"mod_revision":9,"lease":0}],"continue":null}
        ),
        .expected =
        \\{"type":"ok","f":"get","process":3,"time":200,"service":"r1","value":5,"revision":12,
        \\"mod_revision":9,"status":200,"request_id":"zc-test-0001"}
        ,
        .method = "GET",
        .path = "/v1/list?prefix=/services/r1",
    });
}

test "a get that finds only a longer name reads null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "get", "--process", "3", "--service", "r1" },
        .raw = reply(arena, 200,
            \\{"revision":12,"kvs":[{"key":"/services/r10","value":{"name":"r10","replicas":5},
            \\"create_revision":2,"mod_revision":9,"lease":0}],"continue":null}
        ),
        .expected =
        \\{"type":"ok","f":"get","process":3,"time":200,"service":"r1","value":null,"revision":12,
        \\"status":200,"request_id":"zc-test-0001"}
        ,
        .method = "GET",
        .path = "/v1/list?prefix=/services/r1",
    });
}

test "a get answered 503 is fail: a read changes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "get", "--process", "3", "--service", "r1" },
        .raw = reply(arena, 503,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0213","causes":["lost"]}]}
        ),
        .expected =
        \\{"type":"fail","f":"get","process":3,"time":200,"service":"r1","value":null,"status":503,
        \\"code":"ZC-E0213","request_id":"zc-test-0001","error":"lost"}
        ,
        .method = "GET",
        .path = "/v1/list",
    });
}

test "a get whose 200 is not JSON is fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "get", "--process", "3", "--service", "r1" },
        .raw = reply(arena, 200,
            \\[]
        ),
        .expected =
        \\{"type":"fail","f":"get","process":3,"time":200,"service":"r1","value":null,"status":200,
        \\"code":"ZC-E0103","request_id":"zc-test-0001",
        \\"error":"the reply is not the JSON the API describes"}
        ,
        .method = "GET",
        .path = "/v1/list",
    });
}

test "a delete of a missing service is fail with ZC-E0101" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "delete", "--process", "4", "--service", "r1" },
        .raw = reply(arena, 404,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0101",
            \\"causes":["service r1 does not exist"]}]}
        ),
        .expected =
        \\{"type":"fail","f":"delete","process":4,"time":200,"service":"r1","value":null,
        \\"status":404,"code":"ZC-E0101","request_id":"zc-test-0001",
        \\"error":"service r1 does not exist"}
        ,
        .method = "DELETE",
        .path = "/v1/services/r1",
    });
}

test "a delete answered ZC-E0213 is info" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{ "--op", "delete", "--process", "4", "--service", "r1" },
        .raw = reply(arena, 503,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0213","causes":["lost"]}]}
        ),
        .expected =
        \\{"type":"info","f":"delete","process":4,"time":200,"service":"r1","value":null,
        \\"status":503,"code":"ZC-E0213","request_id":"zc-test-0001","error":"lost"}
        ,
        .method = "DELETE",
        .path = "/v1/services/r1",
    });
}

test "a watch keeps its service's events and drops others" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{
            "--op",   "watch", "--process", "5", "--service", "r1",
            "--from", "3",     "--hold-ms", "0",
        },
        .raw = reply(arena, 200,
            \\{"revision":9,"events":[{"type":"put","kv":{"key":"/services/r1",
            \\"value":{"replicas":2},"mod_revision":4,"create_revision":4,"lease":0}},
            \\{"type":"put","kv":{"key":"/services/r10","value":{"replicas":7},
            \\"mod_revision":5,"create_revision":5,"lease":0}},{"type":"delete",
            \\"kv":{"key":"/services/r1","value":null,"mod_revision":8,
            \\"create_revision":0,"lease":0}}]}
        ),
        .expected =
        \\{"type":"ok","f":"watch","process":5,"time":200,"service":"r1","value":[{"type":"put",
        \\"mod_revision":4,"replicas":2},{"type":"delete","mod_revision":8,"replicas":null}],
        \\"from":3,"revision":9,"status":200,"request_id":"zc-test-0001"}
        ,
        .method = "GET",
        .path = "/v1/watch?prefix=/services/r1&from=3&timeout=0",
    });
}

test "a watch answered 410 is fail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try check(.{
        .args = &.{
            "--op",   "watch", "--process", "5", "--service", "r1",
            "--from", "3",     "--hold-ms", "0",
        },
        .raw = reply(arena, 410,
            \\{"request_id":"zc-test-0001","diagnostics":[{"code":"ZC-E0203",
            \\"causes":["compacted"]}]}
        ),
        .expected =
        \\{"type":"fail","f":"watch","process":5,"time":200,"service":"r1","value":null,"from":3,
        \\"status":410,"code":"ZC-E0203","request_id":"zc-test-0001","error":"compacted"}
        ,
        .method = "GET",
        .path = "/v1/watch",
    });
}

test "parse refuses bad arguments" {
    const cases = [_]struct { args: []const []const u8, problem: []const u8 }{
        .{
            .args = &.{ "--op", "apply", "--history", "h", "--process", "1", "--service", "r1" },
            .problem = "--value goes with --op apply, and only with it",
        },
        .{
            .args = &.{
                "--op",      "get", "--history", "h", "--process", "1",
                "--service", "r1",  "--value",   "3",
            },
            .problem = "--value goes with --op apply, and only with it",
        },
        .{
            .args = &.{ "--op", "watch", "--history", "h", "--process", "1", "--service", "r1" },
            .problem = "--from goes with --op watch, and only with it",
        },
        .{
            .args = &.{
                "--op",      "watch", "--history", "h", "--process", "1",
                "--service", "r1",    "--from",    "0",
            },
            .problem = "--from starts at 1",
        },
        .{
            .args = &.{ "--op", "get", "--history", "h", "--process", "1", "--service", "R1" },
            .problem = "--service is not a service name",
        },
        .{
            .args = &.{ "--op", "get", "--history", "h", "--process", "1" },
            .problem = "--service is required",
        },
        .{
            .args = &.{ "--op", "nope", "--history", "h", "--process", "1", "--service", "r1" },
            .problem = "unknown --op",
        },
        .{
            .args = &.{
                "--op",      "get", "--history", "h",     "--process", "1",
                "--service", "r1",  "--hold-ms", "20001",
            },
            .problem = "--hold-ms is over 20000",
        },
        .{
            .args = &.{
                "--op",      "get", "--history", "h", "--process", "1",
                "--service", "r1",  "--bogus",   "1",
            },
            .problem = "unknown flag",
        },
        .{
            .args = &.{ "--op", "get", "--history", "h", "--process" },
            .problem = "a flag has no value",
        },
    };
    for (cases) |case| {
        var problem: []const u8 = "";
        try testing.expectError(error.Usage, jepsen.parse(case.args, &problem));
        try testing.expectEqualStrings(case.problem, problem);
    }
}

test "parse refuses a repeated flag and an image a JSON string cannot hold as given" {
    const cases = [_]struct { args: []const []const u8, problem: []const u8 }{
        .{
            .args = &.{
                "--op",      "apply", "--history", "h",      "--process", "1",
                "--service", "r1",    "--op",      "delete",
            },
            .problem = "a flag is given twice",
        },
        .{
            .args = &.{
                "--op",      "apply", "--history", "h", "--process", "1",
                "--service", "r1",    "--value",   "3", "--image",   "a\"b",
            },
            .problem = "--image is empty or holds a quote, a backslash or a control character",
        },
    };
    for (cases) |case| {
        var problem: []const u8 = "";
        try testing.expectError(error.Usage, jepsen.parse(case.args, &problem));
        try testing.expectEqualStrings(case.problem, problem);
    }
}

// ---- Over a real socket ----------------------------------------------------------------------
// The script cannot say "sent, then cut": these cases run `perform` over `cli_http`'s own socket
// path, so `Client.sent` is the real one (review of PR 276: dropping it went unseen).

/// Performs `arguments` against `address` over a real socket and returns the completion.
fn over_socket(arena: Allocator, arguments: []const []const u8, address: []const u8) !history.Line {
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, arguments);
    try all.appendSlice(arena, &.{ "--history", "unused.jsonl" });
    var problem: []const u8 = "";
    const args = try jepsen.parse(all.items, &problem);
    const environ = try arena.create(std.process.Environ.Map);
    environ.* = .init(arena);
    const stdout = try arena.create(Writer.Allocating);
    stdout.* = .init(arena);
    const stderr = try arena.create(Writer.Allocating);
    stderr.* = .init(arena);
    const env = try arena.create(cli_env.Env);
    env.* = .{
        .io = testing.io,
        .arena = arena,
        .environ = environ,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .deterministic_ids = true,
        .reply_timeout_ms = 200,
    };
    var report: cli_report.Report = undefined;
    report.reset();
    const client = try arena.create(cli_http.Client);
    try client.init(env, address, .{}, &report);
    return jepsen.perform(env, client, args, jepsen.invocation(args, 100));
}

fn expect_line(line: history.Line, kind: history.Type, code: []const u8) !void {
    try testing.expectEqual(kind, line.type);
    try testing.expectEqualStrings(code, line.code.?);
    try testing.expectEqualStrings("zc-test-0001", line.request_id.?);
    try testing.expect(line.status == null);
}

const apply_args: []const []const u8 = &.{
    "--op", "apply", "--process", "1", "--service", "r1", "--value", "3",
};
const delete_args: []const []const u8 = &.{ "--op", "delete", "--process", "1", "--service", "r1" };
const get_args: []const []const u8 = &.{ "--op", "get", "--process", "1", "--service", "r1" };
const watch_args: []const []const u8 = &.{
    "--op", "watch", "--process", "1", "--service", "r1", "--from", "1", "--hold-ms", "100",
};

test "socket: sent, then no reply within the timeout, is info for a write and fail for a read" {
    // A listener that never accepts: the connect completes in its backlog and the request is
    // written, then no byte comes back (ZC-E0102, "no reply within 200 ms").
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    defer listener.deinit(testing.io);
    const address = try std.fmt.allocPrint(arena, "{f}", .{listener.socket.address});
    try expect_line(try over_socket(arena, apply_args, address), .info, "ZC-E0102");
    try expect_line(try over_socket(arena, delete_args, address), .info, "ZC-E0102");
    try expect_line(try over_socket(arena, get_args, address), .fail, "ZC-E0102");
    try expect_line(try over_socket(arena, watch_args, address), .fail, "ZC-E0102");
}

/// Accepts one connection, reads what the client sent, and closes it without a reply.
fn accept_read_close(listener: *net.Server) void {
    var stream = listener.accept(testing.io) catch return;
    defer stream.close(testing.io);
    var buffer: [4096]u8 = undefined;
    _ = linux.read(stream.socket.handle, &buffer, buffer.len);
}

test "socket: a server that reads the request and closes is info for a write, fail for a read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    defer listener.deinit(testing.io);
    const address = try std.fmt.allocPrint(arena, "{f}", .{listener.socket.address});
    const cases = [_]struct { args: []const []const u8, kind: history.Type }{
        .{ .args = apply_args, .kind = .info },
        .{ .args = delete_args, .kind = .info },
        .{ .args = get_args, .kind = .fail },
        .{ .args = watch_args, .kind = .fail },
    };
    for (cases) |case| {
        const server = try std.Thread.spawn(.{}, accept_read_close, .{&listener});
        const line = over_socket(arena, case.args, address);
        server.join();
        try expect_line(try line, case.kind, "ZC-E0103");
    }
}

test "socket: a refused connection is fail for every operation: nothing was sent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    const address = try std.fmt.allocPrint(arena, "{f}", .{listener.socket.address});
    listener.deinit(testing.io);
    for ([_][]const []const u8{ apply_args, delete_args, get_args, watch_args }) |args| {
        try expect_line(try over_socket(arena, args, address), .fail, "ZC-E0102");
    }
}
