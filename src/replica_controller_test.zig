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
const control_plane = @import("control_plane.zig");
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
    plane: control_plane.ControlPlane,
    api: controller.DecisionSource,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.plane = control_plane.ControlPlane.init(1);
        self.plane.check_i6 = true;
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
        const wake = try self.plane.reconcile(&ctx);
        try testing.expect(self.plane.mismatch == null);
        return wake;
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

    fn expect_replica_image(self: *Fixture, id: []const u8, image: []const u8) !void {
        const ctx = self.context();
        const list = try controller.list_all(
            records.Replica,
            &ctx,
            records.replicas_prefix("hello").slice(),
            null,
            constants.replicas_max,
        );
        for (list.items) |item| {
            if (!std.mem.eql(u8, item.rec.id, id)) continue;
            return testing.expectEqualStrings(image, item.rec.image);
        }
        return error.TestUnexpectedResult;
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

    /// The `cause_evidence` text of the first decision of `kind`/`name` whose action is `action`.
    fn evidence_of(
        self: *Fixture,
        kind: records.SubjectKind,
        name: []const u8,
        action: []const u8,
    ) ![]const u8 {
        const ctx = self.context();
        const prefix = records.index_prefix(kind, name);
        const query: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 100 };
        const page = try ctx.store.list(ctx.arena, query, &self.diag);
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, &self.diag);
            const at = records.decision_key(entry.id);
            const got = try ctx.store.get(ctx.arena, at.slice(), null, &self.diag);
            const decision = try records.read(records.Decision, ctx.arena, got.kv.?, &self.diag);
            if (!std.mem.eql(u8, decision.action, action)) continue;
            return (decision.cause_evidence orelse return error.NoEvidence).text;
        }
        return error.NoSuchDecision;
    }

    /// The `reason` of the first decision of `kind`/`name` whose action is `action`.
    fn reason_of(
        self: *Fixture,
        kind: records.SubjectKind,
        name: []const u8,
        action: []const u8,
    ) ![]const u8 {
        const ctx = self.context();
        const prefix = records.index_prefix(kind, name);
        const query: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 100 };
        const page = try ctx.store.list(ctx.arena, query, &self.diag);
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, &self.diag);
            const at = records.decision_key(entry.id);
            const got = try ctx.store.get(ctx.arena, at.slice(), null, &self.diag);
            const decision = try records.read(records.Decision, ctx.arena, got.kv.?, &self.diag);
            if (std.mem.eql(u8, decision.action, action)) return decision.reason;
        }
        return error.NoSuchDecision;
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
    _ = replica;
    const assigned_at = records.assigned_key("node1", "hello-2");
    const assigned = try ctx.store.get(ctx.arena, assigned_at.slice(), null, &fixture.diag);
    const given = try records.read(records.Assigned, ctx.arena, assigned.kv.?, &fixture.diag);
    try testing.expectEqual(@as(u32, 250), given.requests.cpu_millis);

    var chain = try fixture.decisions(.replica, "hello-2");
    defer chain.deinit(testing.allocator);
    const expected = "create_replica<decision;hold_pending<desired;place_replica<decision;";
    try testing.expectEqualStrings(expected, chain.items);
    var service_chain = try fixture.decisions(.service, "hello");
    defer service_chain.deinit(testing.allocator);
    const want = "apply<desired;scale_up<desired;scale_up<desired;";
    try testing.expectEqualStrings(want, service_chain.items);
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
    const dead_chain = "create_replica<decision;place_replica<decision;" ++
        "delete_replica<observed;release_replica<decision;";
    try testing.expectEqualStrings(dead_chain, dead.items);
    var fresh = try fixture.decisions(.replica, "hello-4");
    defer fresh.deinit(testing.allocator);
    try testing.expectEqualStrings("create_replica<decision;place_replica<decision;", fresh.items);
    var service = try fixture.decisions(.service, "hello");
    defer service.deinit(testing.allocator);
    const service_chain =
        "apply<desired;scale_up<desired;scale_up<desired;replace_replica<decision;";
    try testing.expectEqualStrings(service_chain, service.items);
}

