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
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const replica_controller = @import("replica_controller.zig");
const sim_clock = @import("sim_clock.zig");
const sim_net = @import("sim_net.zig");
const sim_node = @import("sim_node.zig");
const sim_store = @import("sim_store.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");
const why_mod = @import("why.zig");
const repeat = @import("test_util.zig").repeat;
const ManualClock = @import("clock.zig").ManualClock;
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
/// Half the slowest node seen over seeds 1 to 300 (10 per up-minute).
const ok_steps_per_minute_min: u64 = 5;
/// No node's agent may take more steps than this per minute it was up, over the run. Set from
/// the busiest node over seeds 1 to 300 at 100 operations (docs/DECISIONS.md).
const steps_per_minute_max: u64 = 200;
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

const hello_digest = "b3:51aa9c03";
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

    pub fn draw(seed: u64, nodes_wanted: ?u32) Swarm {
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
const Node = struct {
    cluster: *Cluster,
    index: u32,
    name_buf: [8]u8,
    name_len: u8,
    sim: sim_node.SimNode,
    nclock: sim_clock.NodeClock,
    remote: agent_client.RemoteStore,
    agent: agent_mod.Agent,
    loop: agent_loop.Loop,
    diag: Diag,
    arena: std.heap.ArenaAllocator,
    /// The agent is dead until `restart_at_ms`.
    down: bool,
    restart_at_ms: u64,
    /// The agent does nothing before this true time (a call in progress, a back-off).
    resume_ms: u64,
    /// How long the calls of the step in progress took.
    spent_ms: u64,
    /// The link is cut until this true time.
    partitioned_until_ms: ?u64,
    crashes: u32,
    /// Successful agent steps and virtual time with the agent up, while the faults were on.
    ok_steps: u32,
    up_ms: u64,
    /// Whether the agent's last step worked: a step that fails says why nothing moved.
    last_ok: bool,
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
        };
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
        const net = &node.cluster.net;
        const result = net.transport(node.index).call(arena, request, diag);
        node.spent_ms += net.last_call_ms;
        return result;
    }

    fn restart(node: *Node) void {
        assert(node.down);
        node.sim.restart();
        node.agent.init(node.config());
        node.loop = agent_loop.Loop.init();
        const gpa = node.cluster.gpa;
        node.remote = agent_client.RemoteStore.init(gpa, node.transport(), node.name());
        node.down = false;
        node.resume_ms = 0;
    }

    /// Notes that a call found the agent dead.
    fn check_crashed(node: *Node) void {
        if (!node.sim.crashed) return;
        node.down = true;
        node.crashes += 1;
        const c = node.cluster;
        node.restart_at_ms = c.manual.ms + 200 + c.prng.random().uintLessThan(u32, 5000);
    }

    /// One reconcile step, reported to the loop policy. Returns the transactions it made.
    fn step_once(node: *Node) u32 {
        const c = node.cluster;
        _ = node.arena.reset(.retain_capacity);
        node.diag.reset();
        node.spent_ms = 0;
        const clock = node.nclock.clock();
        const ctx: agent_mod.Context = .{
            .store = node.remote.interface(),
            .runtime = node.sim.interface(),
            .clock = clock,
            .arena = node.arena.allocator(),
            .diag = &node.diag,
        };
        c.stats.agent_steps += 1;
        node.all_steps += 1;
        const result = node.agent.reconcile(&ctx);
        node.resume_ms = c.manual.ms + node.spent_ms;
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

    /// One slice of the wait: true if it ended (a replica changed, an event came, or it failed).
    fn watch_once(node: *Node) bool {
        node.diag.reset();
        node.spent_ms = 0;
        var ended = node.remote.watch_once(0, &node.diag) catch true;
        if (!ended) {
            _ = node.arena.reset(.retain_capacity);
            const events = node.sim.interface().events(node.arena.allocator(), 0, &node.diag);
            ended = if (events) |list| list.len > 0 else |_| true;
        }
        node.resume_ms = node.cluster.manual.ms + node.spent_ms;
        node.loop.watch_done(ended);
        return ended;
    }

    /// Does what the loop says until it must wait for time to pass. Returns transactions made.
    fn drive(node: *Node) u32 {
        const c = node.cluster;
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
                .pause_ms => |ms| node.resume_ms = c.manual.ms + ms,
                .watch_ms => if (!node.watch_once()) return acted,
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
    partitions: u32 = 0,
    outages: u32 = 0,
    suspends: u32 = 0,
    runtime_faults: u32 = 0,
    server_restarts: u32 = 0,
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

pub const Cluster = struct {
    gpa: Allocator,
    seed: u64,
    swarm: Swarm,
    manual: ManualClock,
    memory: *MemoryStore,
    ack_loss: sim_store.AckLossStore,
    switched: sim_world.SwitchedStore,
    net: sim_net.SimNet,
    api: api_mod.Api,
    api_source: controller.DecisionSource,
    server: replica_controller.ReplicaController,
    nodes: []*Node,
    prng: std.Random.DefaultPrng,
    diag: Diag,
    net_diag: Diag,
    arena_state: std.heap.ArenaAllocator,
    server_due_ms: u64,
    server_seen_revision: store.Revision,
    compact_due_ms: u64,
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
    /// The store revision and drop count the invariants last passed at.
    checked_revision: ?store.Revision,
    checked_dropped: u64,
    second_ms: u64,
    check_ms: u64,
    stats: Stats,
    /// The totals when the faults ended and the heal began.
    fault_totals: ?PhaseTotals,
    /// Liveness mode: the faults end mid-run and the end state must converge within
    /// `liveness_bound_ms`; else faults stay on and only the safety checks run.
    liveness: bool,
    report: *Report,

    pub fn create(
        gpa: Allocator,
        seed: u64,
        nodes_wanted: ?u32,
        report: *Report,
    ) Allocator.Error!*Cluster {
        const c = try gpa.create(Cluster);
        errdefer gpa.destroy(c);
        const memory = try gpa.create(MemoryStore);
        errdefer gpa.destroy(memory);
        c.gpa = gpa;
        c.seed = seed;
        c.swarm = Swarm.draw(seed, nodes_wanted);
        c.manual = .{ .ms = epoch_ms };
        memory.init(gpa, c.manual.clock());
        c.memory = memory;
        c.ack_loss = .init(memory.interface(), seed ^ 0xac4, c.swarm.ack_loss_per_mille);
        c.switched = .{ .inner = c.ack_loss.interface() };
        c.net.init(gpa, .{ .context = c, .handle_fn = handle }, seed ^ 0x4e7);
        c.api = .{ .version = "0.0.0", .backend = "memory", .started_at_ms = epoch_ms };
        c.api_source = .{ .instance = 0 };
        c.prng = .init(seed ^ 0xc15e_7e12);
        c.diag.reset();
        c.net_diag.reset();
        c.arena_state = .init(gpa);
        c.server_due_ms = 0;
        c.server_seen_revision = 0;
        c.compact_due_ms = epoch_ms + compact_interval_ms;
        c.instance_next = 1;
        c.request_next = 1;
        c.dropped_before_restart = 0;
        c.excess = undefined;
        c.excess_count = 0;
        c.excess_last_ms = epoch_ms;
        c.starved = undefined;
        c.starved_count = 0;
        c.starved_worst_ms = 0;
        c.fault_ms = 0;
        c.checked_revision = null;
        c.checked_dropped = 0;
        c.second_ms = 0;
        c.check_ms = 0;
        c.stats = .{};
        c.fault_totals = null;
        c.liveness = true;
        c.report = report;
        c.server = replica_controller.ReplicaController.init(c.take_instance());
        c.nodes = try gpa.alloc(*Node, c.swarm.nodes);
        for (c.nodes, 0..) |*slot, index| slot.* = try c.create_node(@intCast(index));
        return c;
    }

    fn create_node(c: *Cluster, index: u32) Allocator.Error!*Node {
        const node = try c.gpa.create(Node);
        const random = c.prng.random();
        const ppm_max: i32 = @intCast(c.swarm.clock_ppm);
        const ppm = if (ppm_max == 0) 0 else random.intRangeAtMost(i32, -ppm_max, ppm_max);
        node.cluster = c;
        node.index = index;
        // "node" and at most two digits fit the buffer, since `nodes_max` is 16.
        const name = std.fmt.bufPrint(&node.name_buf, "node{d}", .{index + 1}) catch unreachable;
        node.name_len = @intCast(name.len);
        node.nclock = sim_clock.NodeClock.init(
            c.manual.clock(),
            random.uintLessThan(u64, 1_000_000),
            ppm,
            @max(c.swarm.clock_ppm, 1),
        );
        node.sim.init(c.gpa, node.nclock.clock(), c.seed +% index, &fixtures);
        node.agent.init(node.config());
        node.loop = agent_loop.Loop.init();
        node.remote = agent_client.RemoteStore.init(c.gpa, node.transport(), node.name());
        node.diag.reset();
        node.arena = .init(c.gpa);
        node.down = false;
        node.restart_at_ms = 0;
        node.resume_ms = 0;
        node.spent_ms = 0;
        node.partitioned_until_ms = null;
        node.crashes = 0;
        node.ok_steps = 0;
        node.last_ok = true;
        node.up_ms = 0;
        node.all_steps = 0;
        node.all_up_ms = 0;
        c.net.set_faults(index, c.swarm.net);
        return node;
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
            c.second_ms += slice;
            if (c.second_ms >= 1000) {
                c.second_ms -= 1000;
                c.stats.duplicate_seconds += c.duplicates();
            }
            c.check_ms += slice;
            if (c.check_ms >= check_interval_ms) {
                c.check_ms = 0;
                safety(c) catch return; // The report says what failed.
            }
        }
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
        const fit: u32 = @intCast(c.nodes.len * 4);
        return random.uintLessThan(u32, @min(most, fit - 1) + 1);
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
        c.dropped_before_restart += c.server.retention.dropped;
        c.server = replica_controller.ReplicaController.init(c.take_instance());
        c.server_due_ms = 0;
        c.stats.server_restarts += 1;
    }

    fn set_store_down(c: *Cluster, down: bool) void {
        c.switched.down = down;
        c.switched.fail_after = null;
    }

    fn dropped_total(c: *const Cluster) u64 {
        return c.dropped_before_restart + c.server.retention.dropped;
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
        node.partitioned_until_ms =
            c.manual.ms + partition_ms_min + random.uintLessThan(u32, partition_ms_spread);
        c.stats.partitions += 1;
    }

    /// The agent of `node` dies: at a write point, at a step boundary or between steps.
    fn crash(c: *Cluster, node: *Node) void {
        if (node.down) return;
        const random = c.prng.random();
        const kind: @import("agent_state.zig").CrashKind =
            if (random.boolean()) .process else .host;
        c.stats.crashes_injected += 1;
        switch (random.uintLessThan(u32, 3)) {
            0 => node.sim.arm_crash(1 + random.uintLessThan(u32, 6), kind),
            1 => node.sim.arm_step(1 + random.uintLessThan(u32, 3), kind),
            else => {
                node.sim.crash_now(kind);
                node.check_crashed();
            },
        }
    }

    fn pick_node(c: *Cluster) *Node {
        // A `u32` draw: the stream is the same on every target, which `usize` would not give.
        const count: u32 = @intCast(c.nodes.len);
        return c.nodes[c.prng.random().uintLessThan(u32, count)];
    }
};

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
};

