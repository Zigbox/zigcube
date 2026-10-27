//! The steps of HANDOFF's C0 demo that need no outage (`demo_c0.zig` runs them in order, and
//! `demo_c0_outage.zig` does step 5): apply, `kill -9`, scaling, a digest that is not there, and
//! the acceptance criteria for restarts and for the record of decisions. Each step asserts its
//! outcome and prints what it did.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const decisions = @import("demo_c0_decisions.zig");
const host_procs = @import("host_procs.zig");
const state = @import("demo_c0_state.zig");

const Demo = state.Demo;
const Host = state.Host;
const Pids = host_procs.Pids;

// ---- 1 ----

/// `hello` has `want` replicas running, and asks for that many.
const RunningCount = struct {
    demo: *Demo,
    want: i64,

    fn check(ctx: RunningCount, _: *Host) !bool {
        const counts = (try state.service_counts(ctx.demo, "hello")) orelse return false;
        return counts.running == ctx.want and counts.desired == ctx.want;
    }
};

pub fn apply(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. zcube apply hello.zon, replicas = 3");
    try state.write_service(demo, "hello", state.hello_image, 3);
    const apply_cli = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try state.expect_applied(host, apply_cli, "applied service hello: created");
    const three: RunningCount = .{ .demo = demo, .want = 3 };
    try host.wait_for(three, RunningCount.check, "3 replicas of hello to run", state.converge_ms);
    try state.expect_ready(demo, "hello", "3/3");
    const json = try host.zcube(&.{ "get", "service", "hello", "-o", "json" });
    const counts = (try state.service_counts(demo, "hello")).?;
    try host.check(json.code == 0, "--output json exits 0", .{});
    try host.check(
        counts.desired == 3 and counts.running == 3 and counts.generation == 1,
        "--output json: desired 3, running 3, generation 1",
        .{},
    );
    const wide = try host.zcube(&.{ "get", "replicas", "hello", "-o", "wide" });
    const running = state.wide_rows(wide.out, "hello", state.node, "running");
    try host.check(running == 3, "3 replicas, all running on {s}", .{state.node});
    try expect_supervised(demo, 3);
    try decisions.expect_new(demo, "step 1", &.{
        .{ .actor = "api", .action = "apply", .count = 1 },
        .{ .actor = "replica-controller", .action = "scale_up", .count = 1 },
        .{ .actor = "replica-controller", .action = "create_replica", .count = 3 },
        .{ .actor = "scheduler", .action = "place_replica", .count = 3 },
    });
}

/// `expected` commands run on the host, each the child of a supervisor that leads a session and a
/// group of its own, and each supervisor is the child of the agent that started it.
fn expect_supervised(demo: *Demo, expected: u32) !void {
    const host = demo.host;
    try state.expect_processes(demo, "one supervisor each", expected);
    const procs = host.procs();
    const agent_pid = host.agent.?.id.?;
    for (try procs.running_containers()) |pids| {
        const supervisor = procs.proc(pids.supervisor).?;
        const name = pids.name();
        try host.check_quiet(supervisor.session == pids.supervisor, "{s}: no session", .{name});
        try host.check_quiet(supervisor.group == pids.supervisor, "{s}: no group", .{name});
        try host.check_quiet(supervisor.parent == agent_pid, "{s}: not the agent's", .{name});
    }
    try host.check(true, "each command is the child of a supervisor that leads a session", .{});
}

// ---- 2 ----

/// The killed replica is gone from `zcube get replicas`, and 3 others run.
const Replaced = struct {
    demo: *Demo,
    victim: []const u8,

    fn check(ctx: Replaced, _: *Host) !bool {
        const rows = (try state.replica_rows(ctx.demo, "hello")) orelse return false;
        if (state.has_id(rows, ctx.victim)) return false;
        return state.count_status(rows, "running") == 3;
    }
};

