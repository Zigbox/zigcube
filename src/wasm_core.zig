//! The control-plane core as a `wasm32-freestanding` library (`zig build wasm`, docs/wasm.md).
//! This file is only the doorway: the exports a host calls. The scenario itself is
//! `core_smoke.zig`, which runs natively as a test as well.
//!
//! A host (a browser, or `tools/wasm_check.mjs` in CI) calls `zcube_smoke`, which returns the
//! `core_smoke.Step` it stopped at (0: every step held), then reads the rendered diagnostics from
//! the report buffer with `zcube_report_ptr` and `zcube_report_len`.
//!
//! What this file must never import: `std.Io`, `std.Thread`, a store backend that links a C
//! library, the agent, the server. `zig build wasm` compiles it for a target that has none of
//! those, so an import that needs one fails the build.

const std = @import("std");
const core = @import("core.zig");
const core_smoke = @import("core_smoke.zig");

comptime {
    // Zig analyses only what is referenced; this makes the whole of every core module count.
    core.reference_all();
}

var report: core_smoke.Report = .{};

/// Runs the scenario. 0: every step held; otherwise the number of the step that did not.
export fn zcube_smoke() u32 {
    core_smoke.run(std.heap.wasm_allocator, &report);
    return @backingInt(report.failed);
}

export fn zcube_report_ptr() [*]const u8 {
    return &report.bytes;
}

export fn zcube_report_len() u32 {
    return report.len;
}
