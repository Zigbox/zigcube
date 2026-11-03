//! `sim-swarm`: the fetch plan and the locality estimate (docs/swarm.md) against a world of
//! lying, silent and refusing peers, from one seed. The world is `sim_images.zig`; the clock is
//! virtual; nothing here touches a thread, a socket or a file, so the report is the same natively
//! and as WebAssembly.
//!
//! **What a run does.** The seed draws a world (a universe of chunks, versions of an image tree,
//! 3 to 12 nodes whose behaviour is honest, liar, silent or refuser) and the caps. Each operation
//! is one of: a node fetches a version it lacks (with a `Plan`, every other node its peer, filters
//! built from what each holds, some of them stale), a node is asked what a version is worth to
//! it (`locality_bytes` against the exact count), or a node loses some chunks. The registry is
//! honest and never refuses.
//!
//! **What is checked.** On every answer: the plan accepts the bytes exactly when they are the
//! chunk's (a wrong chunk accepted is the failure the teeth test provokes), only a liar is ever
//! struck, no chunk is accepted twice. On every request: the peer's filter does say it may hold
//! the chunk, the peer was not struck, and was not already asked for this chunk; the bytes asked
//! of each peer and of the node stay within `rate * elapsed + rate + chunk`. At the end of a
//! fetch: every chunk verified, the bytes by source add up, the blame is the liars' and was
//! raised as ZC-W0601, and the fetch took no longer than the bound (the registry is honest, so a
//! fetch always finishes).
//!
//! The report ends with a hash of every node's store: the same seed twice gives the same hash.

const std = @import("std");
const assert = std.debug.assert;
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const fetch_plan = @import("fetch_plan.zig");
const images = @import("sim_images.zig");

const Blake3 = std.crypto.hash.Blake3;
const Hash = chunk_summary.Hash;
const World = images.World;

pub const report_bytes_max: u32 = 4 * 1024;

pub const Report = struct {
    failed: bool = false,
    bytes: [report_bytes_max]u8 = undefined,
    len: u32 = 0,

    pub fn text(report: *const Report) []const u8 {
        assert(report.len <= report_bytes_max);
        return report.bytes[0..report.len];
    }

    fn print(report: *Report, comptime format: []const u8, args: anytype) void {
        var writer = std.Io.Writer.fixed(report.bytes[report.len..]);
        writer.print(format, args) catch {}; // What does not fit is dropped.
        report.len += @intCast(writer.buffered().len);
        assert(report.len <= report_bytes_max);
    }
};

const filter_bytes = chunk_summary.Filter.bytes_for(images.universe_max);
/// A fetch longer than this (plus the time its bytes need at the node's rate) did not finish.
const fetch_bound_ms: u64 = 5 * 60 * 1000;

/// What the run counted, for the report.
const Totals = struct {
    fetches: u32 = 0,
    already_held: u32 = 0,
    chunks_from_peers: u64 = 0,
    chunks_from_registry: u64 = 0,
    bad_chunks: u32 = 0,
    refused: u32 = 0,
    timeouts: u32 = 0,
    struck: u32 = 0,
    locality_exact: u32 = 0,
    locality_estimated: u32 = 0,
    locality_worst_per_mille: u32 = 0,
    drops: u32 = 0,
    longest_fetch_ms: u64 = 0,
};

/// A request waiting for its answer.
const Pending = struct {
    live: bool = false,
    id: u32 = 0,
    chunk_index: u32 = 0,
    at_ms: u64 = 0,
    kind: enum { bytes, refused, timeout } = .timeout,
    len: u32 = 0,
    bytes: [images.chunk_bytes]u8 = undefined,
};

/// One fetch in progress.
const Fetch = struct {
    target: u32,
    started_ms: u64,
    config: fetch_plan.Config,
    chunks: [images.tree_chunks_max]fetch_plan.ChunkRef = undefined,
    ids: [images.tree_chunks_max]u16 = undefined,
    states: [images.tree_chunks_max]fetch_plan.ChunkState = undefined,
    verified: [images.tree_chunks_max]bool = @splat(false),
    /// Per chunk, the plan peers asked for it (a bit each).
    asked: [images.tree_chunks_max]u16 = @splat(0),
    count: u32 = 0,
    plan: fetch_plan.Plan = undefined,
    filter_store: [images.nodes_max][filter_bytes]u8 = undefined,
    filters: [images.nodes_max]chunk_summary.Filter = undefined,
    /// Plan peer index to node.
    peer_node: [images.nodes_max]u32 = undefined,
    peer_requested: [images.nodes_max]u64 = @splat(0),
    node_requested: u64 = 0,
    struck_seen: [images.nodes_max]bool = @splat(false),
    pending: [constants.fetch_in_flight_max]Pending = @splat(.{}),
};

