//! The peer handshake and sealed records over a socket (docs/peer.md, "What 6b calls"; C2 slice
//! 6b). Shell code: file descriptors, `poll`, the wall clock and the system's randomness. The
//! protocol itself is `peer.zig`; this file moves its bytes.
//!
//! A *message* is a u32 big endian length and that many bytes, sent as sealed records of at most
//! `peer_record_bytes_max` plaintext each. The reader announces nothing it has not bounded: a
//! message longer than the buffer the caller gave is `TooBig`, and the reader stops there. A
//! stream that ends or stalls inside a message is `Closed` or `Timeout`, never a short message:
//! the end of a stream is not authenticated (docs/peer.md, "Records").
//!
//! Every read and write waits with `poll` against one deadline (a socket timeout makes the
//! standard library's reader panic, ZC-B0001). A request is one message and so is a reply.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const peer = @import("peer.zig");

const Session = peer.Session;

/// `Entropy`: the OS secure random source failed (ZC-E0821; the caller raises it).
/// `Canceled`: the task was cancelled; it is never ZC-E0821.
pub const Error = peer.Error || error{ Closed, Timeout, TooBig, Io, Entropy, Canceled };

/// The time a call may take is `end_ms` on this clock: CLOCK_BOOTTIME in milliseconds.
pub fn boot_ms(io: std.Io) u64 {
    const ms = std.Io.Clock.boot.now(io).toMilliseconds();
    assert(ms >= 0);
    return @intCast(ms);
}

/// Unix milliseconds, for credential windows.
pub fn wall_ms(io: std.Io) u64 {
    const ms = std.Io.Clock.real.now(io).toMilliseconds();
    assert(ms >= 0);
    return @intCast(ms);
}

/// A secret seed from the kernel (RB-N9); no fallback. `Entropy` is for the caller to raise.
pub fn random_seed(io: std.Io) error{ Entropy, Canceled }![32]u8 {
    var seed: [32]u8 = undefined;
    io.randomSecure(&seed) catch |err| switch (err) {
        error.EntropyUnavailable => return error.Entropy,
        error.Canceled => return error.Canceled, // Not an Entropy failure; see secure_random.Error.
    };
    return seed;
}

/// An open, authenticated stream. `fd` stays the caller's to close.
pub const Stream = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    session: Session,
    /// One record's plaintext, and one sealed record.
    plain: [constants.peer_record_bytes_max]u8 = undefined,
    sealed: [peer.record_bytes_max]u8 = undefined,

    pub fn deinit(stream: *Stream) void {
        stream.session.wipe();
        std.crypto.secureZero(u8, &stream.plain);
    }

    /// The authenticated name of the other end.
    pub fn peer_name(stream: *const Stream) []const u8 {
        return stream.session.peer_name();
    }

    /// Sends `body` as one message.
    pub fn send(stream: *Stream, body: []const u8, end_ms: u64) Error!void {
        assert(body.len <= std.math.maxInt(u32));
        var head: [4]u8 = undefined;
        std.mem.writeInt(u32, &head, @intCast(body.len), .big);
        var offset: usize = 0;
        var first = true;
        while (first or offset < body.len) {
            var used: usize = 0;
            if (first) {
                @memcpy(stream.plain[0..4], &head);
                used = 4;
                first = false;
            }
            const take = @min(body.len - offset, stream.plain.len - used);
            @memcpy(stream.plain[used..][0..take], body[offset..][0..take]);
            offset += take;
            const record = try stream.session.seal(stream.plain[0 .. used + take], &stream.sealed);
            try write_all(stream.io, stream.fd, record, end_ms);
        }
    }

    /// Reads one message into `out` and returns it. A message longer than `out` is `TooBig`.
    pub fn recv(stream: *Stream, out: []u8, end_ms: u64) Error![]u8 {
        var length: ?usize = null;
        var have: usize = 0;
        var pending: [4]u8 = undefined;
        var pending_len: usize = 0;
        while (length == null or have < length.?) {
            var header: [peer.record_header_bytes]u8 = undefined;
            try read_exact(stream.io, stream.fd, &header, end_ms);
            const body = peer.Session.body_length(&header) orelse return error.RecordRejected;
            @memcpy(stream.sealed[0..2], &header);
            try read_exact(stream.io, stream.fd, stream.sealed[2..][0..body], end_ms);
            var piece = try stream.session.open(stream.sealed[0 .. 2 + body], &stream.plain);
            if (length == null) {
                const need = @min(4 - pending_len, piece.len);
                @memcpy(pending[pending_len..][0..need], piece[0..need]);
                pending_len += need;
                piece = piece[need..];
                if (pending_len < 4) continue;
                const announced = std.mem.readInt(u32, &pending, .big);
                if (announced > out.len) return error.TooBig;
                length = announced;
            }
            if (have + piece.len > length.?) return error.RecordRejected;
            @memcpy(out[have..][0..piece.len], piece);
            have += piece.len;
        }
        return out[0..have];
    }
};