/// With `faults_on` false (after the heal) the fault operations get no weight.
fn pick_op(swarm: *const Swarm, random: std.Random, faults_on: bool) Op {
    const f: u32 = @intFromBool(faults_on);
    const weights = [_]u32{
        swarm.w_advance,    swarm.w_apply,         swarm.w_scale,
        swarm.w_delete,     swarm.w_broken,        swarm.w_runtime * f,
        swarm.w_crash * f,  swarm.w_partition * f, swarm.w_outage * f,
        swarm.w_server * f, swarm.w_suspend * f,
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
    const random = c.prng.random();
    const name = service_names[random.uintLessThan(u32, service_names.len)];
    switch (pick_op(&c.swarm, random, c.fault_totals == null)) {
        .advance => c.advance(100 + random.uintLessThan(u32, 6000)),
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
    return error.StepFailed;
}

/// sim-c0's invariants over the whole store: every decision has a reason and a cause that
/// exists, `why` terminates, every replica has its create (and place) decision.
fn invariants(c: *Cluster) Failure!void {
    if (store_faulty(c)) return;
    const head = c.revision();
    try check(c, head != null, "the store cannot be read");
    // These checks read only the store (and whether a write was dropped): the same revision and
    // drop count as the last time that passed means the same answer.
    const dropped = c.dropped_total();
    if (c.checked_revision == head and c.checked_dropped == dropped) return;
    const ctx = c.controller_context();
    try decisions_have_causes(c, &ctx);
    const snapshot = controller.read_snapshot(&ctx) catch
        return check(c, false, "the snapshot cannot be read");
    for (snapshot.services) |service| {
        try why_terminates(c, &ctx, .{ .kind = .service, .name = service.rec.name });
    }
    for (snapshot.replicas) |replica| {
        try why_terminates(c, &ctx, .{ .kind = .replica, .name = replica.rec.id });
        try replica_has_decisions(c, &ctx, &replica.rec);
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

fn decisions_have_causes(c: *Cluster, ctx: *const controller.Context) Failure!void {
    var after: ?[]const u8 = null;
    var at: ?store.Revision = null;
    for (0..64) |_| {
        const page = ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_decisions,
            .at_revision = at,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag) catch return check(c, false, "the decisions cannot be listed");
        at = page.revision;
        for (page.kvs) |kv| try decision_has_cause(c, ctx, kv);
        after = page.continue_after;
        if (after == null) return;
    }
    return check(c, false, "there are more decisions than the check reads");
}

fn decision_has_cause(
    c: *Cluster,
    ctx: *const controller.Context,
    kv: store.KeyValue,
) Failure!void {
    const decision = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch
        return check(c, false, "a decision cannot be read");
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
        },
        .observed, .desired => try check(c, cause.key != null, "a cause names no key"),
        .lease_expired, .resync => {},
    }
}

fn replica_has_decisions(
    c: *Cluster,
    ctx: *const controller.Context,
    replica: *const records.Replica,
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
    if (replica.node.len > 0) try check(c, placed, "a placed replica has no place decision");
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
    try invariants(c);
    try track_excess(c);
}

/// Whether the replicas list says `name` runs on `node`.
fn assigned_to(
    replicas: []const controller.Entry(records.Replica),
    node: []const u8,
    name: []const u8,
) bool {
    for (replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.id, name)) continue;
        return std.mem.eql(u8, replica.rec.node, node);
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
    try track_unassigned(c, replicas.items, delta_ms);
    try track_starved(c, replicas.items, delta_ms);
}

