//! `sim-cluster`: the whole cluster from one seed. The server's controllers (the ones `sim_world`
//! runs), up to `sim_net.nodes_max` nodes, each a `SimNode` (containers, agent files, crashes), a
//! clock of its own (`sim_clock`), the real `Agent` and its `agent_loop` policy, and a `SimNet`
//! that carries the bytes of the agent endpoints between each agent and the server's `Api`. The
//! store is the memory store behind a lost-acknowledgement layer and a switch. Core code: no
//! clock, thread or file; time is a `ManualClock` the world advances a tick at a time.
//!
//! **Swarm.** The seed picks the node count, the rate of every fault (zero included: some worlds
//! have no partitions, some no crashes) and the workload mix, and the report prints them first.
//!
//! **What is checked.** Every virtual second and after every operation, also during the heal:
//! the decisions' causes and `why` (sim-c0's invariants, read over the whole store), and, per
//! container, that none lives past a grace period on a node that no replica of the store assigns
//! it to (time counts only while its node is up, its link is not cut and the store is up). The
//! faults are rationed so the cluster works while faulty (short outages and cuts, at most half
//! the nodes cut at once, low per-call loss), and the run fails if the fault phase did too
//! little agent work.
//! **Liveness mode** (the default, `Options.liveness`): the faults run for the first operations
//! up to a heal point the seed chose (between half and all of the run), then every fault is off
//! for the rest of the operations (workload only), and `liveness_bound_ms` after the last one,
//! replica by replica, its container runs on the node the replica names and nowhere else, and
//! no node runs a container no replica owns. Without it the faults stay on to the end and only
//! the safety checks run.
//! **Duplicates are counted, never failed**: without leases and fencing (slice 6) a partition can
//! leave one replica running on two nodes. The report prints the replica-seconds with a note that
//! the number is not a pass. `zig build sim-cluster` compares the report with the WASM build's.
//!
//! The report ends with a hash of the whole store and every node's runtime: the same seed twice
//! gives the same hash.

const std = @import("std");
const assert = std.debug.assert;
const agent_client = @import("agent_client.zig");
const agent_loop = @import("agent_loop.zig");
const agent_mod = @import("agent.zig");
const api_mod = @import("api.zig");
const fencing = @import("fencing.zig");
const sim_shape = @import("sim_shape.zig");
const apply_mod = @import("apply.zig");
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const node_store = @import("node_store.zig");
const records = @import("records.zig");
const agent_jobs = @import("agent_jobs.zig");
const control_plane = @import("control_plane.zig");
const sim_c1 = @import("sim_c1.zig");
const why_acceptance = @import("why_acceptance.zig");
const sim_checks = @import("sim_checks.zig");
const sim_clock = @import("sim_clock.zig");
const sim_net = @import("sim_net.zig");
const sim_node = @import("sim_node.zig");
const sim_store = @import("sim_store.zig");
const sim_tenancy = @import("sim_tenancy.zig");
const sim_tap = @import("sim_tap.zig");
const sim_world = @import("sim_world.zig");
const job_api = @import("job_api.zig");
const job_retention = @import("job_retention.zig");
const runtime = @import("runtime.zig");
const sim_jobs = @import("sim_jobs.zig");
const sim_jobs_watch = @import("sim_jobs_watch.zig");
const sim_runtime = @import("sim_runtime.zig");
const store = @import("store.zig");
const why_mod = @import("why.zig");
const repeat = @import("test_util.zig").repeat;
const ManualClock = @import("clock.zig").ManualClock;
const Clock = @import("clock.zig").Clock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const report_bytes_max: u32 = 32 * 1024;
pub const nodes_max: u32 = sim_net.nodes_max;
const tick_ms = sim_world.tick_ms;
const epoch_ms = sim_world.epoch_ms;
const rounds_max: u32 = 16;
const drive_rounds_max: u32 = 8;
const compact_interval_ms: u64 = 60 * 1000;
/// A container that no replica assigns to its node may live this long, counted only while its
/// node can be told to stop it (agent up, link not cut) and the store is up.
const excess_ms_max: u64 = 120_000;
/// Excess containers tracked at once; more than that are not timed (never reached in practice:
/// a node holds a few dozen containers).
const excess_slots_max: u32 = 512;
/// A placed replica of a good image must have a running container on its own node within this
/// long, counted like `excess_ms_max` (agent up, link not cut, store up) and only while the
/// agent's last step worked: a failing step (a flaky link) explains why nothing moved. Seeds 1
/// to 300 at 100 operations reach 20.1 s with the agent fix, 25 to 48 s without it
/// (docs/DECISIONS.md).
const starved_ms_max: u64 = 24_000;
/// The cluster's successful agent steps per minute of uptime while the faults were on must be at
/// least this (`cluster_ok_rate`).
const ok_steps_per_minute_min: u64 = 5;
/// The nodes' uptime together, while the faults were on, below which that rate is not checked.
const cluster_up_ms_min: u64 = 120_000;
/// No node's agent may take more steps than this per minute it was up, over the run. Set from
/// the busiest node over seeds 1 to 300 at 100 operations (docs/DECISIONS.md).
///
/// The burst world (one node, bursts of 12 jobs of 3 s to 4 s deadlines, #202) turns runs over
/// several times faster and the agent steps at each deadline and kill, so its ceiling is 300:
/// seeds 14 and 17 run 214 to 220 steps a minute there, and every one is a wake for a deadline,
/// a kill or the next burst's work. An agent that never sleeps wakes every `fence_poll_ms`
/// (100 ms), 600 steps a minute or more, so 300 still tells it apart.
const steps_per_minute_max: u64 = if (c1_teeth.burst_world) 300 else 200;
/// How often a node may fence in the healed phase: 240 s long, against about 240 for the bug.
const fences_after_heal_per_node_max: u32 = 4;
/// How many of a node's job reports the store may refuse in the healed phase (J10). A report is
/// made only under the run's current assignment, so one is refused only when that assignment or
/// the tenure changed while the agent's pass ran: a few times, not on every pass (B2 review).
const job_refusals_after_heal_per_node_max: u64 = 8;
/// A cut link lasts this long at least, and this much longer at most: the agent's own call on a
/// cut link takes 10 s, so a cut is already long.
const partition_ms_min: u32 = 1000;
const partition_ms_spread: u32 = 8000;
/// A store outage advances time by up to this much.
const outage_ms_max: u32 = 4000;
/// Checks run once per this much virtual time, and after every operation.
const check_interval_ms: u64 = 1000;
/// The liveness bound: virtual time given to the healed world, after its last operation, to
/// converge: parked requests (up to 40 s), leases (10 s), back-offs and the controllers' own
/// pacing. Every service then has its replicas and no node runs anything else. The report states
/// it (docs/DECISIONS.md, "sim-cluster liveness mode").
pub const liveness_bound_ms: u64 = 240_000;

/// sim-c1: a clock beyond the skew bound (the negative test), the longest a frozen agent stays
/// frozen, and the overlap table's size.
const skew_beyond_ppm: u32 = 700_000;
const freeze_ms_min: u32 = 5000;
const freeze_ms_spread: u32 = 20_000;
const overlaps_max: u32 = 64;

/// I1b: how long one replica may execute on two nodes at once when no node is wedged: the lost
/// grace, the kill latency, and the simulator's own granularity (a tick, and the check interval).
const overlap_ms_max: u64 = constants.lost_grace_ms + constants.fence_kill_latency_ms +
    constants.fence_stop_ms + tick_ms + check_interval_ms;
/// A node counts as wedged for this long after its agent was last down, frozen or unable to kill:
/// its fence deadline passed with nobody to act on it.
const wedge_memory_ms: u64 = constants.node_lease_ttl_ms + constants.fence_stop_ms;

const hello_digest = "b3:51aa9c03";
/// The relay table of the simulated server (B3): jobs of the `strong` world may name it.
const sim_relays = [_]records.JobRelay{.{ .name = "sim-relay", .address = "127.0.0.1:9" }};
const next_digest = "b3:9d20c4f1";
const broken_digest = "b3:00ff" ++ repeat('0', 55).* ++ "e1";
const fixtures = [_][]const u8{ hello_digest, next_digest };
const images = [_][]const u8{ hello_digest, next_digest, broken_digest };
const service_names = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

comptime {
    assert(broken_digest.len == 64);
}

pub const Report = struct {
    failed: bool = false,
    /// Calls a crashed agent's step tried to make, which the simulation refused (#167).
    dead_calls: u32 = 0,
    bytes: [report_bytes_max]u8 = undefined,
    len: u32 = 0,

    pub fn text(report: *const Report) []const u8 {
        assert(report.len <= report_bytes_max);
        return report.bytes[0..report.len];
    }

    fn print(report: *Report, comptime format: []const u8, args: anytype) void {
        var writer = std.Io.Writer.fixed(report.bytes[report.len..]);
        writer.print(format, args) catch {}; // What does not fit is dropped.
        report.len += @intCast(writer.buffered().len);
        assert(report.len <= report_bytes_max);
    }
};

// ---- The swarm ----------------------------------------------------------------------------------

/// The world a seed chose: how big, which faults at what rate, what the workload does.
pub const Swarm = struct {
    nodes: u32,
    /// Which fault classes are on (`sim_shape.zig`).
    profile: sim_shape.ClusterProfile = .mixed,
    /// The workload's replica counts as a percentage of the base ones.
    replicas_pct: u32 = sim_shape.replicas_pct_default,
    net: sim_net.Faults,
    ack_loss_per_mille: u32,
    clock_ppm: u32,
    /// Operation weights; the advance of time has a weight of its own.
    w_advance: u32 = 30,
    w_apply: u32,
    w_scale: u32,
    w_delete: u32,
    w_broken: u32,
    w_runtime: u32,
    w_crash: u32,
    w_partition: u32,
    w_outage: u32,
    w_server: u32,
    w_suspend: u32,
    /// sim-c1 only: an agent freezes, with its containers still running.
    w_freeze: u32 = 0,
    /// Jobs (`Options.jobs`): a job is submitted, cancelled, or its container ends by itself.
    w_job_create: u32 = 0,
    w_job_cancel: u32 = 0,
    w_job_end: u32 = 0,

    /// Zero a quarter of the time, else 1 to `max`.
    fn rate(random: std.Random, max: u32) u32 {
        if (random.uintLessThan(u32, 4) == 0) return 0;
        return 1 + random.uintLessThan(u32, max);
    }

    fn delay(random: std.Random) u32 {
        if (random.uintLessThan(u32, 3) == 0) return 0;
        return random.uintLessThan(u32, 600);
    }

    /// The reply lost after the server acted is the common case: when it is on at all, it is
    /// frequent, but a lost call costs the agent 10 s, so not so frequent that no step gets
    /// through.
    fn lost_reply(random: std.Random) u32 {
        if (random.uintLessThan(u32, 4) == 0) return 0;
        return 1 + random.uintLessThan(u32, 8);
    }

    /// The seed's world; `profile` then switches whole fault classes off (and its own on). The
    /// base draw is the same whatever the profile, so `mixed` is the world of every earlier build.
    pub fn draw(seed: u64, nodes_wanted: ?u32, profile: sim_shape.ClusterProfile) Swarm {
        var swarm = draw_base(seed, nodes_wanted);
        swarm.profile = profile;
        swarm.apply_profile(seed);
        return swarm;
    }

    fn draw_base(seed: u64, nodes_wanted: ?u32) Swarm {
        var prng = std.Random.DefaultPrng.init(seed ^ 0x5a3a_17c1);
        const r = prng.random();
        const nodes = nodes_wanted orelse 1 + r.uintLessThan(u32, 5);
        assert(nodes >= 1);
        assert(nodes <= nodes_max);
        return .{
            .nodes = nodes,
            .net = .{
                .request = .{ .drop_per_mille = rate(r, 5), .delay_ms_max = delay(r) },
                .reply = .{ .drop_per_mille = lost_reply(r), .delay_ms_max = delay(r) },
                .duplicate_per_mille = rate(r, 100),
                .reorder_per_mille = rate(r, 10),
            },
            .ack_loss_per_mille = rate(r, 100),
            .clock_ppm = if (r.uintLessThan(u32, 3) == 0) 0 else r.uintLessThan(u32, 10_001),
            .w_apply = 5 + r.uintLessThan(u32, 15),
            .w_scale = rate(r, 15),
            .w_delete = rate(r, 8),
            .w_broken = rate(r, 6),
            .w_runtime = rate(r, 20),
            .w_crash = rate(r, 12),
            .w_partition = if (nodes == 1) 0 else rate(r, 10),
            .w_outage = rate(r, 6),
            .w_server = rate(r, 4),
            .w_suspend = rate(r, 4),
        };
    }

    /// A value forced on: `value` if it is, else 1 to `max`.
    fn nonzero(random: std.Random, value: u32, max: u32) u32 {
        if (value != 0) return value;
        return 1 + random.uintLessThan(u32, max);
    }

    /// Switches every fault class off but the profile's own, which it forces on. The workload
    /// (apply, scale, delete, broken, the passage of time) is the profile's in every case. A
    /// generator of its own draws the forced rates, so no profile moves another draw.
    fn apply_profile(swarm: *Swarm, seed: u64) void {
        if (swarm.profile == .mixed) return;
        var prng = std.Random.DefaultPrng.init(seed ^ 0x9f0f_11e5_c10a_0001);
        const r = prng.random();
        const base = swarm.*;
        swarm.net = .{};
        swarm.ack_loss_per_mille = 0;
        swarm.clock_ppm = 0;
        swarm.w_runtime = 0;
        swarm.w_crash = 0;
        swarm.w_partition = 0;
        swarm.w_outage = 0;
        swarm.w_server = 0;
        swarm.w_suspend = 0;
        swarm.w_freeze = 0;
        switch (swarm.profile) {
            .mixed => unreachable, // Returned above.
            .partitions => {
                swarm.net = .{
                    .request = .{
                        .drop_per_mille = nonzero(r, base.net.request.drop_per_mille, 5),
                        .delay_ms_max = base.net.request.delay_ms_max,
                    },
                    .reply = .{
                        .drop_per_mille = nonzero(r, base.net.reply.drop_per_mille, 8),
                        .delay_ms_max = base.net.reply.delay_ms_max,
                    },
                    .duplicate_per_mille = nonzero(r, base.net.duplicate_per_mille, 100),
                    .reorder_per_mille = nonzero(r, base.net.reorder_per_mille, 10),
                };
                if (base.nodes > 1) swarm.w_partition = 4 + r.uintLessThan(u32, 10);
            },
            .skew => {
                swarm.clock_ppm = 1000 + r.uintLessThan(u32, 9001);
                swarm.w_suspend = 2 + r.uintLessThan(u32, 6);
            },
            .crash_heavy => {
                swarm.w_crash = 10 + r.uintLessThan(u32, 20);
                swarm.w_server = 2 + r.uintLessThan(u32, 4);
                swarm.w_runtime = 8 + r.uintLessThan(u32, 16);
            },
            .slow_store => {
                swarm.ack_loss_per_mille = 20 + r.uintLessThan(u32, 80);
                swarm.w_outage = 4 + r.uintLessThan(u32, 6);
                swarm.net.request.delay_ms_max = 200 + r.uintLessThan(u32, 400);
                swarm.net.reply.delay_ms_max = 200 + r.uintLessThan(u32, 400);
            },
        }
    }

    /// The faults sim-c1 adds to the seed's world, drawn apart from the base draw so that a
    /// sim-cluster run of the same seed is unchanged. The negative tests turn them up.
    fn add_c1_faults(swarm: *Swarm, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed ^ 0xc1fa_17e5);
        const r = prng.random();
        const freeze = rate(r, 6);
        swarm.w_freeze = if (swarm.profile.freezes()) freeze else 0;
        if (swarm.profile == .crash_heavy) swarm.w_freeze = nonzero(r, freeze, 6);
        if (c1_teeth.skew_beyond_bound or c1_teeth.offline_world) {
            if (swarm.nodes > 1) swarm.w_partition = 25;
        }
        if (c1_teeth.wedge) {
            swarm.w_freeze = 30;
            swarm.w_runtime = 20;
        }
    }

    /// The job workload's weights, drawn apart from the base draw (as `add_c1_faults` is).
    fn add_jobs(swarm: *Swarm, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed ^ 0x10b5_0b5);
        const r = prng.random();
        swarm.w_job_create = 3 + r.uintLessThan(u32, 5);
        swarm.w_job_cancel = 2 + r.uintLessThan(u32, 3);
        swarm.w_job_end = 2 + r.uintLessThan(u32, 4);
        // The `job_deadline_offline` tooth needs deadlines that fall while a node is cut off.
        if (c1_teeth.offline_world) swarm.w_job_create = 20;
        // The burst world (#198): creates dominate, and bursts of them start dozens of runs in
        // one step of one node.
        if (c1_teeth.burst_world) {
            swarm.w_job_create = 40;
            swarm.w_job_end = 30;
        }
    }

    fn print(swarm: *const Swarm, report: *Report) void {
        const n = swarm.net;
        report.print("swarm: nodes={d} clock_rate_ppm_max={d} ack_loss={d}\u{2030}\n", .{
            swarm.nodes, swarm.clock_ppm, swarm.ack_loss_per_mille,
        });
        report.print("net (per mille): drop_request={d} drop_reply={d} duplicate={d} " ++
            "reorder={d} delay_ms_max={d}/{d}\n", .{
            n.request.drop_per_mille, n.reply.drop_per_mille, n.duplicate_per_mille,
            n.reorder_per_mille,      n.request.delay_ms_max, n.reply.delay_ms_max,
        });
        report.print("weights: advance={d} apply={d} scale={d} delete={d} broken={d} " ++
            "runtime_fault={d} crash={d} partition={d} store_outage={d} server_restart={d} " ++
            "suspend={d}\n", .{
            swarm.w_advance, swarm.w_apply,   swarm.w_scale,   swarm.w_delete,
            swarm.w_broken,  swarm.w_runtime, swarm.w_crash,   swarm.w_partition,
            swarm.w_outage,  swarm.w_server,  swarm.w_suspend,
        });
    }
};

// ---- A node -------------------------------------------------------------------------------------

/// One node: its half of the world and the agent that runs on it.
const StartedTrue = struct { hash: u64, ms: u64 };

/// How many starts a node remembers: more than the runs it holds, so that one step's burst of
/// starts (up to `jobs_per_node_max`, and its retries) cannot push one out before J8 has seen
/// its container. With a ring of 8 the burst world lost the entries, and J8 counted from the
/// first tick that showed the container instead of its start, up to a whole step earlier (#198).
const started_true_max = 4 * constants.jobs_per_node_max;
comptime {
    // `started_next` wraps at a multiple of the ring.
    assert((std.math.maxInt(u16) + 1) % started_true_max == 0);
}

