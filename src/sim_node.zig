//! One simulated node's local half: a `SimRuntime` (the containers, which outlive the agent) and
//! a `SimState` (the agent's files, which a crash can leave half written), joined by the code the
//! real agent runs: `agent_records`. Core code. It behaves like `FakeRuntime` wherever the server
//! can see the difference: the same order of writes, the same decisions (`agent_records.classify`
//! over `Facts` taken from the processes), the same diagnostics.
//!
//! A start makes room (the oldest stopped container's record goes when the node is full), writes
//! the container's record (`agent_records.write_spec`), then starts the container. A stop stops
//! the container and keeps its record, as `FakeRuntime` does: the record goes only when
//! `make_room` evicts it. A crash at a write point of either, or at a step boundary between them
//! (`arm_step`), makes the call fail with `E0502` and sets `crashed`: the agent is gone, and the
//! cluster simulation builds a new one over the same node with `restart`. The containers keep
//! running through it, as the processes of a real node do. A record whose container never started
//! is `starting` until `fake_start_timeout_ms` has passed on the node's clock, then `lost`
//! (ZC-E0509, recorded once in `run.json`), and stays until it is evicted.

const std = @import("std");
const assert = std.debug.assert;
const agent_records = @import("agent_records.zig");
const agent_state = @import("agent_state.zig");
const Clock = @import("clock.zig").Clock;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");
const sim_runtime = @import("sim_runtime.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const SimNode = struct {
    containers: sim_runtime.SimRuntime,
    files: agent_state.SimState,
    clock: Clock,
    /// A write point or step boundary fired: the agent is dead until `restart`.
    crashed: bool,
    /// How many times the agent has been started again.
    restarts: u32,
    /// The crash at a step boundary: how many boundaries are left, and of which kind.
    step_crash: ?struct { left: u32, kind: agent_state.CrashKind },

    const vtable: runtime.Runtime.VTable = .{
        .start = start_impl,
        .stop = stop_impl,
        .inspect = inspect_impl,
        .list = list_impl,
        .events = events_impl,
    };

    pub fn init(
        node: *SimNode,
        gpa: Allocator,
        clock: Clock,
        seed: u64,
        fixtures: []const []const u8,
    ) void {
        node.* = .{
            .containers = undefined,
            .files = .init(gpa, seed ^ 0x5eed),
            .clock = clock,
            .crashed = false,
            .restarts = 0,
            .step_crash = null,
        };
        node.containers.init(gpa, clock, seed, fixtures);
    }

    pub fn deinit(node: *SimNode) void {
        node.files.deinit();
        node.containers.deinit();
        node.* = undefined;
    }

    /// The runtime the agent on this node uses.
    pub fn interface(node: *SimNode) runtime.Runtime {
        return .{ .context = node, .vtable = &vtable };
    }

    /// The agent's crash fires at the `after`th write point from now.
    pub fn arm_crash(node: *SimNode, after: u32, kind: agent_state.CrashKind) void {
        assert(!node.crashed);
        node.files.arm_crash(after, kind);
    }

    /// The agent's crash fires at the `after`th step boundary from now: a start has two (the
    /// record is written; the container is started), a stop has one (the container is stopped).
    pub fn arm_step(node: *SimNode, after: u32, kind: agent_state.CrashKind) void {
        assert(!node.crashed);
        assert(after > 0);
        node.step_crash = .{ .left = after, .kind = kind };
    }

    /// The agent dies now, between two calls.
    pub fn crash_now(node: *SimNode, kind: agent_state.CrashKind) void {
        assert(!node.crashed);
        node.files.crash_now(kind);
        node.crashed = true;
    }

    /// The agent is started again. It reads nothing here: what the crash left (records, even of
    /// containers that never started) is found by the first `list`, as the real agent finds it.
    pub fn restart(node: *SimNode) void {
        node.files.restart();
        node.crashed = false;
        node.step_crash = null;
        node.restarts += 1;
    }

    fn from(context: *anyopaque) *SimNode {
        return @ptrCast(@alignCast(context));
    }

    /// Counts a step boundary; true if the agent dies here.
    fn step(node: *SimNode) bool {
        const armed = node.step_crash orelse return false;
        if (armed.left > 1) {
            node.step_crash = .{ .left = armed.left - 1, .kind = armed.kind };
            return false;
        }
        node.step_crash = null;
        node.files.crash_now(armed.kind);
        return true;
    }

    /// Fails the call the way a dead agent would: nothing more happens on this node.
    fn dead(node: *SimNode, diag: *Diag) runtime.Error {
        assert(diag.code == null);
        node.crashed = true;
        diag.raise(.E0502);
        diag.cause("the simulated agent crashed at a write point", .{});
        diag.fix(.{ .sentence = "start the agent again" });
        return error.RuntimeFailed;
    }

    /// A failed state operation as its diagnostic: the simulated crash is the agent dying, any
    /// other error is what `FakeRuntime` reports for it.
    fn state_failed(
        node: *SimNode,
        diag: *Diag,
        err: agent_state.Error,
        operation: []const u8,
    ) runtime.Error {
        if (err == error.Crashed) return node.dead(diag);
        return agent_records.state_failed(diag, err, operation);
    }

    fn start_impl(
        context: *anyopaque,
        spec: *const runtime.Spec,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        const node = from(context);
        assert(!node.crashed);
        if (!agent_records.has_image(node.containers.fixtures, spec.image)) {
            // Refused before anything is written, as the real agent does.
            return node.containers.interface().start(spec, diag);
        }
        var arena_state = std.heap.ArenaAllocator.init(node.files.gpa);
        defer arena_state.deinit();
        try node.make_room(arena_state.allocator(), spec.name, diag);
        var labels: [constants.runtime_labels_max]agent_records.Pair = undefined;
        var env: [constants.runtime_env_count_max]agent_records.Pair = undefined;
        assert(spec.labels.len <= labels.len);
        assert(spec.env.len <= env.len);
        for (spec.labels, labels[0..spec.labels.len]) |label, *pair| {
            pair.* = .{ label.key, label.value };
        }
        for (spec.env, env[0..spec.env.len]) |entry, *pair| pair.* = .{ entry.name, entry.value };
        const record: agent_records.SpecFile = .{
            .name = spec.name,
            .image = spec.image,
            .command = spec.command,
            .env = env[0..spec.env.len],
            .labels = labels[0..spec.labels.len],
            .started_at_ms = node.clock.now_ms(),
        };
        agent_records.write_spec(node.files.interface(), &record) catch |err| switch (err) {
            error.TooBig => return agent_records.too_large(diag, spec.name),
            else => |other| return node.state_failed(diag, other, "write the container's record"),
        };
        if (node.step()) return node.dead(diag);
        const outcome = try node.containers.interface().start(spec, diag);
        assert(outcome == .started); // The image is known; a failed command is not simulated.
        if (node.step()) return node.dead(diag);
        return outcome;
    }

    /// The node holds at most `fake_containers_max` containers: when full, the oldest stopped
    /// one goes, record and container; if none has stopped it cannot take another. A stopped
    /// container of the same name is replaced. `FakeRuntime.make_room` does the same.
    fn make_room(
        node: *SimNode,
        arena: Allocator,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!void {
        const state = node.files.interface();
        const records = agent_records.scan(state, arena) catch |err|
            return node.state_failed(diag, err, "read the containers' records");
        var oldest: ?agent_records.Record = null;
        for (records) |record| {
            const stopped = (try node.status_of_record(arena, &record, diag)) == .stopped;
            const same = std.mem.eql(u8, record.name, name);
            if (same) assert(stopped);
            if (!stopped) continue;
            if (same) {
                oldest = record;
                break;
            }
            const older = if (oldest) |best|
                record.spec.started_at_ms < best.spec.started_at_ms
            else
                true;
            if (older) oldest = record;
        }
        const replaced = if (oldest) |record| std.mem.eql(u8, record.name, name) else false;
        const full = records.len >= constants.fake_containers_max;
        if (!full and !replaced) return;
        const victim = oldest orelse {
            assert(diag.code == null);
            diag.raise(.E0502);
            diag.cause("can't hold another container", .{});
            diag.fix(.{ .sentence = "check the agent's state directory and the host's limits" });
            return error.RuntimeFailed;
        };
        agent_records.remove_container(state, arena, victim.name) catch |err|
            return node.state_failed(diag, err, "remove an old container's record");
        node.containers.evict(victim.name);
    }

    fn stop_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        grace_ms: u32,
        diag: *Diag,
    ) runtime.Error!void {
        const node = from(context);
        assert(!node.crashed);
        var arena_state = std.heap.ArenaAllocator.init(node.files.gpa);
        defer arena_state.deinit();
        const state = node.files.interface();
        const read = agent_records.read_spec(state, arena_state.allocator(), handle.name());
        const found = read catch |err|
            return node.state_failed(diag, err, "read the container's record");
        if (found == null) return agent_records.not_found(diag, handle.name());
        // A record whose container never started has nothing to stop; its record stays.
        if (node.containers.has(handle.name())) {
            try node.containers.interface().stop(handle, grace_ms, diag);
        }
        if (node.step()) return node.dead(diag);
    }

    fn inspect_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const node = from(context);
        var arena_state = std.heap.ArenaAllocator.init(node.files.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const read = agent_records.read_spec(node.files.interface(), arena, handle.name());
        const spec = (read catch |err|
            return node.state_failed(diag, err, "read the container's record")) orelse
            return agent_records.not_found(diag, handle.name());
        return node.status_of_record(arena, &.{ .name = handle.name(), .spec = spec }, diag);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        const node = from(context);
        var listings: std.ArrayList(runtime.Listing) = .empty;
        const records = agent_records.scan(node.files.interface(), arena) catch |err|
            return node.state_failed(diag, err, "read the containers' records");
        for (records) |record| {
            if (listings.items.len == constants.runtime_handles_max) break;
            const labels = arena.alloc(runtime.Label, record.spec.labels.len) catch
                return agent_records.state_failed(diag, error.OutOfMemory, "list");
            for (record.spec.labels, labels) |pair, *slot| {
                slot.* = .{ .key = pair[0], .value = pair[1] };
            }
            listings.append(arena, .{
                .handle = runtime.Handle.init(record.name),
                .labels = labels,
                .status = try node.status_of_record(arena, &record, diag),
            }) catch return agent_records.state_failed(diag, error.OutOfMemory, "list");
        }
        std.mem.sort(runtime.Listing, listings.items, {}, listing_less);
        return listings.items;
    }

    fn listing_less(_: void, first: runtime.Listing, second: runtime.Listing) bool {
        return std.mem.lessThan(u8, first.handle.name(), second.handle.name());
    }

    /// The status of one container with a record: `agent_records.classify` over what the
    /// processes and `run.json` say, exactly as `FakeRuntime` decides it. A container whose
    /// supervisor is gone without a record of how it ended is declared lost once.
    fn status_of_record(
        node: *SimNode,
        arena: Allocator,
        record: *const agent_records.Record,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const state = node.files.interface();
        const name = record.name;
        const written = agent_records.read_run(state, arena, name) catch |err|
            return node.state_failed(diag, err, "read the container's result");
        var facts: agent_records.Facts = .{
            .run = written,
            .supervisor_alive = false,
            .child_exists = false,
            .supervisor_pid_exists = false,
            .age_ms = node.clock.now_ms() -| record.spec.started_at_ms,
        };
        switch (node.containers.process(name)) {
            .absent => {},
            .alive => {
                facts.supervisor_alive = true;
                facts.child_exists = true;
            },
            .ended => |run| {
                facts.supervisor_pid_exists = true;
                if (facts.run == null) facts.run = run;
            },
            .vanished => facts.supervisor_pid_exists = true,
        }
        switch (agent_records.classify(facts)) {
            .stopped => |run| return agent_records.stopped_by(name, run),
            .running => return .running,
            .starting => return .starting,
            .declare_lost => {
                const lost: agent_records.RunFile = .{ .kind = .lost };
                agent_records.write_run(state, name, &lost) catch |err| {
                    // The next look tries again, unless the agent died writing it.
                    if (err == error.Crashed) return node.dead(diag);
                };
                return agent_records.stopped_by(name, lost);
            },
        }
    }

    fn events_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        return from(context).containers.interface().events(arena, timeout_ms, diag);
    }
};

