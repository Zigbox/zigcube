//! The deterministic simulation of C0 (`zig build sim-c0 [-Dseed=N]`) and its fuzz variant.
//!
//! **This is a simulation, not `demo-c0`.** It drives the core (controller step, agent step, API
//! handlers, `why`), the memory store and the simulated runtime on virtual time, through the
//! steps of HANDOFF's C0 demo, and asserts each outcome. It proves that the core does what the
//! demo script asks, in a world where time, faults and the machine are all under test control.
//! It does not prove the demo: that needs real processes, a real Postgres and SQLite, and the
//! `zcube` command, and it is `zig build demo-c0` when the server and the agent exist.
//!
//! The scenario: apply `hello` with 3 replicas; kill one; scale to 5, then 2; apply `broken`
//! (a digest that is not in the node's store) and read `why` for it; take the store down and see
//! what the API says, with the workloads still running; restart the server core and the agent
//! core; bring the store back and see everything converge with nothing duplicated.
//!
//! The fuzz variant draws operations from a seed (applies, deletes, faults, store outages with
//! the store failing in the middle of a step, restarts, compaction) and checks invariants: never
//! more running containers than desired for long, every action has a decision with a cause, and
//! `why` always terminates. A failure prints its seed and replays exactly from it.
//!
//! It runs natively (a test, and `sim_c0_main.zig`) and as WebAssembly (`wasm_core.zig`); the two
//! produce the same report byte for byte, which `zig build sim-c0` compares.

const std = @import("std");
const assert = std.debug.assert;
const api_mod = @import("api.zig");
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const store = @import("store.zig");
const why_mod = @import("why.zig");

const repeat = @import("test_util.zig").repeat;

const Allocator = std.mem.Allocator;
const World = sim_world.World;

pub const report_bytes_max: u32 = 32 * 1024;

pub const Step = enum(u32) {
    done = 0,
    apply_hello,
    kill_one,
    scale_up,
    scale_down,
    apply_broken,
    why_broken,
    store_outage,
    restarts,
    recovery,
    invariants,
    fuzz,
};

pub const Report = struct {
    /// The first step that did not hold, `done` if none.
    failed: Step = .done,
    bytes: [report_bytes_max]u8 = undefined,
    len: u32 = 0,

    pub fn text(report: *const Report) []const u8 {
        assert(report.len <= report_bytes_max);
        return report.bytes[0..report.len];
    }

    /// Appends formatted text; what does not fit is dropped (the verdict is `failed`).
    fn print(report: *Report, comptime format: []const u8, args: anytype) void {
        var writer = std.Io.Writer.fixed(report.bytes[report.len..]);
        writer.print(format, args) catch {};
        report.len += @intCast(writer.buffered().len);
        assert(report.len <= report_bytes_max);
    }
};

/// Good digests the simulated node's store holds, and one it does not (HANDOFF's `b3:00ff…e1`).
const hello_digest = "b3:51aa9c03";
const next_digest = "b3:9d20c4f1";
const broken_digest = "b3:00ff" ++ repeat('0', 55).* ++ "e1";

const fixtures = [_][]const u8{ hello_digest, next_digest };

comptime {
    assert(broken_digest.len == 64);
    assert(broken_digest.len <= constants.image_digest_bytes_max);
}

const Failure = error{StepFailed};

/// One scenario in progress: the world, the API in front of its store, and where it reports.
const Run = struct {
    world: *World,
    api: api_mod.Api,
    report: *Report,
    seed: u64,

    /// Records the step and fails if `ok` is false.
    fn check(run: *Run, step: Step, ok: bool, what: []const u8) Failure!void {
        if (ok) return;
        run.report.failed = step;
        run.report.print("FAILED {s}: {s} (seed {d}, at {d} ms)\n", .{
            @tagName(step), what, run.seed, run.world.now_ms() - sim_world.epoch_ms,
        });
        return error.StepFailed;
    }

    fn say(run: *Run, comptime format: []const u8, args: anytype) void {
        run.report.print(format, args);
    }

    fn input(name: []const u8, image: []const u8, replicas: u32) apply_mod.Input {
        return .{
            .name = name,
            .image = image,
            .replicas = replicas,
            .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
            .applied_by = "alex@laptop",
            .request_id = "r-0000000",
        };
    }

    fn apply(run: *Run, step: Step, spec: apply_mod.Input) Failure!void {
        const result = run.world.apply(spec) catch return run.check(step, false, "apply failed");
        try run.check(step, result == .written, "apply wrote nothing");
    }

    fn api_get(run: *Run, path: []const u8, query: []const u8) api_mod.Response {
        const ctx = run.world.controller_context();
        return run.api.handle(&ctx, .{ .method = "GET", .path = path, .query = query });
    }
};

