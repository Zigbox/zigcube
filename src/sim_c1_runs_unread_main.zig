//! `sim-c1-runs-unread`: the cluster simulator in the world of the `job_runs_unread` tooth (the
//! server cuts a node's runs read for 60 s after a stop of one of its runs commits, and answers
//! its keepalives) with the local job fence on, so J6 must hold there
//! (docs/decisions/2026-11-15-j6-jobs-local-fence.md). Only the `sim-c1-runs-unread` build step
//! compiles this root.

pub const c1_runs_unread_world = true;

pub const main = @import("sim_cluster_main.zig").main;
