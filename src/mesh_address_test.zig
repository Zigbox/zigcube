//! Tests of C4 slice 1 through `apply`: mesh addresses (assigned on create, kept, backfilled,
//! never reused while a replica remains or within a day) and `.allow` (refused with ZC-E0135 when
//! bad; a change writes a `grant` decision and is not a new generation).

const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const apply_mod = @import("apply.zig");
const mesh_address = @import("mesh_address.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const day_ms = constants.mesh_address_quarantine_ms;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    manual: ManualClock,
    memory: *MemoryStore,
    diag: Diag,
    source: controller.DecisionSource,

    fn init(fixture: *Fixture) !void {
        fixture.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        fixture.manual = .{ .ms = 1761350000000 };
        fixture.memory = try testing.allocator.create(MemoryStore);
        fixture.memory.init(testing.allocator, fixture.manual.clock());
        fixture.diag.reset();
        fixture.source = .{ .instance = 0 };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.memory.deinit();
        testing.allocator.destroy(fixture.memory);
        fixture.arena_state.deinit();
    }

    fn context(fixture: *Fixture) controller.Context {
        return .{
            .store = fixture.memory.interface(),
            .clock = fixture.manual.clock(),
            .arena = fixture.arena_state.allocator(),
            .diag = &fixture.diag,
        };
    }

    fn apply(fixture: *Fixture, applied: apply_mod.Input) !apply_mod.Result {
        const ctx = fixture.context();
        fixture.diag.reset();
        return apply_mod.apply(&ctx, &fixture.source, applied);
    }

    fn delete(fixture: *Fixture, name: []const u8) !void {
        const ctx = fixture.context();
        const done = try apply_mod.delete_service(&ctx, &fixture.source, name, "me", "r-1");
        try testing.expect(done == .written);
    }

    fn service(fixture: *Fixture, name: []const u8) !records.Service {
        const ctx = fixture.context();
        const got = try ctx.store.get(ctx.arena, records.service_key(name).slice(), null, ctx.diag);
        return records.read(records.Service, ctx.arena, got.kv.?, ctx.diag);
    }

    fn address(fixture: *Fixture, name: []const u8) ![]const u8 {
        return (try fixture.service(name)).mesh_address.?;
    }

    fn put_bytes(fixture: *Fixture, key: []const u8, bytes: []const u8) !void {
        const ctx = fixture.context();
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try ctx.store.txn(.{ .on_success = &.{op} }, ctx.diag);
        try testing.expect(done.succeeded);
    }

    fn put(fixture: *Fixture, key: []const u8, value: anytype) !void {
        const ctx = fixture.context();
        try fixture.put_bytes(key, try records.encode(ctx.arena, value, ctx.diag));
    }

    fn remove(fixture: *Fixture, key: []const u8) !void {
        const ctx = fixture.context();
        const op: store.Op = .{ .delete = key };
        const done = try ctx.store.txn(.{ .on_success = &.{op} }, ctx.diag);
        try testing.expect(done.succeeded);
    }

    /// Sets the counter past the end of the block, so the next create starts again at the first.
    fn wrap(fixture: *Fixture) !void {
        const past: records.MeshAddressNext = .{ .next = @as(u32, constants.mesh_address_max) + 1 };
        try fixture.put(records.key_mesh_address_next, past);
    }

    /// The `grant` decisions written so far, newest last.
    fn grant_changes(fixture: *Fixture) ![]const []const u8 {
        const ctx = fixture.context();
        const listed = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_decisions,
            .limit = 100,
        }, ctx.diag);
        var changes: std.ArrayList([]const u8) = .empty;
        for (listed.kvs) |kv| {
            const decision = try records.read(records.Decision, ctx.arena, kv, ctx.diag);
            if (!std.mem.eql(u8, decision.action, "grant")) continue;
            try changes.append(ctx.arena, decision.change.?);
        }
        return changes.items;
    }
};

fn input(name: []const u8) apply_mod.Input {
    return .{
        .name = name,
        .image = "b3:51aa9c03",
        .replicas = 2,
        .command = &.{ "sh", "-c", "sleep 1" },
        .applied_by = "alex@laptop",
        .request_id = "r-0001a4f",
    };
}