/// Runs the client side over `fd`: `expected_node` must be who answers.
pub fn open_client(
    io: std.Io,
    fd: std.posix.fd_t,
    identity: *const peer.Identity,
    expected_node: []const u8,
    end_ms: u64,
) Error!Stream {
    var initiator = peer.Initiator.init(identity, expected_node, try random_seed(io), wall_ms(io));
    defer initiator.deinit();
    const m1 = initiator.first();
    try write_all(io, fd, &m1, end_ms);
    var m2: [peer.m2_bytes]u8 = undefined;
    try read_exact(io, fd, &m2, end_ms);
    const done = try initiator.second(&m2);
    try write_all(io, fd, &done.m3, end_ms);
    return .{ .io = io, .fd = fd, .session = done.session };
}

/// Runs the server side over `fd`. The caller has admitted the source (`peer_limit`).
pub fn open_server(
    io: std.Io,
    fd: std.posix.fd_t,
    identity: *const peer.Identity,
    end_ms: u64,
) Error!Stream {
    var responder = peer.Responder.init(identity, try random_seed(io), wall_ms(io));
    defer responder.deinit();
    var m1: [peer.m1_bytes]u8 = undefined;
    try read_exact(io, fd, &m1, end_ms);
    const m2 = try responder.first(&m1);
    try write_all(io, fd, &m2, end_ms);
    var m3: [peer.m3_bytes]u8 = undefined;
    try read_exact(io, fd, &m3, end_ms);
    const session = try responder.second(&m3);
    return .{ .io = io, .fd = fd, .session = session };
}

fn left_ms(io: std.Io, end_ms: u64) i32 {
    return @intCast(@min(end_ms -| boot_ms(io), std.math.maxInt(i32)));
}

pub fn read_exact(io: std.Io, fd: std.posix.fd_t, out: []u8, end_ms: u64) Error!void {
    const linux = std.os.linux;
    var at: usize = 0;
    while (at < out.len) {
        try wait_ready(io, fd, std.posix.POLL.IN, end_ms);
        // MSG.DONTWAIT: whatever mode the descriptor is in, the call never blocks, so the poll's
        // deadline is the only wait.
        const got = linux.recvfrom(fd, out[at..].ptr, out.len - at, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(got)) {
            .SUCCESS => {
                if (got == 0) return error.Closed;
                at += got;
            },
            .AGAIN, .INTR => {},
            else => return error.Closed,
        }
    }
}

/// Writes all of `bytes` by `end_ms`. A send never blocks (MSG.DONTWAIT), so a reader that
/// stops reading, or a zero window, ends in `Timeout` at the deadline (docs/peer.md, "The peer
/// server": every wait is a poll against one deadline).
pub fn write_all(io: std.Io, fd: std.posix.fd_t, bytes: []const u8, end_ms: u64) Error!void {
    const linux = std.os.linux;
    const flags = linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL;
    var at: usize = 0;
    while (at < bytes.len) {
        try wait_ready(io, fd, std.posix.POLL.OUT, end_ms);
        const wrote = linux.sendto(fd, bytes.ptr + at, bytes.len - at, flags, null, 0);
        switch (linux.errno(wrote)) {
            .SUCCESS => at += wrote,
            .AGAIN, .INTR => {},
            else => return error.Closed,
        }
    }
}

/// Polls `fd` for `events` until `end_ms`: `Timeout` once the deadline has passed.
pub fn wait_ready(io: std.Io, fd: std.posix.fd_t, events: i16, end_ms: u64) Error!void {
    if (boot_ms(io) >= end_ms) return error.Timeout;
    var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const ready = std.posix.poll(&wait, left_ms(io, end_ms)) catch return error.Io;
    if (ready == 0) return error.Timeout;
}

