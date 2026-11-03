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

const IpAddress = std.Io.net.IpAddress;
const ChunkRef = fetch_plan.ChunkRef;
const Source = fetch_plan.Source;

pub const Peer = struct { name: []const u8, address: IpAddress };

const reply_head_bytes = 14;

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
                return net.registry_get(path, out);
            },
            .peer => |index| {
                const prefix = peer_serve.path_trees;
                const path = std.fmt.bufPrint(&target, "{s}{s}", .{ prefix, digest }) catch
                    return null;
                return net.peer_get(net.peers[index], path, out);
            },
        }
    }

    fn chunk(context: *anyopaque, source: Source, ref: ChunkRef, out: []u8) fetch_plan.Result {
        const net = from(context);
        var target: [128]u8 = undefined;
        const got = switch (source) {
            .registry => blk: {
                const path = std.fmt.bufPrint(&target, "/chunks/{x}", .{&ref.hash}) catch
                    return .refused;
                break :blk net.registry_get(path, out);
            },
            .peer => |index| blk: {
                const prefix = peer_serve.path_chunk;
                const path = std.fmt.bufPrint(&target, "{s}{x}", .{ prefix, &ref.hash }) catch
                    return .refused;
                break :blk net.peer_get(net.peers[index], path, out);
            },
        };
        return if (got) |bytes| .{ .bytes = bytes } else .timeout;
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

    /// The body of `GET path` from the registry, or null on any failure.
    fn registry_get(net: *Net, path: []const u8, out: []u8) ?[]const u8 {
        return net.http_get(net.registry, path, out);
    }

    /// The body of a plain-HTTP `GET path` from `address`, or null on any failure.
    fn http_get(net: *Net, address: IpAddress, path: []const u8, out: []u8) ?[]const u8 {
        const end = peer_stream.boot_ms(net.io) + constants.fetch_request_timeout_ms;
        const fd = peer_stream.connect(net.io, address, end) catch return null;
        defer _ = std.os.linux.close(fd);
        var request: [192]u8 = undefined;
        const form = "GET {s} HTTP/1.0\r\nHost: registry\r\n\r\n";
        const text = std.fmt.bufPrint(&request, form, .{path}) catch return null;
        write_all(fd, text) catch return null;
        const got = read_until_close(net.io, fd, net.reply, end) orelse return null;
        const body = http_body(got) orelse return null;
        if (body.len > out.len) return null;
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }

    /// The body of `GET path` from `who`, over an authenticated stream, or null.
    fn peer_get(net: *Net, who: Peer, path: []const u8, out: []u8) ?[]const u8 {
        const identity = net.identity orelse return null;
        const end = peer_stream.boot_ms(net.io) + constants.fetch_request_timeout_ms;
        const fd = peer_stream.connect(net.io, who.address, end) catch return null;
        defer _ = std.os.linux.close(fd);
        var stream = peer_stream.open_client(net.io, fd, &identity, who.name, end) catch
            return null;
        defer stream.deinit();
        var request: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&request, "GET {s}\n", .{path}) catch return null;
        stream.send(text, end) catch return null;
        const head = stream.recv(net.reply[0..reply_head_bytes], end) catch return null;
        if (head.len != reply_head_bytes) return null;
        if (std.mem.readInt(u16, head[0..2], .big) != 200) return null;
        const body = stream.recv(out, end) catch return null;
        return body;
    }
};

fn write_all(fd: std.posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const wrote = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (std.os.linux.errno(wrote) != .SUCCESS) return error.Io;
        done += wrote;
    }
}

