//! `zcube-agent fetch`: gets one image tree into the node's chunk store, from peers first and
//! from the registry (docs/swarm.md, "The fetch worker"; C2 slice 6b). Shell code: sockets.
//!
//!   zcube-agent fetch --node NAME --state-dir DIR --images-dir DIR --digest b3:HEX
//!                     --registry HOST:PORT [--server HOST:PORT] [--peer NAME=HOST:PORT]...
//!
//! The supervisor runs it before the container's command (it is a process of its own, so a
//! fetch that hangs is killed with its supervisor). It is `fetch_worker.fetch` over two
//! sources: the registry, plain HTTP (`GET /trees/<digest>`, `GET /chunks/<64 hex>`), and the
//! peers, over `peer_stream` (`GET /v1/peer/trees/<digest>`, `/v1/peer/chunk/<64 hex>`). Peers
//! are named on the command line; each is assumed to hold every chunk, and the plan strikes
//! one that lies (a hash mismatch) or does not answer. Exit codes: 0 fetched, 1 bad arguments
//! (ZC-E0505), 2 this node failed (disk, memory), 3 no source had the tree (ZC-E0601).
//!
//! With `--zigbox-store` the whole fetch runs in Zigbox's store namespace (`fetch_in_namespace`,
//! C2 slice 8 M3): the process has one thread (a single-threaded Io, checked), and the child
//! `namespace.run` makes does the network and every store write, so the files get the owners
//! Zigbox's own pull gives them. The child's exit code is the command's.

const std = @import("std");
const assert = std.debug.assert;
const agent_config = @import("agent_config.zig");
const agent_peer = @import("agent_peer.zig");
const constants = @import("constants.zig");
const chunk_summary = @import("chunk_summary.zig");
const dir_images = @import("dir_images.zig");
const diag_mod = @import("diag.zig");
const fetch_plan = @import("fetch_plan.zig");
const fetch_worker = @import("fetch_worker.zig");
const peer = @import("peer.zig");
const peer_serve = @import("peer_serve.zig");
const peer_stream = @import("peer_stream.zig");
const records = @import("records.zig");
const store_failures = @import("store_failures.zig");
const zigbox = @import("zigbox");
const zigbox_fetch = @import("zigbox_fetch.zig");
const zigbox_image = @import("zigbox_image.zig");
const pull_report = @import("pull_report.zig");

const Zsha256 = @FieldType(zigbox.store.image_peer.Options, "expected_manifest");
const IpAddress = std.Io.net.IpAddress;
const ChunkRef = fetch_plan.ChunkRef;
const Source = fetch_plan.Source;

pub const Peer = struct { name: []const u8, address: IpAddress };

const reply_head_bytes = 14;

/// Room beside a body in the reply buffer for a registry's HTTP head.
const reply_head_slack_bytes = 4096;

/// The reply buffer's size: the largest legitimate reply, a tree's chunk list
/// (`tree_list_bytes_max`, larger than a chunk) or a chunk, and a head. A reply past it is
/// refused (`Net.oversize`).
pub const reply_bytes: usize = @max(
    @max(constants.swarm_chunk_bytes, constants.tree_list_bytes_max),
    discover_page_bytes_max,
) + reply_head_slack_bytes;

/// The network side of the worker. `list_scratch` holds one reply; `identity` is the node's.
pub const Net = struct {
    io: std.Io,
    /// Null in Zigbox mode with no `--registry`: the peers are the only source.
    registry: ?IpAddress,
    peers: []const Peer,
    identity: ?peer.Identity,
    reply: []u8,
    /// The tree being fetched, for the diagnostics that name it.
    digest: []const u8 = "",
    /// Counts for the log line.
    bad_lists: u32 = 0,
    /// The registry sent a reply larger than `reply_bytes`: refused, and said in ZC-E0601.
    oversize: bool = false,
    /// Zigbox mode: why Zigbox refused the image record a peer sent, if it did.
    refusal: ?zigbox.store.image_peer.Refusal = null,
    /// Zigbox mode: peers whose bundle held up but whose image record was another manifest's.
    other_images: u32 = 0,
    /// Zigbox mode: the tree is larger than one peer fetch takes here.
    too_large: bool = false,
    /// The process environment, which locates the Zigbox store `pull` writes to.
    environ: std.process.Environ = .empty,
    /// Times a peer answered that it was busy (counts for tests and the log line).
    busy_seen: u32 = 0,
    /// The open stream to each peer, by index (one `Conn` per entry of `peers`).
    conns: []Conn = &.{},

    fn from(context: *anyopaque) *Net {
        return @ptrCast(@alignCast(context));
    }

    pub fn transport(net: *Net) fetch_worker.Transport {
        return .{
            .context = net,
            .tree_fn = tree,
            .chunk_fn = chunk,
            .now_fn = now,
            .sleep_fn = sleep,
            .blame_fn = blame,
            .bad_list_fn = bad_list,
            .bundle_fn = bundle,
        };
    }

    /// A peer's bundle of the tree (`zigbox_fetch`), into `out`. Only peers have one.
    fn bundle(context: *anyopaque, source: Source, digest: []const u8, out: []u8) ?[]const u8 {
        const net = from(context);
        const index = switch (source) {
            .registry => return null,
            .peer => |index| index,
        };
        var target: [128]u8 = undefined;
        const prefix = peer_serve.path_bundle;
        const path = std.fmt.bufPrint(&target, "{s}{s}", .{ prefix, digest }) catch return null;
        const reply = net.peer_get(index, path, out);
        if (reply != .bytes) say_bundle_failed(net.io, net.peers[index].name, reply);
        return switch (reply) {
            .bytes => |bytes| bytes,
            .refused, .timeout, .busy => null,
        };
    }

    fn tree(context: *anyopaque, source: Source, digest: []const u8, out: []u8) ?[]const u8 {
        const net = from(context);
        var target: [128]u8 = undefined;
        switch (source) {
            .registry => {
                const path = std.fmt.bufPrint(&target, "/trees/{s}", .{digest}) catch return null;
                const address = net.registry orelse return null;
                return switch (net.http_get(address, path, out)) {
                    .bytes => |bytes| bytes,
                    .refused, .timeout, .busy => null,
                };
            },
            .peer => |index| {
                const prefix = peer_serve.path_trees;
                const path = std.fmt.bufPrint(&target, "{s}{s}", .{ prefix, digest }) catch
                    return null;
                return switch (net.peer_get(index, path, out)) {
                    .bytes => |bytes| bytes,
                    .refused, .timeout, .busy => null,
                };
            },
        }
    }

    fn chunk(context: *anyopaque, source: Source, ref: ChunkRef, out: []u8) fetch_plan.Result {
        const net = from(context);
        var target: [128]u8 = undefined;
        switch (source) {
            .registry => {
                const path = std.fmt.bufPrint(&target, "/chunks/{x}", .{&ref.hash}) catch
                    return .refused;
                const address = net.registry orelse return .refused;
                return switch (net.http_get(address, path, out)) {
                    .bytes => |bytes| .{ .bytes = bytes },
                    .refused => .refused,
                    .timeout, .busy => .timeout,
                };
            },
            .peer => |index| {
                const prefix = peer_serve.path_chunk;
                const path = std.fmt.bufPrint(&target, "{s}{x}", .{ prefix, &ref.hash }) catch
                    return .refused;
                return switch (net.peer_get(index, path, out)) {
                    .bytes => |bytes| .{ .bytes = bytes },
                    .refused, .busy => .refused, // `peer_get` has waited out a busy peer.
                    .timeout => .timeout,
                };
            },
        }
    }

    fn now(context: *anyopaque) u64 {
        return peer_stream.boot_ms(from(context).io);
    }

    fn sleep(context: *anyopaque, ms: u32) void {
        from(context).io.sleep(.fromMilliseconds(ms), .awake) catch {}; // Cancelled: the loop ends.
    }

    fn blame(context: *anyopaque, index: u8, chunk_index: u32, total: u32) void {
        const net = from(context);
        var diag: diag_mod.Diag = undefined;
        diag.reset();
        const struck: fetch_plan.Blame = .{ .peer = index, .chunk = chunk_index };
        fetch_plan.raise_blame(&diag, struck, net.peers[index].name, total);
        emit(net.io, &diag);
    }

    fn bad_list(context: *anyopaque, index: u8) void {
        const net = from(context);
        var diag: diag_mod.Diag = undefined;
        diag.reset();
        fetch_worker.raise_bad_tree(&diag, net.peers[index].name, net.digest);
        emit(net.io, &diag);
    }

    /// The answer to a plain-HTTP `GET path` from `address`, copied into `out`: the body of a
    /// 200, `.refused` for any other status (the source lacks it), `.timeout` for a connection,
    /// a read, a deadline or a body that fails.
    fn http_get(net: *Net, address: IpAddress, path: []const u8, out: []u8) PeerReply {
        const end = peer_stream.boot_ms(net.io) + constants.fetch_request_timeout_ms;
        const fd = peer_stream.connect(net.io, address, end) catch return .timeout;
        defer _ = std.os.linux.close(fd);
        var request: [192]u8 = undefined;
        const form = "GET {s} HTTP/1.0\r\nHost: registry\r\n\r\n";
        const text = std.fmt.bufPrint(&request, form, .{path}) catch return .timeout;
        write_all(net.io, fd, text, end) catch return .timeout;
        const got = read_until_close(net.io, fd, net.reply, end) catch |err| switch (err) {
            error.TooLarge => {
                net.oversize = true;
                return .refused;
            },
            error.Timeout => return .timeout,
        };
        const body = http_body(got) orelse {
            return if (http_status(got) == null) .timeout else .refused;
        };
        if (body.len > out.len) return .timeout;
        @memcpy(out[0..body.len], body);
        return .{ .bytes = out[0..body.len] };
    }

    /// The answer to `GET path` from peer `index`, over that peer's one authenticated stream.
    /// The stream is kept for the whole fetch (the server limits handshakes per source) and
    /// reopened after an error or `peer_connection_requests_max` requests. A non-200 head is
    /// `.refused` (the peer lacks it); a connect, handshake or stream failure is `.timeout`.
    /// One deadline covers both tries of a request. A peer whose server says it is busy (every
    /// serving slot taken, status 503) is asked again after `fetch_busy_sleep_ms`, at most
    /// `fetch_busy_retries_max` times: it is neither a timeout nor a strike. Still busy after
    /// that, the answer is `.refused` and the plan takes the chunk from another source.
    pub fn peer_get(net: *Net, index: u8, path: []const u8, out: []u8) PeerReply {
        var retries: u32 = 0;
        while (true) {
            const reply = net.peer_get_once(index, path, out);
            if (reply != .busy) return reply;
            net.busy_seen += 1;
            if (retries == constants.fetch_busy_retries_max) return .refused;
            retries += 1;
            sleep(net, constants.fetch_busy_sleep_ms);
        }
    }

    fn peer_get_once(net: *Net, index: u8, path: []const u8, out: []u8) PeerReply {
        const conn = &net.conns[index];
        const reused = conn.open;
        if (conn.open and conn.requests >= constants.peer_connection_requests_max) {
            conn.close();
        }
        const end = peer_stream.boot_ms(net.io) + constants.fetch_request_timeout_ms;
        const first = net.peer_try(index, path, out, end);
        if (first != .timeout or !reused) return first;
        return net.peer_try(index, path, out, end); // The stream was idle-closed.
    }

    fn peer_try(net: *Net, index: u8, path: []const u8, out: []u8, end: u64) PeerReply {
        const identity = net.identity orelse return .timeout;
        const conn = &net.conns[index];
        if (!conn.open) {
            const who = net.peers[index];
            const fd = peer_stream.connect(net.io, who.address, end) catch return .timeout;
            conn.stream = peer_stream.open_client(net.io, fd, &identity, who.name, end) catch {
                _ = std.os.linux.close(fd);
                return .timeout;
            };
            conn.fd = fd;
            conn.open = true;
            conn.requests = 0;
        }
        conn.requests += 1;
        var request: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&request, "GET {s}\n", .{path}) catch return .timeout;
        const reply = net.peer_exchange(&conn.stream, text, out, end);
        if (reply == .timeout or reply == .busy) conn.close();
        return reply;
    }

    fn peer_exchange(
        net: *Net,
        stream: *peer_stream.Stream,
        text: []const u8,
        out: []u8,
        end: u64,
    ) PeerReply {
        stream.send(text, end) catch return .timeout;
        const head = stream.recv(net.reply[0..reply_head_bytes], end) catch return .timeout;
        if (head.len != reply_head_bytes) return .timeout;
        const body = stream.recv(out, end) catch return .timeout;
        const status = std.mem.readInt(u16, head[0..2], .big);
        if (status == peer_serve.status_busy) return .busy;
        if (status != 200) return .refused;
        return .{ .bytes = body };
    }

    /// Closes every open peer stream.
    pub fn close_peers(net: *Net) void {
        for (net.conns) |*conn| conn.close();
    }
};

