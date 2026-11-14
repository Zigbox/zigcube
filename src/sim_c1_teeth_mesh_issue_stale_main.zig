//! `sim-c1-teeth-mesh_issue_stale`: the cluster simulator with `c1_teeth_mesh_issue_stale` on
//! (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_mesh_issue_stale` for replay.

pub const c1_teeth_mesh_issue_stale = true;

pub const main = @import("sim_cluster_main.zig").main;
