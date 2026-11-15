//! `sim-c4-teeth-mesh_stale_accept`: the cluster simulator with `c1_teeth_mesh_stale_accept` on
//! (`c1_teeth.zig`), to show that sim-c4 catches what that weakening lets through (M1 or M2: a
//! supervisor that keeps an accept after its grant is gone). Only the `sim-c4-teeth` build step
//! compiles this root; it installs the runner as `sim_c4_teeth_mesh_stale_accept` for replay.

pub const c1_teeth_mesh_stale_accept = true;

pub const main = @import("sim_cluster_main.zig").main;
