//! `sim-c1-teeth-job_pass_break_fenced`: the cluster simulator in the evict world with
//! `c1_teeth_job_pass_break` and `c1_teeth_job_pass_break_fenced` on (`c1_teeth.zig`): the agent
//! of `job_pass_break`, whose job pass is skipped after a server failure (#247), with the local
//! job fence kept on. The fence then falls for the passes that never read the runs, and J12 must
//! catch it (review of #262). Only the `sim-c1-teeth` build step compiles this root; it installs
//! the runner as `sim_c1_teeth_job_pass_break_fenced` for replay.

pub const c1_evict_world = true;
pub const c1_teeth_job_pass_break = true;
pub const c1_teeth_job_pass_break_fenced = true;
pub const sim_runner = "sim_c1_teeth_job_pass_break_fenced";

pub const main = @import("sim_cluster_main.zig").main;
