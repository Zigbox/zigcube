//! The fleet's variety (docs/briefs/c3-sim-fleet.md items 1 and 2): which fault classes a
//! simulation run has switched on (its **profile**, swarm testing) and how big the run is (its
//! **shape**). Both are drawn from the seed alone, each from a generator of its own, so a seed
//! replays a failure and a draw never moves another: `mixed`, the default, is the world the
//! simulators drew before profiles existed, bit for bit.
//!
//! Pure core code: no clock, thread, file or allocation (it is in the `wasm32-freestanding`
//! build). `docs/decisions/2026-11-04-fleet-profiles-and-shapes.md` has the weights and reasons.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const fencing = @import("fencing.zig");

/// The fault classes of `sim_cluster`, on or off together. `mixed` is the seed's own mix (every
/// class at a rate the seed drew, some of them zero); each other profile switches every class off
/// but its own, and forces that one on, so a rare interleaving of few faults is run often.
pub const ClusterProfile = enum(u8) {
    mixed,
    /// Network faults and partitions only.
    partitions,
    /// Clock-rate error and suspends only.
    skew,
    /// Agent and server crashes, runtime faults and (sim-c1) frozen agents only.
    crash_heavy,
    /// Store outages and lost acknowledgements, with slow links, only.
    slow_store,

    /// Draw weights, in the order of the enum.
    pub const weights = [_]u32{ 3, 2, 2, 2, 2 };

    comptime {
        assert(weights.len == @typeInfo(ClusterProfile).@"enum".field_names.len);
    }

    pub fn name(profile: ClusterProfile) []const u8 {
        return @tagName(profile);
    }

    /// Null for text that names no profile.
    pub fn parse(text: []const u8) ?ClusterProfile {
        return std.meta.stringToEnum(ClusterProfile, text);
    }

    pub fn from_index(index: u32) ?ClusterProfile {
        if (index >= weights.len) return null;
        return @fromBackingInt(@intCast(index));
    }

    /// Whether the profile lets sim-c1's frozen agents run.
    pub fn freezes(profile: ClusterProfile) bool {
        return profile == .mixed or profile == .crash_heavy;
    }
};

/// The peers `sim_swarm` draws, by how they misbehave. `mixed` is the seed's own mix of honest
/// peers, liars, silent ones and refusers; each other profile makes every peer that the mix made
/// misbehave misbehave in one way (the `honest` profile: none).
pub const SwarmProfile = enum(u8) {
    mixed,
    liars,
    silent,
    refusers,
    honest,

    pub const weights = [_]u32{ 3, 3, 2, 2, 1 };

    comptime {
        assert(weights.len == @typeInfo(SwarmProfile).@"enum".field_names.len);
    }

    pub fn name(profile: SwarmProfile) []const u8 {
        return @tagName(profile);
    }

    pub fn parse(text: []const u8) ?SwarmProfile {
        return std.meta.stringToEnum(SwarmProfile, text);
    }

    pub fn from_index(index: u32) ?SwarmProfile {
        if (index >= weights.len) return null;
        return @fromBackingInt(@intCast(index));
    }
};

/// How big a run is. `operations` is what a command line calls `<operations>`.
pub const Shape = struct {
    operations: u32,
    /// The cluster's node count; sim_swarm draws its own and ignores it.
    nodes: u32,
    /// The ttl of the leases the server grants.
    lease_ttl_ms: u32,
    /// The workload's replica counts, as a percentage of the ones sim_cluster always drew.
    replicas_pct: u32,
    /// The run has `operations_long_min` operations or more, after the cost cap: about one run
    /// in ten is drawn at 400 to 800, and the cap cuts some of them below.
    long: bool,
};

pub const operations_min: u32 = 40;
/// The brief asked for 5,000; a run costs about operations^1.8 (measured: 800 operations on 3
/// nodes take 24 s, 100 take 1.3 s), so 5,000 would take 25 minutes and a range of 100 seeds has
/// an hour. The decision record has the measurements.
pub const operations_max: u32 = 800;
/// Runs of this many operations or more are "long".
pub const operations_long_min: u32 = 400;
/// One run in this many is long.
pub const long_share_denominator: u32 = 10;
/// Operations times nodes, at most: keeps a long run on many nodes inside the fleet's per-range
/// deadline (measured, docs/decisions/2026-11-04-fleet-profiles-and-shapes.md).
pub const cost_max: u32 = 5_000;

