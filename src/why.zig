//! `zcube why`, as a core function: from a subject (a service, a replica or a node) to the chain
//! of causes that explains its state, through decisions, observed state, the `lease_expired`
//! cause and the desired spec (docs/api.md, "GET /v1/why"; docs/keys.md, "How a decision
//! references a cause"). It returns structured steps; the API serialises them, and the CLI and
//! the console print `state.text` and then `<- text` for each step, so every client says the
//! same words. A step that carries a diagnostic is rendered as the full diagnostic block.
//!
//! The chain starts at the subject's newest decision (or at a given one) and follows each
//! decision's `cause` until a terminal: observed state, the desired spec, a lease that ran out,
//! a periodic resync, or `gone`, a link that retention has removed. It terminates because every
//! decision is visited once, at most `why_steps_max` of them (a cause that points back at a
//! visited decision is reported as `gone`, not followed).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");

const Allocator = std.mem.Allocator;
const Context = controller.Context;

pub const Error = controller.Error || error{NotFound};

pub const Health = enum { healthy, degraded, failing, gone };

pub const StepType = enum { decision, observed, desired, resync, lease_expired, gone };

pub const State = struct {
    exists: bool,
    health: Health,
    desired: u32,
    running: u32,
    text: []const u8,
};

pub const Step = struct {
    type: StepType,
    /// The sentence every client prints for this step.
    text: []const u8,
    decision: ?records.Decision = null,
    key: ?[]const u8 = null,
    revision: ?u64 = null,
    lease: ?u64 = null,
    ttl_ms: ?u64 = null,
    /// The diagnostic this step carries, in the JSON of DIAGNOSTICS.md: observed state's own, or
    /// the copy a decision embeds when the record it points at is gone.
    diagnostic: ?records.Raw = null,
};

pub const Result = struct {
    v: u32 = 1,
    revision: store.Revision,
    subject: records.Subject,
    at_decision: ?[]const u8,
    state: State,
    steps: []const Step,
};

/// Explains `subject`. `at_decision` starts the chain at that decision instead of the newest.
/// A subject that does not exist and has no decisions is ZC-E0101.
pub fn why(
    ctx: *const Context,
    subject: records.Subject,
    at_decision: ?[]const u8,
) Error!Result {
    const snapshot = try controller.read_snapshot(ctx);
    const state = try state_of(ctx, &snapshot, subject);
    const first = try first_decision(ctx, subject, at_decision);
    if (first == null and !state.exists) return not_found(ctx, subject);
    var steps: std.ArrayList(Step) = .empty;
    if (first) |start| try follow(ctx, start, &steps);
    return .{
        .revision = snapshot.revision,
        .subject = subject,
        .at_decision = at_decision,
        .state = state,
        .steps = steps.items,
    };
}

// ---- The state line ----------------------------------------------------------------------------

fn state_of(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    subject: records.Subject,
) Error!State {
    return switch (subject.kind) {
        .service => service_state(ctx, snapshot, subject.name),
        .replica => replica_state(ctx, snapshot, subject.name),
        .node => node_state(ctx, snapshot, subject.name),
    };
}

fn service_state(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    name: []const u8,
) Error!State {
    const service = snapshot.service_of(name) orelse return .{
        .exists = false,
        .health = .gone,
        .desired = 0,
        .running = 0,
        .text = try controller.format(ctx, "service {s}: deleted", .{name}),
    };
    var running: u32 = 0;
    for (snapshot.replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.service, name)) continue;
        const observed = snapshot.observed_of(&replica.rec) orelse continue;
        if (observed.rec.status == .running) running += 1;
    }
    const wanted = service.rec.replicas;
    var health: Health = .degraded;
    if (running >= wanted) health = .healthy;
    if (running == 0 and wanted > 0) health = .failing;
    return .{
        .exists = true,
        .health = health,
        .desired = wanted,
        .running = running,
        .text = try controller.format(ctx, "service {s}: {d}/{d} running", .{
            name, running, wanted,
        }),
    };
}

fn replica_state(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    id: []const u8,
) Error!State {
    for (snapshot.replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.id, id)) continue;
        return replica_line(ctx, snapshot, &replica.rec);
    }
    return .{
        .exists = false,
        .health = .gone,
        .desired = 0,
        .running = 0,
        .text = try controller.format(ctx, "replica {s}: removed", .{id}),
    };
}

