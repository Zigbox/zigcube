//! The control-plane core as a `wasm32-freestanding` library (`zig build wasm`, docs/wasm.md).
//! This file is only the doorway: the exports a host calls. The scenario itself is
//! `core_smoke.zig`, which runs natively as a test as well.
//!
//! A host (a browser, or `tools/wasm_check.mjs` in CI) calls `zcube_smoke`, which returns the
//! `core_smoke.Step` it stopped at (0: every step held), then reads the rendered diagnostics from
//! the report buffer with `zcube_report_ptr` and `zcube_report_len`.
//!
//! It also calls `zcube_sim_c0(seed)` and `zcube_sim_fuzz(seed, operations)`, the C0 simulation
//! (`sim_c0.zig`): each returns the `sim_c0.Step` it stopped at (0: every step held), and the
//! report, byte for byte what the native `sim-c0` prints for the same seed, is read with
//! `zcube_sim_report_ptr` and `zcube_sim_report_len`. A seed is a `u64`, so it crosses as a
//! BigInt.
//!
//! What this file must never import: `std.Io`, `std.Thread`, a store backend that links a C
//! library, the agent, the server. `zig build wasm` compiles it for a target that has none of
//! those, so an import that needs one fails the build.

const std = @import("std");
const core = @import("core.zig");
const core_smoke = @import("core_smoke.zig");
const mtls_smoke = @import("mtls_smoke.zig");
const sim_c0 = @import("sim_c0.zig");
const sim_cluster = @import("sim_cluster.zig");
const sim_shape = @import("sim_shape.zig");
const sim_swarm = @import("sim_swarm.zig");

/// The profile argument of the `_shaped` exports that asks for the seed's own draw.
const profile_auto: u32 = 0xffff_ffff;

comptime {
    // Zig analyses only what is referenced; this makes the whole of every core module count.
    core.reference_all();
}

var report: core_smoke.Report = .{};

/// Runs the scenario. 0: every step held; otherwise the number of the step that did not.
export fn zcube_smoke() u32 {
    core_smoke.run(std.heap.wasm_allocator, &report);
    return @backingInt(report.failed);
}

/// Runs the mTLS scenario (`mtls_smoke.zig`): certificates issued, verified and refused, and a
/// ClientHello. 0: every step held; otherwise the number of the step that did not.
export fn zcube_mtls_smoke() u32 {
    return @backingInt(mtls_smoke.run());
}

var sim_report: sim_c0.Report = .{};

/// Runs the C0 scenario for `seed`. 0: every step held; else the number of the step that did not.
export fn zcube_sim_c0(seed: u64) u32 {
    sim_c0.simulate(std.heap.wasm_allocator, seed, &sim_report);
    return @backingInt(sim_report.failed);
}

/// Runs the fuzz variant: `operations` random operations drawn from `seed`, then the invariants.
export fn zcube_sim_fuzz(seed: u64, operations: u32) u32 {
    sim_c0.fuzz(std.heap.wasm_allocator, seed, operations, &sim_report);
    return @backingInt(sim_report.failed);
}

var swarm_report: sim_swarm.Report = .{};

/// Runs the swarm simulation (`sim_swarm.zig`): 0 if every check held, else 1. The report is read
/// with `zcube_swarm_report_ptr` and `zcube_swarm_report_len`, and is byte for byte what the
/// native `sim-swarm` prints.
export fn zcube_sim_swarm(seed: u64, operations: u32) u32 {
    sim_swarm.simulate(seed, operations, &swarm_report);
    return @intFromBool(swarm_report.failed);
}

/// `zcube_sim_swarm` with a profile (`sim_shape.SwarmProfile` index; `profile_auto` draws it from
/// the seed) and operations 0 for "draw them from the seed".
export fn zcube_sim_swarm_shaped(seed: u64, operations: u32, profile: u32) u32 {
    const resolved = sim_swarm.resolve(
        seed,
        if (operations == 0) null else operations,
        if (profile == profile_auto) null else sim_shape.SwarmProfile.from_index(profile).?,
    );
    sim_swarm.simulate_profile(seed, resolved.operations, resolved.profile, &swarm_report);
    return @intFromBool(swarm_report.failed);
}

export fn zcube_swarm_report_ptr() [*]const u8 {
    return &swarm_report.bytes;
}

export fn zcube_swarm_report_len() u32 {
    return swarm_report.len;
}

var cluster_report: sim_cluster.Report = .{};

/// Runs the cluster simulation (`sim_cluster.zig`): 0 if every check held, else 1. `nodes` 0 lets
/// the seed pick; `liveness` is 0 or 1. The report is read with `zcube_cluster_report_ptr` and
/// `zcube_cluster_report_len`, and is byte for byte what the native `sim-cluster` prints.
export fn zcube_sim_cluster(seed: u64, operations: u32, nodes: u32, liveness: u32) u32 {
    const options: sim_cluster.Options = .{
        .nodes = if (nodes == 0) null else nodes,
        .liveness = liveness != 0,
    };
    sim_cluster.simulate(std.heap.wasm_allocator, seed, operations, options, &cluster_report);
    return @intFromBool(cluster_report.failed);
}

/// Runs sim-c1 (`Options.c1`), the cluster simulation with the per-revision checks of
/// docs/authority.md §4: 0 if every check held, else 1. The report is read as the cluster's.
export fn zcube_sim_c1(seed: u64, operations: u32, nodes: u32) u32 {
    const options: sim_cluster.Options = .{
        .nodes = if (nodes == 0) null else nodes,
        .c1 = true,
    };
    sim_cluster.simulate(std.heap.wasm_allocator, seed, operations, options, &cluster_report);
    return @intFromBool(cluster_report.failed);
}

/// The cluster simulation with the knobs of the command line: `operations` 0 draws the whole shape
/// from the seed (`sim_cluster.plan`), `profile` is a `sim_shape.ClusterProfile` index or
/// `profile_auto`, and 0 for `nodes`, `lease_ttl_ms` or `replicas_pct` leaves it unset. The report
/// is what the native runner prints for the same arguments.
export fn zcube_sim_cluster_shaped(
    seed: u64,
    operations: u32,
    nodes: u32,
    liveness: u32,
    c1: u32,
    profile: u32,
    lease_ttl_ms: u32,
    replicas_pct: u32,
) u32 {
    const requested: sim_cluster.Options = .{
        .nodes = if (nodes == 0) null else nodes,
        .liveness = liveness != 0,
        .c1 = c1 != 0,
        .profile_auto = profile == profile_auto,
        .profile = if (profile == profile_auto)
            .mixed
        else
            sim_shape.ClusterProfile.from_index(profile).?,
        .lease_ttl_ms = if (lease_ttl_ms == 0) null else lease_ttl_ms,
        .replicas_pct = if (replicas_pct == 0) null else replicas_pct,
    };
    const resolved = sim_cluster.plan(seed, if (operations == 0) null else operations, requested);
    sim_cluster.simulate(
        std.heap.wasm_allocator,
        seed,
        resolved.operations,
        resolved.options,
        &cluster_report,
    );
    return @intFromBool(cluster_report.failed);
}

export fn zcube_cluster_report_ptr() [*]const u8 {
    return &cluster_report.bytes;
}

export fn zcube_cluster_report_len() u32 {
    return cluster_report.len;
}

export fn zcube_sim_report_ptr() [*]const u8 {
    return &sim_report.bytes;
}

export fn zcube_sim_report_len() u32 {
    return sim_report.len;
}

export fn zcube_report_ptr() [*]const u8 {
    return &report.bytes;
}

export fn zcube_report_len() u32 {
    return report.len;
}
