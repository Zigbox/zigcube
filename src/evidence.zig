//! The evidence a decision embeds in `cause_evidence` (docs/authority.md §5, "A decision carries
//! its evidence"): the fields of the cited record that the decision used, as a small JSON object,
//! so that `why` can still explain the decision once the record has changed or been compacted.
//! Each function renders one kind of record into the step's arena. Core code.

const std = @import("std");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");

const Context = controller.Context;

fn render(ctx: *const Context, value: anytype) controller.Error!records.Raw {
    const text = std.json.Stringify.valueAlloc(ctx.arena, value, .{
        .emit_null_optional_fields = false,
    }) catch return failures.no_memory(ctx.diag);
    std.debug.assert(text.len <= constants.decision_evidence_bytes_max);
    return .{ .text = text };
}

/// A desired service as the decision read it: what an apply or a scale acts on.
pub fn service(ctx: *const Context, record: *const records.Service) controller.Error!records.Raw {
    return render(ctx, .{
        .name = record.name,
        .generation = record.generation,
        .replicas = record.replicas,
        .applied_by = record.applied_by,
        .request_id = record.request_id,
    });
}

/// A service that is no longer there: what the deleting decision acted on.
pub fn deleted_service(ctx: *const Context, name: []const u8) controller.Error!records.Raw {
    return render(ctx, .{ .name = name, .deleted = true });
}

/// An observed record as the decision read it: its status and exit, not the diagnostic, which the
/// decision copies on its own (`cause_diagnostic`).
pub fn observed(ctx: *const Context, record: *const records.Observed) controller.Error!records.Raw {
    var buffer: [64]u8 = undefined;
    return render(ctx, .{
        .replica = record.replica,
        .node = record.node,
        .generation = record.generation,
        .status = @tagName(record.status),
        .exit = if (record.exit) |exit| records.exit_text(exit, &buffer) else null,
    });
}