/// Runs the C0 scenario for `seed`. Returns normally in both outcomes: the verdict is
/// `report.failed`. A violated assertion inside the core is still a crash.
pub fn simulate(gpa: Allocator, seed: u64, report: *Report) void {
    report.* = .{};
    report.print("sim-c0 seed={d}\n", .{seed});
    const world = World.create(gpa, seed, &fixtures) catch {
        report.failed = .apply_hello;
        report.print("FAILED: out of memory\n", .{});
        return;
    };
    defer world.destroy();
    var scenario: Run = .{
        .world = world,
        .api = .{ .version = "0.0.0", .backend = "memory", .started_at_ms = sim_world.epoch_ms },
        .report = report,
        .seed = seed,
    };
    scenario_steps(&scenario) catch {
        assert(report.failed != .done);
        return;
    };
    assert(report.failed == .done);
    report.print("sim-c0: every step held\n", .{});
}

fn scenario_steps(scenario: *Run) Failure!void {
    try apply_hello(scenario);
    try kill_one(scenario);
    try scale(scenario);
    try broken(scenario);
    try outage(scenario);
    try restarts(scenario);
    try recovery(scenario);
    try invariants(scenario, .invariants);
    const world = scenario.world;
    scenario.say("final: revision={d} server_steps={d} agent_steps={d} transactions={d}\n", .{
        world.revision().?,
        world.stats.server_steps,
        world.stats.agent_steps,
        world.stats.transactions,
    });
    scenario.say("store hash: {x:0>16}\n", .{store_hash(world)});
}

// ---- HANDOFF's C0 demo, step by step -----------------------------------------------------------

/// Demo step 1: apply `hello` with 3 replicas; 3 are running within seconds.
fn apply_hello(run: *Run) Failure!void {
    const world = run.world;
    try run.apply(.apply_hello, Run.input("hello", hello_digest, 3));
    world.advance(2000);
    try run.check(.apply_hello, world.running_count("hello") == 3, "3 replicas are not running");
    try run.check(.apply_hello, world.sim.running_count() == 3, "3 containers are not running");
    const status = run.api_get("/v1/status", "");
    try run.check(.apply_hello, status.status == 200, "status is not 200");
    run.say("apply_hello: 3/3 running, store revision {d}\n", .{world.revision().?});
}

/// Demo step 2: `kill -9` one; a replacement starts, and 3 are running again.
fn kill_one(run: *Run) Failure!void {
    const world = run.world;
    var buffer: [constants.node_name_bytes_max]u8 = undefined;
    const victim = world.first_running("hello", &buffer) orelse
        return run.check(.kill_one, false, "no replica is running");
    world.kill(victim) catch return run.check(.kill_one, false, "the runtime does not know it");
    world.advance(3000);
    try run.check(.kill_one, world.running_count("hello") == 3, "3 are not running again");
    try run.check(.kill_one, world.replica_count("hello") == 3, "there are not 3 replicas");
    try run.check(.kill_one, world.sim.running_count() == 3, "3 containers are not running");
    run.say("kill_one: killed {s}, 3/3 running again\n", .{victim});
}