test "delete_replica keeps the exit as cause_evidence once the observed record is gone" {
    // Goal: docs/keys.md's cause_evidence for a dead replica; zigbox-smoke's oom stage reads it,
    // because `stopped oom` is observed only for an instant. Method: three replicas end three
    // ways (oom, signal 9, code 3); each delete_replica decision carries that exit, and the
    // observed records are gone by then.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }) |id| {
        try fixture.observe(id, .running, null, null);
    }
    try fixture.observe("hello-1", .stopped, .{ .kind = .oom }, null);
    try fixture.observe("hello-2", .stopped, .{ .kind = .signaled, .signal = 9 }, null);
    try fixture.observe("hello-3", .stopped, .{ .kind = .exited, .code = 3 }, null);
    _ = try fixture.settle();
    const expected = [_][]const u8{
        "{\"status\":\"stopped\",\"exit\":{\"kind\":\"oom\"}}",
        "{\"status\":\"stopped\",\"exit\":{\"kind\":\"signaled\",\"signal\":9}}",
        "{\"status\":\"stopped\",\"exit\":{\"kind\":\"exited\",\"code\":3}}",
    };
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }, expected) |id, want| {
        const got = try fixture.evidence_of(.replica, id, "delete_replica");
        try testing.expectEqualStrings(want, got);
    }
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
    const tail = "delete_service<desired;scale_down<desired;scale_down<desired;";
    try testing.expect(std.mem.endsWith(u8, chain.items, tail));
}

test "a service deleted and applied again between two steps loses its old replicas (issue 55)" {
    // Goal: regression for the simulation fleet's issue 55. Generation restarts at 1 when a
    // service is deleted and applied again, and the controller never saw the service gone, so
    // the old replicas look like the new service's. Method: the replicas are ahead (generation 2,
    // image B) of the new service (generation 1, image A), which is how the simulation kept
    // them until the service's next apply reached generation 2.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var first = hello;
    first.replicas = 2;
    try fixture.apply(first);
    _ = try fixture.settle();
    var second = first;
    second.image = "b3:9d20c4f1";
    try fixture.apply(second);
    _ = try fixture.settle();
    const rolled = try fixture.ids("hello");
    defer Fixture.free_ids(rolled);
    try expect_ids(&.{ "hello-3", "hello-4" }, rolled);

    const ctx = fixture.context();
    const done = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", "r-00000003");
    try testing.expect(done == .written);
    try fixture.apply(first);
    _ = try fixture.settle();
    const renewed = try fixture.ids("hello");
    defer Fixture.free_ids(renewed);
    try expect_ids(&.{ "hello-5", "hello-6" }, renewed);
    try fixture.expect_replica_image("hello-5", first.image);
}

test "a service applied again with the same generation and another image loses its replicas" {
    // Goal: the second way to be wrong in issue 55, alone: the old replicas are equal in
    // generation (1) to the new service and differ only in image, so only the spec comparison
    // finds them. Method: apply, settle, delete and apply another image with no step between.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var first = hello;
    first.replicas = 2;
    try fixture.apply(first);
    _ = try fixture.settle();
    const ctx = fixture.context();
    const gone = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", "r-00000004");
    try testing.expect(gone == .written);
    var second = first;
    second.image = "b3:9d20c4f1";
    try fixture.apply(second);
    _ = try fixture.settle();
    const last = try fixture.ids("hello");
    defer Fixture.free_ids(last);
    try expect_ids(&.{ "hello-3", "hello-4" }, last);
    try fixture.expect_replica_image("hello-3", second.image);
    const reason = try fixture.reason_of(.service, "hello", "replace_replica");
    const expected = "service hello is at generation 1 and 2 replicas do not run what it asks " ++
        "for; replacing hello-1; hello-2";
    try testing.expectEqualStrings(expected, reason);
}

