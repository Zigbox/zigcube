//! The command line's side of the API: one HTTP/1.1 request per connection, the reply read by its
//! `Content-Length`, bounded, and the connection closed by the command, first (see `read_reply`).
//! Written over a bare socket and not `std.http.Client` because the command needs the
//! `X-Request-Id` of every reply, a bounded read and a connect that fails fast, and the API is
//! plain HTTP on a private address.
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
        if (client.env.transport) |transport| {
            const raw = transport.exchange(transport.context, method, path, body);
            const text = raw orelse return unreachable_server(client, report, refused);
            return parse_reply(text, report, id);
        }
        const io = client.env.io;
        // std's connect does not implement a timeout yet (it panics when given one), so a host
        // that drops packets keeps the connect until the kernel gives up. docs/cli.md says so.
        var stream = client.address.connect(io, .{ .mode = .stream }) catch |err| {
            return unreachable_server(client, report, connect_reason(err));
        };
        defer stream.close(io);
        // A service file is cut at `service_file_bytes_max`, so its JSON is far under the limit.
        assert(body.len <= constants.api_request_bytes_max);
        var head: [head_bytes_max]u8 = undefined;
        const line: RequestLine = .{
            .method = method,
            .path = path,
            .host = client.server_text,
            .version = client.env.version,
            .request_id = id,
            .body_bytes = @intCast(body.len),
        };
        const request = request_head(&head, line) orelse return bad_path(report, path);
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(request) catch return lost(client, report, "sending the request");
        writer.interface.writeAll(body) catch return lost(client, report, "sending the request");
        writer.interface.flush() catch return lost(client, report, "sending the request");
        const raw = try read_reply(client, &stream, report);
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

/// Reads the reply, waiting at most `cli_reply_timeout_ms` for each piece of it, and at most
/// `cli_reply_bytes_max` bytes in all, and returns as soon as the reply is whole: the head and as
/// many body bytes as its `Content-Length` promises (the server always sends one). A reply with
/// none is read to the end of the connection. The command then closes the connection, so *it*
/// sends the first FIN: whoever does keeps the connection in TIME_WAIT on its port for a minute,
/// and a `zcube-server` that closed first could not be restarted on its port in that time
/// (docs/core.md, "Known limit: reuse_address"). So the request carries no `Connection: close`,
/// which would make the server close first.
/// It polls and reads the socket itself: a receive timeout on the socket makes the standard
/// library's reader panic ("programmer bug caused syscall error: AGAIN"), which would turn a
/// silent server into a bug report.
fn read_reply(client: *const Client, stream: *net.Stream, report: *Report) Error![]const u8 {
    const fd = stream.socket.handle;
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    const timeout_ms: i32 = @intCast(client.env.reply_timeout_ms);
    while (true) {
        var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&wait, timeout_ms) catch {
            return lost(client, report, "waiting for the reply");
        };
        if (ready == 0) return silent(client, report);
        const length = std.posix.read(fd, &chunk) catch {
            return lost(client, report, "reading the reply");
        };
        if (length == 0) return out.items;
        if (out.items.len + length > constants.cli_reply_bytes_max) return too_big(report);
        try out.appendSlice(client.env.arena, chunk[0..length]);
        if (reply_is_whole(out.items)) return out.items;
    }
}

/// True once `raw` holds a head that promises a `Content-Length` and that many bytes after it.
fn reply_is_whole(raw: []const u8) bool {
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse return false;
    var lines = std.mem.splitSequence(u8, raw[0..split], "\r\n");
    _ = lines.next(); // The status line.
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const promised = std.fmt.parseInt(usize, value, 10) catch return false;
        return raw.len - (split + 4) >= promised;
    }
    return false;
}

fn silent(client: *const Client, report: *Report) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0102);
    report.diag.while_("waiting for the reply of zcube-server", .{});
    report.diag.cause("zcube-server at {s} took the connection and sent nothing", .{
        client.server_text,
    });
    report.diag.cause("no reply within {d} ms", .{client.env.reply_timeout_ms});
    report.diag.context("server", "{s}", .{client.server_text});
    report.diag.context("reqid", "{s}", .{report.request_id.slice()});
    const sentence = "check that it is the server and that it is not stuck, then retry";
    report.diag.fix(.{ .sentence = sentence });
    return error.Failed;
}

const head_bytes_max = 2048;

const RequestLine = struct {
    method: []const u8,
    path: []const u8,
    host: []const u8,
    version: []const u8,
    request_id: []const u8,
    body_bytes: u32,
};

/// The request line and headers. A request with no body has no `Content-Length` and no
/// `Content-Type`: a `Content-Length: 0` on a GET crashes a release build of the server (it reads
/// the empty body through the standard library's `ending` reader, which sits in read-only
/// memory), and no header is the HTTP way to say "no body" anyway.
fn request_head(buffer: *[head_bytes_max]u8, line: RequestLine) ?[]const u8 {
    assert(line.path.len > 0);
    var writer = std.Io.Writer.fixed(buffer);
    const first = "{s} {s} HTTP/1.1\r\nHost: {s}\r\n";
    writer.print(first, .{ line.method, line.path, line.host }) catch return null;
    const second = "User-Agent: zcube/{s}\r\nAccept: application/json\r\n";
    writer.print(second, .{line.version}) catch return null;
    const third = "X-Request-Id: {s}\r\n";
    writer.print(third, .{line.request_id}) catch return null;
    if (line.body_bytes > 0) {
        writer.print("Content-Type: application/json\r\nContent-Length: {d}\r\n", .{
            line.body_bytes,
        }) catch return null;
    }
    writer.writeAll("\r\n") catch return null;
    return writer.buffered();
}

const refused = "connection refused: nothing is listening there";

fn connect_reason(err: net.IpAddress.ConnectError) []const u8 {
    return switch (err) {
        error.ConnectionRefused => refused,
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

test "a request without a body has no Content-Length, and one with a body has" {
    // Goal: the crash found with a release server (see request_head). Method: build the head of
    // a GET and of a POST and look for the headers; a path too long for the buffer is null.
    var buffer: [head_bytes_max]u8 = undefined;
    var line: RequestLine = .{
        .method = "GET",
        .path = "/v1/status",
        .host = "127.0.0.1:7070",
        .version = "0.0.0",
        .request_id = "zc-1",
        .body_bytes = 0,
    };
    const get = request_head(&buffer, line).?;
    try testing.expect(std.mem.indexOf(u8, get, "Content-Length") == null);
    try testing.expect(std.mem.indexOf(u8, get, "Content-Type") == null);
    const start = "GET /v1/status HTTP/1.1\r\nHost: 127.0.0.1:7070\r\n";
    try testing.expect(std.mem.startsWith(u8, get, start));
    try testing.expect(std.mem.endsWith(u8, get, "\r\n\r\n"));
    line.method = "POST";
    line.body_bytes = 42;
    const post = request_head(&buffer, line).?;
    try testing.expect(std.mem.indexOf(u8, post, "Content-Length: 42\r\n") != null);
    var long: [head_bytes_max]u8 = undefined;
    @memset(&long, 'a');
    line.path = &long;
    try testing.expect(request_head(&buffer, line) == null);
}