/// Demo step 3: scale to 5 (two more start, the three that run stay), then to 2 (three stop).
fn scale(run: *Run) Failure!void {
    const world = run.world;
    const before = world.running_count("hello");
    try run.check(.scale_up, before == 3, "3 are not running before scaling");
    try run.apply(.scale_up, Run.input("hello", hello_digest, 5));
    world.advance(3000);
    try run.check(.scale_up, world.running_count("hello") == 5, "5 are not running");
    try run.check(.scale_up, world.sim.running_count() == 5, "5 containers are not running");
    try run.apply(.scale_down, Run.input("hello", hello_digest, 2));
    world.advance(3000);
    try run.check(.scale_down, world.running_count("hello") == 2, "2 are not running");
    try run.check(.scale_down, world.replica_count("hello") == 2, "there are not 2 replicas");
    try run.check(.scale_down, world.sim.running_count() == 2, "2 containers are not running");
    run.say("scale: 3 -> 5 -> 2, containers {d}\n", .{world.sim.running_count()});
}

/// Demo step 4: a digest that is not in the store; `why service broken` says why.
fn broken(run: *Run) Failure!void {
    const world = run.world;
    try run.apply(.apply_broken, Run.input("broken", broken_digest, 1));
    world.advance(3000);
    try run.check(.apply_broken, world.running_count("broken") == 0, "broken is running");
    try run.check(.apply_broken, world.replica_count("broken") == 1, "broken is not held");

    const ctx = world.controller_context();
    const result = why_mod.why(&ctx, .{ .kind = .service, .name = "broken" }, null) catch
        return run.check(.why_broken, false, "why failed");
    const text = why_mod.render_text(ctx.arena, &result, false) catch
        return run.check(.why_broken, false, "why could not be rendered");
    const lines = [_][]const u8{
        "service broken: 0/1 running\n",
        "  \u{2190} replica broken-1 failed to start on node1; it was not replaced because " ++
            "a new one would fail the same way\n",
        "  \u{2190} error[ZBX-E0501]: image not found\n",
        "      cause  digest b3:00ff...e1 is not in this node's store\n",
        "      fix    check the digest in the service file, or pull the image first\n",
    };
    var at: usize = 0;
    for (lines) |line| {
        const found = std.mem.indexOfPos(u8, text, at, line);
        try run.check(.why_broken, found != null, "the why chain is not HANDOFF's chain");
        at = found.? + line.len;
    }
    run.say("-- zcube why service broken --\n{s}-- end --\n", .{text});
}

/// Demo step 5: the store goes down. The API says so with a coded diagnostic, the workloads keep
/// running, and a kill that happens meanwhile is noticed once the store is back.
fn outage(run: *Run) Failure!void {
    const world = run.world;
    world.set_store_down(true);
    // Long enough for the server's resync timer to fire (it wakes on a change or every 30 s) and
    // for the node's lease to run out, so the agent has to register again when the store is back.
    world.advance(35_000);
    const status = run.api_get("/v1/status", "");
    try run.check(.store_outage, status.status == 200, "status must answer with the store down");
    try run.check(.store_outage, has(status.body, "\"ok\":false"), "status does not say ok:false");
    try run.check(.store_outage, has(status.body, "ZC-E0201"), "status does not name ZC-E0201");
    const list = run.api_get("/v1/list", "prefix=/services/");
    try run.check(.store_outage, list.status == 503, "list is not 503");
    try run.check(.store_outage, has(list.body, "\"code\":\"ZC-E0201\""), "list lacks ZC-E0201");
    try run.check(.store_outage, has(list.body, "\"fixes\":[{"), "the diagnostic has no fix");
    try run.check(.store_outage, world.sim.running_count() == 2, "workloads stopped");
    try run.check(.store_outage, world.stats.agent_failures > 0, "the agent saw no failure");
    try run.check(.store_outage, world.stats.server_failures > 0, "the server saw no failure");
    const victim = kill_a_container(world) orelse
        return run.check(.store_outage, false, "no container runs to kill");
    run.say("store_outage: 503 ZC-E0201 ({d} bytes), {s} killed meanwhile\n", .{
        list.body.len, victim,
    });
}

/// Kills the process of the first container that runs; the runtime is not the store, so it can.
fn kill_a_container(world: *World) ?[]const u8 {
    for (world.sim.containers.items) |container| {
        if (container.phase == .stopped) continue;
        world.sim.inject(container.name, .{ .signal = 9 }) catch return null;
        return container.name;
    }
    return null;
}

