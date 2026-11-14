//! The agent with the relay's "relay gone, workload gone" half off (`relay.zig`: a relay whose
//! listener stops leaves the command running), for `zig build relay-teeth`: the same program as
//! `zcube_agent.zig`, whose root file this one replaces. Only that step compiles it, and it is
//! never installed. The test "relay fail closed: a relay that stops ..." must fail with it.

const agent = @import("zcube_agent.zig");

pub const relay_teeth_outlive = true;

pub const main = agent.main;
pub const panic = agent.panic;
