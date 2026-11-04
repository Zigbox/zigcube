//! `ZigboxImages`: the `node_store.Images` seam over Zigbox's own store (C2 slice 8). Shell code:
//! files, and Zigbox's store calls (Z1-Z4: the verified chunk read, the bounded object walk, the
//! checked tree put and the image record import).
//!
//! What the seam keys by and what Zigbox keys by differ, and the adapter is the bridge:
//!
//! * A tree is named by its Zigbox digest (`b3:` and 64 hex), the lock's digest, not by the digest
//!   of a chunk list. Its chunk list is made by walking it: each distinct object, in walk order,
//!   gives one `ChunkRef` per chunk (a hash and a length), the chunks already listed skipped.
//! * A chunk is named by its hash. Zigbox reads and writes by (object id, chunk index), and keeps
//!   no index from a hash to an object, so the adapter keeps one (`index`, made by listing a
//!   tree, rebuilt from the store's roots on a miss). A stale entry (a gc took the object) is
//!   `NotFound`, never a wrong chunk: `chunk_read.read_chunk` checks BLAKE3 before it returns.
//! * Writes take what the hash does not carry: an object's mode, owner and attributes, which its
//!   id commits to. `begin_object` takes them with the chunk hashes and holds the claim to the
//!   id (`object_id(content, attrs) == id`); `put_chunk` then lands a chunk in every claimed
//!   object that lists its hash, and Zigbox assembles an object when its last chunk arrives and
//!   checks the content hash. A tree record (`put_tree_record`) is held to its digest and encoding
//!   by `trees.put_checked`.
//! * The image record is the last step and the one a peer must not steer: `import_image` passes
//!   `expected_manifest`, which the caller takes from the assignment's digest-pinned image
//!   reference, never from the peer's text, so a record for another manifest is refused and
//!   nothing is written (`image_peer.zig`).
//!
//! One thread's. Store writes belong in the namespace child (`zigbox.store.namespace.run`), as
//! `zcube-agent fetch` does: a process of one thread that is started for the batch.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const node_store = @import("node_store.zig");

const store_api = zigbox.store;
const Allocator = std.mem.Allocator;
const ChunkRef = @import("fetch_plan.zig").ChunkRef;
const Digest = store_api.Digest;
const Hash = chunk_summary.Hash;
const Sha256 = @FieldType(store_api.image_peer.Options, "expected_manifest");
const Store = store_api.Store;

/// The most distinct objects and entries one tree walk looks at (the bound of `walk_objects`).
pub const entries_max: u32 = 1 << 16;

/// Where a chunk is held, for reads: the object and the chunk's place in it.
const Position = struct { object: Digest, index: u32 };

pub const Index = std.AutoHashMapUnmanaged(Hash, Position);

/// What the objects of a tree are, as the walk saw them.
pub const Collected = struct {
    list: std.ArrayList(store_api.walk.ObjectRef) = .empty,
    seen: std.AutoHashMapUnmanaged(Hash, void) = .empty,
    allocator: Allocator,
    failed: bool = false,

    pub fn object(self: *Collected, ref: *const store_api.walk.ObjectRef) void {
        if (self.failed) return;
        const found = self.seen.getOrPut(self.allocator, ref.id.bytes) catch {
            self.failed = true;
            return;
        };
        if (found.found_existing) return;
        self.list.append(self.allocator, ref.*) catch {
            self.failed = true;
        };
    }

    pub fn deinit(self: *Collected) void {
        self.list.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }
};

/// The distinct file objects of a tree with the attributes their tree entries record (C2 slice
/// 8, M3). Those are the ids Zigbox recorded inside its store namespace, the container's view,
/// and the object id commits to them; the file's owner as the host sees it (`lstat` outside the
/// namespace, which is where a peer server runs) is not, so it is never what a peer is sent.
pub const Described = struct {
    pub const Item = struct {
        ref: store_api.walk.ObjectRef,
        mode: u16,
        uid: u32,
        gid: u32,
        /// The canonical attribute section; owned by `arena`.
        xattrs: []const u8,
    };

    items: std.ArrayList(Item) = .empty,
    seen: std.AutoHashMapUnmanaged(Hash, void) = .empty,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    chunk_bytes: u32,
    failed: bool = false,

    pub fn entry(self: *Described, found: *const store_api.tree.Entry) void {
        if (self.failed or found.kind != .file) return;
        const slot = self.seen.getOrPut(self.allocator, found.object.bytes) catch {
            self.failed = true;
            return;
        };
        if (slot.found_existing) return;
        const xattrs = self.arena.allocator().dupe(u8, found.xattrs) catch {
            self.failed = true;
            return;
        };
        self.items.append(self.allocator, .{
            .ref = .{
                .id = found.object,
                .size = found.size,
                .content = found.content,
                .chunk_count = store_api.object.chunk_count(found.size, self.chunk_bytes),
            },
            .mode = found.mode,
            .uid = found.uid,
            .gid = found.gid,
            .xattrs = xattrs,
        }) catch {
            self.failed = true;
        };
    }

    pub fn deinit(self: *Described) void {
        self.items.deinit(self.allocator);
        self.seen.deinit(self.allocator);
        self.arena.deinit();
    }
};

