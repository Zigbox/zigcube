//! A rollback (`POST /v1/services/<name>/rollback[?to=N]`, `zcube rollback`, and the rollout
//! controller's automatic rollback, C3 slice 8), as a function over the store so the HTTP handler,
//! the controller, the simulation and the tests share one implementation.
//!
//! A rollback never rewinds: it applies the spec of a stored generation (`/history/<service>/<r>`)
//! as a new generation, `current + 1`, with `reason` `rollback` (by hand) or `auto_rollback` (the
//! controller, owner question O3) and `restores` r, so R6's "generation strictly increases" holds
//! and the rollout controller rolls the replicas onto it as onto any apply. Only the spec is
//! copied (image, source, command, env, limits, health); the replica count and the rollout policy
//! stay the service's own. The service, its history record and a `rollback` decision are one
//! transaction of the `api` role that expects the service key at the revision this read, so a
//! rollback never lands over an apply it did not see. The controller's call also names the
//! service and rollout revisions its pass read: a user's apply or pause after them wins (R8).
//!
//! Core: no thread, no clock but the context's, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const history = @import("history.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const Diag = @import("diag.zig").Diag;

const Context = controller.Context;

pub const Error = controller.Error || error{ NotFound, NothingToRestore, NotInHistory };

/// The decision's actor: the API writes every rollback, the controller's too (O3).
pub const actor = "api";

/// Who the controller's rollback is applied by (`applied_by`, owner question O3).
pub const controller_applied_by = "rollout-controller";

pub const Reason = enum {
    rollback,
    auto_rollback,

    fn history_reason(reason: Reason) records.HistoryReason {
        return switch (reason) {
            .rollback => .rollback,
            .auto_rollback => .auto_rollback,
        };
    }
};

/// What the controller's pass read, which the rollback must still find (R8): the service at
/// `service_revision` and its failed rollout at `rollout_revision`.
pub const Expect = struct {
    service_revision: store.Revision,
    rollout_key: []const u8,
    rollout_revision: store.Revision,
    /// The decision that failed the rollout: the rollback's cause, so `zcube why` joins them.
    failed_decision: []const u8,
};

pub const Input = struct {
    name: []const u8,
    /// The generation to restore; null: the newest usable one below the current.
    to: ?u64 = null,
    reason: Reason = .rollback,
    applied_by: []const u8,
    request_id: []const u8,
    /// Set by the controller (and only with `auto_rollback`); null for a rollback by hand.
    expect: ?Expect = null,
};

pub const Result = union(enum) {
    /// Written at `revision`: `generation` is the new one, `restores` the one it copied, and
    /// `decision` the id of the `rollback` decision, in the context's arena.
    written: struct {
        revision: store.Revision,
        generation: u64,
        restores: u64,
        decision: []const u8,
        change: []const u8,
    },
    /// The service (or, for the controller, its rollout) changed since it was read: nothing was
    /// written. The API reports ZC-E0105; the controller looks again on its next pass.
    conflict,
};

