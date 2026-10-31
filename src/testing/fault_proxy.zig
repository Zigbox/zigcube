//! A scripted TCP proxy for tests (shell: sockets and a thread; standard library only, Linux).
//!
//! It sits between a client and a server on loopback and relays bytes, until a test tells it to
//! misbehave. The store fault tests (`zig build test-store-faults`) point the Postgres store at
//! it; slice 10d's failover test and `demo-c1`'s partition test (slice 8) use the same proxy.
//!
//! ## What a test can script
//!
//!     set_latency(ms)         every chunk waits this long before it is forwarded. A lane holds
//!                             one chunk (16 KiB) at a time and reads the next only after it
//!                             is written, so under latency a lane carries at most 16 KiB per
//!                             period: bulk transfers are slowed as well as delayed. The fault
//!                             tests send small messages, where the two are the same
//!     set_bandwidth(bytes)    at most this many bytes per second in each direction (0: no limit)
//!     cut_all()               reset every open connection now (a TCP RST, not a quiet close)
//!     cut_after(dir, n)       once n more bytes have been forwarded in `dir`, reset the
//!                             connection that forwarded the last of them (n = 0: the next chunk
//!                             is cut before any byte). One shot. Mid-transaction and mid-COMMIT
//!                             cuts are this with the byte count of the message to be cut
//!     stall(dir)              half-open: bytes in `dir` stop (nothing is read from the sender,
//!                             nothing is written to the receiver) and the other direction runs
//!     partition()             both directions dropped: stall(to_server) and stall(to_client).
//!                             This is the interface demo-c1's partition test needs
//!     black_hole(on)          new connections are accepted and nobody answers; what they send
//!                             is read and discarded; nothing reaches the upstream
//!     heal()                  undo every one of the above except connections already cut:
//!                             latency, bandwidth, stalls, the black hole and an armed cut_after.
//!                             A connection the black hole swallowed has no upstream and cannot
//!                             be resumed, so heal resets it (counted in `cuts`): its client
//!                             sees the failure at once and reconnects through the healed proxy
//!
//! A stalled direction holds its bytes, as a partition delays packets and TCP retransmits them:
//! after `heal` they arrive, in order, unless the endpoints gave up in the meantime. "Dropped,
//! then healed" is `partition()`, wait, `heal()`.
//!
//! The proxy thread does everything, including the upstream connect, which gives up after
//! `connect_timeout_ms` (the client is then closed); nothing is served meanwhile.
//!
//! The proxy keeps no log of what it forwarded; `stats` counts bytes and connections.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const fd_t = linux.fd_t;

pub const Direction = enum(u1) {
    /// From the client the proxy accepted to the upstream server.
    to_server,
    /// From the upstream server back to the client.
    to_client,
};

pub const pairs_max = 64;
pub const chunk_bytes = 16 * 1024;
const sleep_ns = 1_000_000;
const ns_per_s = 1_000_000_000;
const ns_per_ms = 1_000_000;
const connect_timeout_ms = 1000;
const burst_ns = 50 * ns_per_ms;
const disarmed = std.math.maxInt(u64);

pub const Stats = struct {
    /// Bytes written onward, per direction.
    forwarded: [2]u64,
    /// Connections accepted, and how many of them reached the upstream.
    accepted: u32,
    upstream_connects: u32,
    /// Connections reset by `cut_all` or `cut_after`.
    cuts: u32,
};

const Lane = struct {
    buffer: [chunk_bytes]u8,
    start: u32,
    end: u32,
    /// Nothing in the buffer leaves before this (monotonic ns): the latency.
    release_ns: u64,
    /// Bandwidth: the time up to which the lane's allowance has been spent.
    spent_ns: u64,
    /// The sender closed its side: once the buffer drains, the receiver is told.
    eof: bool,
    /// The receiver has been told (`shutdown`), or there is nobody to tell.
    shut: bool,
};

