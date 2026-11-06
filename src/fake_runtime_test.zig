//! Tests of `FakeRuntime` with real processes: a container is a supervisor and a command on the
//! host, and the tests look at them with `kill`, `/proc` and the state directory. Test code, so it
//! may sleep and poll. They need the agent's executable (the supervisor is `zcube-agent
//! supervise`), which `zig build test` installs as `zig-out/bin/zcube-agent` (`ZCUBE_AGENT_EXE`
//! names another); where neither exists the tests are skipped, as the Postgres tests are without
//! a database.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const agent_clock = @import("agent_clock.zig");
const agent_mod = @import("agent.zig");
const clock_mod = @import("clock.zig");
const fencing = @import("fencing.zig");
const store_memory = @import("store_memory.zig");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const diag_mod = @import("diag.zig");
const fake_files = @import("fake_files.zig");
const fake_runtime = @import("fake_runtime.zig");
const runtime = @import("runtime.zig");
const fetch_backoff = @import("fetch_backoff.zig");

const Diag = diag_mod.Diag;
const net = std.Io.net;

const fixtures = [_][]const u8{ "b3:51aa9c03", "b3:9d20c4f1" };
const forever = [_][]const u8{ "sh", "-c", "while true; do sleep 1; done" };

const Rig = struct {
    tmp: testing.TmpDir,
    path: []u8,
    clock_source: agent_clock.RealClock,
    fake: *fake_runtime.FakeRuntime,
    exe: []const u8,
    exe_buffer: [constants.state_path_bytes_max]u8,
    arena: std.heap.ArenaAllocator,
    /// How the runtime fetches an image it lacks; null: it does not (`ZBX-E0410`).
    fetch: ?fake_runtime.Fetch,

    /// Skips the test when the supervisor's executable cannot be found.
    fn start() !*Rig {
        // On the heap: the clock handed to the runtime points into the rig, which must not move.
        const rig = try testing.allocator.create(Rig);
        errdefer testing.allocator.destroy(rig);
        const exe = try find_agent_exe(&rig.exe_buffer);
        rig.tmp = testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        var buffer: [constants.state_path_bytes_max]u8 = undefined;
        const length = try rig.tmp.dir.realPath(testing.io, &buffer);
        rig.path = try testing.allocator.dupe(u8, buffer[0..length]);
        errdefer testing.allocator.free(rig.path);
        rig.clock_source = .{ .io = testing.io };
        rig.exe = exe;
        rig.fetch = null;
        rig.arena = .init(testing.allocator);
        rig.fake = try testing.allocator.create(fake_runtime.FakeRuntime);
        errdefer testing.allocator.destroy(rig.fake);
        try rig.open();
        return rig;
    }

    fn open(rig: *Rig) !void {
        var diag: Diag = undefined;
        diag.reset();
        rig.fake.init(testing.io, rig.clock_source.clock(), .{
            .gpa = testing.allocator,
            .state_dir = rig.path,
            .supervisor_exe = rig.exe,
            .fixtures = &fixtures,
            .fetch = rig.fetch,
        }, &diag) catch |err| {
            if (diag.code) |code| std.debug.print("init: {s}\n", .{@tagName(code)});
            return err;
        };
    }

    /// An agent restart: the runtime goes and a new one reads the same state directory.
    fn restart(rig: *Rig) !void {
        rig.fake.deinit();
        try rig.open();
    }

    fn stop(rig: *Rig) void {
        // Whatever a failed test left running goes, so that no test leaks a process.
        rig.kill_everything();
        rig.fake.deinit();
        testing.allocator.destroy(rig.fake);
        rig.arena.deinit();
        testing.allocator.free(rig.path);
        rig.tmp.cleanup();
        testing.allocator.destroy(rig);
    }

    fn kill_everything(rig: *Rig) void {
        var local: Diag = undefined;
        local.reset();
        const listings = rig.fake.interface().list(rig.arena.allocator(), &local) catch return;
        for (listings) |listing| {
            const name = listing.handle.name();
            const dir = rig.fake.containers.openDir(testing.io, name, .{}) catch continue;
            defer dir.close(testing.io);
            rig.fake.kill_group(dir);
        }
    }

    fn launch(
        rig: *Rig,
        name: []const u8,
        image: []const u8,
        command: []const []const u8,
        env: []const runtime.EnvVar,
    ) !runtime.StartOutcome {
        const labels = [_]runtime.Label{.{ .key = runtime.label_replica, .value = name }};
        const value: runtime.Spec = .{
            .name = name,
            .image = image,
            .command = command,
            .env = env,
            .labels = &labels,
        };
        var local: Diag = undefined;
        local.reset();
        return rig.fake.interface().start(&value, &local);
    }

    fn begin(rig: *Rig, name: []const u8, command: []const []const u8) !runtime.Handle {
        const outcome = try rig.launch(name, "b3:51aa9c03", command, &.{});
        return outcome.started;
    }

    fn status(rig: *Rig, handle: runtime.Handle) !runtime.Status {
        var local: Diag = undefined;
        local.reset();
        return rig.fake.interface().inspect(handle, &local);
    }

    /// Polls until the container is stopped, up to ten seconds.
    fn wait_stopped(rig: *Rig, handle: runtime.Handle) !runtime.ExitReason {
        for (0..1000) |_| {
            const now = try rig.status(handle);
            if (now == .stopped) return now.stopped;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.StillRunning;
    }

    fn pid_of(rig: *Rig, name: []const u8, file: []const u8) !i32 {
        const dir = try rig.fake.containers.openDir(testing.io, name, .{});
        defer dir.close(testing.io);
        return fake_files.read_pid(testing.io, dir, file);
    }
};

fn find_agent_exe(buffer: []u8) ![]const u8 {
    const given = testing.environ.getPosix("ZCUBE_AGENT_EXE");
    const relative = given orelse "zig-out/bin/zcube-agent";
    const cwd = std.Io.Dir.cwd();
    const length = cwd.realPathFile(testing.io, relative, buffer) catch return error.SkipZigTest;
    return buffer[0..length];
}

/// A process that has not ended: gone from /proc, or a zombie, is dead.
fn alive(pid: i32) bool {
    var path: [32]u8 = undefined;
    // Cannot fail: "/proc/", a pid of at most ten digits and "/stat" fit 32 bytes.
    const name = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable;
    var buffer: [512]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(testing.io, name, &buffer) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return false;
    return bytes[close + 2] != 'Z';
}

fn expect_dead(pid: i32) !void {
    for (0..300) |_| {
        if (!alive(pid)) return;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.StillAlive;
}

test "a container is a supervisor and a command, and a restarted agent adopts it" {
    // Goal: HANDOFF's re-adoption. Method: start one, check there are two processes with the
    // supervisor as the command's parent, then restart the runtime (a new agent process reading
    // the same directory) and find it running, with no second one started.
    var rig = try Rig.start();
    defer rig.stop();
    const handle = try rig.begin("hello-1", &forever);
    try testing.expect(try rig.status(handle) == .running);
    const supervisor = try rig.pid_of("hello-1", fake_files.file_supervisor);
    const command = try rig.pid_of("hello-1", fake_files.file_child);
    try testing.expect(supervisor != command);
    try testing.expect(alive(supervisor));
    try testing.expect(alive(command));

    try rig.restart();
    var local: Diag = undefined;
    local.reset();
    const listings = try rig.fake.interface().list(rig.arena.allocator(), &local);
    try testing.expectEqual(@as(usize, 1), listings.len);
    try testing.expectEqualStrings("hello-1", listings[0].handle.name());
    try testing.expect(listings[0].status == .running);
    try testing.expectEqualStrings(runtime.label_replica, listings[0].labels[0].key);
    try testing.expectEqualStrings("hello-1", listings[0].labels[0].value);
    try testing.expectEqual(command, try rig.pid_of("hello-1", fake_files.file_child));
}

test "how a command ended is recorded: an exit code, a signal" {
    // Goal: `ExitReason.exited` and `signaled` from the supervisor's record. Method: a command
    // that exits 3, and one that is killed with SIGKILL from outside.
    var rig = try Rig.start();
    defer rig.stop();
    const quick = try rig.begin("quick-1", &.{ "sh", "-c", "exit 3" });
    const reason = try rig.wait_stopped(quick);
    try testing.expectEqual(@as(u8, 3), reason.exited);

    const victim = try rig.begin("victim-1", &forever);
    const pid = try rig.pid_of("victim-1", fake_files.file_child);
    std.posix.kill(pid, .KILL) catch unreachable; // The command is running: we just started it.
    const killed = try rig.wait_stopped(victim);
    try testing.expectEqual(@as(u8, 9), killed.signaled);
}

test "the command gets the spec's environment" {
    // Goal: env reaches the command and nothing is lost on the way through the spec file.
    // Method: the command writes a variable to a file.
    var rig = try Rig.start();
    defer rig.stop();
    var out_path: [constants.state_path_bytes_max]u8 = undefined;
    const path = try std.fmt.bufPrint(&out_path, "{s}/env.out", .{rig.path});
    var script: [constants.state_path_bytes_max + 64]u8 = undefined;
    const text = try std.fmt.bufPrint(&script, "echo \"$ZC_TEST\" > {s}", .{path});
    const env = [_]runtime.EnvVar{.{ .name = "ZC_TEST", .value = "a value; with \"quotes\"" }};
    const outcome = try rig.launch("env-1", "b3:51aa9c03", &.{ "sh", "-c", text }, &env);
    _ = try rig.wait_stopped(outcome.started);
    var buffer: [128]u8 = undefined;
    const written = try rig.tmp.dir.readFile(testing.io, "env.out", &buffer);
    try testing.expectEqualStrings("a value; with \"quotes\"\n", written);
}

test "an image that is not in the fixtures fails with ZBX-E0410 and starts nothing" {
    // Goal: HANDOFF's placeholder code, and that nothing is left behind. Method: start with an
    // unknown digest; the outcome carries the diagnostic and `list` is empty.
    var rig = try Rig.start();
    defer rig.stop();
    const outcome = try rig.launch("broken-1", "b3:00ffee11", &forever, &.{});
    try testing.expectEqualStrings("ZBX-E0410", outcome.failed.code.slice());
    var local: Diag = undefined;
    local.reset();
    const listings = try rig.fake.interface().list(rig.arena.allocator(), &local);
    try testing.expectEqual(@as(usize, 0), listings.len);
}

test "a command that is not there fails with ZC-E0508 and is a stopped container" {
    // Goal: the supervisor's start failure reaches the agent as an outcome with a user-blamed
    // diagnostic, and stays as the container's record. Method: a program that does not exist.
    var rig = try Rig.start();
    defer rig.stop();
    const outcome = try rig.launch("nope-1", "b3:51aa9c03", &.{"/nonexistent/program"}, &.{});
    try testing.expectEqualStrings("ZC-E0508", outcome.failed.code.slice());
    const now = try rig.status(runtime.Handle.init("nope-1"));
    try testing.expectEqualStrings("ZC-E0508", now.stopped.start_failed.code.slice());
}

test "an image that is not a fixture is fetched first, and a failed fetch is ZC-E0601" {
    // Goal: the supervisor runs the fetch before the command, and a fetch that fails is a start
    // failure blamed on the fetch, with the fetch's own text kept in `fetch.log`. Method: a
    // runtime with a registry nobody listens on; the command must never start.
    var rig = try Rig.start();
    defer rig.stop();
    rig.fake.deinit();
    const images = try std.fmt.allocPrint(rig.arena.allocator(), "{s}/images", .{rig.path});
    var local: Diag = undefined;
    local.reset();
    try rig.fake.init(testing.io, rig.clock_source.clock(), .{
        .gpa = testing.allocator,
        .state_dir = rig.path,
        .supervisor_exe = rig.exe,
        .fixtures = &fixtures,
        .fetch = .{ .node = "node1", .images_dir = images, .registry = "127.0.0.1:1" },
    }, &local);
    const digest = "b3:" ++ "0000000000000000000000000000000000000000000000000000000000000000";
    const outcome = try rig.launch("fetch-1", digest, &forever, &.{});
    const handle = switch (outcome) {
        .started => |started| started,
        .failed => |diagnostic| {
            // The fetch failed before `start` returned; the outcome says so.
            try testing.expectEqualStrings("ZC-E0601", diagnostic.code.slice());
            return;
        },
    };
    _ = try rig.wait_stopped(handle);
    const now = try rig.status(handle);
    try testing.expectEqualStrings("ZC-E0601", now.stopped.start_failed.code.slice());
    const dir = try rig.fake.containers.openDir(testing.io, "fetch-1", .{});
    defer dir.close(testing.io);
    const arena = rig.arena.allocator();
    const log = try dir.readFileAlloc(testing.io, fake_files.file_fetch_log, arena, .limited(8192));
    try testing.expect(std.mem.find(u8, log, "ZC-E0601") != null);
    try testing.expectError(error.FileNotFound, dir.access(testing.io, fake_files.file_child, .{}));
}

test "a supervisor that dies leaves a lost container, and nothing of it runs on" {
    // Goal: HANDOFF's `lost`. Method: kill the supervisor with SIGKILL while its command runs;
    // the container is stopped as lost with ZC-E0509, and the command is killed with it.
    var rig = try Rig.start();
    defer rig.stop();
    const handle = try rig.begin("orphan-1", &forever);
    const supervisor = try rig.pid_of("orphan-1", fake_files.file_supervisor);
    const command = try rig.pid_of("orphan-1", fake_files.file_child);
    std.posix.kill(supervisor, .KILL) catch unreachable; // It is running.
    const reason = try rig.wait_stopped(handle);
    try testing.expectEqualStrings("ZC-E0509", reason.lost.?.code.slice());
    try expect_dead(command);
    try expect_dead(supervisor);
}

test "a fault file ends a container as oom, pid_limit or lost" {
    // Goal: the test hooks of HANDOFF's FakeRuntime. Method: write each word for a named replica;
    // the next `list` applies it and the container is stopped for that reason.
    var rig = try Rig.start();
    defer rig.stop();
    const words = [_][]const u8{ "oom", "pid_limit", "lost" };
    const names = [_][]const u8{ "fault-oom", "fault-pid", "fault-lost" };
    var handles: [3]runtime.Handle = undefined;
    for (names, &handles) |name, *handle| handle.* = try rig.begin(name, &forever);
    for (names, words) |name, word| {
        try rig.fake.faults.writeFile(testing.io, .{ .sub_path = name, .data = word });
    }
    var local: Diag = undefined;
    local.reset();
    _ = try rig.fake.interface().list(rig.arena.allocator(), &local);
    try testing.expect((try rig.wait_stopped(handles[0])) == .oom);
    try testing.expect((try rig.wait_stopped(handles[1])) == .pid_limit);
    const lost = try rig.wait_stopped(handles[2]);
    try testing.expectEqualStrings("ZC-E0509", lost.lost.?.code.slice());
}

test "a polite stop ends the command; one that ignores it needs the kill" {
    // Goal: `stop` semantics. Method: SIGTERM ends a plain loop; a command that traps TERM
    // survives a stop with a long grace (stop returns early) and dies on a stop with grace 0.
    var rig = try Rig.start();
    defer rig.stop();
    const polite = try rig.begin("polite-1", &forever);
    var local: Diag = undefined;
    local.reset();
    try rig.fake.interface().stop(polite, constants.stop_grace_ms, &local);
    const reason = try rig.wait_stopped(polite);
    try testing.expectEqual(@as(u8, 15), reason.signaled);

    // The shell says so once the trap is installed: a TERM sent before that would kill it.
    var script_buffer: [constants.state_path_bytes_max + 128]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "trap '' TERM; : > '{s}/faults/stubborn-ready'; while true; do sleep 1; done",
        .{rig.path},
    );
    const stubborn_command = [_][]const u8{ "sh", "-c", script };
    const stubborn = try rig.begin("stubborn-1", &stubborn_command);
    for (0..500) |_| {
        rig.fake.faults.access(testing.io, "stubborn-ready", .{}) catch {
            try testing.io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        break;
    } else return error.TestUnexpectedResult;
    try rig.fake.interface().stop(stubborn, constants.stop_grace_ms, &local);
    try testing.expect(try rig.status(stubborn) == .running);
    try rig.fake.interface().stop(stubborn, 0, &local);
    const killed = try rig.wait_stopped(stubborn);
    try testing.expectEqual(@as(u8, 9), killed.signaled);
    try rig.fake.interface().stop(stubborn, 0, &local); // Stopping a stopped one is nothing.
}

/// Starts `name`, a command that ignores TERM, and returns once the shell says its trap is in:
/// a TERM before that would kill it, and the tests would depend on timing.
fn begin_stubborn(rig: *Rig, name: []const u8) !runtime.Handle {
    var script_buffer: [constants.state_path_bytes_max + 128]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "trap '' TERM; : > '{s}/faults/{s}-ready'; while true; do sleep 1; done",
        .{ rig.path, name },
    );
    const command = [_][]const u8{ "sh", "-c", script };
    const handle = try rig.begin(name, &command);
    var ready_buffer: [64]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "{s}-ready", .{name});
    for (0..500) |_| {
        rig.fake.faults.access(testing.io, ready, .{}) catch {
            try testing.io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        return handle;
    }
    return error.TestUnexpectedResult;
}

test "a signal does not wait: TERM ends a plain loop, a trap survives it, KILL ends it" {
    // Goal: `Runtime.signal` semantics on real processes. Method: TERM to a plain loop ends it;
    // TERM to a command that traps it returns at once (well inside `stop_wait_ms`, which a
    // waiting call would use up) and leaves it running; KILL ends it; signalling a stopped
    // container does nothing and an unknown one is `NotFound`.
    var rig = try Rig.start();
    defer rig.stop();
    const interface = rig.fake.interface();
    var local: Diag = undefined;
    local.reset();
    const polite = try rig.begin("polite-1", &forever);
    try interface.signal(polite, runtime.signal_term, &local);
    try testing.expectEqual(@as(u8, 15), (try rig.wait_stopped(polite)).signaled);

    const stubborn = try begin_stubborn(rig, "stubborn-1");
    const began = rig.clock_source.clock().now_ms();
    try interface.signal(stubborn, runtime.signal_term, &local);
    const spent = rig.clock_source.clock().now_ms() - began;
    try testing.expect(spent < fake_runtime.stop_wait_ms / 2);
    try testing.expect(try rig.status(stubborn) == .running);
    try interface.signal(stubborn, runtime.signal_kill, &local);
    try testing.expectEqual(@as(u8, 9), (try rig.wait_stopped(stubborn)).signaled);
    try interface.signal(stubborn, runtime.signal_kill, &local);
    try testing.expectError(
        error.NotFound,
        interface.signal(runtime.Handle.init("nope"), runtime.signal_term, &local),
    );
}

test "sixteen containers that ignore TERM are signalled in well under one wait, then killed" {
    // Goal: the point of `signal`: N containers cost one deadline, not N waits. Method: sixteen
    // stubborn containers; TERM to all of them takes less than a single `stop_wait_ms` (sixteen
    // `stop` calls would take sixteen of them), none has stopped, then KILL to all of them and
    // every one stops.
    var rig = try Rig.start();
    defer rig.stop();
    const interface = rig.fake.interface();
    var local: Diag = undefined;
    local.reset();
    const count = 16;
    var handles: [count]runtime.Handle = undefined;
    for (&handles, 0..) |*handle, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "stubborn-{d}", .{index});
        handle.* = try begin_stubborn(rig, name);
    }
    const clock = rig.clock_source.clock();
    const began = clock.now_ms();
    for (handles) |handle| try interface.signal(handle, runtime.signal_term, &local);
    try testing.expect(clock.now_ms() - began < fake_runtime.stop_wait_ms);
    for (handles) |handle| try testing.expect(try rig.status(handle) == .running);
    for (handles) |handle| try interface.signal(handle, runtime.signal_kill, &local);
    for (handles) |handle| {
        try testing.expectEqual(@as(u8, 9), (try rig.wait_stopped(handle)).signaled);
    }
}