pub const PeerReply = union(enum) { bytes: []const u8, refused, timeout, busy };

/// The line `fetch.log` gets when a peer gave no bundle: who, and what it answered. Not a strike
/// (docs/swarm.md strikes wrong bytes): the fetch asks the next peer.
pub fn bundle_note(buffer: []u8, peer_name: []const u8, reply: PeerReply) []const u8 {
    const what = switch (reply) {
        .bytes => "a bundle",
        .refused => "a status other than 200 (or a reply too large)",
        .timeout => "no reply (connection, read or deadline failure)",
        .busy => "busy until the retries ran out",
    };
    return std.fmt.bufPrint(buffer, "zcube-agent fetch: peer {s} answered the bundle request " ++
        "with {s}; asking the next peer\n", .{ peer_name, what }) catch buffer[0..0];
}

fn say_bundle_failed(io: std.Io, peer_name: []const u8, reply: PeerReply) void {
    var buffer: [256]u8 = undefined;
    const text = bundle_note(&buffer, peer_name, reply);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

/// One peer's open stream and how many requests it has carried.
pub const Conn = struct {
    open: bool = false,
    fd: std.posix.fd_t = -1,
    requests: u32 = 0,
    stream: peer_stream.Stream = undefined,

    fn close(conn: *Conn) void {
        if (!conn.open) return;
        conn.stream.deinit();
        _ = std.os.linux.close(conn.fd);
        conn.* = .{};
    }
};

/// Writes all of `bytes`, waiting for the socket to take them until `end_ms` (`error.Io` after).
fn write_all(io: std.Io, fd: std.posix.fd_t, bytes: []const u8, end_ms: u64) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const now_ms = peer_stream.boot_ms(io);
        if (now_ms >= end_ms) return error.Io;
        var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&wait, @intCast(end_ms - now_ms)) catch return error.Io;
        if (ready == 0) return error.Io;
        const wrote = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (std.os.linux.errno(wrote) != .SUCCESS) return error.Io;
        done += wrote;
    }
}

/// Reads `fd` to its end into `buffer`: `error.TooLarge` if the reply does not fit,
/// `error.Timeout` if the deadline passes or a read fails.
fn read_until_close(
    io: std.Io,
    fd: std.posix.fd_t,
    buffer: []u8,
    end_ms: u64,
) error{ TooLarge, Timeout }![]u8 {
    var filled: usize = 0;
    while (true) {
        const now_ms = peer_stream.boot_ms(io);
        if (now_ms >= end_ms) return error.Timeout;
        var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&wait, @intCast(end_ms - now_ms)) catch return error.Timeout;
        if (ready == 0) return error.Timeout;
        if (filled == buffer.len) return error.TooLarge;
        const got = std.os.linux.read(fd, buffer[filled..].ptr, buffer.len - filled);
        if (std.os.linux.errno(got) != .SUCCESS) return error.Timeout;
        if (got == 0) return buffer[0..filled];
        filled += got;
    }
}

/// The body of a complete `HTTP/1.x 200` reply, or null for any other status.
pub fn http_body(reply: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, reply, "HTTP/1.")) return null;
    const line_end = std.mem.findScalar(u8, reply, '\r') orelse return null;
    const line = reply[0..line_end];
    if (line.len < 12 or !std.mem.eql(u8, line[8..12], " 200")) return null;
    const split = std.mem.find(u8, reply, "\r\n\r\n") orelse return null;
    return reply[split + 4 ..];
}

/// The status of a reply whose status line is complete, or null.
fn http_status(reply: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, reply, "HTTP/1.")) return null;
    const line_end = std.mem.findScalar(u8, reply, '\r') orelse return null;
    if (line_end < 12) return null;
    return std.fmt.parseInt(u16, reply[9..12], 10) catch null;
}

/// Why discovery or the command line left a node out, as counts, for the one log line.
pub const Skipped = struct {
    self_node: u32 = 0,
    bad_name: u32 = 0,
    no_address: u32 = 0,
    no_filter: u32 = 0,
    over_limit: u32 = 0,

    fn total(skipped: Skipped) u32 {
        return skipped.self_node + skipped.bad_name + skipped.no_address + skipped.no_filter +
            skipped.over_limit;
    }
};

