//! `Runtime`: what the node agent drives, and the contract with Zigbox. Zigbox implements it as
//! a library (the `zigbox` module, wrapped by an adapter that arrives with the real runtime);
//! `FakeRuntime` implements it now. Controllers and the agent's reconcile loop know only this.
//!
//! The shape follows the `zigbox` module as built (Zigbox `src/zigbox.zig`, `src/runtime/run.zig`)
//! and differs from HANDOFF's first sketch where that module made a different thing necessary.
//! Every difference, and every choice HANDOFF left open, is listed in docs/contracts-review.md
//! for the owner to approve. In short:
//!
//!   - A container is named by a small, copyable, serialisable `Handle` (its name), not by
//!     Zigbox's `Handle` struct, which is several kilobytes, holds pointers into itself and the
//!     `Spec`, cannot move, and cannot outlive the process. The adapter keeps those in a pool.
//!   - There is no blocking `wait`: status changes are read with `events`, and `inspect` and
//!     `list` give the truth at any time. The agent reconciles by level, so a lost event is
//!     recovered by the next `list`.
//!   - A start that fails is not an error of the call but an outcome: `StartOutcome.failed`
//!     carries the `Diagnostic`, which may belong to Zigbox's registry (`ZBX-E0501`).
//!
//! ## Failure and memory
//!
//! Operational failures of the runtime itself return `Error` with a `ZC-` diagnostic in the
//! `*Diag`, as in `store.zig`. Results that hold slices (`list`, `events`) are allocated from
//! the caller's arena and valid until it is reset; the runtime keeps no reference to the
//! caller's `Spec` after `start` returns, because it copies what it needs.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

pub const Error = error{
    /// The runtime has no container of that name.
    NotFound,
    /// The runtime could not do what was asked of it (not a workload's own failure).
    RuntimeFailed,
};

/// A container's name: a hostname label, lowercase letters, digits and '-', at most 63 bytes,
/// not starting or ending with '-' (the same rule as Zigbox's container names). The agent
/// uses the replica's id, which is how a restarted agent matches containers to replicas.
pub const name_bytes_max: u32 = 63;

pub const Handle = struct {
    bytes: [name_bytes_max]u8,
    len: u8,

    pub fn init(text: []const u8) Handle {
        assert(name_problem(text) == null);
        var handle: Handle = .{ .bytes = undefined, .len = @intCast(text.len) };
        @memcpy(handle.bytes[0..text.len], text);
        return handle;
    }

    pub fn name(handle: *const Handle) []const u8 {
        assert(handle.len > 0);
        assert(handle.len <= name_bytes_max);
        return handle.bytes[0..handle.len];
    }

    pub fn eql(first: *const Handle, second: *const Handle) bool {
        return std.mem.eql(u8, first.name(), second.name());
    }
};

pub const Label = struct { key: []const u8, value: []const u8 };
pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// The label every container carries so that a restarted agent can re-adopt it.
pub const label_replica = "zcube.replica";
/// The image digest the container was started for, and the store revision its replica key was
/// created at (decimal): together they tell a container from an earlier replica with the same
/// id (a service deleted and applied again) from this one's.
pub const label_image = "zcube.image";
pub const label_created = "zcube.created";

pub const Limits = struct {
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    pids: ?u32 = null,
};

pub const Spec = struct {
    /// The container's name and its `Handle`. Unique among containers that have not stopped.
    name: []const u8,
    /// Tree digest, e.g. "b3:51aa…9c03". Until images exist (Zigbox M4) the Zigbox adapter
    /// maps it to a root directory.
    image: []const u8,
    command: []const []const u8,
    env: []const EnvVar = &.{},
    limits: Limits = .{},
    /// Must include `label_replica`.
    labels: []const Label,
};

/// Why a container ended. `oom` and `pid_limit` are produced once Zigbox has cgroups (M2).
pub const ExitReason = union(enum) {
    exited: u8,
    signaled: u8,
    /// The memory limit was hit.
    oom,
    pid_limit,
    /// It never started; the diagnostic says why, and may carry a `ZBX-` code.
    start_failed: Diagnostic,
    /// The container's supervisor died or its process vanished. The diagnostic, when the runtime
    /// has one, says which of the two (Zigbox keeps the explanation it computed in its handle);
    /// null means it truly does not know.
    lost: ?Diagnostic,
};

pub const Status = union(enum) {
    starting,
    running,
    stopped: ExitReason,
};

/// What `start` came to. A container that did not start is an outcome, not an `Error`: the
/// agent records the diagnostic as the replica's observed state, as it would any exit reason.
pub const StartOutcome = union(enum) {
    started: Handle,
    failed: Diagnostic,
};

pub const Listing = struct {
    handle: Handle,
    labels: []const Label,
    status: Status,
};

pub const StatusChange = struct {
    handle: Handle,
    status: Status,
};

