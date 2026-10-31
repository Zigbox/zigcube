//! Tests of the replica controller on the memory store and a manual clock, with the node's
//! agent played by hand: the tests write `/nodes/` and `/observed/` records themselves, so each
//! one pins the controller's behaviour and nothing of the agent's. The agent and the controller
//! together are `sim.zig`'s business.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const apply_mod = @import("apply.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const replica_controller = @import("replica_controller.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

const Diag = diag_mod.Diag;

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0001a4f",
};

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,
    rc: replica_controller.ReplicaController,
    api: controller.DecisionSource,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.rc = replica_controller.ReplicaController.init(1);
        self.api = .{ .instance = 0 };
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    /// A context on a fresh arena: what one reconcile pass gets.
    fn context(self: *Fixture) controller.Context {
        _ = self.arena_state.reset(.retain_capacity);
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    fn apply(self: *Fixture, input: apply_mod.Input) !void {
        const ctx = self.context();
        const result = try apply_mod.apply(&ctx, &self.api, input);
        try testing.expect(result == .written);
    }

    /// Writes a fixture record as `role`, the one that stands in for whoever wrote it in a cluster.
    fn put(self: *Fixture, role: writers.Role, key: []const u8, value: anytype) !void {
        const ctx = self.context();
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
    }

    fn register_node(self: *Fixture, name: []const u8) !void {
        const node: records.Node = .{
            .name = name,
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
        };
        try self.put(.{ .agent = name }, records.node_key(name).slice(), node);
    }

    fn observe(
        self: *Fixture,
        replica: []const u8,
        status: records.ObservedStatus,
        exit: ?records.Exit,
        raw: ?records.Raw,
    ) !void {
        const node = "node1";
        const observed: records.Observed = .{
            .replica = replica,
            .node = node,
            .generation = 1,
            .status = status,
            .exit = exit,
            .diagnostic = raw,
            .reported_at_ms = self.manual.ms,
        };
        try self.put(.{ .agent = node }, records.observed_key(node, replica).slice(), observed);
    }

    /// One pass; returns what it said.
    fn step(self: *Fixture) !controller.Wakeup {
        const ctx = self.context();
        return self.rc.reconcile(&ctx);
    }

    /// Steps until a pass writes nothing; returns how many passes wrote something.
    fn settle(self: *Fixture) !u32 {
        var busy: u32 = 0;
        for (0..200) |_| {
            const wake = try self.step();
            if (wake.acted == 0) return busy;
            busy += 1;
            self.manual.advance(10);
        }
        return error.DidNotSettle;
    }

    /// The ids of a service's replicas, ascending by number.
    fn ids(self: *Fixture, service: []const u8) ![]const []const u8 {
        const ctx = self.context();
        const list = try controller.list_all(
            records.Replica,
            &ctx,
            records.replicas_prefix(service).slice(),
            null,
            constants.replicas_max,
        );
        var out: std.ArrayList([]const u8) = .empty;
        for (list.items) |item| {
            try out.append(testing.allocator, try testing.allocator.dupe(u8, item.rec.id));
        }
        return out.toOwnedSlice(testing.allocator);
    }

    fn free_ids(list: []const []const u8) void {
        for (list) |item| testing.allocator.free(item);
        testing.allocator.free(list);
    }

    /// The decisions about a subject, oldest first, as (action, cause kind) text.
    fn decisions(self: *Fixture, kind: records.SubjectKind, name: []const u8) !std.ArrayList(u8) {
        const ctx = self.context();
        const prefix = records.index_prefix(kind, name);
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = 100,
        }, &self.diag);
        var out: std.ArrayList(u8) = .empty;
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, &self.diag);
            const at = records.decision_key(entry.id);
            const got = try ctx.store.get(ctx.arena, at.slice(), null, &self.diag);
            const decision = try records.read(records.Decision, ctx.arena, got.kv.?, &self.diag);
            const cause = @tagName(decision.cause.kind);
            try out.print(testing.allocator, "{s}<{s};", .{ decision.action, cause });
        }
        return out;
    }

    fn user_diagnostic(self: *Fixture, blame_user: bool) !records.Raw {
        const ctx = self.context();
        var collector: Diag = undefined;
        collector.reset();
        // Two registered codes stand in for a runtime's: one blames the user, one the environment.
        collector.raise(if (blame_user) .E0206 else .E0207);
        collector.cause("digest b3:00ff is not in this node's store", .{});
        var finished: records.Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        const raw = try records.diagnostic_raw(ctx.arena, &finished, &self.diag);
        return .{ .text = try testing.allocator.dupe(u8, raw.text) };
    }
};

