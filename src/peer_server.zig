//! The agent's peer server (docs/peer.md, "The peer server"; C2 slice 6b). Shell code: it
//! listens, accepts, runs `peer_stream`'s handshake and answers each request with
//! `peer_serve.answer` from the node's `DirImages`. It is read-only: nothing a peer sends is
//! written anywhere.
//!
//! * **Rate limit.** `peer_limit.Limiter` is asked before a handshake starts (ZC-E0808 when a
//!   source is turned away; the connection is closed without a byte).
//! * **Connections.** Two kinds of slot. A *link* (`peer_handshakes_max` of them) is a task, a
//!   descriptor and a few words: every accepted connection takes one for its handshake, which
//!   ends at `peer_handshake_ms` at the latest, so strangers that send nothing cannot use up
//!   the serving slots. A *slot* (`peer_connections_max`) owns a `DirImages` and buffers (pages
//!   the connection does not touch stay untouched) and goes to a connection only once it has
//!   authenticated; an authenticated peer that finds every slot taken is answered 503 (busy) to
//!   its first request and closed. A connection lives while requests keep coming
//!   (`peer_idle_ms` between them) and for `peer_connection_requests_max` requests, then the
//!   client opens another.
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
const zigbox_fetch = @import("zigbox_fetch.zig");
const peer_stream = @import("peer_stream.zig");
const server_listen = @import("server_listen.zig");

const Diag = diag_mod.Diag;

pub const reply_head_bytes = 14;

pub const Config = struct {
    listen: net.IpAddress,
    state_dir: []const u8,
    node: []const u8,
    images_path: []const u8,
    /// An absolute path to a Zigbox store served instead of `images_path`'s chunk directory.
    zigbox_store: ?[]const u8 = null,
    /// Tests only: the chunk size of the Zigbox store when it is not Zigbox's own (0: its own).
    zigbox_chunk_bytes: u32 = 0,
    verbose: bool = false,
    /// Test fault (`<state dir>/faults/peer-corrupt`, docs/agent.md): the first byte of every chunk
    /// sent is flipped, so a peer that lies reaches its clients' hash check.
    corrupt_chunks: bool = false,
    /// Tests: ZC-E0808 is counted (`Server.refusals_shown`) but not written to stderr.
    quiet: bool = false,
};

/// What a connection task owns from accept to its end; no buffers.
const Link = struct {
    busy: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    fd: std.posix.fd_t = -1,
    /// The source key of the connection (`source_key`), valid while `busy`.
    source: u64 = 0,
    /// When the connection was admitted (`peer_stream.boot_ms`), for evicting the oldest stranger.
    started_ms: u64 = 0,
    /// One atomic state for the fd and who it belongs to; see `LinkState`.
    state: std.atomic.Value(LinkState) = .init(.closed),
};

/// The state of a link's connection. Moves: `closed` to `stranger` (`start_link`); `stranger` to
/// `authenticated` by the link's task, or `stranger` to `evicting` by `evict_oldest`, and
/// whoever loses that compare-and-swap backs off; `evicting` to `evicted` once the evictor has
/// shut the fd down; any open state to `closed` by the link's own task, which alone closes the fd.
const LinkState = enum(u8) {
    closed,
    /// Open, handshake not finished: one source holds one such link (`admit`).
    stranger,
    /// Open, handshake done: never evicted.
    authenticated,
    /// An evictor is calling `shutdown` on the fd.
    evicting,
    /// Shut down by an evictor; the task ends and closes it.
    evicted,
};

/// The buffers of one served connection, lent to a connection once it has authenticated.
const Slot = struct {
    busy: std.atomic.Value(bool) = .init(false),
    images: dir_images.DirImages = undefined,
    /// Set when the server serves a Zigbox store: the slot's own handle on it.
    zigbox: ?*zigbox_fetch.Opened = null,
    scratch: []u8 = &.{},
    refs: []fetch_plan.ChunkRef = &.{},
};

/// ZC-E0808 is shown at most once per `peer_refusal_log_ms`, whichever source is refused and
/// whatever other handshakes are admitted meanwhile.
pub const RefusalLog = struct {
    last_ms: ?u64 = null,

    pub fn due(log: *RefusalLog, now_ms: u64) bool {
        if (log.last_ms) |last| {
            if (now_ms -| last < constants.peer_refusal_log_ms) return false;
        }
        log.last_ms = now_ms;
        return true;
    }
};

