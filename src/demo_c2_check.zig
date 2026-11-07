//! What demo-c2 asserts, as pure functions over the JSON the `zcube` command prints
//! (`zcube -o json stats pull`, `get replicas`, `why replica`), so that each rule is a unit test
//! and the driver (src/demo_c2_steps.zig) only fetches and reports. docs/demos/c2.md, "demo-c2".

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;

/// One `/pulls/<node>/<tree>` record (docs/keys.md), with the peer bytes summed.
pub const Pull = struct {
    node: []const u8,
    tree: []const u8,
    registry_bytes: u64,
    peer_bytes: u64,
    cached_bytes: u64,
    bad_peers: []const []const u8,
    /// The agent's clock around the pull; 0 when the record has none (not measured).
    started_at_ms: u64 = 0,
    finished_at_ms: u64 = 0,

    /// How long the record says the pull took, null when it was not measured.
    pub fn span_ms(pull: Pull) ?u64 {
        if (pull.started_at_ms == 0 or pull.finished_at_ms < pull.started_at_ms) return null;
        return pull.finished_at_ms - pull.started_at_ms;
    }

    pub fn has_bad_peer(pull: Pull, peer: []const u8) bool {
        for (pull.bad_peers) |name| {
            if (std.mem.eql(u8, name, peer)) return true;
        }
        return false;
    }
};

/// One row of `zcube -o json get replicas`.
pub const Replica = struct {
    id: []const u8,
    node: []const u8,
    image: []const u8,
    status: []const u8,
};

/// The placement decision `zcube -o json why replica` shows.
pub const Placement = struct {
    reason: []const u8,
    locality_bytes: u64,
};

pub const Error = error{ BadJson, OutOfMemory };

/// The records of `tree` in a `zcube -o json stats pull` reply (`{"pulls":[...], ...}`).
pub fn pulls_of(arena: Allocator, reply: Json, tree: []const u8) Error![]Pull {
    const items = array(reply, "pulls") orelse return error.BadJson;
    var found: std.ArrayList(Pull) = .empty;
    for (items) |item| {
        const pull = try pull_from(arena, item);
        if (std.mem.eql(u8, pull.tree, tree)) try found.append(arena, pull);
    }
    return found.items;
}

fn pull_from(arena: Allocator, item: Json) Error!Pull {
    var peer_sum: u64 = 0;
    for (array(item, "peer_bytes") orelse return error.BadJson) |peer| {
        peer_sum += number(peer, "bytes") orelse return error.BadJson;
    }
    const bad = array(item, "bad_peers") orelse return error.BadJson;
    const names = try arena.alloc([]const u8, bad.len);
    for (names, bad) |*name, value| {
        name.* = switch (value) {
            .string => |text| text,
            else => return error.BadJson,
        };
    }
    return .{
        .node = text_of(item, "node") orelse return error.BadJson,
        .tree = text_of(item, "tree") orelse return error.BadJson,
        .registry_bytes = number(item, "registry_bytes") orelse return error.BadJson,
        .peer_bytes = peer_sum,
        .cached_bytes = number(item, "cached_bytes") orelse return error.BadJson,
        .bad_peers = names,
        .started_at_ms = number(item, "started_at_ms") orelse 0,
        .finished_at_ms = number(item, "finished_at_ms") orelse 0,
    };
}

pub fn pull_on(pulls: []const Pull, node: []const u8) ?Pull {
    for (pulls) |pull| {
        if (std.mem.eql(u8, pull.node, node)) return pull;
    }
    return null;
}

/// Step 1 (O5, "registry once"): exactly one node took bytes from the registry, and every other
/// node took none from it and some from its peers.
pub fn registry_once(pulls: []const Pull) bool {
    var from_registry: u32 = 0;
    for (pulls) |pull| {
        if (pull.registry_bytes > 0) {
            from_registry += 1;
        } else if (pull.peer_bytes == 0) {
            return false;
        }
    }
    return from_registry == 1;
}

