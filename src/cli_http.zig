//! The command line's side of the API: one HTTP/1.1 request per connection (`Connection: close`),
//! read to the end, bounded. Written over a bare socket and not `std.http.Client` because the
//! command needs the `X-Request-Id` of every reply, a bounded read and a connect that fails fast,
//! and the API is plain HTTP on a private address.
//!
//! Every way a request can fail below HTTP is `ZC-E0102` with the system's reason in words (never
//! an error name), every reply the client can't read is `ZC-E0103`, and a non-2xx reply carries
//! the server's own diagnostics, which are relayed to the report unchanged.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const zigbox = @import("zigbox");
const cli_env = @import("cli_env.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const text_util = @import("text.zig");

const Allocator = std.mem.Allocator;
const Env = cli_env.Env;
const Report = cli_report.Report;
const Error = cli_report.Error;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

pub const Reply = struct { status: u16, request_id: []const u8, body: []const u8 };

/// One request made, for `--verbose`.
pub const Trace = struct { id: cli_report.RequestId, line: text_util.Bounded(160), status: u16 };

const traces_max = 64;

pub const Client = struct {
    env: *const Env,
    address: net.IpAddress,
    /// The address as the user gave it (or the default), for messages.
    server_text: []const u8,
    traces: [traces_max]Trace,
    trace_count: u32,
    /// Requests past `traces_max`, not recorded.
    trace_dropped: u32,
    counter: u32,

    /// Initialises in place. The address comes from `--server`, then `ZCUBE_SERVER`, then the
    /// default; one that is not `HOST:PORT` is ZC-E0112.
    pub fn init(client: *Client, env: *const Env, flag: ?[]const u8, report: *Report) Error!void {
        const text = flag orelse env.getenv("ZCUBE_SERVER") orelse constants.cli_server_default;
        const source = if (flag != null) "--server" else if (env.getenv("ZCUBE_SERVER") != null)
            "ZCUBE_SERVER"
        else
            "the default";
        const address = parse_server(text) orelse return bad_server(report, text, source);
        client.* = .{
            .env = env,
            .address = address,
            .server_text = text,
            .traces = undefined,
            .trace_count = 0,
            .trace_dropped = 0,
            .counter = 0,
        };
        assert(client.address.getPort() != 0);
    }

    pub fn get(client: *Client, path: []const u8, report: *Report) Error!Reply {
        return client.send("GET", path, "", report);
    }

    /// One request. A non-2xx reply is relayed to `report` and is `error.Failed`.
    pub fn send(
        client: *Client,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        report: *Report,
    ) Error!Reply {
        assert(path.len > 0);
        assert(path[0] == '/');
        var id: cli_report.RequestId = .{};
        client.next_id(&id);
        report.request_id = id;
        const reply = try client.exchange(method, path, body, id.slice(), report);
        client.record(reply.request_id, method, path, reply.status);
        if (reply.status >= 200 and reply.status < 300) return reply;
        try relay_failure_body(client.env.arena, reply, report);
        return error.Failed;
    }

    /// The text of the request lines that `--verbose` shows after a command.
    pub fn trace_lines(client: *const Client) []const Trace {
        return client.traces[0..client.trace_count];
    }

    fn next_id(client: *Client, id: *cli_report.RequestId) void {
        client.counter += 1;
        if (client.env.deterministic_ids) {
            id.print("zc-test-{d:0>4}", .{client.counter});
            return;
        }
        var random: [4]u8 = undefined;
        client.env.io.random(&random);
        const ms = client.env.now_ms();
        id.print(
            "zc-{x}-{x:0>8}-{d}",
            .{ ms, std.mem.readInt(u32, &random, .little), client.counter },
        );
        assert(id.len >= constants.request_id_bytes_min);
        assert(id.len <= constants.request_id_bytes_max);
    }

    fn record(
        client: *Client,
        id: []const u8,
        method: []const u8,
        path: []const u8,
        status: u16,
    ) void {
        if (client.trace_count == traces_max) {
            client.trace_dropped += 1;
            return;
        }
        const trace = &client.traces[client.trace_count];
        trace.id = .{};
        trace.id.print("{s}", .{id});
        trace.line = .{};
        trace.line.print("{s} {s}", .{ method, path });
        trace.status = status;
        client.trace_count += 1;
    }

    fn exchange(
        client: *Client,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        id: []const u8,
        report: *Report,
    ) Error!Reply {
        const io = client.env.io;
        // std's connect does not implement a timeout yet (it panics when given one), so a host
        // that drops packets keeps the connect until the kernel gives up. docs/cli.md says so.
        var stream = client.address.connect(io, .{ .mode = .stream }) catch |err| {
            return unreachable_server(client, report, connect_reason(err));
        };
        defer stream.close(io);
        set_reply_timeout(&stream);
        var head: [2048]u8 = undefined;
        const request = std.fmt.bufPrint(&head, "{s} {s} HTTP/1.1\r\nHost: {s}\r\n" ++
            "User-Agent: zcube/{s}\r\nAccept: application/json\r\nX-Request-Id: {s}\r\n" ++
            "Connection: close\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{
            method, path, client.server_text, client.env.version, id, body.len,
        }) catch return bad_path(report, path);
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(request) catch return lost(client, report, "sending the request");
        writer.interface.writeAll(body) catch return lost(client, report, "sending the request");
        writer.interface.flush() catch return lost(client, report, "sending the request");
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const limit: std.Io.Limit = .limited(constants.cli_reply_bytes_max);
        const raw = reader.interface.allocRemaining(
            client.env.arena,
            limit,
        ) catch |err| switch (err) {
            error.OutOfMemory => return too_big(report),
            error.StreamTooLong => return too_big(report),
            error.ReadFailed => return lost(client, report, "reading the reply"),
        };
        return parse_reply(raw, report, id);
    }
};