test "a fence over sixteen real containers: polite ones go at once, the rest at the kill time" {
    // Goal: P2 on real processes. Method: an `Agent` over `FakeRuntime` with sixteen containers,
    // the odd ones trapping TERM; the fence is begun with a manual clock for the deadline. After
    // the first step every polite container is gone and every trapping one still runs; just
    // before the kill time that is still so; at it the rest are killed, and the next step ends
    // the fence. The whole fence takes one `fence_stop_ms` of the manual clock plus one poll.
    var rig = try Rig.start();
    defer rig.stop();
    const count = 16;
    var handles: [count]runtime.Handle = undefined;
    for (&handles, 0..) |*handle, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "fence-{d}", .{index});
        handle.* = if (index % 2 == 0)
            try rig.begin(name, &forever)
        else
            try begin_stubborn(rig, name);
    }
    var manual: clock_mod.ManualClock = .{ .ms = 1_000 };
    var memory: store_memory.MemoryStore = undefined;
    memory.init(testing.allocator, manual.clock());
    defer memory.deinit();
    const agent = try testing.allocator.create(agent_mod.Agent);
    defer testing.allocator.destroy(agent);
    agent.init(.{ .node = "node1", .capacity = .{ .cpu_millis = 1000, .memory_bytes = 1 << 30 } });
    const fence_at = manual.ms;
    const kill_at = fencing.kill_at_ms(fence_at);
    agent.fence = .{ .active = true, .asked = false, .kill_at_ms = kill_at };

    try fence_step(rig, agent, &manual, &memory);
    try testing.expect(agent.fence.asked);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 0) {
            try testing.expectEqual(@as(u8, 15), (try rig.wait_stopped(handle)).signaled);
        } else {
            try testing.expect(try rig.status(handle) == .running);
        }
    }
    manual.ms = kill_at - 1;
    try fence_step(rig, agent, &manual, &memory);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 1) try testing.expect(try rig.status(handle) == .running);
    }
    try testing.expectEqual(@as(u32, 0), agent.fences);

    manual.ms = kill_at;
    try fence_step(rig, agent, &manual, &memory);
    for (handles, 0..) |handle, index| {
        if (index % 2 == 0) continue;
        try testing.expectEqual(@as(u8, 9), (try rig.wait_stopped(handle)).signaled);
    }
    manual.ms = kill_at + constants.fence_poll_ms;
    try fence_step(rig, agent, &manual, &memory);
    try testing.expectEqual(@as(u32, 1), agent.fences);
    try testing.expect(manual.ms - fence_at <= constants.fence_stop_ms + constants.fence_poll_ms);
}

