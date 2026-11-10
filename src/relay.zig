//! A job's relay: the one TCP listener a relayed job has, and the copying between it and the
//! upstream the server's configuration names. Shell code (sockets, threads), run by the job's
//! supervisor (`fake_supervisor.zig`). (B3 slice 2, docs/briefs/b3.md.)
//!
//! One acceptor thread takes connections on `127.0.0.1:<port the host picks>` and gives each its
//! own thread, at most `relay_connections_max` at a time (the next is closed at once, ZC-W0701).
//! A connection thread connects to the upstream (ZC-E0701 refused, ZC-E0704 no answer in
//! `relay_connect_timeout_ms`), then copies both ways through two `Pipe`s (`relay_pump.zig`)
//! until both ends are done, a bound is reached (ZC-W0702: bytes, or idle), or a read or write
//! fails (ZC-E0705). The upstream is plain TCP; B4 replaces `connect_upstream` with mTLS.
//!
//! `stop` is the only way the relay ends: it closes the listener and every connection, in every
//! thread's own hands, and returns when none is left. The supervisor calls it before it reports
//! how the job ended, so no ending leaves a route open. Every thread looks at the stop flag at
//! least every `relay_poll_ms`.
//!
//! What it records: `relay.log` in the container's directory, one coded line per event, at most
//! `relay_log_bytes_max` bytes (the rest are counted and dropped). It is not yet shown by
//! `zcube why job`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const constants = @import("constants.zig");
const Pipe = @import("relay_pump.zig").Pipe;
const codes = @import("diag/codes.zig");
const Code = codes.Code;

const fd_t = linux.fd_t;
const ns_per_ms = 1_000_000;
const nonblock_cloexec: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
const log_line_bytes_max = 256;

/// Where the upstream is: a host (a literal address or a name) and a port.
pub const Upstream = struct {
    host: []const u8,
    port: u16,

    /// `HOST:PORT`, the last colon being the separator (a bracketed IPv6 literal works).
    pub fn parse(text: []const u8) ?Upstream {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
        if (colon == 0) return null;
        const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
        if (port == 0) return null;
        const host = std.mem.trim(u8, text[0..colon], "[]");
        if (host.len == 0) return null;
        return .{ .host = host, .port = port };
    }
};

pub const Counts = struct { accepted: u32 = 0, refused_over_limit: u32 = 0, log_dropped: u32 = 0 };

const Slot = struct {
    relay: *Relay,
    client: fd_t = -1,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(true),
};