const Sim = struct {
    report: *Report,
    seed: u64,
    prng: std.Random.DefaultPrng,
    world: World = undefined,
    now_ms: u64 = 0,
    peer_rate: u32,
    node_rate: u32,
    totals: Totals = .{},
    fetch: Fetch = undefined,

    fn random(sim: *Sim) std.Random {
        return sim.prng.random();
    }

    /// Records the first failure; the run stops at the next check of `sim.report.failed`.
    fn fail(sim: *Sim, comptime format: []const u8, args: anytype) void {
        if (sim.report.failed) return;
        sim.report.failed = true;
        sim.report.print("FAILED: " ++ format ++ " (seed {d}, at {d} ms)\n", args ++ .{
            sim.seed, sim.now_ms,
        });
    }
};

/// Runs `operations` operations of the world `seed` draws, into `report`.
pub fn simulate(seed: u64, operations: u32, report: *Report) void {
    assert(operations > 0);
    report.* = .{};
    var sim: Sim = .{
        .report = report,
        .seed = seed,
        .prng = std.Random.DefaultPrng.init(seed),
        .peer_rate = 0,
        .node_rate = 0,
    };
    sim.world.generate(sim.random());
    // Slow enough that the caps bind in some worlds, fast enough to finish.
    sim.peer_rate = 1_000 + sim.random().uintLessThan(u32, 40_000);
    sim.node_rate = sim.peer_rate + sim.random().uintLessThan(u32, 2 * sim.peer_rate);
    print_world(&sim);
    var operation: u32 = 0;
    while (operation < operations and !report.failed) : (operation += 1) {
        run_operation(&sim);
        sim.now_ms += 1 + sim.random().uintLessThan(u64, 2_000);
    }
    if (!report.failed) print_totals(&sim);
    assert(report.len <= report_bytes_max);
}

fn print_world(sim: *Sim) void {
    var counts: [4]u32 = @splat(0);
    for (sim.world.nodes[0..sim.world.node_count]) |node| counts[@backingInt(node.behavior)] += 1;
    sim.report.print(
        "sim-swarm: seed {d}\nworld: {d} chunks, {d} trees of {d} chunks, {d} nodes " ++
            "(honest {d} liar {d} silent {d} refuser {d})\ncaps: peer {d} B/s, node {d} B/s\n",
        .{
            sim.seed,
            sim.world.universe,
            sim.world.tree_count,
            sim.world.trees[0].len,
            sim.world.node_count,
            counts[0],
            counts[1],
            counts[2],
            counts[3],
            sim.peer_rate,
            sim.node_rate,
        },
    );
}

fn run_operation(sim: *Sim) void {
    const random = sim.random();
    const node = random.uintLessThan(u32, sim.world.node_count);
    const tree = random.uintLessThan(u32, sim.world.tree_count);
    switch (random.uintLessThan(u32, 10)) {
        0...6 => run_fetch(sim, node, tree),
        7, 8 => check_locality(sim, node, tree),
        else => drop_chunks(sim, node),
    }
}

fn drop_chunks(sim: *Sim, node: u32) void {
    const random = sim.random();
    const drops = random.uintLessThan(u32, 24);
    for (0..drops) |_| sim.world.nodes[node].drop(random.uintLessThan(u32, sim.world.universe));
    sim.totals.drops += drops;
    assert(sim.world.nodes[node].held.len == 8);
}

// ---- A fetch --------------------------------------------------------------------------------

fn run_fetch(sim: *Sim, target: u32, tree_index: u32) void {
    const f = &sim.fetch;
    f.* = .{ .target = target, .started_ms = sim.now_ms, .config = .{
        .peer_rate_bytes_per_s = sim.peer_rate,
        .node_rate_bytes_per_s = sim.node_rate,
    } };
    const tree = &sim.world.trees[tree_index];
    for (tree.slice()) |id| {
        if (sim.world.nodes[target].has(id)) continue;
        f.chunks[f.count] = .{ .hash = sim.world.hashes[id], .bytes = images.chunk_bytes };
        f.ids[f.count] = id;
        f.count += 1;
    }
    if (f.count == 0) {
        sim.totals.already_held += 1;
        return;
    }
    sim.totals.fetches += 1;
    f.plan = fetch_plan.Plan.init(f.config, f.chunks[0..f.count], f.states[0..f.count], sim.now_ms);
    add_peers(sim);
    drive(sim);
    if (!sim.report.failed) finish(sim);
}

