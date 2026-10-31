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
//!   - The node registers `/nodes/<node>` on a lease it keeps alive. A lease that is gone is
//!     granted again and the node registers again; the workloads keep running (stopping them on
//!     a lost lease is C1, docs/core.md).
//!
//! Observed records are written on every change of what the agent knows, not on a timer, and
//! without a compare: the agent is their only writer.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
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

    fn as_controller(ctx: *const Context) controller.Context {
        return .{ .store = ctx.store, .clock = ctx.clock, .arena = ctx.arena, .diag = ctx.diag };
    }
};

pub const Config = struct {
    /// The node's name; borrowed, it must outlive the agent.
    node: []const u8,
    capacity: records.Requests,
    address: []const u8 = "",
    agent_version: []const u8 = "0.0.0",
    lease_ttl_ms: u32 = constants.node_lease_ttl_ms,
};

const PendingStop = struct {
    handle: runtime.Handle,
    /// The container is killed at the next step after this time if it is still running.
    deadline_ms: u64,
};

pub const watch_prefixes = [_][]const u8{records.prefix_replicas};

pub const Agent = struct {
    config: Config,
    lease: store.LeaseId,
    renew_at_ms: u64,
    stops: [constants.agent_stops_max]PendingStop,
    stops_count: u32,

    /// Initialises in place: the stop table is large.
    pub fn init(agent: *Agent, config: Config) void {
        assert(records.name_problem(config.node, constants.node_name_bytes_max) == null);
        assert(config.lease_ttl_ms >= constants.lease_ttl_ms_min);
        agent.config = config;
        agent.lease = store.lease_none;
        agent.renew_at_ms = 0;
        agent.stops_count = 0;
    }

    pub fn reconcile(agent: *Agent, ctx: *const Context) Error!Wakeup {
        assert(ctx.diag.code == null);
        const now = ctx.clock.now_ms();
        var acted: u32 = 0;
        if (try agent.heartbeat(ctx)) acted += 1;
        const listings = try ctx.runtime.list(ctx.arena, ctx.diag);
        var pass: Pass = .{ .agent = agent, .ctx = ctx, .listings = listings };
        try pass.load();
        try pass.replicas();
        try pass.orphan_containers();
        try pass.orphan_records();
        acted += try pass.flush();
        agent.forget_finished_stops(listings);
        return .{ .at_ms = agent.next_wake(now), .prefixes = &watch_prefixes, .acted = acted };
    }

    /// The soonest the agent needs to run again: its lease renewal, a stop's deadline, or the
    /// resync that notices a container that ended.
    fn next_wake(agent: *const Agent, now: u64) u64 {
        var wake = now + constants.agent_resync_ms;
        if (agent.lease != store.lease_none and agent.renew_at_ms < wake) wake = agent.renew_at_ms;
        for (agent.stops[0..agent.stops_count]) |stop| {
            if (stop.deadline_ms < wake) wake = stop.deadline_ms;
        }
        return @max(wake, now);
    }

    // ---- The lease and the node's registration ----

    /// Keeps the node's lease alive, or grants one and registers. True if a transaction was made.
    fn heartbeat(agent: *Agent, ctx: *const Context) Error!bool {
        const now = ctx.clock.now_ms();
        if (agent.lease != store.lease_none) {
            if (now < agent.renew_at_ms) return false;
            if (ctx.store.lease_keepalive(agent.lease, ctx.diag)) |_| {
                agent.renew_at_ms = now + @divFloor(agent.config.lease_ttl_ms, 3);
                return false;
            } else |err| {
                if (err != error.LeaseNotFound) return err;
                ctx.diag.reset();
                agent.lease = store.lease_none;
            }
        }
        const lease = try ctx.store.lease_grant(agent.config.lease_ttl_ms, ctx.diag);
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
        _ = try writers.txn(ctx.store, .{ .agent = agent.config.node }, request, ctx.diag);
        agent.lease = lease.id;
        agent.renew_at_ms = now + @divFloor(agent.config.lease_ttl_ms, 3);
        return true;
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

    fn load(pass: *Pass) Error!void {
        const ctx = pass.ctx.as_controller();
        const all = try controller.list_all(
            records.Replica,
            &ctx,
            records.prefix_replicas,
            null,
            constants.replicas_max,
        );
        var mine: std.ArrayList(controller.Entry(records.Replica)) = .empty;
        for (all.items) |item| {
            if (!std.mem.eql(u8, item.rec.node, pass.agent.config.node)) continue;
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
    /// with the same id (a service deleted and applied again restarts its numbering), which
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

    fn put_observed(pass: *Pass, observed: records.Observed) Error!void {
        const ctx = pass.ctx;
        const key = records.observed_key(observed.node, observed.replica);
        const value = try records.encode(ctx.arena, observed, ctx.diag);
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
    /// same id (a service deleted and applied again restarts its numbering, and the old
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
            .node = replica.node,
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
            .node = replica.node,
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
            .node = replica.node,
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
        var batch: controller.Batch = .{};
        var commits: u32 = 0;
        const ctx = pass.ctx.as_controller();
        for (pass.writes.items) |write| {
            if (!batch.has_room(1)) {
                _ = try controller.commit(&ctx, .{ .agent = pass.agent.config.node }, &batch);
                commits += 1;
                batch = .{};
            }
            if (write.value) |value| batch.put(write.key, value) else batch.delete(write.key);
        }
        if (batch.ops_count > 0) {
            _ = try controller.commit(&ctx, .{ .agent = pass.agent.config.node }, &batch);
            commits += 1;
        }
        return commits;
    }
};

// ---- Pure helpers ------------------------------------------------------------------------------

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
