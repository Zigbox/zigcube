//! The fetch worker over a real Zigbox store (C2 slice 8). Shell code: files, via `ZigboxImages`.
//!
//! A peer sends a tree as a *bundle* (`encode`, `GET /v1/peer/bundle/<digest>`): every tree
//! record, a description of every object (the attributes its id commits to and its chunk hashes)
//! and the image record. The receiver holds each part to what it can check:
//!
//! * a tree record to its own digest, and the first one to the digest asked for; only the
//!   records that tree reaches are kept;
//! * the objects to the tree: exactly the distinct objects its records name, each once, with
//!   the size and content its entries give (so a peer can neither add chunks nor leave an
//!   object out, and no size from the wire reaches an assert);
//! * an object to its id (`begin_object` refuses attributes that do not make the id);
//! * every chunk to its hash (`put_chunk`, through `fetch_worker.run_plan` and the plan's own
//!   check), and Zigbox to the object's content hash when the last chunk lands;
//! * the image record to the manifest of the assignment's digest-pinned image, which the caller
//!   passes in and the peer never names (`import_image`).
//!
//! A bundle that fails any of these is a bad list (ZC-W0602) and the next peer is tried, except
//! a record for another manifest: a peer exports the newest image of a tree, so that is an
//! honest peer's answer, counted and not struck. A tree larger than this node takes in one fetch
//! is `TooLarge`, a limit of ours. The tree records of a rejected bundle may already be in the
//! store: they stay unrooted until gc. A peer is trusted only against the full tree digest:
//! `Digest` has no short form.
//!
//! Wire format, little-endian: `ZCB1`; u32 trees, each digest[32] u32 length bytes; u32 objects,
//! each id[32] u16 mode u32 uid u32 gid u64 size content[32] u32 length xattrs u32 hashes
//! hash[32]...; u32 length of the image record, and its bytes.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const fetch_plan = @import("fetch_plan.zig");
const fetch_worker = @import("fetch_worker.zig");
const images_mod = @import("zigbox_images.zig");
const node_store = @import("node_store.zig");

const Allocator = std.mem.Allocator;
const ChunkRef = fetch_plan.ChunkRef;
const Digest = zigbox.store.Digest;
const Hash = chunk_summary.Hash;
const Sha256 = @FieldType(zigbox.store.image_peer.Options, "expected_manifest");
const ZigboxImages = images_mod.ZigboxImages;

pub const magic = "ZCB1";

/// The most a bundle may hold. Eight tree records of a megabyte are far more than an image has.
pub const bundle_bytes_max: usize = 64 << 20;

pub const Error = error{
    TreeUnavailable,
    ChunkFailed,
    Deadline,
    Store,
    OutOfMemory,
    Refused,
    TooLarge,
};

/// Builds the bundle of `tree` into `out`; null if the tree is not whole here, has no image record
/// (a tree no image rooted is not worth fetching: it would be collected) or does not fit.
pub fn encode(
    allocator: Allocator,
    images: *ZigboxImages,
    tree: Digest,
    out: []u8,
) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    writer.writeAll(magic) catch return null;
    const digests = images.tree_digests(tree) orelse return null;
    defer allocator.free(digests);
    const record = allocator.alloc(u8, constants.zigbox_tree_buffer_bytes) catch return null;
    defer allocator.free(record);
    writer.writeInt(u32, @intCast(digests.len), .little) catch return null;
    for (digests) |digest| {
        const bytes = images.tree_record(digest, record) orelse return null;
        writer.writeAll(&digest.bytes) catch return null;
        writer.writeInt(u32, @intCast(bytes.len), .little) catch return null;
        writer.writeAll(bytes) catch return null;
    }
    write_objects(images, tree, &writer) orelse return null;
    const image = allocator.create([constants.zigbox_record_bytes_max]u8) catch return null;
    defer allocator.destroy(image);
    const text = images.export_image(tree, image) orelse return null;
    writer.writeInt(u32, @intCast(text.len), .little) catch return null;
    writer.writeAll(text) catch return null;
    return writer.buffered();
}

fn write_objects(
    images: *ZigboxImages,
    tree: Digest,
    writer: *std.Io.Writer,
) ?void {
    var found = images.describe(tree) orelse return null;
    defer found.deinit();
    writer.writeInt(u32, @intCast(found.items.items.len), .little) catch return null;
    for (found.items.items) |*item| {
        const meta = images.object_meta(item) orelse return null;
        writer.writeAll(&meta.id.bytes) catch return null;
        writer.writeInt(u16, meta.mode, .little) catch return null;
        writer.writeInt(u32, meta.uid, .little) catch return null;
        writer.writeInt(u32, meta.gid, .little) catch return null;
        writer.writeInt(u64, meta.size, .little) catch return null;
        writer.writeAll(&meta.content.bytes) catch return null;
        writer.writeInt(u32, @intCast(meta.xattrs.len), .little) catch return null;
        writer.writeAll(meta.xattrs) catch return null;
        writer.writeInt(u32, @intCast(meta.hashes.len), .little) catch return null;
        for (meta.hashes) |hash| writer.writeAll(&hash.bytes) catch return null;
    }
}