/// The shortest ttl a shape draws, and the shortest `fencing.inequality_problem` admits (owner,
/// 2026-11-06: the margin plus `fence_window_min_ms`, 9,000 ms since #238 moved the margin to
/// 4,000): the drawn and the admitted ranges agree (docs/decisions/
/// 2026-11-06-renewal-before-fence.md, docs/decisions/2026-11-13-238-authority-repairs.md).
pub const lease_ttl_ms_min: u32 = 9000;
/// The longest ttl `fencing.inequality_problem` allows with the shipped margin.
pub const lease_ttl_ms_max: u32 = constants.lease_ttl_ms;
pub const replicas_pct_default: u32 = 100;

comptime {
    assert(operations_min < operations_long_min);
    assert(operations_long_min < operations_max);
    assert(lease_ttl_ms_min > constants.fence_margin_ms);
    assert(fencing.inequality_problem(lease_ttl_ms_min) == null);
    assert(fencing.inequality_problem(lease_ttl_ms_max) == null);
    assert(fencing.inequality_problem(lease_ttl_ms_max + 1) != null);
}

/// The shape today's runs have: the given operations, the seed's own node count, the shipped ttl.
pub fn fixed_shape(operations: u32) Shape {
    assert(operations > 0);
    return .{
        .operations = operations,
        .nodes = 0,
        .lease_ttl_ms = constants.lease_ttl_ms,
        .replicas_pct = replicas_pct_default,
        .long = false,
    };
}

/// Operations: one run in ten is long, uniform in 400 to 800; the rest are 40 to 99 (45 %),
/// 100 to 199 (35 %) or 200 to 399 (20 %), so short runs dominate and every size shows up.
fn draw_operations(r: std.Random) u32 {
    if (r.uintLessThan(u32, long_share_denominator) == 0) {
        return operations_long_min + r.uintLessThan(u32, operations_max - operations_long_min + 1);
    }
    return switch (r.uintLessThan(u32, 100)) {
        0...44 => 40 + r.uintLessThan(u32, 60),
        45...79 => 100 + r.uintLessThan(u32, 100),
        else => 200 + r.uintLessThan(u32, 200),
    };
}

/// A pure function of `seed`. Nodes: 1 to 2 (20 %), 3 to 4 (35 %), 5 to 8 (30 %), 9 to 16
/// (15 %). The lease ttl is the shipped one 40 % of the time, else uniform above the fence
/// margin. Replica counts scale with the nodes. A run whose operations times nodes exceeds
/// `cost_max` loses operations, not nodes: a node count is the shape, a length is only how long
/// we watch.
pub fn draw_shape(seed: u64) Shape {
    return draw_shape_nodes(seed, null);
}

/// `draw_shape` with the node count the command line gave, if it did: the cost cap applies to the
/// nodes the run will have, not to the ones the seed would have drawn. Every other draw is the
/// same as without the override, so a seed's ttl and the like do not move.
pub fn draw_shape_nodes(seed: u64, nodes_given: ?u32) Shape {
    if (nodes_given) |given| assert(given > 0);
    var prng = std.Random.DefaultPrng.init(seed ^ 0x5a9e_5bad_0000_0001);
    const r = prng.random();
    const drawn = draw_operations(r);
    const nodes_drawn: u32 = switch (r.uintLessThan(u32, 100)) {
        0...19 => 1 + r.uintLessThan(u32, 2),
        20...54 => 3 + r.uintLessThan(u32, 2),
        55...84 => 5 + r.uintLessThan(u32, 4),
        else => 9 + r.uintLessThan(u32, 8),
    };
    const nodes = nodes_given orelse nodes_drawn;
    const lease_ttl_ms: u32 = if (r.uintLessThan(u32, 5) < 2)
        constants.lease_ttl_ms
    else
        lease_ttl_ms_min + r.uintLessThan(u32, lease_ttl_ms_max - lease_ttl_ms_min + 1);
    const replicas_pct = 100 * (1 + r.uintLessThan(u32, @min(nodes, 3)));
    const operations = @max(operations_min, @min(drawn, @divFloor(cost_max, nodes)));
    assert(fencing.inequality_problem(lease_ttl_ms) == null);
    assert(nodes >= 1);
    if (nodes_given == null) assert(nodes <= 16);
    return .{
        .operations = operations,
        .nodes = nodes,
        .lease_ttl_ms = lease_ttl_ms,
        .replicas_pct = replicas_pct,
        .long = operations >= operations_long_min,
    };
}