const Pair = struct {
    client: fd_t,
    server: fd_t,
    lanes: [2]Lane,
    seen_cut: u32,
    /// The heal generation at accept: a swallowed connection older than a `heal` is reset.
    seen_heal: u32,

    fn source(pair: *const Pair, dir: Direction) fd_t {
        return if (dir == .to_server) pair.client else pair.server;
    }

    fn sink(pair: *const Pair, dir: Direction) fd_t {
        return if (dir == .to_server) pair.server else pair.client;
    }
};

pub const Proxy = struct {
    gpa: std.mem.Allocator,
    listener: fd_t,
    /// The loopback port clients connect to.
    port: u16,
    upstream_port: u16,
    thread: ?std.Thread,
    stopping: std.atomic.Value(bool),
    latency_ms: std.atomic.Value(u32),
    bytes_per_sec: std.atomic.Value(u64),
    stalled: [2]std.atomic.Value(bool),
    hole: std.atomic.Value(bool),
    cut_generation: std.atomic.Value(u32),
    heal_generation: std.atomic.Value(u32),
    cut_budget: [2]std.atomic.Value(u64),
    forwarded: [2]std.atomic.Value(u64),
    accepted: std.atomic.Value(u32),
    upstream_connects: std.atomic.Value(u32),
    cuts: std.atomic.Value(u32),
    pairs: [pairs_max]?*Pair,

    /// Listens on an ephemeral loopback port and relays to `upstream_port` on 127.0.0.1.
    pub fn start(gpa: std.mem.Allocator, upstream_port: u16) !*Proxy {
        assert(upstream_port != 0);
        const proxy = try gpa.create(Proxy);
        errdefer gpa.destroy(proxy);
        const bound = try listen_loopback(0);
        errdefer _ = linux.close(bound.fd);
        proxy.* = .{
            .gpa = gpa,
            .listener = bound.fd,
            .port = bound.port,
            .upstream_port = upstream_port,
            .thread = null,
            .stopping = .init(false),
            .latency_ms = .init(0),
            .bytes_per_sec = .init(0),
            .stalled = .{ .init(false), .init(false) },
            .hole = .init(false),
            .cut_generation = .init(0),
            .heal_generation = .init(0),
            .cut_budget = .{ .init(disarmed), .init(disarmed) },
            .forwarded = .{ .init(0), .init(0) },
            .accepted = .init(0),
            .upstream_connects = .init(0),
            .cuts = .init(0),
            .pairs = @splat(null),
        };
        proxy.thread = try std.Thread.spawn(.{}, run, .{proxy});
        return proxy;
    }

    /// Stops the thread and closes every connection and the listener.
    pub fn stop(proxy: *Proxy) void {
        proxy.stopping.store(true, .release);
        proxy.thread.?.join();
        for (&proxy.pairs) |*slot| {
            if (slot.*) |pair| proxy.drop(pair, false);
            slot.* = null;
        }
        _ = linux.close(proxy.listener);
        proxy.gpa.destroy(proxy);
    }

    pub fn set_latency(proxy: *Proxy, ms: u32) void {
        proxy.latency_ms.store(ms, .release);
    }

    pub fn set_bandwidth(proxy: *Proxy, bytes_per_sec: u64) void {
        proxy.bytes_per_sec.store(bytes_per_sec, .release);
    }

    pub fn cut_all(proxy: *Proxy) void {
        _ = proxy.cut_generation.fetchAdd(1, .acq_rel);
    }

    pub fn cut_after(proxy: *Proxy, dir: Direction, bytes: u64) void {
        assert(bytes != disarmed);
        proxy.cut_budget[@backingInt(dir)].store(bytes, .release);
    }

    pub fn stall(proxy: *Proxy, dir: Direction) void {
        proxy.stalled[@backingInt(dir)].store(true, .release);
    }

    pub fn partition(proxy: *Proxy) void {
        proxy.stall(.to_server);
        proxy.stall(.to_client);
    }

    pub fn black_hole(proxy: *Proxy, on: bool) void {
        proxy.hole.store(on, .release);
    }

    pub fn heal(proxy: *Proxy) void {
        proxy.set_latency(0);
        proxy.set_bandwidth(0);
        proxy.hole.store(false, .release);
        _ = proxy.heal_generation.fetchAdd(1, .acq_rel);
        for (0..2) |index| {
            proxy.stalled[index].store(false, .release);
            proxy.cut_budget[index].store(disarmed, .release);
        }
    }

    pub fn stats(proxy: *const Proxy) Stats {
        return .{
            .forwarded = .{ proxy.forwarded[0].load(.acquire), proxy.forwarded[1].load(.acquire) },
            .accepted = proxy.accepted.load(.acquire),
            .upstream_connects = proxy.upstream_connects.load(.acquire),
            .cuts = proxy.cuts.load(.acquire),
        };
    }

    // ---- The thread ----------------------------------------------------------------------

    fn run(proxy: *Proxy) void {
        while (!proxy.stopping.load(.acquire)) {
            proxy.accept_all();
            const now = monotonic_ns();
            const generation = proxy.cut_generation.load(.acquire);
            const healed = proxy.heal_generation.load(.acquire);
            for (&proxy.pairs) |*slot| {
                const pair = slot.* orelse continue;
                const swallowed = pair.server < 0 and pair.seen_heal != healed;
                if (pair.seen_cut != generation or swallowed) {
                    proxy.drop(pair, true);
                    slot.* = null;
                } else if (!proxy.service(pair, now)) {
                    proxy.drop(pair, false);
                    slot.* = null;
                }
            }
            const nap: linux.timespec = .{ .sec = 0, .nsec = sleep_ns };
            _ = linux.nanosleep(&nap, null);
        }
    }

    fn accept_all(proxy: *Proxy) void {
        while (true) {
            const rc = linux.accept4(proxy.listener, null, null, nonblock_cloexec);
            if (linux.errno(rc) != .SUCCESS) return;
            const client: fd_t = @intCast(rc);
            _ = proxy.accepted.fetchAdd(1, .acq_rel);
            if (!proxy.admit(client)) _ = linux.close(client);
        }
    }

    /// Gives an accepted connection a slot and an upstream, or a black hole. False: no room, or
    /// the upstream refused; the caller closes the client.
    fn admit(proxy: *Proxy, client: fd_t) bool {
        var server: fd_t = -1;
        // Before the hole is read: a `heal` in between leaves this pair older than it.
        const healed = proxy.heal_generation.load(.acquire);
        if (!proxy.hole.load(.acquire)) {
            server = connect_within(proxy.upstream_port, connect_timeout_ms) catch return false;
            _ = proxy.upstream_connects.fetchAdd(1, .acq_rel);
        }
        for (&proxy.pairs) |*slot| {
            if (slot.* != null) continue;
            const pair = proxy.gpa.create(Pair) catch break;
            pair.* = .{
                .client = client,
                .server = server,
                .lanes = @splat(.{
                    .buffer = undefined,
                    .start = 0,
                    .end = 0,
                    .release_ns = 0,
                    .spent_ns = 0,
                    .eof = false,
                    .shut = false,
                }),
                .seen_cut = proxy.cut_generation.load(.acquire),
                .seen_heal = healed,
            };
            set_nodelay(client);
            slot.* = pair;
            return true;
        }
        if (server >= 0) _ = linux.close(server);
        return false;
    }

    /// Closes a connection; `reset` sends a RST instead of a FIN. Frees the pair.
    fn drop(proxy: *Proxy, pair: *Pair, reset: bool) void {
        if (reset) {
            _ = proxy.cuts.fetchAdd(1, .acq_rel);
            reset_close(pair.client);
            if (pair.server >= 0) reset_close(pair.server);
        } else {
            _ = linux.close(pair.client);
            if (pair.server >= 0) _ = linux.close(pair.server);
        }
        proxy.gpa.destroy(pair);
    }

    /// One pass over a connection. False: it is finished (both directions done, or an error, or
    /// a `cut_after` fired) and the caller drops it.
    fn service(proxy: *Proxy, pair: *Pair, now: u64) bool {
        if (pair.server < 0) return swallow(pair);
        for ([_]Direction{ .to_server, .to_client }) |dir| {
            if (proxy.stalled[@backingInt(dir)].load(.acquire)) continue;
            if (!proxy.read_lane(pair, dir, now)) return false;
            switch (proxy.write_lane(pair, dir, now)) {
                .fine => {},
                .broken => return false,
                .cut => {
                    proxy.drop_reset(pair);
                    return false;
                },
            }
        }
        return !(pair.lanes[0].shut and pair.lanes[1].shut);
    }

    fn drop_reset(proxy: *Proxy, pair: *Pair) void {
        _ = proxy.cuts.fetchAdd(1, .acq_rel);
        reset_close(pair.client);
        reset_close(pair.server);
        // `drop` closes again: make that harmless by pointing the pair at nothing.
        pair.client = -1;
        pair.server = -1;
    }

    /// A black-holed connection: read and discard until the client goes away.
    fn swallow(pair: *Pair) bool {
        var scratch: [512]u8 = undefined;
        const rc = linux.read(pair.client, &scratch, scratch.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc != 0,
            .AGAIN => true,
            else => false,
        };
    }

    fn read_lane(proxy: *const Proxy, pair: *Pair, dir: Direction, now: u64) bool {
        const lane = &pair.lanes[@backingInt(dir)];
        if (lane.eof or lane.end != lane.start) return true;
        lane.start = 0;
        lane.end = 0;
        const rc = linux.read(pair.source(dir), &lane.buffer, lane.buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return true,
            else => return false,
        }
        if (rc == 0) {
            lane.eof = true;
            return true;
        }
        lane.end = @intCast(rc);
        lane.release_ns = now + @as(u64, proxy.latency_ms.load(.acquire)) * ns_per_ms;
        return true;
    }

    const Fate = enum { fine, broken, cut };

    fn write_lane(proxy: *Proxy, pair: *Pair, dir: Direction, now: u64) Fate {
        const lane = &pair.lanes[@backingInt(dir)];
        if (lane.start == lane.end) {
            if (lane.eof and !lane.shut) {
                _ = linux.shutdown(pair.sink(dir), linux.SHUT.WR);
                lane.shut = true;
            }
            return .fine;
        }
        if (now < lane.release_ns) return .fine;
        var allowed: u64 = lane.end - lane.start;
        allowed = @min(allowed, proxy.bandwidth_allowance(lane, now));
        const budget = proxy.cut_budget[@backingInt(dir)].load(.acquire);
        if (budget == 0) {
            // One shot: whoever disarms it cuts; a lost race leaves the connection alone.
            const disarm = proxy.cut_budget[@backingInt(dir)].cmpxchgStrong(
                0,
                disarmed,
                .acq_rel,
                .acquire,
            );
            return if (disarm == null) .cut else .fine;
        }
        allowed = @min(allowed, budget);
        if (allowed == 0) return .fine;
        const rc = linux.write(pair.sink(dir), lane.buffer[lane.start..].ptr, allowed);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return .fine,
            else => return .broken,
        }
        lane.start += @intCast(rc);
        _ = proxy.forwarded[@backingInt(dir)].fetchAdd(rc, .acq_rel);
        proxy.spend_bandwidth(lane, rc);
        if (budget == disarmed) return .fine;
        const left = budget - rc;
        const swapped = proxy.cut_budget[@backingInt(dir)].cmpxchgStrong(
            budget,
            if (left == 0) disarmed else left,
            .acq_rel,
            .acquire,
        );
        if (swapped == null and left == 0) return .cut;
        return .fine;
    }

    /// How many bytes the lane may write now under the bandwidth limit.
    fn bandwidth_allowance(proxy: *const Proxy, lane: *Lane, now: u64) u64 {
        const rate = proxy.bytes_per_sec.load(.acquire);
        if (rate == 0) return chunk_bytes;
        if (lane.spent_ns + burst_ns < now) lane.spent_ns = now - burst_ns;
        if (lane.spent_ns > now) return 0;
        return @max(1, (now - lane.spent_ns) * rate / ns_per_s);
    }

    fn spend_bandwidth(proxy: *const Proxy, lane: *Lane, written: usize) void {
        const rate = proxy.bytes_per_sec.load(.acquire);
        if (rate == 0) return;
        lane.spent_ns += written * ns_per_s / rate;
    }
};

