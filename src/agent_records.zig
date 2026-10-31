//! What the node agent keeps about its containers, and how it reads that back after a restart.
//! Core code, written against `AgentState`: `FakeRuntime` runs it over `DirState` (real files),
//! and the cluster simulation's `SimNode` runs the same code over `SimState`, with `SimRuntime`
//! standing in for the supervisors and processes. The crash tests therefore exercise production's
//! write sequence, not a copy of it.
//!
//! A container is a directory `containers/<name>/` (docs/agent.md has the whole table):
//!
//!   spec.json        what the agent asked for. **The agent writes it before it starts anything**
//!                    (so a container that runs always has a spec), and it is the one file the
//!                    agent reads to learn what exists: `scan` lists the directories and keeps
//!                    those whose spec reads. A directory without a readable spec is not a
//!                    container, whatever else is in it (a crash left it half made or half
//!                    removed).
//!   run.json         how the command ended. The supervisor writes it (the simulation has no
//!                    supervisors; `SimRuntime` knows how its containers ended). The agent writes
//!                    it only to record a `lost` verdict, once.
//!   child.pid, supervisor.pid, forced, lock
//!                    process facts that only the supervisor and the shell touch: they are never
//!                    in `AgentState`, and `Facts` carries what they say into `classify`.
//!
//! **The order of writes** is the crash-safety argument. A start: remove stale files of an older
//! container of the name (never its spec: a stale directory has no spec already), put `spec.json`
//! (whole after any crash), then start the supervisor. A crash before the put: nothing exists. A
//! crash after: a spec and maybe no process, which `classify` calls `starting` for a while and
//! then `lost`, and `scan` finds either way. A removal puts the spec *first*, so that a crash in
//! the middle leaves a directory with no spec, which is not a container. There is no write whose
//! partial result a reader misreads, given that `put_atomic` is whole (docs/agent.md says what
//! that costs in fsyncs); the one soft spot is that a `lost` verdict is two steps (kill the
//! group, write `run.json`), and a crash between them repeats the first, which is idempotent.

const std = @import("std");
const assert = std.debug.assert;
const agent_state = @import("agent_state.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const AgentState = agent_state.AgentState;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

pub const dir_containers = "containers/";
pub const file_spec = "spec.json";
pub const file_run = "run.json";
pub const file_child = "child.pid";
pub const file_supervisor = "supervisor.pid";
pub const file_lock = "lock";
pub const file_forced = "forced";

comptime {
    // The longest path the agent builds: containers/<name>/supervisor.pid.
    const longest = dir_containers.len + runtime.name_bytes_max + 1 + file_supervisor.len;
    assert(longest <= agent_state.name_bytes_max);
}

pub const Pair = [2][]const u8;

/// `spec.json`: the `runtime.Spec` the container was started with, and when.
pub const SpecFile = struct {
    name: []const u8,
    image: []const u8,
    command: []const []const u8,
    env: []const Pair = &.{},
    labels: []const Pair = &.{},
    started_at_ms: u64,
};

pub const RunKind = enum { exited, signaled, oom, pid_limit, start_failed, lost };

/// Whose fault a start that failed was, so that the agent can blame correctly.
pub const Blame = enum { user, environment };

/// `run.json`.
pub const RunFile = struct {
    kind: RunKind,
    code: ?u8 = null,
    signal: ?u8 = null,
    /// For `start_failed`: what the host said, in one sentence.
    cause: ?[]const u8 = null,
    blame: ?Blame = null,
};

/// `containers/<container>/<file>` in `buffer`.
pub fn path(
    buffer: *[agent_state.name_bytes_max]u8,
    container: []const u8,
    file: []const u8,
) []const u8 {
    assert(runtime.name_problem(container) == null);
    assert(file.len > 0);
    return std.fmt.bufPrint(buffer, "{s}{s}/{s}", .{ dir_containers, container, file }) catch
        unreachable; // The comptime check above sizes the buffer for the longest file name.
}

fn json_bytes(buffer: []u8, value: anytype) agent_state.Error![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    std.json.Stringify.value(value, options, &writer) catch return error.TooBig;
    return writer.buffered();
}

/// Starts the container's record: clears what an older container of the name left (a stopped
/// container's directory has no spec by now, see `remove_container`), then puts the spec.
pub fn write_spec(state: AgentState, spec: *const SpecFile) agent_state.Error!void {
    assert(runtime.name_problem(spec.name) == null);
    var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
    for ([_][]const u8{ file_run, file_child, file_supervisor, file_forced }) |stale| {
        state.remove(path(&path_buffer, spec.name, stale)) catch |err| switch (err) {
            error.Absent => {}, // The usual case.
            else => |other| return other,
        };
    }
    var buffer: [agent_state.file_bytes_max]u8 = undefined;
    const bytes = try json_bytes(&buffer, spec);
    try state.put_atomic(path(&path_buffer, spec.name, file_spec), bytes);
}

/// Forgets a container that has stopped. The spec goes first: a crash in the middle leaves a
/// directory that is not a container, and `write_spec` clears the rest.
pub fn remove_container(
    state: AgentState,
    arena: Allocator,
    name: []const u8,
) agent_state.Error!void {
    var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
    state.remove(path(&path_buffer, name, file_spec)) catch |err| switch (err) {
        error.Absent => {},
        else => |other| return other,
    };
    var prefix_buffer: [agent_state.name_bytes_max]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "{s}{s}/", .{ dir_containers, name }) catch
        unreachable; // A container name is at most 63 bytes.
    for (try state.list(arena, prefix)) |left| {
        state.remove(left) catch |err| switch (err) {
            error.Absent => {},
            else => |other| return other,
        };
    }
}

