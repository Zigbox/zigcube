//! `sim-c1-teeth-job_deadline_offline`: the cluster simulator with
//! `c1_teeth_job_deadline_offline` on (`c1_teeth.zig`), to show that sim-c1 catches a deadline
//! the agent enforces only while it reaches the server. Only the `sim-c1-teeth` build step
//! compiles this root; it installs the runner as `sim_c1_teeth_job_deadline_offline` for replay.

pub const c1_teeth_job_deadline_offline = true;

pub const main = @import("sim_cluster_main.zig").main;
