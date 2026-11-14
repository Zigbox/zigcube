//! What the API does when a service is applied or deleted, as a function over the store, so the
//! HTTP write path, the simulation and the tests share one implementation of the rules of
//! docs/keys.md: when `generation` rises, how the one-line `change` summary reads, and that the
//! service and its `apply` decision are written in one transaction.
//!
//! The HTTP endpoint that calls this is not part of the read-only API of docs/api.md and arrives
//! with the server; this is the part of it that decides what is written.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const history = @import("history.zig");
const mesh_address = @import("mesh_address.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;

pub const Error = controller.Error || error{ Invalid, NotFound };

pub const actor = "api";

pub const Input = struct {
    name: []const u8,
    image: []const u8,
    replicas: u32,
    command: []const []const u8,
    env: []const records.Pair = &.{},
    limits: records.Limits = .{},
    /// The OCI reference `image` is pulled from, or empty (docs/keys.md).
    source: []const u8 = "",
    /// Who applied it and the request that did (docs/api.md item 4).
    applied_by: []const u8,
    request_id: []const u8,
    /// The command health check (C3, docs/keys.md); a change of it is a new generation.
    health: ?records.Health = null,
    /// How a new generation replaces the old (C3); null, or the default, is stored as null.
    rollout: ?records.RolloutPolicy = null,
    /// Who may connect to the service through the mesh (C4, docs/keys.md); a change is not a new
    /// generation, and writes a `grant` decision.
    allow: []const records.Grant = &.{},
};

pub const Result = union(enum) {
    /// Written at this revision; `created` says whether the service is new. `decision` is the id
    /// of the `apply` decision and `change` its one-line summary, both in the context's arena.
    written: struct {
        revision: store.Revision,
        created: bool,
        generation: u64,
        decision: []const u8,
        change: []const u8,
    },
    /// What was applied is what is already there: nothing was written.
    unchanged,
    /// The service changed while this apply was being made; nothing was written.
    conflict,
};

/// What an apply would do, worked out without writing (`POST /v1/apply?dry_run=1`).
pub const Plan = struct {
    /// The service as stored now, if there is one.
    existing: ?records.Service,
    /// The stored service's `mod_revision`, or 0 for none: the compare that guards the write.
    mod_revision: store.Revision,
    /// The stored service's `create_revision`, or 0 for none: which history records are its own.
    create_revision: store.Revision,
    generation: u64,
    /// The one-line summary; `no_change` when `unchanged`.
    change: []const u8,
    unchanged: bool,
};

/// Works out what applying `input` would do. Invalid input is ZC-E0104 and nothing is written.
/// The shape is checked before the store is read; the bounds of `limits` after, because a limit a
/// stored service already carries is not re-checked. With the store down, a bad limit is therefore
/// ZC-E0201 or ZC-E0207 (the Postgres pool timeout; both 503), not ZC-E0104.
pub fn plan(ctx: *const Context, input: Input) Error!Plan {
    try validate(ctx, input);
    const key = records.service_key(input.name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    var existing: ?records.Service = null;
    if (found.kv) |kv| existing = try records.read(records.Service, ctx.arena, kv, ctx.diag);
    // Limits a stored service already carries are not re-checked (an apply of the same file must
    // not start failing on a cluster that took them before this bound existed); a changed one is.
    // docs/decisions/2026-11-08-service-apply-limits.md
    const limits_kept = if (existing) |old|
        records.limits_equal(old.limits, input.limits)
    else
        false;
    if (!limits_kept) try validate_limits(ctx, input.limits);
    const change = try change_summary(ctx, existing, input);
    return .{
        .existing = existing,
        .mod_revision = if (found.kv) |kv| kv.mod_revision else 0,
        .create_revision = if (found.kv) |kv| kv.create_revision else 0,
        .generation = next_generation(existing, input),
        .change = change,
        .unchanged = existing != null and std.mem.eql(u8, change, no_change),
    };
}

/// A C0 record's `next_replica`, carried only until the replica controller has seeded
/// `/replica-numbers/<service>` from it (docs/keys.md); null once the counter exists, and for a
/// new service.
fn legacy_counter(ctx: *const Context, existing: ?records.Service) Error!?u64 {
    const old = existing orelse return null;
    const next = old.next_replica orelse return null;
    const key = records.replica_numbers_key(old.name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    if (found.kv != null) return null;
    return next;
}

/// Applies a service. Invalid input is ZC-E0104 and nothing is written. The bounds of `limits` are
/// checked after the store is read (see `plan`), so with the store down a bad limit is ZC-E0201.
pub fn apply(ctx: *const Context, source: *controller.DecisionSource, input: Input) Error!Result {
    const planned = try plan(ctx, input);
    if (planned.unchanged) return .unchanged;
    var batch: controller.Batch = .{};
    const service = try service_record(ctx, &batch, &planned, input);
    const key = records.service_key(input.name);
    batch.expect(key.slice(), planned.mod_revision);
    const service_key_copy = try controller.key_copy(ctx, &key);
    batch.put(service_key_copy, try records.encode(ctx.arena, service, ctx.diag));
    // The grant decision before the history: `history.put` leaves room for one decision only.
    if (grants_changed(planned.existing, input)) {
        try put_grant_decision(ctx, source, &batch, planned.existing, &service, service_key_copy);
    }
    try put_history(ctx, &batch, &planned, &service);
    const reason = try controller.format(ctx, "{s} applied {s} (request {s})", .{
        input.applied_by, input.name, input.request_id,
    });
    const id = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "apply",
        .subject = .{ .kind = .service, .name = input.name },
        .reason = reason,
        .change = planned.change,
        // A transaction cannot know the revision it will take; a reader takes it from the
        // decision key's own `mod_revision` (docs/keys.md).
        .cause = .{ .kind = .desired, .key = service_key_copy },
        .cause_evidence = try evidence.service(ctx, &service),
    }, &batch);
    return switch (try controller.commit(ctx, .api, &batch)) {
        .applied => |revision| .{ .written = .{
            .revision = revision,
            .created = planned.existing == null,
            .generation = planned.generation,
            .decision = try controller.format(ctx, "{s}", .{id.slice()}),
            .change = planned.change,
        } },
        .conflict => .conflict,
    };
}

/// The service as `apply` stores it. A service that has no mesh address yet (a new one, or one
/// written before C4) takes one here, in `batch` (`mesh_address.assign`); one that has it keeps it.
fn service_record(
    ctx: *const Context,
    batch: *controller.Batch,
    planned: *const Plan,
    input: Input,
) Error!records.Service {
    assert(!planned.unchanged);
    assert(batch.ops_count == 0);
    const kept: ?[]const u8 = if (planned.existing) |old| old.mesh_address else null;
    const address = kept orelse try mesh_address.assign(ctx, batch, input.name);
    assert(records.mesh_address_parse(address) != null);
    return .{
        .name = input.name,
        .image = input.image,
        .replicas = input.replicas,
        .command = input.command,
        .env = input.env,
        .limits = input.limits,
        .source = input.source,
        .generation = planned.generation,
        .next_replica = try legacy_counter(ctx, planned.existing),
        .applied_by = input.applied_by,
        .request_id = input.request_id,
        .health = input.health,
        .rollout = stored_rollout(input.rollout),
        .mesh_address = address,
        .allow = input.allow,
    };
}

/// The history record of a new generation, if this apply makes one.
fn put_history(
    ctx: *const Context,
    batch: *controller.Batch,
    planned: *const Plan,
    service: *const records.Service,
) Error!void {
    assert(service.generation == planned.generation);
    assert(batch.ops_count > 0);
    const new_generation = if (planned.existing) |old|
        old.generation != planned.generation
    else
        true;
    if (new_generation) {
        const record = records.history_of(service, ctx.clock.now_ms());
        var seed: records.History = undefined;
        var owner: ?history.Owner = null;
        if (planned.existing) |*old| {
            // When the old generation was applied is not stored: its seed says 0, unknown. A
            // record no build writes, generation 0, has nothing to seed.
            if (old.generation > 0) seed = records.history_of(old, 0);
            owner = .{
                .create_revision = planned.create_revision,
                .generation = old.generation,
                .seed = if (old.generation > 0) &seed else null,
            };
        }
        try history.put(ctx, batch, &record, owner);
    }
}

/// Whether an apply changes the service's grants: a new service with any, or a changed list.
fn grants_changed(existing: ?records.Service, input: Input) bool {
    const old = existing orelse return input.allow.len > 0;
    return !records.grants_equal(old.allow, input.allow);
}

/// The `grant` decision (docs/keys.md): who changed the grants of a service and which came and
/// went, as one line. The grants themselves are in the service record it causes; its evidence is
/// the apply's, so `why grant` reads who applied it from `cause_evidence.applied_by`.
fn put_grant_decision(
    ctx: *const Context,
    source: *controller.DecisionSource,
    batch: *controller.Batch,
    existing: ?records.Service,
    service: *const records.Service,
    service_key: []const u8,
) Error!void {
    assert(batch.has_room(controller.decision_ops));
    const old: []const records.Grant = if (existing) |held| held.allow else &.{};
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    for (service.allow) |grant| {
        if (records.grants_contain(old, grant)) continue;
        try grant_part(ctx, &text, grant, .added);
    }
    for (old) |grant| {
        if (records.grants_contain(service.allow, grant)) continue;
        try grant_part(ctx, &text, grant, .removed);
    }
    assert(text.written().len > 0);
    const reason = try controller.format(ctx, "{s} changed who may connect to {s} (request {s})", .{
        service.applied_by, service.name, service.request_id,
    });
    _ = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "grant",
        .subject = .{ .kind = .service, .name = service.name },
        .reason = reason,
        .change = text.written(),
        .cause = .{ .kind = .desired, .key = service_key },
        .cause_evidence = try evidence.service(ctx, service),
    }, batch);
}