pub const Relay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    upstream: Upstream,
    listener: fd_t,
    port: u16,
    log_fd: fd_t,
    log_bytes: u64 = 0,
    log_lock: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    acceptor: ?std.Thread = null,
    slots: [constants.relay_connections_max]Slot = undefined,
    counts: Counts = .{},

    pub const OpenError = error{ SocketFailed, BindFailed, ListenFailed, OutOfMemory };

    /// Opens the listener (no thread yet: the supervisor spawns the job's command while it is
    /// still single-threaded, then calls `run`). `log_path` is where `relay.log` goes.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        upstream: Upstream,
        log_path: [:0]const u8,
    ) OpenError!*Relay {
        const relay = try gpa.create(Relay);
        errdefer gpa.destroy(relay);
        const bound = try listen_loopback();
        errdefer _ = linux.close(bound.fd);
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        };
        const log = linux.open(log_path, flags, 0o644);
        relay.* = .{
            .gpa = gpa,
            .io = io,
            .upstream = upstream,
            .listener = bound.fd,
            .port = bound.port,
            .log_fd = if (linux.errno(log) == .SUCCESS) @intCast(log) else -1,
        };
        for (&relay.slots) |*slot| slot.* = .{ .relay = relay };
        return relay;
    }

    /// Starts accepting.
    pub fn run(relay: *Relay) !void {
        assert(relay.acceptor == null);
        relay.acceptor = try std.Thread.spawn(.{}, accept_loop, .{relay});
    }

    /// Closes the listener and every connection and waits for the threads. Safe to call without
    /// `run`; the relay is gone afterwards.
    pub fn stop(relay: *Relay) void {
        relay.stopping.store(true, .release);
        if (relay.acceptor) |thread| thread.join();
        if (relay.acceptor == null) _ = linux.close(relay.listener);
        if (relay.log_fd >= 0) _ = linux.close(relay.log_fd);
        const gpa = relay.gpa;
        gpa.destroy(relay);
    }

    fn accept_loop(relay: *Relay) void {
        while (!relay.stopping.load(.acquire)) {
            relay.reap_finished();
            var fds = [1]linux.pollfd{
                .{ .fd = relay.listener, .events = linux.POLL.IN, .revents = 0 },
            };
            if (linux.poll(&fds, 1, constants.relay_poll_ms) == 0) continue;
            const accepted = linux.accept4(relay.listener, null, null, nonblock_cloexec);
            if (linux.errno(accepted) != .SUCCESS) continue;
            relay.admit(@intCast(accepted));
        }
        for (&relay.slots) |*slot| {
            if (slot.thread) |thread| thread.join();
            slot.thread = null;
        }
        _ = linux.close(relay.listener);
    }

    fn reap_finished(relay: *Relay) void {
        for (&relay.slots) |*slot| {
            if (slot.thread == null or !slot.done.load(.acquire)) continue;
            slot.thread.?.join();
            slot.thread = null;
        }
    }

    /// Gives a new connection a slot and a thread, or closes it (ZC-W0701).
    fn admit(relay: *Relay, client: fd_t) void {
        for (&relay.slots) |*slot| {
            if (slot.thread != null) continue;
            slot.client = client;
            slot.done.store(false, .release);
            slot.thread = std.Thread.spawn(.{}, serve, .{slot}) catch {
                slot.done.store(true, .release);
                _ = linux.close(client);
                relay.note(.E0705, "no thread for a connection", .{});
                return;
            };
            relay.counts.accepted += 1;
            return;
        }
        _ = linux.close(client);
        relay.counts.refused_over_limit += 1;
        relay.note(.W0701, "{d} connections are open; a new one was closed", .{
            constants.relay_connections_max,
        });
    }

    /// One line of `relay.log`, if there is room.
    fn note(relay: *Relay, code: Code, comptime format: []const u8, args: anytype) void {
        var line: [log_line_bytes_max]u8 = undefined;
        const head = std.fmt.bufPrint(&line, "{s} ", .{codes.full_name(code)}) catch return;
        const room = line[head.len..];
        const tail = std.fmt.bufPrint(room, format ++ "\n", args) catch room[0..0];
        const text = line[0 .. head.len + tail.len];
        while (relay.log_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer relay.log_lock.store(false, .release);
        if (relay.log_fd < 0 or relay.log_bytes + text.len > constants.relay_log_bytes_max) {
            relay.counts.log_dropped += 1;
            return;
        }
        relay.log_bytes += text.len;
        _ = linux.write(relay.log_fd, text.ptr, text.len);
    }
};

const Ending = enum { clean, stopped, byte_bound, idle, failed };

fn serve(slot: *Slot) void {
    const relay = slot.relay;
    defer slot.done.store(true, .release);
    defer _ = linux.close(slot.client);
    set_nodelay(slot.client);
    const upstream = connect_upstream(relay) orelse return;
    defer _ = linux.close(upstream);
    switch (copy_both_ways(relay, slot.client, upstream)) {
        .clean, .stopped => {},
        .byte_bound => relay.note(.W0702, "a connection reached {d} bytes in one direction", .{
            constants.relay_connection_bytes_max,
        }),
        .idle => relay.note(.W0702, "a connection was idle for {d} ms", .{constants.relay_idle_ms}),
        .failed => relay.note(.E0705, "a read or write failed in the middle of a connection", .{}),
    }
}

/// The upstream, connected, nonblocking; null (and a log line) when it cannot be reached.
fn connect_upstream(relay: *Relay) ?fd_t {
    const upstream = relay.upstream;
    const literal = std.Io.net.IpAddress.parseLiteral(upstream.host) catch null;
    const fd = if (literal) |address|
        connect_address(relay, address, upstream.port)
    else
        connect_name(relay, upstream);
    const connected = fd catch |err| {
        switch (err) {
            error.Stopped => {},
            error.TimedOut => relay.note(.E0704, "{s}:{d} did not answer in {d} ms", .{
                upstream.host, upstream.port, constants.relay_connect_timeout_ms,
            }),
            error.Refused => relay.note(.E0701, "{s}:{d} refused the connection", .{
                upstream.host, upstream.port,
            }),
        }
        return null;
    };
    set_nonblocking(connected);
    set_nodelay(connected);
    return connected;
}

const ConnectError = error{ Stopped, TimedOut, Refused };