fn fence_step(
    rig: *Rig,
    agent: *agent_mod.Agent,
    manual: *clock_mod.ManualClock,
    memory: *store_memory.MemoryStore,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const ctx: agent_mod.Context = .{
        .store = memory.interface(),
        .runtime = rig.fake.interface(),
        .clock = manual.clock(),
        .arena = arena_state.allocator(),
        .diag = &diag,
    };
    _ = agent.reconcile(&ctx) catch |err| {
        if (diag.code) |code| std.debug.print("fence step: {s}\n", .{@tagName(code)});
        return err;
    };
}

test "a second agent on the same state directory is refused with ZC-E0506" {
    // Goal: two agents never share containers. Method: open the same directory twice.
    var rig = try Rig.start();
    defer rig.stop();
    var second = try testing.allocator.create(fake_runtime.FakeRuntime);
    defer testing.allocator.destroy(second);
    var local: Diag = undefined;
    local.reset();
    const options: fake_runtime.Options = .{
        .gpa = testing.allocator,
        .state_dir = rig.path,
        .supervisor_exe = rig.exe,
        .fixtures = &fixtures,
    };
    const clock = rig.clock_source.clock();
    try testing.expectError(error.StateDirFailed, second.init(testing.io, clock, options, &local));
    try testing.expectEqualStrings("ZC-E0506", codes.full_name(local.code.?));
}

