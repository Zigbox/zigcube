//! `sim-teeth`: the cluster simulator built with the agent's test-only fault on (it ignores every
//! order to stop a container, `agent.zig`), to show that the simulator has teeth. It is the same
//! runner as `sim_cluster_main.zig`; what differs is this root file, which declares the constant
//! `agent.zig` looks for. Only the `sim-teeth` build step compiles it, and it is never installed.
//!
//!     sim_teeth --seeds A..B --expect-fail
//!
//! exits 0 only if some seed in the range fails (the simulator caught the fault), and 1 if every
//! seed passed (it did not).

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const agent_teeth_ignore_stop = true;

pub const main = sim_cluster_main.main;