/// Appends "web → 5432 added" to a `grant` decision's change (`records.grant_change_write`).
fn grant_part(
    ctx: *const Context,
    text: *std.Io.Writer.Allocating,
    grant: records.Grant,
    how: records.GrantChange,
) Error!void {
    const failures = @import("store_failures.zig");
    if (text.written().len > 0) {
        text.writer.writeAll(records.grant_change_separator) catch
            return failures.no_memory(ctx.diag);
    }
    records.grant_change_write(&text.writer, grant, how) catch return failures.no_memory(ctx.diag);
}

/// Deletes a service and records who did. Its replicas are stopped by the replica controller.
pub fn delete_service(
    ctx: *const Context,
    source: *controller.DecisionSource,
    name: []const u8,
    applied_by: []const u8,
    request_id: []const u8,
) Error!Result {
    if (records.name_problem(name, constants.service_name_bytes_max) != null) {
        return invalid(ctx, "the service name is not a valid name");
    }
    const key = records.service_key(name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return not_found(ctx, name);
    // The history goes first, in transactions of its own that each still find the service as it
    // was read: no history outlives its service (docs/keys.md).
    if (try history.delete_all(ctx, name, kv.mod_revision) == .conflict) return .conflict;
    var batch: controller.Batch = .{};
    batch.expect(key.slice(), kv.mod_revision);
    batch.delete(kv.key);
    // The address stays held, released, until no replica is left and a day has passed. A record
    // that does not read is still deleted; its address, if any, stays held.
    if (try mesh_address.held_by(ctx, kv.value)) |address| {
        try mesh_address.release(ctx, &batch, name, address);
    }
    const reason = try controller.format(ctx, "{s} deleted {s} (request {s})", .{
        applied_by, name, request_id,
    });
    const id = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "delete_service",
        .subject = .{ .kind = .service, .name = name },
        .reason = reason,
        .change = "deleted",
        .cause = .{ .kind = .desired, .key = kv.key },
        .cause_evidence = try evidence.deleted_service(ctx, name),
    }, &batch);
    return switch (try controller.commit(ctx, .api, &batch)) {
        .applied => |revision| .{ .written = .{
            .revision = revision,
            .created = false,
            .generation = 0,
            .decision = try controller.format(ctx, "{s}", .{id.slice()}),
            .change = "deleted",
        } },
        .conflict => .conflict,
    };
}