/// Rolls `input.name` back. No such service is ZC-E0101; nothing below the current generation to
/// restore is ZC-E0127; a named generation that is not a usable record of this service is
/// ZC-E0128. Nothing is written on any of them.
pub fn rollback(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
) Error!Result {
    assert(ctx.diag.code == null);
    if (input.expect != null) assert(input.reason == .auto_rollback);
    if (input.reason == .auto_rollback) assert(input.expect != null);
    if (records.name_problem(input.name, constants.service_name_bytes_max) != null) {
        return not_found(ctx, input.name);
    }
    const key = records.service_key(input.name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return not_found(ctx, input.name);
    const current = try records.read(records.Service, ctx.arena, kv, ctx.diag);
    if (input.expect) |expect| {
        // The pass that owed this rollback read another service: a newer apply wins (R8).
        if (!c1_teeth.rollout_race and kv.mod_revision != expect.service_revision) {
            return .conflict;
        }
    }
    const owner: history.Owner = .{
        .create_revision = kv.create_revision,
        .generation = current.generation,
    };
    const usable = try history.usable(ctx, input.name, owner);
    const target = try target_of(ctx, &current, usable, input.to);
    // `usable` listed it at this revision and a record is never changed; one deleted since (the
    // service deleted, or 16 newer generations) means the service moved: the write's conflict.
    const restored = try read_history(ctx, target) orelse return .conflict;
    assert(restored.generation < current.generation);
    assert(std.mem.eql(u8, restored.service, input.name));
    return write(ctx, source, input, kv, &current, &restored);
}

/// The record to restore: `to`, or the newest usable generation below the current one.
fn target_of(
    ctx: *const Context,
    current: *const records.Service,
    usable: []const history.Stored,
    to: ?u64,
) Error!history.Stored {
    assert(current.generation > 0);
    if (to) |wanted| {
        if (wanted == current.generation) return nothing(ctx, current, wanted);
        for (usable) |entry| {
            if (entry.generation == wanted) return entry;
        }
        return not_in_history(ctx, current, usable, wanted);
    }
    var index = usable.len;
    while (index > 0) {
        index -= 1;
        if (usable[index].generation < current.generation) return usable[index];
    }
    return nothing(ctx, current, null);
}

fn read_history(ctx: *const Context, entry: history.Stored) Error!?records.History {
    assert(entry.generation > 0);
    const found = try ctx.store.get(ctx.arena, entry.key, null, ctx.diag);
    const kv = found.kv orelse return null;
    const record = try records.read(records.History, ctx.arena, kv, ctx.diag);
    assert(record.generation == entry.generation);
    return record;
}

/// The service as the rollback writes it: the current record with the restored spec, at the next
/// generation. The `rollout_exact` tooth keeps the current image instead (R5 must fail).
pub fn restored_service(
    current: *const records.Service,
    restored: *const records.History,
    input: Input,
) records.Service {
    assert(restored.generation < current.generation);
    var service = current.*;
    service.image = if (c1_teeth.rollout_exact) current.image else restored.image;
    service.source = restored.source;
    service.command = restored.command;
    service.env = restored.env;
    service.limits = restored.limits;
    service.health = restored.health;
    service.generation = current.generation + 1;
    service.applied_by = input.applied_by;
    service.request_id = input.request_id;
    assert(service.generation > restored.generation);
    return service;
}

fn write(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    kv: store.KeyValue,
    current: *const records.Service,
    restored: *const records.History,
) Error!Result {
    const service = restored_service(current, restored, input);
    var batch: controller.Batch = .{};
    if (!c1_teeth.rollout_race) batch.expect(kv.key, kv.mod_revision);
    if (input.expect) |expect| batch.expect(expect.rollout_key, expect.rollout_revision);
    batch.put(kv.key, try records.encode(ctx.arena, service, ctx.diag));
    var record = records.history_of(&service, ctx.clock.now_ms());
    record.reason = input.reason.history_reason();
    record.restores = restored.generation;
    const seed = records.history_of(current, 0);
    try history.put(ctx, &batch, &record, .{
        .create_revision = kv.create_revision,
        .generation = current.generation,
        .seed = &seed,
    });
    const change = try controller.format(ctx, "generation {d} → {d}, restoring {d}", .{
        current.generation, service.generation, restored.generation,
    });
    const id = try put_decision(ctx, source, input, kv, &service, restored, change, &batch);
    return switch (try controller.commit(ctx, .api, &batch)) {
        .applied => |revision| .{ .written = .{
            .revision = revision,
            .generation = service.generation,
            .restores = restored.generation,
            .decision = try controller.format(ctx, "{s}", .{id.slice()}),
            .change = change,
        } },
        .conflict => .conflict,
    };
}

fn put_decision(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    kv: store.KeyValue,
    service: *const records.Service,
    restored: *const records.History,
    change: []const u8,
    batch: *controller.Batch,
) Error!records.DecisionId {
    assert(service.generation > restored.generation);
    assert(std.mem.eql(u8, service.name, input.name));
    const reason = if (input.expect) |expect| try controller.format(ctx, "ZC-W0305 the rollout " ++
        "of {s} to generation {d} failed (decision {s}); {s} was rolled back to generation {d} " ++
        "as generation {d}", .{
        input.name,          service.generation - 1, expect.failed_decision, input.name,
        restored.generation, service.generation,
    }) else try controller.format(ctx, "{s} rolled {s} back to generation {d} as generation " ++
        "{d} (request {s})", .{
        input.applied_by, input.name, restored.generation, service.generation, input.request_id,
    });
    const cause: records.Cause = if (input.expect) |expect|
        if (expect.failed_decision.len == 0)
            .{ .kind = .resync }
        else
            .{ .kind = .decision, .id = expect.failed_decision }
    else
        .{ .kind = .desired, .key = kv.key, .revision = kv.mod_revision };
    return controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "rollback",
        .subject = .{ .kind = .service, .name = input.name },
        .reason = reason,
        .change = change,
        .cause = cause,
        .cause_evidence = try evidence.service(ctx, service),
    }, batch);
}

