//! demo-c2's steps (docs/demos/c2.md, "demo-c2"): SPEC's four and the corrupted-chunk criterion,
//! each asserted from what `zcube -o json stats pull`, `get replicas` and `why replica` print
//! (src/demo_c2_check.zig holds the rules). A rule that does not hold is a *miss*: the demo says
//! so, carries on to gather the rest of the evidence and fails at the end. A wait that times out
//! for something a later step needs ends the demo at once.

const std = @import("std");
const assert = std.debug.assert;
const check = @import("demo_c2_check.zig");
const demo_host = @import("demo_host.zig");
const vms = @import("demo_c2_vms.zig");

const Host = demo_host.Host;
const Json = demo_host.Json;
const Guests = vms.Guests;

/// The images (docs/decisions/2026-11-04-demo-c2-images.md): v2 differs from v1 in app.py only,
/// which sits in a layer of its own.
pub const v1_ref = "ghcr.io/zigbox/python-app@sha256:" ++
    "c0373ee9361f29da3cbd8b0eee85ff11297f7f9a61724bc920c622f7de58e14c";
pub const v2_ref = "ghcr.io/zigbox/python-app@sha256:" ++
    "e89d9e8605126e634764d3829c4d71a9e5b85377675b66b16f174f3b3cfa9a36";
/// Step 3's image, one node 3 does not hold yet: Zigbox's pinned Alpine (the tree from its lock
/// file, src/testing/vm/zbx.lock, as ops/zigbox-smoke/guest.sh uses it), through mirror.gcr.io.
pub const alpine_ref = "alpine:3.20@sha256:" ++
    "c64c687cbea9300178b30c95835354e34c4e4febc4badfe27102879de0483b5e";
pub const alpine_tree = "b3:2e478596e56b3c0f1748d14e505d5d289ead0bb0526cbd53b325baff01afe599";

/// Step 2: what one node may transfer for v2, from the registry and peers together.
pub const v2_bytes_max: u64 = 1024 * 1024;

/// Bounds of the waits. The first start pulls about 45 MB from GHCR on a CI runner.
pub const first_start_ms: u32 = 10 * 60 * 1000;
pub const start_ms: u32 = 5 * 60 * 1000;
pub const join_ms: u32 = 2 * 60 * 1000;
pub const record_ms: u32 = 2 * 60 * 1000;
/// How long a wait pumps the guests between two looks.
const look_every_ms: u32 = 1000;