test "a rolled service says its replicas run an older generation" {
    // Goal: the reason of a replacement names what is true of the replicas. Method: apply a new
    // image to a running service (generation 2), so its replicas are behind in generation.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    var first = hello;
    first.replicas = 2;
    try fixture.apply(first);
    _ = try fixture.settle();
    var second = first;
    second.image = "b3:9d20c4f1";
    try fixture.apply(second);
    _ = try fixture.settle();
    const reason = try fixture.reason_of(.service, "hello", "replace_replica");
    const expected = "service hello is at generation 2 and 2 replicas run an older one; " ++
        "replacing hello-1; hello-2";
    try testing.expectEqualStrings(expected, reason);
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
    // The node controller's first write (the node's status) counts beside the batch.
    try testing.expectEqual(@as(u32, 2), first.acted);
    try testing.expectEqual(fixture.manual.ms, first.at_ms);
    const partial = try fixture.ids("hello");
    defer Fixture.free_ids(partial);
    try testing.expectEqual(@as(usize, 2), partial.len);
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
    /// What is written to `key` just before the armed commit.
    value: []const u8 = "{\"v\":1,\"next\":99}",
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
        .hash_at = hash_at,
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
            const op: store.Op = .{ .put = .{ .key = self.key, .value = self.value } };
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

    fn hash_at(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!store.Hash {
        return from(context).inner.hash_at(revision, diag);
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

/// A C0 store: a v1 service at full count with next_replica 10 and its replicas 7 to 9, and no
/// counter (C0 never wrote one).
fn put_c0_service_at_full_count(fixture: *Fixture) !void {
    const legacy: records.Service = .{
        .v = 1,
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 3,
        .command = hello.command,
        .generation = 1,
        .next_replica = 10,
    };
    try fixture.put(.api, records.service_key("hello").slice(), legacy);
    for ([_][]const u8{ "hello-7", "hello-8", "hello-9" }) |id| {
        const replica: records.Replica = .{
            .id = id,
            .service = "hello",
            .generation = 1,
            .image = legacy.image,
            .command = legacy.command,
        };
        try fixture.put(.replica_controller, records.replica_key("hello", id).slice(), replica);
    }
}

fn reapply_one(fixture: *Fixture, request: []const u8) !void {
    const ctx = fixture.context();
    const done = try apply_mod.delete_service(&ctx, &fixture.api, "hello", "alex", request);
    try testing.expect(done == .written);
    _ = try fixture.settle();
    var one = hello;
    one.replicas = 1;
    try fixture.apply(one);
    _ = try fixture.settle();
}

test "a C0 service at full count, deleted and applied again, does not reuse a number" {
    // Goal: a C0 next_replica reaches the counter even when the service never needs a new
    // replica. Method: a C0 service at full count (replicas 7-9, next_replica 10, no counter);
    // a pass seeds the counter at 10 without creating anything; delete and re-apply gives
    // hello-10, not hello-1.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try put_c0_service_at_full_count(&fixture);
    _ = try fixture.settle();
    try testing.expectEqual(@as(?u64, 10), try counter_next(&fixture, "hello"));
    const before = try fixture.ids("hello");
    defer Fixture.free_ids(before);
    try expect_ids(&.{ "hello-7", "hello-8", "hello-9" }, before);
    try reapply_one(&fixture, "r-00000010");
    const after = try fixture.ids("hello");
    defer Fixture.free_ids(after);
    try expect_ids(&.{"hello-10"}, after);
}

test "a C0 service deleted before any pass leaves a counter past its highest replica" {
    // Goal: the delete path seeds the counter too. Method: the C0 store above, deleted before
    // the controller first runs; stopping its replicas writes the counter at 10, so the
    // re-apply gives hello-10.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try put_c0_service_at_full_count(&fixture);
    try reapply_one(&fixture, "r-00000011");
    const after = try fixture.ids("hello");
    defer Fixture.free_ids(after);
    try expect_ids(&.{"hello-10"}, after);
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
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    try testing.expectEqual(@as(?u64, 99), try counter_next(&fixture, "hello"));
    _ = try fixture.settle();
    const ids = try fixture.ids("hello");
    defer Fixture.free_ids(ids);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3", "hello-99" }, ids);
}

test "the replace transaction fails when the dead replica's assignment moved" {
    // Goal: `/assigned/<node>/<replica>` is in the replace transaction's read set. Method: hello-2
    // is observed killed; a store rewrites its assignment just before the commit; that pass writes
    // nothing and hello-2 is still there. The next passes replace it as usual.
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

    var ctx = fixture.context();
    const key = records.assigned_key("node1", "hello-2");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = got.kv.?.value,
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);

    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-1", "hello-3", "hello-4" }, now);
}

/// A report of `replica` stamped with `tenure`, as a C1 agent writes it.
fn observe_stamped(
    fixture: *Fixture,
    replica: []const u8,
    status: records.ObservedStatus,
    exit: ?records.Exit,
    tenure: u64,
) !void {
    try observe_on(fixture, "node1", replica, status, exit, null, tenure);
}

fn observe_on(
    fixture: *Fixture,
    node: []const u8,
    replica: []const u8,
    status: records.ObservedStatus,
    exit: ?records.Exit,
    raw: ?records.Raw,
    tenure: u64,
) !void {
    const observed: records.Observed = .{
        .replica = replica,
        .node = node,
        .generation = 1,
        .status = status,
        .exit = exit,
        .diagnostic = raw,
        .reported_at_ms = fixture.manual.ms,
        .tenure = tenure,
    };
    try fixture.put(.{ .agent = node }, records.observed_key(node, replica).slice(), observed);
}

fn tenure_of(fixture: *Fixture, name: []const u8) !u64 {
    const ctx = fixture.context();
    const key = records.node_key(name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    return got.kv.?.mod_revision;
}

/// Three replicas running on node1 and reported under its tenure, the node judged `ready`.
fn start_stamped(fixture: *Fixture) !u64 {
    try fixture.start();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    const tenure = try tenure_of(fixture, "node1");
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }) |id| {
        try observe_stamped(fixture, id, .running, null, tenure);
    }
    _ = try fixture.settle();
    return tenure;
}

/// One pass of the replica controller alone, so the node controller cannot judge in between.
fn replica_pass(fixture: *Fixture) !u32 {
    const ctx = fixture.context();
    var mutable = ctx;
    const wake = try fixture.plane.replicas.reconcile(&mutable);
    return wake.acted;
}

test "an exit report of a replaced tenure removes nothing (I3, seeds 300 of the C1 sweep)" {
    // Goal: authority.md section 3, condition 1: no action on an observation whose tenure is not
    // the node's current one. Method: hello-2's stop is reported under tenure t1, the agent then
    // registers again (t2) before the replica controller looks; its pass writes nothing and the
    // replica stays. Before the fix it wrote delete_replica citing the old report.
    var fixture: Fixture = undefined;
    const old = try start_stamped(&fixture);
    defer fixture.stop();
    try fixture.register_node("node1");
    try testing.expect((try tenure_of(&fixture, "node1")) != old);
    try observe_stamped(&fixture, "hello-2", .stopped, .{ .kind = .signaled, .signal = 15 }, old);
    try testing.expectEqual(@as(u32, 0), try replica_pass(&fixture));
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);
}

