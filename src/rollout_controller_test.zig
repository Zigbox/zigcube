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
const rollback = @import("rollback.zig");
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

/// A generation 2 of `web` that differs from it in every field a rollback restores: image,
/// command, env, limits and health.
const broken: apply_mod.Input = .{
    .name = "web",
    .image = "b3:9d20c4f1",
    .replicas = 3,
    .command = &.{ "sh", "-c", "exec ./serve --v2" },
    .env = &.{.{ "MODE", "v2" }},
    .limits = .{ .cpu_millis = 200, .memory_bytes = 64 * 1024 * 1024 },
    .source = "ghcr.io/zigbox/web@sha256:" ++
        "9d20c4f19d20c4f19d20c4f19d20c4f19d20c4f19d20c4f19d20c4f19d20c4f1",
    .health = .{
        .command = &.{ "check", "--v2" },
        .interval_ms = 5_000,
        .timeout_ms = 1_000,
        .failure_threshold = 2,
        .success_threshold = 1,
    },
    .applied_by = "alex@laptop",
    .request_id = "r-0002b11",
};

/// What the fixture's store does to the next transaction that deletes a replica record (a
/// retirement), before it commits: the interleavings TLA+ gap 1 and the pause write race name.
/// `pause_create` pauses before the next transaction that creates replicas and deletes none;
/// `stop_last` stops the kept replica the floor counts last (the newest).
/// `apply_rollback` and `pause_rollback` apply `third` or pause before the next transaction that
/// writes the service (the automatic rollback's).
const Interleave = enum {
    none,
    stop_kept,
    stop_last,
    pause,
    pause_create,
    apply_rollback,
    pause_rollback,
};

/// A user's generation 3 of `web`.
const third: apply_mod.Input = .{
    .name = "web",
    .image = "b3:77e0aa12",
    .replicas = 3,
    .command = web.command,
    .applied_by = "alex@laptop",
    .request_id = "r-0002b12",
};

