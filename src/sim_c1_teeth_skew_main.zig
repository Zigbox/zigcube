//! `sim-c1-teeth`, the skew negative test: the cluster simulator with `c1_teeth_skew_beyond_bound`
//! on (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_skew` for replay.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_skew_beyond_bound = true;

pub const main = sim_cluster_main.main;
