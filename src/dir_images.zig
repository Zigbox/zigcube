//! The agent's image store as a directory (C2 slice 6b): the shell's `Images`.
//!
//!   <root>/trees/<name>     a tree's chunk list, one `<64 hex> <bytes>` line per chunk; the name
//!                           is the digest with `:` as `-`
//!   <root>/chunks/<64 hex>  the bytes of one chunk, written only after BLAKE3 of them matched
//!
//! A tree is held when its list is there and every chunk it names is. `put_chunk` and
//! `read_chunk` check BLAKE3 against the name, so a bad chunk is never stored and never served;
//! `put_tree` holds a list to its digest (`node_store.list_matches`). Writes are a temporary file
//! renamed into place, so a reader sees a whole file or none, and a crash leaves no half chunk
//! under its name. A `DirImages` belongs to one thread (its buffers are shared by its calls);
//! each thread opens its own, and the directory itself may be shared (writes are renames of
//! uniquely named temporary files). Shell code: files. The fake registry and the demo seed it
//! with `put_tree`.

const std = @import("std");
const assert = std.debug.assert;
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const fake_files = @import("fake_files.zig");
const node_store = @import("node_store.zig");

const Allocator = std.mem.Allocator;
const ChunkRef = @import("fetch_plan.zig").ChunkRef;
const Dir = std.Io.Dir;
const Hash = chunk_summary.Hash;

pub const dir_trees = "trees";
pub const dir_chunks = "chunks";