pub fn kill(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. kill -9 one of the processes on the host");
    const before = try host.procs().running_containers();
    const victim = before[0];
    const name = try host.arena().dupe(u8, victim.name());
    host.say("$ kill -9 {d}    # the command of replica {s}, a host process", .{
        victim.command, name,
    });
    try std.posix.kill(victim.command, .KILL);
    const replaced: Replaced = .{ .demo = demo, .victim = name };
    try host.wait_for(replaced, Replaced.check, "a replacement to run", state.converge_ms);
    try state.expect_ready(demo, "hello", "3/3");
    const wide = try host.zcube(&.{ "get", "replicas", "hello", "-o", "wide" });
    const running = state.wide_rows(wide.out, "hello", state.node, "running");
    try host.check(running == 3, "zcube get shows 3 running again", .{});
    const procs = host.procs();
    try host.check(!procs.alive(victim.command), "the killed process is gone", .{});
    const alive = try procs.running_containers();
    const gone = state.find_container(alive, name) == null;
    try host.check(alive.len == 3 and gone, "3 commands run, none of them {s}", .{name});
    for (before[1..]) |pids| {
        const same = state.find_container(alive, pids.name());
        try host.check(
            same != null and same.?.command == pids.command,
            "{s} is the same process as before",
            .{pids.name()},
        );
    }
    try state.expect_processes(demo, "after the replacement", 3);
    const why = try host.zcube(&.{ "why", "replica", name });
    try host.check(state.contains(why.out, "SIGKILL"), "zcube why says {s} was killed", .{name});
    try decisions.expect_new(demo, "step 2", &.{
        .{ .actor = "replica-controller", .action = "delete_replica", .count = 1 },
        .{ .actor = "replica-controller", .action = "replace_replica", .count = 1 },
        .{ .actor = "replica-controller", .action = "create_replica", .count = 1 },
        .{ .actor = "scheduler", .action = "place_replica", .count = 1 },
    });
}

// ---- Acceptance: restarting the server, restarting the agent ----

/// The part of a list reply that is the records: the store's revision is left out, since it moves
/// with every write anywhere.
fn records(demo: *Demo, prefix: []const u8) ![]const u8 {
    const host = demo.host;
    const path = try std.fmt.allocPrint(host.arena(), "/v1/list?prefix={s}&limit=500", .{prefix});
    const reply = try host.call("GET", path, "");
    try host.check_quiet(reply.status == 200, "GET {s} answered {d}", .{ path, reply.status });
    const at = std.mem.find(u8, reply.body, "\"kvs\":") orelse return error.DemoFailed;
    return reply.body[at..];
}

/// Everything a restart must leave as it was.
const Snapshot = struct {
    services: []const u8,
    replicas: []const u8,
    decisions: []const u8,
    get_json: []const u8,
    containers: []const Pids,
};

fn snapshot(demo: *Demo) !Snapshot {
    const host = demo.host;
    const json = try host.zcube_quiet(&.{ "get", "replicas", "hello", "-o", "json" });
    return .{
        .services = try records(demo, "/services/"),
        .replicas = try records(demo, "/replicas/"),
        .decisions = try records(demo, "/decisions/"),
        .get_json = json.out,
        .containers = try host.procs().running_containers(),
    };
}

fn expect_unchanged(demo: *Demo, before: Snapshot, comptime when: []const u8) !void {
    const host = demo.host;
    const after = try snapshot(demo);
    const equal = state.expect_equal;
    const bytes = ": the same, byte for byte";
    try equal(host, before.services, after.services, when ++ ": /services/" ++ bytes);
    try equal(host, before.replicas, after.replicas, when ++ ": /replicas/" ++ bytes);
    try equal(host, before.decisions, after.decisions, when ++ ": /decisions/" ++ bytes);
    try equal(host, before.get_json, after.get_json, when ++ ": zcube get replicas -o json");
    const same = state.same_containers(before.containers, after.containers);
    try host.check(same, when ++ ": the same processes run", .{});
}

pub fn restart_server(demo: *Demo) !void {
    const host = demo.host;
    host.section("Acceptance: restarting zcube-server changes nothing");
    const before = try snapshot(demo);
    host.say("$ kill -TERM {d}    # zcube-server", .{host.server.?.id.?});
    try host.stop_child(&host.server, "zcube-server");
    const down = try host.zcube(&.{ "get", "service", "hello" });
    try host.check(
        down.code == constants.exit_environment,
        "while it is down, zcube exits {d}",
        .{constants.exit_environment},
    );
    const first = "error[ZC-E0102]: can't reach zcube-server";
    try host.check(std.mem.eql(u8, state.first_line(down.err), first), "{s}", .{first});
    try host.check(state.contains(down.err, "\n  fix "), "it has a fix", .{});
    try state.expect_no_trace(host, down);
    try host.settle("the agent keeps its processes while the server is away", state.settle_ms);
    const kept = state.same_containers(before.containers, try host.procs().running_containers());
    try host.check(kept, "the processes kept running without the server", .{});
    try host.start_server(state.start_wait_ms);
    try host.settle("the agent and the controllers catch up", state.settle_ms);
    try state.expect_ready(demo, "hello", "3/3");
    try expect_unchanged(demo, before, "after the server restart");
    try decisions.expect_new(demo, "server restart", &.{});
}

