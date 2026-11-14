//! The supervisor of one `FakeRuntime` container: `zcube-agent supervise <container directory>`.
//! Shell code: it is a process of its own and it spawns, waits and signals.
//!
//! HANDOFF's recorded exception (principle 1) is that each container runs under a small
//! supervisor, because only a container's parent can collect its exit status across an agent
//! restart, and `zbx`'s `start` needs a single-threaded caller. This is that process for the fake
//! runtime. It is single-threaded until the command is spawned, and then only a job's relay
//! (`relay.zig`) adds threads; it is the command's parent; it starts its own session and
//! process group, so a restarted or killed agent leaves it alone; and it writes how the command
//! ended to `run.json`, which is what the agent reads, whenever it next looks.
//!
//! What it does, in order: start a session, take the directory's lock (held until the process
//! ends, however it ends: a lost supervisor is a lock that anyone can take), record its pid, run
//! the fetch `fetch.json` names if there is one (C2 slice 6b), run the command with the spec's
//! environment and no terminal, record the command's pid, wait for
//! it, record how it ended. A `SIGTERM` to the supervisor is passed to the command, so that an
//! operator who stops the supervisor does not leave an orphan.
//!
//! What it does not do, because `FakeRuntime` is a plain host process with no isolation: apply
//! limits, set up namespaces, capture output (the command's stdio is /dev/null).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const files = @import("fake_files.zig");
const backoff = @import("fetch_backoff.zig");
const relay_module = @import("relay.zig");
const Relay = relay_module.Relay;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// The command's pid, for the signal handler, which has nowhere else to look.
var child_pid: std.atomic.Value(i32) = .init(0);

/// Set once this supervisor itself got `SIGTERM`: a fetch that ends by a signal after that was
/// stopped; before it, the fetch crashed.
var term_received: std.atomic.Value(bool) = .init(false);

fn on_term(_: std.posix.SIG) callconv(.c) void {
    term_received.store(true, .seq_cst);
    const pid = child_pid.load(.seq_cst);
    if (pid > 1) term_group(pid);
}

/// `SIGTERM` to the command's (or the fetch's) process group, so what it started is told too; to
/// the pid alone if it leads no group (a command an older supervisor started, a test's child).
/// Async-signal-safe: raw system calls only.
fn term_group(pid: i32) void {
    assert(pid > 1);
    const rc = std.os.linux.kill(-pid, .TERM);
    if (std.os.linux.errno(rc) == .SUCCESS) return;
    _ = std.os.linux.kill(pid, .TERM);
}

/// Waits until the child `pid` has ended, without reaping it, then stops `on_term` from signalling
/// it. The caller reaps afterwards (`child.wait`). While the zombie exists its pid cannot be
/// reused, so a `SIGTERM` between the end and `child_pid = 0` signals the zombie, which is
/// harmless; reaping first would leave a window in which the pid could belong to another process
/// (issue #113).
fn wait_ended_unreaped(pid: i32) void {
    var info: std.os.linux.siginfo_t = undefined;
    while (true) {
        const flags = std.os.linux.W.EXITED | std.os.linux.W.NOWAIT;
        const rc = std.os.linux.waitid(.PID, pid, &info, flags, null);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => break, // Not our child, or already reaped: `child.wait` reports it.
        }
    }
    child_pid.store(0, .seq_cst);
}

/// Makes `pid` the child a `SIGTERM` is passed to. The handler stores the flag and then reads the
/// pid; this stores the pid and then reads the flag, all sequentially consistent, so at least one
/// side sees the other: a `SIGTERM` that came before the pid was published (the child already
/// exists, so a stopper can see it) is passed on here, not lost until the child ends by itself.
fn publish_child(pid: i32) void {
    assert(pid > 1);
    child_pid.store(pid, .seq_cst);
    if (term_received.load(.seq_cst)) term_group(pid);
}

