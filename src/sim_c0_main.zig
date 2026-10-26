//! `sim-c0`: runs the deterministic simulation of C0 natively and prints its report (the same
//! bytes the WebAssembly build produces for the same seed; `zig build sim-c0` compares them).
//!
//!     sim-c0 <seed>                  the C0 scenario
//!     sim-c0 <seed> fuzz <operations>  the fuzz variant
//!
//! Exit code 0 if every step held, 1 if one did not (the report says which and the seed), and 2
//! for a usage error. This is a simulation, not `demo-c0` (src/sim_c0.zig says why).

const std = @import("std");
const constants = @import("constants.zig");
const sim_c0 = @import("sim_c0.zig");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    const parsed = parse(args) orelse return usage(init.io);
    var report: sim_c0.Report = undefined;
    switch (parsed.mode) {
        .scenario => sim_c0.simulate(init.gpa, parsed.seed, &report),
        .fuzz => sim_c0.fuzz(init.gpa, parsed.seed, parsed.operations, &report),
    }
    std.Io.File.stdout().writeStreamingAll(init.io, report.text()) catch
        return constants.exit_environment;
    if (report.failed != .done) return constants.exit_user;
    return constants.exit_ok;
}

const Mode = enum { scenario, fuzz };

const Parsed = struct { mode: Mode, seed: u64, operations: u32 };

fn parse(args: []const [:0]const u8) ?Parsed {
    if (args.len != 2 and args.len != 4) return null;
    const seed = std.fmt.parseInt(u64, args[1], 0) catch return null;
    if (args.len == 2) return .{ .mode = .scenario, .seed = seed, .operations = 0 };
    if (!std.mem.eql(u8, args[2], "fuzz")) return null;
    const operations = std.fmt.parseInt(u32, args[3], 10) catch return null;
    return .{ .mode = .fuzz, .seed = seed, .operations = operations };
}

fn usage(io: std.Io) u8 {
    const text = "usage: sim-c0 <seed> [fuzz <operations>]\n";
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    return 2;
}
