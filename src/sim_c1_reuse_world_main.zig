//! `sim-c1-reuse`: the cluster simulator in the world of the `job_reuse` tooth (retention run by
//! a jump of time, job names reused while a container of the older run stands), agent right, so
//! that every check must hold there. Only the `sim-c1-reuse` build step compiles this.

pub const c1_reuse_world = true;

pub const main = @import("sim_cluster_main.zig").main;