fn expect_ids(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| try testing.expectEqualStrings(left, right);
}

test "an applied service gets its replicas, placed on the node, each with a decision chain" {
    // Goal: scale up from nothing, placement once a node exists, idempotence, and the chain of
    // causes of C0's first demo step. Method: apply with no node (replicas wait unplaced), then
    // register a node and settle; a further pass must write nothing.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.apply(hello);
    _ = try fixture.settle();
    const waiting = try fixture.ids("hello");
    defer Fixture.free_ids(waiting);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, waiting);

    try fixture.register_node("node1");
    _ = try fixture.settle();
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);

    const ctx = fixture.context();
    const key = records.replica_key("hello", "hello-2");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    const replica = try records.read(records.Replica, ctx.arena, got.kv.?, &fixture.diag);
    try testing.expectEqualStrings("node1", replica.node);
    try testing.expectEqual(@as(u32, 250), replica.requests.?.cpu_millis);

    var chain = try fixture.decisions(.replica, "hello-2");
    defer chain.deinit(testing.allocator);
    try testing.expectEqualStrings("create_replica<decision;place_replica<decision;", chain.items);
    var service_chain = try fixture.decisions(.service, "hello");
    defer service_chain.deinit(testing.allocator);
    try testing.expectEqualStrings("apply<desired;scale_up<desired;", service_chain.items);
}

test "a replica whose container was killed is replaced, and the decisions say why" {
    // Goal: C0 demo step 2. Method: three running, one observed killed by signal 9; settle; the
    // dead one is gone, a new one with a new number exists, and the chain runs from the observed
    // record through delete_replica and replace_replica.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }) |id| {
        try fixture.observe(id, .running, null, null);
    }
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);

    try fixture.observe("hello-2", .stopped, .{ .kind = .signaled, .signal = 9 }, null);
    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-1", "hello-3", "hello-4" }, now);

    var dead = try fixture.decisions(.replica, "hello-2");
    defer dead.deinit(testing.allocator);
    const dead_chain = "create_replica<decision;place_replica<decision;delete_replica<observed;";
    try testing.expectEqualStrings(dead_chain, dead.items);
    var fresh = try fixture.decisions(.replica, "hello-4");
    defer fresh.deinit(testing.allocator);
    try testing.expectEqualStrings("create_replica<decision;place_replica<decision;", fresh.items);
    var service = try fixture.decisions(.service, "hello");
    defer service.deinit(testing.allocator);
    const service_chain = "apply<desired;scale_up<desired;replace_replica<decision;";
    try testing.expectEqualStrings(service_chain, service.items);
}

test "scaling up keeps the replicas that run; scaling down stops idle ones, then the newest" {
    // Goal: api.md item 10 (a count change does not replace) and the victim order. Method: 3 to
    // 5 must not touch hello-1..3; 5 to 2 with hello-2 not running removes hello-2, hello-5,
    // hello-4.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }) |id| {
        try fixture.observe(id, .running, null, null);
    }
    var five = hello;
    five.replicas = 5;
    try fixture.apply(five);
    _ = try fixture.settle();
    const grown = try fixture.ids("hello");
    defer Fixture.free_ids(grown);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3", "hello-4", "hello-5" }, grown);
    try fixture.observe("hello-4", .running, null, null);
    try fixture.observe("hello-5", .running, null, null);
    try fixture.observe("hello-2", .starting, null, null);

    var two = hello;
    two.replicas = 2;
    try fixture.apply(two);
    _ = try fixture.settle();
    const shrunk = try fixture.ids("hello");
    defer Fixture.free_ids(shrunk);
    try expect_ids(&.{ "hello-1", "hello-3" }, shrunk);
}

