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

pub const StepType = enum { decision, observed, desired, resync, lease_expired, gone, note };

/// Why a chain stops short: a decision it cites has been dropped (`retention`), and the subject is
/// gone too (`subject_deleted`), or a record it cites is older than the store keeps and the
/// decision did not copy what it used (`compacted`). authority.md section 5.
pub const Reason = enum { retention, subject_deleted, compacted };

/// Whether the chain reaches its cause. `at` is the last thing found: the id of the last decision,
/// or the cited key for `compacted`.
pub const Completeness = struct {
    verdict: enum { complete, truncated } = .complete,
    at: ?[]const u8 = null,
    reason: ?Reason = null,
};

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
    /// Why the chain stops here, on a `gone` step.
    reason: ?Reason = null,
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
    completeness: Completeness,
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
    const completeness = completeness_of(steps.items, state.exists);
    if (subject.kind == .node) try rebalance_note(ctx, &snapshot, subject.name, &steps);
    return .{
        .revision = snapshot.revision,
        .subject = subject,
        .at_decision = at_decision,
        .state = state,
        .steps = steps.items,
        .completeness = completeness,
    };
}

/// A chain that ends in a `gone` step is truncated, for the reason that step names (a dropped
/// decision of a subject that is gone is `subject_deleted`); any other chain is complete.
fn completeness_of(steps: []Step, subject_exists: bool) Completeness {
    if (steps.len == 0) return .{};
    const last = &steps[steps.len - 1];
    if (last.type != .gone) return .{};
    if (last.reason == .retention and !subject_exists) last.reason = .subject_deleted;
    var at = last.key;
    var index = steps.len;
    while (at == null and index > 0) {
        index -= 1;
        if (steps[index].decision) |decision| at = decision.id;
    }
    assert(last.reason != null);
    return .{ .verdict = .truncated, .at = at, .reason = last.reason };
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
    const node = snapshot.node_of(replica.id) orelse return .{
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
            replica.id, node,
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
            replica.id, node, status,
        }),
    };
}

fn node_state(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    name: []const u8,
) Error!State {
    const judged = try node_judgement(ctx, name);
    for (snapshot.nodes) |node| {
        if (!std.mem.eql(u8, node.rec.name, name)) continue;
        const load = node_load(snapshot, name);
        const verdict = try judgement_phrase(ctx, judged, node.kv.mod_revision);
        return .{
            .exists = true,
            .health = .healthy,
            .desired = 1,
            .running = 1,
            .text = try controller.format(ctx, "node {s}: {s}, lease {d} with {d} {s} " ++
                "assigned, {d}m of {d}m CPU and {s} of {s} memory in use", .{
                name,
                verdict,
                node.kv.lease,
                load.count,
                if (load.count == 1) "replica" else "replicas",
                load.cpu_millis,
                node.rec.capacity.cpu_millis,
                try bytes_text(ctx, load.memory_bytes),
                try bytes_text(ctx, node.rec.capacity.memory_bytes),
            }),
        };
    }
    const last: []const u8 = if (judged) |status|
        try controller.format(ctx, ", last judged {s} (tenure {d})", .{
            @tagName(status.state), status.tenure,
        })
    else
        "";
    return .{
        .exists = false,
        .health = .gone,
        .desired = 0,
        .running = 0,
        .text = try controller.format(ctx, "node {s}: not registered{s}", .{ name, last }),
    };
}

/// A ready node that holds fewer replicas than another one: say why they are not moved to it.
/// The step is a statement of the scheduler's rule (docs/briefs/c1.md, non-goals), not a reading
/// of the store, and its type says so.
fn rebalance_note(
    ctx: *const Context,
    snapshot: *const controller.Snapshot,
    name: []const u8,
    steps: *std.ArrayList(Step),
) Error!void {
    const judged = try node_judgement(ctx, name);
    var tenure: ?u64 = null;
    var busiest: u32 = 0;
    for (snapshot.nodes) |node| {
        if (std.mem.eql(u8, node.rec.name, name)) {
            tenure = node.kv.mod_revision;
        } else busiest = @max(busiest, node_load(snapshot, node.rec.name).count);
    }
    const status = judged orelse return;
    if (status.state != .ready or status.tenure != (tenure orelse return)) return;
    if (node_load(snapshot, name).count >= busiest) return;
    try append(ctx, steps, .{
        .type = .note,
        .text = "replicas that are already running on other nodes are not moved back: the " ++
            "scheduler places a replica when it is created or its node is lost, and does " ++
            "not rebalance",
    });
}

