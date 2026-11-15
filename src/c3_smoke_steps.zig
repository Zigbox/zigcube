//! The steps of `c3-smoke` and `demo-c3` (docs/briefs/c3.md, "Demo script" and "How demo-c3
//! runs"; docs/demos/c3.md says what each asserts and what is cut). Every wait is bounded and
//! drains the witness (`c3_witness.zig`) at each poll, so every revision of the run is judged.
//! The two runs differ only in their `Nodes` (how time passes, how an agent is restarted) and
//! their `Setup` (the images, the app's command, the health check and the rolling policy).

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const witness_mod = @import("c3_witness.zig");

const Host = demo_host.Host;
const Json = demo_host.Json;
const View = witness_mod.View;
const Witness = witness_mod.Witness;

/// `v1`, `v2` and `v3` of `c3-smoke`: three digests FakeRuntime's image list holds. `v3` never
/// becomes healthy there because the witness scripts its checks to fail.
pub const fake_images = [3][]const u8{ "b3:51aa9c03", "b3:9d20c4f1", "b3:7e3a0b52" };

/// The lease timeout the server runs with, as demo-c1's.
pub const ttl_text = "8000";
/// The server to answer, and the agents to register.
pub const start_wait_ms: u32 = 20_000;
/// A window in which a paused rollout must start and retire nothing.
pub const paused_watch_ms: u32 = 3_000;

/// The node whose agent step 4b restarts (`node2`).
pub const restarted_node: u32 = 1;

/// What the run's nodes are: how time passes while a step waits, and how an agent is restarted.
pub const Nodes = struct {
    context: *anyopaque,
    /// Lets about `ms` pass: a sleep, or the guests' consoles pumped for that long.
    pass: *const fn (context: *anyopaque, ms: u32) anyerror!void,
    /// SIGKILL of node `index`'s agent alone, then a start on the same state directory; checks
    /// (in the transcript) that every container it ran runs on under the same supervisor.
    restart_agent: *const fn (context: *anyopaque, index: u32) anyerror!void,
    /// The node names the agents register, in order.
    names: []const []const u8,
};

/// What the service files say, and how long a step may wait.
pub const Setup = struct {
    images: [3][]const u8 = fake_images,
    /// Each image's registry reference (`.source`); null for FakeRuntime, which needs none.
    sources: ?[3][]const u8 = null,
    /// The app: `sh -c <command>`.
    command: []const u8 = "while true; do sleep 1; done",
    health: []const u8 = health_good,
    rollout: []const u8 = rollout_good,
    /// The policy's `min_ready_ms`, as `rollout` says it.
    min_ready_ms: u32 = 2_000,
    /// One rollout of three replicas: a start, `min_ready_ms` and a retirement each.
    rollout_ms: u32 = 60_000,
    /// A rollout that fails: `ready_timeout_ms`, then the rollback.
    failure_ms: u32 = 90_000,
    /// How `v3` fails, for the transcript.
    v3_fails: []const u8 = "",
};

pub const Demo = struct {
    host: *Host,
    nodes: Nodes,
    setup: Setup = .{},
    witness: *Witness,
    backend: []const u8,
    /// The libpq settings of a Postgres run; empty for SQLite.
    postgres: []const u8,
    /// What the current wait waits for: every replica ready at this generation and image.
    want_generation: u64 = 0,
    want_image: []const u8 = "",
    /// Step 4b: the newest report of the restarted node before its agent was killed.
    restarted_at_ms: u64 = 0,
};

pub fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

// ---- Service files ----

