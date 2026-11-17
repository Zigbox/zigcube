//! The state at one revision, grouped for an outside checker: `GET /v1/replicas` and `GET
//! /v1/nodes` (docs/api.md, "state at one revision"; the Jepsen battery, docs/jepsen.md).
//!
//! Each view reads its prefixes at one revision, in pages, and groups the keys it found by replica
//! id or by node name. It decodes nothing and judges nothing: a record is served as stored, and
//! more than one assignment of an id (what I1a forbids) is shown, not hidden. A prefix with more
//! than `pages_max` pages is cut and the view says `truncated`.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const failures = @import("store_failures.zig");

const Context = controller.Context;
const KeyValue = store.KeyValue;
const Revision = store.Revision;

pub const Error = controller.Error;

/// Pages a view reads of one prefix at most. A page holds at most `page_limit` keys (8,000 keys
/// in all), and fewer when its values reach `store_page_bytes_max`: a prefix of large values is
/// cut sooner, and the view says `truncated`.
pub const pages_max: u32 = constants.cli_list_pages_max;
const page_limit: u32 = constants.store_list_limit_max;

comptime {
    assert(pages_max * page_limit >= constants.replicas_max);
    assert(pages_max * page_limit >= constants.nodes_max);
    assert(pages_max * page_limit >= constants.assigned_max);
}

/// How a view pages: the defaults, except in a test of truncation.
pub const Paging = struct {
    pages: u32 = pages_max,
    limit: u32 = page_limit,
};

pub const ReplicaRow = struct {
    id: []const u8,
    /// `/replicas/<service>/<id>`, null when the id has none.
    replica: ?KeyValue = null,
    /// Every `/assigned/<node>/<id>`, ascending by key.
    assigned: []const KeyValue = &.{},
    /// Every `/observed/<node>/<id>`, ascending by key.
    observed: []const KeyValue = &.{},
};

pub const NodeRow = struct {
    name: []const u8,
    node: ?KeyValue = null,
    status: ?KeyValue = null,
    allocation: ?KeyValue = null,
    /// Every key under `/assigned/<name>/`, job runs included, ascending by key.
    assigned: []const KeyValue = &.{},
};

pub fn View(comptime Row: type) type {
    return struct {
        revision: Revision,
        truncated: bool,
        rows: []const Row,
    };
}

const Reader = struct {
    ctx: *const Context,
    /// Null until the first page answers; every later page reads at it.
    revision: ?Revision,
    paging: Paging,
    truncated: bool = false,

    fn prefix(reader: *Reader, wanted: []const u8) Error![]const KeyValue {
        assert(wanted.len > 0);
        assert(wanted[wanted.len - 1] == '/');
        const ctx = reader.ctx;
        var found: std.ArrayList(KeyValue) = .empty;
        var after: ?[]const u8 = null;
        var page: u32 = 0;
        assert(reader.paging.pages > 0);
        assert(reader.paging.limit > 0);
        while (page < reader.paging.pages) : (page += 1) {
            const got = try ctx.store.list(ctx.arena, .{
                .prefix = wanted,
                .at_revision = reader.revision,
                .limit = reader.paging.limit,
                .continue_after = after,
            }, ctx.diag);
            if (reader.revision) |fixed| assert(got.revision == fixed);
            reader.revision = got.revision;
            found.appendSlice(ctx.arena, got.kvs) catch return failures.no_memory(ctx.diag);
            after = got.continue_after orelse break;
        } else {
            reader.truncated = true;
        }
        for (found.items) |kv| assert(kv.mod_revision <= reader.revision.?);
        return found.items;
    }
};

/// `/replicas/<service>/<id>`, `/assigned/<node>/<id>` and `/observed/<node>/<id>` all end in
/// the id: the part after the last '/'.
fn last_part(key: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, key, '/').?; // Every key starts with '/'.
    return key[slash + 1 ..];
}

/// `/assigned/<node>/<id>` and `/observed/<node>/<id>`: the middle part.
fn middle_part(key: []const u8, prefix: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, key, prefix));
    const rest = key[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    return rest[0..slash];
}