/// An IPv4 literal is connected here, in slices of `relay_poll_ms`, so that `stop` need not wait
/// for a black-holed route; any other address goes through `std.Io`.
fn connect_address(relay: *Relay, address: std.Io.net.IpAddress, port: u16) ConnectError!fd_t {
    switch (address) {
        .ip4 => |ip4| return connect_ip4(relay, ip4.bytes, port),
        .ip6 => {
            var literal = address;
            literal.setPort(port);
            return connect_io(relay, literal);
        },
    }
}

fn connect_ip4(relay: *Relay, bytes: [4]u8, port: u16) ConnectError!fd_t {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | nonblock_cloexec, 0);
    if (linux.errno(made) != .SUCCESS) return error.Refused;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    const address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(bytes),
    };
    switch (linux.errno(linux.connect(fd, &address, @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => return fd,
        .INPROGRESS => {},
        else => return error.Refused,
    }
    const started = monotonic_ms();
    while (true) {
        if (relay.stopping.load(.acquire)) return error.Stopped;
        if (monotonic_ms() - started >= constants.relay_connect_timeout_ms) return error.TimedOut;
        var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        if (linux.poll(&fds, 1, constants.relay_poll_ms) == 0) continue;
        var failed: c_int = 0;
        var length: linux.socklen_t = @sizeOf(c_int);
        const out: [*]u8 = @ptrCast(&failed);
        const got = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, out, &length);
        if (linux.errno(got) != .SUCCESS or failed != 0) return error.Refused;
        return fd;
    }
}

fn connect_name(relay: *Relay, upstream: Upstream) ConnectError!fd_t {
    const name = std.Io.net.HostName.init(upstream.host) catch return error.Refused;
    const stream = name.connect(relay.io, upstream.port, io_options()) catch |err| {
        return if (err == error.Timeout) error.TimedOut else error.Refused;
    };
    return stream.socket.handle;
}

fn connect_io(relay: *Relay, address: std.Io.net.IpAddress) ConnectError!fd_t {
    const stream = address.connect(relay.io, io_options()) catch |err| {
        return if (err == error.Timeout) error.TimedOut else error.Refused;
    };
    return stream.socket.handle;
}

fn io_options() std.Io.net.IpAddress.ConnectOptions {
    return .{ .mode = .stream, .timeout = .{ .duration = .{
        .raw = .fromMilliseconds(constants.relay_connect_timeout_ms),
        .clock = .awake,
    } } };
}

/// One direction: its buffer and its two ends. `shut` is set once the sink has been told the
/// source ended.
const Lane = struct { pipe: Pipe = .{}, source: fd_t, sink: fd_t, shut: bool = false };

const Step = enum { quiet, moved, failed };

fn copy_both_ways(relay: *Relay, client: fd_t, upstream: fd_t) Ending {
    var inbound: Lane = .{ .source = client, .sink = upstream };
    var outbound: Lane = .{ .source = upstream, .sink = client };
    var last_progress = monotonic_ms();
    while (!relay.stopping.load(.acquire)) {
        const first = step(&inbound);
        const second = step(&outbound);
        if (first == .failed or second == .failed) return .failed;
        if (first == .moved or second == .moved) last_progress = monotonic_ms();
        if (inbound.pipe.exhausted() or outbound.pipe.exhausted()) return .byte_bound;
        if (inbound.pipe.finished() and outbound.pipe.finished()) return .clean;
        if (monotonic_ms() - last_progress >= constants.relay_idle_ms) return .idle;
        wait(&inbound, &outbound);
    }
    return .stopped;
}

/// Writes what waits, reads if the buffer is empty, writes what came; passes the source's end on
/// to the sink once everything before it is written.
fn step(lane: *Lane) Step {
    var result: Step = .quiet;
    var turn: u8 = 0;
    while (turn < 3) : (turn += 1) {
        const outcome = if (turn == 1) read_some(lane) else write_some(lane);
        if (outcome == .failed) return .failed;
        if (outcome == .moved) result = .moved;
    }
    if (lane.pipe.finished() and !lane.shut) {
        _ = linux.shutdown(lane.sink, linux.SHUT.WR);
        lane.shut = true;
    }
    return result;
}

fn read_some(lane: *Lane) Step {
    if (!lane.pipe.wants_read()) return .quiet;
    const into = lane.pipe.read_into();
    const got = linux.read(lane.source, into.ptr, into.len);
    switch (linux.errno(got)) {
        .SUCCESS => {
            lane.pipe.fed(got);
            return .moved;
        },
        .AGAIN, .INTR => return .quiet,
        else => return .failed,
    }
}

