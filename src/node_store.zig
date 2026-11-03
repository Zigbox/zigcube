//! The agent's store summary as a record (`/node-store/<node>`, docs/keys.md) and the `Images`
//! seam it comes from (C2 slice 5).
//!
//! * `Images.summary` is what the agent asks of its image store: the trees it holds completely,
//!   as `chunk_summary` sketches. The fake (`FakeImages`) makes them up from digests; slice 6's
//!   directory store reads them from disk.
//! * `held_of` and `sketch_of` convert a sketch to the record's `HeldTree` (hex sample) and back.
//!   A record that does not decode is skipped by the scheduler, never an error: it is advisory.
//!
//! Core code: no file, no clock, no thread.

const std = @import("std");
const assert = std.debug.assert;
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Sketch = chunk_summary.Sketch;

pub const Error = error{OutOfMemory};

/// The agent's view of its image store. Only `summary` so far; slice 6 adds the rest.
pub const Images = struct {
    context: *anyopaque,
    summary_fn: *const fn (*anyopaque, Allocator, []const []const u8) Error!Summary,

    /// The complete trees now in the store. `started` is the digests of the images the agent has
    /// started containers from (a store holds what it has run).
    pub fn summary(images: Images, arena: Allocator, started: []const []const u8) Error!Summary {
        const result = try images.summary_fn(images.context, arena, started);
        assert(result.trees.len <= constants.summary_trees_max);
        return result;
    }
};

pub const Summary = struct {
    /// Digest and sketch of each held tree, most recently used first.
    trees: []const Held = &.{},
    omitted: u32 = 0,
};

pub const Held = struct { digest: []const u8, sketch: Sketch };

/// The tree hash a sketch stands for: BLAKE3 of the digest text. Both sides derive it the same
/// way, so the scheduler matches a replica's image against a node's trees by digest.
pub fn tree_hash(digest: []const u8) chunk_summary.Hash {
    var out: chunk_summary.Hash = undefined;
    std.crypto.hash.Blake3.hash(digest, &out, .{});
    return out;
}

const hex_digits = "0123456789abcdef";

/// The record's tree entry for a sketch.
pub fn held_of(arena: Allocator, held: Held) Error!records.HeldTree {
    const entries = held.sketch.slice();
    const text = try arena.alloc(u8, entries.len * constants.summary_sketch_entry_bytes * 2);
    var at: usize = 0;
    for (entries) |entry| {
        var raw: [12]u8 = undefined;
        std.mem.writeInt(u64, raw[0..8], entry.key, .little);
        std.mem.writeInt(u32, raw[8..12], entry.bytes, .little);
        for (raw) |byte| {
            text[at] = hex_digits[byte >> 4];
            text[at + 1] = hex_digits[byte & 15];
            at += 2;
        }
    }
    assert(at == text.len);
    return .{
        .tree = held.digest,
        .bytes = held.sketch.total_bytes,
        .chunks = held.sketch.chunks,
        .sample = text,
    };
}

/// The sketch a record's tree entry describes, or null if the entry is malformed: a sample that
/// is not hex, not ascending, or not what its chunk count allows.
pub fn sketch_of(tree: records.HeldTree) ?Sketch {
    const entry_digits = constants.summary_sketch_entry_bytes * 2;
    if (tree.sample.len % entry_digits != 0) return null;
    const count = tree.sample.len / entry_digits;
    if (count > constants.summary_sketch_keys or count > tree.chunks) return null;
    var sketch = Sketch.init(tree_hash(tree.tree));
    sketch.chunks = tree.chunks;
    sketch.total_bytes = tree.bytes;
    sketch.count = @intCast(count);
    var previous: ?u64 = null;
    for (0..count) |index| {
        var raw: [12]u8 = undefined;
        const digits = tree.sample[index * entry_digits ..][0..entry_digits];
        _ = std.fmt.hexToBytes(&raw, digits) catch return null;
        const key = std.mem.readInt(u64, raw[0..8], .little);
        const bytes = std.mem.readInt(u32, raw[8..12], .little);
        if (bytes == 0 or bytes > constants.swarm_chunk_bytes) return null;
        if (previous) |before| {
            if (key <= before) return null;
        }
        previous = key;
        sketch.entries[index] = .{ .key = key, .bytes = bytes };
    }
    // A sample is either every chunk or a full K.
    if (count != tree.chunks and count != constants.summary_sketch_keys) return null;
    return sketch;
}

