//! Tests of the rollout controller (C3 slice 7) through the whole control plane over a memory
//! store: a rolling update that obeys the budget, a held new replica that fails the rollout, and
//! a user's pause and resume.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const control_plane = @import("control_plane.zig");
const rollout_controller = @import("rollout_controller.zig");
const sim_tap = @import("sim_tap.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

const Diag = diag_mod.Diag;

const web: apply_mod.Input = .{
    .name = "web",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0002b10",
};

const min_ready_ms = (records.RolloutPolicy{}).min_ready_ms;

/// What the fixture's store does to the next transaction that deletes a replica record (a
/// retirement), before it commits: the interleavings TLA+ gap 1 and the pause write race name.
const Interleave = enum { none, stop_kept, pause };

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    tap: sim_tap.TapStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,
    plane: control_plane.ControlPlane,
    api: controller.DecisionSource,
    interleave: Interleave = .none,
    /// The retirement `interleave` wrote before, and whether it committed.
    interleaved: ?[*]const store.Op = null,
    interleaved_committed: bool = false,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.tap = .{ .inner = self.memory.interface(), .context = self, .after = committed };
        self.tap.before = interleave_before;
        self.interleave = .none;
        self.interleaved = null;
        self.interleaved_committed = false;
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.plane = control_plane.ControlPlane.init(1);
        self.plane.check_i6 = true;
        self.api = .{ .instance = 0 };
        const node: records.Node = .{
            .name = "node1",
            .capacity = .{ .cpu_millis = 8000, .memory_bytes = 16 * 1024 * 1024 * 1024 },
        };
        try self.put(.{ .agent = "node1" }, records.node_key("node1").slice(), node);
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) controller.Context {
        _ = self.arena_state.reset(.retain_capacity);
        return .{
            .store = self.tap.interface(),
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

    fn put(self: *Fixture, role: writers.Role, key: []const u8, value: anytype) !void {
        const ctx = self.context();
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
    }

    /// Steps until a pass writes nothing; after each pass the agent deletes the reports of
    /// replicas whose records are gone (it stopped them).
    fn settle(self: *Fixture) !void {
        for (0..200) |_| {
            const ctx = self.context();
            const wake = try self.plane.reconcile(&ctx);
            try testing.expect(self.plane.mismatch == null);
            const reaped = try self.reap();
            if (wake.acted == 0 and !reaped) return;
            self.manual.advance(10);
        }
        return error.DidNotSettle;
    }

    fn reap(self: *Fixture) !bool {
        const ctx = self.context();
        const prefix = records.observed_prefix("node1");
        const query: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 100 };
        const page = try ctx.store.list(ctx.arena, query, &self.diag);
        var reaped = false;
        for (page.kvs) |kv| {
            const observed = try records.read(records.Observed, ctx.arena, kv, &self.diag);
            const key = records.replica_key(web.name, observed.replica);
            const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
            if (got.kv != null) continue;
            const op: store.Op = .{ .delete = kv.key };
            const role: writers.Role = .{ .agent = "node1" };
            const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &self.diag);
            try testing.expect(done.succeeded);
            reaped = true;
        }
        return reaped;
    }

    /// The service's replicas, ascending by number, on the fixture's arena.
    fn replicas(self: *Fixture) ![]const controller.Entry(records.Replica) {
        const ctx = self.context();
        const list = try controller.list_all(
            records.Replica,
            &ctx,
            records.replicas_prefix(web.name).slice(),
            null,
            constants.replicas_max,
        );
        return list.items;
    }

    /// Reports every replica of generation `generation` that has no report yet as `status`.
    fn report(self: *Fixture, generation: u64, status: records.ObservedStatus) !u32 {
        var ids: [constants.replicas_per_service_max][64]u8 = undefined;
        var lens: [constants.replicas_per_service_max]usize = undefined;
        var count: u32 = 0;
        for (try self.replicas()) |replica| {
            if (replica.rec.generation != generation) continue;
            @memcpy(ids[count][0..replica.rec.id.len], replica.rec.id);
            lens[count] = replica.rec.id.len;
            count += 1;
        }
        for (0..count) |index| {
            const id = ids[index][0..lens[index]];
            const observed: records.Observed = .{
                .replica = id,
                .node = "node1",
                .generation = generation,
                .status = status,
                .reported_at_ms = self.manual.ms,
            };
            const key = records.observed_key("node1", id);
            try self.put(.{ .agent = "node1" }, key.slice(), observed);
        }
        return count;
    }

    fn count_of(self: *Fixture, generation: u64) !u32 {
        var found: u32 = 0;
        for (try self.replicas()) |replica| {
            if (replica.rec.generation == generation) found += 1;
        }
        return found;
    }

    fn rollout(self: *Fixture) !records.Rollout {
        const ctx = self.context();
        const key = records.rollout_key(web.name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return records.read(records.Rollout, ctx.arena, got.kv.?, &self.diag);
    }

    /// Applies `web` at generation 1, runs its three replicas past `min_ready_ms`, then applies a
    /// new image (generation 2).
    fn roll(self: *Fixture) !void {
        try self.apply(web);
        try self.settle();
        try testing.expectEqual(@as(u32, 3), try self.report(1, .running));
        try self.settle();
        self.manual.advance(min_ready_ms);
        try self.settle();
        var next = web;
        next.image = "b3:9d20c4f1";
        next.request_id = "r-0002b11";
        try self.apply(next);
        try self.settle();
    }

    fn request(self: *Fixture, what: rollout_controller.Request) !rollout_controller.Outcome {
        const ctx = self.context();
        return rollout_controller.request(&ctx, &self.api, web.name, what);
    }

    fn committed(pointer: *anyopaque, request_done: ?store.TxnRequest, _: store.Revision) void {
        const self: *Fixture = @ptrCast(@alignCast(pointer));
        const done = request_done orelse return;
        const ops = self.interleaved orelse return;
        if (done.on_success.ptr == ops) self.interleaved_committed = true;
    }

    /// Writes `interleave` straight to the memory store, on an arena of its own (the
    /// transaction's request lives on the fixture's), once.
    fn interleave_before(pointer: *anyopaque, txn_request: store.TxnRequest) void {
        const self: *Fixture = @ptrCast(@alignCast(pointer));
        if (self.interleave == .none) return;
        const prefix = records.replicas_prefix(web.name);
        for (txn_request.on_success) |op| {
            if (op == .delete and std.mem.startsWith(u8, op.delete, prefix.slice())) break;
        } else return;
        const what = self.interleave;
        self.interleave = .none;
        self.interleaved = txn_request.on_success.ptr;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diag: Diag = undefined;
        diag.reset();
        const ctx: controller.Context = .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = arena.allocator(),
            .diag = &diag,
        };
        switch (what) {
            .none => unreachable,
            .stop_kept => stop_kept(&ctx, txn_request) catch @panic("stop_kept failed"),
            .pause => {
                const outcome = rollout_controller.request(&ctx, &self.api, web.name, .pause) catch
                    @panic("pause failed");
                assert(outcome == .done);
            },
        }
    }

    /// Reports `stopped` for the first generation-1 replica the transaction keeps.
    fn stop_kept(ctx: *const controller.Context, txn_request: store.TxnRequest) !void {
        const list = try controller.list_all(
            records.Replica,
            ctx,
            records.replicas_prefix(web.name).slice(),
            null,
            constants.replicas_max,
        );
        for (list.items) |replica| {
            if (replica.rec.generation != 1) continue;
            const deleted = for (txn_request.on_success) |op| {
                if (op == .delete and std.mem.eql(u8, op.delete, replica.kv.key)) break true;
            } else false;
            if (deleted) continue;
            const observed: records.Observed = .{
                .replica = replica.rec.id,
                .node = "node1",
                .generation = 1,
                .status = .stopped,
                .reported_at_ms = ctx.clock.now_ms(),
            };
            const key = records.observed_key("node1", replica.rec.id);
            const bytes = try records.encode(ctx.arena, observed, ctx.diag);
            const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
            const role: writers.Role = .{ .agent = "node1" };
            const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, ctx.diag);
            assert(done.succeeded);
            return;
        }
        unreachable; // The fixture keeps two old replicas while it retires one.
    }
};