// ---- Tests ----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;

const test_labels = [_]runtime.Label{.{ .key = runtime.label_replica, .value = "r1" }};

fn test_spec() runtime.Spec {
    return .{
        .name = "web-1",
        .image = sim_runtime.default_fixtures[0],
        .command = &.{"serve"},
        .labels = &test_labels,
    };
}

/// Where a crash is put: at a write point, at a step boundary, or just before the call.
const Where = union(enum) { write_point: u32, step: u32, before };

const Op = enum { start, stop };

const Outcomes = struct {
    /// After a start: no record, no container.
    nothing: u32 = 0,
    /// After a start: a record of a container that never started (`starting`, then `lost`).
    starting: u32 = 0,
    /// A container runs, with its record.
    running: u32 = 0,
    /// After a stop: the container is stopped and its record is still there.
    stopped: u32 = 0,
};

fn crash_case(
    op: Op,
    where: Where,
    kind: agent_state.CrashKind,
    seed: u64,
    outcomes: *Outcomes,
) !void {
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), seed, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const spec = test_spec();
    const handle = runtime.Handle.init("web-1");
    if (op == .stop) _ = try node.interface().start(&spec, &diag);
    switch (where) {
        .write_point => |point| node.arm_crash(point, kind),
        .step => |count| node.arm_step(count, kind),
        .before => node.crash_now(kind),
    }
    if (where != .before) {
        const result = switch (op) {
            .start => if (node.interface().start(&spec, &diag)) |_| {} else |err| err,
            .stop => node.interface().stop(handle, 0, &diag),
        };
        if (result) |_| {
            try testing.expect(!node.crashed);
        } else |err| {
            try testing.expectEqual(error.RuntimeFailed, err);
            try testing.expect(node.crashed);
            try testing.expect(diag.code != null);
        }
    }
    node.restart();
    try testing.expect(!node.crashed);
    for (try node.files.interface().list(arena, agent_records.dir_containers)) |name| {
        try testing.expect(!agent_state.is_temp(name));
    }
    const records = try agent_records.scan(node.files.interface(), arena);
    try testing.expect(records.len <= 1);
    const running = node.containers.running_count();
    try testing.expect(running <= 1);
    if (running == 1) {
        outcomes.running += 1;
        try testing.expectEqual(@as(usize, 1), records.len);
    } else if (op == .start) {
        if (records.len == 1) outcomes.starting += 1 else outcomes.nothing += 1;
    } else {
        // A stop never forgets the record.
        try testing.expectEqual(@as(usize, 1), records.len);
        outcomes.stopped += 1;
    }
    try start_again(&node, &manual, arena, op, running, records.len);
}

