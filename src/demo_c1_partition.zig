//! The partition test of `demo-c1` (c1.md, "The partition test"; HANDOFF's second acceptance
//! criterion): `node1`'s agent is alive and cannot reach the server, because its `--server` is a
//! local TCP proxy that the demo makes drop traffic in both directions. Asserted from process
//! facts on the host, polled every `poll_ms`:
//!
//!   * every command of `node1` is dead by `P + ttl - fence_margin + fence_stop + kill latency`,
//!     where `P` is the moment the proxy dropped traffic (`s`, the send time of the last
//!     acknowledged keepalive, is at or before `P`, so the bound is sound, if weaker);
//!   * no replacement starts before the server's expiry of the lease plus `lost_grace_ms`
//!     (the expiry is read from the lease after the partition took hold, when no keepalive can
//!     land any more);
//!   * there is no poll at which a command of the old instance and a replacement both run, and
//!     the last old command died before the first replacement was seen;
//!   * after the heal, the agent registers again under a new tenure, empty, prints `ZC-W0501`,
//!     and a late observed write under the old tenure is refused (`503`, `ZC-E0510`, I2).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const fleet_mod = @import("demo_c1_fleet.zig");
const host_procs = @import("host_procs.zig");
const state = @import("demo_c1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const index = fleet_mod.proxied;
const node = fleet_mod.names[index];
/// How often the host's processes are looked at while the partition lasts.
const watch_poll_ms: i64 = 25;
/// The partition has taken hold this long after the proxy was told to drop traffic.
const take_hold_ms: i64 = 200;
const old_max: usize = 8;

/// What the poll loop saw: when each old command was first seen dead, when each replacement was
/// first seen running, and how many polls saw both generations alive at once.
const Watch = struct {
    old: []const host_procs.Pids,
    before: []const state.Placed,
    died_ms: [old_max]u64 = @splat(0),
    new_names: [old_max][]const u8 = undefined,
    new_ms: [old_max]u64 = @splat(0),
    new_count: u32 = 0,
    overlaps: u32 = 0,
    polls: u32 = 0,
};

fn look(watch: *Watch, demo: *Demo, now_ms: u64) !void {
    const procs = demo.fleet.procs(index);
    var old_alive: usize = 0;
    for (watch.old, 0..) |pids, at| {
        if (procs.alive(pids.command)) {
            old_alive += 1;
        } else if (watch.died_ms[at] == 0) {
            watch.died_ms[at] = now_ms;
        }
    }
    const now = try state.running_everywhere(demo.fleet, demo.host.arena());
    var fresh: usize = 0;
    for (now) |placed| {
        if (placed.node == index) continue;
        const name = placed.pids.name();
        if (state.has_container(watch.before, name)) continue;
        fresh += 1;
        var known = false;
        for (watch.new_names[0..watch.new_count]) |seen| {
            known = known or std.mem.eql(u8, seen, name);
        }
        if (known or watch.new_count == old_max) continue;
        watch.new_names[watch.new_count] = try demo.host.arena().dupe(u8, name);
        watch.new_ms[watch.new_count] = now_ms;
        watch.new_count += 1;
    }
    watch.polls += 1;
    if (old_alive > 0 and fresh > 0) watch.overlaps += 1;
}

fn finished(watch: *const Watch) bool {
    for (watch.died_ms[0..watch.old.len]) |died| {
        if (died == 0) return false;
    }
    return watch.new_count >= watch.old.len;
}

pub fn run(demo: *Demo) !void {
    const host = demo.host;
    const fleet = demo.fleet;
    host.section("5. partition node1: the agent is alive, the server unreachable");
    assert(fleet.proxy != null);
    const before = try state.running_everywhere(fleet, host.arena());
    const old = try fleet.procs(index).running_containers();
    const alive = old.len == 3 and fleet.agent_alive(index);
    try host.check(alive, "{s}'s agent is alive and runs {d} replicas before the partition", .{
        node, old.len,
    });
    fleet.proxy.?.partition();
    const cut_ms = host.now_ms();
    host.say("  the proxy in front of {s}'s agent drops traffic in both directions", .{node});
    try host.io.sleep(.fromMilliseconds(take_hold_ms), .awake);
    const expiry_ms = try lease_expiry(demo);
    var watch: Watch = .{ .old = old, .before = before };
    while (host.now_ms() - cut_ms < state.partition_ms and !finished(&watch)) {
        try look(&watch, demo, host.now_ms());
        try host.io.sleep(.fromMilliseconds(watch_poll_ms), .awake);
    }
    const fenced = "{s}'s agent is still alive: it was fenced, not killed";
    try host.check(fleet.agent_alive(index), fenced, .{node});
    try expect_timing(host, &watch, cut_ms, expiry_ms);
    try expect_replaced(demo, old);
    try heal(demo, old);
}

/// The server's expiry of node1's lease, on the demo's clock: the remaining time of the lease as
/// `zcube get nodes` reads it, added to the moment of the read.
fn lease_expiry(demo: *Demo) !u64 {
    const host = demo.host;
    const rows = (try state.node_rows(host)).?;
    const row = state.find_node(rows, node).?;
    const remaining = row.remaining_ms orelse return host.fail("{s} has no lease", .{node});
    const expiry = host.now_ms() + @as(u64, @intCast(remaining));
    host.say("  the server's lease of {s} runs out in {d} ms (ttl {d} ms)", .{
        node, remaining, state.ttl_ms,
    });
    return expiry;
}

fn expect_timing(host: *Host, watch: *const Watch, cut_ms: u64, expiry_ms: u64) !void {
    var last_death: u64 = 0;
    for (watch.died_ms[0..watch.old.len]) |died| {
        try host.check_quiet(died != 0, "a command of {s} still runs", .{node});
        last_death = @max(last_death, died);
    }
    const stopped_after = last_death - cut_ms;
    const in_time = stopped_after <= state.stop_bound_ms + state.tolerance_ms;
    try host.check(in_time, "the agent stopped " ++
        "all {d} containers {d} ms after the cut (bound: ttl {d} - margin {d} + stop {d} + kill " ++
        "{d} = {d} ms)", .{
        watch.old.len,             stopped_after,           state.ttl_ms,
        constants.fence_margin_ms, constants.fence_stop_ms, constants.fence_kill_latency_ms,
        state.stop_bound_ms,
    });
    try host.check_quiet(watch.new_count == watch.old.len, "only {d} replacements ran", .{
        watch.new_count,
    });
    var first_new: u64 = std.math.maxInt(u64);
    for (watch.new_ms[0..watch.new_count]) |started| first_new = @min(first_new, started);
    const grace_ms: u64 = constants.lost_grace_ms;
    const floor = expiry_ms + grace_ms;
    try host.check(first_new + state.tolerance_ms >= floor, "the first replacement ran {d} ms " ++
        "after the server's expiry (no earlier than lost_grace_ms = {d} ms)", .{
        @as(i64, @intCast(first_new)) - @as(i64, @intCast(expiry_ms)), grace_ms,
    });
    try host.check(last_death <= first_new, "the old instance was dead {d} ms before the first " ++
        "replacement ran", .{first_new - last_death});
    try host.check(watch.overlaps == 0, "no overlap: in {d} polls, no old command and " ++
        "replacement ran together", .{watch.polls});
}

/// The replicas were replaced under new ids on the other nodes, and `zcube get` says so.
fn expect_replaced(demo: *Demo, old: []const host_procs.Pids) !void {
    const host = demo.host;
    const rows = (try state.replica_rows(host, "hello")) orelse {
        return host.fail("no replicas", .{});
    };
    const moved = state.all_running(rows, 6) and state.on_node(rows, node, "running") == 0;
    try host.check(moved, "zcube get replicas: 6 running, none on {s}", .{node});
    for (old) |pids| {
        const listed = state.c0.has_id(rows, pids.name());
        try host.check_quiet(!listed, "{s} is still listed", .{pids.name()});
    }
    try state.expect_placement(demo, "after the partition", .{ 0, 3, 3 });
    const nodes = (try state.node_rows(host)).?;
    const row = state.find_node(nodes, node).?;
    try host.check(row.is_lost(), "zcube get nodes: {s} is lost", .{node});
}

fn rejoined(demo: *Demo, host: *Host) !bool {
    const rows = (try state.node_rows(host)) orelse return false;
    const row = state.find_node(rows, node) orelse return false;
    return row.is_ready() and row.tenure.? > demo.tenures[index];
}

/// The heal: connections are reset first so that nothing held back is delivered late, then the
/// proxy forwards again. The agent registers anew; a late write under the old tenure is refused.
fn heal(demo: *Demo, old: []const host_procs.Pids) !void {
    const host = demo.host;
    const old_tenure = demo.tenures[index];
    host.say("  the partition ends: the proxy resets its connections and forwards again", .{});
    demo.fleet.proxy.?.cut_all();
    demo.fleet.proxy.?.heal();
    const what = "node1 to register again under a new tenure";
    try host.wait_for(demo, rejoined, what, state.start_wait_ms);
    const row = state.find_node((try state.node_rows(host)).?, node).?;
    try host.check(row.tenure.? > old_tenure, "{s} registered again under tenure {d} (was {d})", .{
        node, row.tenure.?, old_tenure,
    });
    demo.tenures[index] = row.tenure.?;
    const log = try demo.fleet.agent_log(index);
    const warning = "warning[ZC-W0501]: the agent fenced itself and registered again";
    try host.check(state.contains(log, warning), "the agent printed {s}", .{warning});
    const now = try state.running_everywhere(demo.fleet, host.arena());
    try host.check(state.running_on(now, index) == 0 and row.count == 0, "{s} rejoined empty: " ++
        "no container, no replica assigned", .{node});
    try late_write(demo, old_tenure, old[0].name());
}

/// I2: an observed write under the tenure that ended is refused, and nothing is written.
fn late_write(demo: *Demo, old_tenure: i64, replica: []const u8) !void {
    const host = demo.host;
    const body = try std.fmt.allocPrint(
        host.arena(),
        "{{\"tenure\":{d},\"puts\":[],\"deletes\":[\"/observed/{s}/{s}\"]}}",
        .{ old_tenure, node, replica },
    );
    const path = "/v1/agent/nodes/" ++ node ++ "/observed";
    const reply = try host.call("POST", path, body);
    host.say("$ POST {s}   # a late write under tenure {d}, which ended", .{ path, old_tenure });
    const refused = reply.status == 503 and state.contains(reply.body, "ZC-E0510");
    try host.check(refused, "refused: 503 ZC-E0510 (I2); the server answered {d}", .{reply.status});
    _ = try host.zcube(&.{ "get", "nodes" });
}
