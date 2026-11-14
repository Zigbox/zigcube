//! A user's pause and resume of a rollout (`POST /v1/services/<name>/rollout/pause|resume`, C3
//! slice 11), as a function over the store so the HTTP handler and the tests share it.
//!
//! `/rollouts/` has one writer, the rollout controller (authority.md I4), so the API process runs
//! this as a small rollout-controller transaction: it reads the service and its rollout, applies
//! `rollout_plan.pause_rollout` or `resume_rollout`, and writes the record and a `rollout_pause` or
//! `rollout_resume` decision with a compare on both keys' `mod_revision`. A pause sets the budget
//! to zero in the same write (R4): a controller pass that read the rollout before the pause cannot
//! commit a budget over it, because its own compare on the rollout's revision then fails.
//! docs/decisions/2026-11-14-c3-slice11-surfaces.md.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const records = @import("records.zig");
const rollout_plan = @import("rollout_plan.zig");
const store = @import("store.zig");

const Context = controller.Context;

pub const Error = controller.Error || error{ NotFound, NoRollout };

/// The decisions name the rollout controller: the action is its, though a request asked for it.
pub const actor = "rollout-controller";

/// A pause or resume that lost a race to another writer is tried again this many times in all,
/// then is ZC-E0105.
pub const attempts_max: u32 = 3;

pub const Action = enum {
    pause,
    @"resume",

    pub fn decision_action(action: Action) []const u8 {
        return switch (action) {
            .pause => "rollout_pause",
            .@"resume" => "rollout_resume",
        };
    }
};

pub const Input = struct {
    name: []const u8,
    action: Action,
    applied_by: []const u8,
    request_id: []const u8,
};

/// A rollout a pause or resume left as it was.
pub const Unchanged = struct { phase: records.RolloutPhase, to: u64 };

pub const Result = union(enum) {
    /// Written at `revision`; `decision` is the id of the decision, in the context's arena.
    written: struct {
        revision: store.Revision,
        /// The phase before and after.
        previous: records.RolloutPhase,
        phase: records.RolloutPhase,
        to: u64,
        decision: []const u8,
    },
    /// Pausing a paused rollout, or resuming a running one: nothing was written (ZC-E0129's
    /// explanation: it succeeds and changes nothing).
    unchanged: Unchanged,
    /// The service or the rollout changed under every attempt: nothing was written.
    conflict,
};

/// Pauses or resumes the rollout of `input.name`, trying again on a conflict. No such service is
/// ZC-E0101; no rollout of it (none, another incarnation's, complete, or a failed one to resume)
/// is ZC-E0129. Conflicts on every attempt return `.conflict`, which the caller reports.
pub fn steer(ctx: *const Context, source: *controller.DecisionSource, input: Input) Error!Result {
    var attempt: u32 = 0;
    while (attempt < attempts_max) : (attempt += 1) {
        const result = try steer_once(ctx, source, input);
        if (result != .conflict) return result;
    }
    return .conflict;
}

/// One attempt: read, decide, write with compares. `.conflict` when a compare failed.
pub fn steer_once(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
) Error!Result {
    var batch: controller.Batch = .{};
    const prepared = try prepare(ctx, source, input, &batch);
    const ready = switch (prepared) {
        .unchanged => |unchanged| return .{ .unchanged = unchanged },
        .ready => |ready| ready,
    };
    const written = ready.record;
    return switch (try controller.commit(ctx, .rollout_controller, &batch)) {
        .applied => |revision| .{ .written = .{
            .revision = revision,
            .previous = ready.previous,
            .phase = written.phase,
            .to = written.to,
            .decision = written.cause_decision,
        } },
        .conflict => .conflict,
    };
}

const Prepared = union(enum) {
    unchanged: Unchanged,
    /// The record `batch` writes, and the phase it had.
    ready: struct { record: records.Rollout, previous: records.RolloutPhase },
};