/// Writes `<file>` in the demo's directory: the service `app` at version `version`, with its
/// health check and its rolling policy (surge 1, unavailable 0). `health` and `rollout` replace
/// the setup's for the files that must be refused.
fn write_app(
    demo: *Demo,
    file: []const u8,
    version: usize,
    health: []const u8,
    rollout: []const u8,
) !void {
    const host = demo.host;
    const setup = &demo.setup;
    const source = if (setup.sources) |sources|
        try std.fmt.allocPrint(host.arena(), "    .source = \"{s}\",\n", .{sources[version]})
    else
        "";
    const text = try std.fmt.allocPrint(host.arena(),
        \\.{{
        \\    .name = "app",
        \\    .image = "{s}",
        \\{s}    .replicas = 3,
        \\    .command = .{{ "sh", "-c", "{s}" }},
        \\    .health = .{{ .command = .{{ "test", "-f", "/tmp/ready" }}, {s} }},
        \\    .rollout = .{{ .strategy = .rolling, {s} }},
        \\}}
        \\
    , .{ setup.images[version], source, setup.command, health, rollout });
    try std.Io.Dir.cwd().writeFile(host.io, .{
        .sub_path = try host.path_in_work(file),
        .data = text,
    });
    host.say("$ cat {s}\n{s}", .{ file, std.mem.trimEnd(u8, text, "\n") });
}

pub const health_good = ".interval_ms = 1000, .timeout_ms = 1000, .start_period_ms = 0, " ++
    ".failure_threshold = 2, .success_threshold = 1";
pub const rollout_good = ".max_surge = 1, .max_unavailable = 0, .min_ready_ms = 2000, " ++
    ".ready_timeout_ms = 15000, .progress_deadline_ms = 120000, .grace_ms = 2000, " ++
    ".on_failure = .rollback";

fn write_version(demo: *Demo, version: usize) !void {
    try write_app(demo, "app.zon", version, demo.setup.health, demo.setup.rollout);
}

// ---- The command ----

/// `zcube <args>`, shown; it must succeed and print each of `parts`.
fn expect_ok(host: *Host, args: []const []const u8, parts: []const []const u8) ![]const u8 {
    const cli = try host.zcube(args);
    const line = try std.mem.join(host.arena(), " ", args);
    try host.check_quiet(cli.code == 0, "zcube {s} exited {d}", .{ line, cli.code });
    for (parts) |part| {
        try host.check(contains(cli.out, part), "zcube {s} says \"{s}\"", .{ line, part });
    }
    return cli.out;
}

/// `zcube <args>`, shown; it must fail with `code` and say `summary`.
fn expect_refused(
    host: *Host,
    args: []const []const u8,
    code: []const u8,
    summary: []const u8,
) !void {
    const cli = try host.zcube(args);
    const said = try std.mem.concat(host.arena(), u8, &.{ cli.out, cli.err });
    const line = try std.mem.join(host.arena(), " ", args);
    try host.check(
        cli.code != 0 and contains(said, code) and contains(said, summary),
        "zcube {s} is refused with {s}: \"{s}\"",
        .{ line, code, summary },
    );
}

// ---- Waiting on the witness's mirror ----

/// Waits, draining the witness and letting the nodes run (`Nodes.pass`), until `done` holds;
/// fails the demo after `limit_ms`.
fn wait_until(
    demo: *Demo,
    comptime done: fn (*Demo, *const View) bool,
    comptime what: []const u8,
    limit_ms: u32,
) !void {
    const host = demo.host;
    assert(limit_ms > demo_host.poll_ms);
    const started = host.now_ms();
    while (host.now_ms() - started < limit_ms) {
        const view = try demo.witness.now();
        if (done(demo, &view)) {
            host.say("  (waited {d} ms for " ++ what ++ ")", .{host.now_ms() - started});
            return;
        }
        try demo.nodes.pass(demo.nodes.context, demo_host.poll_ms);
    }
    const view = try demo.witness.now();
    if (done(demo, &view)) return;
    return host.fail("waited {d} ms for " ++ what, .{limit_ms});
}

/// Lets `duration_ms` pass while the witness keeps reading and the nodes run.
fn watch(demo: *Demo, comptime why: []const u8, duration_ms: u32) !void {
    const host = demo.host;
    host.say("  (watching for {d} ms: " ++ why ++ ")", .{duration_ms});
    const started = host.now_ms();
    while (host.now_ms() - started < duration_ms) {
        try demo.witness.drain();
        try demo.nodes.pass(demo.nodes.context, demo_host.poll_ms);
    }
    try demo.witness.drain();
}