const Node = struct {
    cluster: *Cluster,
    index: u32,
    name_buf: [8]u8,
    name_len: u8,
    sim: sim_node.SimNode,
    nclock: sim_clock.NodeClock,
    remote: agent_client.RemoteStore,
    agent: agent_mod.Agent,
    /// The node's image store (it survives the agent): a seed-chosen subset of `images`, which
    /// the agent advertises as `/node-store/<node>` (C2 slice 5).
    store_images: node_store.FakeImages,
    store_digests: [images.len][]const u8,
    loop: agent_loop.Loop,
    diag: Diag,
    arena: std.heap.ArenaAllocator,
    /// The agent is dead until `restart_at_ms`.
    down: bool,
    restart_at_ms: u64,
    /// The host crash that took the agent down also lost its disk: the restart finds no state
    /// directory and no container (RB-S2 c; J2 holds across a lost state directory).
    wipe_pending: bool = false,
    /// B6 (`Options.tenants` only): the index into `tenant_sets` of the labels this node's agent is
    /// configured with. A restart may change it; the node registers it again when its lease
    /// ends, which is a new tenure.
    label_set: u8 = 0,
    /// B6: the agent was stopped by `relabel_node`, and comes back with another label set.
    relabel_pending: bool = false,
    /// B6: the set `relabel_node` chose for it (its shared or exclusive twin), else any other
    /// (`relabel_other`).
    relabel_to: ?u8 = null,
    /// The agent does nothing before this true time (a call in progress, a back-off).
    resume_ms: u64,
    /// How long the calls of the step in progress took.
    spent_ms: u64,
    /// The true time of this node's latest job-container starts (by name hash), newest over the
    /// oldest: a step's true time is frozen, but a start late in it happened later than its
    /// first tick shows, and J8 counts from the start.
    started_true: [started_true_max]StartedTrue = @splat(.{ .hash = 0, .ms = 0 }),
    started_next: u16 = 0,
    /// The link is cut until this true time.
    partitioned_until_ms: ?u64,
    crashes: u32,
    /// Successful agent steps and virtual time with the agent up, while the faults were on.
    ok_steps: u32,
    up_ms: u64,
    /// Whether the agent's last step worked: a step that fails says why nothing moved.
    last_ok: bool,
    /// Since when the server has had no registration of this node (its lease ran out), while
    /// the agent was up; null while it has one. The fencing invariant's clock.
    unregistered_since_ms: ?u64,
    /// sim-c1: the agent does nothing until this true time (frozen, its containers running).
    frozen_until_ms: ?u64,
    /// sim-c1: the last true time the agent was down, frozen, or a container ignored its stop.
    last_wedged_ms: ?u64,
    /// sim-c1, over the whole run: the true time the agent was wedged (as `wedged_now`), and the
    /// last time it was added to. A cut link or store is not wedged time: the agent enforces a
    /// run's deadline from its own records and clock (J8).
    wedged_total_ms: u64,
    cut_mark_ms: u64,
    /// Times the agent fenced itself, over the whole run (all agent lives).
    fences: u32,
    /// `fences` when the heal began.
    fences_at_heal: u32,
    /// Job reports the store refused (`Agent.job_reports_refused`), over all agent lives, and
    /// that count when the heal began (J10).
    job_refusals: u64,
    job_refusals_at_heal: u64,
    /// Every agent step (failed ones too) and the virtual time with the agent up, over the
    /// whole run: the work ceiling's measure.
    all_steps: u32,
    all_up_ms: u64,

    fn name(node: *const Node) []const u8 {
        return node.name_buf[0..node.name_len];
    }

    fn config(node: *const Node) agent_mod.Config {
        return .{
            .node = node.name(),
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
            .address = "10.0.0.5:7070",
            .labels = if (node.cluster.tenants) tenant_sets[node.label_set] else &.{},
        };
    }

    /// The set of tenant labels a node is configured with (B6): a node of even index (the first,
    /// the third, ...) is never exclusive, so that the services, which have no `require`, always
    /// have nodes they may use (`replicas_for` sizes them to those).
    fn draw_label_set(node: *Node) u8 {
        const draw = node.cluster.label_prng.random().uintLessThan(u8, tenant_sets.len);
        return if (node.index % 2 == 0) draw % 2 else draw;
    }

    /// A label set other than the node's own (`relabel_node`): even-index nodes have one other
    /// to take, the others three. Drawn from the label generator only.
    fn relabel_other(node: *Node) void {
        const before = node.label_set;
        for (0..tenant_sets.len * 4) |_| {
            node.label_set = node.draw_label_set();
            if (node.label_set != before) break;
        } else {
            node.label_set = before ^ 1; // Another set of the same exclusiveness.
        }
        assert(node.label_set != before);
        node.cluster.relabels += 1;
    }

    /// The network as the agent sees it, with the time its calls take added up.
    fn transport(node: *Node) agent_client.Transport {
        return .{ .context = node, .call_fn = tapped_call };
    }

    fn tapped_call(
        context: *anyopaque,
        arena: Allocator,
        request: agent_client.Request,
        diag: *Diag,
    ) agent_client.Error!agent_client.Reply {
        const node: *Node = @ptrCast(@alignCast(context));
        // A dead agent makes no call: a step that goes on past the crash (deadline enforcement
        // swallows it) ends at its next call to the server, and nothing reaches the net (#167).
        if (node.sim.crashed or node.sim.files.crashed) return node.dead_call(diag);
        const net = &node.cluster.net;
        assert(!node.sim.crashed);
        assert(!node.sim.files.crashed);
        const result = net.transport(node.index).call(arena, request, diag);
        node.spent_ms += net.last_call_ms;
        // The call took that long on the agent's clock too, so a cap on its calls (the fence,
        // a run's deadline) is reached inside one step as it is in a real agent's.
        node.nclock.spend_until(node.cluster.manual.ms + node.spent_ms);
        return result;
    }

    /// The call of an agent that crashed: the server never hears of it (ZC-E0503).
    fn dead_call(node: *Node, diag: *Diag) agent_client.Error {
        assert(diag.code == null);
        node.cluster.stats.dead_calls += 1;
        diag.raise(.E0503);
        diag.cause("the simulated agent crashed: it makes no call to zcube-server", .{});
        diag.fix(.{ .sentence = "start the agent again" });
        return error.Unreachable;
    }

    fn restart(node: *Node) void {
        assert(node.down);
        if (node.wipe_pending) {
            node.wipe_pending = false;
            node.sim.files.wipe();
            node.sim.containers.wipe();
            node.cluster.stats.wipes += 1;
        }
        // B6: half the restarts of the tenant world draw the node's labels again (its own
        // generator: no other draw moves), and some of those draws differ. The agent registers
        // them only with a new tenure (after a fence or a lost disk); then the replica and job
        // controllers move off what the new labels refuse (P1, `sim_tenancy`).
        if (node.relabel_pending) {
            node.relabel_pending = false;
            if (node.relabel_to) |set| {
                node.relabel_to = null;
                assert(set != node.label_set);
                node.label_set = set;
                node.cluster.relabels += 1;
            } else {
                node.relabel_other();
            }
        } else if (node.cluster.tenants and node.cluster.label_prng.random().boolean()) {
            const before = node.label_set;
            node.label_set = node.draw_label_set();
            if (node.label_set != before) node.cluster.relabels += 1;
        }
        node.sim.restart();
        node.agent.init(node.config());
        node.loop = agent_loop.Loop.init();
        const gpa = node.cluster.gpa;
        node.remote = agent_client.RemoteStore.init(gpa, node.transport(), node.name());
        node.load_pair();
        node.down = false;
        node.resume_ms = 0;
    }

    /// The agent's remembered pair, as `zcube-agent` loads it at start. `restart` has just
    /// cleared the crash (a first start has none), and `SimState.read` fails only while crashed
    /// (a read is no write point, so it cannot crash); `SimState` keeps every put whole, so a
    /// file the agent wrote parses; and the address is always the same. So the load cannot fail.
    fn load_pair(node: *Node) void {
        assert(!node.sim.crashed);
        assert(!node.sim.files.crashed);
        node.diag.reset();
        _ = node.arena.reset(.retain_capacity);
        const state = node.sim.files.interface();
        const arena = node.arena.allocator();
        const loaded = node.remote.load(state, "/sim", "sim-server", arena, &node.diag);
        loaded catch unreachable; // Cannot fail: see above.
        assert(node.remote.notice == null);
    }

    /// The pair saved after a step, as `zcube-agent` does; a crash at its write point is the
    /// agent dying there.
    fn save_pair(node: *Node, now_ms: u64) void {
        node.remote.save(node.sim.files.interface(), now_ms) catch |err| {
            if (err == error.Crashed) node.sim.crashed = true;
        };
    }

    /// Notes that a call found the agent dead.
    fn check_crashed(node: *Node) void {
        // A crash at a write point of the lease file kills the agent as one of a container's does.
        if (node.sim.files.crashed) node.sim.crashed = true;
        if (!node.sim.crashed) return;
        node.down = true;
        node.crashes += 1;
        const c = node.cluster;
        // A step runs whole at its start, and the node's clock already includes the time its
        // calls spent (`busy_until_true_ms`). An agent that died inside that time would have
        // written none of it, and its restart would read a clock ahead of true time, stamp a
        // lease with it and fence late: an artefact of the simulator, not an agent that acts
        // past its fence (seeds 1612, 1384, 893). So the restart waits until true time has
        // caught up with the clock; `step_once` asserts it. Coverage cut: a crash inside a
        // long step (a slow store, many calls) can no longer be followed by a fast restart, so
        // a bug that shows only then (a restored lease or deadline replayed while the old
        // step's calls land) is out of the simulator's reach; docs/core.md, "The cluster
        // simulation".
        const back = c.manual.ms + 200 + c.prng.random().uintLessThan(u32, 5000);
        node.restart_at_ms = @max(back, node.nclock.busy_until_true_ms + 200);
    }

    fn started_true_of(node: *const Node, hash: u64) ?u64 {
        // Newest first: a name reused later is the start that counts. A slot never written has
        // hash 0, which no name has (`job_started` asserts it).
        const len: u16 = started_true_max;
        for (0..len) |back| {
            const slot = (node.started_next -% 1 -% @as(u16, @intCast(back))) % len;
            const entry = node.started_true[slot];
            if (entry.hash != 0 and entry.hash == hash) return entry.ms;
        }
        return null;
    }

    /// One reconcile step, reported to the loop policy. Returns the transactions it made.
    fn step_once(node: *Node) u32 {
        const c = node.cluster;
        _ = node.arena.reset(.retain_capacity);
        node.diag.reset();
        // The node's clock runs ahead of true time only while the step that charged it is in
        // flight (`resume_ms`). A step that starts after that, or on a restarted agent (which
        // has `resume_ms` 0), reads a clock that has caught up: otherwise its stamps (`sent`)
        // would be later than true time and it would fence late, which no real agent does
        // (seeds 1612, 1384, 893).
        const clock_ahead = node.nclock.busy_until_true_ms > c.manual.ms;
        if (clock_ahead) assert(c.manual.ms < node.resume_ms);
        node.spent_ms = 0;
        const clock = node.nclock.clock();
        const ctx: agent_mod.Context = .{
            .store = node.remote.interface(),
            .runtime = node.sim.interface(),
            .clock = clock,
            .arena = node.arena.allocator(),
            .diag = &node.diag,
            .mono = clock,
            .state = node.sim.files.interface(),
            .deadline = .{
                .context = node,
                .set_fn = Node.deadline_set_fn,
                .hook_fn = Node.deadline_hook_fn,
            },
            .images = node.store_images.images(),
        };
        node.remote.set_deadline(clock, std.math.maxInt(u64));
        c.stats.agent_steps += 1;
        node.all_steps += 1;
        const fences_before = node.agent.fences;
        const refusals_before = node.agent.job_reports_refused;
        const result = node.agent.reconcile(&ctx);
        node.fences += node.agent.fences - fences_before;
        node.job_refusals += node.agent.job_reports_refused - refusals_before;
        node.resume_ms = c.manual.ms + node.spent_ms;
        if (!node.sim.crashed) node.save_pair(clock.now_ms());
        node.check_crashed();
        const wake = result catch {
            c.stats.agent_failures += 1;
            node.last_ok = false;
            _ = node.loop.step_done(clock.now_ms(), .{ .failed = node.diag.code });
            return 0;
        };
        _ = node.loop.step_done(clock.now_ms(), .{ .ok = wake });
        node.last_ok = true;
        if (c.fault_totals == null) node.ok_steps += 1;
        return wake.acted;
    }

    /// The agent's calls end by the fence deadline, or a run's deadline or kill, as the real
    /// agent's do (`agent_run.zig`); with no lease and no run there is no deadline.
    fn cap_calls(node: *Node, clock: Clock) void {
        node.deadline_set(node.agent.calls_deadline_ms(clock.now_ms()));
    }

    /// Caps the calls still to be made by `deadline_ms`, on the node's clock. That clock counts
    /// the time the step's calls have spent (`tapped_call`), so the remote's left-over time
    /// shrinks as a real agent's does and nothing is taken off the deadline here: once it was
    /// (issue #136, before the clock ran), and the time counted twice.
    fn deadline_set(node: *Node, deadline_ms: u64) void {
        assert(node.remote.mono != null); // `create_node` gives the remote its clock
        node.remote.deadline_ms = deadline_ms;
    }

    fn deadline_hook_fn(
        context: *anyopaque,
        hook_context: ?*anyopaque,
        hook: ?*const fn (hook_context: *anyopaque) void,
    ) void {
        const node: *Node = @ptrCast(@alignCast(context));
        node.remote.before_context = hook_context;
        node.remote.before_fn = hook;
    }

    fn deadline_set_fn(context: *anyopaque, deadline_ms: u64) void {
        const node: *Node = @ptrCast(@alignCast(context));
        node.deadline_set(deadline_ms);
    }

    /// Time left to the fence or a run's deadline or kill, on the node's clock: a pause or a
    /// wait never runs past it.
    fn before_fence(node: *Node, ms: u32) u32 {
        const left = node.agent.act_in_ms(node.nclock.clock().now_ms());
        return @min(ms, @max(left, 1));
    }

    /// One slice of the wait: true if it ended (a replica changed, an event came, or it failed).
    /// It holds the server as the real agent's does (`agent_run.zig`): a slice, cut at the fence,
    /// so a call that is not answered costs the same time here as there.
    fn watch_once(node: *Node, slice_ms: u32) bool {
        node.diag.reset();
        node.spent_ms = 0;
        const clock = node.nclock.clock();
        node.cap_calls(clock);
        const held = node.agent.watch_hold_ms(clock.now_ms(), slice_ms);
        var failed = false;
        var ended = node.remote.watch_once(held, &node.diag) catch blk: {
            failed = true;
            break :blk true;
        };
        if (!ended) {
            _ = node.arena.reset(.retain_capacity);
            const events = node.sim.interface().events(node.arena.allocator(), 0, &node.diag);
            ended = if (events) |list| list.len > 0 else |_| blk: {
                failed = true;
                break :blk true;
            };
        }
        node.resume_ms = node.cluster.manual.ms + node.spent_ms;
        if (failed) node.loop.watch_failed() else node.loop.watch_done(ended);
        return ended;
    }

    /// Does what the loop says until it must wait for time to pass. Returns transactions made.
    fn drive(node: *Node) u32 {
        const c = node.cluster;
        if (node.frozen_until_ms) |until| {
            if (c.manual.ms < until) return 0;
            node.frozen_until_ms = null;
        }
        if (node.down) {
            if (c.manual.ms < node.restart_at_ms) return 0;
            node.restart();
        }
        var acted: u32 = 0;
        for (0..drive_rounds_max) |_| {
            if (c.manual.ms < node.resume_ms) return acted;
            switch (node.loop.next(node.nclock.clock().now_ms())) {
                .stop => unreachable, // `request_stop` is never called here.
                .step => {
                    acted += node.step_once();
                    if (node.down) return acted;
                },
                .pause_ms => |ms| node.resume_ms = c.manual.ms + node.before_fence(ms),
                .watch_ms => |ms| if (!node.watch_once(ms)) return acted,
            }
        }
        return acted;
    }
};

// ---- The cluster --------------------------------------------------------------------------------

pub const Stats = struct {
    server_steps: u32 = 0,
    server_failures: u32 = 0,
    agent_steps: u32 = 0,
    agent_failures: u32 = 0,
    transactions: u32 = 0,
    crashes_injected: u32 = 0,
    /// B6: agents an operator restarted with other labels (`relabel_node`).
    relabel_restarts: u32 = 0,
    /// Host crashes that also lost the disk (`Options.strong` only; no draw).
    wipes: u32 = 0,
    /// Calls refused because the agent that made them had crashed.
    dead_calls: u32 = 0,
    partitions: u32 = 0,
    outages: u32 = 0,
    suspends: u32 = 0,
    runtime_faults: u32 = 0,
    server_restarts: u32 = 0,
    /// `mark_lost` and `mark_replica_lost` decisions in the store at the last decisions check:
    /// a run that prints 0 never exercised the lost-node path.
    nodes_marked_lost: u32 = 0,
    replicas_marked_lost: u32 = 0,
    /// Replica-seconds with one replica running on two nodes: counted, not failed.
    duplicate_seconds: u64 = 0,
};

/// Counters read at the end of the faults and again at the end of the run, so the report can say
/// how much work each phase did.
pub const PhaseTotals = struct {
    agent_steps: u32,
    agent_failures: u32,
    server_steps: u32,
    transactions: u32,
    revision: u64,
    delivered: u32,
    requests_dropped: u32,
    replies_lost: u32,
    partitioned: u32,

    fn minus(a: PhaseTotals, b: PhaseTotals) PhaseTotals {
        return .{
            .agent_steps = a.agent_steps - b.agent_steps,
            .agent_failures = a.agent_failures - b.agent_failures,
            .server_steps = a.server_steps - b.server_steps,
            .transactions = a.transactions - b.transactions,
            .revision = a.revision - b.revision,
            .delivered = a.delivered - b.delivered,
            .requests_dropped = a.requests_dropped - b.requests_dropped,
            .replies_lost = a.replies_lost - b.replies_lost,
            .partitioned = a.partitioned - b.partitioned,
        };
    }
};

/// One replica executing on two or more nodes at once (I1b): since when, and whether a wedged
/// node was among them at any time.
const Overlap = struct { name_hash: u64, since_ms: u64, wedged_at_ms: ?u64, seen: bool };