// ---- Loopback sockets (also used by the tests) -------------------------------------------------

const nonblock_cloexec: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;

pub const Bound = struct { fd: fd_t, port: u16 };

fn loopback(port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
}

/// A nonblocking listening socket on 127.0.0.1; port 0 picks one.
pub fn listen_loopback(port: u16) !Bound {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | nonblock_cloexec, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    var address = loopback(port);
    const size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), size)) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 64)) != .SUCCESS) return error.ListenFailed;
    var length = size;
    if (linux.errno(linux.getsockname(fd, @ptrCast(&address), &length)) != .SUCCESS) {
        return error.SocketFailed;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, address.port) };
}

/// A nonblocking connection to 127.0.0.1:`port` that gives up after `ms`, with Nagle off.
fn connect_within(port: u16, ms: i32) !fd_t {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | nonblock_cloexec, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    const address = loopback(port);
    const size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    switch (linux.errno(linux.connect(fd, &address, size))) {
        .SUCCESS => {},
        .INPROGRESS => {
            var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT }};
            if (linux.poll(&fds, 1, ms) == 0) return error.ConnectTimeout;
            var failed: c_int = 0;
            var length: linux.socklen_t = @sizeOf(c_int);
            const out: [*]u8 = @ptrCast(&failed);
            const got = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, out, &length);
            if (linux.errno(got) != .SUCCESS or failed != 0) return error.ConnectFailed;
        },
        else => return error.ConnectFailed,
    }
    set_nodelay(fd);
    return fd;
}