/// The service is at `want_generation`, its rollout (if any) is complete, and every replica is
/// ready at that generation with `want_image`, nothing else running.
fn settled(demo: *Demo, view: *const View) bool {
    const service = view.service orelse return false;
    if (service.generation != demo.want_generation) return false;
    if (view.rollout) |rollout| {
        if (rollout.to != demo.want_generation or rollout.phase != .complete) return false;
    }
    return view.settled_at(demo.want_generation, demo.want_image);
}

/// A replica of `want_generation` is ready and the rollout to it is still active.
fn first_new_ready(demo: *Demo, view: *const View) bool {
    const rollout = view.rollout orelse return false;
    if (rollout.to != demo.want_generation or rollout.phase == .complete) return false;
    for (view.replicas) |*replica| {
        if (replica.generation == demo.want_generation and view.ready(replica)) return true;
    }
    return false;
}

/// A replica of `want_generation` exists and the rollout to it is still active.
fn first_new_created(demo: *Demo, view: *const View) bool {
    const rollout = view.rollout orelse return false;
    if (rollout.to != demo.want_generation or rollout.phase == .complete) return false;
    return view.at_generation(demo.want_generation) > 0;
}

/// The replica named `want_image` (here a replica id) is reported unhealthy.
fn reported_unhealthy(demo: *Demo, view: *const View) bool {
    const observed = view.observed_of(demo.want_image) orelse return false;
    return observed.health == .unhealthy;
}

/// Every replica the restarted node runs was reported again since `restarted_at_ms`, by the new
/// agent, running and healthy: a restarted agent reports `unknown` until a check of its own
/// passes (`agent_health.zig`), so this is a check run since the restart. `want_image` holds
/// the node's name.
fn node_checked_again(demo: *Demo, view: *const View) bool {
    var count: u32 = 0;
    for (view.observed) |*observed| {
        if (!std.mem.eql(u8, observed.node, demo.want_image)) continue;
        if (observed.status == .stopped) continue;
        if (view.replica(observed.replica) == null) continue;
        if (observed.reported_at_ms <= demo.restarted_at_ms) return false;
        if (observed.status != .running or observed.health != .healthy) return false;
        count += 1;
    }
    return count > 0;
}

fn wait_settled(demo: *Demo, generation: u64, image: []const u8, limit_ms: u32) !void {
    demo.want_generation = generation;
    demo.want_image = image;
    const what = "every replica ready at the generation, the rollout complete";
    try wait_until(demo, settled, what, limit_ms);
    const view = try demo.witness.now();
    try demo.host.check(view.settled_at(generation, image), "generation {d}: 3 replicas ready, " ++
        "each running {s}, nothing else of app running", .{ generation, image });
}

fn service_generation(demo: *Demo) !u64 {
    const view = try demo.witness.now();
    const service = view.service orelse return demo.host.fail("app does not exist", .{});
    return service.generation;
}

// ---- 1. v1 ----

pub fn v1(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. v1: three replicas with a health check");
    try write_version(demo, 0);
    _ = try expect_ok(host, &.{ "apply", "--yes", "app.zon" }, &.{});
    try wait_settled(demo, 1, demo.setup.images[0], demo.setup.rollout_ms);
    // The rollout controller counts a replica ready once it has run healthy for `min_ready_ms`,
    // and a first rollout's `from` is the newest generation ready then (0 if none): wait it out,
    // or v2's rollout is `0 → 2` and its failure would roll back to nothing.
    try watch(demo, "v1's replicas to be ready for min_ready_ms", demo.setup.min_ready_ms + 500);
    _ = try host.zcube(&.{ "get", "replicas", "app" });
    _ = try expect_ok(host, &.{ "rollout", "status", "app" }, &.{"app: generation 1, 3 replicas"});
}

