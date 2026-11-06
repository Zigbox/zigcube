//! `sim-c1-teeth-job_deadline_late`: the cluster simulator with `c1_teeth_job_deadline_late` on
//! (`c1_teeth.zig`), to show that sim-c1 catches a deadline the agent enforces late. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_deadline_late` for replay.

pub const c1_teeth_job_deadline_late = true;

pub const main = @import("sim_cluster_main.zig").main;
