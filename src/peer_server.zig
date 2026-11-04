//! The agent's peer server (docs/peer.md, "The peer server"; C2 slice 6b). Shell code: it
//! listens, accepts, runs `peer_stream`'s handshake and answers each request with
//! `peer_serve.answer` from the node's `DirImages`. It is read-only: nothing a peer sends is
//! written anywhere.
//!
//! * **Rate limit.** `peer_limit.Limiter` is asked before a handshake starts (ZC-E0808 when a
//!   source is turned away; the connection is closed without a byte).
//! * **Connections.** At most `peer_connections_max` at once, each on a task of its own with its
//!   own `DirImages` and buffers (pages the connection does not touch stay untouched); one more
//!   is closed at once. A connection lives while requests keep coming (`peer_idle_ms` between
//!   them) and for `peer_connection_requests_max` requests, then the client opens another.
//! * **Identity.** Read from the state directory at each handshake (`agent_peer.load_identity`),
//!   so a renewed credential is used and a node that has not joined yet refuses everyone.
//! * **A request** is one message `GET <target>\n[Range: bytes=A-B\n]`; the reply is a head
//!   message of 14 bytes (status u16, first u32, last u32, total u32 big endian; the three are 0
//!   unless the status is 206) and a body message.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const agent_peer = @import("agent_peer.zig");
const constants = @import("constants.zig");
const dir_images = @import("dir_images.zig");
const diag_mod = @import("diag.zig");
const fetch_plan = @import("fetch_plan.zig");
const peer = @import("peer.zig");
const peer_limit = @import("peer_limit.zig");
const peer_serve = @import("peer_serve.zig");
const peer_stream = @import("peer_stream.zig");
const server_listen = @import("server_listen.zig");

const Diag = diag_mod.Diag;

pub const reply_head_bytes = 14;

pub const Config = struct {
    listen: net.IpAddress,
    state_dir: []const u8,
    node: []const u8,
    images_path: []const u8,
    verbose: bool = false,
    /// Test fault (`<state dir>/faults/peer-corrupt`, docs/agent.md): the first byte of every chunk
    /// sent is flipped, so a peer that lies reaches its clients' hash check.
    corrupt_chunks: bool = false,
};

/// What one connection task owns.
const Slot = struct {
    busy: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    images: dir_images.DirImages = undefined,
    scratch: []u8 = &.{},
    refs: []fetch_plan.ChunkRef = &.{},
    fd: std.posix.fd_t = -1,
};

pub const Server = struct {
    io: std.Io,
    config: Config,
    listener: net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    accept_future: ?std.Io.Future(void) = null,
    slots: [constants.peer_connections_max]Slot = @splat(.{}),
    limiter: peer_limit.Limiter = .{},
    /// The last source refused with ZC-E0808 was shown; cleared by the next admitted one.
    refusal_shown: bool = false,

    pub const StartError = error{ Listen, NoThreads, OutOfMemory, Store };

    /// Listens and starts the accept task. `server` must stay where it is until `stop`.
    pub fn start(server: *Server, io: std.Io, config: Config) StartError!void {
        server.* = .{
            .io = io,
            .config = config,
            .listener = server_listen.listen(io, config.listen) catch return error.Listen,
        };
        errdefer server.listener.deinit(io);
        const gpa = std.heap.page_allocator;
        var opened: usize = 0;
        errdefer for (server.slots[0..opened]) |*slot| free_slot(slot, io, gpa);
        for (&server.slots) |*slot| {
            slot.* = .{};
            slot.images = dir_images.DirImages.open(io, gpa, config.images_path) catch
                return error.Store;
            errdefer slot.images.close(gpa);
            slot.scratch = try gpa.alloc(u8, peer_serve.scratch_bytes);
            errdefer gpa.free(slot.scratch);
            slot.refs = try gpa.alloc(fetch_plan.ChunkRef, constants.fetch_chunks_max);
            opened += 1;
        }
        server.accept_future = io.concurrent(accept_loop, .{server}) catch return error.NoThreads;
    }

    /// The port the server listens on (the system's choice if the configuration said 0).
    pub fn port(server: *const Server) u16 {
        return server.listener.socket.address.getPort();
    }

    pub fn stop(server: *Server) void {
        server.stopping.store(true, .release);
        if (server.accept_future) |*future| future.cancel(server.io);
        server.accept_future = null;
        for (&server.slots) |*slot| {
            if (slot.future) |*future| future.await(server.io);
            slot.future = null;
            free_slot(slot, server.io, std.heap.page_allocator);
        }
        server.listener.deinit(server.io);
    }
};