pub const DirImages = struct {
    io: std.Io,
    root: Dir,
    /// One tree list's text, read into here (startup allocation, `tree_list_bytes_max`).
    list: []u8,
    refs: []ChunkRef,
    /// The most chunks a summary's filter is made for (`summary_chunks_capacity`; a test lowers
    /// it). Trees past it are left out of the summary and counted in `omitted`, so the filter
    /// never holds more than it was sized for and the hashes read stay under 2 MiB.
    chunks_capacity: u32 = constants.summary_chunks_capacity,

    pub const OpenError = error{ OutOfMemory, Unusable };

    /// Opens (making) the store at `path`. `allocator` is used here only.
    pub fn open(io: std.Io, allocator: Allocator, path: []const u8) OpenError!DirImages {
        const cwd = Dir.cwd();
        cwd.createDirPath(io, path) catch return error.Unusable;
        var root = cwd.openDir(io, path, .{ .iterate = true }) catch return error.Unusable;
        errdefer root.close(io);
        root.createDirPath(io, dir_trees) catch return error.Unusable;
        root.createDirPath(io, dir_chunks) catch return error.Unusable;
        for ([_][]const u8{ dir_trees, dir_chunks }) |name| {
            sweep_temps(io, root, name, constants.dir_temp_stale_ms);
        }
        const list = try allocator.alloc(u8, constants.tree_list_bytes_max);
        errdefer allocator.free(list);
        const refs = try allocator.alloc(ChunkRef, constants.fetch_chunks_max);
        return .{ .io = io, .root = root, .list = list, .refs = refs };
    }

    pub fn close(self: *DirImages, allocator: Allocator) void {
        allocator.free(self.list);
        allocator.free(self.refs);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub fn images(self: *DirImages) node_store.Images {
        return .{
            .context = self,
            .summary_fn = summary_impl,
            .has_fn = has_impl,
            .chunk_list_fn = chunk_list_impl,
            .read_chunk_fn = read_chunk_impl,
            .put_chunk_fn = put_chunk_impl,
        };
    }

    /// Stores a tree's chunk list, after checking it is what `digest` names and parses.
    pub fn put_tree(
        self: *DirImages,
        digest: []const u8,
        list: []const u8,
    ) node_store.ChunkError!void {
        if (!node_store.list_matches(digest, list)) return error.BadHash;
        if (list.len > self.list.len) return error.BadHash;
        const count = node_store.list_parse(list, self.refs) orelse return error.BadHash;
        // Only the canonical text: it is what a peer will be sent, and what the digest names.
        const canon = node_store.list_format(self.refs[0..count], self.list) orelse
            return error.BadHash;
        if (!std.mem.eql(u8, canon, list)) return error.BadHash;
        var name_buffer: [80]u8 = undefined;
        const name = tree_name(&name_buffer, digest) orelse return error.BadHash;
        const trees = self.root.openDir(self.io, dir_trees, .{}) catch return error.StoreFailed;
        defer trees.close(self.io);
        write_whole(self.io, trees, name, list) catch return error.StoreFailed;
    }

    fn from(context: *anyopaque) *DirImages {
        return @ptrCast(@alignCast(context));
    }

    /// `digest` as a file name, or null if it has anything but hex after `b3:`: a name that came
    /// from a peer's URL must not walk out of the directory.
    fn tree_name(buffer: []u8, digest: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, digest, "b3:")) return null;
        const hex = digest[3..];
        if (hex.len < 8 or hex.len > 64 or 3 + hex.len > buffer.len) return null;
        for (hex) |c| {
            if (!std.ascii.isDigit(c)) {
                if (c < 'a' or c > 'f') return null; // Lower case only: one name per tree.
            }
        }
        @memcpy(buffer[0..3], "b3-");
        @memcpy(buffer[3..][0..hex.len], hex);
        return buffer[0 .. 3 + hex.len];
    }

    fn chunk_name(buffer: *[64]u8, hash: *const Hash) []const u8 {
        for (hash, 0..) |byte, at| {
            buffer[at * 2] = "0123456789abcdef"[byte >> 4];
            buffer[at * 2 + 1] = "0123456789abcdef"[byte & 15];
        }
        return buffer;
    }

    /// The tree's list parsed into `self.refs`; its length, or null if the tree has no list.
    fn load_list(self: *DirImages, digest: []const u8) ?u32 {
        var name_buffer: [80]u8 = undefined;
        const name = tree_name(&name_buffer, digest) orelse return null;
        const trees = self.root.openDir(self.io, dir_trees, .{}) catch return null;
        defer trees.close(self.io);
        const text = trees.readFile(self.io, name, self.list) catch return null;
        if (text.len == self.list.len) return null; // Does not fit: not a list we wrote.
        return node_store.list_parse(text, self.refs);
    }

    /// Whether the chunk is in `chunks` at the size the list gives (a cut-short file is not held;
    /// its hash is checked only when it is read).
    fn has_chunk(self: *DirImages, chunks: Dir, ref: ChunkRef) bool {
        var name_buffer: [64]u8 = undefined;
        const stat = chunks.statFile(self.io, chunk_name(&name_buffer, &ref.hash), .{}) catch
            return false;
        return stat.size == ref.bytes;
    }

    /// Whether every chunk of the `count` in `self.refs` is in `chunks`.
    fn complete(self: *DirImages, chunks: Dir, count: u32) bool {
        for (self.refs[0..count]) |ref| {
            if (!self.has_chunk(chunks, ref)) return false;
        }
        return true;
    }

    fn has_impl(context: *anyopaque, tree: []const u8) bool {
        const self = from(context);
        const count = self.load_list(tree) orelse return false;
        const chunks = self.root.openDir(self.io, dir_chunks, .{}) catch return false;
        defer chunks.close(self.io);
        return self.complete(chunks, count);
    }

    fn chunk_list_impl(
        context: *anyopaque,
        tree: []const u8,
        out: []ChunkRef,
    ) node_store.ChunkError!u32 {
        const self = from(context);
        const count = self.load_list(tree) orelse return error.NotFound;
        if (count > out.len) return error.StoreFailed;
        @memcpy(out[0..count], self.refs[0..count]);
        return count;
    }

    fn read_chunk_impl(
        context: *anyopaque,
        hash: *const Hash,
        out: []u8,
    ) node_store.ChunkError![]u8 {
        const self = from(context);
        const chunks = self.root.openDir(self.io, dir_chunks, .{}) catch return error.StoreFailed;
        defer chunks.close(self.io);
        var name_buffer: [64]u8 = undefined;
        const name = chunk_name(&name_buffer, hash);
        const bytes = chunks.readFile(self.io, name, out) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.StoreFailed,
        };
        if (bytes.len == out.len) {
            // Exactly full: a whole chunk of the largest size, or a longer file cut short.
            const stat = chunks.statFile(self.io, name, .{}) catch return error.StoreFailed;
            if (stat.size != out.len) return error.BadHash;
        }
        if (!node_store.chunk_verifies(hash, bytes)) return error.BadHash;
        return bytes;
    }

    fn put_chunk_impl(
        context: *anyopaque,
        hash: *const Hash,
        bytes: []const u8,
    ) node_store.ChunkError!void {
        const self = from(context);
        if (!node_store.chunk_verifies(hash, bytes)) return error.BadHash;
        const chunks = self.root.openDir(self.io, dir_chunks, .{}) catch return error.StoreFailed;
        defer chunks.close(self.io);
        var name_buffer: [64]u8 = undefined;
        const name = chunk_name(&name_buffer, hash);
        write_whole(self.io, chunks, name, bytes) catch return error.StoreFailed;
    }

    fn summary_impl(
        context: *anyopaque,
        arena: Allocator,
        started: []const []const u8,
    ) node_store.Error!node_store.Summary {
        _ = started; // A directory store holds what it holds, run or not.
        const self = from(context);
        const iterating: Dir.OpenOptions = .{ .iterate = true };
        const trees = self.root.openDir(self.io, dir_trees, iterating) catch return .{};
        defer trees.close(self.io);
        const chunks = self.root.openDir(self.io, dir_chunks, .{}) catch return .{};
        defer chunks.close(self.io);
        var held: std.ArrayList(node_store.Held) = .empty;
        var hashes: std.ArrayList(Hash) = .empty;
        var omitted: u32 = 0;
        var iterator = trees.iterate();
        for (0..constants.fake_dir_entries_max) |_| {
            const entry = iterator.next(self.io) catch break orelse break;
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "b3-")) continue;
            const digest = try arena.dupe(u8, entry.name);
            digest[2] = ':';
            const count = self.load_list(digest) orelse continue;
            if (!self.complete(chunks, count)) continue;
            const over_trees = held.items.len == constants.summary_trees_max;
            if (over_trees or hashes.items.len + count > self.chunks_capacity) {
                omitted += 1;
                continue;
            }
            var sketch = chunk_summary.Sketch.init(node_store.tree_hash(digest));
            for (self.refs[0..count]) |ref| {
                sketch.add(&ref.hash, ref.bytes);
                try hashes.append(arena, ref.hash);
            }
            try held.append(arena, .{ .digest = digest, .sketch = sketch });
        }
        if (hashes.items.len == 0) return .{ .omitted = omitted };
        const capacity: u32 = @intCast(hashes.items.len);
        assert(capacity <= self.chunks_capacity);
        const size = chunk_summary.Filter.bytes_for(@max(capacity, 64));
        const bits = try arena.alloc(u8, size);
        var filter = chunk_summary.Filter.init(bits);
        for (hashes.items) |*hash| filter.add(hash);
        return .{
            .trees = held.items,
            .omitted = omitted,
            .filter = bits,
            .filter_chunks = capacity,
        };
    }
};

