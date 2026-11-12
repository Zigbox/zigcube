//! Getting the locked tree onto the node, then starting the container: `start_with_image`. C2
//! slice 1. It is the decision of `zigbox_supervisor.zig`, kept apart from the process so that a
//! table of cases can drive it with fake steps.
//!
//! Zigbox's `start` with an image looks the tree up in the store and refuses with ZBX-E0410 when
//! it is not there, before it creates anything. So the order is: try to start; on E0410, and only
//! if the node has a reference for the tree, pull it, check that the pull produced the tree the
//! service names (ZC-E0511 if not), and start again. A tree that is already in the store costs
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
    /// Asks the swarm for the tree (the peers, `zcube-agent fetch`). Null: the node has no peers
    /// to ask (no server, or no manifest to hold them to).
    fetch: ?*const fn (context: *anyopaque) Fetched = null,
    /// Takes the node's pull lock, waiting for it, and `leave_pull` gives it back. Zigbox's store
    /// has one writer and two pulls of one image race on its blob cache (ZBX-E0417), so the
    /// supervisors of one node take turns. Null: nothing else shares the store.
    enter_pull: ?*const fn (context: *anyopaque) void = null,
    leave_pull: ?*const fn (context: *anyopaque) void = null,
};

/// What the swarm fetch left behind.
pub const Fetched = enum {
    /// The tree is in the store.
    in_store,
    /// It is not, and the fetch is over: the pull may write the store.
    absent,
    /// A process of the fetch outlived its kill and may still write the store. Zigbox's store
    /// has one writer, so nothing else may write it: no pull (ZC-E0515).
    outlived_kill,
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
    /// The tree came from a peer.
    fetched: bool = false,
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
    // The tree is missing. From here the store is written: one supervisor at a time, and the
    // one that waited tries again first, because the one before it may have brought the tree.
    const guarded = collector.code == .E0410 and steps.enter_pull != null;
    if (guarded) steps.enter_pull.?(steps.context);
    defer if (guarded) steps.leave_pull.?(steps.context);
    if (guarded) {
        collector.reset();
        if (steps.start(steps.context, &collector)) |_| return .started else |_| {}
    }
    if (collector.code == .E0410) {
        if (steps.fetch) |fetch| switch (fetch(steps.context)) {
            .in_store => {
                trace.fetched = true;
                collector.reset();
                if (steps.start(steps.context, &collector)) |_| return .started else |_| {}
            },
            .absent => {},
            .outlived_kill => return .{ .failed = fetch_outlived_kill() },
        };
    }
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
    // Limits with no user systemd bus: the node's problem, in the words of the agent's operator.
    if (collector.code == .E0307) return .{ .failed = no_bus() };
    zigbox.diagnostic.from_diag(&out, collector);
    return .{ .failed = out };
}

/// The number after `Threads:` in the text of `/proc/self/status`.
pub fn threads_in(status: []const u8) ?u32 {
    const key = "Threads:";
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const text = std.mem.trim(u8, line[key.len..], " \t");
        return std.fmt.parseInt(u32, text, 10) catch null;
    }
    return null;
}

/// What the supervisor says when it has threads: Zigbox's start and pull make namespaces, which
/// the kernel allows only a single-threaded process. Our bug, not the host's.
pub fn not_single_threaded(count: ?u32) Diagnostic {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.B0002);
    if (count) |threads| {
        collector.cause("the supervisor has {d} threads; Zigbox needs exactly one", .{threads});
    } else {
        collector.cause("the supervisor can't tell how many threads it has", .{});
    }
    collector.fix(.{ .sentence = "report this: the supervisor must start no thread of its own" });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

fn no_bus() Diagnostic {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.E0512);
    collector.cause("Zigbox refused the service's limits (ZBX-E0307): it can't make a cgroup " ++
        "scope, because the agent's user has no systemd user bus", .{});
    collector.fix(.{ .sentence = "enable lingering for the agent's user (loginctl " ++
        "enable-linger), or remove the limits from the service file" });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

fn fetch_outlived_kill() Diagnostic {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.E0515);
    collector.cause("a process of the swarm fetch was still alive after SIGKILL to its process " ++
        "group, so the image was not pulled: the store takes one writer at a time", .{});
    collector.fix(.{
        .sentence = "find the process in state D and the disk it waits on; the start is retried",
        .command = "ps -eo pid,stat,wchan:32,args | awk '$2 ~ /D/'",
    });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    assert(std.mem.eql(u8, out.code.slice(), "ZC-E0515"));
    return out;
}