/// The health check of the tests that roll a checked service.
const checked_health: records.Health = .{
    .command = &.{ "test", "-f", "/tmp/ready" },
    .interval_ms = 1000,
    .timeout_ms = 1000,
    .failure_threshold = 2,
    .success_threshold = 1,
};

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    tap: sim_tap.TapStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,
    plane: control_plane.ControlPlane,
    api: controller.DecisionSource,
    interleave: Interleave = .none,
    /// The write `interleave` wrote before, and whether it committed. A write is known by the
    /// decision key it creates (a retry makes a new decision; its arena may reuse the address).
    interleaved: ?[*]const store.Op = null,
    interleaved_decision: [128]u8 = undefined,
    interleaved_decision_len: u8 = 0,
    interleaved_committed: bool = false,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.tap = .{ .inner = self.memory.interface(), .context = self, .after = committed };
        self.tap.before = interleave_before;
        self.interleave = .none;
        self.interleaved = null;
        self.interleaved_decision_len = 0;
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
        return self.report_health(generation, status, null);
    }

    /// `report`, with the health check's verdict (absent for a replica without a check).
    fn report_health(
        self: *Fixture,
        generation: u64,
        status: records.ObservedStatus,
        health: ?records.HealthState,
    ) !u32 {
        var ids: [constants.replicas_per_service_max][64]u8 = undefined;
        var lens: [constants.replicas_per_service_max]usize = undefined;
        var count: u32 = 0;
        for (try self.replicas()) |replica| {
            if (replica.rec.generation != generation) continue;
            @memcpy(ids[count][0..replica.rec.id.len], replica.rec.id);
            lens[count] = replica.rec.id.len;
            count += 1;
        }
        const failures: u32 = @intFromBool(health == .unhealthy);
        for (0..count) |index| {
            const id = ids[index][0..lens[index]];
            const observed: records.Observed = .{
                .replica = id,
                .node = "node1",
                .generation = generation,
                .status = status,
                .reported_at_ms = self.manual.ms,
                .health = health,
                .health_failures = if (health) |_| failures else null,
                .last_probe_exit = if (health) |_| @intCast(failures) else null,
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
        var next = web;
        next.image = "b3:9d20c4f1";
        next.request_id = "r-0002b11";
        try self.roll_to(next);
    }

    /// `roll` with `next` as generation 2.
    fn roll_to(self: *Fixture, next: apply_mod.Input) !void {
        try self.apply(web);
        try self.settle();
        try testing.expectEqual(@as(u32, 3), try self.report(1, .running));
        try self.settle();
        self.manual.advance(min_ready_ms);
        try self.settle();
        try self.apply(next);
        try self.settle();
    }

    /// Rolls `web` to generation 2 and fails its first new replica's start by the user's fault
    /// (ZC-E0304). `.roll_back`: the controller then rolls back to generation 1 as generation 3.
    /// `.refuse`: generation 1's history record is deleted first, so the rollback is refused
    /// (ZC-E0128) and the rollout stays failed with three old replicas and the held new one.
    /// With `.roll_back`, generation 2 is `broken`, which differs from `web` in every field a
    /// rollback restores.
    fn fail(self: *Fixture, then: Then) !void {
        if (then == .roll_back) try self.roll_to(broken) else try self.roll();
        if (then == .refuse) try self.forget(1);
        try self.fail_start(2);
        switch (then) {
            .refuse => {
                const failed = try self.rollout();
                try testing.expectEqual(records.RolloutPhase.failed, failed.phase);
                try testing.expectEqual(@as(?bool, true), failed.rollback_refused);
            },
            .roll_back => try testing.expectEqual(@as(u64, 3), (try self.service()).generation),
        }
    }

    /// Fails the start of the first replica of `generation` by the user's fault (ZC-E0304), and
    /// steps past `min_ready_ms`.
    fn fail_start(self: *Fixture, generation: u64) !void {
        var collector: Diag = undefined;
        collector.reset();
        collector.raise(.E0206);
        collector.cause("digest b3:9d20c4f1 is not in this node's store", .{});
        var finished: records.Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        const ctx = self.context();
        const raw = try records.diagnostic_raw(ctx.arena, &finished, &self.diag);
        const text = try testing.allocator.dupe(u8, raw.text);
        defer testing.allocator.free(text);
        const new = for (try self.replicas()) |replica| {
            if (replica.rec.generation == generation) break replica;
        } else return error.NoNewReplica;
        const id = try testing.allocator.dupe(u8, new.rec.id);
        defer testing.allocator.free(id);
        const observed: records.Observed = .{
            .replica = id,
            .node = "node1",
            .generation = generation,
            .status = .stopped,
            .exit = .{ .kind = .start_failed },
            .diagnostic = .{ .text = text },
            .reported_at_ms = self.manual.ms,
        };
        try self.put(.{ .agent = "node1" }, records.observed_key("node1", id).slice(), observed);
        try self.settle();
        self.manual.advance(min_ready_ms);
        try self.settle();
    }

    const Then = enum { roll_back, refuse };

    /// Deletes `/history/web/<generation>`, as the API (which owns the history).
    fn forget(self: *Fixture, generation: u64) !void {
        const ctx = self.context();
        const key = records.history_key(web.name, generation);
        const op: store.Op = .{ .delete = key.slice() };
        const done = try writers.txn(ctx.store, .api, .{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
    }

    fn service(self: *Fixture) !records.Service {
        const ctx = self.context();
        const key = records.service_key(web.name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return records.read(records.Service, ctx.arena, got.kv.?, &self.diag);
    }

    fn history(self: *Fixture, generation: u64) !records.History {
        const ctx = self.context();
        const key = records.history_key(web.name, generation);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        return records.read(records.History, ctx.arena, got.kv.?, &self.diag);
    }

    /// The decisions whose action is `action` and whose reason holds `text`.
    fn decisions(self: *Fixture, action: []const u8, text: []const u8) !u32 {
        const ctx = self.context();
        const list = try controller.list_all(
            records.Decision,
            &ctx,
            records.prefix_decisions,
            null,
            4096,
        );
        var found: u32 = 0;
        for (list.items) |entry| {
            if (!std.mem.eql(u8, entry.rec.action, action)) continue;
            if (std.mem.indexOf(u8, entry.rec.reason, text) != null) found += 1;
        }
        return found;
    }

    fn request(self: *Fixture, what: rollout_controller.Request) !rollout_controller.Outcome {
        const ctx = self.context();
        return rollout_controller.request(&ctx, &self.api, web.name, what);
    }

    fn committed(pointer: *anyopaque, request_done: ?store.TxnRequest, _: store.Revision) void {
        const self: *Fixture = @ptrCast(@alignCast(pointer));
        const done = request_done orelse return;
        if (self.interleaved == null) return;
        const decision = self.interleaved_decision[0..self.interleaved_decision_len];
        assert(decision.len > 0);
        for (done.compares) |compare| {
            if (std.mem.eql(u8, compare.key, decision)) self.interleaved_committed = true;
        }
    }

    /// Writes `interleave` straight to the memory store, on an arena of its own (the
    /// transaction's request lives on the fixture's), once.
    fn interleave_before(pointer: *anyopaque, txn_request: store.TxnRequest) void {
        const self: *Fixture = @ptrCast(@alignCast(pointer));
        if (self.interleave == .none) return;
        if (!interleaved_here(self.interleave, txn_request)) return;
        const what = self.interleave;
        self.interleave = .none;
        self.interleaved = txn_request.on_success.ptr;
        for (txn_request.compares) |compare| {
            if (!std.mem.startsWith(u8, compare.key, "/decisions/")) continue;
            assert(compare.key.len <= self.interleaved_decision.len);
            @memcpy(self.interleaved_decision[0..compare.key.len], compare.key);
            self.interleaved_decision_len = @intCast(compare.key.len);
            break;
        }
        assert(self.interleaved_decision_len > 0);
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
            .stop_kept, .stop_last => stop_kept(&ctx, txn_request, what == .stop_last) catch
                @panic("stop_kept failed"),
            .pause, .pause_create, .pause_rollback => {
                const outcome = rollout_controller.request(&ctx, &self.api, web.name, .pause) catch
                    @panic("pause failed");
                assert(outcome == .done);
            },
            .apply_rollback => {
                const result = apply_mod.apply(&ctx, &self.api, third) catch
                    @panic("apply failed");
                assert(result == .written);
            },
        }
    }

    /// Whether `what` interleaves before this transaction: one that deletes a replica of `web`,
    /// or for `pause_create` one that creates replicas of it and deletes none.
    fn interleaved_here(what: Interleave, txn_request: store.TxnRequest) bool {
        if (what == .apply_rollback or what == .pause_rollback) {
            const key = records.service_key(web.name);
            for (txn_request.on_success) |op| {
                if (op == .put and std.mem.eql(u8, op.put.key, key.slice())) return true;
            }
            return false;
        }
        const prefix = records.replicas_prefix(web.name);
        var deletes = false;
        var creates = false;
        for (txn_request.on_success) |op| switch (op) {
            .delete => |key| deletes = deletes or std.mem.startsWith(u8, key, prefix.slice()),
            .put => |item| creates = creates or std.mem.startsWith(u8, item.key, prefix.slice()),
        };
        if (what == .pause_create) return creates and !deletes;
        return deletes;
    }

    /// Reports `stopped` for the first generation-1 replica the transaction keeps, or with
    /// `last` for the last replica it keeps, of any generation.
    fn stop_kept(
        ctx: *const controller.Context,
        txn_request: store.TxnRequest,
        last: bool,
    ) !void {
        const list = try controller.list_all(
            records.Replica,
            ctx,
            records.replicas_prefix(web.name).slice(),
            null,
            constants.replicas_max,
        );
        for (0..list.items.len) |index| {
            const replica = list.items[if (last) list.items.len - 1 - index else index];
            if (!last and replica.rec.generation != 1) continue;
            const deleted = for (txn_request.on_success) |op| {
                if (op == .delete and std.mem.eql(u8, op.delete, replica.kv.key)) break true;
            } else false;
            if (deleted) continue;
            const observed: records.Observed = .{
                .replica = replica.rec.id,
                .node = "node1",
                .generation = replica.rec.generation,
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

test "a replica with a health check is ready only while its report says healthy" {
    // Goal: the brief's "a replica counts only when its health check passes" (demo-c3 step 3).
    // A new replica that runs but is `unknown` or `unhealthy` is never ready, however long it
    // runs, so no old replica is retired for it; once it reports `healthy`, `min_ready_ms`
    // counts from then. Method: roll a service with a check to a new image, report the new
    // replica running with each verdict, and count the old generation after each wait.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.health = .{
        .command = &.{ "test", "-f", "/tmp/ready" },
        .interval_ms = 1000,
        .timeout_ms = 1000,
        .failure_threshold = 2,
        .success_threshold = 1,
    };
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b11";
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    for ([_]records.HealthState{ .unknown, .unhealthy }) |verdict| {
        _ = try fixture.report_health(2, .running, verdict);
        try fixture.settle();
        fixture.manual.advance(min_ready_ms + 100);
        try fixture.settle();
        try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
        try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    }
    _ = try fixture.report_health(2, .running, .healthy);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms / 2);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    fixture.manual.advance(min_ready_ms / 2 + 100);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
}

test "an unhealthy replica of a failed rollout is retired as not ready by the rollback" {
    // Goal: demo-c3 step 3. A new replica that runs but never passes its check fails the
    // rollout at `ready_timeout_ms`; the rollback retires it within `budget.retire_unready`
    // (the replica controller agrees it is not ready) and ends on the old spec. Method: roll a
    // checked service, report the new replica running and unhealthy, pass the timeout, then
    // bring the rollback's replicas up healthy one by one.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.health = .{
        .command = &.{ "test", "-f", "/tmp/ready" },
        .interval_ms = 1000,
        .timeout_ms = 1000,
        .failure_threshold = 2,
        .success_threshold = 1,
    };
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b11";
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.report_health(2, .running, .unhealthy));
    try fixture.settle();
    fixture.manual.advance((records.RolloutPolicy{}).ready_timeout_ms + 100);
    try fixture.settle();
    try testing.expectEqual(@as(u64, 3), (try fixture.service()).generation);
    for (0..3) |_| {
        _ = try fixture.report_health(3, .running, .healthy);
        try fixture.settle();
        fixture.manual.advance(min_ready_ms);
        try fixture.settle();
    }
    try testing.expectEqual(@as(u32, 0), try fixture.count_of(2));
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(3));
    try testing.expectEqual(records.RolloutPhase.complete, (try fixture.rollout()).phase);
}

test "an agent restart's unknown keeps old replicas ready and new ones not ready" {
    // Goal: docs/decisions/2026-11-15-c3-rollout-health-gate.md. An agent restart reports every
    // replica `unknown` until it probes again. An old replica last seen healthy keeps counting
    // toward the floor (it is not free to retire as unready), and a new replica counts as ready
    // only on `healthy`. Method: roll a checked service (surge 1, unavailable 0); report the old
    // replicas `unknown` before any new one is ready, then the new one healthy and `unknown`.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.health = .{
        .command = &.{ "test", "-f", "/tmp/ready" },
        .interval_ms = 1000,
        .timeout_ms = 1000,
        .failure_threshold = 2,
        .success_threshold = 1,
    };
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b12";
    try fixture.apply(checked);
    try fixture.settle();
    // The agent restarts: the old replicas are `unknown`. None is retired.
    _ = try fixture.report_health(1, .running, .unknown);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    // The new replica runs healthy for min_ready_ms, then is `unknown`: still none retired.
    _ = try fixture.report_health(2, .running, .healthy);
    try fixture.settle();
    _ = try fixture.report_health(2, .running, .unknown);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    // Healthy again: it is ready at once (its time was kept), and one old replica is retired.
    _ = try fixture.report_health(2, .running, .healthy);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
}

test "a never-healthy replica of a failed rollout whose checks never settle is retired" {
    // Goal: PR #261 re-review MUST. A release whose checks never settle (every probe refused,
    // ZC-E0516) reports `unknown` forever. Its rollout fails at `ready_timeout_ms`, and the
    // rollback must still end: the stale `unknown` replica is running to both controllers, so it
    // is retired within `budget.retire` once the rollback's replicas are ready. Before the fix
    // the rollout controller counted it unready (`retire_unready`) and the replica controller
    // running (`retire` only), so the rollback stayed `rolling_back`. Method: as "an unhealthy
    // replica of a failed rollout ...", with the new replica `unknown` instead of `unhealthy`.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.health = checked_health;
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b13";
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.report_health(2, .running, .unknown));
    try fixture.settle();
    fixture.manual.advance((records.RolloutPolicy{}).ready_timeout_ms + 100);
    try fixture.settle();
    try testing.expectEqual(@as(u64, 3), (try fixture.service()).generation);
    for (0..40) |_| {
        _ = try fixture.report_health(3, .running, .healthy);
        try fixture.settle();
        fixture.manual.advance(10_000);
        try fixture.settle();
    }
    try testing.expectEqual(@as(u32, 0), try fixture.count_of(2));
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(3));
    try testing.expectEqual(records.RolloutPhase.complete, (try fixture.rollout()).phase);
}