const no_change = "no change";

/// `generation` rises on every change of what a replica runs (docs/keys.md). The replica count
/// is not one of them.
fn next_generation(existing: ?records.Service, input: Input) u64 {
    const old = existing orelse return 1;
    if (runs_differently(old, input)) return old.generation + 1;
    return old.generation;
}

fn runs_differently(old: records.Service, input: Input) bool {
    if (!std.mem.eql(u8, old.image, input.image)) return true;
    if (!std.mem.eql(u8, old.source, input.source)) return true;
    if (!records.strings_equal(old.command, input.command)) return true;
    if (!records.pairs_equal(old.env, input.env)) return true;
    if (!records.health_equal(old.health, input.health)) return true;
    return !records.limits_equal(old.limits, input.limits);
}

/// The rollout policy as stored: null when it is the default, so a service that sets none, or
/// sets the default, stays a version 3 record an older release reads.
fn stored_rollout(policy: ?records.RolloutPolicy) ?records.RolloutPolicy {
    const given = policy orelse return null;
    const default: records.RolloutPolicy = .{};
    if (given.equal(default)) return null;
    return given;
}

/// One line saying what an apply changed; never an `env` value (docs/keys.md).
fn change_summary(ctx: *const Context, existing: ?records.Service, input: Input) Error![]const u8 {
    const old = existing orelse return "created";
    var text: std.ArrayList(u8) = .empty;
    if (old.replicas != input.replicas) {
        const piece = try controller.format(ctx, "replicas {d} → {d}", .{
            old.replicas, input.replicas,
        });
        try append_part(ctx, &text, piece);
    }
    if (!std.mem.eql(u8, old.image, input.image)) {
        const piece = try controller.format(ctx, "image {s} → {s}", .{
            shorten(old.image), shorten(input.image),
        });
        try append_part(ctx, &text, piece);
    }
    if (!std.mem.eql(u8, old.source, input.source)) {
        const piece = try controller.format(ctx, "source {s} → {s}", .{
            shorten_source(old.source), shorten_source(input.source),
        });
        try append_part(ctx, &text, piece);
    }
    if (!records.strings_equal(old.command, input.command)) {
        try append_part(ctx, &text, "command changed");
    }
    if (!records.pairs_equal(old.env, input.env)) try append_part(ctx, &text, "env changed");
    if (!records.limits_equal(old.limits, input.limits)) {
        try append_part(ctx, &text, "limits changed");
    }
    if (!records.health_equal(old.health, input.health)) {
        try append_part(ctx, &text, "health changed");
    }
    const old_rollout = old.rollout_policy();
    const new_rollout = input.rollout orelse records.RolloutPolicy{};
    if (!old_rollout.equal(new_rollout)) try append_part(ctx, &text, "rollout changed");
    if (!records.grants_equal(old.allow, input.allow)) {
        try append_part(ctx, &text, "grants changed");
    }
    // A service written before C4 takes its address on its next apply, a re-apply of the same
    // file included (docs/keys.md, "Mesh addresses").
    if (old.mesh_address == null) try append_part(ctx, &text, "mesh address assigned");
    if (text.items.len == 0) return no_change;
    return text.items;
}

fn append_part(ctx: *const Context, text: *std.ArrayList(u8), piece: []const u8) Error!void {
    const failures = @import("store_failures.zig");
    if (text.items.len > 0) text.appendSlice(ctx.arena, ", ") catch
        return failures.no_memory(ctx.diag);
    text.appendSlice(ctx.arena, piece) catch return failures.no_memory(ctx.diag);
}

/// "b3:51aa9c03…" for a long digest, as keys.md writes it.
fn shorten(digest: []const u8) []const u8 {
    const keep = 7;
    if (digest.len <= keep + 4) return digest;
    return digest[0..keep];
}

/// A reference as a line shows it: "none" for no reference, else "…@sha256:" and the first 12
/// digits of the digest it ends in; a text that does not end in one is cut to 24 bytes.
fn shorten_source(reference: []const u8) []const u8 {
    if (reference.len == 0) return "none";
    const tail = source_digest_prefix.len + source_digest_hex;
    if (reference.len < tail) return reference[0..@min(reference.len, 24)];
    const at = reference.len - tail;
    const shown = at + source_digest_prefix.len + 12;
    if (!std.mem.eql(u8, reference[at..][0..source_digest_prefix.len], source_digest_prefix)) {
        return reference[0..@min(reference.len, 24)];
    }
    return reference[at..shown];
}

