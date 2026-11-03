//! What a peer's request is answered with (docs/peer.md, "The peer server"; C2 slice 6b).
//!
//! The peer server is read-only. Each request is one `GET` on a handshaken connection; this file
//! turns the request line and an optional `Range` into a status and a body from the agent's
//! `Images`, and nothing else: no socket, no file, no clock (the shell, `peer_server.zig`, owns
//! those), so it runs in the core's tests.
//!
//!   GET /v1/peer/trees/<digest>        the tree's chunk list, as the text its digest names
//!   GET /v1/peer/chunk/<64 hex>        the chunk, which the store checked against its hash first
//!                                      (`Range: bytes=A-B`, inclusive, answers 206)
//!
//! A path the server does not know is 404, a method other than GET is 405, a malformed name or
//! range is 400, a range outside the chunk is 416, and a chunk the store cannot vouch for (its
//! bytes no longer match its hash) is 500, never served. There is no route for an object listing:
//! a fake tree is flat, and the objects model arrives with the real store (docs/swarm.md).

const std = @import("std");
const assert = std.debug.assert;
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const node_store = @import("node_store.zig");

const ChunkRef = @import("fetch_plan.zig").ChunkRef;
const Hash = chunk_summary.Hash;

pub const path_trees = "/v1/peer/trees/";
pub const path_chunk = "/v1/peer/chunk/";

/// The scratch bytes `answer` needs: one chunk, or one tree list.
pub const scratch_bytes: u32 = @max(constants.swarm_chunk_bytes, constants.tree_list_bytes_max);

pub const Reply = struct {
    status: u16,
    /// Borrowed from the scratch given to `answer`, or a static message.
    body: []const u8,
    /// For 206: the first and last byte sent and the chunk's size (`Content-Range`).
    range: ?struct { first: u32, last: u32, total: u32 } = null,
};

/// The `Range` header's value (`bytes=A-B`), or null for none; `error.Bad` for any other form.
/// Only a closed range is served: a peer asks for the pieces it wants.
pub fn parse_range(value: []const u8) error{Bad}!struct { first: u32, last: u32 } {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, prefix)) return error.Bad;
    const spec = value[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.Bad;
    const first = std.fmt.parseInt(u32, spec[0..dash], 10) catch return error.Bad;
    const last = std.fmt.parseInt(u32, spec[dash + 1 ..], 10) catch return error.Bad;
    if (first > last) return error.Bad;
    return .{ .first = first, .last = last };
}

/// The reply to `method target` with the `Range` header value `range_header` (null if none).
/// `scratch` holds the body: `scratch_bytes` long. `refs` holds a tree's chunks:
/// `fetch_chunks_max` long.
pub fn answer(
    images: node_store.Images,
    method: []const u8,
    target: []const u8,
    range_header: ?[]const u8,
    scratch: []u8,
    refs: []ChunkRef,
) Reply {
    assert(scratch.len >= scratch_bytes);
    assert(refs.len >= constants.fetch_chunks_max);
    if (std.mem.startsWith(u8, target, path_trees) or std.mem.startsWith(u8, target, path_chunk)) {
        if (!std.mem.eql(u8, method, "GET")) return fixed(405, "peer routes are read-only");
    } else return fixed(404, "no such route");
    if (std.mem.startsWith(u8, target, path_trees)) {
        return tree(images, target[path_trees.len..], scratch, refs);
    }
    return chunk(images, target[path_chunk.len..], range_header, scratch);
}

fn fixed(status: u16, message: []const u8) Reply {
    return .{ .status = status, .body = message };
}

fn tree(images: node_store.Images, digest: []const u8, scratch: []u8, refs: []ChunkRef) Reply {
    if (digest.len < 11 or digest.len > 67) return fixed(400, "not a tree digest");
    const count = images.chunk_list(digest, refs) catch |err| switch (err) {
        error.NotFound => return fixed(404, "no such tree"),
        else => return fixed(500, "the store failed"),
    };
    const text = node_store.list_format(refs[0..count], scratch) orelse
        return fixed(500, "the store failed");
    return .{ .status = 200, .body = text };
}