test "a new replica unknown after healthy is not ready to the rollout controller" {
    // Goal: PR #261 re-review SHOULD, the rollout controller's half of the `unknown` rule
    // (`!(fresh and held_over)` in `view`). A new replica that ran healthy for `min_ready_ms`
    // and is then `unknown` (an agent restart) is not counted ready by the rollout record, so
    // the rollout does not complete on replicas nobody knows are healthy. Method: roll a checked
    // service of one replica; the new replica runs healthy, then `unknown` for `min_ready_ms`.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.replicas = 1;
    checked.health = checked_health;
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b14";
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.report_health(2, .running, .healthy));
    try fixture.settle();
    _ = try fixture.report_health(2, .running, .unknown);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    const rollout = try fixture.rollout();
    try testing.expectEqual(@as(u32, 0), rollout.ready_new);
    try testing.expect(rollout.phase != .complete);
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(1));
}

test "an old replica unknown after an agent restart counts toward the replica floor" {
    // Goal: PR #261 re-review SHOULD, the replica controller's half of the `unknown` rule
    // (`running_healthy`: a stale `unknown` replica runs). A budget that retires one old replica
    // was stored while the new replica was ready; the new replica then turns unhealthy and the
    // agent restarts (old replicas `unknown`). The replica controller, run alone over that budget,
    // must keep all three old replicas: they are running and the floor (3) allows none to go. If
    // it counted them not running, it would retire one as unready, without the floor's check.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    var checked = web;
    checked.health = checked_health;
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.report_health(1, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    checked.image = "b3:9d20c4f1";
    checked.request_id = "r-0002b15";
    try fixture.apply(checked);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.report_health(2, .running, .healthy));
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try rollouts_only(&fixture);
    try testing.expectEqual(@as(u32, 1), (try fixture.rollout()).budget.retire);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    _ = try fixture.report_health(2, .running, .unhealthy);
    _ = try fixture.report_health(1, .running, .unknown);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
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

test "the kept replica the floor counts last also fails the retirement when it stops" {
    // Goal: Review B SHOULD 5 (M6). The floor compares all `replicas - max_unavailable` kept
    // running replicas, the last one too: the new replica, stopped before the commit, fails it.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    fixture.interleave = .stop_last;
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

test "a pause between the read and the commit fails a replacement at the new spec" {
    // Goal: seam b. Every write of the replica controller compares `/rollouts/<service>` as it
    // read it, not only a retirement: a replacement it judged on the active rollout (a dead old
    // replica comes back at the new spec) fails if a pause lands before the commit, and the next
    // pass replaces it at its own generation (R4). Method: an old replica stops while the rollout
    // progresses; the pause lands inside the replacement's transaction.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try testing.expectEqual(records.RolloutPhase.progressing, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    const old = (try fixture.replicas())[0];
    try testing.expectEqual(@as(u64, 1), old.rec.generation);
    const old_id = try testing.allocator.dupe(u8, old.rec.id);
    defer testing.allocator.free(old_id);
    const observed: records.Observed = .{
        .replica = old_id,
        .node = "node1",
        .generation = 1,
        .status = .stopped,
        .reported_at_ms = fixture.manual.ms,
    };
    const key = records.observed_key("node1", old_id);
    try fixture.put(.{ .agent = "node1" }, key.slice(), observed);
    fixture.interleave = .pause;
    try fixture.settle();
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
    for (try fixture.replicas()) |replica| {
        try testing.expect(!std.mem.eql(u8, replica.rec.id, old_id));
    }
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
}

test "an apply over a rollout still progressing starts from the generation that completed" {
    // Goal: the supervisor's `from` rule. Generation 2 never became ready, so a rollout of
    // generation 3 started over it names generation 1, which ran, never 2.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try testing.expectEqual(@as(u64, 1), (try fixture.rollout()).from);
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
    // start fails by the user's fault and its rollback is refused; the rollout fails, its old
    // replicas stay, and a resume is refused (a failed rollout is not continued).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.fail(.refuse);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
    try testing.expect(try fixture.request(.resume_rollout) == .refused);
    try testing.expect(fixture.diag.code.? == .E0129);
    fixture.diag.reset();
}

test "C3 slice 8: a failed rollout rolls back through the API's handler (O3)" {
    // Goal: the automatic rollback. Method: fail generation 2; the controller applies generation
    // 1's spec as generation 3, applied by `rollout-controller`, with an `auto_rollback` history
    // record and a `rollback` decision caused by the failure's, then rolls onto it.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.fail(.roll_back);
    // Generation 2 (`broken`) differs from 1 in every restored field: each must be 1's again.
    const service = try fixture.service();
    try expect_web_spec(service);
    try testing.expectEqualStrings("rollout-controller", service.applied_by);
    const record = try fixture.history(3);
    try expect_web_spec(record);
    try testing.expectEqual(records.HistoryReason.auto_rollback, record.reason);
    try testing.expectEqual(@as(?u64, 1), record.restores);
    try testing.expectEqual(@as(u32, 1), try fixture.decisions("rollback", "ZC-W0305"));
    const rollout = try fixture.rollout();
    try testing.expectEqual(@as(u64, 3), rollout.to);
    try testing.expectEqual(records.RolloutReason.rollback, rollout.reason);
    // Generation 3 runs generation 1's spec: its replicas come up one by one (max_surge 1) and
    // the rollout completes.
    for (0..3) |_| {
        _ = try fixture.report(3, .running);
        try fixture.settle();
        fixture.manual.advance(min_ready_ms);
        try fixture.settle();
    }
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(3));
    for (try fixture.replicas()) |replica| {
        if (replica.rec.generation == 3) try expect_web_spec(replica.rec);
    }
    try testing.expectEqual(records.RolloutPhase.complete, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u64, 3), (try fixture.service()).generation);
}