/// `data` as `name` in `dir`, whole or not at all: a temporary file, synced, then renamed.
fn write_whole(io: std.Io, dir: Dir, name: []const u8, data: []const u8) !void {
    // A name of its own per write: two writers of one chunk must not share a temporary file.
    var random: [8]u8 = undefined;
    io.random(&random);
    var temp_buffer: [96]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.{x}.tmp", .{ name, &random });
    {
        const file = try dir.createFile(io, temp, .{ .exclusive = true });
        defer file.close(io);
        // A write that fails leaves nothing behind: the name is random, so nothing else would
        // ever remove it.
        errdefer dir.deleteFile(io, temp) catch {}; // Already failing; the sweep at open is next.
        try file.writeStreamingAll(io, data);
        try file.sync(io);
    }
    errdefer dir.deleteFile(io, temp) catch {}; // The rename failed: same.
    try dir.rename(temp, dir, name, io);
    try fake_files.sync_dir(io, dir);
}

/// Removes the temporary files (`*.tmp`) of `sub` under `root` that were last written more than
/// `stale_ms` ago: a writer that was killed between create and rename leaves one, and its random
/// name means no later write reuses it. Younger ones may belong to a live writer (the agent, a
/// fetch and the peer server share the directory), so they stay. Best effort.
fn sweep_temps(io: std.Io, root: Dir, sub: []const u8, stale_ms: u64) void {
    const iterating: Dir.OpenOptions = .{ .iterate = true };
    const dir = root.openDir(io, sub, iterating) catch return;
    defer dir.close(io);
    const now = std.Io.Clock.real.now(io).toNanoseconds();
    var iterator = dir.iterate();
    for (0..constants.dir_sweep_entries_max) |_| {
        const entry = iterator.next(io) catch return;
        const found = entry orelse return;
        if (found.kind != .file) continue;
        if (!std.mem.endsWith(u8, found.name, ".tmp")) continue;
        const stat = dir.statFile(io, found.name, .{}) catch continue;
        const age_ns = now - stat.mtime.toNanoseconds();
        if (age_ns < @as(i96, stale_ms) * std.time.ns_per_ms) continue;
        dir.deleteFile(io, found.name) catch {}; // Another sweeper was first, or it is not ours.
    }
}

