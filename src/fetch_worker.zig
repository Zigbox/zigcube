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
const diag_mod = @import("diag.zig");
const node_store = @import("node_store.zig");

const Allocator = std.mem.Allocator;
const ChunkRef = fetch_plan.ChunkRef;

/// A whole tree digest as text: `b3:` and 64 hex digits of BLAKE3.
const full_digest_len = 3 + 64;

pub const Error = error{ TreeUnavailable, ChunkFailed, Deadline, Store, OutOfMemory, TooMany };

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
    /// A peer sent a chunk list that does not hash to the tree's digest (ZC-W0602); the argument
    /// is the peer's index.
    bad_list_fn: *const fn (*anyopaque, u8) void,
    /// The Zigbox bundle of the tree (`zigbox_fetch.zig`) from a peer, into `out`; null if the
    /// source has none. Registries have none: their fallback is Zigbox's `pull`.
    bundle_fn: *const fn (*anyopaque, fetch_plan.Source, []const u8, []u8) ?[]const u8 = no_bundle,
    /// The fetch changed phase (#93: say where it is). Arguments: chunks in the tree, chunks
    /// lacking here (`.chunks_done` passes 0 for both).
    phase_fn: *const fn (*anyopaque, Phase, u32, u32) void = no_phase,
};

pub const Phase = enum { bundle_found, chunks_done };

fn no_phase(_: *anyopaque, _: Phase, _: u32, _: u32) void {}

fn no_bundle(_: *anyopaque, _: fetch_plan.Source, _: []const u8, _: []u8) ?[]const u8 {
    return null;
}

/// Raises ZC-W0602: `peer_name` sent a chunk list that is not the tree's.
pub fn raise_bad_tree(diag: *diag_mod.Diag, peer_name: []const u8, digest: []const u8) void {
    diag.raise(.W0602);
    diag.cause("peer {s} sent a chunk list that does not hash to tree {s}", .{
        peer_name, digest,
    });
    diag.fix(.{
        .sentence = "no action needed for this fetch; if it repeats, check that peer node",
    });
}

/// Raises ZC-E0601: no source had `digest`. `tried` is the sentence naming the sources.
pub fn raise_tree_missing(diag: *diag_mod.Diag, digest: []const u8, tried: []const u8) void {
    diag.raise(.E0601);
    diag.cause("tree {s} was tried at {s}", .{ digest, tried });
    const sentence = "check the registry is reachable from this node and the digest was pushed";
    diag.fix(.{ .sentence = sentence });
}

pub const Report = struct {
    chunks: u32 = 0,
    already_held: u32 = 0,
    registry_chunks: u32 = 0,
    peer_chunks: u32 = 0,
    bad_lists: u32 = 0,
    blamed: u32 = 0,
    /// Bytes by source (C2 slice 7, `/pulls`): what the registry gave, what each peer gave (by
    /// the place in the caller's list), and what the store already held.
    registry_bytes: u64 = 0,
    peer_bytes: [constants.fetch_candidates_max]u64 = @splat(0),
    cached_bytes: u64 = 0,
    /// Bit `i` is set for a peer (by the place in the caller's list) the plan struck.
    struck_peers: u64 = 0,
};

comptime {
    assert(constants.fetch_candidates_max <= 64); // `struck_peers` is a u64.
}

/// Gets the tree `digest` into `store`. `allocator` is used for the buffers of this call only.
pub fn fetch(
    allocator: Allocator,
    transport: Transport,
    store: *dir_images.DirImages,
    digest: []const u8,
    all_peers: []const PeerInfo,
    config: fetch_plan.Config,
    report: *Report,
) Error!void {
    assert(all_peers.len <= constants.fetch_candidates_max);
    report.* = .{};
    assert(config.total_ms > 0);
    const deadline = transport.now_fn(transport.context) + config.total_ms;
    // A peer is not trusted: only the whole digest (`b3:` and 64 hex) holds its list to the
    // tree. A shorter one (8 hex is 32 bits) could be matched by a forged list, so such a tree
    // comes from the registry alone.
    const peers = if (digest.len == full_digest_len) all_peers else all_peers[0..0];
    const list_buffer = try allocator.alloc(u8, constants.tree_list_bytes_max);
    defer allocator.free(list_buffer);
    const refs = try allocator.alloc(ChunkRef, constants.fetch_chunks_max);
    defer allocator.free(refs);
    const asked = @min(peers.len, constants.fetch_list_peers_max);
    const list = try find_list(transport, digest, asked, list_buffer, deadline, report);
    const count = node_store.list_parse(list, refs) orelse return error.TreeUnavailable;
    store.put_tree(digest, list) catch return error.Store;
    const chunk_buffer = try allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer allocator.free(chunk_buffer);
    const needed = try lacking(store.images(), refs[0..count], chunk_buffer, report);
    report.chunks = count;
    if (needed == 0) return;
    const states = try allocator.alloc(fetch_plan.ChunkState, needed);
    defer allocator.free(states);
    const ranked = rank_peers(peers, refs[0..needed]);
    const run: Run = .{ .deadline = deadline, .config = config, .ranked = ranked };
    const images = store.images();
    try run_plan(transport, images, refs[0..needed], states, peers, &run, chunk_buffer, report);
}

