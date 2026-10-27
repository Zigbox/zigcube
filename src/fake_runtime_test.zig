//! Tests of `FakeRuntime` with real processes: a container is a supervisor and a command on the
//! host, and the tests look at them with `kill`, `/proc` and the state directory. Test code, so it
//! may sleep and poll. They need the agent's executable (the supervisor is `zcube-agent
//! supervise`), which `zig build test` installs as `zig-out/bin/zcube-agent` (`ZCUBE_AGENT_EXE`
//! names another); where neither exists the tests are skipped, as the Postgres tests are without
//! a database.

const std = @import("std");
const testing = std.testing;
const agent_clock = @import("agent_clock.zig");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const diag_mod = @import("diag.zig");
const fake_files = @import("fake_files.zig");
const fake_runtime = @import("fake_runtime.zig");
const runtime = @import("runtime.zig");

const Diag = diag_mod.Diag;

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

test "an image that is not in the fixtures fails with ZBX-E0501 and starts nothing" {
    // Goal: HANDOFF's placeholder code, and that nothing is left behind. Method: start with an
    // unknown digest; the outcome carries the diagnostic and `list` is empty.
    var rig = try Rig.start();
    defer rig.stop();
    const outcome = try rig.launch("broken-1", "b3:00ffee11", &forever, &.{});
    try testing.expectEqualStrings("ZBX-E0501", outcome.failed.code.slice());
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

    const stubborn_command = [_][]const u8{
        "sh", "-c", "trap '' TERM; while true; do sleep 1; done",
    };
    const stubborn = try rig.begin("stubborn-1", &stubborn_command);
    try rig.fake.interface().stop(stubborn, constants.stop_grace_ms, &local);
    try testing.expect(try rig.status(stubborn) == .running);
    try rig.fake.interface().stop(stubborn, 0, &local);
    const killed = try rig.wait_stopped(stubborn);
    try testing.expectEqual(@as(u8, 9), killed.signaled);
    try rig.fake.interface().stop(stubborn, 0, &local); // Stopping a stopped one is nothing.
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
