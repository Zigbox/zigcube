//! The supervisor of one `FakeRuntime` container: `zcube-agent supervise <container directory>`.
//! Shell code: it is a process of its own and it spawns, waits and signals.
//!
//! HANDOFF's recorded exception (principle 1) is that each container runs under a small
//! supervisor, because only a container's parent can collect its exit status across an agent
//! restart, and `zbx`'s `start` needs a single-threaded caller. This is that process for the fake
//! runtime. It is single-threaded; it is the command's parent; it starts its own session and
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
    if (pid > 1) _ = std.os.linux.kill(pid, .TERM);
}

/// Makes `pid` the child a `SIGTERM` is passed to. The handler stores the flag and then reads the
/// pid; this stores the pid and then reads the flag, all sequentially consistent, so at least one
/// side sees the other: a `SIGTERM` that came before the pid was published (the child already
/// exists, so a stopper can see it) is passed on here, not lost until the child ends by itself.
fn publish_child(pid: i32) void {
    assert(pid > 1);
    child_pid.store(pid, .seq_cst);
    if (term_received.load(.seq_cst)) _ = std.os.linux.kill(pid, .TERM);
}

pub fn run(init: std.process.Init, dir_path: []const u8) u8 {
    assert(dir_path.len > 0);
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = Dir.openDirAbsolute(io, dir_path, .{}) catch return constants.exit_environment;
    defer dir.close(io);
    // A new session and process group: signals and a closing terminal aimed at the agent do not
    // reach it, and one `kill(-pid)` reaches the supervisor and everything it started.
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
    return supervise(init, dir, &spec);
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
    }) catch return failed(.environment, "the host refused to start the fetch");
    publish_child(child.id.?);
    const term = child.wait(io) catch return .{ .kind = .lost };
    child_pid.store(0, .seq_cst);
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

fn supervise(init: std.process.Init, dir: Dir, spec: *const files.SpecFile) u8 {
    const io = init.io;
    var environ = init.environ_map.clone(init.gpa) catch return constants.exit_environment;
    defer environ.deinit();
    for (spec.env) |pair| {
        if (!std.process.Environ.Map.validateKeyForPut(pair[0])) {
            return record(io, dir, failed(.user, "an environment name is not valid"));
        }
        environ.put(pair[0], pair[1]) catch return constants.exit_environment;
    }
    var child = std.process.spawn(io, .{
        .argv = spec.command,
        .environ_map = &environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return record(io, dir, spawn_failure(err));
    const pid: i32 = child.id.?;
    publish_child(pid);
    files.write_pid(io, dir, files.file_child, pid) catch child.kill(io);
    const term = child.wait(io) catch return record(io, dir, .{ .kind = .lost });
    child_pid.store(0, .seq_cst);
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    return record(io, dir, ended(io, dir, arena_state.allocator(), term));
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
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    publish_child(child.id.?);
    defer child_pid.store(0, .seq_cst);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.posix.SIG.TERM, term.signal);
}