/// The directory trees of a tree, the root first, each once: the records a peer needs besides
/// the objects, for a directory is a tree record of its own.
const Subtrees = struct {
    list: std.ArrayList(Digest) = .empty,
    allocator: Allocator,
    failed: bool = false,

    pub fn entry(self: *Subtrees, found: *const store_api.tree.Entry) void {
        if (self.failed or found.kind != .dir) return;
        for (self.list.items) |known| {
            if (known.eql(found.subtree)) return;
        }
        self.list.append(self.allocator, found.subtree) catch {
            self.failed = true;
        };
    }
};

/// An object a peer described: what Zigbox's `put_chunk` needs besides the chunks. `xattrs` is
/// the canonical attribute section, `hashes` one hash per chunk.
pub const ObjectMeta = struct {
    id: Digest,
    mode: u16,
    uid: u32,
    gid: u32,
    xattrs: []const u8,
    size: u64,
    content: Digest,
    hashes: []const Digest,
};

/// An object claimed by `begin_object`, with its own copies of what the claim named.
const Claim = struct {
    wanted: store_api.chunk_put.Wanted,
    xattrs: []u8,
    hashes: []Digest,
    complete: bool,
};

pub const ReceiveError = error{ OutOfMemory, BadHash, StoreFailed, Busy, TooMany };

/// Why an image record was refused: Zigbox's `Refusal`, or the store failing.
pub const ImportError = error{ Refused, StoreFailed };

