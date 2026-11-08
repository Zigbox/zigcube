//! `sim-c1-teeth-job_unclaimed`: the cluster simulator with `c1_teeth_job_unclaimed` on
//! (`c1_teeth.zig`), to show that J8's second clause catches what that weakening lets through.
//! Only the `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_job_unclaimed` for replay.

pub const c1_teeth_job_unclaimed = true;

pub const main = @import("sim_cluster_main.zig").main;
