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
const Hash = chunk_summary.Hash;
const ChunkRef = @import("fetch_plan.zig").ChunkRef;

pub const Error = error{OutOfMemory};

/// What the chunk calls of the seam can say.
pub const ChunkError = error{ OutOfMemory, NotFound, BadHash, StoreFailed };

/// The agent's view of its image store (C2 slice 6b). `summary` says what is held; the rest move
/// chunks. A tree is named by its digest text, a chunk by its BLAKE3 hash. The fake that only
/// makes summaries up (`FakeImages`) holds no bytes and answers every chunk call `NotFound`.
pub const Images = struct {
    context: *anyopaque,
    summary_fn: *const fn (*anyopaque, Allocator, []const []const u8) Error!Summary,
    has_fn: *const fn (*anyopaque, []const u8) bool = no_has,
    chunk_list_fn: *const fn (*anyopaque, []const u8, []ChunkRef) ChunkError!u32 = no_list,
    read_chunk_fn: *const fn (*anyopaque, *const Hash, []u8) ChunkError![]u8 = no_read,
    put_chunk_fn: *const fn (*anyopaque, *const Hash, []const u8) ChunkError!void = no_put,
    /// The bundle of a tree (`zigbox_fetch.encode`) into the buffer; null if the store has none.
    bundle_fn: *const fn (*anyopaque, []const u8, []u8) ?[]const u8 = no_bundle,

    /// The bundle of `tree` in `out`, or null: a store of chunk lists has none.
    pub fn bundle(images: Images, tree: []const u8, out: []u8) ?[]const u8 {
        const bytes = images.bundle_fn(images.context, tree, out) orelse return null;
        assert(bytes.len <= out.len);
        return bytes;
    }

    /// The complete trees now in the store. `started` is the digests of the images the agent has
    /// started containers from (a store holds what it has run).
    pub fn summary(images: Images, arena: Allocator, started: []const []const u8) Error!Summary {
        const result = try images.summary_fn(images.context, arena, started);
        assert(result.trees.len <= constants.summary_trees_max);
        return result;
    }

    /// Whether the store holds every chunk of `tree`.
    pub fn has(images: Images, tree: []const u8) bool {
        return images.has_fn(images.context, tree);
    }

    /// The chunks of `tree` in order into `out`; the count, or `NotFound` for a tree the store
    /// has no list for. A list longer than `out` is `StoreFailed`.
    pub fn chunk_list(images: Images, tree: []const u8, out: []ChunkRef) ChunkError!u32 {
        const count = try images.chunk_list_fn(images.context, tree, out);
        assert(count <= out.len);
        return count;
    }

    /// The bytes of chunk `hash` in `out` (which holds a chunk). The store checks BLAKE3 of what
    /// it read against `hash` before it returns: a chunk that fails is `BadHash`, never served.
    pub fn read_chunk(images: Images, hash: *const Hash, out: []u8) ChunkError![]u8 {
        assert(out.len >= constants.swarm_chunk_bytes);
        const bytes = try images.read_chunk_fn(images.context, hash, out);
        assert(bytes.len <= out.len);
        return bytes;
    }

    /// Stores `bytes` as chunk `hash`, after checking BLAKE3 of them against it: a mismatch is
    /// `BadHash` and nothing is written. The check is the store's, not the caller's.
    pub fn put_chunk(images: Images, hash: *const Hash, bytes: []const u8) ChunkError!void {
        assert(bytes.len <= constants.swarm_chunk_bytes);
        return images.put_chunk_fn(images.context, hash, bytes);
    }
};

fn no_bundle(_: *anyopaque, _: []const u8, _: []u8) ?[]const u8 {
    return null;
}

/// The digest a chunk list stands for: `b3:` and the lowercase hex of BLAKE3 of the list's text.
pub fn list_digest(list: []const u8, out: *[67]u8) []const u8 {
    var hash: Hash = undefined;
    std.crypto.hash.Blake3.hash(list, &hash, .{});
    out[0..3].* = "b3:".*;
    for (hash, 0..) |byte, at| {
        out[3 + at * 2] = hex_digits[byte >> 4];
        out[4 + at * 2] = hex_digits[byte & 15];
    }
    return out;
}

/// Whether `digest` names `list`: it is `list_digest` or a prefix of it at least 8 hex digits long
/// (the short digests of images and fixtures). A peer or registry that sends a list is held to it.
/// A short digest is never asked of a peer (`fetch_worker`): 32 bits are searchable.
pub fn list_matches(digest: []const u8, list: []const u8) bool {
    var full: [67]u8 = undefined;
    const want = list_digest(list, &full);
    if (digest.len < 3 + 8 or digest.len > want.len) return false;
    return std.mem.eql(u8, digest, want[0..digest.len]);
}