test "a user-caused failed start is held once, not retried; a new generation replaces it" {
    // Goal: api.md item 11. Method: observed start_failed with a user-blame diagnostic: no
    // replacement, one hold decision however many passes run; then a changed image replaces it.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var broken = hello;
    broken.name = "broken";
    broken.replicas = 1;
    try fixture.apply(broken);
    _ = try fixture.settle();
    const raw = try fixture.user_diagnostic(true);
    defer testing.allocator.free(raw.text);
    try fixture.observe("broken-1", .stopped, .{ .kind = .start_failed }, raw);
    _ = try fixture.settle();
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
    const held = try fixture.ids("broken");
    defer Fixture.free_ids(held);
    try expect_ids(&.{"broken-1"}, held);
    var chain = try fixture.decisions(.service, "broken");
    defer chain.deinit(testing.allocator);
    const expected = "apply<desired;scale_up<desired;hold_failed_replica<observed;";
    try testing.expectEqualStrings(expected, chain.items);

    broken.image = "b3:9d20c4f1";
    try fixture.apply(broken);
    _ = try fixture.settle();
    const replaced = try fixture.ids("broken");
    defer Fixture.free_ids(replaced);
    try expect_ids(&.{"broken-2"}, replaced);
}

test "a start that failed for the host's reason is replaced like any crash" {
    // Goal: only a user-blamed failure is held (docs/keys.md): an environment-blamed one is
    // replaced. Method: the same observed record with an environment-blamed diagnostic.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var one = hello;
    one.replicas = 1;
    try fixture.apply(one);
    _ = try fixture.settle();
    const raw = try fixture.user_diagnostic(false);
    defer testing.allocator.free(raw.text);
    try fixture.observe("hello-1", .stopped, .{ .kind = .start_failed }, raw);
    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{"hello-2"}, now);
}

test "a spec change replaces every replica; deleting the service stops them all" {
    // Goal: generation replacement and service deletion. Method: a new image bumps the
    // generation and replaces hello-1..3 with hello-4..6; deleting the service removes all,
    // with a scale_down on the gone service whose cause is its desired key.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    var next = hello;
    next.image = "b3:9d20c4f1";
    try fixture.apply(next);
    _ = try fixture.settle();
    const rolled = try fixture.ids("hello");
    defer Fixture.free_ids(rolled);
    try expect_ids(&.{ "hello-4", "hello-5", "hello-6" }, rolled);

    const ctx = fixture.context();
    const done = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", "r-00000002");
    try testing.expect(done == .written);
    _ = try fixture.settle();
    const gone = try fixture.ids("hello");
    defer Fixture.free_ids(gone);
    try testing.expectEqual(@as(usize, 0), gone.len);
    var chain = try fixture.decisions(.service, "hello");
    defer chain.deinit(testing.allocator);
    const tail = "delete_service<desired;scale_down<desired;";
    try testing.expect(std.mem.endsWith(u8, chain.items, tail));
}

test "a pass stops after one batch and says it has more to do" {
    // Goal: the step model's partial progress. Method: 10 replicas is more than one transaction
    // holds; the first pass creates a batch and asks to run again now, and settling finishes it.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var many = hello;
    many.replicas = 10;
    try fixture.apply(many);
    const first = try fixture.step();
    try testing.expectEqual(@as(u32, 1), first.acted);
    try testing.expectEqual(fixture.manual.ms, first.at_ms);
    const partial = try fixture.ids("hello");
    defer Fixture.free_ids(partial);
    try testing.expectEqual(@as(usize, 4), partial.len);
    _ = try fixture.settle();
    const done = try fixture.ids("hello");
    defer Fixture.free_ids(done);
    try testing.expectEqual(@as(usize, 10), done.len);
    const idle = try fixture.step();
    try testing.expectEqual(@as(u32, 0), idle.acted);
    try testing.expect(idle.at_ms > fixture.manual.ms);
}

test "a malformed record is ZC-E0301 naming its key" {
    // Goal: a store with a value no writer of ours produced fails the pass with a coded
    // diagnostic, not a crash and not a silent skip.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const op: store.Op = .{ .put = .{ .key = "/services/bad", .value = "[1,2" } };
    _ = try writers.txn(fixture.memory.interface(), .api, .{ .on_success = &.{op} }, &fixture.diag);
    try testing.expectError(error.Malformed, fixture.step());
    try testing.expectEqual(codes.Code.E0301, fixture.diag.code.?);
}