// ---- Validation ------------------------------------------------------------------------------

const source_digest_prefix = "@sha256:";
const source_digest_hex = 64;

/// Why `reference` is not a digest-pinned OCI reference `apply` takes, as a sentence; null if it
/// is one (or empty). A prefilter: the supervisor parses with Zigbox's `parse_reference`, which
/// the core cannot link, and may still refuse a reference this accepts.
pub fn source_problem(reference: []const u8) ?[]const u8 {
    if (reference.len == 0) return null;
    if (reference.len > constants.source_bytes_max) {
        return std.fmt.comptimePrint("the source must be at most {d} bytes", .{
            constants.source_bytes_max,
        });
    }
    for (reference) |byte| {
        if (byte <= ' ' or byte == 0x7f) {
            return "the source must not hold whitespace or control characters";
        }
    }
    const tail = source_digest_prefix.len + source_digest_hex;
    if (reference.len == tail and std.mem.startsWith(u8, reference, source_digest_prefix)) {
        return "the source needs a repository before @sha256: (registry/name@sha256:<digest>)";
    }
    if (reference.len <= tail) {
        return "the source must end in @sha256: and 64 lowercase hex digits (a tag can move)";
    }
    const prefix_at = reference.len - tail;
    const found = reference[prefix_at..][0..source_digest_prefix.len];
    const ends_pinned = std.mem.eql(u8, found, source_digest_prefix);
    if (!ends_pinned) {
        return "the source must end in @sha256: and 64 lowercase hex digits (a tag can move)";
    }
    for (reference[reference.len - source_digest_hex ..]) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return "the source's digest must be 64 lowercase hex digits";
    }
    return null;
}

fn validate(ctx: *const Context, input: Input) Error!void {
    if (source_problem(input.source)) |problem| return invalid_text(ctx, problem);
    if (records.name_problem(input.name, constants.service_name_bytes_max) != null) {
        return invalid(ctx, "the service name must be 1 to 48 lowercase letters, digits or '-'");
    }
    if (input.replicas > constants.replicas_per_service_max) {
        return invalid(ctx, "a service may have at most 128 replicas");
    }
    if (input.image.len == 0 or input.image.len > constants.image_digest_bytes_max) {
        return invalid(ctx, "the image digest must be 1 to 67 bytes");
    }
    if (input.command.len == 0 or input.command.len > constants.runtime_command_words_max) {
        return invalid(ctx, "the command must have 1 to 64 words");
    }
    if (input.command[0].len == 0) return invalid(ctx, "the command's first word is empty");
    if (input.env.len > constants.runtime_env_count_max) {
        return invalid(ctx, "a service may set at most 16 environment variables");
    }
    for (input.env) |pair| {
        if (pair[0].len == 0) return invalid(ctx, "an environment variable has no name");
    }
    if (input.health) |health| try validate_health(ctx, health);
    if (input.rollout) |rollout| try validate_rollout(ctx, rollout);
    var buffer: [256]u8 = undefined;
    if (records.allow_problem(&buffer, input.name, input.allow)) |problem| {
        return refuse(ctx, .E0135, "allow: {s}", .{problem});
    }
}

/// A command health check (C3): ZC-E0125 naming the field. The command is bounded as a
/// command; the times nest and are bounded by `health_interval_ms_max` and
/// `health_verdict_ms_max`.
fn validate_health(ctx: *const Context, health: records.Health) Error!void {
    if (health.command.len == 0 or health.command.len > constants.runtime_command_words_max) {
        return refuse(ctx, .E0125, "health.command must have 1 to 64 words", .{});
    }
    if (health.command[0].len == 0) {
        return refuse(ctx, .E0125, "health.command's first word is empty", .{});
    }
    if (health.interval_ms == 0) return refuse(ctx, .E0125, "health.interval_ms is 0", .{});
    if (health.timeout_ms == 0) return refuse(ctx, .E0125, "health.timeout_ms is 0", .{});
    if (health.timeout_ms > health.interval_ms) {
        return refuse(ctx, .E0125, "health.timeout_ms is {d}, longer than health.interval_ms " ++
            "({d})", .{ health.timeout_ms, health.interval_ms });
    }
    if (health.failure_threshold == 0) {
        return refuse(ctx, .E0125, "health.failure_threshold is 0; it must be at least 1", .{});
    }
    if (health.success_threshold == 0) {
        return refuse(ctx, .E0125, "health.success_threshold is 0; it must be at least 1", .{});
    }
    try validate_health_bounds(ctx, health);
}

fn validate_health_bounds(ctx: *const Context, health: records.Health) Error!void {
    const interval_max = constants.health_interval_ms_max;
    if (health.interval_ms > interval_max) {
        return refuse(ctx, .E0125, "health.interval_ms is {d}; it must be at most {d}", .{
            health.interval_ms, interval_max,
        });
    }
    if (health.start_period_ms > interval_max) {
        return refuse(ctx, .E0125, "health.start_period_ms is {d}; it must be at most {d}", .{
            health.start_period_ms, interval_max,
        });
    }
    const verdict_max = constants.health_verdict_ms_max;
    const threshold = @max(health.failure_threshold, health.success_threshold);
    if (@as(u64, threshold) * health.interval_ms > verdict_max) {
        return refuse(ctx, .E0125, "health thresholds of {d} runs every {d} ms take longer " ++
            "than {d} ms to reach a verdict", .{ threshold, health.interval_ms, verdict_max });
    }
}

