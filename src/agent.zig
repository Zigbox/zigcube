//! The node agent's reconcile step. Like a controller (`controller.zig`) it is `reconcile(ctx) ->
//! Wakeup`: it compares this node's desired replicas with what the `Runtime` lists, starts and
//! stops containers, writes what it saw to `/observed/<node>/<replica>`, and returns. The shell
//! around it (the process, the HTTP client to the server, the adapter around `zigbox`) is not
//! here; this is the decision-making, and it runs unchanged against the simulated runtime.
//!
//! The rules (docs/keys.md, "Desired replica" and "Observed state"):
//!
//!   - A desired replica with no container and no observed record is started. A container that
//!     failed to start is observed as `stopped` with `start_failed` and the runtime's own
//!     diagnostic, and is not started again: only the controller decides whether to replace it.
//!   - A container the runtime lists for a desired replica is **re-adopted**: after an agent
//!     restart it is observed as it is, never started a second time. Containers are matched to
//!     replicas by the `zcube.replica` label, which is how a restarted agent knows them.
//!   - A container that ended is observed as stopped with how it ended. An observed record that
//!     says `running` for a container the runtime no longer has is corrected to `stopped`, `lost`.
//!   - A container whose replica key has been deleted is stopped ("deleting the key means stop
//!     it"), and once it has stopped the observed record is removed. A stop is asked for once and
//!     checked on later steps: if the container is still running after its grace period the next
//!     step kills it. The step never waits for a stop.
//!   - The node registers `/nodes/<node>` on a lease it keeps alive. The lease's ttl is the
//!     server's: the agent learns it from the grant. The revision of its registration is its
//!     **tenure**, and every observed write is checked against it (I2): a write from a tenure
//!     that has ended is refused.
//!   - The agent **fences itself** (docs/authority.md §3). It records `s`, the time on its
//!     monotonic clock at which it sent the last keepalive the server acknowledged, and at
//!     `s + ttl - fence_margin` it stops every container (`fencing.zig`), killing what is left
//!     `fence_stop_ms` later. `s`, the lease and the tenure are in the agent's state directory,
//!     so a restarted agent honours them. A lease that is gone, or a refused observed write,
//!     fences at once. Then the node registers again, empty, under a new tenure.
//!
//! Observed records are written on every change of what the agent knows, not on a timer, with a
//! compare on the agent's tenure.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const fencing = @import("fencing.zig");
const agent_records = @import("agent_records.zig");
const agent_state = @import("agent_state.zig");
const compare_sets = @import("compare_sets.zig");
const node_store = @import("node_store.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const Clock = @import("clock.zig").Clock;

const root = @import("root");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Wakeup = controller.Wakeup;
const maxInt = std.math.maxInt;

pub const Error = controller.Error || runtime.Error;

/// The agent's test-only fault, for the cluster simulator's teeth test (docs/core.md, "The
/// cluster simulation"): the agent ignores every order to stop a container. It is a constant
/// the program's root file can declare as `pub const agent_teeth_ignore_stop = true;` and no
/// other way: the one root that does is `sim_teeth_main.zig`, which only the `sim-teeth` build
/// step compiles. The shipped programs, the tests and the WASM core have other roots, so for
/// them it is false, and `zcube_agent.zig` asserts that at compile time.
pub const fault_ignore_stop: bool = if (@hasDecl(root, "agent_teeth_ignore_stop"))
    root.agent_teeth_ignore_stop
else
    false;

pub const Context = struct {
    store: store.Store,
    runtime: runtime.Runtime,
    clock: Clock,
    arena: Allocator,
    diag: *Diag,
    /// The clock the fence deadline is on: monotonic, and not stopped by a suspended host
    /// (CLOCK_BOOTTIME). Null means `clock` is it, which is what the tests and the simulator use.
    mono: ?Clock = null,
    /// Where the lease, its send time and the tenure are kept across a restart. Null keeps
    /// nothing (the tests that do not restart).
    state: ?agent_state.AgentState = null,
    /// The host's boot id (`/proc/sys/kernel/random/boot_id`), kept with the lease: a kept send
    /// time is on a clock that restarts at boot, so a lease kept under another boot fences.
    /// Empty where there is none (the tests and the simulator, which do not reboot).
    boot_id: []const u8 = "",
    /// Where the agent says by when every call to the server must end (the fence), as soon as it
    /// changes within a step. Null caps nothing (a store in memory never waits).
    deadline: ?Deadline = null,
    /// The agent's image store, for the summary it publishes as `/node-store/<node>`. Null
    /// publishes none (the tests that do not look at locality).
    images: ?node_store.Images = null,

    pub fn mono_ms(ctx: *const Context) u64 {
        const clock = ctx.mono orelse ctx.clock;
        return clock.now_ms();
    }

    fn as_controller(ctx: *const Context) controller.Context {
        return .{ .store = ctx.store, .clock = ctx.clock, .arena = ctx.arena, .diag = ctx.diag };
    }
};

/// Receives the time, on the monotonic clock, by which every later call to the server must end;
/// `maxInt` if there is none (no lease, or a fence that makes no call).
pub const Deadline = struct {
    context: *anyopaque,
    set_fn: *const fn (context: *anyopaque, deadline_ms: u64) void,
};

pub const Config = struct {
    /// The node's name; borrowed, it must outlive the agent.
    node: []const u8,
    capacity: records.Requests,
    address: []const u8 = "",
    /// `HOST:PORT` of the node's peer server, as other nodes' fetches reach it; borrowed.
    peer: []const u8 = "",
    agent_version: []const u8 = "0.0.0",
};

/// The state file that holds the lease, in the agent's state directory.
pub const lease_file = "lease.json";

/// What the agent keeps in `lease_file`.
const LeaseFile = struct {
    lease: u64,
    ttl_ms: u32,
    /// `s`, on the monotonic clock.
    sent_ms: u64,
    tenure: u64,
    /// The boot the send time was read in (`Context.boot_id`).
    boot_id: []const u8 = "",
    /// A fence had begun: a restarted agent finishes it, whatever the lease says, so that it
    /// never starts again what the fence stopped.
    fencing: bool = false,
    /// With `fencing`: when the fence kills what is left, monotonic, in `boot_id`.
    kill_at_ms: u64 = 0,
};

/// The fence in progress: containers are being stopped, and killed at `kill_at_ms` (monotonic).
const Fence = struct {
    active: bool = false,
    asked: bool = false,
    kill_at_ms: u64 = 0,
};

const Beat = enum { idle, acted, fenced };

const PendingStop = struct {
    handle: runtime.Handle,
    /// The container is killed at the next step after this time if it is still running.
    deadline_ms: u64,
};

pub const Agent = struct {
    config: Config,
    lease: store.LeaseId,
    /// The lease's ttl as the server granted it; 0 with no lease.
    lease_ttl_ms: u32,
    /// The revision of the node's registration: the agent's tenure. 0 with no lease.
    tenure: store.Revision,
    /// `s`: when the last acknowledged keepalive (or the grant) was sent, monotonic.
    sent_ms: u64,
    /// When the next keepalive is due, monotonic.
    renew_at_ms: u64,
    fence: Fence,
    /// How many times the agent has fenced itself; the shell says so when it grows.
    fences: u32,
    restored: bool,
    stops: [constants.agent_stops_max]PendingStop,
    stops_count: u32,
    /// The lease and the hash of the `/node-store` value last written: the summary is written
    /// again only when it changes or the lease does (a new lease deleted the old key).
    store_lease: store.LeaseId,
    store_hash: u64,
    /// Summary writes the server refused (not a failed tenure compare): counted once per run of
    /// refusals, and cleared by the next write that is accepted. The summary is advisory, so a
    /// refusal never stops replica work; the next step tries again.
    store_refusals: u32,
    store_refused: bool,
    /// The first cause of the last counted refusal, for the shell to say.
    store_refusal_text: [store_refusal_text_bytes]u8,
    store_refusal_len: u8,
    /// Pull records dropped unpublished (ZC-W0504), and the last one's container and reason, for
    /// the shell to say: a dropped record is statistics lost, and it must not be silent.
    pull_drops: u32,
    pull_drop_text: [pull_drop_text_bytes]u8,
    pull_drop_len: u8,

    const store_refusal_text_bytes = 160;
    const pull_drop_text_bytes = 200;

    /// What the last counted summary refusal said (empty if none).
    pub fn store_refusal(agent: *const Agent) []const u8 {
        return agent.store_refusal_text[0..agent.store_refusal_len];
    }

    /// The container and reason of the last dropped pull record (empty if none).
    pub fn pull_drop(agent: *const Agent) []const u8 {
        return agent.pull_drop_text[0..agent.pull_drop_len];
    }

    /// Keeps the container and reason of a pull record about to be dropped; `drop_pull` counts it
    /// once the file is gone, so a remove that fails does not count the same file every step.
    fn note_pull_drop(agent: *Agent, name: []const u8, reason: []const u8) void {
        var writer: std.Io.Writer = .fixed(&agent.pull_drop_text);
        // A text too long for the buffer is cut: the line is a hint, never a failure.
        writer.print("container {s}: {s}", .{ name, reason }) catch {};
        agent.pull_drop_len = @intCast(writer.end);
    }

    /// Initialises in place: the stop table is large.
    pub fn init(agent: *Agent, config: Config) void {
        assert(records.name_problem(config.node, constants.node_name_bytes_max) == null);
        agent.config = config;
        agent.lease = store.lease_none;
        agent.lease_ttl_ms = 0;
        agent.tenure = 0;
        agent.sent_ms = 0;
        agent.renew_at_ms = 0;
        agent.fence = .{};
        agent.fences = 0;
        agent.store_refusals = 0;
        agent.store_refused = false;
        agent.store_refusal_len = 0;
        agent.pull_drops = 0;
        agent.pull_drop_len = 0;
        agent.restored = false;
        agent.stops_count = 0;
        agent.store_lease = store.lease_none;
        agent.store_hash = 0;
    }

    /// When the fence falls, on the monotonic clock; null if the agent holds no lease or is
    /// already fencing.
    pub fn fence_at_ms(agent: *const Agent) ?u64 {
        if (agent.lease == store.lease_none or agent.fence.active) return null;
        return fencing.fence_at_ms(agent.sent_ms, agent.lease_ttl_ms);
    }

    /// How long until the fence, so a caller that waits does not wait past it (`maxInt` if
    /// there is none). While fencing, how long until the kill, and at most `fence_poll_ms` once
    /// it is due: a step that failed is retried in time to kill.
    pub fn fence_in_ms(agent: *const Agent, mono_now: u64) u32 {
        if (agent.fence.active) {
            const left = agent.fence.kill_at_ms -| mono_now;
            return @intCast(if (left == 0) constants.fence_poll_ms else @min(left, maxInt(u32)));
        }
        const at = agent.fence_at_ms() orelse return maxInt(u32);
        return @intCast(@min(at -| mono_now, maxInt(u32)));
    }

    /// How long a wait for a replica change may hold the server: `slice_ms`, or less if the
    /// fence (or a fence's kill) falls sooner, and at least 1.
    pub fn watch_hold_ms(agent: *const Agent, mono_now: u64, slice_ms: u32) u32 {
        const capped = @min(slice_ms, constants.api_watch_timeout_ms_max);
        return @max(1, @min(capped, agent.fence_in_ms(mono_now)));
    }

    /// Tells the caller by when every call to the server must end: the fence.
    fn cap_calls(agent: *const Agent, ctx: *const Context) void {
        const deadline = ctx.deadline orelse return;
        deadline.set_fn(deadline.context, agent.fence_at_ms() orelse maxInt(u64));
    }

    pub fn reconcile(agent: *Agent, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        const mono = ctx.mono_ms();
        // The fence comes first and needs no server: an agent cut off from everything still stops.
        try agent.restore_lease(ctx);
        if (agent.fence_at_ms()) |at| {
            if (mono >= at) try agent.begin_fence(ctx, at);
        }
        if (agent.fence.active) return agent.fence_step(ctx, now);
        agent.cap_calls(ctx);
        var acted: u32 = 0;
        switch (try agent.heartbeat(ctx)) {
            .idle => {},
            .acted => acted += 1,
            .fenced => return agent.fence_step(ctx, now),
        }
        // A grant or a keepalive moves the fence: the calls that follow are capped by the new one.
        agent.cap_calls(ctx);
        const listings = try ctx.runtime.list(ctx.arena, ctx.diag);
        try agent.publish_store(ctx, listings);
        if (agent.fence.active) return agent.fence_step(ctx, now);
        var pass: Pass = .{
            .agent = agent,
            .ctx = ctx,
            .listings = listings,
            .node_key = records.node_key(agent.config.node),
        };
        try pass.load();
        try pass.replicas();
        try pass.orphan_containers();
        try pass.orphan_records();
        acted += try pass.flush();
        agent.forget_finished_stops(listings);
        if (agent.fence.active) return agent.fence_step(ctx, now);
        // After the replica pass: the records are statistics, so a failing publish (a server that
        // cannot be reached, a state directory that cannot be read) never holds replica work back.
        try agent.publish_pulls(ctx);
        if (agent.fence.active) return agent.fence_step(ctx, now);
        const at_ms = agent.next_wake(now, mono);
        return .{ .at_ms = at_ms, .prefixes = &.{}, .acted = acted };
    }

    /// The soonest the agent needs to run again: its lease renewal, the fence, a stop's deadline,
    /// or the resync that notices a container that ended. A stop whose deadline has passed is not
    /// a wake: if the container is still an orphan or stale, this pass already killed it
    /// (`stop_once`), and one that is still listed (a record whose container never started reads
    /// `starting` until `fake_start_timeout_ms`, and there is nothing to kill) is looked at again
    /// by the resync, not at once, every step. A pending stop that neither path visits waits
    /// quietly for its container to end.
    fn next_wake(agent: *const Agent, now: u64, mono: u64) u64 {
        var wake = now + constants.agent_resync_ms;
        if (agent.lease != store.lease_none) {
            wake = @min(wake, now + (agent.renew_at_ms -| mono));
            wake = @min(wake, now + (agent.fence_at_ms().? -| mono));
        }
        for (agent.stops[0..agent.stops_count]) |stop| {
            if (stop.deadline_ms > now and stop.deadline_ms < wake) wake = stop.deadline_ms;
        }
        return @max(wake, now);
    }

    // ---- The lease and the node's registration ----

    /// Writes the image summary (`/node-store/<node>`, advisory, bound to the node's lease) when
    /// it changed. A failed tenure compare fences, as for an observed write.
    fn publish_store(
        agent: *Agent,
        ctx: *const Context,
        listings: []const runtime.Listing,
    ) Error!void {
        const images = ctx.images orelse return;
        assert(agent.lease != store.lease_none);
        var started: std.ArrayList([]const u8) = .empty;
        for (listings) |listing| {
            const digest = label_value(listing.labels, runtime.label_image) orelse continue;
            started.append(ctx.arena, digest) catch return failures.no_memory(ctx.diag);
        }
        const summary = images.summary(ctx.arena, started.items) catch
            return failures.no_memory(ctx.diag);
        var record = node_store.record_of(ctx.arena, agent.config.node, summary) catch
            return failures.no_memory(ctx.diag);
        record.peer = agent.config.peer;
        const value = try records.encode(ctx.arena, record, ctx.diag);
        const hash = std.hash.Wyhash.hash(0, value);
        if (agent.store_lease == agent.lease and agent.store_hash == hash) return;
        const key = records.node_store_key(agent.config.node);
        var tenure: compare_sets.Set = .{};
        compare_sets.observed_write(&tenure, agent.config.node, agent.tenure);
        const put: store.Put = .{ .key = key.slice(), .value = value, .lease = agent.lease };
        const op: store.Op = .{ .put = put };
        const request: store.TxnRequest = .{ .compares = tenure.compares(), .on_success = &.{op} };
        const role: writers.Role = .{ .agent = agent.config.node };
        const done = writers.txn(ctx.store, role, request, ctx.diag) catch |err| {
            return agent.store_refused_by(ctx, err);
        };
        if (!done.succeeded) return agent.begin_fence(ctx, ctx.mono_ms());
        agent.store_lease = agent.lease;
        agent.store_hash = hash;
        agent.store_refused = false;
    }

    /// Publishes the pull records the fetch children left (`pull.json` in a container's directory)
    /// as `/pulls/<node>/<tree>`, at most `pulls_per_step_max` a step, and removes each file once
    /// it is stored or can never be (a server that refuses it, a file that is not a record). The
    /// records are statistics: a refusal never stops replica work, but a server that cannot be
    /// reached ends the step as any call does, and a failed tenure compare fences.
    fn publish_pulls(agent: *Agent, ctx: *const Context) Error!void {
        const state = ctx.state orelse return;
        assert(agent.lease != store.lease_none);
        const entries = state.list(ctx.arena, agent_records.dir_containers) catch |err| {
            return state_failed(ctx, err, "list the containers for pull records");
        };
        var published: u32 = 0;
        for (entries[0..@min(entries.len, constants.fake_dir_entries_max)]) |entry| {
            if (published == constants.pulls_per_step_max) break;
            if (!std.mem.endsWith(u8, entry, "/")) continue;
            const name = entry[agent_records.dir_containers.len .. entry.len - 1];
            if (runtime.name_problem(name) != null) continue;
            var buffer: [agent_state.name_bytes_max]u8 = undefined;
            const file = agent_records.path(&buffer, name, agent_records.file_pull);
            const text = state.read(ctx.arena, file) catch |err| switch (err) {
                error.Absent => continue,
                // A file past the state limit can never be read: remove it, or it wedges here.
                error.TooBig => {
                    agent.note_pull_drop(name, "its pull.json is too big to read");
                    try agent.drop_pull(ctx, state, file);
                    continue;
                },
                else => return state_failed(ctx, err, "read a pull record"),
            };
            published += 1;
            try agent.publish_pull(ctx, state, file, name, text);
            if (agent.fence.active) return;
        }
    }

    fn publish_pull(
        agent: *Agent,
        ctx: *const Context,
        state: agent_state.AgentState,
        file: []const u8,
        name: []const u8,
        text: []const u8,
    ) Error!void {
        const parsed = std.json.parseFromSliceLeaky(records.Pull, ctx.arena, text, .{
            .ignore_unknown_fields = true,
        }) catch {
            agent.note_pull_drop(name, "its pull.json is not a pull record");
            return agent.drop_pull(ctx, state, file);
        };
        const tree_ok = parsed.tree.len > 0 and parsed.tree.len <= constants.tree_digest_bytes;
        if (!tree_ok or !std.mem.eql(u8, parsed.node, agent.config.node)) {
            agent.note_pull_drop(name, "its pull record names another node or no usable tree");
            return agent.drop_pull(ctx, state, file);
        }
        const value = try records.encode(ctx.arena, parsed, ctx.diag);
        const key = records.pull_key(agent.config.node, parsed.tree);
        var tenure: compare_sets.Set = .{};
        compare_sets.observed_write(&tenure, agent.config.node, agent.tenure);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = value } };
        const request: store.TxnRequest = .{ .compares = tenure.compares(), .on_success = &.{op} };
        const role: writers.Role = .{ .agent = agent.config.node };
        const done = writers.txn(ctx.store, role, request, ctx.diag) catch |err| {
            // A server that answered and refused (an older one has no such endpoint) loses the
            // statistics, never the node's work; any other failure leaves the file for the next
            // step.
            const code = ctx.diag.code orelse return err;
            if (code != .E0504) return err;
            agent.note_pull_drop(name, ctx.diag.last_cause() orelse "zcube-server refused it");
            ctx.diag.reset();
            return agent.drop_pull(ctx, state, file);
        };
        if (!done.succeeded) return agent.begin_fence(ctx, ctx.mono_ms());
        return remove_pull(ctx, state, file);
    }

    /// Removes a pull record that could not be published and counts it (ZC-W0504), after the
    /// remove: a file that stays would be noted again at the next step.
    fn drop_pull(
        agent: *Agent,
        ctx: *const Context,
        state: agent_state.AgentState,
        file: []const u8,
    ) Error!void {
        try remove_pull(ctx, state, file);
        agent.pull_drops += 1;
    }

    fn remove_pull(
        ctx: *const Context,
        state: agent_state.AgentState,
        file: []const u8,
    ) Error!void {
        state.remove(file) catch |err| switch (err) {
            error.Absent => {},
            else => return state_failed(ctx, err, "remove a pull record"),
        };
    }

    /// A summary write that failed for any reason but a failed tenure compare. A server that
    /// cannot be reached ends the step as any call does; a refusal (a C1 server with no such
    /// endpoint, a body it will not take) is noted once and the step goes on, because the summary
    /// is advisory and replica work must not wait for it.
    fn store_refused_by(agent: *Agent, ctx: *const Context, err: Error) Error!void {
        // ZC-E0504 is a server that answered and was not understood or refused; ZC-E0503 is one
        // that did not answer, which the fence and the step's retry handle as for any call.
        const code = ctx.diag.code orelse return err;
        if (code != .E0504) return err;
        if (!agent.store_refused) {
            agent.store_refused = true;
            agent.store_refusals += 1;
            const text = ctx.diag.last_cause() orelse @tagName(code);
            const len = @min(text.len, agent.store_refusal_text.len);
            @memcpy(agent.store_refusal_text[0..len], text[0..len]);
            agent.store_refusal_len = @intCast(len);
        }
        ctx.diag.reset();
    }

    /// Keeps the node's lease alive, or grants one and registers.
    fn heartbeat(agent: *Agent, ctx: *const Context) Error!Beat {
        const sent = ctx.mono_ms();
        if (agent.lease != store.lease_none) {
            if (sent < agent.renew_at_ms) return .idle;
            if (ctx.store.lease_keepalive(agent.lease, ctx.diag)) |granted| {
                try agent.acknowledged(ctx, sent, granted.ttl_ms);
                return .idle;
            } else |err| {
                if (err != error.LeaseNotFound) return err;
                // The lease has ended, so the server will take the node for lost: stop at once.
                ctx.diag.reset();
                try agent.begin_fence(ctx, sent);
                return .fenced;
            }
        }
        const lease = try ctx.store.lease_grant(constants.lease_ttl_ms, ctx.diag);
        const node: records.Node = .{
            .name = agent.config.node,
            .agent_version = agent.config.agent_version,
            .address = agent.config.address,
            .capacity = agent.config.capacity,
        };
        const key = records.node_key(agent.config.node);
        const value = try records.encode(ctx.arena, node, ctx.diag);
        const op: store.Op = .{ .put = .{ .key = key.slice(), .value = value, .lease = lease.id } };
        const request: store.TxnRequest = .{ .on_success = &.{op} };
        const done = try writers.txn(ctx.store, .{ .agent = agent.config.node }, request, ctx.diag);
        assert(done.succeeded);
        assert(done.revision > 0);
        agent.lease = lease.id;
        agent.tenure = done.revision;
        try agent.acknowledged(ctx, sent, lease.ttl_ms);
        return .acted;
    }

    /// The server acknowledged a request sent at `sent`: the lease runs `ttl_ms` from then at
    /// the least. The state is kept after it is held, so a failure to keep it leaves an older
    /// `s` in the file, which fences earlier, never later.
    fn acknowledged(agent: *Agent, ctx: *const Context, sent: u64, ttl_ms: u32) Error!void {
        assert(agent.lease != store.lease_none);
        assert(fencing.inequality_problem(ttl_ms) == null);
        agent.lease_ttl_ms = ttl_ms;
        agent.sent_ms = sent;
        agent.renew_at_ms = sent + @divFloor(ttl_ms, 3);
        try agent.persist(ctx);
    }

    fn persist(agent: *const Agent, ctx: *const Context) Error!void {
        const state = ctx.state orelse return;
        const file: LeaseFile = .{
            .lease = agent.lease,
            .ttl_ms = agent.lease_ttl_ms,
            .sent_ms = agent.sent_ms,
            .tenure = agent.tenure,
            .boot_id = ctx.boot_id,
            .fencing = agent.fence.active,
            .kill_at_ms = agent.fence.kill_at_ms,
        };
        const text = try records.encode(ctx.arena, file, ctx.diag);
        state.put_atomic(lease_file, text) catch |err| {
            return state_failed(ctx, err, "keep the lease");
        };
    }

    /// Reads the kept lease once, so the caller can cap its calls by the fence before the step's
    /// first call. `reconcile` does it too; later calls change nothing.
    pub fn restore_lease(agent: *Agent, ctx: *const Context) Error!void {
        if (!agent.restored) try agent.restore(ctx, ctx.mono_ms());
    }

    /// Reads what a previous run kept. A file that is not there is a first start or a finished
    /// fence; one that cannot be read or understood fences (the agent cannot know how long it
    /// has). A send time in the future, or another boot id, means the host restarted, which
    /// fences too, and so does a fence the previous run had begun.
    fn restore(agent: *Agent, ctx: *const Context, mono: u64) Error!void {
        assert(!agent.restored);
        agent.restored = true;
        const state = ctx.state orelse return;
        const text = state.read(ctx.arena, lease_file) catch |err| switch (err) {
            error.Absent => return,
            else => return agent.begin_fence(ctx, mono),
        };
        const parsed = std.json.parseFromSliceLeaky(LeaseFile, ctx.arena, text, .{}) catch
            return agent.begin_fence(ctx, mono);
        const same_boot = std.mem.eql(u8, parsed.boot_id, ctx.boot_id) and parsed.sent_ms <= mono;
        if (parsed.fencing) {
            // The kill stays where the previous run put it, if its clock is still this one.
            const kill_at = fencing.kill_at_ms(mono);
            const kept = if (same_boot and parsed.kill_at_ms > 0) parsed.kill_at_ms else kill_at;
            return agent.start_fence(ctx, @min(kept, kill_at));
        }
        const usable = parsed.lease != store.lease_none and parsed.tenure > 0 and
            fencing.inequality_problem(parsed.ttl_ms) == null and same_boot;
        if (!usable) return agent.begin_fence(ctx, mono);
        agent.lease = parsed.lease;
        agent.tenure = parsed.tenure;
        agent.lease_ttl_ms = parsed.ttl_ms;
        agent.sent_ms = parsed.sent_ms;
        agent.renew_at_ms = parsed.sent_ms + @divFloor(parsed.ttl_ms, 3);
    }

    /// Starts the fence: `nominal_ms` is when it should have begun, on the monotonic clock.
    fn begin_fence(agent: *Agent, ctx: *const Context, nominal_ms: u64) Error!void {
        if (agent.fence.active) return;
        return agent.start_fence(ctx, fencing.kill_at_ms(nominal_ms));
    }

    /// The fence is on from here, and kept so: a crash before it ends finishes it on restart.
    /// A failure to keep it fails the step, but the fence goes on (it is in memory).
    fn start_fence(agent: *Agent, ctx: *const Context, kill_at_ms: u64) Error!void {
        assert(!agent.fence.active);
        agent.fence = .{ .active = true, .asked = false, .kill_at_ms = kill_at_ms };
        try agent.persist(ctx);
    }

    /// One step of a fence: the first step signals TERM to every running container of this node,
    /// none of the calls waiting; later steps look at the runtime again (`list`) and, from the
    /// deadline on, signal KILL to each one still running. When none runs any longer the lease
    /// is forgotten, so the next step registers the node again, empty. Needs no server. N
    /// containers cost one deadline, not N waits (`Runtime.signal`); a container that cannot be
    /// signalled does not keep the others running.
    fn fence_step(agent: *Agent, ctx: *const Context, now: u64) Error!Wakeup {
        assert(agent.fence.active);
        const listings = try ctx.runtime.list(ctx.arena, ctx.diag);
        const kill = ctx.mono_ms() >= agent.fence.kill_at_ms;
        const number = if (kill) runtime.signal_kill else runtime.signal_term;
        var running: u32 = 0;
        // The first failure is the step's; later ones are dropped (the next step retries).
        var spare: Diag = undefined;
        var failed: ?runtime.Error = null;
        for (listings) |*listing| {
            if (label_value(listing.labels, runtime.label_replica) == null) continue;
            if (!is_running(listing)) continue;
            running += 1;
            if (fault_ignore_stop) continue;
            if (!kill and agent.fence.asked) continue;
            const diag = if (failed == null) ctx.diag else &spare;
            spare.reset();
            ctx.runtime.signal(listing.handle, number, diag) catch |err| switch (err) {
                error.NotFound => diag.reset(), // It has gone: what the fence wants.
                error.RuntimeFailed => failed = failed orelse err,
            };
        }
        agent.fence.asked = true;
        if (failed) |err| return err;
        if (running == 0) try agent.fenced(ctx);
        const poll = now + constants.fence_poll_ms;
        const at_ms = if (running == 0) now else poll;
        return .{ .at_ms = at_ms, .prefixes = &.{}, .acted = 0 };
    }

    /// Every container has stopped: the lease and the tenure are over.
    fn fenced(agent: *Agent, ctx: *const Context) Error!void {
        if (ctx.state) |state| {
            state.remove(lease_file) catch |err| switch (err) {
                error.Absent => {},
                else => return state_failed(ctx, err, "forget the lease"),
            };
        }
        agent.lease = store.lease_none;
        agent.lease_ttl_ms = 0;
        agent.tenure = 0;
        agent.sent_ms = 0;
        agent.renew_at_ms = 0;
        agent.stops_count = 0;
        agent.fence = .{};
        agent.fences += 1;
    }

    fn forget_finished_stops(agent: *Agent, listings: []const runtime.Listing) void {
        var kept: u32 = 0;
        for (agent.stops[0..agent.stops_count]) |stop| {
            if (!is_running(find_listing_by_name(listings, stop.handle.name()))) continue;
            agent.stops[kept] = stop;
            kept += 1;
        }
        agent.stops_count = kept;
    }

    /// Forgets the pending stop of the container called `name`, if any: it has stopped.
    fn forget_stop(agent: *Agent, name: []const u8) void {
        var kept: u32 = 0;
        for (agent.stops[0..agent.stops_count]) |stop| {
            if (std.mem.eql(u8, stop.handle.name(), name)) continue;
            agent.stops[kept] = stop;
            kept += 1;
        }
        assert(kept <= agent.stops_count);
        agent.stops_count = kept;
    }

    fn pending_stop(agent: *Agent, name: []const u8) ?*PendingStop {
        for (agent.stops[0..agent.stops_count]) |*stop| {
            if (std.mem.eql(u8, stop.handle.name(), name)) return stop;
        }
        return null;
    }
};