/// Waits for `child` to end and reaps it, in the one order that is safe (issue #113). While its
/// zombie is unreaped its pid is still its own, so `child_pid` is cleared and `child.pid` is
/// removed first: after the reap the number may belong to a stranger, and neither the handler
/// nor an agent reading `child.pid` (`stop`, `signal`) may signal it then. `between` is a test
/// hook that runs in that window.
fn reap(
    io: std.Io,
    dir: ?Dir,
    child: *std.process.Child,
    between: ?*const fn () void,
) std.process.Child.WaitError!std.process.Child.Term {
    const pid = child.id.?;
    wait_ended_unreaped(pid);
    // What the child started ends with it, as in a pid namespace (B6 slice 3's review: a
    // `sh -c 'sleep 300'` stopped by `SIGTERM` to the shell left the `sleep` running). The
    // unreaped zombie still holds the group's id, so no stranger can own it; a child that leads
    // no group makes this ESRCH.
    _ = std.os.linux.kill(-pid, .KILL);
    if (dir) |own| own.deleteFile(io, files.file_child) catch {}; // Absent if it was never written.
    if (between) |hook| hook();
    return child.wait(io);
}

pub fn run(init: std.process.Init, dir_path: []const u8) u8 {
    assert(dir_path.len > 0);
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = Dir.openDirAbsolute(io, dir_path, .{}) catch return constants.exit_environment;
    defer dir.close(io);
    // A new session: signals and a closing terminal aimed at the agent do not reach it. The
    // command gets a group of its own inside it, so killing everything the supervisor started
    // is a kill of the session (`process_session.kill_all`), not of this group.
    _ = std.os.linux.setsid();
    const lock = dir.createFile(io, files.file_lock, .{ .truncate = false, .lock = .exclusive });
    // Not closed: the lock is released when the process ends, and that is what the agent tests.
    _ = lock catch return constants.exit_environment;
    // Before the pid file: whoever sees the supervisor (the pid file is how) may stop it, and a
    // `SIGTERM` before the handler stands would kill it with the default action.
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = on_term },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    const own_pid: i32 = @intCast(std.os.linux.getpid());
    files.write_pid(io, dir, files.file_supervisor, own_pid) catch
        return constants.exit_environment;
    const spec = files.read_json(files.SpecFile, io, dir, files.file_spec, arena) catch
        return constants.exit_environment;
    if (files.exists(io, dir, files.file_fetch)) {
        const failure = after_fetch(fetch_first(init, dir, arena));
        if (failure) |over| return record(io, dir, over);
    }
    return supervise(init, dir, dir_path, &spec);
}

/// What ends the container after its fetch: the fetch's failure if it failed, a stop if this
/// supervisor was sent `SIGTERM` meanwhile (the command must not start after it), else null.
fn after_fetch(failure: ?files.RunFile) ?files.RunFile {
    if (failure) |over| return over;
    if (term_received.load(.seq_cst)) return stopped_run();
    return null;
}

fn stopped_run() files.RunFile {
    return .{ .kind = .signaled, .signal = @intCast(@backingInt(std.posix.SIG.TERM)) };
}

/// Runs the fetch `fetch.json` names and waits for it; null if the image is now on the node,
/// else the `run.json` that says it is not. The container reports `starting` meanwhile (the
/// supervisor's pid exists, the command's does not). A `SIGTERM` reaches the fetch through
/// `child_pid`, like the command.
fn fetch_first(init: std.process.Init, dir: Dir, arena: Allocator) ?files.RunFile {
    const io = init.io;
    const plan = files.read_json(files.FetchFile, io, dir, files.file_fetch, arena) catch
        return failed(.environment, "the fetch record could not be read");
    // The fetch's diagnostics (ZC-W0601, ZC-E0601) are kept beside the container's other files.
    const log = dir.createFile(io, files.file_fetch_log, .{}) catch
        return failed(.environment, "the fetch log could not be created");
    defer log.close(io);
    const state = std.Io.Dir.openDirAbsolute(io, plan.state_dir, .{}) catch null;
    defer if (state) |opened| opened.close(io);
    if (state) |opened| {
        if (wait_for_backoff(io, opened, arena, &plan)) |stopped| return stopped;
    }
    var child = std.process.spawn(io, .{
        .argv = plan.argv,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0, // As the command's: a stop reaches the fetch's own children too.
    }) catch return failed(.environment, "the host refused to start the fetch");
    publish_child(child.id.?);
    const term = reap(io, null, &child, null) catch return .{ .kind = .lost };
    const result = fetch_ended(arena, plan.digest, term);
    if (state) |opened| settle_streak(io, opened, arena, plan.digest, result);
    return result;
}