/// The peers a plan uses, best first: `order[i]` is the index in the caller's `peers` of the
/// plan's peer `i`.
pub const Ranked = struct {
    order: [constants.fetch_peers_max]u8 = undefined,
    count: u8 = 0,
};

/// What `run_plan` needs besides its buffers.
pub const Run = struct {
    deadline: u64,
    config: fetch_plan.Config,
    ranked: Ranked,
};

/// Picks the `fetch_peers_max` peers whose filters claim the most of `chunks`, most first (ties
/// keep the caller's order). A peer that claims none is left out: the plan would never ask it.
pub fn rank_peers(peers: []const PeerInfo, chunks: []const ChunkRef) Ranked {
    assert(peers.len <= constants.fetch_candidates_max);
    var claims: [constants.fetch_candidates_max]u32 = @splat(0);
    for (peers, 0..) |peer, at| {
        const filter = chunk_summary.Filter.view(peer.filter);
        for (chunks) |ref| {
            if (filter.maybe_has(&ref.hash)) claims[at] += 1;
        }
    }
    var ranked: Ranked = .{};
    while (ranked.count < constants.fetch_peers_max) {
        var best: ?usize = null;
        for (claims[0..peers.len], 0..) |claimed, at| {
            if (claimed == 0) continue;
            if (best == null or claimed > claims[best.?]) best = at;
        }
        const at = best orelse break;
        ranked.order[ranked.count] = @intCast(at);
        ranked.count += 1;
        claims[at] = 0;
    }
    return ranked;
}

/// The first list a source gives that is the tree's own. Peers first.
fn find_list(
    transport: Transport,
    digest: []const u8,
    peer_count: usize,
    out: []u8,
    deadline: u64,
    report: *Report,
) Error![]const u8 {
    var index: usize = 0;
    while (index <= peer_count) : (index += 1) {
        if (transport.now_fn(transport.context) >= deadline) return error.Deadline;
        const source: fetch_plan.Source = if (index < peer_count)
            .{ .peer = @intCast(index) }
        else
            .registry;
        const text = transport.tree_fn(transport.context, source, digest, out) orelse continue;
        if (node_store.list_matches(digest, text)) return text;
        report.bad_lists += 1;
        if (index < peer_count) transport.bad_list_fn(transport.context, @intCast(index));
    }
    return error.TreeUnavailable;
}

/// Moves the chunks the store lacks to the front of `refs`; returns how many.
pub fn lacking(
    store: node_store.Images,
    refs: []ChunkRef,
    scratch: []u8,
    report: *Report,
) Error!u32 {
    var kept: u32 = 0;
    for (refs, 0..) |ref, at| {
        if (store.read_chunk(&ref.hash, scratch)) |_| {
            report.already_held += 1;
            report.cached_bytes += ref.bytes;
            continue;
        } else |_| {}
        refs[kept] = refs[at];
        kept += 1;
    }
    return kept;
}