/// The container's spec; null if it is missing, empty or damaged: nothing to adopt or report.
/// (An empty file is what a crash can leave of a file nobody synced; it is not a spec.)
pub fn read_spec(
    state: AgentState,
    arena: Allocator,
    name: []const u8,
) agent_state.Error!?SpecFile {
    var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
    const bytes = state.read(arena, path(&path_buffer, name, file_spec)) catch |err| switch (err) {
        error.Absent => return null,
        else => |other| return other,
    };
    return parse(SpecFile, arena, bytes);
}

/// `run.json` if the command ended, null if there is none. A record that cannot be read is a
/// container whose end nobody knows: `lost`.
pub fn read_run(
    state: AgentState,
    arena: Allocator,
    name: []const u8,
) agent_state.Error!?RunFile {
    var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
    const bytes = state.read(arena, path(&path_buffer, name, file_run)) catch |err| switch (err) {
        error.Absent => return null,
        else => |other| return other,
    };
    return (try parse(RunFile, arena, bytes)) orelse .{ .kind = .lost };
}

pub fn write_run(state: AgentState, name: []const u8, run: *const RunFile) agent_state.Error!void {
    var buffer: [agent_state.file_bytes_max]u8 = undefined;
    const bytes = try json_bytes(&buffer, run.*);
    var path_buffer: [agent_state.name_bytes_max]u8 = undefined;
    try state.put_atomic(path(&path_buffer, name, file_run), bytes);
}

