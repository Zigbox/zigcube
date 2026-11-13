//! `zcube why grant <from> <to>:<port>` (and `why connection`, its alias), as a core function
//! (docs/briefs/c4.md, "Grants and their compilation"; docs/api.md, "GET /v1/why/grant"). It
//! evaluates one grant with the mesh plan's own `check` over a snapshot, so it says what the
//! agents compile, and adds who changed the destination's grants, from its `grant` decisions:
//!
//! - no such grant: ZC-E0707, the grants the destination has and who added each (and who removed
//!   this one, if a kept decision says so);
//! - a grant from a service that does not exist: ZC-W0704;
//! - a grant with no endpoint: ZC-E0709, and why each replica of the destination is not one;
//! - granted: which replicas are endpoints, and why the others are not.
//!
//! The decisions read are the destination's newest `decisions_per_subject_max` index entries,
//! retention's own bound, so every `grant` decision the store keeps is seen.

const std = @import("std");
const assert = std.debug.assert;
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const mesh_plan = @import("mesh_plan.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const zigbox = @import("zigbox");

const Allocator = std.mem.Allocator;
const Context = controller.Context;

pub const Error = controller.Error || error{NotFound};

/// The `grant` decision that last added (or removed) a grant.
pub const Attribution = struct {
    decision: []const u8,
    at_ms: u64,
    /// Who applied the change, as the decision's reason names them.
    by: []const u8,
};

/// One grant of the destination, and the decision that added it, if one is kept.
pub const Allowed = struct {
    from: []const u8,
    port: u32,
    added: ?Attribution = null,
};

/// A replica of the destination that is not an endpoint, and why, as a client prints it.
pub const Excluded = struct {
    replica: []const u8,
    node: ?[]const u8,
    exclusion: mesh_plan.Exclusion,
    text: []const u8,
};

pub const Result = struct {
    v: u32 = 1,
    revision: store.Revision,
    from: []const u8,
    to: []const u8,
    port: u16,
    verdict: mesh_plan.Verdict,
    /// The sentence every client prints first.
    text: []const u8,
    /// ZC-E0707, ZC-E0709 or ZC-W0704 in the JSON of DIAGNOSTICS.md, when the verdict has one.
    diagnostic: ?records.Raw = null,
    /// The destination's grants, in its `allow` order.
    allows: []const Allowed,
    /// For a grant that is not there: the newest kept decision that removed it.
    removed: ?Attribution = null,
    endpoints: []const mesh_plan.Endpoint,
    excluded: []const Excluded,
};

/// Evaluates `query` now. A destination that does not exist is ZC-E0101.
pub fn why_grant(ctx: *const Context, query: mesh_plan.GrantQuery) Error!Result {
    assert(query.port > 0);
    assert(query.from.len > 0);
    const snapshot = try controller.read_snapshot(ctx);
    const input = mesh_plan.input_of(ctx.arena, &snapshot) catch
        return failures.no_memory(ctx.diag);
    const checked = mesh_plan.check(ctx.arena, &input, query) catch
        return failures.no_memory(ctx.diag);
    if (checked.verdict == .no_destination) return not_found(ctx, query.to);
    const destination = mesh_plan.find_service(&input, query.to).?;
    var result: Result = .{
        .revision = snapshot.revision,
        .from = query.from,
        .to = query.to,
        .port = query.port,
        .verdict = checked.verdict,
        .text = "",
        .allows = &.{},
        .endpoints = checked.endpoints,
        .excluded = try excluded_of(ctx, checked.excluded),
    };
    try attribute(ctx, destination.allow, query, &result);
    result.text = try text_of(ctx, &result);
    result.diagnostic = try diagnostic_of(ctx, &result);
    if (result.verdict == .granted) assert(result.endpoints.len > 0);
    assert(result.text.len > 0);
    return result;
}

fn excluded_of(ctx: *const Context, excluded: []const mesh_plan.Excluded) Error![]const Excluded {
    const result = ctx.arena.alloc(Excluded, excluded.len) catch
        return failures.no_memory(ctx.diag);
    for (excluded, result) |from, *to| {
        const text = switch (from.exclusion) {
            .draining => "draining: it takes no new connections",
            .no_endpoint => "no mesh endpoint published yet",
            .not_ready => try format(ctx, "not ready: {s}", .{readiness_text(from.readiness)}),
        };
        to.* = .{
            .replica = from.replica,
            .node = from.node,
            .exclusion = from.exclusion,
            .text = text,
        };
    }
    assert(result.len == excluded.len);
    return result;
}

fn readiness_text(readiness: mesh_plan.Readiness) []const u8 {
    assert(readiness != .ready);
    return switch (readiness) {
        .ready => unreachable, // Asserted above: a ready replica is excluded for another reason.
        .not_assigned => "not placed on a node",
        .not_reported => "its node has not reported it yet",
        .starting => "starting",
        .stopped => "stopped",
        .not_healthy => "its health check has not passed",
    };
}

// ---- Who changed the grants ----

/// Fills `result.allows` and `result.removed` from the destination's kept `grant` decisions,
/// newest first: each grant is attributed to the newest decision that added it.
fn attribute(
    ctx: *const Context,
    allow: []const records.Grant,
    query: mesh_plan.GrantQuery,
    result: *Result,
) Error!void {
    const allows = ctx.arena.alloc(Allowed, allow.len) catch return failures.no_memory(ctx.diag);
    for (allow, allows) |grant, *allowed| allowed.* = .{ .from = grant.from, .port = grant.port };
    result.allows = allows;
    const wanted: records.Grant = .{ .from = query.from, .port = query.port };
    var removed_wanted = !records.grants_contain(allow, wanted);
    var left = allow.len + @intFromBool(removed_wanted);
    const prefix = records.index_prefix(.service, query.to);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = constants.decisions_per_subject_max,
        .reverse = true,
    }, ctx.diag);
    for (page.kvs) |kv| {
        if (left == 0) break;
        const entry = try records.read(records.IndexEntry, ctx.arena, kv, ctx.diag);
        if (!std.mem.eql(u8, entry.action, "grant")) continue;
        const decision = try fetch_decision(ctx, entry.id) orelse continue;
        const change = decision.change orelse continue;
        const attribution: Attribution = .{
            .decision = decision.id,
            .at_ms = decision.at_ms,
            .by = by_of(decision),
        };
        for (allows) |*allowed| {
            if (allowed.added != null) continue;
            const grant: records.Grant = .{ .from = allowed.from, .port = allowed.port };
            if (!change_names(change, grant, "added")) continue;
            allowed.added = attribution;
            left -= 1;
        }
        if (removed_wanted and change_names(change, wanted, "removed")) {
            result.removed = attribution;
            removed_wanted = false;
            left -= 1;
        }
    }
}