/// A cursor over a bundle's bytes; every read is bounds-checked and a short bundle is `null`.
const Cursor = struct {
    bytes: []const u8,
    at: u32 = 0,

    fn take(cursor: *Cursor, count: u32) ?[]const u8 {
        assert(cursor.at <= cursor.bytes.len);
        if (count > cursor.bytes.len - cursor.at) return null;
        defer cursor.at += count;
        return cursor.bytes[cursor.at..][0..count];
    }

    fn int(cursor: *Cursor, comptime T: type) ?T {
        const raw = cursor.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn digest(cursor: *Cursor) ?Digest {
        const raw = cursor.take(32) orelse return null;
        return .{ .bytes = raw[0..32].* };
    }
};

/// What a received bundle gave: the chunks to fetch (hash and length, each hash once), the
/// image record, which borrows the bundle, and the place of the peer that sent it.
pub const Received = struct {
    chunks: []ChunkRef,
    record: []const u8,
    peer: u8 = 0,
};

/// Applies `bytes` to `images`: stores the tree records, claims the objects and lists the chunks
/// they need. `BadBundle` is anything the bundle got wrong, whoever's fault; `OtherImage` a
/// bundle that holds up whose image record is for another manifest (an honest peer that ran
/// another image of the same tree: Zigbox exports the newest); `TooLarge` a tree larger than
/// this node takes in one fetch (a limit of ours, no peer's fault).
pub const ReceiveError = error{ BadBundle, OtherImage, TooLarge, Store, OutOfMemory };

pub fn receive(
    allocator: Allocator,
    images: *ZigboxImages,
    tree: Digest,
    expected_manifest: Sha256,
    bytes: []const u8,
) ReceiveError!Received {
    var cursor: Cursor = .{ .bytes = bytes };
    const head = cursor.take(magic.len) orelse return error.BadBundle;
    if (!std.mem.eql(u8, head, magic)) return error.BadBundle;
    try receive_trees(allocator, images, tree, &cursor);
    // The objects the tree itself names, from the records just checked against their digests:
    // the bundle's objects must be exactly these, so a peer can neither invent objects (and
    // chunks) nor leave one out.
    var named = images.collect_checked(tree) catch |err| return switch (err) {
        error.Incomplete => error.BadBundle,
        error.TooLarge => error.TooLarge,
        error.StoreFailed => error.Store,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer named.deinit();
    if (named.list.items.len > images.claims_max) return error.TooLarge;
    const chunks = try receive_objects(allocator, images, &cursor, named.list.items);
    errdefer allocator.free(chunks);
    const length = cursor.int(u32) orelse return error.BadBundle;
    const record = cursor.take(length) orelse return error.BadBundle;
    if (cursor.at != bytes.len or record.len == 0) return error.BadBundle;
    // Checked now, not after every chunk is fetched: the next peer is tried. Not a strike: an
    // honest peer sends the newest image of the tree, which may be another manifest's.
    // `import_image` still decides at the end.
    if (!record_names(record, expected_manifest)) return error.OtherImage;
    return .{ .chunks = chunks, .record = record };
}

/// Whether the image record `record` names `manifest`: Zigbox writes the line
/// `    .manifest = "sha256:HEX",` (`images.zig`), and a bundle's record comes from `export_image`.
/// The pinned Zigbox exposes no parser of a record (`store/images.zig` is not exported), so
/// this is a text match; `import_image` parses the record and is what decides.
fn record_names(record: []const u8, manifest: Sha256) bool {
    var needle: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&needle, "\n    .manifest = \"{s}\",\n", .{
        &manifest.text(),
    }) catch unreachable; // The line is 92 bytes.
    return std.mem.indexOf(u8, record, line) != null;
}

/// Stores the bundle's tree records that `tree` reaches, `tree` first; a record it does not
/// reach is ignored. Each is held to its digest (`put_tree_record`).
fn receive_trees(
    allocator: Allocator,
    images: *ZigboxImages,
    tree: Digest,
    cursor: *Cursor,
) ReceiveError!void {
    const count = cursor.int(u32) orelse return error.BadBundle;
    if (count == 0 or count > images_mod.entries_max) return error.BadBundle;
    var sent: std.AutoHashMapUnmanaged(Hash, []const u8) = .empty;
    defer sent.deinit(allocator);
    for (0..count) |at| {
        const digest = cursor.digest() orelse return error.BadBundle;
        if (at == 0 and !digest.eql(tree)) return error.BadBundle;
        const length = cursor.int(u32) orelse return error.BadBundle;
        const record = cursor.take(length) orelse return error.BadBundle;
        try sent.put(allocator, digest.bytes, record);
    }
    var pending: std.ArrayList(Digest) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, tree);
    // Each record is stored and decoded once (`fetchRemove`), so the work is bounded by the
    // bundle. A subtree the bundle lacks is left to `collect_checked`, which finds it missing
    // unless this store holds it.
    while (pending.pop()) |digest| {
        const found = sent.fetchRemove(digest.bytes) orelse continue;
        images.put_tree_record(digest, found.value) catch |err| return switch (err) {
            error.BadHash => error.BadBundle,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Store,
        };
        var decoder: zigbox.store.tree.Decoder = undefined;
        decoder.init(found.value) catch return error.BadBundle;
        var entry: zigbox.store.tree.Entry = undefined;
        while (decoder.next(&entry) catch return error.BadBundle) {
            if (entry.kind == .dir) try pending.append(allocator, entry.subtree);
        }
    }
}

/// Claims the bundle's objects, which must be `named` (the tree's own), each once, and lists
/// their chunks.
fn receive_objects(
    allocator: Allocator,
    images: *ZigboxImages,
    cursor: *Cursor,
    named: []const zigbox.store.walk.ObjectRef,
) ReceiveError![]ChunkRef {
    const count = cursor.int(u32) orelse return error.BadBundle;
    if (count != named.len) return error.BadBundle;
    var wanted: std.AutoHashMapUnmanaged(Hash, zigbox.store.walk.ObjectRef) = .empty;
    defer wanted.deinit(allocator);
    for (named) |ref| try wanted.put(allocator, ref.id.bytes, ref);
    var listed: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    defer listed.deinit(allocator);
    var chunks: std.ArrayList(ChunkRef) = .empty;
    errdefer chunks.deinit(allocator);
    const hashes = try allocator.alloc(Digest, constants.zigbox_chunks_per_object_max);
    defer allocator.free(hashes);
    for (0..count) |_| {
        const meta = try read_meta(cursor, &wanted, hashes, images.store.chunk_bytes);
        images.begin_object(meta) catch |err| return switch (err) {
            error.BadHash => error.BadBundle,
            error.TooMany => error.TooLarge,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Store,
        };
        for (meta.hashes, 0..) |hash, index| {
            const fresh = try listed.getOrPut(allocator, hash.bytes);
            if (fresh.found_existing) continue;
            const bytes = images.store.chunk_bytes;
            const size = images_mod.chunk_length(meta.size, bytes, @intCast(index));
            try chunks.append(allocator, .{ .hash = hash.bytes, .bytes = size });
        }
        // The objects are the tree's and their sizes its entries', so this is the tree's own
        // size: a limit of this node's, never one a peer's lie reaches.
        if (chunks.items.len > constants.fetch_chunks_max) return error.TooLarge;
    }
    assert(wanted.count() == 0); // As many objects as named, each taken out once.
    return chunks.toOwnedSlice(allocator);
}

