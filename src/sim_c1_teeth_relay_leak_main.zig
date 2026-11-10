//! `sim-c1-teeth-relay_leak`: the cluster simulator with `c1_teeth_relay_leak` on
//! (`c1_teeth.zig`), to show that sim-c1 catches what that weakening lets through. Only the
//! `sim-c1-teeth` build step compiles this root; it installs the runner as
//! `sim_c1_teeth_relay_leak` for replay.

pub const c1_teeth_relay_leak = true;

pub const main = @import("sim_cluster_main.zig").main;
