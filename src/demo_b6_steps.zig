//! The steps of `demo-b6` (docs/demos/b6.md says what each asserts): three nodes of 1000m,
//! `node1` `tenant=a`, `node2` `tenant=a exclusive=tenant`, `node3` `tenant=b`; jobs of 250m
//! posted with and without `placement.require`, one node powered off under its job.

const std = @import("std");
const fleet_mod = @import("demo_b6_fleet.zig");
const state = @import("demo_b6_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const node1: usize = 0;
const node2: usize = 1;
const node3: usize = 2;

/// The jobs that require `tenant=a`; none may ever be on `node3`.
const a_jobs = [_][]const u8{ "a1", "a2", "a3" };
/// The jobs with no placement; none may ever be on `node2`.
const open_jobs = [_][]const u8{ "n1", "n2", "n3" };

// ---- 0. Labels refused, and labels registered ----

/// Runs `zcube-agent <args>`, shown; the agent must refuse its configuration with ZC-E0505.
pub fn refused(host: *Host, args: []const []const u8, comptime what: []const u8) !void {
    const argv = try host.arena().alloc([]const u8, args.len + 1);
    argv[0] = host.config.agent_exe;
    @memcpy(argv[1..], args);
    host.say("$ zcube-agent {s}", .{try std.mem.join(host.arena(), " ", args)});
    const result = std.process.run(host.arena(), host.io, .{
        .argv = argv,
        .cwd = .{ .path = host.work },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } },
    }) catch |err| return host.fail("zcube-agent did not finish: {s}", .{@errorName(err)});
    host.out(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |value| value,
        else => 255,
    };
    try host.check(code != 0 and state.contains(result.stderr, "ZC-E0505"), "zcube-agent " ++
        "refuses " ++ what ++ " (ZC-E0505, exit {d})", .{code});
}

pub fn labels_refused(demo: *Demo) !void {
    const host = demo.host;
    host.section("0a. node labels the agent refuses before it starts");
    const file = try host.path_in_work("conflict.zon");
    try std.Io.Dir.cwd().writeFile(host.io, .{
        .sub_path = file,
        .data = ".{ .labels = .{\"tenant=b\"} }\n",
    });
    const base = [_][]const u8{
        "--node",         "nodex",      "--server",     "127.0.0.1:1",
        "--state-dir",    host.state,   "--cpu-millis", "1000",
        "--memory-bytes", "8589934592",
    };
    var conflict: std.ArrayList([]const u8) = .empty;
    try conflict.appendSlice(host.arena(), &base);
    try conflict.appendSlice(host.arena(), &.{ "--config", file, "--label", "tenant=a" });
    try refused(host, conflict.items, "labels given by --label and by its file that differ");
    var orphan: std.ArrayList([]const u8) = .empty;
    try orphan.appendSlice(host.arena(), &base);
    try orphan.appendSlice(host.arena(), &.{ "--label", "exclusive=tenant" });
    try refused(host, orphan.items, "exclusive=tenant on a node without a tenant label");
}

pub fn labels_registered(demo: *Demo) !void {
    const host = demo.host;
    host.section("0c. the labels the three nodes registered");
    for (fleet_mod.names, fleet_mod.labels, 0..) |name, labels, index| {
        const how: []const u8 = if (index == fleet_mod.configured)
            "by .labels in node3.zon (--config)"
        else
            "by --label";
        host.say("  {s}: {s}, given {s}", .{ name, labels, how });
    }
    host.say("$ curl /v1/list?prefix=/nodes/   # zcube get nodes does not show labels", .{});
    const lines = try state.node_labels(host);
    for (lines) |line| host.say("  {s}", .{line});
    try host.check(lines.len == fleet_mod.count, "the store holds {d} nodes", .{lines.len});
    for (lines, fleet_mod.names, fleet_mod.labels) |line, name, labels| {
        const want = try std.fmt.allocPrint(host.arena(), "{s} {s}", .{ name, labels });
        try host.check(std.mem.eql(u8, line, want), "{s} registered with {s}", .{ name, labels });
    }
}

// ---- 1-3. Where jobs land ----

pub fn tenant_jobs(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. jobs for tenant a land only on tenant=a nodes; b's on the b node");
    var used: [fleet_mod.count]bool = @splat(false);
    for (a_jobs[0..2]) |name| {
        try state.post(host, name, 250, "a");
        const index = try state.wait_running(demo, name);
        used[index] = true;
        try host.check(index == node1 or index == node2, "{s} runs on {s}, a tenant=a node", .{
            name, fleet_mod.names[index],
        });
    }
    try host.check(used[node1] and used[node2], "both tenant=a nodes took one, the exclusive " ++
        "node2 included", .{});
    try state.post(host, "b1", 250, "b");
    const index = try state.wait_running(demo, "b1");
    try host.check(index == node3, "b1 runs on {s}, the tenant=b node", .{fleet_mod.names[index]});
}

pub fn open_jobs_avoid_exclusive(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. jobs with no placement never land on the exclusive node2");
    try host.check(try state.running_on(demo, node2) == 1, "node2 runs one of a1 and " ++
        "a2, and nothing else", .{});
    for (open_jobs) |name| {
        try state.post(host, name, 250, null);
        const index = try state.wait_running(demo, name);
        try host.check(index != node2, "{s} runs on {s}, not on node2", .{
            name, fleet_mod.names[index],
        });
    }
    try only_exclusive_fits(demo);
}