/// What the agent does after a restart: finds a record without a running container by listing
/// (a start that never ran is `starting` until the timeout, then lost; a stopped container is
/// stopped), and starts the container again if it is not running: exactly one then runs.
fn start_again(
    node: *SimNode,
    manual: *ManualClock,
    arena: Allocator,
    op: Op,
    running: u32,
    records: usize,
) !void {
    var diag: Diag = undefined;
    diag.reset();
    const spec = test_spec();
    if (running == 0 and records == 1) {
        // The agent finds the record by listing: a start that never ran is `starting` until the
        // timeout and then lost, a stopped container is stopped.
        const before = try node.interface().list(arena, &diag);
        try testing.expectEqual(@as(usize, 1), before.len);
        manual.advance(constants.fake_start_timeout_ms);
        const after_wait = try node.interface().list(arena, &diag);
        try testing.expect(after_wait[0].status == .stopped);
        if (op == .start) {
            try testing.expect(before[0].status == .starting);
            try testing.expect(after_wait[0].status.stopped == .lost);
            const lost = after_wait[0].status.stopped.lost.?;
            try testing.expectEqualStrings("ZC-E0509", lost.code.slice());
        }
    }
    // A container that is not running is started again: exactly one then runs.
    if (running == 0) {
        const outcome = try node.interface().start(&spec, &diag);
        try testing.expect(outcome == .started);
    }
    try testing.expectEqual(@as(u32, 1), node.containers.running_count());
    const after = try agent_records.scan(node.files.interface(), arena);
    try testing.expectEqual(@as(usize, 1), after.len);
}