/// Reads the service and its rollout and fills `batch` with the write and its compares.
fn prepare(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    batch: *controller.Batch,
) Error!Prepared {
    if (records.name_problem(input.name, constants.service_name_bytes_max) != null) {
        return not_found(ctx, input.name);
    }
    const service_key = records.service_key(input.name);
    const service_found = try ctx.store.get(ctx.arena, service_key.slice(), null, ctx.diag);
    const service_kv = service_found.kv orelse return not_found(ctx, input.name);
    const service = try records.read(records.Service, ctx.arena, service_kv, ctx.diag);
    const key = records.rollout_key(input.name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return no_rollout(ctx, input.name);
    const rollout = try records.read(records.Rollout, ctx.arena, kv, ctx.diag);
    if (!records.rollout_of(&rollout, service_kv.create_revision)) {
        return no_rollout(ctx, input.name);
    }
    const state = state_of(&rollout);
    const policy = service.rollout_policy();
    const now_ms = ctx.clock.now_ms();
    const next = switch (input.action) {
        .pause => rollout_plan.pause_rollout(&state, now_ms),
        .@"resume" => rollout_plan.resume_rollout(&policy, &state, now_ms),
    } catch return refused(ctx, input, &rollout);
    if (next.phase == state.phase) {
        return .{ .unchanged = .{ .phase = state.phase, .to = rollout.to } };
    }
    batch.expect(service_kv.key, service_kv.mod_revision);
    batch.expect(kv.key, kv.mod_revision);
    const id = try put_decision(ctx, source, input, &rollout, kv, next.phase, batch);
    var written = record_of(&rollout, &next);
    written.cause_decision = try controller.format(ctx, "{s}", .{id.slice()});
    batch.put(kv.key, try records.encode(ctx.arena, written, ctx.diag));
    return .{ .ready = .{ .record = written, .previous = rollout.phase } };
}

fn put_decision(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    rollout: *const records.Rollout,
    kv: store.KeyValue,
    phase: records.RolloutPhase,
    batch: *controller.Batch,
) Error!records.DecisionId {
    const verb = switch (input.action) {
        .pause => "paused",
        .@"resume" => "resumed",
    };
    const reason = try controller.format(ctx, "{s} {s} the rollout of {s} to generation {d} " ++
        "(request {s})", .{ input.applied_by, verb, input.name, rollout.to, input.request_id });
    const change = try controller.format(ctx, "{s} → {s}", .{
        @tagName(rollout.phase), @tagName(phase),
    });
    return controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = input.action.decision_action(),
        .subject = .{ .kind = .service, .name = input.name },
        .reason = reason,
        .change = change,
        .cause = .{ .kind = .desired, .key = kv.key, .revision = kv.mod_revision },
        .cause_evidence = try evidence.rollout(ctx, rollout),
    }, batch);
}

/// The plan's view of a stored rollout. A record written before pause and resume's members
/// existed (slice 5's) lacks them: an active phase names its reason, the evidence counts from the
/// start, and a pause without its time and cause counts as a failure's from that moment, so a
/// resume restarts the deadline rather than stretching one of unknown age.
pub fn state_of(rollout: *const records.Rollout) rollout_plan.State {
    const reason: rollout_plan.Reason = switch (rollout.phase) {
        .progressing => .apply,
        .rolling_back => .rollback,
        .paused, .complete, .failed => reason_of(rollout.reason),
    };
    const started = rollout.started_at_ms;
    const evidence_from = @max(rollout.evidence_from_ms orelse started, started);
    var state: rollout_plan.State = .{
        .phase = rollout.phase,
        .reason = reason,
        .started_at_ms = started,
        .deadline_at_ms = @max(rollout.deadline_at_ms, started),
        .evidence_from_ms = evidence_from,
    };
    if (rollout.phase == .paused) {
        state.paused_at_ms = @max(rollout.paused_at_ms orelse evidence_from, evidence_from);
        state.paused_by = switch (rollout.paused_by orelse .failure) {
            .user => .user,
            .failure => .failure,
        };
    }
    state.assert_valid();
    return state;
}

fn reason_of(reason: ?records.RolloutReason) rollout_plan.Reason {
    return switch (reason orelse .apply) {
        .apply => .apply,
        .rollback => .rollback,
    };
}

/// The stored record after `next`: the plan's state, and for a pause a zero budget (R4) so the
/// replica controller starts and retires nothing from the moment the pause commits. A resume
/// leaves the budget zero: the controller's next pass computes it.
pub fn record_of(rollout: *const records.Rollout, next: *const rollout_plan.State) records.Rollout {
    next.assert_valid();
    var record = rollout.*;
    record.phase = next.phase;
    record.reason = switch (next.reason) {
        .apply => .apply,
        .rollback => .rollback,
    };
    record.started_at_ms = next.started_at_ms;
    record.deadline_at_ms = next.deadline_at_ms;
    record.evidence_from_ms = next.evidence_from_ms;
    record.paused_at_ms = next.paused_at_ms;
    record.paused_by = if (next.paused_by) |by| switch (by) {
        .user => .user,
        .failure => .failure,
    } else null;
    if (next.phase == .paused) {
        record.budget = .{};
        record.next_at_ms = null;
    }
    return record;
}