/// A blocking connection to 127.0.0.1:`port`, with Nagle off.
pub fn connect_loopback(port: u16) !fd_t {
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    const address = loopback(port);
    const size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.connect(fd, &address, size)) != .SUCCESS) return error.ConnectFailed;
    set_nodelay(fd);
    return fd;
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

/// Closes with a RST: the peer sees "connection reset", not an orderly end.
fn reset_close(fd: fd_t) void {
    if (fd < 0) return;
    const linger: linux.linger = .{ .onoff = 1, .linger = 0 };
    const bytes = std.mem.asBytes(&linger);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.LINGER, bytes.ptr, bytes.len);
    _ = linux.close(fd);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.MONOTONIC, &now)) == .SUCCESS);
    return @as(u64, @intCast(now.sec)) * ns_per_s + @as(u64, @intCast(now.nsec));
}

// ---- Tests --------------------------------------------------------------------------------------

/// Test helpers: a blocking send, and a receive that gives up after `ms`.
pub fn send_all(fd: fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (linux.errno(rc) != .SUCCESS) return error.SendFailed;
        sent += rc;
    }
}

pub const Received = union(enum) { bytes: usize, closed, reset, timeout };

pub fn recv_within(fd: fd_t, buffer: []u8, ms: i32) Received {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN }};
    if (linux.poll(&fds, 1, ms) == 0) return .timeout;
    const rc = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(rc) != .SUCCESS) return .reset;
    return if (rc == 0) .closed else .{ .bytes = rc };
}