/// `HOST:PORT` with an IP address (or `localhost`) and a port that is not 0.
pub fn parse_server(text: []const u8) ?net.IpAddress {
    if (text.len == 0 or text.len > constants.listen_bytes_max) return null;
    const local = "localhost:";
    var storage: [constants.listen_bytes_max]u8 = undefined;
    var subject = text;
    if (std.mem.startsWith(u8, text, local)) {
        subject = std.fmt.bufPrint(
            &storage,
            "127.0.0.1:{s}",
            .{text[local.len..]},
        ) catch return null;
    }
    const address = net.IpAddress.parseLiteral(subject) catch return null;
    if (address.getPort() == 0) return null;
    return address;
}

/// A reply that never comes must not hang the command: reads give up after the reply timeout.
fn set_reply_timeout(stream: *net.Stream) void {
    const seconds = constants.cli_reply_timeout_ms / 1000;
    const timeout: std.posix.timeval = .{ .sec = seconds, .usec = 0 };
    // Best effort: a platform without the option keeps the blocking read.
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
}

fn connect_reason(err: net.IpAddress.ConnectError) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "connection refused: nothing is listening there",
        error.Timeout => "no answer within the connect timeout",
        error.HostUnreachable => "no route to that host",
        error.NetworkUnreachable, error.NetworkDown => "the network is unreachable",
        error.AccessDenied => "the system refused the connection",
        error.ConnectionResetByPeer => "the connection was reset",
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        => "that address can't be used from this machine",
        else => "the system could not open a connection",
    };
}

fn unreachable_server(client: *const Client, report: *Report, reason: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0102);
    report.diag.while_("sending a request to zcube-server", .{});
    report.diag.cause("no answer from zcube-server at {s}", .{client.server_text});
    report.diag.cause("{s}", .{reason});
    report.diag.context("server", "{s}", .{client.server_text});
    report.diag.context("reqid", "{s}", .{report.request_id.slice()});
    report.diag.fix(.{
        .sentence = "start it:",
        .command = "zcube-server --store sqlite:zcube.db --create-store",
    });
    report.diag.fix(.{
        .sentence = "or name the one that is running:",
        .command = "zcube --server HOST:PORT get service",
    });
    return error.Failed;
}

