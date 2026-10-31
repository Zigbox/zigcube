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
//! **What is checked.** After every operation: the decisions' causes and `why` (sim-c0's
//! invariants, read over the whole store), and that nothing runs for long that no service wants.
//! After the faults are healed: every service has its replicas, and no node runs anything else.
//! **Duplicates are counted, never failed**: without leases and fencing (slice 6) a partition can
//! leave one replica running on two nodes. The report prints the replica-seconds with a note that
//! the number is not a pass. The full checker set, the liveness bound and the comparison with
//! WASM are slice 2b part F.
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
/// More containers running than services want, on nodes that can be corrected, for this long.
const excess_ms_max: u64 = 120_000;
/// Virtual time given to the healed world to converge: parked requests (up to 40 s), leases
/// (10 s), back-offs and the controllers' own pacing.
const heal_ms: u64 = 240_000;

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
        return random.uintLessThan(u32, 4000);
    }

    /// The reply lost after the server acted is the common case: when it is on at all, it is
    /// frequent.
    fn lost_reply(random: std.Random) u32 {
        if (random.uintLessThan(u32, 4) == 0) return 0;
        return 50 + random.uintLessThan(u32, 200);
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
                .request = .{ .drop_per_mille = rate(r, 150), .delay_ms_max = delay(r) },
                .reply = .{ .drop_per_mille = lost_reply(r), .delay_ms_max = delay(r) },
                .duplicate_per_mille = rate(r, 100),
                .reorder_per_mille = rate(r, 80),
            },
            .ack_loss_per_mille = rate(r, 100),
            .clock_ppm = if (r.uintLessThan(u32, 3) == 0) 0 else r.uintLessThan(u32, 10_001),
            .w_apply = 5 + r.uintLessThan(u32, 15),
            .w_scale = rate(r, 15),
            .w_delete = rate(r, 8),
            .w_broken = rate(r, 6),
            .w_runtime = rate(r, 20),
            .w_crash = rate(r, 12),
            .w_partition = rate(r, 10),
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
        node.remote = agent_client.RemoteStore.init(node.cluster.gpa, node.transport(), node.name());
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
        const result = node.agent.reconcile(&ctx);
        node.resume_ms = c.manual.ms + node.spent_ms;
        node.check_crashed();
        const wake = result catch {
            c.stats.agent_failures += 1;
            _ = node.loop.step_done(clock.now_ms(), .{ .failed = node.diag.code });
            return 0;
        };
        _ = node.loop.step_done(clock.now_ms(), .{ .ok = wake });
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
    excess_since_ms: ?u64,
    second_ms: u64,
    stats: Stats,
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
        c.excess_since_ms = null;
        c.second_ms = 0;
        c.stats = .{};
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
        const name = std.fmt.bufPrint(&node.name_buf, "node{d}", .{index + 1}) catch unreachable;
        node.name_len = @intCast(name.len); // "node" and at most two digits fit the buffer.
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
            const slice = @min(left, tick_ms);
            c.manual.advance(slice);
            left -= slice;
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
        }
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

    pub fn revision(c: *Cluster) ?store.Revision {
        c.diag.reset();
        const status = c.store_handle().status(&c.diag) catch {
            c.diag.reset();
            return null;
        };
        return status.revision;
    }

    /// How many replicas run on more than one node right now.
    fn duplicates(c: *Cluster) u64 {
        var count: u64 = 0;
        for (c.nodes, 0..) |node, index| {
            for (node.sim.containers.containers.items) |container| {
                if (container.phase == .stopped) continue;
                if (c.runs_elsewhere(index, container.name)) count += 1;
            }
        }
        return count;
    }

    /// Whether a later node also runs `name`, so a pair is counted once.
    fn runs_elsewhere(c: *Cluster, index: usize, name: []const u8) bool {
        for (c.nodes[index + 1 ..]) |other| {
            for (other.sim.containers.containers.items) |container| {
                if (container.phase == .stopped) continue;
                if (std.mem.eql(u8, container.name, name)) return true;
            }
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
        // Nothing converges while the store is off, and the checks only look between operations:
        // the grace period for excess containers starts again when it is back.
        if (!down) c.excess_since_ms = null;
    }

    fn dropped_total(c: *const Cluster) u64 {
        return c.dropped_before_restart + c.server.retention.dropped;
    }

    /// Cuts or damages a node's link for a while: a request-side, a reply-side or a full cut.
    fn partition(c: *Cluster, node: *Node) void {
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
        node.partitioned_until_ms = c.manual.ms + 3000 + random.uintLessThan(u32, 60_000);
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
        return c.nodes[c.prng.random().uintLessThan(usize, c.nodes.len)];
    }
};

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

