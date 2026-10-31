//! The agent's HTTP/1.1 client: one request per connection, the whole reply read into the
//! caller's arena. Shell code: sockets. It is small on purpose. The agent talks to
//! one server, a few times a second, and a connection per request costs nothing at that rate and
//! cannot go stale; the server's keep-alive and its limits are for the console and the CLI.
//!
//! A connection serves one request and the agent closes it first (see `parse_head`).
//!
//! Everything is bounded: a reply is read for at most the request's own wait plus
//! `agent_io_timeout_ms` (a `poll` before each read, so a server that accepts and then says nothing
//! cannot stop the agent), and a reply is at most `agent_response_bytes_max`. Connecting is
//! bounded by the kernel only (see `connect`). A failure is ZC-E0503 (the server did not answer) or
//! ZC-E0504 (it answered something the agent cannot use), never a Zig error name.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

const client_mod = @import("agent_client.zig");

pub const Error = client_mod.Error;
pub const Request = client_mod.Request;
pub const Reply = client_mod.Reply;

pub const Client = struct {
    io: std.Io,
    address: net.IpAddress,
    /// How long a read waits for the next piece of a reply, on top of the request's own hold.
    io_timeout_ms: u32 = constants.agent_io_timeout_ms,

    /// Sends the request and returns the reply, whatever its status. `Unreachable` and `BadReply`
    /// leave a diagnostic in `diag`.
    pub fn call(
        client: *const Client,
        arena: Allocator,
        request: Request,
        diag: *Diag,
    ) Error!Reply {
        assert(diag.code == null);
        assert(request.target.len > 0);
        assert(request.target[0] == '/');
        if (request.body.len > constants.agent_request_bytes_max) {
            return bad_reply(diag, "the request the agent built is larger than the server accepts");
        }
        var stream = client.connect(diag) catch |err| return err;
        defer stream.close(client.io);
        try client.send(&stream, request, diag);
        return client.receive(arena, &stream, request.hold_ms + client.io_timeout_ms, diag);
    }

    /// The standard library's threaded `Io` does not implement a connect timeout on POSIX (it
    /// panics), and a socket's timeout can only be set once the socket exists, so a connect to a
    /// host that drops packets waits as long as the kernel does (about two minutes). A server
    /// that is down answers with a refusal at once, which is the case that matters on one
    /// network (docs/agent.md).
    fn connect(client: *const Client, diag: *Diag) Error!net.Stream {
        return client.address.connect(client.io, .{ .mode = .stream }) catch |err| {
            const reason: []const u8 = switch (err) {
                error.ConnectionRefused => "the connection was refused",
                error.Timeout => "it did not answer in time",
                error.NetworkUnreachable, error.HostUnreachable => "the network has no route to it",
                else => "the connection could not be made",
            };
            return unreachable_server(diag, client, reason);
        };
    }

    fn send(client: *const Client, stream: *net.Stream, request: Request, diag: *Diag) Error!void {
        var buffer: [4096]u8 = undefined;
        var writer = stream.writer(client.io, &buffer);
        const head = "{s} {s} HTTP/1.1\r\nHost: {f}\r\n" ++
            "Accept: application/json\r\nContent-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n\r\n";
        writer.interface.print(head, .{
            request.method, request.target, client.address, request.body.len,
        }) catch return unreachable_server(diag, client, "the request could not be sent");
        writer.interface.writeAll(request.body) catch
            return unreachable_server(diag, client, "the request could not be sent");
        writer.interface.flush() catch
            return unreachable_server(diag, client, "the request could not be sent");
    }

    /// The reply, head and body, read with `poll` so that a server that goes quiet ends the wait
    /// with an error of ours. A receive timeout on the socket would end it inside the standard
    /// library's reader, which panics when the timeout fires ("programmer bug caused syscall
    /// error: AGAIN"): the agent then crashed with ZC-B0001 whenever the server held a request
    /// for longer than the timeout, which a store outage does (found by demo-c0).
    fn receive(
        client: *const Client,
        arena: Allocator,
        stream: *net.Stream,
        wait_ms: u32,
        diag: *Diag,
    ) Error!Reply {
        const fd = stream.socket.handle;
        const lost = "the connection was lost";
        var raw: std.ArrayList(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        var head: ?Head = null;
        var head_len: usize = 0;
        while (true) {
            const events = std.posix.POLL.IN;
            var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
            const ready = std.posix.poll(&wait, @intCast(wait_ms)) catch
                return unreachable_server(diag, client, lost);
            if (ready == 0) return unreachable_server(diag, client, "it did not answer in time");
            const length = std.posix.read(fd, &chunk) catch
                return unreachable_server(diag, client, lost);
            if (length == 0) return unreachable_server(diag, client, lost);
            raw.appendSlice(arena, chunk[0..length]) catch return error.OutOfMemory;
            if (head == null) {
                const end = std.mem.find(u8, raw.items, "\r\n\r\n");
                if (end == null and raw.items.len > head_bytes_max) {
                    return bad_reply(diag, "the reply's headers are longer than the agent reads");
                }
                if (end) |at| {
                    head_len = at + 4;
                    head = try parse_head(raw.items[0..head_len], diag);
                }
            }
            const parsed = head orelse continue;
            const promised = parsed.content_length orelse
                return bad_reply(diag, "the reply has no Content-Length");
            if (promised > constants.agent_response_bytes_max) {
                return bad_reply(diag, "the reply is larger than the agent reads");
            }
            if (raw.items.len - head_len >= promised) {
                return .{ .status = parsed.status, .body = raw.items[head_len..][0..promised] };
            }
        }
    }
};

/// The status line and headers of a reply fit in this many bytes, or the reply is not the server's.
const head_bytes_max: u32 = 16 * 1024;

pub const Head = struct { status: u16, content_length: ?u32 };

/// Reads "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n...\r\n\r\n": the status and, if it has one, the
/// length of the body that follows. The agent closes the connection itself after the body, so
/// that the server does not: a server that closes first keeps its port in TIME_WAIT, and could
/// not be restarted on it (docs/core.md, "Known limit: reuse_address").
pub fn parse_head(head: []const u8, diag: *Diag) Error!Head {
    const prefix = "HTTP/1.1 ";
    if (head.len < prefix.len + 3) return bad_reply(diag, "the reply is not HTTP");
    if (!std.mem.startsWith(u8, head, prefix)) return bad_reply(diag, "the reply is not HTTP/1.1");
    const status = std.fmt.parseInt(u16, head[prefix.len..][0..3], 10) catch
        return bad_reply(diag, "the reply has no status");
    var length: ?u32 = null;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // The status line.
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const text = std.mem.trim(u8, line[colon + 1 ..], " ");
        length = std.fmt.parseInt(u32, text, 10) catch
            return bad_reply(diag, "the reply's Content-Length is not a number");
    }
    return .{ .status = status, .content_length = length };
}