fn crash_all(op: Op, points_max: u32, steps_max: u32) !Outcomes {
    var outcomes: Outcomes = .{};
    for ([_]agent_state.CrashKind{ .process, .host }) |kind| {
        for (0..64) |seed| {
            try crash_case(op, .before, kind, seed, &outcomes);
            for (1..steps_max + 1) |count| {
                try crash_case(op, .{ .step = @intCast(count) }, kind, seed, &outcomes);
            }
            for (1..points_max + 1) |point| {
                try crash_case(op, .{ .write_point = @intCast(point) }, kind, seed, &outcomes);
            }
        }
    }
    return outcomes;
}

test "a crash at every write point and step of a start leaves records the restart reads" {
    // Goal: wherever the agent dies while starting a container, the new agent reads what is left
    // and a second start gives exactly one container. Method: for the call, each of the write
    // points (a spec write is the stale removals and a two-point put), each step boundary and
    // just before it, both crash kinds, 64 seeds: crash, restart, check the files, start again
    // if nothing runs, and count. The counts assert that each outcome the model allows occurs.
    const outcomes = try crash_all(.start, 8, 2);
    try testing.expect(outcomes.nothing > 0);
    try testing.expect(outcomes.starting > 0);
    try testing.expect(outcomes.running > 0);
    try testing.expectEqual(@as(u32, 0), outcomes.stopped);
}