/// What the fetch's end means for the next fetch on this node: a tree fetched ends the streak,
/// a failure of the fetch extends it, and anything else (a stop, this node's own setup) leaves
/// it as it was.
fn settle_streak(
    io: std.Io,
    state: Dir,
    arena: Allocator,
    digest: []const u8,
    result: ?files.RunFile,
) void {
    const failure = result orelse return backoff.clear(io, state, arena, digest);
    if (failure.kind != .start_failed) return;
    if (failure.blame != .fetch) return;
    backoff.record_failure(io, state, arena, digest, boot_ms(io));
}

fn boot_ms(io: std.Io) u64 {
    const ms = std.Io.Clock.boot.now(io).toMilliseconds();
    assert(ms >= 0);
    return @intCast(ms);
}

/// Waits out the back-off a failed fetch on this node left (`fetch_backoff.zig`), in short
/// sleeps so a `SIGTERM` ends the wait. Returns the container's end if it was stopped meanwhile.
fn wait_for_backoff(
    io: std.Io,
    state: Dir,
    arena: Allocator,
    plan: *const files.FetchFile,
) ?files.RunFile {
    assert(plan.backoff_base_ms > 0);
    assert(plan.backoff_cap_ms >= plan.backoff_base_ms);
    const streak = backoff.read(io, state, arena, plan.digest);
    while (true) {
        if (term_received.load(.seq_cst)) {
            return stopped_run();
        }
        const left = backoff.wait_remaining_ms(
            streak,
            boot_ms(io),
            plan.backoff_base_ms,
            plan.backoff_cap_ms,
        );
        if (left == 0) return null;
        const slice_ms: i64 = @min(left, constants.fetch_backoff_slice_ms);
        io.sleep(.fromMilliseconds(slice_ms), .boot) catch return null;
    }
}

fn fetch_ended(arena: Allocator, digest: []const u8, term: std.process.Child.Term) ?files.RunFile {
    switch (term) {
        .exited => |code| {
            if (code == constants.exit_ok) return null;
            return fetch_exit(arena, digest, code);
        },
        // Stopped while fetching: the container ended by that signal, it did not fail to start.
        // A signal this supervisor was not sent is the fetch crashing or being killed.
        .signal => |signal| {
            if (term_received.load(.seq_cst)) {
                return .{ .kind = .signaled, .signal = @intCast(@backingInt(signal)) };
            }
            return failed(.fetch, "the fetch ended by a signal before it finished the tree");
        },
        else => return failed(.environment, "the fetch ended in a way the host did not report"),
    }
}

/// What a fetch's exit code says (`fetch_cli.zig`): 3 is the tree not fetched (`ZC-E0601`, the
/// registry or the peers), 1 and 2 are this node's own setup, anything else is a crash.
fn fetch_exit(arena: Allocator, digest: []const u8, code: u8) files.RunFile {
    if (code == constants.exit_external) {
        const text = std.fmt.allocPrint(
            arena,
            "tree {s} was tried at this node's peers and the registry",
            .{digest},
        ) catch return failed(.environment, "the fetch failed");
        return failed(.fetch, text);
    }
    if (code == constants.exit_user or code == constants.exit_environment) {
        return failed(.environment, "the fetch could not run on this node; see fetch.log");
    }
    return failed(.fetch, "the fetch crashed; see fetch.log");
}

fn supervise(
    init: std.process.Init,
    dir: Dir,
    dir_path: []const u8,
    spec: *const files.SpecFile,
) u8 {
    const io = init.io;
    var environ = init.environ_map.clone(init.gpa) catch return constants.exit_environment;
    defer environ.deinit();
    for (spec.env) |pair| {
        if (!std.process.Environ.Map.validateKeyForPut(pair[0])) {
            return record(io, dir, failed(.user, "an environment name is not valid"));
        }
        environ.put(pair[0], pair[1]) catch return constants.exit_environment;
    }
    // The listener exists before the command does (its address is in the command's environment)
    // and is closed, with every connection, before the ending is recorded: `stop` returns only
    // when no thread of the relay is left.
    var relay: ?*Relay = null;
    if (spec.relay) |upstream| {
        switch (open_relay(init, dir, dir_path, upstream, &environ)) {
            .opened => |opened| relay = opened,
            .failed => |over| return record(io, dir, over),
        }
    }
    const ending = run_command(init, dir, spec, &environ, relay);
    if (relay) |open| open.stop();
    const over = ending orelse return constants.exit_environment;
    return record(io, dir, over);
}

