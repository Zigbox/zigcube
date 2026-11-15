//! The agent's mesh view (C4 slice 4): the mesh port each local replica is given, the endpoint it
//! publishes, and the rules its supervisor is handed (`Runtime.mesh_update`, owner answer O2).
//!
//! Each step the agent reads the node's view of the mesh from the server (`GET .../mesh`, the
//! services and the replicas this node's rules depend on, `mesh_plan.input_for`), plans it as the
//! server would (`mesh_plan.plan`) and sends each running local replica its rules
//! (`mesh_plan.rules_of`) when they differ from the last it sent that replica. A replica that
//! starts is given its port and the rules of the step's plan in `Spec.mesh`.
//!
//! The mesh is on only when the agent has both a port range and a node address (`Config`) and
//! the step has a way to read the view (`Source`). The simulator has neither, so its worlds do
//! not change.
//!
//! A failed read of the view never holds replica work back: it is noted (`note_enforce_failure`)
//! and the step's replicas start with empty rules, which the next step that reads the view
//! replaces. Rules are sent whole; the supervisor applies the difference.

const std = @import("std");
const assert = std.debug.assert;
const agent_mod = @import("agent.zig");
const agent_records = @import("agent_records.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const mesh_plan = @import("mesh_plan.zig");
const runtime = @import("runtime.zig");
const store = @import("store.zig");

const Agent = agent_mod.Agent;
const Context = agent_mod.Context;
const Error = agent_mod.Error;
const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

/// The label that holds a replica container's mesh port (decimal): the port stays the
/// container's across an agent restart, and the agent gives no other replica a port in use.
pub const label_port = "zcube.mesh-port";

/// Where the node takes mesh connections: the host of the address it advertises for C2's chunk
/// server (borrowed) and the range of ports it hands its replicas (`--mesh-ports A-B`).
pub const Config = struct {
    host: []const u8,
    ports_first: u16 = constants.mesh_ports_default_first,
    ports_last: u16 = constants.mesh_ports_default_last,
};

/// How a step reads the node's view of the mesh: `RemoteStore.mesh_fetch_fn` in the agent.
pub const Source = struct {
    context: *anyopaque,
    fetch_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) store.Error!mesh_plan.Input,
};

/// The hash of the rules last sent to each replica (by the Wyhash of its id), as a ring: a
/// replica that falls out of it is sent its rules again, which the supervisor takes as the same.
/// In memory only, so a restarted agent sends every replica its rules once.
pub const Sent = struct {
    entries: [constants.agent_node_replicas_max]Entry = undefined,
    count: u32 = 0,
    next: u32 = 0,

    const Entry = struct { replica: u64, rules: u64 };

    pub fn same(sent: *const Sent, replica: []const u8, rules: u64) bool {
        const key = std.hash.Wyhash.hash(0, replica);
        for (sent.entries[0..sent.count]) |entry| {
            if (entry.replica == key) return entry.rules == rules;
        }
        return false;
    }

    pub fn note(sent: *Sent, replica: []const u8, rules: u64) void {
        const key = std.hash.Wyhash.hash(0, replica);
        for (sent.entries[0..sent.count]) |*entry| {
            if (entry.replica != key) continue;
            entry.rules = rules;
            return;
        }
        assert(sent.next < sent.entries.len);
        sent.entries[sent.next] = .{ .replica = key, .rules = rules };
        sent.next = (sent.next + 1) % @as(u32, @intCast(sent.entries.len));
        sent.count = @min(sent.count + 1, @as(u32, @intCast(sent.entries.len)));
    }
};

/// Whether this step gives replicas a mesh at all.
pub fn enabled(agent: *const Agent, ctx: *const Context) bool {
    return agent.config.mesh != null and ctx.mesh != null;
}

/// This step's plan for the node, or null: no mesh, or the view could not be read (noted).
pub fn plan_now(agent: *Agent, ctx: *const Context) Error!?mesh_plan.Plan {
    if (!enabled(agent, ctx)) return null;
    const source = ctx.mesh.?;
    const input = source.fetch_fn(source.context, ctx.arena, ctx.diag) catch {
        agent.note_enforce_failure(ctx, "read the node's mesh view");
        return null;
    };
    return mesh_plan.plan(ctx.arena, &input, agent.config.node) catch
        return failures.no_memory(ctx.diag);
}

/// The rules `replica` is handed under `plan`; empty without one.
pub fn rules_for(
    ctx: *const Context,
    plan: ?*const mesh_plan.Plan,
    replica: []const u8,
) Error!runtime.MeshRules {
    const known = plan orelse return .{};
    return mesh_plan.rules_of(ctx.arena, known, replica) catch failures.no_memory(ctx.diag);
}

/// The lowest port of the range that no container of this node is labelled with and `taken`
/// (given earlier in this step) does not hold; null when every one is.
pub fn free_port(
    config: Config,
    listings: []const runtime.Listing,
    taken: []const u16,
) ?u16 {
    assert(config.ports_first > 0);
    assert(config.ports_first <= config.ports_last);
    var port: u32 = config.ports_first;
    next: while (port <= config.ports_last) : (port += 1) {
        for (taken) |held| {
            if (held == port) continue :next;
        }
        for (listings) |*listing| {
            const held = port_of(listing) orelse continue;
            if (held == port) continue :next;
        }
        return @intCast(port);
    }
    return null;
}