test "a crash at every write point and step of a stop leaves records the restart reads" {
    // Goal: as for a start, for a stop (the container stops; its record stays, as in
    // `FakeRuntime`). The outcomes: still running, or stopped with its record kept.
    const outcomes = try crash_all(.stop, 1, 1);
    try testing.expect(outcomes.running > 0);
    try testing.expect(outcomes.stopped > 0);
    try testing.expectEqual(@as(u32, 0), outcomes.nothing + outcomes.starting);
}

test "a restart reads an empty or damaged record as no container" {
    // Goal: what a host crash can leave of a file never panics the restart. Method: plant an
    // empty record, a damaged one and a stray temporary file, then restart.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 5, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const files = node.files.interface();
    try files.put_atomic("containers/web-1/spec.json", "");
    try files.put_atomic("containers/web-2/spec.json", "{not json");
    try files.put_atomic("containers/web-3/spec.json.tmp", "{}");
    node.crash_now(.host);
    node.restart();
    const left = try agent_records.scan(files, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), left.len);
}

test "a start of an unknown image is refused and writes nothing" {
    // Goal: the simulation refuses as the real agent does. Method: start an image the node lacks
    // and check the outcome, the files and that no write point was passed.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 9, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    var spec = test_spec();
    spec.image = "b3:00000000";
    const outcome = try node.interface().start(&spec, &diag);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(@as(u32, 0), node.files.points);
    try testing.expectEqual(@as(usize, 0), (try agent_records.scan(
        node.files.interface(),
        arena_state.allocator(),
    )).len);
    try testing.expectEqual(@as(u32, 0), node.containers.running_count());
}

test "containers outlive the agent: a restart finds them by listing" {
    // Goal: a restarted agent finds its containers by listing. Method: start, stop the
    // container and crash the agent at the step boundary after it, restart, and list: the
    // container is there with its replica label and the status it ended with.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 3, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const spec = test_spec();
    _ = try node.interface().start(&spec, &diag);
    node.arm_step(1, .process);
    diag.reset();
    const handle = runtime.Handle.init("web-1");
    try testing.expectError(error.RuntimeFailed, node.interface().stop(handle, 0, &diag));
    try testing.expect(node.crashed);
    node.restart();
    diag.reset();
    const listing = try node.interface().list(arena, &diag);
    try testing.expectEqual(@as(usize, 1), listing.len);
    try testing.expectEqualStrings("r1", listing[0].labels[0].value);
    try testing.expectEqual(@as(u8, 15), listing[0].status.stopped.signaled);
}

test "a record whose container never started is starting, then lost" {
    // Goal: production's view of a record whose container never started (N1): `starting` until
    // `fake_start_timeout_ms` on the node's clock, then `lost` with ZC-E0509, the record kept and
    // the verdict made once. Method: crash at the step after `write_spec`, restart, look three
    // times (young, old, older), restart again, look again.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 11, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const spec = test_spec();
    const handle = runtime.Handle.init("web-1");
    node.arm_step(1, .host);
    try testing.expectError(error.RuntimeFailed, node.interface().start(&spec, &diag));
    try testing.expect(node.crashed);
    try testing.expectEqual(@as(u32, 0), node.containers.running_count());
    node.restart();

    diag.reset();
    manual.advance(constants.fake_start_timeout_ms - 1);
    try testing.expect((try node.interface().inspect(handle, &diag)) == .starting);
    const young = try node.interface().list(arena, &diag);
    try testing.expectEqual(@as(usize, 1), young.len);
    try testing.expect(young[0].status == .starting);

    manual.advance(1);
    const old = try node.interface().list(arena, &diag);
    try testing.expectEqual(@as(usize, 1), old.len);
    const lost = old[0].status.stopped.lost.?;
    try testing.expectEqualStrings("ZC-E0509", lost.code.slice());
    const run = try agent_records.read_run(node.files.interface(), arena, "web-1");
    try testing.expectEqual(agent_records.RunKind.lost, run.?.kind);

    manual.advance(5 * constants.fake_start_timeout_ms);
    node.crash_now(.process);
    node.restart();
    const later = try node.interface().inspect(handle, &diag);
    try testing.expectEqualStrings("ZC-E0509", later.stopped.lost.?.code.slice());
    const kept = try agent_records.scan(node.files.interface(), arena);
    try testing.expectEqual(@as(usize, 1), kept.len);
}