const Echo = struct {
    listener: Bound,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn run(echo: *Echo) void {
        while (!echo.stopping.load(.acquire)) {
            const rc = linux.accept4(echo.listener.fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) {
                const nap: linux.timespec = .{ .sec = 0, .nsec = sleep_ns };
                _ = linux.nanosleep(&nap, null);
                continue;
            }
            echo.serve(@intCast(rc));
        }
    }

    fn serve(echo: *Echo, fd: fd_t) void {
        defer _ = linux.close(fd);
        var buffer: [256]u8 = undefined;
        while (!echo.stopping.load(.acquire)) {
            switch (recv_within(fd, &buffer, 20)) {
                .timeout => continue,
                .bytes => |count| send_all(fd, buffer[0..count]) catch return,
                .closed, .reset => return,
            }
        }
    }

    fn stop(echo: *Echo) void {
        echo.stopping.store(true, .release);
        echo.thread.?.join();
        _ = linux.close(echo.listener.fd);
    }
};

const Rig = struct {
    echo: *Echo,
    proxy: *Proxy,

    fn start() !Rig {
        const echo = try std.testing.allocator.create(Echo);
        errdefer std.testing.allocator.destroy(echo);
        echo.* = .{ .listener = try listen_loopback(0) };
        echo.thread = std.Thread.spawn(.{}, Echo.run, .{echo}) catch |err| {
            _ = linux.close(echo.listener.fd);
            return err;
        };
        errdefer echo.stop();
        const proxy = try Proxy.start(std.testing.allocator, echo.listener.port);
        return .{ .echo = echo, .proxy = proxy };
    }

    fn stop(rig: *Rig) void {
        rig.proxy.stop();
        rig.echo.stop();
        std.testing.allocator.destroy(rig.echo);
    }
};

