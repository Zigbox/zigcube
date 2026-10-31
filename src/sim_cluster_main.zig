//! `sim-cluster`: runs the deterministic cluster simulation natively and prints its report.
//!
//!     sim-cluster <seed> <operations> [<nodes>]
//!
//! Exit code 0 if every check held, 1 if one did not (the report says which and the seed), and 2
//! for a usage error. A simulation, not a demo (src/sim_cluster.zig says what it checks).

const std = @import("std");
const constants = @import("constants.zig");
const sim_cluster = @import("sim_cluster.zig");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return constants.exit_user;
    if (args.len != 3 and args.len != 4) return usage(init.io);
    const seed = std.fmt.parseInt(u64, args[1], 0) catch return usage(init.io);
    const operations = std.fmt.parseInt(u32, args[2], 10) catch return usage(init.io);
    var nodes: ?u32 = null;
    if (args.len == 4) {
        const count = std.fmt.parseInt(u32, args[3], 10) catch return usage(init.io);
        if (count == 0 or count > sim_cluster.nodes_max) return usage(init.io);
        nodes = count;
    }
    const report = init.gpa.create(sim_cluster.Report) catch return constants.exit_environment;
    defer init.gpa.destroy(report);
    sim_cluster.simulate(init.gpa, seed, operations, nodes, report);
    std.Io.File.stdout().writeStreamingAll(init.io, report.text()) catch
        return constants.exit_environment;
    if (report.failed) return constants.exit_user;
    return constants.exit_ok;
}

fn usage(io: std.Io) u8 {
    const text = "usage: sim-cluster <seed> <operations> [<nodes>]\n";
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    return 2;
}