/// `/node-status/<node>`, or null before the node controller has judged the node.
fn node_judgement(ctx: *const Context, name: []const u8) Error!?records.NodeStatus {
    const key = records.node_status_key(name);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = got.kv orelse return null;
    return try records.read(records.NodeStatus, ctx.arena, kv, ctx.diag);
}

/// "ready (tenure 22)", "registered, not yet judged", or a judgement for an earlier tenure.
fn judgement_phrase(
    ctx: *const Context,
    judged: ?records.NodeStatus,
    tenure: u64,
) Error![]const u8 {
    const status = judged orelse return "registered, not yet judged";
    if (status.tenure == tenure) {
        return controller.format(ctx, "{s} (tenure {d})", .{ @tagName(status.state), tenure });
    }
    return controller.format(
        ctx,
        "tenure {d}, not yet judged (last judged {s} for tenure {d})",
        .{ tenure, @tagName(status.state), status.tenure },
    );
}

const Load = struct { count: u32, cpu_millis: u64, memory_bytes: u64 };

/// What `/assigned/<node>/` holds: the count and the sum of the requests.
fn node_load(snapshot: *const controller.Snapshot, name: []const u8) Load {
    var load: Load = .{ .count = 0, .cpu_millis = 0, .memory_bytes = 0 };
    for (snapshot.assigned) |entry| {
        const node = assigned_node(entry.kv.key) orelse continue;
        if (!std.mem.eql(u8, node, name)) continue;
        load.count += 1;
        load.cpu_millis += entry.rec.requests.cpu_millis;
        load.memory_bytes += entry.rec.requests.memory_bytes;
    }
    assert(load.count <= snapshot.assigned.len);
    assert(name.len > 0);
    return load;
}