pub const ZigboxImages = struct {
    allocator: Allocator,
    store: *Store,
    io: []u8,
    scratch: *store_api.xattrs.Scratch,
    tree_buffer: []u8,
    stack: []Digest,
    hashes: []Digest,
    memory: *store_api.image_peer.Memory,
    index: Index = .empty,
    /// Whether `reindex` has walked every root since the store last changed. A chunk the index
    /// lacks then cannot be found by walking again, so a peer asking for unknown hashes costs
    /// one walk, not one per hash. Cleared by whatever writes to the store.
    walked: bool = false,
    /// How many walks `reindex` has made (the tests count them).
    walks: u32 = 0,
    claims: std.ArrayList(Claim) = .empty,
    /// What the last refused `import_image` was refused for.
    refusal: ?store_api.image_peer.Refusal = null,

    pub const OpenError = error{ OutOfMemory, Unusable };

    /// Takes a store that is open (`zigbox.store.open`, or `Store.at` and `open.check`).
    pub fn open(allocator: Allocator, store: *Store) OpenError!ZigboxImages {
        const io = try allocator.alloc(u8, constants.zigbox_io_bytes);
        errdefer allocator.free(io);
        const scratch = try allocator.create(store_api.xattrs.Scratch);
        errdefer allocator.destroy(scratch);
        const tree_buffer = try allocator.alloc(u8, constants.zigbox_tree_buffer_bytes);
        errdefer allocator.free(tree_buffer);
        const stack = try allocator.alloc(Digest, constants.zigbox_walk_stack_max);
        errdefer allocator.free(stack);
        const hashes = try allocator.alloc(Digest, constants.zigbox_chunks_per_object_max);
        errdefer allocator.free(hashes);
        const memory = try allocator.create(store_api.image_peer.Memory);
        return .{
            .allocator = allocator,
            .store = store,
            .io = io,
            .scratch = scratch,
            .tree_buffer = tree_buffer,
            .stack = stack,
            .hashes = hashes,
            .memory = memory,
        };
    }

    pub fn close(self: *ZigboxImages) void {
        self.clear_claims();
        self.claims.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.allocator.destroy(self.memory);
        self.allocator.free(self.hashes);
        self.allocator.free(self.stack);
        self.allocator.free(self.tree_buffer);
        self.allocator.destroy(self.scratch);
        self.allocator.free(self.io);
        self.* = undefined;
    }

    pub fn images(self: *ZigboxImages) node_store.Images {
        return .{
            .context = self,
            .summary_fn = summary_impl,
            .has_fn = has_impl,
            .chunk_list_fn = chunk_list_impl,
            .read_chunk_fn = read_chunk_impl,
            .put_chunk_fn = put_chunk_impl,
        };
    }

    fn from(context: *anyopaque) *ZigboxImages {
        return @ptrCast(@alignCast(context));
    }

    // ---- The serving half ----------------------------------------------------------------

    /// The distinct file objects below `tree`, walk order. Null if the walk could not finish
    /// (a missing or damaged tree, too many entries, memory).
    pub fn collect(self: *ZigboxImages, tree: Digest) ?Collected {
        var found: Collected = .{ .allocator = self.allocator };
        var failure: store_api.walk.Failure = undefined;
        store_api.walk_objects(
            self.store,
            self.tree_buffer,
            self.stack,
            null,
            tree,
            &found,
            entries_max,
            &failure,
        ) catch {
            found.deinit();
            return null;
        };
        if (found.failed) {
            found.deinit();
            return null;
        }
        return found;
    }

    /// The distinct file objects below `tree` with their tree entries' attributes, walk order.
    /// Null if the walk could not finish. `collect` runs first: it stops at `entries_max`
    /// entries, so the unbounded walk here only revisits trees already read whole.
    pub fn describe(self: *ZigboxImages, tree: Digest) ?Described {
        var bounded = self.collect(tree) orelse return null;
        bounded.deinit();
        var found: Described = .{
            .arena = .init(self.allocator),
            .allocator = self.allocator,
            .chunk_bytes = self.store.chunk_bytes,
        };
        var failure: store_api.walk.Failure = undefined;
        store_api.walk.walk(
            self.store,
            self.tree_buffer,
            self.stack,
            null,
            tree,
            &found,
            &failure,
        ) catch {
            found.deinit();
            return null;
        };
        if (found.failed) {
            found.deinit();
            return null;
        }
        return found;
    }

    /// Every tree record below `tree`, `tree` first, each once. The caller frees the slice.
    pub fn tree_digests(self: *ZigboxImages, tree: Digest) ?[]Digest {
        var found: Subtrees = .{ .allocator = self.allocator };
        found.list.append(self.allocator, tree) catch return null;
        var failure: store_api.walk.Failure = undefined;
        store_api.walk.walk(
            self.store,
            self.tree_buffer,
            self.stack,
            null,
            tree,
            &found,
            &failure,
        ) catch {
            found.list.deinit(self.allocator);
            return null;
        };
        if (found.failed) {
            found.list.deinit(self.allocator);
            return null;
        }
        return found.list.toOwnedSlice(self.allocator) catch null;
    }

    fn holds_all(self: *ZigboxImages, tree: Digest) bool {
        const has_tree = store_api.has_tree(self.store, tree) catch return false;
        if (!has_tree) return false;
        var found = self.collect(tree) orelse return false;
        defer found.deinit();
        for (found.list.items) |ref| {
            const present = store_api.has_object(self.store, ref.id) catch return false;
            if (!present) return false;
        }
        return true;
    }

    fn has_impl(context: *anyopaque, tree: []const u8) bool {
        const digest = Digest.parse(tree) orelse return false;
        return from(context).holds_all(digest);
    }

    /// The chunks of `tree` into `out`, and every chunk's position into the index.
    fn list_chunks(
        self: *ZigboxImages,
        tree: Digest,
        out: []ChunkRef,
    ) node_store.ChunkError!u32 {
        var found = self.collect(tree) orelse return error.NotFound;
        defer found.deinit();
        var listed: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer listed.deinit(self.allocator);
        var count: u32 = 0;
        for (found.list.items) |ref| {
            const hashes = store_api.chunks(self.store, ref.id, self.io, self.hashes) catch
                return error.NotFound;
            for (hashes, 0..) |hash, at| {
                const fresh = listed.getOrPut(self.allocator, hash.bytes) catch
                    return error.OutOfMemory;
                if (fresh.found_existing) continue;
                if (count == out.len) return error.StoreFailed;
                const bytes = chunk_length(ref.size, self.store.chunk_bytes, @intCast(at));
                out[count] = .{ .hash = hash.bytes, .bytes = bytes };
                count += 1;
                const place = self.index.getOrPut(self.allocator, hash.bytes) catch
                    return error.OutOfMemory;
                place.value_ptr.* = .{ .object = ref.id, .index = @intCast(at) };
            }
        }
        return count;
    }

    fn chunk_list_impl(
        context: *anyopaque,
        tree: []const u8,
        out: []ChunkRef,
    ) node_store.ChunkError!u32 {
        const digest = Digest.parse(tree) orelse return error.NotFound;
        return from(context).list_chunks(digest, out);
    }

    fn read_chunk_impl(
        context: *anyopaque,
        hash: *const Hash,
        out: []u8,
    ) node_store.ChunkError![]u8 {
        const self = from(context);
        if (self.index.get(hash.*) == null and !self.walked) self.reindex();
        const place = self.index.get(hash.*) orelse return error.NotFound;
        const length = store_api.read_chunk(
            self.store,
            self.io,
            self.scratch,
            place.object,
            place.index,
            out,
        ) catch |err| switch (err) {
            error.NotFound, error.IndexOutOfRange => {
                _ = self.index.remove(hash.*); // A gc took it: the entry is stale.
                return error.NotFound;
            },
            error.Damaged => return error.BadHash,
            error.Unreadable => return error.StoreFailed,
        };
        // Zigbox hashed the chunk against its list or its object id; the seam's hash is the same
        // BLAKE3 of the same bytes, and a chunk that is not what the index said is not served.
        if (!node_store.chunk_verifies(hash, out[0..length])) return error.BadHash;
        return out[0..length];
    }

    /// Lists every root's tree, which puts its chunks in the index (best effort).
    fn reindex(self: *ZigboxImages) void {
        self.walked = true;
        self.walks += 1;
        var listing: [constants.summary_trees_max]store_api.roots.Root = undefined;
        var arena: [constants.zigbox_roots_arena_bytes]u8 = undefined;
        const found = store_api.roots.list(self.store, &arena, &listing) catch return;
        const refs = self.allocator.alloc(ChunkRef, constants.fetch_chunks_max) catch return;
        defer self.allocator.free(refs);
        for (listing[0..found.count]) |root| {
            _ = self.list_chunks(root.digest, refs) catch continue; // One bad tree is not all.
        }
    }

    fn summary_impl(
        context: *anyopaque,
        arena: Allocator,
        started: []const []const u8,
    ) node_store.Error!node_store.Summary {
        _ = started; // The store holds what it holds, run or not.
        const self = from(context);
        var listing: [constants.summary_trees_max]store_api.roots.Root = undefined;
        var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
        const found = store_api.roots.list(self.store, &names, &listing) catch return .{};
        const refs = try self.allocator.alloc(ChunkRef, constants.fetch_chunks_max);
        defer self.allocator.free(refs);
        var held: std.ArrayList(node_store.Held) = .empty;
        var all: std.ArrayList(Hash) = .empty;
        var omitted: u32 = 0;
        for (listing[0..found.count]) |root| {
            if (!self.holds_all(root.digest)) continue;
            const count = self.list_chunks(root.digest, refs) catch {
                omitted += 1; // Too many chunks for one summary, or it went away.
                continue;
            };
            if (all.items.len + count > constants.summary_chunks_capacity) {
                omitted += 1;
                continue;
            }
            const text = try arena.dupe(u8, &root.digest.text());
            var sketch = chunk_summary.Sketch.init(node_store.tree_hash(text));
            for (refs[0..count]) |ref| {
                sketch.add(&ref.hash, ref.bytes);
                try all.append(arena, ref.hash);
            }
            try held.append(arena, .{ .digest = text, .sketch = sketch });
        }
        if (all.items.len == 0) return .{ .omitted = omitted };
        const capacity: u32 = @intCast(all.items.len);
        const bits = try arena.alloc(u8, chunk_summary.Filter.bytes_for(@max(capacity, 64)));
        var filter = chunk_summary.Filter.init(bits);
        for (all.items) |*hash| filter.add(hash);
        return .{
            .trees = held.items,
            .omitted = omitted,
            .filter = bits,
            .filter_chunks = capacity,
        };
    }

    // ---- What a peer is sent -------------------------------------------------------------

    /// The record of tree `digest`, checked against its name as Zigbox loads it, into `out`.
    pub fn tree_record(self: *ZigboxImages, digest: Digest, out: []u8) ?[]const u8 {
        var errno: u16 = 0;
        return store_api.get_tree(self.store, digest, out, &errno) catch null;
    }

    /// What `begin_object` takes, for object `item.ref.id`: the attributes are its tree
    /// entry's (`Described`), the hashes (one per chunk) go into the adapter's own room, valid
    /// until the next call. Null if the store lacks the object or it cannot be read, or the
    /// entry's attributes do not make its id (a tree the store holds damaged).
    pub fn object_meta(self: *ZigboxImages, item: *const Described.Item) ?ObjectMeta {
        const attrs: store_api.object.Attrs = .{
            .mode = item.mode,
            .uid = item.uid,
            .gid = item.gid,
            .xattrs = item.xattrs,
        };
        if (item.mode > 0o7777) return null;
        if (store_api.xattrs.validate(item.xattrs) != .none) return null;
        if (!store_api.object.object_id(item.ref.content, attrs).eql(item.ref.id)) return null;
        const listed = store_api.chunks(self.store, item.ref.id, self.io, self.hashes) catch
            return null;
        return .{
            .id = item.ref.id,
            .mode = item.mode,
            .uid = item.uid,
            .gid = item.gid,
            .xattrs = item.xattrs,
            .size = item.ref.size,
            .content = item.ref.content,
            .hashes = listed,
        };
    }

    /// The image record of the newest image that became `tree`, into `out`.
    pub fn export_image(
        self: *ZigboxImages,
        tree: Digest,
        out: *[constants.zigbox_record_bytes_max]u8,
    ) ?[]const u8 {
        var failure: store_api.image_peer.Failure = undefined;
        return store_api.export_image(self.store, self.memory, tree, out, &failure) catch null;
    }

    // ---- The receiving half --------------------------------------------------------------

    /// Stores a tree record from a peer: held to its digest and encoding, or refused.
    pub fn put_tree_record(
        self: *ZigboxImages,
        digest: Digest,
        bytes: []const u8,
    ) ReceiveError!void {
        self.walked = false;
        var failure: store_api.object.Failure = undefined;
        _ = store_api.put_tree(self.store, digest, bytes, &failure) catch |err| switch (err) {
            error.TooLarge, error.DigestMismatch, error.Malformed => return error.BadHash,
            error.Busy => return error.Busy,
            error.StoreFailed => return error.StoreFailed,
        };
    }

    /// Claims object `meta.id`: the chunks `put_chunk` is given for its hashes go into it. The
    /// claim is refused (`BadHash`) when the id is not the one these attributes and this content
    /// make, or the hashes are not as many as the size needs: a peer cannot name an object it
    /// cannot prove.
    pub fn begin_object(self: *ZigboxImages, meta: ObjectMeta) ReceiveError!void {
        const attrs: store_api.object.Attrs = .{
            .mode = meta.mode,
            .uid = meta.uid,
            .gid = meta.gid,
            .xattrs = meta.xattrs,
        };
        self.walked = false;
        if (meta.mode > 0o7777) return error.BadHash;
        if (store_api.xattrs.validate(meta.xattrs) != .none) return error.BadHash;
        if (!store_api.object.object_id(meta.content, attrs).eql(meta.id)) return error.BadHash;
        const wanted_count = store_api.object.chunk_count(meta.size, self.store.chunk_bytes);
        if (meta.hashes.len != wanted_count) return error.BadHash;
        if (self.claims.items.len == constants.zigbox_claims_max) return error.TooMany;
        const xattrs = try self.allocator.dupe(u8, meta.xattrs);
        errdefer self.allocator.free(xattrs);
        const hashes = try self.allocator.dupe(Digest, meta.hashes);
        errdefer self.allocator.free(hashes);
        try self.claims.append(self.allocator, .{
            .wanted = .{
                .id = meta.id,
                .attrs = .{ .mode = meta.mode, .uid = meta.uid, .gid = meta.gid, .xattrs = xattrs },
                .size = meta.size,
                .content = meta.content,
                .hashes = hashes,
            },
            .xattrs = xattrs,
            .hashes = hashes,
            .complete = false,
        });
        const claim = &self.claims.items[self.claims.items.len - 1];
        try self.settle(claim);
    }

    /// Completes a claim no chunk will finish: an empty file, an object the store already holds
    /// (two images share files; `lacking` then never asks for its chunks), or one whose chunks
    /// an earlier fetch left in `partial/`.
    fn settle(self: *ZigboxImages, claim: *Claim) ReceiveError!void {
        var failure: store_api.chunk_put.Failure = undefined;
        const progress = store_api.chunk_put.finish(
            self.store,
            self.io,
            &claim.wanted,
            &failure,
        ) catch return error.StoreFailed;
        claim.complete = progress.complete;
        if (claim.wanted.size == 0) assert(claim.complete);
    }

    fn put_chunk_impl(
        context: *anyopaque,
        hash: *const Hash,
        bytes: []const u8,
    ) node_store.ChunkError!void {
        const self = from(context);
        if (!node_store.chunk_verifies(hash, bytes)) return error.BadHash;
        var used = false;
        for (self.claims.items) |*claim| {
            for (claim.hashes, 0..) |listed, at| {
                if (!std.mem.eql(u8, &listed.bytes, hash)) continue;
                used = true; // A complete claim lists it too: the object is there already.
                if (!claim.complete) try self.land(claim, @intCast(at), bytes);
            }
        }
        if (!used) return error.NotFound; // No object that was claimed lists this chunk.
    }

    fn land(
        self: *ZigboxImages,
        claim: *Claim,
        index: u32,
        bytes: []const u8,
    ) node_store.ChunkError!void {
        var failure: store_api.chunk_put.Failure = undefined;
        const progress = store_api.put_chunk(
            self.store,
            self.io,
            &claim.wanted,
            index,
            bytes,
            &failure,
        ) catch |err| switch (err) {
            error.StoreFailed, error.Busy => return error.StoreFailed,
            else => return error.BadHash,
        };
        if (progress.complete) claim.complete = true;
    }

    /// Whether every claimed object is in the store.
    pub fn claims_complete(self: *const ZigboxImages) bool {
        for (self.claims.items) |claim| {
            if (!claim.complete) return false;
        }
        return true;
    }

    fn clear_claims(self: *ZigboxImages) void {
        for (self.claims.items) |claim| {
            self.allocator.free(claim.xattrs);
            self.allocator.free(claim.hashes);
        }
        self.claims.clearRetainingCapacity();
    }

    /// Forgets the claims (a fetch's end).
    pub fn end_claims(self: *ZigboxImages) void {
        self.walked = false;
        self.clear_claims();
    }

    /// Takes the image record `text` a peer sent for `tree`, which must be whole in the store.
    /// `expected_manifest` is the manifest of the assignment's digest-pinned image reference:
    /// never read from `text`. A record for another manifest is refused (`refusal` says why)
    /// and nothing is written. Tags are dropped: a tag names a thing on this node.
    pub fn import_image(
        self: *ZigboxImages,
        text: []const u8,
        tree: Digest,
        expected_manifest: Sha256,
    ) ImportError!store_api.image_peer.Imported {
        const options: store_api.image_peer.Options = .{
            .expected_manifest = expected_manifest,
            .tags = .drop,
            .entries_max = entries_max,
        };
        var failure: store_api.image_peer.Failure = undefined;
        self.walked = false;
        self.refusal = null;
        const store = self.store;
        return store_api.import_image(store, self.memory, text, tree, options, &failure) catch {
            self.refusal = failure.refusal;
            return if (failure.refusal == .store_failed or failure.refusal == .busy)
                error.StoreFailed
            else
                error.Refused;
        };
    }
};