/// Turns Nagle's algorithm off. A reply is two sends (head, then body); with Nagle the body, when
/// shorter than a segment, waits for the ACK of the head, which the peer's delayed ACK holds back
/// for tens of milliseconds: one chunk request cost ~60 ms and a fetch ran at ~400 KB/s (#93).
/// Failure is ignored: the link is only slower.
pub fn set_nodelay(fd: std.posix.fd_t) void {
    const on = std.mem.toBytes(@as(c_int, 1));
    const linux = std.os.linux;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, &on, on.len);
}

/// A connected socket to `address`, made with a non-blocking connect and a `poll` until `end_ms`
/// (the standard library's connect has no timeout on POSIX). It stays non-blocking: every read
/// and write on it polls against its caller's deadline. The caller closes it.
pub fn connect(io: std.Io, address: std.Io.net.IpAddress, end_ms: u64) Error!std.posix.fd_t {
    const linux = std.os.linux;
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const length = std.Io.Threaded.addressToPosix(&address, &storage);
    const family: u32 = storage.any.family;
    const kind = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const opened = linux.socket(family, kind, linux.IPPROTO.TCP);
    if (linux.errno(opened) != .SUCCESS) return error.Io;
    const fd: std.posix.fd_t = @intCast(opened);
    errdefer _ = linux.close(fd);
    set_nodelay(fd);
    switch (linux.errno(linux.connect(fd, &storage.any, length))) {
        .SUCCESS => {},
        .INPROGRESS => {
            const events = std.posix.POLL.OUT;
            var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
            const ready = std.posix.poll(&wait, left_ms(io, end_ms)) catch return error.Io;
            if (ready == 0) return error.Timeout;
            var code: i32 = 0;
            var code_len: std.posix.socklen_t = @sizeOf(i32);
            const asked = linux.getsockopt(
                fd,
                linux.SOL.SOCKET,
                linux.SO.ERROR,
                @ptrCast(&code),
                &code_len,
            );
            if (linux.errno(asked) != .SUCCESS or code != 0) return error.Closed;
        },
        else => return error.Closed,
    }
    return fd;
}

// ---- Tests -----------------------------------------------------------------------------------

test "a connected socket has Nagle off" {
    const linux = std.os.linux;
    const listener = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(listener) == .SUCCESS);
    const lfd: std.posix.fd_t = @intCast(listener);
    defer _ = linux.close(lfd);
    var addr = linux.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try std.testing.expect(linux.errno(linux.bind(lfd, @ptrCast(&addr), size)) == .SUCCESS);
    try std.testing.expect(linux.errno(linux.listen(lfd, 1)) == .SUCCESS);
    const named = linux.getsockname(lfd, @ptrCast(&addr), &size);
    try std.testing.expect(linux.errno(named) == .SUCCESS);
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = std.mem.bigToNative(u16, addr.port),
    } };
    const fd = try connect(io, address, boot_ms(io) + 5000);
    defer _ = linux.close(fd);
    var value: i32 = 0;
    var length: linux.socklen_t = @sizeOf(i32);
    const level = linux.IPPROTO.TCP;
    const got = linux.getsockopt(fd, level, linux.TCP.NODELAY, @ptrCast(&value), &length);
    try std.testing.expect(linux.errno(got) == .SUCCESS);
    try std.testing.expect(value != 0);
}

const Ed25519 = std.crypto.sign.Ed25519;
const secure_random = @import("secure_random.zig");

fn test_identity(ca: Ed25519.KeyPair, name: []const u8, seed: u8, now: u64) !peer.Identity {
    const key = Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch
        unreachable; // Fixed seed.
    const credential = peer.issue(ca, name, key.public_key.toBytes(), now - 1000, now + 100_000);
    return .{ .key = key, .credential = credential, .ca_public = ca.public_key.toBytes() };
}

const Pair = struct {
    fds: [2]std.posix.fd_t,

    fn make() !Pair {
        var fds: [2]i32 = undefined;
        const linux = std.os.linux;
        const made = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(made));
        return .{ .fds = fds };
    }

    fn close(pair: Pair) void {
        for (pair.fds) |fd| _ = std.os.linux.close(fd);
    }
};