test "a stop keeps the record; make_room evicts the oldest stopped one before the spec is written" {
    // Goal: the node holds `fake_containers_max` containers and a start at the limit evicts the
    // oldest stopped one, record and container, then writes its own (N3). Method: fill the node
    // with stopped containers (each older than the next), start one more, and look.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 12, &sim_runtime.default_fixtures);
    defer node.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    var name_buffer: [16]u8 = undefined;
    for (0..constants.fake_containers_max) |index| {
        diag.reset();
        // 16 bytes hold "c-" and a number.
        const name = std.fmt.bufPrint(&name_buffer, "c-{d}", .{index}) catch unreachable;
        var spec = test_spec();
        spec.name = name;
        _ = try node.interface().start(&spec, &diag);
        try node.interface().stop(runtime.Handle.init(name), 0, &diag);
        manual.advance(1);
    }
    const full = try agent_records.scan(node.files.interface(), arena);
    try testing.expectEqual(@as(usize, constants.fake_containers_max), full.len);
    diag.reset();
    var spec = test_spec();
    spec.name = "fresh-1";
    _ = try node.interface().start(&spec, &diag);
    const after = try agent_records.scan(node.files.interface(), arena);
    try testing.expectEqual(@as(usize, constants.fake_containers_max), after.len);
    try testing.expect(!node.containers.has("c-0"));
    try testing.expect(node.containers.has("c-1"));
    try testing.expect(node.containers.has("fresh-1"));
}

test "a long run with crashes never fills the state" {
    // Goal: `SimState` holds the records of a full node with their files, so a long run with
    // faults never fails for room (N4: it once did, and the failure was called a crash). Method:
    // more starts than the node holds, each stopped, with a crash armed at a random write point
    // or step now and then; after a crash restart and stop what runs. Only a crash may fail a call.
    var manual: ManualClock = .{};
    var node: SimNode = undefined;
    node.init(testing.allocator, manual.clock(), 13, &sim_runtime.default_fixtures);
    defer node.deinit();
    var prng: std.Random.DefaultPrng = .init(13);
    const random = prng.random();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    var name_buffer: [16]u8 = undefined;
    var crashes: u32 = 0;
    for (0..constants.fake_containers_max + 140) |index| {
        diag.reset();
        // 16 bytes hold "c-" and a number.
        const name = std.fmt.bufPrint(&name_buffer, "c-{d}", .{index}) catch unreachable;
        var spec = test_spec();
        spec.name = name;
        if (random.uintLessThan(u32, 4) == 0) {
            const kind: agent_state.CrashKind = if (random.boolean()) .host else .process;
            if (random.boolean()) {
                node.arm_crash(random.intRangeAtMost(u32, 1, 6), kind);
            } else node.arm_step(random.intRangeAtMost(u32, 1, 3), kind);
        }
        const started = node.interface().start(&spec, &diag);
        if (started) |_| {
            if (!node.crashed) {
                diag.reset();
                node.interface().stop(runtime.Handle.init(name), 0, &diag) catch {};
            }
        } else |err| {
            try testing.expectEqual(error.RuntimeFailed, err);
        }
        if (node.crashed) {
            crashes += 1;
            try testing.expectEqual(@as(?@TypeOf(diag.code.?), .E0502), diag.code);
            node.restart();
            _ = arena_state.reset(.retain_capacity);
            diag.reset();
            for (try node.interface().list(arena_state.allocator(), &diag)) |listing| {
                if (listing.status != .running) continue;
                diag.reset();
                try node.interface().stop(listing.handle, 0, &diag);
            }
        } else try testing.expect(diag.code == null);
        manual.advance(1);
    }
    try testing.expect(crashes > 0);
    const left = try agent_records.scan(node.files.interface(), arena_state.allocator());
    try testing.expect(left.len <= constants.fake_containers_max);
}