/// One object of the bundle, which must be one of `wanted` (taken out of it: each once) with
/// the size and content the tree's entry records, and with one hash per chunk.
fn read_meta(
    cursor: *Cursor,
    wanted: *std.AutoHashMapUnmanaged(Hash, zigbox.store.walk.ObjectRef),
    hashes: []Digest,
    chunk_bytes: u32,
) ReceiveError!images_mod.ObjectMeta {
    const id = cursor.digest() orelse return error.BadBundle;
    const mode = cursor.int(u16) orelse return error.BadBundle;
    const uid = cursor.int(u32) orelse return error.BadBundle;
    const gid = cursor.int(u32) orelse return error.BadBundle;
    const size = cursor.int(u64) orelse return error.BadBundle;
    const content = cursor.digest() orelse return error.BadBundle;
    const xattr_length = cursor.int(u32) orelse return error.BadBundle;
    const xattrs = cursor.take(xattr_length) orelse return error.BadBundle;
    const count = cursor.int(u32) orelse return error.BadBundle;
    const ref = (wanted.fetchRemove(id.bytes) orelse return error.BadBundle).value;
    if (ref.size != size or !ref.content.eql(content)) return error.BadBundle;
    assert(ref.chunk_count == zigbox.store.object.chunk_count(size, chunk_bytes));
    if (count != ref.chunk_count) return error.BadBundle;
    if (count > hashes.len) return error.TooLarge; // The tree's own object: our limit.
    for (hashes[0..count]) |*slot| slot.* = cursor.digest() orelse return error.BadBundle;
    return .{
        .id = id,
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .xattrs = xattrs,
        .size = size,
        .content = content,
        .hashes = hashes[0..count],
    };
}

/// What a fetch did.
pub const Report = struct {
    chunks: u32 = 0,
    already_held: u32 = 0,
    peer_chunks: u32 = 0,
    bad_bundles: u32 = 0,
    blamed: u32 = 0,
    /// Bytes by source, for `/pulls` (C2 slice 8, Z5): what each peer gave (by the place in the
    /// caller's list), what the store already held. A tree held whole is left alone, so its
    /// bytes are not counted. All figures are store chunk bytes (uncompressed); a registry
    /// pull's `cached_bytes` is compressed blob bytes (`pull_report.zig`).
    peer_bytes: [constants.fetch_candidates_max]u64 = @splat(0),
    cached_bytes: u64 = 0,
    /// Bit `i` is set for a peer that sent a bundle or a chunk that failed its hash.
    struck_peers: u64 = 0,
    /// Peers whose bundle held up but whose image record was for another manifest (not struck).
    other_images: u32 = 0,
};

/// Gets `tree` into `images` from `peers`, importing its image record only for
/// `expected_manifest`. A tree already whole here with that manifest's record is imported again
/// from this store's own record, and nothing is asked of a peer.
/// `TreeUnavailable` means no peer gave a bundle that held up for this manifest (the caller's
/// fallback is the registry's `pull`); `TooLarge` that the tree is larger than a peer fetch
/// takes here; `ChunkFailed` that the chunks could not all be had from the peers; `Refused`
/// that Zigbox refused the record (`images.refusal` says why).
pub fn fetch(
    allocator: Allocator,
    transport: fetch_worker.Transport,
    images: *ZigboxImages,
    tree: Digest,
    expected_manifest: Sha256,
    peers: []const fetch_worker.PeerInfo,
    config: fetch_plan.Config,
    report: *Report,
) Error!void {
    assert(peers.len <= constants.fetch_candidates_max);
    report.* = .{};
    if (try imported_here(images, tree, expected_manifest)) return;
    const deadline = transport.now_fn(transport.context) + config.total_ms;
    const buffer = try allocator.alloc(u8, bundle_bytes_max);
    defer allocator.free(buffer);
    defer images.end_claims();
    const got = try find_bundle(
        allocator,
        transport,
        images,
        tree,
        expected_manifest,
        peers,
        buffer,
        report,
    );
    defer allocator.free(got.chunks);
    report.chunks = @intCast(got.chunks.len);
    const args = .{ allocator, transport, images, got.chunks, peers, config, deadline, report };
    @call(.auto, fetch_chunks, args) catch |err| {
        transport.phase_fn(transport.context, .chunks_failed, 0, 0, @errorName(err));
        return err;
    };
    transport.phase_fn(transport.context, .chunks_done, 0, 0, "");
    if (!images.claims_complete()) {
        transport.phase_fn(transport.context, .chunks_missing, 0, 0, "");
        return error.ChunkFailed;
    }
    _ = images.import_image(got.record, tree, expected_manifest) catch |err| switch (err) {
        error.StoreFailed => {
            transport.phase_fn(transport.context, .import_failed, 0, 0, "StoreFailed");
            return error.Store;
        },
        error.Refused => {
            transport.phase_fn(transport.context, .import_failed, 0, 0, @tagName(images.refusal.?));
            // A record that is not one, or names another tree, is the peer's wrong bytes.
            if (record_fault(images.refusal.?)) {
                report.bad_bundles += 1;
                report.struck_peers |= @as(u64, 1) << @intCast(got.peer);
                transport.bad_list_fn(transport.context, got.peer);
            }
            return error.Refused;
        },
    };
    transport.phase_fn(transport.context, .imported, 0, 0, "");
}