/// The chunks a list's text names, into `out`; the count, or null if a line is malformed, a size
/// is 0 or over a chunk, or there are more lines than `out` holds (or none).
pub fn list_parse(list: []const u8, out: []ChunkRef) ?u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break; // The text ends in a newline.
        if (line.len < 66 or line[64] != ' ' or count == out.len) return null;
        _ = std.fmt.hexToBytes(&out[count].hash, line[0..64]) catch return null;
        out[count].bytes = std.fmt.parseInt(u32, line[65..], 10) catch return null;
        if (out[count].bytes == 0 or out[count].bytes > constants.swarm_chunk_bytes) return null;
        count += 1;
    }
    return if (count == 0) null else count;
}

/// The canonical text of a chunk list (lowercase hex, one decimal size, a newline per chunk), the
/// text a digest names; null if `out` is too small.
pub fn list_format(chunks: []const ChunkRef, out: []u8) ?[]u8 {
    var writer: std.Io.Writer = .fixed(out);
    for (chunks) |chunk| {
        writer.print("{x} {d}\n", .{ &chunk.hash, chunk.bytes }) catch return null;
    }
    return writer.buffered();
}

/// BLAKE3 of `bytes` is `hash`: the check every store makes.
pub fn chunk_verifies(hash: *const Hash, bytes: []const u8) bool {
    var actual: Hash = undefined;
    std.crypto.hash.Blake3.hash(bytes, &actual, .{});
    return std.crypto.timing_safe.eql(Hash, actual, hash.*);
}

fn no_has(_: *anyopaque, _: []const u8) bool {
    return false;
}

fn no_list(_: *anyopaque, _: []const u8, _: []ChunkRef) ChunkError!u32 {
    return error.NotFound;
}

fn no_read(_: *anyopaque, _: *const Hash, _: []u8) ChunkError![]u8 {
    return error.NotFound;
}

fn no_put(_: *anyopaque, _: *const Hash, _: []const u8) ChunkError!void {
    return error.NotFound;
}

pub const Summary = struct {
    /// Digest and sketch of each held tree, most recently used first.
    trees: []const Held = &.{},
    omitted: u32 = 0,
    /// The Bloom filter over every chunk held (raw bytes), and the chunks it was filled with;
    /// empty when the store has none (`filter_chunks` 0).
    filter: []const u8 = "",
    filter_chunks: u32 = 0,
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
/// is not hex, not ascending, not what its chunk count allows, or whose bytes do not fit the
/// entry's `bytes`. The record is another node's word, so nothing in it is trusted: the
/// scheduler's estimate relies on what this checks (O1: a bad summary costs speed, never
/// correctness).
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
    var sampled_bytes: u64 = 0;
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
        sampled_bytes += bytes;
        sketch.entries[index] = .{ .key = key, .bytes = bytes };
    }
    // A sample is either every chunk or a full K.
    if (count != tree.chunks and count != constants.summary_sketch_keys) return null;
    if (!bytes_fit(&tree, count, sampled_bytes)) return null;
    assert(sketch.count <= sketch.chunks);
    assert(sampled_bytes <= sketch.total_bytes);
    return sketch;
}

/// Whether a tree entry's `bytes` agrees with its sample, as `Sketch.add` builds one: a sample of
/// every chunk sums to the tree's bytes; a partial sample leaves at least one byte for each chunk
/// outside it; and no tree is larger than its chunks at their largest.
fn bytes_fit(tree: *const records.HeldTree, count: u64, sampled_bytes: u64) bool {
    assert(count <= tree.chunks);
    if (tree.bytes > @as(u64, tree.chunks) * constants.swarm_chunk_bytes) return false;
    if (count == tree.chunks) return sampled_bytes == tree.bytes;
    const unsampled: u64 = tree.chunks - count;
    if (sampled_bytes > tree.bytes) return false;
    return unsampled <= tree.bytes - sampled_bytes;
}

/// The record for a summary.
pub fn record_of(arena: Allocator, node: []const u8, summary: Summary) Error!records.NodeStore {
    const trees = try arena.alloc(records.HeldTree, summary.trees.len);
    for (summary.trees, trees) |held, *slot| slot.* = try held_of(arena, held);
    const filter = try arena.alloc(u8, summary.filter.len * 2);
    for (summary.filter, 0..) |byte, at| {
        filter[at * 2] = hex_digits[byte >> 4];
        filter[at * 2 + 1] = hex_digits[byte & 15];
    }
    return .{
        .node = node,
        .trees = trees,
        .omitted = summary.omitted,
        .filter = filter,
        .filter_chunks = summary.filter_chunks,
    };
}