/// "left out 3 nodes (2 with no usable peer address, 1 with a bad name)", or empty.
fn describe_skipped(buffer: []u8, skipped: Skipped) []const u8 {
    if (skipped.total() == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    writer.print("zcube-agent fetch: left out {d} nodes (", .{skipped.total()}) catch return "";
    const reasons = [_]struct { count: u32, text: []const u8 }{
        .{ .count = skipped.self_node, .text = "this node" },
        .{ .count = skipped.bad_name, .text = "a name that is not a node name" },
        .{ .count = skipped.no_address, .text = "no usable peer address" },
        .{ .count = skipped.no_filter, .text = "no usable chunk filter" },
        .{ .count = skipped.over_limit, .text = "past the limit of candidates" },
    };
    var first = true;
    for (reasons) |reason| {
        if (reason.count == 0) continue;
        const separator = if (first) "" else ", ";
        writer.print("{s}{d} with {s}", .{ separator, reason.count, reason.text }) catch return "";
        first = false;
    }
    writer.writeAll(")\n") catch return "";
    return writer.buffered();
}

/// The peers the control plane knows from `/node-store/` (`peer` is the address the node's peer
/// server answers on, `filter` its chunk filter), other than `self`, written to `peers` and
/// `infos`; their count. A node with a bad name, no usable address or no usable filter is
/// counted in `skipped` and left out: discovery only ever adds sources, and the registry
/// remains. Strings live in `arena`. The worker ranks the candidates by what they claim.
fn select_candidates(
    arena: std.mem.Allocator,
    stores: []const Kv,
    self: []const u8,
    peers: []Peer,
    infos: []fetch_worker.PeerInfo,
    skipped: *Skipped,
) u32 {
    assert(peers.len == infos.len);
    const prefix = "/node-store/";
    var count: u32 = 0;
    for (stores) |kv| {
        if (!std.mem.startsWith(u8, kv.key, prefix)) continue;
        const name = kv.key[prefix.len..];
        if (records.name_problem(name, constants.node_name_bytes_max) != null) {
            skipped.bad_name += 1;
            continue;
        }
        if (std.mem.eql(u8, name, self)) {
            skipped.self_node += 1;
            continue;
        }
        const address = (string_field(kv.value, "peer") orelse "");
        const parsed = usable_address(address) orelse {
            skipped.no_address += 1;
            continue;
        };
        const filter = decode_filter(arena, kv.value) orelse {
            skipped.no_filter += 1;
            continue;
        };
        if (count == peers.len) {
            skipped.over_limit += 1;
            continue;
        }
        peers[count] = .{ .name = name, .address = parsed };
        infos[count] = .{ .name = name, .filter = filter };
        count += 1;
    }
    return count;
}

const Kv = struct { key: []const u8, value: std.json.Value };

/// One page of a `/v1/list` reply: its `kvs`, the revision it was read at and, if the list was
/// cut, the key to continue after.
const Page = struct {
    kvs: []const Kv,
    revision: u64 = 0,
    @"continue": ?[]const u8 = null,
};

/// The page a `/v1/list` reply holds, or null if the text is over `discover_page_bytes_max` or is
/// not one.
fn parse_page(arena: std.mem.Allocator, text: []const u8) ?Page {
    if (text.len > discover_page_bytes_max) return null;
    // Every string is copied into `arena`: `text` is a reused buffer, and a key or value that
    // pointed into it would change under its reader at the next request (O5's fetcher names did).
    return std.json.parseFromSliceLeaky(Page, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// The `kvs` of a `/v1/list` reply, or null (see `parse_page`).
fn parse_kvs(arena: std.mem.Allocator, text: []const u8) ?[]const Kv {
    const page = parse_page(arena, text) orelse return null;
    return page.kvs;
}

/// Nodes asked for in one page of discovery. A node's record is at most
/// `summary_json_bytes_max` (a full filter and sketches, about 216 KiB) and a listed key adds a
/// few hundred bytes, so a page of this many fits one reply (`api_response_bytes_max`) and one
/// `reply_bytes` buffer; the list is read page by page (`/v1/list`'s `continue`), so the number
/// of nodes is not bound by the size of one reply.
const discover_page_nodes: u32 = 16;
const discover_kv_overhead_bytes = 512;
/// The reply to one page is at most this long.
const discover_page_bytes_max: usize = discover_page_nodes *
    (constants.summary_json_bytes_max + discover_kv_overhead_bytes) + 256;
/// Pages read at most: enough for `fetch_candidates_max` nodes and one more (to count the rest).
const discover_pages_max = (constants.fetch_candidates_max + 1 + discover_page_nodes - 1) /
    discover_page_nodes;

comptime {
    assert(discover_page_bytes_max <= constants.api_response_bytes_max);
    assert(constants.summary_json_bytes_max <= constants.store_value_bytes_max);
    assert(discover_pages_max * discover_page_nodes > constants.fetch_candidates_max);
}

fn string_field(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// The decoded chunk filter in a `/node-store/<node>` value, or null if it has none that fits
/// `chunk_summary.Filter`.
fn decode_filter(arena: std.mem.Allocator, value: std.json.Value) ?[]u8 {
    const hex = string_field(value, "filter") orelse return null;
    const size = hex.len / 2;
    const fits = hex.len % 2 == 0 and size >= 8 and size <= constants.summary_filter_bytes_max;
    if (!fits) return null;
    const bytes = arena.alloc(u8, size) catch return null;
    _ = std.fmt.hexToBytes(bytes, hex) catch return null;
    return bytes;
}

/// "node2, node3 and the registry", or "the registry" when there are no peers; without a
/// registry, "node2 and node3" or "no peer".
fn tried_sources(buffer: []u8, peers: []const Peer, registry: bool) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (peers, 0..) |who, at| {
        writer.print("{s}{s}", .{ if (at == 0) "" else ", ", who.name }) catch break;
    }
    if (registry) {
        writer.writeAll(if (peers.len > 0) " and the registry" else "the registry") catch {};
    } else if (peers.len == 0) {
        writer.writeAll("no peer, and no registry is given") catch {};
    }
    return writer.buffered();
}

/// Prints `diag` on stderr as text; there is nowhere else to say it.
fn emit(io: std.Io, diag: *const diag_mod.Diag) void {
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .text, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

// ---- The command ----------------------------------------------------------------------------

pub const Args = struct {
    node: []const u8 = "",
    state_dir: []const u8 = "",
    images_dir: []const u8 = "",
    digest: []const u8 = "",
    /// Zigbox mode: the absolute root of the node's Zigbox store (instead of `images_dir`) and
    /// the manifest of the assignment's digest-pinned image, `sha256:HEX`.
    zigbox_store: []const u8 = "",
    manifest: []const u8 = "",
    registry: ?IpAddress = null,
    /// zcube-server: where the peers and their chunk filters are read (`/node-store/`).
    server: ?IpAddress = null,
    peers: [constants.fetch_peers_max]Peer = undefined,
    peer_count: u32 = 0,
    /// `--peer` values left out because the name is not a node name, and the first of them.
    peers_skipped: u32 = 0,
    first_skipped: []const u8 = "",
    /// Where a successful fetch writes its `records.Pull` (the agent publishes it); empty: none.
    report: []const u8 = "",
};

pub fn parse(args: []const []const u8) ?Args {
    var parsed: Args = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return null;
        const value = args[index + 1];
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--node")) {
            parsed.node = value;
        } else if (std.mem.eql(u8, flag, "--state-dir")) {
            parsed.state_dir = value;
        } else if (std.mem.eql(u8, flag, "--images-dir")) {
            parsed.images_dir = value;
        } else if (std.mem.eql(u8, flag, "--zigbox-store")) {
            parsed.zigbox_store = value;
        } else if (std.mem.eql(u8, flag, "--manifest")) {
            parsed.manifest = value;
        } else if (std.mem.eql(u8, flag, "--digest")) {
            parsed.digest = value;
        } else if (std.mem.eql(u8, flag, "--registry")) {
            parsed.registry = parse_address(value) orelse return null;
        } else if (std.mem.eql(u8, flag, "--report")) {
            parsed.report = value;
        } else if (std.mem.eql(u8, flag, "--server")) {
            parsed.server = parse_address(value) orelse return null;
        } else if (std.mem.eql(u8, flag, "--peer")) {
            if (!parse_peer(&parsed, value)) return null;
        } else return null;
    }
    const complete = parsed.node.len > 0 and parsed.state_dir.len > 0;
    if (!complete or !digest_valid(parsed.digest)) return null;
    if (parsed.zigbox_store.len > 0) {
        // Zigbox mode: the store and the manifest come together; the digest is a full one.
        if (parsed.images_dir.len > 0 or parsed.digest.len != constants.tree_digest_bytes) {
            return null;
        }
        if (Zsha256.parse(parsed.manifest) == null) return null;
        return parsed;
    }
    if (parsed.registry == null) return null; // The chunk directory's registry is not optional.
    if (parsed.images_dir.len == 0 or parsed.manifest.len > 0) {
        return null;
    }
    return parsed;
}

/// `b3:` and 8 to 64 lower-case hex digits. The digest goes into request lines (the registry's
/// HTTP and the peers'), so anything else, a CR or LF above all, is refused here.
pub fn digest_valid(digest: []const u8) bool {
    if (!std.mem.startsWith(u8, digest, "b3:")) return false;
    const hex = digest[3..];
    if (hex.len < 8 or hex.len > 64) return false;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}

/// Adds `NAME=HOST:PORT` to `parsed.peers`. False if the value is not of that form or there are
/// too many; a name that is not a node name is counted and left out (the handshake asserts a
/// valid name, and a bad one can only come from a typo or an attacker).
fn parse_peer(parsed: *Args, value: []const u8) bool {
    const equals = std.mem.findScalar(u8, value, '=') orelse return false;
    const address = parse_address(value[equals + 1 ..]) orelse return false;
    const name = value[0..equals];
    if (records.name_problem(name, constants.node_name_bytes_max) != null) {
        if (parsed.peers_skipped == 0) parsed.first_skipped = name;
        parsed.peers_skipped += 1;
        return true;
    }
    if (parsed.peer_count == parsed.peers.len) return false;
    parsed.peers[parsed.peer_count] = .{ .name = name, .address = address };
    parsed.peer_count += 1;
    return true;
}

/// A peer address another node published: null when it is not an address or when no peer can
/// connect to it (port 0, 0.0.0.0, ::).
fn usable_address(text: []const u8) ?IpAddress {
    const address = parse_address(text) orelse return null;
    if (address.getPort() == 0) return null;
    if (agent_config.is_unspecified(address)) return null;
    return address;
}

/// `HOST:PORT`, or `[IPV6]:PORT`.
fn parse_address(text: []const u8) ?IpAddress {
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    return IpAddress.parse(host, port) catch null;
}

pub const usage = "usage: zcube-agent fetch --node NAME --state-dir DIR " ++
    "(--images-dir DIR | --zigbox-store ROOT --manifest sha256:HEX) " ++
    "--digest b3:HEX [--registry HOST:PORT] [--server HOST:PORT] [--report FILE] " ++
    "[--peer NAME=HOST:PORT]...";

/// Prints `diag` and gives the exit code. 1 is a bad command line, 2 is this node (disk,
/// memory), 3 is that no source had the tree (the supervisor records that as ZC-E0601).
fn finish(io: std.Io, diag: *const diag_mod.Diag, code: u8) u8 {
    assert(code != constants.exit_ok);
    emit(io, diag);
    return code;
}

fn no_memory(io: std.Io, diag: *diag_mod.Diag) u8 {
    diag.reset();
    store_failures.no_memory(diag) catch {}; // It only raises the diagnostic.
    return finish(io, diag, constants.exit_environment);
}

fn note(io: std.Io, text: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

/// The node's identity, or null when it has none or its files cannot be used; the second case
/// leaves ZC-E0806 in `diag` (never an error with no diagnostic).
fn identity_or_say(io: std.Io, parsed: *const Args, diag: *diag_mod.Diag) ?peer.Identity {
    assert(diag.code == null);
    const loaded = agent_peer.load_identity(io, parsed.state_dir, parsed.node, diag) catch |err| {
        switch (err) {
            error.Failed => assert(diag.code != null), // `Failed` always carries its diagnostic.
        }
        return null;
    };
    return loaded;
}

pub fn run(init: std.process.Init, args: []const []const u8) u8 {
    // Not `init.io`: that is a threaded Io. A Zigbox store is written in Zigbox's store
    // namespace, which only a process of one thread may make, and this Io never starts another.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const parsed = parse(args) orelse {
        diag.raise(.E0505);
        diag.cause("the arguments of zcube-agent fetch are not complete or not valid", .{});
        diag.fix(.{ .sentence = usage });
        return finish(io, &diag, constants.exit_user);
    };
    const gpa = init.gpa;
    const identity = identity_or_say(io, &parsed, &diag);
    if (diag.code != null) {
        emit(io, &diag); // The peers will not be asked; the registry may still answer.
        diag.reset();
    }
    const reply = gpa.alloc(u8, reply_bytes) catch
        return no_memory(io, &diag);
    defer gpa.free(reply);
    const conns = gpa.alloc(Conn, constants.fetch_candidates_max) catch
        return no_memory(io, &diag);
    defer gpa.free(conns);
    @memset(conns, .{});
    var net: Net = .{
        .io = io,
        .registry = parsed.registry,
        .peers = &.{},
        .identity = identity,
        .reply = reply,
        .digest = parsed.digest,
        .conns = conns,
        .environ = init.minimal.environ,
    };
    defer net.close_peers();
    if (parsed.zigbox_store.len > 0) return fetch_in_namespace(gpa, &net, &parsed, &diag);
    var dir = dir_images.DirImages.open(io, gpa, parsed.images_dir) catch {
        return unusable_images(io, &diag, parsed.images_dir);
    };
    defer dir.close(gpa);
    return fetch_from(gpa, &net, .{ .dir = &dir }, &parsed, &diag);
}

/// Zigbox mode. The whole fetch (the store opened, the peers asked, every write, the report)
/// runs in Zigbox's store namespace (`zigbox.store.namespace.run`, Z6): a child of one thread
/// with the id map Zigbox's own pull uses, so an object's owner lands as the id a container
/// sees and the store is the one `zbx pull` of the same image would leave. The child inherits
/// stdout and stderr, and its exit code is the command's. What it set in memory is lost with
/// it, which is why nothing runs after it here.
fn fetch_in_namespace(
    gpa: std.mem.Allocator,
    net: *Net,
    parsed: *const Args,
    diag: *diag_mod.Diag,
) u8 {
    assert(parsed.zigbox_store.len > 0);
    assert(diag.code == null);
    const io = net.io;
    var real: zigbox.host_real.HostReal = .{ .environ = net.environ };
    const host = real.interface();
    var status: [4096]u8 = undefined;
    const threads = if (host.read_file("/proc/self/status", &status)) |text|
        zigbox_image.threads_in(text)
    else |_|
        null;
    if (threads != 1) return not_single_threaded(io, diag, threads);
    const facts = gpa.create(Facts) catch return no_memory(io, diag);
    defer gpa.destroy(facts);
    var job: NamespaceJob = .{ .gpa = gpa, .net = net, .parsed = parsed, .diag = diag };
    const work: zigbox.store.namespace.Work = .{ .context = &job, .call = NamespaceJob.call };
    const warn: zigbox.store.namespace.Warn = .{ .context = net, .call = say_warning };
    var failure: zigbox.diag.Diag = undefined;
    failure.reset();
    return zigbox.store.namespace.run(host, facts, work, warn, &failure) catch {
        say_foreign(io, &failure); // ZBX-E0419: the child could not be made or was killed.
        return constants.exit_environment;
    };
}

/// Zigbox's doctor facts, which `namespace.run` fills to choose the id map (not exported).
const Facts = @FieldType(zigbox.Handle, "facts");

/// What the namespace child does: everything `run` would do with the store, in the child.
const NamespaceJob = struct {
    gpa: std.mem.Allocator,
    net: *Net,
    parsed: *const Args,
    diag: *diag_mod.Diag,

    fn call(context: *anyopaque, squash_owner: bool) u8 {
        const job: *NamespaceJob = @ptrCast(@alignCast(context));
        // Only Zigbox's tree import takes an owner; a peer's objects carry theirs in their ids,
        // and `put_chunk`, `put_tree` and `import_image` store what the namespace's file system
        // gives (namespace.zig, "For Zigcube"). On a one-id map an owner that is not 0 cannot
        // be stored: that object fails, and the supervisor's pull is the fallback.
        _ = squash_owner;
        const io = job.net.io;
        var opened: zigbox_fetch.Opened = .{};
        opened.open(job.gpa, job.parsed.zigbox_store) catch |err| switch (err) {
            error.OutOfMemory => return no_memory(io, job.diag),
            error.NoStore => return unusable_images(io, job.diag, job.parsed.zigbox_store),
        };
        defer opened.close();
        const code = fetch_from(job.gpa, job.net, .{ .zigbox = &opened }, job.parsed, job.diag);
        assert(code != zigbox_setup_failed);
        return code;
    }
};

/// Zigbox's exit code for a namespace child that could not be set up (not exported); the
/// fetch's own codes never collide with it.
const zigbox_setup_failed: u8 = 125;

comptime {
    for ([_]u8{
        constants.exit_ok,       constants.exit_user,     constants.exit_environment,
        constants.exit_external, constants.exit_internal,
    }) |code| assert(code != zigbox_setup_failed);
}

fn say_warning(context: *anyopaque, warning: *const zigbox.diag.Diag) void {
    const net: *Net = @ptrCast(@alignCast(context));
    say_foreign(net.io, warning); // ZBX-W0201: the one-id map.
}

/// Prints a diagnostic of Zigbox's (ZBX-) on stderr, as Zigbox wrote it.
fn say_foreign(io: std.Io, collector: *const zigbox.diag.Diag) void {
    assert(collector.code != null);
    var diagnostic: diag_mod.Diagnostic = undefined;
    zigbox.diagnostic.from_diag(&diagnostic, collector);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, .text, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

fn not_single_threaded(io: std.Io, diag: *diag_mod.Diag, count: ?u32) u8 {
    diag.raise(.B0002);
    if (count) |threads| {
        diag.cause("zcube-agent fetch has {d} threads; Zigbox's store namespace needs one", .{
            threads,
        });
    } else {
        diag.cause("zcube-agent fetch can't tell how many threads it has", .{});
    }
    diag.fix(.{ .sentence = "report this: the fetch must start no thread before its store work" });
    return finish(io, diag, constants.exit_internal);
}

/// Where the tree goes: a chunk directory, or a Zigbox store (`--zigbox-store`).
const Target = union(enum) {
    dir: *dir_images.DirImages,
    zigbox: *zigbox_fetch.Opened,
};

fn unusable_images(io: std.Io, diag: *diag_mod.Diag, path: []const u8) u8 {
    diag.raise(.E0506);
    diag.cause("the images directory {s} can't be used", .{path});
    diag.fix(.{ .sentence = "check the path and its permissions, and the free disk space" });
    return finish(io, diag, constants.exit_environment);
}

/// Finds the peers (the server's, then the named ones) and runs the worker over them.
fn fetch_from(
    gpa: std.mem.Allocator,
    net: *Net,
    target: Target,
    parsed: *const Args,
    diag: *diag_mod.Diag,
) u8 {
    const io = net.io;
    var infos: [constants.fetch_candidates_max]fetch_worker.PeerInfo = undefined;
    var all: [constants.fetch_candidates_max]Peer = undefined;
    var filter: [64]u8 = undefined;
    _ = chunk_summary.Filter.init(&filter);
    @memset(&filter, 0xff); // A named peer is assumed to hold everything: the plan strikes liars.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var skipped: Skipped = .{ .bad_name = parsed.peers_skipped };
    var found: u32 = 0;
    for (parsed.peers[0..parsed.peer_count]) |named| {
        all[found] = named;
        infos[found] = .{ .name = named.name, .filter = &filter };
        found += 1;
    }
    var poll = std.heap.ArenaAllocator.init(gpa);
    defer poll.deinit();
    var start: fetch_plan.Start = .peers;
    if (parsed.server) |server| {
        const room: Slots = .{ all[found..], infos[found..] };
        const arenas: Arenas = .{ &arena_state, &poll };
        const got = discover(arenas, net, server, parsed, room, &skipped);
        found += got.count;
        start = got.start;
    }
    var line: [320]u8 = undefined;
    note(io, describe_skipped(&line, skipped));
    if (start == .registry_first) {
        // The peers are still asked, without waiting: in Zigbox mode their refusals and ZC-E0601
        // go to fetch.log as before O5, and the supervisor's own pull is the registry fetch.
        note(io, "zcube-agent fetch: no peer holds the tree yet and this node pulls it from " ++
            "the registry first (O5); the others fetch it from here\n");
    }
    net.peers = all[0..found];
    var report: fetch_worker.Report = .{};
    const started_ms = real_ms(io);
    const transport = net.transport();
    const asked = infos[0..found];
    switch (target) {
        .dir => |store| {
            const digest = parsed.digest;
            fetch_worker.fetch(gpa, transport, store, digest, asked, .{}, &report) catch |err| {
                return fetch_failed(net, diag, err, target);
            };
        },
        .zigbox => |opened| {
            report = fetch_zigbox(gpa, transport, opened, parsed, asked, net) catch |err| {
                return fetch_failed(net, diag, err, target);
            };
        },
    }
    if (parsed.report.len > 0) write_report(gpa, net, parsed, &report, started_ms);
    var buffer: [256]u8 = undefined;
    const said = "zcube-agent fetch: {s} chunks {d} held {d} peers {d} registry {d} " ++
        "bad lists {d}\n";
    const text = std.fmt.bufPrint(&buffer, said, .{
        parsed.digest,      report.chunks,          report.already_held,
        report.peer_chunks, report.registry_chunks, report.bad_lists,
    }) catch return constants.exit_ok;
    std.Io.File.stdout().writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
    return constants.exit_ok;
}

/// Zigbox mode: the tree by bundle and chunks from the peers into the store, its image record
/// imported for the assignment's manifest only. The report is shaped as the directory mode's.
fn fetch_zigbox(
    gpa: std.mem.Allocator,
    transport: fetch_worker.Transport,
    opened: *zigbox_fetch.Opened,
    parsed: *const Args,
    infos: []const fetch_worker.PeerInfo,
    net: *Net,
) fetch_worker.Error!fetch_worker.Report {
    const tree = zigbox.store.Digest.parse(parsed.digest) orelse return error.TreeUnavailable;
    const manifest = Zsha256.parse(parsed.manifest) orelse return error.TreeUnavailable;
    var done: zigbox_fetch.Report = .{};
    const images = &opened.images;
    // No peer had the tree: the supervisor's own pull is the registry fallback (it writes the
    // pull record from Zigbox's blobs), so a failure here is the exit code it reacts to.
    const fetched = zigbox_fetch.fetch(gpa, transport, images, tree, manifest, infos, .{}, &done);
    net.other_images = done.other_images;
    fetched catch |err| {
        return switch (err) {
            error.TreeUnavailable, error.ChunkFailed, error.Deadline, error.Store => |same| same,
            error.OutOfMemory => error.OutOfMemory,
            error.Refused => {
                net.refusal = images.refusal;
                return error.TreeUnavailable;
            },
            error.TooLarge => {
                net.too_large = true;
                return error.TreeUnavailable;
            },
        };
    };
    return .{
        .chunks = done.chunks,
        .already_held = done.already_held,
        .peer_chunks = done.peer_chunks,
        .bad_lists = done.bad_bundles,
        .peer_bytes = done.peer_bytes,
        .cached_bytes = done.cached_bytes,
        .struck_peers = done.struck_peers,
    };
}

fn real_ms(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
}

/// The peers a pull's record names, as (with bytes, struck): a peer whose name is not a node
/// name is left out, because the server refuses the record for it (ZC-E0104) and the name is
/// printed on a terminal.
fn report_peers(
    named: []const Peer,
    report: *const fetch_worker.Report,
    peers: []records.PullPeer,
    bad: [][]const u8,
) [2]usize {
    var peer_count: usize = 0;
    var bad_count: usize = 0;
    for (named, 0..) |who, at| {
        if (records.name_problem(who.name, constants.node_name_bytes_max) != null) continue;
        if (peer_count < peers.len and report.peer_bytes[at] > 0) {
            peers[peer_count] = .{ .peer = who.name, .bytes = report.peer_bytes[at] };
            peer_count += 1;
        }
        const struck = (report.struck_peers >> @intCast(at)) & 1 != 0;
        if (struck and bad_count < bad.len) {
            bad[bad_count] = who.name;
            bad_count += 1;
        }
    }
    return .{ peer_count, bad_count };
}

/// Writes `report` as a `records.Pull` to `parsed.report`, through a temporary file and a rename,
/// so the agent never reads half of it. A failure is said on stderr and changes nothing else: the
/// fetch worked, and only its statistics are lost.
fn write_report(
    gpa: std.mem.Allocator,
    net: *const Net,
    parsed: *const Args,
    report: *const fetch_worker.Report,
    started_ms: u64,
) void {
    const io = net.io;
    var peers: [constants.fetch_peers_max]records.PullPeer = undefined;
    var bad: [constants.fetch_peers_max][]const u8 = undefined;
    const counts = report_peers(net.peers, report, &peers, &bad);
    const peer_count = counts[0];
    const bad_count = counts[1];
    const record: records.Pull = .{
        .node = parsed.node,
        .tree = parsed.digest,
        .registry_bytes = report.registry_bytes,
        .peer_bytes = peers[0..peer_count],
        .cached_bytes = report.cached_bytes,
        .started_at_ms = started_ms,
        .finished_at_ms = real_ms(io),
        .bad_peers = bad[0..bad_count],
    };
    if (!pull_report.write(gpa, io, parsed.report, record)) note(io, report_failed);
}

const report_failed = "zcube-agent fetch: the pull report could not be written\n";

/// ZC-E0601 for a tree no source could give in time (exit 3, external); this node's own memory
/// or disk failing is exit 2, with the code of the one that ran out.
fn fetch_failed(
    net: *const Net,
    diag: *diag_mod.Diag,
    err: fetch_worker.Error,
    target: Target,
) u8 {
    diag.reset();
    switch (err) {
        error.OutOfMemory, error.TooMany => {
            return no_memory(net.io, diag);
        },
        error.Store => {
            diag.raise(.E0506);
            const place = switch (target) {
                .dir => "images directory",
                .zigbox => "Zigbox store",
            };
            diag.cause("the chunks could not be written to this node's {s}", .{place});
            diag.fix(.{ .sentence = "check its permissions and the free disk space" });
            return finish(net.io, diag, constants.exit_environment);
        },
        error.TreeUnavailable, error.ChunkFailed, error.Deadline => {},
    }
    var tried_buffer: [256]u8 = undefined;
    const tried = tried_sources(&tried_buffer, net.peers, net.registry != null);
    fetch_worker.raise_tree_missing(diag, net.digest, tried);
    if (net.oversize) {
        diag.cause("the registry sent a reply larger than the {d} bytes a reply may have", .{
            reply_bytes,
        });
    }
    switch (err) {
        error.TreeUnavailable => zigbox_cause(net, diag),
        error.ChunkFailed => diag.cause("a chunk could not be had from any source asked", .{}),
        else => diag.cause("the fetch ran past its limit of {d} minutes", .{
            @divExact(constants.fetch_total_ms, 60_000),
        }),
    }
    return finish(net.io, diag, constants.exit_external);
}

/// The cause of a tree no source gave, in Zigbox mode as in directory mode.
fn zigbox_cause(net: *const Net, diag: *diag_mod.Diag) void {
    if (net.refusal) |refusal| {
        diag.cause("Zigbox refused the image record a peer sent: {s}", .{refusal_text(refusal)});
    } else if (net.too_large) {
        diag.cause("the tree has more than the {d} files or {d} chunks one peer fetch takes", .{
            constants.zigbox_claims_max, constants.fetch_chunks_max,
        });
    } else if (net.other_images > 0) {
        diag.cause("{d} peer(s) hold the tree only under another image's record (a peer sends " ++
            "the newest image of a tree)", .{net.other_images});
    } else diag.cause("no source sent a list that hashes to the digest", .{});
}

/// What a refusal of `zigbox.store.image_peer` means, said to an operator.
pub fn refusal_text(refusal: zigbox.store.image_peer.Refusal) []const u8 {
    return switch (refusal) {
        .no_record => "no image record names the tree",
        .local_unusable => "an image record of this store is damaged or from a newer zbx",
        .too_large => "the record is longer than any image record",
        .malformed => "the record is not one this zbx reads",
        .newer => "the record is from a newer zbx",
        .wrong_tree => "the record names another tree",
        .wrong_manifest => "the record is not for the manifest this assignment pins",
        .incomplete => "the tree or an object below it is not whole in the store",
        .tree_damaged => "a tree below is damaged in the store",
        .too_many_entries => "the tree has more entries than an import checks",
        .stack_full => "the tree is nested deeper than an import checks",
        .conflict => "a record of the same manifest already names another tree",
        .busy => "the store is locked by a gc or a restore",
        .store_failed => "a read or a write of the store failed",
    };
}

/// What `select_candidates` fills: the peers and, beside them, their filters.
const Slots = struct { []Peer, []fetch_worker.PeerInfo };

/// A `/v1/list` the fetch reads: its prefix, the keys a page asks for, the pages read at most.
const Listing = struct { prefix: []const u8, limit: u32, pages_max: u32 };

const node_store_listing: Listing = .{
    .prefix = "/node-store/",
    .limit = discover_page_nodes,
    .pages_max = discover_pages_max,
};
/// The assignments and replicas, read once per fetch to know which nodes fetch the tree (O5).
/// Their records are well under a kilobyte, so a page of this many fits `discover_page_bytes_max`.
const assigned_listing: Listing = .{ .prefix = "/assigned/", .limit = 128, .pages_max = 8 };
const replicas_listing: Listing = .{ .prefix = "/replicas/", .limit = 128, .pages_max = 8 };

/// Reads the server's `/node-store/` list, a page at a time (`discover_page_nodes` each, at most
/// `discover_pages_max`); what was read when a later page fails is kept, and null if none was.
/// `getter.get(path, out)` is the body of a 200 for `path`, copied into `out`, or null.
fn collect_pages(arena: std.mem.Allocator, getter: anytype, out: []u8) ?[]const Kv {
    return collect_list(arena, getter, out, node_store_listing);
}

/// `collect_pages` for any listing.
fn collect_list(
    arena: std.mem.Allocator,
    getter: anytype,
    out: []u8,
    listing: Listing,
) ?[]const Kv {
    var all: std.ArrayList(Kv) = .empty;
    var first_revision: u64 = 0;
    var after: ?[]const u8 = null;
    for (0..listing.pages_max) |at| {
        var target: [400]u8 = undefined;
        const form = "/v1/list?prefix={s}&limit={d}";
        const path = if (after) |key|
            std.fmt.bufPrint(&target, form ++ "&at={d}&continue={s}", .{
                listing.prefix, listing.limit, first_revision, key,
            })
        else
            std.fmt.bufPrint(&target, form, .{ listing.prefix, listing.limit });
        const body = getter.get(path catch break, out) orelse break;
        const page = parse_page(arena, body) orelse break;
        all.appendSlice(arena, page.kvs) catch break;
        if (at == 0) first_revision = page.revision;
        after = page.@"continue" orelse return all.items;
        // The key goes into a request line: a server's reply must not shape it.
        if (!continue_key_valid_in(listing.prefix, after.?)) break;
    }
    return if (all.items.len == 0) null else all.items;
}

/// A `continue` key is accepted only as a `/node-store/` key made of `[a-z0-9./-]`.
fn continue_key_valid(key: []const u8) bool {
    return continue_key_valid_in("/node-store/", key);
}

/// A `continue` key is accepted only under `prefix` and made of `[a-z0-9./-]`.
fn continue_key_valid_in(prefix: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, key, prefix)) return false;
    for (key) |byte| {
        const ok = switch (byte) {
            'a'...'z', '0'...'9', '.', '/', '-' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// `collect_pages` over the control plane's HTTP.
const HttpGetter = struct {
    net: *Net,
    server: IpAddress,

    fn get(getter: HttpGetter, path: []const u8, out: []u8) ?[]const u8 {
        return switch (getter.net.http_get(getter.server, path, out)) {
            .bytes => |body| body,
            .refused, .timeout, .busy => null,
        };
    }
};

const Arenas = struct { *std.heap.ArenaAllocator, *std.heap.ArenaAllocator };

/// Asks the server which nodes fetch the tree and for the nodes' summaries (waiting as O5 says,
/// `begin`), and picks the candidates among them. A digest no peer is asked for waits for none.
fn discover(
    arenas: Arenas,
    net: *Net,
    server: IpAddress,
    parsed: *const Args,
    slots: Slots,
    skipped: *Skipped,
) struct { count: u32, start: fetch_plan.Start } {
    const arena = arenas[0].allocator();
    // A digest no peer is asked for (not the full one, fetch_worker.zig) waits for none.
    const begun: Begun = if (parsed.digest.len == 3 + 64)
        begin(arena, arenas[1], net, server, parsed)
    else
        read_once(arena, net, server);
    say_begun(net.io, begun);
    const stores = begun.stores orelse {
        note(net.io, "zcube-agent fetch: the server's node list could not be read; peers: " ++
            "only those named\n");
        return .{ .count = 0, .start = begun.start };
    };
    const room = @min(slots[0].len, slots[1].len);
    const self = parsed.node;
    const peers = slots[0][0..room];
    const count = select_candidates(arena, stores, self, peers, slots[1][0..room], skipped);
    return .{ .count = count, .start = begun.start };
}

/// One line in the fetch's log on how O5's wait ended, when there was one to have.
fn say_begun(io: std.Io, begun: Begun) void {
    var buffer: [200]u8 = undefined;
    const text = switch (begun.start) {
        .peers, .wait => if (begun.waited_ms == 0) return else std.fmt.bufPrint(
            &buffer,
            "zcube-agent fetch: a peer came to hold the tree after {d} ms (O5)\n",
            .{begun.waited_ms},
        ),
        .registry_first => return,
        .waited => std.fmt.bufPrint(&buffer, "zcube-agent fetch: no peer came to hold the " ++
            "tree in {d} ms; {d} node(s) fetch it (O5)\n", .{ begun.waited_ms, begun.fetchers }),
    } catch return;
    note(io, text);
}

/// The `/node-store/` list read once, with no wait.
fn read_once(arena: std.mem.Allocator, net: *Net, server: IpAddress) Begun {
    const getter: HttpGetter = .{ .net = net, .server = server };
    const none: Begun = .{ .stores = null, .start = .peers, .fetchers = 0, .waited_ms = 0 };
    const scratch = arena.alloc(u8, discover_page_bytes_max) catch return none;
    var once = none;
    once.stores = collect_pages(arena, getter, scratch);
    return once;
}

/// What `begin` found: the `/node-store/` list read last (null if it could not be read) and
/// how the wait of O5 ended.
const Begun = struct {
    stores: ?[]const Kv,
    start: fetch_plan.Start,
    fetchers: u32,
    waited_ms: u64,
};

/// O5 (docs/briefs/c2.md, owner 2026-11-03): before the peers are chosen, reads which nodes fetch
/// the tree and, unless a peer holds it or this node ranks lowest among them, re-reads
/// `/node-store/` every `fetch_peer_poll_ms` for up to `fetch_peer_wait_ms` until a peer holds
/// it. `arena` holds the fetchers; `poll` is reset before each read and holds the last.
fn begin(
    arena: std.mem.Allocator,
    poll: *std.heap.ArenaAllocator,
    net: *Net,
    server: IpAddress,
    parsed: *const Args,
) Begun {
    const getter: HttpGetter = .{ .net = net, .server = server };
    const scratch = arena.alloc(u8, discover_page_bytes_max) catch
        return .{ .stores = null, .start = .peers, .fetchers = 0, .waited_ms = 0 };
    const fetchers = fetching_nodes(arena, getter, scratch, parsed.digest);
    const started = peer_stream.boot_ms(net.io);
    while (true) {
        _ = poll.reset(.retain_capacity);
        const stores = collect_pages(poll.allocator(), getter, scratch);
        const self = parsed.node;
        const tree = parsed.digest;
        const holds = if (stores) |listed| peer_holds(listed, self, tree) else false;
        const now = peer_stream.boot_ms(net.io);
        const wait_ms = constants.fetch_peer_wait_ms;
        const decided = fetch_plan.start(self, tree, fetchers, holds, started, now, wait_ms);
        switch (decided) {
            .wait => |until| {
                const ms: u32 = @intCast(@max(until -| now, 1));
                net.io.sleep(.fromMilliseconds(ms), .awake) catch {}; // Cancelled: read again.
            },
            else => return .{
                .stores = stores,
                .start = decided,
                .fetchers = @intCast(fetchers.len),
                .waited_ms = now - started,
            },
        }
    }
}

/// The nodes with an assignment of a replica whose image is `digest` (`/assigned/<node>/<id>`
/// joined to `/replicas/<service>/<id>`), each once. Empty if either list cannot be read: the
/// fetch then ranks itself alone and does not wait, as before O5.
fn fetching_nodes(
    arena: std.mem.Allocator,
    getter: anytype,
    scratch: []u8,
    digest: []const u8,
) []const []const u8 {
    const replicas = collect_list(arena, getter, scratch, replicas_listing) orelse return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    for (replicas) |kv| {
        const image = string_field(kv.value, "image") orelse continue;
        if (!std.mem.eql(u8, image, digest)) continue;
        const id = string_field(kv.value, "id") orelse continue;
        ids.append(arena, id) catch return &.{};
    }
    if (ids.items.len == 0) return &.{};
    const assigned = collect_list(arena, getter, scratch, assigned_listing) orelse return &.{};
    return assigned_nodes(arena, assigned, ids.items);
}

/// The nodes of `/assigned/<node>/<id>` keys whose `id` is in `ids`, each once.
fn assigned_nodes(
    arena: std.mem.Allocator,
    assigned: []const Kv,
    ids: []const []const u8,
) []const []const u8 {
    var nodes: std.ArrayList([]const u8) = .empty;
    for (assigned) |kv| {
        const rest = strip_prefix(kv.key, "/assigned/") orelse continue;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const node = rest[0..slash];
        const id = rest[slash + 1 ..];
        if (!contains(ids, id) or contains(nodes.items, node)) continue;
        nodes.append(arena, node) catch return nodes.items;
    }
    return nodes.items;
}

fn strip_prefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |each| {
        if (std.mem.eql(u8, each, name)) return true;
    }
    return false;
}

/// Whether a node other than `self` that a fetch can reach (a usable `peer` address) lists
/// `digest` among the whole trees of its `/node-store/` record.
fn peer_holds(stores: []const Kv, self: []const u8, digest: []const u8) bool {
    for (stores) |kv| {
        const name = strip_prefix(kv.key, "/node-store/") orelse continue;
        if (std.mem.eql(u8, name, self)) continue;
        _ = usable_address(string_field(kv.value, "peer") orelse "") orelse continue;
        if (kv.value != .object) continue;
        const trees = kv.value.object.get("trees") orelse continue;
        if (trees != .array) continue;
        for (trees.array.items) |tree| {
            const text = string_field(tree, "tree") orelse continue;
            if (std.mem.eql(u8, text, digest)) return true;
        }
    }
    return false;
}

// ---- Tests ----------------------------------------------------------------------------------

test "a peer that gave no bundle is named with what it answered" {
    var buffer: [256]u8 = undefined;
    const line = bundle_note(&buffer, "node2", .refused);
    try std.testing.expect(std.mem.indexOf(u8, line, "peer node2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "status other than 200") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    const timed_out = bundle_note(&buffer, "n", .timeout);
    try std.testing.expect(std.mem.indexOf(u8, timed_out, "no reply") != null);
}

test "an HTTP reply gives its body only for 200" {
    // Goal: the registry client takes the body of a 200 and nothing else. Method: a 200, a 404,
    // garbage and a reply cut before the blank line.
    try std.testing.expectEqualStrings("abc", http_body("HTTP/1.0 200 OK\r\nX: y\r\n\r\nabc").?);
    try std.testing.expectEqualStrings("", http_body("HTTP/1.1 200 OK\r\n\r\n").?);
    try std.testing.expect(http_body("HTTP/1.0 404 Not Found\r\n\r\nabc") == null);
    try std.testing.expect(http_body("nonsense") == null);
    try std.testing.expect(http_body("HTTP/1.0 200 OK\r\n") == null);
}

test "the fetch arguments need a node, directories, a digest and a registry" {
    // Goal: a partial command line is refused (usage), a complete one is parsed with its peers.
    const good = [_][]const u8{
        "--node",       "node1",          "--state-dir", "/s",
        "--images-dir", "/i",             "--digest",    "b3:00000000",
        "--registry",   "127.0.0.1:9000", "--peer",      "node2=127.0.0.1:9001",
    };
    const parsed = parse(&good).?;
    try std.testing.expectEqual(@as(u32, 1), parsed.peer_count);
    try std.testing.expectEqualStrings("node2", parsed.peers[0].name);
    try std.testing.expect(parse(good[0..8]) == null);
    const zeros65: [65]u8 = @splat('0');
    const a64: [64]u8 = @splat('a');
    // The digest ends up in request lines: CR/LF, a path, upper case, a wrong length are refused.
    const bad_digests = [_][]const u8{
        "b3:00000000\r\nX-Evil: 1", "b3:00000000\n",   "b3:0000000",
        "b3:" ++ zeros65,           "b3:0000000G",     "b3:0000000A",
        "B3:00000000",              "sha256:00000000", "b3:../../../x",
        "b3:00000000 HTTP/1.1",     "",                "b3:",
    };
    for (bad_digests) |bad| {
        var args = good;
        args[7] = bad;
        try std.testing.expect(parse(&args) == null);
    }
    var long = good;
    long[7] = "b3:" ++ a64;
    try std.testing.expect(parse(&long) != null);
    try std.testing.expect(parse(&.{ "--node", "n", "--bogus", "x" }) == null);
}

const test_filter = "00ff00ff00ff00ff";

/// A `/v1/list` reply for the tests: one `/node-store/<name>` per `(name, peer, filter)`.
fn stores_text(arena: std.mem.Allocator, entries: []const [3][]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    try writer.writer.writeAll("{\"kvs\":[");
    for (entries, 0..) |entry, at| {
        if (at > 0) try writer.writer.writeAll(",");
        try writer.writer.print("{{\"key\":\"/node-store/{s}\",\"value\":{{", .{entry[0]});
        try writer.writer.print("\"peer\":\"{s}\",\"filter\":\"{s}\"}}}}", .{ entry[1], entry[2] });
    }
    try writer.writer.writeAll("]}");
    return writer.written();
}

fn select_from(
    arena: std.mem.Allocator,
    text: []const u8,
    slots: Slots,
    skipped: *Skipped,
) u32 {
    const stores = parse_kvs(arena, text) orelse return 0;
    return select_candidates(arena, stores, "node1", slots[0], slots[1], skipped);
}

test "discovery keeps the nodes it can use and counts the rest" {
    // Goal: only usable sources are added, and every node left out is counted. Method: node-store
    // entries for this node itself, a good node, a bad name (upper case, and one that is too
    // long), an IPv6 peer, a node with no peer address, a bad address, a filter that is not hex
    // and one that is too short, and a node whose entry has no filter at all.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_name: [64]u8 = @splat('a');
    const text = try stores_text(arena, &.{
        .{ "node1", "127.0.0.1:1", test_filter },
        .{ "node2", "127.0.0.1:2", test_filter },
        .{ "Node3", "127.0.0.1:3", test_filter },
        .{ &long_name, "127.0.0.1:3", test_filter },
        .{ "node4", "[::1]:4", test_filter },
        .{ "node5", "", test_filter },
        .{ "node6", "not-an-address", test_filter },
        .{ "node7", "127.0.0.1:7", "zzzzzzzzzzzzzzzz" },
        .{ "node8", "127.0.0.1:8", "00ff" },
        .{ "node9", "0.0.0.0:9", test_filter },
        .{ "node10", "[::]:10", test_filter },
        .{ "node11", "127.0.0.1:0", test_filter },
        .{ "node12", "[::ffff:0.0.0.0]:12", test_filter },
    });
    var peers: [constants.fetch_candidates_max]Peer = undefined;
    var infos: [constants.fetch_candidates_max]fetch_worker.PeerInfo = undefined;
    var skipped: Skipped = .{};
    const count = select_from(arena, text, .{ &peers, &infos }, &skipped);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqualStrings("node2", peers[0].name);
    try std.testing.expectEqualStrings("node4", peers[1].name);
    try std.testing.expect(peers[1].address == .ip6);
    try std.testing.expectEqualStrings("node4", infos[1].name);
    try std.testing.expectEqual(@as(usize, 8), infos[0].filter.len);
    try std.testing.expectEqual(@as(u32, 1), skipped.self_node);
    try std.testing.expectEqual(@as(u32, 2), skipped.bad_name);
    try std.testing.expectEqual(@as(u32, 6), skipped.no_address);
    try std.testing.expectEqual(@as(u32, 2), skipped.no_filter);
    var line: [320]u8 = undefined;
    const said = describe_skipped(&line, skipped);
    try std.testing.expect(std.mem.startsWith(u8, said, "zcube-agent fetch: left out 11 nodes ("));
    try std.testing.expect(std.mem.find(u8, said, "2 with a name that is not a node name") != null);
}

test "discovery keeps at most the room it is given and a malformed body gives nothing" {
    // Goal: more nodes than candidates are counted, not dropped silently; a body that is cut,
    // not JSON or longer than the bound is no discovery at all. Method: 70 good nodes into 64
    // slots, then into 16; then a truncated body, text, and a body one byte over the bound.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: [70][8]u8 = undefined;
    var entries: [70][3][]const u8 = undefined;
    for (&names, &entries, 0..) |*name, *entry, at| {
        entry.* = .{
            std.fmt.bufPrint(name, "peer-{d:0>2}", .{at}) catch unreachable, // Fits.
            "127.0.0.1:9",
            test_filter,
        };
    }
    const text = try stores_text(arena, &entries);
    var peers: [constants.fetch_candidates_max]Peer = undefined;
    var infos: [constants.fetch_candidates_max]fetch_worker.PeerInfo = undefined;
    var skipped: Skipped = .{};
    const all = select_from(arena, text, .{ &peers, &infos }, &skipped);
    try std.testing.expectEqual(constants.fetch_candidates_max, all);
    try std.testing.expectEqual(@as(u32, 6), skipped.over_limit);
    skipped = .{};
    const few = select_from(arena, text, .{ peers[0..16], infos[0..16] }, &skipped);
    try std.testing.expectEqual(@as(u32, 16), few);
    try std.testing.expectEqual(@as(u32, 54), skipped.over_limit);
    try std.testing.expect(parse_kvs(arena, text[0 .. text.len - 5]) == null);
    try std.testing.expect(parse_kvs(arena, "no") == null);
    const over = try arena.alloc(u8, discover_page_bytes_max + 1);
    @memset(over, ' ');
    try std.testing.expect(parse_kvs(arena, over) == null);
}

/// A server that answers `collect_pages` from prepared pages, one per call.
const PagedGetter = struct {
    pages: []const []const u8,
    calls: *u32,
    last_path: *[160]u8,

    fn get(getter: PagedGetter, path: []const u8, out: []u8) ?[]const u8 {
        const at = getter.calls.*;
        getter.calls.* += 1;
        if (at == 1) @memcpy(getter.last_path[0..path.len], path);
        if (at >= getter.pages.len) return null;
        @memcpy(out[0..getter.pages[at].len], getter.pages[at]);
        return out[0..getter.pages[at].len];
    }
};

test "discovery reads more nodes than one reply holds, with full-size filters, page by page" {
    // Goal: review S1. Method: 40 nodes whose records are as large as a node's summary may be
    // (`summary_json_bytes_max`), served 16 to a page; all 40 arrive, the second request names
    // the revision of the first page and the key to continue after.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filter = try arena.alloc(u8, constants.summary_json_bytes_max - 128);
    @memset(filter, 'a');
    var pages: [3][]const u8 = undefined;
    for (&pages, 0..) |*page, number| {
        const first = number * discover_page_nodes;
        const last = @min(first + discover_page_nodes, 40);
        var writer: std.Io.Writer.Allocating = .init(arena);
        try writer.writer.writeAll("{\"revision\":7,\"kvs\":[");
        for (first..last) |at| {
            if (at > first) try writer.writer.writeAll(",");
            try writer.writer.print(
                "{{\"key\":\"/node-store/n{d:0>3}\",\"value\":{{\"filter\":\"{s}\"}}}}",
                .{ at, filter },
            );
        }
        try writer.writer.writeAll("]");
        if (last < 40) {
            const more = ",\"continue\":\"/node-store/n{d:0>3}\"";
            try writer.writer.print(more, .{last - 1});
        }
        try writer.writer.writeAll("}");
        page.* = writer.written();
    }
    var calls: u32 = 0;
    var second: [160]u8 = @splat(0);
    const getter: PagedGetter = .{ .pages = &pages, .calls = &calls, .last_path = &second };
    const out = try arena.alloc(u8, discover_page_bytes_max);
    const kvs = collect_pages(arena, getter, out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 40), kvs.len);
    try std.testing.expectEqual(@as(u32, 3), calls);
    const asked = std.mem.sliceTo(&second, 0);
    try std.testing.expect(std.mem.find(u8, asked, "&at=7&continue=/node-store/n015") != null);
}

test "a continue key that could shape the request line stops paging, keeping what was read" {
    // Goal: review follow-up 3. Method: a first page whose `continue` holds a space and a line
    // break; only one request is made and the page's nodes are kept.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const evil = "{\"revision\":7,\"kvs\":[{\"key\":\"/node-store/n000\",\"value\":{}}]," ++
        "\"continue\":\"/node-store/n000 HTTP/1.1\\r\\nX: y\"}";
    const pages = [_][]const u8{ evil, evil };
    var calls: u32 = 0;
    var last: [160]u8 = @splat(0);
    const getter: PagedGetter = .{ .pages = &pages, .calls = &calls, .last_path = &last };
    const out = try arena.alloc(u8, discover_page_bytes_max);
    const kvs = collect_pages(arena, getter, out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), kvs.len);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(continue_key_valid("/node-store/n015"));
    try std.testing.expect(!continue_key_valid("/v1/list"));
    try std.testing.expect(!continue_key_valid("/node-store/A"));
}

test "a --peer with a name that is not a node name is left out, the rest are kept" {
    // Goal: the handshake asserts a valid name, so a bad one must never reach it. Method: three
    // --peer flags (good, upper case, empty name) and an IPv6 one; two are kept, two counted.
    const base = [_][]const u8{
        "--node",       "node1",              "--state-dir", "/s",
        "--images-dir", "/i",                 "--digest",    "b3:00000000",
        "--registry",   "127.0.0.1:9000",     "--peer",      "node2=127.0.0.1:9001",
        "--peer",       "Bad=127.0.0.1:9002", "--peer",      "=127.0.0.1:9003",
        "--peer",       "node4=[::1]:9004",
    };
    const parsed = parse(&base).?;
    try std.testing.expectEqual(@as(u32, 2), parsed.peer_count);
    try std.testing.expectEqual(@as(u32, 2), parsed.peers_skipped);
    try std.testing.expectEqualStrings("Bad", parsed.first_skipped);
    try std.testing.expectEqualStrings("node4", parsed.peers[1].name);
    var line: [320]u8 = undefined;
    const said = describe_skipped(&line, .{ .bad_name = parsed.peers_skipped });
    try std.testing.expect(std.mem.find(u8, said, "2 with a name") != null);
    try std.testing.expectEqualStrings("", describe_skipped(&line, .{}));
}

test "a pull report leaves out a peer whose name is not a node name" {
    // Goal: no control byte or bad name reaches the record. Method: three peers all gave bytes
    // and were struck; the one named with an escape sequence is dropped from both lists.
    const unused = try IpAddress.parse("127.0.0.1", 1);
    const named = [_]Peer{
        .{ .name = "node1", .address = unused },
        .{ .name = "node2\x1b[2J", .address = unused },
        .{ .name = "node3", .address = unused },
    };
    var report: fetch_worker.Report = .{ .struck_peers = 0b111 };
    @memset(report.peer_bytes[0..3], 7);
    var peers: [3]records.PullPeer = undefined;
    var bad: [3][]const u8 = undefined;
    const counts = report_peers(&named, &report, &peers, &bad);
    try std.testing.expectEqual(@as(usize, 2), counts[0]);
    try std.testing.expectEqual(@as(usize, 2), counts[1]);
    try std.testing.expectEqualStrings("node3", peers[1].peer);
    try std.testing.expectEqualStrings("node3", bad[1]);
}

test "a reply's status is read from a complete status line" {
    // Goal: a 404 from the registry is `refused`, garbage is a timeout. Method: statuses.
    try std.testing.expectEqual(@as(?u16, 404), http_status("HTTP/1.0 404 Not Found\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, 200), http_status("HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(http_status("HTTP/1.0 20") == null);
    try std.testing.expect(http_status("nonsense\r\n") == null);
}

test "the sources a failed fetch names are its peers and the registry" {
    var buffer: [128]u8 = undefined;
    const address = try IpAddress.parse("127.0.0.1", 1);
    const peers = [_]Peer{
        .{ .name = "node2", .address = address },
        .{ .name = "node3", .address = address },
    };
    try std.testing.expectEqualStrings(
        "node2, node3 and the registry",
        tried_sources(&buffer, &peers, true),
    );
    try std.testing.expectEqualStrings("the registry", tried_sources(&buffer, &.{}, true));
}

test "a fetch with an unusable key file says ZC-E0806 and has no identity" {
    // Goal: S4. Method: a peer.key readable by others; the identity is null and the diagnostic
    // is E0806, which `run` prints before asking the registry alone.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = agent_peer.key_file, .data = "00\n" });
    try tmp.dir.setFilePermissions(io, agent_peer.key_file, .fromMode(0o644), .{});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const parsed: Args = .{ .node = "node1", .state_dir = path };
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    try std.testing.expect(identity_or_say(io, &parsed, &diag) == null);
    try std.testing.expectEqual(@as(?@TypeOf(diag.code.?), .E0806), diag.code);
}

test "a reply past the buffer is TooLarge and a write that never drains times out" {
    // Goal: S5 and the write deadline. Method: a pipe holding more than the buffer, closed, is
    // read into a small buffer; a full pipe nobody reads fails `write_all` at its deadline.
    const io = std.testing.io;
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(
        std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }),
    ));
    defer _ = std.os.linux.close(fds[0]);
    var open_write = true;
    defer if (open_write) {
        _ = std.os.linux.close(fds[1]);
    };
    const data: [100]u8 = @splat(0xab);
    try write_all(io, fds[1], &data, peer_stream.boot_ms(io) + 1000);
    _ = std.os.linux.close(fds[1]);
    open_write = false;
    var small: [50]u8 = @splat(0);
    const soon = peer_stream.boot_ms(io) + 1000;
    try std.testing.expectError(error.TooLarge, read_until_close(io, fds[0], &small, soon));
    var fits: [200]u8 = @splat(0);
    const whole = try read_until_close(io, fds[0], &fits, peer_stream.boot_ms(io) + 1000);
    try std.testing.expectEqual(@as(usize, 50), whole.len); // The 50 the small buffer left.

    var full: [2]i32 = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(
        std.os.linux.pipe2(&full, .{ .NONBLOCK = true }),
    ));
    defer _ = std.os.linux.close(full[0]);
    defer _ = std.os.linux.close(full[1]);
    const huge: [4 * 65536]u8 = @splat(1); // More than a pipe holds.
    const started = peer_stream.boot_ms(io);
    try std.testing.expectError(error.Io, write_all(io, full[1], &huge, started + 200));
    try std.testing.expect(peer_stream.boot_ms(io) - started < 5000);
}

test "the reply buffer holds the largest tree list and a head" {
    try std.testing.expect(reply_bytes >= constants.tree_list_bytes_max + reply_head_slack_bytes);
    try std.testing.expect(reply_bytes >= constants.swarm_chunk_bytes + reply_head_slack_bytes);
}

test "zigbox mode arguments: a store and a manifest together, a full digest, no images dir" {
    const full = "b3:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const manifest = "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const base = [_][]const u8{
        "--node",     "node1",       "--state-dir", "/s",
        "--registry", "127.0.0.1:1", "--digest",    full,
    };
    const ok = base ++ [_][]const u8{ "--zigbox-store", "/store", "--manifest", manifest };
    const parsed = parse(&ok).?;
    try std.testing.expectEqualStrings("/store", parsed.zigbox_store);
    // The manifest is required, and so is a full digest; the two modes do not mix.
    try std.testing.expect(parse(&(base ++ [_][]const u8{ "--zigbox-store", "/store" })) == null);
    const mixed = ok ++ [_][]const u8{ "--images-dir", "/i" };
    try std.testing.expect(parse(&mixed) == null);
    var short = ok;
    short[7] = "b3:abcdef12";
    try std.testing.expect(parse(&short) == null);
    const dir_mode = base ++ [_][]const u8{ "--images-dir", "/i", "--manifest", manifest };
    try std.testing.expect(parse(&dir_mode) == null);
    // Zigbox mode needs no registry (the peers are the only source); the directory mode does.
    const bare = [_][]const u8{
        "--node",         "node1",  "--state-dir", "/s",     "--digest", full,
        "--zigbox-store", "/store", "--manifest",  manifest,
    };
    try std.testing.expect(parse(&bare).?.registry == null);
    const dir_bare = [_][]const u8{
        "--node", "node1", "--state-dir", "/s", "--digest", full, "--images-dir", "/i",
    };
    try std.testing.expect(parse(&dir_bare) == null);
}

test "without a registry the sources a failed fetch names are the peers alone" {
    var buffer: [128]u8 = undefined;
    const peers = [_]Peer{.{ .name = "node2", .address = undefined }};
    try std.testing.expectEqualStrings("node2", tried_sources(&buffer, &peers, false));
    try std.testing.expectEqualStrings(
        "no peer, and no registry is given",
        tried_sources(&buffer, &.{}, false),
    );
}

test "the nodes fetching a tree are those assigned a replica of it, each once" {
    // Goal: O5's set of fetchers from `/assigned/` and `/replicas/`. Method: two replicas of the
    // tree on node1 and one on node3, one of another image on node2.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const assigned = parse_kvs(arena,
        \\{"kvs":[{"key":"/assigned/node1/app-1","value":{"replica":"app-1"}},
        \\{"key":"/assigned/node1/app-2","value":{}},{"key":"/assigned/node2/web-1","value":{}},
        \\{"key":"/assigned/node3/app-3","value":{}},{"key":"/assigned/bad","value":{}}]}
    ).?;
    const ids = [_][]const u8{ "app-1", "app-2", "app-3" };
    const nodes = assigned_nodes(arena, assigned, &ids);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("node1", nodes[0]);
    try std.testing.expectEqualStrings("node3", nodes[1]);
}