test "a service takes the next address on create and keeps it on every later apply" {
    // Goal: docs/keys.md "Mesh addresses": assigned once, by the API, in order. Method: create two
    // services, change one, delete and re-create none; the addresses stay.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("web"));
    _ = try fixture.apply(input("db"));
    try testing.expectEqualStrings("127.77.0.1", try fixture.address("web"));
    try testing.expectEqualStrings("127.77.0.2", try fixture.address("db"));
    var scaled = input("web");
    scaled.replicas = 5;
    scaled.image = "b3:7c02aaaaaaaa";
    try testing.expect((try fixture.apply(scaled)) == .written);
    try testing.expectEqualStrings("127.77.0.1", try fixture.address("web"));
    try testing.expect((try fixture.apply(scaled)) == .unchanged);
    try testing.expectEqual(@as(u32, 5), (try fixture.service("web")).v);
}

test "an identical re-apply of a service written before C4 assigns its address" {
    // Goal: the backfill: a v4 record with no address takes one on its next apply, even with
    // nothing else changed. Method: strip the address and write the record at v4, re-apply.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("old"));
    var stripped = try fixture.service("old");
    stripped.v = 4;
    stripped.mesh_address = null;
    try fixture.put(records.service_key("old").slice(), stripped);
    try testing.expectEqual(@as(?[]const u8, null), (try fixture.service("old")).mesh_address);
    const again = try fixture.apply(input("old"));
    try testing.expect(again == .written);
    try testing.expectEqual(@as(u64, 1), again.written.generation);
    try testing.expectEqualStrings("127.77.0.2", try fixture.address("old"));
}

test "an address is not reused within a day, nor while a replica record of its service remains" {
    // Goal: the slice's test "the address is never reused while a replica remains". Method: wrap
    // the counter after deleting `a`, which held 127.77.0.1: each block (quarantine, a
    // `/replicas/` record, an `/observed/` record, one that does not read) sends the next create
    // past it; with all gone, the address is taken again.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("a"));
    try testing.expectEqualStrings("127.77.0.1", try fixture.address("a"));
    try fixture.delete("a");

    fixture.manual.ms += day_ms - 1;
    try fixture.wrap();
    _ = try fixture.apply(input("b"));
    try testing.expectEqualStrings("127.77.0.2", try fixture.address("b"));

    fixture.manual.ms += 1;
    const replica_key = "/replicas/a/a-1";
    try fixture.put_bytes(replica_key, "{}");
    try fixture.wrap();
    _ = try fixture.apply(input("c"));
    try testing.expectEqualStrings("127.77.0.3", try fixture.address("c"));
    try fixture.remove(replica_key);

    const observed_key = "/observed/n1/a-1";
    const seen: records.Observed = .{
        .replica = "a-1",
        .node = "n1",
        .generation = 1,
        .status = .stopped,
        .reported_at_ms = fixture.manual.ms,
    };
    try fixture.put(observed_key, seen);
    try fixture.wrap();
    _ = try fixture.apply(input("d"));
    try testing.expectEqualStrings("127.77.0.4", try fixture.address("d"));

    try fixture.put_bytes(observed_key, "not a record");
    try fixture.wrap();
    _ = try fixture.apply(input("e"));
    try testing.expectEqualStrings("127.77.0.5", try fixture.address("e"));
    try fixture.remove(observed_key);

    try fixture.wrap();
    _ = try fixture.apply(input("f"));
    try testing.expectEqualStrings("127.77.0.1", try fixture.address("f"));
}

test "a replica of another service with a longer name does not hold an address" {
    // Goal: `replica_of` matches `<service>-<n>` only, so `a` is not held by `a-b-1`'s records.
    try testing.expect(mesh_address.replica_of("a-1", "a"));
    try testing.expect(mesh_address.replica_of("a-12", "a"));
    try testing.expect(!mesh_address.replica_of("a-b-1", "a"));
    try testing.expect(!mesh_address.replica_of("ab-1", "a"));
    try testing.expect(!mesh_address.replica_of("a-", "a"));
    try testing.expect(!mesh_address.replica_of("a", "a"));
}

test "every number of the block becomes a canonical address and parses back" {
    // Goal: text and parse agree on the whole block, and non-canonical text is refused.
    var buffer: [constants.mesh_address_text_bytes_max]u8 = undefined;
    var number: u32 = constants.mesh_address_min;
    while (number <= constants.mesh_address_max) : (number += 1) {
        const text = records.mesh_address_text(&buffer, @intCast(number));
        try testing.expectEqual(@as(?u16, @intCast(number)), records.mesh_address_parse(text));
    }
    const refused = [_][]const u8{
        "127.77.0.0",  "127.77.255.255", "127.77.0.01",  "127.78.0.1",
        "127.77.0",    "127.77.0.1.",    "127.77.256.1", "127.77.-1.1",
        " 127.77.0.1", "",
    };
    for (refused) |text| try testing.expectEqual(@as(?u16, null), records.mesh_address_parse(text));
    try testing.expectEqual(@as(u16, 1), mesh_address.wrapped(0));
    try testing.expectEqual(@as(u16, 1), mesh_address.wrapped(65535));
    try testing.expectEqual(@as(u16, 65534), mesh_address.wrapped(65534));
}

