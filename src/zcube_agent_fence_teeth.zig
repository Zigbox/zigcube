//! The agent with a late fence kill (`c1_teeth.fence_stop_teeth`): it kills what a fence has not
//! stopped 8,000 ms after the fence instead of `fence_stop_ms`, while the server it talks to keeps
//! the real constants. The same program as `zcube_agent.zig`, whose root file this one replaces.
//! Built by plain `zig build` as `zcube-agent-fence-teeth`, so that it cannot stop compiling
//! unnoticed, and never shipped. The Jepsen lease test (zigcube-jepsen) run with this agent
//! under partitions must fail I1b (measured: 3,335 ms against 1,900).

const agent = @import("zcube_agent.zig");

pub const c1_teeth_fence_stop = true;

pub const main = agent.main;
pub const panic = agent.panic;
