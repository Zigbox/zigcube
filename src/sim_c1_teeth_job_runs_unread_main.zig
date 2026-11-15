//! `sim-c1-teeth-job_runs_unread`: the cluster simulator with `c1_teeth_job_runs_unread` on
//! (`c1_teeth.zig`): the server fails a node's read of its runs for a while after a stop is asked,
//! and answers its keepalives, and the agent's local job fence is off: the gap of
//! docs/decisions/2026-11-14-j6-runs-unread-gap.md, which the fence closes
//! (docs/decisions/2026-11-15-j6-jobs-local-fence.md). sim-c1 must catch it as J6; with the fence
//! on, `sim-c1-runs-unread` must pass. Only the `sim-c1-teeth` build step compiles this root; it
//! installs the runner as
//! `sim_c1_teeth_job_runs_unread` for replay.

pub const c1_teeth_job_runs_unread = true;
pub const sim_runner = "sim_c1_teeth_job_runs_unread";

pub const main = @import("sim_cluster_main.zig").main;