// ---- One pass --------------------------------------------------------------------------------

/// True if `seen` was written for another replica that had this one's id: for another
/// generation (a replica's never changes), or before this replica's key was created, so it
/// cannot be about it (revisions of one store are comparable; a record is only written after
/// the replica exists).
fn is_leftover(
    seen: *const controller.Entry(records.Observed),
    item: *const controller.Entry(records.Replica),
) bool {
    if (seen.rec.generation != item.rec.generation) return true;
    return seen.kv.mod_revision < item.kv.create_revision;
}

const Write = struct { key: []const u8, value: ?[]const u8 };

const Pass = struct {
    agent: *Agent,
    ctx: *const Context,
    listings: []const runtime.Listing,
    mine: []const controller.Entry(records.Replica) = &.{},
    observed: []const controller.Entry(records.Observed) = &.{},
    writes: std.ArrayList(Write) = .empty,
    node_key: records.Key = undefined,

    fn load(pass: *Pass) Error!void {
        const ctx = pass.ctx.as_controller();
        const all = try controller.list_all(
            records.Replica,
            &ctx,
            records.prefix_replicas,
            null,
            constants.replicas_max,
        );
        // Mine are the replicas the scheduler assigned to this node; an assignment whose replica
        // is gone has nothing to run, so its container is stopped.
        const assigned_prefix = records.assigned_prefix(pass.agent.config.node);
        const given = try controller.list_all(
            records.Assigned,
            &ctx,
            assigned_prefix.slice(),
            null,
            constants.replicas_max,
        );
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (given.items) |entry| {
            wanted.put(ctx.arena, entry.rec.replica, {}) catch
                return failures.no_memory(ctx.diag);
        }
        var mine: std.ArrayList(controller.Entry(records.Replica)) = .empty;
        for (all.items) |item| {
            if (!wanted.contains(item.rec.id)) continue;
            mine.append(ctx.arena, item) catch return failures.no_memory(ctx.diag);
        }
        pass.mine = mine.items;
        const prefix = records.observed_prefix(pass.agent.config.node);
        const seen = try controller.list_all(
            records.Observed,
            &ctx,
            prefix.slice(),
            null,
            constants.replicas_max,
        );
        pass.observed = seen.items;
    }

    /// The observed record of `item`'s replica, unless it is a leftover of an earlier replica
    /// with the same id (an older store, or one removed before its cleanup), which
    /// must never stand in for this one: such a record is replaced, not obeyed.
    fn observed_for(
        pass: *const Pass,
        item: *const controller.Entry(records.Replica),
    ) ?*const records.Observed {
        for (pass.observed) |*seen| {
            if (!std.mem.eql(u8, seen.rec.replica, item.rec.id)) continue;
            if (is_leftover(seen, item)) return null;
            return &seen.rec;
        }
        return null;
    }

    fn is_desired(pass: *const Pass, id: []const u8) bool {
        for (pass.mine) |item| {
            if (std.mem.eql(u8, item.rec.id, id)) return true;
        }
        return false;
    }

    /// Queues the record, stamped with the tenure it is written under (I2).
    fn put_observed(pass: *Pass, observed: records.Observed) Error!void {
        const ctx = pass.ctx;
        const key = records.observed_key(observed.node, observed.replica);
        assert(pass.agent.tenure > 0);
        var stamped = observed;
        stamped.tenure = pass.agent.tenure;
        const value = try records.encode(ctx.arena, stamped, ctx.diag);
        const copy = ctx.arena.dupe(u8, key.slice()) catch return failures.no_memory(ctx.diag);
        pass.writes.append(ctx.arena, .{ .key = copy, .value = value }) catch
            return failures.no_memory(ctx.diag);
    }

    // ---- Desired replicas ----

    fn replicas(pass: *Pass) Error!void {
        for (pass.mine) |*item| {
            const replica = &item.rec;
            const listing = find_listing_by_replica(pass.listings, replica.id);
            const seen = pass.observed_for(item);
            if (listing) |found| {
                if (!is_this_replica(found, item)) {
                    try pass.replace_stale(found, item, seen);
                    continue;
                }
                pass.agent.forget_stop(found.handle.name());
                try pass.report(replica, seen, found.status);
            } else if (seen) |record| {
                if (record.status != .stopped) try pass.report_lost(replica, record);
            } else {
                try pass.start(item);
            }
        }
    }

    /// The runtime holds a container of this name that belongs to an earlier replica with the
    /// same id (an older store, or one removed before its cleanup, and the old
    /// container may not have been cleaned up yet): it is stopped, never adopted, and once it
    /// has stopped the right one is started in its place. A stop is asked for once and checked
    /// on later steps, like an orphan's.
    fn replace_stale(
        pass: *Pass,
        stale: *const runtime.Listing,
        item: *const controller.Entry(records.Replica),
        seen: ?*const records.Observed,
    ) Error!void {
        const ctx = pass.ctx;
        assert(!is_this_replica(stale, item));
        assert(std.mem.eql(u8, label_value(stale.labels, runtime.label_replica).?, item.rec.id));
        if (is_running(stale)) {
            try pass.stop_once(stale);
            const status = try ctx.runtime.inspect(stale.handle, ctx.diag);
            switch (status) {
                .starting, .running => return,
                .stopped => {},
            }
            // The stop is done: the name's pending stop must not outlive it, or it would
            // never be forgotten (the listings of this pass still show the old container
            // running), keep the agent awake, and kill the container started in its place.
            pass.agent.forget_stop(stale.handle.name());
        }
        if (seen) |record| {
            // A record of this replica means it was started already (and, if the start failed,
            // is not started again); the stale container is only the name's earlier holder. A
            // record that says it runs, though, is about a container that is gone.
            if (record.status != .stopped) try pass.report_lost(&item.rec, record);
            return;
        }
        try pass.start(item);
    }

    /// Asks for `listing`'s container to stop, once; a later step kills it if it is still
    /// running after its grace period.
    fn stop_once(pass: *Pass, listing: *const runtime.Listing) Error!void {
        assert(is_running(listing));
        const ctx = pass.ctx;
        const now = ctx.clock.now_ms();
        const name = listing.handle.name();
        if (fault_ignore_stop) return;
        if (pass.agent.pending_stop(name)) |stop| {
            if (now < stop.deadline_ms) return;
            try ctx.runtime.stop(listing.handle, 0, ctx.diag);
            return;
        }
        try ctx.runtime.stop(listing.handle, constants.stop_grace_ms, ctx.diag);
        if (pass.agent.stops_count == constants.agent_stops_max) return;
        pass.agent.stops[pass.agent.stops_count] = .{
            .handle = listing.handle,
            .deadline_ms = now + constants.stop_grace_ms,
        };
        pass.agent.stops_count += 1;
        assert(pass.agent.pending_stop(name) != null);
    }

    /// Writes the observed record for a container the runtime has, if it differs from the
    /// record the store holds (adopting a container after a restart is this, with no record).
    fn report(
        pass: *Pass,
        replica: *const records.Replica,
        seen: ?*const records.Observed,
        status: runtime.Status,
    ) Error!void {
        const now = pass.ctx.clock.now_ms();
        var wanted: records.Observed = .{
            .replica = replica.id,
            .node = pass.agent.config.node,
            .generation = replica.generation,
            .status = .running,
            .started_at_ms = if (seen) |record| record.started_at_ms orelse now else now,
            .reported_at_ms = now,
        };
        switch (status) {
            .starting => wanted.status = .starting,
            .running => {},
            .stopped => |reason| try pass.apply_exit(&wanted, reason),
        }
        if (seen) |record| {
            if (same_state(record, &wanted)) return;
        }
        try pass.put_observed(wanted);
    }

    fn apply_exit(pass: *Pass, wanted: *records.Observed, reason: runtime.ExitReason) Error!void {
        wanted.status = .stopped;
        switch (reason) {
            .exited => |code| wanted.exit = .{ .kind = .exited, .code = code },
            .signaled => |number| wanted.exit = .{ .kind = .signaled, .signal = number },
            .oom => wanted.exit = .{ .kind = .oom },
            .pid_limit => wanted.exit = .{ .kind = .pid_limit },
            .start_failed => |*failure| {
                wanted.exit = .{ .kind = .start_failed };
                const arena = pass.ctx.arena;
                wanted.diagnostic = try records.diagnostic_raw(arena, failure, pass.ctx.diag);
                wanted.started_at_ms = null;
            },
            .lost => |maybe| {
                wanted.exit = .{ .kind = .lost };
                if (maybe) |*explanation| {
                    wanted.diagnostic = try records.diagnostic_raw(
                        pass.ctx.arena,
                        explanation,
                        pass.ctx.diag,
                    );
                }
            },
        }
    }

    /// The record says the container runs and the runtime has never heard of it.
    fn report_lost(
        pass: *Pass,
        replica: *const records.Replica,
        seen: *const records.Observed,
    ) Error!void {
        const now = pass.ctx.clock.now_ms();
        try pass.put_observed(.{
            .replica = replica.id,
            .node = pass.agent.config.node,
            .generation = replica.generation,
            .status = .stopped,
            .exit = .{ .kind = .lost },
            .started_at_ms = seen.started_at_ms,
            .reported_at_ms = now,
        });
    }

    fn start(pass: *Pass, item: *const controller.Entry(records.Replica)) Error!void {
        const replica = &item.rec;
        const created_revision = item.kv.create_revision;
        const ctx = pass.ctx;
        assert(created_revision > 0);
        assert(replica.id.len > 0);
        var created_buffer: [20]u8 = undefined;
        const created = created_text(&created_buffer, created_revision);
        const labels = [_]runtime.Label{
            .{ .key = runtime.label_replica, .value = replica.id },
            .{ .key = runtime.label_image, .value = replica.image },
            .{ .key = runtime.label_created, .value = created },
        };
        const env = ctx.arena.alloc(runtime.EnvVar, replica.env.len) catch
            return failures.no_memory(ctx.diag);
        for (replica.env, env) |pair, *slot| slot.* = .{ .name = pair[0], .value = pair[1] };
        const spec: runtime.Spec = .{
            .name = replica.id,
            .image = replica.image,
            .source = replica.source,
            .command = replica.command,
            .env = env,
            .limits = .{
                .cpu_millis = replica.limits.cpu_millis,
                .memory_bytes = replica.limits.memory_bytes,
            },
            .labels = &labels,
        };
        const now = ctx.clock.now_ms();
        var observed: records.Observed = .{
            .replica = replica.id,
            .node = pass.agent.config.node,
            .generation = replica.generation,
            .status = .running,
            .started_at_ms = now,
            .reported_at_ms = now,
        };
        if (runtime.spec_problem(&spec) != null) return pass.unstartable(&observed, replica);
        const outcome = try ctx.runtime.start(&spec, ctx.diag);
        switch (outcome) {
            .started => {},
            .failed => |failure| try pass.apply_exit(&observed, .{ .start_failed = failure }),
        }
        try pass.put_observed(observed);
    }

    /// A replica record the runtime would refuse outright: the API validates what it writes, so
    /// this is a hand-edited store, reported as ZC-E0301 on the replica, blamed outside.
    fn unstartable(
        pass: *Pass,
        observed: *records.Observed,
        replica: *const records.Replica,
    ) Error!void {
        const ctx = pass.ctx;
        var collector: Diag = undefined;
        collector.reset();
        const key = records.replica_key(replica.service, replica.id);
        records.raise_malformed(&collector, key.slice(), "Replica");
        var finished: Diagnostic = undefined;
        diag_mod.to_diagnostic(&finished, &collector);
        observed.status = .stopped;
        observed.exit = .{ .kind = .start_failed };
        observed.diagnostic = try records.diagnostic_raw(ctx.arena, &finished, ctx.diag);
        observed.started_at_ms = null;
        try pass.put_observed(observed.*);
    }

    // ---- Containers and records without a replica ----

    /// Stops running containers of ours whose replica key is gone. Asked for once; a container
    /// still running after its grace period is killed on a later step.
    fn orphan_containers(pass: *Pass) Error!void {
        for (pass.listings) |listing| {
            const id = label_value(listing.labels, runtime.label_replica) orelse continue;
            if (pass.is_desired(id)) continue;
            if (!is_running(&listing)) continue;
            try pass.stop_once(&listing);
        }
    }

    /// Removes the observed record of a replica that is gone, once its container has stopped.
    fn orphan_records(pass: *Pass) Error!void {
        const ctx = pass.ctx;
        for (pass.observed) |item| {
            if (pass.is_desired(item.rec.replica)) continue;
            const listing = find_listing_by_replica(pass.listings, item.rec.replica);
            if (is_running(listing)) continue;
            const copy = ctx.arena.dupe(u8, item.kv.key) catch return failures.no_memory(ctx.diag);
            pass.writes.append(ctx.arena, .{ .key = copy, .value = null }) catch
                return failures.no_memory(ctx.diag);
        }
    }

    // ---- Writing ----

    /// Commits the collected writes in transactions of the store's size. Returns how many.
    fn flush(pass: *Pass) Error!u32 {
        var batch = pass.new_batch();
        var commits: u32 = 0;
        for (pass.writes.items) |write| {
            if (!batch.has_room(1)) {
                if (!try pass.commit(&batch)) return commits;
                commits += 1;
                batch = pass.new_batch();
            }
            if (write.value) |value| batch.put(write.key, value) else batch.delete(write.key);
        }
        if (batch.ops_count > 0) {
            if (!try pass.commit(&batch)) return commits;
            commits += 1;
        }
        return commits;
    }

    /// An observed write rests on the agent's tenure (I2).
    fn new_batch(pass: *Pass) controller.Batch {
        var batch: controller.Batch = .{};
        assert(pass.agent.tenure > 0);
        batch.expect(pass.node_key.slice(), pass.agent.tenure);
        return batch;
    }

    /// False if the tenure had ended: nothing was written, and the agent fences (its lease is
    /// not the one the server holds for this node).
    fn commit(pass: *Pass, batch: *const controller.Batch) Error!bool {
        const ctx = pass.ctx.as_controller();
        const result = try controller.commit(&ctx, .{ .agent = pass.agent.config.node }, batch);
        switch (result) {
            .applied => return true,
            .conflict => {
                try pass.agent.begin_fence(pass.ctx, pass.ctx.mono_ms());
                return false;
            },
        }
    }
};