/// The node of `/assigned/<node>/<replica>`.
fn assigned_node(key: []const u8) ?[]const u8 {
    const prefix = "/assigned/";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const rest = key[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
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
    try append(ctx, steps, .{ .type = .gone, .text = text, .reason = .retention });
}

/// The chain ends because the record it cites is older than the store keeps and the decision did
/// not copy what it used: never the key's value now, which may be what the controller never saw.
fn gone_compacted(
    ctx: *const Context,
    steps: *std.ArrayList(Step),
    key: []const u8,
    revision: store.Revision,
) Error!void {
    const text = try controller.format(
        ctx,
        "the record {s} as it was at revision {d} is no longer kept",
        .{ key, revision },
    );
    try append(ctx, steps, .{
        .type = .gone,
        .text = text,
        .key = key,
        .revision = revision,
        .reason = .compacted,
    });
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
/// has it, else what the decision itself copied (`cause_evidence`, `cause_diagnostic`), else the
/// chain is truncated.
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
    switch (try read_at(ctx, key, cause.revision)) {
        .absent => {},
        .compacted => {
            const revision = cause.revision.?;
            text = try copied_text(ctx, decision, key, revision) orelse
                return gone_compacted(ctx, steps, key, revision);
        },
        .found => |kv| if (std.mem.startsWith(u8, key, records.prefix_nodes)) {
            // The node controller reacted to a node's registration, not to a replica's report.
            const name = key[records.prefix_nodes.len..];
            text = try controller.format(ctx, "node {s} registered ({s})", .{ name, key });
        } else {
            const observed = try records.read(records.Observed, ctx.arena, kv, ctx.diag);
            const phrase = try observed_phrase(ctx, &observed);
            text = try controller.format(ctx, "{s} on {s}: {s}", .{
                observed.replica, observed.node, phrase,
            });
            if (observed.diagnostic) |raw| diagnostic = raw;
        },
    }
    try append(ctx, steps, .{
        .type = .observed,
        .text = text,
        .key = key,
        .revision = cause.revision,
        .diagnostic = diagnostic,
    });
}

/// What a decision kept of a record the store no longer has: the evidence as written, or a line
/// saying the diagnostic it carries is its own copy. Null when it kept neither.
fn copied_text(
    ctx: *const Context,
    decision: records.Decision,
    key: []const u8,
    revision: store.Revision,
) Error!?[]const u8 {
    if (decision.cause_evidence) |evidence| {
        return try controller.format(ctx, "{s} at revision {d}: {s}", .{
            key, revision, evidence.text,
        });
    }
    if (decision.cause_diagnostic == null) return null;
    return try controller.format(ctx, "{s} at revision {d} is no longer kept; the decision " ++
        "kept its own copy of the diagnostic", .{ key, revision });
}

fn desired_step(ctx: *const Context, steps: *std.ArrayList(Step), last: Fetched) Error!void {
    const cause = last.decision.cause;
    const key = cause.key orelse return gone(ctx, steps, "a desired record");
    // An apply's cause has no revision: it is the revision of the decision's own key.
    const revision = cause.revision orelse last.mod_revision;
    var text = try controller.format(ctx, "{s} no longer exists", .{key});
    switch (try read_at(ctx, key, revision)) {
        .absent => {},
        .compacted => text = try copied_text(ctx, last.decision, key, revision) orelse
            return gone_compacted(ctx, steps, key, revision),
        .found => |kv| {
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
        },
    }
    try append(ctx, steps, .{
        .type = .desired,
        .text = text,
        .key = key,
        .revision = revision,
    });
}

/// `0B`, `512Ki`, `128Mi`, `8.0Gi`: the CLI's style (cli_view.zig, a shell module this core
/// module may not import).
fn bytes_text(ctx: *const Context, bytes: u64) Error![]const u8 {
    const kib: u64 = 1024;
    const gib = kib * kib * kib;
    if (bytes >= gib) {
        const tenths = bytes * 10 / gib;
        return controller.format(ctx, "{d}.{d}Gi", .{ tenths / 10, tenths % 10 });
    }
    if (bytes >= kib * kib) return controller.format(ctx, "{d}Mi", .{bytes / kib / kib});
    if (bytes >= kib) return controller.format(ctx, "{d}Ki", .{bytes / kib});
    return controller.format(ctx, "{d}B", .{bytes});
}

const Read = union(enum) { found: store.KeyValue, absent, compacted };

/// A key at a revision. `compacted` when the store no longer keeps that revision and the key has
/// changed since (authority.md section 5), or when the revision is not one the store has yet (the
/// cited record cannot be shown as it was, so the chain may not claim to be complete). A key
/// that has not changed since the cited revision is read now: its value now is its value then.
/// With no revision to ask for, the key now.
fn read_at(ctx: *const Context, key: []const u8, revision: ?store.Revision) Error!Read {
    if (store.key_problem(key) != null) return .absent;
    if (revision) |at| {
        const attempt = ctx.store.get(ctx.arena, key, at, ctx.diag);
        if (attempt) |got| {
            return if (got.kv) |kv| .{ .found = kv } else .absent;
        } else |err| {
            if (err == error.FutureRevision) {
                ctx.diag.reset();
                // Not a revision the store has yet: a key that is not there now was not there at
                // it either; one that is there cannot be shown as it was.
                const now = try ctx.store.get(ctx.arena, key, null, ctx.diag);
                return if (now.kv == null) .absent else .compacted;
            }
            if (err != error.Compacted) return err;
            ctx.diag.reset();
            const now = try ctx.store.get(ctx.arena, key, null, ctx.diag);
            const kv = now.kv orelse return .compacted; // Deleted since: the value then is gone.
            return if (kv.mod_revision <= at) .{ .found = kv } else .compacted;
        }
    }
    const now = try ctx.store.get(ctx.arena, key, null, ctx.diag);
    return if (now.kv) |kv| .{ .found = kv } else .absent;
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

test "why says a node registered only while the store has its key" {
    // Goal: a `/nodes/` cause reads as a registration only if the key is there at that revision
    // (or now); else it reads as removed. Method: node1's own chain, then a mark_ready decision
    // written by hand whose node never registered.
    const world = try new_world(5);
    defer world.destroy();
    world.advance(2000);
    var ctx = world.controller_context();
    const node1 = try why(&ctx, .{ .kind = .node, .name = "node1" }, null);
    const registered = node1.steps[node1.steps.len - 1];
    try testing.expectEqual(StepType.observed, registered.type);
    try testing.expectEqualStrings("node node1 registered (/nodes/node1)", registered.text);

    var source: controller.DecisionSource = .{ .instance = 9 };
    var batch: controller.Batch = .{};
    _ = try controller.put_decision(&ctx, &source, .{
        .actor = "node-controller",
        .action = "mark_ready",
        .subject = .{ .kind = .node, .name = "node9" },
        .reason = "node node9 registered",
        .cause = .{ .kind = .observed, .key = "/nodes/node9", .revision = 5 },
    }, &batch);
    _ = try controller.commit(&ctx, .replica_controller, &batch);
    ctx = world.controller_context();
    const node9 = try why(&ctx, .{ .kind = .node, .name = "node9" }, null);
    try testing.expectEqualStrings(
        "/nodes/node9: the record the controller saw has been removed",
        node9.steps[node9.steps.len - 1].text,
    );
}

test "why node states its load and its judgement, and notes that nothing is rebalanced" {
    // Goal: HANDOFF step 4's question, "why does node2 hold nothing". Method: the world's node1
    // holds an assignment written by hand, node2 registers and is judged ready with none: the
    // note is on node2's chain and not on node1's.
    const world = try new_world(6);
    defer world.destroy();
    world.advance(2000);
    var ctx = world.controller_context();
    const before = try why(&ctx, .{ .kind = .node, .name = "node1" }, null);
    try testing.expectEqualStrings(
        "node node1: ready (tenure 1), lease 1 with 0 replicas assigned, " ++
            "0m of 4000m CPU and 0B of 8.0Gi memory in use",
        before.state.text,
    );
    const assigned: records.Assigned = .{
        .replica = "hello-1",
        .service = "hello",
        .requests = .{ .cpu_millis = 250, .memory_bytes = 128 << 20 },
        .reason = "test",
    };
    const assigned_key = records.assigned_key("node1", "hello-1");
    try put_record(world, .scheduler, assigned_key.slice(), assigned);
    const tenure = try register_node2(world);
    ctx = world.controller_context();
    const waiting = try why(&ctx, .{ .kind = .node, .name = "node2" }, null);
    try expect_contains(waiting.state.text, "registered, not yet judged");
    try testing.expect(note_of(waiting.steps) == null);

    try put_status(world, "node2", .ready, tenure);
    ctx = world.controller_context();
    const node1 = try why(&ctx, .{ .kind = .node, .name = "node1" }, null);
    try expect_contains(node1.state.text, "1 replica assigned, 250m of 4000m CPU and 128Mi");
    try testing.expect(note_of(node1.steps) == null);
    const idle = try why(&ctx, .{ .kind = .node, .name = "node2" }, null);
    try expect_contains(idle.state.text, "ready (tenure");
    const note = note_of(idle.steps).?;
    try expect_contains(note.text, "does not rebalance");
    try testing.expect(note.decision == null);
}

test "why node says a judgement for an older tenure, and a status with no registration" {
    // Goal: the state line does not pass a stale judgement off as current, and a node that left
    // keeps its last judgement in the line. Method: node2's status one tenure behind; node7 has a
    // status and a decision and no registration.
    const world = try new_world(7);
    defer world.destroy();
    world.advance(2000);
    const tenure = try register_node2(world);
    try put_status(world, "node2", .ready, tenure - 1);
    var ctx = world.controller_context();
    const stale = try why(&ctx, .{ .kind = .node, .name = "node2" }, null);
    try expect_contains(stale.state.text, "not yet judged (last judged ready for tenure");
    try testing.expect(note_of(stale.steps) == null);

    try put_status(world, "node7", .lost, 4);
    var source: controller.DecisionSource = .{ .instance = 9 };
    var batch: controller.Batch = .{};
    ctx = world.controller_context();
    _ = try controller.put_decision(&ctx, &source, .{
        .actor = "node-controller",
        .action = "node_lost",
        .subject = .{ .kind = .node, .name = "node7" },
        .reason = "node node7 stopped renewing lease 9",
        .cause = .{
            .kind = .lease_expired,
            .key = "/nodes/node7",
            .lease = 9,
            .ttl_ms = 10000,
            .revision = 3,
        },
    }, &batch);
    _ = try controller.commit(&ctx, .replica_controller, &batch);
    ctx = world.controller_context();
    const left = try why(&ctx, .{ .kind = .node, .name = "node7" }, null);
    try testing.expectEqualStrings(
        "node node7: not registered, last judged lost (tenure 4)",
        left.state.text,
    );
}

fn expect_contains(text: []const u8, wanted: []const u8) !void {
    if (std.mem.indexOf(u8, text, wanted) != null) return;
    std.debug.print("expected to find {s} in {s}\n", .{ wanted, text });
    return error.TestExpectedContains;
}

fn note_of(steps: []const Step) ?Step {
    for (steps) |step| {
        if (step.type == .note) return step;
    }
    return null;
}

/// Registers `node2` (4 CPUs, 8 GiB) and returns its tenure revision.
fn register_node2(world: *sim_world.World) !u64 {
    const node: records.Node = .{
        .name = "node2",
        .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 << 30 },
    };
    try put_record(world, .{ .agent = "node2" }, records.node_key("node2").slice(), node);
    const ctx = world.controller_context();
    const got = try ctx.store.get(ctx.arena, "/nodes/node2", null, ctx.diag);
    return got.kv.?.mod_revision;
}

fn put_status(
    world: *sim_world.World,
    name: []const u8,
    state: records.NodeState,
    tenure: u64,
) !void {
    const status: records.NodeStatus = .{
        .state = state,
        .tenure = tenure,
        .at_ms = 1,
        .decision = "x",
    };
    const key = records.node_status_key(name);
    try put_record(world, .node_controller, key.slice(), status);
}

fn put_record(
    world: *sim_world.World,
    role: writers.Role,
    key: []const u8,
    value: anytype,
) !void {
    const ctx = world.controller_context();
    const bytes = try records.encode(ctx.arena, value, ctx.diag);
    const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
    const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, ctx.diag);
    try testing.expect(done.succeeded);
}