/// Restarting the server core, then the agent core, mid-run: nothing is duplicated or lost.
fn restarts(run: *Run) Failure!void {
    const world = run.world;
    world.restart_server();
    world.advance(1000);
    world.set_store_down(false);
    world.advance(500);
    world.restart_agent();
    world.advance(4000);
    try run.check(.restarts, world.running_count("hello") == 2, "hello is not back to 2");
    try run.check(.restarts, world.sim.running_count() == 2, "a container was duplicated");
    run.say("restarts: server and agent restarted, containers {d}\n", .{world.sim.running_count()});
}

/// With everything back: the state is the one the demo ends in, and a quiet system stays quiet.
fn recovery(run: *Run) Failure!void {
    const world = run.world;
    world.advance(30_000);
    try run.check(.recovery, world.running_count("hello") == 2, "hello is not running 2");
    try run.check(.recovery, world.running_count("broken") == 0, "broken is running");
    try run.check(.recovery, world.sim.running_count() == 2, "containers do not match");
    const before = world.revision().?;
    world.advance(5000);
    const after = world.revision().?;
    // Only the agent's lease keepalive (no revision) happens on a converged system.
    try run.check(.recovery, before == after, "a converged system wrote to the store");
    const lease = run.api_get("/v1/leases", "");
    try run.check(.recovery, has(lease.body, "/nodes/node1"), "the node holds no lease");
    run.say("recovery: converged at revision {d}\n", .{after});
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// What the store and the runtime hold for a service that did not converge, into the report.
fn dump_service(run: *Run, name: []const u8) void {
    const world = run.world;
    var scratch = std.heap.ArenaAllocator.init(world.gpa);
    defer scratch.deinit();
    world.diag.reset();
    const ctx: controller.Context = .{
        .store = world.store_handle(),
        .clock = world.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &world.diag,
    };
    const snapshot = controller.read_snapshot(&ctx) catch return;
    if (snapshot.service_of(name)) |service| {
        const record = service.rec;
        run.say("service {s}: want {d}, generation {d}, image {s}, next {d}\n", .{
            name, record.replicas, record.generation, record.image, record.next_replica,
        });
    }
    for (snapshot.replicas) |replica| {
        if (!std.mem.eql(u8, replica.rec.service, name)) continue;
        const observed = snapshot.observed_of(&replica.rec);
        const status = if (observed) |found| @tagName(found.rec.status) else "none";
        run.say("  replica {s} node={s} generation={d} observed={s}\n", .{
            replica.rec.id, replica.rec.node, replica.rec.generation, status,
        });
    }
    for (world.sim.containers.items) |container| {
        if (!std.mem.startsWith(u8, container.name, name)) continue;
        run.say("  container {s} {s}\n", .{ container.name, @tagName(container.phase) });
    }
}

/// A hash of everything the store holds (keys, values and revisions), so two runs that end in
/// different states cannot print the same report. Zero if the store cannot be read.
fn store_hash(world: *World) u64 {
    var scratch = std.heap.ArenaAllocator.init(world.gpa);
    defer scratch.deinit();
    world.diag.reset();
    const s = world.store_handle();
    var hasher = std.hash.Wyhash.init(0);
    var after: ?[]const u8 = null;
    var at: ?store.Revision = null;
    for (0..1024) |_| {
        const page = s.list(scratch.allocator(), .{
            .prefix = "",
            .at_revision = at,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, &world.diag) catch {
            world.diag.reset();
            return 0;
        };
        at = page.revision;
        for (page.kvs) |kv| {
            hasher.update(kv.key);
            hasher.update(kv.value);
            hasher.update(std.mem.asBytes(&kv.mod_revision));
            hasher.update(std.mem.asBytes(&kv.lease));
        }
        after = page.continue_after;
        if (after == null) break;
    }
    return hasher.final();
}

// ---- Invariants ---------------------------------------------------------------------------------

/// Every action has a decision with a cause, and `why` terminates, for everything in the store.
/// The checks read the store directly; the world must have a store that answers.
fn invariants(run: *Run, step: Step) Failure!void {
    const world = run.world;
    try run.check(step, world.revision() != null, "the store cannot be read");
    const ctx = world.controller_context();
    try decisions_have_causes(run, step, &ctx);
    const snapshot = controller.read_snapshot(&ctx) catch
        return run.check(step, false, "the snapshot cannot be read");
    for (snapshot.services) |service| {
        try why_terminates(run, step, &ctx, .{ .kind = .service, .name = service.rec.name });
    }
    for (snapshot.replicas) |replica| {
        try why_terminates(run, step, &ctx, .{ .kind = .replica, .name = replica.rec.id });
        try replica_has_decisions(run, step, &ctx, &replica.rec);
    }
}

fn why_terminates(
    run: *Run,
    step: Step,
    ctx: *const controller.Context,
    subject: records.Subject,
) Failure!void {
    const result = why_mod.why(ctx, subject, null) catch |err| {
        ctx.diag.reset();
        return run.check(step, err == error.NotFound, "why failed with something but NotFound");
    };
    try run.check(step, result.steps.len <= constants.why_steps_max, "why is too long");
    if (result.steps.len == 0) return;
    const last = result.steps[result.steps.len - 1];
    try run.check(step, last.type != .decision, "a why chain ends in a decision, not a cause");
}

/// Every decision in the store has a well-formed cause, and a cause that names another decision
/// names one that exists (retention has not run for long enough to remove any in a simulation).
fn decisions_have_causes(run: *Run, step: Step, ctx: *const controller.Context) Failure!void {
    var after: ?[]const u8 = null;
    var at: ?store.Revision = null;
    for (0..64) |_| {
        const page = ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_decisions,
            .at_revision = at,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag) catch return run.check(step, false, "the decisions cannot be listed");
        at = page.revision;
        for (page.kvs) |kv| try decision_has_cause(run, step, ctx, kv);
        after = page.continue_after;
        if (after == null) return;
    }
    return run.check(step, false, "there are more decisions than the check reads");
}

fn decision_has_cause(
    run: *Run,
    step: Step,
    ctx: *const controller.Context,
    kv: store.KeyValue,
) Failure!void {
    const decision = records.read(records.Decision, ctx.arena, kv, ctx.diag) catch
        return run.check(step, false, "a decision cannot be read");
    try run.check(step, decision.reason.len > 0, "a decision has no reason");
    const cause = decision.cause;
    switch (cause.kind) {
        .decision => {
            const id = cause.id orelse return run.check(step, false, "a cause names no decision");
            const key = records.decision_key(id);
            const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch
                return run.check(step, false, "a cause cannot be read");
            // Retention may have dropped it (docs/keys.md): then `why` says `gone`. A link that is
            // missing when nothing was dropped was never written, which is the bug to catch.
            const dropped = run.world.decisions_dropped() > 0;
            try run.check(step, got.kv != null or dropped, "a decision's cause was never written");
        },
        .observed, .desired => {
            try run.check(step, cause.key != null, "a cause names no key");
        },
        .lease_expired, .resync => {},
    }
}

fn replica_has_decisions(
    run: *Run,
    step: Step,
    ctx: *const controller.Context,
    replica: *const records.Replica,
) Failure!void {
    const prefix = records.index_prefix(.replica, replica.id);
    const page = ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = 64,
    }, ctx.diag) catch return run.check(step, false, "a replica's decisions cannot be listed");
    var created = false;
    var placed = false;
    for (page.kvs) |kv| {
        const entry = records.read(records.IndexEntry, ctx.arena, kv, ctx.diag) catch
            return run.check(step, false, "an index entry cannot be read");
        if (std.mem.eql(u8, entry.action, "create_replica")) created = true;
        if (std.mem.eql(u8, entry.action, "place_replica")) placed = true;
    }
    try run.check(step, created, "a replica has no create_replica decision");
    if (replica.node.len > 0) try run.check(step, placed, "a placed replica has no place decision");
}