fn fetch_decision(ctx: *const Context, id: []const u8) Error!?records.Decision {
    if (records.decision_id_time(id) == null) return null;
    const key = records.decision_key(id);
    const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = got.kv orelse return null; // Dropped by retention after its index entry was read.
    return try records.read(records.Decision, ctx.arena, kv, ctx.diag);
}

/// Who applied it: the reason is "<who> changed who may connect to <service> (request <id>)"
/// (apply.zig); any other reason names the actor.
fn by_of(decision: records.Decision) []const u8 {
    assert(std.mem.eql(u8, decision.action, "grant"));
    const marker = " changed who may connect to ";
    const end = std.mem.indexOf(u8, decision.reason, marker) orelse return decision.actor;
    if (end == 0) return decision.actor;
    return decision.reason[0..end];
}

/// Whether a decision's change ("web → 5432 added, batch → 80 removed") names `grant` as `how`.
fn change_names(change: []const u8, grant: records.Grant, comptime how: []const u8) bool {
    assert(grant.port > 0);
    var buffer: [constants.service_name_bytes_max + 32]u8 = undefined;
    const part = std.fmt.bufPrint(&buffer, "{s} → {d} " ++ how, .{ grant.from, grant.port }) catch
        return false; // A name longer than any service's: no change names it.
    var parts = std.mem.splitSequence(u8, change, ", ");
    while (parts.next()) |held| {
        if (std.mem.eql(u8, held, part)) return true;
    }
    return false;
}

// ---- The words ----