pub const Cluster = struct {
    gpa: Allocator,
    seed: u64,
    swarm: Swarm,
    manual: ManualClock,
    memory: *MemoryStore,
    /// Beneath `ack_loss`: sees every revision as it commits (sim-c1's per-revision checks).
    tap: sim_tap.TapStore,
    ack_loss: sim_store.AckLossStore,
    switched: sim_world.SwitchedStore,
    net: sim_net.SimNet,
    api: api_mod.Api,
    api_source: controller.DecisionSource,
    server: control_plane.ControlPlane,
    nodes: []*Node,
    prng: std.Random.DefaultPrng,
    diag: Diag,
    net_diag: Diag,
    arena_state: std.heap.ArenaAllocator,
    server_due_ms: u64,
    /// Scheduler passes after which an allocation disagreed with its assignments (I6).
    i6_violations: u32,
    server_seen_revision: store.Revision,
    compact_due_ms: u64,
    /// The last true time the store was unreachable (J8's second clause waits for it).
    store_healthy_since_ms: u64,
    instance_next: u16,
    request_next: u32,
    dropped_before_restart: u64,
    excess: [excess_slots_max]Excess,
    excess_count: u32,
    excess_last_ms: u64,
    starved: [excess_slots_max]Excess,
    starved_count: u32,
    starved_worst_ms: u64,
    /// Virtual time the faults were on.
    fault_ms: u64,
    /// Assignments written after this revision have not yet been checked against I7.
    i7_revision: store.Revision,
    /// The store revision and drop count the invariants last passed at.
    checked_revision: ?store.Revision,
    checked_dropped: u64,
    second_ms: u64,
    check_ms: u64,
    stats: Stats,
    /// The totals when the faults ended and the heal began.
    fault_totals: ?PhaseTotals,
    /// Where in the run a check is made: "faults", "healed", "convergence" or "end". A failure
    /// report names it (the simulation fleet files a failure by its check and this step).
    step: []const u8,
    /// Told each step as the run enters it (`Options.on_step`).
    on_step: ?*const fn (step: []const u8) void,
    /// Liveness mode: the faults end mid-run and the end state must converge within
    /// `liveness_bound_ms`; else faults stay on and only the safety checks run.
    liveness: bool,
    report: *Report,
    /// sim-c1 (`Options.c1`): the per-revision checks run, and duplicates fail.
    c1: bool,
    /// The first per-revision check that failed, and the revision it failed at.
    c1_violation: ?[]const u8,
    /// I2's and I3's verdict on the transaction about to commit; it counts if that one commits.
    c1_pending: ?[]const u8,
    /// Replaced replicas whose overlap was not watched because the table was full.
    overlaps_unwatched: u32,
    c1_tally: sim_c1.Tally,
    c1_violation_revision: store.Revision,
    c1_revisions: u64,
    /// Scratch for the per-revision checks, which run inside a store call.
    tap_arena: std.heap.ArenaAllocator,
    /// sim-c1: every decision as `why` rendered it when it committed (docs/authority.md §5).
    recorder: why_acceptance.Recorder,
    tap_diag: Diag,
    /// A negative test's competing write has been made (once per run).
    injected: bool,
    /// Replicas executing on two nodes right now, and since when.
    overlaps: [overlaps_max]Overlap,
    overlap_count: u32,
    overlap_worst_ms: u64,
    overlap_wedged_worst_ms: u64,
    /// The job workload is on (`Options.jobs`); the ledger and trackers' state; the next number.
    jobs_on: bool,
    jobs: sim_jobs.State,
    /// J4: the client that follows the job endings through the watch, and its own random stream.
    jobs_watch: sim_jobs_watch.State,
    watch_prng: std.Random.DefaultPrng,
    /// B6: draws the nodes' tenant labels (`Options.tenants` only), apart from `prng` so that no
    /// other draw of a run moves.
    label_prng: std.Random.DefaultPrng,
    /// Restarts that came back with other labels (a draw of the same set is not counted).
    relabels: u32,
    /// B6's P1 judge (`sim_tenancy`): registrations, refused holds, its verdict.
    tenancy: sim_tenancy.Tenancy,
    job_next: u32,
    /// The reuse world (B2.1 slice 4): retention run by a jump of time, so that a name is reused
    /// while a container of its earlier incarnation still stands. Its counters: jumps made,
    /// creates of a name made before, and those that found a container of that name on a node.
    reuse_cursor: job_retention.Cursor,
    reuse_ops: u32,
    reuse_jumps: u32,
    reuse_made: u32,
    reuse_met: u32,
    /// True while `retention_jump` runs retention: I4 lets its sweep span nodes
    /// (`writers.foreign_key`).
    retention_running: bool = false,
    /// A started job's spec lacked (or wrongly carried) its relay (R3; sticky).
    relay_spec_wrong: bool = false,
    /// `Options.strong`, or a tooth that needs it (`c1_teeth.strong_world`).
    strong: bool,
    /// B6: nodes carry tenant labels and jobs require one (`Options.tenants`, or the tooth).
    tenants: bool,
    /// The host crashes injected so far (the wipe takes every other one, from the first).
    host_crashes: u32,

    pub fn create(
        gpa: Allocator,
        seed: u64,
        options: Options,
        report: *Report,
    ) Allocator.Error!*Cluster {
        const c = try gpa.create(Cluster);
        errdefer gpa.destroy(c);
        const memory = try gpa.create(MemoryStore);
        errdefer gpa.destroy(memory);
        c.gpa = gpa;
        c.seed = seed;
        assert(!options.profile_auto); // `plan` resolves it.
        c.swarm = Swarm.draw(seed, options.nodes, options.profile);
        c.swarm.replicas_pct = options.replicas_pct orelse sim_shape.replicas_pct_default;
        assert(c.swarm.replicas_pct > 0);
        c.manual = .{ .ms = epoch_ms };
        memory.init(gpa, c.manual.clock());
        c.memory = memory;
        c.tap = .{
            .inner = memory.interface(),
            .context = c,
            .after = tapped,
            .before = before_commit,
        };
        c.ack_loss = .init(c.tap.interface(), seed ^ 0xac4, c.swarm.ack_loss_per_mille);
        c.switched = .{ .inner = c.ack_loss.interface() };
        c.net.init(gpa, .{ .context = c, .handle_fn = handle }, seed ^ 0x4e7);
        c.api = .{ .version = "0.0.0", .backend = "memory", .started_at_ms = epoch_ms };
        if (options.lease_ttl_ms) |ttl_ms| {
            assert(fencing.inequality_problem(ttl_ms) == null);
            c.api.lease_ttl_ms = ttl_ms;
        }
        c.api_source = .{ .instance = 0 };
        c.prng = .init(seed ^ 0xc15e_7e12);
        c.diag.reset();
        c.net_diag.reset();
        c.arena_state = .init(gpa);
        c.server_due_ms = 0;
        c.server_seen_revision = 0;
        c.compact_due_ms = epoch_ms + compact_interval_ms;
        c.store_healthy_since_ms = epoch_ms;
        c.instance_next = 1;
        c.request_next = 1;
        c.dropped_before_restart = 0;
        c.init_trackers();
        c.second_ms = 0;
        c.check_ms = 0;
        c.stats = .{};
        c.fault_totals = null;
        c.step = "faults";
        c.on_step = null;
        c.liveness = true;
        c.report = report;
        c.jobs_on = false;
        c.jobs = .{};
        c.jobs_watch = .{};
        c.watch_prng = .init(seed ^ 0x4a34_77a7_c4e5);
        c.init_tenants(seed, options.tenants);
        c.job_next = 1;
        c.init_reuse();
        c.strong = options.strong or c1_teeth.strong_world;
        c.host_crashes = 0;
        c.init_c1(gpa);
        c.server = control_plane.ControlPlane.init(c.take_instance());
        c.server.check_i6 = true;
        c.nodes = try gpa.alloc(*Node, c.swarm.nodes);
        for (c.nodes, 0..) |*slot, index| slot.* = try c.create_node(@intCast(index));
        return c;
    }

    /// B6: the generator of the nodes' tenant labels, and the count of relabels.
    fn init_tenants(c: *Cluster, seed: u64, requested: bool) void {
        c.tenants = requested or c1_teeth.tenant_world;
        c.label_prng = .init(seed ^ 0xb6b6_7e1a_9d03);
        c.relabels = 0;
        c.tenancy = .{};
    }

    /// The reuse world's cursor and counters start empty.
    fn init_reuse(c: *Cluster) void {
        c.reuse_cursor = .{ .age_ms = constants.job_finished_age_ms_min };
        c.reuse_ops = 0;
        c.reuse_jumps = 0;
        c.reuse_made = 0;
        c.reuse_met = 0;
    }

    /// The per-tick trackers start empty.
    fn init_trackers(c: *Cluster) void {
        c.excess = undefined;
        c.excess_count = 0;
        c.excess_last_ms = epoch_ms;
        c.starved = undefined;
        c.starved_count = 0;
        c.starved_worst_ms = 0;
        c.fault_ms = 0;
        c.checked_revision = null;
        c.checked_dropped = 0;
        c.i6_violations = 0;
        c.i7_revision = 0;
    }

    /// The state sim-c1 keeps (`Options.c1` turns the checks on).
    fn init_c1(c: *Cluster, gpa: Allocator) void {
        c.c1 = false;
        c.c1_violation = null;
        c.c1_pending = null;
        c.overlaps_unwatched = 0;
        c.c1_tally = .{};
        c.c1_violation_revision = 0;
        c.c1_revisions = 0;
        c.tap_arena = .init(gpa);
        c.recorder = .init(gpa);
        c.tap_diag.reset();
        c.injected = false;
        c.overlap_count = 0;
        c.overlap_worst_ms = 0;
        c.overlap_wedged_worst_ms = 0;
    }

    fn create_node(c: *Cluster, index: u32) Allocator.Error!*Node {
        const node = try c.gpa.create(Node);
        const random = c.prng.random();
        const ppm_max: i32 = @intCast(c.swarm.clock_ppm);
        const skew_ppm: i32 = @intCast(skew_beyond_ppm);
        const ppm = if (ppm_max == 0) 0 else random.intRangeAtMost(i32, -ppm_max, ppm_max);
        node.cluster = c;
        node.index = index;
        const skewed = c1_teeth.skew_beyond_bound;
        // "node" and at most two digits fit the buffer, since `nodes_max` is 16.
        const name = std.fmt.bufPrint(&node.name_buf, "node{d}", .{index + 1}) catch unreachable;
        node.name_len = @intCast(name.len);
        node.nclock = sim_clock.NodeClock.init(
            c.manual.clock(),
            random.uintLessThan(u64, 1_000_000),
            if (skewed) -skew_ppm else ppm,
            if (skewed) skew_beyond_ppm else @max(c.swarm.clock_ppm, 1),
        );
        node.label_set = 0;
        if (c.tenants) node.label_set = node.draw_label_set();
        node.sim.init(c.gpa, node.nclock.clock(), c.seed +% index, &fixtures);
        node.sim.containers.on_start = job_started;
        node.sim.containers.on_start_context = node;
        node.agent.init(node.config());
        // Its own generator: the store's contents must not move the cluster's stream.
        var store_prng = std.Random.DefaultPrng.init(c.seed ^ (0x5f5f0000 + index));
        var held: usize = 0;
        for (images) |digest| {
            if (!store_prng.random().boolean()) continue;
            node.store_digests[held] = digest;
            held += 1;
        }
        node.store_images = .{ .digests = node.store_digests[0..held] };
        node.loop = agent_loop.Loop.init();
        node.remote = agent_client.RemoteStore.init(c.gpa, node.transport(), node.name());
        node.diag.reset();
        node.arena = .init(c.gpa);
        node.load_pair(); // A fresh state directory: nothing remembered, the address set.
        node.down = false;
        node.restart_at_ms = 0;
        node.resume_ms = 0;
        node.spent_ms = 0;
        node.partitioned_until_ms = null;
        node.crashes = 0;
        node.ok_steps = 0;
        node.last_ok = true;
        node.unregistered_since_ms = null;
        node.frozen_until_ms = null;
        node.last_wedged_ms = null;
        node.wedged_total_ms = 0;
        node.cut_mark_ms = c.manual.ms;
        node.fences = 0;
        node.fences_at_heal = 0;
        node.job_refusals = 0;
        node.job_refusals_at_heal = 0;
        node.up_ms = 0;
        node.all_steps = 0;
        node.all_up_ms = 0;
        c.net.set_faults(index, c.swarm.net);
        return node;
    }

    /// Moves the run to `step` and tells the runner's hook, if any.
    fn enter(c: *Cluster, step: []const u8) void {
        assert(step.len > 0);
        assert(!c.report.failed);
        c.step = step;
        if (c.on_step) |hook| hook(step);
    }

    pub fn destroy(c: *Cluster) void {
        const gpa = c.gpa;
        for (c.nodes) |node| {
            node.arena.deinit();
            node.sim.deinit();
            gpa.destroy(node);
        }
        gpa.free(c.nodes);
        c.net.deinit();
        c.tap_arena.deinit();
        c.recorder.deinit();
        c.arena_state.deinit();
        c.memory.deinit();
        gpa.destroy(c.memory);
        gpa.destroy(c);
    }

    fn take_instance(c: *Cluster) u16 {
        const instance = c.instance_next;
        c.instance_next += 1;
        return instance;
    }

    fn node_names(c: *const Cluster) NodeNames {
        var names: NodeNames = .{ .count = @intCast(c.nodes.len) };
        for (c.nodes, 0..) |node, i| {
            names.names[i] = node.name();
            names.sets[i] = node.label_set;
        }
        return names;
    }

    pub fn store_handle(c: *Cluster) store.Store {
        return c.switched.interface();
    }

    fn fresh_arena(c: *Cluster) Allocator {
        _ = c.arena_state.reset(.retain_capacity);
        return c.arena_state.allocator();
    }

    fn controller_context(c: *Cluster) controller.Context {
        c.diag.reset();
        return .{
            .store = c.store_handle(),
            .clock = c.manual.clock(),
            .arena = c.fresh_arena(),
            .diag = &c.diag,
        };
    }

    /// The server's side of the network: the real `Api`, over the store, answering at once (a
    /// held watch is the agent's polling here).
    fn handle(
        context: *anyopaque,
        scratch: Allocator,
        node: u32,
        request: agent_client.Request,
    ) agent_client.Reply {
        _ = node;
        const c: *Cluster = @ptrCast(@alignCast(context));
        c.net_diag.reset();
        const ctx: controller.Context = .{
            .store = c.store_handle(),
            .clock = c.manual.clock(),
            .arena = scratch,
            .diag = &c.net_diag,
        };
        const cut = std.mem.indexOfScalar(u8, request.target, '?');
        const response = c.api.handle(&ctx, .{
            .method = request.method,
            .path = request.target[0 .. cut orelse request.target.len],
            .query = if (cut) |at| request.target[at + 1 ..] else "",
            .body = request.body,
            .hold = false,
        });
        return .{ .status = response.status, .body = response.body };
    }

    // ---- Time ----

    fn server_step(c: *Cluster) u32 {
        const ctx = c.controller_context();
        c.stats.server_steps += 1;
        const wake = c.server.reconcile(&ctx) catch {
            c.diag.reset();
            c.stats.server_failures += 1;
            c.server_due_ms = c.manual.ms + tick_ms;
            return 0;
        };
        if (c.server.mismatch != null) c.i6_violations += 1;
        c.server_due_ms = wake.at_ms;
        c.stats.transactions += wake.acted;
        return wake.acted;
    }

    /// Whether the server should step: its timer is due, or the store's revision moved.
    fn server_wakes(c: *Cluster) bool {
        c.diag.reset();
        const status = c.store_handle().status(&c.diag) catch {
            c.diag.reset();
            return c.manual.ms >= c.server_due_ms;
        };
        const due = c.manual.ms >= c.server_due_ms;
        const moved = status.revision != c.server_seen_revision;
        c.server_seen_revision = status.revision;
        return due or moved;
    }

    fn settle(c: *Cluster) void {
        for (0..rounds_max) |_| {
            var acted: u32 = 0;
            if (c.server_wakes()) acted += c.server_step();
            for (c.nodes) |node| acted += node.drive();
            if (acted == 0) return;
        }
    }

    pub fn advance(c: *Cluster, ms: u64) void {
        var left = ms;
        while (left > 0) {
            if (c.report.failed) return;
            const slice = @min(left, tick_ms);
            c.manual.advance(slice);
            left -= slice;
            if (c.fault_totals == null) c.fault_ms += slice;
            for (c.nodes) |node| {
                if (node.down) continue;
                node.all_up_ms += slice;
                if (c.fault_totals == null) node.up_ms += slice;
            }
            c.diag.reset();
            _ = c.store_handle().expire_leases(&c.diag) catch c.diag.reset();
            c.maintain();
            c.net.tick(c.manual.ms);
            c.mend_links();
            c.settle();
            if (c.jobs_on) c.watch_client();
            // The wedge totals J1, J6 and J8 judge by are kept whenever jobs are on,
            // not only under c1: a plain run judges the same bounds.
            if (c.c1 or c.jobs_on) c.note_wedged();
            if (c.c1) {
                track_overlap(c) catch return;
                c1_check(c) catch return;
            }
            c.second_ms += slice;
            if (c.second_ms >= 1000) {
                c.second_ms -= 1000;
                const twice = c.duplicates();
                c.stats.duplicate_seconds += twice;
                // A replica id is placed on one node, and a replacement gets a new id: the same
                // replica executing on two nodes is a bug whatever wedged (sim-c1).
                if (c.c1) check(c, twice == 0, "I1b: one replica executes on two nodes at " ++
                    "once") catch return;
            }
            c.check_ms += slice;
            if (c.check_ms >= check_interval_ms) {
                c.check_ms = 0;
                track_tenancy(c) catch return;
                safety(c) catch return; // The report says what failed.
            }
        }
    }

    /// J4's client, once per poll: it is killed now and then, away for less than a minute or for
    /// minutes, and resumes from its revision. The simulation compacts to the head every 60 s,
    /// so even a short absence can end in a 410 (relist and dedupe); the real keep window is
    /// not simulated, and a plain in-window resume is the rarer path here.
    fn watch_client(c: *Cluster) void {
        const w = &c.jobs_watch;
        const now = c.manual.ms;
        if (now < w.away_until_ms or now < w.next_poll_ms) return;
        const random = c.watch_prng.random();
        w.next_poll_ms = now + 1000 + random.uintLessThan(u32, 4000);
        if (random.uintLessThan(u32, 60) == 0) {
            const long = random.uintLessThan(u32, 4) == 0;
            const span: u64 = if (long)
                60_000 + random.uintLessThan(u32, 600_000)
            else
                1000 + random.uintLessThan(u32, 59_000);
            w.away_until_ms = now + span;
            w.restarts += 1;
            return;
        }
        if (store_faulty(c)) return;
        const ctx = c.controller_context();
        sim_jobs_watch.poll(w, &c.api, &ctx);
    }

    fn node_named(c: *const Cluster, name: []const u8) ?*Node {
        for (c.nodes) |node| {
            if (std.mem.eql(u8, node.name(), name)) return node;
        }
        return null;
    }

    fn maintain(c: *Cluster) void {
        if (c.manual.ms < c.compact_due_ms) return;
        c.compact_due_ms = c.manual.ms + compact_interval_ms;
        const head = c.revision() orelse return;
        if (head < 2) return;
        c.diag.reset();
        c.store_handle().compact(head, &c.diag) catch c.diag.reset();
    }

    /// A cut link comes back to the swarm's baseline when its time is up.
    fn mend_links(c: *Cluster) void {
        for (c.nodes) |node| {
            const until = node.partitioned_until_ms orelse continue;
            if (c.manual.ms < until) continue;
            node.partitioned_until_ms = null;
            c.net.set_faults(node.index, c.swarm.net);
        }
    }

    /// A replica count up to `most`, held so that the four services together always fit the
    /// nodes' CPU (16 replicas of 250 millis on each 4000): an unplaceable replica is not a bug.
    fn replicas_for(c: *Cluster, random: std.Random, most: u32) u32 {
        // B6: in the tenant world only the nodes that are never exclusive hold a replica.
        const usable = if (c.tenants) (c.nodes.len + 1) / 2 else c.nodes.len;
        const fit: u32 = @intCast(usable * 4);
        const scaled = @divFloor(most * c.swarm.replicas_pct, 100);
        return random.uintLessThan(u32, @min(scaled, fit - 1) + 1);
    }

    fn phase_totals(c: *Cluster) PhaseTotals {
        var net: sim_net.Stats = .{};
        for (c.nodes) |node| {
            const link = c.net.stats(node.index);
            net.delivered += link.delivered;
            net.requests_dropped += link.requests_dropped;
            net.replies_lost += link.replies_lost;
            net.partitioned += link.partitioned;
        }
        return .{
            .agent_steps = c.stats.agent_steps,
            .agent_failures = c.stats.agent_failures,
            .server_steps = c.stats.server_steps,
            .transactions = c.stats.transactions,
            .revision = c.revision() orelse 0,
            .delivered = net.delivered,
            .requests_dropped = net.requests_dropped,
            .replies_lost = net.replies_lost,
            .partitioned = net.partitioned,
        };
    }

    pub fn revision(c: *Cluster) ?store.Revision {
        c.diag.reset();
        const status = c.store_handle().status(&c.diag) catch {
            c.diag.reset();
            return null;
        };
        return status.revision;
    }

    /// How many replicas run on more than one node right now, each counted once. A container
    /// that is `stopping` is on its way out and does not count as running.
    fn duplicates(c: *Cluster) u64 {
        var count: u64 = 0;
        for (c.nodes, 0..) |node, index| {
            for (node.sim.containers.containers.items) |container| {
                if (container.phase != .running) continue;
                if (c.runs_before(index, container.name)) continue;
                if (c.runs_after(index, container.name)) count += 1;
            }
        }
        return count;
    }

    /// Whether an earlier node runs `name`, so a replica on three nodes is counted once.
    fn runs_before(c: *Cluster, index: usize, name: []const u8) bool {
        for (c.nodes[0..index]) |other| {
            if (runs(other, name)) return true;
        }
        return false;
    }

    fn runs_after(c: *Cluster, index: usize, name: []const u8) bool {
        for (c.nodes[index + 1 ..]) |other| {
            if (runs(other, name)) return true;
        }
        return false;
    }

    /// Starts the clock of I1b for each replica this transaction marks lost (its decision).
    fn note_replaced(c: *Cluster, request: store.TxnRequest) void {
        for (request.on_success) |op| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
            _ = c.tap_arena.reset(.retain_capacity);
            const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
            const decision = std.json.parseFromSliceLeaky(
                records.Decision,
                c.tap_arena.allocator(),
                put.value,
                options,
            ) catch {
                c.overlaps_unwatched += 1;
                continue;
            };
            if (!std.mem.eql(u8, decision.action, "mark_replica_lost")) continue;
            if (c.overlap_count == overlaps_max) {
                c.overlaps_unwatched += 1; // Counted in the report: never judged.
                continue;
            }
            c.overlaps[c.overlap_count] = .{
                .name_hash = std.hash.Wyhash.hash(0, decision.subject.name),
                .since_ms = c.manual.ms,
                .wedged_at_ms = null,
                .seen = true,
            };
            c.overlap_count += 1;
        }
    }

    /// Whether `node` cannot stop its containers right now: its agent is down or frozen, or a
    /// container ignores a stop (`slow_stop`).
    fn wedged_now(node: *const Node) bool {
        if (node.down or node.frozen_until_ms != null) return true;
        for (node.sim.containers.containers.items) |container| {
            if (container.ignores_stop and container.phase != .stopped) return true;
        }
        return false;
    }

    /// Whether `node` was wedged now or within `wedge_memory_ms`: a stop the node missed while
    /// wedged is still being made up for.
    fn wedged_lately(c: *const Cluster, node: *const Node) bool {
        if (wedged_now(node)) return true;
        const last = node.last_wedged_ms orelse return false;
        return c.manual.ms - last <= wedge_memory_ms;
    }

    fn note_wedged(c: *Cluster) void {
        for (c.nodes) |node| {
            const passed = c.manual.ms - node.cut_mark_ms;
            node.cut_mark_ms = c.manual.ms;
            if (wedged_now(node)) {
                node.last_wedged_ms = c.manual.ms;
                node.wedged_total_ms += passed;
            }
        }
    }

    // ---- What a person or a fault does ----

    fn request_id(c: *Cluster, buffer: []u8) []const u8 {
        const text = std.fmt.bufPrint(buffer, "r-{x:0>7}", .{c.request_next});
        c.request_next += 1;
        return text catch unreachable; // "r-" and seven digits fit sixteen bytes.
    }

    fn apply(c: *Cluster, name: []const u8, image: []const u8, replicas: u32) void {
        var buffer: [16]u8 = undefined;
        const id = c.request_id(&buffer);
        const ctx = c.controller_context();
        _ = apply_mod.apply(&ctx, &c.api_source, .{
            .name = name,
            .image = image,
            .replicas = replicas,
            .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
            .applied_by = "alex@laptop",
            .request_id = id,
        }) catch c.diag.reset();
    }

    fn delete_service(c: *Cluster, name: []const u8) void {
        var buffer: [16]u8 = undefined;
        const id = c.request_id(&buffer);
        const ctx = c.controller_context();
        _ = apply_mod.delete_service(&ctx, &c.api_source, name, "alex@laptop", id) catch
            c.diag.reset();
    }

    fn restart_server(c: *Cluster) void {
        c.dropped_before_restart += c.server.replicas.retention.dropped;
        c.server = control_plane.ControlPlane.init(c.take_instance());
        c.server.check_i6 = true;
        c.server_due_ms = 0;
        c.stats.server_restarts += 1;
    }

    fn set_store_down(c: *Cluster, down: bool) void {
        c.switched.down = down;
        c.switched.fail_after = null;
    }

    fn dropped_total(c: *const Cluster) u64 {
        return c.dropped_before_restart + c.server.replicas.retention.dropped;
    }

    fn cut_count(c: *const Cluster) u32 {
        var count: u32 = 0;
        for (c.nodes) |node| count += @intFromBool(node.partitioned_until_ms != null);
        return count;
    }

    /// Cuts or damages a node's link for a while: a request-side, a reply-side or a full cut.
    /// At most half the nodes are cut at once (so a one-node world has no partitions: its only
    /// agent would be cut a third of the time, and the cluster must be mostly working while it is
    /// faulty); a node already cut is left as it is.
    fn partition(c: *Cluster, node: *Node) void {
        const cuts_max: u32 = @divFloor(@as(u32, @intCast(c.nodes.len)), 2);
        if (node.partitioned_until_ms != null) return;
        if (c.cut_count() >= cuts_max) return;
        const random = c.prng.random();
        var faults = c.swarm.net;
        switch (random.uintLessThan(u32, 3)) {
            0 => faults.partition_up = true,
            1 => faults.partition_down = true,
            else => {
                faults.partition_up = true;
                faults.partition_down = true;
            },
        }
        c.net.set_faults(node.index, faults);
        // The `job_deadline_offline` tooth cuts for up to the lease's ttl and beyond: a deadline
        // that falls in the cut must still be enforced, by the agent alone.
        const stretch: u32 = if (c1_teeth.offline_world) 4 else 1;
        const spread = stretch * partition_ms_spread;
        node.partitioned_until_ms =
            c.manual.ms + partition_ms_min + random.uintLessThan(u32, spread);
        c.stats.partitions += 1;
    }

    /// The agent of `node` dies: at a write point, at a step boundary or between steps.
    fn crash(c: *Cluster, node: *Node) void {
        if (node.down) return;
        const random = c.prng.random();
        const kind: @import("agent_state.zig").CrashKind =
            if (random.boolean()) .process else .host;
        c.stats.crashes_injected += 1;
        // No draw: with `Options.strong`, every other host crash loses the disk, state directory
        // and containers. A `.process` crash never does: a directory removed by hand would leave
        // containers running that this simulated node cannot list (its runtime keeps their
        // records in that directory), which no agent can find, and J1, J8 and I1b rightly fail
        // (about one seed in five at 100 operations; docs/core.md, "What the simulation does not
        // cover").
        if (c.strong and kind == .host) {
            c.host_crashes += 1;
            if (c.host_crashes % 2 == 1) node.wipe_pending = true;
        }
        switch (random.uintLessThan(u32, 3)) {
            0 => node.sim.arm_crash(1 + random.uintLessThan(u32, 6), kind),
            1 => node.sim.arm_step(1 + random.uintLessThan(u32, 3), kind),
            else => {
                node.sim.crash_now(kind);
                node.check_crashed();
            },
        }
    }

    /// B6, the tenant world before the heal: before one operation in eight (the label generator
    /// draws it), an operator reinstalls one node with other labels (a host crash that loses its
    /// disk, state directory and containers). An agent registers labels only with a new tenure
    /// (`agent.zig`: a restart that finds its lease keeps it, and the old labels), so a plain
    /// restart would change nothing the server sees. The node comes back empty under its new
    /// labels while the server still assigns it what it held, which its agent would start again,
    /// so the replica and job controllers must move what the labels refuse elsewhere (P1,
    /// `sim_tenancy`). Runs without tenants draw nothing here.
    fn relabel_node(c: *Cluster) void {
        assert(c.tenants);
        const random = c.label_prng.random();
        if (random.uintLessThan(u32, 8) != 0) return;
        // Half the time an odd-index node (the only ones that may be exclusive), toggled between
        // shared and exclusive for its own tenant (`tenant_sets` keeps the exclusive twin of set
        // `s` at `s + 2`): a shared spell lets services and other tenants land on it, and the
        // exclusive one refuses them, the case P1's eviction exists for.
        const odd = c.nodes.len > 1 and random.boolean();
        const index = if (odd)
            1 + 2 * random.uintLessThan(usize, c.nodes.len / 2)
        else
            random.uintLessThan(usize, c.nodes.len);
        const node = c.nodes[index];
        if (node.down or node.sim.crashed) return;
        c.stats.relabel_restarts += 1;
        node.relabel_pending = true;
        node.wipe_pending = true;
        if (odd) {
            const set = node.label_set;
            node.relabel_to = if (set < 2) set + 2 else set - 2;
        }
        node.sim.crash_now(.host);
        node.check_crashed();
    }

    fn create_job(c: *Cluster) void {
        _ = c.create_job_as(c.job_next);
    }

    /// The reuse world's seam: the store's retention runs as if an hour had passed, without
    /// ticking an agent. Two passes (the first ends a sweep cycle, the second deletes what was
    /// old when it began); jobs that ended in the last minute stay.
    fn retention_jump(c: *Cluster) void {
        if (store_faulty(c)) return;
        // The jump stands for an hour in which the J4 client, which is never away that long,
        // would have polled: it catches up first, or retention would delete endings it had no
        // time to see (a property of the jump, not of the server).
        c.jobs_watch.away_until_ms = 0;
        const head = c.store_handle().status(&c.diag) catch return;
        sim_jobs_watch.finish(&c.jobs_watch, &c.api, &c.controller_context(), head.revision);
        c.retention_running = true;
        defer c.retention_running = false;
        const gap = constants.job_finished_age_ms_min - 60_000;
        const now = c.manual.ms +| gap;
        for (0..2) |_| {
            var scratch = std.heap.ArenaAllocator.init(c.gpa);
            defer scratch.deinit();
            c.diag.reset();
            const ctx: controller.Context = .{
                .store = c.store_handle(),
                .clock = c.manual.clock(),
                .arena = scratch.allocator(),
                .diag = &c.diag,
            };
            _ = job_retention.prune_or_back_off(&ctx, &c.reuse_cursor, now);
        }
        c.reuse_jumps += 1;
    }

    /// The job to reuse: one whose container stopped with an exit code (the stale container a
    /// run of the same name could take for its own), else a random one.
    fn reuse_pick(c: *Cluster) u32 {
        assert(c.job_next > 1);
        var seen: u32 = 0;
        var chosen: u32 = 0;
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                const job = job_of(container) orelse continue;
                if (container.phase != .stopped) continue;
                if (container.phase.stopped != .exited) continue;
                if (!std.mem.startsWith(u8, job, "jb-")) continue;
                const number = std.fmt.parseInt(u32, job[3..], 10) catch continue;
                if (number == 0 or number >= c.job_next) continue;
                seen += 1;
                if (c.prng.random().uintLessThan(u32, seen) == 0) chosen = number;
            }
        }
        if (chosen != 0) return chosen;
        return 1 + c.prng.random().uintLessThan(u32, c.job_next - 1);
    }

    /// A create of a name used before: the older incarnation was deleted by retention, or the
    /// create is refused (the name is taken; false). Counts when it met a container of that name.
    fn reuse_job(c: *Cluster) bool {
        if (c.job_next == 1) return false;
        const number = c.reuse_pick();
        var name_buffer: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "jb-{d}", .{number}) catch
            unreachable; // "jb-" and a u32 fit.
        if (!c.create_job_as(number)) return false;
        c.reuse_made += 1;
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                const job = job_of(container) orelse continue;
                if (std.mem.eql(u8, job, name)) {
                    c.reuse_met += 1;
                    return true;
                }
            }
        }
        return true;
    }

    /// Creates job `number`; false if the create was refused.
    fn create_job_as(c: *Cluster, number: u32) bool {
        const random = c.prng.random();
        var name_buffer: [16]u8 = undefined;
        // "jb-" and a u32 fit.
        const name = std.fmt.bufPrint(&name_buffer, "jb-{d}", .{number}) catch unreachable;
        // Every 13th job asks for more cpu than any node has, so that no node ever claims it and
        // its run must end `not_started` (J8's second clause). No draw, and only with
        // `Options.strong`: other worlds are unchanged.
        const fresh = number == c.job_next;
        const unplaceable = c.strong and number % 13 == 5;
        // Every third job (job numbers 1, 4, 7, ...; `job_relayed`) names the relay (B3 slice 3).
        // No draw, and only with `Options.strong`.
        const relayed = c.strong and job_relayed(number);
        // B6: in the tenant world most jobs name a tenant (`job_tenant`; no draw).
        var require_buffer: [1]records.Pair = undefined;
        var placement: ?job_api.PlacementInput = null;
        if (c.tenants) {
            if (sim_tenancy.job_tenant(number)) |tenant| {
                require_buffer[0] = .{ "tenant", tenant };
                placement = .{ .require = &require_buffer };
            }
        }
        if (fresh) c.job_next += 1;
        var buffer: [16]u8 = undefined;
        const id = c.request_id(&buffer);
        const ctx = c.controller_context();
        const long = random.uintLessThan(u32, 4) == 0;
        // The `job_deadline_offline` tooth: deadlines that fall within the run (see `add_jobs`).
        const spread: u32 = if (c1_teeth.burst_world)
            1000
        else if (c1_teeth.offline_world)
            10_000
        else
            40_000;
        _ = job_api.create(&ctx, &c.api_source, .{
            .name = name,
            .image = hello_digest,
            .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
            .limits = .{
                .cpu_millis = if (unplaceable) 100_000 else 10,
                .memory_bytes = constants.job_limit_memory_bytes_min,
            },
            .deadline_ms = if (long) 600_000 else 3000 + random.uintLessThan(u32, spread),
            .grace_ms = random.uintLessThan(u32, 2000),
            .submit_by_ms = c.manual.ms + 5000 + random.uintLessThan(u32, 20_000),
            .relay = if (relayed) sim_relays[0].name else null,
            .relays = &sim_relays,
            .placement = placement,
            .applied_by = "alex@laptop",
            .request_id = id,
        }) catch {
            c.diag.reset();
            return false;
        };
        c.jobs.created += 1;
        return true;
    }

    /// The job of a random live job container, copied into `buffer`; null if none runs. Half of
    /// the cancels go to a running job, so that the stop reaches an agent holding a container.
    fn live_job(c: *Cluster, buffer: []u8) ?[]const u8 {
        var live: u32 = 0;
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                live += @intFromBool(container.phase != .stopped and job_of(container) != null);
            }
        }
        if (live == 0) return null;
        var pick = c.prng.random().uintLessThan(u32, live);
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                const job = job_of(container) orelse continue;
                if (container.phase == .stopped) continue;
                if (pick > 0) {
                    pick -= 1;
                    continue;
                }
                if (job.len > buffer.len) return null;
                @memcpy(buffer[0..job.len], job);
                return buffer[0..job.len];
            }
        }
        return null;
    }

    /// A running job three times in four; else the newest job a third of the time, else any
    /// made so far.
    fn cancel_job(c: *Cluster) void {
        if (c.job_next == 1) return;
        const random = c.prng.random();
        var name_buffer: [16]u8 = undefined;
        const live = if (random.uintLessThan(u32, 4) != 0) c.live_job(&name_buffer) else null;
        const name = live orelse name: {
            const number = if (random.uintLessThan(u32, 3) == 0)
                c.job_next - 1
            else
                1 + random.uintLessThan(u32, c.job_next - 1);
            // "jb-" and a u32 fit.
            break :name std.fmt.bufPrint(&name_buffer, "jb-{d}", .{number}) catch unreachable;
        };
        var buffer: [16]u8 = undefined;
        const id = c.request_id(&buffer);
        const ctx = c.controller_context();
        _ = job_api.cancel(&ctx, &c.api_source, name, "alex@laptop", id) catch {
            c.diag.reset();
            return;
        };
        c.jobs.cancelled += 1;
    }

    /// A job's container ends by itself: it exits, is killed, runs out of memory or of pids.
    fn end_job(c: *Cluster) void {
        var live: u32 = 0;
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                live += @intFromBool(container.phase != .stopped and job_of(container) != null);
            }
        }
        if (live == 0) return;
        const random = c.prng.random();
        var pick = random.uintLessThan(u32, live);
        const fault: sim_runtime.Fault = switch (random.uintLessThan(u32, 5)) {
            0, 1 => .{ .exit = 0 },
            2 => .{ .exit = 1 },
            3 => .{ .signal = 9 },
            else => .oom,
        };
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                if (container.phase == .stopped or job_of(container) == null) continue;
                if (pick > 0) {
                    pick -= 1;
                    continue;
                }
                node.sim.containers.inject(container.name, fault) catch return;
                c.jobs.ended += 1;
                return;
            }
        }
    }

    fn pick_node(c: *Cluster) *Node {
        // A `u32` draw: the stream is the same on every target, which `usize` would not give.
        const count: u32 = @intCast(c.nodes.len);
        return c.nodes[c.prng.random().uintLessThan(u32, count)];
    }
};

