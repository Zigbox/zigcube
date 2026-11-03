//! `sim-c1-teeth`, the locality negative test: the cluster simulator with
//! `c1_teeth_locality_before_spread` on (`c1_teeth.zig`), to show that sim-c1's L1 catches a
//! scheduler that ranks locality ahead of spread. Only the `sim-c1-teeth` build step compiles
//! this root; it installs the runner as `sim_c1_teeth_locality` for replay.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_locality_before_spread = true;

pub const main = sim_cluster_main.main;