/// The log of the second agent says it registered.
const AgentRegistered = struct {
    fn check(_: void, host: *Host) !bool {
        const name = try host.path_in_work("agent-2.log");
        const cwd = std.Io.Dir.cwd();
        const text = cwd.readFileAlloc(host.io, name, host.arena(), .limited(8192)) catch {
            return false;
        };
        return std.mem.find(u8, text, "registered") != null;
    }
};

pub fn restart_agent(demo: *Demo) !void {
    const host = demo.host;
    host.section("Acceptance: restarting zcube-agent re-adopts, it does not duplicate");
    const before = try snapshot(demo);
    host.say("$ kill -TERM {d}    # zcube-agent", .{host.agent.?.id.?});
    try host.stop_child(&host.agent, "zcube-agent");
    const kept = state.same_containers(before.containers, try host.procs().running_containers());
    try host.check(kept, "stopping the agent stopped no container", .{});
    try host.start_agent(state.node);
    try host.wait_for({}, AgentRegistered.check, "the new agent to register", state.start_wait_ms);
    try host.settle("several agent passes: a duplicate would start in the first", state.settle_ms);
    try expect_unchanged(demo, before, "after the agent restart");
    try state.expect_processes(demo, "no duplicates", 3);
    try state.expect_ready(demo, "hello", "3/3");
    try decisions.expect_new(demo, "agent restart", &.{});
}

// ---- 3 ----

/// `hello` runs `want` replicas, and the host runs `want` commands under `want` supervisors.
const HostAtCount = struct {
    demo: *Demo,
    want: u32,

    fn check(ctx: HostAtCount, host: *Host) !bool {
        const counts = (try state.service_counts(ctx.demo, "hello")) orelse return false;
        if (counts.running != ctx.want) return false;
        const procs = host.procs();
        if ((try procs.running_containers()).len != ctx.want) return false;
        return (try procs.supervisors()) == ctx.want;
    }
};

pub fn scale(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. replicas = 5, then replicas = 2");
    const three = try host.procs().running_containers();
    try state.write_service(demo, "hello", state.hello_image, 5);
    const dry = try host.zcube(&.{ "apply", "--dry-run", "hello.zon" });
    try host.check(
        dry.code == 0 and state.contains(dry.out, "replicas 3 → 5"),
        "--dry-run shows replicas 3 → 5 and writes nothing",
        .{},
    );
    const up = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try state.expect_applied(host, up, "applied service hello: replicas 3 → 5");
    const at_five: HostAtCount = .{ .demo = demo, .want = 5 };
    const what_up = "5 replicas to run on the host";
    try host.wait_for(at_five, HostAtCount.check, what_up, state.converge_ms);
    const five = try host.procs().running_containers();
    try state.expect_ready(demo, "hello", "5/5");
    try state.expect_processes(demo, "5 replicas", 5);
    for (three) |pids| {
        const same = state.find_container(five, pids.name());
        try host.check(
            same != null and same.?.command == pids.command,
            "{s} kept running: two more started, nothing restarted",
            .{pids.name()},
        );
    }
    try decisions.expect_new(demo, "step 3 (up)", &.{
        .{ .actor = "api", .action = "apply", .count = 1 },
        .{ .actor = "replica-controller", .action = "scale_up", .count = 1 },
        .{ .actor = "replica-controller", .action = "create_replica", .count = 2 },
        .{ .actor = "scheduler", .action = "place_replica", .count = 2 },
    });
    try scale_down(demo, five);
}

fn scale_down(demo: *Demo, five: []const Pids) !void {
    const host = demo.host;
    try state.write_service(demo, "hello", state.hello_image, 2);
    const down = try host.zcube(&.{ "apply", "--yes", "hello.zon" });
    try state.expect_applied(host, down, "applied service hello: replicas 5 → 2");
    const at_two: HostAtCount = .{ .demo = demo, .want = 2 };
    const what_down = "3 replicas to stop on the host";
    try host.wait_for(at_two, HostAtCount.check, what_down, state.converge_ms);
    try state.expect_ready(demo, "hello", "2/2");
    try state.expect_processes(demo, "2 replicas", 2);
    const procs = host.procs();
    const two = try procs.running_containers();
    var stopped: u32 = 0;
    for (five) |pids| {
        if (state.find_container(two, pids.name()) != null) continue;
        const gone = !procs.alive(pids.command);
        try host.check_quiet(gone, "{s} was removed but its command runs", .{pids.name()});
        stopped += 1;
    }
    try host.check(stopped == 3, "3 processes stopped on the host (their commands are gone)", .{});
    try decisions.expect_new(demo, "step 3 (down)", &.{
        .{ .actor = "api", .action = "apply", .count = 1 },
        .{ .actor = "replica-controller", .action = "scale_down", .count = 1 },
        .{ .actor = "replica-controller", .action = "stop_replica", .count = 3 },
    });
}