fn text_of(ctx: *const Context, result: *const Result) Error![]const u8 {
    const grant = try format(ctx, "{s} → {s}:{d}", .{ result.from, result.to, result.port });
    return switch (result.verdict) {
        .no_destination => unreachable, // `why_grant` answers ZC-E0101 first.
        .no_grant => no_grant_text(ctx, result, grant),
        .no_source => format(ctx, "{s} is granted, and no service {s} exists (ZC-W0704)", .{
            grant, result.from,
        }),
        .destination_has_no_address => format(
            ctx,
            "{s} is granted, and {s} has no mesh address yet: apply it again",
            .{ grant, result.to },
        ),
        .source_has_no_address => format(
            ctx,
            "{s} is granted, and {s} has no mesh address yet: apply it again",
            .{ grant, result.from },
        ),
        .no_endpoint => format(ctx, "{s} is granted, and {s} has no ready replica (ZC-E0709){s}", .{
            grant, result.to, try excluded_text(ctx, result.excluded),
        }),
        .granted => format(ctx, "{s} is granted; endpoints: {s}{s}", .{
            grant,
            try endpoints_text(ctx, result.endpoints),
            try excluded_text(ctx, result.excluded),
        }),
    };
}

/// "no grant batch → db:5432 (ZC-E0707); db allows: web → 5432 (added by alex at …)".
fn no_grant_text(ctx: *const Context, result: *const Result, grant: []const u8) Error![]const u8 {
    assert(result.verdict == .no_grant);
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &text.writer;
    writer.print("no grant {s} (ZC-E0707); {s} allows: ", .{ grant, result.to }) catch
        return failures.no_memory(ctx.diag);
    if (result.allows.len == 0) {
        writer.writeAll("nothing") catch return failures.no_memory(ctx.diag);
    }
    for (result.allows, 0..) |allowed, index| {
        if (index > 0) writer.writeAll(", ") catch return failures.no_memory(ctx.diag);
        writer.print("{s} → {d}", .{ allowed.from, allowed.port }) catch
            return failures.no_memory(ctx.diag);
        const added = allowed.added orelse continue;
        write_attribution(writer, "added", added) catch return failures.no_memory(ctx.diag);
    }
    if (result.removed) |removed| {
        writer.print("; {s} → {d}", .{ result.from, result.port }) catch
            return failures.no_memory(ctx.diag);
        write_attribution(writer, "removed", removed) catch return failures.no_memory(ctx.diag);
    }
    return text.written();
}

fn write_attribution(
    writer: *std.Io.Writer,
    comptime how: []const u8,
    attribution: Attribution,
) std.Io.Writer.Error!void {
    try writer.print(" (" ++ how ++ " by {s} at ", .{attribution.by});
    try write_time(writer, attribution.at_ms);
    try writer.writeAll(")");
}

/// `2026-11-13 10:00:00Z`, as `zcube why` prints its summaries.
fn write_time(writer: *std.Io.Writer, at_ms: u64) std.Io.Writer.Error!void {
    const since: std.time.epoch.EpochSeconds = .{ .secs = at_ms / 1000 };
    const date = since.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    const clock = since.getDaySeconds();
    try writer.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{
        date.year,
        @backingInt(month.month),
        month.day_index + 1,
        clock.getHoursIntoDay(),
        clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),
    });
}

/// "db-1 on node1, db-2 on node2".
fn endpoints_text(ctx: *const Context, endpoints: []const mesh_plan.Endpoint) Error![]const u8 {
    assert(endpoints.len > 0);
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    for (endpoints, 0..) |endpoint, index| {
        const separator = if (index == 0) "" else ", ";
        text.writer.print("{s}{s} on {s}", .{ separator, endpoint.replica, endpoint.node }) catch
            return failures.no_memory(ctx.diag);
    }
    return text.written();
}

/// "; not endpoints: db-3 on node3 (draining: ...)", or nothing.
fn excluded_text(ctx: *const Context, excluded: []const Excluded) Error![]const u8 {
    if (excluded.len == 0) return "";
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    const writer = &text.writer;
    writer.writeAll("; not endpoints: ") catch return failures.no_memory(ctx.diag);
    for (excluded, 0..) |replica, index| {
        if (index > 0) writer.writeAll(", ") catch return failures.no_memory(ctx.diag);
        writer.print("{s} on {s} ({s})", .{
            replica.replica, replica.node orelse "no node", replica.text,
        }) catch return failures.no_memory(ctx.diag);
    }
    assert(text.written().len > 0);
    return text.written();
}