/// A rollout policy (C3): ZC-E0126 naming the field.
fn validate_rollout(ctx: *const Context, rollout: records.RolloutPolicy) Error!void {
    const most = constants.replicas_per_service_max;
    if (rollout.max_surge > most) {
        return refuse(ctx, .E0126, "rollout.max_surge is {d}; it must be at most {d}", .{
            rollout.max_surge, most,
        });
    }
    if (rollout.max_unavailable > most) {
        return refuse(ctx, .E0126, "rollout.max_unavailable is {d}; it must be at most {d}", .{
            rollout.max_unavailable, most,
        });
    }
    if (rollout.strategy == .rolling and rollout.max_surge == 0 and rollout.max_unavailable == 0) {
        return refuse(ctx, .E0126, "rollout.max_surge and rollout.max_unavailable are both 0, " ++
            "so nothing can move", .{});
    }
    if (rollout.min_ready_ms >= rollout.ready_timeout_ms) {
        return refuse(ctx, .E0126, "rollout.min_ready_ms ({d}) must be below " ++
            "rollout.ready_timeout_ms ({d})", .{ rollout.min_ready_ms, rollout.ready_timeout_ms });
    }
    if (rollout.ready_timeout_ms > rollout.progress_deadline_ms) {
        return refuse(ctx, .E0126, "rollout.ready_timeout_ms ({d}) must be at most " ++
            "rollout.progress_deadline_ms ({d})", .{
            rollout.ready_timeout_ms, rollout.progress_deadline_ms,
        });
    }
    const deadline_max = constants.rollout_deadline_ms_max;
    if (rollout.progress_deadline_ms > deadline_max) {
        return refuse(ctx, .E0126, "rollout.progress_deadline_ms is {d}; it must be at most {d}", .{
            rollout.progress_deadline_ms, deadline_max,
        });
    }
    if (rollout.grace_ms > constants.rollout_grace_ms_max) {
        return refuse(ctx, .E0126, "rollout.grace_ms is {d}; it must be at most {d}", .{
            rollout.grace_ms, constants.rollout_grace_ms_max,
        });
    }
}

fn refuse(
    ctx: *const Context,
    comptime code: codes.Code,
    comptime problem: []const u8,
    args: anytype,
) error{Invalid} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(code);
    ctx.diag.cause(problem, args);
    ctx.diag.fix(.{ .sentence = "correct the service file and apply it again" });
    return error.Invalid;
}

/// The bounds of a runtime container's limits, the same as a job's (`job_api.zig`).
fn validate_limits(ctx: *const Context, limits: records.Limits) Error!void {
    if (limits.cpu_millis) |value| {
        if (value < constants.job_limit_cpu_millis_min or
            value > constants.job_limit_cpu_millis_max)
        {
            return invalid_limit(ctx, "cpu_millis", value, .{
                constants.job_limit_cpu_millis_min, constants.job_limit_cpu_millis_max,
            });
        }
    }
    if (limits.memory_bytes) |value| {
        if (value < constants.job_limit_memory_bytes_min or
            value > constants.job_limit_memory_bytes_max)
        {
            return invalid_limit(ctx, "memory_bytes", value, .{
                constants.job_limit_memory_bytes_min, constants.job_limit_memory_bytes_max,
            });
        }
    }
}

fn invalid_limit(
    ctx: *const Context,
    comptime field: []const u8,
    value: u64,
    bounds: [2]u64,
) error{Invalid} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause("limits." ++ field ++ " must be {d} to {d}, it is {d}", .{
        bounds[0], bounds[1], value,
    });
    ctx.diag.fix(.{ .sentence = "correct the service file and apply it again" });
    return error.Invalid;
}

fn invalid(ctx: *const Context, comptime problem: []const u8) error{Invalid} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause(problem, .{});
    ctx.diag.fix(.{ .sentence = "correct the service file and apply it again" });
    return error.Invalid;
}

fn invalid_text(ctx: *const Context, problem: []const u8) error{Invalid} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause("{s}", .{problem});
    ctx.diag.fix(.{ .sentence = "correct the service file and apply it again" });
    return error.Invalid;
}

fn not_found(ctx: *const Context, name: []const u8) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("service {s} does not exist", .{name});
    ctx.diag.fix(.{ .sentence = "list what exists", .command = "zcube get service" });
    return error.NotFound;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const hello: Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = &.{ "sh", "-c", "sleep 1" },
    .applied_by = "alex@laptop",
    .request_id = "r-0001a4f",
};

test "apply creates a service with its decision; a count change keeps the generation" {
    // Goal: the generation rules of docs/keys.md and api.md item 10, and the one-line change
    // summary of item 5. Method: create, scale, change the image, re-apply unchanged.
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
    var source: controller.DecisionSource = .{ .instance = 0 };

    const created = try apply(&ctx, &source, hello);
    try testing.expect(created.written.created);
    try testing.expectEqual(@as(u64, 1), created.written.generation);

    var scaled = hello;
    scaled.replicas = 5;
    const second = try apply(&ctx, &source, scaled);
    try testing.expectEqual(@as(u64, 1), second.written.generation);

    var rebuilt = scaled;
    rebuilt.image = "b3:7c02aaaaaaaa";
    const third = try apply(&ctx, &source, rebuilt);
    try testing.expectEqual(@as(u64, 2), third.written.generation);

    try testing.expect((try apply(&ctx, &source, rebuilt)) == .unchanged);

    const index = try ctx.store.list(ctx.arena, .{
        .prefix = records.index_prefix(.service, "hello").slice(),
        .limit = 10,
    }, &diag);
    try testing.expectEqual(@as(usize, 3), index.kvs.len);
    const summary = try records.read(records.IndexEntry, ctx.arena, index.kvs[1], &diag);
    try testing.expectEqualStrings("apply", summary.action);
    const got = try ctx.store.get(ctx.arena, records.decision_key(summary.id).slice(), null, &diag);
    const decision = try records.read(records.Decision, ctx.arena, got.kv.?, &diag);
    try testing.expectEqualStrings("replicas 3 → 5", decision.change.?);
    try testing.expectEqual(records.CauseKind.desired, decision.cause.kind);
}