const tenant_sets = sim_tenancy.tenant_sets;

/// Whether the `strong` world's job number `n` names the relay (every third; no draw).
fn job_relayed(n: u32) bool {
    return n % 3 == 1;
}

const job_number = sim_tenancy.job_number;

/// The job a container belongs to, from its label; null for a replica's container.
fn job_of(container: anytype) ?[]const u8 {
    for (container.labels) |label| {
        if (std.mem.eql(u8, label.key, runtime.label_job)) return label.value;
    }
    return null;
}

/// A node's runtime is about to start a container: the ledger judges it (J2, J7) against the
/// store as committed, read beneath the faults.
fn job_started(context: *anyopaque, spec: *const runtime.Spec) void {
    const node: *Node = @ptrCast(@alignCast(context));
    const c = node.cluster;
    if (!c.jobs_on) return;
    // R3: the spec the agent built carries the relay the job asked for, resolved, and no other.
    if (job_of(spec)) |job| {
        const want: []const u8 = if (c.strong and job_relayed(job_number(job) orelse 0))
            sim_relays[0].address
        else
            "";
        if (!std.mem.eql(u8, spec.relay, want)) c.relay_spec_wrong = true;
    }
    const hash = std.hash.Wyhash.hash(0, spec.name);
    assert(hash != 0);
    node.started_true[node.started_next % node.started_true.len] = .{
        .hash = hash,
        .ms = @max(c.manual.ms, node.nclock.busy_until_true_ms),
    };
    node.started_next +%= 1;
    _ = c.tap_arena.reset(.retain_capacity);
    c.tap_diag.reset();
    const ctx: controller.Context = .{
        .store = c.tap.inner,
        .clock = c.manual.clock(),
        .arena = c.tap_arena.allocator(),
        .diag = &c.tap_diag,
    };
    sim_jobs.note_start(&c.jobs, &ctx, node.name(), node.agent.tenure, spec);
}

/// The tap's `after`: checks the revision a call just made (`sim_c1.at_revision`).
fn tapped(context: *anyopaque, request: ?store.TxnRequest, revision: store.Revision) void {
    const c: *Cluster = @ptrCast(@alignCast(context));
    if (!c.c1) {
        // J4 judges the endings the store committed, with or without the per-revision checks.
        if (!c.jobs_on) return;
        const txn = request orelse return;
        _ = c.tap_arena.reset(.retain_capacity);
        sim_jobs_watch.note_commit(&c.jobs_watch, txn, revision, c.tap_arena.allocator());
        return;
    }
    c.c1_revisions += 1;
    if (request) |txn| c.note_replaced(txn);
    _ = c.tap_arena.reset(.retain_capacity);
    c.tap_diag.reset();
    const ctx: controller.Context = .{
        .store = c.tap.inner,
        .clock = c.manual.clock(),
        .arena = c.tap_arena.allocator(),
        .diag = &c.tap_diag,
    };
    if (request) |txn| c.recorder.record_request(&ctx, txn);
    if (request) |txn| {
        if (c.jobs_on) {
            sim_jobs_watch.note_commit(&c.jobs_watch, txn, revision, c.tap_arena.allocator());
        }
    }
    note_tenancy(c, &ctx, request);
    if (c.c1_violation != null) return;
    if (request != null) {
        if (c.c1_pending) |found| {
            c.c1_violation = found;
            c.c1_violation_revision = revision;
            return;
        }
    }
    if (sim_c1.at_revision(&ctx, request, c.retention_running)) |found| {
        c.c1_violation = found;
        c.c1_violation_revision = revision;
    }
}

