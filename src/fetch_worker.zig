//! The fetch worker's driver (docs/swarm.md, "The fetch worker"; C2 slice 6b): it gets one tree
//! into a `DirImages`, from peers first and from the registry when `fetch_plan` says so.
//!
//! The driver does no network itself. A `Transport` answers three questions (the tree's list
//! from a source, one chunk from a source, the time) and hears about blame, so the same driver
//! runs over `peer_stream` and a registry client in the agent and over a table in a test.
//!
//! * The tree's list is asked of the peers, then of the registry, and only a list whose
//!   BLAKE3 digest is the tree's digest is used (`node_store.list_matches`): a peer's list that
//!   does not match is counted in `Report.bad_lists` and the next source is tried.
//! * Every chunk goes through `Plan.receive`, which hashes it. Only chunks it calls `verified`
//!   are handed to `DirImages.put_chunk`, which hashes them again and refuses a mismatch, so a
//!   chunk that fails its hash reaches the disk by neither road.
//! * One request is in flight at a time. The plan allows more; the worker does not need them for
//!   chunks of 1 MiB on a LAN, and the plan's caps and its bookkeeping hold either way.
//! * A chunk the store already holds is not asked for again, so a fetch that was cut off resumes.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const chunk_summary = @import("chunk_summary.zig");
const dir_images = @import("dir_images.zig");
const fetch_plan = @import("fetch_plan.zig");
const node_store = @import("node_store.zig");

const Allocator = std.mem.Allocator;
const ChunkRef = fetch_plan.ChunkRef;

pub const Error = error{ TreeUnavailable, ChunkFailed, Store, OutOfMemory, TooMany };

/// A peer the worker may ask: its name for reports and the bytes of its chunk filter.
pub const PeerInfo = struct {
    name: []const u8,
    filter: []u8,
};

pub const Transport = struct {
    context: *anyopaque,
    /// The tree's list text from `source`, into `out`; null if the source has none or fails.
    tree_fn: *const fn (*anyopaque, fetch_plan.Source, []const u8, []u8) ?[]const u8,
    /// The chunk's bytes from `source`, into `out`.
    chunk_fn: *const fn (*anyopaque, fetch_plan.Source, ChunkRef, []u8) fetch_plan.Result,
    now_fn: *const fn (*anyopaque) u64,
    sleep_fn: *const fn (*anyopaque, u32) void,
    /// A peer was struck for sending bytes that do not match their hash (ZC-W0601).
    blame_fn: *const fn (*anyopaque, u8, u32, u32) void,
};

pub const Report = struct {
    chunks: u32 = 0,
    already_held: u32 = 0,
    registry_chunks: u32 = 0,
    peer_chunks: u32 = 0,
    bad_lists: u32 = 0,
    blamed: u32 = 0,
};

/// Gets the tree `digest` into `store`. `allocator` is used for the buffers of this call only.
pub fn fetch(
    allocator: Allocator,
    transport: Transport,
    store: *dir_images.DirImages,
    digest: []const u8,
    peers: []const PeerInfo,
    config: fetch_plan.Config,
    report: *Report,
) Error!void {
    assert(peers.len <= constants.fetch_peers_max);
    report.* = .{};
    const list_buffer = try allocator.alloc(u8, constants.tree_list_bytes_max);
    defer allocator.free(list_buffer);
    const refs = try allocator.alloc(ChunkRef, constants.fetch_chunks_max);
    defer allocator.free(refs);
    const list = try find_list(transport, digest, peers.len, list_buffer, report);
    const count = node_store.list_parse(list, refs) orelse return error.TreeUnavailable;
    store.put_tree(digest, list) catch return error.Store;
    const chunk_buffer = try allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer allocator.free(chunk_buffer);
    const needed = try lacking(store, refs[0..count], chunk_buffer, report);
    report.chunks = count;
    if (needed == 0) return;
    const states = try allocator.alloc(fetch_plan.ChunkState, needed);
    defer allocator.free(states);
    try run_plan(transport, store, refs[0..needed], states, peers, config, chunk_buffer, report);
}

/// The first list a source gives that is the tree's own. Peers first.
fn find_list(
    transport: Transport,
    digest: []const u8,
    peer_count: usize,
    out: []u8,
    report: *Report,
) Error![]const u8 {
    var index: usize = 0;
    while (index <= peer_count) : (index += 1) {
        const source: fetch_plan.Source = if (index < peer_count)
            .{ .peer = @intCast(index) }
        else
            .registry;
        const text = transport.tree_fn(transport.context, source, digest, out) orelse continue;
        if (node_store.list_matches(digest, text)) return text;
        report.bad_lists += 1;
    }
    return error.TreeUnavailable;
}