/// Reads `fd` to its end into `buffer` (null if it does not fit or the deadline passes).
fn read_until_close(io: std.Io, fd: std.posix.fd_t, buffer: []u8, end_ms: u64) ?[]u8 {
    var filled: usize = 0;
    while (true) {
        const now_ms = peer_stream.boot_ms(io);
        if (now_ms >= end_ms) return null;
        var wait = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&wait, @intCast(end_ms - now_ms)) catch return null;
        if (ready == 0) return null;
        if (filled == buffer.len) return null;
        const got = std.os.linux.read(fd, buffer[filled..].ptr, buffer.len - filled);
        if (std.os.linux.errno(got) != .SUCCESS) return null;
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

/// The peers the control plane knows (`/nodes/<n>` with an address, `/node-store/<n>` with a
/// chunk filter), other than `self`, written to `peers` and `infos`; their count. Anything
/// malformed or incomplete is skipped: discovery only ever adds sources, and the registry
/// remains. Strings live in `arena`.
fn discover(
    arena: std.mem.Allocator,
    net: *Net,
    server: IpAddress,
    self: []const u8,
    peers: []Peer,
    infos: []fetch_worker.PeerInfo,
) u32 {
    const body = arena.alloc(u8, constants.swarm_chunk_bytes) catch return 0;
    const nodes = list_prefix(arena, net, server, "/nodes/", body) orelse return 0;
    const stores = list_prefix(arena, net, server, "/node-store/", body) orelse return 0;
    var count: u32 = 0;
    for (nodes) |kv| {
        if (count == peers.len) break;
        const name = string_field(kv.value, "name") orelse continue;
        const address_text = string_field(kv.value, "address") orelse continue;
        if (name.len == 0 or std.mem.eql(u8, name, self)) continue;
        const address = parse_address(address_text) orelse continue;
        const filter = filter_of(arena, stores, name) orelse continue;
        peers[count] = .{ .name = name, .address = address };
        infos[count] = .{ .name = name, .filter = filter };
        count += 1;
    }
    return count;
}

const Kv = struct { key: []const u8, value: std.json.Value };

fn list_prefix(
    arena: std.mem.Allocator,
    net: *Net,
    server: IpAddress,
    prefix: []const u8,
    scratch: []u8,
) ?[]const Kv {
    var target: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&target, "/v1/list?prefix={s}&limit=500", .{prefix}) catch
        return null;
    const body = net.http_get(server, path, scratch) orelse return null;
    const Listed = struct { kvs: []const Kv };
    const parsed = std.json.parseFromSliceLeaky(Listed, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.kvs;
}

fn string_field(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// The decoded chunk filter of `/node-store/<node>` among `stores`, or null if it has none that
/// fits `chunk_summary.Filter`.
fn filter_of(arena: std.mem.Allocator, stores: []const Kv, node: []const u8) ?[]u8 {
    for (stores) |kv| {
        const prefix = "/node-store/";
        if (!std.mem.startsWith(u8, kv.key, prefix)) continue;
        if (!std.mem.eql(u8, kv.key[prefix.len..], node)) continue;
        const hex = string_field(kv.value, "filter") orelse return null;
        const size = hex.len / 2;
        const fits = hex.len % 2 == 0 and size >= 8 and size <= constants.summary_filter_bytes_max;
        if (!fits) return null;
        const bytes = arena.alloc(u8, size) catch return null;
        _ = std.fmt.hexToBytes(bytes, hex) catch return null;
        return bytes;
    }
    return null;
}

/// "node2, node3 and the registry", or "the registry" when there are no peers.
fn tried_sources(buffer: []u8, peers: []const Peer) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (peers) |who| writer.print("{s}, ", .{who.name}) catch break;
    writer.writeAll(if (peers.len > 0) "and the registry" else "the registry") catch {};
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
    /// zcube-server: where the peers and their chunk filters are read (`/nodes/`, `/node-store/`).
    server: ?IpAddress = null,
    peers: [constants.fetch_peers_max]Peer = undefined,
    peer_count: u32 = 0,
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
            const equals = std.mem.findScalar(u8, value, '=') orelse return null;
            if (parsed.peer_count == parsed.peers.len) return null;
            const address = parse_address(value[equals + 1 ..]) orelse return null;
            parsed.peers[parsed.peer_count] = .{ .name = value[0..equals], .address = address };
            parsed.peer_count += 1;
        } else return null;
    }
    const complete = parsed.node.len > 0 and parsed.state_dir.len > 0 and
        parsed.images_dir.len > 0 and parsed.digest.len > 0 and parsed.registry != null;
    return if (complete) parsed else null;
}

fn parse_address(text: []const u8) ?IpAddress {
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    return IpAddress.parse(text[0..colon], port) catch null;
}

pub const usage = "usage: zcube-agent fetch --node NAME --state-dir DIR --images-dir DIR " ++
    "--digest b3:HEX --registry HOST:PORT [--server HOST:PORT] [--peer NAME=HOST:PORT]...\n";

pub fn run(init: std.process.Init, args: []const []const u8) u8 {
    const io = init.io;
    const stderr = std.Io.File.stderr();
    const parsed = parse(args) orelse {
        stderr.writeStreamingAll(io, usage) catch {}; // Nowhere else to say it.
        return constants.exit_user;
    };
    const gpa = init.gpa;
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const identity = agent_peer.load_identity(io, parsed.state_dir, parsed.node, &diag) catch null;
    const reply = gpa.alloc(u8, constants.swarm_chunk_bytes + 4096) catch
        return constants.exit_environment;
    defer gpa.free(reply);
    var store = dir_images.DirImages.open(io, gpa, parsed.images_dir) catch
        return constants.exit_environment;
    defer store.close(gpa);
    var net: Net = .{
        .io = io,
        .registry = parsed.registry.?,
        .peers = parsed.peers[0..parsed.peer_count],
        .identity = identity,
        .reply = reply,
        .digest = parsed.digest,
    };
    var infos: [constants.fetch_peers_max]fetch_worker.PeerInfo = undefined;
    var filter: [64]u8 = undefined;
    _ = chunk_summary.Filter.init(&filter);
    @memset(&filter, 0xff); // A named peer is assumed to hold everything: the plan strikes liars.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var all: [constants.fetch_peers_max]Peer = undefined;
    var found: u32 = 0;
    if (parsed.server) |server| {
        const room = all.len - parsed.peer_count;
        found = discover(arena_state.allocator(), &net, server, parsed.node, all[0..room], &infos);
    }
    for (parsed.peers[0..parsed.peer_count]) |named| {
        all[found] = named;
        infos[found] = .{ .name = named.name, .filter = &filter };
        found += 1;
    }
    net.peers = all[0..found];
    var report: fetch_worker.Report = .{};
    const peers = infos[0..found];
    const transport = net.transport();
    fetch_worker.fetch(gpa, transport, &store, parsed.digest, peers, .{}, &report) catch |err| {
        var tried_buffer: [256]u8 = undefined;
        const tried = tried_sources(&tried_buffer, net.peers);
        diag.reset();
        fetch_worker.raise_tree_missing(&diag, parsed.digest, tried);
        diag.cause("the last failure was {t}", .{err});
        emit(io, &diag);
        return 1;
    };
    var buffer: [256]u8 = undefined;
    const said = "zcube-agent fetch: {s} chunks {d} held {d} peers {d} registry {d} " ++
        "bad lists {d}\n";
    const line = std.fmt.bufPrint(&buffer, said, .{
        parsed.digest,      report.chunks,          report.already_held,
        report.peer_chunks, report.registry_chunks, report.bad_lists,
    }) catch return 0;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {}; // Nowhere else to say it.
    return 0;
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