// ---- Tests --------------------------------------------------------------------------------

/// A tree of `count` small chunks for tests: the list text and, in `chunks`, their bytes.
const Sample = struct {
    list: [1024]u8 = undefined,
    list_len: u32 = 0,
    digest: [67]u8 = undefined,
    hashes: [4]Hash = undefined,
    bodies: [4][40]u8 = undefined,

    fn make(sample: *Sample, seed: u8, count: usize) void {
        var writer: std.Io.Writer = .fixed(&sample.list);
        for (0..count) |index| {
            @memset(&sample.bodies[index], seed +% @as(u8, @intCast(index)));
            std.crypto.hash.Blake3.hash(&sample.bodies[index], &sample.hashes[index], .{});
            writer.print("{x} 40\n", .{&sample.hashes[index]}) catch unreachable; // Sized.
        }
        sample.list_len = @intCast(writer.buffered().len);
        _ = node_store.list_digest(sample.list[0..sample.list_len], &sample.digest);
    }
};

fn test_store(tmp: *std.testing.TmpDir) !DirImages {
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/store", .{tmp.sub_path});
    return DirImages.open(std.testing.io, std.testing.allocator, path);
}

test "a directory store holds a tree only when every chunk is there, and serves it verified" {
    // Goal: the seam's rules: has needs all chunks, put_chunk refuses a wrong hash and stores
    // nothing, read_chunk checks what it reads, the list comes back as written, and the summary
    // shows the tree with a filter that has its chunks. Method: put chunks one by one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    const images = store.images();
    var sample: Sample = .{};
    sample.make(10, 3);
    const digest: []const u8 = &sample.digest;
    const list = sample.list[0..sample.list_len];
    try std.testing.expectError(error.BadHash, store.put_tree("b3:00000000", list));
    try store.put_tree(digest, list);
    try std.testing.expect(!images.has(digest));
    for (0..3) |index| try images.put_chunk(&sample.hashes[index], &sample.bodies[index]);
    // The wrong bytes under a right hash are refused and leave nothing.
    try std.testing.expectError(error.BadHash, images.put_chunk(&sample.hashes[0], "not it"));
    try std.testing.expect(images.has(digest));
    var refs: [8]ChunkRef = undefined;
    try std.testing.expectEqual(@as(u32, 3), try images.chunk_list(digest, &refs));
    try std.testing.expectEqualSlices(u8, &sample.hashes[2], &refs[2].hash);
    try std.testing.expectError(error.NotFound, images.chunk_list("b3:12345678", &refs));
    try std.testing.expectError(error.NotFound, images.chunk_list("../../x", &refs));
    const out = try std.testing.allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer std.testing.allocator.free(out);
    const read = try images.read_chunk(&sample.hashes[1], out);
    try std.testing.expectEqualSlices(u8, &sample.bodies[1], read);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const summary = try images.summary(arena_state.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 1), summary.trees.len);
    try std.testing.expectEqual(@as(u32, 3), summary.filter_chunks);
    var filter = chunk_summary.Filter.view(@constCast(summary.filter));
    for (sample.hashes[0..3]) |*hash| try std.testing.expect(filter.maybe_has(hash));
}

