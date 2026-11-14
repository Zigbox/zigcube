//! The agent's HTTP/1.1 client: one request per connection, the whole reply read into the
//! caller's arena. Shell code: sockets. It is small on purpose. The agent talks to
//! one server, a few times a second, and a connection per request costs nothing at that rate and
//! cannot go stale; the server's keep-alive and its limits are for the console and the CLI.
//!
//! A connection serves one request and the agent closes it first (see `parse_head`).
//!
//! Everything is bounded: the whole call, connecting included, ends within the request's own wait
//! plus its I/O timeout (`agent_io_timeout_ms` unless the request caps it: the agent's fence
//! does), with a `poll` before the connection completes and before each read, so a server that
//! accepts and then says nothing, or a host that drops packets, cannot stop the agent. A reply is
//! at most `agent_response_bytes_max`. A failure is ZC-E0503 (the server did not answer) or
//! ZC-E0504 (it answered something the agent cannot use), never a Zig error name. Linux only,
//! as the agent is.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const agent_api = @import("agent_api.zig");
const api_tls_client = @import("api_tls_client.zig");
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
    /// The API over TLS (docs/mtls.md): the CA pinned and the certificate presented, which the
    /// agent switches to its own `node.crt` once it has one. Null: plain HTTP.
    tls: ?*api_tls_client.Credentials = null,

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
        if (request.body.len > agent_api.body_bytes_max(request.target)) {
            return bad_reply(diag, "the request the agent built is larger than the server accepts");
        }
        const io_ms = request.timeout_ms orelse client.io_timeout_ms;
        const end_ms = client.now_ms() + request.hold_ms + io_ms;
        var stream = try client.connect(end_ms, diag);
        defer stream.close(client.io);
        if (client.tls) |tls| return client.call_tls(tls, arena, &stream, request, end_ms, diag);
        try client.send(&stream, request, diag);
        return client.receive(arena, &stream, end_ms, diag);
    }

    /// CLOCK_BOOTTIME, the clock of the agent's fence.
    fn now_ms(client: *const Client) u64 {
        const ms = std.Io.Clock.boot.now(client.io).toMilliseconds();
        assert(ms >= 0);
        return @intCast(ms);
    }

    /// What is left until `end_ms`, as `poll` takes it.
    fn left_ms(client: *const Client, end_ms: u64) i32 {
        return @intCast(@min(end_ms -| client.now_ms(), std.math.maxInt(i32)));
    }

    /// A non-blocking connect and a `poll` until `end_ms`: the standard library's threaded `Io`
    /// has no connect timeout on POSIX (it panics), and the kernel's own waits about two minutes
    /// for a host that drops packets, which is longer than the agent may wait before its fence.
    /// The socket is made blocking again for the standard library's writer.
    fn connect(client: *const Client, end_ms: u64, diag: *Diag) Error!net.Stream {
        const linux = std.os.linux;
        var storage: std.Io.Threaded.PosixAddress = undefined;
        const length = std.Io.Threaded.addressToPosix(&client.address, &storage);
        const family: u32 = switch (client.address) {
            .ip4 => linux.AF.INET,
            .ip6 => linux.AF.INET6,
        };
        const kind = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
        const opened = linux.socket(family, kind, linux.IPPROTO.TCP);
        if (linux.errno(opened) != .SUCCESS) {
            return unreachable_server(diag, client, "the agent could not open a socket");
        }
        const fd: std.posix.fd_t = @intCast(opened);
        errdefer _ = linux.close(fd);
        const started = linux.connect(fd, &storage, length);
        switch (linux.errno(started)) {
            .SUCCESS => {},
            .INPROGRESS => try client.connected(fd, end_ms, diag),
            else => |code| return unreachable_server(diag, client, connect_reason(code)),
        }
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        var mode: linux.O = @bitCast(@as(u32, @truncate(flags)));
        mode.NONBLOCK = false;
        const set = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(mode)));
        if (linux.errno(flags) != .SUCCESS or linux.errno(set) != .SUCCESS) {
            return unreachable_server(diag, client, "the connection could not be made");
        }
        return .{ .socket = .{ .handle = fd, .address = client.address } };
    }

    /// Waits for a connect in progress to end, until `end_ms`.
    fn connected(client: *const Client, fd: std.posix.fd_t, end_ms: u64, diag: *Diag) Error!void {
        const linux = std.os.linux;
        var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&wait, client.left_ms(end_ms)) catch
            return unreachable_server(diag, client, "the connection could not be made");
        if (ready == 0) return unreachable_server(diag, client, "it did not answer in time");
        var code: i32 = 0;
        var code_len: std.posix.socklen_t = @sizeOf(i32);
        const asked = linux.getsockopt(
            fd,
            linux.SOL.SOCKET,
            linux.SO.ERROR,
            @ptrCast(&code),
            &code_len,
        );
        if (linux.errno(asked) != .SUCCESS) {
            return unreachable_server(diag, client, "the connection could not be made");
        }
        if (code != 0) {
            const reason = connect_reason(@fromBackingInt(@intCast(@as(u16, @intCast(code)))));
            return unreachable_server(diag, client, reason);
        }
    }

    /// `call` over TLS: one exchange, then the same checks of the reply as `receive`.
    fn call_tls(
        client: *const Client,
        tls: *api_tls_client.Credentials,
        arena: Allocator,
        stream: *net.Stream,
        request: Request,
        end_ms: u64,
        diag: *Diag,
    ) Error!Reply {
        const head = std.fmt.allocPrint(arena, head_format, .{
            request.method, request.target, client.address, request.body.len,
        }) catch return error.OutOfMemory;
        const limit = head_bytes_max + constants.agent_response_bytes_max;
        const done = api_tls_client.exchange(
            tls,
            client.io,
            stream.socket.handle,
            arena,
            &.{ head, request.body },
            limit,
            api_tls_client.reply_is_whole,
            end_ms,
            diag,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return error.Unreachable,
        };
        switch (done.ending) {
            .done => {},
            .silent => return unreachable_server(diag, client, "it did not answer in time"),
            .failed => {
                assert(diag.code != null);
                return error.Unreachable;
            },
        }
        const raw = done.reply;
        const end = std.mem.find(u8, raw, "\r\n\r\n") orelse {
            if (raw.len > head_bytes_max) {
                return bad_reply(diag, "the reply's headers are longer than the agent reads");
            }
            return unreachable_server(diag, client, "the connection was lost");
        };
        const parsed = try parse_head(raw[0 .. end + 4], diag);
        const promised = parsed.content_length orelse
            return bad_reply(diag, "the reply has no Content-Length");
        if (promised > constants.agent_response_bytes_max) {
            return bad_reply(diag, "the reply is larger than the agent reads");
        }
        const body = raw[end + 4 ..];
        if (body.len < promised) return unreachable_server(diag, client, "the connection was lost");
        return .{ .status = parsed.status, .body = body[0..promised] };
    }

    fn send(client: *const Client, stream: *net.Stream, request: Request, diag: *Diag) Error!void {
        var buffer: [4096]u8 = undefined;
        var writer = stream.writer(client.io, &buffer);
        writer.interface.print(head_format, .{
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
        end_ms: u64,
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
            const ready = std.posix.poll(&wait, client.left_ms(end_ms)) catch
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

fn connect_reason(code: std.os.linux.E) []const u8 {
    return switch (code) {
        .CONNREFUSED => "the connection was refused",
        .TIMEDOUT => "it did not answer in time",
        .NETUNREACH, .HOSTUNREACH => "the network has no route to it",
        else => "the connection could not be made",
    };
}

const head_format = "{s} {s} HTTP/1.1\r\nHost: {f}\r\n" ++
    "Accept: application/json\r\nContent-Type: application/json\r\n" ++
    "Content-Length: {d}\r\n\r\n";

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
