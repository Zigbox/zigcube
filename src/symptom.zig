//! The symptom a negative test or a fleet canary expects: one or more alternatives, separated by
//! `|`. A failure matches if its check text starts with one of them, so `J2: a run id was started
//! a second time|J7: a run was started under another tenure` accepts those two checks and no
//! other J check. Used by `sim_cluster --expect-symptom` and `sim_fleet ingest --canary`.

const std = @import("std");
const assert = std.debug.assert;

pub const separator = '|';

/// True if `text` starts with one of the `|`-separated alternatives of `spec`. Every
/// alternative must be non-empty (an empty one would match everything).
pub fn matches(text: []const u8, spec: []const u8) bool {
    assert(valid(spec));
    var alternatives = std.mem.splitScalar(u8, spec, separator);
    while (alternatives.next()) |alternative| {
        if (std.mem.startsWith(u8, text, alternative)) return true;
    }
    return false;
}

/// False for an empty spec or an empty alternative ("J2||J7", "J2|").
pub fn valid(spec: []const u8) bool {
    var alternatives = std.mem.splitScalar(u8, spec, separator);
    while (alternatives.next()) |alternative| {
        if (alternative.len == 0) return false;
    }
    return true;
}

test "one alternative is a prefix match, as before" {
    try std.testing.expect(matches("J2: a run id was started a second time", "J2"));
    try std.testing.expect(!matches("J8: a run", "J2"));
}

test "alternatives: any of them matches, a bare prefix does not match another check" {
    const spec = "J2: a run id was started a second time|" ++
        "J7: a run was started under another tenure";
    try std.testing.expect(matches("J2: a run id was started a second time (run 4)", spec));
    const j7 = "J7: a run was started under another tenure than its claim";
    try std.testing.expect(matches(j7, spec));
    // The review's scenario: other J checks, and J7's plumbing message, are not accepted.
    try std.testing.expect(!matches("J8: a run that no node started", spec));
    try std.testing.expect(!matches("J4: the client missed an ending", spec));
    try std.testing.expect(!matches("J7: a claim cannot be read", spec));
    try std.testing.expect(!matches("J2", spec)); // Shorter than the alternative.
}

test "an empty spec or alternative is invalid" {
    try std.testing.expect(valid("J2"));
    try std.testing.expect(valid("J2|J7"));
    try std.testing.expect(!valid(""));
    try std.testing.expect(!valid("J2|"));
    try std.testing.expect(!valid("|J2"));
    try std.testing.expect(!valid("J2||J7"));
}