test "invalid input is ZC-E0104 and a missing service is ZC-E0101" {
    // Goal: the refusals carry registered codes and write nothing.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1 };
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    var bad = hello;
    bad.name = "Hello";
    try testing.expectError(error.Invalid, apply(&ctx, &source, bad));
    try testing.expectEqual(@import("diag/codes.zig").Code.E0104, diag.code.?);
    diag.reset();
    const missing = delete_service(&ctx, &source, "nope", "me", "r-00000001");
    try testing.expectError(error.NotFound, missing);
    try testing.expectEqual(@import("diag/codes.zig").Code.E0101, diag.code.?);
    diag.reset();
    try testing.expectEqual(@as(store.Revision, 0), (try ctx.store.status(&diag)).revision);
}

test "apply refuses container limits outside the runtime's bounds; a stored one is kept" {
    // Goal: #181. Out-of-bounds cpu_millis and memory_bytes are ZC-E0104 naming the member and
    // write nothing; the bounds themselves pass; a service stored with an out-of-bounds limit
    // (accepted before this check) can be re-applied unchanged and with other fields changed,
    // but not with the limit changed to another bad value.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1 };
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    const bad_limits = [_]records.Limits{
        .{ .cpu_millis = 0 },
        .{ .cpu_millis = constants.job_limit_cpu_millis_max + 1 },
        .{ .memory_bytes = 0 },
        .{ .memory_bytes = constants.job_limit_memory_bytes_min - 1 },
        .{ .memory_bytes = constants.job_limit_memory_bytes_max + 1 },
    };
    for (bad_limits) |limits| {
        var bad = hello;
        bad.limits = limits;
        try testing.expectError(error.Invalid, apply(&ctx, &source, bad));
        try testing.expectEqual(@import("diag/codes.zig").Code.E0104, diag.code.?);
        diag.reset();
    }
    try testing.expectEqual(@as(store.Revision, 0), (try ctx.store.status(&diag)).revision);
    var edge = hello;
    edge.limits = .{
        .cpu_millis = constants.job_limit_cpu_millis_max,
        .memory_bytes = constants.job_limit_memory_bytes_min,
    };
    _ = try apply(&ctx, &source, edge);

    // A stored out-of-bounds limit, as an earlier build wrote it.
    var old = hello;
    old.name = "old";
    old.limits = .{ .cpu_millis = 5 };
    const key = records.service_key("old");
    const stored: records.Service = .{
        .name = old.name,
        .image = old.image,
        .replicas = old.replicas,
        .command = old.command,
        .limits = old.limits,
        .generation = 1,
        .applied_by = old.applied_by,
        .request_id = old.request_id,
        .mesh_address = "127.77.0.2", // an address: the re-apply is unchanged, not a backfill
    };
    const value = try records.encode(ctx.arena, stored, &diag);
    const written = try ctx.store.txn(.{
        .on_success = &.{.{ .put = .{ .key = key.slice(), .value = value } }},
    }, &diag);
    try testing.expect(written.succeeded);
    try testing.expect((try apply(&ctx, &source, old)) == .unchanged);
    old.replicas = 4;
    _ = try apply(&ctx, &source, old);
    old.limits = .{ .cpu_millis = 6 };
    try testing.expectError(error.Invalid, apply(&ctx, &source, old));
}

test "apply: cpu_millis 9 is refused, 10 and memory_bytes 2^40 are accepted (docs/api.md)" {
    try testing.expectEqual(@as(u32, 10), constants.job_limit_cpu_millis_min);
    try testing.expectEqual(@as(u64, 1 << 40), constants.job_limit_memory_bytes_max);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1 };
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    var edge = hello;
    edge.limits = .{ .cpu_millis = 10, .memory_bytes = 1 << 40 };
    _ = try apply(&ctx, &source, edge);
    edge.name = "under";
    edge.limits = .{ .cpu_millis = 9 };
    try testing.expectError(error.Invalid, apply(&ctx, &source, edge));
}

test "apply refuses more environment variables than Zigbox runs" {
    // Goal: P3 of docs/briefs/c2-1.md. `runtime_env_count_max` is Zigbox's `run_env_count_max`
    // (16), so a service the real runtime would refuse is refused at apply, not held later.
    // Method: 16 variables are accepted, 17 are ZC-E0104, and nothing is written.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1 };
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    var pairs: [17][2][]const u8 = undefined;
    for (&pairs) |*pair| pair.* = .{ "KEY", "value" };
    var many = hello;
    many.env = pairs[0..16];
    _ = try apply(&ctx, &source, many);
    diag.reset();
    many.name = "hello2";
    many.env = pairs[0..17];
    try testing.expectError(error.Invalid, apply(&ctx, &source, many));
    try testing.expectEqual(@import("diag/codes.zig").Code.E0104, diag.code.?);
}

fn repeated(comptime byte: u8, comptime count: usize) *const [count]u8 {
    const bytes: [count]u8 = @splat(byte);
    return &bytes;
}