fn expect_echo(fd: fd_t, text: []const u8, ms: i32) !void {
    try send_all(fd, text);
    var buffer: [64]u8 = undefined;
    var got: usize = 0;
    while (got < text.len) {
        switch (recv_within(fd, buffer[got..], ms)) {
            .bytes => |count| got += count,
            else => return error.NoEcho,
        }
    }
    try std.testing.expectEqualStrings(text, buffer[0..got]);
}

test "relay: bytes cross both ways, and one connection reaches the upstream once" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    try expect_echo(fd, "hello", 1000);
    try expect_echo(fd, "again", 1000);
    const stats = rig.proxy.stats();
    try std.testing.expectEqual(@as(u64, 10), stats.forwarded[0]);
    try std.testing.expectEqual(@as(u64, 10), stats.forwarded[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.upstream_connects);
}

test "latency: a round trip takes at least twice the set delay" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    rig.proxy.set_latency(40);
    const began = monotonic_ns();
    try expect_echo(fd, "slow", 2000);
    try std.testing.expect(monotonic_ns() - began >= 80 * ns_per_ms);
}

test "bandwidth: a limit spreads the bytes over time" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    rig.proxy.set_bandwidth(200);
    const text: [60]u8 = @splat('x');
    const began = monotonic_ns();
    try expect_echo(fd, &text, 3000);
    // 60 bytes at 200 bytes/s, less a 10-byte burst, is 250 ms; the two directions overlap.
    try std.testing.expect(monotonic_ns() - began >= 200 * ns_per_ms);
}

test "cut_all: an open connection is reset" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    try expect_echo(fd, "up", 1000);
    rig.proxy.cut_all();
    var buffer: [8]u8 = undefined;
    try std.testing.expect(recv_within(fd, &buffer, 1000) == .reset);
    try std.testing.expectEqual(@as(u32, 1), rig.proxy.stats().cuts);
}

test "cut_after: exactly n bytes pass in the direction, then the connection is reset" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    rig.proxy.cut_after(.to_server, 7);
    try send_all(fd, "0123456789");
    var buffer: [16]u8 = undefined;
    var saw_reset = false;
    for (0..20) |_| {
        switch (recv_within(fd, &buffer, 200)) {
            .reset => saw_reset = true,
            .closed => return error.CleanCloseNotReset,
            else => continue,
        }
        break;
    }
    try std.testing.expect(saw_reset);
    const stats = rig.proxy.stats();
    try std.testing.expectEqual(@as(u64, 7), stats.forwarded[0]);
    try std.testing.expectEqual(@as(u32, 1), stats.cuts);
    // One shot: the next connection is not cut.
    const again = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(again);
    try expect_echo(again, "fine", 1000);
}

