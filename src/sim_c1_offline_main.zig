//! `sim-c1-offline`: the cluster simulator in the world of the `job_deadline_offline` tooth (long
//! cuts, short deadlines) with every fix on, so J8 must hold there. Only the `sim-c1-offline`
//! build step compiles this root.

pub const c1_offline_world = true;

pub const main = @import("sim_cluster_main.zig").main;