/// The bytes of chunk `index` of an object of `size` bytes in chunks of `chunk_bytes`.
pub fn chunk_length(size: u64, chunk_bytes: u32, index: u32) u32 {
    const start = @as(u64, index) * chunk_bytes;
    assert(start < size);
    return @intCast(@min(@as(u64, chunk_bytes), size - start));
}

// ---- Tests ------------------------------------------------------------------------------------

const testing = std.testing;
const HostReal = zigbox.host_real.HostReal;

/// 64 hex digits of one repeated byte.
fn hex_of(comptime byte: *const [2]u8) [64]u8 {
    var text: [64]u8 = undefined;
    for (0..32) |at| @memcpy(text[at * 2 ..][0..2], byte);
    return text;
}

pub const manifest_text = "sha256:" ++ hex_of("ab");
pub const other_manifest_text = "sha256:" ++ hex_of("cd");

/// Two real stores in a scratch directory, `a` with a tree and `b` empty, chunks of 8 bytes.
pub const Pair = struct {
    host: HostReal = .{},
    a: Store,
    b: Store,
    tree: Digest,
    workspace: *store_api.import.Workspace,

    fn base_of(tmp: *testing.TmpDir, out: []u8) ![]const u8 {
        var cwd_buffer: [512]u8 = undefined;
        const cwd_len = try std.process.currentPath(testing.io, &cwd_buffer);
        return std.fmt.bufPrint(out, "{s}/.zig-cache/tmp/{s}", .{
            cwd_buffer[0..cwd_len], tmp.sub_path,
        });
    }

    /// Imports into `a` a second tree: the first one's files plus `src2/etc/extra`, so the two
    /// trees share every chunk but the new file's.
    pub fn add_tree(pair: *Pair, tmp: *testing.TmpDir) !Digest {
        var root_buffer: [768]u8 = undefined;
        const base = try base_of(tmp, &root_buffer);
        try tmp.dir.createDir(testing.io, "src2", .default_dir);
        try tmp.dir.createDir(testing.io, "src2/etc", .default_dir);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src2/hello", .data = "hello, world" });
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "src2/etc/long",
            .data = "0123456789abcdefghijklmnopqrstuvwxyz",
        });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src2/etc/copy", .data = "hello, world" });
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "src2/etc/extra",
            .data = "a file only the second image has",
        });
        var path: [800]u8 = undefined;
        const source = try std.fmt.bufPrint(&path, "{s}/src2", .{base});
        var result: store_api.import.Result = undefined;
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        store_api.import.import(&pair.a, pair.workspace, source, .{
            .squash_owner = false,
            .warn = null,
        }, &result, &diag) catch return error.ImportFailed;
        return result.digest;
    }

    pub fn make(pair: *Pair, tmp: *testing.TmpDir) !void {
        var root_buffer: [768]u8 = undefined;
        const base = try base_of(tmp, &root_buffer);
        try tmp.dir.createDir(testing.io, "src", .default_dir);
        try tmp.dir.createDir(testing.io, "src/etc", .default_dir);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/hello", .data = "hello, world" });
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "src/etc/long",
            .data = "0123456789abcdefghijklmnopqrstuvwxyz",
        });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/etc/copy", .data = "hello, world" });
        try tmp.dir.createDir(testing.io, "a", .default_dir);
        try tmp.dir.createDir(testing.io, "b", .default_dir);
        pair.host = .{};
        const interface = pair.host.interface();
        var path: [800]u8 = undefined;
        inline for (.{ "a", "b" }) |name| {
            const root = try std.fmt.bufPrint(&path, "{s}/{s}/store", .{ base, name });
            const store = if (comptime std.mem.eql(u8, name, "a")) &pair.a else &pair.b;
            store.at(interface, root);
            store.chunk_bytes = 8;
            var diag: zigbox.diag.Diag = undefined;
            diag.reset();
            const opened = store_api.open.check(store, .create, &diag) catch
                return error.StoreFailed;
            try testing.expect(opened);
        }
        pair.workspace = try testing.allocator.create(store_api.import.Workspace);
        var result: store_api.import.Result = undefined;
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        const source = try std.fmt.bufPrint(&path, "{s}/src", .{base});
        store_api.import.import(&pair.a, pair.workspace, source, .{
            .squash_owner = false,
            .warn = null,
        }, &result, &diag) catch return error.ImportFailed;
        pair.tree = result.digest;
        // The tree is a fetched one: no root of its own on the receiving side, and none needed
        // on this side after the import.
    }

    pub fn deinit(pair: *Pair) void {
        testing.allocator.destroy(pair.workspace);
    }
};