fn parse(comptime T: type, arena: Allocator, bytes: []const u8) agent_state.Error!?T {
    if (bytes.len == 0) return null;
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    return std.json.parseFromSliceLeaky(T, arena, bytes, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

pub const Record = struct { name: []const u8, spec: SpecFile };

/// Every container with a readable spec, by name. This is the agent's whole memory of what it
/// started: after a restart, adoption is this and nothing else.
pub fn scan(state: AgentState, arena: Allocator) agent_state.Error![]const Record {
    var found: std.ArrayList(Record) = .empty;
    const entries = try state.list(arena, dir_containers);
    for (entries[0..@min(entries.len, constants.fake_dir_entries_max)]) |entry| {
        if (!std.mem.endsWith(u8, entry, "/")) continue;
        const name = entry[dir_containers.len .. entry.len - 1];
        if (runtime.name_problem(name) != null) continue;
        const spec = try read_spec(state, arena, name) orelse continue;
        try found.append(arena, .{ .name = name, .spec = spec });
    }
    return found.items;
}

// ---- Deciding what a container is -----------------------------------------------------------

/// What the process side says about one container. In the shell: the supervisor's lock and pid
/// files. In the simulation: whether `SimRuntime` has the container.
pub const Facts = struct {
    /// `run.json`, read after the lock was seen free (a supervisor writes it before it lets go).
    run: ?RunFile,
    supervisor_alive: bool,
    child_exists: bool,
    supervisor_pid_exists: bool,
    /// Now minus the spec's `started_at_ms`.
    age_ms: u64,
};

pub const Verdict = union(enum) {
    stopped: RunFile,
    running,
    starting,
    /// The supervisor is gone and said nothing. The caller kills what it left, records the
    /// verdict with `write_run` (so it is made once) and reports `stopped` with kind `lost`.
    declare_lost,
};

pub fn classify(facts: Facts) Verdict {
    if (facts.run) |run| return .{ .stopped = run };
    if (facts.supervisor_alive) {
        return if (facts.child_exists) .running else .starting;
    }
    if (!facts.supervisor_pid_exists) {
        if (facts.age_ms < constants.fake_start_timeout_ms) return .starting;
    }
    return .declare_lost;
}

pub fn stopped_by(name: []const u8, run: RunFile) runtime.Status {
    return .{ .stopped = exit_reason(name, run) };
}

fn exit_reason(name: []const u8, run: RunFile) runtime.ExitReason {
    return switch (run.kind) {
        .exited => .{ .exited = run.code orelse 0 },
        .signaled => .{ .signaled = run.signal orelse 0 },
        .oom => .oom,
        .pid_limit => .pid_limit,
        .start_failed => .{ .start_failed = start_failure(name, run) },
        .lost => .{ .lost = lost_diagnostic(name) },
    };
}

/// ZC-E0508 (the user's command) or ZC-E0507 (the host), as the supervisor recorded.
pub fn start_failure(name: []const u8, run: RunFile) Diagnostic {
    var collector: Diag = undefined;
    collector.reset();
    const cause = run.cause orelse "the supervisor did not say why";
    if ((run.blame orelse .environment) == .user) {
        collector.raise(.E0508);
        collector.cause("{s}", .{cause});
        const sentence = "check the command in the service file, then apply it again";
        collector.fix(.{ .sentence = sentence });
    } else {
        collector.raise(.E0507);
        collector.cause("{s}", .{cause});
        const sentence = "free process slots on the node, then apply the service again";
        collector.fix(.{ .sentence = sentence });
    }
    collector.while_("starting container {s}", .{name});
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

pub fn lost_diagnostic(name: []const u8) Diagnostic {
    var collector: Diag = undefined;
    collector.reset();
    collector.raise(.E0509);
    collector.cause("the supervisor of {s} ended without writing how the command ended", .{name});
    collector.fix(.{ .sentence = "look for something killing zcube-agent processes on this node" });
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

// ---- Tests ----------------------------------------------------------------------------------

const testing = std.testing;

const test_labels = [_]Pair{.{ "zcube.replica", "r1" }};

fn test_spec(name: []const u8) SpecFile {
    return .{
        .name = name,
        .image = "b3:51aa9c03",
        .command = &.{ "serve", "--port=80" },
        .labels = &test_labels,
        .started_at_ms = 1234,
    };
}

test "a spec is written, scanned back, and removed spec-first" {
    // Goal: the record's round trip. Method: two containers, scan, read one, remove one; a
    // directory with an empty or damaged spec is not a container.
    var state = agent_state.SimState.init(testing.allocator, 1);
    defer state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent = state.interface();
    try write_spec(agent, &test_spec("web-1"));
    try write_spec(agent, &test_spec("web-2"));
    try agent.put_atomic("containers/web-3/spec.json", "");
    try agent.put_atomic("containers/web-4/spec.json", "{not json");
    try agent.put_atomic("containers/Bad_Name/spec.json", "{}");
    const found = try scan(agent, arena);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("web-1", found[0].name);
    try testing.expectEqualStrings("serve", found[0].spec.command[0]);
    try testing.expectEqual(@as(u64, 1234), found[1].spec.started_at_ms);
    try testing.expectEqual(@as(?SpecFile, null), try read_spec(agent, arena, "web-3"));

    try write_run(agent, "web-1", &.{ .kind = .exited, .code = 3 });
    const run = (try read_run(agent, arena, "web-1")).?;
    try testing.expectEqual(@as(?u8, 3), run.code);
    try testing.expectEqual(@as(?RunFile, null), try read_run(agent, arena, "web-2"));
    try agent.put_atomic("containers/web-2/run.json", "");
    try testing.expectEqual(RunKind.lost, (try read_run(agent, arena, "web-2")).?.kind);

    try remove_container(agent, arena, "web-1");
    try testing.expectEqual(@as(usize, 1), (try scan(agent, arena)).len);
    try testing.expectEqual(@as(usize, 0), (try agent.list(arena, "containers/web-1/")).len);
}

const Counts = struct {
    start_absent: u32 = 0,
    start_present: u32 = 0,
    removal_kept: u32 = 0,
    removal_gone: u32 = 0,
    lost_recorded: u32 = 0,
    lost_missing: u32 = 0,
};

/// Run `op` and, if it fails, require the failure to be the simulated crash.
fn crashed_by(result: anyerror!void) !bool {
    if (result) |_| return false else |err| {
        try testing.expectEqual(error.Crashed, err);
        return true;
    }
}

fn crash_start(
    state: *agent_state.SimState,
    arena: Allocator,
    point: u32,
    kind: agent_state.CrashKind,
    counts: *Counts,
) !void {
    // A start over a container that stopped earlier (stale files and an old spec).
    const agent = state.interface();
    try write_spec(agent, &test_spec("web-1"));
    try write_run(agent, "web-1", &.{ .kind = .exited, .code = 0 });
    try remove_container(agent, arena, "web-1");
    try write_run(agent, "web-1", &.{ .kind = .lost }); // A stale file, no spec.
    state.arm_crash(point, kind);
    const crashed = try crashed_by(write_spec(agent, &test_spec("web-1")));
    state.restart();
    const after = try scan(agent, arena);
    try testing.expect(after.len <= 1);
    if (after.len == 1) {
        try testing.expectEqualStrings("web-1", after[0].name);
        try testing.expectEqual(@as(u64, 1234), after[0].spec.started_at_ms);
        counts.start_present += 1;
    } else {
        counts.start_absent += 1;
        try testing.expect(crashed);
    }
    try write_spec(agent, &test_spec("web-1")); // The retry after the restart.
    try testing.expectEqual(@as(usize, 1), (try scan(agent, arena)).len);
    try testing.expectEqual(@as(?RunFile, null), try read_run(agent, arena, "web-1"));
}

fn crash_removal_and_lost(
    state: *agent_state.SimState,
    arena: Allocator,
    point: u32,
    kind: agent_state.CrashKind,
    counts: *Counts,
) !void {
    const agent = state.interface();
    state.arm_crash(point, kind); // A removal of a stopped container.
    _ = try crashed_by(remove_container(agent, arena, "web-1"));
    state.restart();
    const left = try scan(agent, arena);
    if (left.len == 1) counts.removal_kept += 1 else counts.removal_gone += 1;
    try testing.expect(left.len <= 1);

    // A lost verdict: the agent writes run.json once.
    try write_spec(agent, &test_spec("web-2"));
    state.arm_crash(@min(point, 2), kind);
    _ = try crashed_by(write_run(agent, "web-2", &.{ .kind = .lost }));
    state.restart();
    if (try read_run(agent, arena, "web-2")) |run| {
        try testing.expectEqual(RunKind.lost, run.kind);
        counts.lost_recorded += 1;
    } else counts.lost_missing += 1;
}

test "a crash at every write point leaves records a restart reads" {
    // Goal: production's write sequence under every crash the model allows. Method: for each
    // write point of each operation, both crash kinds, 64 seeds each: arm the crash, run the
    // operation, restart, and check that `scan` never fails and finds either nothing or a whole
    // spec of the name (never a torn one); that a start retried after the crash always ends with
    // one readable spec; and that every outcome occurs: crashed-before-spec and spec-present
    // after a start, and for the removal both a surviving and a gone container. Counts are
    // asserted so the loop cannot silently stop covering a case.
    var counts: Counts = .{};
    for ([_]agent_state.CrashKind{ .process, .host }) |kind| {
        for (1..9) |point| {
            for (0..64) |seed| {
                var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena_state.deinit();
                var state = agent_state.SimState.init(testing.allocator, seed * 7 + point);
                defer state.deinit();
                const arena = arena_state.allocator();
                try crash_start(&state, arena, @intCast(point), kind, &counts);
                try crash_removal_and_lost(&state, arena, @intCast(point), kind, &counts);
            }
        }
    }
    try testing.expect(counts.start_absent > 0);
    try testing.expect(counts.start_present > 0);
    try testing.expect(counts.removal_kept > 0);
    try testing.expect(counts.removal_gone > 0);
    try testing.expect(counts.lost_recorded > 0);
    try testing.expect(counts.lost_missing > 0);
}

test "classify: an ended command, a live supervisor, a young spec, and a dead supervisor" {
    // Goal: the decision table `FakeRuntime` and `SimNode` share. Method: each row of it.
    const base: Facts = .{
        .run = null,
        .supervisor_alive = false,
        .child_exists = false,
        .supervisor_pid_exists = false,
        .age_ms = 0,
    };
    var facts = base;
    facts.run = .{ .kind = .exited, .code = 2 };
    facts.supervisor_alive = true;
    try testing.expectEqual(@as(?u8, 2), classify(facts).stopped.code);
    facts = base;
    facts.supervisor_alive = true;
    try testing.expect(classify(facts) == .starting);
    facts.child_exists = true;
    try testing.expect(classify(facts) == .running);
    facts = base;
    try testing.expect(classify(facts) == .starting);
    facts.age_ms = constants.fake_start_timeout_ms;
    try testing.expect(classify(facts) == .declare_lost);
    facts = base;
    facts.supervisor_pid_exists = true;
    try testing.expect(classify(facts) == .declare_lost);
}