fn add_peers(sim: *Sim) void {
    const f = &sim.fetch;
    var peers: u32 = 0;
    for (sim.world.nodes[0..sim.world.node_count], 0..) |*node, index| {
        if (index == f.target) continue;
        var filter = chunk_summary.Filter.init(&f.filter_store[peers]);
        for (0..sim.world.universe) |id| {
            if (node.claims(@intCast(id))) filter.add(&sim.world.hashes[id]);
        }
        f.filters[peers] = filter;
        f.peer_node[peers] = @intCast(index);
        const added = f.plan.add_peer(filter);
        assert(added == peers);
        peers += 1;
    }
    assert(peers == sim.world.node_count - 1);
}

/// Runs the plan to `done` or a failure, delivering answers in the order of their times.
fn drive(sim: *Sim) void {
    const f = &sim.fetch;
    const bytes_ms = @as(u64, f.count) * images.chunk_bytes * 1000 / f.config.node_rate_bytes_per_s;
    const bound = fetch_bound_ms + 2 * bytes_ms;
    while (!sim.report.failed) {
        if (sim.now_ms - f.started_ms > bound) {
            return sim.fail("a fetch did not finish in time", .{});
        }
        switch (f.plan.next(sim.now_ms)) {
            .request => |request| schedule(sim, request),
            .wait => |until| wait(sim, until),
            .done => return,
            .failed => return sim.fail("a fetch failed though the registry never refuses", .{}),
        }
    }
}

/// Advances the virtual clock to the earlier of `until` and the next answer, and delivers what
/// is due.
fn wait(sim: *Sim, until: ?u64) void {
    const f = &sim.fetch;
    var next_at: ?u64 = until;
    for (f.pending) |pending| {
        if (!pending.live) continue;
        if (next_at == null or pending.at_ms < next_at.?) next_at = pending.at_ms;
    }
    const at = next_at orelse return sim.fail("the plan waits for nothing", .{});
    assert(f.count > 0); // A wake time in the past means "now".
    sim.now_ms = @max(sim.now_ms, at);
    while (!sim.report.failed) {
        const slot = earliest_due(f, sim.now_ms) orelse break;
        deliver(sim, slot);
    }
}

fn earliest_due(f: *const Fetch, now_ms: u64) ?usize {
    var best: ?usize = null;
    for (f.pending, 0..) |pending, slot| {
        if (!pending.live or pending.at_ms > now_ms) continue;
        if (best == null or pending.at_ms < f.pending[best.?].at_ms) best = slot;
    }
    return best;
}

/// Checks the request against the plan's promises, then works out how its source answers.
fn schedule(sim: *Sim, request: fetch_plan.Request) void {
    const f = &sim.fetch;
    assert(request.bytes == images.chunk_bytes);
    check_request(sim, request);
    if (sim.report.failed) return;
    const slot = for (f.pending, 0..) |pending, index| {
        if (!pending.live) break index;
    } else return sim.fail("the plan has more requests in flight than its limit", .{});
    const id = f.ids[request.chunk];
    var pending: Pending = .{ .live = true, .id = request.id, .chunk_index = request.chunk };
    switch (request.source) {
        .registry => answer(sim, &pending, .honest, 50, id, request.deadline_ms, true),
        .peer => |peer| {
            const node = &sim.world.nodes[f.peer_node[peer]];
            const has = node.has(id);
            answer(sim, &pending, node.behavior, node.latency_ms, id, request.deadline_ms, has);
        },
    }
    f.pending[slot] = pending;
}

fn answer(
    sim: *Sim,
    pending: *Pending,
    behavior: images.Behavior,
    latency_ms: u32,
    id: u32,
    deadline_ms: u64,
    has: bool,
) void {
    const jitter = sim.random().uintLessThan(u32, 10);
    pending.at_ms = sim.now_ms + latency_ms + jitter;
    pending.kind = .bytes;
    switch (behavior) {
        .silent => pending.kind = .timeout,
        .refuser => pending.kind = .refused,
        .honest => {
            if (!has) pending.kind = .refused;
            sim.world.content(id, &pending.bytes);
            pending.len = images.chunk_bytes;
        },
        .liar => pending.len = sim.world.corrupt(id, sim.random(), &pending.bytes),
    }
    // A caller's timeout fires at the deadline; the late answer is never heard.
    if (pending.kind == .timeout or pending.at_ms > deadline_ms) {
        pending.kind = .timeout;
        pending.at_ms = deadline_ms;
    }
}