/// Copies the tree from `source` to `target` the way a fetch worker does: the tree record, one
/// claim per object, every chunk once (the hash-keyed seam).
fn replicate(source: *ZigboxImages, target: *ZigboxImages, tree: Digest) !void {
    const record = try testing.allocator.alloc(u8, constants.zigbox_tree_buffer_bytes);
    defer testing.allocator.free(record);
    const digests = source.tree_digests(tree).?;
    defer testing.allocator.free(digests);
    for (digests) |digest| try target.put_tree_record(digest, source.tree_record(digest, record).?);
    var found = source.describe(tree).?;
    defer found.deinit();
    for (found.items.items) |*item| try target.begin_object(source.object_meta(item).?);
    const seam = target.images();
    const chunk = try testing.allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer testing.allocator.free(chunk);
    var text: [67]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{s}", .{&tree.text()});
    var refs: [64]ChunkRef = undefined;
    const count = try source.images().chunk_list(&text, &refs);
    for (refs[0..count]) |entry| {
        const body = try source.images().read_chunk(&entry.hash, chunk);
        try seam.put_chunk(&entry.hash, body);
    }
}

test "a tree is copied between two real Zigbox stores through the seam, every chunk verified" {
    // Goal: the adapter serves a tree's chunk list and chunks from a real Zigbox store and
    // another adapter rebuilds the same objects from them. Method: import a tree into store A,
    // replicate to an empty store B, check `has` and the object ids on both sides.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    const text = pair.tree.text();
    try testing.expect(from_a.images().has(&text));
    try testing.expect(!to_b.images().has(&text));
    try replicate(&from_a, &to_b, pair.tree);
    try testing.expect(to_b.claims_complete());
    try testing.expect(to_b.images().has(&text));
    to_b.end_claims();
    // The duplicate content ("hello, world" twice) is one object and one chunk list entry set:
    // the list has no repeated hash.
    var refs: [64]ChunkRef = undefined;
    const count = try from_a.images().chunk_list(&text, &refs);
    for (refs[0..count], 0..) |first, index| {
        for (refs[index + 1 .. count]) |second| {
            try testing.expect(!std.mem.eql(u8, &first.hash, &second.hash));
        }
    }
}