fn replica_line(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    replica: *const records.Replica,
) Error!State {
    if (replica.node.len == 0) return .{
        .exists = true,
        .health = .degraded,
        .desired = 1,
        .running = 0,
        .text = try controller.format(ctx, "replica {s}: waiting for a node", .{replica.id}),
    };
    const observed = snapshot.observed_of(replica) orelse return .{
        .exists = true,
        .health = .degraded,
        .desired = 1,
        .running = 0,
        .text = try controller.format(ctx, "replica {s}: assigned to {s}, not yet reported", .{
            replica.id, replica.node,
        }),
    };
    const status = try observed_phrase(ctx, &observed.rec);
    const running: u32 = if (observed.rec.status == .running) 1 else 0;
    var health: Health = .degraded;
    if (running == 1) health = .healthy;
    if (observed.rec.status == .stopped) health = .failing;
    return .{
        .exists = true,
        .health = health,
        .desired = 1,
        .running = running,
        .text = try controller.format(ctx, "replica {s} on {s}: {s}", .{
            replica.id, replica.node, status,
        }),
    };
}

fn node_state(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    name: []const u8,
) Error!State {
    for (snapshot.nodes) |node| {
        if (!std.mem.eql(u8, node.rec.name, name)) continue;
        return .{
            .exists = true,
            .health = .healthy,
            .desired = 1,
            .running = 1,
            .text = try controller.format(ctx, "node {s}: registered on lease {d}", .{
                name, node.kv.lease,
            }),
        };
    }
    return .{
        .exists = false,
        .health = .gone,
        .desired = 0,
        .running = 0,
        .text = try controller.format(ctx, "node {s}: not registered", .{name}),
    };
}

/// "running", "starting", "stopped (failed to start)".
fn observed_phrase(ctx: *const Context, observed: *const records.Observed) Error![]const u8 {
    switch (observed.status) {
        .running => return "running",
        .starting => return "starting",
        .stopped => {
            const exit = observed.exit orelse records.Exit{ .kind = .lost };
            var buffer: [64]u8 = undefined;
            return controller.format(ctx, "stopped ({s})", .{records.exit_text(exit, &buffer)});
        },
    }
}

// ---- The chain ---------------------------------------------------------------------------------

const Fetched = struct { decision: records.Decision, mod_revision: store.Revision };

fn fetch_decision(ctx: *const Context, id: []const u8) Error!?Fetched {
    if (records.decision_id_time(id) == null) return null;
    const key = records.decision_key(id);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = got.kv orelse return null;
    const decision = try records.read(records.Decision, ctx.arena, kv, ctx.diag);
    return .{ .decision = decision, .mod_revision = kv.mod_revision };
}

fn first_decision(
    ctx: *const Context,
    subject: records.Subject,
    at_decision: ?[]const u8,
) Error!?Fetched {
    if (at_decision) |id| {
        const found = try fetch_decision(ctx, id);
        if (found == null) return no_decision(ctx, id);
        return found;
    }
    const prefix = records.index_prefix(subject.kind, subject.name);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = 1,
        .reverse = true,
    }, ctx.diag);
    if (page.kvs.len == 0) return null;
    const entry = try records.read(records.IndexEntry, ctx.arena, page.kvs[0], ctx.diag);
    return fetch_decision(ctx, entry.id);
}

/// Walks the causes from `start`. Each decision becomes a step; the cause of the last decides
/// the terminal step, or `gone` if the decision it points at has been removed.
fn follow(ctx: *const Context, start: Fetched, steps: *std.ArrayList(Step)) Error!void {
    var current = start;
    for (0..constants.why_steps_max) |_| {
        try append(ctx, steps, .{
            .type = .decision,
            .text = current.decision.reason,
            .decision = current.decision,
        });
        const cause = current.decision.cause;
        if (cause.kind != .decision) return terminal(ctx, steps, current);
        const id = cause.id orelse return gone(ctx, steps, "a decision");
        if (visited(steps.items, id)) return gone(ctx, steps, id);
        const next = try fetch_decision(ctx, id);
        current = next orelse return gone(ctx, steps, id);
    }
    return gone(ctx, steps, "the rest of the chain");
}