fn not_found(ctx: *const Context, name: []const u8) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("service {s} does not exist", .{name});
    ctx.diag.fix(.{ .sentence = "list what exists", .command = "zcube get service" });
    return error.NotFound;
}

fn no_rollout(ctx: *const Context, name: []const u8) error{NoRollout} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0129);
    ctx.diag.cause("service {s} has no rollout", .{name});
    ctx.diag.fix_with("see what the service runs", "zcube rollout status {s}", .{name});
    return error.NoRollout;
}

/// The plan refused: the rollout is complete, or a resume found it failed.
fn refused(ctx: *const Context, input: Input, rollout: *const records.Rollout) error{NoRollout} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0129);
    switch (rollout.phase) {
        .failed => ctx.diag.cause("the rollout of service {s} to generation {d} failed; " ++
            "a failed rollout is resumed only once paused", .{ input.name, rollout.to }),
        else => ctx.diag.cause("service {s} has no rollout in progress (the last one, to " ++
            "generation {d}, is {s})", .{ input.name, rollout.to, @tagName(rollout.phase) }),
    }
    ctx.diag.fix_with("see what the service runs", "zcube rollout status {s}", .{input.name});
    return error.NoRollout;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;
const writers = @import("writers.zig");

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    memory: *MemoryStore,
    clock: ManualClock,
    diag: Diag,
    source: controller.DecisionSource,
    service_created: store.Revision = 0,

    /// In place: the memory store keeps a pointer to the clock.
    fn init(fixture: *Fixture) !void {
        fixture.* = .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .memory = try testing.allocator.create(MemoryStore),
            .clock = .{ .ms = 1_000_000 },
            .diag = undefined,
            .source = .{ .instance = 7 },
        };
        fixture.diag.reset();
        fixture.memory.init(testing.allocator, fixture.clock.clock());
    }

    fn deinit(fixture: *Fixture) void {
        fixture.memory.deinit();
        testing.allocator.destroy(fixture.memory);
        fixture.arena_state.deinit();
    }

    fn ctx(fixture: *Fixture) Context {
        return .{
            .store = fixture.memory.interface(),
            .clock = fixture.clock.clock(),
            .arena = fixture.arena_state.allocator(),
            .diag = &fixture.diag,
        };
    }

    fn put(fixture: *Fixture, role: writers.Role, key: []const u8, value: anytype) !store.Revision {
        var context = fixture.ctx();
        var batch: controller.Batch = .{};
        batch.put(key, try records.encode(context.arena, value, context.diag));
        return switch (try controller.commit(&context, role, &batch)) {
            .applied => |revision| revision,
            .conflict => error.TestUnexpectedResult,
        };
    }

    fn put_service(fixture: *Fixture) !void {
        const service: records.Service = .{
            .name = "hello",
            .image = "b3:51aa9c03",
            .replicas = 3,
            .command = &.{ "sh", "-c", "sleep 1" },
            .generation = 7,
            .applied_by = "alex@laptop",
            .request_id = "r1",
        };
        _ = try fixture.put(.api, "/services/hello", service);
        var context = fixture.ctx();
        const found = try context.store.get(context.arena, "/services/hello", null, context.diag);
        fixture.service_created = found.kv.?.create_revision;
    }

    fn put_rollout(fixture: *Fixture, record: records.Rollout) !void {
        _ = try fixture.put(.rollout_controller, "/rollouts/hello", record);
    }

    fn rollout(fixture: *Fixture, phase: records.RolloutPhase) records.Rollout {
        return .{
            .service = "hello",
            .service_created = fixture.service_created,
            .from = 6,
            .to = 7,
            .phase = phase,
            .started_at_ms = 900_000,
            .deadline_at_ms = 1_500_000,
            .budget = .{ .start = 1, .retire = 1, .retire_unready = 1 },
            .next_at_ms = 1_100_000,
        };
    }

    fn read_rollout(fixture: *Fixture) !records.Rollout {
        var context = fixture.ctx();
        const found = try context.store.get(context.arena, "/rollouts/hello", null, context.diag);
        return records.read(records.Rollout, context.arena, found.kv.?, context.diag);
    }

    fn run(fixture: *Fixture, action: Action) Error!Result {
        var context = fixture.ctx();
        return steer(&context, &fixture.source, .{
            .name = "hello",
            .action = action,
            .applied_by = "alex@laptop",
            .request_id = "r-0001",
        });
    }
};