test "a chunk with the wrong bytes under its hash is refused and nothing lands" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    const record = try testing.allocator.alloc(u8, constants.zigbox_tree_buffer_bytes);
    defer testing.allocator.free(record);
    try to_b.put_tree_record(pair.tree, from_a.tree_record(pair.tree, record).?);
    var found = from_a.describe(pair.tree).?;
    defer found.deinit();
    for (found.items.items) |*item| try to_b.begin_object(from_a.object_meta(item).?);
    var text: [67]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{s}", .{&pair.tree.text()});
    var refs: [64]ChunkRef = undefined;
    _ = try from_a.images().chunk_list(&text, &refs);
    try testing.expectError(error.BadHash, to_b.images().put_chunk(&refs[0].hash, "rotten!!"));
    try testing.expect(!to_b.claims_complete());
    try testing.expect(!to_b.images().has(&text));
}

test "an object is described by its tree entry, not by the file's owner on the host" {
    // Goal: M3. A peer server runs outside Zigbox's store namespace, where an object a mapped
    // write left owned by container id 1000 reads as a host id of the subordinate range; what it
    // sends must still make the object's id. Method: change the owner of every object file in A
    // (as root; skipped otherwise) and replicate A into B: every claim must still be accepted.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var found = from_a.describe(pair.tree).?;
    defer found.deinit();
    try testing.expect(found.items.items.len >= 2);
    for (found.items.items) |*item| {
        var path: store_api.fs.PathBuf = undefined;
        const text = pair.a.object_path(&path, item.ref.id);
        const rc = std.os.linux.fchownat(std.os.linux.AT.FDCWD, text, 200999, 200999, 0);
        if (std.os.linux.errno(rc) == .PERM) return error.SkipZigTest; // Not root.
        try testing.expectEqual(.SUCCESS, std.os.linux.errno(rc));
    }
    try replicate(&from_a, &to_b, pair.tree);
    try testing.expect(to_b.claims_complete());
}

