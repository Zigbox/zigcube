//! The acceptance test of docs/authority.md §5, "When an explanation is complete", as a core
//! module that `sim-c1` and a `zig build test` test both drive:
//!
//! 1. `Recorder.record_*` records, right after a decision commits, the terminal evidence `why`
//!    renders for it (and the evidence the decision itself embeds);
//! 2. `Recorder.disturb` changes or deletes every key any recorded decision cites and compacts the
//!    store past all of them;
//! 3. `Recorder.verify` asks `why` again for every recorded decision. Each answer is `complete`
//!    and renders the evidence recorded in step 1 (from the decision's own copy, never from the
//!    changed key), or `truncated` with a reason and nothing it cannot back.
//!
//! `check_completeness` is I5 on one answer: it is `complete` or names its truncation. Core code:
//! it takes the store through the `Context` and allocates only from its own allocator and the
//! context's arena.

const std = @import("std");
const assert = std.debug.assert;
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const why_mod = @import("why.zig");

const Allocator = std.mem.Allocator;
const Context = controller.Context;

/// A sentence naming what broke, or null.
pub const Found = ?[]const u8;

/// What one decision's chain ended with when it committed.
const Entry = struct {
    id: []const u8,
    subject: records.Subject,
    /// The terminal step `why` rendered: null when the chain was already truncated.
    terminal: ?Terminal,
};

const Terminal = struct {
    type: why_mod.StepType,
    text: []const u8,
    key: ?[]const u8,
    revision: ?u64,
    /// The `cause_evidence` text of the decision whose cause the terminal is, if it embeds any.
    evidence: ?[]const u8,
};

pub const Counts = struct {
    recorded: u32 = 0,
    complete: u32 = 0,
    truncated: u32 = 0,
    /// A decision retention dropped before the check: nothing to ask.
    dropped: u32 = 0,
    /// A decision `why` could not explain the moment it committed, or that did not fit in the
    /// recorder: `verify` fails on either, so nothing is skipped without a word.
    unexplained: u32 = 0,
    unrecorded: u32 = 0,
    keys_deleted: u32 = 0,
    keys_changed: u32 = 0,
};