pub const Server = struct {
    io: std.Io,
    config: Config,
    listener: net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    accept_future: ?std.Io.Future(void) = null,
    links: [constants.peer_handshakes_max]Link = @splat(.{}),
    slots: [constants.peer_connections_max]Slot = @splat(.{}),
    limiter: peer_limit.Limiter = .{},
    refusal_log: RefusalLog = .{},
    /// How many times ZC-E0808 was shown, for tests.
    refusals_shown: u32 = 0,
    /// Strangers shut down to make room for a newcomer (`evict_oldest`).
    evictions: std.atomic.Value(u32) = .init(0),

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
            if (config.zigbox_store) |root| {
                const handle = try gpa.create(zigbox_fetch.Opened);
                errdefer gpa.destroy(handle);
                handle.* = .{ .chunk_bytes = config.zigbox_chunk_bytes };
                handle.open(gpa, root) catch |err| return switch (err) {
                    error.NoStore => error.Store,
                    error.OutOfMemory => error.OutOfMemory,
                };
                slot.zigbox = handle;
            }
            errdefer if (slot.zigbox) |handle| {
                handle.close();
                gpa.destroy(handle);
            };
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
        for (&server.links) |*link| {
            if (link.future) |*future| future.await(server.io);
            link.future = null;
        }
        for (&server.slots) |*slot| free_slot(slot, server.io, std.heap.page_allocator);
        server.listener.deinit(server.io);
    }
};

fn free_slot(slot: *Slot, io: std.Io, gpa: std.mem.Allocator) void {
    _ = io;
    slot.images.close(gpa);
    if (slot.zigbox) |opened| {
        opened.close();
        gpa.destroy(opened);
    }
    gpa.free(slot.scratch);
    gpa.free(slot.refs);
}

const accept_poll_ms = 100;

fn accept_loop(server: *Server) void {
    const io = server.io;
    const listen_fd = server.listener.socket.handle;
    while (!server.stopping.load(.acquire)) {
        const events = std.posix.POLL.IN;
        var wait = [_]std.posix.pollfd{.{ .fd = listen_fd, .events = events, .revents = 0 }};
        const ready = std.posix.poll(&wait, accept_poll_ms) catch continue;
        if (ready == 0) continue;
        var storage: std.os.linux.sockaddr.storage = undefined;
        var length: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
        const linux = std.os.linux;
        const got = linux.accept4(listen_fd, @ptrCast(&storage), &length, linux.SOCK.CLOEXEC);
        switch (std.os.linux.errno(got)) {
            .SUCCESS => {},
            .AGAIN, .INTR => continue,
            // EMFILE, ENFILE, ENOMEM...: the connection stays queued and the listener stays
            // readable, so retrying at once would spin. Wait a poll period.
            else => {
                io.sleep(.fromMilliseconds(accept_poll_ms), .awake) catch {};
                continue;
            },
        }
        const fd: std.posix.fd_t = @intCast(got);
        admit(server, fd, &storage, io);
    }
}

const Storage = std.os.linux.sockaddr.storage;

/// The address bytes of a peer: 4 (IPv4) or 16 (IPv6).
fn address_bytes(storage: *const Storage) []const u8 {
    const bytes = std.mem.asBytes(storage);
    const family = std.mem.readInt(u16, bytes[0..2], .little);
    if (family == std.os.linux.AF.INET) return bytes[4..8];
    return bytes[8..24];
}

/// A key for the peer's address, the port left out.
fn source_of(storage: *const Storage) u64 {
    return source_key(address_bytes(storage));
}

