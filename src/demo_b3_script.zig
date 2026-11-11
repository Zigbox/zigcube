//! demo-b3's script (docs/demos/b3.md): a relayed job that tries to reach everything but its
//! relay, and a second relayed job beside it, both on the one node.
//!
//!   1. start: the server with the relay `botpike`, one guest with the agent and a test upstream;
//!   2. a bystander job with a relay of its own runs on the node, so the hostile job has "another
//!      job's relay" to aim at;
//!   3. the hostile job runs: it reaches the world on seven counts, and the upstream (which it
//!      reaches through its relay) logs what it saw: every one must read `failed`;
//!   4. the node: no relay listens in its namespace, no relay failure is logged, the job exits 0.

const std = @import("std");
const assert = std.debug.assert;
const state = @import("demo_b1_state.zig");
const steps = @import("demo_c2_steps.zig");
const vms = @import("demo_c2_vms.zig");

const Demo = steps.Demo;

/// The relay `botpike`'s upstream as the agent reaches it (the guest's loopback; the test
/// upstream of ops/demo-b3/guest.sh).
pub const upstream = "127.0.0.1:9090";
/// The Python image of demo-c2 (docs/decisions/2026-11-04-demo-c2-images.md): it has `python`.
const image_ref = steps.v1_ref;

const job_wait_ms: u32 = 5 * 60 * 1000;
const hostile = "hostile";
const bystander = "bystander";

/// The checks of the hostile job, as the job names them in its report. Each reads `failed`.
const checks = [_][]const u8{
    "internet", "node", "metadata", "server", "upstream_direct", "dns", "raw",
};

/// What the job runs (`python -c`). It tries each route out, then reports through its relay:
/// `GET /report?<check>=<failed|REACHED>&...`, which the test upstream logs, and answers
/// `upstream-ok`. Exit 0 only if every check failed and the answer came through.
const hostile_python =
    \\import os, socket, sys, urllib.request
    \\def tcp(host, port):
    \\    s = socket.socket()
    \\    s.settimeout(3)
    \\    try:
    \\        s.connect((host, port))
    \\        return "REACHED"
    \\    except Exception:
    \\        return "failed"
    \\    finally:
    \\        s.close()
    \\def dns():
    \\    try:
    \\        socket.getaddrinfo("example.com", 443)
    \\        return "REACHED"
    \\    except Exception:
    \\        return "failed"
    \\def raw():
    \\    try:
    \\        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    \\        s.settimeout(3)
    \\        s.sendto(b"\x08\x00\xf7\xff\x00\x00\x00\x00", ("1.1.1.1", 0))
    \\        return "REACHED"
    \\    except Exception:
    \\        return "failed"
    \\node = os.environ["NODE_ADDR"]
    \\got = [
    \\    ("internet", tcp("1.1.1.1", 443)),
    \\    ("node", tcp(node, 22)),
    \\    ("metadata", tcp("169.254.169.254", 80)),
    \\    ("server", tcp(os.environ["SERVER_HOST"], int(os.environ["SERVER_PORT"]))),
    \\    ("upstream_direct", tcp("127.0.0.1", 9090)),
    \\    ("dns", dns()),
    \\    ("raw", raw()),
    \\]
    \\query = "&".join(k + "=" + v for k, v in got)
    \\try:
    \\    url = os.environ["ZCUBE_RELAY"] + "/report?" + query
    \\    body = urllib.request.urlopen(url, timeout=15).read()
    \\except Exception:
    \\    sys.exit(12)
    \\if body != b"upstream-ok":
    \\    sys.exit(11)
    \\sys.exit(10 if any(v != "failed" for k, v in got) else 0)
;

pub fn run(demo: *Demo) !void {
    try start(demo);
    try bystander_runs(demo);
    try hostile_runs(demo);
    try node_is_clean(demo);
    try summary(demo);
}

// ---- 1. Start ----

fn start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. Start: zcube-server with the relay botpike, one guest, a test upstream");
    _ = try host.zcube(&.{"version"});
    try host.start_server(30 * 1000);
    host.say("  zcube-server is up on 127.0.0.1:{d} (SQLite); the guest reaches it at {s}", .{
        host.port, demo.server,
    });
    _ = try demo.guest(0, "setup-root", .{});
    _ = try demo.guest(0, "upstream", .{});
    const learned = try demo.guest(0, "learn {s}", .{image_ref});
    const at = std.mem.indexOf(u8, learned, "tree b3:") orelse
        return host.fail("no tree learned for {s}", .{image_ref});
    const length = "b3:".len + 64;
    if (learned.len < at + "tree ".len + length) return host.fail("a short tree", .{});
    demo.v1_tree = learned[at + "tree ".len ..][0..length];
    _ = try demo.guest(0, "images {s} {s}", .{ demo.v1_tree, image_ref });
    _ = try demo.guest(0, "agent {s} {s}", .{ vms.names[0], demo.server });
    try demo.wait_hard({}, node_joined, "the node to join", steps.join_ms);
    _ = try host.zcube(&.{ "get", "nodes" });
}