fn reachable(node: *const Node) bool {
    return !node.down and node.partitioned_until_ms == null;
}

fn track_unassigned(
    c: *Cluster,
    replicas: []const controller.Entry(records.Replica),
    delta_ms: u64,
) Failure!void {
    var next: [excess_slots_max]Excess = undefined;
    var count: u32 = 0;
    for (c.nodes) |node| {
        for (node.sim.containers.containers.items) |container| {
            if (container.phase == .stopped) continue;
            if (assigned_to(replicas, node.name(), container.name)) continue;
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
    delta_ms: u64,
) Failure!void {
    var next: [excess_slots_max]Excess = undefined;
    var count: u32 = 0;
    for (replicas) |entry| {
        const replica = &entry.rec;
        if (replica.node.len == 0) continue;
        if (std.mem.eql(u8, replica.image, broken_digest)) continue;
        const node = c.node_named(replica.node) orelse continue;
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

/// Every fault off; the agents come back up as time passes. Ends the fault phase.
fn heal(c: *Cluster) void {
    c.fault_totals = c.phase_totals();
    c.set_store_down(false);
    c.ack_loss.loss_per_mille = 0;
    c.swarm.net = .{};
    c.net.heal();
    for (c.nodes) |node| node.partitioned_until_ms = null;
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
        for (replicas.items) |replica| try replica_converged(c, observed.items, &replica.rec, good);
    }
    try no_strays(c, &ctx);
}

/// Every container alive on any node is the container of a replica placed on that node.
fn no_strays(c: *Cluster, ctx: *const controller.Context) Failure!void {
    const replicas = controller.list_all(
        records.Replica,
        ctx,
        records.prefix_replicas,
        null,
        constants.replicas_max,
    ) catch return check(c, false, "the replicas cannot be read");
    for (c.nodes) |node| {
        for (node.sim.containers.containers.items) |container| {
            if (container.phase == .stopped) continue;
            const mine = assigned_to(replicas.items, node.name(), container.name);
            try check(c, mine, "a container is left behind");
        }
    }
}

fn replica_converged(
    c: *Cluster,
    observed: []const controller.Entry(records.Observed),
    replica: *const records.Replica,
    good: bool,
) Failure!void {
    try check(c, replica.node.len > 0, "a replica is not placed");
    var homes: u32 = 0;
    for (c.nodes) |node| {
        const running = live_container(node, replica.id) orelse continue;
        homes += 1;
        try check(c, std.mem.eql(u8, node.name(), replica.node), "a replica runs on a node " ++
            "other than its own");
        try check(c, good, "a replica of a broken service is running");
        try check(c, running, "a replica is still stopping");
        const live = find_live(node, replica.id).?; // live_container found it.
        try check(c, std.mem.eql(u8, live.image, replica.image), "a replica runs " ++
            "another image than its own");
    }
    try check(c, homes == @intFromBool(good), "a replica is not running exactly once");
    var seen = false;
    for (observed) |item| {
        if (!std.mem.eql(u8, item.rec.replica, replica.id)) continue;
        seen = true;
        const running = item.rec.status == .running;
        try check(c, item.rec.generation == replica.generation, "the server's view of a " ++
            "replica is of another generation");
        try check(c, running == good, "the server's view of a replica disagrees with its node");
        if (good) try check(c, std.mem.eql(u8, item.rec.node, replica.node), "observed on " ++
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
};

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
    const c = Cluster.create(gpa, seed, options.nodes, report) catch {
        report.failed = true;
        report.print("FAILED: out of memory\n", .{});
        return;
    };
    defer c.destroy();
    report.print("sim-cluster seed={d} operations={d}\n", .{ seed, operations });
    c.swarm.print(report);
    c.liveness = options.liveness;
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
        if (c.liveness and index == heal_at) heal(c);
        operation(c);
        if (c.report.failed) return error.StepFailed;
        try safety(c);
    }
    if (c.liveness) {
        if (c.fault_totals == null) heal(c);
        c.advance(liveness_bound_ms);
        if (c.report.failed) return error.StepFailed;
        try converged(c);
    } else {
        c.fault_totals = c.phase_totals();
    }
    try safety(c);
    try enough_work_under_faults(c, @min(heal_at, operations));
    try work_under_ceiling(c);
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

/// An agent that never sleeps (a wake time that is always now) passes every other check and
/// burns a core: no node may take more than `steps_per_minute_max` steps per minute it was up.
fn work_under_ceiling(c: *Cluster) Failure!void {
    try check(c, busiest_node_rate(c) <= steps_per_minute_max, "an agent took too many " ++
        "steps for the time it was up (a busy loop)");
}

/// The slowest rate of successful agent steps (per minute of agent uptime) among the nodes that
/// were up for at least half of the fault phase; null if there is none.
fn slowest_node_rate(c: *const Cluster) ?u64 {
    var slowest: ?u64 = null;
    for (c.nodes) |node| {
        if (node.up_ms * 2 < c.fault_ms or node.up_ms == 0) continue;
        const rate = @as(u64, node.ok_steps) * 60_000 / node.up_ms;
        slowest = if (slowest) |s| @min(s, rate) else rate;
    }
    return slowest;
}

/// The faults must leave the cluster working: a world where the store or every link is down most
/// of the time proves little, and a change that made it so would pass silently otherwise. Every
/// node that was up for half of the fault phase got `ok_steps_per_minute_min` successful agent
/// steps per minute it was up (the slowest seen over seeds 1 to 300 is in docs/DECISIONS.md),
/// and one delivered request per operation reached the server (the least seen over seeds 1 to
/// 60 was 268 in 100 operations; the old fault rates left 39).
fn enough_work_under_faults(c: *Cluster, operations: u32) Failure!void {
    const during = c.fault_totals.?;
    if (slowest_node_rate(c)) |rate| {
        try check(c, rate >= ok_steps_per_minute_min, "too few agent steps on a node that " ++
            "was up while faults were on");
    }
    try check(c, during.delivered >= operations, "too few requests reached the server " ++
        "while faults were on");
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
    report.print("starved: worst={d}ms; slowest node: {d} ok steps per up-minute\n", .{
        c.starved_worst_ms, slowest_node_rate(c) orelse 0,
    });
    report.print("busiest node: {d} steps per up-minute\n", .{busiest_node_rate(c)});
    report.print("faults: crashes={d} partitions={d} outages={d} suspends={d} " ++
        "runtime={d} server_restarts={d} ack_lost={d}\n", .{
        s.crashes_injected, s.partitions,      s.outages,             s.suspends,
        s.runtime_faults,   s.server_restarts, c.ack_loss.lost_count,
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
    report.print("duplicates: {d} replica-seconds on two nodes (counted, NOT a pass: without " ++
        "leases and fencing, slice 6, a partition can cause them)\n", .{s.duplicate_seconds});
    report.print("world hash: {x:0>16}\n", .{world_hash(c)});
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

test "a node count can be asked for" {
    // Goal: -Dnodes. Method: ask for 3 and read the swarm line.
    var report: Report = undefined;
    simulate(testing.allocator, 5, 10, .{ .nodes = 3 }, &report);
    try testing.expect(!report.failed);
    try testing.expect(std.mem.indexOf(u8, report.text(), "swarm: nodes=3 ") != null);
}