/// Moves the chunks the store lacks to the front of `refs`; returns how many.
fn lacking(
    store: *dir_images.DirImages,
    refs: []ChunkRef,
    scratch: []u8,
    report: *Report,
) Error!u32 {
    var kept: u32 = 0;
    for (refs, 0..) |ref, at| {
        if (store.images().read_chunk(&ref.hash, scratch)) |_| {
            report.already_held += 1;
            continue;
        } else |_| {}
        refs[kept] = refs[at];
        kept += 1;
    }
    return kept;
}

fn run_plan(
    transport: Transport,
    store: *dir_images.DirImages,
    chunks: []const ChunkRef,
    states: []fetch_plan.ChunkState,
    peers: []const PeerInfo,
    config: fetch_plan.Config,
    buffer: []u8,
    report: *Report,
) Error!void {
    var plan = fetch_plan.Plan.init(config, chunks, states, transport.now_fn(transport.context));
    for (peers) |peer| _ = plan.add_peer(chunk_summary.Filter.view(peer.filter));
    while (true) {
        const now = transport.now_fn(transport.context);
        switch (plan.next(now)) {
            .done => return,
            .failed => return error.ChunkFailed,
            .wait => |until| {
                const ms: u64 = if (until) |at| at -| now else 50;
                transport.sleep_fn(transport.context, @intCast(@min(@max(ms, 1), 1000)));
            },
            .request => |request| {
                const ref = chunks[request.chunk];
                const result = transport.chunk_fn(transport.context, request.source, ref, buffer);
                const after = transport.now_fn(transport.context);
                const outcome = plan.receive(request.id, result, after);
                if (outcome == .verified) {
                    const bytes = result.bytes[0..ref.bytes];
                    store.images().put_chunk(&ref.hash, bytes) catch return error.Store;
                    switch (request.source) {
                        .registry => report.registry_chunks += 1,
                        .peer => report.peer_chunks += 1,
                    }
                }
                while (plan.take_blame()) |blame| {
                    report.blamed += 1;
                    const total: u32 = @intCast(chunks.len);
                    transport.blame_fn(transport.context, blame.peer, blame.chunk, total);
                }
            },
        }
    }
}

// ---- Tests --------------------------------------------------------------------------------

const Blake3 = std.crypto.hash.Blake3;
const chunk_len = 64;
const tree_chunks = 6;

/// A table-driven source: `peer_has` is what the one peer holds, `corrupt` the chunk it
/// garbles, `registry_asked` counts the registry's chunk answers.
const Table = struct {
    bodies: [tree_chunks][chunk_len]u8 = undefined,
    refs: [tree_chunks]ChunkRef = undefined,
    list: [tree_chunks * 80]u8 = undefined,
    list_len: u32 = 0,
    digest: [67]u8 = undefined,
    corrupt: ?u32 = null,
    registry_up: bool = true,
    registry_asked: u32 = 0,
    peer_asked: u32 = 0,
    blames: u32 = 0,
    clock: u64 = 1000,
    garbage: [chunk_len]u8 = @splat(0xee),

    fn make(table: *Table) void {
        var writer: std.Io.Writer = .fixed(&table.list);
        for (&table.bodies, &table.refs, 0..) |*body, *ref, index| {
            @memset(body, @as(u8, @intCast(index)) + 1);
            ref.* = .{ .hash = undefined, .bytes = chunk_len };
            Blake3.hash(body, &ref.hash, .{});
            writer.print("{x} {d}\n", .{ &ref.hash, chunk_len }) catch unreachable; // Sized.
        }
        table.list_len = @intCast(writer.buffered().len);
        _ = node_store.list_digest(table.list[0..table.list_len], &table.digest);
    }

    fn from(context: *anyopaque) *Table {
        return @ptrCast(@alignCast(context));
    }

    fn tree(context: *anyopaque, source: fetch_plan.Source, _: []const u8, out: []u8) ?[]const u8 {
        const table = from(context);
        if (source == .registry and !table.registry_up) return null;
        @memcpy(out[0..table.list_len], table.list[0..table.list_len]);
        return out[0..table.list_len];
    }

    fn chunk(
        context: *anyopaque,
        source: fetch_plan.Source,
        ref: ChunkRef,
        out: []u8,
    ) fetch_plan.Result {
        const table = from(context);
        const index = for (table.refs, 0..) |held, at| {
            if (std.mem.eql(u8, &held.hash, &ref.hash)) break at;
        } else unreachable; // The plan asks only for the tree's chunks.
        switch (source) {
            .registry => {
                if (!table.registry_up) return .timeout;
                table.registry_asked += 1;
            },
            .peer => {
                table.peer_asked += 1;
                if (table.corrupt == @as(u32, @intCast(index))) return .{ .bytes = &table.garbage };
            },
        }
        @memcpy(out[0..chunk_len], &table.bodies[index]);
        return .{ .bytes = out[0..chunk_len] };
    }

    fn now(context: *anyopaque) u64 {
        return from(context).clock;
    }

    fn sleep(context: *anyopaque, ms: u32) void {
        from(context).clock += ms;
    }

    fn blame(context: *anyopaque, _: u8, _: u32, _: u32) void {
        from(context).blames += 1;
    }

    fn transport(table: *Table) Transport {
        return .{
            .context = table,
            .tree_fn = tree,
            .chunk_fn = chunk,
            .now_fn = now,
            .sleep_fn = sleep,
            .blame_fn = blame,
        };
    }
};