/// The address a refusal names: an IPv4 address (a mapped one as the IPv4 it carries) as
/// dotted decimal, an IPv6 one as its /64, the unit it is counted in.
pub fn source_text(buffer: *[64]u8, storage: *const Storage) []const u8 {
    var bytes = address_bytes(storage);
    const zeros: [10]u8 = @splat(0);
    if (bytes.len == 16 and std.mem.eql(u8, bytes[0..10], &zeros) and
        bytes[10] == 0xff and bytes[11] == 0xff) bytes = bytes[12..16];
    // 64 bytes hold either form, so the prints cannot fail.
    if (bytes.len == 4) {
        const form = "{d}.{d}.{d}.{d}";
        return std.fmt.bufPrint(buffer, form, .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch
            unreachable;
    }
    var group: [4]u16 = undefined;
    for (&group, 0..) |*each, at| each.* = std.mem.readInt(u16, bytes[at * 2 ..][0..2], .big);
    return std.fmt.bufPrint(buffer, "{x}:{x}:{x}:{x}::/64", .{
        group[0], group[1], group[2], group[3],
    }) catch unreachable; // At most 4 groups of 4 digits and the suffix fit `buffer`.
}

/// The key of an address of 4 bytes (IPv4) or 16 (IPv6). An IPv6 address is keyed by its /64,
/// because one host holds a whole /64 and each of its addresses would otherwise be a new source;
/// an IPv4-mapped address (`::ffff:a.b.c.d`) is the IPv4 address it carries.
pub fn source_key(address: []const u8) u64 {
    const sized = address.len == 4 or address.len == 16;
    assert(sized);
    if (address.len == 4) return std.hash.Wyhash.hash(0, address);
    const zeros: [10]u8 = @splat(0);
    if (std.mem.eql(u8, address[0..10], &zeros)) {
        if (address[10] == 0xff) {
            if (address[11] == 0xff) return source_key(address[12..16]);
        }
    }
    return std.hash.Wyhash.hash(1, address[0..8]);
}

fn admit(server: *Server, fd: std.posix.fd_t, storage: *const Storage, io: std.Io) void {
    const source = source_of(storage);
    if (handshake_pending(server, source)) {
        // One unauthenticated connection per source: a stranger that sends nothing cannot take
        // the links one by one. The refused peer connects again by itself (its handshake, at the
        // longest `peer_handshake_ms` from now, has ended by then). Not counted by the limiter.
        refuse(server, io, storage, "already has a handshake that has not finished");
        _ = std.os.linux.close(fd);
        return;
    }
    const verdict = server.limiter.admit(source, peer_stream.boot_ms(io));
    if (verdict != .admitted) {
        refuse(server, io, storage, switch (verdict) {
            .table_full => "was turned away: the server tracks as many peer addresses as it keeps",
            else => "started more handshakes than a window allows",
        });
        _ = std.os.linux.close(fd);
        return;
    }
    for (&server.links) |*link| {
        if (link.busy.load(.acquire)) continue;
        return start_link(server, link, fd, source, io);
    }
    // Every link is taken. Silent strangers must not lock honest peers out: the oldest stranger
    // that is old enough (`peer_handshake_evict_min_ms`) is shut down, its task ends and frees
    // the link the usual way, and the newcomer takes it.
    if (evict_oldest(server, io)) |link| return start_link(server, link, fd, source, io);
    // None can be evicted (all authenticated or too young): the peer tries again.
    _ = std.os.linux.close(fd);
}

fn start_link(server: *Server, link: *Link, fd: std.posix.fd_t, source: u64, io: std.Io) void {
    assert(!link.busy.load(.acquire));
    if (link.future) |*future| future.await(io);
    link.future = null;
    link.fd = fd;
    link.source = source;
    link.started_ms = peer_stream.boot_ms(io);
    link.state.store(.stranger, .release);
    link.busy.store(true, .release);
    link.future = io.concurrent(serve, .{ server, link }) catch {
        link.state.store(.closed, .release);
        link.busy.store(false, .release);
        _ = std.os.linux.close(fd);
        return;
    };
}

/// How long `evict_oldest` waits for the shut-down task to free its link.
const evict_wait_ms = 500;

/// Shuts down the oldest stranger that is at least `peer_handshake_evict_min_ms` old and returns
/// its link once free. Null when every link is authenticated or too young to evict, or the task
/// did not end in time. An authenticated link is never touched: the state moves from `stranger`
/// only by compare-and-swap, so a link whose task has just authenticated is passed over.
fn evict_oldest(server: *Server, io: std.Io) ?*Link {
    const now = peer_stream.boot_ms(io);
    var attempts: u32 = 0;
    while (attempts < constants.peer_handshakes_max) : (attempts += 1) {
        var oldest: ?*Link = null;
        for (&server.links) |*link| {
            if (!link.busy.load(.acquire)) return link; // Freed meanwhile.
            if (link.state.load(.acquire) != .stranger) continue;
            if (now -| link.started_ms < constants.peer_handshake_evict_min_ms) continue;
            if (oldest) |best| {
                if (link.started_ms >= best.started_ms) continue;
            }
            oldest = link;
        }
        const link = oldest orelse return null;
        const won = link.state.cmpxchgStrong(.stranger, .evicting, .acq_rel, .acquire);
        if (won != null) continue; // It authenticated or ended first: look again.
        _ = std.os.linux.shutdown(link.fd, std.os.linux.SHUT.RDWR);
        link.state.store(.evicted, .release);
        _ = server.evictions.fetchAdd(1, .monotonic);
        const deadline = peer_stream.boot_ms(io) + evict_wait_ms;
        while (link.busy.load(.acquire)) {
            if (peer_stream.boot_ms(io) >= deadline) return null;
            io.sleep(.fromMilliseconds(1), .awake) catch return null;
        }
        return link;
    }
    return null;
}

/// Closes the link's fd once, after any evictor has finished with it.
fn close_link_fd(link: *Link) void {
    while (true) {
        const seen = link.state.load(.acquire);
        switch (seen) {
            .closed => return,
            .evicting => std.atomic.spinLoopHint(),
            .stranger, .authenticated, .evicted => {
                if (link.state.cmpxchgWeak(seen, .closed, .acq_rel, .acquire) == null) break;
            },
        }
    }
    _ = std.os.linux.close(link.fd);
}

/// Whether a connection of `source` is still in its handshake in some link.
fn handshake_pending(server: *Server, source: u64) bool {
    for (&server.links) |*link| {
        if (!link.busy.load(.acquire)) continue;
        if (link.source != source) continue;
        const state = link.state.load(.acquire);
        if (state != .authenticated and state != .closed) return true;
    }
    return false;
}

/// A slot for an authenticated connection, or null when every one is serving.
fn claim_slot(server: *Server) ?*Slot {
    for (&server.slots) |*slot| {
        if (slot.busy.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) return slot;
    }
    return null;
}

/// Shows ZC-E0808, naming the refused address, at most once per `peer_refusal_log_ms`.
fn refuse(server: *Server, io: std.Io, storage: *const Storage, why: []const u8) void {
    if (!server.refusal_log.due(peer_stream.boot_ms(io))) return;
    server.refusals_shown += 1;
    var text_buffer: [64]u8 = undefined;
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0808);
    diag.cause("peer address {s} {s}", .{ source_text(&text_buffer, storage), why });
    diag.fix(.{ .sentence = "no action needed; it is tried again by itself" });
    if (!server.config.quiet) show(io, &diag, server.config.verbose);
}