test "C3 slice 8: a refused automatic rollback is asked again after pause, resume, new failure" {
    // Goal: docs/decisions/2026-11-15-c3-pause-clears-rollback-refused.md. A refusal is recorded
    // once and not asked again while the rollout stays failed; a pause clears the mark, and once
    // resumed and failed again the controller asks the handler again (refused again here).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.fail(.refuse);
    const refusal = "the automatic rollback of web to generation 1 was refused";
    try testing.expectEqual(@as(u32, 1), try fixture.decisions("rollout_fail", refusal));
    fixture.manual.advance(10 * min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 1), try fixture.decisions("rollout_fail", refusal));
    try testing.expect(try fixture.request(.pause) == .done);
    try testing.expect((try fixture.rollout()).rollback_refused != true);
    try testing.expect(try fixture.request(.resume_rollout) == .done);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    const failed = try fixture.rollout();
    try testing.expectEqual(records.RolloutPhase.failed, failed.phase);
    try testing.expectEqual(@as(?bool, true), failed.rollback_refused);
    try testing.expectEqual(@as(u32, 2), try fixture.decisions("rollout_fail", refusal));
    try testing.expectEqual(@as(u64, 2), (try fixture.service()).generation);
}

test "C3 slice 8: an automatic rollback restores the generation that completed, not the newest" {
    // Goal: `from` (docs/decisions/2026-11-14-c3-rollout-from-rule.md). Generation 2 never became
    // ready when generation 3 was applied over it; 3 fails, and the rollback must restore 1, the
    // newest generation whose rollout completed, never 2.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    try fixture.apply(third);
    try fixture.settle();
    try testing.expectEqual(@as(u64, 1), (try fixture.rollout()).from);
    try fixture.fail_start(3);
    const service = try fixture.service();
    try testing.expectEqual(@as(u64, 4), service.generation);
    try testing.expectEqualStrings(web.image, service.image);
    const record = try fixture.history(4);
    try testing.expectEqual(records.HistoryReason.auto_rollback, record.reason);
    try testing.expectEqual(@as(?u64, 1), record.restores);
}