test "an exit report from a node that is not ready removes nothing (I3, seeds 306 and 145)" {
    // Goal: condition 3: no action on an observation of a node whose status is not `ready`.
    // Method: the node is judged `fenced` after the agent stopped hello-2 (the report is still
    // stamped with the current tenure); the pass writes nothing, and once the node is judged
    // `ready` again the replica is replaced.
    var fixture: Fixture = undefined;
    const tenure = try start_stamped(&fixture);
    defer fixture.stop();
    const fenced: records.NodeStatus = .{
        .state = .fenced,
        .tenure = tenure,
        .at_ms = fixture.manual.ms,
        .decision = "fence-1",
    };
    try fixture.put(.node_controller, records.node_status_key("node1").slice(), fenced);
    const signalled: records.Exit = .{ .kind = .signaled, .signal = 15 };
    try observe_stamped(&fixture, "hello-2", .stopped, signalled, tenure);
    try testing.expectEqual(@as(u32, 0), try replica_pass(&fixture));
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);

    const ready: records.NodeStatus = .{
        .state = .ready,
        .tenure = tenure,
        .at_ms = fixture.manual.ms,
        .decision = "ready-1",
    };
    try fixture.put(.node_controller, records.node_status_key("node1").slice(), ready);
    try testing.expect((try replica_pass(&fixture)) > 0);
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try testing.expect(now.len == 3);
    try testing.expect(!std.mem.eql(u8, now[1], "hello-2"));
}

test "the replacement fails when the node's status moved after the exit report was read" {
    // Goal: `/node-status/<node>` and `/nodes/<node>` are in the read set of a removal that cites
    // an exit report (the read-set rule). Method: a store rewrites the status just before the
    // commit; that pass writes nothing and hello-2 is still there.
    var fixture: Fixture = undefined;
    const tenure = try start_stamped(&fixture);
    defer fixture.stop();
    try observe_stamped(&fixture, "hello-2", .stopped, .{ .kind = .signaled, .signal = 9 }, tenure);
    var ctx = fixture.context();
    const key = records.node_status_key("node1");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = got.kv.?.value,
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);
}