fn lost(client: *const Client, report: *Report, doing: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0102);
    report.diag.while_("{s}", .{doing});
    report.diag.cause("the connection to zcube-server was lost or timed out", .{});
    report.diag.context("server", "{s}", .{client.server_text});
    report.diag.context("reqid", "{s}", .{report.request_id.slice()});
    report.diag.fix(
        .{ .sentence = "check that the server is running and retry, or use another with --server" },
    );
    return error.Failed;
}

fn bad_server(report: *Report, text: []const u8, source: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0112);
    report.diag.while_("reading the server address", .{});
    report.diag.cause("{s} is not HOST:PORT with an IP address (or localhost) and a port", .{text});
    report.diag.context("from", "{s}", .{source});
    report.diag.fix(.{
        .sentence = "write it like this:",
        .command = "zcube --server 127.0.0.1:7070 get service",
    });
    return error.Failed;
}

fn bad_path(report: *Report, path: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0104);
    report.diag.while_("building the request", .{});
    report.diag.cause("the request path is over {d} bytes", .{@as(u32, 1024)});
    report.diag.context("path", "{s}", .{path[0..@min(path.len, 40)]});
    report.diag.fix(.{ .sentence = "use a shorter name" });
    return error.Failed;
}

fn too_big(report: *Report) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("reading the reply", .{});
    report.diag.cause(
        "the reply is larger than the {d} bytes zcube reads",
        .{constants.cli_reply_bytes_max},
    );
    report.diag.context("reqid", "{s}", .{report.request_id.slice()});
    report.diag.fix(.{ .sentence = "ask for less, for example one service by name" });
    return error.Failed;
}

fn unreadable(report: *Report, why: []const u8, id: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("reading the reply", .{});
    report.diag.cause("{s}", .{why});
    report.diag.context("reqid", "{s}", .{id});
    report.diag.fix(
        .{ .sentence = "use the zcube that came with the server, or upgrade the older one" },
    );
    return error.Failed;
}

/// Splits a reply into status, request id and body.
fn parse_reply(raw: []const u8, report: *Report, sent_id: []const u8) Error!Reply {
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse
        return unreadable(report, "the reply has no end of headers", sent_id);
    const head = raw[0..split];
    const line_end = std.mem.find(u8, head, "\r\n") orelse head.len;
    const status_line = head[0..line_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.") or status_line.len < 12) {
        return unreadable(report, "the reply is not HTTP", sent_id);
    }
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch
        return unreadable(report, "the reply's status is not a number", sent_id);
    var request_id: []const u8 = sent_id;
    var length: ?usize = null;
    var lines = std.mem.splitSequence(u8, head[line_end..], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(name, "x-request-id")) request_id = value;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            length = std.fmt.parseInt(usize, value, 10) catch
                return unreadable(report, "the reply's length is not a number", sent_id);
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return unreadable(report, "the reply is chunked, which zcube does not read", sent_id);
        }
    }
    const rest = raw[split + 4 ..];
    if (length) |promised| {
        if (rest.len < promised) return unreadable(report, "the reply ended early", sent_id);
        return .{ .status = status, .request_id = request_id, .body = rest[0..promised] };
    }
    return .{ .status = status, .request_id = request_id, .body = rest };
}

/// Relays the diagnostics of a failed reply. A reply that is not the error body of docs/api.md
/// is ZC-E0103, not a guess.
fn relay_failure_body(arena: Allocator, reply: Reply, report: *Report) Error!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, .{}) catch
        return not_a_diagnostic(report, reply);
    if (parsed != .object) return not_a_diagnostic(report, reply);
    const list = parsed.object.get("diagnostics") orelse return not_a_diagnostic(report, reply);
    if (list != .array or list.array.items.len == 0) return not_a_diagnostic(report, reply);
    for (list.array.items) |item| {
        const text = std.json.Stringify.valueAlloc(
            arena,
            item,
            .{},
        ) catch return not_a_diagnostic(report, reply);
        var diagnostic: Diagnostic = undefined;
        zigbox.diagnostic.parse_json(
            &diagnostic,
            text,
        ) catch return not_a_diagnostic(report, reply);
        set_docs(&diagnostic);
        // The id the server answered with is the one to quote: it may have replaced ours.
        add_request_id(&diagnostic, reply.request_id);
        report.relay(&diagnostic);
    }
    report.request_id = .{};
    report.request_id.print("{s}", .{reply.request_id});
}