/// How step 1 found the registry reads (docs/decisions/2026-11-07-demo-c2-registry-once-cap.md).
pub const RegistryRead = struct {
    kind: enum {
        /// One node read the registry, and every other node got the tree from peers.
        once,
        /// Several nodes read it, and every one of those pulls took at least the O5 wait cap:
        /// the elected pull outlasted the wait, so the others fell back to the registry as
        /// designed. Allowed, and said as such.
        overran,
        /// Several nodes read it although the elected pull finished inside the cap (or no
        /// pull was measured): a duplicate pull, the bug the check exists to catch.
        repeated,
        /// No node read the registry, or a node that did not took nothing from peers.
        broken,
    },
    /// The shortest span among the nodes that read the registry (0: none or not measured).
    shortest_ms: u64 = 0,

    pub fn passes(read: RegistryRead) bool {
        return read.kind == .once or read.kind == .overran;
    }
};

/// Step 1 (O5, "registry once"), with the wait cap `cap_ms` (`constants.fetch_peer_wait_ms`).
/// Strict unless the pulls themselves show the cap was overrun: the elected node's pull, the
/// shortest of the registry pulls (a waiting node's span is its wait plus its own pull), took at
/// least `cap_ms`. Without that measurement, more than one registry read is `repeated`.
pub fn registry_read(pulls: []const Pull, cap_ms: u64) RegistryRead {
    var from_registry: u32 = 0;
    var shortest: ?u64 = null;
    var measured = true;
    for (pulls) |pull| {
        if (pull.registry_bytes == 0) {
            if (pull.peer_bytes == 0) return .{ .kind = .broken };
            continue;
        }
        from_registry += 1;
        const span = pull.span_ms() orelse {
            measured = false;
            continue;
        };
        shortest = if (shortest) |held| @min(held, span) else span;
    }
    if (from_registry == 0) return .{ .kind = .broken };
    if (from_registry == 1) return .{ .kind = .once, .shortest_ms = shortest orelse 0 };
    const overran = measured and shortest.? >= cap_ms;
    return .{
        .kind = if (overran) .overran else .repeated,
        .shortest_ms = if (measured) shortest.? else 0,
    };
}

/// Step 2: what a node transferred, from the registry and its peers together.
pub fn transferred(pull: Pull) u64 {
    return pull.registry_bytes + pull.peer_bytes;
}

/// Step 3: nothing from the registry, something from the peers.
pub fn from_peers_only(pull: Pull) bool {
    return pull.registry_bytes == 0 and pull.peer_bytes > 0;
}

/// The replicas of a `zcube -o json get replicas` reply (`{"kind":"replicas","items":[...]}`).
pub fn replicas_of(arena: Allocator, reply: Json) Error![]Replica {
    const items = array(reply, "items") orelse return error.BadJson;
    const rows = try arena.alloc(Replica, items.len);
    for (rows, items) |*row, item| {
        row.* = .{
            .id = text_of(item, "id") orelse return error.BadJson,
            .node = text_of(item, "node") orelse return error.BadJson,
            .image = text_of(item, "image") orelse return error.BadJson,
            .status = text_of(item, "status") orelse return error.BadJson,
        };
    }
    return rows;
}

/// How many replicas run `image` on `node` (`node` empty: on any node).
pub fn running(rows: []const Replica, image: []const u8, node: []const u8) u32 {
    var count: u32 = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.status, "running")) continue;
        if (!std.mem.eql(u8, row.image, image)) continue;
        if (node.len > 0 and !std.mem.eql(u8, row.node, node)) continue;
        count += 1;
    }
    return count;
}

/// True when every node of `nodes` runs exactly `each` replicas of `image`.
pub fn spread_evenly(rows: []const Replica, image: []const u8, nodes: []const []const u8) bool {
    assert(nodes.len > 0);
    const each = running(rows, image, nodes[0]);
    for (nodes) |node| {
        if (running(rows, image, node) != each) return false;
    }
    return each > 0;
}

/// The last placement in a `zcube -o json why replica` reply (`steps[].decision`), if any.
pub fn placement_of(reply: Json) Error!?Placement {
    const steps = array(reply, "steps") orelse return error.BadJson;
    var found: ?Placement = null;
    for (steps) |step| {
        const decision = member(step, "decision") orelse continue;
        if (decision != .object) continue;
        const action = text_of(decision, "action") orelse return error.BadJson;
        if (!std.mem.eql(u8, action, "place_replica")) continue;
        found = .{
            .reason = text_of(decision, "reason") orelse return error.BadJson,
            .locality_bytes = number(decision, "locality_bytes") orelse 0,
        };
    }
    return found;
}

