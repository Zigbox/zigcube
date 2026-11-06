//! The test-only switches of the `sim-c1` negative tests (docs/authority.md §4, docs/core.md "The
//! cluster simulation"). Each is a constant that only a program's root file can switch on, by
//! declaring `pub const <name> = true;`: the roots that do are `src/sim_c1_teeth_*_main.zig`.
//! The `sim-c1-teeth*` steps compile all but `oldrule`, which only `sim-fencing-teeth` compiles.
//! Every shipped program, test and the WASM core has
//! another root, so for them each is false; `zcube_server.zig` and `zcube_agent.zig` assert that
//! at compile time.

const root = @import("root");

fn declared(comptime name: []const u8) bool {
    return @hasDecl(root, name) and @field(root, name);
}

/// The scheduler leaves `/allocations/<node>` out of a placement's compares (must break I6).
pub const skip_allocation_compare = declared("c1_teeth_skip_allocation_compare");
/// The scheduler leaves `/node-status/<node>` and `/nodes/<node>` out of a placement's compares
/// (with a node lost between planning and commit, must break I7).
pub const skip_readiness_compare = declared("c1_teeth_skip_readiness_compare");
/// Nodes' clocks run beyond the skew bound (must break I1b).
pub const skew_beyond_bound = declared("c1_teeth_skew_beyond_bound");
/// Agents freeze and containers ignore stops, and a wedged node is not excused (must break I1b).
pub const wedge = declared("c1_teeth_wedge");

/// A node registers again between a controller's read of its report and the decision's commit, as
/// if the controller did not compare the report's tenure (must break I3).
pub const stale_observation = declared("c1_teeth_stale_observation");

/// The scheduler ranks locality ahead of spread (C2 slice 5; must break the placement-order
/// invariant of `sim-cluster`).
pub const locality_before_spread = declared("c1_teeth_locality_before_spread");

/// The agent renews every `ttl / 3` again, and the shortest ttl is lifted to the margin
/// (`fencing.zig`; must break `fencing_settles`, run by hand at a ttl below 5,000 ms).
pub const old_renewal_rule = declared("c1_teeth_old_renewal_rule");

pub const any = old_renewal_rule or skip_allocation_compare or skip_readiness_compare or
    skew_beyond_bound or wedge or stale_observation or locality_before_spread;