/// What is refused, by code and summary; none of it changes the service.
pub fn refusals(demo: *Demo) !void {
    const host = demo.host;
    host.section("1b. Refusals: nothing to roll back, nothing to pause, bad files");
    try expect_refused(host, &.{ "rollback", "app" }, "ZC-E0127", "has run only generation 1");
    try expect_refused(host, &.{ "rollout", "pause", "app" }, "ZC-E0129", "service app has no");
    try write_app(demo, "bad-health.zon", 0, ".interval_ms = 0, .timeout_ms = 1000, " ++
        ".start_period_ms = 0, .failure_threshold = 2, .success_threshold = 1", rollout_good);
    const bad_health = [_][]const u8{ "apply", "--yes", "bad-health.zon" };
    try expect_refused(host, &bad_health, "ZC-E0125", "health.interval_ms is 0");
    try write_app(demo, "bad-rollout.zon", 0, health_good, ".max_surge = 0, " ++
        ".max_unavailable = 0, .min_ready_ms = 2000");
    try expect_refused(host, &.{ "apply", "--yes", "bad-rollout.zon" }, "ZC-E0126", "both 0");
    try host.check(try service_generation(demo) == 1, "app is still at generation 1", .{});
}

// ---- 2. v2 ----

pub fn v2(demo: *Demo) !void {
    const host = demo.host;
    const witness = demo.witness;
    host.section("2. v2: surge 1, unavailable 0; never fewer than 3 ready");
    try write_version(demo, 1);
    witness.floor = true;
    witness.tally.floor_low = std.math.maxInt(u32);
    witness.tally.live_max = 0;
    _ = try expect_ok(host, &.{ "apply", "--yes", "app.zon" }, &.{});
    try wait_settled(demo, 2, demo.setup.images[1], demo.setup.rollout_ms);
    witness.floor = false;
    const tally = witness.tally;
    try host.check(tally.floor_low >= 3, "the witness saw at least 3 ready at each of {d} " ++
        "revisions of the rollout (fewest {d})", .{ tally.floor_revisions, tally.floor_low });
    try host.check(tally.live_max <= 4, "never more than 4 replicas live (most {d})", .{
        tally.live_max,
    });
    _ = try expect_ok(host, &.{ "rollout", "status", "app" }, &.{
        "app: generation 2, 3 replicas",
        "1 → 2",
    });
}

// ---- 3. v3, never healthy ----

pub fn v3(demo: *Demo) !void {
    const host = demo.host;
    const witness = demo.witness;
    host.section("3. v3 never becomes healthy: the rollout stops, rolls back, ends on v2");
    const images = demo.setup.images;
    const next = try next_replica_number(demo);
    const failing = try std.fmt.allocPrint(host.arena(), "app-{d}", .{next});
    witness.fault_image = images[2];
    if (witness.fault_dirs.len > 0) {
        try witness.script_unhealthy(failing);
        host.say("  FakeRuntime's check of {s} (and of any other v3 replica) fails: " ++
            "<state-dir>/faults/<id> holds \"unhealthy\"", .{failing});
    } else {
        host.say("  {s} (and any other v3 replica): {s}", .{ failing, demo.setup.v3_fails });
    }
    try write_version(demo, 2);
    _ = try expect_ok(host, &.{ "apply", "--yes", "app.zon" }, &.{});
    demo.want_image = failing;
    const limit = demo.setup.rollout_ms;
    try wait_until(demo, reported_unhealthy, "the v3 replica's check to fail", limit);
    _ = try host.zcube(&.{ "why", "service", "app" });
    _ = try host.zcube(&.{ "why", "replica", failing });
    _ = try host.zcube(&.{ "rollout", "status", "app" });
    try wait_settled(demo, 4, images[1], demo.setup.failure_ms);
    const view = try witness.now();
    const landed = view.history_of(4) orelse return host.fail("no history of generation 4", .{});
    const restored = landed.reason == .auto_rollback and landed.restores == 2;
    try host.check(restored, "generation 4 is the automatic rollback, restoring generation 2", .{});
    var created_v3: u32 = 0;
    for (witness.images.values()) |image| {
        created_v3 += @intFromBool(std.mem.eql(u8, image, images[2]));
    }
    try host.check(created_v3 == 1, "the rollout stopped on its first new replica: {d} v3 " ++
        "replica created", .{created_v3});
    for (view.replicas) |*replica| {
        try host.check(std.mem.eql(u8, replica.image, images[1]), "{s} runs exactly {s} (v2)", .{
            replica.id, replica.image,
        });
    }
    _ = try host.zcube(&.{ "get", "replicas", "app" });
    _ = try expect_ok(host, &.{ "rollout", "status", "app" }, &.{
        "app: generation 4, 3 replicas",
        "2 → 4 (rollback): complete",
    });
    // Cut (docs/demos/c3.md): the brief's "`zcube why` names the failing replica". Neither the
    // `rollout_fail` decision's text nor `why`'s chain names it yet; the chain is shown as it is.
    _ = try host.zcube(&.{ "why", "service", "app" });
}