test "the fetching nodes stay as read when the same buffer serves the next request" {
    // Goal: the demo-c2 run 41965968058 bug: the names pointed into the reply buffer, so the next
    // `/node-store/` read changed them and no node ranked lowest. Method: read the fetchers, then
    // a node-store page through the same buffer; the names and the ids they came from hold.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pages = [_][]const u8{
        \\{"kvs":[{"key":"/replicas/app/app-1","value":{"id":"app-1","image":"b3:aa"}},
        \\{"key":"/replicas/app/app-2","value":{"id":"app-2","image":"b3:aa"}}]}
        ,
        \\{"kvs":[{"key":"/assigned/node1/app-1","value":{}},
        \\{"key":"/assigned/node3/app-2","value":{}}]}
        ,
        \\{"kvs":[{"key":"/node-store/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","value":{
        \\"peer":"10.0.0.9:7700","trees":[]}}]}
        ,
    };
    var calls: u32 = 0;
    var last_path: [160]u8 = undefined;
    const getter: PagedGetter = .{ .pages = &pages, .calls = &calls, .last_path = &last_path };
    const scratch = try arena.alloc(u8, 4096);
    @memset(scratch, 'x');
    const nodes = fetching_nodes(arena, getter, scratch, "b3:aa");
    _ = collect_pages(arena, getter, scratch).?;
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("node1", nodes[0]);
    try std.testing.expectEqualStrings("node3", nodes[1]);
}

test "a peer holds a tree when its summary lists it and it can be reached" {
    // Goal: the condition that ends O5's wait. Method: node2 lists the tree but has no address,
    // node1 is this node, node3 lists another tree; then node3 lists it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = parse_kvs(arena,
        \\{"kvs":[{"key":"/node-store/node1","value":{"peer":"10.0.0.1:7700",
        \\"trees":[{"tree":"b3:aa"}]}},{"key":"/node-store/node2","value":{"peer":"",
        \\"trees":[{"tree":"b3:aa"}]}},{"key":"/node-store/node3","value":{
        \\"peer":"10.0.0.3:7700","trees":[{"tree":"b3:bb"}]}}]}
    ).?;
    try std.testing.expect(!peer_holds(before, "node1", "b3:aa"));
    try std.testing.expect(peer_holds(before, "node1", "b3:bb"));
    const after = parse_kvs(arena,
        \\{"kvs":[{"key":"/node-store/node3","value":{"peer":"10.0.0.3:7700",
        \\"trees":[{"tree":"b3:bb"},{"tree":"b3:aa"}]}}]}
    ).?;
    try std.testing.expect(peer_holds(after, "node1", "b3:aa"));
}
