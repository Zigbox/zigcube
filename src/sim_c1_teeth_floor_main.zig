//! `sim-c1-teeth`, the ttl-floor negative test: the cluster simulator with `c1_teeth_ttl_floor_off`
//! on (`c1_teeth.zig`), so a ttl below `fencing.ttl_floor_ms` is admitted, to show that the
//! healed-cluster check catches what the floor prevents. Only the `sim-c1-teeth` build step
//! compiles this root.

const sim_cluster_main = @import("sim_cluster_main.zig");

pub const c1_teeth_ttl_floor_off = true;

pub const main = sim_cluster_main.main;