// ---- The fuzz variant ---------------------------------------------------------------------

const service_names = [_][]const u8{ "alpha", "beta", "gamma" };
const images = [_][]const u8{ hello_digest, next_digest, broken_digest };
/// More running containers than desired for this long (with the store up) is a violation.
const excess_ms_max: u64 = 30_000;

/// Runs `operations` random operations drawn from `seed`, heals the world, and checks that it
/// converged and that the invariants hold. The same seed gives the same run, natively and in WASM.
pub fn fuzz(gpa: Allocator, seed: u64, operations: u32, report: *Report) void {
    report.* = .{};
    report.print("sim-c0 fuzz seed={d} operations={d}\n", .{ seed, operations });
    const world = World.create(gpa, seed, &fixtures) catch {
        report.failed = .fuzz;
        report.print("FAILED: out of memory\n", .{});
        return;
    };
    defer world.destroy();
    var scenario: Run = .{
        .world = world,
        .api = .{ .version = "0.0.0", .backend = "memory", .started_at_ms = sim_world.epoch_ms },
        .report = report,
        .seed = seed,
    };
    fuzz_steps(&scenario, operations) catch {
        assert(report.failed != .done);
        return;
    };
    report.print("fuzz: every invariant held; revision={d} transactions={d}\n", .{
        world.revision().?, world.stats.transactions,
    });
    report.print("steps: server={d} agent={d} failures: server={d} agent={d}\n", .{
        world.stats.server_steps,
        world.stats.agent_steps,
        world.stats.server_failures,
        world.stats.agent_failures,
    });
    report.print("store hash: {x:0>16}\n", .{store_hash(world)});
}