fn free_slot(slot: *Slot, io: std.Io, gpa: std.mem.Allocator) void {
    _ = io;
    slot.images.close(gpa);
    gpa.free(slot.scratch);
    gpa.free(slot.refs);
}

fn accept_loop(server: *Server) void {
    const io = server.io;
    const listen_fd = server.listener.socket.handle;
    while (!server.stopping.load(.acquire)) {
        const events = std.posix.POLL.IN;
        var wait = [_]std.posix.pollfd{.{ .fd = listen_fd, .events = events, .revents = 0 }};
        const ready = std.posix.poll(&wait, 100) catch continue;
        if (ready == 0) continue;
        var storage: std.os.linux.sockaddr.storage = undefined;
        var length: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
        const linux = std.os.linux;
        const got = linux.accept4(listen_fd, @ptrCast(&storage), &length, linux.SOCK.CLOEXEC);
        if (std.os.linux.errno(got) != .SUCCESS) continue;
        const fd: std.posix.fd_t = @intCast(got);
        admit(server, fd, source_of(&storage), io);
    }
}

/// A key for the peer's address, the port left out.
fn source_of(storage: *const std.os.linux.sockaddr.storage) u64 {
    const bytes = std.mem.asBytes(storage);
    const family = std.mem.readInt(u16, bytes[0..2], .little);
    const part = if (family == std.os.linux.AF.INET) bytes[4..8] else bytes[8..24];
    return std.hash.Wyhash.hash(0, part);
}

fn admit(server: *Server, fd: std.posix.fd_t, source: u64, io: std.Io) void {
    const verdict = server.limiter.admit(source, peer_stream.boot_ms(io));
    if (verdict != .admitted) {
        if (!server.refusal_shown) {
            server.refusal_shown = true;
            var diag: Diag = undefined;
            diag.reset();
            diag.raise(.E0808);
            diag.cause("a peer address started more than {d} handshakes in {d} ms", .{
                constants.peer_handshakes_per_source_max, constants.peer_handshake_window_ms,
            });
            diag.fix(.{ .sentence = "no action needed; it is tried again by itself" });
            show(io, &diag, server.config.verbose);
        }
        _ = std.os.linux.close(fd);
        return;
    }
    server.refusal_shown = false;
    for (&server.slots) |*slot| {
        if (slot.busy.load(.acquire)) continue;
        if (slot.future) |*future| future.await(io);
        slot.future = null;
        slot.fd = fd;
        slot.busy.store(true, .release);
        slot.future = io.concurrent(serve, .{ server, slot }) catch {
            slot.busy.store(false, .release);
            _ = std.os.linux.close(fd);
            return;
        };
        return;
    }
    _ = std.os.linux.close(fd); // Every slot is busy: the peer tries another source.
}

