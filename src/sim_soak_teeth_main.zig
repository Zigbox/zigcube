//! `sim_soak_teeth`: the cluster simulator with `c1_teeth_soak_leak` on (`c1_teeth.zig`): every
//! operation leaks 16 KiB, and a soak of it must fail its teardown check. Only the
//! `sim-soak-teeth-exe` step and `zig build test` (through `ops/sim-fleet/test-soak.sh`) compile
//! this root.

pub const c1_teeth_soak_leak = true;

pub const main = @import("sim_cluster_main.zig").main;