fn node_joined(_: void, demo: *Demo) !bool {
    const reply = try demo.host.json("/v1/list?prefix=/nodes/");
    const kvs = switch (reply) {
        .object => |object| object.get("kvs") orelse return false,
        else => return false,
    };
    return switch (kvs) {
        .array => |list| list.items.len >= 1,
        else => false,
    };
}

// ---- Jobs ----

const Want = struct { name: []const u8, state: []const u8 };

fn in_state(want: Want, demo: *Demo) !bool {
    const view = (try state.job_view(demo.host, want.name)) orelse return false;
    return std.mem.eql(u8, view.state, want.state);
}

fn has_ended(want: Want, demo: *Demo) !bool {
    const view = (try state.job_view(demo.host, want.name)) orelse return false;
    return view.end_kind != null;
}

/// `zcube job run NAME --image TREE --relay botpike <extra> --command python -c <source>`.
fn run_job(demo: *Demo, name: []const u8, extra: []const []const u8, source: []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(demo.arena(), &.{
        "job", "run", name, "--image", demo.v1_tree, "--relay", "botpike",
    });
    try args.appendSlice(demo.arena(), extra);
    try args.appendSlice(demo.arena(), &.{ "--command", "python", "-c", source });
    const started = try demo.host.zcube(args.items);
    try demo.host.check(started.code == 0, "zcube job run {s} --relay botpike", .{name});
}

// ---- 2. A bystander with a relay of its own ----

fn bystander_runs(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. A second relayed job runs beside it");
    try run_job(demo, bystander, &.{}, "import time; time.sleep(600)");
    try demo.wait_hard(Want{ .name = bystander, .state = "running" }, in_state, "the bystander " ++
        "to run", job_wait_ms);
    _ = try host.zcube(&.{ "job", "get", bystander });
}

// ---- 3. The hostile job ----

fn hostile_runs(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. The hostile job: seven ways out, one way through the relay");
    const addr_text = try demo.guest(0, "node-addr", .{});
    const node_addr = std.mem.trim(u8, addr_text, " \r\n");
    const node_env = try std.fmt.allocPrint(demo.arena(), "NODE_ADDR={s}", .{node_addr});
    const server_port = try std.fmt.allocPrint(demo.arena(), "SERVER_PORT={d}", .{host.port});
    try run_job(demo, hostile, &.{
        "--env",      node_env, "--env", "SERVER_HOST=10.0.2.2", "--env", server_port,
        "--deadline", "5m",
    }, hostile_python);
    const ending = Want{ .name = hostile, .state = "" };
    try demo.wait_hard(ending, has_ended, "the hostile job to end", job_wait_ms);
    _ = try host.zcube(&.{ "job", "get", hostile });
    const view = (try state.job_view(host, hostile)).?;
    demo.expect(view.code != null and view.code.? == 0, "the hostile job exits 0 (every " ++
        "attempt failed and the relay answered; 10: something was reached, 11: wrong answer, " ++
        "12: no answer), got {?d}", .{view.code});
    const log = try demo.guest(0, "upstream-log", .{});
    host.say("  the upstream saw the job's relayed requests only: {d} line(s)", .{
        std.mem.count(u8, log, "\n"),
    });
    demo.expect(std.mem.count(u8, log, "GET /report?") == 1, "the test upstream received " ++
        "the job's request through the relay, exactly once", .{});
    for (checks) |name| {
        const reached = try std.fmt.allocPrint(demo.arena(), "{s}=REACHED", .{name});
        const failed = try std.fmt.allocPrint(demo.arena(), "{s}=failed", .{name});
        demo.expect(std.mem.indexOf(u8, log, failed) != null and
            std.mem.indexOf(u8, log, reached) == null, "the job's {s} attempt failed", .{name});
    }
}

// ---- 4. The node afterwards ----

fn node_is_clean(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. The node: no relay in its namespace, no relay failure logged");
    const listeners = try demo.guest(0, "listeners", .{});
    demo.expect(std.mem.indexOf(u8, listeners, ":8080") == null, "nothing listens on 8080 in " ++
        "the node's own namespace: the relays live in their jobs'", .{});
    const logs = try demo.guest(0, "relay-logs", .{});
    demo.expect(std.mem.indexOf(u8, logs, "ZC-E07") == null, "no relay.log holds a ZC-E07xx " ++
        "line", .{});
    _ = try host.zcube(&.{ "job", "cancel", bystander });
    const ending = Want{ .name = bystander, .state = "" };
    try demo.wait_hard(ending, has_ended, "the bystander to end", job_wait_ms);
    const view = (try state.job_view(host, bystander)).?;
    demo.expect(view.end_kind != null, "the bystander ended after its cancel ({s})", .{
        view.end_kind orelse "?",
    });
}

fn summary(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. Summary");
    _ = try host.zcube(&.{ "job", "list" });
    try host.check(demo.misses == 0, "every rule of the demo held ({d} missed)", .{demo.misses});
}

comptime {
    assert(checks.len == 8);
}