test "a chunk file that was damaged on disk is not served" {
    // Goal: read_chunk checks BLAKE3 of what is on disk, so a rotten file never reaches a peer.
    // Method: store a chunk, overwrite its file with other bytes, read it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    const images = store.images();
    var sample: Sample = .{};
    sample.make(30, 1);
    try images.put_chunk(&sample.hashes[0], &sample.bodies[0]);
    var name: [64]u8 = undefined;
    const chunks = try store.root.openDir(std.testing.io, dir_chunks, .{});
    defer chunks.close(std.testing.io);
    const file = DirImages.chunk_name(&name, &sample.hashes[0]);
    try write_whole(std.testing.io, chunks, file, "rotten");
    const out = try std.testing.allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer std.testing.allocator.free(out);
    try std.testing.expectError(error.BadHash, images.read_chunk(&sample.hashes[0], out));
}

test "a chunk file cut short is not held" {
    // Goal: `has` checks the size the list gives, not only that the name exists. Method: a whole
    // tree, then one chunk's file replaced by a shorter one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    const images = store.images();
    var sample: Sample = .{};
    sample.make(50, 2);
    const digest: []const u8 = &sample.digest;
    try store.put_tree(digest, sample.list[0..sample.list_len]);
    for (0..2) |index| try images.put_chunk(&sample.hashes[index], &sample.bodies[index]);
    try std.testing.expect(images.has(digest));
    var name: [64]u8 = undefined;
    const chunks = try store.root.openDir(std.testing.io, dir_chunks, .{});
    defer chunks.close(std.testing.io);
    try write_whole(std.testing.io, chunks, DirImages.chunk_name(&name, &sample.hashes[1]), "cut");
    try std.testing.expect(!images.has(digest));
}

