//! `sim-c1-teeth-job_pass_break`: the cluster simulator in the evict world with
//! `c1_teeth_job_pass_break` on (`c1_teeth.zig`), to show that sim-c1 catches an agent whose job
//! pass ends at the first server failure, so that a stop committed for a later run waits a step
//! (J6; #247, #248). Only the `sim-c1-teeth` build step compiles this root; it installs the
//! runner as `sim_c1_teeth_job_pass_break` for replay.

pub const c1_evict_world = true;
pub const c1_teeth_job_pass_break = true;
pub const sim_runner = "sim_c1_teeth_job_pass_break";

pub const main = @import("sim_cluster_main.zig").main;
