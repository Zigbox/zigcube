//! `sim-c1-worlds`: the cluster simulator in the world of the `job_evicted` tooth, controller
//! right, so that every check must hold there. Only the `sim-c1-worlds` build step compiles this.

pub const c1_evict_world = true;

pub const main = @import("sim_cluster_main.zig").main;