const RelayOpening = union(enum) { opened: *Relay, failed: files.RunFile };

/// Opens the relay's listener and tells the command where it is (`ZCUBE_RELAY`, and the
/// `relay.port` file for the agent and for tests). A failure is ZC-E0702, its cause naming the
/// step: the job must not run without the route it was promised.
fn open_relay(
    init: std.process.Init,
    dir: Dir,
    dir_path: []const u8,
    upstream: []const u8,
    environ: *std.process.Environ.Map,
) RelayOpening {
    const target = relay_module.Upstream.parse(upstream) orelse {
        return relay_failed("the relay's address is not HOST:PORT");
    };
    const log_path = std.fmt.allocPrintSentinel(init.gpa, "{s}/{s}", .{
        dir_path, files.file_relay_log,
    }, 0) catch return relay_failed("there was no memory for the relay's log path");
    defer init.gpa.free(log_path);
    const relay = Relay.open(init.gpa, init.io, target, log_path) catch |err| {
        return relay_failed(switch (err) {
            error.SocketFailed => "the socket for the relay could not be made",
            error.BindFailed => "the relay could not bind 127.0.0.1",
            error.ListenFailed => "the relay could not listen on 127.0.0.1",
            error.OutOfMemory => "there was no memory for the relay",
        });
    };
    var text: [64]u8 = undefined;
    const address = std.fmt.bufPrint(&text, "http://127.0.0.1:{d}", .{relay.port}) catch
        unreachable; // 64 bytes hold a port.
    environ.put(constants.relay_env_name, address) catch {
        relay.stop();
        return relay_failed("the relay's address could not be put in the environment");
    };
    const port = std.fmt.bufPrint(&text, "{d}\n", .{relay.port}) catch
        unreachable; // 64 bytes hold a port and a newline.
    files.write_atomic(init.io, dir, files.file_relay_port, port) catch {
        relay.stop();
        return relay_failed("relay.port could not be written");
    };
    return .{ .opened = relay };
}

fn relay_failed(cause: []const u8) RelayOpening {
    return .{ .failed = failed(.relay, cause) };
}

/// Spawns the command, starts the relay (the supervisor is single-threaded until the command has
/// been spawned) and waits for the command; how it ended, or null if the supervisor itself broke.
fn run_command(
    init: std.process.Init,
    dir: Dir,
    spec: *const files.SpecFile,
    environ: *std.process.Environ.Map,
    relay: ?*Relay,
) ?files.RunFile {
    const io = init.io;
    var child = std.process.spawn(io, .{
        .argv = spec.command,
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // A group of its own inside this session: a stop reaches what the command started, and
        // `SIGKILL` to the command's group does not reach this supervisor before it records.
        .pgid = 0,
    }) catch |err| return spawn_failure(err);
    const pid: i32 = child.id.?;
    publish_child(pid);
    if (relay) |open| open.run() catch {
        // Without a relay thread the command has a listener nobody serves: end it.
        _ = std.os.linux.kill(pid, .KILL);
    };
    // Without its pid file nobody can find the command to stop it, so it ends here, by the same
    // reap as any other end (`child.kill` would reap first and `child.wait` then has no pid).
    files.write_pid(io, dir, files.file_child, pid) catch {
        _ = std.os.linux.kill(pid, .KILL);
    };
    const term = reap(io, dir, &child, null) catch return .{ .kind = .lost };
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    return ended(io, dir, arena_state.allocator(), term);
}

/// How the command ended, as `run.json` says it. A kill by `SIGKILL` that a test fault announced
/// in `forced` was the memory or process limit, not a signal.
fn ended(io: std.Io, dir: Dir, arena: Allocator, term: std.process.Child.Term) files.RunFile {
    switch (term) {
        .exited => |code| return .{ .kind = .exited, .code = code },
        .signal, .stopped => |signal| {
            const number: u8 = @intCast(@backingInt(signal));
            if (number != @backingInt(std.posix.SIG.KILL)) {
                return .{ .kind = .signaled, .signal = number };
            }
            const forced = files.read_bytes(io, dir, files.file_forced, arena) catch "";
            const word = std.mem.trim(u8, forced, "\n ");
            if (std.mem.eql(u8, word, "oom")) return .{ .kind = .oom };
            if (std.mem.eql(u8, word, "pid_limit")) return .{ .kind = .pid_limit };
            return .{ .kind = .signaled, .signal = number };
        },
        .unknown => return .{ .kind = .lost },
    }
}