fn show(io: std.Io, diag: *const Diag, verbose: bool) void {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: @import("zigbox").render.Mode = if (verbose) .verbose else .text;
    const text = diag_mod.render(&diagnostic, mode, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
}

fn serve(server: *Server, link: *Link) void {
    const io = server.io;
    defer {
        close_link_fd(link);
        link.busy.store(false, .release);
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
    var stream = peer_stream.open_server(io, link.fd, &identity, handshake_end) catch |err| {
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
    // Lost to an evictor: the link is being shut down, so end (the fd is closed below).
    if (link.state.cmpxchgStrong(.stranger, .authenticated, .acq_rel, .acquire) != null) return;
    const slot = claim_slot(server) orelse return tell_busy(&stream);
    defer slot.busy.store(false, .release);
    var count: u32 = 0;
    while (count < constants.peer_connection_requests_max) : (count += 1) {
        if (server.stopping.load(.acquire)) return;
        if (!one_request(&stream, slot, server.config.corrupt_chunks)) return;
    }
}

/// Every serving slot is taken: answers the authenticated peer's first request with 503 (an
/// empty body) so that it knows the server is busy rather than gone, and ends the connection.
fn tell_busy(stream: *peer_stream.Stream) void {
    var request: [1024]u8 = undefined;
    const io = stream.io;
    _ = stream.recv(&request, peer_stream.boot_ms(io) + constants.peer_idle_ms) catch return;
    var head: [reply_head_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, head[0..2], peer_serve.status_busy, .big);
    const end = peer_stream.boot_ms(io) + constants.peer_reply_ms;
    stream.send(&head, end) catch return;
    stream.send("", end) catch return;
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
    const target = first[space + 1 ..];
    // A bundle can be megabytes: its buffer is mapped for this request alone (untouched pages
    // cost nothing) and the reply is sent before it is unmapped.
    const wants_bundle = std.mem.startsWith(u8, target, peer_serve.path_bundle);
    const gpa = std.heap.page_allocator;
    const bundle_buffer: []u8 = if (wants_bundle and slot.zigbox != null)
        gpa.alloc(u8, zigbox_fetch.bundle_bytes_max) catch &.{}
    else
        &.{};
    defer if (bundle_buffer.len > 0) gpa.free(bundle_buffer);
    const seam = if (slot.zigbox) |opened|
        zigbox_fetch.serving(&opened.images)
    else
        slot.images.images();
    const reply = peer_serve.answer(
        seam,
        first[0..space],
        target,
        range,
        slot.scratch,
        slot.refs,
        bundle_buffer,
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
    /// A Zigbox store served beside the chunk directory (bundles), and whether chunks are
    /// corrupted on the way out.
    zigbox_root: ?[]const u8 = null,
    corrupt: bool = false,
    /// Serve through the agent's own wiring (`agent_run.Swarm`), configured for Zigbox only: no
    /// `images_dir`, the store named by `zigbox_root`.
    via_agent: bool = false,
    swarm: agent_run.Swarm = .{},

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
        if (rig.via_agent) {
            const config: agent_config.Config = .{
                .runtime = .zigbox,
                .pulls = &.{},
                .node = "node2",
                .server = try net.IpAddress.parse("127.0.0.1", 1),
                .state_dir = rig.state(),
                .images = &.{},
                .capacity = .{ .cpu_millis = 1, .memory_bytes = 1 },
                .address = "",
                .verbose = false,
                .peer_listen = try net.IpAddress.parse("127.0.0.1", 0),
                .peer_advertise = try net.IpAddress.parse("127.0.0.1", 1),
            };
            rig.swarm.chunk_bytes_test = 8;
            try rig.swarm.start_with(io, std.testing.allocator, config, rig.zigbox_root);
            return;
        }
        try rig.server.start(io, .{
            .listen = try net.IpAddress.parse("127.0.0.1", 0),
            .state_dir = rig.state(),
            .node = "node2",
            .images_path = images,
            .zigbox_store = rig.zigbox_root,
            .zigbox_chunk_bytes = if (rig.zigbox_root != null) 8 else 0,
            .corrupt_chunks = rig.corrupt,
            .quiet = true,
        });
    }

    fn port(rig: *const Rig) u16 {
        return if (rig.via_agent) rig.swarm.server.?.port() else rig.server.port();
    }

    fn deinit(rig: *Rig) void {
        if (rig.via_agent) rig.swarm.stop(std.testing.allocator) else rig.server.stop();
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
    // A tree under its short name is not served (400); a full digest that is not held is 404.
    const short = try std.fmt.bufPrint(&target, "GET {s}{s}\n", .{ trees_path, "b3:12345678" });
    try stream.send(short, end);
    const refused_short = try stream.recv(&reply, end);
    try std.testing.expectEqual(@as(u16, 400), std.mem.readInt(u16, refused_short[0..2], .big));
    _ = try stream.recv(&reply, end); // Its body.
    const zeros: [64]u8 = @splat('0');
    const absent = try std.fmt.bufPrint(&target, "GET {s}b3:{s}\n", .{ trees_path, &zeros });
    try stream.send(absent, end);
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

test "four silent connections from one source hold one slot, and an honest peer is served" {
    // Goal: a source that connects and sends nothing cannot take the connection slots from
    // everyone (review M2). Method: four raw connections that never send; only one is admitted
    // (the rest are closed at accept, so the slots are not all taken); an honest client of the
    // same source, which on loopback is every client, is served once the silent handshake has
    // timed out, retrying meanwhile.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    var silent: [4]std.posix.fd_t = undefined;
    for (&silent) |*fd| fd.* = try peer_stream.connect(io, address, peer_stream.boot_ms(io) + 5000);
    defer for (silent) |fd| {
        _ = std.os.linux.close(fd);
    };
    try io.sleep(.fromMilliseconds(200), .awake);
    var busy: u32 = 0;
    for (&rig.server.links) |*link| {
        if (link.busy.load(.acquire)) busy += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), busy);
    // Three refused connections are one streak: ZC-E0808 was shown once, not three times.
    try std.testing.expectEqual(@as(u32, 1), rig.server.refusals_shown);

    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const give_up = peer_stream.boot_ms(io) + constants.peer_handshake_ms + 3000;
    while (peer_stream.boot_ms(io) < give_up) {
        const end = peer_stream.boot_ms(io) + 2000;
        const fd = peer_stream.connect(io, address, end) catch continue;
        defer _ = std.os.linux.close(fd);
        var stream = peer_stream.open_client(io, fd, &identity, "node2", end) catch {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        };
        defer stream.deinit();
        var target: [128]u8 = undefined;
        var reply: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &rig.hash });
        try stream.send(path, end);
        const head = try stream.recv(&reply, end);
        try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, head[0..2], .big));
        return;
    }
    return error.NeverServed;
}