fn compact_to_head(world: *sim_world.World) !void {
    const head = world.revision().?;
    try world.store_handle().compact(head, &world.diag);
}

test "why is complete when the chain reaches its cause, truncated when a decision was dropped" {
    // Goal: `completeness` for the chain of hello-1. Method: complete as it stands; then the
    // create decision is removed (retention): truncated at the decision found last, reason
    // `retention`; then the service goes too: `subject_deleted`.
    const world = try new_world(8);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    var ctx = world.controller_context();
    const whole = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expectEqual(.complete, whole.completeness.verdict);
    try testing.expect(whole.completeness.at == null and whole.completeness.reason == null);

    const first_id = whole.steps[0].decision.?.id;
    const create_id = whole.steps[1].decision.?.id;
    const key = records.decision_key(create_id);
    const op: store.Op = .{ .delete = key.slice() };
    _ = try writers.txn(ctx.store, .retention, .{ .on_success = &.{op} }, ctx.diag);
    const dropped = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expectEqual(.truncated, dropped.completeness.verdict);
    try testing.expectEqual(Reason.retention, dropped.completeness.reason.?);
    try testing.expectEqualStrings(first_id, dropped.completeness.at.?);
    try testing.expectEqual(Reason.retention, dropped.steps[dropped.steps.len - 1].reason.?);

    _ = try world.delete_service("hello");
    world.advance(5000);
    ctx = world.controller_context();
    // The service is gone; retention drops the decision at the end of the chain (the delete's
    // own), keeping the ones before it: the subject is gone, so the reason is `subject_deleted`.
    const gone_chain = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expectEqual(.complete, gone_chain.completeness.verdict);
    const tail = gone_chain.steps[gone_chain.steps.len - 2].decision.?;
    const tail_key = records.decision_key(tail.id);
    const drop: store.Op = .{ .delete = tail_key.slice() };
    _ = try writers.txn(ctx.store, .retention, .{ .on_success = &.{drop} }, ctx.diag);
    ctx = world.controller_context();
    const left = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expect(!left.state.exists);
    try testing.expectEqual(.truncated, left.completeness.verdict);
    try testing.expectEqual(Reason.subject_deleted, left.completeness.reason.?);
}

