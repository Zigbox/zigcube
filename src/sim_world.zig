//! `World`: the control-plane core, one node's agent and a simulated runtime, wired to the memory
//! store on virtual time, with the faults a real deployment has: the store going down, the
//! server and the agent restarting, containers dying. It is the shell the simulation needs, and
//! the smallest honest one: it does what `zcube-server` and `zcube-agent` will do around the core
//! (call a step when its `Wakeup` says so or when a key it watches changed, advance the store's
//! leases), and nothing else.
//!
//! Everything in it is deterministic: time is a `ManualClock`, randomness is the runtime's seed
//! and the caller's own generator, and no step blocks. A run is a function of its seed and the
//! calls made on it, which is what lets `sim-c0` replay a failure and compare native with WASM.

const std = @import("std");
const assert = std.debug.assert;
const agent_mod = @import("agent.zig");
const agent_state = @import("agent_state.zig");
const apply_mod = @import("apply.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const control_plane = @import("control_plane.zig");
const runtime = @import("runtime.zig");
const runtime_mod = runtime;
const sim_runtime = @import("sim_runtime.zig");
const fencing = @import("fencing.zig");
const store = @import("store.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

/// A fixed wall-clock origin, so decision ids carry 13 digits as in docs/keys.md.
pub const epoch_ms: u64 = 1761350000000;
/// How often the world looks at the clock: a step is made when its `Wakeup` is due or a watched
/// prefix changed, and never more often than this.
pub const tick_ms: u32 = 100;
/// How often the world compacts the store, as the server's maintenance will.
const compact_interval_ms: u64 = 60 * 1000;
/// Steps of server and agent in turn until neither acts, at most this many in one tick.
const rounds_max: u32 = 128;
pub const node_name = "node1";

// ---- A store that can be switched off ---------------------------------------------------------

/// Wraps a `Store` and fails every call while it is down, with the diagnostic a backend that
/// cannot be reached raises (ZC-E0201). `fail_after` switches it off after that many more calls,
/// so a fault can land in the middle of a controller step.
pub const SwitchedStore = struct {
    inner: store.Store,
    down: bool = false,
    fail_after: ?u32 = null,
    /// A transaction that puts a key under this prefix is answered, and refused (ZC-E0504), as a
    /// server that has no such endpoint does; test-only, null in every simulation.
    refuse_put_prefix: ?[]const u8 = null,
    /// A transaction that puts or deletes a key under this prefix fails as a server that cannot
    /// be reached does (ZC-E0201), while every other call is answered; test-only, null in every
    /// simulation.
    down_write_prefix: ?[]const u8 = null,
    /// A transaction that puts or deletes a key under this prefix is applied, and its answer is
    /// then lost (ZC-E0201), as a store that committed and dropped the connection; test-only,
    /// null in every simulation. `lost_answers` counts them.
    lost_answer_prefix: ?[]const u8 = null,
    lost_answers: u32 = 0,
    /// A transaction that puts a key under this prefix is answered as a server answers a write
    /// under a tenure that has ended (ZC-E0510); test-only, null in every simulation.
    tenure_ended_put_prefix: ?[]const u8 = null,
    /// A keepalive is answered with this ttl in place of the lease's own, as an older server run
    /// with a short `--lease-ttl-ms` does; test-only, null in every simulation.
    keepalive_ttl_ms: ?u32 = null,
    /// With `keepalive_ttl_ms`: the keepalive is refused with ZC-E0121 when the ttl is too short,
    /// as `RemoteStore` refuses a reply it cannot fence under; test-only, false in every
    /// simulation.
    keepalive_refuse_short: bool = false,
    /// A get of a key under this prefix fails as a server that cannot be reached does (ZC-E0201);
    /// test-only, null in every simulation.
    down_get_prefix: ?[]const u8 = null,
    /// Runs once, just before the first transaction that puts a key under `prefix` is applied;
    /// it may write through the world's store (the transaction then meets that write). Test-only,
    /// null in every simulation.
    before_put: ?BeforePut = null,
    /// A keepalive takes `cost_ms` of the clock and is cut with ZC-E0503 if that passes `cap_ms`
    /// (the cap the agent set, as a real exchange is cut); test-only, null in every simulation.
    keepalive_cost: ?KeepaliveCost = null,
    /// Every call takes `cost_ms` of the clock and is cut with ZC-E0503 if that passes the cap,
    /// after the agent's before-call hook has run; test-only, null in every simulation.
    call_cost: ?KeepaliveCost = null,
    /// True while the agent's step runs: `call_cost` costs the agent's calls only.
    in_agent_step: bool = false,
    /// The agent's before-call hook (`agent.Deadline.hook_fn`).
    before_context: ?*anyopaque = null,
    before_fn: ?*const fn (context: *anyopaque) void = null,
    calls: u32 = 0,

    pub const KeepaliveCost = struct {
        clock: *ManualClock,
        cost_ms: u32,
        cap_ms: *const u64,
        /// Keepalives cut by the cap.
        cut: u32 = 0,
    };

    pub const BeforePut = struct {
        prefix: []const u8,
        context: *anyopaque,
        run: *const fn (context: *anyopaque) void,
    };

    const vtable: store.Store.VTable = .{
        .status = status,
        .get = get,
        .list = list,
        .txn = txn,
        .watch = watch,
        .lease_grant = lease_grant,
        .lease_keepalive = lease_keepalive,
        .lease_revoke = lease_revoke,
        .lease_list = lease_list,
        .expire_leases = expire_leases,
        .compact = compact,
        .hash_at = hash_at,
    };

    pub fn interface(self: *SwitchedStore) store.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *SwitchedStore {
        return @ptrCast(@alignCast(context));
    }

    /// Counts the call and fails it if the store is down.
    fn gate(self: *SwitchedStore, diag: *Diag) store.Error!void {
        if (self.fail_after) |left| {
            if (left == 0) {
                self.down = true;
                self.fail_after = null;
            } else {
                self.fail_after = left - 1;
            }
        }
        self.calls += 1;
        if (self.before_fn) |before| before(self.before_context.?);
        if (self.call_cost) |*cost| if (self.in_agent_step) {
            if (cost.clock.ms + cost.cost_ms > cost.cap_ms.*) {
                cost.cut += 1;
                diag.raise(.E0503);
                diag.cause("the call was cut by the agent's call cap", .{});
                diag.fix(.{ .sentence = "none: the simulated call ran out of time" });
                return error.BackendFailed;
            }
            cost.clock.advance(cost.cost_ms);
        };
        if (!self.down) return;
        assert(diag.code == null);
        diag.raise(.E0201);
        diag.cause("connection refused", .{});
        diag.cause("the simulated store is switched off", .{});
        diag.fix(.{ .sentence = "switch it back on" });
        return error.BackendFailed;
    }

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        const self = from(context);
        try self.gate(diag);
        return self.inner.status(diag);
    }

    fn get(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        const self = from(context);
        try self.gate(diag);
        if (self.down_get_prefix) |prefix| {
            if (std.mem.startsWith(u8, key, prefix)) {
                diag.raise(.E0201);
                diag.cause("connection refused", .{});
                diag.fix(.{ .sentence = "switch it back on" });
                return error.BackendFailed;
            }
        }
        return self.inner.get(arena, key, at_revision, diag);
    }

    fn list(
        context: *anyopaque,
        arena: Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const self = from(context);
        try self.gate(diag);
        return self.inner.list(arena, options, diag);
    }

    fn txn(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const self = from(context);
        try self.gate(diag);
        if (self.refuse_put_prefix) |prefix| {
            for (request.on_success) |op| {
                if (op != .put) continue;
                if (!std.mem.startsWith(u8, op.put.key, prefix)) continue;
                @import("agent_client.zig").raise_bad_reply(diag, "the server refused the write");
                return error.BackendFailed;
            }
        }
        if (self.tenure_ended_put_prefix) |prefix| {
            for (request.on_success) |op| {
                if (op != .put) continue;
                if (!std.mem.startsWith(u8, op.put.key, prefix)) continue;
                diag.raise(.E0510);
                diag.cause("the simulated server ended this tenure", .{});
                diag.fix(.{ .sentence = "the agent registers the node again" });
                return error.BackendFailed;
            }
        }
        if (self.down_write_prefix) |prefix| {
            for (request.on_success) |op| {
                const key = switch (op) {
                    .put => |put| put.key,
                    .delete => |deleted| deleted,
                };
                if (!std.mem.startsWith(u8, key, prefix)) continue;
                diag.raise(.E0201);
                diag.cause("connection refused", .{});
                diag.fix(.{ .sentence = "switch it back on" });
                return error.BackendFailed;
            }
        }
        if (self.before_put) |hook| {
            for (request.on_success) |op| {
                if (op != .put) continue;
                if (!std.mem.startsWith(u8, op.put.key, hook.prefix)) continue;
                self.before_put = null;
                hook.run(hook.context);
                break;
            }
        }
        const result = try self.inner.txn(request, diag);
        if (self.lost_answer_prefix) |prefix| {
            for (request.on_success) |op| {
                const key = switch (op) {
                    .put => |put| put.key,
                    .delete => |deleted| deleted,
                };
                if (!std.mem.startsWith(u8, key, prefix)) continue;
                self.lost_answers += 1;
                diag.raise(.E0201);
                diag.cause("the store committed the write and the connection dropped", .{});
                diag.fix(.{ .sentence = "none: the next read shows the write" });
                return error.BackendFailed;
            }
        }
        return result;
    }

    fn watch(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        const self = from(context);
        try self.gate(diag);
        return self.inner.watch(options, diag);
    }

    fn lease_grant(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_grant(ttl_ms, diag);
    }

    fn lease_keepalive(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const self = from(context);
        try self.gate(diag);
        if (self.keepalive_cost) |*cost| {
            if (cost.clock.ms + cost.cost_ms > cost.cap_ms.*) {
                cost.cut += 1;
                diag.raise(.E0503);
                diag.cause("the keepalive was cut by the agent's call cap", .{});
                diag.fix(.{ .sentence = "none: the simulated call ran out of time" });
                return error.BackendFailed;
            }
            cost.clock.advance(cost.cost_ms);
        }
        var lease = try self.inner.lease_keepalive(id, diag);
        if (self.keepalive_ttl_ms) |ttl_ms| lease.ttl_ms = ttl_ms;
        if (self.keepalive_refuse_short) {
            if (fencing.inequality_problem(lease.ttl_ms)) |problem| {
                fencing.raise_problem(diag, lease.ttl_ms, problem);
                return error.BackendFailed;
            }
        }
        return lease;
    }

    fn lease_revoke(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Revision {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_revoke(id, diag);
    }

    fn lease_list(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        const self = from(context);
        try self.gate(diag);
        return self.inner.lease_list(arena, diag);
    }

    fn expire_leases(context: *anyopaque, diag: *Diag) store.Error!u32 {
        const self = from(context);
        try self.gate(diag);
        return self.inner.expire_leases(diag);
    }

    fn compact(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!void {
        const self = from(context);
        try self.gate(diag);
        return self.inner.compact(revision, diag);
    }

    fn hash_at(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!store.Hash {
        const self = from(context);
        try self.gate(diag);
        return self.inner.hash_at(revision, diag);
    }
};

// ---- The world --------------------------------------------------------------------------------

/// What one step did, for the caller's accounting.
pub const StepResult = struct {
    ran: bool,
    acted: u32,
    /// The code of the diagnostic that failed the step, if one did.
    failed: ?codes.Code,
};

pub const Stats = struct {
    server_steps: u32 = 0,
    agent_steps: u32 = 0,
    server_failures: u32 = 0,
    agent_failures: u32 = 0,
    transactions: u32 = 0,
    /// Scheduler passes after which a node's allocation record disagreed with its assignments
    /// (authority.md I6). Anything but zero is a bug.
    i6_violations: u32 = 0,
};

pub const World = struct {
    gpa: Allocator,
    manual: ManualClock,
    memory: *MemoryStore,
    switched: SwitchedStore,
    sim: sim_runtime.SimRuntime,
    /// A runtime the agent uses instead of `sim` (a test's wrapper that watches the specs it is
    /// given and passes them on to `sim.interface()`); null in every simulation.
    runtime_override: ?runtime_mod.Runtime = null,
    /// The agent's files as a wrapper of `files` that injects failures; null in every simulation.
    state_override: ?agent_state.AgentState = null,
    /// The agent's image store, for the summary it writes; null in every simulation but a test's.
    images: ?@import("node_store.zig").Images = null,
    server: control_plane.ControlPlane,
    agent: *agent_mod.Agent,
    /// The agent's files (the kept lease), which a restart of the agent finds again.
    files: agent_state.SimState,
    api_source: controller.DecisionSource,
    diag: Diag,
    arena_state: std.heap.ArenaAllocator,
    server_due_ms: u64,
    agent_due_ms: u64,
    server_seen_revision: store.Revision,
    agent_seen_revision: store.Revision,
    instance_next: u16,
    request_next: u32,
    stats: Stats,
    /// When the store is compacted next: the server's maintenance, once a minute.
    compact_due_ms: u64,
    /// Decisions dropped by the controllers that have since restarted.
    dropped_before_restart: u64,
    /// The last diagnostic that failed a step, kept for the caller to render.
    last_failure: ?codes.Code,
    /// The cap the agent last set on its calls (monotonic ms), as the shell hands it to the
    /// client; `SwitchedStore.keepalive_cost` reads it. Unused in every simulation.
    call_cap_ms: u64 = std.math.maxInt(u64),
    /// The host's boot id the agent sees; a test changes it to reboot the host.
    boot_id: []const u8 = "",

    pub fn create(gpa: Allocator, seed: u64, fixtures: []const []const u8) Allocator.Error!*World {
        const world = try gpa.create(World);
        errdefer gpa.destroy(world);
        const memory = try gpa.create(MemoryStore);
        errdefer gpa.destroy(memory);
        const agent = try gpa.create(agent_mod.Agent);
        errdefer gpa.destroy(agent);
        world.manual = .{ .ms = epoch_ms };
        memory.init(gpa, world.manual.clock());
        world.gpa = gpa;
        world.memory = memory;
        world.switched = .{ .inner = memory.interface() };
        world.sim.init(gpa, world.manual.clock(), seed, fixtures);
        world.instance_next = 1;
        world.server = control_plane.ControlPlane.init(world.take_instance());
        world.server.check_i6 = true;
        world.agent = agent;
        world.files = .init(gpa, seed ^ 0x5eed);
        agent.init(agent_config());
        world.api_source = .{ .instance = 0 };
        world.diag.reset();
        world.arena_state = std.heap.ArenaAllocator.init(gpa);
        world.server_due_ms = 0;
        world.agent_due_ms = 0;
        world.server_seen_revision = 0;
        world.agent_seen_revision = 0;
        world.request_next = 1;
        world.stats = .{};
        world.compact_due_ms = epoch_ms + compact_interval_ms;
        world.dropped_before_restart = 0;
        world.last_failure = null;
        world.boot_id = "";
        world.call_cap_ms = std.math.maxInt(u64);
        world.runtime_override = null;
        world.state_override = null;
        world.images = null;
        return world;
    }

    pub fn destroy(world: *World) void {
        const gpa = world.gpa;
        world.arena_state.deinit();
        world.files.deinit();
        world.sim.deinit();
        world.memory.deinit();
        gpa.destroy(world.memory);
        gpa.destroy(world.agent);
        gpa.destroy(world);
    }

    fn agent_config() agent_mod.Config {
        return .{
            .node = node_name,
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 * 1024 * 1024 * 1024 },
            .address = "10.0.0.5:7070",
        };
    }

    fn take_instance(world: *World) u16 {
        const instance = world.instance_next;
        world.instance_next += 1;
        return instance;
    }

    pub fn now_ms(world: *const World) u64 {
        return world.manual.ms;
    }

    /// The `Store` the core sees: the memory store behind the switch.
    pub fn store_handle(world: *World) store.Store {
        return world.switched.interface();
    }

    /// A fresh arena for a step or a request; the previous one's data is gone.
    pub fn fresh_arena(world: *World) Allocator {
        _ = world.arena_state.reset(.retain_capacity);
        return world.arena_state.allocator();
    }

    pub fn controller_context(world: *World) controller.Context {
        world.diag.reset();
        return .{
            .store = world.store_handle(),
            .clock = world.manual.clock(),
            .arena = world.fresh_arena(),
            .diag = &world.diag,
        };
    }

    // ---- Steps ----

    pub fn server_step(world: *World) StepResult {
        const ctx = world.controller_context();
        world.stats.server_steps += 1;
        const wake = world.server.reconcile(&ctx) catch return world.failed_step(.server);
        if (world.server.mismatch != null) world.stats.i6_violations += 1;
        world.server_due_ms = wake.at_ms;
        world.stats.transactions += wake.acted;
        return .{ .ran = true, .acted = wake.acted, .failed = null };
    }

    pub fn agent_step(world: *World) StepResult {
        world.diag.reset();
        const ctx: agent_mod.Context = .{
            .store = world.store_handle(),
            .runtime = world.runtime_override orelse world.sim.interface(),
            .clock = world.manual.clock(),
            .arena = world.fresh_arena(),
            .diag = &world.diag,
            .images = world.images,
            .state = world.state_override orelse world.files.interface(),
            .boot_id = world.boot_id,
            .deadline = .{
                .context = world,
                .set_fn = World.set_call_cap,
                .hook_fn = World.set_call_hook,
            },
        };
        world.stats.agent_steps += 1;
        world.switched.in_agent_step = true;
        const result = world.agent.reconcile(&ctx);
        world.switched.in_agent_step = false;
        const wake = result catch return world.failed_step(.agent);
        world.agent_due_ms = wake.at_ms;
        world.stats.transactions += wake.acted;
        return .{ .ran = true, .acted = wake.acted, .failed = null };
    }

    fn set_call_hook(
        context: *anyopaque,
        hook_context: ?*anyopaque,
        hook: ?*const fn (hook_context: *anyopaque) void,
    ) void {
        const world: *World = @ptrCast(@alignCast(context));
        world.switched.before_context = hook_context;
        world.switched.before_fn = hook;
    }

    fn set_call_cap(context: *anyopaque, deadline_ms: u64) void {
        const world: *World = @ptrCast(@alignCast(context));
        world.call_cap_ms = deadline_ms;
    }

    const Who = enum { server, agent };

    /// A failed step is retried a tick later: the shell's backoff, in its simplest form.
    fn failed_step(world: *World, who: Who) StepResult {
        const code = world.diag.code.?;
        world.last_failure = code;
        world.diag.reset();
        const retry = world.manual.ms + tick_ms;
        switch (who) {
            .server => {
                world.stats.server_failures += 1;
                world.server_due_ms = retry;
            },
            .agent => {
                world.stats.agent_failures += 1;
                world.agent_due_ms = retry;
            },
        }
        return .{ .ran = true, .acted = 0, .failed = code };
    }

    /// Steps whichever of server and agent is due, or has a watched key changed (here: any write
    /// since its last step, its own included, as a watch would report them), until neither acts
    /// or `rounds_max` rounds have passed. Returns the rounds made.
    pub fn settle(world: *World) u32 {
        var round: u32 = 0;
        while (round < rounds_max) : (round += 1) {
            var acted: u32 = 0;
            if (world.wakes(&world.server_seen_revision, world.server_due_ms)) {
                acted += world.server_step().acted;
            }
            if (world.wakes(&world.agent_seen_revision, world.agent_due_ms)) {
                acted += world.agent_step().acted;
            }
            if (acted == 0) return round;
        }
        return round;
    }

    /// Whether a side should step now: its timer is due, or the store's revision moved since it
    /// last looked. Records the revision it looks at. A store that is down answers nothing, so
    /// only timers wake a side then.
    fn wakes(world: *World, seen: *store.Revision, due_ms: u64) bool {
        world.diag.reset();
        const status = world.store_handle().status(&world.diag) catch {
            world.diag.reset();
            return world.manual.ms >= due_ms;
        };
        if (world.manual.ms >= due_ms) {
            seen.* = status.revision;
            return true;
        }
        if (status.revision == seen.*) return false;
        seen.* = status.revision;
        return true;
    }

    /// Moves virtual time by `ms`, a tick at a time: the store reaps expired leases, then both
    /// sides step as they are due.
    pub fn advance(world: *World, ms: u64) void {
        var left = ms;
        while (left > 0) {
            const slice = @min(left, tick_ms);
            world.manual.advance(slice);
            left -= slice;
            world.diag.reset();
            _ = world.store_handle().expire_leases(&world.diag) catch world.diag.reset();
            world.maintain();
            _ = world.settle();
        }
    }

    /// Compacts the store to its current revision when the minute is up (a store that is down
    /// is tried again a tick later). The log would otherwise grow for ever, and the memory
    /// store replays it on every read.
    fn maintain(world: *World) void {
        if (world.manual.ms < world.compact_due_ms) return;
        const head = world.revision() orelse return;
        world.compact_due_ms = world.manual.ms + compact_interval_ms;
        if (head < 2) return;
        world.diag.reset();
        world.store_handle().compact(head, &world.diag) catch world.diag.reset();
    }

    // ---- What a person or a fault does ----

    pub fn apply(world: *World, input: apply_mod.Input) apply_mod.Error!apply_mod.Result {
        const ctx = world.controller_context();
        return apply_mod.apply(&ctx, &world.api_source, input);
    }

    pub fn delete_service(world: *World, name: []const u8) apply_mod.Error!apply_mod.Result {
        const ctx = world.controller_context();
        var buffer: [16]u8 = undefined;
        const id = world.request_id(&buffer);
        return apply_mod.delete_service(&ctx, &world.api_source, name, "alex@laptop", id);
    }

    /// A request id of the shape docs/api.md asks for, never repeating in one world.
    pub fn request_id(world: *World, buffer: []u8) []const u8 {
        const text = std.fmt.bufPrint(buffer, "r-{x:0>7}", .{world.request_next});
        world.request_next += 1;
        // Cannot fail: "r-" and seven digits fit sixteen bytes.
        return text catch unreachable;
    }

    /// `kill -9` of a replica's process.
    pub fn kill(world: *World, replica: []const u8) error{NotFound}!void {
        try world.sim.inject(replica, .{ .signal = 9 });
    }

    pub fn set_store_down(world: *World, down: bool) void {
        world.switched.down = down;
        world.switched.fail_after = null;
    }

    /// The server process restarts: a new controller instance with none of the old one's memory.
    pub fn restart_server(world: *World) void {
        world.dropped_before_restart += world.server.replicas.retention.dropped;
        world.server = control_plane.ControlPlane.init(world.take_instance());
        world.server.check_i6 = true;
        world.server_due_ms = 0;
    }

    /// The agent process restarts: no lease and no stops in flight; the containers keep running
    /// in the runtime, and the agent must find them again.
    pub fn restart_agent(world: *World) void {
        world.agent.init(agent_config());
        world.files.restart();
        world.agent_due_ms = 0;
    }

    // ---- Reading what the store holds ----

    /// Decisions retention has dropped so far, over every controller instance.
    pub fn decisions_dropped(world: *const World) u64 {
        return world.dropped_before_restart + world.server.replicas.retention.dropped;
    }

    /// The store's current revision, or null if it cannot be read (it is down).
    pub fn revision(world: *World) ?store.Revision {
        world.diag.reset();
        const status = world.store_handle().status(&world.diag) catch {
            world.diag.reset();
            return null;
        };
        return status.revision;
    }

    /// How many replicas of `service` the agent has observed running.
    pub fn running_count(world: *World, service: []const u8) u32 {
        var count: u32 = 0;
        var iterator = ReplicaIterator.start(world, service);
        while (iterator.next()) |entry| {
            if (entry.observed_status == .running) count += 1;
        }
        return count;
    }

    /// How many replica keys `service` has.
    pub fn replica_count(world: *World, service: []const u8) u32 {
        var count: u32 = 0;
        var iterator = ReplicaIterator.start(world, service);
        while (iterator.next()) |_| count += 1;
        return count;
    }

    /// The lowest-numbered replica of `service` that is observed running, or null.
    pub fn first_running(world: *World, service: []const u8, buffer: []u8) ?[]const u8 {
        var iterator = ReplicaIterator.start(world, service);
        while (iterator.next()) |entry| {
            if (entry.observed_status != .running) continue;
            @memcpy(buffer[0..entry.id.len], entry.id);
            return buffer[0..entry.id.len];
        }
        return null;
    }
};

/// Walks a service's replica keys and their observed status, reading the store directly (the
/// world is the test's eye, not a controller). Stops quietly if the store cannot be read.
const ReplicaIterator = struct {
    world: *World,
    replicas: []const controller.Entry(records.Replica),
    observed: []const controller.Entry(records.Observed),
    index: u32,

    const Item = struct { id: []const u8, observed_status: ?records.ObservedStatus };

    fn start(world: *World, service: []const u8) ReplicaIterator {
        const ctx = world.controller_context();
        const none: ReplicaIterator = .{
            .world = world,
            .replicas = &.{},
            .observed = &.{},
            .index = 0,
        };
        const prefix = records.replicas_prefix(service);
        const replicas = controller.list_all(
            records.Replica,
            &ctx,
            prefix.slice(),
            null,
            constants.replicas_max,
        ) catch return none;
        const observed = controller.list_all(
            records.Observed,
            &ctx,
            records.prefix_observed,
            null,
            constants.replicas_max,
        ) catch return none;
        return .{
            .world = world,
            .replicas = replicas.items,
            .observed = observed.items,
            .index = 0,
        };
    }

    fn next(iterator: *ReplicaIterator) ?Item {
        if (iterator.index >= iterator.replicas.len) return null;
        const replica = iterator.replicas[iterator.index].rec;
        iterator.index += 1;
        var status: ?records.ObservedStatus = null;
        for (iterator.observed) |item| {
            if (!std.mem.eql(u8, item.rec.replica, replica.id)) continue;
            status = item.rec.status;
        }
        return .{ .id = replica.id, .observed_status = status };
    }
};

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

const hello: apply_mod.Input = .{
    .name = "hello",
    .image = "b3:51aa9c03",
    .replicas = 3,
    .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
    .applied_by = "alex@laptop",
    .request_id = "r-0000001",
};

test "the controller and the agent bring a service up and replace a killed replica" {
    // Goal: the two cores cooperate through the store alone. Method: apply 3 replicas and let
    // virtual time run; kill one process and see a replacement.
    const world = try World.create(testing.allocator, 1, &sim_runtime.default_fixtures);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    try testing.expectEqual(@as(u32, 3), world.running_count("hello"));
    try testing.expectEqual(@as(u32, 3), world.sim.running_count());

    try world.kill("hello-2");
    world.advance(2000);
    try testing.expectEqual(@as(u32, 3), world.running_count("hello"));
    try testing.expectEqual(@as(u32, 3), world.replica_count("hello"));
}

test "restarting the server changes nothing, and restarting the agent duplicates nothing" {
    // Goal: HANDOFF's acceptance criteria for C0. Method: converge, restart each side, run on,
    // and compare the store's revision and the runtime's container count with before.
    const world = try World.create(testing.allocator, 2, &sim_runtime.default_fixtures);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(2000);
    const before = (try world.store_handle().status(&world.diag)).revision;
    const started = world.sim.containers.items.len;

    world.restart_server();
    world.advance(2000);
    try testing.expectEqual(before, (try world.store_handle().status(&world.diag)).revision);

    world.restart_agent();
    world.advance(2000);
    try testing.expectEqual(started, world.sim.containers.items.len);
    try testing.expectEqual(@as(u32, 3), world.running_count("hello"));
}

test "a store that is down fails the steps with ZC-E0201 and everything resumes when it is back" {
    // Goal: store failure is a coded diagnostic on each side, not a crash, and nothing is lost.
    // Method: switch the store off, advance, switch it on.
    const world = try World.create(testing.allocator, 3, &sim_runtime.default_fixtures);
    defer world.destroy();
    _ = try world.apply(hello);
    world.advance(1000);
    world.set_store_down(true);
    world.advance(40_000);
    try testing.expect(world.stats.server_failures > 0);
    try testing.expect(world.stats.agent_failures > 0);
    try testing.expectEqual(codes.Code.E0201, world.last_failure.?);
    world.set_store_down(false);
    world.advance(3000);
    try testing.expectEqual(@as(u32, 3), world.running_count("hello"));
}