pub fn run_plan(
    transport: Transport,
    store: node_store.Images,
    chunks: []const ChunkRef,
    states: []fetch_plan.ChunkState,
    peers: []const PeerInfo,
    run: *const Run,
    buffer: []u8,
    report: *Report,
) Error!void {
    const start = transport.now_fn(transport.context);
    var plan = fetch_plan.Plan.init(run.config, chunks, states, start);
    const order = run.ranked.order[0..run.ranked.count];
    for (order) |original| _ = plan.add_peer(chunk_summary.Filter.view(peers[original].filter));
    while (true) {
        const now = transport.now_fn(transport.context);
        if (now >= run.deadline) return error.Deadline;
        switch (plan.next(now)) {
            .done => return,
            .failed => return error.ChunkFailed,
            .wait => |until| {
                const ms: u64 = if (until) |at| at -| now else 50;
                transport.sleep_fn(transport.context, @intCast(@min(@max(ms, 1), 1000)));
            },
            .request => |request| {
                const ref = chunks[request.chunk];
                // The transport knows peers by their place in the caller's list.
                const source: fetch_plan.Source = switch (request.source) {
                    .registry => .registry,
                    .peer => |ranked| .{ .peer = order[ranked] },
                };
                const result = transport.chunk_fn(transport.context, source, ref, buffer);
                const after = transport.now_fn(transport.context);
                const outcome = plan.receive(request.id, result, after);
                if (outcome == .verified) {
                    const bytes = result.bytes[0..ref.bytes];
                    store.put_chunk(&ref.hash, bytes) catch return error.Store;
                    switch (request.source) {
                        .registry => {
                            report.registry_chunks += 1;
                            report.registry_bytes += ref.bytes;
                        },
                        .peer => {
                            report.peer_chunks += 1;
                            report.peer_bytes[source.peer] += ref.bytes;
                        },
                    }
                }
                while (plan.take_blame()) |blame| {
                    report.blamed += 1;
                    report.struck_peers |= @as(u64, 1) << @intCast(order[blame.peer]);
                    const total: u32 = @intCast(chunks.len);
                    transport.blame_fn(transport.context, order[blame.peer], blame.chunk, total);
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
    digest: [full_digest_len]u8 = undefined,
    corrupt: ?u32 = null,
    registry_up: bool = true,
    registry_asked: u32 = 0,
    peer_asked: u32 = 0,
    blames: u32 = 0,
    clock: u64 = 1000,
    /// What each reading of the clock adds, to make time pass while nothing sleeps.
    tick: u64 = 0,
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
        const table = from(context);
        table.clock += table.tick;
        return table.clock;
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
            .bad_list_fn = bad_list,
        };
    }

    fn bad_list(_: *anyopaque, _: u8) void {}
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
    // Bytes by source: 2 chunks from the peer (the caller's peer 0), the rest from the registry,
    // none already on disk; and the peer is the one struck.
    try std.testing.expectEqual(@as(u64, 2 * chunk_len), report.peer_bytes[0]);
    try std.testing.expectEqual(@as(u64, (tree_chunks - 2) * chunk_len), report.registry_bytes);
    try std.testing.expectEqual(@as(u64, 0), report.cached_bytes);
    try std.testing.expectEqual(@as(u64, 1), report.struck_peers);
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
    try std.testing.expectEqual(@as(u64, tree_chunks * chunk_len), report.cached_bytes);

    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    var other = try test_store(&empty);
    defer other.close(std.testing.allocator);
    table.registry_up = false;
    const gpa = std.testing.allocator;
    const failed = fetch(gpa, transport, &other, &table.digest, &.{}, config, &report);
    try std.testing.expectError(error.TreeUnavailable, failed);
}

test "a tree named by a short digest is never fetched from a peer" {
    // Goal: an 8-hex prefix proves too little to trust a peer's list. Method: fetch with a
    // digest cut to 11 characters and a peer that holds everything: the peer is not asked for
    // anything, the registry serves the lot; with the full digest the peer serves.
    var table: Table = .{};
    table.make();
    var filter: [64]u8 = undefined;
    full_filter(&table, &filter);
    const peers = [_]PeerInfo{.{ .name = "node2", .filter = &filter }};
    var report: Report = .{};
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(gpa);
    try fetch(gpa, table.transport(), &store, table.digest[0..11], &peers, .{}, &report);
    try std.testing.expectEqual(@as(u32, 0), table.peer_asked);
    try std.testing.expectEqual(@as(u32, tree_chunks), table.registry_asked);
    var again = std.testing.tmpDir(.{});
    defer again.cleanup();
    var second = try test_store(&again);
    defer second.close(gpa);
    try fetch(gpa, table.transport(), &second, &table.digest, &peers, .{}, &report);
    try std.testing.expect(table.peer_asked > 0);
}

test "the fetch ends in an error when its total time is spent" {
    // Goal: one deadline covers the whole fetch. Method: a clock that moves 1000 ms at each
    // reading and a total of 1 ms; the list step must give up with Deadline and nothing may be
    // stored. A fetch with the default total, on the same table, succeeds.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(gpa);
    var table: Table = .{};
    table.make();
    table.tick = 1000;
    var report: Report = .{};
    const hurried: fetch_plan.Config = .{ .total_ms = 1 };
    const failed = fetch(gpa, table.transport(), &store, &table.digest, &.{}, hurried, &report);
    try std.testing.expectError(error.Deadline, failed);
    try std.testing.expect(!store.images().has(&table.digest));
    try fetch(gpa, table.transport(), &store, &table.digest, &.{}, .{}, &report);
    try std.testing.expect(store.images().has(&table.digest));
}

test "peers are ranked by the chunks their filters claim and the ones with none are left out" {
    // Goal: the sixteen peers a plan uses are the best of up to sixty-four. Method: three peers
    // claiming 6, 2 and 0 of the tree's chunks, then 40 peers claiming two chunks and 24 claiming
    // all: only 16 are kept, the biggest claim first.
    var table: Table = .{};
    table.make();
    var full: [64]u8 = undefined;
    full_filter(&table, &full);
    var some: [64]u8 = undefined;
    var filter = chunk_summary.Filter.init(&some);
    filter.add(&table.refs[0].hash);
    filter.add(&table.refs[1].hash);
    var none: [64]u8 = undefined;
    _ = chunk_summary.Filter.init(&none);
    const three = [_]PeerInfo{
        .{ .name = "a", .filter = &none },
        .{ .name = "b", .filter = &some },
        .{ .name = "c", .filter = &full },
    };
    const ranked = rank_peers(&three, &table.refs);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, ranked.order[0..ranked.count]);
    var many: [constants.fetch_candidates_max]PeerInfo = undefined;
    for (&many, 0..) |*slot, at| {
        slot.* = .{ .name = "n", .filter = if (at < 40) &some else &full };
    }
    const kept = rank_peers(&many, &table.refs);
    try std.testing.expectEqual(@as(u8, constants.fetch_peers_max), kept.count);
    try std.testing.expectEqual(@as(u8, 40), kept.order[0]);
    try std.testing.expectEqual(@as(u8, 41), kept.order[1]);
}