fn failed(blame: files.Blame, cause: []const u8) files.RunFile {
    return .{ .kind = .start_failed, .cause = cause, .blame = blame };
}

/// Why the command could not be started, in a sentence a person can act on.
fn spawn_failure(err: std.process.SpawnError) files.RunFile {
    return switch (err) {
        error.FileNotFound => failed(.user, "the command was not found on this node"),
        error.AccessDenied, error.PermissionDenied => failed(.user, "the command may not be run"),
        error.InvalidExe => failed(.user, "the command is not an executable program"),
        error.IsDir, error.NotDir => failed(.user, "the command's path is not a program"),
        else => failed(.environment, "the host refused to start the command"),
    };
}

/// Writes `run.json`, the last thing the supervisor does. Returns the process's exit code.
fn record(io: std.Io, dir: Dir, run_file: files.RunFile) u8 {
    files.write_json(io, dir, files.file_run, run_file) catch return constants.exit_environment;
    return constants.exit_ok;
}

test "a SIGTERM during the fetch ends the container before its command; a failure is kept" {
    // Goal: the command must not start after the supervisor was stopped (review nit). Method:
    // `after_fetch` over no failure, a failure, and no failure with `term_received` set.
    term_received.store(false, .release);
    try std.testing.expect(after_fetch(null) == null);
    const failure = after_fetch(failed(.fetch, "x")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(files.Blame.fetch, failure.blame);
    term_received.store(true, .release);
    defer term_received.store(false, .release);
    const stopped = after_fetch(null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(files.RunKind.signaled, stopped.kind);
}

test "a SIGTERM that came before the fetch's pid was published still reaches the fetch" {
    // Goal: issue #90. A stopper can see the fetch (it is a child) before the supervisor has
    // published its pid, and the handler then had nobody to pass the signal to; the fetch ran on
    // to its own failure and the stopped replica ended as a failed start. Method: `term_received`
    // set first, then a real child published; it must die of SIGTERM.
    const io = std.testing.io;
    term_received.store(true, .seq_cst);
    defer term_received.store(false, .seq_cst);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "5" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    publish_child(child.id.?);
    defer child_pid.store(0, .seq_cst);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .TERM }, term);
}

var window_pid_seen: i32 = -1;
/// The test's child, whose zombie the window's hook looks for (`child_pid` is clear by then).
var window_child_pid: i32 = 0;
var window_zombie_seen: bool = false;

fn observe_window() void {
    window_pid_seen = child_pid.load(.seq_cst);
    // A SIGTERM in the window finds nobody to pass on to.
    on_term(.TERM);
    var info: std.os.linux.siginfo_t = undefined;
    const flags = std.os.linux.W.EXITED | std.os.linux.W.NOWAIT | std.os.linux.W.NOHANG;
    const rc = std.os.linux.waitid(.PID, window_child_pid, &info, flags, null);
    const found = std.os.linux.errno(rc) == .SUCCESS;
    window_zombie_seen = found and info.fields.common.first.piduid.pid != 0;
}

test "between the end of the command and its reap nothing can be signalled (issue #113)" {
    // Goal: after the command ended and before it is reaped its pid is not `child_pid` and its
    // `child.pid` file is gone, so a signal cannot reach a reused pid. Method: a real child that
    // exits at once, a `child.pid` file, and a hook in the window that records `child_pid`,
    // delivers the handler's SIGTERM and checks that the zombie is still there. Without the fix
    // (the reap before the clear) `window_pid_seen` is the child's pid.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try files.write_pid(io, tmp.dir, files.file_child, 4242);
    var child = try std.process.spawn(io, .{
        .argv = &.{"true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    publish_child(child.id.?);
    window_child_pid = child.id.?;
    defer term_received.store(false, .release); // The hook's SIGTERM sets it.
    window_pid_seen = -1;
    window_zombie_seen = false;
    const term = try reap(io, tmp.dir, &child, observe_window);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try std.testing.expectEqual(@as(i32, 0), window_pid_seen);
    try std.testing.expect(window_zombie_seen);
    try std.testing.expect(!files.exists(io, tmp.dir, files.file_child));
    term_received.store(false, .seq_cst);
}
