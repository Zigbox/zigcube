//! The `ZBX-` codes the runtime side of Zigcube relies on and that Zigbox's registry does not have
//! yet. HANDOFF has the fake runtime "use a placeholder `ZBX-` code agreed with the Zigbox side";
//! this file is where Zigcube keeps its half of that agreement (docs/runtime-codes.md says what
//! is agreed and what is not). The simulated runtime raises them, and the API serves their text
//! from `/v1/codes` and `/v1/explain` next to Zigbox's own, so the console can explain a failure
//! that arrives from a node. A code leaves this file the day Zigbox registers it.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const text_util = @import("text.zig");

pub const Entry = struct {
    /// "ZBX-E0501".
    full_name: []const u8,
    severity: zigbox.codes.Severity,
    blame: zigbox.codes.Blame,
    summary: []const u8,
    explanation: []const u8,
};

/// A start whose image digest is not in the node's store (HANDOFF, C0 demo step 4). Zigbox's
/// numbering puts registry and pull problems in `05xx`.
pub const image_not_found: Entry = .{
    .full_name = "ZBX-E0501",
    .severity = .@"error",
    .blame = .user,
    .summary = "image not found",
    .explanation =
    \\The runtime on the node has no image with that digest in its store, so the
    \\container cannot start. The digest in the service file is wrong, or the
    \\image was never pulled to this node.
    \\
    \\Check the digest in the service file against the images the node has, or
    \\pull the image first, then apply the corrected file. The replica is held,
    \\not retried: a new one would fail the same way.
    ,
};

pub const placeholders = [_]Entry{image_not_found};

pub fn find(full_name: []const u8) ?*const Entry {
    for (&placeholders) |*entry| {
        if (std.mem.eql(u8, entry.full_name, full_name)) return entry;
    }
    return null;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (placeholders) |entry| {
        assert(std.mem.startsWith(u8, entry.full_name, "ZBX-"));
        assert(entry.full_name.len <= constants.diag_code_bytes_max);
        assert(entry.summary.len <= constants.diag_summary_bytes_max);
        assert(entry.summary[entry.summary.len - 1] != '.');
        assert(entry.explanation.len <= constants.diag_explanation_bytes_max);
        var lines = std.mem.splitScalar(u8, entry.explanation, '\n');
        while (lines.next()) |line| {
            assert(line.len <= constants.diag_explanation_line_bytes_max);
            for (line) |byte| assert(text_util.is_printable(byte));
        }
    }
}

test "a placeholder is found by its full name and by nothing else" {
    // Goal: `find` is exact, so the API never explains a code it does not own.
    try std.testing.expect(find("ZBX-E0501") == &placeholders[0]);
    try std.testing.expect(find("ZBX-E0502") == null);
    try std.testing.expect(find("E0501") == null);
}