fn pick_op(swarm: *const Swarm, random: std.Random) Op {
    const weights = [_]u32{
        swarm.w_advance, swarm.w_apply,   swarm.w_scale,   swarm.w_delete,
        swarm.w_broken,  swarm.w_runtime, swarm.w_crash,   swarm.w_partition,
        swarm.w_outage,  swarm.w_server,  swarm.w_suspend,
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
    switch (pick_op(&c.swarm, random)) {
        .advance => c.advance(100 + random.uintLessThan(u32, 3000)),
        .apply => c.apply(name, images[random.uintLessThan(u32, 2)], c.replicas_for(random, 5)),
        .scale => c.apply(name, hello_digest, c.replicas_for(random, 8)),
        .delete => c.delete_service(name),
        .broken => c.apply(name, broken_digest, 1 + c.replicas_for(random, 2)),
        .runtime_fault => {
            c.stats.runtime_faults += 1;
            _ = c.pick_node().sim.containers.random_fault();
        },
        .crash => c.crash(c.pick_node()),
        .partition => c.partition(c.pick_node()),
        .outage => {
            c.stats.outages += 1;
            c.switched.fail_after = 1 + random.uintLessThan(u32, 40);
            c.advance(random.uintLessThan(u32, 40_000));
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
    if (c.switched.down) return;
    try check(c, c.revision() != null, "the store cannot be read");
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

/// The replicas the services want, or null if the store cannot be read.
fn desired_total(c: *Cluster) ?u32 {
    const ctx = c.controller_context();
    const list = controller.list_all(
        records.Service,
        &ctx,
        records.prefix_services,
        null,
        constants.services_max,
    ) catch return null;
    var total: u32 = 0;
    for (list.items) |service| total += service.rec.replicas;
    return total;
}

/// Containers running on nodes that could be told to stop them: agent up, link not cut.
fn correctable_running(c: *Cluster) u32 {
    var count: u32 = 0;
    for (c.nodes) |node| {
        if (node.down) continue;
        if (node.partitioned_until_ms != null) continue;
        count += node.sim.containers.running_count();
    }
    return count;
}

fn track_excess(c: *Cluster) Failure!void {
    const wanted = desired_total(c) orelse {
        c.excess_since_ms = null;
        return;
    };
    if (c.switched.down or correctable_running(c) <= wanted) {
        c.excess_since_ms = null;
        return;
    }
    const since = c.excess_since_ms orelse c.manual.ms;
    c.excess_since_ms = since;
    try check(c, c.manual.ms - since <= excess_ms_max, "more containers run than desired");
}

/// Every fault off, every agent up, time to settle.
fn heal(c: *Cluster) void {
    c.set_store_down(false);
    c.ack_loss.loss_per_mille = 0;
    c.swarm.net = .{};
    c.net.heal();
    for (c.nodes) |node| node.partitioned_until_ms = null;
    c.advance(heal_ms);
}

/// Every service has what it asked for (or is held, if its image is broken), and no node runs
/// anything else.
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
    const list = controller.list_all(
        records.Service,
        &ctx,
        records.prefix_services,
        null,
        constants.services_max,
    ) catch return check(c, false, "the services cannot be read");
    var running_total: u32 = 0;
    for (list.items) |service| {
        const counts = service_counts(c, &ctx, service.rec.name);
        running_total += counts.running;
        const wanted = service.rec.replicas;
        const good = !std.mem.eql(u8, service.rec.image, broken_digest);
        try check(c, counts.replicas == wanted, "a service lacks replicas");
        if (good) try check(c, counts.running == wanted, "a good service is not all running");
        if (!good) try check(c, counts.running == 0, "a broken service is running");
    }
    var left: u32 = 0;
    for (c.nodes) |node| left += node.sim.containers.running_count();
    try check(c, left == running_total, "containers left behind");
}

const Counts = struct { replicas: u32, running: u32 };

fn service_counts(c: *Cluster, ctx: *const controller.Context, service: []const u8) Counts {
    _ = c;
    var counts: Counts = .{ .replicas = 0, .running = 0 };
    const prefix = records.replicas_prefix(service);
    const replicas = controller.list_all(
        records.Replica,
        ctx,
        prefix.slice(),
        null,
        constants.replicas_max,
    ) catch
        return counts;
    const observed = controller.list_all(
        records.Observed,
        ctx,
        records.prefix_observed,
        null,
        constants.replicas_max,
    ) catch return counts;
    for (replicas.items) |replica| {
        counts.replicas += 1;
        for (observed.items) |item| {
            if (!std.mem.eql(u8, item.rec.replica, replica.rec.id)) continue;
            if (item.rec.status == .running) counts.running += 1;
        }
    }
    return counts;
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
    return hasher.final();
}

fn hash_node(hasher: *std.hash.Wyhash, node: *Node) void {
    hasher.update(node.name());
    hasher.update(std.mem.asBytes(&node.sim.restarts));
    for (node.sim.containers.containers.items) |container| {
        hasher.update(container.name);
        const tag: u8 = @backingInt(std.meta.activeTag(container.phase));
        hasher.update(&.{tag});
    }
}

// ---- A run --------------------------------------------------------------------------------------

/// Runs `operations` operations drawn from `seed` in the world the seed chose, heals it, checks
/// that it converged, and ends the report with the hash. The verdict is `report.failed`.
pub fn simulate(
    gpa: Allocator,
    seed: u64,
    operations: u32,
    nodes_wanted: ?u32,
    report: *Report,
) void {
    report.* = .{};
    const c = Cluster.create(gpa, seed, nodes_wanted, report) catch {
        report.failed = true;
        report.print("FAILED: out of memory\n", .{});
        return;
    };
    defer c.destroy();
    report.print("sim-cluster seed={d} operations={d}\n", .{ seed, operations });
    c.swarm.print(report);
    run_steps(c, operations) catch {
        assert(report.failed);
        return;
    };
    print_summary(c);
}

fn run_steps(c: *Cluster, operations: u32) Failure!void {
    for (0..operations) |_| {
        operation(c);
        try invariants(c);
        try track_excess(c);
    }
    heal(c);
    try converged(c);
    try invariants(c);
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

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

test "the same seed gives the same report and the same hash" {
    // Goal: determinism, which replay and native-versus-WASM comparison rest on. Method: run two
    // seeds twice each and compare the bytes, the hash line included.
    var first: Report = undefined;
    var second: Report = undefined;
    for ([_]u64{ 3, 9 }) |seed| {
        simulate(testing.allocator, seed, 30, null, &first);
        simulate(testing.allocator, seed, 30, null, &second);
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
        simulate(testing.allocator, 100 + index, 40, null, &report);
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
    simulate(testing.allocator, 5, 10, 3, &report);
    try testing.expect(!report.failed);
    try testing.expect(std.mem.indexOf(u8, report.text(), "swarm: nodes=3 ") != null);
}