test "an object claim whose id its attributes do not make is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var found = from_a.describe(pair.tree).?;
    defer found.deinit();
    var meta = from_a.object_meta(&found.items.items[0]).?;
    meta.mode ^= 0o111; // A peer that changes the mode of an object it cannot prove.
    try testing.expectError(error.BadHash, to_b.begin_object(meta));
    try testing.expectEqual(@as(usize, 0), to_b.claims.items.len);
}

pub fn record_text(buffer: []u8, tree: Digest, manifest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\.{{
        \\    .version = 2,
        \\    .manifest = "{s}",
        \\    .platform = "linux/amd64",
        \\    .config = "sha256:{s}",
        \\    .tree = "{s}",
        \\    .time = 5,
        \\    .layers = "sha256:{s}",
        \\}}
        \\
    , .{ manifest, &hex_of("11"), &tree.text(), &hex_of("22") });
}

test "the image record is imported only for the manifest the assignment names" {
    // Goal: the owner rule. A peer cannot choose the manifest: `expected_manifest` comes from
    // the assignment's digest-pinned image. Method: a whole tree in B, a record for another
    // manifest is refused with nothing written, the right one lands and roots the tree.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    try replicate(&from_a, &to_b, pair.tree);
    var buffer: [2048]u8 = undefined;
    const wrong = try record_text(&buffer, pair.tree, other_manifest_text);
    const expected = Sha256.parse(manifest_text).?;
    try testing.expectError(error.Refused, to_b.import_image(wrong, pair.tree, expected));
    try testing.expect(to_b.refusal != null);
    var listing: [8]store_api.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = try store_api.roots.list(&pair.b, &names, &listing);
    try testing.expectEqual(@as(usize, 0), rooted.count);
    var again: [2048]u8 = undefined;
    const right = try record_text(&again, pair.tree, manifest_text);
    const done = try to_b.import_image(right, pair.tree, expected);
    try testing.expect(done.created);
    try testing.expect(done.tree.eql(pair.tree));
}