fn show(io: std.Io, diag: *const Diag, verbose: bool) void {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: @import("zigbox").render.Mode = if (verbose) .verbose else .text;
    const text = diag_mod.render(&diagnostic, mode, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
}

fn serve(server: *Server, slot: *Slot) void {
    const io = server.io;
    defer {
        _ = std.os.linux.close(slot.fd);
        slot.busy.store(false, .release);
    }
    var diag: Diag = undefined;
    diag.reset();
    const identity_found = agent_peer.load_identity(
        io,
        server.config.state_dir,
        server.config.node,
        &diag,
    ) catch {
        show(io, &diag, server.config.verbose);
        return;
    };
    var identity = identity_found orelse return; // Not joined yet: nobody is served.
    defer identity.deinit();
    const handshake_end = peer_stream.boot_ms(io) + constants.peer_handshake_ms;
    var stream = peer_stream.open_server(io, slot.fd, &identity, handshake_end) catch |err| {
        switch (err) {
            error.Closed, error.Timeout, error.Io, error.TooBig => {},
            else => |refusal| {
                peer.raise(&diag, refusal, "a connecting peer");
                show(io, &diag, server.config.verbose);
            },
        }
        return;
    };
    defer stream.deinit();
    var count: u32 = 0;
    while (count < constants.peer_connection_requests_max) : (count += 1) {
        if (server.stopping.load(.acquire)) return;
        if (!one_request(&stream, slot, server.config.corrupt_chunks)) return;
    }
}

/// Reads one request and answers it. False when the connection should end.
fn one_request(stream: *peer_stream.Stream, slot: *Slot, corrupt_chunks: bool) bool {
    var request: [1024]u8 = undefined;
    const io = stream.io;
    const text = stream.recv(&request, peer_stream.boot_ms(io) + constants.peer_idle_ms) catch
        return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return false;
    const space = std.mem.indexOfScalar(u8, first, ' ') orelse return false;
    var range: ?[]const u8 = null;
    while (lines.next()) |line| {
        const prefix = "Range: ";
        if (std.mem.startsWith(u8, line, prefix)) range = line[prefix.len..];
    }
    const reply = peer_serve.answer(
        slot.images.images(),
        first[0..space],
        first[space + 1 ..],
        range,
        slot.scratch,
        slot.refs,
    );
    const is_chunk = std.mem.startsWith(u8, first[space + 1 ..], peer_serve.path_chunk);
    if (corrupt_chunks and is_chunk and reply.status == 200 and reply.body.len > 0) {
        @constCast(reply.body)[0] ^= 0xff; // The body is the slot's own scratch (`chunk`).
    }
    var head: [reply_head_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, head[0..2], reply.status, .big);
    if (reply.range) |span| {
        std.mem.writeInt(u32, head[2..6], span.first, .big);
        std.mem.writeInt(u32, head[6..10], span.last, .big);
        std.mem.writeInt(u32, head[10..14], span.total, .big);
    }
    const end = peer_stream.boot_ms(io) + constants.peer_reply_ms;
    stream.send(&head, end) catch return false;
    stream.send(reply.body, end) catch return false;
    return true;
}

// ---- Tests --------------------------------------------------------------------------------

const Ed25519 = std.crypto.sign.Ed25519;
const chunk_path = peer_serve.path_chunk;
const trees_path = peer_serve.path_trees;

fn issue(ca: Ed25519.KeyPair, name: []const u8, key: [32]u8, now: u64) peer.Credential {
    return peer.issue(ca, name, key, now - 1000, now + 100_000);
}

const Rig = struct {
    tmp: std.testing.TmpDir,
    state_buffer: [std.fs.max_path_bytes]u8 = undefined,
    state_len: u32 = 0,
    images_buffer: [std.fs.max_path_bytes]u8 = undefined,
    images_len: u32 = 0,
    ca: Ed25519.KeyPair,
    hash: [32]u8 = undefined,
    body: [40]u8 = @splat(0x5a),
    digest: [67]u8 = undefined,
    list: [80]u8 = undefined,
    list_len: u32 = 0,
    server: Server = undefined,

    fn state(rig: *const Rig) []const u8 {
        return rig.state_buffer[0..rig.state_len];
    }

    fn init(rig: *Rig) !void {
        const io = std.testing.io;
        rig.tmp = std.testing.tmpDir(.{});
        rig.ca = try Ed25519.KeyPair.generateDeterministic(@splat(1));
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try rig.tmp.dir.realPath(io, &root_buffer)];
        const made = try std.fmt.bufPrint(&rig.state_buffer, "{s}/state", .{root});
        rig.state_len = @intCast(made.len);
        const images = try std.fmt.bufPrint(&rig.images_buffer, "{s}/images", .{root});
        rig.images_len = @intCast(images.len);
        var diag: Diag = undefined;
        diag.reset();
        var opened = try agent_peer.Peer.open(io, rig.state(), "node2", &diag);
        defer opened.close();
        const now = peer_stream.wall_ms(io);
        opened.credential = issue(rig.ca, "node2", opened.key.public_key.toBytes(), now);
        opened.ca_public = rig.ca.public_key.toBytes();
        try opened.store(&diag);
        var store = try dir_images.DirImages.open(io, std.testing.allocator, images);
        defer store.close(std.testing.allocator);
        std.crypto.hash.Blake3.hash(&rig.body, &rig.hash, .{});
        const text = try std.fmt.bufPrint(&rig.list, "{x} 40\n", .{&rig.hash});
        rig.list_len = @intCast(text.len);
        _ = @import("node_store.zig").list_digest(text, &rig.digest);
        try store.put_tree(&rig.digest, text);
        try store.images().put_chunk(&rig.hash, &rig.body);
        try rig.server.start(io, .{
            .listen = try net.IpAddress.parse("127.0.0.1", 0),
            .state_dir = rig.state(),
            .node = "node2",
            .images_path = images,
        });
    }

    fn deinit(rig: *Rig) void {
        rig.server.stop();
        rig.tmp.cleanup();
    }
};

