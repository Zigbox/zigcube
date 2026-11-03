//! The world `sim-swarm` fetches in (docs/swarm.md): a universe of chunks, a few versions of an
//! image tree that share most of them, and N node stores, some of whose nodes lie, stay silent
//! or refuse. A chunk's bytes come from its id alone, so the simulation can say what the right
//! bytes are, produce wrong ones, and never keep a chunk store.
//!
//! Core code: no clock, thread or file. Everything comes from the `std.Random` it is given.

const std = @import("std");
const assert = std.debug.assert;
const chunk_summary = @import("chunk_summary.zig");

pub const Hash = chunk_summary.Hash;
const Blake3 = std.crypto.hash.Blake3;

/// Chunks in the universe, trees, nodes, and the size of a chunk here (small, so a run is fast;
/// the plan and the estimate are generic in it).
pub const universe_max: u32 = 512;
pub const trees_max: u32 = 6;
pub const tree_chunks_max: u32 = 96;
pub const nodes_max: u32 = 12;
pub const chunk_bytes: u32 = 256;

const words = universe_max / 64;

/// How a node answers a request for a chunk.
pub const Behavior = enum {
    /// Gives the right bytes after its latency.
    honest,
    /// Gives bytes that are not the chunk's.
    liar,
    /// Never answers: the caller's timeout fires.
    silent,
    /// Says it has no such chunk, whatever its filter said.
    refuser,
};

pub const Tree = struct {
    ids: [tree_chunks_max]u16 = undefined,
    len: u32 = 0,

    pub fn slice(tree: *const Tree) []const u16 {
        assert(tree.len <= tree_chunks_max);
        return tree.ids[0..tree.len];
    }
};

pub const Node = struct {
    held: [words]u64 = @splat(0),
    behavior: Behavior = .honest,
    /// Time to answer, in virtual milliseconds.
    latency_ms: u32 = 20,
    /// Chunks its filter claims without holding them (a stale or over-full summary).
    stale: [words]u64 = @splat(0),

    pub fn has(node: *const Node, id: u32) bool {
        assert(id < universe_max);
        return node.held[id / 64] >> @intCast(id % 64) & 1 == 1;
    }

    pub fn give(node: *Node, id: u32) void {
        assert(id < universe_max);
        node.held[id / 64] |= @as(u64, 1) << @intCast(id % 64);
    }

    pub fn drop(node: *Node, id: u32) void {
        assert(id < universe_max);
        node.held[id / 64] &= ~(@as(u64, 1) << @intCast(id % 64));
    }

    /// True if the node's filter claims chunk `id`: it holds it, or its summary is stale.
    pub fn claims(node: *const Node, id: u32) bool {
        assert(id < universe_max);
        return node.has(id) or (node.stale[id / 64] >> @intCast(id % 64) & 1 == 1);
    }

    pub fn holds_tree(node: *const Node, tree: *const Tree) bool {
        for (tree.slice()) |id| {
            if (!node.has(id)) return false;
        }
        return tree.len > 0;
    }
};

