//! `sim-c1-runs-unread`: the cluster simulator in the world of the `job_runs_unread` tooth (the
//! server cuts a node's runs read while one of its runs has a stop asked, and answers its
//! keepalives) with the local job fence on, so J6 must hold there
//! (docs/decisions/2026-11-15-j6-jobs-local-fence.md). Only the `sim-c1-runs-unread` build step
//! compiles this root.

pub const c1_runs_unread_world = true;

pub const main = @import("sim_cluster_main.zig").main;