test "events report a container when it starts and when it ends" {
    // Goal: the hint stream. Method: nothing at first; a start is reported once; the kill is
    // reported as stopped; a quiet call times out empty.
    var rig = try Rig.start();
    defer rig.stop();
    var local: Diag = undefined;
    local.reset();
    const interface = rig.fake.interface();
    const arena = rig.arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try interface.events(arena, 0, &local)).len);
    const handle = try rig.begin("event-1", &forever);
    const started = try interface.events(arena, 1000, &local);
    try testing.expectEqual(@as(usize, 1), started.len);
    try testing.expect(started[0].status == .running);
    try testing.expectEqual(@as(usize, 0), (try interface.events(arena, 50, &local)).len);
    try interface.stop(handle, 0, &local);
    const ended = try interface.events(arena, 1000, &local);
    try testing.expectEqual(@as(usize, 1), ended.len);
    try testing.expect(ended[0].status == .stopped);
}

const unfetched = "b3:" ++ "0000000000000000000000000000000000000000000000000000000000000000";

/// The runtime fetches from `registry`, with a back-off of `base_ms` doubling to `cap_ms`.
fn fetch_from(rig: *Rig, registry: []const u8, base_ms: u32, cap_ms: u32) !void {
    const images = try std.fmt.allocPrint(rig.arena.allocator(), "{s}/images", .{rig.path});
    rig.fetch = .{
        .node = "node1",
        .images_dir = images,
        .registry = registry,
        .backoff_base_ms = base_ms,
        .backoff_cap_ms = cap_ms,
    };
    try rig.restart();
}

