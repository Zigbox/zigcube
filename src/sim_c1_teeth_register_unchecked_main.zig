//! `sim-c1-teeth-register_unchecked`, the late-registration negative test: the cluster simulator
//! with `c1_teeth_register_unchecked` on (`c1_teeth.zig`), to show that sim-c1 catches a
//! registration that lands after a newer one and puts the node key on a lease nobody renews
//! (#237). Only the `sim-c1-teeth-*` build steps compile this root.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_register_unchecked = true;

pub const main = sim_cluster_main.main;
