//! One simulated node's local half: a `SimRuntime` (the containers, which outlive the agent) and
//! a `SimState` (the agent's files, which a crash can leave half written), joined by the code the
//! real agent runs: `agent_records`. Core code.
//!
//! A start writes the container's record (`agent_records.write_spec`), then starts the container.
//! A stop stops the container, then forgets its record (`remove_container`, spec first). A crash
//! at a write point of either, or at a step boundary between them (`arm_step`), makes the call
//! fail with `E0502` and sets `crashed`: the agent is gone, and the cluster simulation builds a
//! new one over the same node with `restart`. The containers keep running through it, as the
//! processes of a real node do, and the new agent finds them by `list` (the replica id is a label
//! on the container). What the files add is the one thing a restart cannot learn from the
//! processes: a record whose container never started, which `restart` drops.

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
    /// Records `restart` dropped because their container never started.
    dropped: u32,
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
            .dropped = 0,
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

    /// The agent is started again. What it reads is what the crash left: a record of a container
    /// that never started is dropped here, as the real agent drops it. An empty or damaged record
    /// is no container (`scan` skips it), never an error.
    pub fn restart(node: *SimNode, scratch: Allocator) agent_state.Error!void {
        node.files.restart();
        node.crashed = false;
        node.step_crash = null;
        node.restarts += 1;
        const state = node.files.interface();
        for (try agent_records.scan(state, scratch)) |record| {
            if (node.containers.has(record.name)) continue;
            try agent_records.remove_container(state, scratch, record.name);
            node.dropped += 1;
        }
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

    fn start_impl(
        context: *anyopaque,
        spec: *const runtime.Spec,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        const node = from(context);
        assert(!node.crashed);
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
        if (!agent_records.has_image(node.containers.fixtures, spec.image)) {
            // Refused before anything is written, as the real agent does.
            return node.containers.interface().start(spec, diag);
        }
        const state = node.files.interface();
        agent_records.write_spec(state, &record) catch return node.dead(diag);
        if (node.step()) return node.dead(diag);
        const outcome = try node.containers.interface().start(spec, diag);
        assert(outcome == .started); // The image is known; a failed command is not simulated.
        if (node.step()) return node.dead(diag);
        return outcome;
    }

    fn stop_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        grace_ms: u32,
        diag: *Diag,
    ) runtime.Error!void {
        const node = from(context);
        assert(!node.crashed);
        try node.containers.interface().stop(handle, grace_ms, diag);
        if (node.step()) return node.dead(diag);
        node.forget(handle.name()) catch return node.dead(diag);
    }

    fn forget(node: *SimNode, name: []const u8) agent_state.Error!void {
        var arena_state = std.heap.ArenaAllocator.init(node.files.gpa);
        defer arena_state.deinit();
        try agent_records.remove_container(node.files.interface(), arena_state.allocator(), name);
    }

    fn inspect_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        return from(context).containers.interface().inspect(handle, diag);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        return from(context).containers.interface().list(arena, diag);
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
    /// After a start: a record of a container that never started, dropped by the restart.
    dropped: u32 = 0,
    /// A container runs, with its record.
    running: u32 = 0,
    /// After a stop: the container is stopped and its record is still there.
    stopped_kept: u32 = 0,
    /// After a stop: the container is stopped and its record is gone.
    stopped_gone: u32 = 0,
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
    try node.restart(arena);
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
        try testing.expectEqual(@as(usize, 0), records.len);
        if (node.dropped == 1) outcomes.dropped += 1 else outcomes.nothing += 1;
    } else if (records.len == 1) {
        outcomes.stopped_kept += 1;
    } else {
        outcomes.stopped_gone += 1;
    }
    // The agent starts the container again if it is not running: exactly one then runs.
    diag.reset();
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
    try testing.expect(outcomes.dropped > 0);
    try testing.expect(outcomes.running > 0);
    try testing.expectEqual(@as(u32, 0), outcomes.stopped_kept + outcomes.stopped_gone);
}

test "a crash at every write point and step of a stop leaves records the restart reads" {
    // Goal: as for a start, for a stop (the container stops, then its record goes, spec first).
    // The outcomes: still running, stopped with its record kept, stopped with it gone.
    const outcomes = try crash_all(.stop, 4, 1);
    try testing.expect(outcomes.running > 0);
    try testing.expect(outcomes.stopped_kept > 0);
    try testing.expect(outcomes.stopped_gone > 0);
    try testing.expectEqual(@as(u32, 0), outcomes.nothing + outcomes.dropped);
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
    try node.restart(arena_state.allocator());
    try testing.expectEqual(@as(u32, 0), node.dropped);
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
    // Goal: adoption needs nothing from the files. Method: start, crash the agent on the
    // next write, restart, and list: the container is there with its replica label.
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
    node.arm_crash(1, .process);
    diag.reset();
    const handle = runtime.Handle.init("web-1");
    try testing.expectError(error.RuntimeFailed, node.interface().stop(handle, 0, &diag));
    try testing.expect(node.crashed);
    try node.restart(arena);
    diag.reset();
    const listing = try node.interface().list(arena, &diag);
    try testing.expectEqual(@as(usize, 1), listing.len);
    try testing.expectEqualStrings("r1", listing[0].labels[0].value);
}