// ---- Pure helpers ------------------------------------------------------------------------------

fn state_failed(ctx: *const Context, err: agent_state.Error, operation: []const u8) Error {
    // `Crashed` is the simulator's, which looks for its own flag before it reads a result.
    const mapped: agent_state.Error = if (err == error.Crashed) error.Io else err;
    return agent_records.state_failed(ctx.diag, mapped, operation);
}

fn label_value(labels: []const runtime.Label, key: []const u8) ?[]const u8 {
    for (labels) |label| {
        if (std.mem.eql(u8, label.key, key)) return label.value;
    }
    return null;
}

fn created_text(buffer: *[20]u8, revision: store.Revision) []const u8 {
    assert(revision > 0);
    // 20 digits hold a u64.
    return std.fmt.bufPrint(buffer, "{d}", .{revision}) catch unreachable;
}

/// False if the container was started for another replica that had this one's id: its image
/// or the revision its replica key was created at differ. A container without those labels is
/// not this replica's either (the project is pre-release: no container predates the labels).
fn is_this_replica(
    listing: *const runtime.Listing,
    item: *const controller.Entry(records.Replica),
) bool {
    assert(label_value(listing.labels, runtime.label_replica) != null);
    const image = label_value(listing.labels, runtime.label_image) orelse return false;
    if (!std.mem.eql(u8, image, item.rec.image)) return false;
    const text = label_value(listing.labels, runtime.label_created) orelse return false;
    var buffer: [20]u8 = undefined;
    return std.mem.eql(u8, text, created_text(&buffer, item.kv.create_revision));
}