fn check_request(sim: *Sim, request: fetch_plan.Request) void {
    const f = &sim.fetch;
    assert(request.deadline_ms > sim.now_ms);
    f.node_requested += request.bytes;
    const waited = sim.now_ms - f.started_ms;
    const node_rate = f.config.node_rate_bytes_per_s;
    if (f.node_requested > @as(u64, node_rate) * waited / 1000 + node_rate + images.chunk_bytes) {
        return sim.fail("the node asked for more bytes than its cap allows", .{});
    }
    switch (request.source) {
        .registry => {},
        .peer => |peer| check_peer_request(sim, request, peer, waited),
    }
}

fn check_peer_request(sim: *Sim, request: fetch_plan.Request, peer: u8, waited: u64) void {
    const f = &sim.fetch;
    const id = f.ids[request.chunk];
    if (!f.filters[peer].maybe_has(&sim.world.hashes[id])) {
        return sim.fail("a peer was asked for a chunk its filter does not claim", .{});
    }
    if (f.struck_seen[peer]) return sim.fail("a struck peer was asked again", .{});
    const bit = @as(u16, 1) << @intCast(peer);
    if (f.asked[request.chunk] & bit != 0) {
        return sim.fail("a peer was asked twice for the same chunk", .{});
    }
    f.asked[request.chunk] |= bit;
    f.peer_requested[peer] += request.bytes;
    const rate = f.config.peer_rate_bytes_per_s;
    if (f.peer_requested[peer] > @as(u64, rate) * waited / 1000 + rate + images.chunk_bytes) {
        return sim.fail("a peer was asked for more bytes than its cap allows", .{});
    }
}

/// Hands a due answer to the plan and judges what it says.
fn deliver(sim: *Sim, slot: usize) void {
    const f = &sim.fetch;
    const pending = &f.pending[slot];
    pending.live = false;
    const id = f.ids[pending.chunk_index];
    const result: fetch_plan.Result = switch (pending.kind) {
        .bytes => .{ .bytes = pending.bytes[0..pending.len] },
        .refused => .refused,
        .timeout => .timeout,
    };
    const outcome = f.plan.receive(pending.id, result, @max(sim.now_ms, pending.at_ms));
    var expected: [images.chunk_bytes]u8 = undefined;
    sim.world.content(id, &expected);
    const right = pending.kind == .bytes and pending.len == images.chunk_bytes and
        std.mem.eql(u8, &expected, &pending.bytes);
    judge(sim, pending, outcome, right);
}

fn judge(sim: *Sim, pending: *const Pending, outcome: fetch_plan.Outcome, right: bool) void {
    const f = &sim.fetch;
    switch (outcome) {
        .verified => {
            if (!right) return sim.fail("a chunk with wrong bytes was accepted", .{});
            if (f.verified[pending.chunk_index]) return sim.fail("a chunk was accepted twice", .{});
            f.verified[pending.chunk_index] = true;
        },
        .bad_hash => {
            if (right) return sim.fail("a chunk with the right bytes was rejected", .{});
            sim.totals.bad_chunks += 1;
        },
        .refused => sim.totals.refused += 1,
        .timeout => sim.totals.timeouts += 1,
    }
}

// ---- The end of a fetch ---------------------------------------------------------------------

fn finish(sim: *Sim) void {
    const f = &sim.fetch;
    const plan = &f.plan;
    for (f.verified[0..f.count]) |verified| {
        if (!verified) return sim.fail("a fetch finished with a chunk unverified", .{});
    }
    const total = @as(u64, f.count) * images.chunk_bytes;
    if (plan.peer_bytes + plan.registry_bytes != total) {
        return sim.fail("the bytes by source do not add up to the chunks fetched", .{});
    }
    var diag: diag_mod.Diag = undefined;
    while (plan.take_blame()) |blame| {
        const node = f.peer_node[blame.peer];
        if (sim.world.nodes[node].behavior != .liar) {
            return sim.fail("an honest peer was struck", .{});
        }
        diag.reset();
        fetch_plan.raise_blame(&diag, blame, "node", f.count);
        sim.totals.struck += 1;
    }
    for (f.ids[0..f.count]) |id| sim.world.nodes[f.target].give(id);
    sim.totals.chunks_from_peers += plan.peer_bytes / images.chunk_bytes;
    sim.totals.chunks_from_registry += plan.registry_bytes / images.chunk_bytes;
    sim.totals.longest_fetch_ms = @max(sim.totals.longest_fetch_ms, sim.now_ms - f.started_ms);
    assert(plan.done_count == f.count);
}