/// The operations of a `sim_swarm` run drawn from `seed`: the same lengths, uncapped, because its
/// cost per operation does not grow with a node count.
pub fn draw_swarm_operations(seed: u64) u32 {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x5a9e_5bad_0000_0002);
    return draw_operations(prng.random());
}

/// A profile drawn by `weights` from a generator of its own.
fn draw_weighted(seed: u64, salt: u64, comptime weights: []const u32) u32 {
    var prng = std.Random.DefaultPrng.init(seed ^ salt);
    var total: u32 = 0;
    for (weights) |weight| total += weight;
    var pick = prng.random().uintLessThan(u32, total);
    for (weights, 0..) |weight, index| {
        if (pick < weight) return @intCast(index);
        pick -= weight;
    }
    unreachable; // `pick` is below the total.
}

pub fn draw_cluster_profile(seed: u64) ClusterProfile {
    const index = draw_weighted(seed, 0x9f0f_11e5_0000_0001, &ClusterProfile.weights);
    return ClusterProfile.from_index(index).?;
}

pub fn draw_swarm_profile(seed: u64) SwarmProfile {
    const index = draw_weighted(seed, 0x9f0f_11e5_0000_0002, &SwarmProfile.weights);
    return SwarmProfile.from_index(index).?;
}

const testing = std.testing;

test "a shape is a function of the seed, in range, and long runs are a tenth" {
    // Goal: the draws are reproducible and stay inside the documented bounds. Method: draw 20,000
    // seeds twice, check each bound and count the long runs and each node bucket.
    var long: u32 = 0;
    var buckets: [4]u32 = @splat(0);
    for (0..20_000) |seed| {
        const shape = draw_shape(seed);
        try testing.expectEqual(shape, draw_shape(seed));
        try testing.expect(shape.operations >= operations_min);
        try testing.expect(shape.operations <= operations_max);
        try testing.expect(shape.operations * shape.nodes <= @max(cost_max, operations_min * 16));
        try testing.expect(shape.nodes >= 1 and shape.nodes <= 16);
        try testing.expect(shape.lease_ttl_ms > constants.fence_margin_ms);
        try testing.expect(fencing.inequality_problem(shape.lease_ttl_ms) == null);
        try testing.expect(shape.replicas_pct % 100 == 0 and shape.replicas_pct <= 300);
        long += @intFromBool(shape.long);
        var bucket: usize = 3;
        if (shape.nodes <= 8) bucket = 2;
        if (shape.nodes <= 4) bucket = 1;
        if (shape.nodes <= 2) bucket = 0;
        buckets[bucket] += 1;
    }
    // A tenth of 20,000 are drawn long; the cost cap cuts some of them below the long minimum
    // (about 1,860 remain). The bound is wide on purpose: it is a sanity check, not a fit.
    try testing.expect(long > 1_000 and long < 3_000);
    for (buckets) |count| try testing.expect(count > 2_000);
}

test "the profiles are drawn by weight, each one comes up, and a draw is pure" {
    // Goal: every profile is reachable and `mixed` is the commonest. Method: count 10,000 draws.
    var cluster: [ClusterProfile.weights.len]u32 = @splat(0);
    var swarm: [SwarmProfile.weights.len]u32 = @splat(0);
    for (0..10_000) |seed| {
        const profile = draw_cluster_profile(seed);
        try testing.expectEqual(profile, draw_cluster_profile(seed));
        cluster[@backingInt(profile)] += 1;
        swarm[@backingInt(draw_swarm_profile(seed))] += 1;
    }
    for (cluster) |count| try testing.expect(count > 1_200);
    for (swarm) |count| try testing.expect(count > 700);
    try testing.expect(cluster[0] > cluster[1]);
    try testing.expectEqual(ClusterProfile.crash_heavy, ClusterProfile.parse("crash_heavy").?);
    try testing.expect(ClusterProfile.parse("nope") == null);
    try testing.expect(ClusterProfile.from_index(5) == null);
}