fn find_listing_by_replica(
    listings: []const runtime.Listing,
    id: []const u8,
) ?*const runtime.Listing {
    for (listings) |*listing| {
        const value = label_value(listing.labels, runtime.label_replica) orelse continue;
        if (std.mem.eql(u8, value, id)) return listing;
    }
    return null;
}

fn find_listing_by_name(
    listings: []const runtime.Listing,
    name: []const u8,
) ?*const runtime.Listing {
    for (listings) |*listing| {
        if (std.mem.eql(u8, listing.handle.name(), name)) return listing;
    }
    return null;
}

fn is_running(listing: ?*const runtime.Listing) bool {
    const found = listing orelse return false;
    return switch (found.status) {
        .starting, .running => true,
        .stopped => false,
    };
}

/// Whether two observed records say the same thing about the container.
fn same_state(first: *const records.Observed, second: *const records.Observed) bool {
    if (first.status != second.status) return false;
    if (first.generation != second.generation) return false;
    if ((first.exit == null) != (second.exit == null)) return false;
    if (first.exit) |left| {
        if (!left.equal(second.exit.?)) return false;
    }
    return true;
}

// The test-only fault is a constant only a root file can switch on, and no root that runs these
// tests (or ships) does: so every test here, and every other, sees the agent that stops what it
// is told to stop. `sim-teeth` is the one build that sees it on.
test "the test-only fault is off in this build" {
    try std.testing.expect(!fault_ignore_stop);
}

