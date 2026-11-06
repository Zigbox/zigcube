//! `sim-fencing-teeth`, the negative test of `fencing_settles`: the cluster simulator with
//! `c1_teeth_old_renewal_rule` on (`c1_teeth.zig`), run by hand at a ttl the old `ttl / 3` rule
//! cannot renew in. Only the `sim-fencing-teeth` build step compiles this root.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_old_renewal_rule = true;

pub const main = sim_cluster_main.main;