pub const Demo = struct {
    host: *Host,
    guests: *Guests,
    /// The server as the guests reach it: `10.0.2.2:<P>`.
    server: []const u8,
    v1_tree: []const u8 = "",
    v2_tree: []const u8 = "",
    /// The rules that did not hold.
    misses: u32 = 0,

    pub fn arena(demo: *Demo) std.mem.Allocator {
        return demo.host.arena();
    }

    /// A rule of the demo: a miss is said and counted, and the demo goes on.
    pub fn expect(demo: *Demo, ok: bool, comptime what: []const u8, args: anytype) void {
        if (ok) {
            demo.host.say("  ok: " ++ what, args);
            return;
        }
        demo.misses += 1;
        demo.host.say("  MISSED in step \"{s}\": " ++ what, .{demo.host.step} ++ args);
    }

    /// Looks with `look(ctx, demo)` until it is true, pumping every guest in between. Past
    /// `limit_ms` it says so and returns false.
    pub fn wait(
        demo: *Demo,
        ctx: anytype,
        comptime look: fn (@TypeOf(ctx), *Demo) anyerror!bool,
        comptime what: []const u8,
        limit_ms: u32,
    ) !bool {
        const started = demo.host.now_ms();
        while (demo.host.now_ms() - started < limit_ms) {
            if (try look(ctx, demo)) {
                demo.host.say("  waited {d} ms for " ++ what, .{demo.host.now_ms() - started});
                return true;
            }
            const until = demo.host.now_ms() + look_every_ms;
            while (demo.host.now_ms() < until) try demo.guests.pump_all(25);
        }
        demo.host.say("  timed out after {d} ms waiting for " ++ what, .{limit_ms});
        return false;
    }

    /// A wait whose end later steps need: a timeout ends the demo.
    pub fn wait_hard(
        demo: *Demo,
        ctx: anytype,
        comptime look: fn (@TypeOf(ctx), *Demo) anyerror!bool,
        comptime what: []const u8,
        limit_ms: u32,
    ) !void {
        if (try demo.wait(ctx, look, what, limit_ms)) return;
        return demo.host.fail("timed out waiting for " ++ what, .{});
    }

    /// `guest.sh <arguments>` as root on guest `index`, shown in the transcript. A non-zero
    /// exit ends the demo.
    pub fn guest(demo: *Demo, index: u32, comptime format: []const u8, args: anytype) ![]const u8 {
        const arguments = try std.fmt.allocPrint(demo.arena(), format, args);
        const ran = try demo.guest_run(index, arguments);
        if (ran.status != 0) {
            return demo.host.fail("guest.sh {s} on {s} exited {d}", .{
                arguments, vms.names[index], ran.status,
            });
        }
        return ran.output;
    }

    /// As `guest`, but a non-zero exit is the caller's to judge.
    pub fn guest_run(demo: *Demo, index: u32, arguments: []const u8) !Ran {
        const timeout_s: u32 = 300;
        const result = try demo.guests.root(index, arguments, timeout_s);
        const output = try demo.arena().dupe(u8, result.output);
        demo.host.say("{s}# guest.sh {s}", .{ vms.names[index], arguments });
        demo.host.out(output);
        demo.host.out("\n");
        return .{ .output = output, .status = result.status };
    }

    /// `zcube -o json <args>`, parsed; not shown.
    pub fn json(demo: *Demo, args: []const []const u8) !Json {
        const argv = try demo.arena().alloc([]const u8, args.len + 2);
        argv[0] = "-o";
        argv[1] = "json";
        @memcpy(argv[2..], args);
        const cli = try demo.host.zcube_quiet(argv);
        try demo.host.check_quiet(cli.code == 0, "zcube -o json {s} exited {d}: {s}", .{
            args[0], cli.code, cli.err,
        });
        return std.json.parseFromSliceLeaky(Json, demo.arena(), cli.out, .{});
    }

    pub fn pulls(demo: *Demo, tree: []const u8) ![]check.Pull {
        return check.pulls_of(demo.arena(), try demo.json(&.{ "stats", "pull" }), tree);
    }

    pub fn replicas(demo: *Demo, service: []const u8) ![]check.Replica {
        return check.replicas_of(demo.arena(), try demo.json(&.{ "get", "replicas", service }));
    }

    /// Writes `<name>.zon` in the demo's directory and applies it with `zcube apply --yes`.
    pub fn apply(demo: *Demo, service: Service) !void {
        const host = demo.host;
        const file = try std.fmt.allocPrint(demo.arena(), "{s}.zon", .{service.name});
        const text = try std.fmt.allocPrint(demo.arena(),
            \\.{{
            \\    .name = "{s}",
            \\    .image = "{s}",
            \\    .source = "{s}",
            \\    .replicas = {d},
            \\    .command = .{{ {s} }},
            \\    .limits = .{{ .cpu_millis = 250, .memory_bytes = 134217728 }},
            \\}}
            \\
        , .{ service.name, service.image, service.source, service.replicas, service.command });
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(host.io, .{ .sub_path = try host.path_in_work(file), .data = text });
        const applied = try host.zcube(&.{ "apply", "--yes", file });
        try host.check(applied.code == 0, "zcube apply {s}", .{file});
    }
};

pub const Ran = struct { output: []const u8, status: u8 };

pub const Service = struct {
    name: []const u8,
    image: []const u8,
    source: []const u8,
    replicas: u32,
    /// The ZON items of `.command`, quoted.
    command: []const u8,
};

pub const python_command = "\"python\", \"/app/app.py\"";
pub const loop_command = "\"sh\", \"-c\", \"while true; do sleep 1; done\"";

// ---- Start: the server, the trees, three agents ----