// ---- The replica counter (`/replica-numbers/<service>`) ---------------------------------------

/// A store that, just before the first `txn`, puts `key` through the inner store: a peer that
/// writes between a controller's read and its commit.
const MovingStore = struct {
    inner: store.Store,
    key: []const u8,
    armed: bool = true,
    fired: bool = false,

    const vtable: store.Store.VTable = .{
        .status = status,
        .get = get,
        .list = list,
        .txn = txn,
        .watch = watch,
        .lease_grant = lease_grant,
        .lease_keepalive = lease_keepalive,
        .lease_revoke = lease_revoke,
        .lease_list = lease_list,
        .expire_leases = expire_leases,
        .compact = compact,
    };

    fn interface(self: *MovingStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *MovingStore {
        return @ptrCast(@alignCast(context));
    }

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        return from(context).inner.vtable.status(from(context).inner.context, diag);
    }

    fn get(
        context: *anyopaque,
        arena: std.mem.Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        const inner = from(context).inner;
        return inner.vtable.get(inner.context, arena, key, at_revision, diag);
    }

    fn list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const inner = from(context).inner;
        return inner.vtable.list(inner.context, arena, options, diag);
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const self = from(context);
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            const op: store.Op = .{ .put = .{ .key = self.key, .value = "{\"v\":1,\"next\":99}" } };
            _ = try self.inner.vtable.txn(self.inner.context, .{ .on_success = &.{op} }, diag);
        }
        return self.inner.vtable.txn(self.inner.context, request, diag);
    }

    fn watch(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        const inner = from(context).inner;
        return inner.vtable.watch(inner.context, options, diag);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        const inner = from(context).inner;
        return inner.vtable.lease_grant(inner.context, ttl_ms, diag);
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const inner = from(context).inner;
        return inner.vtable.lease_keepalive(inner.context, id, diag);
    }

    fn lease_revoke(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Revision {
        const inner = from(context).inner;
        return inner.vtable.lease_revoke(inner.context, id, diag);
    }

    fn lease_list(
        context: *anyopaque,
        arena: std.mem.Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        const inner = from(context).inner;
        return inner.vtable.lease_list(inner.context, arena, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) store.Error!u32 {
        const inner = from(context).inner;
        return inner.vtable.expire_leases(inner.context, diag);
    }

    fn compact(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!void {
        const inner = from(context).inner;
        return inner.vtable.compact(inner.context, revision, diag);
    }
};

/// The counter's `next`, or null if the key is absent.
fn counter_next(fixture: *Fixture, service: []const u8) !?u64 {
    const ctx = fixture.context();
    const key = records.replica_numbers_key(service);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    const kv = got.kv orelse return null;
    return (try records.read(records.ReplicaNumber, ctx.arena, kv, &fixture.diag)).next;
}

test "replica numbers are never reused across scale down, scale up and a re-apply" {
    // Goal: the counter lives in `/replica-numbers/hello`, moves with the replicas it creates,
    // and is never deleted. Method: 3 replicas, down to 1, up to 3; then delete the service, let
    // every replica go, and only then apply it again.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    try testing.expectEqual(@as(?u64, 4), try counter_next(&fixture, "hello"));

    var down = hello;
    down.replicas = 1;
    try fixture.apply(down);
    _ = try fixture.settle();
    try fixture.apply(hello);
    _ = try fixture.settle();
    const regrown = try fixture.ids("hello");
    defer Fixture.free_ids(regrown);
    try expect_ids(&.{ "hello-1", "hello-4", "hello-5" }, regrown);
    try testing.expectEqual(@as(?u64, 6), try counter_next(&fixture, "hello"));

    var ctx = fixture.context();
    const done = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", "r-00000003");
    try testing.expect(done == .written);
    _ = try fixture.settle(); // every replica is gone before the re-apply
    const gone = try fixture.ids("hello");
    defer Fixture.free_ids(gone);
    try expect_ids(&.{}, gone);
    try testing.expectEqual(@as(?u64, 6), try counter_next(&fixture, "hello"));
    try fixture.apply(hello);
    _ = try fixture.settle();
    const again = try fixture.ids("hello");
    defer Fixture.free_ids(again);
    try expect_ids(&.{ "hello-6", "hello-7", "hello-8" }, again);
}

test "the counter stays after its service and replicas are gone" {
    // Goal: one small key per service name ever applied, so ids are unique forever. Method:
    // delete, settle, look for the key.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    const ctx = fixture.context();
    _ = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", "r-00000004");
    _ = try fixture.settle();
    try testing.expectEqual(@as(?u64, 4), try counter_next(&fixture, "hello"));
}

test "the counters never bound the controller: more service names than services_max" {
    // Goal: counters are kept forever, so the number of them must bound nothing. Method: apply
    // and delete more than `services_max` distinct names, one live at a time, then reconcile a
    // live service and a re-applied first name: both work and numbering is right.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var one = hello;
    one.replicas = 1;
    var name_buffer: [32]u8 = undefined;
    var request_buffer: [32]u8 = undefined;
    for (0..constants.services_max + 10) |i| {
        one.name = try std.fmt.bufPrint(&name_buffer, "svc-{d}", .{i});
        try fixture.apply(one);
        _ = try fixture.settle();
        const request = try std.fmt.bufPrint(&request_buffer, "r-{x:0>8}", .{i + 100});
        const ctx = fixture.context();
        const done = try apply_mod.delete_service(&ctx, &fixture.api, one.name, "alex", request);
        try testing.expect(done == .written);
        _ = try fixture.settle();
    }
    try fixture.apply(hello);
    _ = try fixture.settle();
    const live = try fixture.ids("hello");
    defer Fixture.free_ids(live);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, live);
    one.name = "svc-0";
    try fixture.apply(one);
    _ = try fixture.settle();
    const again = try fixture.ids("svc-0");
    defer Fixture.free_ids(again);
    try expect_ids(&.{"svc-0-2"}, again);
}

test "a C0 service record's next_replica seeds the counter, or one past the highest replica" {
    // Goal: a number is never reused when the counter is first created. Method: a v1 service
    // record with next_replica 7 starts the numbers at 7; with the counter removed and a lower
    // legacy value, one past the highest replica number wins.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    const legacy: records.Service = .{
        .v = 1,
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 2,
        .command = hello.command,
        .generation = 1,
        .next_replica = 7,
    };
    try fixture.put(.api, records.service_key("hello").slice(), legacy);
    _ = try fixture.settle();
    const first = try fixture.ids("hello");
    defer Fixture.free_ids(first);
    try expect_ids(&.{ "hello-7", "hello-8" }, first);
    try testing.expectEqual(@as(?u64, 9), try counter_next(&fixture, "hello"));

    const ctx = fixture.context();
    const key = records.replica_numbers_key("hello");
    const drop: store.Op = .{ .delete = key.slice() };
    _ = try writers.txn(ctx.store, .replica_controller, .{ .on_success = &.{drop} }, &fixture.diag);
    var more = hello;
    more.replicas = 3;
    try fixture.apply(more);
    _ = try fixture.settle();
    try testing.expectEqual(@as(?u64, 10), try counter_next(&fixture, "hello"));
}

test "the creating transaction fails when the counter moved, and the next pass plans again" {
    // Goal: the counter is in the read set. Method: a store that moves the counter just before
    // the first commit; that pass writes nothing, the next one creates the replicas from 99.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.apply(hello);
    _ = try fixture.settle();
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = records.replica_numbers_key("hello").slice(),
        .armed = false,
    };
    var more = hello;
    more.replicas = 4;
    try fixture.apply(more);
    moving.armed = true;
    var ctx = fixture.context();
    ctx.store = moving.interface();
    const wake = try fixture.rc.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    try testing.expectEqual(@as(?u64, 99), try counter_next(&fixture, "hello"));
    _ = try fixture.settle();
    const ids = try fixture.ids("hello");
    defer Fixture.free_ids(ids);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3", "hello-99" }, ids);
}