pub const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),
    counts: Counts,

    pub fn init(gpa: Allocator) Recorder {
        return .{ .arena = .init(gpa), .entries = .empty, .counts = .{} };
    }

    pub fn deinit(r: *Recorder) void {
        r.arena.deinit();
    }

    /// Records the decisions `request` wrote (the puts under `/decisions/`), by asking `why` at
    /// each now. The caller calls it right after the transaction committed.
    pub fn record_request(r: *Recorder, ctx: *const Context, request: store.TxnRequest) void {
        for (request.on_success) |op| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
            const decision = std.json.parseFromSliceLeaky(records.Decision, ctx.arena, put.value, .{
                .ignore_unknown_fields = true,
            }) catch {
                r.counts.unexplained += 1;
                continue;
            };
            r.record(ctx, decision);
        }
    }

    /// Records every decision in the store that is not recorded yet (for a test that drives a
    /// scenario and records between steps).
    pub fn record_listed(r: *Recorder, ctx: *const Context) !void {
        const listed = try controller.list_all(
            records.Decision,
            ctx,
            records.prefix_decisions,
            null,
            listed_max,
        );
        for (listed.items) |item| {
            if (r.has(item.rec.id)) continue;
            r.record(ctx, item.rec);
        }
    }

    fn has(r: *const Recorder, id: []const u8) bool {
        for (r.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return true;
        }
        return false;
    }

    fn record(r: *Recorder, ctx: *const Context, decision: records.Decision) void {
        const kept = r.arena.allocator();
        const answer = why_mod.why(ctx, decision.subject, decision.id) catch {
            ctx.diag.reset();
            r.counts.unexplained += 1;
            return;
        };
        const id = kept.dupe(u8, decision.id) catch return r.fail_to_record();
        const name = kept.dupe(u8, decision.subject.name) catch return r.fail_to_record();
        const entry: Entry = .{
            .id = id,
            .subject = .{ .kind = decision.subject.kind, .name = name },
            .terminal = terminal_of(kept, answer.steps),
        };
        r.entries.append(kept, entry) catch return r.fail_to_record();
        r.counts.recorded += 1;
    }

    fn fail_to_record(r: *Recorder) void {
        r.counts.unrecorded += 1;
    }

    /// Step 2: every key a recorded decision cites is deleted or changed (alternately), then the
    /// store is compacted to its head. Writes through `ctx.store`: a simulation passes the store
    /// beneath its checks.
    pub fn disturb(r: *Recorder, ctx: *const Context) !void {
        var done: std.ArrayList([]const u8) = .empty;
        var head: store.Revision = 1;
        for (r.entries.items) |entry| {
            const terminal = entry.terminal orelse continue;
            const key = terminal.key orelse continue;
            if (contains(done.items, key)) continue;
            try done.append(ctx.arena, key);
            const got = try ctx.store.get(ctx.arena, key, null, ctx.diag);
            head = @max(head, got.revision);
            const kv = got.kv orelse continue;
            const even = done.items.len % 2 == 0;
            const changed = if (even) try changed_value(ctx.arena, kv.value) else null;
            const op: store.Op = if (changed) |value|
                .{ .put = .{ .key = key, .value = value } }
            else
                .{ .delete = key };
            const ops = [_]store.Op{op};
            const result = try ctx.store.txn(.{ .on_success = &ops }, ctx.diag);
            head = @max(head, result.revision);
            if (changed == null) r.counts.keys_deleted += 1 else r.counts.keys_changed += 1;
        }
        if (head > 0) try ctx.store.compact(head, ctx.diag);
    }

    /// Step 3: null when every recorded decision passes, else the first sentence that fails.
    pub fn verify(r: *Recorder, ctx: *const Context) Found {
        if (r.counts.unexplained > 0) {
            return "I5: why failed on a decision at the moment it committed";
        }
        if (r.counts.unrecorded > 0) return "I5: the recorder could not hold a decision";
        for (r.entries.items) |entry| {
            if (r.verify_one(ctx, entry)) |found| return found;
        }
        return null;
    }

    fn verify_one(r: *Recorder, ctx: *const Context, entry: Entry) Found {
        const answer = why_mod.why(ctx, entry.subject, entry.id) catch |err| {
            ctx.diag.reset();
            if (err == error.NotFound) {
                r.counts.dropped += 1; // Retention took the decision itself.
                return null;
            }
            return "I5: why failed on a decision it explained when the decision committed";
        };
        if (check_completeness(&answer)) |found| return found;
        switch (answer.completeness.verdict) {
            .complete => r.counts.complete += 1,
            .truncated => r.counts.truncated += 1,
        }
        return compare(ctx, entry, &answer);
    }
};

/// Every decision a run writes is listed, up to this many (a test's scenario is small).
const listed_max: u32 = 4096;