fn chunk(
    images: node_store.Images,
    name: []const u8,
    range_header: ?[]const u8,
    scratch: []u8,
) Reply {
    var hash: Hash = undefined;
    if (name.len != 64) return fixed(400, "not a chunk hash");
    _ = std.fmt.hexToBytes(&hash, name) catch return fixed(400, "not a chunk hash");
    const wanted = if (range_header) |value| parse_range(value) catch
        return fixed(400, "not a range this server serves") else null;
    const bytes = images.read_chunk(&hash, scratch[0..constants.swarm_chunk_bytes]) catch |err| {
        return switch (err) {
            error.NotFound => fixed(404, "no such chunk"),
            error.BadHash => fixed(500, "the chunk on disk does not match its hash"),
            else => fixed(500, "the store failed"),
        };
    };
    const total: u32 = @intCast(bytes.len);
    const span = wanted orelse return .{ .status = 200, .body = bytes };
    if (span.first >= total) return fixed(416, "the range starts past the chunk");
    const last = @min(span.last, total - 1);
    return .{
        .status = 206,
        .body = bytes[span.first .. last + 1],
        .range = .{ .first = span.first, .last = last, .total = total },
    };
}

// ---- Tests --------------------------------------------------------------------------------

/// One tree of two chunks, in memory; `damaged` makes the second chunk fail its check.
const Mem = struct {
    refs: [2]ChunkRef = undefined,
    bodies: [2][100]u8 = undefined,
    digest: [67]u8 = undefined,
    damaged: bool = false,

    fn init(mem: *Mem) void {
        for (&mem.bodies, &mem.refs, 0..) |*body, *ref, index| {
            for (body, 0..) |*byte, at| byte.* = @intCast((index * 31 + at) % 251);
            std.crypto.hash.Blake3.hash(body, &ref.hash, .{});
            ref.bytes = body.len;
        }
        var text: [200]u8 = undefined;
        const text_list = node_store.list_format(&mem.refs, &text).?;
        _ = node_store.list_digest(text_list, &mem.digest);
    }

    fn images(mem: *Mem) node_store.Images {
        return .{
            .context = mem,
            .summary_fn = summary,
            .chunk_list_fn = list,
            .read_chunk_fn = read,
        };
    }

    fn from(context: *anyopaque) *Mem {
        return @ptrCast(@alignCast(context));
    }

    fn summary(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: []const []const u8,
    ) node_store.Error!node_store.Summary {
        return .{};
    }

    fn list(
        context: *anyopaque,
        tree_name: []const u8,
        out: []ChunkRef,
    ) node_store.ChunkError!u32 {
        const mem = from(context);
        if (!std.mem.eql(u8, tree_name, &mem.digest)) return error.NotFound;
        @memcpy(out[0..2], &mem.refs);
        return 2;
    }

    fn read(context: *anyopaque, hash: *const Hash, out: []u8) node_store.ChunkError![]u8 {
        const mem = from(context);
        for (mem.refs, 0..) |ref, index| {
            if (!std.mem.eql(u8, &ref.hash, hash)) continue;
            if (mem.damaged and index == 1) return error.BadHash;
            @memcpy(out[0..100], &mem.bodies[index]);
            return out[0..100];
        }
        return error.NotFound;
    }
};

const Rig = struct {
    mem: Mem = .{},
    scratch: []u8,
    refs: []ChunkRef,

    fn init() !Rig {
        var rig: Rig = .{
            .scratch = try std.testing.allocator.alloc(u8, scratch_bytes),
            .refs = try std.testing.allocator.alloc(ChunkRef, constants.fetch_chunks_max),
        };
        rig.mem.init();
        return rig;
    }

    fn deinit(rig: *Rig) void {
        std.testing.allocator.free(rig.scratch);
        std.testing.allocator.free(rig.refs);
    }

    fn get(rig: *Rig, target: []const u8, range: ?[]const u8) Reply {
        return answer(rig.mem.images(), "GET", target, range, rig.scratch, rig.refs);
    }

    fn chunk_path(rig: *Rig, buffer: []u8, index: usize) []const u8 {
        const hash = &rig.mem.refs[index].hash;
        // Sized: the buffer holds a path and 64 digits.
        return std.fmt.bufPrint(buffer, "{s}{x}", .{ path_chunk, hash }) catch unreachable;
    }
};

