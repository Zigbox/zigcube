//! The worst case of `GET /v1/stats/pull` against the real request arena (`BoundedArena` of
//! exactly `request_arena_bytes_max`), on the memory store (which copies only the page it
//! returns) and on SQLite (which copies every key and value into the arena).
//! Shell test: it needs SQLite and files.

const std = @import("std");
const testing = std.testing;
const api_mod = @import("api.zig");
const clock_mod = @import("clock.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const SqliteStore = @import("store_sqlite.zig").SqliteStore;

const Diag = diag_mod.Diag;

/// Stores `count` pull records of the largest size the agent endpoint accepts.
fn fill(s: store.Store, count: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const node: [constants.node_name_bytes_max]u8 = @splat('n');
    const peer: [constants.node_name_bytes_max]u8 = @splat('p');
    var peers: [constants.pull_peers_max]records.PullPeer = undefined;
    for (&peers) |*slot| slot.* = .{ .peer = &peer, .bytes = std.math.maxInt(u64) };
    var bad: [constants.pull_peers_max][]const u8 = undefined;
    for (&bad) |*slot| slot.* = &peer;
    var longest: usize = 0;
    for (0..count) |at| {
        var tree: [64]u8 = @splat('t');
        _ = std.fmt.bufPrint(&tree, "b3:{x:0>8}", .{at}) catch unreachable; // 11 bytes fit in 64.
        const record: records.Pull = .{
            .node = &node,
            .tree = &tree,
            .registry_bytes = std.math.maxInt(u64),
            .peer_bytes = &peers,
            .cached_bytes = std.math.maxInt(u64),
            .started_at_ms = std.math.maxInt(u64),
            .finished_at_ms = 1000 + at,
            .bad_peers = &bad,
        };
        const bytes = try records.encode(arena.allocator(), record, &diag);
        try testing.expect(bytes.len <= constants.pull_record_bytes_max);
        longest = @max(longest, bytes.len);
        const key = records.pull_key(&node, &tree);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
        _ = try writers.txn(s, .{ .agent = &node }, .{ .on_success = &.{op} }, &diag);
    }
    try testing.expect(longest > constants.pull_record_bytes_max / 2);
}

/// Asks for the stats under an arena of exactly the real limit; returns what it used.
fn ask(s: store.Store) !u64 {
    var manual: clock_mod.ManualClock = .{};
    var bounded = BoundedArena.init(testing.allocator, constants.request_arena_bytes_max);
    defer bounded.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: controller.Context = .{
        .store = s,
        .clock = manual.clock(),
        .arena = bounded.allocator(),
        .diag = &diag,
    };
    var api: api_mod.Api = .{ .version = "0.0.0", .backend = "test", .started_at_ms = 0 };
    const response = api.handle(&ctx, .{
        .caller = .local,
        .method = "GET",
        .path = "/v1/stats/pull",
        .query = "limit=500",
    });
    // Silent on a pass: a passing test step that writes to stderr is reported by the build
    // runner as `failed command: ...` (docs/STYLE.md, "Randomised and racing tests"). The
    // measurement is in docs/decisions/2026-11-04-pull-stats-caps.md.
    if (response.status != 200 or bounded.used_bytes * 2 > constants.request_arena_bytes_max) {
        std.debug.print("pull stats worst case: used_bytes {d} of {d}\n{s}\n", .{
            bounded.used_bytes,
            constants.request_arena_bytes_max,
            response.body[0..@min(response.body.len, 600)],
        });
    }
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, "\"truncated\":true") != null);
    // At least twice the room it needs. This guards the arena bound; the cap itself is guarded
    // by the comptime assert on `pulls_read_max` in constants.zig (at the old cap of 1,000 this
    // test still passes).
    try testing.expect(bounded.used_bytes * 2 <= constants.request_arena_bytes_max);
    return bounded.used_bytes;
}

test "stats pull at its read cap with the largest records fits the request arena (memory)" {
    // Goal: the worst case at the cap uses at most half the real limit (2x arena bound; the cap
    // itself is enforced by the comptime assert in constants.zig, not by this test).
    // Method: cap + 500 maximum records, one request under a
    // BoundedArena of exactly `request_arena_bytes_max`.
    var manual: clock_mod.ManualClock = .{};
    var memory: MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    try fill(memory.interface(), constants.pulls_read_max + 500);
    _ = try ask(memory.interface());
}

test "stats pull at its read cap with the largest records fits the request arena (SQLite)" {
    // Goal: as above on the store that copies every key and value into the arena.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/pulls.db", .{tmp.sub_path});
    var manual: clock_mod.ManualClock = .{};
    var diag: Diag = undefined;
    diag.reset();
    const db = try testing.allocator.create(SqliteStore);
    defer testing.allocator.destroy(db);
    try db.open(testing.io, manual.clock(), path, .{ .create = true }, &diag);
    defer db.close();
    try fill(db.interface(), constants.pulls_read_max + 500);
    _ = try ask(db.interface());
}