const Echo = struct {
    fn serve(io: std.Io, fd: std.posix.fd_t, identity: *const peer.Identity, size: usize) bool {
        const end = boot_ms(io) + 5000;
        var stream = open_server(io, fd, identity, end) catch return false;
        defer stream.deinit();
        const buffer = std.testing.allocator.alloc(u8, size) catch return false;
        defer std.testing.allocator.free(buffer);
        const got = stream.recv(buffer, end) catch return false;
        stream.send(got, end) catch return false;
        return true;
    }
};

test "a handshake with a failing random source is Entropy and sends nothing" {
    // Goal: RB-N9 at the caller: no ClientHello-equivalent leaves when the kernel's source fails.
    // Method: an Io whose `randomSecure` fails; the seed is drawn before the first write.
    var vtable: std.Io.VTable = undefined;
    const io = secure_random.failing_io(std.testing.io, &vtable);
    const ca = Ed25519.KeyPair.generateDeterministic(@splat(1)) catch unreachable; // Fixed seed.
    var client_id = try test_identity(ca, "node1", 2, wall_ms(std.testing.io));
    const pair = try Pair.make();
    defer pair.close();
    const end = boot_ms(io) + 1000;
    const opened = open_client(io, pair.fds[0], &client_id, "node2", end);
    try std.testing.expectError(error.Entropy, opened);
}

test "a message of several records crosses a handshaken stream both ways" {
    // Goal: the handshake runs over a real socket and a message longer than one record comes
    // back intact, with the server seeing the client's authenticated name. Method: a socketpair,
    // the server on a concurrent task, a 40 000 byte message echoed.
    const io = std.testing.io;
    const now = wall_ms(io);
    const ca = Ed25519.KeyPair.generateDeterministic(@splat(1)) catch unreachable; // Fixed seed.
    var client_id = try test_identity(ca, "node1", 2, now);
    var server_id = try test_identity(ca, "node2", 3, now);
    const pair = try Pair.make();
    defer pair.close();
    const size = 40_000;
    var future = try io.concurrent(Echo.serve, .{ io, pair.fds[1], &server_id, size });
    const end = boot_ms(io) + 5000;
    var stream = try open_client(io, pair.fds[0], &client_id, "node2", end);
    defer stream.deinit();
    try std.testing.expectEqualStrings("node2", stream.peer_name());
    const body = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, at| byte.* = @intCast(at % 251);
    try stream.send(body, end);
    const back = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(back);
    const got = try stream.recv(back, end);
    try std.testing.expectEqualSlices(u8, body, got);
    try std.testing.expect(future.await(io));
}

test "a message longer than the reader's buffer is TooBig, and a wrong node is refused" {
    // Goal: the two bounds the protocol relies on. Method: a 100 byte buffer for a 200 byte
    // message; then a client that expects another node name.
    const io = std.testing.io;
    const now = wall_ms(io);
    const ca = Ed25519.KeyPair.generateDeterministic(@splat(1)) catch unreachable; // Fixed seed.
    var client_id = try test_identity(ca, "node1", 2, now);
    var server_id = try test_identity(ca, "node2", 3, now);
    {
        const pair = try Pair.make();
        defer pair.close();
        var future = try io.concurrent(Echo.serve, .{ io, pair.fds[1], &server_id, 100 });
        const end = boot_ms(io) + 5000;
        var stream = try open_client(io, pair.fds[0], &client_id, "node2", end);
        defer stream.deinit();
        const body: [200]u8 = @splat(7);
        try stream.send(&body, end);
        try std.testing.expect(!future.await(io)); // The server's recv said TooBig.
    }
    {
        const pair = try Pair.make();
        defer pair.close();
        var future = try io.concurrent(Echo.serve, .{ io, pair.fds[1], &server_id, 10 });
        const end = boot_ms(io) + 5000;
        try std.testing.expectError(
            error.WrongNode,
            open_client(io, pair.fds[0], &client_id, "node9", end),
        );
        _ = std.os.linux.close(pair.fds[0]); // The server sees the stream end.
        try std.testing.expect(!future.await(io));
    }
}

test "a stalled peer ends in a timeout, not a hang" {
    // Goal: a read has a deadline. Method: a pair nobody writes to, 50 ms.
    const io = std.testing.io;
    const pair = try Pair.make();
    defer pair.close();
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.Timeout, read_exact(io, pair.fds[0], &out, boot_ms(io) + 50));
}
