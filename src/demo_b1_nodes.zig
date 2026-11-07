//! Steps 3 and 4 of `demo-b1` (docs/demos/b1.md): `kill -9` of an agent while its job runs (the
//! job lives on and the restarted agent reports its ending), and the power-off of a node under a
//! running job (`failed unreachable` after the lease and the grace, never started elsewhere).

const std = @import("std");
const state = @import("demo_b1_state.zig");
const fleet_mod = @import("demo_b1_fleet.zig");

const Demo = state.Demo;
const Host = state.Host;

/// `kill -9` of the agent under `adopt`; its command goes on and the new agent records exit 5.
pub fn adoption(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. kill -9 of an agent while its job runs: the job lives on and is adopted");
    const mark = try host.path_in_work("adopt-starts");
    const script = try std.fmt.allocPrint(host.arena(), "echo start >> {s}; sleep 10; exit 5", .{
        mark,
    });
    _ = try state.run_job(host, "adopt", &.{}, script);
    try state.wait_state(host, "adopt", "running", state.job_wait_ms);
    const index = try state.node_index(host, try state.need_job(host, "adopt"));
    const name = fleet_mod.names[index];
    try state.wait_runs_on(demo, index, "adopt-job");
    try host.check(try state.runs_on(demo, index, "adopt-job"), "adopt-job runs on {s}", .{name});
    try demo.fleet.kill_agent(index);
    try host.check(!demo.fleet.agent_alive(index), "the agent of {s} is killed (kill -9)", .{name});
    try host.check(try state.runs_on(demo, index, "adopt-job"), "its job's command lives on", .{});
    try demo.fleet.start_agent(index);
    host.say("  the agent of {s} is started again with the same state directory", .{name});
    const cli = try state.wait_job(host, "adopt", 10, "exited otherwise");
    try host.check(state.contains(cli.out, "end: exited (code 5)"), "the restarted agent " ++
        "reported the ending: exited, code 5", .{});
    const view = try state.need_job(host, "adopt");
    try host.check(std.mem.eql(u8, view.state, "exited") and view.code == 5, "the job is " ++
        "exited with code 5 on the server", .{});
    const starts = std.Io.Dir.cwd().readFileAlloc(host.io, mark, host.arena(), .limited(4096));
    try host.check(state.lines_with(starts catch "", "start") == 1, "the command started " ++
        "once (its marker file has one line)", .{});
}

const Ready = struct { index: usize };

fn node_ready(want: Ready, host: *Host) !bool {
    const rows = (try state.c1.node_rows(host)) orelse return false;
    const row = state.c1.find_node(rows, fleet_mod.names[want.index]) orelse return false;
    return row.is_ready();
}

/// The node under the running `doomed` is powered off; the job is failed `unreachable`.
pub fn power_off(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. power off the node under a running job: failed, not started elsewhere");
    const mark = try host.path_in_work("doomed-starts");
    const script = try std.fmt.allocPrint(host.arena(), "echo start >> {s}; sleep 300", .{mark});
    _ = try state.run_job(host, "doomed", &.{}, script);
    try state.wait_state(host, "doomed", "running", state.job_wait_ms);
    const index = try state.node_index(host, try state.need_job(host, "doomed"));
    const other = 1 - index;
    const name = fleet_mod.names[index];
    host.say("  # power off {s}: kill -9 of its agent, then of every supervisor's group", .{name});
    const off_ms = host.now_ms();
    try demo.fleet.power_off(index);
    try state.wait_state(host, "doomed", "failed", state.failover_ms + state.job_wait_ms);
    const failed_after: u64 = host.now_ms() - off_ms;
    const cli = try state.wait_job(host, "doomed", 11, "failed");
    try host.check(state.contains(cli.out, "end: failed (unreachable)"), "doomed failed: " ++
        "unreachable", .{});
    // The server's expiry is at or after the last acknowledged keepalive's receipt plus the
    // ttl, and that keepalive is at most one pass old when the power goes off. The job is failed
    // at the expiry (`lost_grace_ms` only holds back unstarted claims).
    const floor: u64 = state.ttl_ms - state.keepalive_slack_ms;
    try host.check(failed_after + state.c1.tolerance_ms >= floor, "it was read failed {d} ms " ++
        "after the power-off (not before the lease ran out: at least {d} ms)", .{
        failed_after, floor,
    });
    const view = try state.need_job(host, "doomed");
    try host.check(view.retries == 0, "its retries are 0", .{});
    try host.settle("the job must not be started on the other node", state.settle_ms);
    try host.check(!(try state.runs_on(demo, other, "doomed-job")), "doomed-job is not " ++
        "running on {s}", .{fleet_mod.names[other]});
    const starts = std.Io.Dir.cwd().readFileAlloc(host.io, mark, host.arena(), .limited(4096));
    try host.check(state.lines_with(starts catch "", "start") == 1, "the command started " ++
        "once, never on the other node (its marker file has one line)", .{});
    const after = try state.need_job(host, "doomed");
    const still = after.node != null and std.mem.eql(u8, after.node.?, name);
    try host.check(std.mem.eql(u8, after.state, "failed") and still, "the job stays failed, " ++
        "on {s}", .{name});
    const why = try host.zcube(&.{ "why", "job", "doomed" });
    try host.check(why.code == 0 and state.contains(why.out, "the node of the run was lost"), "" ++
        "zcube why job doomed names the lost node", .{});
    const rows = (try state.c1.node_rows(host)) orelse return host.fail("no node list", .{});
    const lost = state.c1.find_node(rows, name) orelse return host.fail("{s} unlisted", .{name});
    try host.check(!lost.is_ready(), "{s} is not ready before its agent is back", .{name});
    try demo.fleet.start_agent(index);
    const ready: Ready = .{ .index = index };
    try host.wait_for(ready, node_ready, "the powered-off node to rejoin", state.start_wait_ms);
}