test "C3 slice 11: a pause stops the budget and a resume moves the deadline by the pause" {
    // Goal: the record contract the rollout controller reads (slice 6 item 5): a user's pause
    // writes phase paused, paused_by user, the time and a zero budget, with a rollout_pause
    // decision; the resume restores the phase its reason names and stretches the deadline.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.put_service();
    try fixture.put_rollout(fixture.rollout(.progressing));

    const paused = try fixture.run(.pause);
    try testing.expectEqual(records.RolloutPhase.paused, paused.written.phase);
    const record = try fixture.read_rollout();
    try testing.expectEqual(records.RolloutPhase.paused, record.phase);
    try testing.expectEqual(@as(?records.RolloutPausedBy, .user), record.paused_by);
    try testing.expectEqual(@as(?u64, 1_000_000), record.paused_at_ms);
    try testing.expectEqual(@as(?records.RolloutReason, .apply), record.reason);
    try testing.expectEqual(@as(u32, 0), record.budget.start);
    try testing.expectEqual(@as(u32, 0), record.budget.retire);
    try testing.expectEqual(@as(u32, 0), record.budget.retire_unready);
    try testing.expectEqual(@as(?u64, null), record.next_at_ms);
    try testing.expectEqualStrings(paused.written.decision, record.cause_decision);

    // Pausing again changes nothing and writes nothing.
    const again = try fixture.run(.pause);
    try testing.expectEqual(records.RolloutPhase.paused, again.unchanged.phase);

    fixture.clock.ms = 1_060_000;
    const resumed = try fixture.run(.@"resume");
    try testing.expectEqual(records.RolloutPhase.progressing, resumed.written.phase);
    const back = try fixture.read_rollout();
    try testing.expectEqual(@as(u64, 1_560_000), back.deadline_at_ms);
    try testing.expectEqual(@as(?u64, 1_060_000), back.evidence_from_ms);
    try testing.expectEqual(@as(?u64, null), back.paused_at_ms);
    try testing.expectEqual(@as(?records.RolloutPausedBy, null), back.paused_by);
    try testing.expectEqual(@as(u32, 0), back.budget.start);

    // Resuming a running rollout changes nothing.
    const running = try fixture.run(.@"resume");
    try testing.expectEqual(records.RolloutPhase.progressing, running.unchanged.phase);

    // Each write left its decision, citing the request.
    var context = fixture.ctx();
    const decisions = try context.store.list(context.arena, .{
        .prefix = "/decisions/",
        .limit = 16,
    }, &fixture.diag);
    try testing.expectEqual(@as(usize, 2), decisions.kvs.len);
    const first_kv = decisions.kvs[0];
    const first = try records.read(records.Decision, context.arena, first_kv, &fixture.diag);
    try testing.expectEqualStrings("rollout_pause", first.action);
    try testing.expectEqualStrings(actor, first.actor);
    try testing.expect(std.mem.indexOf(u8, first.reason, "r-0001") != null);
    try testing.expect(std.mem.indexOf(u8, first.reason, "alex@laptop") != null);
}

test "C3 slice 11: a paused rollback resumes as a rollback; a failed rollout pauses as a failure" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.put_service();
    try fixture.put_rollout(fixture.rollout(.rolling_back));
    _ = try fixture.run(.pause);
    const record = try fixture.read_rollout();
    try testing.expectEqual(@as(?records.RolloutReason, .rollback), record.reason);
    const resumed = try fixture.run(.@"resume");
    try testing.expectEqual(records.RolloutPhase.rolling_back, resumed.written.phase);

    try fixture.put_rollout(fixture.rollout(.failed));
    const resume_failed = fixture.run(.@"resume");
    try testing.expectError(error.NoRollout, resume_failed);
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0129), fixture.diag.code);
    fixture.diag.reset();
    _ = try fixture.run(.pause);
    const failed_paused = try fixture.read_rollout();
    try testing.expectEqual(@as(?records.RolloutPausedBy, .failure), failed_paused.paused_by);
    // A failure's pause restarts the deadline from the resume.
    fixture.clock.ms = 2_000_000;
    _ = try fixture.run(.@"resume");
    const restarted = try fixture.read_rollout();
    const policy: records.RolloutPolicy = .{};
    try testing.expectEqual(2_000_000 + policy.progress_deadline_ms, restarted.deadline_at_ms);
}