/// Whether a refusal of a peer's record is that record's own fault, not this store's.
fn record_fault(refusal: zigbox.store.image_peer.Refusal) bool {
    return switch (refusal) {
        .too_large, .malformed, .wrong_tree, .wrong_manifest => true,
        else => false,
    };
}

/// Whether `tree` is whole here and this store already holds its image record for
/// `expected_manifest`; if so, that record is imported again (idempotent, and checked whole by
/// Zigbox: a record of this manifest for another tree is refused). A tree whole here under
/// other manifests' records only is fetched as any other: the peer's bundle brings the record,
/// and its objects are found held.
fn imported_here(images: *ZigboxImages, tree: Digest, expected_manifest: Sha256) Error!bool {
    const text = tree.text();
    if (!images.images().has(&text)) return false;
    const own = try images.allocator.create([constants.zigbox_record_bytes_max]u8);
    defer images.allocator.destroy(own);
    const record = images.own_record(expected_manifest, own) orelse return false;
    _ = images.import_image(record, tree, expected_manifest) catch |err| return switch (err) {
        error.StoreFailed => error.Store,
        error.Refused => error.Refused,
    };
    return true;
}

/// The first peer's bundle that `receive` accepts. A peer whose bundle fails is counted and told
/// to the transport (ZC-W0602); one whose record is for another manifest is counted in
/// `other_images` and not struck. The claims a bundle made are dropped before the next is tried.
fn find_bundle(
    allocator: Allocator,
    transport: fetch_worker.Transport,
    images: *ZigboxImages,
    tree: Digest,
    expected_manifest: Sha256,
    peers: []const fetch_worker.PeerInfo,
    buffer: []u8,
    report: *Report,
) Error!Received {
    const text = tree.text();
    const asked = @min(peers.len, constants.fetch_list_peers_max);
    for (0..asked) |index| {
        const source: fetch_plan.Source = .{ .peer = @intCast(index) };
        const bytes = transport.bundle_fn(transport.context, source, &text, buffer) orelse continue;
        if (receive(allocator, images, tree, expected_manifest, bytes)) |got| {
            var taken = got;
            taken.peer = @intCast(index);
            return taken;
        } else |err| {
            images.end_claims();
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Store => return error.Store,
                error.TooLarge => return error.TooLarge, // No peer can help: the tree is ours.
                error.OtherImage => report.other_images += 1,
                error.BadBundle => {
                    report.bad_bundles += 1;
                    report.struck_peers |= @as(u64, 1) << @intCast(index);
                    transport.bad_list_fn(transport.context, @intCast(index));
                },
            }
        }
    }
    return error.TreeUnavailable;
}

fn fetch_chunks(
    allocator: Allocator,
    transport: fetch_worker.Transport,
    images: *ZigboxImages,
    chunks: []ChunkRef,
    peers: []const fetch_worker.PeerInfo,
    config: fetch_plan.Config,
    deadline: u64,
    report: *Report,
) Error!void {
    const scratch = try allocator.alloc(u8, constants.swarm_chunk_bytes);
    defer allocator.free(scratch);
    var inner: fetch_worker.Report = .{};
    const seam = images.images();
    const needed = fetch_worker.lacking(seam, chunks, scratch, &inner) catch
        return error.OutOfMemory;
    report.already_held = inner.already_held;
    report.cached_bytes = inner.cached_bytes;
    transport.phase_fn(transport.context, .bundle_found, @intCast(chunks.len), needed, "");
    if (needed == 0) return;
    const states = try allocator.alloc(fetch_plan.ChunkState, needed);
    defer allocator.free(states);
    const ranked = fetch_worker.rank_peers(peers, chunks[0..needed]);
    const run: fetch_worker.Run = .{ .deadline = deadline, .config = config, .ranked = ranked };
    const done = fetch_worker.run_plan(
        transport,
        seam,
        chunks[0..needed],
        states,
        peers,
        &run,
        scratch,
        &inner,
    );
    report.peer_chunks = inner.peer_chunks;
    report.blamed = inner.blamed;
    report.peer_bytes = inner.peer_bytes;
    report.struck_peers |= inner.struck_peers;
    done catch |err| return switch (err) {
        error.Deadline => error.Deadline,
        error.Store => error.Store,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ChunkFailed,
    };
}

/// The seam a peer server answers from: `images` plus the bundle of a whole tree.
pub fn serving(images: *ZigboxImages) node_store.Images {
    var seam = images.images();
    seam.bundle_fn = serve_bundle;
    return seam;
}

fn serve_bundle(context: *anyopaque, tree: []const u8, out: []u8) ?[]const u8 {
    const images: *ZigboxImages = @ptrCast(@alignCast(context));
    const digest = Digest.parse(tree) orelse return null;
    return encode(images.allocator, images, digest, out);
}

/// A Zigbox store at an absolute path, opened for an existing store, with its `ZigboxImages`.
/// One thread's: a server opens one per serving slot.
pub const Opened = struct {
    host: zigbox.host_real.HostReal = .{},
    store: zigbox.store.Store = undefined,
    images: ZigboxImages = undefined,
    /// Set before `open` to open a store made with another chunk size than Zigbox's own (tests
    /// only: the size is not recorded in the store); 0 keeps Zigbox's.
    chunk_bytes: u32 = 0,

    pub const OpenError = error{ NoStore, OutOfMemory };

    /// `self` must stay where it is until `close`.
    pub fn open(self: *Opened, allocator: Allocator, root: []const u8) OpenError!void {
        if (root.len < 2 or root[0] != '/' or root.len >= self.store.root.len) return error.NoStore;
        self.host = .{};
        self.store.at(self.host.interface(), root);
        if (self.chunk_bytes != 0) self.store.chunk_bytes = self.chunk_bytes;
        var diag: zigbox.diag.Diag = undefined;
        diag.reset();
        const present = zigbox.store.open.check(&self.store, .existing, &diag) catch
            return error.NoStore;
        if (!present) return error.NoStore;
        self.images = ZigboxImages.open(allocator, &self.store) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unusable => error.NoStore,
        };
    }

    /// Makes this store read as the host sees it, for a reader that is not in Zigbox's store
    /// namespace (the peer server, which has threads): an object of one chunk is owned by a
    /// container id, and `lstat` outside the namespace gives host ids (Zigbox Z9, 0.3.1). Call
    /// it once, before the first read; never on a store a namespace child works on.
    pub fn read_from_outside(self: *Opened, map: OutsideMap) void {
        self.store.owners = .{ .outside = map };
    }

    pub fn close(self: *Opened) void {
        self.images.close();
    }
};

