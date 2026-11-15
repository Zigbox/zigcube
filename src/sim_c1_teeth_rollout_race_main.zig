//! `sim-c3-teeth-race`: the cluster simulator with `c1_teeth_rollout_race` on
//! (`c1_teeth.zig`), to show that sim-c3 catches what that weakening lets through. Only the
//! `sim-c3-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_rollout_race` for replay.

pub const c1_teeth_rollout_race = true;

pub const main = @import("sim_cluster_main.zig").main;
