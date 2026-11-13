//! HANDOFF's four steps of the C1 demo (`demo_c1.zig` runs them in order): three agents join,
//! `hello` with 6 replicas spreads two per node, a powered-off node's replicas are replaced on the
//! survivors, and the restarted node rejoins empty and `zcube why node` says why nothing moved
//! back. Each step asserts its outcome and prints what it did.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const fleet_mod = @import("demo_c1_fleet.zig");
const state = @import("demo_c1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const lost_index = fleet_mod.powered_off;
const lost_name = fleet_mod.names[lost_index];

// ---- 1 ----

/// Every node is registered and judged `ready` for its current registration.
fn all_ready(_: *Demo, host: *Host) !bool {
    const rows = (try state.node_rows(host)) orelse return false;
    if (rows.len != fleet_mod.count) return false;
    for (rows) |row| {
        if (!row.is_ready()) return false;
    }
    return true;
}

pub fn join(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. three agents join: zcube get nodes");
    try host.wait_for(demo, all_ready, "three nodes to be ready", state.start_wait_ms);
    const get = try host.zcube(&.{ "get", "nodes" });
    try host.check(get.code == 0, "zcube get nodes exits 0", .{});
    const rows = try state.need_nodes(host);
    assert(rows.len == fleet_mod.count);
    for (fleet_mod.names, 0..) |name, index| {
        const row = state.find_node(rows, name) orelse return host.fail("{s} not listed", .{name});
        const capacity = row.cpu_millis == 4000 and row.memory_bytes == 8 * 1024 * 1024 * 1024;
        try host.check(capacity, "{s} is ready with capacity 4000m / 8.0Gi", .{name});
        try host.check(row.ttl_ms == state.ttl_ms, "{s}'s lease has a ttl of {d} ms", .{
            name, state.ttl_ms,
        });
        demo.tenures[index] = try state.need_tenure(host, row);
    }
    try host.check(state.contains(get.out, "4000m / 8.0Gi"), "the table shows 4000m / 8.0Gi", .{});
    try host.check(state.contains(get.out, "s/9s"), "the table shows leases of 9s", .{});
}

// ---- 2 ----

/// `hello` has 6 replicas that all run, two on each node.
fn six_spread(host: *Host, _: *Host) !bool {
    const rows = (try state.replica_rows(host, "hello")) orelse return false;
    if (!state.all_running(rows, 6)) return false;
    for (fleet_mod.names) |name| {
        if (state.on_node(rows, name, "running") != 2) return false;
    }
    return true;
}

pub fn apply(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. zcube apply hello.zon, replicas = 6: two per node");
    try state.write_service(host, "hello", 6);
    const applied = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try host.check(
        applied.code == 0 and state.contains(applied.out, "applied service hello: created"),
        "applied service hello: created",
        .{},
    );
    try host.wait_for(host, six_spread, "6 replicas, two per node, to run", state.converge_ms);
    const wide = try host.zcube(&.{ "get", "replicas", "hello", "-o", "wide" });
    for (fleet_mod.names) |name| {
        const running = state.wide_rows(wide.out, "hello", name, "running");
        try host.check(running == 2, "zcube get replicas -o wide: 2 running on {s}", .{name});
    }
    try state.expect_placement(demo, "the host", .{ 2, 2, 2 });
}

// ---- 3 ----

/// `hello` runs 6 replicas on the survivors, and the old ones are gone.
const Replaced = struct {
    demo: *Demo,
    gone: []const []const u8,
};

fn replaced(ctx: Replaced, host: *Host) !bool {
    const rows = (try state.replica_rows(host, "hello")) orelse return false;
    if (!state.all_running(rows, 6)) return false;
    for (ctx.gone) |id| {
        if (state.c0.has_id(rows, id)) return false;
    }
    return state.on_node(rows, lost_name, "running") == 0;
}

fn node_is_lost(_: void, host: *Host) !bool {
    const rows = (try state.node_rows(host)) orelse return false;
    const row = state.find_node(rows, lost_name) orelse return false;
    return row.is_lost();
}

pub fn power_off(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. power off node3: its replicas are replaced on the survivors");
    const before = try state.running_everywhere(demo.fleet, host.arena());
    const doomed = try names_on(host, before, lost_index);
    assert(before.len == 6);
    assert(doomed.len == 2);
    host.say("$ kill -9 the agent of {s} and its {d} supervisors' groups   # demo/kill-node.sh", .{
        lost_name, doomed.len,
    });
    const started = host.now_ms();
    try demo.fleet.power_off(lost_index);
    // A killed process disappears a moment later.
    try host.io.sleep(.fromMilliseconds(500), .awake);
    for (before) |placed| {
        if (placed.node != lost_index) continue;
        const alive = demo.fleet.procs(lost_index).alive(placed.pids.command);
        try host.check_quiet(!alive, "{s} is alive", .{placed.pids.name()});
    }
    try host.check(true, "the agent and the {d} replicas of {s} are dead", .{
        doomed.len, lost_name,
    });
    try host.wait_for({}, node_is_lost, "node3 to read lost", state.failover_ms);
    const lost_after = host.now_ms() - started;
    // The last keepalive was sent at most ttl/3 (+ the agent's 1 s pass) before the kill, and the
    // server declares the loss at the expiry, so it cannot come much sooner than ttl - that.
    const early_ms: u64 = state.ttl_ms - state.ttl_ms / 3 - 1_000 - state.tolerance_ms;
    const late_ms: u64 = state.ttl_ms + state.tolerance_ms + 2_000;
    const lost_in_time = lost_after >= early_ms and lost_after <= late_ms;
    try host.check(lost_in_time, "{s} read lost {d} ms after the power-off (the lease timeout " ++
        "is {d} ms: expected {d}..{d} ms, the controllers' pass included)", .{
        lost_name, lost_after, state.ttl_ms, early_ms, late_ms,
    });
    const swapped: Replaced = .{ .demo = demo, .gone = doomed };
    try host.wait_for(swapped, replaced, "the replicas to be replaced", state.failover_ms);
    const done_after = host.now_ms() - started;
    try host.check(done_after <= state.failover_ms, "6 replicas run again {d} ms after the " ++
        "power-off (bound: lease timeout {d} + lost grace {d} + 5000 ms)", .{
        done_after, state.ttl_ms, constants.lost_grace_ms,
    });
    try expect_survivors(demo, before, doomed);
    try expect_printed(demo);
}

/// The names of the containers that run on node `index`.
fn names_on(host: *Host, list: []const state.Placed, index: usize) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (list) |placed| {
        if (placed.node != index) continue;
        try found.append(host.arena(), try host.arena().dupe(u8, placed.pids.name()));
    }
    return found.items;
}