pub fn start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. Start: zcube-server on the host, three guests' agents");
    _ = try host.zcube(&.{"version"});
    try host.start_server(30 * 1000);
    host.say("  zcube-server is up on 127.0.0.1:{d} (SQLite); the guests reach it at {s}", .{
        host.port, demo.server,
    });
    // The agents run as root (slice 8's M3, gap 2): root gets a subordinate range for the full
    // id map and a user bus (linger) for its scopes.
    for (0..vms.count) |index| _ = try demo.guest(@intCast(index), "setup-root", .{});
    // The tree digest Zigbox computes for an image depends on the host it is pulled on, so the
    // demo learns v1's and v2's on guest 4, in a scratch store it deletes; node4 stays empty.
    demo.v1_tree = try learn(demo, v1_ref);
    demo.v2_tree = try learn(demo, v2_ref);
    _ = try demo.guest(3, "store-empty", .{});
    for (0..3) |index| try start_agent(demo, @intCast(index));
    try demo.wait_hard(@as(u32, 3), peers_known, "3 nodes with peer addresses", join_ms);
    _ = try host.zcube(&.{ "get", "nodes" });
}

fn learn(demo: *Demo, reference: []const u8) ![]const u8 {
    const output = try demo.guest(3, "learn {s}", .{reference});
    const at = std.mem.indexOf(u8, output, "tree b3:") orelse
        return demo.host.fail("no tree learned for {s}", .{reference});
    const tree = output[at + "tree ".len ..];
    const length = "b3:".len + 64;
    if (tree.len < length) return demo.host.fail("a short tree for {s}", .{reference});
    return tree[0..length];
}

pub fn start_agent(demo: *Demo, index: u32) !void {
    _ = try demo.guest(index, "agent {s} {s} 10.0.2.2:{d}", .{
        vms.names[index], demo.server, demo.guests.peer_ports[index],
    });
}

/// `nodes` nodes have a `/node-store/` record (a summary and a peer address).
pub fn peers_known(nodes: u32, demo: *Demo) !bool {
    const reply = try demo.host.json("/v1/list?prefix=/node-store/");
    const kvs = switch (reply) {
        .object => |object| object.get("kvs") orelse return false,
        else => return false,
    };
    return switch (kvs) {
        .array => |list| list.items.len >= nodes,
        else => false,
    };
}

// ---- Zigbox gap 1 (slice 8's M3; Zigbox Z9) ----

/// Says what stands behind a miss of step 1 or 3 while the pinned Zigbox has gap 1: a node
/// that holds `tree` cannot serve a one-chunk object whose container owner is not 0:0 (it reads
/// as Damaged, the peer server answers 500 and the fetch falls back or fails, ZC-E0601). Lists
/// those objects as `holder` sees them inside the image, then the fetch logs of `fetchers`.
pub fn gap_evidence(demo: *Demo, tree: []const u8, holder: u32, fetchers: []const u32) !void {
    demo.host.say("  evidence for Zigbox gap 1 (Z9): one-chunk objects not owned by 0:0 in {s}", .{
        tree,
    });
    const owners = try std.fmt.allocPrint(demo.arena(), "one-chunk-owners {s}", .{tree});
    _ = try demo.guest_run(holder, owners);
    _ = try demo.guest_run(holder, "fetch-logs 'does not match\\|Damaged'");
    for (fetchers) |index| {
        _ = try demo.guest_run(index, "fetch-logs 'ZC-[EW]06\\|does not match'");
    }
}

// ---- Waits on replicas and records ----

pub const Expect = struct {
    service: []const u8,
    image: []const u8,
    total: u32,
    /// The nodes that each run the same number of them, or empty for no such rule.
    nodes: []const []const u8 = &.{},
};

pub fn replicas_running(want: Expect, demo: *Demo) !bool {
    const rows = try demo.replicas(want.service);
    if (check.running(rows, want.image, "") != want.total) return false;
    if (want.nodes.len == 0) return true;
    return check.spread_evenly(rows, want.image, want.nodes);
}

pub const Records = struct { tree: []const u8, nodes: []const []const u8 };

pub fn pulls_recorded(want: Records, demo: *Demo) !bool {
    const pulls = try demo.pulls(want.tree);
    for (want.nodes) |node| {
        if (check.pull_on(pulls, node) == null) return false;
    }
    return true;
}

pub fn say_pull(demo: *Demo, pull: check.Pull) void {
    demo.host.say("  {s}: registry {d} B, peers {d} B, cached {d} B, struck {d}", .{
        pull.node, pull.registry_bytes, pull.peer_bytes, pull.cached_bytes, pull.bad_peers.len,
    });
}

pub const first_three = [_][]const u8{ "node1", "node2", "node3" };

comptime {
    assert(first_three.len + 1 == vms.count);
    assert(v2_bytes_max < 45 * 1024 * 1024); // Far below the image.
}