pub const OutsideMap = @FieldType(zigbox.store.namespace.Outside, "map");

/// The id map a reader outside the namespace needs, from the same choice `namespace.run` makes.
/// `facts` is large (static or heap) and only scratch.
pub fn outside_owners(facts: *zigbox.Facts) zigbox.store.namespace.Outside {
    var real: zigbox.host_real.HostReal = .{};
    return zigbox.store.namespace.outside_owners(real.interface(), facts);
}

// ---- Tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// Two peers' worth of behaviour over real stores: `from` serves its bundle and chunks.
const Rig = struct {
    from: *ZigboxImages,
    allocator: Allocator,
    /// 0 serves honestly; 1 flips a bit in every chunk; 2 serves a bundle for another manifest's
    /// tree record (the first tree record's digest changed); of the first bundle it serves, 3
    /// changes the manifest the image record names, 4 leaves the last object out and 5 adds
    /// `forged_count` objects of `zigbox_chunks_per_object_max` chunks the tree does not name.
    mode: u8 = 0,
    /// Bundles asked for so far (modes 3 to 5 spoil the first only).
    bundles: u32 = 0,
    clock: u64 = 1000,
    bad: u32 = 0,
    chunks_served: u32 = 0,
    garbage: [constants.swarm_chunk_bytes]u8 = undefined,
    /// The phases `fetch` announced, in order.
    phases: [8]fetch_worker.Phase = undefined,
    phases_count: u32 = 0,

    fn phase(context: *anyopaque, which: fetch_worker.Phase, _: u32, _: u32, _: []const u8) void {
        const rig = self(context);
        rig.phases[rig.phases_count] = which;
        rig.phases_count += 1;
    }

    fn self(context: *anyopaque) *Rig {
        return @ptrCast(@alignCast(context));
    }

    fn bundle(context: *anyopaque, _: fetch_plan.Source, text: []const u8, out: []u8) ?[]const u8 {
        const rig = self(context);
        const wanted = Digest.parse(text) orelse return null;
        const made = encode(rig.allocator, rig.from, wanted, out) orelse return null;
        if (rig.mode == 2) out[magic.len + 4] ^= 1; // The first tree's digest, one bit off.
        rig.bundles += 1;
        if (rig.mode == 3 and rig.bundles == 1) {
            // The image record names another manifest: one digit of it changed.
            const at = std.mem.indexOf(u8, made, ".manifest = \"sha256:").?;
            out[at + ".manifest = \"sha256:".len] ^= 1;
        }
        if (rig.mode >= 4 and rig.bundles == 1) return spoil(rig.allocator, made, out, rig.mode);
        return made;
    }

    fn chunk(
        context: *anyopaque,
        _: fetch_plan.Source,
        ref: ChunkRef,
        out: []u8,
    ) fetch_plan.Result {
        const rig = self(context);
        const bytes = rig.from.images().read_chunk(&ref.hash, out) catch return .refused;
        rig.chunks_served += 1;
        if (rig.mode == 1) {
            @memset(&rig.garbage, 0xee);
            return .{ .bytes = rig.garbage[0..bytes.len] };
        }
        return .{ .bytes = bytes };
    }

    fn tree(_: *anyopaque, _: fetch_plan.Source, _: []const u8, _: []u8) ?[]const u8 {
        return null;
    }

    fn now(context: *anyopaque) u64 {
        const rig = self(context);
        rig.clock += 1;
        return rig.clock;
    }

    fn sleep(_: *anyopaque, _: u32) void {}

    fn blame(_: *anyopaque, _: u8, _: u32, _: u32) void {}

    fn bad_list(context: *anyopaque, _: u8) void {
        self(context).bad += 1;
    }

    fn transport(rig: *Rig) fetch_worker.Transport {
        return .{
            .context = rig,
            .tree_fn = tree,
            .chunk_fn = chunk,
            .now_fn = now,
            .sleep_fn = sleep,
            .blame_fn = blame,
            .bad_list_fn = bad_list,
            .bundle_fn = bundle,
            .phase_fn = phase,
        };
    }
};

/// A bundle cut into its sections: the tree records with their count, each object's bytes, and
/// the image record with its length.
const Parts = struct {
    trees: []const u8,
    objects: std.ArrayList([]const u8) = .empty,
    record: []const u8 = &.{},

    fn split(allocator: Allocator, bundle: []const u8) !Parts {
        var cursor: Cursor = .{ .bytes = bundle };
        _ = cursor.take(magic.len).?;
        const start = cursor.at;
        for (0..cursor.int(u32).?) |_| {
            _ = cursor.digest().?;
            _ = cursor.take(cursor.int(u32).?).?;
        }
        var parts: Parts = .{ .trees = bundle[start..cursor.at] };
        errdefer parts.objects.deinit(allocator);
        for (0..cursor.int(u32).?) |_| {
            const begin = cursor.at;
            _ = cursor.take(32 + 2 + 4 + 4 + 8 + 32).?;
            _ = cursor.take(cursor.int(u32).?).?;
            _ = cursor.take(32 * cursor.int(u32).?).?;
            try parts.objects.append(allocator, bundle[begin..cursor.at]);
        }
        parts.record = bundle[cursor.at..];
        return parts;
    }

    /// The bundle of these trees and record with `objects` in place of the bundle's own.
    fn join(parts: *const Parts, objects: []const []const u8, out: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(out);
        try writer.writeAll(magic);
        try writer.writeAll(parts.trees);
        try writer.writeInt(u32, @intCast(objects.len), .little);
        for (objects) |object| try writer.writeAll(object);
        try writer.writeAll(parts.record);
        return writer.buffered();
    }

    fn deinit(parts: *Parts, allocator: Allocator) void {
        parts.objects.deinit(allocator);
    }
};