/// The survivors' four original commands are the same processes; two new ones joined them;
/// nothing runs on the lost node; `zcube get` shows the same.
fn expect_survivors(demo: *Demo, before: []const state.Placed, doomed: []const []const u8) !void {
    const host = demo.host;
    assert(doomed.len == 2);
    const now = try state.running_everywhere(demo.fleet, host.arena());
    assert(now.len <= 6);
    for (before) |placed| {
        if (placed.node == lost_index) continue;
        const name = placed.pids.name();
        var same = false;
        for (now) |current| {
            same = same or (std.mem.eql(u8, current.pids.name(), name) and
                current.pids.command == placed.pids.command);
        }
        try host.check_quiet(same, "{s} was restarted or moved", .{name});
    }
    try host.check(true, "the four commands of the survivors are the same processes", .{});
    for (doomed) |name| {
        try host.check_quiet(!state.has_container(now, name), "{s} runs", .{name});
    }
    try state.expect_placement(demo, "after the failover", .{ 3, 3, 0 });
    const wide = try host.zcube(&.{ "get", "replicas", "hello", "-o", "wide" });
    try host.check(wide.code == 0, "zcube get replicas -o wide exits 0", .{});
    for (doomed) |name| {
        try host.check_quiet(!state.contains(wide.out, name), "{s} still listed", .{name});
    }
    try host.check(true, "the replicas of {s} are replaced under new ids (not {s})", .{
        lost_name, try std.mem.join(host.arena(), ", ", doomed),
    });
}

/// "Lease timeout is configurable and printed at failover": `zcube why node` says it, and the
/// `mark_lost` decision in the store carries it (`ttl_ms`) with when the server last heard.
fn expect_printed(demo: *Demo) !void {
    const host = demo.host;
    const why = try host.zcube(&.{ "why", "node", lost_name });
    try host.check(why.code == 0, "zcube why node {s} exits 0", .{lost_name});
    const ttl = "(ttl 9000 ms) ran out";
    const timeout_shown = state.contains(why.out, ttl);
    try host.check(timeout_shown, "it prints the lease timeout: \"" ++ ttl ++ "\"", .{});
    const heard = "the server last heard from it ";
    const at = std.mem.find(u8, why.out, heard) orelse {
        return host.fail("zcube why node {s} does not say when it last heard", .{lost_name});
    };
    const ago = leading_number(why.out[at + heard.len ..]) orelse {
        return host.fail("the time last heard is not a number: {s}", .{why.out[at..]});
    };
    const lower: u64 = state.ttl_ms;
    const upper: u64 = state.ttl_ms + state.tolerance_ms + 2_000;
    try host.check(ago >= lower and ago <= upper, "it prints that the server last heard from " ++
        "it {d} ms ago (the lease ran out, so at least {d}; at most {d})", .{ ago, lower, upper });
    const decision = "node node3 is lost: its lease";
    try host.check(state.contains(why.out, decision), "...in the node controller's decision", .{});
    try expect_mark_lost(host);
    _ = try host.zcube(&.{ "get", "nodes" });
}

