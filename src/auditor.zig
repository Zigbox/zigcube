//! The allocation auditor (docs/authority.md, "Auditing the accounting"), role `auditor`: each
//! pass reconstructs every node's tally at one revision (`allocations.zig`) and
//!
//! - on a mismatch with no open finding writes `/audit/allocations/<node>` and an
//!   `allocation_mismatch` decision on the node (cause `/allocations/<node>` observed at its
//!   revision, evidence both tallies and the revision read, `cause_diagnostic` ZC-B0003);
//! - deletes a finding whose node is consistent again, with an `audit_clear` decision.
//!
//! It never repairs: an open finding stays until an operator's `repair allocations` (the
//! scheduler's) makes the node consistent. While it is open the scheduler places nothing on the
//! node (the finding's absence is in the placement compare set) but still releases. One finding,
//! one decision: a mismatch that persists is not recorded again on every pass.
//!
//! Every write compares `/allocations/<node>` at the revision read (0: absent) and the finding at
//! the revision read (0: absent). `ControlPlane` runs it after the scheduler.
//!
//! Core: no thread, no clock but the one in the context, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const allocations = @import("allocations.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Error = controller.Error;
const NodeTally = allocations.NodeTally;
const Wakeup = controller.Wakeup;

pub const actor = "allocation-auditor";
pub const action_mismatch = "allocation_mismatch";
pub const action_clear = "audit_clear";
pub const resync_ms: u64 = 30 * 1000;

pub const watch_prefixes = [_][]const u8{
    records.prefix_assigned,
    records.prefix_allocations,
    records.prefix_audit_allocations,
};

comptime {
    // One node per transaction: the finding's put or delete, then its decision.
    assert(1 + controller.decision_ops <= constants.store_txn_ops_max);
    assert(2 + controller.decision_compares <= constants.store_txn_compares_max);
}

pub const Auditor = struct {
    source: controller.DecisionSource,

    pub fn init(instance: u16) Auditor {
        return .{ .source = .{ .instance = instance } };
    }

    /// One pass. A conflict ends it with a wake-up at once: the next pass reads again.
    pub fn reconcile(auditor: *Auditor, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const reconstruction = try allocations.reconstruct(ctx);
        var acted: u32 = 0;
        var more = false;
        for (reconstruction.nodes) |*tally| {
            const consistent = tally.consistent();
            if (consistent == (tally.finding == null)) continue;
            const done = if (consistent)
                try auditor.clear(ctx, tally)
            else
                try auditor.open(ctx, tally, reconstruction.revision);
            if (!done) {
                more = true;
                break;
            }
            acted += 1;
        }
        return .{
            .at_ms = if (more) now else now + resync_ms,
            .prefixes = &watch_prefixes,
            .acted = acted,
        };
    }

    fn open(
        auditor: *Auditor,
        ctx: *const Context,
        tally: *const NodeTally,
        revision: u64,
    ) Error!bool {
        assert(tally.finding == null);
        const recorded = tally.recorded orelse allocations.zero;
        var batch: Batch = .{};
        const audit_key = try expect_both(ctx, &batch, tally);
        const allocation_at = records.allocation_key(tally.node);
        const id = try controller.put_decision(ctx, &auditor.source, .{
            .actor = actor,
            .action = action_mismatch,
            .subject = .{ .kind = .node, .name = tally.node },
            .reason = try controller.format(
                ctx,
                "recorded {d} assignments and {d} cpu millis, the assignments sum to {d} and {d}",
                .{
                    recorded.count,
                    recorded.allocated.cpu_millis,
                    tally.reconstructed.count,
                    tally.reconstructed.allocated.cpu_millis,
                },
            ),
            .cause = .{
                .kind = .observed,
                .key = try controller.key_copy(ctx, &allocation_at),
                .revision = tally.allocation_revision,
            },
            .cause_diagnostic = .{ .text = try mismatch_diagnostic(ctx, tally) },
            .cause_evidence = .{
                .text = try allocations.evidence(ctx, recorded, tally.reconstructed, revision),
            },
        }, &batch);
        const finding: records.Audit = .{
            .recorded = recorded,
            .reconstructed = tally.reconstructed,
            .revision = revision,
            .decision = id.slice(),
        };
        batch.put(audit_key, try records.encode(ctx.arena, finding, ctx.diag));
        return try controller.commit(ctx, .auditor, &batch) != .conflict;
    }

    fn clear(auditor: *Auditor, ctx: *const Context, tally: *const NodeTally) Error!bool {
        const finding = tally.finding.?;
        var batch: Batch = .{};
        const audit_key = try expect_both(ctx, &batch, tally);
        batch.delete(audit_key);
        const allocation_at = records.allocation_key(tally.node);
        _ = try controller.put_decision(ctx, &auditor.source, .{
            .actor = actor,
            .action = action_clear,
            .subject = .{ .kind = .node, .name = tally.node },
            .reason = try controller.format(
                ctx,
                "the accounting agrees with the {d} assignments again (finding {s})",
                .{ tally.reconstructed.count, finding.rec.decision },
            ),
            .cause = .{
                .kind = .observed,
                .key = try controller.key_copy(ctx, &allocation_at),
                .revision = tally.allocation_revision,
            },
        }, &batch);
        return try controller.commit(ctx, .auditor, &batch) != .conflict;
    }
};

/// Compares `/allocations/<node>` and the finding at the revisions read; returns the finding's key.
fn expect_both(ctx: *const Context, batch: *Batch, tally: *const NodeTally) Error![]const u8 {
    const allocation_at = records.allocation_key(tally.node);
    const audit_at = records.audit_key(tally.node);
    const audit_key = try controller.key_copy(ctx, &audit_at);
    batch.expect(try controller.key_copy(ctx, &allocation_at), tally.allocation_revision);
    batch.expect(audit_key, if (tally.finding) |finding| finding.kv.mod_revision else 0);
    return audit_key;
}

/// ZC-B0003 as the JSON a decision embeds (DIAGNOSTICS.md).
fn mismatch_diagnostic(ctx: *const Context, tally: *const NodeTally) Error![]const u8 {
    const recorded = tally.recorded orelse allocations.zero;
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.B0003);
    collector.cause(
        "/allocations/{s} records {d} assignments, {d} cpu millis and {d} memory bytes; " ++
            "its assignments sum to {d}, {d} and {d}",
        .{
            tally.node,
            recorded.count,
            recorded.allocated.cpu_millis,
            recorded.allocated.memory_bytes,
            tally.reconstructed.count,
            tally.reconstructed.allocated.cpu_millis,
            tally.reconstructed.allocated.memory_bytes,
        },
    );
    collector.fix_with(
        "check the accounting, then repair it",
        "zcube repair allocations {s} --confirm",
        .{tally.node},
    );
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
    return written[0 .. written.len - 1];
}
