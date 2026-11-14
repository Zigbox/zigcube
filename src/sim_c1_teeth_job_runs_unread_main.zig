//! `sim-c1-teeth-job_runs_unread`: the cluster simulator with `c1_teeth_job_runs_unread` on
//! (`c1_teeth.zig`): the server fails a node's read of its runs while one of them has a stop asked,
//! and answers its keepalives. Not an agent fault: it shows the gap that
//! docs/decisions/2026-11-14-j6-runs-unread-gap.md leaves to the owner, and sim-c1 must catch it
//! as J6. Only the `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_runs_unread` for replay.

pub const c1_teeth_job_runs_unread = true;
pub const sim_runner = "sim_c1_teeth_job_runs_unread";

pub const main = @import("sim_cluster_main.zig").main;