/// Step 4: the decision chose by locality: it counted bytes of the image on the node, and its
/// reason says the image was there (scheduler.zig's placement reason).
pub fn names_locality(placement: Placement) bool {
    if (placement.locality_bytes == 0) return false;
    return std.mem.indexOf(u8, placement.reason, "of the image already there") != null;
}

// ---- JSON access ----

fn member(value: Json, name: []const u8) ?Json {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn array(value: Json, name: []const u8) ?[]const Json {
    return switch (member(value, name) orelse return null) {
        .array => |list| list.items,
        else => null,
    };
}

fn text_of(value: Json, name: []const u8) ?[]const u8 {
    return switch (member(value, name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn number(value: Json, name: []const u8) ?u64 {
    return switch (member(value, name) orelse return null) {
        .integer => |int| if (int < 0) null else @intCast(int),
        else => null,
    };
}

// ---- Tests ----

const testing = std.testing;

/// The envelope `zcube -o json stats pull` prints (docs/api.md, `GET /v1/stats/pull`) around
/// three records swarm-smoke wrote (src/testdata/c2_pulls.txt): node2 from the registry, node1
/// and node3 from node2, node3 having struck node1.
const fixture_pulls =
    \\{"pulls":[
    \\{"v":1,"node":"node1","tree":"b3:af","registry_bytes":0,
    \\ "peer_bytes":[{"peer":"node2","bytes":1353576}],"cached_bytes":0,
    \\ "started_at_ms":1793780016450,"finished_at_ms":1793780016877,"bad_peers":[]},
    \\{"v":1,"node":"node2","tree":"b3:af","registry_bytes":1353576,"peer_bytes":[],
    \\ "cached_bytes":0,"started_at_ms":1793780015945,"finished_at_ms":1793780016016,
    \\ "bad_peers":[]},
    \\{"v":1,"node":"node3","tree":"b3:af","registry_bytes":0,
    \\ "peer_bytes":[{"peer":"node2","bytes":1353576}],"cached_bytes":0,
    \\ "started_at_ms":1793780017171,"finished_at_ms":1793780017750,"bad_peers":["node1"]},
    \\{"v":1,"node":"node3","tree":"b3:other","registry_bytes":5,"peer_bytes":[],
    \\ "cached_bytes":0,"started_at_ms":1,"finished_at_ms":2,"bad_peers":[]}
    \\],"skipped":0,"matched":4,"truncated":false,"revision":40}
;

fn parse(arena: Allocator, text: []const u8) !Json {
    return std.json.parseFromSliceLeaky(Json, arena, text, .{});
}

test "pulls_of keeps one tree's records and sums their peer bytes" {
    // Goal: the step checks read the records of the tree the step deployed, and nothing else.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pulls = try pulls_of(arena, try parse(arena, fixture_pulls), "b3:af");
    try testing.expectEqual(@as(usize, 3), pulls.len);
    const node3 = pull_on(pulls, "node3").?;
    try testing.expectEqual(@as(u64, 1353576), node3.peer_bytes);
    try testing.expect(node3.has_bad_peer("node1"));
    try testing.expect(!node3.has_bad_peer("node2"));
    try testing.expect(from_peers_only(node3));
    try testing.expect(!from_peers_only(pull_on(pulls, "node2").?));
    try testing.expect(registry_once(pulls));
    const other = try pulls_of(arena, try parse(arena, fixture_pulls), "b3:other");
    try testing.expectEqual(@as(usize, 1), other.len);
}

test "registry_once fails when a second node pulled from the registry or took nothing" {
    // Goal: step 1's rule has teeth both ways: two registry pulls, and a node with no bytes.
    const base: Pull = .{
        .node = "node1",
        .tree = "b3:af",
        .registry_bytes = 0,
        .peer_bytes = 10,
        .cached_bytes = 0,
        .bad_peers = &.{},
    };
    var twice = [_]Pull{ base, base, base };
    twice[0].registry_bytes = 10;
    try testing.expect(registry_once(&twice));
    twice[1].registry_bytes = 10;
    try testing.expect(!registry_once(&twice));
    var empty = [_]Pull{ base, base };
    empty[0].registry_bytes = 10;
    empty[1].peer_bytes = 0;
    try testing.expect(!registry_once(&empty));
    var none = [_]Pull{ base, base };
    try testing.expect(!registry_once(&none));
}

test "registry_read tells a slow elected pull from a duplicate pull" {
    // Goal: three registry reads pass only when the elected (shortest) pull took the cap or more;
    // inside the cap, or unmeasured, they stay a failure. Method: spans set on the records.
    const cap: u64 = constants.fetch_peer_wait_ms;
    const base: Pull = .{
        .node = "node1",
        .tree = "b3:af",
        .registry_bytes = 10,
        .peer_bytes = 0,
        .cached_bytes = 0,
        .bad_peers = &.{},
        .started_at_ms = 1000,
        .finished_at_ms = 1000 + cap + 5000,
    };
    var three = [_]Pull{ base, base, base };
    three[0].finished_at_ms = 1000 + cap + 5587; // The elected pull: 35.6 s on a slow runner.
    const slow = registry_read(&three, cap);
    try testing.expect(slow.kind == .overran and slow.passes());
    try testing.expectEqual(cap + 5000, slow.shortest_ms);
    three[1].finished_at_ms = 1000 + cap - 1; // A pull inside the cap, and still two more.
    try testing.expect(registry_read(&three, cap).kind == .repeated);
    three[1].started_at_ms = 0; // Not measured: strict.
    try testing.expect(!registry_read(&three, cap).passes());
    var one = [_]Pull{ base, base };
    one[1].registry_bytes = 0;
    one[1].peer_bytes = 3;
    try testing.expect(registry_read(&one, cap).kind == .once);
    one[1].peer_bytes = 0;
    try testing.expect(registry_read(&one, cap).kind == .broken);
}

test "pulls_of refuses a reply without the envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BadJson, pulls_of(arena, try parse(arena, "{}"), "b3:af"));
    const bad = "{\"pulls\":[{\"node\":\"n\"}]}";
    try testing.expectError(error.BadJson, pulls_of(arena, try parse(arena, bad), "b3:af"));
}

test "replicas_of and running count running replicas by image and node" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"kind":"replicas","items":[
        \\{"id":"a-1","service":"a","node":"node1","generation":1,"image":"b3:1",
        \\ "status":"running","detail":"","started_at_ms":1},
        \\{"id":"a-2","service":"a","node":"node2","generation":1,"image":"b3:1",
        \\ "status":"running","detail":"","started_at_ms":1},
        \\{"id":"a-3","service":"a","node":"node2","generation":2,"image":"b3:2",
        \\ "status":"starting","detail":"","started_at_ms":null}]}
    ;
    const rows = try replicas_of(arena, try parse(arena, text));
    try testing.expectEqual(@as(u32, 2), running(rows, "b3:1", ""));
    try testing.expectEqual(@as(u32, 1), running(rows, "b3:1", "node2"));
    try testing.expectEqual(@as(u32, 0), running(rows, "b3:2", ""));
    try testing.expect(spread_evenly(rows, "b3:1", &.{ "node1", "node2" }));
    try testing.expect(!spread_evenly(rows, "b3:1", &.{ "node1", "node2", "node3" }));
}

test "placement_of finds the placement and names_locality reads it" {
    // Goal: step 4's rule. The reason text is the scheduler's (scheduler.zig, placement reason).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reason = "node1 is the best of the 4 of 4 nodes that fit 250m CPU and 128 MiB: 0 " ++
        "replicas of this service there, then 114 MiB of the image already there (by its " ++
        "summary), then least allocated, then name";
    const text = "{\"v\":1,\"revision\":9,\"subject\":\"replica/w-1\",\"steps\":[" ++
        "{\"type\":\"spec\",\"text\":\"x\"},{\"type\":\"decision\",\"text\":\"y\"," ++
        "\"decision\":{\"id\":\"d1\",\"action\":\"place_replica\",\"reason\":\"" ++
        reason ++ "\",\"locality_bytes\":7}}],\"completeness\":\"complete\"}";
    const placement = (try placement_of(try parse(arena, text))).?;
    try testing.expectEqual(@as(u64, 7), placement.locality_bytes);
    try testing.expect(names_locality(placement));
    try testing.expect(!names_locality(.{ .reason = placement.reason, .locality_bytes = 0 }));
    const none = "{\"steps\":[{\"type\":\"spec\",\"text\":\"x\"}]}";
    try testing.expectEqual(@as(?Placement, null), try placement_of(try parse(arena, none)));
}