test "a summary leaves out trees past the filter's capacity" {
    // Goal: the filter is never over capacity (it would saturate and claim everything), and the
    // memory a summary reads is bounded. Method: capacity 4 chunks, a tree of 3 and one of 2.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    store.chunks_capacity = 4;
    const images = store.images();
    var first: Sample = .{};
    first.make(60, 3);
    var second: Sample = .{};
    second.make(90, 2);
    for ([_]*Sample{ &first, &second }) |sample| {
        try store.put_tree(&sample.digest, sample.list[0..sample.list_len]);
        for (0..3) |index| {
            if (std.mem.eql(u8, &sample.digest, &first.digest) or index < 2) {
                try images.put_chunk(&sample.hashes[index], &sample.bodies[index]);
            }
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const summary = try images.summary(arena_state.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 1), summary.trees.len);
    try std.testing.expectEqual(@as(u32, 1), summary.omitted);
    // Directory order decides which tree came first; the other no longer fits.
    const kept_first = std.mem.eql(u8, summary.trees[0].digest, &first.digest);
    try std.testing.expectEqual(@as(u32, if (kept_first) 3 else 2), summary.filter_chunks);
}

test "a chunk of exactly the largest size is stored, read and served" {
    // Goal: a full-size chunk (every chunk but a file's last) is not mistaken for an overlong
    // file. Method: store swarm_chunk_bytes of data, read it into a buffer of that size; then a
    // file one byte longer under the same name is refused.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try test_store(&tmp);
    defer store.close(std.testing.allocator);
    const images = store.images();
    const big = try std.testing.allocator.alloc(u8, constants.swarm_chunk_bytes + 1);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*byte, at| byte.* = @truncate(at *% 7);
    var hash: Hash = undefined;
    std.crypto.hash.Blake3.hash(big[0..constants.swarm_chunk_bytes], &hash, .{});
    try images.put_chunk(&hash, big[0..constants.swarm_chunk_bytes]);
    const out = try std.testing.allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer std.testing.allocator.free(out);
    const read = try images.read_chunk(&hash, out);
    try std.testing.expectEqualSlices(u8, big[0..constants.swarm_chunk_bytes], read);
    const chunks = try store.root.openDir(std.testing.io, dir_chunks, .{});
    defer chunks.close(std.testing.io);
    var name: [64]u8 = undefined;
    try write_whole(std.testing.io, chunks, DirImages.chunk_name(&name, &hash), big);
    try std.testing.expectError(error.BadHash, images.read_chunk(&hash, out));
}

test "a write never touches another writer's temporary file" {
    // Goal: two writers of one file must not share a temporary name (one would truncate or
    // rename away the other's half-written file). Method: leave a file under the plain
    // `<name>.tmp` as a stand-in for a concurrent writer's, write the name, and check the
    // write landed whole and the stand-in is untouched.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.tmp", .data = "half-written" });
    try write_whole(std.testing.io, tmp.dir, "other", "whole");
    var buffer: [32]u8 = undefined;
    const whole = try tmp.dir.readFile(std.testing.io, "other", &buffer);
    try std.testing.expectEqualStrings("whole", whole);
    const stand_in = try tmp.dir.readFile(std.testing.io, "other.tmp", &buffer);
    try std.testing.expectEqualStrings("half-written", stand_in);
}

fn count_temps(dir: Dir) !u32 {
    var count: u32 = 0;
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".tmp")) count += 1;
    }
    return count;
}

test "a write that fails leaves no temporary file, and open sweeps the stale ones" {
    // Goal: review S1. Method: make the rename fail (the name is a directory), count the
    // temporary files; then leave one by hand, and see open keep it while it is young and a
    // sweep with no age remove it.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "blocked", .default_dir);
    try std.testing.expect(std.meta.isError(write_whole(io, tmp.dir, "blocked", "data")));
    try std.testing.expectEqual(@as(u32, 0), try count_temps(tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = "left.1234.tmp", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "x" });
    sweep_temps(io, tmp.dir, ".", constants.dir_temp_stale_ms);
    try std.testing.expectEqual(@as(u32, 1), try count_temps(tmp.dir));
    sweep_temps(io, tmp.dir, ".", 0);
    try std.testing.expectEqual(@as(u32, 0), try count_temps(tmp.dir));
    try tmp.dir.access(io, "kept", .{});
}

const Writer = struct {
    dir: Dir,
    failures: std.atomic.Value(u32) = .init(0),

    fn run(writer: *Writer, data: []const u8) void {
        for (0..40) |_| {
            write_whole(std.testing.io, writer.dir, "shared", data) catch {
                _ = writer.failures.fetchAdd(1, .monotonic);
            };
        }
    }
};

test "two writers of one name leave a whole file and no temporary file" {
    // Goal: review S1, the two-writer case. Two threads write the same name with the same
    // bytes (two fetches of one tree); every write succeeds, a reader sees all of it, and no
    // temporary file is left.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var writer: Writer = .{ .dir = tmp.dir };
    const data: [512]u8 = @splat(0x5a);
    const first = try std.Thread.spawn(.{}, Writer.run, .{ &writer, &data });
    const second = try std.Thread.spawn(.{}, Writer.run, .{ &writer, &data });
    first.join();
    second.join();
    try std.testing.expectEqual(@as(u32, 0), writer.failures.load(.monotonic));
    var back: [1024]u8 = undefined;
    const read = try tmp.dir.readFile(std.testing.io, "shared", &back);
    try std.testing.expectEqualSlices(u8, &data, read);
    try std.testing.expectEqual(@as(u32, 0), try count_temps(tmp.dir));
}
