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
    /// "ZBX-E0410".
    full_name: []const u8,
    severity: zigbox.codes.Severity,
    blame: zigbox.codes.Blame,
    summary: []const u8,
    explanation: []const u8,
};

/// Empty since Zigbox 600939c registered `ZBX-E0410`, the code the simulated runtime used to
/// keep here. The mechanism stays for the next code Zigbox lacks.
pub const placeholders = [_]Entry{};

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

test "find is exact, so the API never explains a code it does not own" {
    try std.testing.expect(find("ZBX-E0410") == null);
    try std.testing.expect(find("E0410") == null);
}
