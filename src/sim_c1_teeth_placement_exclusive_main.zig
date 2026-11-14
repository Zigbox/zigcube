//! `sim-c1-teeth-placement_exclusive`: the cluster simulator with `c1_teeth_placement_exclusive`
//! on (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_placement_exclusive` for replay.

pub const c1_teeth_placement_exclusive = true;

pub const main = @import("sim_cluster_main.zig").main;
