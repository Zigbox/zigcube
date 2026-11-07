//! demo-c2's script (docs/demos/c2.md, "demo-c2"): SPEC's four steps and the corrupted-chunk
//! criterion, each asserted from the server's JSON (src/demo_c2_check.zig holds the rules).
//!
//!   1. python-app v1, 3 replicas on three empty nodes: one per node, and the image's bytes come
//!      from the registry once, the rest from peers;
//!   2. v2 (app.py only): each node transfers under `v2_bytes_max`;
//!   3. node3 cannot reach any registry and node1 corrupts what it serves: node3 starts its first
//!      replica of a new image from peers alone, and strikes node1 (ZC-W0601);
//!   4. node4 joins empty: a new service on v2 is placed where v2 already is, and `zcube why`
//!      names the locality; python-app's fourth replica still goes to node4 (spread first).

const std = @import("std");
const check = @import("demo_c2_check.zig");
const constants = @import("constants.zig");
const steps = @import("demo_c2_steps.zig");

const Demo = steps.Demo;

pub fn run(demo: *Demo) !void {
    try steps.start(demo);
    try deploy_v1(demo);
    try roll_to_v2(demo);
    try peers_only(demo);
    try fourth_node(demo);
    try summary(demo);
}

fn python_app(tree: []const u8, reference: []const u8, count: u32) steps.Service {
    return .{
        .name = "python-app",
        .image = tree,
        .source = reference,
        .replicas = count,
        .command = steps.python_command,
    };
}

// ---- 1. Deploy v1 on three empty nodes ----

fn deploy_v1(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. Deploy python-app v1, 3 replicas, on three empty nodes");
    try demo.apply(python_app(demo.v1_tree, steps.v1_ref, 3));
    try demo.wait_hard(steps.Expect{
        .service = "python-app",
        .image = demo.v1_tree,
        .total = 3,
    }, steps.replicas_running, "3 replicas of v1 running", steps.first_start_ms);
    _ = try host.zcube(&.{ "get", "replicas", "python-app" });
    const rows = try demo.replicas("python-app");
    demo.expect(check.spread_evenly(rows, demo.v1_tree, &steps.first_three), "one replica of " ++
        "v1 on each of node1, node2 and node3", .{});
    try demo.wait_hard(steps.Records{
        .tree = demo.v1_tree,
        .nodes = &steps.first_three,
    }, steps.pulls_recorded, "v1's pull records of node1-3", steps.record_ms);
    const pulls = try demo.pulls(demo.v1_tree);
    for (pulls) |pull| steps.say_pull(demo, pull);
    const evidence = try demo.o5_evidence(&steps.first_three);
    const read = check.registry_read(pulls, evidence, constants.fetch_peer_wait_ms);
    steps.say_registry_readers(demo, pulls, evidence);
    switch (read.kind) {
        .once => demo.host.say("  registry read once, by {s} (its pull took {d} ms)", .{
            read.elected, read.elected_ms,
        }),
        .overran => demo.host.say("  {s} was elected (O5) and its registry pull took {d} ms, " ++
            "over the wait cap of {d} ms; the other nodes waited the cap out and fell back to " ++
            "the registry as designed " ++
            "(docs/decisions/2026-11-07-demo-c2-registry-once-cap.md)", .{
            read.elected, read.elected_ms, constants.fetch_peer_wait_ms,
        }),
        .repeated => demo.host.say("  not explained by an overrun: {s}", .{read.why}),
        .broken => {},
    }
    demo.expect(read.passes(), "v1 came from the registry on one node only; the other two " ++
        "fetched it from peers{s}", .{switch (read.kind) {
        .repeated => " (FAILED: several registry reads, and the nodes' own logs do not show " ++
            "the elected pull outlasting the O5 cap: a duplicate pull)",
        .overran => " (waived: the elected pull overran the O5 cap)",
        .once, .broken => "",
    }});
    if (!read.passes()) try steps.gap_evidence(demo, demo.v1_tree, 0, &.{ 0, 1, 2 });
}

// ---- 2. Roll to v2: only the changed layer moves ----

fn roll_to_v2(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. Roll python-app to v2 (app.py changed, one small layer)");
    try demo.apply(python_app(demo.v2_tree, steps.v2_ref, 3));
    try demo.wait_hard(steps.Expect{
        .service = "python-app",
        .image = demo.v2_tree,
        .total = 3,
    }, steps.replicas_running, "3 replicas of v2 running", steps.start_ms);
    _ = try host.zcube(&.{ "get", "replicas", "python-app" });
    try demo.wait_hard(steps.Records{
        .tree = demo.v2_tree,
        .nodes = &steps.first_three,
    }, steps.pulls_recorded, "v2's pull records of node1-3", steps.record_ms);
    const pulls = try demo.pulls(demo.v2_tree);
    for (pulls) |pull| {
        steps.say_pull(demo, pull);
        const bytes = check.transferred(pull);
        demo.expect(bytes <= steps.v2_bytes_max, "{s} transferred {d} B for v2 (at most {d})", .{
            pull.node, bytes, steps.v2_bytes_max,
        });
    }
}

// ---- 3. node3 behind a firewall, node1 corrupting ----

const alpine_box = "alpine-box";

fn alpine(count: u32) steps.Service {
    return .{
        .name = alpine_box,
        .image = steps.alpine_tree,
        .source = steps.alpine_ref,
        .replicas = count,
        .command = steps.loop_command,
    };
}