pub const World = struct {
    content_seed: u64,
    universe: u32,
    hashes: [universe_max]Hash = undefined,
    trees: [trees_max]Tree = undefined,
    tree_count: u32 = 0,
    nodes: [nodes_max]Node = undefined,
    node_count: u32 = 0,

    /// The right bytes of chunk `id`.
    pub fn content(world: *const World, id: u32, out: *[chunk_bytes]u8) void {
        assert(id < world.universe);
        var prng = std.Random.DefaultPrng.init(world.content_seed ^ (@as(u64, id) << 20) ^ 0x5eed);
        prng.random().bytes(out);
    }

    /// Wrong bytes for chunk `id`: the right ones with a byte or two changed, or the wrong length.
    pub fn corrupt(world: *const World, id: u32, random: std.Random, out: *[chunk_bytes]u8) u32 {
        world.content(id, out);
        const at = random.uintLessThan(u32, chunk_bytes);
        out[at] ^= 1 + random.uintLessThan(u8, 255); // Never zero: the byte does change.
        if (random.uintLessThan(u32, 8) == 0) return chunk_bytes - 1 - random.uintLessThan(u32, 8);
        return chunk_bytes;
    }

    /// Fills the world from `random`: the universe's hashes, versions of one tree that share most
    /// of their chunks, and nodes holding whole versions and scattered chunks.
    pub fn generate(world: *World, random: std.Random) void {
        world.universe = 128 + random.uintLessThan(u32, universe_max - 128 + 1);
        world.content_seed = random.int(u64);
        var bytes: [chunk_bytes]u8 = undefined;
        for (world.hashes[0..world.universe], 0..) |*hash, id| {
            world.content(@intCast(id), &bytes);
            Blake3.hash(&bytes, hash, .{});
        }
        world.make_trees(random);
        world.make_nodes(random);
        assert(world.tree_count >= 2);
        assert(world.node_count >= 3);
    }

    fn make_trees(world: *World, random: std.Random) void {
        const size = 24 + random.uintLessThan(u32, tree_chunks_max - 24 + 1);
        assert(size <= world.universe);
        world.trees[0] = distinct(world, random, size);
        world.tree_count = 2 + random.uintLessThan(u32, trees_max - 1);
        for (1..world.tree_count) |index| {
            // A new version changes up to a fifth of the chunks of the base.
            var tree = world.trees[0];
            const changes = random.uintLessThan(u32, size / 5 + 1);
            for (0..changes) |_| {
                const slot = random.uintLessThan(u32, size);
                const id = random.uintLessThan(u16, @intCast(world.universe));
                if (!tree_has(&tree, id)) tree.ids[slot] = id;
            }
            world.trees[index] = tree;
        }
    }

    /// A tree of `size` distinct chunks.
    fn distinct(world: *const World, random: std.Random, size: u32) Tree {
        var tree: Tree = .{};
        while (tree.len < size) {
            const id = random.uintLessThan(u16, @intCast(world.universe));
            if (tree_has(&tree, id)) continue;
            tree.ids[tree.len] = id;
            tree.len += 1;
        }
        assert(tree.len == size);
        return tree;
    }

    fn make_nodes(world: *World, random: std.Random) void {
        world.node_count = 3 + random.uintLessThan(u32, nodes_max - 3 + 1);
        for (world.nodes[0..world.node_count]) |*node| {
            node.* = .{ .latency_ms = 5 + random.uintLessThan(u32, 200) };
            node.behavior = switch (random.uintLessThan(u32, 10)) {
                0...5 => .honest,
                6, 7 => .liar,
                8 => .silent,
                else => .refuser,
            };
            // Whole versions first, then scattered chunks.
            const trees = random.uintLessThan(u32, 3);
            for (0..trees) |_| {
                const tree = &world.trees[random.uintLessThan(u32, world.tree_count)];
                for (tree.slice()) |id| node.give(id);
            }
            const extra = random.uintLessThan(u32, world.universe / 3 + 1);
            for (0..extra) |_| node.give(random.uintLessThan(u32, world.universe));
            const stale = random.uintLessThan(u32, 8);
            for (0..stale) |_| {
                const id = random.uintLessThan(u32, world.universe);
                node.stale[id / 64] |= @as(u64, 1) << @intCast(id % 64);
            }
        }
    }
};

fn tree_has(tree: *const Tree, id: u16) bool {
    return std.mem.indexOfScalar(u16, tree.slice(), id) != null;
}

test "a world is the same for the same seed, and its trees share chunks" {
    var a: World = undefined;
    var b: World = undefined;
    var prng_a = std.Random.DefaultPrng.init(11);
    var prng_b = std.Random.DefaultPrng.init(11);
    a.generate(prng_a.random());
    b.generate(prng_b.random());
    try std.testing.expectEqual(a.universe, b.universe);
    try std.testing.expectEqualSlices(Hash, a.hashes[0..a.universe], b.hashes[0..b.universe]);
    try std.testing.expectEqualSlices(u16, a.trees[0].slice(), b.trees[0].slice());
    var shared: u32 = 0;
    for (a.trees[0].slice()) |id| {
        if (tree_has(&a.trees[1], id)) shared += 1;
    }
    try std.testing.expect(shared * 10 >= a.trees[0].len * 7);
}

test "corrupt bytes never hash like the chunk" {
    var world: World = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    world.generate(prng.random());
    var bytes: [chunk_bytes]u8 = undefined;
    for (0..64) |id| {
        const len = world.corrupt(@intCast(id), prng.random(), &bytes);
        var digest: Hash = undefined;
        Blake3.hash(bytes[0..len], &digest, .{});
        try std.testing.expect(!std.mem.eql(u8, &digest, &world.hashes[id]));
    }
}