test "C3 slice 8: a user's apply before the automatic rollback commits wins (R8)" {
    // Goal: the compare on the service key. Method: the user applies generation 3 inside the
    // rollback's transaction, after the handler read the service: the rollback must write
    // nothing, and generation 3 is the user's.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    fixture.interleave = .apply_rollback;
    try fixture.fail_start(2);
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    const service = try fixture.service();
    try testing.expectEqual(@as(u64, 3), service.generation);
    try testing.expectEqualStrings(third.image, service.image);
    try testing.expectEqual(records.HistoryReason.apply, (try fixture.history(3)).reason);
    try testing.expectEqual(@as(u32, 0), try fixture.decisions("rollback", "ZC-W0305"));
}

test "C3 slice 8: a user's pause before the automatic rollback commits wins (R8)" {
    // Goal: the compare on the rollout record. Method: the user pauses the failed rollout inside
    // the rollback's transaction: the rollback must write nothing, and the rollout stays paused.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    fixture.interleave = .pause_rollback;
    try fixture.fail_start(2);
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    fixture.manual.advance(10 * min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u64, 2), (try fixture.service()).generation);
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u32, 0), try fixture.decisions("rollback", "ZC-W0305"));
}

test "C3 slice 8: an automatic rollback whose pass read an older service writes nothing" {
    // Goal: the handler's early compare of `Expect.service_revision`. The handler reads the
    // service itself; an apply between the controller's snapshot and that read must still win,
    // though the batch's compares (taken from the handler's read) would match.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    const ctx = fixture.context();
    const service_key = records.service_key(web.name);
    const read = (try ctx.store.get(ctx.arena, service_key.slice(), null, &fixture.diag)).kv.?;
    const read_revision = read.mod_revision;
    const rollout_key = records.rollout_key(web.name);
    const rollout_kv =
        (try ctx.store.get(ctx.arena, rollout_key.slice(), null, &fixture.diag)).kv.?;
    const rollout_revision = rollout_kv.mod_revision;
    try fixture.apply(third);
    const after = fixture.context();
    const result = try rollback.rollback(&after, &fixture.api, .{
        .name = web.name,
        .to = 1,
        .reason = .auto_rollback,
        .applied_by = rollback.controller_applied_by,
        .request_id = "r-0002b13",
        .expect = .{
            .service_revision = read_revision,
            .rollout_key = rollout_key.slice(),
            .rollout_revision = rollout_revision,
            .failed_decision = "",
        },
    });
    try testing.expect(result == .conflict);
    try testing.expectEqual(@as(u64, 3), (try fixture.service()).generation);
}