const pinned_source = "registry.example/team/hello@sha256:" ++
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

const cut_pinned = pinned_source[0 .. pinned_source.len - 1];

test "apply accepts no source or a digest-pinned one, and refuses everything else" {
    // Goal: P1 of docs/briefs/c2-2.md. A tag can move, so only `@sha256:` and 64 lowercase hex
    // digits is taken; every refusal is ZC-E0104 with a sentence naming the rule, and nothing is
    // written. Method: one table of references, each applied to an empty store.
    const long = repeated('a', 952) ++ "@sha256:" ++ repeated('0', 64);
    const Case = struct { source: []const u8, ok: bool, rule: []const u8 = "" };
    const cases = [_]Case{
        .{ .source = "", .ok = true },
        .{ .source = pinned_source, .ok = true },
        .{ .source = long, .ok = true },
        .{ .source = "registry.example:5000/a/b@sha256:" ++ repeated('f', 64), .ok = true },
        .{ .source = "registry.example/hello:latest", .ok = false, .rule = "must end in @sha256:" },
        .{ .source = cut_pinned ++ "F", .ok = false, .rule = "lowercase hex" },
        .{ .source = cut_pinned, .ok = false, .rule = "must end in @sha256:" },
        .{ .source = "a b@sha256:" ++ repeated('0', 64), .ok = false, .rule = "whitespace" },
        .{ .source = "a\nb@sha256:" ++ repeated('0', 64), .ok = false, .rule = "whitespace" },
        .{ .source = "a\x00b@sha256:" ++ repeated('0', 64), .ok = false, .rule = "control" },
        .{ .source = "a" ++ long, .ok = false, .rule = "at most 1024 bytes" },
    };
    try testing.expectEqual(@as(usize, 1024), long.len);
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var manual: ManualClock = .{ .ms = 1 };
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
        var source: controller.DecisionSource = .{ .instance = 0 };
        var input = hello;
        input.source = case.source;
        if (case.ok) {
            _ = try apply(&ctx, &source, input);
            continue;
        }
        try testing.expectError(error.Invalid, apply(&ctx, &source, input));
        try testing.expectEqual(@import("diag/codes.zig").Code.E0104, diag.code.?);
        try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, case.rule) != null);
        diag.reset();
        try testing.expectEqual(@as(store.Revision, 0), (try ctx.store.status(&diag)).revision);
    }
}

test "a change of source bumps the generation and the summary says source" {
    // Goal: a replica held for a bad reference is replaced only on a generation bump, so fixing
    // `source` must move it (docs/keys.md). Method: create with none, set it, change it, clear
    // it, and repeat the same apply.
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    const created = try apply(&ctx, &source, hello);
    try testing.expectEqual(@as(u64, 1), created.written.generation);
    var with = hello;
    with.source = pinned_source;
    const second = try apply(&ctx, &source, with);
    try testing.expectEqual(@as(u64, 2), second.written.generation);
    try testing.expectEqualStrings(
        "source none → @sha256:0123456789ab",
        second.written.change,
    );
    try testing.expect((try apply(&ctx, &source, with)) == .unchanged);
    var other = hello;
    other.source = "registry.example/team/hello@sha256:" ++ repeated('f', 64);
    const third = try apply(&ctx, &source, other);
    try testing.expectEqual(@as(u64, 3), third.written.generation);
    try testing.expectEqualStrings(
        "source @sha256:0123456789ab → @sha256:ffffffffffff",
        third.written.change,
    );
    const cleared = try apply(&ctx, &source, hello);
    try testing.expectEqual(@as(u64, 4), cleared.written.generation);
    const got = try ctx.store.get(ctx.arena, records.service_key("hello").slice(), null, &diag);
    const stored = try records.read(records.Service, ctx.arena, got.kv.?, &diag);
    try testing.expectEqualStrings("", stored.source);
}

const test_health: records.Health = .{
    .command = &.{ "/bin/check", "--quick" },
    .interval_ms = 2_000,
    .timeout_ms = 1_000,
    .failure_threshold = 3,
    .success_threshold = 1,
};

fn history_generations(ctx: *const Context) ![]u64 {
    const found = try history.stored(ctx, "hello");
    const out = try ctx.arena.alloc(u64, found.len);
    for (found, out) |entry, *generation| generation.* = entry.generation;
    return out;
}