/// The tap's `before`: the negative tests' injection, then I2 and I3 over the head the
/// transaction is about to commit over (`sim_c1.before_commit`); `tapped` acts on the verdict if
/// the transaction commits.
fn before_commit(context: *anyopaque, request: store.TxnRequest) void {
    const c: *Cluster = @ptrCast(@alignCast(context));
    if (!c.c1) return;
    if (c1_teeth.skip_allocation_compare or c1_teeth.skip_readiness_compare) {
        inject(context, request);
    }
    if (c1_teeth.stale_observation) inject_reregistration(c, request);
    if (c1_teeth.job_double) inject_run_stop(c, request);
    _ = c.tap_arena.reset(.retain_capacity);
    c.tap_diag.reset();
    const ctx: controller.Context = .{
        .store = c.tap.inner,
        .clock = c.manual.clock(),
        .arena = c.tap_arena.allocator(),
        .diag = &c.tap_diag,
    };
    c.c1_pending = sim_c1.before_commit(&ctx, request, &c.c1_tally);
    if (c.tenants and c.c1_pending == null) {
        const names = c.node_names();
        c.c1_pending = sim_tenancy.placed_problem(&c.tenancy, &ctx, names.slice(), request);
    }
}

/// The names of the simulated nodes, and the label set each one's agent runs with (B6).
const NodeNames = struct {
    names: [nodes_max][]const u8 = undefined,
    sets: [nodes_max]u8 = undefined,
    count: u32 = 0,

    fn slice(n: *const NodeNames) []const []const u8 {
        return n.names[0..n.count];
    }
};

/// P1 (B6): a revision that touched `/nodes/` (or a lease expiry) may be a registration; the judge
/// records which set each tenure registered with and checks the stored labels against it.
fn note_tenancy(c: *Cluster, ctx: *const controller.Context, request: ?store.TxnRequest) void {
    if (!c.tenants) return;
    if (request) |txn| {
        var touched = false;
        for (txn.on_success) |op| {
            const key = switch (op) {
                .put => |put| put.key,
                .delete => |key| key,
            };
            if (std.mem.startsWith(u8, key, records.prefix_nodes)) touched = true;
        }
        if (!touched) return;
    }
    const names = c.node_names();
    sim_tenancy.note_registrations(&c.tenancy, ctx, names.slice(), names.sets[0..names.count]);
}

/// P1b (B6), once a second while the store is healthy: refused holds are acted on in time.
fn track_tenancy(c: *Cluster) Failure!void {
    if (!c.tenants or !c.c1) return;
    try check(c, c.tenancy.violation == null, c.tenancy.violation orelse "");
    if (store_faulty(c)) {
        c.store_healthy_since_ms = c.manual.ms; // As `track_jobs` keeps it.
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    c.diag.reset();
    const ctx: controller.Context = .{
        .store = c.tap.inner,
        .clock = c.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &c.diag,
    };
    const names = c.node_names();
    const now = c.manual.ms;
    const healthy = c.store_healthy_since_ms;
    const found = sim_tenancy.scan(&c.tenancy, &ctx, names.slice(), now, healthy, false);
    try check(c, found == null, found orelse "");
}

/// The injection of the two negative tests (compare skipped): just ahead of the scheduler's
/// first placement it commits the competing write that the missing compare would have caught.
fn inject(context: *anyopaque, request: store.TxnRequest) void {
    const c: *Cluster = @ptrCast(@alignCast(context));
    if (c.injected) return;
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_assigned)) continue;
        const rest = put.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
        c.injected = true;
        if (c1_teeth.skip_readiness_compare) return inject_node_lost(c, rest[0..slash]);
        return inject_competing_placement(
            c,
            rest[0..slash],
            allocation_node_revision(c, request, rest[0..slash]),
        );
    }
}

/// Another writer commits a run's `stop`, once, just ahead of the scheduler's first placement of a
/// run: the compare of the run, which the negative test leaves out, would have refused it (J5).
fn inject_run_stop(c: *Cluster, request: store.TxnRequest) void {
    if (c.injected) return;
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_assigned)) continue;
        const rest = put.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const job = records.job_of_run(rest[slash + 1 ..]) orelse continue;
        c.injected = true;
        var arena = std.heap.ArenaAllocator.init(c.gpa);
        defer arena.deinit();
        var scratch: Diag = undefined;
        scratch.reset();
        const key = records.job_run_key(job);
        const got = c.tap.inner.get(arena.allocator(), key.slice(), null, &scratch) catch return;
        const kv = got.kv orelse return;
        var run = records.read(records.JobRun, arena.allocator(), kv, &scratch) catch return;
        run.stop = .{ .cause = .cancel, .at_ms = c.manual.ms };
        const bytes = records.encode(arena.allocator(), run, &scratch) catch return;
        const ops = [_]store.Op{.{ .put = .{ .key = key.slice(), .value = bytes } }};
        _ = c.tap.inner.txn(.{ .on_success = &ops }, &scratch) catch scratch.reset();
        return;
    }
}

/// The node a decision cites a report of registers again (a new tenure), once, just before that
/// decision commits: the report was admissible when the controller read it, and is not now.
fn inject_reregistration(c: *Cluster, request: store.TxnRequest) void {
    if (c.injected) return;
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_decisions)) continue;
        const arena = c.tap_arena.allocator();
        const decision = std.json.parseFromSliceLeaky(records.Decision, arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        const cited = decision.cause.key orelse continue;
        if (decision.cause.kind != .observed) continue;
        if (!std.mem.startsWith(u8, cited, records.prefix_observed)) continue;
        const rest = cited[records.prefix_observed.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const key = records.node_key(rest[0..slash]);
        var scratch: Diag = undefined;
        scratch.reset();
        const got = c.tap.inner.get(c.tap_arena.allocator(), key.slice(), null, &scratch) catch {
            scratch.reset();
            continue;
        };
        const kv = got.kv orelse continue;
        c.injected = true;
        const same: store.Put = .{ .key = kv.key, .value = kv.value, .lease = kv.lease };
        const ops = [_]store.Op{.{ .put = same }};
        _ = c.tap.inner.txn(.{ .on_success = &ops }, &scratch) catch scratch.reset();
        return;
    }
}

/// The `node_revision` the scheduler's own allocation put carries, which a competing put copies.
fn allocation_node_revision(c: *Cluster, request: store.TxnRequest, node: []const u8) u64 {
    const key = records.allocation_key(node);
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.eql(u8, put.key, key.slice())) continue;
        const arena = c.tap_arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(records.Allocation, arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch return 0;
        return parsed.node_revision;
    }
    return 0;
}

/// The node is lost between the scheduler's read and its commit.
fn inject_node_lost(c: *Cluster, node: []const u8) void {
    var scratch: Diag = undefined;
    scratch.reset();
    const key = records.node_key(node);
    const ops = [_]store.Op{.{ .delete = key.slice() }};
    _ = c.tap.inner.txn(.{ .on_success = &ops }, &scratch) catch scratch.reset();
}

/// Another writer places a replica on the node and raises its allocation by it, after the
/// scheduler read the allocation: the scheduler's allocation put is then built from a stale sum.
fn inject_competing_placement(c: *Cluster, node: []const u8, node_revision: u64) void {
    var arena = std.heap.ArenaAllocator.init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var scratch: Diag = undefined;
    scratch.reset();
    const allocation_key = records.allocation_key(node);
    const got = c.tap.inner.get(a, allocation_key.slice(), null, &scratch) catch return;
    const before: records.Allocation = if (got.kv) |kv|
        records.read(records.Allocation, a, kv, &scratch) catch return
    else
        .{
            .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 },
            .count = 0,
            .node_revision = node_revision,
        };
    const extra: records.Requests = .{ .cpu_millis = 1, .memory_bytes = 1 };
    const assigned = records.assigned_replica(
        "c1-injected",
        "c1-injected",
        extra,
        "a competing placement (negative test)",
    );
    const after: records.Allocation = .{
        .allocated = .{
            .cpu_millis = before.allocated.cpu_millis + extra.cpu_millis,
            .memory_bytes = before.allocated.memory_bytes + extra.memory_bytes,
        },
        .count = before.count + 1,
        .node_revision = before.node_revision,
    };
    const assigned_key = records.assigned_key(node, "c1-injected");
    const assigned_bytes = records.encode(a, assigned, &scratch) catch return;
    const allocation_bytes = records.encode(a, after, &scratch) catch return;
    const ops = [_]store.Op{
        .{ .put = .{ .key = assigned_key.slice(), .value = assigned_bytes } },
        .{ .put = .{ .key = allocation_key.slice(), .value = allocation_bytes } },
    };
    _ = c.tap.inner.txn(.{ .on_success = &ops }, &scratch) catch scratch.reset();
}

fn c1_check(c: *Cluster) Failure!void {
    if (!c.c1) return;
    try check(c, c.c1_violation == null, c.c1_violation orelse "");
}

/// I1b (docs/authority.md §4): a replica the server replaced (`mark_replica_lost`, which lets the
/// scheduler place a successor under a new id) is not still executing on its old node for longer
/// than the lost grace plus the kill latency, unless that node was wedged (its agent down or
/// frozen, or a kill that fails) now or lately, which the run records without failing. With the
/// wedge negative test on, nothing is excused. A replica's two instances have different container
/// names, so the pair is found through the replacement, not through a shared name.
fn track_overlap(c: *Cluster) Failure!void {
    var kept: u32 = 0;
    for (c.overlaps[0..c.overlap_count]) |*entry| {
        var running = false;
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                if (container.phase == .stopped) continue;
                if (std.hash.Wyhash.hash(0, container.name) != entry.name_hash) continue;
                running = true;
                if (c.wedged_lately(node)) entry.wedged_at_ms = c.manual.ms;
            }
        }
        if (!running) continue; // Stopped: the overlap is over.
        c.overlaps[kept] = entry.*;
        kept += 1;
        const length = c.manual.ms - entry.since_ms;
        // The excuse lasts while a node running the replica is wedged, and for the bound after
        // it last was: a wedge long past does not excuse an overlap that goes on.
        const excused_from = entry.wedged_at_ms orelse entry.since_ms;
        const from = if (c1_teeth.wedge) entry.since_ms else excused_from;
        if (entry.wedged_at_ms != null) {
            c.overlap_wedged_worst_ms = @max(c.overlap_wedged_worst_ms, length);
        } else {
            c.overlap_worst_ms = @max(c.overlap_worst_ms, length);
        }
        const counted = c.manual.ms - from;
        try check(c, counted <= overlap_ms_max, "I1b: a replaced replica kept executing longer " ++
            "than the lost grace plus the kill latency");
    }
    c.overlap_count = kept;
}

fn executes(node: *const Node, name: []const u8) bool {
    for (node.sim.containers.containers.items) |container| {
        if (container.phase == .stopped) continue;
        if (std.mem.eql(u8, container.name, name)) return true;
    }
    return false;
}

fn runs(node: *const Node, name: []const u8) bool {
    for (node.sim.containers.containers.items) |container| {
        if (container.phase != .running) continue;
        if (std.mem.eql(u8, container.name, name)) return true;
    }
    return false;
}

// ---- The workload -------------------------------------------------------------------------------

const Op = enum {
    advance,
    apply,
    scale,
    delete,
    broken,
    runtime_fault,
    crash,
    partition,
    outage,
    server_restart,
    suspend_node,
    /// sim-c1 only: an agent stops taking steps for a while, its containers keep running.
    freeze,
    job_create,
    job_cancel,
    job_end,
};

/// With `faults_on` false (after the heal) the fault operations get no weight.
fn pick_op(swarm: *const Swarm, random: std.Random, faults_on: bool) Op {
    const f: u32 = @intFromBool(faults_on);
    const weights = [_]u32{
        swarm.w_advance,    swarm.w_apply,         swarm.w_scale,
        swarm.w_delete,     swarm.w_broken,        swarm.w_runtime * f,
        swarm.w_crash * f,  swarm.w_partition * f, swarm.w_outage * f,
        swarm.w_server * f, swarm.w_suspend * f,   swarm.w_freeze * f,
        swarm.w_job_create, swarm.w_job_cancel,    swarm.w_job_end,
    };
    comptime assert(weights.len == @typeInfo(Op).@"enum".field_names.len);
    var total: u32 = 0;
    for (weights) |weight| total += weight;
    var pick = random.uintLessThan(u32, total);
    for (weights, 0..) |weight, index| {
        if (pick < weight) return @fromBackingInt(@intCast(index));
        pick -= weight;
    }
    unreachable; // `pick` is below the total.
}

fn operation(c: *Cluster) void {
    if (c.tenants and c.fault_totals == null) c.relabel_node();
    const random = c.prng.random();
    const name = service_names[random.uintLessThan(u32, service_names.len)];
    switch (pick_op(&c.swarm, random, c.fault_totals == null)) {
        .advance => {
            c.advance(100 + random.uintLessThan(u32, 6000));
        },
        .apply => c.apply(name, images[random.uintLessThan(u32, 2)], c.replicas_for(random, 5)),
        .scale => c.apply(name, hello_digest, c.replicas_for(random, 8)),
        .delete => c.delete_service(name),
        .broken => c.apply(name, broken_digest, 1 + c.replicas_for(random, 2)),
        .runtime_fault => {
            const injected = c.pick_node().sim.containers.random_fault();
            if (injected != null) c.stats.runtime_faults += 1;
        },
        .crash => c.crash(c.pick_node()),
        .partition => c.partition(c.pick_node()),
        .outage => {
            c.stats.outages += 1;
            c.switched.fail_after = 1 + random.uintLessThan(u32, 40);
            c.advance(random.uintLessThan(u32, outage_ms_max));
            c.set_store_down(false);
        },
        .server_restart => c.restart_server(),
        .suspend_node => {
            c.stats.suspends += 1;
            c.pick_node().nclock.jump_forward(1000 + random.uintLessThan(u32, 20_000));
        },
        .freeze => {
            const span = freeze_ms_min + random.uintLessThan(u32, freeze_ms_spread);
            // Never the last unfrozen node: a cluster with every agent frozen does no work, which
            // `enough_work_under_faults` would then rightly call a failure of the world.
            const node = c.pick_node();
            var unfrozen: u32 = 0;
            for (c.nodes) |other| {
                if (other.frozen_until_ms == null) unfrozen += 1;
            }
            if (unfrozen > 1 or node.frozen_until_ms != null) {
                node.frozen_until_ms = c.manual.ms + span;
            }
        },
        .job_create => {
            // The burst world (#198): a burst, so that one node starts dozens of runs in a step.
            const burst: u32 = if (c1_teeth.burst_world) 12 else 1;
            for (0..burst) |_| c.create_job();
            if (c1_teeth.reuse_world) {
                c.reuse_ops += 1;
                // Reuse follows the jump at once: no agent step lies between, so a container of
                // the deleted incarnation still stands when its name is made again.
                if (c.reuse_ops % 3 == 0) c.retention_jump();
                // A few tries: most names are still held by their job, and are refused.
                if (c.reuse_ops % 3 == 0) {
                    var made: u32 = 0;
                    for (0..16) |_| {
                        if (c.reuse_job()) made += 1;
                        if (made == 4) break;
                    }
                }
            }
        },
        .job_cancel => c.cancel_job(),
        .job_end => c.end_job(),
    }
    c.advance(100);
}

// ---- Checks -------------------------------------------------------------------------------------

const Failure = error{StepFailed};

fn check(c: *Cluster, ok: bool, what: []const u8) Failure!void {
    if (ok) return;
    c.report.failed = true;
    c.report.print("FAILED: {s} (seed {d}, at {d} ms)\n", .{
        what, c.seed, c.manual.ms - epoch_ms,
    });
    c.report.print("step: {s}\n", .{c.step});
    return error.StepFailed;
}

/// sim-c0's invariants over the whole store: every decision has a reason and a cause that
/// exists, `why` terminates, every replica has its create (and place) decision.
fn invariants(c: *Cluster) Failure!void {
    try check(c, c.i6_violations == 0, "I6: an allocation disagrees with its assignments");
    if (store_faulty(c)) return;
    const head = c.revision();
    try check(c, head != null, "the store cannot be read");
    // These checks read only the store (and whether a write was dropped): the same revision and
    // drop count as the last time that passed means the same answer.
    const dropped = c.dropped_total();
    if (c.checked_revision == head and c.checked_dropped == dropped) return;
    const ctx = c.controller_context();
    try decisions_have_causes(c, &ctx);
    try verdict(c, sim_checks.no_findings(&ctx));
    try verdict(c, sim_checks.placements(&ctx, c.i7_revision, head.?));
    c.i7_revision = head.?;
    const snapshot = controller.read_snapshot(&ctx) catch
        return check(c, false, "the snapshot cannot be read");
    for (snapshot.services) |service| {
        try why_terminates(c, &ctx, .{ .kind = .service, .name = service.rec.name });
    }
    for (snapshot.replicas) |replica| {
        try why_terminates(c, &ctx, .{ .kind = .replica, .name = replica.rec.id });
        try replica_has_decisions(c, &ctx, &replica.rec, snapshot.node_of(replica.rec.id) != null);
    }
    c.checked_revision = head;
    c.checked_dropped = dropped;
}

fn why_terminates(
    c: *Cluster,
    ctx: *const controller.Context,
    subject: records.Subject,
) Failure!void {
    const result = why_mod.why(ctx, subject, null) catch |err| {
        ctx.diag.reset();
        return check(c, err == error.NotFound, "why failed with something but NotFound");
    };
    try check(c, result.steps.len <= constants.why_steps_max, "why is too long");
    if (result.steps.len == 0) return;
    const last = result.steps[result.steps.len - 1];
    try check(c, last.type != .decision, "a why chain ends in a decision, not a cause");
}

/// Every decision has a reason and a cause that exists; a replica of a lost node is replaced no
/// earlier than the grace after its node's `mark_lost`; and, while retention has dropped nothing,
/// every summary's `count` is the number of decisions written for its subject, action and kind
/// of cause, read at one revision.
fn decisions_have_causes(c: *Cluster, ctx: *const controller.Context) Failure!void {
    var counts: sim_checks.Counts = .empty;
    var after: ?[]const u8 = null;
    var at: ?store.Revision = null;
    var nodes_lost: u32 = 0;
    var replicas_lost: u32 = 0;
    for (0..64) |_| {
        const page = ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_decisions,
            .at_revision = at,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag) catch return check(c, false, "the decisions cannot be listed");
        at = page.revision;
        for (page.kvs) |kv| {
            const decision = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch
                return check(c, false, "a decision cannot be read");
            try decision_has_cause(c, ctx, &decision);
            try verdict(c, sim_checks.count(ctx, &counts, &decision));
            if (std.mem.eql(u8, decision.action, "mark_lost")) nodes_lost += 1;
            // A `mark_replica_lost` caused by a decision is the grace's end (the others are
            // caused by an observed record).
            const by_node = decision.cause.kind == .decision;
            if (std.mem.eql(u8, decision.action, "mark_replica_lost") and by_node) {
                replicas_lost += 1;
            }
        }
        after = page.continue_after;
        if (after != null) continue;
        c.stats.nodes_marked_lost = @max(c.stats.nodes_marked_lost, nodes_lost);
        c.stats.replicas_marked_lost = @max(c.stats.replicas_marked_lost, replicas_lost);
        if (c.dropped_total() > 0) return;
        return verdict(c, sim_checks.summaries(ctx, &counts, at.?));
    }
    return check(c, false, "there are more decisions than the check reads");
}

fn verdict(c: *Cluster, found: sim_checks.Found) Failure!void {
    if (found) |what| return check(c, false, what);
}