/// Whether a record's spec is `web`'s (generation 1), not `broken`'s.
fn expect_web_spec(record: anytype) !void {
    try testing.expectEqualStrings(web.image, record.image);
    try testing.expectEqualStrings(web.source, record.source);
    try testing.expect(records.strings_equal(web.command, record.command));
    try testing.expect(records.pairs_equal(web.env, record.env));
    try testing.expectEqual(web.limits, record.limits);
    try testing.expect(record.health == null);
}

/// Applies `web` again at generation 2's spec with `replicas` replicas (no new generation).
fn rescale(fixture: *Fixture, replicas: u32) !void {
    var next = web;
    next.image = "b3:9d20c4f1";
    next.replicas = replicas;
    next.request_id = "r-0002b13";
    try fixture.apply(next);
}

test "a pause between the read and the commit fails a scale-up of a failed rollout" {
    // Goal: seam b on `scale_up`. A failed rollout's service scaled up creates replicas past
    // what it ran; a pause that lands before the commit must fail it, since a paused rollout
    // starts nothing (R4). Method: the pause lands inside the creating transaction.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.fail(.refuse);
    try rescale(&fixture, 5);
    fixture.interleave = .pause_create;
    try fixture.settle();
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
}

test "a pause between the read and the commit fails a scale-down of a failed rollout" {
    // Goal: seam b on `scale_down`: what it removes rests on the rollout's phase as read (a
    // halted rollout keeps `max_surge` more), so a pause that lands first fails the commit.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.fail(.refuse);
    try rescale(&fixture, 1);
    fixture.interleave = .pause;
    try fixture.settle();
    try testing.expect(fixture.interleaved != null);
    try testing.expect(!fixture.interleaved_committed);
    try testing.expectEqual(records.RolloutPhase.paused, (try fixture.rollout()).phase);
}

test "a rollout record that does not decode halts its service only (RB-S2)" {
    // Goal: an undecodable `/rollouts/web` (ZC-E0301) fails the rollout pass, which runs before
    // the replicas' controller; that must not stop the replicas of other services, and `web`'s
    // own replicas must not move on a rollout nobody can read. Method: corrupt the record, apply
    // a second service, and step the whole plane: each step returns the rollout pass's error
    // and the second service still gets its replicas.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    const ctx = fixture.context();
    const key = records.rollout_key(web.name);
    const bad = [_]store.Op{.{ .put = .{ .key = key.slice(), .value = "{no" } }};
    const role: writers.Role = .rollout_controller;
    const done = try writers.txn(ctx.store, role, .{ .on_success = &bad }, &fixture.diag);
    try testing.expect(done.succeeded);
    var other = web;
    other.name = "hello";
    other.replicas = 2;
    try fixture.apply(other);
    var failed: u32 = 0;
    for (0..6) |_| {
        const again = fixture.context();
        _ = fixture.plane.reconcile(&again) catch {
            try testing.expectEqual(.E0301, fixture.diag.code.?);
            failed += 1;
            fixture.diag.reset();
        };
        fixture.manual.advance(10);
    }
    try testing.expectEqual(@as(u32, 6), failed);
    const list_ctx = fixture.context();
    const hello = try controller.list_all(
        records.Replica,
        &list_ctx,
        records.replicas_prefix("hello").slice(),
        null,
        constants.replicas_max,
    );
    try testing.expectEqual(@as(usize, 2), hello.items.len);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
}

/// Rewrites `/rollouts/web` as `edit` changes it, in one arena, as the rollout controller.
fn rewrite_rollout(fixture: *Fixture, edit: *const fn (*records.Rollout) void) !void {
    const ctx = fixture.context();
    const key = records.rollout_key(web.name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var rec = try records.read(records.Rollout, ctx.arena, got.kv.?, &fixture.diag);
    edit(&rec);
    const bytes = try records.encode(ctx.arena, rec, &fixture.diag);
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
    const role: writers.Role = .rollout_controller;
    const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &fixture.diag);
    try testing.expect(done.succeeded);
}