test "C3: apply writes history with a new generation only, capped, and delete removes it" {
    // Goal: docs/keys.md `/history`: one record per generation, in the apply's transaction, at
    // most `history_generations_max`, none left once the service is deleted. Method: create,
    // scale (no record), change health (a record), overflow the cap, delete, re-create.
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    _ = try apply(&ctx, &source, hello);
    try testing.expectEqualSlices(u64, &.{1}, try history_generations(&ctx));
    const first_kv = (try ctx.store.get(ctx.arena, "/history/hello/1", null, &diag)).kv.?;
    const first = try records.read(records.History, ctx.arena, first_kv, &diag);
    try testing.expectEqualStrings(hello.image, first.image);
    try testing.expectEqual(manual.ms, first.applied_at_ms);
    try testing.expectEqual(records.HistoryReason.apply, first.reason);

    var scaled = hello;
    scaled.replicas = 7;
    _ = try apply(&ctx, &source, scaled);
    try testing.expectEqualSlices(u64, &.{1}, try history_generations(&ctx));

    var checked = scaled;
    checked.health = test_health;
    const health_bump = try apply(&ctx, &source, checked);
    try testing.expectEqual(@as(u64, 2), health_bump.written.generation);
    try testing.expectEqualStrings("health changed", health_bump.written.change);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, try history_generations(&ctx));

    // A rollout policy is not what a replica runs: no new generation, no history.
    var rolled = checked;
    rolled.rollout = .{ .max_surge = 3 };
    const policy = try apply(&ctx, &source, rolled);
    try testing.expectEqual(@as(u64, 2), policy.written.generation);
    try testing.expectEqualStrings("rollout changed", policy.written.change);
    try testing.expectEqual(@as(usize, 2), (try history_generations(&ctx)).len);

    var image_index: u32 = 0;
    while (image_index < constants.history_generations_max + 3) : (image_index += 1) {
        var next = rolled;
        next.image = try std.fmt.allocPrint(ctx.arena, "b3:{x:0>8}", .{image_index});
        manual.ms += 1;
        _ = try apply(&ctx, &source, next);
    }
    const kept = try history_generations(&ctx);
    try testing.expectEqual(@as(usize, constants.history_generations_max), kept.len);
    const newest: u64 = 2 + constants.history_generations_max + 3;
    try testing.expectEqual(newest, kept[kept.len - 1]);
    try testing.expectEqual(newest - constants.history_generations_max + 1, kept[0]);

    const deleted = try delete_service(&ctx, &source, "hello", "ana", "r9");
    try testing.expect(deleted == .written);
    try testing.expectEqual(@as(usize, 0), (try history_generations(&ctx)).len);
    const again = try apply(&ctx, &source, hello);
    try testing.expectEqual(@as(u64, 1), again.written.generation);
    try testing.expectEqualSlices(u64, &.{1}, try history_generations(&ctx));
}

test "C3: a default rollout is stored as none, so the service carries no rollout" {
    // (Before C4 the record stayed version 3; from C4 its mesh address makes it version 5.)
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
    var source: controller.DecisionSource = .{ .instance = 0 };
    var defaulted = hello;
    defaulted.rollout = .{};
    _ = try apply(&ctx, &source, defaulted);
    const got = try ctx.store.get(ctx.arena, records.service_key("hello").slice(), null, &diag);
    try testing.expect(std.mem.startsWith(u8, got.kv.?.value, "{\"v\":5,"));
    try testing.expect(std.mem.indexOf(u8, got.kv.?.value, "rollout") == null);
    try testing.expect((try apply(&ctx, &source, hello)) == .unchanged);
}

test "C3: an invalid health check is ZC-E0125 and an invalid rollout ZC-E0126" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var manual: ManualClock = .{ .ms = 1761350000123 };
    const memory = try testing.allocator.create(MemoryStore);
    defer testing.allocator.destroy(memory);
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    var diag: Diag = undefined;
    const ctx: Context = .{
        .store = memory.interface(),
        .clock = manual.clock(),
        .arena = arena_state.allocator(),
        .diag = &diag,
    };
    var source: controller.DecisionSource = .{ .instance = 0 };
    var health_cases: [9]records.Health = @splat(test_health);
    health_cases[0].command = &.{};
    health_cases[1].command = &.{""};
    health_cases[2].interval_ms = 0;
    health_cases[3].timeout_ms = 0;
    health_cases[4].timeout_ms = test_health.interval_ms + 1;
    health_cases[5].failure_threshold = 0;
    health_cases[6].interval_ms = constants.health_interval_ms_max + 1;
    health_cases[7].start_period_ms = constants.health_interval_ms_max + 1;
    health_cases[8].interval_ms = constants.health_interval_ms_max;
    health_cases[8].success_threshold = 25; // 25 hours to a verdict.
    for (health_cases) |health| {
        diag.reset();
        var input = hello;
        input.health = health;
        try testing.expectError(error.Invalid, apply(&ctx, &source, input));
        try testing.expectEqual(codes.Code.E0125, diag.code.?);
    }
    var rollout_cases: [7]records.RolloutPolicy = @splat(.{});
    rollout_cases[0].max_surge = 0;
    rollout_cases[1].max_surge = constants.replicas_per_service_max + 1;
    rollout_cases[2].max_unavailable = constants.replicas_per_service_max + 1;
    rollout_cases[3].min_ready_ms = rollout_cases[3].ready_timeout_ms;
    rollout_cases[4].ready_timeout_ms = rollout_cases[4].progress_deadline_ms + 1;
    rollout_cases[5].progress_deadline_ms = constants.rollout_deadline_ms_max + 1;
    rollout_cases[6].grace_ms = constants.rollout_grace_ms_max + 1;
    for (rollout_cases) |rollout| {
        diag.reset();
        var input = hello;
        input.rollout = rollout;
        try testing.expectError(error.Invalid, apply(&ctx, &source, input));
        try testing.expectEqual(codes.Code.E0126, diag.code.?);
    }
    // Recreate moves without surge or unavailability: both 0 are fine there.
    diag.reset();
    var recreate = hello;
    recreate.rollout = .{ .strategy = .recreate, .max_surge = 0 };
    try testing.expect(try apply(&ctx, &source, recreate) == .written);
    // Every bound is inclusive.
    diag.reset();
    var longest = hello;
    longest.health = test_health;
    longest.health.?.interval_ms = constants.health_interval_ms_max;
    longest.health.?.start_period_ms = constants.health_interval_ms_max;
    longest.health.?.failure_threshold = 24; // A day to a verdict.
    longest.rollout = .{
        .progress_deadline_ms = constants.rollout_deadline_ms_max,
        .grace_ms = constants.rollout_grace_ms_max,
    };
    try testing.expect(try apply(&ctx, &source, longest) == .written);
}

const codes = @import("diag/codes.zig");