test "the image record of a tree that is not whole is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var buffer: [2048]u8 = undefined;
    const text = try record_text(&buffer, pair.tree, manifest_text);
    const expected = Sha256.parse(manifest_text).?;
    try testing.expectError(error.Refused, to_b.import_image(text, pair.tree, expected));
}

test "unknown chunk hashes cost one walk of the roots, not one each" {
    // Goal: a peer that asks for many hashes the store lacks cannot make the agent list every
    // root once per hash. Method: a fresh adapter (empty index) over a store with an image;
    // ask for 20 unknown hashes, count walks; the first known hash is then served from the
    // index that walk built; a write to the store lets the next miss walk again.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: Pair = undefined;
    try pair.make(&tmp);
    defer pair.deinit();
    var adapter = try ZigboxImages.open(testing.allocator, &pair.a);
    defer adapter.close();
    const seam = adapter.images();
    const chunk = try testing.allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer testing.allocator.free(chunk);
    var unknown: Hash = @splat(0);
    for (0..20) |n| {
        unknown[0] = @intCast(n + 1);
        try testing.expectError(error.NotFound, seam.read_chunk(&unknown, chunk));
    }
    try testing.expectEqual(@as(u32, 1), adapter.walks);
    var text: [67]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{s}", .{&pair.tree.text()});
    var refs: [64]ChunkRef = undefined;
    const count = try seam.chunk_list(&text, &refs);
    try testing.expect(count > 0);
    _ = try seam.read_chunk(&refs[0].hash, chunk);
    try testing.expectEqual(@as(u32, 1), adapter.walks);
    adapter.end_claims(); // Something may have been written: the next miss may walk.
    try testing.expectError(error.NotFound, seam.read_chunk(&unknown, chunk));
    try testing.expectEqual(@as(u32, 2), adapter.walks);
}