fn write_some(lane: *Lane) Step {
    if (!lane.pipe.wants_write()) return .quiet;
    const from = lane.pipe.write_from();
    const sent = linux.sendto(lane.sink, from.ptr, from.len, linux.MSG.NOSIGNAL, null, 0);
    switch (linux.errno(sent)) {
        .SUCCESS => {
            lane.pipe.drained(sent);
            return .moved;
        },
        .AGAIN, .INTR => return .quiet,
        else => return .failed,
    }
}

/// Sleeps until a socket the lanes are waiting on can be used, or `relay_poll_ms` passes.
fn wait(inbound: *const Lane, outbound: *const Lane) void {
    var fds = [2]linux.pollfd{
        .{ .fd = inbound.source, .events = 0, .revents = 0 },
        .{ .fd = inbound.sink, .events = 0, .revents = 0 },
    };
    if (inbound.pipe.wants_read()) fds[0].events |= linux.POLL.IN;
    if (outbound.pipe.wants_write()) fds[0].events |= linux.POLL.OUT;
    if (outbound.pipe.wants_read()) fds[1].events |= linux.POLL.IN;
    if (inbound.pipe.wants_write()) fds[1].events |= linux.POLL.OUT;
    for (&fds) |*entry| {
        if (entry.events == 0) entry.fd = -1;
    }
    _ = linux.poll(&fds, fds.len, constants.relay_poll_ms);
}

// ---- Sockets -----------------------------------------------------------------------------------

const Bound = struct { fd: fd_t, port: u16 };

fn listen_loopback() error{ SocketFailed, BindFailed, ListenFailed }!Bound {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | nonblock_cloexec, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    var address: linux.sockaddr.in = .{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    const size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), size)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;
    var length = size;
    if (linux.errno(linux.getsockname(fd, @ptrCast(&address), &length)) != .SUCCESS) {
        return error.BindFailed;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
}

fn set_nodelay(fd: fd_t) void {
    const on = std.mem.toBytes(@as(c_int, 1));
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, &on, on.len);
}

fn set_nonblocking(fd: fd_t) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

fn monotonic_ms() u64 {
    var now: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.MONOTONIC, &now)) == .SUCCESS);
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / ns_per_ms;
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

/// A test upstream: accepts connections on a loopback port and echoes what it reads, until told
/// to stop. A connection closes when its peer does.
const Echo = struct {
    bound: Bound,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start() !*Echo {
        const echo = try testing.allocator.create(Echo);
        echo.* = .{ .bound = try listen_loopback() };
        echo.thread = try std.Thread.spawn(.{}, run, .{echo});
        return echo;
    }

    fn run(echo: *Echo) void {
        var peers: [32]fd_t = undefined;
        var count: usize = 0;
        var buffer: [512]u8 = undefined;
        while (!echo.stopping.load(.acquire)) {
            const accepted = linux.accept4(echo.bound.fd, null, null, nonblock_cloexec);
            if (linux.errno(accepted) == .SUCCESS and count < peers.len) {
                peers[count] = @intCast(accepted);
                count += 1;
            }
            for (peers[0..count]) |peer| {
                const got = linux.read(peer, &buffer, buffer.len);
                if (linux.errno(got) == .SUCCESS and got > 0) {
                    _ = linux.write(peer, &buffer, got);
                }
            }
            const nap: linux.timespec = .{ .sec = 0, .nsec = ns_per_ms };
            _ = linux.nanosleep(&nap, null);
        }
        for (peers[0..count]) |peer| _ = linux.close(peer);
    }

    fn stop(echo: *Echo) void {
        echo.stopping.store(true, .release);
        echo.thread.?.join();
        _ = linux.close(echo.bound.fd);
        testing.allocator.destroy(echo);
    }
};

/// A blocking connection to the relay, as the job would make.
fn dial(port: u16) !fd_t {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    const address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (linux.errno(linux.connect(fd, &address, @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.ConnectFailed;
    }
    return fd;
}

/// Reads at most `buffer.len` bytes, waiting up to `ms`: the count, 0 for an end, null for none.
fn receive(fd: fd_t, buffer: []u8, ms: i32) ?usize {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&fds, 1, ms) == 0) return null;
    const got = linux.read(fd, buffer.ptr, buffer.len);
    return if (linux.errno(got) == .SUCCESS) got else 0;
}