/// Forged objects a bundle may add: each a valid object (its id is made from its attributes)
/// of the most chunks an object lists, none of which the tree names. Seventeen of them are more
/// chunks than a fetch takes (M1: the old receiver reached an assert with them).
const forged_count = 17;

fn forged(allocator: Allocator, chunk_bytes: u32) ![]const []const u8 {
    const per = constants.zigbox_chunks_per_object_max;
    const length = 32 + 2 + 4 + 4 + 8 + 32 + 4 + 1 + 4 + 32 * per;
    const all = try allocator.alloc(u8, forged_count * length);
    errdefer allocator.free(all);
    const objects = try allocator.alloc([]const u8, forged_count);
    for (objects, 0..) |*object, index| {
        const content: Digest = .{ .bytes = @splat(@intCast(index + 1)) };
        const none = &zigbox.store.xattrs.empty;
        const attrs: zigbox.store.object.Attrs = .{
            .mode = 0o644,
            .uid = 0,
            .gid = 0,
            .xattrs = none,
        };
        var writer: std.Io.Writer = .fixed(all[index * length ..][0..length]);
        try writer.writeAll(&zigbox.store.object.object_id(content, attrs).bytes);
        try writer.writeInt(u16, 0o644, .little); // 83 bytes in all, then the hashes.
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u64, @as(u64, per) * chunk_bytes, .little);
        try writer.writeAll(&content.bytes);
        try writer.writeInt(u32, none.len, .little);
        try writer.writeAll(none);
        try writer.writeInt(u32, per, .little);
        for (0..per) |at| {
            var hash: Hash = @splat(0xa5);
            std.mem.writeInt(u32, hash[0..4], @intCast(index * per + at), .little);
            try writer.writeAll(&hash);
        }
        object.* = writer.buffered();
    }
    return objects;
}

fn free_forged(allocator: Allocator, objects: []const []const u8) void {
    allocator.free(objects[0].ptr[0 .. forged_count * objects[0].len]);
    allocator.free(objects);
}

/// The rig's spoiled bundles (modes 4 and 5), made from the honest bundle `made` in `out`.
fn spoil(allocator: Allocator, made: []const u8, out: []u8, mode: u8) ?[]const u8 {
    const copy = allocator.dupe(u8, made) catch return null;
    defer allocator.free(copy);
    var parts = Parts.split(allocator, copy) catch return null;
    defer parts.deinit(allocator);
    const own = parts.objects.items;
    if (mode == 4) return parts.join(own[0 .. own.len - 1], out) catch null;
    const extra = forged(allocator, 8) catch return null; // The `Pair` stores' chunk size.
    defer free_forged(allocator, extra);
    parts.objects.appendSlice(allocator, extra) catch return null;
    return parts.join(parts.objects.items, out) catch null;
}

const peer_infos = [_]fetch_worker.PeerInfo{.{ .name = "node1", .filter = &filter_all }};
var filter_all: [64]u8 = @splat(0xff);

fn run_rig(
    rig: *Rig,
    to: *ZigboxImages,
    tree: Digest,
    manifest: Sha256,
    report: *Report,
) Error!void {
    const transport = rig.transport();
    return fetch(testing.allocator, transport, to, tree, manifest, &peer_infos, .{}, report);
}

/// Store A holds the tree and its image record; B is empty.
fn rigged(pair: *images_mod.Pair, tmp: *testing.TmpDir) !void {
    try pair.make(tmp);
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var buffer: [2048]u8 = undefined;
    const text = try images_mod.record_text(&buffer, pair.tree, images_mod.manifest_text);
    _ = try from_a.import_image(text, pair.tree, Sha256.parse(images_mod.manifest_text).?);
}

test "zigbox fetch: a tree comes from a peer by bundle and chunks, and is rooted for its manifest" {
    // Goal: the whole receiving path on real stores. Method: A holds the tree and its record, B
    // fetches it from A through the transport; B then has the tree whole and one root.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator };
    var report: Report = undefined;
    const expected = Sha256.parse(images_mod.manifest_text).?;
    try run_rig(&rig, &to_b, pair.tree, expected, &report);
    const name = pair.tree.text();
    try testing.expect(to_b.images().has(&name));
    try testing.expect(report.peer_chunks > 0);
    try testing.expectEqual(report.chunks, report.peer_chunks);
    try testing.expect(report.peer_bytes[0] > 0);
    try testing.expectEqual(@as(u64, 0), report.cached_bytes);
    try testing.expectEqual(@as(u64, 0), report.struck_peers);
    const Phase = fetch_worker.Phase;
    try testing.expectEqualSlices(
        Phase,
        &.{ .bundle_found, .chunks_done, .imported },
        rig.phases[0..rig.phases_count],
    );
    var listing: [8]zigbox.store.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = try zigbox.store.roots.list(&pair.b, &names, &listing);
    try testing.expectEqual(@as(usize, 1), rooted.count);
    // A second fetch finds the tree whole and asks for nothing.
    const before = rig.chunks_served;
    try run_rig(&rig, &to_b, pair.tree, expected, &report);
    try testing.expectEqual(before, rig.chunks_served);
}

