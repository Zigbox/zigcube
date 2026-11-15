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
    try wait_marker(host, mark);
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

const Marker = struct { path: []const u8 };

/// True once the job's command has run its `echo start >> marker`. The server reads `running` when
/// the agent has started the supervisor, which can be before `sh` has run its first command.
fn marker_written(want: Marker, host: *Host) !bool {
    const text = std.Io.Dir.cwd().readFileAlloc(host.io, want.path, host.arena(), .limited(4096));
    return state.lines_with(text catch "", "start") >= 1;
}

fn wait_marker(host: *Host, path: []const u8) !void {
    const want: Marker = .{ .path = path };
    try host.wait_for(want, marker_written, "the command to write its marker", state.job_wait_ms);
}

fn node_ready(want: Ready, host: *Host) !bool {
    const rows = (try state.c1.node_rows(host)) orelse return false;
    const row = state.c1.find_node(rows, fleet_mod.names[want.index]) orelse return false;
    return row.is_ready();
}

/// What is left of the lease of node `name`, as the server reports it (`remaining_ms`).
fn lease_left_ms(host: *Host, name: []const u8) !u64 {
    const rows = try state.c1.need_nodes(host);
    const row = state.c1.find_node(rows, name) orelse return host.fail("{s} unlisted", .{name});
    const left = row.remaining_ms orelse return host.fail("{s} has no lease", .{name});
    return @intCast(left);
}

/// The node under the running `doomed` is powered off; the job is failed `unreachable`.
pub fn power_off(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. power off the node under a running job: failed, not started elsewhere");
    const mark = try host.path_in_work("doomed-starts");
    const script = try std.fmt.allocPrint(host.arena(), "echo start >> {s}; sleep 300", .{mark});
    _ = try state.run_job(host, "doomed", &.{}, script);
    try state.wait_state(host, "doomed", "running", state.job_wait_ms);
    try wait_marker(host, mark);
    const index = try state.node_index(host, try state.need_job(host, "doomed"));
    const other = 1 - index;
    const name = fleet_mod.names[index];
    // The lease's expiry is at least `remaining_ms` after a read sent before the power-off (a
    // renewal after the read only moves it later). The last renewal may be up to the renewal
    // interval (ttl / 3 at 8 s) old at the power-off, so the expiry can come well before
    // ttl after it; the job controller fails the running job `lost_grace_ms` after the expiry.
    const read_ms = host.now_ms();
    const left_ms = try lease_left_ms(host, name);
    host.say("  # power off {s}: kill -9 of its agent, then of every supervisor's group", .{name});
    const off_ms = host.now_ms();
    try demo.fleet.power_off(index);
    try state.wait_state(host, "doomed", "failed", state.failover_ms + state.job_wait_ms);
    const failed_after: u64 = host.now_ms() - off_ms;
    const cli = try state.wait_job(host, "doomed", 11, "failed");
    try host.check(state.contains(cli.out, "end: failed (unreachable)"), "doomed failed: " ++
        "unreachable", .{});
    const floor: u64 = (read_ms + left_ms + state.lost_grace_ms) -| off_ms;
    try host.check(failed_after + state.c1.tolerance_ms >= floor, "it was read failed {d} ms " ++
        "after the power-off (not before the lease ran out, {d} ms left when read, and the " ++
        "grace passed: at least {d} ms)", .{ failed_after, left_ms, floor });
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
