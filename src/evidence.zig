//! The evidence a decision embeds in `cause_evidence` (docs/authority.md §5, "A decision carries
//! its evidence"): the fields of the cited record that the decision used, as a small JSON object,
//! so that `why` can still explain the decision once the record has changed or been compacted.
//! Each function renders one kind of record into the step's arena. Core code.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");

const Context = controller.Context;

comptime {
    // The longest evidence is a service's (name, replicas, applied_by, request id and the keys
    // around them, 128 bytes of JSON syntax in all) or an observed record's (replica id, node,
    // status and exit, 160): both fit `decision_evidence_bytes_max`, which `render` asserts.
    const service_max = 128 + constants.service_name_bytes_max + 64 +
        constants.request_id_bytes_max;
    const replica_id_max = constants.service_name_bytes_max + 1 + 9;
    const observed_max = 160 + replica_id_max + constants.node_name_bytes_max;
    assert(service_max <= constants.decision_evidence_bytes_max);
    assert(observed_max <= constants.decision_evidence_bytes_max);
    // A job's: name, a deadline, applied_by, a request id and 96 bytes of JSON syntax.
    const job_max = 96 + constants.service_name_bytes_max + 20 + 64 +
        constants.request_id_bytes_max;
    assert(job_max <= constants.decision_evidence_bytes_max);
}

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

/// A job as a submit or a cancel read it: who asked, and under which request.
pub fn job(
    ctx: *const Context,
    record: *const records.Job,
    request_id: []const u8,
) controller.Error!records.Raw {
    return render(ctx, .{
        .name = record.name,
        .deadline_ms = record.deadline_ms,
        .applied_by = record.applied_by,
        .request_id = request_id,
    });
}

/// A service that is no longer there: what the deleting decision acted on.
pub fn deleted_service(ctx: *const Context, name: []const u8) controller.Error!records.Raw {
    return render(ctx, .{ .name = name, .deleted = true });
}

/// An observed record as the decision read it: its status and exit, not the diagnostic, which the
/// decision copies on its own (`cause_diagnostic`).
pub fn observed(ctx: *const Context, record: *const records.Observed) controller.Error!records.Raw {
    return render(ctx, .{
        .replica = record.replica,
        .node = record.node,
        .generation = record.generation,
        .status = @tagName(record.status),
        .exit = record.exit, // The object keys.md documents: {"kind":"signaled","signal":9}.
    });
}

/// A job run's report as the decision read it: its status and exit, not the diagnostic, which the
/// decision copies on its own (`cause_diagnostic`).
pub fn job_observed(
    ctx: *const Context,
    record: *const records.JobObserved,
) controller.Error!records.Raw {
    return render(ctx, .{
        .run = record.run,
        .node = record.node,
        .assignment = record.assignment,
        .tenure = record.tenure,
        .status = @tagName(record.status),
        .exit = record.exit,
        .stop_cause = if (record.stop_cause) |cause| @tagName(cause) else null,
    });
}