fn decision_has_cause(
    c: *Cluster,
    ctx: *const controller.Context,
    decision: *const records.Decision,
) Failure!void {
    try check(c, decision.reason.len > 0, "a decision has no reason");
    const cause = decision.cause;
    switch (cause.kind) {
        .decision => {
            const id = cause.id orelse return check(c, false, "a cause names no decision");
            const key = records.decision_key(id);
            const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch
                return check(c, false, "a cause cannot be read");
            const dropped = c.dropped_total() > 0;
            try check(c, got.kv != null or dropped, "a decision's cause was never written");
            const grace_ms = c.server.replicas.lost_grace_ms;
            try verdict(c, sim_checks.lost_grace(ctx, decision, got.kv, grace_ms));
        },
        .observed, .desired => try check(c, cause.key != null, "a cause names no key"),
        .lease_expired, .resync => {},
    }
}

fn replica_has_decisions(
    c: *Cluster,
    ctx: *const controller.Context,
    replica: *const records.Replica,
    assigned: bool,
) Failure!void {
    const prefix = records.index_prefix(.replica, replica.id);
    const query: store.ListOptions = .{ .prefix = prefix.slice(), .limit = 64 };
    const page = ctx.store.list(ctx.arena, query, ctx.diag) catch
        return check(c, false, "a replica's decisions cannot be listed");
    var created = false;
    var placed = false;
    for (page.kvs) |kv| {
        const entry = records.read(records.IndexEntry, ctx.arena, kv, ctx.diag) catch
            return check(c, false, "an index entry cannot be read");
        if (std.mem.eql(u8, entry.action, "create_replica")) created = true;
        if (std.mem.eql(u8, entry.action, "place_replica")) placed = true;
    }
    try check(c, created, "a replica has no create_replica decision");
    if (assigned) try check(c, placed, "a placed replica has no place decision");
}

/// The store is down, or about to be: reads would fail and would use up the countdown.
fn store_faulty(c: *const Cluster) bool {
    if (c.switched.fail_after != null) return true;
    return c.switched.down;
}

/// One container that no replica assigns to its node: when it was first seen is not kept, only
/// how long its node could have stopped it, so an outage or a cut link does not run the clock.
const Excess = struct { node: u32, name_hash: u64, accrued_ms: u64 };

/// What is checked every `check_interval_ms` and after every operation.
fn safety(c: *Cluster) Failure!void {
    try c1_check(c);
    try invariants(c);
    try track_excess(c);
    try track_fencing(c);
    try track_jobs(c);
}

/// I3 (docs/authority.md §3): no container runs on a node the server has given up on for longer
/// than the grace plus the simulator's own granularity. The server has given up on a node when
/// its `/nodes/<node>` key is gone (its lease ran out). The clock restarts while the agent is
/// down (a dead agent cannot fence; its restart does, at its first step).
fn track_fencing(c: *Cluster) Failure!void {
    if (store_faulty(c)) return;
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    for (c.nodes) |node| {
        if (node.down or node.frozen_until_ms != null) {
            node.unregistered_since_ms = null;
            continue;
        }
        const key = records.node_key(node.name());
        c.diag.reset();
        const got = c.store_handle().get(scratch.allocator(), key.slice(), null, &c.diag) catch {
            c.diag.reset();
            continue;
        };
        if (got.kv != null) {
            node.unregistered_since_ms = null;
            continue;
        }
        const since = node.unregistered_since_ms orelse c.manual.ms;
        node.unregistered_since_ms = since;
        if (c.manual.ms - since <= fencing_ms_max) continue;
        for (node.sim.containers.containers.items) |container| {
            const message = "a container runs on a node whose lease ran out longer ago than " ++
                "the lost grace (self-fencing failed)";
            try check(c, container.phase == .stopped, if (c.c1) "I1b: " ++ message else message);
        }
    }
}

/// How long a node may run containers after the server's lease on it ran out: the lost grace,
/// and the checks' and the ticks' granularity.
const fencing_ms_max: u64 = constants.lost_grace_ms + 2 * check_interval_ms;

/// Replica id to the node `/assigned/` puts it on.
const Homes = std.StringHashMapUnmanaged([]const u8);

fn read_homes(c: *Cluster, ctx: *const controller.Context) Failure!Homes {
    const assigned = controller.list_all(
        records.Assigned,
        ctx,
        records.prefix_assigned,
        null,
        constants.assigned_max,
    ) catch {
        try check(c, false, "the assignments cannot be read");
        return error.StepFailed;
    };
    var homes: Homes = .empty;
    for (assigned.items) |entry| {
        const rest = entry.kv.key[records.prefix_assigned.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
            {
                try check(c, false, "an assignment has a malformed key");
                return error.StepFailed;
            };
        homes.put(ctx.arena, entry.rec.replica, rest[0..slash]) catch {
            try check(c, false, "out of memory");
            return error.StepFailed;
        };
    }
    return homes;
}

/// Whether the replica `name` exists and `/assigned/` puts it on `node`: what the endpoint serves
/// the node's agent.
fn assigned_to(
    replicas: []const controller.Entry(records.Replica),
    homes: *const Homes,
    node: []const u8,
    name: []const u8,
) bool {
    for (replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.id, name)) continue;
        const home = homes.get(name) orelse return false;
        return std.mem.eql(u8, home, node);
    }
    return false;
}

fn excess_accrued(c: *const Cluster, node: u32, name_hash: u64) u64 {
    for (c.excess[0..c.excess_count]) |entry| {
        if (entry.node == node and entry.name_hash == name_hash) return entry.accrued_ms;
    }
    return 0;
}

/// Per container: one that is not stopped and that no replica of the store assigns to its own
/// node (a deleted replica, or one that lives on another node now) must be stopped within
/// `excess_ms_max` of the time its node could be told to: agent up, link not cut, store up. The
/// replicas are read once per call; when the store cannot be read nothing accrues.
fn track_excess(c: *Cluster) Failure!void {
    const delta_ms = c.manual.ms - c.excess_last_ms;
    c.excess_last_ms = c.manual.ms;
    if (store_faulty(c)) return;
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    c.diag.reset();
    const ctx: controller.Context = .{
        .store = c.store_handle(),
        .clock = c.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &c.diag,
    };
    const replicas = controller.list_all(
        records.Replica,
        &ctx,
        records.prefix_replicas,
        null,
        constants.replicas_max,
    ) catch {
        c.diag.reset();
        return;
    };
    const homes = read_homes(c, &ctx) catch {
        c.diag.reset();
        return;
    };
    try track_unassigned(c, replicas.items, &homes, delta_ms);
    try track_starved(c, replicas.items, &homes, delta_ms);
}

fn reachable(node: *const Node) bool {
    return !node.down and node.partitioned_until_ms == null;
}

fn track_unassigned(
    c: *Cluster,
    replicas: []const controller.Entry(records.Replica),
    homes: *const Homes,
    delta_ms: u64,
) Failure!void {
    var next: [excess_slots_max]Excess = undefined;
    var count: u32 = 0;
    for (c.nodes) |node| {
        for (node.sim.containers.containers.items) |container| {
            if (container.phase == .stopped or job_of(container) != null) continue;
            if (assigned_to(replicas, homes, node.name(), container.name)) continue;
            const hash = std.hash.Wyhash.hash(0, container.name);
            var accrued = excess_accrued(c, node.index, hash);
            if (reachable(node)) accrued += delta_ms;
            try check(c, accrued <= excess_ms_max, "a container runs that no replica assigns " ++
                "to its node");
            if (count == excess_slots_max) continue;
            next[count] = .{ .node = node.index, .name_hash = hash, .accrued_ms = accrued };
            count += 1;
        }
    }
    @memcpy(c.excess[0..count], next[0..count]);
    c.excess_count = count;
}

fn starved_accrued(c: *const Cluster, node: u32, name_hash: u64) u64 {
    for (c.starved[0..c.starved_count]) |entry| {
        if (entry.node == node and entry.name_hash == name_hash) return entry.accrued_ms;
    }
    return 0;
}

/// Per placed replica of a good image: its own node must come to hold a running container of
/// it. Time accrues while the node's agent is up and its link is not cut (the store is up, or
/// this is not reached); a running container resets it. A replica of a service whose image is
/// the broken one is skipped.
fn track_starved(
    c: *Cluster,
    replicas: []const controller.Entry(records.Replica),
    homes: *const Homes,
    delta_ms: u64,
) Failure!void {
    var next: [excess_slots_max]Excess = undefined;
    var count: u32 = 0;
    for (replicas) |entry| {
        const replica = &entry.rec;
        const home = homes.get(replica.id) orelse continue;
        if (std.mem.eql(u8, replica.image, broken_digest)) continue;
        const node = c.node_named(home) orelse continue;
        if (live_container(node, replica.id) == true) continue;
        const hash = std.hash.Wyhash.hash(0, replica.id);
        var accrued = starved_accrued(c, node.index, hash);
        if (reachable(node) and node.last_ok) accrued += delta_ms;
        c.starved_worst_ms = @max(c.starved_worst_ms, accrued);
        try check(c, accrued <= starved_ms_max, "a placed replica has no running container " ++
            "on its node");
        if (count == excess_slots_max) continue;
        next[count] = .{ .node = node.index, .name_hash = hash, .accrued_ms = accrued };
        count += 1;
    }
    @memcpy(c.starved[0..count], next[0..count]);
    c.starved_count = count;
}