test "a bad allow list is ZC-E0135 and writes nothing" {
    // Goal: the slice's admission test. Method: each rule of `allow_problem` once; the store has
    // no service and no address held after each.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var many: [constants.service_allow_max + 1]records.Grant = undefined;
    for (&many, 0..) |*grant, index| grant.* = .{ .from = "web", .port = @intCast(index + 1) };
    const cases = [_]struct { allow: []const records.Grant, cause: []const u8 }{
        .{ .allow = &.{.{ .from = "web", .port = 0 }}, .cause = "port 0" },
        .{ .allow = &.{.{ .from = "web", .port = 70000 }}, .cause = "port 70000" },
        .{ .allow = &.{.{ .from = "db", .port = 5432 }}, .cause = "names itself" },
        .{ .allow = &.{.{ .from = "Web!", .port = 5432 }}, .cause = "not a valid" },
        .{
            .allow = &.{ .{ .from = "web", .port = 5432 }, .{ .from = "web", .port = 5432 } },
            .cause = "grant 2: web on port 5432 is listed twice",
        },
        .{ .allow = &many, .cause = "it holds 65 grants" },
    };
    for (cases) |case| {
        var bad = input("db");
        bad.allow = case.allow;
        try testing.expectError(error.Invalid, fixture.apply(bad));
        try testing.expectEqual(.E0135, fixture.diag.code.?);
        const cause = fixture.diag.causes.slice()[0].slice();
        try testing.expect(std.mem.indexOf(u8, cause, case.cause) != null);
        fixture.diag.reset();
        const ctx = fixture.context();
        const held = try ctx.store.get(ctx.arena, "/mesh-addresses/00001", null, ctx.diag);
        try testing.expectEqual(@as(?store.KeyValue, null), held.kv);
    }
    var ok = input("db");
    ok.allow = many[0..constants.service_allow_max];
    try testing.expect((try fixture.apply(ok)) == .written);
}

test "a change of allow writes a grant decision and is not a new generation" {
    // Goal: docs/keys.md: `allow` does not change how replicas run. Method: create with one grant,
    // swap it for another, re-apply unchanged, then drop every grant.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var db = input("db");
    db.allow = &.{.{ .from = "web", .port = 5432 }};
    const created = try fixture.apply(db);
    try testing.expectEqual(@as(u64, 1), created.written.generation);
    db.allow = &.{ .{ .from = "web", .port = 5432 }, .{ .from = "batch", .port = 5432 } };
    const changed = try fixture.apply(db);
    try testing.expectEqual(@as(u64, 1), changed.written.generation);
    try testing.expect((try fixture.apply(db)) == .unchanged);
    db.allow = &.{};
    _ = try fixture.apply(db);
    const changes = try fixture.grant_changes();
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("web → 5432 added", changes[0]);
    try testing.expectEqualStrings("batch → 5432 added", changes[1]);
    try testing.expectEqualStrings("web → 5432 removed, batch → 5432 removed", changes[2]);
    const stored = try fixture.service("db");
    try testing.expectEqual(@as(usize, 0), stored.allow.len);
    try testing.expectEqual(@as(u32, 5), stored.v);
}

test "a reorder of allow alone is no change: no grant decision, no write" {
    // Goal: review MUST 1: `allow` is a set; a reorder must not reach the grant decision with
    // nothing added or removed (its assertion would take the server down). Method: create with
    // two grants, apply them reversed, then reversed with a third added.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var db = input("db");
    db.allow = &.{ .{ .from = "web", .port = 5432 }, .{ .from = "batch", .port = 5432 } };
    _ = try fixture.apply(db);
    db.allow = &.{ .{ .from = "batch", .port = 5432 }, .{ .from = "web", .port = 5432 } };
    try testing.expect((try fixture.apply(db)) == .unchanged);
    try testing.expectEqual(@as(usize, 1), (try fixture.grant_changes()).len);
    db.allow = &.{
        .{ .from = "batch", .port = 5432 },
        .{ .from = "cron", .port = 5432 },
        .{ .from = "web", .port = 5432 },
    };
    const changed = try fixture.apply(db);
    try testing.expectEqual(@as(u64, 1), changed.written.generation);
    try testing.expectEqualStrings("grants changed", changed.written.change);
    const changes = try fixture.grant_changes();
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("cron → 5432 added", changes[1]);
}