const Kind = enum { replica, assigned, observed, node, status, allocation };

/// One key, filed under the row it belongs to.
const Entry = struct {
    row: []const u8,
    kind: Kind,
    kv: KeyValue,

    fn less(_: void, a: Entry, b: Entry) bool {
        const order = std.mem.order(u8, a.row, b.row);
        if (order != .eq) return order == .lt;
        return std.mem.order(u8, a.kv.key, b.kv.key) == .lt;
    }
};

fn file(ctx: *const Context, entries: *std.ArrayList(Entry), entry: Entry) Error!void {
    assert(entry.kv.key.len > 0);
    assert(entry.kv.mod_revision > 0);
    entries.append(ctx.arena, entry) catch return failures.no_memory(ctx.diag);
}

/// The replicas view at `at` (null: the current revision).
pub fn replicas(ctx: *const Context, at: ?Revision) Error!View(ReplicaRow) {
    return replicas_paged(ctx, at, .{});
}

pub fn replicas_paged(ctx: *const Context, at: ?Revision, paging: Paging) Error!View(ReplicaRow) {
    var reader: Reader = .{ .ctx = ctx, .revision = at, .paging = paging };
    var entries: std.ArrayList(Entry) = .empty;
    for (try reader.prefix(records.prefix_replicas)) |kv| {
        try file(ctx, &entries, .{ .row = last_part(kv.key), .kind = .replica, .kv = kv });
    }
    for (try reader.prefix(records.prefix_assigned)) |kv| {
        const id = last_part(kv.key);
        if (records.job_of_run(id) != null) continue; // A job's run: GET /v1/jobs shows it.
        try file(ctx, &entries, .{ .row = id, .kind = .assigned, .kv = kv });
    }
    for (try reader.prefix(records.prefix_observed)) |kv| {
        try file(ctx, &entries, .{ .row = last_part(kv.key), .kind = .observed, .kv = kv });
    }
    std.sort.block(Entry, entries.items, {}, Entry.less);
    var rows: std.ArrayList(ReplicaRow) = .empty;
    var index: usize = 0;
    while (index < entries.items.len) {
        const id = entries.items[index].row;
        var end = index;
        while (end < entries.items.len and std.mem.eql(u8, entries.items[end].row, id)) end += 1;
        rows.append(ctx.arena, try replica_row(ctx, id, entries.items[index..end])) catch
            return failures.no_memory(ctx.diag);
        index = end;
    }
    assert(rows.items.len <= entries.items.len);
    return .{ .revision = reader.revision.?, .truncated = reader.truncated, .rows = rows.items };
}

fn replica_row(ctx: *const Context, id: []const u8, group: []const Entry) Error!ReplicaRow {
    assert(group.len > 0);
    var row: ReplicaRow = .{ .id = id };
    var assigned: std.ArrayList(KeyValue) = .empty;
    var observed: std.ArrayList(KeyValue) = .empty;
    for (group) |entry| {
        assert(std.mem.eql(u8, entry.row, id));
        switch (entry.kind) {
            // Two services cannot hold one id (`<service>-<n>`); keep the first if they did.
            .replica => row.replica = row.replica orelse entry.kv,
            .assigned => assigned.append(ctx.arena, entry.kv) catch
                return failures.no_memory(ctx.diag),
            .observed => observed.append(ctx.arena, entry.kv) catch
                return failures.no_memory(ctx.diag),
            .node, .status, .allocation => unreachable, // Filed by `nodes` only.
        }
    }
    row.assigned = assigned.items;
    row.observed = observed.items;
    return row;
}