fn format(ctx: *const Context, comptime pattern: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(ctx.arena, pattern, args) catch failures.no_memory(ctx.diag);
}

// ---- The diagnostic ----

fn diagnostic_of(ctx: *const Context, result: *const Result) Error!?records.Raw {
    return switch (result.verdict) {
        .no_grant => try diagnostic_text(ctx, .E0707, try format(
            ctx,
            "{s} allows no connection from {s} on port {d}",
            .{ result.to, result.from, result.port },
        ), try format(
            ctx,
            "add {{ .from = \"{s}\", .port = {d} }} to {s}'s allow and apply it",
            .{ result.from, result.port, result.to },
        )),
        .no_source => try diagnostic_text(ctx, .W0704, try format(
            ctx,
            "{s} allows {s} on port {d}, and no service {s} exists",
            .{ result.to, result.from, result.port, result.from },
        ), "correct the name in allow if it is a typo, or create the service"),
        .no_endpoint => try diagnostic_text(ctx, .E0709, try format(
            ctx,
            "{s} has {d} replicas and none is ready with a mesh endpoint",
            .{ result.to, result.excluded.len },
        ), try format(ctx, "zcube why service {s}", .{result.to})),
        .granted, .destination_has_no_address, .source_has_no_address => null,
        .no_destination => unreachable, // `why_grant` answers ZC-E0101 first.
    };
}

fn diagnostic_text(
    ctx: *const Context,
    comptime code: codes.Code,
    cause: []const u8,
    fix: []const u8,
) Error!records.Raw {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(code);
    collector.cause("{s}", .{cause});
    collector.fix(.{ .sentence = fix });
    const diagnostic = ctx.arena.create(zigbox.diagnostic.Diagnostic) catch
        return failures.no_memory(ctx.diag);
    diag_mod.to_diagnostic(diagnostic, &collector);
    diagnostic.docs = .{};
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    zigbox.diagnostic.write_json(&text.writer, diagnostic) catch
        return failures.no_memory(ctx.diag);
    const written = text.written();
    assert(written.len > 1);
    assert(written[written.len - 1] == '\n');
    return .{ .text = written[0 .. written.len - 1] };
}

fn not_found(ctx: *const Context, name: []const u8) error{NotFound} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("service {s} does not exist", .{name});
    ctx.diag.fix(.{ .sentence = "list what exists", .command = "zcube get service" });
    return error.NotFound;
}

// ---- Tests ----

