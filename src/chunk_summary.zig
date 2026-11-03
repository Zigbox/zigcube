//! The store summary of C2 (docs/swarm.md): what a node says about the chunks it holds.
//!
//! * **`Filter`**, a Bloom filter over the BLAKE3 hashes of the chunks a node holds. It answers
//!   "does the node have chunk c" with false positives and no false negatives. It is for a
//!   fetching agent, which already has the tree's chunk list; a false positive costs one refused
//!   request, because every chunk is verified.
//! * **`Sketch`**, the bottom-K sketch of one tree: the K smallest keys of the tree's distinct
//!   chunks, each with its chunk's size. It is for the scheduler, which has no chunk lists.
//!   `locality_bytes` estimates from sketches how many bytes of a target tree a node holds.
//!
//! Both read their bits from the chunk hash itself (a BLAKE3 digest is uniform), so nothing here
//! hashes anything. Core code: no allocation, no clock, no file; a filter lives in bytes the
//! caller gives it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// A chunk's BLAKE3 hash, raw (the 64 hex digits of `b3:...` decoded).
pub const Hash = [32]u8;

const hash_zero: Hash = @splat(0);

// ---- The Bloom filter ---------------------------------------------------------------------------

/// A Bloom filter over caller-owned bytes. Bits `0..16` of a hash give the probe sequence (double
/// hashing: index i is `h1 + i * h2` modulo the bit count), so the filter and the sketch's key
/// (bytes `16..24`) read different parts of the hash.
pub const Filter = struct {
    bits: []u8,

    /// The bytes a filter needs for `chunks` chunks at `summary_filter_bits_per_chunk`.
    pub fn bytes_for(chunks: u32) u32 {
        assert(chunks > 0);
        assert(chunks <= constants.summary_chunks_capacity);
        const bits = @as(u64, chunks) * constants.summary_filter_bits_per_chunk;
        return @intCast(@max(8, std.math.divCeil(u64, bits, 8) catch unreachable)); // Bits > 0.
    }

    /// An empty filter over `bytes` (zeroed here).
    pub fn init(bytes: []u8) Filter {
        assert(bytes.len >= 8); // The step below needs at least 63 bits to pick from.
        assert(bytes.len <= constants.summary_filter_bytes_max);
        @memset(bytes, 0);
        return .{ .bits = bytes };
    }

    /// A filter that already holds bits (a peer's, decoded): nothing is cleared.
    pub fn view(bytes: []u8) Filter {
        assert(bytes.len >= 8);
        assert(bytes.len <= constants.summary_filter_bytes_max);
        return .{ .bits = bytes };
    }

    fn bit_count(filter: *const Filter) u64 {
        return @as(u64, filter.bits.len) * 8;
    }

    /// The i-th probe of `hash`, a bit number.
    fn probe(filter: *const Filter, hash: *const Hash, index: u32) u64 {
        const count = filter.bit_count();
        const first = std.mem.readInt(u64, hash[0..8], .little);
        const second = std.mem.readInt(u64, hash[8..16], .little);
        // A step of 0 would repeat one probe; a step in 1..count-1 spreads them (probes may still
        // coincide when the step shares a factor with count, which only costs a little accuracy).
        const step = second % (count - 1) + 1;
        return (first % count + @as(u64, index) * step) % count;
    }

    pub fn add(filter: *Filter, hash: *const Hash) void {
        var index: u32 = 0;
        while (index < constants.summary_filter_hashes) : (index += 1) {
            const bit = filter.probe(hash, index);
            filter.bits[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
        }
        assert(filter.maybe_has(hash)); // No false negatives: the pair of `add`.
    }

    /// False means the chunk is not held; true means it probably is.
    pub fn maybe_has(filter: *const Filter, hash: *const Hash) bool {
        var index: u32 = 0;
        while (index < constants.summary_filter_hashes) : (index += 1) {
            const bit = filter.probe(hash, index);
            if (filter.bits[@intCast(bit / 8)] & (@as(u8, 1) << @intCast(bit % 8)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Adds every chunk of `other` (the same size): the filter of the union of two sets.
    pub fn merge(filter: *Filter, other: *const Filter) void {
        assert(filter.bits.len == other.bits.len);
        for (filter.bits, other.bits) |*byte, extra| byte.* |= extra;
    }

    /// Bits set, in parts per thousand of the filter: a node that is over capacity shows here
    /// (about 500 at capacity for 7 hashes), long before its false-positive rate hurts.
    pub fn fill_per_mille(filter: *const Filter) u32 {
        var set: u64 = 0;
        for (filter.bits) |byte| set += @popCount(byte);
        const per_mille = set * 1000 / filter.bit_count();
        assert(per_mille <= 1000);
        return @intCast(per_mille);
    }
};

// ---- The bottom-K sketch -----------------------------------------------------------------------

pub const sketch_keys_max = constants.summary_sketch_keys;

pub const Entry = struct {
    /// Bytes `16..24` of the chunk's hash, little endian.
    key: u64,
    /// The chunk's size, for the weight.
    bytes: u32,
};

fn key_of(hash: *const Hash) u64 {
    return std.mem.readInt(u64, hash[16..24], .little);
}

/// The K smallest keys of a tree's distinct chunks. Because the keys are uniform, the entries are a
/// uniform sample of the tree's chunks, and a sketch with fewer than K chunks is exact.
pub const Sketch = struct {
    /// The tree's digest, or all zero for a sketch that stands for no one tree.
    tree: Hash = hash_zero,
    /// Chunks added, and their bytes: the tree's size. A chunk is counted once per `add`; the
    /// caller adds each distinct chunk once (a repeat of a chunk still in the sample is dropped,
    /// a repeat of one that fell out of it cannot be seen).
    chunks: u32 = 0,
    total_bytes: u64 = 0,
    count: u32 = 0,
    /// Ascending by key, distinct.
    entries: [sketch_keys_max]Entry = undefined,

    pub fn init(tree: Hash) Sketch {
        return .{ .tree = tree };
    }

    pub fn slice(sketch: *const Sketch) []const Entry {
        assert(sketch.count <= sketch_keys_max);
        return sketch.entries[0..sketch.count];
    }

    /// True if the sample is every chunk of the tree.
    pub fn exact(sketch: *const Sketch) bool {
        assert(sketch.count <= sketch.chunks);
        return sketch.count == sketch.chunks;
    }

    /// The largest key the sample is complete up to, or null if it is complete throughout.
    pub fn limit(sketch: *const Sketch) ?u64 {
        if (sketch.exact()) return null;
        assert(sketch.count == sketch_keys_max); // Not exact means the sample is full.
        return sketch.entries[sketch.count - 1].key;
    }

    pub fn add(sketch: *Sketch, hash: *const Hash, bytes: u32) void {
        assert(bytes > 0);
        assert(bytes <= constants.swarm_chunk_bytes);
        sketch.add_entry(.{ .key = key_of(hash), .bytes = bytes });
    }

    /// `add` for a key that is already extracted (the union of sketches uses it).
    fn add_entry(sketch: *Sketch, entry: Entry) void {
        const found = lower_bound(sketch.slice(), entry.key);
        if (found < sketch.count and sketch.entries[found].key == entry.key) return;
        sketch.chunks += 1;
        sketch.total_bytes += entry.bytes;
        if (sketch.count < sketch_keys_max) {
            sketch.insert_at(found, entry);
        } else if (found < sketch_keys_max) {
            sketch.count -= 1; // The largest key leaves the sample.
            sketch.insert_at(found, entry);
        }
        assert(sketch.count <= sketch.chunks);
    }

    fn insert_at(sketch: *Sketch, at: u32, entry: Entry) void {
        assert(sketch.count < sketch_keys_max);
        var index = sketch.count;
        while (index > at) : (index -= 1) sketch.entries[index] = sketch.entries[index - 1];
        sketch.entries[at] = entry;
        sketch.count += 1;
    }
};

/// The index of the first entry whose key is at least `key`.
fn lower_bound(entries: []const Entry, key: u64) u32 {
    var low: u32 = 0;
    var high: u32 = @intCast(entries.len);
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (entries[middle].key < key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

/// The bottom-K of the union of several trees' chunks: the K smallest keys among theirs. It is
/// exact only below the smallest limit of the trees it merges.
fn union_of(held: []const Sketch) Sketch {
    var merged: Sketch = .{};
    for (held) |*tree| {
        for (tree.slice()) |entry| merged.add_entry(entry);
    }
    return merged;
}

/// What the node's summary says it holds, for `locality_bytes`: the sketches of the complete
/// trees on the node (their order does not matter).
pub fn locality_bytes(target: *const Sketch, held: []const Sketch) u64 {
    assert(held.len <= constants.summary_trees_max);
    if (target.chunks == 0) return 0;
    if (!std.mem.eql(u8, &target.tree, &hash_zero)) {
        for (held) |*tree| {
            if (std.mem.eql(u8, &tree.tree, &target.tree)) return target.total_bytes;
        }
    }
    const node = union_of(held);
    // Each sketch is exact below its own limit, so the union of the held ones is exact below the
    // smallest held limit (not below the union's own limit, which can be far lower), and the
    // target is exact below its own: compare in the range all of them cover.
    var cutoff: ?u64 = target.limit();
    for (held) |*tree| {
        const tree_limit = tree.limit() orelse continue;
        cutoff = if (cutoff) |own| @min(own, tree_limit) else tree_limit;
    }
    var sampled: u64 = 0;
    var hit: u64 = 0;
    for (target.slice()) |entry| {
        if (cutoff) |limit| {
            if (entry.key > limit) break;
        }
        sampled += entry.bytes;
        const found = lower_bound(node.slice(), entry.key);
        if (found < node.count and node.entries[found].key == entry.key) {
            hit += entry.bytes;
        }
    }
    if (sampled == 0) return 0; // Nothing to judge by: advisory, so no credit.
    assert(hit <= sampled);
    const estimate: u64 = @intCast(@as(u128, target.total_bytes) * hit / sampled);
    assert(estimate <= target.total_bytes);
    if (target.exact()) assert(sampled <= target.total_bytes);
    return estimate;
}

// ---- Tests -------------------------------------------------------------------------------------

fn random_hash(random: std.Random) Hash {
    var hash: Hash = undefined;
    random.bytes(&hash);
    return hash;
}

test "a filter has no false negatives and a false-positive rate within bound at capacity" {
    // Goal: c2.md's Bloom test. Method: fill a filter sized for 4096 chunks with 4096 seeded
    // hashes, check each is found, then probe 100,000 other hashes (a random 32-byte hash
    // colliding with a held one is not a case worth a thought) and bound the hits at 1.5 %
    // against the design's 0.82 %.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const capacity = 4096;
    var storage: [Filter.bytes_for(capacity)]u8 = undefined;
    @memset(&storage, 0xAA); // Not zero: `init` must clear it.
    var filter = Filter.init(&storage);
    try std.testing.expectEqual(@as(u32, 0), filter.fill_per_mille());
    var held: [capacity]Hash = undefined;
    for (&held) |*hash| {
        hash.* = random_hash(random);
        filter.add(hash);
    }
    for (&held) |*hash| try std.testing.expect(filter.maybe_has(hash));
    var false_positives: u32 = 0;
    const probes = 100_000;
    for (0..probes) |_| {
        const absent = random_hash(random);
        if (filter.maybe_has(&absent)) false_positives += 1;
    }
    try std.testing.expect(false_positives * 1000 < probes * 15);
    // The count is not zero either: a filter that says yes to everything would fail above, and
    // one that says no would have failed the held loop.
    const fill = filter.fill_per_mille();
    try std.testing.expect(fill > 400 and fill < 600);
}

test "an over-full filter says yes more often, which the fill shows" {
    // Goal: the negative space of the bound: capacity matters, and `fill_per_mille` notices.
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var storage: [Filter.bytes_for(512)]u8 = undefined;
    var filter = Filter.init(&storage);
    for (0..2048) |_| {
        const hash = random_hash(random);
        filter.add(&hash);
    }
    try std.testing.expect(filter.fill_per_mille() > 900);
}

test "merging two filters holds both sets" {
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var storage_a: [Filter.bytes_for(256)]u8 = undefined;
    var storage_b: [Filter.bytes_for(256)]u8 = undefined;
    var a = Filter.init(&storage_a);
    var b = Filter.init(&storage_b);
    var in_a: [100]Hash = undefined;
    var in_b: [100]Hash = undefined;
    for (&in_a) |*hash| {
        hash.* = random_hash(random);
        a.add(hash);
    }
    for (&in_b) |*hash| {
        hash.* = random_hash(random);
        b.add(hash);
    }
    a.merge(&b);
    for (&in_a) |*hash| try std.testing.expect(a.maybe_has(hash));
    for (&in_b) |*hash| try std.testing.expect(a.maybe_has(hash));
}

test "a filter of the least size still probes inside itself" {
    // Boundary: 8 bytes is 64 bits; every probe must land in them (the assertion in `add` and
    // the indexing check it).
    var prng = std.Random.DefaultPrng.init(3);
    var storage: [8]u8 = undefined;
    var filter = Filter.init(&storage);
    for (0..100) |_| {
        const hash = random_hash(prng.random());
        filter.add(&hash);
    }
    try std.testing.expect(filter.fill_per_mille() <= 1000);
}

test "a sketch keeps the smallest keys, sorted, and counts the tree" {
    // Goal: the bottom-K rule. Method: add 200 chunks of 1 MiB in random order and compare the
    // sample with the 64 smallest keys sorted by the test itself.
    var prng = std.Random.DefaultPrng.init(21);
    const random = prng.random();
    var sketch = Sketch.init(random_hash(random));
    var keys: [200]u64 = undefined;
    for (&keys) |*key| {
        const hash = random_hash(random);
        key.* = key_of(&hash);
        sketch.add(&hash, constants.swarm_chunk_bytes);
        sketch.add(&hash, constants.swarm_chunk_bytes); // A repeat inside the sample is dropped.
    }
    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    try std.testing.expectEqual(@as(u32, sketch_keys_max), sketch.count);
    for (sketch.slice(), keys[0..sketch_keys_max]) |entry, expected| {
        try std.testing.expectEqual(expected, entry.key);
    }
    try std.testing.expect(!sketch.exact());
    try std.testing.expectEqual(keys[sketch_keys_max - 1], sketch.limit().?);
    // Repeats of the large keys went uncounted only when they were in the sample; the total is
    // at least the 200 chunks and at most twice that.
    try std.testing.expect(sketch.chunks >= 200 and sketch.chunks <= 400);
}

test "a small tree's sketch is exact" {
    var prng = std.Random.DefaultPrng.init(22);
    var sketch = Sketch.init(random_hash(prng.random()));
    for (0..10) |_| {
        const hash = random_hash(prng.random());
        sketch.add(&hash, 1000);
    }
    try std.testing.expect(sketch.exact());
    try std.testing.expectEqual(@as(?u64, null), sketch.limit());
    try std.testing.expectEqual(@as(u64, 10_000), sketch.total_bytes);
}

/// Builds the target tree of `target_chunks` chunks and a held tree that has `shared_per_mille`
/// of them and as many others besides; returns the target and the held sketch, and the true
/// bytes shared.
fn overlap_case(
    random: std.Random,
    target_chunks: u32,
    shared_per_mille: u32,
    target: *Sketch,
    held: *Sketch,
) u64 {
    target.* = Sketch.init(random_hash(random));
    held.* = Sketch.init(random_hash(random)); // A different tree: no shortcut by id.
    var shared: u64 = 0;
    for (0..target_chunks) |_| {
        const hash = random_hash(random);
        const size: u32 = random.intRangeAtMost(u32, 1000, constants.swarm_chunk_bytes);
        target.add(&hash, size);
        if (random.uintLessThan(u32, 1000) < shared_per_mille) {
            held.add(&hash, size);
            shared += size;
        }
    }
    while (held.chunks < target_chunks) {
        const hash = random_hash(random);
        held.add(&hash, constants.swarm_chunk_bytes);
    }
    return shared;
}

test "the locality estimate is exact at 0 and 100 per cent and within bound between" {
    // Goal: c2.md's sketch bound at overlaps of 0, 50, 99 and 100 %. Method: 100 seeded trials
    // of a 2000-chunk target against a held tree of the same size; chunk sizes differ, so the
    // weighting by bytes is exercised. Bounds: exact at 0 and 100; at 99 within 10 % of the
    // tree (it is about 1.6 % a differing sample); at 50 within 30 % of the tree (the standard
    // deviation is about 6 %) and on average within 10 %.
    var prng = std.Random.DefaultPrng.init(0xc2);
    const random = prng.random();
    const overlaps = [_]u32{ 0, 500, 990, 1000 };
    for (overlaps) |overlap| {
        var error_sum: u64 = 0;
        for (0..100) |_| {
            var target: Sketch = undefined;
            var held: Sketch = undefined;
            const truth = overlap_case(random, 2000, overlap, &target, &held);
            const estimate = locality_bytes(&target, &.{held});
            const difference = if (estimate > truth) estimate - truth else truth - estimate;
            error_sum += difference;
            switch (overlap) {
                0 => try std.testing.expectEqual(@as(u64, 0), estimate),
                1000 => try std.testing.expectEqual(target.total_bytes, estimate),
                990 => try std.testing.expect(difference * 10 < target.total_bytes),
                else => try std.testing.expect(difference * 10 < target.total_bytes * 3),
            }
        }
        if (overlap == 500) try std.testing.expect(error_sum / 100 < 2000 * 524_288 / 10);
    }
}

test "a held tree with the target's digest is worth its whole size" {
    var prng = std.Random.DefaultPrng.init(31);
    const random = prng.random();
    var target = Sketch.init(random_hash(random));
    for (0..500) |_| {
        const hash = random_hash(random);
        target.add(&hash, 4096);
    }
    var held: Sketch = Sketch.init(target.tree); // Same digest, an empty sample: id decides.
    held.chunks = 0;
    try std.testing.expectEqual(target.total_bytes, locality_bytes(&target, &.{held}));
    // Nothing held, or a target with nothing in it, is worth nothing.
    try std.testing.expectEqual(@as(u64, 0), locality_bytes(&target, &.{}));
    try std.testing.expectEqual(@as(u64, 0), locality_bytes(&Sketch.init(target.tree), &.{held}));
}

test "several held trees together cover the target" {
    // Goal: the union rule. Method: the target is two halves; two held trees each have one half
    // (different digests): together they are worth the whole, and each alone about half.
    var prng = std.Random.DefaultPrng.init(32);
    const random = prng.random();
    var target = Sketch.init(random_hash(random));
    var left = Sketch.init(random_hash(random));
    var right = Sketch.init(random_hash(random));
    for (0..1000) |index| {
        const hash = random_hash(random);
        target.add(&hash, 1000);
        if (index % 2 == 0) left.add(&hash, 1000) else right.add(&hash, 1000);
    }
    const both = locality_bytes(&target, &.{ left, right });
    try std.testing.expectEqual(target.total_bytes, both);
    const half = locality_bytes(&target, &.{left});
    try std.testing.expect(half > target.total_bytes / 4);
    try std.testing.expect(half < target.total_bytes * 3 / 4);
}

test "many held versions at about 20 per cent churn estimate the target within bound" {
    // Goal: the estimate stays accurate when the union of the held trees is far larger than the
    // target (the cutoff is the smallest limit, not the union's). Method: a chain of versions of
    // 1000 chunks, each replacing 20 % of the previous one's chunks; the first 16 are held, the
    // 17th is the target; the truth is the target bytes not new in it. 20 seeded trials at 16
    // and 32 held versions (the 32 only if the tree table allows), mean error within 10 %.
    var prng = std.Random.DefaultPrng.init(0xc3);
    const random = prng.random();
    const chunks = 1000;
    const Chunk = struct { hash: Hash, size: u32 };
    for ([_]u32{ 16, 32 }) |versions| {
        if (versions > constants.summary_trees_max) continue;
        var error_sum: u64 = 0;
        for (0..20) |_| {
            var current: [chunks]Chunk = undefined;
            for (&current) |*chunk| chunk.* = .{
                .hash = random_hash(random),
                .size = random.intRangeAtMost(u32, 1000, constants.swarm_chunk_bytes),
            };
            var held: [32]Sketch = undefined;
            var target: Sketch = undefined;
            var truth: u64 = 0;
            for (0..versions + 1) |version| {
                var sketch = Sketch.init(random_hash(random));
                truth = 0;
                for (&current) |*chunk| {
                    if (version > 0 and random.uintLessThan(u32, 5) == 0) {
                        chunk.* = .{
                            .hash = random_hash(random),
                            .size = random.intRangeAtMost(u32, 1000, constants.swarm_chunk_bytes),
                        };
                    } else truth += chunk.size;
                    sketch.add(&chunk.hash, chunk.size);
                }
                if (version < versions) held[version] = sketch else target = sketch;
            }
            const estimate = locality_bytes(&target, held[0..versions]);
            error_sum += if (estimate > truth) estimate - truth else truth - estimate;
        }
        try std.testing.expect(error_sum / 20 * 10 < 1000 * constants.swarm_chunk_bytes / 2);
    }
}