/// The mesh port a container is labelled with, if any.
pub fn port_of(listing: *const runtime.Listing) ?u16 {
    const text = agent_mod.label_value(listing.labels, label_port) orelse return null;
    const port = std.fmt.parseInt(u16, text, 10) catch return null;
    if (port == 0) return null;
    return port;
}

/// `<host>:<port>`, the endpoint a replica on this node publishes in `/observed`.
pub fn endpoint_text(agent: *const Agent, ctx: *const Context, port: u16) Error![]const u8 {
    const config = agent.config.mesh.?;
    return std.fmt.allocPrint(ctx.arena, "{s}:{d}", .{ config.host, port }) catch
        failures.no_memory(ctx.diag);
}

/// The start failure of a replica the range has no port for (ZC-E0710).
pub fn no_port_failure(agent: *const Agent, ctx: *const Context) Error!Diagnostic {
    const config = agent.config.mesh.?;
    const cause = std.fmt.allocPrint(
        ctx.arena,
        "every port of the mesh range {d}-{d} is given to a container of this node",
        .{ config.ports_first, config.ports_last },
    ) catch return failures.no_memory(ctx.diag);
    const failure: agent_records.RunFile = .{
        .kind = .start_failed,
        .cause = cause,
        .blame = .mesh,
    };
    return agent_records.start_failure("", failure);
}

/// What a replica that starts is given: its port (and the label text that keeps it), the rules
/// of the step's plan, and the endpoint it publishes.
pub const Start = struct {
    port: u16,
    label: []const u8,
    rules: runtime.MeshRules,
    endpoint: []const u8,
};

pub const Given = union(enum) { none, no_port, given: Start };

/// The mesh of a replica that starts in this step: none without a mesh, `no_port` when the range
/// is spent (a start failure, ZC-E0710), else a port, kept in `taken` for the rest of the step.
pub fn for_start(
    agent: *const Agent,
    ctx: *const Context,
    listings: []const runtime.Listing,
    plan: ?*const mesh_plan.Plan,
    taken: *std.ArrayList(u16),
    replica: []const u8,
) Error!Given {
    if (!enabled(agent, ctx)) return .none;
    const config = agent.config.mesh.?;
    const port = free_port(config, listings, taken.items) orelse return .no_port;
    taken.append(ctx.arena, port) catch return failures.no_memory(ctx.diag);
    const label = std.fmt.allocPrint(ctx.arena, "{d}", .{port}) catch
        return failures.no_memory(ctx.diag);
    return .{ .given = .{
        .port = port,
        .label = label,
        .rules = try rules_for(ctx, plan, replica),
        .endpoint = try endpoint_text(agent, ctx, port),
    } };
}

/// Sends each running replica container that has a mesh port its rules under `plan`, if they
/// differ from the last sent. A runtime that cannot take them is noted, and they are sent again
/// next step. Returns how many were sent.
pub fn update(
    agent: *Agent,
    ctx: *const Context,
    listings: []const runtime.Listing,
    plan: *const mesh_plan.Plan,
) Error!u32 {
    var sent: u32 = 0;
    for (listings) |*listing| {
        if (!agent_mod.is_running(listing)) continue;
        if (port_of(listing) == null) continue;
        const replica = agent_mod.label_value(listing.labels, runtime.label_replica) orelse
            continue;
        const rules = try rules_for(ctx, plan, replica);
        const hash = runtime.mesh_rules_hash(&rules);
        if (agent.mesh_sent.same(replica, hash)) continue;
        // The runtime's failures only (`RuntimeFailed`, `NotFound`): noted, and sent next step.
        ctx.runtime.mesh_update(listing.handle, &rules, ctx.diag) catch {
            agent.note_enforce_failure(ctx, "send a replica its mesh rules");
            continue;
        };
        agent.mesh_sent.note(replica, hash);
        sent += 1;
    }
    return sent;
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "agent mesh: the ring remembers the last rules per replica and forgets the oldest" {
    var sent: Sent = .{};
    try testing.expect(!sent.same("a", 1));
    sent.note("a", 1);
    try testing.expect(sent.same("a", 1));
    try testing.expect(!sent.same("a", 2));
    sent.note("a", 2);
    try testing.expect(sent.same("a", 2));
    try testing.expectEqual(@as(u32, 1), sent.count);
    var name: [16]u8 = undefined;
    for (0..sent.entries.len) |index| {
        // Sized for every index: 16 bytes hold "r" and any usize.
        sent.note(std.fmt.bufPrint(&name, "r{d}", .{index}) catch unreachable, 7);
    }
    try testing.expect(!sent.same("a", 2)); // The oldest fell out: sent again, harmlessly.
}

test "agent mesh: a free port is the lowest no container holds and the step has not given" {
    const config: Config = .{ .host = "10.0.0.1", .ports_first = 30_000, .ports_last = 30_002 };
    const held = [_]runtime.Label{.{ .key = label_port, .value = "30000" }};
    var listing: runtime.Listing = undefined;
    listing.labels = &held;
    const listings = [_]runtime.Listing{listing};
    try testing.expectEqual(@as(?u16, 30_001), free_port(config, &listings, &.{}));
    try testing.expectEqual(@as(?u16, 30_002), free_port(config, &listings, &.{30_001}));
    try testing.expectEqual(@as(?u16, null), free_port(config, &listings, &.{ 30_001, 30_002 }));
    try testing.expectEqual(@as(?u16, 30_000), free_port(config, &.{}, &.{}));
}
