//! `sim-c1-teeth-job_cancel`: the cluster simulator with `c1_teeth_job_cancel` on
//! (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_cancel` for replay.

pub const c1_teeth_job_cancel = true;

pub const main = @import("sim_cluster_main.zig").main;
