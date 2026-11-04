//! The agent with the fetch plan's test-only fault on (it accepts a chunk without checking its
//! hash, `fetch_plan.zig`), for `zig build swarm-smoke-teeth`: the same program as
//! `zcube_agent.zig`, whose root file this one replaces. Only that build step compiles it, and it
//! is never installed. `swarm_smoke` run with this agent must fail: a bad chunk from a peer
//! reaches the store, which refuses it, and the fetch fails.

const agent = @import("zcube_agent.zig");

pub const swarm_teeth_skip_verify = true;

pub const main = agent.main;
pub const panic = agent.panic;