test "a busy peer is asked again a few times, then refused, and is never a timeout" {
    // Goal: review S3. Method: every serving slot taken; the client's `peer_get` sees 503 each
    // time, retries `fetch_busy_retries_max` times and answers `.refused` (a timeout would be a
    // strike), having seen busy once more than it retried.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    for (&rig.server.slots) |*slot| slot.busy.store(true, .release);
    defer for (&rig.server.slots) |*slot| slot.busy.store(false, .release);
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
    try std.testing.expectEqual(fetch_cli.PeerReply.refused, net_state.peer_get(0, path, &out));
    try std.testing.expectEqual(constants.fetch_busy_retries_max + 1, net_state.busy_seen);
}

/// A connection to `address` from the loopback address 127.0.0.`octet`, a source of its own.
fn connect_from(io: std.Io, octet: u8, address: net.IpAddress) !std.posix.fd_t {
    const linux = std.os.linux;
    const opened = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Io;
    const fd: std.posix.fd_t = @intCast(opened);
    errdefer _ = linux.close(fd);
    var text: [16]u8 = undefined;
    const from = try net.IpAddress.parse(try std.fmt.bufPrint(&text, "127.0.0.{d}", .{octet}), 0);
    var from_storage: std.Io.Threaded.PosixAddress = undefined;
    const from_length = std.Io.Threaded.addressToPosix(&from, &from_storage);
    if (linux.errno(linux.bind(fd, &from_storage.any, from_length)) != .SUCCESS) return error.Io;
    var to_storage: std.Io.Threaded.PosixAddress = undefined;
    const to_length = std.Io.Threaded.addressToPosix(&address, &to_storage);
    if (linux.errno(linux.connect(fd, &to_storage.any, to_length)) != .SUCCESS) return error.Io;
    _ = io;
    return fd;
}

test "silent connections from more sources than there are serving slots do not lock out a peer" {
    // Goal: review M1. Method: twice `peer_connections_max` silent connections, each from a
    // source of its own (127.0.0.2 and up); an honest peer (127.0.0.1) is served at once.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    var silent: [2 * constants.peer_connections_max]std.posix.fd_t = undefined;
    for (&silent, 0..) |*fd, at| fd.* = try connect_from(io, @intCast(2 + at), address);
    defer for (silent) |fd| {
        _ = std.os.linux.close(fd);
    };
    try wait_busy(io, &rig.server, silent.len);
    try expect_served(&rig, address);
}

fn busy_links(server: *const Server) u32 {
    var busy: u32 = 0;
    for (&server.links) |*link| {
        if (link.busy.load(.acquire)) busy += 1;
    }
    return busy;
}

/// An honest client (127.0.0.1) handshakes and fetches the rig's chunk.
fn expect_served(rig: *Rig, address: net.IpAddress) !void {
    const io = std.testing.io;
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const end = peer_stream.boot_ms(io) + 3000;
    const fd = try peer_stream.connect(io, address, end);
    defer _ = std.os.linux.close(fd);
    var stream = try peer_stream.open_client(io, fd, &identity, "node2", end);
    defer stream.deinit();
    var target: [128]u8 = undefined;
    var reply: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &rig.hash });
    try stream.send(path, end);
    const head = try stream.recv(&reply, end);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, head[0..2], .big));
}