/// A run's record and its job's status, read from the store as it is.
fn job_run_of(ctx: *const controller.Context, job: []const u8) ?records.JobRun {
    const key = records.job_run_key(job);
    const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const kv = got.kv orelse return null;
    return records.read(records.JobRun, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
}

fn job_status_of(ctx: *const controller.Context, job: []const u8) ?records.JobStatus {
    const key = records.job_status_key(job);
    const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const kv = got.kv orelse return null;
    return records.read(records.JobStatus, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
}

fn watch_of(c: *const Cluster, node: u32, name_hash: u64) ?sim_jobs.Watch {
    for (c.jobs.watch[0..c.jobs.watch_count]) |watch| {
        if (watch.node == node and watch.name_hash == name_hash) return watch;
    }
    return null;
}

/// The checks that hold the running job containers to a bound, on true time: J1 (no container
/// runs long past its job's terminal status), J6 (a run with a `stop` is not executing after the
/// stop bound) and J8 (no run executes past its deadline and grace, with the kill and the
/// clocks' rate error). A wedged node (as I1b: its agent down or frozen, or a container ignoring
/// a stop; a cut link is not wedged, and J8's bound has no term for it) is excused per check:
/// J6 and J8 subtract the wedged time from their bounds and judge every tick, and J1 starts its
/// clock only when the node has not been wedged lately. Every live job container has a watch
/// (RB-N8). The start ledger's verdict (J2, J7) is reported here too.
fn track_jobs(c: *Cluster) Failure!void {
    if (!c.jobs_on) return;
    try check(c, c.jobs.violation == null, c.jobs.violation orelse "");
    try check(c, c.jobs_watch.violation == null, c.jobs_watch.violation orelse "");
    try track_relays(c);
    const ledger_found = sim_jobs.ledger_problem(&c.jobs);
    try check(c, ledger_found == null, ledger_found orelse "");
    if (store_faulty(c)) {
        c.store_healthy_since_ms = c.manual.ms;
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    c.diag.reset();
    const ctx: controller.Context = .{
        .store = c.store_handle(),
        .clock = c.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &c.diag,
    };
    try unclaimed_ended(c, &ctx);
    if (c1_teeth.reuse_world) try started_ended(c, &ctx);
    comptime assert(nodes_max * constants.runtime_handles_max <= sim_jobs.watch_max);
    const next = scratch.allocator().alloc(sim_jobs.Watch, sim_jobs.watch_max) catch
        return check(c, false, "the job trackers are out of memory");
    var count: u32 = 0;
    for (c.nodes) |node| {
        for (node.sim.containers.containers.items) |container| {
            if (container.phase == .stopped) continue;
            const job = job_of(container) orelse continue;
            const hash = std.hash.Wyhash.hash(0, container.name);
            var watch = watch_of(c, node.index, hash) orelse sim_jobs.Watch{
                .node = node.index,
                .name_hash = hash,
                .first_seen_ms = node.started_true_of(hash) orelse c.manual.ms,
                .ended_since_ms = null,
            };
            if (watch_of(c, node.index, hash) == null) {
                watch.wedged_base_ms = node.wedged_total_ms;
            }
            const run = job_run_of(&ctx, job);
            if (run) |known| note_marks(c, known, node, &watch);
            try judge_job_container(c, &ctx, job, node, &watch, run);
            assert(count < sim_jobs.watch_max); // Every container of every runtime has a slot.
            next[count] = watch;
            count += 1;
        }
    }
    @memcpy(c.jobs.watch[0..count], next[0..count]);
    assert(count <= sim_jobs.watch_max);
    c.jobs.watch_count = count;
}

/// How long after its `start_by_ms` (or after the store last failed) a run that no node ever
/// started may stay open. The job controller ends it at once on a healthy store, its pass paced
/// by the wake it set for that time; this leaves room for a slow pass and a retried write.
const unclaimed_ms_max: u64 = 90_000;

/// J8, second clause: a run that was never started (no entry in the start ledger) is ended by
/// the server, whatever the nodes do, once its `start_by_ms` has passed. Judged only once the
/// store has been reachable for `unclaimed_ms_max`. A full ledger fails the run in `track_jobs`
/// first, so the ledger read here is whole.
fn unclaimed_ended(c: *Cluster, ctx: *const controller.Context) Failure!void {
    assert(c.jobs.ledger_full == 0);
    const job_runs = controller.list_all(
        records.JobRun,
        ctx,
        records.prefix_job_runs,
        null,
        constants.job_admitted_window_max,
    ) catch {
        // Judged only while the store is healthy (`track_jobs`), so a refusal, or more runs than
        // the admission window holds, is a failure, not a skip (RB-N8: past 512 runs).
        ctx.diag.reset();
        return check(c, false, "J8: the runs of the second clause cannot be read");
    };
    const now = c.manual.ms;
    for (job_runs.items) |entry| {
        const run = &entry.rec;
        if (now < @max(run.start_by_ms, c.store_healthy_since_ms) +| unclaimed_ms_max) continue;
        const status = job_status_of(ctx, run.job) orelse continue;
        if (records.job_state_terminal(status.state)) continue;
        const hash = sim_jobs.run_hash(run.id, entry.kv.create_revision);
        if (std.mem.indexOfScalar(u64, c.jobs.ledger[0..c.jobs.ledger_count], hash) != null) {
            continue;
        }
        try check(c, false, "J8: a run that no node started was still open long after its " ++
            "start_by_ms");
    }
}

/// J11 (the reuse world): a run whose status is `exited`, or failed by memory or process limit,
/// is an ending only a real container has, so some node started the run in its own incarnation.
/// A container left by an older run of the same name, taken for this one, makes a run that
/// ended without a start. `running` may be reported ahead of the start, and a `failed deadline`
/// can follow a start record whose container was never made: neither is judged.
fn ran_to_an_end(status: records.JobStatus) bool {
    return switch (status.state) {
        .exited => true,
        .failed => if ((status.end orelse return false).cause) |cause|
            cause == .oom or cause == .pid_limit
        else
            false,
        .pending, .placed, .running, .cancelled => false,
    };
}

fn started_ended(c: *Cluster, ctx: *const controller.Context) Failure!void {
    assert(c.jobs.ledger_full == 0);
    const job_runs = controller.list_all(
        records.JobRun,
        ctx,
        records.prefix_job_runs,
        null,
        constants.job_admitted_window_max,
    ) catch {
        ctx.diag.reset();
        return check(c, false, "J11: the runs cannot be read");
    };
    for (job_runs.items) |entry| {
        const run = &entry.rec;
        const status = job_status_of(ctx, run.job) orelse continue;
        if (!ran_to_an_end(status)) continue;
        if (status.node == null) continue;
        const hash = sim_jobs.run_hash(run.id, entry.kv.create_revision);
        if (std.mem.indexOfScalar(u64, c.jobs.ledger[0..c.jobs.ledger_count], hash) != null) {
            continue;
        }
        try check(c, false, "J11: a run ended after running that no node started");
    }
}

fn note_marks(
    c: *const Cluster,
    run: records.JobRun,
    node: *const Node,
    watch: *sim_jobs.Watch,
) void {
    const stopped = run.stop != null;
    sim_jobs.note_marks(
        watch,
        c.manual.ms,
        run.deadline_ms,
        stopped,
        node.wedged_total_ms,
    );
}

fn judge_job_container(
    c: *Cluster,
    ctx: *const controller.Context,
    job: []const u8,
    node: *const Node,
    watch: *sim_jobs.Watch,
    found: ?records.JobRun,
) Failure!void {
    const now = c.manual.ms;
    const run = found orelse return;
    const wedged = sim_jobs.wedged_since(watch, node.wedged_total_ms);
    const granularity = tick_ms + 2 * check_interval_ms;
    const bound = sim_jobs.deadline_bound_ms(
        run.deadline_ms,
        run.grace_ms,
        c.swarm.clock_ppm,
        granularity,
        wedged,
    );
    c.jobs.deadline_worst_ms = @max(c.jobs.deadline_worst_ms, sim_jobs.deadline_past_ms(
        now -| watch.first_seen_ms,
        run.deadline_ms,
        run.grace_ms,
        wedged,
    ));
    try check(c, now -| watch.first_seen_ms <= bound, "J8: a run kept executing past its " ++
        "deadline, its grace and the kill");
    if (run.stop) |stop| {
        const stop_bound = sim_jobs.stop_bound_ms(c.api.lease_ttl_ms, run.grace_ms, granularity);
        const base = watch.stop_wedged_base_ms orelse node.wedged_total_ms;
        const since = (now -| stop.at_ms) -| (node.wedged_total_ms - base);
        c.jobs.stop_worst_ms = @max(c.jobs.stop_worst_ms, since);
        try check(c, since <= stop_bound, "J6: a run kept executing after its stop committed, " ++
            "past the bound");
    }
    // J1 has no wedge allowance, so a node that is, or lately was, wedged is not judged for it
    // (RB-N8: J6 and J8 above count the wedged time out and are judged on every node).
    if (c.wedged_lately(node)) return;
    const status = job_status_of(ctx, job) orelse return;
    if (!records.job_state_terminal(status.state)) return;
    const ended = watch.ended_since_ms orelse now;
    watch.ended_since_ms = ended;
    c.jobs.overlap_worst_ms = @max(c.jobs.overlap_worst_ms, now - ended);
    try check(c, now - ended <= overlap_ms_max, "J1: a container kept executing after its " ++
        "job reached a terminal status");
}

/// B3's relay check (R1 to R3): a job's relay listener is open only while its run runs on that
/// node. Opened at start (R3: a running relayed job has one), closed by every ending before the
/// ending can be reported (R1: none stays open on a stopped or forgotten container) and never two
/// for one run (R2, across the nodes). Judged on every tick, store faults or not: the listeners
/// are the runtime's, not the store's.
fn track_relays(c: *Cluster) Failure!void {
    try check(c, !c.relay_spec_wrong, "R3: a job's spec lacks the relay the job asked for");
    for (c.nodes) |node| {
        const found = node.sim.containers.relay_problem();
        try check(c, found == null, found orelse "");
    }
    for (c.nodes, 0..) |node, index| {
        for (node.sim.containers.containers.items) |container| {
            if (!container.relay_open) continue;
            // R2 restates J2 and R1 (names are run ids; R1 closes every stopped container's
            // listener, J2 forbids a run on two nodes): it guards a listener keyed by anything
            // else. The same run's listener on this node's other containers cannot be (names are
            // unique); on another node, it is a second listener for one run.
            for (c.nodes[index + 1 ..]) |other| {
                for (other.sim.containers.containers.items) |twin| {
                    if (!twin.relay_open) continue;
                    const same = std.mem.eql(u8, container.name, twin.name);
                    try check(c, !same, "R2: two relay listeners are open for one run");
                }
            }
        }
    }
}

/// J10, at rest: no agent keeps a start record for a run whose assignment on its node is gone.
/// A report of such a run is refused at write time (J9), and the agent must end the run locally
/// instead of repeating the refusal on every pass (B2 review).
fn start_records_retired(c: *Cluster, ctx: *const controller.Context) Failure!void {
    for (c.nodes) |node| {
        const names = node.sim.files.interface().list(ctx.arena, agent_jobs.dir) catch
            return check(c, false, "J10: a node's start records cannot be listed");
        for (names) |entry| {
            if (!std.mem.endsWith(u8, entry, ".json")) continue;
            const run = entry[agent_jobs.dir.len .. entry.len - ".json".len];
            const placed = records.assigned_key(node.name(), run);
            const got = ctx.store.get(ctx.arena, placed.slice(), null, ctx.diag) catch
                return check(c, false, "J10: an assignment cannot be read");
            try check(c, got.kv != null, "J10: a start record outlives its run's assignment");
        }
    }
}

/// After the heal, with the world settled: no live container of an ended job, and no run still
/// open long after the latest it could have started and run (J1, J8 at rest).
fn jobs_converged(c: *Cluster, ctx: *const controller.Context) Failure!void {
    const job_runs = controller.list_all(
        records.JobRun,
        ctx,
        records.prefix_job_runs,
        null,
        constants.job_admitted_window_max,
    ) catch return check(c, false, "the job job_runs cannot be read");
    for (job_runs.items) |entry| {
        const run = &entry.rec;
        const status = job_status_of(ctx, run.job) orelse
            return check(c, false, "a job run has no status");
        if (!records.job_state_terminal(status.state)) {
            const late = run.start_by_ms + run.deadline_ms + run.grace_ms + 30_000;
            try check(c, c.manual.ms <= late, "J8: a run is still open long after its deadline");
            continue;
        }
        for (c.nodes) |node| {
            for (node.sim.containers.containers.items) |container| {
                if (container.phase == .stopped) continue;
                const live = job_of(container) orelse continue;
                try check(c, !std.mem.eql(u8, live, run.job), "J1: a container of an ended " ++
                    "job is still alive");
            }
        }
    }
    // J4: the watching client, back from any outage, has seen every ending the store committed.
    const head = ctx.store.status(ctx.diag) catch return check(c, false, "the head is unreadable");
    sim_jobs_watch.finish(&c.jobs_watch, &c.api, ctx, head.revision);
    try check(c, c.jobs_watch.violation == null, c.jobs_watch.violation orelse "");
}

/// Every fault off; the agents come back up as time passes. Ends the fault phase.
fn heal(c: *Cluster) void {
    c.fault_totals = c.phase_totals();
    c.set_store_down(false);
    c.ack_loss.loss_per_mille = 0;
    c.swarm.net = .{};
    c.net.heal();
    for (c.nodes) |node| {
        node.partitioned_until_ms = null;
        node.frozen_until_ms = null;
        node.fences_at_heal = node.fences;
        node.job_refusals_at_heal = node.job_refusals;
    }
}

/// Null if `node` has no container of `name` that is not stopped; else whether it is `running`
/// (and not `stopping`), and its image.
const Live = struct { running: bool, image: []const u8 };

fn find_live(node: *const Node, name: []const u8) ?Live {
    for (node.sim.containers.containers.items) |container| {
        if (container.phase == .stopped) continue;
        if (!std.mem.eql(u8, container.name, name)) continue;
        return .{ .running = container.phase == .running, .image = container.image };
    }
    return null;
}

fn live_container(node: *const Node, name: []const u8) ?bool {
    const live = find_live(node, name) orelse return null;
    return live.running;
}

/// Replica by replica: it exists as the service says, its container runs on the node the replica
/// names (a good image) or nowhere (a broken one), no other node has one, and the server's view
/// agrees; then every container still alive on any node belongs to a replica.
fn converged(c: *Cluster) Failure!void {
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    c.diag.reset();
    const ctx: controller.Context = .{
        .store = c.store_handle(),
        .clock = c.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &c.diag,
    };
    const services = controller.list_all(
        records.Service,
        &ctx,
        records.prefix_services,
        null,
        constants.services_max,
    ) catch return check(c, false, "the services cannot be read");
    const observed = controller.list_all(
        records.Observed,
        &ctx,
        records.prefix_observed,
        null,
        constants.replicas_max,
    ) catch return check(c, false, "the observed records cannot be read");
    const homes = try read_homes(c, &ctx);
    for (services.items) |service| {
        const prefix = records.replicas_prefix(service.rec.name);
        const replicas = controller.list_all(
            records.Replica,
            &ctx,
            prefix.slice(),
            null,
            constants.replicas_max,
        ) catch return check(c, false, "the replicas cannot be read");
        try check(c, replicas.items.len == service.rec.replicas, "a service lacks replicas");
        const good = !std.mem.eql(u8, service.rec.image, broken_digest);
        for (replicas.items) |replica| {
            try replica_converged(c, observed.items, &homes, &replica.rec, good);
        }
    }
    try no_strays(c, &ctx, &homes);
    if (c.jobs_on) try jobs_converged(c, &ctx);
    if (c.jobs_on) try start_records_retired(c, &ctx);
    if (c.tenants and c.c1) try tenancy_at_rest(c, &ctx);
}

/// P1 at rest (B6): no node holds an assignment its registered labels refuse.
fn tenancy_at_rest(c: *Cluster, ctx: *const controller.Context) Failure!void {
    try check(c, c.tenancy.violation == null, c.tenancy.violation orelse "");
    const names = c.node_names();
    const now = c.manual.ms;
    const found = sim_tenancy.scan(&c.tenancy, ctx, names.slice(), now, now, true);
    try check(c, found == null, found orelse "");
}

/// Every container alive on any node is the container of a replica placed on that node.
fn no_strays(c: *Cluster, ctx: *const controller.Context, homes: *const Homes) Failure!void {
    const replicas = controller.list_all(
        records.Replica,
        ctx,
        records.prefix_replicas,
        null,
        constants.replicas_max,
    ) catch return check(c, false, "the replicas cannot be read");
    for (c.nodes) |node| {
        for (node.sim.containers.containers.items) |container| {
            if (container.phase == .stopped or job_of(container) != null) continue;
            const mine = assigned_to(replicas.items, homes, node.name(), container.name);
            try check(c, mine, "a container is left behind");
        }
    }
}

fn replica_converged(
    c: *Cluster,
    observed: []const controller.Entry(records.Observed),
    homes: *const Homes,
    replica: *const records.Replica,
    good: bool,
) Failure!void {
    const home = homes.get(replica.id) orelse return check(c, false, "a replica is not placed");
    var copies: u32 = 0;
    for (c.nodes) |node| {
        const running = live_container(node, replica.id) orelse continue;
        copies += 1;
        try check(c, std.mem.eql(u8, node.name(), home), "a replica runs on a node " ++
            "other than its own");
        try check(c, good, "a replica of a broken service is running");
        try check(c, running, "a replica is still stopping");
        const live = find_live(node, replica.id).?; // live_container found it.
        try check(c, std.mem.eql(u8, live.image, replica.image), "a replica runs " ++
            "another image than its own");
    }
    try check(c, copies == @intFromBool(good), "a replica is not running exactly once");
    var seen = false;
    for (observed) |item| {
        if (!std.mem.eql(u8, item.rec.replica, replica.id)) continue;
        seen = true;
        const running = item.rec.status == .running;
        try check(c, item.rec.generation == replica.generation, "the server's view of a " ++
            "replica is of another generation");
        try check(c, running == good, "the server's view of a replica disagrees with its node");
        if (good) try check(c, std.mem.eql(u8, item.rec.node, home), "observed on " ++
            "another node");
    }
    if (good) try check(c, seen, "a running replica was never reported");
}

/// A hash of everything the store holds, then of every node's containers and restarts.
fn world_hash(c: *Cluster) u64 {
    var scratch = std.heap.ArenaAllocator.init(c.gpa);
    defer scratch.deinit();
    c.diag.reset();
    var hasher = std.hash.Wyhash.init(0);
    var after: ?[]const u8 = null;
    var at: ?store.Revision = null;
    for (0..1024) |_| {
        const page = c.store_handle().list(scratch.allocator(), .{
            .prefix = "",
            .at_revision = at,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, &c.diag) catch {
            c.diag.reset();
            break;
        };
        at = page.revision;
        for (page.kvs) |kv| {
            hasher.update(kv.key);
            hasher.update(kv.value);
            hasher.update(std.mem.asBytes(&kv.mod_revision));
            hasher.update(std.mem.asBytes(&kv.lease));
        }
        after = page.continue_after;
        if (after == null) break;
    }
    for (c.nodes) |node| hash_node(&hasher, node);
    hash_net(&hasher, &c.net);
    hash_value(&hasher, .{ c.manual.ms, c.switched.down, c.excess_count, c.starved_count });
    return hasher.final();
}

fn hash_node(hasher: *std.hash.Wyhash, node: *Node) void {
    hasher.update(node.name());
    hasher.update(std.mem.asBytes(&node.sim.restarts));
    hash_value(hasher, .{ node.down, node.restart_at_ms, node.resume_ms, node.spent_ms });
    hash_value(hasher, .{ node.partitioned_until_ms, node.crashes, node.sim.crashed });
    const loop = &node.loop;
    hash_value(hasher, .{ loop.state, loop.retry_ms, loop.wake_at_ms, loop.last_code });
    hash_value(hasher, .{ loop.last_report_ms, loop.stop_requested });
    for (node.sim.containers.containers.items) |container| {
        hasher.update(container.name);
        hasher.update(container.image);
        hash_value(hasher, .{ container.phase, container.pid, container.started_at_ms });
        hash_value(hasher, container.ignores_stop);
    }
    // The agent's files: names and bytes, and how much of each a host crash would keep.
    for (node.sim.files.files.items) |file| {
        hasher.update(file.name);
        hasher.update(file.data);
        hash_value(hasher, file.synced_len);
    }
    hash_value(hasher, .{ node.sim.files.points, node.sim.files.crashed });
}

fn hash_value(hasher: *std.hash.Wyhash, value: anytype) void {
    std.hash.autoHash(hasher, value);
}

/// The requests in flight on every link, and the link's faults and counters.
fn hash_net(hasher: *std.hash.Wyhash, net: *const sim_net.SimNet) void {
    for (&net.links) |*link| {
        hash_value(hasher, .{
            link.faults.request.drop_per_mille, link.faults.reply.drop_per_mille,
            link.faults.partition_up,           link.faults.partition_down,
            link.stats.delivered,               link.stats.requests_dropped,
            link.stats.replies_lost,            link.stats.duplicated,
            link.stats.parked,                  link.stats.delivered_late,
            link.stats.partitioned,
        });
        for (link.parked) |slot| {
            const parked = slot orelse continue;
            hasher.update(parked.method);
            hasher.update(parked.target);
            hasher.update(parked.body);
            hash_value(hasher, .{ parked.hold_ms, parked.due_ms, parked.sequence });
        }
    }
}

// ---- A run --------------------------------------------------------------------------------------

pub const Options = struct {
    /// Null: the seed picks the node count.
    nodes: ?u32 = null,
    /// See `Cluster.liveness`.
    liveness: bool = true,
    /// Liveness mode: the operation before which the faults end, instead of the seed's choice
    /// (`heal_operation`). A shrunk replay needs it: the seed's choice is drawn from the number of
    /// operations, so a shorter run would heal elsewhere and be a different run.
    heal_at: ?u32 = null,
    /// Called with each step ("faults", "healed", "convergence", "end") as the run enters it,
    /// so a runner can say where a run that panics was (`sim_cluster --trace-steps`). It must
    /// not touch the run.
    on_step: ?*const fn (step: []const u8) void = null,
    /// sim-c1 (docs/core.md): the per-revision checks, the overlap bound, the extra faults.
    c1: bool = false,
    /// Which fault classes are on (`sim_shape.zig`). `mixed` is the seed's own mix, as every
    /// build before profiles drew it.
    profile: sim_shape.ClusterProfile = .mixed,
    /// True: `plan` draws the profile from the seed (and clears this). `simulate` refuses it.
    profile_auto: bool = false,
    /// The ttl of the leases the server grants. Null: the shipped one.
    lease_ttl_ms: ?u32 = null,
    /// The workload's replica counts as a percentage of the base ones. Null: 100.
    replicas_pct: ?u32 = null,
    /// The job workload (docs/briefs/b1.md): jobs are submitted and cancelled, their containers
    /// end, and J1 to J3 and J5 to J8 are checked (J3 and J5 under `c1`).
    jobs: bool = true,
    /// The stronger world of B2 slice 4: every other host crash also loses the node's disk (state
    /// directory and containers) and every thirteenth job cannot be placed. Off, a run is the
    /// world it was before those faults existed, bit for bit (a replay line of an older failure
    /// has no `--strong`). `plan` turns it on for drawn operations (`auto`).
    strong: bool = false,
    /// B6 slice 2: nodes carry seeded tenant labels (some exclusive), jobs a seeded `require`, and
    /// P1 is judged. Apart from `strong` so that the worlds of the older teeth (`job_evicted`'s
    /// sparse seed) are unchanged; `plan` turns it on for drawn operations (`auto`).
    tenants: bool = false,
};

/// What a command line asked for, resolved: the operations and the options every unset knob of
/// which the seed drew (`sim_shape.draw_shape`, `draw_cluster_profile`). A pure function of the
/// seed and the request, so a seed alone replays a run, and what it returns is concrete, so its
/// replay line needs no draw.
pub const Plan = struct {
    operations: u32,
    options: Options,
};

/// `operations` null draws the whole shape from the seed (operations, nodes, lease ttl, replica
/// counts); each knob the request set is kept. `options.profile_auto` draws the profile.
pub fn plan(seed: u64, operations: ?u32, requested: Options) Plan {
    var options = requested;
    if (c1_teeth.burst_world) options.nodes = 1; // One node takes every burst.
    var shape = sim_shape.fixed_shape(1);
    // The cost cap sees the node count the request gave, if any.
    if (operations == null) shape = sim_shape.draw_shape_nodes(seed, requested.nodes);
    if (options.profile_auto) {
        options.profile = sim_shape.draw_cluster_profile(seed);
        options.profile_auto = false;
    }
    if (operations == null) {
        options.strong = true;
        options.tenants = true;
        if (options.nodes == null) options.nodes = shape.nodes;
        if (options.lease_ttl_ms == null) options.lease_ttl_ms = shape.lease_ttl_ms;
        if (options.replicas_pct == null) options.replicas_pct = shape.replicas_pct;
    }
    return .{ .operations = operations orelse shape.operations, .options = options };
}

/// The operation before which the faults end in a liveness run of `operations` operations from
/// `seed`, as the run prints it; what `Options.heal_at` overrides.
pub fn heal_point(seed: u64, operations: u32) u32 {
    return heal_operation(seed, operations);
}

/// The operation before which the faults end (liveness mode): the second half of the run, or
/// part of it, is fault-free workload. Drawn from the seed alone.
fn heal_operation(seed: u64, operations: u32) u32 {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x4ea1);
    return operations / 2 + prng.random().uintLessThan(u32, operations - operations / 2 + 1);
}

/// Runs `operations` operations drawn from `seed` in the world the seed chose. In liveness mode
/// (the default) every fault ends at a time the seed chose, the world gets `liveness_bound_ms`
/// to settle, and it must have converged; without it the faults stay on and only the safety
/// checks run. The report ends with the hash. The verdict is `report.failed`.
pub fn simulate(
    gpa: Allocator,
    seed: u64,
    operations: u32,
    options: Options,
    report: *Report,
) void {
    report.* = .{};
    const c = Cluster.create(gpa, seed, options, report) catch {
        report.failed = true;
        report.print("FAILED: out of memory\n", .{});
        // The run never started: the host's trouble, which the fleet counts and never files.
        report.print("step: setup\n", .{});
        return;
    };
    defer c.destroy();
    defer report.dead_calls = c.stats.dead_calls;
    c.on_step = options.on_step;
    c.enter("faults");
    report.print("sim-cluster seed={d} operations={d}\n", .{ seed, operations });
    c.swarm.print(report);
    report.print("profile: {s}\nshape: operations={d} nodes={d} lease_ttl_ms={d} " ++
        "replicas_pct={d}\n", .{
        c.swarm.profile.name(), operations,
        c.swarm.nodes,          options.lease_ttl_ms orelse constants.lease_ttl_ms,
        c.swarm.replicas_pct,
    });
    c.liveness = options.liveness;
    c.c1 = options.c1;
    c.jobs_on = options.jobs;
    if (c.jobs_on) {
        c.swarm.add_jobs(seed);
        report.print("jobs: on; weights create={d} cancel={d} end={d}\n", .{
            c.swarm.w_job_create, c.swarm.w_job_cancel, c.swarm.w_job_end,
        });
    }
    if (c.c1) {
        c.swarm.add_c1_faults(seed);
        report.print("sim-c1: every revision checked (I1a I2 I3 I4 I6 I7), overlaps bounded " ++
            "(I1b), then every decision re-explained after its cited keys changed (I5, §5)\n", .{});
    }
    const heal_at = if (!options.liveness)
        operations
    else
        options.heal_at orelse heal_operation(seed, operations);
    if (options.liveness) {
        report.print("liveness: on; faults for the first {d} of {d} operations, then none; " ++
            "converged {d} ms after the last operation\n", .{
            heal_at, operations, liveness_bound_ms,
        });
    } else {
        report.print("liveness: off; faults stay on, safety checks only, no convergence " ++
            "check\n", .{});
    }
    run_steps(c, operations, heal_at) catch {
        assert(report.failed);
        if (c.fault_totals != null) print_phases(c);
        return;
    };
    print_summary(c);
}

fn run_steps(c: *Cluster, operations: u32, heal_at: u32) Failure!void {
    for (0..operations) |index| {
        if (c.liveness and index == heal_at) {
            heal(c);
            c.enter("healed");
        }
        operation(c);
        if (c.report.failed) return error.StepFailed;
        try safety(c);
    }
    if (c.liveness) {
        if (c.fault_totals == null) heal(c);
        c.advance(liveness_bound_ms);
        if (c.report.failed) return error.StepFailed;
        c.enter("convergence");
        try converged(c);
        try fencing_settles(c);
        if (c.jobs_on) try reports_settle(c);
    } else {
        c.fault_totals = c.phase_totals();
    }
    c.enter("end");
    try safety(c);
    try enough_work_under_faults(c, @min(heal_at, operations));
    try work_under_ceiling(c);
    try acceptance(c);
}

/// sim-c1, docs/authority.md §5: every cited key is changed or deleted and the history compacted
/// past them, and `why` must still explain every decision with the evidence it recorded.
fn acceptance(c: *Cluster) Failure!void {
    if (!c.c1) return;
    _ = c.tap_arena.reset(.retain_capacity);
    c.tap_diag.reset();
    const ctx: controller.Context = .{
        .store = c.tap.inner,
        .clock = c.manual.clock(),
        .arena = c.tap_arena.allocator(),
        .diag = &c.tap_diag,
    };
    c.recorder.disturb(&ctx) catch {
        try check(c, false, "§5: the cited keys could not be changed and compacted");
    };
    const found = c.recorder.verify(&ctx);
    try check(c, found == null, found orelse "");
}

/// The highest rate of agent steps (per minute of agent uptime, over the whole run) among the
/// nodes that were up for at least a minute; 0 if there is none.
fn busiest_node_rate(c: *const Cluster) u64 {
    var busiest: u64 = 0;
    for (c.nodes) |node| {
        if (node.all_up_ms < 60_000) continue;
        busiest = @max(busiest, @as(u64, node.all_steps) * 60_000 / node.all_up_ms);
    }
    return busiest;
}

fn total_fences(c: *const Cluster) u32 {
    var fences: u32 = 0;
    for (c.nodes) |node| fences += node.fences;
    return fences;
}

/// A healed cluster stops fencing (issue #78): once the faults have ended, a node may still
/// fence for a lease it lost, and again for one that ran out while its renewal waited out a
/// back-off, but not once a second for the rest of the run. Each node gets
/// `fences_after_heal_per_node_max`.
fn fencing_settles(c: *Cluster) Failure!void {
    var worst: u32 = 0;
    for (c.nodes) |node| worst = @max(worst, node.fences - node.fences_at_heal);
    try check(c, worst <= fences_after_heal_per_node_max, "agents kept fencing after the " ++
        "cluster healed (a lease renewal that cannot beat its fence)");
}

fn job_refusals(c: *const Cluster) u64 {
    var total: u64 = 0;
    for (c.nodes) |node| total += node.job_refusals;
    return total;
}

/// J10, after the heal: an agent does not keep making job reports the store refuses. A report of
/// a run that is gone (released, or placed again elsewhere) is never made; one that was made is
/// not made again on every pass, so its refusal is no busy loop of store writes.
fn reports_settle(c: *Cluster) Failure!void {
    var worst: u64 = 0;
    for (c.nodes) |node| worst = @max(worst, node.job_refusals - node.job_refusals_at_heal);
    try check(c, worst <= job_refusals_after_heal_per_node_max, "J10: an agent kept making " ++
        "job reports the store refused after the cluster healed");
}

/// An agent that never sleeps (a wake time that is always now) passes every other check and
/// burns a core: no node may take more than `steps_per_minute_max` steps per minute it was up.
fn work_under_ceiling(c: *Cluster) Failure!void {
    try check(c, busiest_node_rate(c) <= steps_per_minute_max, "an agent took too many " ++
        "steps for the time it was up (a busy loop)");
}

/// The slowest rate of successful agent steps (per minute of agent uptime) among the nodes that
/// were up for at least half of the fault phase; null if there is none. Reported, not checked:
/// one node's luck with 10 s timeouts says little about the cluster (`cluster_ok_rate`).
fn slowest_node_rate(c: *const Cluster) ?u64 {
    var slowest: ?u64 = null;
    for (c.nodes) |node| {
        if (node.up_ms * 2 < c.fault_ms or node.up_ms == 0) continue;
        const rate = @as(u64, node.ok_steps) * 60_000 / node.up_ms;
        slowest = if (slowest) |s| @min(s, rate) else rate;
    }
    return slowest;
}

/// Successful agent steps per minute of agent uptime, over every node together, while the faults
/// were on; null if the nodes were up for less than `cluster_up_ms_min` in all, too little for
/// a rate to mean anything (a lost call costs 10 s, so a short run is a few calls' luck).
fn cluster_ok_rate(c: *const Cluster) ?u64 {
    const up_ms = cluster_up_ms(c);
    if (up_ms < cluster_up_ms_min) return null;
    var steps: u64 = 0;
    for (c.nodes) |node| steps += node.ok_steps;
    return steps * 60_000 / up_ms;
}

/// Agent uptime summed over every node, while the faults were on.
fn cluster_up_ms(c: *const Cluster) u64 {
    var up_ms: u64 = 0;
    for (c.nodes) |node| up_ms += node.up_ms;
    return up_ms;
}

/// Whether `delivered` requests reaching the server while the faults were on meet the floor for
/// a run of `operations` operations and `up_ms` of summed agent uptime. With at least
/// `cluster_up_ms_min` of uptime the floor is one request per operation (the least seen over
/// seeds 1 to 60 was 268 in 100 operations; the old fault rates left 39). Below it the run is
/// too short for that: operations are not time, the draw can hold few `advance` operations, and
/// one lost call costs the agent 10 s, so a run of 30 to 50 virtual seconds delivers fewer
/// requests than it has operations by luck alone (seeds 3491114665 and 1995814075: 72 of 73 and
/// 37 of 38). There the floor is half a request per operation (the lowest ratio seen over seeds
/// 1 to 200 among such runs was 2.22), which still fails a world that is down most of the time.
fn request_floor_met(delivered: u64, operations: u32, up_ms: u64) bool {
    if (up_ms >= cluster_up_ms_min) return delivered >= operations;
    return delivered * 2 >= operations;
}

/// The faults must leave the cluster working: a world where the store or every link is down most
/// of the time proves little, and a change that made it so would pass silently otherwise. The
/// nodes together got `ok_steps_per_minute_min` successful agent steps per minute they were up
/// (the least seen is in docs/DECISIONS.md, judged only on enough uptime), and the requests that
/// reached the server meet `request_floor_met`.
fn enough_work_under_faults(c: *Cluster, operations: u32) Failure!void {
    const during = c.fault_totals.?;
    if (cluster_ok_rate(c)) |rate| {
        try check(c, rate >= ok_steps_per_minute_min, "too few agent steps while faults were " ++
            "on");
    }
    const met = request_floor_met(during.delivered, operations, cluster_up_ms(c));
    try check(c, met, "too few requests reached the server while faults were on");
}

fn print_summary(c: *Cluster) void {
    const report = c.report;
    const s = c.stats;
    report.print("cluster: every invariant held; revision={d} transactions={d}\n", .{
        c.revision().?, s.transactions,
    });
    report.print("steps: server={d} agent={d} failures: server={d} agent={d}\n", .{
        s.server_steps, s.agent_steps, s.server_failures, s.agent_failures,
    });
    print_phases(c);
    report.print("starved: worst={d}ms; ok steps per up-minute: cluster {d}, slowest node {d}\n", .{
        c.starved_worst_ms, cluster_ok_rate(c) orelse 0, slowest_node_rate(c) orelse 0,
    });
    report.print("busiest node: {d} steps per up-minute\n", .{busiest_node_rate(c)});
    report.print("faults: crashes={d} partitions={d} outages={d} suspends={d} " ++
        "runtime={d} server_restarts={d} ack_lost={d} wipes={d}\n", .{
        s.crashes_injected, s.partitions,      s.outages,             s.suspends,
        s.runtime_faults,   s.server_restarts, c.ack_loss.lost_count, s.wipes,
    });
    report.print("lost nodes: mark_lost={d} replicas replaced after the grace={d}\n", .{
        s.nodes_marked_lost, s.replicas_marked_lost,
    });
    var total: sim_net.Stats = .{};
    for (c.nodes) |node| {
        const link = c.net.stats(node.index);
        total.delivered += link.delivered;
        total.requests_dropped += link.requests_dropped;
        total.replies_lost += link.replies_lost;
        total.duplicated += link.duplicated;
        total.parked += link.parked;
        total.delivered_late += link.delivered_late;
        total.partitioned += link.partitioned;
    }
    report.print("net: delivered={d} requests_dropped={d} replies_lost={d} duplicated={d} " ++
        "parked={d} delivered_late={d} partitioned={d}\n", .{
        total.delivered, total.requests_dropped, total.replies_lost, total.duplicated,
        total.parked,    total.delivered_late,   total.partitioned,
    });
    const fences = total_fences(c);
    report.print("fences: {d} (agents that stopped their containers for a lease)\n", .{fences});
    report.print("duplicates: {d} replica-seconds on two nodes (a failure under sim-c1, " ++
        "counted otherwise)\n", .{
        s.duplicate_seconds,
    });
    if (c.c1) {
        report.print("sim-c1: revisions checked={d} overlap worst " ++
            "{d} ms (bound {d} ms), wedged worst {d} ms (excused)\n", .{
            c.c1_revisions, c.overlap_worst_ms, overlap_ms_max, c.overlap_wedged_worst_ms,
        });
        report.print("sim-c1 overlaps not watched (table full): {d}\n", .{c.overlaps_unwatched});
        report.print("sim-c1 I2/I3: guarded writes={d} observations judged={d} unjudged={d} " ++
            "other facts cited={d}\n", .{
            c.c1_tally.guarded_writes,
            c.c1_tally.observations_judged,
            c.c1_tally.observations_unjudged,
            c.c1_tally.facts_other,
        });
        report.print("sim-c1 L1: placements judged={d}\n", .{c.c1_tally.placements_judged});
        const n = c.recorder.counts;
        report.print("sim-c1 acceptance: decisions={d} complete={d} truncated={d} dropped={d} " ++
            "keys deleted={d} changed={d}\n", .{
            n.recorded, n.complete, n.truncated, n.dropped, n.keys_deleted, n.keys_changed,
        });
    }
    if (c.jobs_on) print_jobs(c);
    report.print("world hash: {x:0>16}\n", .{world_hash(c)});
}

fn print_jobs(c: *Cluster) void {
    const j = &c.jobs;
    c.report.print("jobs: created={d} cancelled={d} ended={d}; starts judged={d} ledger={d} " ++
        "unjudged={d}\n", .{
        j.created, j.cancelled, j.ended, j.starts_judged, j.ledger_count, j.ledger_full,
    });
    c.report.print("jobs: worst stop {d} ms, overlap {d} ms, past deadline {d} ms; " ++
        "status rewrites judged={d} placements judged={d} reports judged={d} " ++
        "refused={d}\n", .{
        j.stop_worst_ms,               j.overlap_worst_ms,
        j.deadline_worst_ms,           c.c1_tally.job_statuses_judged,
        c.c1_tally.runs_placed_judged, c.c1_tally.job_reports_judged,
        job_refusals(c),
    });
    const w = &c.jobs_watch;
    c.report.print("jobs: watch endings={d} handled={d} watches={d} relists={d} restarts={d}\n", .{
        w.truth_count, w.handled_count, w.watches, w.relists, w.restarts,
    });
    if (c1_teeth.reuse_world) {
        c.report.print("jobs: reuse jumps={d} dropped={d} reused creates={d} met a " ++
            "container={d}\n", .{
            c.reuse_jumps, c.reuse_cursor.dropped, c.reuse_made, c.reuse_met,
        });
    }
    if (c.tenants) {
        c.report.print("jobs: tenants relabels={d} (operator restarts {d}) P1 placements " ++
            "judged={d} refused holds={d} acted worst={d} ms\n", .{
            c.relabels,                  c.stats.relabel_restarts,
            c.tenancy.placements_judged, c.tenancy.refused_seen,
            c.tenancy.acted_worst_ms,
        });
    }
    if (c.strong) {
        var opened: u32 = 0;
        var closed: u32 = 0;
        var open_now: u32 = 0;
        var by: [4]u32 = .{ 0, 0, 0, 0 };
        for (c.nodes) |node| {
            for (&by, node.sim.containers.relays_closed_by) |*sum, n| sum.* += n;
            opened += node.sim.containers.relays_opened;
            closed += node.sim.containers.relays_closed;
            open_now += node.sim.containers.relay_open_count();
        }
        c.report.print("jobs: relays opened={d} closed={d} open at the end={d} " ++
            "(closed by exit={d} signal={d} other={d} wipe={d})\n", .{
            opened, closed, open_now, by[0], by[1], by[2], by[3],
        });
    }
}

fn print_phases(c: *Cluster) void {
    const end = c.phase_totals();
    const during = c.fault_totals.?;
    print_phase(c.report, "fault phase", during);
    if (c.liveness) print_phase(c.report, "heal phase", end.minus(during));
}

fn print_phase(report: *Report, label: []const u8, p: PhaseTotals) void {
    report.print("{s}: agent_steps={d} agent_failures={d} server_steps={d} writes={d} " ++
        "delivered={d} requests_dropped={d} replies_lost={d} partitioned={d} revisions={d}\n", .{
        label,          p.agent_steps, p.agent_failures,   p.server_steps,
        p.transactions, p.delivered,   p.requests_dropped, p.replies_lost,
        p.partitioned,  p.revision,
    });
}

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

test "the request floor is one per operation with enough uptime and half below it" {
    // Goal: the weaker floor for short runs has teeth. Method: the two fleet runs pass it, a run
    // delivering under half of its operations fails it, and the full floor applies from
    // `cluster_up_ms_min` of uptime.
    const short = cluster_up_ms_min - 1;
    try std.testing.expect(request_floor_met(72, 73, short));
    try std.testing.expect(request_floor_met(37, 38, short));
    try std.testing.expect(request_floor_met(20, 40, short));
    try std.testing.expect(!request_floor_met(19, 40, short));
    try std.testing.expect(!request_floor_met(0, 40, 0));
    try std.testing.expect(request_floor_met(40, 40, cluster_up_ms_min));
    try std.testing.expect(!request_floor_met(39, 40, cluster_up_ms_min));
}

test "the same seed gives the same report and the same hash" {
    // Goal: determinism, which replay and native-versus-WASM comparison rest on. Method: run two
    // seeds twice each and compare the bytes, the hash line included.
    var first: Report = undefined;
    var second: Report = undefined;
    for ([_]u64{ 3, 9 }) |seed| {
        simulate(testing.allocator, seed, 30, .{}, &first);
        simulate(testing.allocator, seed, 30, .{}, &second);
        try testing.expectEqualStrings(first.text(), second.text());
        try testing.expect(std.mem.indexOf(u8, first.text(), "world hash: ") != null);
    }
}

test "a few seeds hold every invariant, and the swarm differs between them" {
    // Goal: the world is testable: it runs and its checks pass. Method: run seeds with the
    // testing allocator (nothing leaks) and compare the swarm lines.
    var report: Report = undefined;
    var swarm_lines: [4][80]u8 = undefined;
    for (0..4) |index| {
        simulate(testing.allocator, 100 + index, 40, .{}, &report);
        if (report.failed) std.debug.print("{s}\n", .{report.text()});
        try testing.expect(!report.failed);
        const line = report.text();
        const start = std.mem.indexOf(u8, line, "swarm:").?;
        @memcpy(&swarm_lines[index], line[start..][0..80]);
    }
    try testing.expect(!std.mem.eql(u8, &swarm_lines[0], &swarm_lines[1]));
}

test "J8 holds on a small world whose agents' steps fail, without c1" {
    // Goal: regression for the J8 release blocker. A plain run (no `c1`) once judged J8 without
    // the wedge allowance, because `note_wedged` ran only under `c1`, so a run
    // whose agent was backed off by failed steps looked like one that outlived its deadline.
    // Method: seed 136502595 at 40 operations failed J8 before the fix; it is small enough to run
    // on every target. The large drawn worlds that also failed (`sim_cluster <seed> auto
    // --profile=auto` for seeds 130, 4026630699808099468, 8059167289430031834 and 148) ran 30
    // minutes under WASI in this test, 62 s natively for seed 148 alone, and no native test
    // target runs this file's tests, so they are not repeated here; the fleet draws such worlds.
    var report: Report = undefined;
    simulate(testing.allocator, 136502595, 40, .{}, &report);
    if (report.failed) std.debug.print("{s}\n", .{report.text()});
    try testing.expect(!report.failed);
}

test "a start after the agent's crash is refused, not asserted (#158)" {
    // Goal: regression for #152, #156 and #158 (`SimNode.start_impl` asserted the node had not
    // crashed). Method: seed 57 at 100 operations under c1 aborted before the fix.
    var report: Report = undefined;
    simulate(testing.allocator, 57, 100, .{ .c1 = true }, &report);
    if (report.failed) std.debug.print("{s}\n", .{report.text()});
    try testing.expect(!report.failed);
}

test "a crashed node's step makes no call to the server (#167)" {
    // Goal: after a crash that deadline enforcement swallows, the step's heartbeat, publish and
    // load must not reach the server (`tapped_call` refuses; it asserts nothing got through).
    // Method: a run that crashes an agent mid-step; it counts the calls the gate refused and the
    // test fails if there were none, so a change of the draws cannot leave it passing without
    // reaching the gate. Seed 57 at 100 operations under c1 did when this was written.
    var report: Report = undefined;
    simulate(testing.allocator, 57, 100, .{ .c1 = true }, &report);
    if (report.failed) std.debug.print("{s}\n", .{report.text()});
    try testing.expect(!report.failed);
    try testing.expect(report.dead_calls > 0);
}

test "a node count can be asked for" {
    // Goal: -Dnodes. Method: ask for 3 and read the swarm line.
    var report: Report = undefined;
    simulate(testing.allocator, 5, 10, .{ .nodes = 3 }, &report);
    try testing.expect(!report.failed);
    try testing.expect(std.mem.indexOf(u8, report.text(), "swarm: nodes=3 ") != null);
}

test "the fencing check fires on a node that runs containers long after it lost its lease" {
    // Goal: track_fencing has teeth. Method: run replicas, delete the node's registration, then
    // move the clock past the bound without letting any node step: the containers still run.
    var report: Report = .{};
    const c = try Cluster.create(testing.allocator, 7, .{ .nodes = 1 }, &report);
    defer c.destroy();
    c.apply("hello", hello_digest, 2);
    c.advance(5_000);
    try testing.expect(!report.failed);
    const node = c.nodes[0];
    var running: u32 = 0;
    for (node.sim.containers.containers.items) |container| {
        if (container.phase != .stopped) running += 1;
    }
    try testing.expectEqual(@as(u32, 2), running);
    const key = records.node_key(node.name());
    c.diag.reset();
    const delete: store.Op = .{ .delete = key.slice() };
    // Straight to the memory store: the cluster's own handle may lose the acknowledgement.
    _ = try c.memory.interface().txn(.{ .on_success = &.{delete} }, &c.diag);
    try track_fencing(c);
    c.manual.advance(fencing_ms_max);
    try track_fencing(c);
    c.manual.advance(1);
    try testing.expectError(error.StepFailed, track_fencing(c));
    try testing.expect(report.failed);
}

test "a step's calls are capped by the time it has spent, once (issue 136)" {
    // Goal: the fence cap on a step's calls counts the step's spent time exactly once. The
    // cluster's clock stands still during a step (#136: every call had the whole window), so
    // the node's clock runs by the calls' time (`spend_until`) and the remote compares the
    // deadline with it; the deadline is handed on as it is. Method: spend 4 s as `tapped_call`
    // does, set a deadline 5 s ahead as the agent does; the call has about 1 s left, not 0
    // (which a second subtraction of the 4 s would give), and a missing deadline stays missing.
    var report: Report = .{};
    const c = try Cluster.create(testing.allocator, 7, .{ .nodes = 1 }, &report);
    defer c.destroy();
    const node = c.nodes[0];
    const clock = node.nclock.clock();
    node.remote.set_deadline(clock, std.math.maxInt(u64));
    const start = clock.now_ms();
    node.spent_ms = 4000;
    node.nclock.spend_until(c.manual.ms + node.spent_ms);
    Node.deadline_set_fn(node, start + 5000);
    try testing.expectEqual(start + 5000, node.remote.deadline_ms);
    const left = node.remote.deadline_ms -| clock.now_ms();
    try testing.expect(left > 900); // The node's clock has a rate error of its own.
    try testing.expect(left <= 1000);
    Node.deadline_set_fn(node, std.math.maxInt(u64));
    try testing.expectEqual(std.math.maxInt(u64), node.remote.deadline_ms);
}

test "a crashed node restarts only once its clock has caught up with true time (seeds 1612, 893)" {
    // Goal: the restarted agent never reads a clock ahead of true time. A step runs whole at its
    // start and its clock reading and saved pair already include its spent time; a restart
    // inside that time stamped a lease ahead of true time and fenced late (I1b, seed 1612).
    // Method: charge a node 5 s of calls, crash it, and read when it is to restart.
    var report: Report = .{};
    const c = try Cluster.create(testing.allocator, 7, .{ .nodes = 1 }, &report);
    defer c.destroy();
    const node = c.nodes[0];
    node.nclock.spend_until(c.manual.ms + 5000);
    for (0..40) |_| {
        node.sim.crashed = true;
        node.check_crashed();
        try testing.expect(node.down);
        try testing.expect(node.restart_at_ms >= node.nclock.busy_until_true_ms + 200);
        node.sim.crashed = false;
        node.down = false;
    }
}
