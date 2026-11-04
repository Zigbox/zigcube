//! `zcube stats pull [node]` (docs/cli.md): the recorded pulls of image trees, as
//! `GET /v1/stats/pull` returns them, newest first: how many bytes each came from the registry
//! and from which peers, how many were already on the node, how long it took and which peers
//! were struck. The table shortens a tree digest; `-o wide` prints it whole with the per-peer
//! bytes.

const std = @import("std");
const cli_args = @import("cli_args.zig");
const cli_commands = @import("cli_commands.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const cli_view = @import("cli_view.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Options = cli_args.Options;
const Report = cli_report.Report;
const Writer = std.Io.Writer;

const PeerBytes = struct { peer: []const u8, bytes: u64 };

/// One entry of the reply's `pulls`.
const Pull = struct {
    node: []const u8,
    tree: []const u8,
    registry_bytes: u64 = 0,
    peer_bytes: []const PeerBytes = &.{},
    cached_bytes: u64 = 0,
    started_at_ms: u64 = 0,
    finished_at_ms: u64 = 0,
    bad_peers: []const []const u8 = &.{},
};

const Reply = struct { pulls: []const Pull, skipped: u32 = 0, revision: u64 = 0 };

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// A digest longer than this is shortened in the table: `b3:` and 12 hex digits, then three dots
/// (ASCII: the table pads by bytes).
const tree_shown_bytes = 15;

pub fn pull(
    env: *const Env,
    client: *Client,
    options: Options,
    node: ?[]const u8,
    report: *Report,
) Error!void {
    const arena = env.arena;
    const path = if (node) |name|
        try std.fmt.allocPrint(arena, "/v1/stats/pull?node={s}", .{name})
    else
        "/v1/stats/pull";
    const reply = try client.get(path, report);
    const body = std.json.parseFromSliceLeaky(Reply, arena, reply.body, parse_options) catch
        return cli_data.contract(report, reply.request_id, "is not a list of pulls");
    report.revision = body.revision;
    const out = if (options.output == .json)
        try std.fmt.allocPrint(arena, "{s}\n", .{std.mem.trimEnd(u8, reply.body, "\n")})
    else
        try text(arena, &body, options.output == .wide);
    try cli_commands.emit(env, .stdout, out, report);
}

/// The table: one row per pull. The default columns fit a terminal; `wide` adds the whole digest
/// and each peer's share.
pub fn text(arena: Allocator, body: *const Reply, wide: bool) Error![]const u8 {
    if (body.pulls.len == 0) return "no pulls have been recorded\n";
    var out: Writer.Allocating = .init(arena);
    var cells: std.ArrayList([]const []const u8) = .empty;
    for (body.pulls) |*item| try cells.append(arena, try row(arena, item, wide));
    const narrow: []const []const u8 = &.{
        "NODE", "TREE", "REGISTRY", "PEERS", "CACHED", "TOOK", "BAD PEERS",
    };
    const wider: []const []const u8 = &.{
        "NODE", "TREE", "REGISTRY", "PEERS", "CACHED", "TOOK", "BAD PEERS", "FROM PEERS",
    };
    cli_view.write_table(&out.writer, if (wide) wider else narrow, cells.items) catch
        return error.OutOfMemory;
    if (body.skipped > 0) {
        out.writer.print("{d} records could not be read\n", .{body.skipped}) catch
            return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn row(arena: Allocator, item: *const Pull, wide: bool) Error![]const []const u8 {
    var peers_total: u64 = 0;
    for (item.peer_bytes) |from| peers_total += from.bytes;
    const took_ms = item.finished_at_ms -| item.started_at_ms;
    const tree = if (wide or item.tree.len <= tree_shown_bytes)
        item.tree
    else
        try std.fmt.allocPrint(arena, "{s}...", .{item.tree[0..tree_shown_bytes]});
    const bad = if (item.bad_peers.len == 0)
        "-"
    else
        try std.mem.join(arena, ",", item.bad_peers);
    const cells: []const []const u8 = &.{
        item.node,
        tree,
        try cli_view.bytes_text(arena, item.registry_bytes),
        try cli_view.bytes_text(arena, peers_total),
        try cli_view.bytes_text(arena, item.cached_bytes),
        try cli_view.seconds_text(arena, took_ms),
        bad,
    };
    if (!wide) return arena.dupe([]const u8, cells);
    var shares: std.ArrayList(u8) = .empty;
    for (item.peer_bytes, 0..) |from, at| {
        const size = try cli_view.bytes_text(arena, from.bytes);
        const sep = if (at == 0) "" else ",";
        try shares.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}{s}={s}", .{
            sep, from.peer, size,
        }));
    }
    const joined = if (shares.items.len == 0) "-" else shares.items;
    return std.mem.concat(arena, []const u8, &.{ cells, &.{joined} });
}

test "the table shortens a long digest, sums the peers, and wide says it all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = "b3:abababababababababababababababababababababababababababababababab";
    const pulls = [_]Pull{.{
        .node = "node2",
        .tree = long,
        .registry_bytes = 3 * 1024 * 1024,
        .peer_bytes = &.{
            .{ .peer = "node1", .bytes = 1024 },
            .{ .peer = "node3", .bytes = 2048 },
        },
        .cached_bytes = 0,
        .started_at_ms = 1000,
        .finished_at_ms = 3500,
        .bad_peers = &.{"node3"},
    }};
    const body: Reply = .{ .pulls = &pulls, .skipped = 1, .revision = 9 };
    const narrow = try text(arena, &body, false);
    try std.testing.expectEqualStrings(
        "NODE   TREE                REGISTRY  PEERS  CACHED  TOOK  BAD PEERS\n" ++
            "node2  b3:abababababab...  3Mi       3Ki    0B      2.5s  node3\n" ++
            "1 records could not be read\n",
        narrow,
    );
    const wide = try text(arena, &body, true);
    try std.testing.expect(std.mem.indexOf(u8, wide, long) != null);
    const tail = "node1=1Ki,node3=2Ki\n1 records could not be read\n";
    try std.testing.expect(std.mem.endsWith(u8, wide, tail));
    const empty = try text(arena, &.{ .pulls = &.{} }, false);
    try std.testing.expectEqualStrings("no pulls have been recorded\n", empty);
}
