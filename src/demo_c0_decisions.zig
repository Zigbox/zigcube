//! HANDOFF's acceptance criterion for the controllers: "Every controller action is recorded with
//! its cause and visible to `zcube why`." After each step, `expect_new` reads the decisions the
//! step added to the store and asserts exactly the ones that step should have made, each with a
//! reason and a cause that leads somewhere; `expect_all_explained` asks the server's `why` for
//! every decision of the run.

const std = @import("std");
const assert = std.debug.assert;
const state = @import("demo_c0_state.zig");

const Demo = state.Demo;
const Json = state.Json;

pub const Decision = struct {
    id: []const u8,
    actor: []const u8,
    action: []const u8,
    subject_kind: []const u8,
    subject_name: []const u8,
    reason: []const u8,
    cause_kind: []const u8,
    /// The cause's key (desired, observed) or decision id (decision).
    cause_ref: []const u8,
};

/// What a step should have decided: `count` decisions of this actor and action.
pub const Expect = struct { actor: []const u8, action: []const u8, count: u32 };

fn text_of(object: std.json.ObjectMap, name: []const u8) []const u8 {
    const value = object.get(name) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

/// Every decision in the store, oldest first (ids start with the time, and keys are ordered).
pub fn read_all(demo: *Demo) ![]const Decision {
    const host = demo.host;
    const listed = try host.json("/v1/list?prefix=/decisions/&limit=500");
    var found: std.ArrayList(Decision) = .empty;
    for (listed.object.get("kvs").?.array.items) |kv| {
        const value = kv.object.get("value").?.object;
        const subject = value.get("subject").?.object;
        const cause = value.get("cause").?.object;
        const kind = text_of(cause, "kind");
        const reference = if (std.mem.eql(u8, kind, "decision"))
            text_of(cause, "id")
        else
            text_of(cause, "key");
        try found.append(host.arena(), .{
            .id = text_of(value, "id"),
            .actor = text_of(value, "actor"),
            .action = text_of(value, "action"),
            .subject_kind = text_of(subject, "kind"),
            .subject_name = text_of(subject, "name"),
            .reason = text_of(value, "reason"),
            .cause_kind = kind,
            .cause_ref = reference,
        });
    }
    return found.items;
}

fn find_decision(all: []const Decision, id: []const u8) bool {
    for (all) |decision| {
        if (std.mem.eql(u8, decision.id, id)) return true;
    }
    return false;
}

fn count_of(new: []const Decision, expect: Expect) u32 {
    var count: u32 = 0;
    for (new) |decision| {
        if (!std.mem.eql(u8, decision.actor, expect.actor)) continue;
        if (std.mem.eql(u8, decision.action, expect.action)) count += 1;
    }
    return count;
}

fn known_cause_kind(kind: []const u8) bool {
    const kinds = [_][]const u8{ "desired", "observed", "decision", "resync", "lease_expired" };
    for (kinds) |known| {
        if (std.mem.eql(u8, kind, known)) return true;
    }
    return false;
}

/// The decisions made since the last call are exactly `expected`, and each one has a reason and a
/// cause that exists. Prints them: this is the record of what the controllers did.
pub fn expect_new(demo: *Demo, comptime label: []const u8, expected: []const Expect) !void {
    const host = demo.host;
    const all = try read_all(demo);
    try host.check_quiet(all.len >= demo.decisions_seen, "decisions were removed", .{});
    const new = all[demo.decisions_seen..];
    host.say("  decisions recorded by this step ({d}):", .{new.len});
    for (new) |decision| {
        host.say("    {s} {s} {s} {s}: {s}  [cause: {s} {s}]", .{
            decision.actor,  decision.action,     decision.subject_kind, decision.subject_name,
            decision.reason, decision.cause_kind, decision.cause_ref,
        });
    }
    var total: u32 = 0;
    for (expected) |expect| {
        const count = count_of(new, expect);
        total += expect.count;
        try host.check(count == expect.count, label ++ ": {d} x {s} {s} (expected {d})", .{
            count, expect.actor, expect.action, expect.count,
        });
    }
    try host.check(new.len == total, label ++ ": no decision beyond those ({d} of {d})", .{
        total, new.len,
    });
    for (new) |decision| try check_cause(demo, all, decision);
    demo.decisions_seen = @intCast(all.len);
}

fn check_cause(demo: *Demo, all: []const Decision, decision: Decision) !void {
    const host = demo.host;
    try host.check_quiet(decision.reason.len > 0, "decision {s} has no reason", .{decision.id});
    try host.check_quiet(known_cause_kind(decision.cause_kind), "decision {s}: cause kind '{s}'", .{
        decision.id, decision.cause_kind,
    });
    if (std.mem.eql(u8, decision.cause_kind, "decision")) {
        const present = find_decision(all, decision.cause_ref);
        try host.check_quiet(present, "decision {s}: its cause {s} is gone", .{
            decision.id, decision.cause_ref,
        });
    }
}

/// Every decision of the run is visible to `why`: the chain that starts at it names it first, and
/// ends at something that exists (a desired or observed key), not at `gone`.
pub fn expect_all_explained(demo: *Demo) !void {
    const host = demo.host;
    const all = try read_all(demo);
    var explained: u32 = 0;
    for (all) |decision| {
        const path = try std.fmt.allocPrint(host.arena(), "/v1/why/{s}/{s}?decision={s}", .{
            decision.subject_kind, decision.subject_name, decision.id,
        });
        const why = try host.json(path);
        const steps = why.object.get("steps").?.array.items;
        try host.check_quiet(steps.len > 0, "why for decision {s} has no steps", .{decision.id});
        const first = steps[0].object;
        const first_id = text_of(first.get("decision").?.object, "id");
        const starts_here = std.mem.eql(u8, first_id, decision.id);
        try host.check_quiet(starts_here, "why starts at {s}, not {s}", .{
            first_id, decision.id,
        });
        const last_type = text_of(steps[steps.len - 1].object, "type");
        try host.check_quiet(!std.mem.eql(u8, last_type, "gone"), "why for {s} ends at 'gone'", .{
            decision.id,
        });
        explained += 1;
    }
    try host.check(
        explained == all.len and all.len > 0,
        "all {d} decisions of the run have a reason, a cause, and a chain in /v1/why",
        .{all.len},
    );
}