/// Sets the service's replica counter to `next`, as the replica controller.
fn set_counter(fixture: *Fixture, next: u64) !void {
    const key = records.replica_numbers_key(web.name);
    try fixture.put(.replica_controller, key.slice(), records.ReplicaNumber{ .next = next });
}

fn counter(fixture: *Fixture) !u64 {
    const ctx = fixture.context();
    const key = records.replica_numbers_key(web.name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    return (try records.read(records.ReplicaNumber, ctx.arena, got.kv.?, &fixture.diag)).next;
}

/// One pass of the rollout controller alone, then of the replicas' controller alone: the budget
/// the second spends is the one the first stored (or a test's rewrite of it).
fn rollouts_only(fixture: *Fixture) !void {
    const ctx = fixture.context();
    _ = try fixture.plane.rollouts.reconcile(&ctx);
}

fn replicas_only(fixture: *Fixture) !void {
    const ctx = fixture.context();
    _ = try fixture.plane.replicas.reconcile(&ctx);
}

/// Rolls to generation 2 and makes its first new replica ready, then stores the budget that
/// retires one old replica, and spends nothing of it.
fn ready_to_retire(fixture: *Fixture) !void {
    try fixture.roll();
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try rollouts_only(fixture);
    const rollout = try fixture.rollout();
    try testing.expectEqual(@as(u32, 1), rollout.budget.retire);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
}

fn budget_revision_old(rollout: *records.Rollout) void {
    rollout.budget_revision = 1;
}

fn retire_two(rollout: *records.Rollout) void {
    rollout.budget.retire = 2;
}

test "a budget computed on an older service spends nothing (stale budget, revision)" {
    // Goal: Review A MUST 2. The replicas' controller run alone over a budget whose revision is
    // older than the service's retires nothing (`budget_revision`), and retires one once it is
    // current again (the setup can retire).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try ready_to_retire(&fixture);
    const current = (try fixture.rollout()).budget_revision;
    try rewrite_rollout(&fixture, budget_revision_old);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try rollouts_only(&fixture);
    try testing.expect((try fixture.rollout()).budget_revision >= current);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
}

test "a budget larger than the floor allows retires no more than the floor (stale budget)" {
    // Goal: Review A MUST 2. A budget that would retire two running old replicas (stale, or
    // wrong) retires one: the replicas running stay at `replicas - max_unavailable` (R1).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try ready_to_retire(&fixture);
    try rewrite_rollout(&fixture, retire_two);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
}

test "a replica created since the budget retires no running replica on it (stale budget)" {
    // Goal: the R1 guard of the review's SHOULD. The budget counted the replicas ready when it
    // was computed; once the counter moved (a replacement started), no running replica is
    // retired until the rollout controller counts again.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try ready_to_retire(&fixture);
    const next = try counter(&fixture);
    try set_counter(&fixture, next + 1);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    try set_counter(&fixture, next);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
}

test "a start counted since the budget is not started again (stale budget, starts_left)" {
    // Goal: Review A MUST 2. The budget allows one start; once the counter moved past the
    // number the budget saw, the replicas' controller run alone starts nothing, and starts one
    // when the counter is back where the budget saw it.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.apply(web);
    try fixture.settle();
    _ = try fixture.report(1, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    var next = web;
    next.image = "b3:9d20c4f1";
    next.request_id = "r-0002b11";
    try fixture.apply(next);
    try rollouts_only(&fixture);
    const rollout = try fixture.rollout();
    try testing.expectEqual(@as(u32, 1), rollout.budget.start);
    const seen = try counter(&fixture);
    try testing.expectEqual(seen, rollout.budget_next.?);
    try set_counter(&fixture, seen + 1);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 0), try fixture.count_of(2));
    try set_counter(&fixture, seen);
    try replicas_only(&fixture);
    try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
}

/// One contradiction `rollout_valid` must refuse, made on a valid record.
const Contradiction = enum {
    rollback_from_zero,
    paused_without_by,
    by_without_paused,
    evidence_before_start,
    paused_before_evidence,
};

fn contradict(rollout: *records.Rollout, what: Contradiction) void {
    switch (what) {
        .rollback_from_zero => {
            rollout.reason = .rollback;
            rollout.phase = .complete;
            rollout.from = 0;
        },
        .paused_without_by => {
            rollout.phase = .paused;
            rollout.paused_at_ms = rollout.started_at_ms;
            rollout.paused_by = null;
        },
        .by_without_paused => rollout.paused_by = .user,
        .evidence_before_start => rollout.evidence_from_ms = rollout.started_at_ms - 1,
        .paused_before_evidence => {
            rollout.phase = .paused;
            rollout.paused_by = .user;
            rollout.evidence_from_ms = rollout.started_at_ms + 10;
            rollout.paused_at_ms = rollout.started_at_ms + 9;
        },
    }
}

