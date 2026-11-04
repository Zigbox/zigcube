//! The fetch worker over a real Zigbox store (C2 slice 8). Shell code: files, via `ZigboxImages`.
//!
//! A peer sends a tree as a *bundle* (`encode`, `GET /v1/peer/bundle/<digest>`): every tree
//! record, a description of every object (the attributes its id commits to and its chunk hashes)
//! and the image record. The receiver holds each part to what it can check:
//!
//! * a tree record to its own digest, and the first one to the digest asked for;
//! * an object to its id (`begin_object` refuses attributes that do not make the id);
//! * every chunk to its hash (`put_chunk`, through `fetch_worker.run_plan` and the plan's own
//!   check), and Zigbox to the object's content hash when the last chunk lands;
//! * the image record to the manifest of the assignment's digest-pinned image, which the caller
//!   passes in and the peer never names (`import_image`).
//!
//! A bundle that fails any of these is a bad list (ZC-W0602) and the next peer is tried. The tree
//! records of a rejected bundle may already be in the store: they stay unrooted until gc. A
//! peer is trusted only against the full tree digest: `Digest` has no short form.
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
};

const room_attrs: usize = 1 << 16;

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
    write_objects(allocator, images, tree, &writer) orelse return null;
    const image = allocator.create([constants.zigbox_record_bytes_max]u8) catch return null;
    defer allocator.destroy(image);
    const text = images.export_image(tree, image) orelse return null;
    writer.writeInt(u32, @intCast(text.len), .little) catch return null;
    writer.writeAll(text) catch return null;
    return writer.buffered();
}

fn write_objects(
    allocator: Allocator,
    images: *ZigboxImages,
    tree: Digest,
    writer: *std.Io.Writer,
) ?void {
    var found = images.collect(tree) orelse return null;
    defer found.deinit();
    const room = allocator.alloc(u8, room_attrs) catch return null;
    defer allocator.free(room);
    writer.writeInt(u32, @intCast(found.list.items.len), .little) catch return null;
    for (found.list.items) |ref| {
        const meta = images.object_meta(ref, room) orelse return null;
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

/// What a received bundle gave: the chunks to fetch (hash and length, each hash once) and the
/// image record, which borrows the bundle.
pub const Received = struct {
    chunks: []ChunkRef,
    record: []const u8,
};

/// Applies `bytes` to `images`: stores the tree records, claims the objects and lists the chunks
/// they need. `BadBundle` is anything the bundle got wrong, whoever's fault.
pub const ReceiveError = error{ BadBundle, Store, OutOfMemory };

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
    try receive_trees(images, tree, &cursor);
    const chunks = try receive_objects(allocator, images, &cursor);
    errdefer allocator.free(chunks);
    const length = cursor.int(u32) orelse return error.BadBundle;
    const record = cursor.take(length) orelse return error.BadBundle;
    if (cursor.at != bytes.len or record.len == 0) return error.BadBundle;
    // A peer's record for another image is a bad bundle now, not after every chunk is fetched:
    // the next peer is tried and this one is struck. `import_image` still decides at the end.
    if (!record_names(record, expected_manifest)) return error.BadBundle;
    return .{ .chunks = chunks, .record = record };
}

/// Whether the image record `record` names `manifest`: Zigbox writes the line
/// `    .manifest = "sha256:HEX",` (`images.zig`), and a bundle's record comes from `export_image`.
fn record_names(record: []const u8, manifest: Sha256) bool {
    var needle: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&needle, "\n    .manifest = \"{s}\",\n", .{
        &manifest.text(),
    }) catch unreachable; // The line is 92 bytes.
    return std.mem.indexOf(u8, record, line) != null;
}

fn receive_trees(images: *ZigboxImages, tree: Digest, cursor: *Cursor) ReceiveError!void {
    const count = cursor.int(u32) orelse return error.BadBundle;
    if (count == 0 or count > images_mod.entries_max) return error.BadBundle;
    for (0..count) |at| {
        const digest = cursor.digest() orelse return error.BadBundle;
        if (at == 0 and !digest.eql(tree)) return error.BadBundle;
        const length = cursor.int(u32) orelse return error.BadBundle;
        const record = cursor.take(length) orelse return error.BadBundle;
        images.put_tree_record(digest, record) catch |err| return switch (err) {
            error.BadHash => error.BadBundle,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Store,
        };
    }
}

