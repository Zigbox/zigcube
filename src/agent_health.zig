//! The agent's health checks (C3 slice 9; docs/agent.md, "Health checks"). Each step, the agent
//! tracks the running containers of its replicas that have a check, takes the results of the
//! checks in flight and begins the due ones, through `Runtime.probe_begin` and `probe_poll`, which
//! never block; `probe_scheduler` keeps the times and the counts. `fill` then puts what the checks
//! say into the replica's observed record. Core code: no files, clocks or sockets of its own.
//!
//! A check the runtime cannot begin or report on (it refused the command, the container went
//! away, its table was full) counts as neither a pass nor a failure: the replica's record carries
//! ZC-E0516 with the runtime's code and cause, and the step goes on. Nothing here fails a step.

const std = @import("std");
const assert = std.debug.assert;
const agent_mod = @import("agent.zig");
const codes = @import("diag/codes.zig");
const diag_mod = @import("diag.zig");
const probe_scheduler = @import("probe_scheduler.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");

const Context = agent_mod.Context;
const Error = agent_mod.Error;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Entry = probe_scheduler.Entry;
const Table = probe_scheduler.Table;

/// A running container of this node's replica that has a health check.
pub const Target = struct {
    handle: runtime.Handle,
    /// The create revision of the replica's key.
    created: u64,
    health: *const records.Health,
    /// When the container started, on the wall clock, as its observed record says; null if
    /// there is no record yet (the agent sees it start now).
    started_at_ms: ?u64,
};

/// Tracks `targets`, forgets the rest, takes the results of the checks in flight and begins the
/// due checks, at most `probes_concurrent_max` in flight.
pub fn step(table: *Table, ctx: *const Context, targets: []const Target) void {
    assert(ctx.diag.code == null);
    const mono = ctx.mono_ms();
    const wall = ctx.clock.now_ms();
    table.mark_unseen();
    for (targets) |*target| {
        const health = target.health;
        const ends = probe_scheduler.start_ends(
            health.start_period_ms,
            target.started_at_ms,
            wall,
            mono,
        );
        _ = table.track(target.handle, target.created, health, ends, mono);
    }
    table.sweep();
    for (table.entries[0..table.count]) |*entry| {
        if (entry.in_flight()) poll(ctx, entry, mono);
    }
    while (table.next_to_begin(mono)) |entry| {
        const target = find_target(targets, entry.name()).?;
        begin(ctx, entry, target.health, mono);
    }
    assert(ctx.diag.code == null);
}

fn find_target(targets: []const Target, name: []const u8) ?*const Target {
    for (targets) |*target| {
        if (std.mem.eql(u8, target.handle.name(), name)) return target;
    }
    return null;
}

fn begin(ctx: *const Context, entry: *Entry, health: *const records.Health, now: u64) void {
    const command = health.command;
    entry.began(now);
    ctx.runtime.probe_begin(entry.handle, command, health.timeout_ms, ctx.diag) catch {
        var buffer: [probe_scheduler.refusal_bytes_max]u8 = undefined;
        entry.finished(.{ .refused = diag_line(&buffer, ctx.diag) }, now);
        ctx.diag.reset();
    };
}

fn poll(ctx: *const Context, entry: *Entry, now: u64) void {
    var buffer: [probe_scheduler.refusal_bytes_max]u8 = undefined;
    const result = ctx.runtime.probe_poll(entry.handle, ctx.diag) catch {
        entry.finished(.{ .refused = diag_line(&buffer, ctx.diag) }, now);
        ctx.diag.reset();
        return;
    };
    switch (result) {
        .running => {},
        .exited => |code| entry.finished(.{ .exited = code }, now),
        .timed_out => entry.finished(.timed_out, now),
        .refused => |*failure| {
            entry.finished(.{ .refused = diagnostic_line(&buffer, failure) }, now);
        },
    }
}

/// "ZC-E0502: <the last cause>", cut to the buffer.
fn diag_line(buffer: []u8, diag: *const Diag) []const u8 {
    const code = diag.code.?;
    var writer: std.Io.Writer = .fixed(buffer);
    // A line too long for the buffer is cut: it is a cause line, never a failure.
    writer.print("{s}: {s}", .{
        codes.full_name(code),
        diag.last_cause() orelse "no cause given",
    }) catch {};
    assert(writer.end > 0);
    return buffer[0..writer.end];
}

fn diagnostic_line(buffer: []u8, diagnostic: *const Diagnostic) []const u8 {
    const causes = diagnostic.causes.slice();
    var writer: std.Io.Writer = .fixed(buffer);
    // A line too long for the buffer is cut: it is a cause line, never a failure.
    writer.print("{s}: {s}", .{
        diagnostic.code.slice(),
        if (causes.len == 0) "no cause given" else causes[causes.len - 1].slice(),
    }) catch {};
    assert(writer.end > 0);
    return buffer[0..writer.end];
}

/// Puts what the checks say of `replica` into `observed`, a record of a container that has not
/// stopped: the verdict (`unknown` before a check settled it, and after an agent restart), the
/// failures in a row, the last exit and, for a check that timed out or could not run, its
/// diagnostic. A replica without a check gets none of it.
pub fn fill(
    table: *Table,
    ctx: *const Context,
    replica: *const records.Replica,
    observed: *records.Observed,
) Error!void {
    assert(observed.status != .stopped);
    assert(observed.diagnostic == null);
    const health = replica.health orelse return;
    observed.health = .unknown;
    observed.health_failures = 0;
    const entry = table.find(replica.id) orelse return;
    observed.health = entry.verdict;
    observed.health_failures = entry.failures;
    observed.last_probe_exit = entry.last_exit;
    var collector: Diag = undefined;
    collector.reset();
    switch (entry.problem) {
        .none => return,
        .timed_out => {
            collector.raise(.W0502);
            collector.cause(
                "replica {s}: the health check ran longer than its timeout_ms of {d}",
                .{ replica.id, health.timeout_ms },
            );
            collector.fix(.{
                .sentence = "make the check faster, or raise its timeout_ms (at most interval_ms)",
            });
        },
        .refused => {
            collector.raise(.E0516);
            collector.cause("{s}", .{entry.refusal()});
            collector.cause("replica {s}: the health check could not run", .{replica.id});
            collector.fix(.{ .sentence = "read the runtime's code: the check runs again in turn" });
        },
    }
    var diagnostic: Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &collector);
    observed.diagnostic = try records.diagnostic_raw(ctx.arena, &diagnostic, ctx.diag);
}

/// The kind of check problem an observed record carries, read back from its diagnostic.
pub fn problem_of(observed: *const records.Observed) probe_scheduler.Problem {
    const raw = observed.diagnostic orelse return .none;
    var diagnostic: Diagnostic = undefined;
    if (!records.diagnostic_parse(&diagnostic, raw)) return .none;
    const code = codes.parse(diagnostic.code.slice()) orelse return .none;
    return switch (code) {
        .W0502 => .timed_out,
        .E0516 => .refused,
        else => .none,
    };
}
