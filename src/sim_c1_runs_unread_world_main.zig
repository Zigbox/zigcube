//! `sim-c1-runs-unread`: the cluster simulator with `c1_teeth_job_runs_unread` on (`c1_teeth.zig`):
//! the server fails a node's read of its runs while one of them has a stop asked, and answers its
//! keepalives. It was the tooth that showed the J6 gap of
//! docs/decisions/2026-11-14-j6-runs-unread-gap.md; with the agent's job fence (option B,
//! docs/decisions/2026-11-15-j6-143-job-fence.md) J6 must hold here. Only the `sim-c1-runs-unread`
//! build step compiles this root.

pub const c1_teeth_job_runs_unread = true;
pub const sim_runner = "sim_c1_runs_unread";

pub const main = @import("sim_cluster_main.zig").main;