fn test_store(tmp: *std.testing.TmpDir) !dir_images.DirImages {
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/store", .{tmp.sub_path});
    return dir_images.DirImages.open(std.testing.io, std.testing.allocator, path);
}

fn full_filter(table: *const Table, bytes: []u8) void {
    var filter = chunk_summary.Filter.init(bytes);
    for (&table.refs) |*ref| filter.add(&ref.hash);
}

test "a tree is fetched from a peer, a corrupt chunk strikes the peer and the registry finishes" {
    // Goal: the worker's contract. Method: one peer that holds everything but garbles chunk 2.
    // The tree must end up whole and verified in the store, the peer blamed once, the garbled
    // chunk not on disk, and the registry asked for that chunk alone.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    var table: Table = .{};
    table.make();
    table.corrupt = 2;
    var filter: [64]u8 = undefined;
    full_filter(&table, &filter);
    const peers = [_]PeerInfo{.{ .name = "node2", .filter = &filter }};
    var report: Report = .{};
    const config: fetch_plan.Config = .{};
    const transport = table.transport();
    const gpa = std.testing.allocator;
    try fetch(gpa, transport, &store, &table.digest, &peers, config, &report);
    try std.testing.expect(store.images().has(&table.digest));
    try std.testing.expectEqual(@as(u32, 1), table.blames);
    // The peer is struck for the rest of the fetch: chunks 0 and 1 came from it, and chunk 2
    // (the garbled one) and everything after it from the registry.
    try std.testing.expectEqual(@as(u32, 2), report.peer_chunks);
    try std.testing.expectEqual(@as(u32, tree_chunks - 2), table.registry_asked);
    var out: [constants.swarm_chunk_bytes]u8 = undefined;
    const read = try store.images().read_chunk(&table.refs[2].hash, out[0..]);
    try std.testing.expectEqualSlices(u8, &table.bodies[2], read);
}

test "a second fetch asks for nothing, and a tree no source has fails" {
    // Goal: resuming costs nothing and the failure is an error, not a hang. Method: fetch twice
    // (no peer asked the second time), then a fresh store with the registry down and no peers.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    var table: Table = .{};
    table.make();
    var report: Report = .{};
    const config: fetch_plan.Config = .{};
    const transport = table.transport();
    try fetch(std.testing.allocator, transport, &store, &table.digest, &.{}, config, &report);
    try std.testing.expectEqual(@as(u32, tree_chunks), table.registry_asked);
    try fetch(std.testing.allocator, transport, &store, &table.digest, &.{}, config, &report);
    try std.testing.expectEqual(@as(u32, tree_chunks), table.registry_asked);
    try std.testing.expectEqual(@as(u32, tree_chunks), report.already_held);

    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    var other = try test_store(&empty);
    defer other.close(std.testing.allocator);
    table.registry_up = false;
    const gpa = std.testing.allocator;
    const failed = fetch(gpa, transport, &other, &table.digest, &.{}, config, &report);
    try std.testing.expectError(error.TreeUnavailable, failed);
}