/// What the node controller writes when `name`'s lease ends: `/nodes/<name>` gone and the status
/// `lost` for the tenure it had, by decision "mark-lost-1", at the clock's time.
fn lose(fixture: *Fixture, name: []const u8) !void {
    const ctx = fixture.context();
    const key = records.node_key(name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    const tenure = got.kv.?.mod_revision;
    const op: store.Op = .{ .delete = key.slice() };
    const role: writers.Role = .{ .agent = name };
    _ = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &fixture.diag);
    const value: records.NodeStatus = .{
        .state = .lost,
        .tenure = tenure,
        .at_ms = fixture.manual.ms,
        .decision = "mark-lost-1",
    };
    try fixture.put(.node_controller, records.node_status_key(name).slice(), value);
}

/// The cause id of the newest decision `action` on replica `name`.
fn cause_of(fixture: *Fixture, name: []const u8, action: []const u8) ![]const u8 {
    const ctx = fixture.context();
    const prefix = records.index_prefix(.replica, name);
    const options: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 100 };
    const page = try ctx.store.list(ctx.arena, options, &fixture.diag);
    for (page.kvs) |kv| {
        const entry = try records.read(records.IndexEntry, ctx.arena, kv, &fixture.diag);
        if (!std.mem.eql(u8, entry.action, action)) continue;
        const at = records.decision_key(entry.id);
        const got = try ctx.store.get(ctx.arena, at.slice(), null, &fixture.diag);
        const decision = try records.read(records.Decision, ctx.arena, got.kv.?, &fixture.diag);
        return decision.cause.id.?;
    }
    return error.TestUnexpectedResult;
}

test "a lost node's replicas are replaced under new ids at the grace, caused by its mark_lost" {
    // Goal: decision 2 of slice 4 (authority.md §3). Method: three replicas on node1, node2
    // joins, node1 is lost; nothing changes until `lost_grace_ms` has passed, and the wake-up is
    // at its end; then each replica gets `mark_replica_lost` (cause the `mark_lost`), the
    // service a `replace_replica`, and three new ids run on node2; the old assignments are
    // released.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    for ([_][]const u8{ "hello-1", "hello-2", "hello-3" }) |id| {
        try fixture.observe(id, .running, null, null);
    }
    try fixture.register_node("node2");
    _ = try fixture.settle();
    try lose(&fixture, "node1");
    const lost_at = fixture.manual.ms;
    const waiting = try fixture.step();
    try testing.expectEqual(@as(u32, 0), waiting.acted);
    try testing.expectEqual(lost_at + constants.lost_grace_ms, waiting.at_ms);
    fixture.manual.ms = lost_at + constants.lost_grace_ms - 1;
    try testing.expectEqual(@as(u32, 0), (try fixture.step()).acted);
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);

    fixture.manual.ms += 1;
    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-4", "hello-5", "hello-6" }, now);
    var old = try fixture.decisions(.replica, "hello-2");
    defer old.deinit(testing.allocator);
    const old_chain = "create_replica<decision;place_replica<decision;" ++
        "mark_replica_lost<decision;release_replica<decision;";
    try testing.expectEqualStrings(old_chain, old.items);
    const cause = try cause_of(&fixture, "hello-2", "mark_replica_lost");
    try testing.expectEqualStrings("mark-lost-1", cause);
    const ctx = fixture.context();
    for ([_][]const u8{ "hello-4", "hello-5", "hello-6" }) |id| {
        const at = records.assigned_key("node2", id);
        const got = try ctx.store.get(ctx.arena, at.slice(), null, &fixture.diag);
        try testing.expect(got.kv != null);
    }
    const gone = records.assigned_key("node1", "hello-1");
    const left = try ctx.store.get(ctx.arena, gone.slice(), null, &fixture.diag);
    try testing.expect(left.kv == null);
}

test "a lost node that registers again before the grace ends keeps its replicas" {
    // Goal: a `/nodes` record newer than the lost tenure stops the replacement; the node
    // controller judges the new tenure.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    try lose(&fixture, "node1");
    try fixture.register_node("node1");
    fixture.manual.ms += constants.lost_grace_ms;
    _ = try fixture.settle();
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);
}