/// Polls until `want` links are busy, up to a deadline.
fn wait_busy(io: std.Io, server: *const Server, want: u32) !void {
    const deadline = peer_stream.boot_ms(io) + 5000;
    while (busy_links(server) != want) {
        if (peer_stream.boot_ms(io) >= deadline) return error.LinksNeverBusy;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// Sleeps until every connection admitted so far is `peer_handshake_evict_min_ms` old.
fn age_strangers(io: std.Io, since_ms: u64) !void {
    const due = since_ms + constants.peer_handshake_evict_min_ms + 50;
    while (peer_stream.boot_ms(io) < due) try io.sleep(.fromMilliseconds(10), .awake);
}

fn rig_identity(rig: *Rig) !peer.Identity {
    const now = peer_stream.wall_ms(std.testing.io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    return .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
}

/// A client that handshakes from 127.0.0.`octet` and then sits idle.
const Idle = struct {
    fd: std.posix.fd_t,
    stream: peer_stream.Stream,

    fn open(rig: *Rig, octet: u8, address: net.IpAddress) !Idle {
        const io = std.testing.io;
        var identity = try rig_identity(rig);
        const end = peer_stream.boot_ms(io) + 3000;
        const fd = try connect_from(io, octet, address);
        errdefer _ = std.os.linux.close(fd);
        const stream = try peer_stream.open_client(io, fd, &identity, "node2", end);
        return .{ .fd = fd, .stream = stream };
    }

    fn close(idle: *Idle) void {
        idle.stream.deinit();
        _ = std.os.linux.close(idle.fd);
    }

    /// Asks for the rig's chunk and returns the reply status.
    fn request(idle: *Idle, rig: *Rig) !u16 {
        const io = std.testing.io;
        const end = peer_stream.boot_ms(io) + 3000;
        var target: [128]u8 = undefined;
        var reply: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &rig.hash });
        try idle.stream.send(path, end);
        const head = try idle.stream.recv(&reply, end);
        return std.mem.readInt(u16, head[0..2], .big);
    }
};

test "silent connections taking every link do not lock out an honest peer" {
    // Goal: review follow-up 1. Method: `peer_handshakes_max` silent connections, one source
    // each, hold every link and age past the minimum; an honest handshake evicts the oldest
    // stranger and is served.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    var silent: [constants.peer_handshakes_max]std.posix.fd_t = undefined;
    for (&silent, 0..) |*fd, at| fd.* = try connect_from(io, @intCast(2 + at), address);
    defer for (silent) |fd| {
        _ = std.os.linux.close(fd);
    };
    const since = peer_stream.boot_ms(io);
    try wait_busy(io, &rig.server, constants.peer_handshakes_max);
    try age_strangers(io, since);
    try expect_served(&rig, address);
    try std.testing.expectEqual(@as(u32, 1), rig.server.evictions.load(.monotonic));
}

test "authenticated links are never evicted, and a stranger too young to evict is not" {
    // Goal: review S1/S2/S3. Method: two clients handshake and sit idle; the other links are
    // silent strangers. (a) At once, the newcomer finds every stranger too young: it is closed,
    // nothing is evicted. (b) After the minimum age it evicts a stranger and is served, and the
    // two authenticated clients can still make a request.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    var idle: [2]Idle = undefined;
    for (&idle, 0..) |*client, at| client.* = try Idle.open(&rig, @intCast(100 + at), address);
    defer for (&idle) |*client| client.close();
    var silent: [constants.peer_handshakes_max - 2]std.posix.fd_t = undefined;
    for (&silent, 0..) |*fd, at| fd.* = try connect_from(io, @intCast(2 + at), address);
    defer for (silent) |fd| {
        _ = std.os.linux.close(fd);
    };
    const since = peer_stream.boot_ms(io);
    try wait_busy(io, &rig.server, constants.peer_handshakes_max);
    try std.testing.expect(peer_stream.boot_ms(io) - since < constants.peer_handshake_evict_min_ms);
    try std.testing.expect(std.meta.isError(expect_served(&rig, address)));
    try std.testing.expectEqual(@as(u32, 0), rig.server.evictions.load(.monotonic));
    try age_strangers(io, since);
    try expect_served(&rig, address);
    try std.testing.expectEqual(@as(u32, 1), rig.server.evictions.load(.monotonic));
    for (&idle) |*client| try std.testing.expectEqual(@as(u16, 200), try client.request(&rig));
}

test "a newcomer is closed when every link is authenticated" {
    // Goal: review S3. Method: `peer_handshakes_max` clients handshake from sources of their own
    // and sit idle; one more connection is closed without being served, nothing is evicted, and
    // the clients that hold serving slots still get their chunk.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    var idle: [constants.peer_handshakes_max]Idle = undefined;
    for (&idle, 0..) |*client, at| client.* = try Idle.open(&rig, @intCast(2 + at), address);
    defer for (&idle) |*client| client.close();
    try wait_busy(io, &rig.server, constants.peer_handshakes_max);
    try std.testing.expect(std.meta.isError(expect_served(&rig, address)));
    try std.testing.expectEqual(@as(u32, 0), rig.server.evictions.load(.monotonic));
    for (idle[0..constants.peer_connections_max]) |*client| {
        try std.testing.expectEqual(@as(u16, 200), try client.request(&rig));
    }
}

test "an eviction whose task never ends gives up after the wait, and skips an authenticated link" {
    // Goal: review S3, the wait-timeout path, and S1's losing side. Method: every link is made
    // busy by hand with no task behind it: one old stranger on a socket pair, the rest
    // authenticated. The evictor shuts the stranger down, waits `evict_wait_ms` and answers
    // null; with the stranger authenticated too, it answers null at once and touches nothing.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair),
    );
    defer for (pair) |fd| {
        _ = std.os.linux.close(fd);
    };
    const links = &rig.server.links;
    for (links) |*link| {
        link.state.store(.authenticated, .release);
        link.busy.store(true, .release);
    }
    defer for (links) |*link| {
        link.busy.store(false, .release);
        link.state.store(.closed, .release);
    };
    try std.testing.expect(evict_oldest(&rig.server, io) == null);
    try std.testing.expectEqual(@as(u32, 0), rig.server.evictions.load(.monotonic));
    links[7].fd = pair[0];
    links[7].started_ms = 0;
    links[7].state.store(.stranger, .release);
    const before = peer_stream.boot_ms(io);
    try std.testing.expect(evict_oldest(&rig.server, io) == null);
    try std.testing.expect(peer_stream.boot_ms(io) - before >= evict_wait_ms);
    try std.testing.expectEqual(LinkState.evicted, links[7].state.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), rig.server.evictions.load(.monotonic));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(pair[1], &byte, 1));
}