/// The number the next replica of `app` gets: `/replica-numbers/app`'s `next`.
fn next_replica_number(demo: *Demo) !u64 {
    const host = demo.host;
    const listed = try host.json("/v1/list?prefix=/replica-numbers/app");
    const bad = "GET /v1/list?prefix=/replica-numbers/app is not shaped as expected";
    if (listed != .object) return host.fail(bad, .{});
    const kvs = listed.object.get("kvs") orelse return host.fail(bad, .{});
    if (kvs != .array or kvs.array.items.len != 1) return host.fail(bad, .{});
    const item = kvs.array.items[0];
    if (item != .object) return host.fail(bad, .{});
    const value = item.object.get("value") orelse return host.fail(bad, .{});
    if (value != .object) return host.fail(bad, .{});
    const next = value.object.get("next") orelse return host.fail(bad, .{});
    if (next != .integer or next.integer < 1) return host.fail(bad, .{});
    return @intCast(next.integer);
}

// ---- 4. history, rollback, pause and resume ----

pub fn history(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. History, rollback, pause and resume");
    _ = try expect_ok(host, &.{ "history", "app" }, &.{ "4*", "demo@" });
    const view = try demo.witness.now();
    const reasons = [_]@TypeOf(view.history[0].reason){ .apply, .apply, .apply, .auto_rollback };
    for (reasons, 1..) |reason, generation| {
        const stored = view.history_of(generation) orelse
            return host.fail("no history of generation {d}", .{generation});
        try host.check_quiet(stored.reason == reason, "generation {d}: reason {s}", .{
            generation, @tagName(stored.reason),
        });
    }
    host.say("  ok: the history holds generations 1 to 4: apply, apply, apply, auto_rollback", .{});
    const to_99 = [_][]const u8{ "rollback", "app", "--to", "99" };
    try expect_refused(host, &to_99, "ZC-E0128", "is newer than the one it runs");
}

/// `rollback --to 1`, paused after its first new replica is ready; the agent of a node restarted
/// while it is paused keeps its containers, and nothing starts or retires.
pub fn rollback_paused(demo: *Demo) !void {
    const host = demo.host;
    host.section("4b. rollback --to 1, paused; a restarted agent keeps its containers");
    const to_1 = [_][]const u8{ "rollback", "app", "--to", "1" };
    _ = try expect_ok(host, &to_1, &.{"generation 4 → 5, restoring 1"});
    demo.want_generation = 5;
    const first = "the rollback's first replica to run healthy";
    try wait_until(demo, first_new_ready, first, demo.setup.rollout_ms);
    _ = try expect_ok(host, &.{ "rollout", "pause", "app" }, &.{"rolling_back → paused"});
    _ = try expect_ok(host, &.{ "rollout", "status", "app" }, &.{"paused by user"});
    const before = try demo.witness.now();
    const name = demo.nodes.names[restarted_node];
    var on_node: u32 = 0;
    for (before.observed) |*observed| {
        const placed = before.replica(observed.replica) != null;
        on_node += @intFromBool(placed and std.mem.eql(u8, observed.node, name));
    }
    try host.check_quiet(on_node > 0, "{s} runs no replica of app", .{name});
    demo.restarted_at_ms = newest_report(&before, name);
    try demo.nodes.restart_agent(demo.nodes.context, restarted_node);
    demo.want_image = name;
    const again = "a check by the restarted agent to pass on each of its replicas";
    try wait_until(demo, node_checked_again, again, demo.setup.rollout_ms);
    const checked = try demo.witness.now();
    try host.check(node_checked_again(demo, &checked), "{s}'s restarted agent reported each of " ++
        "its {d} replicas again, running and healthy", .{ name, on_node });
    try watch(demo, "a paused rollout starts and retires nothing", paused_watch_ms);
    const after = try demo.witness.now();
    try host.check(same_ids(&before, &after), "while paused, the replicas did not change " ++
        "({d} of generation 5, {d} records)", .{ after.at_generation(5), after.replicas.len });
}

