//! `sim-swarm-teeth`: the swarm simulator built with the fetch plan's test-only fault on (it
//! accepts a chunk without checking its hash, `fetch_plan.zig`), to show that the simulator has
//! teeth. It is the same runner as `sim_swarm_main.zig`; what differs is this root file, which
//! declares the constant `fetch_plan.zig` looks for. Only the `sim-swarm-teeth` build step
//! compiles it, and it is never installed.
//!
//!     sim_swarm_teeth --seeds A..B <operations> --expect-fail
//!
//! exits 0 only if some seed in the range fails (the simulator caught the fault), and 1 if every
//! seed passed (it did not).

const sim_swarm_main = @import("sim_swarm_main.zig");

pub const swarm_teeth_skip_verify = true;

pub const main = sim_swarm_main.main;