test "each rule of a stored rollout's own consistency is refused alone with ZC-E0301" {
    // Goal: decision item 20 (Review A, Review B SHOULD 6). Rollback from generation 0, paused
    // without `paused_by` and `paused_by` without paused, evidence before the start, a pause
    // before the evidence: each, made alone on a valid record, is malformed.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    const ctx = fixture.context();
    const key = records.rollout_key(web.name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    const valid = try records.read(records.Rollout, ctx.arena, got.kv.?, &fixture.diag);
    try testing.expectEqual(records.RolloutPhase.progressing, valid.phase);
    for (std.enums.values(Contradiction)) |what| {
        var bad = valid;
        contradict(&bad, what);
        var kv = got.kv.?;
        kv.value = try records.encode(ctx.arena, bad, &fixture.diag);
        fixture.diag.reset();
        const read = records.read(records.Rollout, ctx.arena, kv, &fixture.diag);
        try testing.expectError(error.Malformed, read);
        try testing.expectEqual(.E0301, fixture.diag.code.?);
    }
}

/// Sets node1's status to `state`, keeping the rest of the record.
fn node_state(fixture: *Fixture, state: records.NodeState) !void {
    const ctx = fixture.context();
    const key = records.node_status_key("node1");
    const got = try ctx.store.get(ctx.arena, key.slice(), null, &fixture.diag);
    var status = try records.read(records.NodeStatus, ctx.arena, got.kv.?, &fixture.diag);
    status.state = state;
    const bytes = try records.encode(ctx.arena, status, &fixture.diag);
    const op: store.Op = .{ .put = .{ .key = key.slice(), .value = bytes } };
    const role: writers.Role = .node_controller;
    const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &fixture.diag);
    try testing.expect(done.succeeded);
}

const Interruption = enum { starting, lost };

/// Runs the first new replica half of `min_ready_ms`, interrupts its running as `how` says for
/// one rollout pass, runs it again, and checks it is not ready before a whole `min_ready_ms`
/// more (no old replica is retired), then is.
fn interrupted(how: Interruption) !void {
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    _ = try fixture.report(2, .running);
    try fixture.settle();
    fixture.manual.advance(min_ready_ms / 2);
    switch (how) {
        .starting => _ = try fixture.report(2, .starting),
        .lost => try node_state(&fixture, .lost),
    }
    try rollouts_only(&fixture);
    switch (how) {
        .starting => _ = try fixture.report(2, .running),
        .lost => try node_state(&fixture, .ready),
    }
    try rollouts_only(&fixture);
    fixture.manual.advance(min_ready_ms / 2 + 100);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
    fixture.manual.advance(min_ready_ms);
    try fixture.settle();
    try testing.expectEqual(@as(u32, 2), try fixture.count_of(1));
}

test "a new replica that stops running restarts its readiness clock" {
    // Goal: Review A SHOULD, Review B SHOULD 7 (M11). Running, then starting, then running
    // again: `min_ready_ms` counts from the second running, never the first.
    try interrupted(.starting);
}

test "a new replica whose node is lost restarts its readiness clock" {
    // Goal: Review A SHOULD (M10). A replica on a lost node is not running for readiness, so
    // its clock starts again once the node is back.
    try interrupted(.lost);
}

test "new replicas that die more than rollout_restarts_max times fail the rollout (ZC-E0304)" {
    // Goal: Review B SHOULD 7. Each death of a new replica (not the user's fault) is counted; the
    // fourth fails the rollout, and the rollout's ready count is zero. `count_deaths` counts the
    // deaths it saw reported: a lower bound (docs/decisions/2026-11-14-c3-paused-scale-down.md).
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.roll();
    // Without generation 1 in the history the automatic rollback is refused, so the rollout
    // stays failed (the rollback itself is the slice 8 tests' subject).
    try fixture.forget(1);
    for (0..constants.rollout_restarts_max + 1) |round| {
        try testing.expectEqual(records.RolloutPhase.progressing, (try fixture.rollout()).phase);
        try testing.expectEqual(@as(u32, 1), try fixture.count_of(2));
        _ = round;
        _ = try fixture.report(2, .running);
        try fixture.settle();
        const exit: records.Exit = .{ .kind = .exited, .code = 1 };
        const new = (try fixture.replicas())[3];
        const id = try testing.allocator.dupe(u8, new.rec.id);
        defer testing.allocator.free(id);
        const observed: records.Observed = .{
            .replica = id,
            .node = "node1",
            .generation = 2,
            .status = .stopped,
            .exit = exit,
            .reported_at_ms = fixture.manual.ms,
        };
        try fixture.put(.{ .agent = "node1" }, records.observed_key("node1", id).slice(), observed);
        try fixture.settle();
        fixture.manual.advance(100);
        try fixture.settle();
    }
    const rollout = try fixture.rollout();
    try testing.expectEqual(records.RolloutPhase.failed, rollout.phase);
    try testing.expectEqual(@as(u32, 3), try fixture.count_of(1));
}

test "a first rollout over a generation that never became ready rolls back to nothing" {
    // Goal: Review B SHOULD 4. With no rollout before it, `from` is the newest earlier generation
    // an old replica is ready at; generation 1 was never reported running, so `from` is 0.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.apply(web);
    try fixture.settle();
    var next = web;
    next.image = "b3:9d20c4f1";
    next.request_id = "r-0002b11";
    try fixture.apply(next);
    try fixture.settle();
    try testing.expectEqual(@as(u64, 0), (try fixture.rollout()).from);
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
