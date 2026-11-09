//! `sim-c1-burst`: the cluster simulator in the burst world (one node, bursts of short jobs, #198)
//! with the agent right, so that every check must hold there. Only that build step compiles this
//! root.

pub const c1_burst_world = true;

pub const main = @import("sim_cluster_main.zig").main;