fn mismatch(reference: []const u8, produced: []const u8, tree: []const u8) Diagnostic {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.E0511);
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
    /// What the swarm fetch answers; null: the node has no peers to ask.
    fetch_answer: ?Fetched = null,
    fetches: u32 = 0,
    /// How many of the first starts fail with `first_start`.
    first_count: u32 = 1,
    /// Whether the steps have a pull lock, and how it was used.
    locked: bool = false,
    held: bool = false,
    entered: u32 = 0,
    left: u32 = 0,
    /// The pull happened while the lock was held.
    pulled_held: bool = false,

    fn steps(script: *Script) Steps {
        const asks: ?*const fn (context: *anyopaque) Fetched = if (script.fetch_answer != null)
            fetch
        else
            null;
        return .{
            .context = script,
            .start = start,
            .pull = pull,
            .fetch = asks,
            .enter_pull = if (script.locked) enter else null,
            .leave_pull = if (script.locked) leave else null,
        };
    }

    fn enter(context: *anyopaque) void {
        const script: *Script = @ptrCast(@alignCast(context));
        assert(!script.held);
        script.held = true;
        script.entered += 1;
    }

    fn leave(context: *anyopaque) void {
        const script: *Script = @ptrCast(@alignCast(context));
        assert(script.held);
        script.held = false;
        script.left += 1;
    }

    fn fetch(context: *anyopaque) Fetched {
        const script: *Script = @ptrCast(@alignCast(context));
        script.fetches += 1;
        return script.fetch_answer.?;
    }

    fn start(context: *anyopaque, diag: *zigbox.diag.Diag) error{StartFailed}!void {
        const script: *Script = @ptrCast(@alignCast(context));
        script.starts += 1;
        const failing = script.starts <= script.first_count;
        const code = if (failing) script.first_start else script.later_start;
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
        script.pulled_held = script.held;
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

test "a pull that gives another tree is ZC-E0511 and nothing is started" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = "b3:aa11",
    };
    const outcome, const trace = run(&script, true);
    try testing.expectEqualStrings("ZC-E0511", outcome.failed.code.slice());
    try testing.expect(trace.pulled);
    try testing.expectEqual(@as(u32, 1), script.starts);
}

test "limits refused for want of a user bus are ZC-E0512, and nothing is pulled" {
    var script: Script = .{
        .first_start = .E0307,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
    };
    const outcome, _ = run(&script, true);
    try testing.expectEqualStrings("ZC-E0512", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 0), script.pulls);
}

test "the thread count is read from the status text, and anything but one is refused" {
    const one = "Name:\tzcube-agent\nThreads:\t1\nVmRSS:\t5 kB\n";
    try testing.expectEqual(@as(?u32, 1), threads_in(one));
    try testing.expectEqual(@as(?u32, 3), threads_in("Threads:\t3\n"));
    try testing.expectEqual(@as(?u32, null), threads_in("Name:\tx\n"));
    try testing.expectEqual(@as(?u32, null), threads_in("Threads:\tmany\n"));
    const many = not_single_threaded(3);
    try testing.expectEqualStrings("ZC-B0002", many.code.slice());
    const unknown = not_single_threaded(null);
    try testing.expectEqualStrings("ZC-B0002", unknown.code.slice());
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

test "a tree a peer has is fetched, then started, and nothing is pulled" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .fetch_answer = .in_store,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expect(trace.fetched and !trace.pulled);
    try testing.expectEqual(@as(u32, 2), script.starts);
    try testing.expectEqual(@as(u32, 0), script.pulls);
}

test "a tree no peer has is pulled; a fetch that did not make the tree start is too" {
    var none: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .fetch_answer = .absent,
    };
    const outcome, const trace = run(&none, true);
    try testing.expect(outcome == .started);
    try testing.expect(!trace.fetched and trace.pulled);
    try testing.expectEqual(@as(u32, 1), none.fetches);
    var empty: Script = .{
        .first_start = .E0410,
        .later_start = .E0410,
        .pull_code = null,
        .produces = locked,
        .fetch_answer = .in_store,
    };
    const second, _ = run(&empty, true);
    try testing.expect(second == .failed);
    try testing.expectEqual(@as(u32, 1), empty.pulls);
    // With no reference the E0410 stays what the node says.
    var bare: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .fetch_answer = .absent,
    };
    const refused, _ = run(&bare, false);
    try testing.expect(refused == .failed);
}

test "a fetch that outlived its kill fails the start with ZC-E0515, and nothing is pulled" {
    // Goal: MUST 2 of the C2 release review. A fetch process still alive after the kill may
    // still write the store, so the pull, a second writer, must not start. Method: a script
    // whose fetch answers `outlived_kill`; the start fails with ZC-E0515 and no pull is made.
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .fetch_answer = .outlived_kill,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .failed);
    try testing.expectEqualStrings("ZC-E0515", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 0), script.pulls);
    try testing.expectEqual(@as(u32, 1), script.starts);
    try testing.expect(!trace.fetched);
    try testing.expect(!trace.pulled);
}

test "a pull is made under the node's lock, after a start that waited for it" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .first_count = 2,
        .locked = true,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expect(trace.pulled);
    try testing.expect(script.pulled_held);
    try testing.expectEqual(@as(u32, 3), script.starts);
    try testing.expectEqual(@as(u32, 1), script.entered);
    try testing.expectEqual(@as(u32, 1), script.left);
}

test "a tree the supervisor before brought is started after the wait, and not pulled" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .locked = true,
    };
    const outcome, const trace = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expectEqual(@as(u32, 2), script.starts);
    try testing.expectEqual(@as(u32, 0), script.pulls);
    try testing.expect(!trace.pulled);
    try testing.expectEqual(@as(u32, 1), script.left);
}

test "a tree in the store takes no lock" {
    var script: Script = .{
        .first_start = null,
        .later_start = null,
        .pull_code = null,
        .produces = locked,
        .locked = true,
    };
    const outcome, _ = run(&script, true);
    try testing.expect(outcome == .started);
    try testing.expectEqual(@as(u32, 0), script.entered);
}

test "the lock is given back when the pull fails" {
    var script: Script = .{
        .first_start = .E0410,
        .later_start = null,
        .pull_code = .E0417,
        .produces = locked,
        .first_count = 2,
        .locked = true,
    };
    const outcome, _ = run(&script, true);
    try testing.expectEqualStrings("ZBX-E0417", outcome.failed.code.slice());
    try testing.expectEqual(@as(u32, 1), script.left);
}