test "next_wake: an overdue stop is not a wake time, a future one is (issue 96)" {
    const agent = try std.testing.allocator.create(Agent);
    defer std.testing.allocator.destroy(agent);
    agent.init(.{ .node = "node1", .capacity = .{ .cpu_millis = 1000, .memory_bytes = 1 << 30 } });
    const now: u64 = 10_000;
    const resync = now + constants.agent_resync_ms;
    try std.testing.expectEqual(resync, agent.next_wake(now, 0));

    // A deadline that has passed, or is exactly now, leaves the wake at the resync.
    agent.stops[0] = .{ .handle = runtime.Handle.init("a"), .deadline_ms = now - 1 };
    agent.stops_count = 1;
    try std.testing.expectEqual(resync, agent.next_wake(now, 0));
    agent.stops[0].deadline_ms = now;
    try std.testing.expectEqual(resync, agent.next_wake(now, 0));

    // A future deadline sooner than the resync is the wake; one later than it is not.
    agent.stops[0].deadline_ms = now + 100;
    try std.testing.expectEqual(now + 100, agent.next_wake(now, 0));
    agent.stops[0].deadline_ms = resync + 5_000;
    try std.testing.expectEqual(resync, agent.next_wake(now, 0));

    // An overdue stop beside a future one: only the future one counts.
    agent.stops[1] = .{ .handle = runtime.Handle.init("b"), .deadline_ms = now + 200 };
    agent.stops[0].deadline_ms = now - 500;
    agent.stops_count = 2;
    try std.testing.expectEqual(now + 200, agent.next_wake(now, 0));
}
