//! `sim-c1-teeth-job_ledger_small`: the cluster simulator with `c1_teeth_job_ledger_small` on
//! (`c1_teeth.zig`), to show that a full start ledger fails the run (J8). Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_ledger_small` for replay.

pub const c1_teeth_job_ledger_small = true;

pub const main = @import("sim_cluster_main.zig").main;
