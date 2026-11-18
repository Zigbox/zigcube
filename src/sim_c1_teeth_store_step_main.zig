//! `sim-c1-teeth`, the store clock step negative test: the cluster simulator with
//! `c1_teeth_store_clock_step` on (`c1_teeth.zig`): the store's clock steps forward by more than
//! `clock_step_max_ms`, which the fencing contract assumes it never does, and sim-c1 must catch
//! the overlap that lets through. Only the `sim-c1-teeth` build step compiles this root; it
//! installs the runner as `sim_c1_teeth_store_step` for replay.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_store_clock_step = true;

pub const main = sim_cluster_main.main;