/// The newest `reported_at_ms` of `node`'s reports: what the agent wrote before it was killed.
fn newest_report(view: *const View, node: []const u8) u64 {
    var newest: u64 = 0;
    for (view.observed) |*observed| {
        if (!std.mem.eql(u8, observed.node, node)) continue;
        newest = @max(newest, observed.reported_at_ms);
    }
    return newest;
}

/// Resumed, then the server is restarted before the rollback completes; it goes on.
pub fn resume_and_restart(demo: *Demo) !void {
    const host = demo.host;
    host.section("4c. resume; the server restarted mid-rollout resumes the rollout");
    _ = try expect_ok(host, &.{ "rollout", "resume", "app" }, &.{"paused → rolling_back"});
    const view = try demo.witness.now();
    const rollout = view.rollout orelse return host.fail("app has no rollout", .{});
    try host.check(rollout.to == 5 and rollout.phase == .rolling_back and
        view.at_generation(5) < 3, "the rollback to generation 5 is in progress ({d} of 3 " ++
        "replicas at generation 5)", .{view.at_generation(5)});
    try host.stop_child(&host.server, "zcube-server");
    try host.start_server(start_wait_ms);
    host.say("  zcube-server restarted on the same store", .{});
    try wait_settled(demo, 5, demo.setup.images[0], demo.setup.rollout_ms);
    const done = (try demo.witness.now()).rollout orelse return host.fail("no rollout", .{});
    try host.check(done.started_at_ms == rollout.started_at_ms, "the same rollout went on " ++
        "after the restart (started at {d} ms)", .{done.started_at_ms});
}

/// A rollback in progress, then an apply: the apply wins.
pub fn apply_wins(demo: *Demo) !void {
    const host = demo.host;
    host.section("4d. An apply during a rollback wins");
    _ = try expect_ok(host, &.{ "rollback", "app" }, &.{"generation 5 → 6, restoring 4"});
    demo.want_generation = 6;
    try wait_until(demo, first_new_created, "the rollback's first replica", demo.setup.rollout_ms);
    const view = try demo.witness.now();
    const rollout = view.rollout orelse return host.fail("app has no rollout", .{});
    try host.check(rollout.to == 6 and rollout.phase != .complete, "the rollback to generation " ++
        "6 is in progress ({s})", .{@tagName(rollout.phase)});
    try write_version(demo, 0);
    _ = try expect_ok(host, &.{ "apply", "--yes", "app.zon" }, &.{});
    try wait_settled(demo, 7, demo.setup.images[0], demo.setup.rollout_ms);
    const after = try demo.witness.now();
    const stored = after.history_of(7) orelse return host.fail("no history of generation 7", .{});
    try host.check(stored.reason == .apply, "generation 7 is the apply; no replica of the " ++
        "rollback's generation 6 is left", .{});
    _ = try expect_ok(host, &.{ "history", "app" }, &.{"7*"});
    _ = try host.zcube(&.{ "get", "replicas", "app" });
}

fn same_ids(before: *const View, after: *const View) bool {
    if (before.replicas.len != after.replicas.len) return false;
    for (before.replicas) |*replica| {
        if (after.replica(replica.id) == null) return false;
    }
    return true;
}