/// The filter bytes a record carries, into `out`, or null if the hex is damaged, the size is not
/// one `Filter` takes, or `out` is too small. Empty is a valid answer: a node with no filter.
pub fn filter_of(record: records.NodeStore, out: []u8) ?[]u8 {
    const digits = record.filter;
    if (digits.len == 0) return out[0..0];
    if (digits.len % 2 != 0 or digits.len / 2 > out.len) return null;
    const size = digits.len / 2;
    if (size < 8 or size > constants.summary_filter_bytes_max) return null;
    _ = std.fmt.hexToBytes(out[0..size], digits) catch return null;
    return out[0..size];
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
    // The bytes must agree with the sample: an exact sample sums to them.
    bad = record.trees[0];
    bad.bytes += 1;
    try std.testing.expect(sketch_of(bad) == null);
    bad.bytes -= 2;
    try std.testing.expect(sketch_of(bad) == null);
}

test "a tree entry whose sample outweighs its bytes is refused" {
    // Goal: the release review's lying record (one chunk of 1 byte, sampled as 4096 bytes) does
    // not decode, nor does a partial sample with no byte left for its unsampled chunks, nor a
    // tree larger than its chunks can hold. Method: hand-written hex samples.
    const one_4096 = "0100000000000000" ++ "00100000"; // Key 1, 4096 bytes, little-endian.
    var tree: records.HeldTree = .{
        .tree = "b3:51aa9c03",
        .bytes = 1,
        .chunks = 1,
        .sample = one_4096,
    };
    try std.testing.expect(sketch_of(tree) == null);
    tree.bytes = 4096;
    try std.testing.expectEqual(@as(u64, 4096), sketch_of(tree).?.total_bytes);
    tree.chunks = 2; // Count 1 is neither every chunk nor a full K.
    try std.testing.expect(sketch_of(tree) == null);
    tree = .{ .tree = "b3:51aa9c03", .bytes = 0, .chunks = 0, .sample = "" };
    try std.testing.expectEqual(@as(u32, 0), sketch_of(tree).?.chunks);
    tree.bytes = 1; // No chunks, yet a byte.
    try std.testing.expect(sketch_of(tree) == null);
}

test "a held tree scores its whole size against itself" {
    // Goal: locality_bytes over decoded sketches finds a tree by digest.
    const mine = FakeImages.sketch("b3:51aa9c03");
    const other = FakeImages.sketch("b3:9d20c4f1");
    const both = chunk_summary.locality_bytes(&mine, &.{ other, mine });
    try std.testing.expectEqual(mine.total_bytes, both);
    try std.testing.expectEqual(@as(u64, 0), chunk_summary.locality_bytes(&mine, &.{other}));
}

test "a chunk list is held to its digest, and parses only whole" {
    // Goal: a list from a peer or a registry is accepted only if it is what the digest names.
    // Method: build a list, check the full digest and that a prefix is refused, flip one digit,
    // then malformed lines.
    var list_bytes: [200]u8 = undefined;
    const hash_a: [32]u8 = @splat(0xab);
    const hash_b: [32]u8 = @splat(0x01);
    const list = std.fmt.bufPrint(&list_bytes, "{x} 1048576\n{x} 77\n", .{ &hash_a, &hash_b }) catch
        unreachable; // Sized.
    var full: [67]u8 = undefined;
    const digest = list_digest(list, &full);
    try std.testing.expect(list_matches(digest, list));
    try std.testing.expect(list_matches(digest[0..11], list));
    try std.testing.expect(!list_matches(digest[0..10], list)); // Too short to mean anything.
    var other: [200]u8 = undefined;
    @memcpy(other[0..list.len], list);
    other[70] = '9';
    try std.testing.expect(!list_matches(digest, other[0..list.len]));
    var out: [4]ChunkRef = undefined;
    try std.testing.expectEqual(@as(?u32, 2), list_parse(list, &out));
    try std.testing.expectEqual(@as(u32, 77), out[1].bytes);
    try std.testing.expectEqual(@as(?u32, null), list_parse("", &out));
    try std.testing.expectEqual(@as(?u32, null), list_parse(list[0 .. list.len - 3], &out));
    var one: [1]ChunkRef = undefined;
    try std.testing.expectEqual(@as(?u32, null), list_parse(list, &one)); // More than fit.
}

test "a store refuses a chunk whose bytes are not its hash" {
    // Goal: chunk_verifies is the check; the store's calls use it.
    var hash: Hash = undefined;
    std.crypto.hash.Blake3.hash("abc", &hash, .{});
    try std.testing.expect(chunk_verifies(&hash, "abc"));
    try std.testing.expect(!chunk_verifies(&hash, "abd"));
}