/// The record for a summary.
pub fn record_of(arena: Allocator, node: []const u8, summary: Summary) Error!records.NodeStore {
    const trees = try arena.alloc(records.HeldTree, summary.trees.len);
    for (summary.trees, trees) |held, *slot| slot.* = try held_of(arena, held);
    return .{ .node = node, .trees = trees, .omitted = summary.omitted };
}

// ---- The fake -----------------------------------------------------------------------------

/// Chunks of a fake tree: 4 to 11, of `fake_chunk_bytes` each, derived from the digest text.
const fake_chunk_bytes: u32 = 256 * 1024;

/// An image store that has the digests it was given (`--images`) and whatever the agent started.
/// Every tree is made up: its chunk hashes are BLAKE3 of `<digest>/<index>`.
pub const FakeImages = struct {
    /// The digests the store starts with; borrowed.
    digests: []const []const u8,

    pub fn images(fake: *FakeImages) Images {
        return .{ .context = fake, .summary_fn = summary_impl };
    }

    /// The sketch of the fake tree for `digest`.
    pub fn sketch(digest: []const u8) Sketch {
        var seed: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(digest, &seed, .{});
        const chunks: u32 = 4 + seed[0] % 8;
        var result = Sketch.init(tree_hash(digest));
        var index: u32 = 0;
        while (index < chunks) : (index += 1) {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update(digest);
            hasher.update("/");
            hasher.update(std.mem.asBytes(&index));
            var hash: chunk_summary.Hash = undefined;
            hasher.final(&hash);
            result.add(&hash, fake_chunk_bytes);
        }
        return result;
    }

    fn summary_impl(
        context: *anyopaque,
        arena: Allocator,
        started: []const []const u8,
    ) Error!Summary {
        const fake: *FakeImages = @ptrCast(@alignCast(context));
        var held: std.ArrayList(Held) = .empty;
        var omitted: u32 = 0;
        // The trees run most recently first, then the ones the store came with.
        for ([_][]const []const u8{ started, fake.digests }) |list| {
            for (list) |digest| {
                if (contains(held.items, digest)) continue;
                if (held.items.len == constants.summary_trees_max) {
                    omitted += 1;
                    continue;
                }
                try held.append(arena, .{ .digest = digest, .sketch = sketch(digest) });
            }
        }
        return .{ .trees = held.items, .omitted = omitted };
    }

    fn contains(held: []const Held, digest: []const u8) bool {
        for (held) |tree| {
            if (std.mem.eql(u8, tree.digest, digest)) return true;
        }
        return false;
    }
};

// ---- Tests --------------------------------------------------------------------------------

test "a fake summary becomes a record and decodes back to the same sketch" {
    // Goal: the record round-trips what the scheduler will read. Method: two digests, one held
    // twice; encode, decode and compare the sketch, and a damaged sample is refused.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeImages = .{ .digests = &.{ "b3:51aa9c03", "b3:9d20c4f1" } };
    const started = [_][]const u8{"b3:51aa9c03"};
    const summary = try fake.images().summary(arena, &started);
    try std.testing.expectEqual(@as(usize, 2), summary.trees.len);
    const record = try record_of(arena, "node1", summary);
    for (record.trees, summary.trees) |tree, held| {
        const back = sketch_of(tree).?;
        try std.testing.expectEqual(held.sketch.chunks, back.chunks);
        try std.testing.expectEqual(held.sketch.total_bytes, back.total_bytes);
        try std.testing.expectEqualSlices(
            chunk_summary.Entry,
            held.sketch.slice(),
            back.slice(),
        );
    }
    var bad = record.trees[0];
    bad.sample = bad.sample[0 .. bad.sample.len - 2];
    try std.testing.expect(sketch_of(bad) == null);
    bad = record.trees[0];
    bad.chunks += 1;
    try std.testing.expect(sketch_of(bad) == null);
}

test "a held tree scores its whole size against itself" {
    // Goal: locality_bytes over decoded sketches finds a tree by digest.
    const mine = FakeImages.sketch("b3:51aa9c03");
    const other = FakeImages.sketch("b3:9d20c4f1");
    const both = chunk_summary.locality_bytes(&mine, &.{ other, mine });
    try std.testing.expectEqual(mine.total_bytes, both);
    try std.testing.expectEqual(@as(u64, 0), chunk_summary.locality_bytes(&mine, &.{other}));
}