test "why treats a compacted key that never changed as complete" {
    // Goal: authority.md section 5: `compacted` means the cited key has changed since. Method:
    // compact to the head with /services/hello untouched; the chain still ends at its desired
    // record, read now.
    const world = try new_world(10);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    try compact_to_head(world);
    var ctx = world.controller_context();
    const result = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    try testing.expectEqual(.complete, result.completeness.verdict);
    try testing.expect(result.steps[result.steps.len - 1].type != .gone);
}

test "why never shows the current value as the reason for a compacted record" {
    // Goal: a cited revision below the compaction point ends the chain `compacted`, unless the
    // decision copied what it used; the key's value now is never offered as the justification.
    // Method: compact to the head; the replica controller writes no evidence, so hello-1 is
    // truncated; a hand-written decision with evidence is complete and says the evidence.
    const world = try new_world(9);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    // The service changes after hello-1's decision cited it: only then is the cited value gone.
    var scaled = hello;
    scaled.replicas = 4;
    scaled.request_id = "r-0000002";
    _ = try world.apply(scaled);
    world.advance(2000);
    try compact_to_head(world);
    var ctx = world.controller_context();
    const result = try why(&ctx, .{ .kind = .replica, .name = "hello-1" }, null);
    const last = result.steps[result.steps.len - 1];
    try testing.expectEqual(StepType.gone, last.type);
    try testing.expectEqual(Reason.compacted, last.reason.?);
    try testing.expectEqualStrings("/services/hello", last.key.?);
    try testing.expectEqual(.truncated, result.completeness.verdict);
    try testing.expectEqualStrings("/services/hello", result.completeness.at.?);
    try expect_contains(last.text, "as it was at revision");
    for (result.steps) |step| {
        try testing.expect(std.mem.indexOf(u8, step.text, "was applied by") == null);
    }

    var source: controller.DecisionSource = .{ .instance = 9 };
    var batch: controller.Batch = .{};
    _ = try controller.put_decision(&ctx, &source, .{
        .actor = "scheduler",
        .action = "hold_pending",
        .subject = .{ .kind = .replica, .name = "hello-9" },
        .reason = "no node fits",
        .cause = .{ .kind = .desired, .key = "/replicas/hello/hello-9", .revision = 1 },
        .cause_evidence = .{ .text = "{\"cpu_millis\":250}" },
    }, &batch);
    _ = try controller.commit(&ctx, .scheduler, &batch);
    ctx = world.controller_context();
    const kept = try why(&ctx, .{ .kind = .replica, .name = "hello-9" }, null);
    try testing.expectEqual(.complete, kept.completeness.verdict);
    try testing.expectEqualStrings(
        "/replicas/hello/hello-9 at revision 1: {\"cpu_millis\":250}",
        kept.steps[kept.steps.len - 1].text,
    );
}