test "a rolling update starts one new replica at a time and retires an old one once it is ready" {
    // Goal: the replica controller spends the rollout's budget (max_surge 1, max_unavailable 0):
    // never more than four live, never fewer than three ready. Method: report each new replica
    // running, wait `min_ready_ms`, and count the generations after every settle.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try testing.expectEqual(records.RolloutPhase.progressing, (try fixture.rollout()).phase);
    for (0..3) |round| {
        const old: u32 = @intCast(3 - round);
        try testing.expectEqual(old, try fixture.count_of(1));
        try testing.expectEqual(@as(u32, @intCast(round + 1)), try fixture.count_of(2));
        // Nothing more starts until the new replica is ready.
        try fixture.settle();
        try testing.expectEqual(@as(u32, @intCast(round + 1)), try fixture.count_of(2));
        _ = try fixture.report(2, .running);
        try fixture.settle();
        try testing.expectEqual(old, try fixture.count_of(1));
        fixture.manual.advance(min_ready_ms);
        try fixture.settle();
    }
    try testing.expectEqual(@as(u32, 0), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(2));
    const done = try fixture.rollout();
    try testing.expectEqual(records.RolloutPhase.complete, done.phase);
    try testing.expectEqual(@as(u64, 2), done.to);
}

test "a kept replica that stops between the read and the commit fails the retirement" {
    // Goal: TLA+ gap 1. A retirement compares the reports of the replicas it counts toward the
    // floor (`replicas - max_unavailable`, 3 here), so one that stops after the controller read
    // it fails the transaction and the next pass counts again. Method: the store reports a kept
    // old replica stopped just before the first retirement commits.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    fixture.interleave = .stop_kept;
    try fixture.settle();
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
}

