//! `sim-c4-teeth-mesh_revoke_late`: the cluster simulator with `c1_teeth_mesh_revoke_late` on
//! (`c1_teeth.zig`), to show that sim-c4 catches what that weakening lets through (M2). Only the
//! `sim-c4-teeth` build step compiles this root; it installs the runner as
//! `sim_c4_teeth_mesh_revoke_late` for replay.

pub const c1_teeth_mesh_revoke_late = true;

pub const main = @import("sim_cluster_main.zig").main;