fn receive_objects(
    allocator: Allocator,
    images: *ZigboxImages,
    cursor: *Cursor,
) ReceiveError![]ChunkRef {
    const count = cursor.int(u32) orelse return error.BadBundle;
    if (count > images_mod.entries_max) return error.BadBundle;
    var listed: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    defer listed.deinit(allocator);
    var chunks: std.ArrayList(ChunkRef) = .empty;
    errdefer chunks.deinit(allocator);
    const hashes = try allocator.alloc(Digest, constants.zigbox_chunks_per_object_max);
    defer allocator.free(hashes);
    for (0..count) |_| {
        const meta = try read_meta(cursor, hashes);
        images.begin_object(meta) catch |err| return switch (err) {
            error.BadHash, error.TooMany => error.BadBundle,
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
    }
    return chunks.toOwnedSlice(allocator);
}

fn read_meta(cursor: *Cursor, hashes: []Digest) ReceiveError!images_mod.ObjectMeta {
    const id = cursor.digest() orelse return error.BadBundle;
    const mode = cursor.int(u16) orelse return error.BadBundle;
    const uid = cursor.int(u32) orelse return error.BadBundle;
    const gid = cursor.int(u32) orelse return error.BadBundle;
    const size = cursor.int(u64) orelse return error.BadBundle;
    const content = cursor.digest() orelse return error.BadBundle;
    const xattr_length = cursor.int(u32) orelse return error.BadBundle;
    const xattrs = cursor.take(xattr_length) orelse return error.BadBundle;
    const count = cursor.int(u32) orelse return error.BadBundle;
    if (count > hashes.len) return error.BadBundle;
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
};

/// Gets `tree` into `images` from `peers`, importing its image record only for
/// `expected_manifest`. A tree already whole is left alone. `TreeUnavailable` means no peer gave
/// a bundle that held up (the caller's fallback is the registry's `pull`); `ChunkFailed` that the
/// chunks could not all be had from the peers.
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
    const text = tree.text();
    if (images.images().has(&text)) return;
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
    try fetch_chunks(allocator, transport, images, got.chunks, peers, config, deadline, report);
    if (!images.claims_complete()) return error.ChunkFailed;
    _ = images.import_image(got.record, tree, expected_manifest) catch |err| return switch (err) {
        error.Refused => error.Refused,
        error.StoreFailed => error.Store,
    };
}

/// The first peer's bundle that `receive` accepts. A peer whose bundle fails is counted and told
/// to the transport (ZC-W0602); the claims it made are dropped before the next is tried.
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
            return got;
        } else |err| {
            images.end_claims();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Store) return error.Store;
            report.bad_bundles += 1;
            report.struck_peers |= @as(u64, 1) << @intCast(index);
            transport.bad_list_fn(transport.context, @intCast(index));
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

    pub fn close(self: *Opened) void {
        self.images.close();
    }
};

// ---- Tests ------------------------------------------------------------------------------------

const testing = std.testing;

/// Two peers' worth of behaviour over real stores: `from` serves its bundle and chunks.
const Rig = struct {
    from: *ZigboxImages,
    allocator: Allocator,
    /// 0 serves honestly; 1 flips a bit in every chunk; 2 serves a bundle for another manifest's
    /// tree record (the first tree record's digest changed); 3 spoils the image record of the
    /// first bundle it serves.
    mode: u8 = 0,
    /// Bundles asked for so far (mode 3 spoils the first only).
    bundles: u32 = 0,
    clock: u64 = 1000,
    bad: u32 = 0,
    chunks_served: u32 = 0,
    garbage: [constants.swarm_chunk_bytes]u8 = undefined,

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
        };
    }
};

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
    var listing: [8]zigbox.store.roots.Root = undefined;
    var names: [constants.zigbox_roots_arena_bytes]u8 = undefined;
    const rooted = try zigbox.store.roots.list(&pair.b, &names, &listing);
    try testing.expectEqual(@as(usize, 1), rooted.count);
    // A second fetch finds the tree whole and asks for nothing.
    const before = rig.chunks_served;
    try run_rig(&rig, &to_b, pair.tree, expected, &report);
    try testing.expectEqual(before, rig.chunks_served);
}

test "zigbox fetch: a record for another manifest is refused and the tree is not rooted" {
    // The owner rule through the worker: the manifest comes from the assignment.
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
    try testing.expectError(error.TreeUnavailable, got); // A bad bundle, whatever the chunks.
    try testing.expectEqual(@as(u32, 1), rig.bad);
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

test "zigbox fetch: a record naming another manifest strikes the peer, the next is asked" {
    // Goal: S2. The record is checked when the bundle arrives: the chunks of a bundle that can
    // never be rooted are not fetched, the peer is struck, and the next peer's bundle is taken.
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
    const two = [_]fetch_worker.PeerInfo{
        .{ .name = "node1", .filter = &filter_all },
        .{ .name = "node2", .filter = &filter_all },
    };
    const transport = rig.transport();
    try fetch(testing.allocator, transport, &to_b, pair.tree, expected, &two, .{}, &report);
    try testing.expectEqual(@as(u32, 1), rig.bad);
    try testing.expectEqual(@as(u64, 1), report.struck_peers); // Bit 0: the first peer.
    try testing.expectEqual(@as(u32, 1), report.bad_bundles);
    const name = pair.tree.text();
    try testing.expect(to_b.images().has(&name));
}
