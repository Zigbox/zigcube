//! The agent with the supervisor's "no relay, no workload" half off (`fake_supervisor.zig`: the
//! command runs although its relay could not be opened), for `zig build relay-teeth`: the same
//! program as `zcube_agent.zig`, whose root file this one replaces. Only that step compiles it,
//! and it is never installed. The test "relay fail closed: a relay that cannot be opened ..."
//! must fail with it.

const agent = @import("zcube_agent.zig");

pub const relay_teeth_run_unrelayed = true;

pub const main = agent.main;
pub const panic = agent.panic;