fn contains(items: []const []const u8, key: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

/// The last step if it ends the chain at a cause, with the evidence the decision before it
/// embeds. Null for a chain that was truncated.
fn terminal_of(kept: Allocator, steps: []const why_mod.Step) ?Terminal {
    if (steps.len == 0) return null;
    const last = steps[steps.len - 1];
    switch (last.type) {
        .observed, .desired, .resync, .lease_expired => {},
        .decision, .gone, .note => return null,
    }
    var evidence: ?[]const u8 = null;
    if (steps.len >= 2) {
        if (steps[steps.len - 2].decision) |decision| {
            if (decision.cause_evidence) |raw| evidence = kept.dupe(u8, raw.text) catch return null;
        }
    }
    return .{
        .type = last.type,
        .text = kept.dupe(u8, last.text) catch return null,
        .key = if (last.key) |key| kept.dupe(u8, key) catch return null else null,
        .revision = last.revision,
        .evidence = evidence,
    };
}

/// I5 on one answer: `complete`, or `truncated` with its reason and the last thing found, ending in
/// the `gone` step that says so. A `complete` answer has no `gone` step.
pub fn check_completeness(answer: *const why_mod.Result) Found {
    const steps = answer.steps;
    const last_is_gone = steps.len > 0 and steps[steps.len - 1].type == .gone;
    switch (answer.completeness.verdict) {
        .complete => {
            if (last_is_gone) return "I5: a chain ends at a gone step but claims to be complete";
            if (answer.completeness.reason != null) return "I5: a complete chain names a reason";
        },
        .truncated => {
            if (answer.completeness.reason == null) return "I5: a truncated chain names no reason";
            if (answer.completeness.at == null) return "I5: a truncated chain names no last step";
            if (!last_is_gone) {
                return "I5: a truncated chain does not end with the step that says so";
            }
            const reason = steps[steps.len - 1].reason orelse
                return "I5: the gone step of a truncated chain names no reason";
            if (reason != answer.completeness.reason.?) {
                return "I5: the gone step and the completeness name different reasons";
            }
        },
    }
    return null;
}

/// What a decision's embedded copy renders as, which is `why`'s own form (`copied_text`).
fn copied_form(ctx: *const Context, terminal: Terminal) ?[]const u8 {
    const evidence = terminal.evidence orelse return null;
    const key = terminal.key orelse return null;
    const revision = terminal.revision orelse return null;
    return controller.format(ctx, "{s} at revision {d}: {s}", .{ key, revision, evidence }) catch
        null;
}

/// Step 3's comparison of one answer with what step 1 recorded.
fn compare(ctx: *const Context, entry: Entry, answer: *const why_mod.Result) Found {
    const steps = answer.steps;
    // Nothing may be shown that is neither what was recorded nor the decision's copy of it.
    var terminal_now: ?why_mod.Step = null;
    for (steps) |step| {
        switch (step.type) {
            .observed, .desired => terminal_now = step,
            else => {},
        }
    }
    const recorded = entry.terminal orelse return null;
    switch (recorded.type) {
        .observed, .desired => {},
        else => return null, // A resync or a lease has no key to disturb.
    }
    switch (answer.completeness.verdict) {
        .truncated => {
            // Truncated is only honest when there was nothing to show it from; with the evidence
            // embedded the chain must stay complete.
            if (recorded.evidence != null and answer.completeness.reason.? == .compacted) {
                return "§5: a decision that embeds its evidence was truncated as compacted";
            }
            const shown = terminal_now orelse return null;
            if (!std.mem.eql(u8, shown.text, recorded.text)) {
                return "§5: a truncated chain renders a terminal it cannot back";
            }
            return null;
        },
        .complete => {
            const shown = terminal_now orelse return "§5: a complete chain has no terminal";
            if (std.mem.eql(u8, shown.text, recorded.text)) return null;
            if (copied_form(ctx, recorded)) |copy| {
                if (std.mem.eql(u8, shown.text, copy)) return null;
            }
            return "§5: a complete chain renders evidence other than the recorded";
        },
    }
}

/// `value` with its first integer member other than `v` raised by one: the same record, as a
/// later writer might have left it. Null when it has none (the caller deletes the key instead).
fn changed_value(arena: Allocator, raw: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return null;
    if (parsed != .object) return null;
    var it = parsed.object.iterator();
    while (it.next()) |member| {
        if (std.mem.eql(u8, member.key_ptr.*, "v")) continue;
        if (member.value_ptr.* != .integer) continue;
        member.value_ptr.* = .{ .integer = member.value_ptr.integer +| 1 };
        return try std.json.Stringify.valueAlloc(arena, parsed, .{});
    }
    return null;
}

// ---- Tests -------------------------------------------------------------------------------------

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

test "every decision of a scenario stays explained once its cited keys changed and were compacted" {
    // Goal: authority.md §5's acceptance test over the real core. Method: apply, kill a replica,
    // scale up and scale down, recording after each step; then disturb every cited key, compact,
    // and verify every recorded decision.
    const world = try sim_world.World.create(testing.allocator, 5, &sim_runtime.default_fixtures);
    defer world.destroy();
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    _ = try world.apply(hello);
    world.advance(2000);
    var ctx = world.controller_context();
    try recorder.record_listed(&ctx);
    try world.kill("hello-2");
    world.advance(2000);
    ctx = world.controller_context();
    try recorder.record_listed(&ctx);
    var scaled = hello;
    scaled.replicas = 5;
    scaled.request_id = "r-0000002";
    _ = try world.apply(scaled);
    world.advance(2000);
    ctx = world.controller_context();
    try recorder.record_listed(&ctx);
    try testing.expect(recorder.counts.recorded > 10);

    try recorder.disturb(&ctx);
    try testing.expect(recorder.counts.keys_deleted + recorder.counts.keys_changed > 0);
    ctx = world.controller_context();
    const found = recorder.verify(&ctx);
    if (found) |sentence| std.debug.print("acceptance: {s}\n", .{sentence});
    try testing.expect(found == null);

    try testing.expect(recorder.counts.complete > recorder.counts.truncated);
}
