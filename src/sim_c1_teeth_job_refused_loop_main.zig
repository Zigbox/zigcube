//! `sim-c1-teeth-job_refused_loop`: the cluster simulator with `c1_teeth_job_refused_loop` on
//! (`c1_teeth.zig`), to show that J10's bound on refused job reports bites. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_refused_loop` for replay.

pub const c1_teeth_job_refused_loop = true;

pub const main = @import("sim_cluster_main.zig").main;