// ---- 4 ----

/// What `zcube why service broken` prints: HANDOFF's chain, with the wording that api.md and the
/// registry give (docs/demos/c0.md lists each difference).
const broken_why = [_][]const u8{
    "service broken: 0/1 running",
    "  ← replica broken-1 failed to start on node1; " ++
        "it was not replaced because a new one would fail the same way",
    "  ← error[ZBX-E0501]: image not found",
    "      cause  digest b3:00ff7be1 is not in this node's store",
    "      fix    check the digest in the service file, or pull the image first",
    "      more   zbx explain E0501 · rerun with --verbose for the full cause chain",
    "      docs   https://zigbox.github.io/zigbox/errors/E0501.html",
};

fn why_is_broken_chain(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    for (broken_why) |expected| {
        const line = lines.next() orelse return false;
        if (!std.mem.eql(u8, line, expected)) return false;
    }
    return lines.next() == null;
}

const BrokenChain = struct {
    fn check(_: void, host: *Host) !bool {
        const cli = try host.zcube_quiet(&.{ "why", "service", "broken" });
        return cli.code == 0 and why_is_broken_chain(cli.out);
    }
};

pub fn broken(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. A digest that is not in the fixtures");
    try state.write_service(demo, "broken", state.broken_image, 1);
    const apply_cli = try host.zcube(&.{ "apply", "--yes", "broken.zon" });
    try state.expect_applied(host, apply_cli, "applied service broken: created");
    const what = "zcube why service broken to print the chain";
    try host.wait_for({}, BrokenChain.check, what, state.converge_ms);
    const why = try host.zcube(&.{ "why", "service", "broken" });
    try host.check(
        why.code == 0 and why_is_broken_chain(why.out),
        "the chain is HANDOFF's: state, replica, then the ZBX-E0501 block with cause and fix",
        .{},
    );
    try expect_broken_held(demo);
    try decisions.expect_new(demo, "step 4", &.{
        .{ .actor = "api", .action = "apply", .count = 1 },
        .{ .actor = "replica-controller", .action = "scale_up", .count = 1 },
        .{ .actor = "replica-controller", .action = "create_replica", .count = 1 },
        .{ .actor = "scheduler", .action = "place_replica", .count = 1 },
        .{ .actor = "replica-controller", .action = "hold_failed_replica", .count = 1 },
    });
}

/// `broken-1` failed to start with ZBX-E0501 and is held, not replaced; nothing else is disturbed.
fn expect_broken_held(demo: *Demo) !void {
    const host = demo.host;
    const table = try host.zcube(&.{ "get", "replicas", "broken", "-o", "wide" });
    const failed = state.wide_rows(table.out, "broken", state.node, "start-failed");
    try host.check(failed == 1, "broken-1 is start-failed on {s}", .{state.node});
    const detail = "ZBX-E0501: image not found";
    try host.check(state.contains(table.out, detail), "its DETAIL is " ++ detail, .{});
    const first = (try state.replica_rows(demo, "broken")).?;
    try host.settle("broken is held, not replaced; hello is not disturbed", state.settle_ms);
    const later = (try state.replica_rows(demo, "broken")).?;
    const one = first.len == 1 and later.len == 1;
    const same_id = one and std.mem.eql(u8, first[0].id, later[0].id);
    try host.check(same_id, "broken-1 was held, not replaced", .{});
    const hello = (try state.service_counts(demo, "hello")).?;
    try host.check(hello.running == 2 and hello.desired == 2, "hello is still 2/2", .{});
    try state.expect_processes(demo, "broken runs nothing", 2);
}

// ---- Acceptance: every action is recorded and explained ----

pub fn explained(demo: *Demo) !void {
    const host = demo.host;
    host.section("Acceptance: every controller action is recorded, with its cause");
    const why = try host.zcube(&.{ "why", "service", "hello", "-v" });
    try host.check(
        state.contains(why.out, "decision ") and state.contains(why.out, "scale_down"),
        "zcube why -v names the decision that scaled hello down, with its id and actor",
        .{},
    );
    try decisions.expect_all_explained(demo);
}