fn unreachable_server(diag: *Diag, client: *const Client, reason: []const u8) Error {
    assert(diag.code == null);
    diag.raise(.E0503);
    diag.cause("no answer from zcube-server at {f}: {s}", .{ client.address, reason });
    diag.fix(.{
        .sentence = "start the server, or give the agent the address it listens on",
        .command = "zcube-server --listen 127.0.0.1:7070",
    });
    return error.Unreachable;
}

pub fn bad_reply(diag: *Diag, problem: []const u8) Error {
    raise_bad_reply(diag, problem);
    return error.BadReply;
}

pub const raise_bad_reply = client_mod.raise_bad_reply;

const testing = std.testing;

test "a reply head gives the status and the length, and anything else is ZC-E0504" {
    // Goal: the one parser of the client. Method: a good head with and without a length, and
    // the malformed shapes: no HTTP, a short status, a length that is not a number.
    var diag: Diag = undefined;
    diag.reset();
    const good = try parse_head("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", &diag);
    try testing.expectEqual(@as(u16, 200), good.status);
    try testing.expectEqual(@as(?u32, 2), good.content_length);
    const bare = try parse_head("HTTP/1.1 503 Service Unavailable\r\n\r\n", &diag);
    try testing.expectEqual(@as(u16, 503), bare.status);
    try testing.expectEqual(@as(?u32, null), bare.content_length);

    const bad = [_][]const u8{
        "",
        "HTTP/1.0 200 OK\r\n\r\n",
        "HTTP/1.1 2x0 OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\ncontent-length: many\r\n\r\n",
    };
    for (bad) |raw| {
        diag.reset();
        try testing.expectError(error.BadReply, parse_head(raw, &diag));
        try testing.expectEqual(@as(?@TypeOf(diag.code.?), .E0504), diag.code);
    }
}

test "a server that accepts and says nothing is ZC-E0503 after the wait, not a crash" {
    // Goal: a server that holds a request longer than the agent waits (a store outage does) must
    // end the wait with a coded diagnostic. With a receive timeout on the socket, the standard
    // library's reader panicked when it fired ("syscall error: AGAIN"), and the agent died with
    // ZC-B0001 (found by demo-c0). Method: a listener that never accepts (the kernel completes the
    // connection) and a client that waits 100 ms.
    const io = testing.io;
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    const client: Client = .{
        .io = io,
        .address = listener.socket.address,
        .io_timeout_ms = 100,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const request: Request = .{ .method = "GET", .target = "/v1/status" };
    const result = client.call(arena_state.allocator(), request, &diag);
    try testing.expectError(error.Unreachable, result);
    try testing.expectEqual(@as(?@TypeOf(diag.code.?), .E0503), diag.code);
    try testing.expect(std.mem.endsWith(u8, diag.last_cause().?, "it did not answer in time"));
}