pub const Runtime = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (context: *anyopaque, spec: *const Spec, diag: *Diag) Error!StartOutcome,
        stop: *const fn (
            context: *anyopaque,
            handle: Handle,
            grace_ms: u32,
            diag: *Diag,
        ) Error!void,
        inspect: *const fn (context: *anyopaque, handle: Handle, diag: *Diag) Error!Status,
        list: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            diag: *Diag,
        ) Error![]const Listing,
        events: *const fn (
            context: *anyopaque,
            arena: std.mem.Allocator,
            timeout_ms: u32,
            diag: *Diag,
        ) Error![]const StatusChange,
    };

    /// Starts a container and returns once its command is running, or says why it could not.
    pub fn start(runtime: Runtime, spec: *const Spec, diag: *Diag) Error!StartOutcome {
        assert(diag.code == null);
        assert(spec_problem(spec) == null);
        const outcome = try finish(diag, runtime.vtable.start(runtime.context, spec, diag));
        switch (outcome) {
            .started => |handle| assert(std.mem.eql(u8, handle.name(), spec.name)),
            .failed => |failure| assert(failure.code.len > 0),
        }
        return outcome;
    }

    /// Asks the container to stop, waits up to `grace_ms`, then kills it. Returns once it has
    /// stopped. How the request reaches the container (a signal to its supervisor, or to its
    /// PID 1 through a pidfd) is the runtime's business, and callers must not depend on it.
    /// Stopping a container that has already stopped does nothing.
    pub fn stop(runtime: Runtime, handle: Handle, grace_ms: u32, diag: *Diag) Error!void {
        assert(diag.code == null);
        try finish(diag, runtime.vtable.stop(runtime.context, handle, grace_ms, diag));
    }

    pub fn inspect(runtime: Runtime, handle: Handle, diag: *Diag) Error!Status {
        assert(diag.code == null);
        return finish(diag, runtime.vtable.inspect(runtime.context, handle, diag));
    }

    /// Every container the runtime knows, including ones started by a previous agent process
    /// and ones that have stopped (until the runtime's own bounded retention drops the oldest).
    /// This is how a restarted agent re-adopts running processes instead of starting duplicates.
    pub fn list(runtime: Runtime, arena: std.mem.Allocator, diag: *Diag) Error![]const Listing {
        assert(diag.code == null);
        const listings = try finish(diag, runtime.vtable.list(runtime.context, arena, diag));
        assert(listings.len <= constants.runtime_handles_max);
        return listings;
    }

    /// Status changes since the previous call, oldest first, waiting up to `timeout_ms` for the
    /// first one. Events are a hint to reconcile sooner: one may be lost (an agent restart),
    /// and `list` and `inspect` are the truth. In particular the run record, which `list` and
    /// `inspect` read, is the truth for why a container exited.
    pub fn events(
        runtime: Runtime,
        arena: std.mem.Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) Error![]const StatusChange {
        assert(diag.code == null);
        const changes = try finish(diag, runtime.vtable.events(
            runtime.context,
            arena,
            timeout_ms,
            diag,
        ));
        assert(changes.len <= constants.runtime_events_batch_max);
        return changes;
    }
};

/// A failed call always leaves a diagnostic behind; a successful one never does.
fn finish(diag: *Diag, result: anytype) @TypeOf(result) {
    if (result) |_| {
        assert(diag.code == null);
    } else |_| {
        assert(diag.code != null);
    }
    return result;
}

// ---- Validation ----------------------------------------------------------------------------

pub const NameProblem = enum { empty, too_long, bad_character, hyphen_at_edge };

/// Null if `name` is a valid container name (see `name_bytes_max`).
pub fn name_problem(name: []const u8) ?NameProblem {
    if (name.len == 0) return .empty;
    if (name.len > name_bytes_max) return .too_long;
    for (name) |byte| {
        const allowed = std.ascii.isDigit(byte) or std.ascii.isLower(byte) or byte == '-';
        if (!allowed) return .bad_character;
    }
    if (name[0] == '-' or name[name.len - 1] == '-') return .hyphen_at_edge;
    return null;
}

pub const SpecProblem = enum {
    bad_name,
    bad_image,
    bad_command,
    too_many_env,
    too_many_labels,
    bad_label,
    missing_replica_label,
};