/// node1 (a1, two of the n jobs: 750m) and node3 (b1 and the third: 500m) lack the room for
/// 700m, which only node2 (a2: 250m) has: a job of 700m with no placement must wait.
fn only_exclusive_fits(demo: *Demo) !void {
    const host = demo.host;
    const busy = try state.running_on(demo, node1) >= 2 and try state.running_on(demo, node3) >= 2;
    try host.check(busy, "node1 and node3 each run two jobs of 250m or more: less than 700m " ++
        "free on each", .{});
    try state.post(host, "n4", 700, null);
    try host.settle("n4 must stay pending though node2 has the room", state.settle_ms);
    const view = try state.need_job(host, "n4");
    try host.check(std.mem.eql(u8, view.state, "pending") and view.node == null, "n4 is " ++
        "pending, not on node2, which has 750m free", .{});
    const why = try host.zcube(&.{ "why", "job", "n4" });
    try host.check(why.code == 0 and state.contains(why.out, "2 of 3 nodes lack the room, " ++
        "1 are excluded, 1 of them by the placement of the job"), "zcube why job n4 says " ++
        "node1 and node3 lack the room and node2 is excluded by placement", .{});
    _ = try host.zcube(&.{ "job", "cancel", "n4" });
    try state.wait_state(host, "n4", "cancelled", state.job_wait_ms);
}

pub fn tenant_c_pending(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. a job for tenant c, which no node carries, stays pending");
    try state.post(host, "c1", 250, "c");
    try host.settle("c1 must stay pending", state.settle_ms);
    const view = try state.need_job(host, "c1");
    try host.check(std.mem.eql(u8, view.state, "pending") and view.node == null, "c1 is " ++
        "pending, on no node", .{});
    const why = try host.zcube(&.{ "why", "job", "c1" });
    try host.check(why.code == 0 and state.contains(why.out, "no ready node has tenant=c"), "" ++
        "zcube why job c1 says no ready node has tenant=c", .{});
    _ = try host.zcube(&.{ "job", "cancel", "c1" });
}

// ---- 4. Power off a tenant=a node ----

pub fn power_off(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. power off a tenant=a node: its job is lost; no a job lands on node3");
    for (open_jobs) |name| _ = try host.zcube(&.{ "job", "cancel", name });
    _ = try host.zcube(&.{ "job", "cancel", "b1" });
    for (open_jobs ++ [_][]const u8{"b1"}) |name| {
        try state.wait_state(host, name, "cancelled", state.job_wait_ms);
    }
    host.say("  node3 now runs nothing: 1000m free", .{});
    const index = try state.node_index(host, try state.need_job(host, "a1"));
    const survivor = if (index == node1) node2 else node1;
    try lose_node(demo, index);
    try host.check(!(try state.runs_on(demo, node3, "a1-job")), "a1 was not started on node3", .{});
    try refill(demo, survivor);
}

/// Powers off node `index` under `a1`: the job ends failed (unreachable), the node of the run
/// was lost, and it is not started anywhere else.
fn lose_node(demo: *Demo, index: usize) !void {
    const host = demo.host;
    const name = fleet_mod.names[index];
    host.say("  # power off {s} (under a1): kill -9 of its agent and its supervisors", .{name});
    const off_ms = host.now_ms();
    try demo.fleet.power_off(index);
    try state.wait_state(host, "a1", "failed", state.failover_ms + state.job_wait_ms);
    const failed_after: u64 = host.now_ms() - off_ms;
    const cli = try state.wait_job(host, "a1", 11, "failed");
    try host.check(state.contains(cli.out, "end: failed (unreachable)"), "a1 ended failed " ++
        "(unreachable): the node was lost", .{});
    const floor: u64 = state.ttl_ms - state.keepalive_slack_ms;
    try host.check(failed_after + state.c1.tolerance_ms >= floor, "it was read failed {d} ms " ++
        "after the power-off (not before the lease ran out: at least {d} ms)", .{
        failed_after, floor,
    });
    const why = try host.zcube(&.{ "why", "job", "a1" });
    try host.check(why.code == 0 and state.contains(why.out, "the node of the run was lost"), "" ++
        "zcube why job a1 names the lost node", .{});
    try host.settle("a1 must not start anywhere", state.settle_ms);
    const view = try state.need_job(host, "a1");
    try host.check(std.mem.eql(u8, view.state, "failed") and view.retries == 0, "a1 stays " ++
        "failed, not retried", .{});
}

/// With one tenant=a node left (`survivor`, running a2) and node3 empty, a job for a that does
/// not fit beside a2 waits rather than land on node3, then runs on `survivor` once a2 is gone.
fn refill(demo: *Demo, survivor: usize) !void {
    const host = demo.host;
    const home = fleet_mod.names[survivor];
    try state.post(host, "a3", 900, "a");
    try host.settle("a3 must stay pending though node3 has the room", state.settle_ms);
    const view = try state.need_job(host, "a3");
    try host.check(std.mem.eql(u8, view.state, "pending") and view.node == null, "a3 is " ++
        "pending, not on node3, which has 1000m free", .{});
    const why = try host.zcube(&.{ "why", "job", "a3" });
    try host.check(why.code == 0 and state.contains(why.out, "1 of 3 nodes lack the room, " ++
        "2 are excluded, 1 of them by the placement of the job"), "zcube why job a3 says " ++
        "{s} lacks the room, and the lost node and node3 (by placement) are excluded", .{home});
    _ = try host.zcube(&.{ "job", "cancel", "a2" });
    const index = try state.wait_running(demo, "a3");
    try host.check(index == survivor, "a3 runs on {s} once a2 is cancelled", .{home});
    try host.check(try state.running_on(demo, node3) == 0, "node3 runs nothing", .{});
    for (a_jobs) |name| {
        const placed = try state.need_job(host, name);
        const node = placed.node orelse "(none)";
        try host.check(!std.mem.eql(u8, node, "node3"), "{s} ({s}) was placed on {s}, " ++
            "never on node3", .{ name, placed.state, node });
    }
    _ = try host.zcube(&.{ "job", "cancel", "a3" });
}