pub fn set_docs(diagnostic: *Diagnostic) void {
    const code = diagnostic.code.slice();
    if (std.mem.startsWith(u8, code, "ZBX-")) diagnostic.set_docs(&zigbox.product.Product.zbx);
    if (std.mem.startsWith(u8, code, "ZC-")) diagnostic.set_docs(&diag_mod.product);
}

/// Adds the request id as the `reqid` context of a relayed diagnostic, unless it has one.
fn add_request_id(diagnostic: *Diagnostic, id: []const u8) void {
    for (diagnostic.pairs.slice()) |*pair| {
        if (std.mem.eql(u8, pair.key_slice(), "reqid")) return;
    }
    if (diagnostic.pairs.count == diagnostic.pairs.items.len) return;
    const slot = &diagnostic.pairs.items[diagnostic.pairs.count];
    slot.key = @splat(0);
    @memcpy(slot.key[0.."reqid".len], "reqid");
    slot.key_len = "reqid".len;
    slot.value = .{};
    slot.value.print("{s}", .{id});
    diagnostic.pairs.count += 1;
}

fn not_a_diagnostic(report: *Report, reply: Reply) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("reading the server's answer to a failed request", .{});
    report.diag.cause("HTTP status {d} with a body that is not a diagnostic", .{reply.status});
    report.diag.context("status", "{d}", .{reply.status});
    report.diag.context("reqid", "{s}", .{reply.request_id});
    report.diag.fix(
        .{ .sentence = "check that --server names zcube-server and not another service" },
    );
    return error.Failed;
}

const testing = std.testing;

test "server addresses: an IP and a port, or localhost and a port" {
    // Goal: the boundary of --server and ZCUBE_SERVER. Method: good forms, then near misses.
    try testing.expect(parse_server("127.0.0.1:7070") != null);
    try testing.expect(parse_server("localhost:7070") != null);
    try testing.expectEqual(@as(u16, 9), parse_server("localhost:9").?.getPort());
    try testing.expect(parse_server("[::1]:7070") != null);
    try testing.expect(parse_server("") == null);
    try testing.expect(parse_server("127.0.0.1") == null);
    try testing.expect(parse_server("127.0.0.1:0") == null);
    try testing.expect(parse_server("127.0.0.1:99999") == null);
    try testing.expect(parse_server("example.com:7070") == null);
    try testing.expect(parse_server("localhost:") == null);
}

test "a reply is split into status, request id and exactly its promised body" {
    // Goal: the parser of the one reply shape the server sends. Method: a good reply with extra
    // trailing bytes, then each malformed form; none is a crash and each is ZC-E0103.
    var report: Report = undefined;
    report.reset();
    const good = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Request-Id: r-1234567\r\n" ++
        "\r\n{}trailing";
    const reply = try parse_reply(good, &report, "zc-1");
    try testing.expectEqual(@as(u16, 200), reply.status);
    try testing.expectEqualStrings("r-1234567", reply.request_id);
    try testing.expectEqualStrings("{}", reply.body);
    const bad = [_][]const u8{
        "",
        "HTTP/1.1 200 OK\r\nno end",
        "SPDY/9 200 OK\r\n\r\n",
        "HTTP/1.1 2x0 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort",
        "HTTP/1.1 200 OK\r\nContent-Length: nine\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    };
    for (bad) |text| {
        report.reset();
        try testing.expectError(error.Failed, parse_reply(text, &report, "zc-1"));
        try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0103), report.diag.code);
    }
}