test "a pause between the read and the commit fails the retirement" {
    // Goal: the replica controller's write compares `/rollouts/<service>`, so a pause that lands
    // between its read and its commit stops the retirement it judged on the active rollout (R4).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    fixture.interleave = .pause;
    try fixture.settle();
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
}

test "an apply over a rollout still progressing starts from the generation that completed" {
    // Goal: the supervisor's `from` rule. Generation 2 never became ready, so a rollout of
    // generation 3 started over it names generation 1, which ran, never 2.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try testing.expectEqual(@as(u64, 1), (try fixture.rollout()).from);
    var third = web;
    third.image = "b3:77e0aa12";
    third.request_id = "r-0002b12";
    try fixture.apply(third);
    try fixture.settle();
    const rollout = try fixture.rollout();
    try testing.expectEqual(@as(u64, 3), rollout.to);
    try testing.expectEqual(@as(u64, 1), rollout.from);
}

test "a stored rollout that contradicts itself is refused at decode with ZC-E0301" {
    // Goal: a record that would trip the plan's assertions (from not below to, an active phase
    // of the other reason, a refused rollback on a rollout that has not failed, a rollback from
    // generation 0) is malformed, never asserted on.
    // Method: real record text the controller wrote, edited, then read back and handed to a
    // controller pass.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    const ctx = fixture.context();
    const key = records.rollout_key(web.name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    const text = got.kv.?.value;
    const edits = [_][2][]const u8{
        .{ "\"from\":1,", "\"from\":2," },
        .{ "\"phase\":\"progressing\"", "\"phase\":\"rolling_back\"" },
        // A refused rollback marks only a failed rollout.
        .{ "\"phase\":\"progressing\"", "\"phase\":\"progressing\",\"rollback_refused\":true" },
    };
    for (edits) |edit| {
        try testing.expect(std.mem.indexOf(u8, text, edit[0]) != null);
        const bad = try std.mem.replaceOwned(u8, ctx.arena, text, edit[0], edit[1]);
        var kv = got.kv.?;
        kv.value = bad;
        fixture.diag.reset();
        const read = records.read(records.Rollout, ctx.arena, kv, &fixture.diag);
        try testing.expectError(error.Malformed, read);
        try testing.expectEqual(.E0301, fixture.diag.code.?);
    }
    const apply_text = "\"reason\":\"apply\"";
    try testing.expect(std.mem.indexOf(u8, text, apply_text) != null);
    const arena = ctx.arena;
    const reason = try std.mem.replaceOwned(u8, arena, text, apply_text, "\"reason\":\"rollback\"");
    const contradiction = try std.mem.replaceOwned(u8, arena, reason, "\"from\":1,", "\"from\":0,");
    fixture.diag.reset();
    var kv = got.kv.?;
    kv.value = contradiction;
    const read = records.read(records.Rollout, arena, kv, &fixture.diag);
    try testing.expectError(error.Malformed, read);
    // A pass over the stored record refuses it and asserts nothing.
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = contradiction } };
    const role: writers.Role = .rollout_controller;
    fixture.diag.reset();
    const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &fixture.diag);
    try testing.expect(done.succeeded);
    fixture.diag.reset();
    const pass_ctx = fixture.context();
    if (fixture.plane.reconcile(&pass_ctx)) |_| {} else |_| {}
}