/// Null if the spec is well formed. A bad spec is a programmer error: the API validates a
/// service when it is applied, and the agent builds specs only from validated ones.
pub fn spec_problem(spec: *const Spec) ?SpecProblem {
    if (name_problem(spec.name) != null) return .bad_name;
    if (spec.image.len == 0) return .bad_image;
    if (spec.image.len > constants.image_digest_bytes_max) return .bad_image;
    if (spec.command.len == 0) return .bad_command;
    if (spec.command.len > constants.runtime_command_words_max) return .bad_command;
    if (spec.command[0].len == 0) return .bad_command;
    if (spec.env.len > constants.runtime_env_count_max) return .too_many_env;
    if (spec.labels.len > constants.runtime_labels_max) return .too_many_labels;
    var has_replica = false;
    for (spec.labels) |label| {
        if (label.key.len == 0) return .bad_label;
        if (label.key.len > constants.label_key_bytes_max) return .bad_label;
        if (label.value.len > constants.label_value_bytes_max) return .bad_label;
        if (std.mem.indexOfScalar(u8, label.key, '=') != null) return .bad_label;
        if (std.mem.eql(u8, label.key, label_replica)) has_replica = true;
    }
    if (!has_replica) return .missing_replica_label;
    return null;
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;
const repeat = @import("test_util.zig").repeat;

test "container names are hostname labels" {
    // Goal: the boundary where a name becomes invalid, the same rule as Zigbox's.
    try testing.expect(name_problem("hello-1") == null);
    try testing.expectEqual(NameProblem.empty, name_problem("").?);
    try testing.expectEqual(NameProblem.bad_character, name_problem("Hello").?);
    try testing.expectEqual(NameProblem.bad_character, name_problem("a_b").?);
    try testing.expectEqual(NameProblem.hyphen_at_edge, name_problem("-a").?);
    try testing.expectEqual(NameProblem.hyphen_at_edge, name_problem("a-").?);
    try testing.expect(name_problem(repeat('a', name_bytes_max)) == null);
    try testing.expectEqual(NameProblem.too_long, name_problem(repeat('a', name_bytes_max + 1)).?);
}

test "a spec needs a name, an image, a command and the replica label" {
    // Goal: each rule of `spec_problem` once. Method: start from a good spec and break one
    // field at a time.
    const good: Spec = .{
        .name = "hello-1",
        .image = "b3:51aa9c03",
        .command = &.{ "sh", "-c", "sleep 1" },
        .labels = &.{.{ .key = label_replica, .value = "hello-1" }},
    };
    try testing.expect(spec_problem(&good) == null);
    var bad = good;
    bad.name = "Hello";
    try testing.expectEqual(SpecProblem.bad_name, spec_problem(&bad).?);
    bad = good;
    bad.image = "";
    try testing.expectEqual(SpecProblem.bad_image, spec_problem(&bad).?);
    bad = good;
    bad.command = &.{};
    try testing.expectEqual(SpecProblem.bad_command, spec_problem(&bad).?);
    bad = good;
    bad.labels = &.{.{ .key = "other", .value = "x" }};
    try testing.expectEqual(SpecProblem.missing_replica_label, spec_problem(&bad).?);
    bad = good;
    bad.labels = &.{ .{ .key = label_replica, .value = "x" }, .{ .key = "a=b", .value = "" } };
    try testing.expectEqual(SpecProblem.bad_label, spec_problem(&bad).?);
}

/// A runtime that starts nothing, to show the vtable is implementable and the wrappers hold.
const Refusing = struct {
    fn runtime(self: *Refusing) Runtime {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Runtime.VTable = .{
        .start = start,
        .stop = stop,
        .inspect = inspect,
        .list = list,
        .events = events,
    };

    fn start(context: *anyopaque, spec: *const Spec, diag: *Diag) Error!StartOutcome {
        _ = context;
        _ = spec;
        diag.reset();
        diag.raise(.E0502);
        var failure: Diagnostic = undefined;
        diag_mod.to_diagnostic(&failure, diag);
        diag.reset();
        return .{ .failed = failure };
    }

    fn stop(context: *anyopaque, handle: Handle, grace_ms: u32, diag: *Diag) Error!void {
        _ = context;
        _ = grace_ms;
        _ = handle;
        diag.raise(.E0501);
        diag.cause("no container by that name", .{});
        return error.NotFound;
    }

    fn inspect(context: *anyopaque, handle: Handle, diag: *Diag) Error!Status {
        _ = context;
        _ = handle;
        diag.raise(.E0501);
        return error.NotFound;
    }

    fn list(context: *anyopaque, arena: std.mem.Allocator, diag: *Diag) Error![]const Listing {
        _ = context;
        _ = arena;
        _ = diag;
        return &.{};
    }

    fn events(
        context: *anyopaque,
        arena: std.mem.Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) Error![]const StatusChange {
        _ = context;
        _ = arena;
        _ = timeout_ms;
        _ = diag;
        return &.{};
    }
};

test "a failed start is an outcome carrying a diagnostic; an unknown handle is an error" {
    // Goal: the two failure shapes of the contract. Method: drive a runtime that refuses; the
    // start call itself succeeds with `.failed`, while stop and inspect fail with `NotFound`
    // and leave a coded diagnostic.
    var refusing: Refusing = .{};
    const runtime = refusing.runtime();
    var diag: Diag = undefined;
    diag.reset();
    const spec: Spec = .{
        .name = "hello-1",
        .image = "b3:00ff",
        .command = &.{"true"},
        .labels = &.{.{ .key = label_replica, .value = "hello-1" }},
    };
    const outcome = try runtime.start(&spec, &diag);
    try testing.expectEqualStrings("ZC-E0502", outcome.failed.code.slice());

    const handle = Handle.init("hello-1");
    try testing.expectError(error.NotFound, runtime.stop(handle, 1000, &diag));
    try testing.expectEqual(@as(@TypeOf(diag.code.?), .E0501), diag.code.?);
    diag.reset();
    try testing.expectError(error.NotFound, runtime.inspect(handle, &diag));

    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try runtime.list(arena_state.allocator(), &diag)).len);
}
