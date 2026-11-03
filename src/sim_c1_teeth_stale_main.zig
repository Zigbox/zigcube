//! `sim-c1-teeth`, the stale-observation negative test: the cluster simulator with
//! `c1_teeth_stale_observation` on (`c1_teeth.zig`), to show that sim-c1 catches a decision whose
//! cited report is from another tenure. Only the `sim-c1-teeth` build step compiles this root; it
//! installs the runner as `sim_c1_teeth_stale` for replay.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_stale_observation = true;

pub const main = sim_cluster_main.main;