test "a tree is served as the list its digest names, and a missing tree is 404" {
    // Goal: the tree route answers from the store and nothing else. Method: the held digest, an
    // unheld one, a malformed one, and one that tries to leave the directory.
    var rig = try Rig.init();
    defer rig.deinit();
    var target: [128]u8 = undefined;
    const held = try std.fmt.bufPrint(&target, "{s}{s}", .{ path_trees, rig.mem.digest });
    const reply = rig.get(held, null);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expect(node_store.list_matches(&rig.mem.digest, reply.body));
    try std.testing.expectEqual(@as(u16, 404), rig.get(path_trees ++ "b3:12345678", null).status);
    try std.testing.expectEqual(@as(u16, 400), rig.get(path_trees ++ "../etc", null).status);
    try std.testing.expectEqual(@as(u16, 404), rig.get("/v1/peer/other", null).status);
    try std.testing.expectEqual(@as(u16, 404), rig.get("/v1/agent/nodes/node1/store", null).status);
}

test "a range is served exactly, clamped at the end, and refused past it" {
    // Goal: a range bound holds: the body is never longer than asked or than the chunk, a range
    // that starts past the end is 416, and a malformed one is 400. Method: ranges around the
    // end of a 100-byte chunk.
    var rig = try Rig.init();
    defer rig.deinit();
    var buffer: [128]u8 = undefined;
    const path = rig.chunk_path(&buffer, 0);
    const whole = rig.get(path, null);
    try std.testing.expectEqual(@as(u16, 200), whole.status);
    try std.testing.expectEqualSlices(u8, &rig.mem.bodies[0], whole.body);
    const middle = rig.get(path, "bytes=10-19");
    try std.testing.expectEqual(@as(u16, 206), middle.status);
    try std.testing.expectEqualSlices(u8, rig.mem.bodies[0][10..20], middle.body);
    try std.testing.expectEqual(@as(u32, 100), middle.range.?.total);
    const clamped = rig.get(path, "bytes=90-4000");
    try std.testing.expectEqual(@as(usize, 10), clamped.body.len);
    try std.testing.expectEqual(@as(u32, 99), clamped.range.?.last);
    try std.testing.expectEqual(@as(u16, 416), rig.get(path, "bytes=100-120").status);
    for ([_][]const u8{ "bytes=5-", "bytes=-5", "bytes=9-3", "items=0-1", "bytes=0-1,5-6" }) |bad| {
        try std.testing.expectEqual(@as(u16, 400), rig.get(path, bad).status);
    }
}

test "a missing or damaged chunk is not served, and the server is read-only" {
    // Goal: 404 for a chunk the store lacks, 500 (never the bytes) for one that fails its hash,
    // 400 for a name that is not a hash, 405 for any method but GET. Method: one case each.
    var rig = try Rig.init();
    defer rig.deinit();
    var buffer: [128]u8 = undefined;
    const second = rig.chunk_path(&buffer, 1);
    try std.testing.expectEqual(@as(u16, 200), rig.get(second, null).status);
    rig.mem.damaged = true;
    const damaged = rig.get(second, null);
    try std.testing.expectEqual(@as(u16, 500), damaged.status);
    try std.testing.expect(damaged.body.len < 64); // A message, not 100 bytes of chunk.
    const zeros: [64]u8 = @splat('0');
    const absent = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ path_chunk, &zeros });
    try std.testing.expectEqual(@as(u16, 404), rig.get(absent, null).status);
    try std.testing.expectEqual(@as(u16, 400), rig.get(path_chunk ++ "../../x", null).status);
    for ([_][]const u8{ "PUT", "POST", "DELETE" }) |method| {
        const reply = answer(rig.mem.images(), method, second, null, rig.scratch, rig.refs);
        try std.testing.expectEqual(@as(u16, 405), reply.status);
    }
}