const testing = std.testing;
const apply_mod = @import("apply.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const writers = @import("writers.zig");

fn service(name: []const u8, allow: []const records.Grant) apply_mod.Input {
    return .{
        .name = name,
        .image = "b3:51aa9c03",
        .replicas = 2,
        .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
        .allow = allow,
        .applied_by = "alex@laptop",
        .request_id = "r-0000001",
    };
}

const web_5432 = [_]records.Grant{.{ .from = "web", .port = 5432 }};

/// A world running `db` (which allows web on 5432), `web` and `batch`.
fn demo_world(seed: u64) !*sim_world.World {
    const fixtures = &sim_runtime.default_fixtures;
    const world = try sim_world.World.create(testing.allocator, seed, fixtures);
    errdefer world.destroy();
    _ = try world.apply(service("db", &web_5432));
    _ = try world.apply(service("web", &.{}));
    _ = try world.apply(service("batch", &.{}));
    world.advance(2000);
    return world;
}

/// Publishes a mesh endpoint for every running replica of `name`, as its agent would.
fn publish_endpoints(world: *sim_world.World, name: []const u8) !void {
    const ctx = world.controller_context();
    const snapshot = try controller.read_snapshot(&ctx);
    for (snapshot.observed) |entry| {
        if (!std.mem.startsWith(u8, entry.kv.key, records.prefix_observed)) continue;
        const rest = entry.kv.key[records.prefix_observed.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/').?;
        const replica = rest[slash + 1 ..];
        if (!std.mem.startsWith(u8, replica, name)) continue;
        if (replica[name.len] != '-') continue;
        var observed = entry.rec;
        observed.endpoint = "10.0.0.1:30000";
        const bytes = try records.encode(ctx.arena, observed, ctx.diag);
        const op: store.Op = .{ .put = .{ .key = entry.kv.key, .value = bytes } };
        const role: writers.Role = .{ .agent = rest[0..slash] };
        _ = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, ctx.diag);
    }
}

test "why grant: no grant is ZC-E0707 and names the destination's grants and who added them" {
    // Goal: the brief's example, "no grant batch → db:5432 (ZC-E0707); db allows: web → 5432
    // (added by … at …)". Method: db allows web; ask for batch.
    const world = try demo_world(11);
    defer world.destroy();
    const ctx = world.controller_context();
    const result = try why_grant(&ctx, .{ .from = "batch", .to = "db", .port = 5432 });
    try testing.expectEqual(mesh_plan.Verdict.no_grant, result.verdict);
    const wanted = "no grant batch → db:5432 (ZC-E0707); db allows: " ++
        "web → 5432 (added by alex@laptop at ";
    try testing.expect(std.mem.startsWith(u8, result.text, wanted));
    try testing.expect(result.allows[0].added != null);
    try testing.expect(std.mem.indexOf(u8, result.diagnostic.?.text, "ZC-E0707") != null);
    try testing.expect(result.removed == null);
}

test "why grant: a grant with no endpoint is ZC-E0709, then granted once replicas publish one" {
    // Goal: the endpoint half of the answer: which replicas are endpoints and why the others are
    // not. Method: the simulated agents publish no endpoint; publish one for db's replicas.
    const world = try demo_world(12);
    defer world.destroy();
    const ctx = world.controller_context();
    const query: mesh_plan.GrantQuery = .{ .from = "web", .to = "db", .port = 5432 };
    const before = try why_grant(&ctx, query);
    try testing.expectEqual(mesh_plan.Verdict.no_endpoint, before.verdict);
    try testing.expectEqual(@as(usize, 2), before.excluded.len);
    try testing.expectEqual(mesh_plan.Exclusion.no_endpoint, before.excluded[0].exclusion);
    try testing.expect(std.mem.indexOf(u8, before.diagnostic.?.text, "ZC-E0709") != null);
    try testing.expect(std.mem.indexOf(u8, before.text, "no mesh endpoint published yet") != null);

    try publish_endpoints(world, "db");
    const after = try why_grant(&ctx, query);
    try testing.expectEqual(mesh_plan.Verdict.granted, after.verdict);
    try testing.expectEqual(@as(usize, 2), after.endpoints.len);
    try testing.expectEqual(@as(usize, 0), after.excluded.len);
    try testing.expect(after.diagnostic == null);
    const granted = "web → db:5432 is granted; endpoints: db-";
    try testing.expect(std.mem.startsWith(u8, after.text, granted));
}

test "why grant: a removed grant says who removed it, a missing source is ZC-W0704" {
    // Goal: the `removed` attribution and W0704. Method: db's grant to web is replaced by one to
    // cache, which does not exist; then the destination does not exist at all (ZC-E0101).
    const world = try demo_world(13);
    defer world.destroy();
    const cache_80 = [_]records.Grant{.{ .from = "cache", .port = 80 }};
    _ = try world.apply(service("db", &cache_80));
    var ctx = world.controller_context();
    const removed = try why_grant(&ctx, .{ .from = "web", .to = "db", .port = 5432 });
    try testing.expectEqual(mesh_plan.Verdict.no_grant, removed.verdict);
    try testing.expect(removed.removed != null);
    try testing.expectEqualStrings("alex@laptop", removed.removed.?.by);
    const by = "; web → 5432 (removed by alex@laptop at ";
    try testing.expect(std.mem.indexOf(u8, removed.text, by) != null);

    const ghost = try why_grant(&ctx, .{ .from = "cache", .to = "db", .port = 80 });
    try testing.expectEqual(mesh_plan.Verdict.no_source, ghost.verdict);
    try testing.expect(std.mem.indexOf(u8, ghost.diagnostic.?.text, "ZC-W0704") != null);

    const nowhere: mesh_plan.GrantQuery = .{ .from = "web", .to = "nope", .port = 1 };
    try testing.expectError(error.NotFound, why_grant(&ctx, nowhere));
    try testing.expectEqual(codes.Code.E0101, ctx.diag.code.?);
}
