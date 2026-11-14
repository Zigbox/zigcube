//! `sim-c1-teeth-rollout_budget`: the cluster simulator with `c1_teeth_rollout_budget` on
//! (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_rollout_budget` for replay.

pub const c1_teeth_rollout_budget = true;

pub const main = @import("sim_cluster_main.zig").main;