test "the replacement off a lost node fails when the node's status moved" {
    // Goal: `/node-status/<node>` is in the read set. Method: a store rewrites node1's status just
    // before the commit; that pass writes nothing; the next ones replace as usual.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    try fixture.register_node("node2");
    try lose(&fixture, "node1");
    fixture.manual.ms += constants.lost_grace_ms;
    var ctx = fixture.context();
    const key = records.node_status_key("node1");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = got.kv.?.value,
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-4", "hello-5", "hello-6" }, now);
}

test "the replacement off a lost node fails when the node registers again before the commit" {
    // Goal: `/nodes/<node>` (absent) is in the read set of the replacement (review M1).
    // Method: the agent's record is put back just before the commit, after the plan saw the
    // node unregistered; the transaction fails its compare and nothing is replaced.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    try fixture.register_node("node2");
    var ctx = fixture.context();
    const key = records.node_key("node1");
    const registered = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    try lose(&fixture, "node1");
    fixture.manual.ms += constants.lost_grace_ms;
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = registered.kv.?.value,
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, now);
    const lost = try count_decisions(&fixture, "hello-1", "mark_replica_lost");
    try testing.expectEqual(@as(u64, 0), lost);
}

fn count_decisions(fixture: *Fixture, name: []const u8, action: []const u8) !u64 {
    const ctx = fixture.context();
    const prefix = records.index_prefix(.replica, name);
    const options: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 100 };
    const page = try ctx.store.list(ctx.arena, options, &fixture.diag);
    var count: u64 = 0;
    for (page.kvs) |kv| {
        const entry = try records.read(records.IndexEntry, ctx.arena, kv, &fixture.diag);
        if (std.mem.eql(u8, entry.action, action)) count += 1;
    }
    return count;
}

/// What the agent API writes when `name` registers (#238): `/nodes/<name>` and
/// `/node-tenure/<name>` in one transaction, so both are at the tenure's revision.
fn register_tenured(fixture: *Fixture, name: []const u8) !void {
    const ctx = fixture.context();
    const node: records.Node = .{
        .name = name,
        .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
    };
    const tenure: records.NodeTenure = .{ .node = name };
    const node_key = records.node_key(name);
    const tenure_key = records.node_tenure_key(name);
    const ops = [_]store.Op{
        .{ .put = .{
            .key = node_key.slice(),
            .value = try records.encode(ctx.arena, node, &fixture.diag),
        } },
        .{ .put = .{
            .key = tenure_key.slice(),
            .value = try records.encode(ctx.arena, tenure, &fixture.diag),
        } },
    };
    const role: writers.Role = .{ .agent = name };
    const done = try writers.txn(ctx.store, role, .{ .on_success = &ops }, &fixture.diag);
    try testing.expect(done.succeeded);
}

/// node1 (registered with a tenure record when `tenured`) runs hello's three replicas, node2
/// is ready, node1 is lost for its tenure, and that tenure's grace has passed.
fn start_lost_past_grace(fixture: *Fixture, tenured: bool) !void {
    try fixture.start();
    if (tenured) try register_tenured(fixture, "node1") else try fixture.register_node("node1");
    try fixture.apply(hello);
    _ = try fixture.settle();
    try fixture.register_node("node2");
    _ = try fixture.settle();
    try lose(fixture, "node1");
    fixture.manual.ms += constants.lost_grace_ms + 1;
}

test "a newer tenure that ended before the node controller judged it gets a grace of its own" {
    // Goal: #238 finding 2, the replica controller's half (`newer_tenure` in `lost_placement`).
    // Method: node1 is lost for T1 and T1's grace is long past; node1 registers as T2 and T2's
    // lease ends before any node controller pass. A replica controller pass must not replace on
    // T1's verdict; once the node controller judges T2 lost, the replacement waits for T2's own
    // `lost_grace_ms`.
    var fixture: Fixture = undefined;
    try start_lost_past_grace(&fixture, true);
    defer fixture.stop();
    try register_tenured(&fixture, "node1");
    const ctx = fixture.context();
    const key = records.node_key("node1");
    const op: store.Op = .{ .delete = key.slice() };
    const role: writers.Role = .{ .agent = "node1" };
    _ = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &fixture.diag);

    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);

    // The node controller judges T2: `lost` again, stamped now; the grace counts from it.
    const judged_at = fixture.manual.ms;
    _ = try fixture.step();
    const status_key = records.node_status_key("node1");
    const got = try ctx.store.get(ctx.arena, status_key.slice(), null, &fixture.diag);
    const status = try records.read(records.NodeStatus, ctx.arena, got.kv.?, &fixture.diag);
    try testing.expectEqual(records.NodeState.lost, status.state);
    try testing.expectEqual(judged_at, status.at_ms);
    fixture.manual.ms = judged_at + constants.lost_grace_ms - 1;
    try testing.expectEqual(@as(u32, 0), (try fixture.plane.replicas.reconcile(&ctx)).acted);
    const still = try fixture.ids("hello");
    defer Fixture.free_ids(still);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, still);
    fixture.manual.ms += 1;
    _ = try fixture.settle();
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-4", "hello-5", "hello-6" }, now);
}