fn not_found(ctx: *const Context, name: []const u8) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("service {s} does not exist", .{name});
    ctx.diag.fix(.{ .sentence = "list what exists", .command = "zcube get service" });
    return error.NotFound;
}

fn nothing(
    ctx: *const Context,
    current: *const records.Service,
    to: ?u64,
) error{NothingToRestore} {
    raise_nothing(ctx.diag, current.name, current.generation, to);
    return error.NothingToRestore;
}

/// ZC-E0127: nothing to roll back to. Public so the CLI's golden shows the server's own text.
pub fn raise_nothing(diag: *Diag, name: []const u8, generation: u64, to: ?u64) void {
    assert(diag.code == null);
    assert(generation > 0);
    diag.raise(.E0127);
    if (to != null) {
        diag.cause("service {s} runs generation {d} now", .{ name, generation });
        diag.fix_with("name an older generation", "zcube history {s}", .{name});
        return;
    }
    if (generation == 1) {
        diag.cause("service {s} has run only generation 1", .{name});
    } else {
        diag.cause("service {s} has no stored generation below {d}", .{ name, generation });
    }
    diag.fix(.{ .sentence = "apply the service file you want to run" });
}

fn not_in_history(
    ctx: *const Context,
    current: *const records.Service,
    usable: []const history.Stored,
    to: u64,
) error{NotInHistory} {
    const low: u64 = if (usable.len > 0) usable[0].generation else 0;
    const high: u64 = if (usable.len > 0) usable[usable.len - 1].generation else 0;
    raise_not_in_history(ctx.diag, current.name, current.generation, to, low, high);
    return error.NotInHistory;
}

/// ZC-E0128: the named generation is not in the history (`low` to `high` are; 0 for none), or
/// is newer than `generation`, the one the service runs. Public so the CLI's golden shows the
/// server's own text.
pub fn raise_not_in_history(
    diag: *Diag,
    name: []const u8,
    generation: u64,
    to: u64,
    low: u64,
    high: u64,
) void {
    assert(diag.code == null);
    assert(low <= high);
    assert(high <= generation);
    assert(to != generation);
    diag.raise(.E0128);
    if (to > generation) {
        diag.cause("generation {d} of {s} is newer than the one it runs ({d})", .{
            to, name, generation,
        });
    } else if (high == 0) {
        diag.cause("generation {d} of {s} is not in its history (it keeps none)", .{ to, name });
    } else if (low == high) {
        diag.cause("generation {d} of {s} is not in its history (it keeps generation {d})", .{
            to, name, low,
        });
    } else {
        diag.cause("generation {d} of {s} is not in its history (it keeps generations {d} " ++
            "to {d})", .{ to, name, low, high });
    }
    diag.fix_with("list the generations that can be restored", "zcube history {s}", .{name});
}