test "C3 slice 11: no rollout, a complete one or another incarnation's is ZC-E0129" {
    const Code = @import("diag/codes.zig").Code;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try testing.expectError(error.NotFound, fixture.run(.pause));
    try testing.expectEqual(@as(?Code, .E0101), fixture.diag.code);
    fixture.diag.reset();
    try fixture.put_service();
    try testing.expectError(error.NoRollout, fixture.run(.pause));
    try testing.expectEqual(@as(?Code, .E0129), fixture.diag.code);
    fixture.diag.reset();
    try fixture.put_rollout(fixture.rollout(.complete));
    try testing.expectError(error.NoRollout, fixture.run(.pause));
    try testing.expectEqual(@as(?Code, .E0129), fixture.diag.code);
    fixture.diag.reset();
    var stale = fixture.rollout(.progressing);
    stale.service_created = fixture.service_created + 100;
    try fixture.put_rollout(stale);
    try testing.expectError(error.NoRollout, fixture.run(.@"resume"));
    try testing.expectEqual(@as(?Code, .E0129), fixture.diag.code);
}

test "C3 slice 11: a slice 5 record without pause members reads as a failure's pause" {
    // Goal: the defaults of `state_of`, so a record written before slice 6's members still
    // resumes without breaking the plan's invariants.
    var fixture: Fixture = .{
        .arena_state = undefined,
        .memory = undefined,
        .clock = .{},
        .diag = undefined,
        .source = .{ .instance = 7 },
        .service_created = 40,
    };
    var rollout = fixture.rollout(.paused);
    const state = state_of(&rollout);
    try testing.expectEqual(@as(?u64, 900_000), state.paused_at_ms);
    try testing.expectEqual(@as(?rollout_plan.PauseCause, .failure), state.paused_by);
    try testing.expectEqual(rollout_plan.Reason.apply, state.reason);
    // An evidence time before the start, from a confused writer, is clamped.
    rollout.evidence_from_ms = 1;
    rollout.paused_at_ms = 2;
    const clamped = state_of(&rollout);
    try testing.expectEqual(@as(u64, 900_000), clamped.evidence_from_ms);
    try testing.expectEqual(@as(?u64, 900_000), clamped.paused_at_ms);
}

test "C3 slice 11: a pause that races a controller write commits only over what it read" {
    // Goal: R4's argument. An attempt reads the rollout, the controller moves it, and the
    // attempt's compare fails: nothing of the pause is written. The retrying `steer` then pauses
    // the record as it is now. (The same compare is what fails a controller pass whose read came
    // before a pause: the seam slice 7 relies on.)
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.put_service();
    try fixture.put_rollout(fixture.rollout(.progressing));
    var context = fixture.ctx();
    var batch: controller.Batch = .{};
    const prepared = try prepare(&context, &fixture.source, .{
        .name = "hello",
        .action = .pause,
        .applied_by = "alex@laptop",
        .request_id = "r-0002",
    }, &batch);
    try testing.expect(prepared == .ready);
    var moved = fixture.rollout(.progressing);
    moved.ready_new = 2;
    try fixture.put_rollout(moved);
    try testing.expect(try controller.commit(&context, .rollout_controller, &batch) == .conflict);
    const kept = try fixture.read_rollout();
    try testing.expectEqual(records.RolloutPhase.progressing, kept.phase);
    try testing.expectEqual(@as(u32, 2), kept.ready_new);

    const paused = try fixture.run(.pause);
    try testing.expectEqual(records.RolloutPhase.paused, paused.written.phase);
    const record = try fixture.read_rollout();
    try testing.expectEqual(@as(u32, 2), record.ready_new);
    try testing.expectEqual(@as(u32, 0), record.budget.start);
}
