//! `sim-c4-teeth-mesh_no_dst_check`: the cluster simulator with `c1_teeth_mesh_no_dst_check` on
//! (`c1_teeth.zig`), to show that sim-c4 catches what that weakening lets through (M1). Only the
//! `sim-c4-teeth` build step compiles this root; it installs the runner as
//! `sim_c4_teeth_mesh_no_dst_check` for replay.

pub const c1_teeth_mesh_no_dst_check = true;

pub const main = @import("sim_cluster_main.zig").main;