test "two creates that race for one number: the second commit conflicts" {
    // Goal: review SHOULD 1: the compares on the counter and on the hold are what keep two
    // services off one address. Method: plan two assigns at the same revision, commit both: the
    // second conflicts. Then each compare alone: a counter moved, or a hold written, between
    // the assign's read and its commit fails it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const ctx = fixture.context();
    var first: controller.Batch = .{};
    var second: controller.Batch = .{};
    const first_address = try mesh_address.assign(&ctx, &first, "x");
    const second_address = try mesh_address.assign(&ctx, &second, "y");
    try testing.expectEqualStrings(first_address, second_address);
    try testing.expect((try controller.commit(&ctx, .api, &first)) == .applied);
    try testing.expect((try controller.commit(&ctx, .api, &second)) == .conflict);

    // The counter alone: the hold the batch writes is free, but the counter moved.
    var counter_moved: controller.Batch = .{};
    _ = try mesh_address.assign(&ctx, &counter_moved, "z");
    try fixture.put(records.key_mesh_address_next, records.MeshAddressNext{ .next = 9 });
    try testing.expect((try controller.commit(&ctx, .api, &counter_moved)) == .conflict);

    // The hold alone: the counter is as read, but the number was taken under it.
    var hold_taken: controller.Batch = .{};
    const taken = try mesh_address.assign(&ctx, &hold_taken, "z");
    try testing.expectEqualStrings("127.77.0.9", taken);
    const key = records.mesh_address_key(9);
    try fixture.put(key.slice(), records.MeshAddressHold{ .service = "w" });
    try testing.expect((try controller.commit(&ctx, .api, &hold_taken)) == .conflict);
}

test "a release that races a write of its hold conflicts and leaves the new holder" {
    // Goal: review SHOULD 1, the delete side: `release` compares the hold it read, so a hold
    // rewritten between the delete's read and its commit (a reuse) is never marked released
    // under its new service. Method: release `a`'s hold into a batch, rewrite the hold, commit.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("a"));
    const ctx = fixture.context();
    var batch: controller.Batch = .{};
    try mesh_address.release(&ctx, &batch, "a", "127.77.0.1");
    try testing.expectEqual(@as(u32, 1), batch.compares_count);
    const key = records.mesh_address_key(1);
    try fixture.put(key.slice(), records.MeshAddressHold{ .service = "b" });
    try testing.expect((try controller.commit(&ctx, .api, &batch)) == .conflict);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const hold = try records.read(records.MeshAddressHold, ctx.arena, got.kv.?, ctx.diag);
    try testing.expectEqualStrings("b", hold.service);
    try testing.expectEqual(@as(?u64, null), hold.released_at_ms);
}

test "a hold that does not read is held: a delete and the next creates still succeed" {
    // Goal: review SHOULD 2: a malformed hold (a service name that is not one, or not JSON)
    // neither fails the delete of the service that held it nor any later create. Method: spoil
    // `a`'s hold, delete `a`, wrap past a day: the create skips the hold and takes the next.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("a"));
    const key = records.mesh_address_key(1);
    const spoiled = [_][]const u8{
        "{\"v\":1,\"service\":\"Not A Name\",\"released_at_ms\":1}",
        "not a record",
    };
    for (spoiled, 0..) |bytes, index| {
        try fixture.put_bytes(key.slice(), bytes);
        if (index == 0) try fixture.delete("a");
        fixture.manual.ms += day_ms;
        try fixture.wrap();
        const name = if (index == 0) "b" else "c";
        _ = try fixture.apply(input(name));
        const want = if (index == 0) "127.77.0.2" else "127.77.0.3";
        try testing.expectEqualStrings(want, try fixture.address(name));
    }
    const ctx = fixture.context();
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    try testing.expectEqualStrings("not a record", got.kv.?.value);
}

test "an observation that does not read holds back its own service's address only" {
    // Goal: review SHOULD 2: one undecodable `/observed/` record no longer blocks every reuse:
    // the key names its replica. Method: two deleted services past their day; an unreadable
    // observation of `a-1` keeps 127.77.0.1, and `b`'s 127.77.0.2 is reused.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.apply(input("a"));
    _ = try fixture.apply(input("b"));
    try fixture.delete("a");
    try fixture.delete("b");
    try fixture.put_bytes("/observed/n1/a-1", "not a record");
    fixture.manual.ms += day_ms;
    try fixture.wrap();
    _ = try fixture.apply(input("c"));
    try testing.expectEqualStrings("127.77.0.2", try fixture.address("c"));
}