test "an authenticated peer finding every serving slot taken is told busy" {
    // Goal: review M1, the explicit busy reply. Method: take every serving slot by hand.
    const io = std.testing.io;
    var rig: Rig = .{ .tmp = undefined, .ca = undefined };
    try rig.init();
    defer rig.deinit();
    for (&rig.server.slots) |*slot| slot.busy.store(true, .release);
    defer for (&rig.server.slots) |*slot| slot.busy.store(false, .release);
    const address = try net.IpAddress.parse("127.0.0.1", rig.server.port());
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    var identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const end = peer_stream.boot_ms(io) + 3000;
    const fd = try peer_stream.connect(io, address, end);
    defer _ = std.os.linux.close(fd);
    var stream = try peer_stream.open_client(io, fd, &identity, "node2", end);
    defer stream.deinit();
    var target: [128]u8 = undefined;
    var reply: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&target, "GET {s}{x}\n", .{ chunk_path, &rig.hash });
    try stream.send(path, end);
    const head = try stream.recv(&reply, end);
    try std.testing.expectEqual(
        @as(u16, peer_serve.status_busy),
        std.mem.readInt(u16, head[0..2], .big),
    );
}

test "an IPv6 address is a source by its /64, and a mapped IPv4 address by its IPv4 address" {
    // Goal: one host with a /64 is one source (review M2), and mapped addresses are not all one.
    // Method: addresses that differ in the low 64 bits, the high 64 bits, and mapped forms.
    var first: [16]u8 = @splat(0);
    first[0] = 0x20;
    first[1] = 0x01;
    var second = first;
    second[15] = 9;
    try std.testing.expectEqual(source_key(&first), source_key(&second));
    second[7] = 1;
    try std.testing.expect(source_key(&first) != source_key(&second));
    var mapped_one: [16]u8 = @splat(0);
    mapped_one[10] = 0xff;
    mapped_one[11] = 0xff;
    var mapped_two = mapped_one;
    mapped_one[12..16].* = .{ 10, 0, 0, 1 };
    mapped_two[12..16].* = .{ 10, 0, 0, 2 };
    try std.testing.expect(source_key(&mapped_one) != source_key(&mapped_two));
    try std.testing.expectEqual(source_key(&.{ 10, 0, 0, 1 }), source_key(&mapped_one));
}

const images_mod = @import("zigbox_images.zig");
const fetch_client = @import("fetch_cli.zig");
const fetch_worker = @import("fetch_worker.zig");
const zigbox = @import("zigbox");
const agent_run = @import("agent_run.zig");
const agent_config = @import("agent_config.zig");

const Digest = zigbox.store.Digest;
const Manifest = @FieldType(zigbox.store.image_peer.Options, "expected_manifest");