test "partition then heal: nothing crosses while dropped, and the held bytes arrive after" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    try expect_echo(fd, "before", 1000);
    rig.proxy.partition();
    try send_all(fd, "held");
    var buffer: [16]u8 = undefined;
    try std.testing.expect(recv_within(fd, &buffer, 150) == .timeout);
    rig.proxy.heal();
    switch (recv_within(fd, &buffer, 1000)) {
        .bytes => |count| try std.testing.expectEqualStrings("held", buffer[0..count]),
        else => return error.NoEcho,
    }
}

test "half-open: with the return direction stalled the upstream hears us and we hear nothing" {
    var rig = try Rig.start();
    defer rig.stop();
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    try expect_echo(fd, "first", 1000);
    rig.proxy.stall(.to_client);
    try send_all(fd, "second");
    var buffer: [16]u8 = undefined;
    try std.testing.expect(recv_within(fd, &buffer, 150) == .timeout);
    try std.testing.expectEqual(@as(u64, 11), rig.proxy.stats().forwarded[0]);
    rig.proxy.heal();
    switch (recv_within(fd, &buffer, 1000)) {
        .bytes => |count| try std.testing.expectEqualStrings("second", buffer[0..count]),
        else => return error.NoEcho,
    }
}

test "black hole: the connection is accepted, nothing answers, nothing reaches the upstream" {
    var rig = try Rig.start();
    defer rig.stop();
    rig.proxy.black_hole(true);
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    try send_all(fd, "anyone?");
    var buffer: [16]u8 = undefined;
    try std.testing.expect(recv_within(fd, &buffer, 150) == .timeout);
    const stats = rig.proxy.stats();
    try std.testing.expectEqual(@as(u32, 1), stats.accepted);
    try std.testing.expectEqual(@as(u32, 0), stats.upstream_connects);
    rig.proxy.heal();
    // The swallowed connection cannot be resumed: heal resets it.
    try std.testing.expect(recv_within(fd, &buffer, 1000) == .reset);
    const after = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(after);
    try expect_echo(after, "back", 1000);
}

test "cut_after zero: the next chunk is cut before any byte, and only that connection" {
    var rig = try Rig.start();
    defer rig.stop();
    // The echo upstream serves one connection at a time, so the connections go one after another.
    const first = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(first);
    rig.proxy.cut_after(.to_server, 0);
    try send_all(first, "doomed");
    var buffer: [16]u8 = undefined;
    for (0..20) |_| switch (recv_within(first, &buffer, 200)) {
        .reset => break,
        .closed => return error.CleanCloseNotReset,
        else => continue,
    } else return error.NotCut;
    try std.testing.expectEqual(@as(u64, 0), rig.proxy.stats().forwarded[0]);
    // Disarmed by the first cut: two later connections are not cut.
    for ([_][]const u8{ "second", "third" }) |text| {
        const later = try connect_loopback(rig.proxy.port);
        defer _ = linux.close(later);
        try expect_echo(later, text, 1000);
    }
    try std.testing.expectEqual(@as(u32, 1), rig.proxy.stats().cuts);
}

test "upstream connect: a refused upstream closes the client instead of hanging the proxy" {
    var rig = try Rig.start();
    defer rig.stop();
    const gone = try listen_loopback(0);
    _ = linux.close(gone.fd);
    rig.proxy.upstream_port = gone.port;
    const fd = try connect_loopback(rig.proxy.port);
    defer _ = linux.close(fd);
    var buffer: [8]u8 = undefined;
    try std.testing.expect(recv_within(fd, &buffer, 1000) == .closed);
    try std.testing.expectEqual(@as(u32, 0), rig.proxy.stats().upstream_connects);
}