/// The nodes view at `at` (null: the current revision).
pub fn nodes(ctx: *const Context, at: ?Revision) Error!View(NodeRow) {
    var reader: Reader = .{ .ctx = ctx, .revision = at, .paging = .{} };
    var entries: std.ArrayList(Entry) = .empty;
    const singles = [_]struct { []const u8, Kind }{
        .{ records.prefix_nodes, .node },
        .{ records.prefix_node_status, .status },
        .{ records.prefix_allocations, .allocation },
    };
    for (singles) |single| {
        for (try reader.prefix(single[0])) |kv| {
            const name = kv.key[single[0].len..];
            try file(ctx, &entries, .{ .row = name, .kind = single[1], .kv = kv });
        }
    }
    for (try reader.prefix(records.prefix_assigned)) |kv| {
        const name = middle_part(kv.key, records.prefix_assigned);
        try file(ctx, &entries, .{ .row = name, .kind = .assigned, .kv = kv });
    }
    std.sort.block(Entry, entries.items, {}, Entry.less);
    var rows: std.ArrayList(NodeRow) = .empty;
    var index: usize = 0;
    while (index < entries.items.len) {
        const name = entries.items[index].row;
        var end = index;
        while (end < entries.items.len and std.mem.eql(u8, entries.items[end].row, name)) end += 1;
        rows.append(ctx.arena, try node_row(ctx, name, entries.items[index..end])) catch
            return failures.no_memory(ctx.diag);
        index = end;
    }
    assert(rows.items.len <= entries.items.len);
    return .{ .revision = reader.revision.?, .truncated = reader.truncated, .rows = rows.items };
}

fn node_row(ctx: *const Context, name: []const u8, group: []const Entry) Error!NodeRow {
    assert(group.len > 0);
    var row: NodeRow = .{ .name = name };
    var assigned: std.ArrayList(KeyValue) = .empty;
    for (group) |entry| {
        assert(std.mem.eql(u8, entry.row, name));
        switch (entry.kind) {
            .node => row.node = entry.kv,
            .status => row.status = entry.kv,
            .allocation => row.allocation = entry.kv,
            .assigned => assigned.append(ctx.arena, entry.kv) catch
                return failures.no_memory(ctx.diag),
            .replica, .observed => unreachable, // Filed by `replicas` only.
        }
    }
    row.assigned = assigned.items;
    return row;
}

test "last and middle parts of keys" {
    try std.testing.expectEqualStrings("hello-1", last_part("/replicas/hello/hello-1"));
    try std.testing.expectEqualStrings("node1", middle_part("/assigned/node1/x-1", "/assigned/"));
    try std.testing.expectEqualStrings("x", middle_part("/assigned/x", "/assigned/"));
}

test "a prefix longer than the pages a view reads is cut and says truncated" {
    // Goal: `truncated` is set when, and only when, a prefix has keys past the last page read
    // (review of PR 276: nothing failed when it was never set). Method: two pages of three keys;
    // five replicas fit, seven do not, and the six read are the first six by key.
    const testing = std.testing;
    const ManualClock = @import("clock.zig").ManualClock;
    const MemoryStore = @import("store_memory.zig").MemoryStore;
    const Diag = @import("diag.zig").Diag;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1761350000123 };
    const memory = try testing.allocator.create(MemoryStore);
    defer testing.allocator.destroy(memory);
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: Context = .{
        .store = memory.interface(),
        .clock = manual.clock(),
        .arena = arena_state.allocator(),
        .diag = &diag,
    };
    const paging: Paging = .{ .pages = 2, .limit = 3 };
    const keys = [_][]const u8{
        "/replicas/s/s-1", "/replicas/s/s-2", "/replicas/s/s-3", "/replicas/s/s-4",
        "/replicas/s/s-5", "/replicas/s/s-6", "/replicas/s/s-7",
    };
    for (keys, 0..) |key, index| {
        const op: store.Op = .{ .put = .{ .key = key, .value = "{}" } };
        _ = try ctx.store.txn(.{ .on_success = &.{op} }, &diag);
        if (index == 4) {
            const whole = try replicas_paged(&ctx, null, paging);
            try testing.expect(!whole.truncated);
            try testing.expectEqual(@as(usize, 5), whole.rows.len);
        }
    }
    const cut = try replicas_paged(&ctx, null, paging);
    try testing.expect(cut.truncated);
    try testing.expectEqual(@as(usize, 6), cut.rows.len);
    for (cut.rows, keys[0..6]) |row, key| {
        try testing.expectEqualStrings(last_part(key), row.id);
        try testing.expectEqualStrings(key, row.replica.?.key);
    }
    try testing.expect(!(try replicas(&ctx, null)).truncated);
}