const Rig = struct {
    tmp: testing.TmpDir,
    log_path: [:0]u8,
    relay: *Relay,

    fn start(upstream_port: u16) !Rig {
        var rig: Rig = undefined;
        rig.tmp = testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const length = try rig.tmp.dir.realPath(testing.io, &path);
        rig.log_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/relay.log", .{
            path[0..length],
        }, 0);
        errdefer testing.allocator.free(rig.log_path);
        const upstream: Upstream = .{ .host = "127.0.0.1", .port = upstream_port };
        rig.relay = try Relay.open(testing.allocator, testing.io, upstream, rig.log_path);
        try rig.relay.run();
        return rig;
    }

    /// Stops the relay and returns what it logged (the caller frees it).
    fn finish(rig: *Rig) ![]u8 {
        rig.relay.stop();
        defer rig.tmp.cleanup();
        defer testing.allocator.free(rig.log_path);
        const limit: std.Io.Limit = .limited(1 << 16);
        return rig.tmp.dir.readFileAlloc(testing.io, "relay.log", testing.allocator, limit);
    }
};

test "a relay copies both ways to its upstream and stop closes every connection" {
    const echo = try Echo.start();
    defer echo.stop();
    var rig = try Rig.start(echo.bound.port);
    const port = rig.relay.port;
    const fd = try dial(port);
    defer _ = linux.close(fd);
    var buffer: [64]u8 = undefined;
    _ = linux.write(fd, "hello", 5);
    try testing.expectEqual(@as(?usize, 5), receive(fd, &buffer, 2000));
    try testing.expectEqualStrings("hello", buffer[0..5]);
    const log = try rig.finish();
    defer testing.allocator.free(log);
    // The relay is gone: its connection reads an end, and nothing listens on its port.
    try testing.expectEqual(@as(?usize, 0), receive(fd, &buffer, 2000));
    try testing.expectError(error.ConnectFailed, dial(port));
}

test "a relay closes the connection beyond its limit and says so (ZC-W0701)" {
    const echo = try Echo.start();
    defer echo.stop();
    var rig = try Rig.start(echo.bound.port);
    var fds: [constants.relay_connections_max + 1]fd_t = undefined;
    for (&fds) |*fd| fd.* = try dial(rig.relay.port);
    defer for (fds) |fd| {
        _ = linux.close(fd);
    };
    var buffer: [8]u8 = undefined;
    // The extra one is closed at once; the others stay open and quiet.
    try testing.expectEqual(@as(?usize, 0), receive(fds[fds.len - 1], &buffer, 2000));
    try testing.expectEqual(@as(?usize, null), receive(fds[0], &buffer, 100));
    const log = try rig.finish();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.startsWith(u8, log, "ZC-W0701 "));
}

test "a refused upstream closes the connection and logs ZC-E0701, the relay going on" {
    const dead = try listen_loopback();
    _ = linux.close(dead.fd); // Nothing listens on this port now.
    var rig = try Rig.start(dead.port);
    const fd = try dial(rig.relay.port);
    defer _ = linux.close(fd);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, 0), receive(fd, &buffer, 2000));
    const second = try dial(rig.relay.port);
    defer _ = linux.close(second);
    try testing.expectEqual(@as(?usize, 0), receive(second, &buffer, 2000));
    const log = try rig.finish();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.startsWith(u8, log, "ZC-E0701 "));
}

test "an end from the job is passed on and the upstream's reply still arrives" {
    const echo = try Echo.start();
    defer echo.stop();
    var rig = try Rig.start(echo.bound.port);
    const fd = try dial(rig.relay.port);
    defer _ = linux.close(fd);
    _ = linux.write(fd, "abc", 3);
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, 3), receive(fd, &buffer, 2000));
    const log = try rig.finish();
    defer testing.allocator.free(log);
    try testing.expectEqual(@as(usize, 0), log.len);
}

test "an upstream address is HOST:PORT" {
    const up = Upstream.parse("broker.botpike.com:8443").?;
    try testing.expectEqualStrings("broker.botpike.com", up.host);
    try testing.expectEqual(@as(u16, 8443), up.port);
    try testing.expectEqualStrings("::1", Upstream.parse("[::1]:80").?.host);
    try testing.expect(Upstream.parse("nohost") == null);
    try testing.expect(Upstream.parse(":80") == null);
    try testing.expect(Upstream.parse("a:0") == null);
}
