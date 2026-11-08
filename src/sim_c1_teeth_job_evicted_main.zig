//! `sim-c1-teeth-job_evicted`: the cluster simulator with
//! `c1_teeth_job_evicted` on (`c1_teeth.zig`), to show that sim-c1 catches the agent mishandling
//! a run whose container the runtime evicted. Only the `sim-c1-teeth` build step
//! compiles this root; it installs the runner as `sim_c1_teeth_job_evicted` for replay.

pub const c1_teeth_job_evicted = true;

pub const main = @import("sim_cluster_main.zig").main;