test "zigbox fetch: a record for another manifest is not taken, the peer not struck" {
    // The owner rule through the worker: the manifest comes from the assignment. S1a: a peer
    // sends the newest image of a tree, so an honest peer that ran another image of the same
    // tree sends that one's record; it is counted, never struck.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator };
    var report: Report = undefined;
    const other = Sha256.parse(images_mod.other_manifest_text).?;
    const got = run_rig(&rig, &to_b, pair.tree, other, &report);
    try testing.expectError(error.TreeUnavailable, got);
    try testing.expectEqual(@as(u32, 0), rig.bad);
    try testing.expectEqual(@as(u64, 0), report.struck_peers);
    try testing.expectEqual(@as(u32, 1), report.other_images);
    try testing.expectEqual(@as(u32, 0), rig.chunks_served);
    var listing: [8]zigbox.store.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = try zigbox.store.roots.list(&pair.b, &names, &listing);
    try testing.expectEqual(@as(usize, 0), rooted.count);
}

test "zigbox fetch: a peer that corrupts chunks fails the fetch and nothing is rooted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator, .mode = 1 };
    var report: Report = undefined;
    const expected = Sha256.parse(images_mod.manifest_text).?;
    const got = run_rig(&rig, &to_b, pair.tree, expected, &report);
    try testing.expect(std.meta.isError(got));
    const name = pair.tree.text();
    try testing.expect(!to_b.images().has(&name));
    try testing.expect(report.blamed > 0);
    try testing.expectEqual(@as(u64, 1), report.struck_peers);
    try testing.expectEqual(@as(u64, 0), report.peer_bytes[0]);
    // The log names where it ended: the chunk phase, never the import.
    const Phase = fetch_worker.Phase;
    const seen = rig.phases[0..rig.phases_count];
    try testing.expectEqualSlices(Phase, &.{ .bundle_found, .chunks_failed }, seen);
}

test "zigbox fetch: a bundle whose first tree is not the tree asked for is a bad bundle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator, .mode = 2 };
    var report: Report = undefined;
    const expected = Sha256.parse(images_mod.manifest_text).?;
    const got = run_rig(&rig, &to_b, pair.tree, expected, &report);
    try testing.expectError(error.TreeUnavailable, got);
    try testing.expectEqual(@as(u32, 1), rig.bad);
    try testing.expectEqual(@as(u64, 1), report.struck_peers);
    try testing.expectEqual(@as(usize, 0), to_b.claims.items.len);
}

test "zigbox fetch: every cut of a bundle is refused, never read past" {
    // The cursor bounds every read: truncate a real bundle at each length.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    const out = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(out);
    const whole = encode(testing.allocator, &from_a, pair.tree, out).?;
    const manifest = Sha256.parse(images_mod.manifest_text).?;
    for (0..whole.len) |cut| {
        const got = receive(testing.allocator, &to_b, pair.tree, manifest, whole[0..cut]);
        try testing.expectError(error.BadBundle, got);
        to_b.end_claims();
    }
}

test "zigbox fetch: the serving seam gives the bundle encode makes, and none for a bad name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    const buffer = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(buffer);
    const direct = encode(testing.allocator, &from_a, pair.tree, buffer).?;
    const copy = try testing.allocator.dupe(u8, direct);
    defer testing.allocator.free(copy);
    const name = pair.tree.text();
    const served = serving(&from_a).bundle(&name, buffer).?;
    try testing.expectEqualSlices(u8, copy, served);
    try testing.expect(serving(&from_a).bundle("b3:nonsense", buffer) == null);
    try testing.expect(from_a.images().bundle("anything", buffer) == null);
}

test "zigbox fetch: a second image that shares files with a held one is fetched" {
    // Goal: demo-c2's v1 to v2. Chunks the store holds are not fetched again, so the objects
    // they belong to must not wait for them. Method: B fetches T1, then T2 (T1 plus one file)
    // from A; B ends with both trees whole, and only the new file's chunks come from the peer.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    const second = try pair.add_tree(&tmp);
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var buffer: [2048]u8 = undefined;
    const text = try images_mod.record_text(&buffer, second, images_mod.other_manifest_text);
    const other = Sha256.parse(images_mod.other_manifest_text).?;
    _ = try from_a.import_image(text, second, other);
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator };
    var report: Report = undefined;
    const first = Sha256.parse(images_mod.manifest_text).?;
    try run_rig(&rig, &to_b, pair.tree, first, &report);
    try run_rig(&rig, &to_b, second, other, &report);
    const name = second.text();
    try testing.expect(to_b.images().has(&name));
    try testing.expect(report.already_held > 0);
    try testing.expect(report.peer_chunks > 0);
    try testing.expect(report.peer_chunks < report.chunks);
    var listing: [8]zigbox.store.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = try zigbox.store.roots.list(&pair.b, &names, &listing);
    try testing.expectEqual(@as(usize, 2), rooted.count);
}

test "zigbox fetch: a record naming another manifest is passed over, the next peer is asked" {
    // Goal: S2 and S1a. The record is checked when the bundle arrives: the chunks of a bundle
    // that cannot be rooted for this manifest are not fetched, and the next peer's bundle is
    // taken. The first peer is not struck: it may hold another image of the same tree.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator, .mode = 3 };
    var report: Report = undefined;
    const expected = Sha256.parse(images_mod.manifest_text).?;
    const transport = rig.transport();
    try fetch(testing.allocator, transport, &to_b, pair.tree, expected, &two_peers, .{}, &report);
    try testing.expectEqual(@as(u32, 0), rig.bad);
    try testing.expectEqual(@as(u64, 0), report.struck_peers);
    try testing.expectEqual(@as(u32, 0), report.bad_bundles);
    try testing.expectEqual(@as(u32, 1), report.other_images);
    const name = pair.tree.text();
    try testing.expect(to_b.images().has(&name));
}

const two_peers = [_]fetch_worker.PeerInfo{
    .{ .name = "node1", .filter = &filter_all },
    .{ .name = "node2", .filter = &filter_all },
};