/// The digits at the start of `text`, or null.
fn leading_number(text: []const u8) ?u64 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, text[0..end], 10) catch null;
}

/// The store holds one `mark_lost` decision for the lost node: cause `lease_expired`, evidence
/// with the ttl the server was started with and when it last heard (`last_heard_ms`, present).
fn expect_mark_lost(host: *Host) !void {
    const listed = try host.json("/v1/list?prefix=/decisions/&limit=500");
    const kvs = listed.object.get("kvs") orelse return host.fail("no decisions listed", .{});
    var found: u32 = 0;
    for (kvs.array.items) |kv| {
        const value = (kv.object.get("value") orelse continue).object;
        const action = value.get("action") orelse continue;
        const subject = (value.get("subject") orelse continue).object;
        const name = subject.get("name") orelse continue;
        if (!std.mem.eql(u8, action.string, "mark_lost")) continue;
        if (!std.mem.eql(u8, name.string, lost_name)) continue;
        found += 1;
        const cause = (value.get("cause") orelse continue).object;
        const kind = (cause.get("kind") orelse continue).string;
        try host.check(std.mem.eql(u8, kind, "lease_expired"), "mark_lost's cause is {s}", .{kind});
        const evidence = (value.get("cause_evidence") orelse {
            return host.fail("mark_lost carries no evidence", .{});
        }).object;
        const ttl = evidence.get("ttl_ms") orelse return host.fail("no ttl_ms in evidence", .{});
        const heard = evidence.get("last_heard_ms") orelse {
            return host.fail("no last_heard_ms in evidence", .{});
        };
        try host.check(ttl == .integer and ttl.integer == state.ttl_ms, "mark_lost's evidence " ++
            "has ttl_ms {d}", .{state.ttl_ms});
        try host.check(heard == .integer, "mark_lost's evidence has last_heard_ms", .{});
    }
    try host.check(found == 1, "one mark_lost decision for {s} ({d})", .{ lost_name, found });
}

// ---- 4 ----

fn rejoined(demo: *Demo, host: *Host) !bool {
    const rows = (try state.node_rows(host)) orelse return false;
    const row = state.find_node(rows, lost_name) orelse return false;
    return row.is_ready() and row.tenure.? > demo.tenures[lost_index];
}

pub fn restart(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. restart node3: it rejoins empty, and nothing moves back");
    const before = try state.need_replicas(host, "hello");
    assert(before.len == 6);
    try demo.fleet.start_agent(lost_index);
    try host.wait_for(demo, rejoined, "node3 to rejoin under a new tenure", state.start_wait_ms);
    const row = try state.need_node(host, lost_name);
    const tenure = try state.need_tenure(host, row);
    try host.check(tenure > demo.tenures[lost_index], "{s} registered under a new tenure " ++
        "({d}, was {d})", .{ lost_name, tenure, demo.tenures[lost_index] });
    demo.tenures[lost_index] = tenure;
    try host.settle("nothing may move back", state.settle_ms);
    const after = try state.need_replicas(host, "hello");
    const same = rows_equal(before, after);
    try host.check(same, "no replica moved: the same 6 ids on the same nodes", .{});
    const now = try state.running_everywhere(demo.fleet, host.arena());
    try host.check(state.running_on(now, lost_index) == 0, "{s} runs nothing: it rejoined empty", .{
        lost_name,
    });
    const node_row = try state.need_node(host, lost_name);
    try host.check(node_row.count == 0, "zcube get nodes: {s} has 0 assigned", .{lost_name});
    try expect_explained(demo);
}

fn rows_equal(left: []const state.Row, right: []const state.Row) bool {
    if (left.len != right.len) return false;
    for (left) |row| {
        var found = false;
        for (right) |other| {
            const same_id = std.mem.eql(u8, row.id, other.id);
            found = found or (same_id and std.mem.eql(u8, row.node, other.node));
        }
        if (!found) return false;
    }
    return true;
}

fn expect_explained(demo: *Demo) !void {
    const host = demo.host;
    _ = try host.zcube(&.{ "get", "nodes" });
    const why = try host.zcube(&.{ "why", "node", lost_name });
    try host.check(why.code == 0, "zcube why node {s} exits 0", .{lost_name});
    const heading = "node node3: ready";
    try host.check(state.contains(why.out, heading), "it says the node is ready", .{});
    const again = state.contains(why.out, "registered again");
    try host.check(again, "it says the node registered again", .{});
    const reason = "are not moved back";
    const stays = state.contains(why.out, reason);
    try host.check(stays, "it says why nothing moved back (no rebalancing)", .{});
}
