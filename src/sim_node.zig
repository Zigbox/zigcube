//! One simulated node's local half: a `SimRuntime` (the containers, which outlive the agent) and
//! a `SimState` (the agent's files, which a crash can leave half written), joined the way the real
//! agent joins them. Core code.
//!
//! A start writes the container's spec (`spec/<name>`, atomically), starts the container, and
//! appends a line to `runs`. A stop stops the container, then removes the spec. A crash at any of
//! those write points makes the call fail with `E0502` and sets `crashed`: the agent is gone, and
//! the cluster simulation builds a new one over the same node with `restart`. The containers keep
//! running through it, as the processes of a real node do, and the new agent finds them by `list`
//! (the replica id is a label on the container), so nothing it needs is in the files; the files
//! hold only what a start must not repeat, and `restart` checks that they are readable.

const std = @import("std");
const assert = std.debug.assert;
const agent_state = @import("agent_state.zig");
const Clock = @import("clock.zig").Clock;
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");
const sim_runtime = @import("sim_runtime.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const SimNode = struct {
    containers: sim_runtime.SimRuntime,
    files: agent_state.SimState,
    /// A write point fired: the agent is dead until `restart`.
    crashed: bool,
    /// How many times the agent has been started again.
    restarts: u32,

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
            .crashed = false,
            .restarts = 0,
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

    /// The agent is started again. What it reads is what the crash left, so a spec that was
    /// written for a container that never started is dropped here, as the real agent drops it.
    pub fn restart(node: *SimNode, scratch: Allocator) agent_state.Error!void {
        node.files.restart();
        node.crashed = false;
        node.restarts += 1;
        const state = node.files.interface();
        for (try state.list(scratch, "spec/")) |name| {
            if (agent_state.is_temp(name)) {
                try state.remove(name);
                continue;
            }
            const spec_text = try state.read(scratch, name);
            assert(spec_text.len > 0);
            const container = name["spec/".len..];
            if (!node.containers.has(container)) {
                try state.remove(name);
            }
        }
    }

    fn from(context: *anyopaque) *SimNode {
        return @ptrCast(@alignCast(context));
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
        var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "spec/{s}", .{spec.name}) catch
            unreachable; // A name is at most 63 bytes and the buffer holds 96.
        const state = node.files.interface();
        state.put_atomic(path, spec.image) catch return node.dead(diag);
        const outcome = try node.containers.interface().start(spec, diag);
        state.append("runs", spec.name) catch return node.dead(diag);
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
        var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "spec/{s}", .{handle.name()}) catch
            unreachable; // A name is at most 63 bytes and the buffer holds 96.
        node.files.interface().remove(path) catch return node.dead(diag);
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

test "a crash at every write point of a start leaves files the restart reads" {
    // Goal: wherever the agent dies while starting a container, the new agent can read what is
    // left, finds no half-written spec, and a second start gives exactly one container. Method:
    // for each write point of a start, and for both kinds of crash, arm the crash there, start,
    // restart, check the files, start again if the container is missing, and count.
    var kind_index: u32 = 0;
    while (kind_index < 2) : (kind_index += 1) {
        const kind: agent_state.CrashKind = if (kind_index == 0) .process else .host;
        var point: u32 = 1;
        while (point <= 3) : (point += 1) {
            var manual: ManualClock = .{};
            var node: SimNode = undefined;
            node.init(testing.allocator, manual.clock(), 7 + point, &sim_runtime.default_fixtures);
            defer node.deinit();
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var diag: Diag = undefined;
            diag.reset();
            node.arm_crash(point, kind);
            const spec = test_spec();
            if (node.interface().start(&spec, &diag)) |_| {
                try testing.expect(!node.crashed);
            } else |_| {
                try testing.expect(node.crashed);
                try testing.expect(diag.code != null);
            }
            try node.restart(arena);
            try testing.expect(!node.crashed);
            for (try node.files.interface().list(arena, "spec/")) |name| {
                try testing.expect(!agent_state.is_temp(name));
            }
            diag.reset();
            if (node.containers.running_count() == 0) {
                const outcome = try node.interface().start(&spec, &diag);
                try testing.expect(outcome == .started);
            }
            try testing.expectEqual(@as(u32, 1), node.containers.running_count());
        }
    }
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