fn peers_only(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. node3 cannot reach a registry; node1 corrupts what it serves");
    // Two replicas go to node1 and node2 (spread ties, then least allocated ties, then name), so
    // node3 is the one node without the image when the registry is cut.
    try demo.apply(alpine(2));
    try demo.wait_hard(steps.Expect{
        .service = alpine_box,
        .image = steps.alpine_tree,
        .total = 2,
    }, steps.replicas_running, "2 replicas of alpine-box running", steps.start_ms);
    const before = try demo.replicas(alpine_box);
    try host.check(check.running(before, steps.alpine_tree, "node3") == 0, "node3 runs no " ++
        "alpine-box replica yet", .{});
    try demo.wait_hard(steps.Records{
        .tree = steps.alpine_tree,
        .nodes = &.{ "node1", "node2" },
    }, steps.pulls_recorded, "alpine's pull records of node1 and node2", steps.record_ms);
    _ = try demo.guest(0, "fault-on", .{});
    _ = try demo.guest(0, "restart", .{});
    _ = try demo.guest(2, "block-registry", .{});
    try demo.apply(alpine(3));
    const started = try demo.wait(steps.Expect{
        .service = alpine_box,
        .image = steps.alpine_tree,
        .total = 3,
    }, steps.replicas_running, "alpine-box's third replica, on node3", steps.start_ms);
    demo.expect(started, "node3 started alpine-box with no registry reachable", .{});
    _ = try host.zcube(&.{ "get", "replicas", alpine_box });
    const peers_alone = if (started) try peers_only_record(demo) else false;
    const warned = try demo.guest(2, "fetch-logs ZC-W0601", .{});
    demo.expect(std.mem.indexOf(u8, warned, "ZC-W0601") != null, "node3's fetch log says " ++
        "ZC-W0601", .{});
    if (!peers_alone) try steps.gap_evidence(demo, steps.alpine_tree, 0, &.{2});
    _ = try demo.guest(0, "fault-off", .{});
    _ = try demo.guest(0, "restart", .{});
}

/// node3's pull record of alpine: from peers alone, with node1 struck. True if it was from peers
/// alone.
fn peers_only_record(demo: *Demo) !bool {
    const found = try demo.wait(steps.Records{
        .tree = steps.alpine_tree,
        .nodes = &.{"node3"},
    }, steps.pulls_recorded, "node3's pull record of alpine", steps.record_ms);
    demo.expect(found, "node3 recorded its pull of alpine", .{});
    if (!found) return false;
    const pull = check.pull_on(try demo.pulls(steps.alpine_tree), "node3").?;
    steps.say_pull(demo, pull);
    const alone = check.from_peers_only(pull);
    demo.expect(alone, "node3 took every byte from peers, none from a registry", .{});
    demo.expect(pull.has_bad_peer("node1"), "node3 struck node1 for a chunk that did not " ++
        "verify", .{});
    return alone;
}

// ---- 4. A fourth, empty node ----

const python_warm = "python-warm";

fn fourth_node(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. node4 joins empty; a new service on v2 goes where v2 already is");
    try steps.start_agent(demo, 3);
    const four: u32 = 4;
    try demo.wait_hard(four, steps.peers_known, "4 nodes with peer addresses", steps.join_ms);
    _ = try host.zcube(&.{ "get", "nodes" });
    try demo.apply(.{
        .name = python_warm,
        .image = demo.v2_tree,
        .source = steps.v2_ref,
        .replicas = 1,
        .command = steps.python_command,
    });
    try demo.wait_hard(steps.Expect{
        .service = python_warm,
        .image = demo.v2_tree,
        .total = 1,
    }, steps.replicas_running, "python-warm's replica running", steps.start_ms);
    const rows = try demo.replicas(python_warm);
    try host.check(rows.len == 1, "python-warm has one replica", .{});
    demo.expect(!std.mem.eql(u8, rows[0].node, "node4"), "python-warm's replica is on {s}, " ++
        "a node that holds v2, not on the empty node4", .{rows[0].node});
    _ = try host.zcube(&.{ "why", "replica", rows[0].id });
    const placement = try check.placement_of(try demo.json(&.{ "why", "replica", rows[0].id }));
    demo.expect(if (placement) |p| check.names_locality(p) else false, "`zcube why replica " ++
        "{s}` names the bytes of the image already there", .{rows[0].id});
    try spread_wins(demo);
}

/// Locality breaks ties only: python-app's fourth replica goes to the node without one.
fn spread_wins(demo: *Demo) !void {
    try demo.apply(python_app(demo.v2_tree, steps.v2_ref, 4));
    try demo.wait_hard(steps.Expect{
        .service = "python-app",
        .image = demo.v2_tree,
        .total = 4,
    }, steps.replicas_running, "4 replicas of python-app running", steps.start_ms);
    const rows = try demo.replicas("python-app");
    demo.expect(check.running(rows, demo.v2_tree, "node4") == 1, "python-app's fourth " ++
        "replica runs on node4 (spread before locality)", .{});
    const found = try demo.wait(steps.Records{
        .tree = demo.v2_tree,
        .nodes = &.{"node4"},
    }, steps.pulls_recorded, "node4's pull record of v2", steps.record_ms);
    if (!found) return;
    const pull = check.pull_on(try demo.pulls(demo.v2_tree), "node4").?;
    steps.say_pull(demo, pull);
    const alone = check.from_peers_only(pull);
    demo.expect(alone, "node4 fetched v2 from peers alone", .{});
    if (!alone) try steps.gap_evidence(demo, demo.v2_tree, 0, &.{3});
}

fn summary(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. The pull records");
    _ = try host.zcube(&.{ "stats", "pull" });
    try host.check(demo.misses == 0, "every rule of the demo held ({d} missed)", .{demo.misses});
}
