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
//! one that lies (a hash mismatch) or does not answer. Exit codes: 0 fetched, 1 not fetched.

const std = @import("std");
const assert = std.debug.assert;
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
pub const reply_bytes: usize = @max(constants.swarm_chunk_bytes, constants.tree_list_bytes_max) +
    reply_head_slack_bytes;

/// The network side of the worker. `list_scratch` holds one reply; `identity` is the node's.
pub const Net = struct {
    io: std.Io,
    registry: IpAddress,
    peers: []const Peer,
    identity: ?peer.Identity,
    reply: []u8,
    /// The tree being fetched, for the diagnostics that name it.
    digest: []const u8 = "",
    /// Counts for the log line.
    bad_lists: u32 = 0,
    /// The registry sent a reply larger than `reply_bytes`: refused, and said in ZC-E0601.
    oversize: bool = false,
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
        };
    }

    fn tree(context: *anyopaque, source: Source, digest: []const u8, out: []u8) ?[]const u8 {
        const net = from(context);
        var target: [128]u8 = undefined;
        switch (source) {
            .registry => {
                const path = std.fmt.bufPrint(&target, "/trees/{s}", .{digest}) catch return null;
                return switch (net.http_get(net.registry, path, out)) {
                    .bytes => |bytes| bytes,
                    .refused, .timeout => null,
                };
            },
            .peer => |index| {
                const prefix = peer_serve.path_trees;
                const path = std.fmt.bufPrint(&target, "{s}{s}", .{ prefix, digest }) catch
                    return null;
                return switch (net.peer_get(index, path, out)) {
                    .bytes => |bytes| bytes,
                    .refused, .timeout => null,
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
                return switch (net.http_get(net.registry, path, out)) {
                    .bytes => |bytes| .{ .bytes = bytes },
                    .refused => .refused,
                    .timeout => .timeout,
                };
            },
            .peer => |index| {
                const prefix = peer_serve.path_chunk;
                const path = std.fmt.bufPrint(&target, "{s}{x}", .{ prefix, &ref.hash }) catch
                    return .refused;
                return switch (net.peer_get(index, path, out)) {
                    .bytes => |bytes| .{ .bytes = bytes },
                    .refused => .refused,
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
    /// One deadline covers both tries of a request.
    pub fn peer_get(net: *Net, index: u8, path: []const u8, out: []u8) PeerReply {
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
        if (reply == .timeout) conn.close();
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
        if (std.mem.readInt(u16, head[0..2], .big) != 200) return .refused;
        return .{ .bytes = body };
    }

    /// Closes every open peer stream.
    pub fn close_peers(net: *Net) void {
        for (net.conns) |*conn| conn.close();
    }
};

pub const PeerReply = union(enum) { bytes: []const u8, refused, timeout };

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
        const parsed = parse_address(address) orelse {
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

/// The `kvs` of a `/v1/list` reply, or null if the text is over `discover_body_bytes_max` or is
/// not one.
fn parse_kvs(arena: std.mem.Allocator, text: []const u8) ?[]const Kv {
    if (text.len > discover_body_bytes_max) return null;
    const Listed = struct { kvs: []const Kv };
    const parsed = std.json.parseFromSliceLeaky(Listed, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.kvs;
}

/// The reply to the server's list of `/node-store/` is at most this long (a filter is hex).
const discover_body_bytes_max = constants.swarm_chunk_bytes;

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

/// "node2, node3 and the registry", or "the registry" when there are no peers.
fn tried_sources(buffer: []u8, peers: []const Peer) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (peers, 0..) |who, at| {
        writer.print("{s}{s}", .{ if (at == 0) "" else ", ", who.name }) catch break;
    }
    writer.writeAll(if (peers.len > 0) " and the registry" else "the registry") catch {};
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
    registry: ?IpAddress = null,
    /// zcube-server: where the peers and their chunk filters are read (`/node-store/`).
    server: ?IpAddress = null,
    peers: [constants.fetch_peers_max]Peer = undefined,
    peer_count: u32 = 0,
    /// `--peer` values left out because the name is not a node name, and the first of them.
    peers_skipped: u32 = 0,
    first_skipped: []const u8 = "",
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
        } else if (std.mem.eql(u8, flag, "--digest")) {
            parsed.digest = value;
        } else if (std.mem.eql(u8, flag, "--registry")) {
            parsed.registry = parse_address(value) orelse return null;
        } else if (std.mem.eql(u8, flag, "--server")) {
            parsed.server = parse_address(value) orelse return null;
        } else if (std.mem.eql(u8, flag, "--peer")) {
            if (!parse_peer(&parsed, value)) return null;
        } else return null;
    }
    const complete = parsed.node.len > 0 and parsed.state_dir.len > 0 and
        parsed.images_dir.len > 0 and parsed.digest.len > 0 and parsed.registry != null;
    return if (complete) parsed else null;
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

pub const usage = "usage: zcube-agent fetch --node NAME --state-dir DIR --images-dir DIR " ++
    "--digest b3:HEX --registry HOST:PORT [--server HOST:PORT] [--peer NAME=HOST:PORT]...";

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
    const io = init.io;
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
    var store = dir_images.DirImages.open(io, gpa, parsed.images_dir) catch {
        diag.raise(.E0506);
        diag.cause("the images directory {s} can't be used", .{parsed.images_dir});
        diag.fix(.{ .sentence = "check the path and its permissions, and the free disk space" });
        return finish(io, &diag, constants.exit_environment);
    };
    defer store.close(gpa);
    const conns = gpa.alloc(Conn, constants.fetch_candidates_max) catch
        return no_memory(io, &diag);
    defer gpa.free(conns);
    @memset(conns, .{});
    var net: Net = .{
        .io = io,
        .registry = parsed.registry.?,
        .peers = &.{},
        .identity = identity,
        .reply = reply,
        .digest = parsed.digest,
        .conns = conns,
    };
    defer net.close_peers();
    return fetch_from(gpa, &net, &store, &parsed, &diag);
}

/// Finds the peers (the server's, then the named ones) and runs the worker over them.
fn fetch_from(
    gpa: std.mem.Allocator,
    net: *Net,
    store: *dir_images.DirImages,
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
    if (parsed.server) |server| {
        const arena = arena_state.allocator();
        const room: Slots = .{ all[found..], infos[found..] };
        found += discover(arena, net, server, parsed.node, room, &skipped);
    }
    var line: [320]u8 = undefined;
    note(io, describe_skipped(&line, skipped));
    net.peers = all[0..found];
    var report: fetch_worker.Report = .{};
    const transport = net.transport();
    const asked = infos[0..found];
    fetch_worker.fetch(gpa, transport, store, parsed.digest, asked, .{}, &report) catch |err| {
        return fetch_failed(net, diag, err);
    };
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

/// ZC-E0601 for a tree no source could give in time (exit 3, external); this node's own memory
/// or disk failing is exit 2, with the code of the one that ran out.
fn fetch_failed(net: *const Net, diag: *diag_mod.Diag, err: fetch_worker.Error) u8 {
    diag.reset();
    switch (err) {
        error.OutOfMemory, error.TooMany => {
            return no_memory(net.io, diag);
        },
        error.Store => {
            diag.raise(.E0506);
            diag.cause("the chunks could not be written to this node's images directory", .{});
            diag.fix(.{ .sentence = "check the directory's permissions and the free disk space" });
            return finish(net.io, diag, constants.exit_environment);
        },
        error.TreeUnavailable, error.ChunkFailed, error.Deadline => {},
    }
    var tried_buffer: [256]u8 = undefined;
    const tried = tried_sources(&tried_buffer, net.peers);
    fetch_worker.raise_tree_missing(diag, net.digest, tried);
    if (net.oversize) {
        diag.cause("the registry sent a reply larger than the {d} bytes a reply may have", .{
            reply_bytes,
        });
    }
    switch (err) {
        error.TreeUnavailable => diag.cause("no source sent a list that hashes to the digest", .{}),
        error.ChunkFailed => diag.cause("a chunk could not be had from any source asked", .{}),
        else => diag.cause("the fetch ran past its limit of {d} minutes", .{
            @divExact(constants.fetch_total_ms, 60_000),
        }),
    }
    return finish(net.io, diag, constants.exit_external);
}

/// What `select_candidates` fills: the peers and, beside them, their filters.
const Slots = struct { []Peer, []fetch_worker.PeerInfo };

/// Asks the server for the nodes' summaries and picks the candidates among them.
fn discover(
    arena: std.mem.Allocator,
    net: *Net,
    server: IpAddress,
    self: []const u8,
    slots: Slots,
    skipped: *Skipped,
) u32 {
    const scratch = arena.alloc(u8, discover_body_bytes_max) catch return 0;
    var target: [96]u8 = undefined;
    const form = "/v1/list?prefix=/node-store/&limit={d}";
    const path = std.fmt.bufPrint(&target, form, .{constants.fetch_candidates_max + 1}) catch
        return 0;
    const stores = switch (net.http_get(server, path, scratch)) {
        .bytes => |body| parse_kvs(arena, body),
        .refused, .timeout => null,
    } orelse {
        note(net.io, "zcube-agent fetch: the server's node list could not be read; peers: " ++
            "only those named\n");
        return 0;
    };
    const room = @min(slots[0].len, slots[1].len);
    return select_candidates(arena, stores, self, slots[0][0..room], slots[1][0..room], skipped);
}

// ---- Tests ----------------------------------------------------------------------------------

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
    try std.testing.expectEqual(@as(u32, 2), skipped.no_address);
    try std.testing.expectEqual(@as(u32, 2), skipped.no_filter);
    var line: [320]u8 = undefined;
    const said = describe_skipped(&line, skipped);
    try std.testing.expect(std.mem.startsWith(u8, said, "zcube-agent fetch: left out 7 nodes ("));
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
    const over = try arena.alloc(u8, discover_body_bytes_max + 1);
    @memset(over, ' ');
    try std.testing.expect(parse_kvs(arena, over) == null);
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
        tried_sources(&buffer, &peers),
    );
    try std.testing.expectEqualStrings("the registry", tried_sources(&buffer, &.{}));
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