/// Runs one replica controller pass in which a tenure of node1 begins and ends just before the
/// commit (`/node-tenure/node1` moves; `/nodes/node1` is absent at both ends), and checks that
/// the pass replaced nothing.
fn expect_tenure_between_read_and_commit(fixture: *Fixture) !void {
    var ctx = fixture.context();
    const tenure: records.NodeTenure = .{ .node = "node1" };
    const key = records.node_tenure_key("node1");
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = try records.encode(ctx.arena, tenure, &fixture.diag),
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, now);
    const lost = try count_decisions(fixture, "hello-1", "mark_replica_lost");
    try testing.expectEqual(@as(u64, 0), lost);
}

test "the replacement off a lost node fails when a tenure begins and ends before the commit" {
    // Goal: `/node-tenure/<node>` as read is in the replacement's read set (#238): a
    // registration that came and went between the snapshot and the commit leaves `/nodes`
    // absent at both ends, so only the tenure record shows it.
    var fixture: Fixture = undefined;
    try start_lost_past_grace(&fixture, true);
    defer fixture.stop();
    try expect_tenure_between_read_and_commit(&fixture);
}

test "the replacement off a lost node with no tenure record fails when one is written" {
    // Goal: a node last registered by a server from before #238 has no `/node-tenure` record;
    // the replacement compares that record at revision 0, so a tenure that begins and ends
    // before the commit still fails it.
    var fixture: Fixture = undefined;
    try start_lost_past_grace(&fixture, false);
    defer fixture.stop();
    try expect_tenure_between_read_and_commit(&fixture);
}

const node_names = [_][]const u8{ "node1", "node2", "node3" };

/// Three replicas of `hello` placed on three ready nodes (the scheduler spreads them), each
/// reported running under its node's tenure.
fn start_spread(fixture: *Fixture) !void {
    try fixture.start();
    for (node_names) |name| try fixture.register_node(name);
    try fixture.apply(hello);
    _ = try fixture.settle();
    const listed = try fixture.ids("hello");
    defer Fixture.free_ids(listed);
    for (listed) |id| {
        const node = try node_of(fixture, id);
        try observe_on(fixture, node, id, .running, null, null, try tenure_of(fixture, node));
    }
    _ = try fixture.settle();
}

/// The node `replica` is assigned to.
fn node_of(fixture: *Fixture, replica: []const u8) ![]const u8 {
    const ctx = fixture.context();
    for (node_names) |name| {
        const key = records.assigned_key(name, replica);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
        if (got.kv != null) return name;
    }
    return error.TestUnexpectedResult;
}

/// Every replica of `hello` reported stopped with `exit` (and `raw`) under its node's tenure.
fn stop_all(fixture: *Fixture, exit: records.Exit, raw: ?records.Raw) !void {
    const listed = try fixture.ids("hello");
    defer Fixture.free_ids(listed);
    for (listed) |id| {
        const node = try node_of(fixture, id);
        const tenure = try tenure_of(fixture, node);
        try observe_on(fixture, node, id, .stopped, exit, raw, tenure);
    }
}

test "three dead replicas on three ready nodes are all replaced within the compare budget" {
    // Goal: the removal batch holds the compare budget however many nodes the reports come from
    // (`Batch.expect` asserts past `store_txn_compares_max`). Method: all three replicas stop on
    // three nodes; passes of the replica controller alone replace each, none panics.
    var fixture: Fixture = undefined;
    try start_spread(&fixture);
    defer fixture.stop();
    try stop_all(&fixture, .{ .kind = .signaled, .signal = 9 }, null);
    var passes: u32 = 0;
    while (passes < 4 and (try replica_pass(&fixture)) > 0) passes += 1;
    try testing.expect(passes >= 2);
    const now = try fixture.ids("hello");
    defer Fixture.free_ids(now);
    try testing.expectEqual(@as(usize, 3), now.len);
    for (now) |id| {
        try testing.expect(!std.mem.eql(u8, id, "hello-1"));
        try testing.expect(!std.mem.eql(u8, id, "hello-2"));
        try testing.expect(!std.mem.eql(u8, id, "hello-3"));
    }
}