/// The pids of the processes the supervisor `supervisor` has started (its fetch, while it fetches).
fn children_of(supervisor: i32, out: *[8]i32) !usize {
    var path: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &path,
        "/proc/{d}/task/{d}/children",
        .{ supervisor, supervisor },
    );
    var buffer: [128]u8 = undefined;
    const line = try std.Io.Dir.cwd().readFile(testing.io, name, &buffer);
    var count: usize = 0;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |word| {
        const trimmed = std.mem.trim(u8, word, "\n");
        if (trimmed.len == 0) continue;
        if (count == out.len) break;
        out[count] = try std.fmt.parseInt(i32, trimmed, 10);
        count += 1;
    }
    return count;
}

/// Waits until the supervisor has a fetch running, and returns its pid.
fn fetch_pid(supervisor: i32) !i32 {
    for (0..500) |_| {
        var found: [8]i32 = undefined;
        const count = children_of(supervisor, &found) catch 0;
        if (count > 0) return found[0];
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.NoFetch;
}

test "an agent that restarts in the middle of a fetch adopts it, and the fetch goes on" {
    // Goal: the review's S3, restart case. A fetch is the supervisor's child, so the agent
    // going away must neither end it nor start a second one. Method: a registry that accepts and
    // says nothing holds the fetch; restart the runtime; the same supervisor and the same fetch
    // are there, the replica is still starting, and stopping it ends both.
    var rig = try Rig.start();
    defer rig.stop();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    defer listener.deinit(testing.io);
    var address: [32]u8 = undefined;
    const port = listener.socket.address.getPort();
    const registry = try std.fmt.bufPrint(&address, "127.0.0.1:{d}", .{port});
    try fetch_from(rig, try rig.arena.allocator().dupe(u8, registry), 50, 100);
    const outcome = try rig.launch("mid-1", unfetched, &forever, &.{});
    const handle = outcome.started;
    const supervisor = try rig.pid_of("mid-1", fake_files.file_supervisor);
    const fetching = try fetch_pid(supervisor);
    try rig.restart();
    try testing.expect(alive(supervisor));
    try testing.expect(alive(fetching));
    try testing.expectEqual(supervisor, try rig.pid_of("mid-1", fake_files.file_supervisor));
    try testing.expect((try rig.status(handle)) == .starting);
    var local: Diag = undefined;
    local.reset();
    try rig.fake.interface().stop(handle, 1000, &local);
    _ = try rig.wait_stopped(handle);
    try expect_dead(fetching);
    try expect_dead(supervisor);
}

test "a fetch that is killed with SIGKILL is a failed start blamed on the fetch" {
    // Goal: the review's S3, SIGKILL case. The fetch ending by a signal the supervisor did not
    // send is a crash, not a stop. Method: hold a fetch as above, kill it, and expect ZC-E0601
    // with the fetch's blame and no command ever started.
    var rig = try Rig.start();
    defer rig.stop();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    defer listener.deinit(testing.io);
    var address: [32]u8 = undefined;
    const port = listener.socket.address.getPort();
    const registry = try std.fmt.bufPrint(&address, "127.0.0.1:{d}", .{port});
    try fetch_from(rig, try rig.arena.allocator().dupe(u8, registry), 50, 100);
    const handle = (try rig.launch("kill-1", unfetched, &forever, &.{})).started;
    const supervisor = try rig.pid_of("kill-1", fake_files.file_supervisor);
    std.posix.kill(try fetch_pid(supervisor), .KILL) catch unreachable; // It is running.
    const reason = try rig.wait_stopped(handle);
    try testing.expectEqualStrings("ZC-E0601", reason.start_failed.code.slice());
    try testing.expectEqual(codes.Blame.external, reason.start_failed.blame);
    try testing.expectError(error.FileNotFound, (try rig.fake.containers.openDir(
        testing.io,
        "kill-1",
        .{},
    )).access(testing.io, fake_files.file_child, .{}));
}

test "a replica stopped while it fetches ends as stopped, not as a failed start" {
    // Goal: the review's S3, stop case. Stopping is not the fetch's fault, so the controller must
    // not read it as one, and the streak must not grow. Method: stop a held fetch with the
    // streak file absent; expect a signal exit and no streak afterwards.
    var rig = try Rig.start();
    defer rig.stop();
    var listener = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(testing.io, .{});
    defer listener.deinit(testing.io);
    var address: [32]u8 = undefined;
    const port = listener.socket.address.getPort();
    const registry = try std.fmt.bufPrint(&address, "127.0.0.1:{d}", .{port});
    try fetch_from(rig, try rig.arena.allocator().dupe(u8, registry), 50, 100);
    const handle = (try rig.launch("stop-1", unfetched, &forever, &.{})).started;
    const supervisor = try rig.pid_of("stop-1", fake_files.file_supervisor);
    const fetching = try fetch_pid(supervisor);
    var local: Diag = undefined;
    local.reset();
    try rig.fake.interface().stop(handle, 1000, &local);
    const reason = try rig.wait_stopped(handle);
    try testing.expect(reason == .signaled);
    try expect_dead(fetching);
    try testing.expectError(
        error.FileNotFound,
        rig.tmp.dir.access(testing.io, "fetch-streak.json", .{}),
    );
}

test "after a failed fetch the next one on the node waits, longer each time, up to the cap" {
    // Goal: the back-off of fetch_backoff.zig as the supervisors apply it (review S6). Method: a
    // registry nobody listens on; the first failure comes at once, the second replica waits the
    // base (200 ms), the third twice that, the fourth the cap (400 ms). The wait counts from the
    // previous failure, not from this test's call to `launch` (the test's own latency between the
    // two is part of the wait), so the bound is on the gap between the failures the supervisors
    // recorded, `at_ms` in the streak file. Lower bound only: a loaded machine may be slower,
    // never faster. (Measuring from `launch` failed 1 run in many on a loaded machine.) The
    // recorded times are tied to this test's own boot clock, so a supervisor clock that runs
    // fast or in other units cannot pass: each `at_ms` lies between the test's reads before the
    // `launch` and after the end, and the whole run takes at least the sum of the waits.
    var rig = try Rig.start();
    defer rig.stop();
    try fetch_from(rig, "127.0.0.1:1", 200, 400);
    const names = [_][]const u8{ "back-1", "back-2", "back-3", "back-4" };
    const waits_ms = [_]u64{ 0, 200, 400, 400 };
    var previous_ms: u64 = 0;
    var total_ms: u64 = 0;
    for (waits_ms) |wait_ms| total_ms += wait_ms;
    const first_began_ms = boot_now_ms();
    var last_ended_ms: u64 = 0;
    for (names, waits_ms, 1..) |name, wait_ms, failures| {
        const began_ms = boot_now_ms();
        const outcome = try rig.launch(name, unfetched, &forever, &.{});
        const reason = switch (outcome) {
            .started => |handle| try rig.wait_stopped(handle),
            .failed => |diagnostic| runtime.ExitReason{ .start_failed = diagnostic },
        };
        const ended_ms = boot_now_ms();
        last_ended_ms = ended_ms;
        try testing.expectEqualStrings("ZC-E0601", reason.start_failed.code.slice());
        const streak = fetch_backoff.read(
            testing.io,
            rig.tmp.dir,
            rig.arena.allocator(),
            unfetched,
        );
        try testing.expectEqual(@as(u32, @intCast(failures)), streak.failures);
        // A millisecond of slack: both times were cut to whole milliseconds.
        try testing.expect(streak.at_ms + 1 >= previous_ms + wait_ms);
        // The supervisor's clock is the test's clock: the failure lies inside this launch.
        try testing.expect(began_ms <= streak.at_ms);
        try testing.expect(streak.at_ms <= ended_ms + 1);
        previous_ms = streak.at_ms;
    }
    try testing.expect(last_ended_ms >= first_began_ms + total_ms);
}

fn boot_now_ms() u64 {
    const ms = std.Io.Clock.boot.now(testing.io).toMilliseconds();
    assert(ms >= 0);
    return @intCast(ms);
}