test "a pause starts nothing more until a resume, and a second pause changes nothing" {
    // Goal: R4 through the API's handler (slice 11 calls `request`). Method: pause right after
    // the first new replica starts, make it ready, and see no second one until the resume.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    const paused = try fixture.request(.pause);
    try testing.expectEqual(records.RolloutPhase.paused, paused.done);
    const again = try fixture.request(.pause);
    try testing.expectEqual(records.RolloutPhase.paused, again.unchanged);
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);

    const resumed = try fixture.request(.resume_rollout);
    try testing.expectEqual(records.RolloutPhase.progressing, resumed.done);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(2));
}

test "an old replica that dies during a pause is replaced at its own generation" {
    // Goal: R4 allows a same-generation replacement only (TLA+ review): an old replica lost while
    // paused comes back old, not as a start of the new generation. Method: pause after the first
    // new replica starts, report one old replica stopped, and count the generations.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.request(.pause)).done);
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    const old = (try fixture.replicas())[0];
    try testing.expectEqual(@as(u64, 1), old.rec.generation);
    const observed: records.Observed = .{
        .replica = old.rec.id,
        .node = "node1",
        .generation = 1,
        .status = .stopped,
        .reported_at_ms = fixture.manual.ms,
    };
    const key = records.observed_key("node1", old.rec.id);
    try fixture.put(.{ .agent = "node1" }, key.slice(), observed);
    try fixture.settle();
    var found_old = false;
    for (try fixture.replicas()) |replica| {
        try testing.expect(!std.mem.eql(u8, replica.rec.id, old.rec.id));
        if (replica.rec.generation == 1) found_old = true;
    }
    try testing.expect(found_old);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
}

test "a held new replica fails the rollout with ZC-E0304 and nothing more starts" {
    // Goal: `hold_failed_replica` feeds the rollout's failure. Method: the first new replica's
    // start fails by the user's fault; the rollout fails, its old replicas stay, and a resume is
    // refused (a failed rollout is not continued; slice 8 adds the rollback).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    var collector: Diag = undefined;
    collector.reset();
    collector.raise(.E0206);
    collector.cause("digest b3:9d20c4f1 is not in this node's store", .{});
    var finished: records.Diagnostic = undefined;
    diag_mod.to_diagnostic(&finished, &collector);
    const ctx = fixture.context();
    const raw = try records.diagnostic_raw(ctx.arena, &finished, &fixture.diag);
    const text = try testing.allocator.dupe(u8, raw.text);
    defer testing.allocator.free(text);
    const new = (try fixture.replicas())[3];
    try testing.expectEqual(@as(u64, 2), new.rec.generation);
    const id = try testing.allocator.dupe(u8, new.rec.id);
    defer testing.allocator.free(id);
    const observed: records.Observed = .{
        .replica = id,
        .node = "node1",
        .generation = 2,
        .status = .stopped,
        .exit = .{ .kind = .start_failed },
        .diagnostic = .{ .text = text },
        .reported_at_ms = fixture.manual.ms,
    };
    try fixture.put(.{ .agent = "node1" }, records.observed_key("node1", id).slice(), observed);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(records.RolloutPhase.failed, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    try testing.expect(try fixture.request(.resume_rollout) == .refused);
    try testing.expect(fixture.diag.code.? == .E0129);
    fixture.diag.reset();
}

test "a pause of a service with no rollout is refused with ZC-E0129" {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try testing.expect(try fixture.request(.pause) == .refused);
    try testing.expect(fixture.diag.code.? == .E0129);
    fixture.diag.reset();
    try fixture.apply(web);
    try fixture.settle();
    try testing.expect(try fixture.request(.resume_rollout) == .refused);
    try testing.expect(fixture.diag.code.? == .E0129);
    fixture.diag.reset();
}

comptime {
    assert(min_ready_ms > 0);
}