fn fuzz_steps(run: *Run, operations: u32) Failure!void {
    var prng = std.Random.DefaultPrng.init(run.seed ^ 0x5eed_c0de);
    var excess: Excess = .{};
    for (0..operations) |index| {
        try operation(run, prng.random());
        try excess.track(run, @intCast(index));
    }
    try heal(run);
    try converged(run);
    try invariants(run, .fuzz);
}

/// How long there have been more running containers than the services want.
const Excess = struct {
    since_ms: ?u64 = null,

    fn track(excess: *Excess, run: *Run, index: u32) Failure!void {
        const world = run.world;
        const wanted = desired_total(world) orelse {
            excess.since_ms = null; // The store is down: nothing can be corrected meanwhile.
            return;
        };
        if (world.sim.running_count() <= wanted) {
            excess.since_ms = null;
            return;
        }
        const now = world.now_ms();
        const since = excess.since_ms orelse now;
        excess.since_ms = since;
        try run.check(.fuzz, now - since <= excess_ms_max, "more containers run than desired");
        _ = index;
    }
};

/// The replicas the existing services want, or null if the store cannot be read.
fn desired_total(world: *World) ?u32 {
    const ctx = world.controller_context();
    const list = controller.list_all(
        records.Service,
        &ctx,
        records.prefix_services,
        null,
        constants.services_max,
    ) catch return null;
    var total: u32 = 0;
    for (list.items) |service| total += service.rec.replicas;
    return total;
}

fn operation(run: *Run, random: std.Random) Failure!void {
    const world = run.world;
    const choice = random.uintLessThan(u32, 100);
    if (choice < 25) {
        world.advance(100 + random.uintLessThan(u32, 3000));
    } else if (choice < 50) {
        const name = service_names[random.uintLessThan(u32, service_names.len)];
        const image = images[random.uintLessThan(u32, images.len)];
        _ = world.apply(Run.input(name, image, random.uintLessThan(u32, 6))) catch {};
    } else if (choice < 56) {
        const name = service_names[random.uintLessThan(u32, service_names.len)];
        _ = world.delete_service(name) catch {};
    } else if (choice < 76) {
        _ = world.sim.random_fault();
    } else if (choice < 84) {
        world.switched.fail_after = 1 + random.uintLessThan(u32, 40);
        world.advance(random.uintLessThan(u32, 40_000));
        world.set_store_down(false);
    } else if (choice < 89) {
        world.restart_server();
    } else if (choice < 94) {
        world.restart_agent();
    } else if (choice < 97) {
        compact(world);
    } else {
        slow_one(world, random);
    }
    world.advance(100);
}