// ---- The locality estimate ------------------------------------------------------------------

fn sketch_of(world: *const World, tree: *const images.Tree) chunk_summary.Sketch {
    var digest: Hash = undefined;
    Blake3.hash(std.mem.sliceAsBytes(tree.slice()), &digest, .{});
    var sketch = chunk_summary.Sketch.init(digest);
    for (tree.slice()) |id| sketch.add(&world.hashes[id], images.chunk_bytes);
    return sketch;
}

fn check_locality(sim: *Sim, node_index: u32, tree_index: u32) void {
    const world = &sim.world;
    const node = &world.nodes[node_index];
    const target_tree = &world.trees[tree_index];
    const target = sketch_of(world, target_tree);
    var held: [images.trees_max]chunk_summary.Sketch = undefined;
    var held_count: usize = 0;
    var all_exact = true;
    var in_held: [images.universe_max]bool = @splat(false);
    for (world.trees[0..world.tree_count]) |*tree| {
        if (!node.holds_tree(tree)) continue;
        held[held_count] = sketch_of(world, tree);
        all_exact = all_exact and held[held_count].exact();
        held_count += 1;
        for (tree.slice()) |id| in_held[id] = true;
    }
    var truth: u64 = 0;
    for (target_tree.slice()) |id| {
        if (in_held[id]) truth += images.chunk_bytes;
    }
    const estimate = chunk_summary.locality_bytes(&target, held[0..held_count]);
    const difference = if (estimate > truth) estimate - truth else truth - estimate;
    // The union of held trees is exact only while it has no more chunks than a sketch holds.
    const union_chunks = std.mem.count(bool, &in_held, &.{true});
    if (target.exact() and all_exact and union_chunks <= chunk_summary.sketch_keys_max) {
        if (difference != 0) return sim.fail("an exact locality estimate was not exact", .{});
        sim.totals.locality_exact += 1;
        return;
    }
    if (difference * 10 > target.total_bytes * 3) {
        return sim.fail("the locality estimate is off by more than 30% of the tree", .{});
    }
    sim.totals.locality_estimated += 1;
    const per_mille: u32 = @intCast(difference * 1000 / target.total_bytes);
    sim.totals.locality_worst_per_mille = @max(sim.totals.locality_worst_per_mille, per_mille);
}

fn print_totals(sim: *Sim) void {
    const totals = &sim.totals;
    var digest: Hash = undefined;
    var hasher = Blake3.init(.{});
    for (sim.world.nodes[0..sim.world.node_count]) |node| {
        hasher.update(std.mem.sliceAsBytes(&node.held));
    }
    hasher.final(&digest);
    sim.report.print(
        "fetches: {d} (already held {d}); chunks from peers {d}, from the registry {d}; " ++
            "longest {d} ms\npeers: bad chunks {d}, struck {d}, refused {d}, timeouts {d}\n" ++
            "locality: exact {d}, estimated {d} (worst error {d} per mille); " ++
            "chunks dropped {d}\n" ++
            "stores: {x}\nresult: ok\n",
        .{
            totals.fetches,            totals.already_held,
            totals.chunks_from_peers,  totals.chunks_from_registry,
            totals.longest_fetch_ms,   totals.bad_chunks,
            totals.struck,             totals.refused,
            totals.timeouts,           totals.locality_exact,
            totals.locality_estimated, totals.locality_worst_per_mille,
            totals.drops,              digest[0..8],
        },
    );
}

test "a seed passes, twice the same" {
    var first: Report = undefined;
    var second: Report = undefined;
    simulate(1, 60, &first);
    simulate(1, 60, &second);
    try std.testing.expect(!first.failed);
    try std.testing.expectEqualStrings(first.text(), second.text());
    try std.testing.expect(std.mem.indexOf(u8, first.text(), "result: ok") != null);
}

test "seeds 1 to 40 pass" {
    var report: Report = undefined;
    for (1..41) |seed| {
        simulate(seed, 40, &report);
        if (report.failed) std.debug.print("{s}", .{report.text()});
        try std.testing.expect(!report.failed);
    }
}