test "zigbox fetch: a bundle's objects are exactly its tree's, none added and none left out" {
    // Goal: M1 and M2. Method: cut a real bundle into its sections and receive it with objects
    // added (forged, more chunks than a fetch takes: the old receiver reached an assert), one
    // replaced by a forged one, the last left out, and the first sent twice. Every one is a bad
    // bundle; the bundle as made is received.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    const out = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(out);
    const made = encode(testing.allocator, &from_a, pair.tree, out).?;
    const whole = try testing.allocator.dupe(u8, made);
    defer testing.allocator.free(whole);
    var parts = try Parts.split(testing.allocator, whole);
    defer parts.deinit(testing.allocator);
    const extra = try forged(testing.allocator, pair.a.chunk_bytes);
    defer free_forged(testing.allocator, extra);
    const own = parts.objects.items;
    try testing.expect(own.len >= 2);
    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(testing.allocator);
    try added.appendSlice(testing.allocator, own);
    try added.appendSlice(testing.allocator, extra);
    const replaced = try testing.allocator.dupe([]const u8, own);
    defer testing.allocator.free(replaced);
    replaced[0] = extra[0];
    const twice = try testing.allocator.dupe([]const u8, own);
    defer testing.allocator.free(twice);
    twice[own.len - 1] = own[0];
    const manifest = Sha256.parse(images_mod.manifest_text).?;
    const spoiled = [_][]const []const u8{ added.items, replaced, own[0 .. own.len - 1], twice };
    for (spoiled) |objects| {
        const bytes = try parts.join(objects, out);
        const got = receive(testing.allocator, &to_b, pair.tree, manifest, bytes);
        try testing.expectError(error.BadBundle, got);
        to_b.end_claims();
    }
    const honest = try parts.join(own, out);
    const got = try receive(testing.allocator, &to_b, pair.tree, manifest, honest);
    testing.allocator.free(got.chunks);
    to_b.end_claims();
}

test "zigbox fetch: a peer that adds or leaves out objects is struck, the next is asked" {
    // Goal: M1 and M2 through the worker. A peer that leaves an object out used to have its
    // bundle taken and the import refused at the end, with no strike and no next peer.
    for ([_]u8{ 4, 5 }) |mode| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var pair: images_mod.Pair = undefined;
        try rigged(&pair, &tmp);
        defer pair.deinit();
        var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
        defer from_a.close();
        var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
        defer to_b.close();
        var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator, .mode = mode };
        var report: Report = undefined;
        const expected = Sha256.parse(images_mod.manifest_text).?;
        const transport = rig.transport();
        const peers = &two_peers;
        try fetch(testing.allocator, transport, &to_b, pair.tree, expected, peers, .{}, &report);
        try testing.expectEqual(@as(u32, 1), rig.bad);
        try testing.expectEqual(@as(u64, 1), report.struck_peers); // Bit 0: the first peer.
        try testing.expectEqual(@as(u32, 1), report.bad_bundles);
        try testing.expectEqual(@as(u32, 2), rig.bundles);
        const name = pair.tree.text();
        try testing.expect(to_b.images().has(&name));
    }
}

test "zigbox fetch: a tree over this node's object limit is too large, and no peer is struck" {
    // Goal: S1b. A limit of ours is no peer's fault: the fetch stops with `TooLarge` before any
    // chunk is asked for, and nobody is struck.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    to_b.claims_max = 1; // The tree has two distinct objects.
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator };
    var report: Report = undefined;
    const expected = Sha256.parse(images_mod.manifest_text).?;
    const transport = rig.transport();
    const peers = &two_peers;
    const tree = pair.tree;
    const got = fetch(testing.allocator, transport, &to_b, tree, expected, peers, .{}, &report);
    try testing.expectError(error.TooLarge, got);
    try testing.expectEqual(@as(u32, 0), rig.bad);
    try testing.expectEqual(@as(u64, 0), report.struck_peers);
    try testing.expectEqual(@as(u32, 1), rig.bundles); // The tree is the same at every peer.
    try testing.expectEqual(@as(u32, 0), rig.chunks_served);
    try testing.expectEqual(@as(usize, 0), to_b.claims.items.len);
}

test "zigbox fetch: a tree held whole for one manifest is imported for another from a peer" {
    // Goal: S4. Whole is not imported: a tree B holds for M1 is fetched for M2 as any other,
    // and B ends with both records; one it holds a record for asks no peer.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pair: images_mod.Pair = undefined;
    try rigged(&pair, &tmp);
    defer pair.deinit();
    var from_a = try ZigboxImages.open(testing.allocator, &pair.a);
    defer from_a.close();
    var to_b = try ZigboxImages.open(testing.allocator, &pair.b);
    defer to_b.close();
    var rig: Rig = .{ .from = &from_a, .allocator = testing.allocator };
    var report: Report = undefined;
    const first = Sha256.parse(images_mod.manifest_text).?;
    const second = Sha256.parse(images_mod.other_manifest_text).?;
    try run_rig(&rig, &to_b, pair.tree, first, &report);
    // A has no record of M2: nothing is imported, and the fetch says so.
    const missing = run_rig(&rig, &to_b, pair.tree, second, &report);
    try testing.expectError(error.TreeUnavailable, missing);
    try testing.expectEqual(@as(u32, 1), report.other_images);
    var buffer: [2048]u8 = undefined;
    const text = try images_mod.record_text(&buffer, pair.tree, images_mod.other_manifest_text);
    _ = try from_a.import_image(text, pair.tree, second);
    const chunks = rig.chunks_served;
    try run_rig(&rig, &to_b, pair.tree, second, &report);
    try testing.expectEqual(@as(u32, 3), rig.bundles);
    try testing.expectEqual(chunks, rig.chunks_served); // Every chunk was held.
    var own: [constants.zigbox_record_bytes_max]u8 = undefined;
    try testing.expect(to_b.own_record(first, &own) != null);
    try testing.expect(to_b.own_record(second, &own) != null);
    // Both records held: either fetch is done here, though B's newest record is M2's.
    try run_rig(&rig, &to_b, pair.tree, first, &report);
    try run_rig(&rig, &to_b, pair.tree, second, &report);
    try testing.expectEqual(@as(u32, 3), rig.bundles);
}