/// A fetch of `tree` for `manifest` from the one peer `rig` serves, over a real peer stream,
/// into `to`. The client is node1 of the rig's CA. The result is the worker's.
fn fetch_from_rig(
    rig: *Rig,
    to: *images_mod.ZigboxImages,
    tree: Digest,
    manifest: Manifest,
) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const now = peer_stream.wall_ms(io);
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const identity: peer.Identity = .{
        .key = key,
        .credential = issue(rig.ca, "node1", key.public_key.toBytes(), now),
        .ca_public = rig.ca.public_key.toBytes(),
    };
    const reply = try gpa.alloc(u8, fetch_client.reply_bytes);
    defer gpa.free(reply);
    const conns = try gpa.alloc(fetch_client.Conn, constants.fetch_candidates_max);
    defer gpa.free(conns);
    @memset(conns, .{});
    const peers = [_]fetch_client.Peer{.{
        .name = "node2",
        .address = try net.IpAddress.parse("127.0.0.1", rig.port()),
    }};
    var text = tree.text();
    var client: fetch_client.Net = .{
        .io = io,
        .registry = null,
        .peers = &peers,
        .identity = identity,
        .reply = reply,
        .digest = &text,
        .conns = conns,
    };
    defer client.close_peers();
    var filter: [64]u8 = @splat(0xff);
    const infos = [_]fetch_worker.PeerInfo{.{ .name = "node2", .filter = &filter }};
    var report: zigbox_fetch.Report = .{};
    try zigbox_fetch.fetch(gpa, client.transport(), to, tree, manifest, &infos, .{}, &report);
}

test "a Zigbox store serves a tree to a fetch into an empty store; a lying peer is refused" {
    // Goal: the bundle path end to end on real stores and a real stream, the tree trusted only
    // against its full digest. Method: store A holds an image; a corrupting peer, a peer asked
    // for another manifest and a peer asked for a tree it lacks all fail and root nothing in B;
    // an honest peer then gives B the tree whole.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    const manifest = Manifest.parse(images_mod.manifest_text).?;
    {
        var from_a = try images_mod.ZigboxImages.open(gpa, &pair.a);
        defer from_a.close();
        var buffer: [2048]u8 = undefined;
        const record = try images_mod.record_text(&buffer, pair.tree, images_mod.manifest_text);
        _ = try from_a.import_image(record, pair.tree, manifest);
    }
    var to_b = try images_mod.ZigboxImages.open(gpa, &pair.b);
    defer to_b.close();
    const name = pair.tree.text();

    var liar: Rig = .{ .tmp = undefined, .ca = undefined, .corrupt = true };
    liar.zigbox_root = pair.a.root_text();
    try liar.init();
    defer liar.deinit();
    const corrupted = fetch_from_rig(&liar, &to_b, pair.tree, manifest);
    try std.testing.expectError(error.ChunkFailed, corrupted);
    try std.testing.expectEqual(@as(usize, 0), rooted_count(&pair.b));

    var honest: Rig = .{ .tmp = undefined, .ca = undefined };
    honest.zigbox_root = pair.a.root_text();
    try honest.init();
    defer honest.deinit();
    // A tree the peer does not hold is not served.
    const absent_hex: [64]u8 = @splat('0');
    const absent = Digest.parse("b3:" ++ &absent_hex).?;
    const unavailable = fetch_from_rig(&honest, &to_b, absent, manifest);
    try std.testing.expectError(error.TreeUnavailable, unavailable);
    try fetch_from_rig(&honest, &to_b, pair.tree, manifest);
    try std.testing.expect(to_b.images().has(&name));
    try std.testing.expectEqual(@as(usize, 1), rooted_count(&pair.b));
}

fn rooted_count(store: *zigbox.store.Store) usize {
    var listing: [8]zigbox.store.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = zigbox.store.roots.list(store, &names, &listing) catch return 999;
    return rooted.count;
}

test "an agent configured for Zigbox only serves its store's tree to a peer fetch" {
    // Goal: demo-c2 needs a node with no --images-dir to serve what it pulled. Method: the agent's
    // own wiring (`Swarm`) with `runtime = .zigbox`, `peer_listen` and no `images_dir` serves
    // store A; a peer fetches the tree into an empty store B, checked against the full digest.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    const manifest = Manifest.parse(images_mod.manifest_text).?;
    var to_b = try images_mod.ZigboxImages.open(gpa, &pair.b);
    defer to_b.close();
    var agent: Rig = .{ .tmp = undefined, .ca = undefined, .via_agent = true };
    agent.zigbox_root = pair.a.root_text();
    try agent.init();
    defer agent.deinit();
    try std.testing.expect(!agent.swarm.has_store);
    // The node's summary comes from the Zigbox store the agent opened: it lists the tree.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const seam = agent.swarm.zigbox.?.images.images();
    {
        var from_a = try images_mod.ZigboxImages.open(gpa, &pair.a);
        defer from_a.close();
        var buffer: [2048]u8 = undefined;
        const record = try images_mod.record_text(&buffer, pair.tree, images_mod.manifest_text);
        _ = try from_a.import_image(record, pair.tree, manifest);
    }
    const held = try seam.summary(arena_state.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 1), held.trees.len);
    const text = pair.tree.text();
    try std.testing.expectEqualStrings(&text, held.trees[0].digest);
    try std.testing.expect(held.filter_chunks > 0);
    try fetch_from_rig(&agent, &to_b, pair.tree, manifest);
    const name = pair.tree.text();
    try std.testing.expect(to_b.images().has(&name));
    try std.testing.expectEqual(@as(usize, 1), rooted_count(&pair.b));
}
