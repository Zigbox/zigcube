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
    /// Who applied it and the request that did (docs/api.md item 4).
    applied_by: []const u8,
    request_id: []const u8,
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
    generation: u64,
    /// The one-line summary; `no_change` when `unchanged`.
    change: []const u8,
    unchanged: bool,
};

/// Works out what applying `input` would do. Invalid input is ZC-E0104 and nothing is read.
pub fn plan(ctx: *const Context, input: Input) Error!Plan {
    try validate(ctx, input);
    const key = records.service_key(input.name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    var existing: ?records.Service = null;
    if (found.kv) |kv| existing = try records.read(records.Service, ctx.arena, kv, ctx.diag);
    const change = try change_summary(ctx, existing, input);
    return .{
        .existing = existing,
        .mod_revision = if (found.kv) |kv| kv.mod_revision else 0,
        .generation = next_generation(existing, input),
        .change = change,
        .unchanged = existing != null and std.mem.eql(u8, change, no_change),
    };
}

/// Applies a service. Invalid input is ZC-E0104 and nothing is read or written.
pub fn apply(ctx: *const Context, source: *controller.DecisionSource, input: Input) Error!Result {
    const planned = try plan(ctx, input);
    if (planned.unchanged) return .unchanged;
    const service: records.Service = .{
        .name = input.name,
        .image = input.image,
        .replicas = input.replicas,
        .command = input.command,
        .env = input.env,
        .limits = input.limits,
        .generation = planned.generation,
        // A v1 record's counter is carried until the replica controller has moved it to
        // `/replica-numbers/`; a new service has none.
        .next_replica = if (planned.existing) |old| old.next_replica else null,
        .applied_by = input.applied_by,
        .request_id = input.request_id,
    };
    const key = records.service_key(input.name);
    var batch: controller.Batch = .{};
    batch.expect(key.slice(), planned.mod_revision);
    const service_key_copy = try controller.key_copy(ctx, &key);
    batch.put(service_key_copy, try records.encode(ctx.arena, service, ctx.diag));
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
    var batch: controller.Batch = .{};
    batch.expect(key.slice(), kv.mod_revision);
    batch.delete(kv.key);
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
    if (!strings_equal(old.command, input.command)) return true;
    if (!pairs_equal(old.env, input.env)) return true;
    return !limits_equal(old.limits, input.limits);
}

fn strings_equal(first: []const []const u8, second: []const []const u8) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn pairs_equal(first: []const records.Pair, second: []const records.Pair) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!std.mem.eql(u8, left[0], right[0])) return false;
        if (!std.mem.eql(u8, left[1], right[1])) return false;
    }
    return true;
}

fn limits_equal(first: records.Limits, second: records.Limits) bool {
    if (first.cpu_millis != second.cpu_millis) return false;
    return first.memory_bytes == second.memory_bytes;
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
    if (!strings_equal(old.command, input.command)) try append_part(ctx, &text, "command changed");
    if (!pairs_equal(old.env, input.env)) try append_part(ctx, &text, "env changed");
    if (!limits_equal(old.limits, input.limits)) try append_part(ctx, &text, "limits changed");
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

// ---- Validation ------------------------------------------------------------------------------

fn validate(ctx: *const Context, input: Input) Error!void {
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
        return invalid(ctx, "a service may set at most 64 environment variables");
    }
    for (input.env) |pair| {
        if (pair[0].len == 0) return invalid(ctx, "an environment variable has no name");
    }
}

fn invalid(ctx: *const Context, comptime problem: []const u8) error{Invalid} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause(problem, .{});
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
