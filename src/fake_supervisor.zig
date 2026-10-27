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
//! the command with the spec's environment and no terminal, record the command's pid, wait for
//! it, record how it ended. A `SIGTERM` to the supervisor is passed to the command, so that an
//! operator who stops the supervisor does not leave an orphan.
//!
//! What it does not do, because `FakeRuntime` is a plain host process with no isolation: apply
//! limits, set up namespaces, capture output (the command's stdio is /dev/null).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const files = @import("fake_files.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// The command's pid, for the signal handler, which has nowhere else to look.
var child_pid: std.atomic.Value(i32) = .init(0);

fn on_term(_: std.posix.SIG) callconv(.c) void {
    const pid = child_pid.load(.acquire);
    if (pid > 1) _ = std.os.linux.kill(pid, .TERM);
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
    const own_pid: i32 = @intCast(std.os.linux.getpid());
    files.write_pid(io, dir, files.file_supervisor, own_pid) catch
        return constants.exit_environment;
    const spec = files.read_json(files.SpecFile, io, dir, files.file_spec, arena) catch
        return constants.exit_environment;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = on_term },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    return supervise(init, dir, &spec);
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
    child_pid.store(pid, .release);
    files.write_pid(io, dir, files.file_child, pid) catch child.kill(io);
    const term = child.wait(io) catch return record(io, dir, .{ .kind = .lost });
    child_pid.store(0, .release);
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
