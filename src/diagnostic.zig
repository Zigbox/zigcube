//! `Diagnostic`: a finished diagnostic as plain data, the form that crosses a boundary. A `Diag`
//! is the collector a function fills while it fails; a `Diagnostic` is what is left once it has
//! failed, safe to copy, store and send. It carries the code as text because the code may belong
//! to either product's registry: `ZBX-E0501` ("image not found") comes from Zigbox's registry
//! and reaches Zigcube inside `ExitReason.start_failed`, while `ZC-E0201` comes from ours. The
//! renderer and `zcube why` need the text, the blame and the summary, never the registry.
//!
//! The JSON form (DIAGNOSTICS.md: one object per line, the API and `zcube why`) belongs to the
//! rendering work in C0 proper and is not written yet.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const codes = @import("diag/codes.zig");
const text_util = @import("text.zig");

pub const Code = text_util.Bounded(constants.diag_code_bytes_max);
pub const Summary = text_util.Bounded(constants.diag_summary_bytes_max);

pub const Diagnostic = struct {
    /// "ZC-E0201", "ZBX-E0501": prefix, kind letter and four digits.
    code: Code,
    severity: codes.Severity,
    blame: codes.Blame,
    summary: Summary,
    causes: diag_mod.Causes,
    whiles: diag_mod.Whiles,
    pairs: diag_mod.Pairs,
    fixes: diag_mod.Fixes,

    /// Copies a finished collector. Initialises `out` in place: it is several kilobytes.
    pub fn from_diag(out: *Diagnostic, diag: *const diag_mod.Diag) void {
        assert(diag.code != null);
        const registered = diag.entry();
        out.code = .{};
        out.code.print("{s}", .{codes.full_name(registered.code)});
        out.severity = registered.severity;
        out.blame = registered.blame;
        out.summary = .{};
        out.summary.print("{s}", .{registered.summary});
        out.causes = diag.causes;
        out.whiles = diag.whiles;
        out.pairs = diag.pairs;
        out.fixes = diag.fixes;
        assert(out.code.len > 0);
        assert(!out.summary.truncated);
    }

    /// The process exit code for this failure, decided by blame alone (as `Diag.exit_code`).
    pub fn exit_code(diagnostic: *const Diagnostic) u8 {
        return codes.exit_code(diagnostic.blame);
    }
};

test "a diagnostic keeps the code, blame and causes of the collector it came from" {
    // Goal: the copy loses nothing the renderer needs. Method: fill a collector, copy it,
    // compare the text fields and the exit code.
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    diag.raise(.E0201);
    diag.cause("connection refused", .{});
    diag.cause("postgres at 127.0.0.1:5432 is not accepting connections", .{});
    diag.fix(.{ .sentence = "start it", .command = "pg_ctl start" });

    var diagnostic: Diagnostic = undefined;
    Diagnostic.from_diag(&diagnostic, &diag);
    try std.testing.expectEqualStrings("ZC-E0201", diagnostic.code.slice());
    try std.testing.expectEqualStrings("can't reach the store backend", diagnostic.summary.slice());
    try std.testing.expectEqual(codes.Blame.external, diagnostic.blame);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.causes.count);
    try std.testing.expectEqualStrings("pg_ctl start", diagnostic.fixes.slice()[0].command.slice());
    try std.testing.expectEqual(diag.exit_code(), diagnostic.exit_code());
}
