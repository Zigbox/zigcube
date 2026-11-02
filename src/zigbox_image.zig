//! Getting the locked tree onto the node, then starting the container: `start_with_image`. C2
//! slice 1. It is the decision of `zigbox_supervisor.zig`, kept apart from the process so that a
//! table of cases can drive it with fake steps.
//!
//! Zigbox's `start` with an image looks the tree up in the store and refuses with ZBX-E0410 when
//! it is not there, before it creates anything. So the order is: try to start; on E0410, and only
//! if the node has a reference for the tree, pull it, check that the pull produced the tree the
//! service names (ZC-E0510 if not), and start again. A tree that is already in the store costs
//! one attempt and no network.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const diag_mod = @import("diag.zig");

const Diagnostic = diag_mod.Diagnostic;

/// What the decision does to the world: two calls, with a context of the caller's.
pub const Steps = struct {
    context: *anyopaque,
    /// Starts the container from the tree; `error.StartFailed` with the reason in `diag`.
    start: *const fn (context: *anyopaque, diag: *zigbox.diag.Diag) error{StartFailed}!void,
    /// Pulls `reference` into the store and returns the digest text of the tree it produced
    /// (valid until the next call), or `error.Failed` with the reason in `diag`.
    pull: *const fn (
        context: *anyopaque,
        reference: []const u8,
        diag: *zigbox.diag.Diag,
    ) error{Failed}![]const u8,
};

pub const Outcome = union(enum) {
    /// The container is running (`start` returned).
    started,
    /// It is not, and this is why.
    failed: Diagnostic,
};

/// How far the image got, for the supervisor's log line.
pub const Trace = struct {
    pulled: bool = false,
};

pub fn start_with_image(
    steps: Steps,
    tree: []const u8,
    reference: []const u8,
    trace: *Trace,
) Outcome {
    assert(tree.len > 0);
    var collector: zigbox.diag.Diag = undefined;
    collector.reset();
    if (steps.start(steps.context, &collector)) |_| {
        return .started;
    } else |_| {}
    if (collector.code != .E0410 or reference.len == 0) return foreign_failure(&collector);
    collector.reset();
    const produced = steps.pull(steps.context, reference, &collector) catch
        return foreign_failure(&collector);
    trace.pulled = true;
    if (!std.mem.eql(u8, produced, tree)) return .{ .failed = mismatch(reference, produced, tree) };
    collector.reset();
    steps.start(steps.context, &collector) catch return foreign_failure(&collector);
    return .started;
}

fn foreign_failure(collector: *const zigbox.diag.Diag) Outcome {
    var out: Diagnostic = undefined;
    zigbox.diagnostic.from_diag(&out, collector);
    return .{ .failed = out };
}

fn mismatch(reference: []const u8, produced: []const u8, tree: []const u8) Diagnostic {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.E0510);
    collector.cause("the image at {s} unpacks to {s}, not {s}", .{ reference, produced, tree });
    collector.fix(.{ .sentence = "pull the reference with zbx, and put the tree digest it " ++
        "prints in the service file" });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

/// Scripted steps: what each call answers, and how many calls were made.
const Script = struct {
    /// The code `start` fails with on its first call (null: it works), and on later calls.
    first_start: ?zigbox.codes.Code,
    later_start: ?zigbox.codes.Code,
    pull_code: ?zigbox.codes.Code,
    produces: []const u8,
    starts: u32 = 0,
    pulls: u32 = 0,

    fn steps(script: *Script) Steps {
        return .{ .context = script, .start = start, .pull = pull };
    }

    fn start(context: *anyopaque, diag: *zigbox.diag.Diag) error{StartFailed}!void {
        const script: *Script = @ptrCast(@alignCast(context));
        script.starts += 1;
        const code = if (script.starts == 1) script.first_start else script.later_start;
        const failure = code orelse return;
        diag.raise(failure);
        return error.StartFailed;
    }

    fn pull(
        context: *anyopaque,
        reference: []const u8,
        diag: *zigbox.diag.Diag,
    ) error{Failed}![]const u8 {
        const script: *Script = @ptrCast(@alignCast(context));
        assert(reference.len > 0);
        script.pulls += 1;
        if (script.pull_code) |failure| {
            diag.raise(failure);
            return error.Failed;
        }
        return script.produces;
    }
};

const locked = "b3:51aa9c03";
const sample_reference = "ghcr.io/o/r@sha256:00";

fn run(script: *Script, with_reference: bool) struct { Outcome, Trace } {
    var trace: Trace = .{};
    const reference = if (with_reference) sample_reference else "";
    const outcome = start_with_image(script.steps(), locked, reference, &trace);
    return .{ outcome, trace };
}

test "a tree in the store starts at once and pulls nothing" {
    var script: Script = .{
        .first_start = null,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expect(!trace.pulled);
    try testing.expectEqual(@as(u32, 1), script.starts);
    try testing.expectEqual(@as(u32, 0), script.pulls);
}

test "a missing tree is pulled once, checked against the lock, and started" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expect(trace.pulled);
    try testing.expectEqual(@as(u32, 2), script.starts);
    try testing.expectEqual(@as(u32, 1), script.pulls);
}

test "a missing tree with no reference stays ZBX-E0410 and pulls nothing" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, _ = run(&script, false);
    try testing.expectEqualStrings("ZBX-E0410", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 0), script.pulls);
}

test "a pull that gives another tree is ZC-E0510 and nothing is started" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = "b3:aa11",
    };
    const outcome, const trace = run(&script, true);
    try testing.expectEqualStrings("ZC-E0510", outcome.failed.code.slice());
    try testing.expect(trace.pulled);
    try testing.expectEqual(@as(u32, 1), script.starts);
}

test "a pull that fails keeps Zigbox's diagnostic" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = .E0501,
        .produces = locked,
    };
    const outcome, const trace = run(&script, true);
    try testing.expectEqualStrings("ZBX-E0501", outcome.failed.code.slice());
    try testing.expect(!trace.pulled);
}

test "a start that fails for another reason is not pulled for" {
    var script: Script = .{
        .first_start = .E0425,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, _ = run(&script, true);
    try testing.expectEqualStrings("ZBX-E0425", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 0), script.pulls);
}

test "a second start that fails is reported, and the pull is not repeated" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = .E0425,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, _ = run(&script, true);
    try testing.expectEqualStrings("ZBX-E0425", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 1), script.pulls);
    try testing.expectEqual(@as(u32, 2), script.starts);
}