test "a peer of the cluster is served a chunk and a tree, and a stranger is not" {
    // Goal: the peer server answers authenticated peers from the node's images and nobody else.
    // Method: a real listener on loopback; a client of the same CA fetches a chunk (200), a
    // missing one (404) and the tree list; a client of another CA is refused in the handshake.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const end = peer_stream.boot_ms(io) + 5000;
    const fd = try peer_stream.connect(io, address, end);
    defer _ = std.os.linux.close(fd);
    var stream = try peer_stream.open_client(io, fd, &identity, "node2", end);
    defer stream.deinit();
    var target: [128]u8 = undefined;
    var reply: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &rig.hash });
    try stream.send(path, end);
    const head = try stream.recv(&reply, end);
    try std.testing.expectEqual(@as(usize, reply_head_bytes), head.len);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, head[0..2], .big));
    const body = try stream.recv(&reply, end);
    try std.testing.expectEqualSlices(u8, &rig.body, body);
    const tree = try std.fmt.bufPrint(&target, "GET {s}{s}\n", .{ trees_path, &rig.digest });
    try stream.send(tree, end);
    _ = try stream.recv(&reply, end);
    try std.testing.expectEqualSlices(u8, rig.list[0..rig.list_len], try stream.recv(&reply, end));
    const missing = try std.fmt.bufPrint(&target, "GET {s}{s}\n", .{ trees_path, "b3:12345678" });
    try stream.send(missing, end);
    const gone = try stream.recv(&reply, end);
    try std.testing.expectEqual(@as(u16, 404), std.mem.readInt(u16, gone[0..2], .big));

    const other_ca = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    identity.credential = issue(other_ca, "node1", key.public_key.toBytes(), now);
    identity.ca_public = other_ca.public_key.toBytes();
    const stranger_fd = try peer_stream.connect(io, address, end);
    defer _ = std.os.linux.close(stranger_fd);
    if (peer_stream.open_client(io, stranger_fd, &identity, "node2", end)) |opened| {
        var kept = opened;
        defer kept.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "a chunk of the largest size is served whole" {
    // Goal: every chunk but a file's last is swarm_chunk_bytes; the server must answer it 200.
    // Method: store such a chunk next to the rig's tree, ask for it through a real connection.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const big = try gpa.alloc(u8, constants.swarm_chunk_bytes);
    defer gpa.free(big);
    for (big, 0..) |*byte, at| byte.* = @truncate(at *% 13);
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(big, &hash, .{});
    {
        var store = try dir_images.DirImages.open(io, gpa, rig.images_buffer[0..rig.images_len]);
        defer store.close(gpa);
        try store.images().put_chunk(&hash, big);
    }
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const end = peer_stream.boot_ms(io) + 10_000;
    const fd = try peer_stream.connect(io, address, end);
    defer _ = std.os.linux.close(fd);
    var stream = try peer_stream.open_client(io, fd, &identity, "node2", end);
    defer stream.deinit();
    var target: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &hash });
    try stream.send(path, end);
    const reply = try gpa.alloc(u8, constants.swarm_chunk_bytes + 64);
    defer gpa.free(reply);
    const head = try stream.recv(reply, end);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, head[0..2], .big));
    const body = try stream.recv(reply, end);
    try std.testing.expectEqualSlices(u8, big, body);
}

test "more requests than the handshake limit are served over one stream, a missing one refused" {
    // Goal: the fetch client keeps one stream per peer, so an image of many chunks does not hit
    // `peer_handshakes_per_source_max`, and a non-200 reply is `.refused`, not `.timeout`.
    // Method: ask one peer server for the same chunk 3 * peer_connection_requests_max times (the
    // stream is reopened twice, far under the limit) and then for a chunk it does not hold.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const fetch_cli = @import("fetch_cli.zig");
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const peers = [_]fetch_cli.Peer{.{
        .name = "node2",
        .address = try net.IpAddress.parse("127.0.0.1", rig.server.port()),
    }};
    var reply: [1024]u8 = undefined;
    var conns: [1]fetch_cli.Conn = .{.{}};
    var net_state: fetch_cli.Net = .{
        .io = io,
        .conns = &conns,
        .registry = peers[0].address,
        .peers = &peers,
        .identity = .{
            .key = key,
            .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
            .ca_public = rig.ca.public_key.toBytes(),
        },
        .reply = &reply,
    };
    defer net_state.close_peers();
    var target: [128]u8 = undefined;
    var out: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&target, "{s}{x}", .{ chunk_path, &rig.hash });
    const requests = 3 * constants.peer_connection_requests_max;
    comptime assert(requests > 2 * constants.peer_handshakes_per_source_max);
    for (0..requests) |_| {
        const got = net_state.peer_get(0, path, &out);
        try std.testing.expectEqualSlices(u8, &rig.body, got.bytes);
    }
    const zeros: [64]u8 = @splat('0');
    const absent = try std.fmt.bufPrint(&target, "{s}{s}", .{ chunk_path, &zeros });
    try std.testing.expectEqual(
        fetch_cli.PeerReply.refused,
        net_state.peer_get(0, absent, &out),
    );
}