test "three failed starts are held in batches that fit the compare budget" {
    // Goal: the hold batch compares each report, its assignment and its node, within the
    // budget. Method: all three replicas fail to start for a user reason on three nodes; one
    // pass holds `hold_batch_max` (2, since #177) and nothing panics, the next holds the third,
    // a third writes nothing.
    var fixture: Fixture = undefined;
    try start_spread(&fixture);
    defer fixture.stop();
    const raw = try fixture.user_diagnostic(true);
    defer testing.allocator.free(raw.text);
    try stop_all(&fixture, .{ .kind = .start_failed }, raw);
    try testing.expect((try replica_pass(&fixture)) > 0);
    var chain = try fixture.decisions(.service, "hello");
    defer chain.deinit(testing.allocator);
    var holds: u32 = 0;
    var parts = std.mem.splitScalar(u8, chain.items, ';');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "hold_failed_replica")) holds += 1;
    }
    try testing.expectEqual(@as(u32, 2), holds);
    try testing.expect((try replica_pass(&fixture)) > 0);
    chain.deinit(testing.allocator);
    chain = try fixture.decisions(.service, "hello");
    holds = 0;
    parts = std.mem.splitScalar(u8, chain.items, ';');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "hold_failed_replica")) holds += 1;
    }
    try testing.expectEqual(@as(u32, 3), holds);
    try testing.expectEqual(@as(u32, 0), try replica_pass(&fixture));
}

test "a failed start reported under a replaced tenure is not held (I3)" {
    // Goal: a hold cites its report, so it needs an admissible one. Method: hello-2's failed
    // start is reported under t1, the node registers again (t2); the pass holds nothing. Once the
    // node is judged for t2 and reports under it, the hold is written.
    var fixture: Fixture = undefined;
    const old = try start_stamped(&fixture);
    defer fixture.stop();
    const raw = try fixture.user_diagnostic(true);
    defer testing.allocator.free(raw.text);
    try fixture.register_node("node1");
    try observe_on(&fixture, "node1", "hello-2", .stopped, .{ .kind = .start_failed }, raw, old);
    try testing.expectEqual(@as(u32, 0), try replica_pass(&fixture));
    var chain = try fixture.decisions(.service, "hello");
    defer chain.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, chain.items, "hold_failed_replica") == null);

    _ = try fixture.settle();
    const current = try tenure_of(&fixture, "node1");
    try testing.expect(current != old);
    const failed: records.Exit = .{ .kind = .start_failed };
    try observe_on(&fixture, "node1", "hello-2", .stopped, failed, raw, current);
    try testing.expect((try replica_pass(&fixture)) > 0);
    var after = try fixture.decisions(.service, "hello");
    defer after.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, after.items, "hold_failed_replica") != null);
}

test "the replacement fails when only the node's registration moved after the report was read" {
    // Goal: `/nodes/<node>` is in the read set of a removal that cites an exit report, by itself
    // (the status test moves only `/node-status`). Method: the registration is put back
    // unchanged just before the commit: a new revision, so the tenure is not the one judged.
    var fixture: Fixture = undefined;
    const tenure = try start_stamped(&fixture);
    defer fixture.stop();
    try observe_stamped(&fixture, "hello-2", .stopped, .{ .kind = .signaled, .signal = 9 }, tenure);
    var ctx = fixture.context();
    const key = records.node_key("node1");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var moving: MovingStore = .{
        .inner = fixture.memory.interface(),
        .key = key.slice(),
        .value = got.kv.?.value,
    };
    ctx.store = moving.interface();
    const wake = try fixture.plane.replicas.reconcile(&ctx);
    try testing.expect(moving.fired);
    try testing.expectEqual(@as(u32, 0), wake.acted);
    const kept = try fixture.ids("hello");
    defer Fixture.free_ids(kept);
    try expect_ids(&.{ "hello-1", "hello-2", "hello-3" }, kept);
}