fn visited(steps: []const Step, id: []const u8) bool {
    for (steps) |step| {
        const decision = step.decision orelse continue;
        if (std.mem.eql(u8, decision.id, id)) return true;
    }
    return false;
}

fn append(ctx: *const Context, steps: *std.ArrayList(Step), step: Step) Error!void {
    steps.append(ctx.arena, step) catch return failures.no_memory(ctx.diag);
}

fn gone(ctx: *const Context, steps: *std.ArrayList(Step), what: []const u8) Error!void {
    const text = try controller.format(ctx, "the decision {s} that came before is no longer " ++
        "kept (decisions are dropped after 200 per subject, 7 days, or 24 hours once the " ++
        "subject is gone)", .{what});
    try append(ctx, steps, .{ .type = .gone, .text = text });
}

/// The step a decision's cause ends the chain with.
fn terminal(ctx: *const Context, steps: *std.ArrayList(Step), last: Fetched) Error!void {
    const cause = last.decision.cause;
    switch (cause.kind) {
        .decision => unreachable, // `follow` handles it before calling here.
        .resync => try append(ctx, steps, .{
            .type = .resync,
            .text = "found by a periodic resync, not by a change",
        }),
        .lease_expired => try lease_step(ctx, steps, cause),
        .observed => try observed_step(ctx, steps, last.decision),
        .desired => try desired_step(ctx, steps, last),
    }
}

fn lease_step(ctx: *const Context, steps: *std.ArrayList(Step), cause: records.Cause) Error!void {
    const key = cause.key orelse "a node";
    const text = try controller.format(ctx, "{s} was deleted because its lease {d} ran out " ++
        "(ttl {d} ms)", .{ key, cause.lease orelse 0, cause.ttl_ms orelse 0 });
    try append(ctx, steps, .{
        .type = .lease_expired,
        .text = text,
        .key = cause.key,
        .revision = cause.revision,
        .lease = cause.lease,
        .ttl_ms = cause.ttl_ms,
    });
}

/// The observed record the controller reacted to, as it was at that revision if the store still
/// has it, else as the decision's own copy of its diagnostic remembers.
fn observed_step(
    ctx: *const Context,
    steps: *std.ArrayList(Step),
    decision: records.Decision,
) Error!void {
    const cause = decision.cause;
    const key = cause.key orelse return gone(ctx, steps, "an observed record");
    var diagnostic = decision.cause_diagnostic;
    var text = try controller.format(ctx, "{s}: the record the controller saw has been removed", .{
        key,
    });
    if (try read_at(ctx, key, cause.revision)) |kv| {
        const observed = try records.read(records.Observed, ctx.arena, kv, ctx.diag);
        const phrase = try observed_phrase(ctx, &observed);
        text = try controller.format(ctx, "{s} on {s}: {s}", .{
            observed.replica, observed.node, phrase,
        });
        if (observed.diagnostic) |raw| diagnostic = raw;
    }
    try append(ctx, steps, .{
        .type = .observed,
        .text = text,
        .key = key,
        .revision = cause.revision,
        .diagnostic = diagnostic,
    });
}

fn desired_step(ctx: *const Context, steps: *std.ArrayList(Step), last: Fetched) Error!void {
    const cause = last.decision.cause;
    const key = cause.key orelse return gone(ctx, steps, "a desired record");
    // An apply's cause has no revision: it is the revision of the decision's own key.
    const revision = cause.revision orelse last.mod_revision;
    var text = try controller.format(ctx, "{s} no longer exists", .{key});
    if (try read_at(ctx, key, revision)) |kv| {
        const service = try records.read(records.Service, ctx.arena, kv, ctx.diag);
        text = try controller.format(ctx, "service {s} was applied by {s} (request {s}): " ++
            "generation {d}, {d} {s}", .{
            service.name,
            if (service.applied_by.len > 0) service.applied_by else "someone",
            if (service.request_id.len > 0) service.request_id else "unknown",
            service.generation,
            service.replicas,
            if (service.replicas == 1) "replica" else "replicas",
        });
    }
    try append(ctx, steps, .{
        .type = .desired,
        .text = text,
        .key = key,
        .revision = revision,
    });
}