test "a create past the end of the block wraps, and is ZC-E0207 when every probe is held" {
    // Goal: the supervisor's test of the wrap and the refusal. Method: hold the last 100 numbers
    // and start the counter at the first of them: the probe runs off the end of the block,
    // wraps and takes 127.77.0.1. Then hold every number one create probes: it is refused and
    // writes nothing.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const last_first: u16 = constants.mesh_address_max - 99;
    var number: u32 = last_first;
    while (number <= constants.mesh_address_max) : (number += 1) {
        const key = records.mesh_address_key(@intCast(number));
        try fixture.put(key.slice(), records.MeshAddressHold{ .service = "held" });
    }
    try fixture.put(records.key_mesh_address_next, records.MeshAddressNext{ .next = last_first });
    _ = try fixture.apply(input("wrapped"));
    try testing.expectEqualStrings("127.77.0.1", try fixture.address("wrapped"));

    const start: u16 = 1000;
    for (0..constants.mesh_address_probes_max) |probe| {
        const key = records.mesh_address_key(mesh_address.probe_number(start, @intCast(probe)));
        try fixture.put(key.slice(), records.MeshAddressHold{ .service = "held" });
    }
    try fixture.put(records.key_mesh_address_next, records.MeshAddressNext{ .next = start });
    try testing.expectError(error.NoCapacity, fixture.apply(input("db")));
    try testing.expectEqual(.E0207, fixture.diag.code.?);
    const cause = fixture.diag.causes.slice()[0].slice();
    try testing.expect(std.mem.startsWith(u8, cause, "127.77.0.0/16 has no free address"));
    fixture.diag.reset();
    const ctx = fixture.context();
    const db = try ctx.store.get(ctx.arena, records.service_key("db").slice(), null, ctx.diag);
    try testing.expectEqual(@as(?store.KeyValue, null), db.kv);
}

test "a run of held numbers longer than the probes does not refuse a create" {
    // Goal: review SHOULD 3: after the wrap, 500 held numbers in a row after the counter must
    // not refuse every create while most of the block is free. Method: hold 500 in a row from
    // the counter: the create takes a spread probe past them, and the counter moves past it.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const start: u16 = 2000;
    for (0..constants.mesh_address_probes_max) |offset| {
        const key = records.mesh_address_key(@intCast(start + offset));
        try fixture.put(key.slice(), records.MeshAddressHold{ .service = "held" });
    }
    try fixture.put(records.key_mesh_address_next, records.MeshAddressNext{ .next = start });
    _ = try fixture.apply(input("db"));
    const taken = records.mesh_address_parse(try fixture.address("db")).?;
    try testing.expect(taken >= start + constants.mesh_address_probes_max);
    const ctx = fixture.context();
    const got = try ctx.store.get(ctx.arena, records.key_mesh_address_next, null, ctx.diag);
    const next = try records.read(records.MeshAddressNext, ctx.arena, got.kv.?, ctx.diag);
    try testing.expectEqual(@as(u32, taken) + 1, next.next);
}

test "probe numbers: in order from the counter, then spread, all distinct, wrapping" {
    var seen: std.StaticBitSet(constants.mesh_address_max + 1) = .empty;
    for (0..constants.mesh_address_probes_max) |probe| {
        const number = mesh_address.probe_number(constants.mesh_address_max, @intCast(probe));
        try testing.expect(number >= constants.mesh_address_min);
        try testing.expect(!seen.isSet(number));
        seen.set(number);
    }
    try testing.expectEqual(@as(u16, 65534), mesh_address.probe_number(65534, 0));
    try testing.expectEqual(@as(u16, 1), mesh_address.probe_number(65534, 1));
    try testing.expectEqual(@as(u16, 7), mesh_address.probe_number(5, 2));
}

test "an observed endpoint's host: a name, IPv4, or bracketed IPv6" {
    // Goal: review NIT: `endpoint_valid` refused only some bad hosts.
    const accepted = [_][]const u8{ "10.0.0.7:30001", "node-1.lan:30001", "[::1]:30001" };
    for (accepted) |text| try testing.expect(records.endpoint_valid(text));
    const refused = [_][]const u8{
        "::1:30001", "[::1:30001", "a:b:1", "[::1]x:1", "[]:1", ":1", "10.0.0.7:0", "10.0.0.7",
    };
    for (refused) |text| try testing.expect(!records.endpoint_valid(text));
}