/// A container that ignores the polite stop, if any runs: the agent must still get rid of it.
fn slow_one(world: *World, random: std.Random) void {
    var buffer: [constants.node_name_bytes_max]u8 = undefined;
    const name = service_names[random.uintLessThan(u32, service_names.len)];
    const victim = world.first_running(name, &buffer) orelse return;
    world.sim.inject(victim, .slow_stop) catch {};
}

/// Compaction at the current revision, as the server's maintenance does now and then.
fn compact(world: *World) void {
    const head = world.revision() orelse return;
    if (head < 2) return;
    world.diag.reset();
    world.store_handle().compact(head, &world.diag) catch world.diag.reset();
}

/// The store is switched on, and time runs until everything that can converge has.
fn heal(run: *Run) Failure!void {
    run.world.set_store_down(false);
    run.world.advance(120_000);
}

/// Every service has what it asked for (or is held, if its image is not in the store), and the
/// runtime holds nothing else.
fn converged(run: *Run) Failure!void {
    const world = run.world;
    // The world's own reads below reset its arena, so this read has an arena of its own.
    var scratch = std.heap.ArenaAllocator.init(world.gpa);
    defer scratch.deinit();
    world.diag.reset();
    const ctx: controller.Context = .{
        .store = world.store_handle(),
        .clock = world.manual.clock(),
        .arena = scratch.allocator(),
        .diag = &world.diag,
    };
    const list = controller.list_all(
        records.Service,
        &ctx,
        records.prefix_services,
        null,
        constants.services_max,
    ) catch return run.check(.fuzz, false, "the services cannot be read");
    var running_total: u32 = 0;
    for (list.items) |service| {
        const name = service.rec.name;
        const wanted = service.rec.replicas;
        const good = !std.mem.eql(u8, service.rec.image, broken_digest);
        const running = world.running_count(name);
        running_total += running;
        if (world.replica_count(name) != wanted or (good and running != wanted)) {
            dump_service(run, name);
        }
        try run.check(.fuzz, world.replica_count(name) == wanted, "a service lacks replicas");
        if (good) try run.check(.fuzz, running == wanted, "a good service is not all running");
        if (!good) try run.check(.fuzz, running == 0, "a broken service is running");
    }
    try run.check(.fuzz, world.sim.running_count() == running_total, "containers left behind");
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "the C0 scenario holds, and prints HANDOFF's chain" {
    // Goal: the simulation's own verdict, natively. Method: run it for a few seeds with the
    // testing allocator (which proves nothing leaks) and read the report of the first.
    var report: Report = undefined;
    for ([_]u64{ 1, 2, 3, 0xdead_beef }) |seed| {
        simulate(testing.allocator, seed, &report);
        if (report.failed != .done) std.debug.print("{s}\n", .{report.text()});
        try testing.expectEqual(Step.done, report.failed);
    }
    try testing.expect(has(report.text(), "error[ZBX-E0501]: image not found"));
    try testing.expect(has(report.text(), "sim-c0: every step held"));
}

test "the same seed gives the same report, and different seeds can differ" {
    // Goal: determinism, which is what lets a failure be replayed and native be compared with
    // WASM. Method: run twice and compare the bytes.
    var first: Report = undefined;
    var second: Report = undefined;
    simulate(testing.allocator, 77, &first);
    simulate(testing.allocator, 77, &second);
    try testing.expectEqualStrings(first.text(), second.text());
    fuzz(testing.allocator, 5, 40, &first);
    fuzz(testing.allocator, 5, 40, &second);
    try testing.expectEqualStrings(first.text(), second.text());
}

test "fuzz: random faults, outages and restarts keep the invariants, for many seeds" {
    // Goal: the invariants of the brief under random operations: never more running containers
    // than desired for long, every action has a decision with a cause, `why` terminates, and the
    // world converges once healed. A failure prints its seed; replay with `fuzz(gpa, seed, ...)`.
    var report: Report = undefined;
    for (0..6) |index| {
        const seed: u64 = 1000 + index;
        fuzz(testing.allocator, seed, 80, &report);
        if (report.failed != .done) std.debug.print("{s}\n", .{report.text()});
        try testing.expectEqual(Step.done, report.failed);
    }
}
