//! A bound on handshakes per source (docs/peer.md, "Rate limit"; C2 slice 6b).
//!
//! The responder spends public-key work on every `m1` it accepts, so the peer server asks the
//! `Limiter` before it starts one. A source is a 64-bit key the shell derives from the peer's
//! address (the port is left out: a new port is not a new source). Each source gets
//! `peer_handshakes_per_source_max` starts in a window of `peer_handshake_window_ms`, counted from
//! its first start. The table holds `peer_sources_max` sources; a source whose window has run out
//! frees its slot, and a table of live windows refuses a new source, which is the answer to a flood
//! from many addresses at once.
//!
//! Core code: no clock of its own (the caller passes `now_ms`), no allocation.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Verdict = enum { admitted, source_busy, table_full };

pub const Limiter = struct {
    keys: [constants.peer_sources_max]u64 = undefined,
    starts: [constants.peer_sources_max]u64 = undefined,
    counts: [constants.peer_sources_max]u32 = @splat(0),

    /// Whether `source` may start a handshake at `now_ms` (which never goes backwards). An
    /// admitted start is counted.
    pub fn admit(limiter: *Limiter, source: u64, now_ms: u64) Verdict {
        var free: ?usize = null;
        for (&limiter.counts, 0..) |*count, slot| {
            const age = now_ms -| limiter.starts[slot];
            if (count.* != 0 and age >= constants.peer_handshake_window_ms) count.* = 0;
            if (count.* == 0) {
                if (free == null) free = slot;
                continue;
            }
            if (limiter.keys[slot] != source) continue;
            if (count.* >= constants.peer_handshakes_per_source_max) return .source_busy;
            count.* += 1;
            return .admitted;
        }
        const slot = free orelse return .table_full;
        limiter.keys[slot] = source;
        limiter.starts[slot] = now_ms;
        limiter.counts[slot] = 1;
        return .admitted;
    }
};

test "a source is admitted up to its bound per window, then refused until the window ends" {
    // Goal: the per-source bound holds, other sources are unaffected, and a window that ran out
    // starts afresh. Method: one source to its bound and one past, a second source, then time.
    var limiter: Limiter = .{};
    const bound = constants.peer_handshakes_per_source_max;
    for (0..bound) |_| try std.testing.expectEqual(Verdict.admitted, limiter.admit(7, 1000));
    try std.testing.expectEqual(Verdict.source_busy, limiter.admit(7, 1001));
    try std.testing.expectEqual(Verdict.admitted, limiter.admit(8, 1001));
    // Still inside the window one millisecond before it ends; fresh at the end.
    const end = 1000 + constants.peer_handshake_window_ms;
    try std.testing.expectEqual(Verdict.source_busy, limiter.admit(7, end - 1));
    try std.testing.expectEqual(Verdict.admitted, limiter.admit(7, end));
    // The window counts from the first start, so a burst of refusals does not extend it.
    for (1..bound) |_| try std.testing.expectEqual(Verdict.admitted, limiter.admit(7, end));
    try std.testing.expectEqual(Verdict.source_busy, limiter.admit(7, end));
}

test "a table of live windows refuses a new source and frees slots as windows end" {
    // Goal: a flood of distinct addresses cannot make the server do more than the table's worth
    // of handshakes per window, and the table recovers. Method: fill it, add one, wait.
    var limiter: Limiter = .{};
    for (0..constants.peer_sources_max) |source| {
        try std.testing.expectEqual(Verdict.admitted, limiter.admit(source, 50));
    }
    try std.testing.expectEqual(Verdict.table_full, limiter.admit(1 << 40, 51));
    // A source in the table is still counted, not "full".
    try std.testing.expectEqual(Verdict.admitted, limiter.admit(3, 51));
    const later = 50 + constants.peer_handshake_window_ms;
    try std.testing.expectEqual(Verdict.admitted, limiter.admit(1 << 40, later));
}