/// A key at a revision, or now if the revision is unknown or has been compacted away.
fn read_at(ctx: *const Context, key: []const u8, revision: ?store.Revision) Error!?store.KeyValue {
    if (store.key_problem(key) != null) return null;
    if (revision) |at| {
        const attempt = ctx.store.get(ctx.arena, key, at, ctx.diag);
        if (attempt) |got| return got.kv else |err| {
            if (err != error.Compacted and err != error.FutureRevision) return err;
            ctx.diag.reset();
        }
    }
    const now = try ctx.store.get(ctx.arena, key, null, ctx.diag);
    return now.kv;
}

fn not_found(ctx: *const Context, subject: records.Subject) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("{s} {s} does not exist and has no recorded decisions", .{
        @tagName(subject.kind), subject.name,
    });
    ctx.diag.fix(.{ .sentence = "list what exists", .command = "zcube get service" });
    return error.NotFound;
}

fn no_decision(ctx: *const Context, id: []const u8) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("decision {s} does not exist or was dropped by retention", .{id});
    ctx.diag.fix(.{ .sentence = "ask without a decision to start from the newest" });
    return error.NotFound;
}

// ---- Rendering ---------------------------------------------------------------------------------

/// The text `zcube why` prints (docs/api.md): the state line, then `<-` and the text of each
/// step, a step with a diagnostic as the full diagnostic block (HANDOFF's example).
pub fn render_text(
    arena: Allocator,
    result: *const Result,
    verbose: bool,
) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print("{s}\n", .{result.state.text}) catch return error.OutOfMemory;
    const buffer = try arena.alloc(u8, constants.diag_output_bytes_max);
    for (result.steps) |step| {
        if (step.diagnostic) |raw| {
            if (try render_diagnostic_step(writer, buffer, raw, verbose)) continue;
        }
        writer.print("  \u{2190} {s}\n", .{step.text}) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// Writes a diagnostic as the step's block: the arrow before its first line, the rest indented
/// under it. False if the text is not a diagnostic (the caller prints the step's sentence).
fn render_diagnostic_step(
    writer: *std.Io.Writer,
    buffer: []u8,
    raw: records.Raw,
    verbose: bool,
) Allocator.Error!bool {
    var diagnostic: records.Diagnostic = undefined;
    if (!records.diagnostic_parse(&diagnostic, raw)) return false;
    const mode: @import("zigbox").render.Mode = if (verbose) .verbose else .text;
    const block = diag_mod.render(&diagnostic, mode, false, buffer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        const prefix = if (first) "  \u{2190} " else "    ";
        writer.print("{s}{s}\n", .{ prefix, line }) catch return error.OutOfMemory;
        first = false;
    }
    return true;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const apply_mod = @import("apply.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0000001",
};

test "why explains a service whose image is not in the node's store, as HANDOFF shows" {
    // Goal: C0 demo step 4. Method: apply `broken` with a digest that is not in the fixtures and
    // let the cores run; the chain is the hold decision, then the observed failure rendered as
    // the full ZBX-E0501 block.
    const world = try new_world(1);
    defer world.destroy();
    var broken = hello;
    broken.name = "broken";
    broken.image = "b3:00ff7be1";
    broken.replicas = 1;
    _ = try world.apply(broken);
    world.advance(3000);

    const ctx = world.controller_context();
    const result = try why(&ctx, .{ .kind = .service, .name = "broken" }, null);
    try testing.expectEqualStrings("service broken: 0/1 running", result.state.text);
    try testing.expectEqual(Health.failing, result.state.health);
    try testing.expectEqual(StepType.decision, result.steps[0].type);
    try testing.expectEqualStrings("hold_failed_replica", result.steps[0].decision.?.action);
    try testing.expectEqual(StepType.observed, result.steps[1].type);
    try testing.expectEqual(@as(usize, 2), result.steps.len);

    const text = try render_text(ctx.arena, &result, false);
    const lines = [_][]const u8{
        "service broken: 0/1 running\n",
        "  \u{2190} replica broken-1 failed to start on node1; it was not replaced because " ++
            "a new one would fail the same way\n",
        "  \u{2190} error[ZBX-E0501]: image not found\n",
        "      cause  digest b3:00ff7be1 is not in this node's store\n",
        "      fix    check the digest in the service file, or pull the image first\n",
    };
    var at: usize = 0;
    for (lines) |line| {
        const found = std.mem.indexOfPos(u8, text, at, line) orelse {
            std.debug.print("missing {s} in:\n{s}", .{ line, text });
            return error.TestExpectedEqual;
        };
        at = found + line.len;
    }
}

fn new_world(seed: u64) !*sim_world.World {
    return sim_world.World.create(testing.allocator, seed, &sim_runtime.default_fixtures);
}

test "why follows a replacement back through the decisions to the observed exit" {
    // Goal: the chain for a replica that replaced a killed one: place, create, replace, then the
    // delete of the old replica and the observed record it reacted to. Method: kill a replica of
    // a running service and read the chain of its replacement and of the service.
    const world = try new_world(2);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    try world.kill("hello-2");
    world.advance(2000);

    const ctx = world.controller_context();
    const service = try why(&ctx, .{ .kind = .service, .name = "hello" }, null);
    try testing.expectEqualStrings("service hello: 3/3 running", service.state.text);
    try testing.expectEqualStrings("replace_replica", service.steps[0].decision.?.action);
    try testing.expectEqualStrings("delete_replica", service.steps[1].decision.?.action);
    try testing.expectEqual(StepType.observed, service.steps[2].type);
    try testing.expectEqualStrings(
        "hello-2 on node1: stopped (was killed by signal 9 (SIGKILL))",
        service.steps[2].text,
    );

    const replica = try why(&ctx, .{ .kind = .replica, .name = "hello-4" }, null);
    try testing.expectEqualStrings("place_replica", replica.steps[0].decision.?.action);
    try testing.expectEqualStrings("create_replica", replica.steps[1].decision.?.action);
    try testing.expectEqualStrings("replace_replica", replica.steps[2].decision.?.action);
    try testing.expectEqual(StepType.observed, replica.steps[replica.steps.len - 1].type);
}

test "why ends at the desired spec for a scale-up, and a missing link is a gone step" {
    // Goal: the `desired` terminal, and retention's effect: a cause that was dropped. Method:
    // the chain of a first replica ends at the apply; after its create decision is removed, the
    // chain of the place decision ends in `gone`.
    const world = try new_world(3);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    const ctx = world.controller_context();
    const replica = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    const last = replica.steps[replica.steps.len - 1];
    try testing.expectEqual(StepType.desired, last.type);
    try testing.expectEqualStrings(
        "service hello was applied by alex@laptop (request r-0000001): generation 1, 3 replicas",
        last.text,
    );

    // Retention drops the create decision of hello-1.
    const create_id = replica.steps[1].decision.?.id;
    const key = records.decision_key(create_id);
    const op: store.Op = .{ .delete = key.slice() };
    _ = try writers.txn(ctx.store, .retention, .{ .on_success = &.{op} }, ctx.diag);
    const after = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expectEqual(StepType.gone, after.steps[after.steps.len - 1].type);
    try testing.expectEqual(@as(usize, 2), after.steps.len);
}

test "why renders a lease that ran out, and refuses an unknown subject" {
    // Goal: the `lease_expired` terminal, which a lost node leaves in place of an observed
    // record, and the 404 of the API. Method: write a node_lost decision by hand.
    const world = try new_world(4);
    defer world.destroy();
    var ctx = world.controller_context();
    var source: controller.DecisionSource = .{ .instance = 9 };
    var batch: controller.Batch = .{};
    _ = try controller.put_decision(&ctx, &source, .{
        .actor = "node-controller",
        .action = "node_lost",
        .subject = .{ .kind = .node, .name = "node3" },
        .reason = "node node3 stopped renewing lease 43 for 10 s, so its registration was deleted",
        .cause = .{
            .kind = .lease_expired,
            .key = "/nodes/node3",
            .lease = 43,
            .ttl_ms = 10000,
            .revision = 5,
        },
    }, &batch);
    _ = try controller.commit(&ctx, .replica_controller, &batch);
    ctx = world.controller_context();
    const result = try why(&ctx, .{ .kind = .node, .name = "node3" }, null);
    try testing.expectEqual(Health.gone, result.state.health);
    try testing.expectEqual(StepType.lease_expired, result.steps[1].type);
    try testing.expectEqual(@as(?u64, 43), result.steps[1].lease);

    ctx = world.controller_context();
    try testing.expectError(error.NotFound, why(&ctx, .{ .kind = .service, .name = "nope" }, null));
    try testing.expectEqual(@import("diag/codes.zig").Code.E0101, ctx.diag.code.?);
}
