//! `zcube local up` and `zcube local down`: a server (SQLite) and one agent (`FakeRuntime`) on this
//! machine, with no database to install and no administrator step (brief c1-7, section 6).
//!
//! **The one exception to "zcube opens no store and starts no process"** (docs/cli.md): every
//! other command is a client of the HTTP API. This file is therefore shell code, never part of the
//! wasm core, and nothing else imports it but `cli.zig`.
//!
//! Everything lives in one directory (`$ZCUBE_LOCAL_DIR`, else `$XDG_STATE_HOME/zcube/local`, else
//! `$HOME/.local/state/zcube/local`): the database, the agent's state directory (its containers),
//! a pid file and a log for each process, and the address the server listens on. `down` keeps all
//! of it, so the next `up` finds the same services and the agent adopts the same containers.
//!
//! The two processes are detached: their own process group, no input, output in their logs, so
//! they outlive `zcube` and a Ctrl-C at the prompt. A pid file alone is never trusted. The pid may
//! be dead, a zombie, or reused by a stranger, so a process counts as ours only if `/proc` shows
//! it alive, started when the pid file says, and with exactly the arguments `up` gave it (see
//! `is_ours`); anything else is a stale file, which is deleted and never signalled.
//!
//! `up` and `down` run one at a time: each holds a lock on `<dir>/lock` throughout.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const agent_config = @import("agent_config.zig");
const agent_http = @import("agent_http.zig");
const cli_args = @import("cli_args.zig");
const cli_env = @import("cli_env.zig");
const cli_report = @import("cli_report.zig");
const cli_commands = @import("cli_commands.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Env = cli_env.Env;
const Report = cli_report.Report;

const server_exe = "zcube-server";
const agent_exe = "zcube-agent";

/// The image digests the local agent's fake runtime has: `fixtures/images.zon`, which a person who
/// installed the three executables does not have. A test keeps the two in step.
const images_text =
    \\.{ .images = .{
    \\    "b3:51aa9c03", "b3:9d20c4f1",
    \\    "b3:51aa9c0351aa9c0351aa9c0351aa9c0351aa9c0351aa9c0351aa9c0351aa9c03",
    \\} }
    \\
;

// ---- The pure parts --------------------------------------------------------------------------

/// The directory `zcube local` keeps everything in; null if no variable names an absolute one.
pub fn local_dir(env: *const Env, buffer: *[constants.state_path_bytes_max]u8) ?[]const u8 {
    if (env.getenv("ZCUBE_LOCAL_DIR")) |dir| {
        if (std.fs.path.isAbsolute(dir) and dir.len < buffer.len) {
            const trimmed = std.mem.trimEnd(u8, dir, "/");
            if (trimmed.len == 0) return null;
            @memcpy(buffer[0..trimmed.len], trimmed);
            return buffer[0..trimmed.len];
        }
        return null;
    }
    var state: [constants.state_path_bytes_max]u8 = undefined;
    const base = env.state_dir(&state) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/local", .{base}) catch null;
}

/// A pid file holds the pid and the process's start time (field 22 of `/proc/<pid>/stat`, in clock
/// ticks since boot), each in decimal. The start time tells our process from a stranger that
/// was given the same pid later.
pub const PidFile = struct { pid: i32, start: u64 };

/// Anything but exactly `<pid> <start>` is not a pid file of ours.
pub fn parse_pid_file(text: []const u8) ?PidFile {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first = fields.next() orelse return null;
    const second = fields.next() orelse return null;
    if (fields.next() != null) return null;
    const pid = std.fmt.parseInt(i32, first, 10) catch return null;
    if (pid <= 1) return null; // 0, 1 and negatives address groups or init, never our children.
    const start = std.fmt.parseInt(u64, second, 10) catch return null;
    return .{ .pid = pid, .start = start };
}

/// Field 22 of `/proc/<pid>/stat`: when the process started. The fields after the last `)` begin
/// with field 3, so it is the 20th of those.
pub fn stat_start(stat: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeAny(u8, stat[close + 1 ..], " \n");
    var index: u32 = 3;
    while (fields.next()) |field| : (index += 1) {
        if (index == 22) return std.fmt.parseInt(u64, field, 10) catch null;
    }
    return null;
}

/// `HOST:PORT` of the address file, as the CLI's `$ZCUBE_SERVER` wants it; the port alone.
pub fn parse_port(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    const port = std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return port;
}

/// True if `/proc/<pid>/stat` says the process has ended and not been collected yet.
pub fn is_zombie(stat: []const u8) bool {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    const state = fields.next() orelse return false;
    return state[0] == 'Z' or state[0] == 'X';
}

pub const Role = enum {
    server,
    agent,

    fn exe_name(role: Role) []const u8 {
        return switch (role) {
            .server => server_exe,
            .agent => agent_exe,
        };
    }
};

/// True if `cmdline` (NUL-separated, from `/proc`) is the program `zcube local up` starts for
/// `role` in `dir`, and no other. Whole arguments are compared, never substrings: the program's
/// file name is the role's; it is not a container's supervisor (`zcube-agent supervise <dir>/...`
/// has the directory too); the server's `--store` is `sqlite:<dir>/zcube.db` and the agent's
/// `--state-dir` is `<dir>/agent`, so a sibling directory with the same prefix is not ours.
pub fn is_ours(cmdline: []const u8, role: Role, dir: []const u8) bool {
    assert(dir.len > 0);
    assert(dir[dir.len - 1] != '/');
    var args = std.mem.splitScalar(u8, cmdline, 0);
    const program = args.next().?; // A split always yields a first element.
    if (!std.mem.eql(u8, std.fs.path.basename(program), role.exe_name())) return false;
    const flag = switch (role) {
        .server => "--store",
        .agent => "--state-dir",
    };
    var found = false;
    var wanted = false;
    while (args.next()) |arg| {
        if (found) {
            if (!value_is(role, arg, dir)) return false;
            wanted = true;
            found = false;
        } else if (std.mem.eql(u8, arg, "supervise")) {
            return false;
        } else {
            found = std.mem.eql(u8, arg, flag);
        }
    }
    return wanted;
}

/// The value after `--store` or `--state-dir` that names `dir`'s own file or directory.
fn value_is(role: Role, value: []const u8, dir: []const u8) bool {
    const prefix = switch (role) {
        .server => "sqlite:",
        .agent => "",
    };
    const suffix = switch (role) {
        .server => "/zcube.db",
        .agent => "/agent",
    };
    if (!std.mem.startsWith(u8, value, prefix)) return false;
    const path = value[prefix.len..];
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return std.mem.eql(u8, path[dir.len..], suffix);
}

pub const Presence = enum { absent, running, stale };

pub const Found = struct { presence: Presence, pid: i32 };

/// What a pid file and `/proc` say about one process. `file` is null when there is no pid file,
/// `stat` and `cmdline` are null when there is no such process.
pub fn decide(
    file: ?[]const u8,
    stat: ?[]const u8,
    cmdline: ?[]const u8,
    role: Role,
    dir: []const u8,
) Found {
    const text = file orelse return .{ .presence = .absent, .pid = 0 };
    const recorded = parse_pid_file(text) orelse return .{ .presence = .stale, .pid = 0 };
    const pid = recorded.pid;
    const alive = stat orelse return .{ .presence = .stale, .pid = pid };
    if (is_zombie(alive)) return .{ .presence = .stale, .pid = pid };
    const start = stat_start(alive) orelse return .{ .presence = .stale, .pid = pid };
    if (start != recorded.start) return .{ .presence = .stale, .pid = pid };
    const line = cmdline orelse return .{ .presence = .stale, .pid = pid };
    if (!is_ours(line, role, dir)) return .{ .presence = .stale, .pid = pid };
    return .{ .presence = .running, .pid = pid };
}

/// The first of `tries` ports from `first` that `is_free` accepts; null if none is.
pub fn pick_port(
    first: u16,
    tries: u16,
    context: *anyopaque,
    is_free: *const fn (context: *anyopaque, port: u16) bool,
) ?u16 {
    assert(first > 0);
    assert(tries > 0);
    var offset: u16 = 0;
    while (offset < tries) : (offset += 1) {
        const port = std.math.add(u16, first, offset) catch return null;
        if (is_free(context, port)) return port;
    }
    return null;
}

// ---- Diagnostics -----------------------------------------------------------------------------

fn raise_no_dir(report: *Report) void {
    report.diag.raise(.E0116);
    report.diag.while_("finding the directory for zcube local", .{});
    report.diag.cause("none of ZCUBE_LOCAL_DIR, XDG_STATE_HOME and HOME is absolute", .{});
    report.diag.fix(.{
        .sentence = "name a directory you can write, then run it again:",
        .command = "export ZCUBE_LOCAL_DIR=$HOME/.local/state/zcube/local",
    });
}

fn raise_cannot_use_dir(report: *Report, what: []const u8) void {
    report.diag.raise(.E0116);
    report.diag.while_("preparing the directory for zcube local", .{});
    report.diag.cause("{s}", .{what});
    report.diag.fix(.{ .sentence = "name a directory you can write with ZCUBE_LOCAL_DIR" });
}

fn raise_no_executable(report: *Report, name: []const u8, dir: []const u8, what: []const u8) void {
    report.diag.raise(.E0122);
    report.diag.while_("starting the local {s}", .{name});
    report.diag.cause("{s} {s} in {s}", .{ name, what, dir });
    report.diag.fix(.{
        .sentence = "build them and run zcube from the directory they are in:",
        .command = "zig build && zig-out/bin/zcube local up",
    });
}

fn raise_not_up(report: *Report, step: []const u8, log: []const u8) void {
    report.diag.raise(.E0123);
    report.diag.while_("waiting for the local server and agent", .{});
    report.diag.cause("{s}", .{step});
    report.diag.fix_with("read the log; the process says why it failed there:", "cat {s}", .{log});
}

fn raise_busy(report: *Report, lock_path: []const u8, wait_ms: u32) void {
    report.diag.raise(.E0124);
    report.diag.while_("waiting for another zcube local command to finish", .{});
    // The text before the path is long enough that the path always wraps to a line of its own,
    // so the report does not depend on how long the path is.
    report.diag.cause("another zcube local command still held the lock after {d} s: {s}", .{
        @divFloor(wait_ms, 1000), lock_path,
    });
    report.diag.fix(.{ .sentence = "wait for the other zcube local command, then run this again" });
}

// ---- The lock --------------------------------------------------------------------------------

/// Takes an exclusive lock on the file at `path`, creating it. `up` and `down` hold it from start
/// to end, so two of them never run against the same processes at once. The kernel drops the lock
/// when its holder ends, however it ends, and the descriptor is close-on-exec, so the server and
/// the agent never inherit it. Waits at most `wait_ms` for the holder.
pub fn lock_file(io: std.Io, path: []const u8, wait_ms: u32) error{ Busy, Unusable }!std.Io.File {
    assert(path.len > 0);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch
        return error.Unusable;
    var waited: u32 = 0;
    while (true) {
        const got = file.tryLock(io, .exclusive) catch {
            file.close(io);
            return error.Unusable;
        };
        if (got) return file;
        if (waited >= wait_ms) {
            file.close(io);
            return error.Busy;
        }
        io.sleep(.fromMilliseconds(constants.local_poll_ms), .awake) catch {}; // Cancel.
        waited += constants.local_poll_ms;
    }
}

/// Marks every descriptor above stderr close-on-exec, so the server and the agent do not inherit
/// what our caller left open (`exec 7>file; zcube local up`). Descriptors made later by std are
/// close-on-exec already. A bounded scan: nobody keeps more than this many open across an exec.
fn close_inherited_on_exec() void {
    var fd: i32 = 3;
    while (fd < constants.local_fd_scan_max) : (fd += 1) {
        // EBADF for a descriptor that is not open is the common answer, and fine.
        _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
    }
}

// ---- The processes ---------------------------------------------------------------------------

/// Why `up` gave up and which process to blame: the log to read is that process's.
const NotUp = struct { culprit: Role, step: []const u8 };

/// The pids `stop_all` stopped; 0 for a process that was not running (or would not stop).
const Stopped = struct { server: i32 = 0, agent: i32 = 0 };

const Local = struct {
    env: *const Env,
    report: *Report,
    arena: Allocator,
    dir: []const u8,
    bin_dir: []const u8,

    fn path(local: *const Local, name: []const u8) Failed![]const u8 {
        return std.fmt.allocPrint(local.arena, "{s}/{s}", .{ local.dir, name }) catch
            return local.out_of_memory();
    }

    /// The whole of a small file, or null; a bigger one is not ours.
    fn read(local: *const Local, file: []const u8) ?[]const u8 {
        const buffer = local.arena.alloc(u8, constants.local_file_bytes_max) catch return null;
        return std.Io.Dir.cwd().readFile(local.env.io, file, buffer) catch null;
    }

    fn write(local: *const Local, name: []const u8, text: []const u8) !void {
        const file = try local.path(name);
        try std.Io.Dir.cwd().writeFile(local.env.io, .{ .sub_path = file, .data = text });
    }

    fn remove(local: *const Local, name: []const u8) void {
        const file = local.path(name) catch return;
        std.Io.Dir.cwd().deleteFile(local.env.io, file) catch {}; // Already gone is the goal.
    }

    /// What the pid file of `role` and `/proc` say about that process.
    fn find(local: *const Local, role: Role) Found {
        const stale: Found = .{ .presence = .stale, .pid = 0 };
        const pid_name = std.fmt.allocPrint(local.arena, "{s}.pid", .{@tagName(role)}) catch
            return stale;
        const file = local.read(local.path(pid_name) catch return stale);
        const recorded = if (file) |text| parse_pid_file(text) else null;
        if (recorded == null) return decide(file, null, null, role, local.dir);
        // Stack buffers: this runs on every poll, and the arena would grow by 9 KB each time.
        var stat_buffer: [1024]u8 = undefined;
        var line_buffer: [constants.local_cmdline_bytes_max]u8 = undefined;
        const pid = recorded.?.pid;
        const stat = read_proc(local.env.io, pid, "stat", &stat_buffer);
        const line = read_proc(local.env.io, pid, "cmdline", &line_buffer);
        return decide(file, stat, line, role, local.dir);
    }

    fn alive(local: *const Local, pid: i32) bool {
        var buffer: [1024]u8 = undefined;
        const stat = read_proc(local.env.io, pid, "stat", &buffer) orelse return false;
        return !is_zombie(stat);
    }

    fn sleep(local: *const Local) void {
        local.env.io.sleep(.fromMilliseconds(constants.local_poll_ms), .awake) catch {}; // Cancel.
    }

    /// SIGTERM, a wait, then SIGKILL. Only ever called with a pid `find` said is ours. True if
    /// the process is gone at the end; a refused signal (EPERM) is not "gone".
    fn stop(local: *const Local, pid: i32) bool {
        assert(pid > 1);
        std.posix.kill(pid, .TERM) catch |err| return err == error.ProcessNotFound;
        if (local.wait_gone(pid)) return true;
        std.posix.kill(pid, .KILL) catch |err| return err == error.ProcessNotFound;
        return local.wait_gone(pid);
    }

    fn wait_gone(local: *const Local, pid: i32) bool {
        var waited: u32 = 0;
        while (waited < constants.local_stop_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(pid)) return true;
            local.sleep();
        }
        return false;
    }

    fn out_of_memory(local: *const Local) error{Failed} {
        if (local.report.diag.code == null) {
            local.report.diag.raise(.E0120);
            local.report.diag.while_("running zcube local", .{});
            local.report.diag.cause("a request for memory was refused", .{});
            local.report.diag.fix(.{ .sentence = "free memory, then run it again" });
        }
        return error.Failed;
    }

    fn cannot_write(local: *const Local, what: []const u8) error{Failed} {
        var text: [constants.state_path_bytes_max + 64]u8 = undefined;
        const cause = std.fmt.bufPrint(&text, "can't write {s} in {s}", .{ what, local.dir }) catch
            "can't write in the local directory";
        raise_cannot_use_dir(local.report, cause);
        return error.Failed;
    }

    fn emit(local: *const Local, text: []const u8) Failed!void {
        cli_commands.emit(local.env, .stdout, text, local.report) catch return error.Failed;
    }

    /// Finds the two programs (nothing is created unless they are there), creates the directory
    /// (readable by this user only: the database may hold secrets), takes the lock, then writes
    /// the agent's state directory and the image list. The caller closes the returned lock file.
    fn prepare(local: *const Local) Failed!std.Io.File {
        const cwd = std.Io.Dir.cwd();
        for ([_]Role{ .server, .agent }) |role| {
            const exe = std.fmt.allocPrint(local.arena, "{s}/{s}", .{
                local.bin_dir, role.exe_name(),
            }) catch return local.out_of_memory();
            cwd.access(local.env.io, exe, .{ .execute = true }) catch {
                const what = "is not an executable file";
                raise_no_executable(local.report, role.exe_name(), local.bin_dir, what);
                return error.Failed;
            };
        }
        const parent = std.fs.path.dirname(local.dir) orelse "/";
        cwd.createDirPath(local.env.io, parent) catch return local.cannot_write("the directory");
        const private: std.Io.File.Permissions = @fromBackingInt(@intCast(0o700));
        cwd.createDir(local.env.io, local.dir, private) catch |err| {
            if (err != error.PathAlreadyExists) return local.cannot_write("the directory");
        };
        const held = try local.lock();
        errdefer held.close(local.env.io);
        const agent_dir = try local.path("agent");
        cwd.createDirPath(local.env.io, agent_dir) catch return local.cannot_write("agent");
        local.write("images.zon", images_text) catch return local.cannot_write("images.zon");
        return held;
    }

    fn lock(local: *const Local) Failed!std.Io.File {
        const file = try local.path("lock");
        return lock_file(local.env.io, file, local.env.local_lock_wait_ms) catch |err| {
            switch (err) {
                error.Busy => raise_busy(local.report, file, local.env.local_lock_wait_ms),
                error.Unusable => raise_cannot_use_dir(local.report, "can't lock the directory"),
            }
            return error.Failed;
        };
    }

    /// The port the server used last time if it is free (so `$ZCUBE_SERVER` stays valid), else
    /// the first free one from 7070.
    fn choose_port(local: *const Local) u16 {
        const self: *anyopaque = @ptrCast(@constCast(local));
        if (local.read(local.path("address") catch "")) |text| {
            if (parse_port(text)) |port| {
                if (port_is_free(self, port)) return port;
            }
        }
        const found = pick_port(
            constants.local_port_first,
            constants.local_port_tries_max,
            self,
            port_is_free,
        );
        // All 32 busy is not an error of ours: the bind fails and the server's log says so.
        return found orelse constants.local_port_first;
    }

    fn start_server(local: *const Local, address: []const u8) Failed!i32 {
        const database = std.fmt.allocPrint(local.arena, "sqlite:{s}/zcube.db", .{local.dir}) catch
            return local.out_of_memory();
        return local.spawn(.server, &.{
            "--insecure-listen", address, "--store", database, "--create-store", "--quiet",
        });
    }

    fn start_agent(local: *const Local, address: []const u8) Failed!i32 {
        const agent_dir = try local.path("agent");
        const images = try local.path("images.zon");
        var cpu: [16]u8 = undefined;
        var memory: [24]u8 = undefined;
        // A u32 has 10 digits and a u64 20, so neither buffer can run out.
        const cpu_text = std.fmt.bufPrint(&cpu, "{d}", .{constants.local_cpu_millis}) catch
            unreachable;
        const memory_text = std.fmt.bufPrint(&memory, "{d}", .{constants.local_memory_bytes}) catch
            unreachable;
        return local.spawn(.agent, &.{
            "--node",         constants.local_node_name,
            "--server",       address,
            "--state-dir",    agent_dir,
            "--cpu-millis",   cpu_text,
            "--memory-bytes", memory_text,
            "--images",       images,
        });
    }

    /// Starts the program of `role` detached (a process group of its own, no input, output in
    /// `<role>.log`; the last run's log is kept as `<role>.log.1`) and records its pid and start
    /// time. Returns the pid.
    fn spawn(local: *const Local, role: Role, args: []const []const u8) Failed!i32 {
        const arena = local.arena;
        const io = local.env.io;
        const cwd = std.Io.Dir.cwd();
        const log_name = std.fmt.allocPrint(arena, "{s}.log", .{@tagName(role)}) catch
            return local.out_of_memory();
        const log_path = try local.path(log_name);
        const older = std.fmt.allocPrint(arena, "{s}.1", .{log_path}) catch
            return local.out_of_memory();
        cwd.rename(log_path, cwd, older, io) catch {}; // No earlier log is fine.
        const log = cwd.createFile(io, log_path, .{}) catch return local.cannot_write(log_name);
        defer log.close(io);
        const exe = role.exe_name();
        const argv = arena.alloc([]const u8, args.len + 1) catch return local.out_of_memory();
        argv[0] = std.fmt.allocPrint(arena, "{s}/{s}", .{ local.bin_dir, exe }) catch
            return local.out_of_memory();
        @memcpy(argv[1..], args);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = log },
            .stderr = .{ .file = log },
            .pgid = 0,
        }) catch {
            raise_no_executable(local.report, exe, local.bin_dir, "could not be started");
            return error.Failed;
        };
        const pid: i32 = child.id.?; // A spawned child has an id.
        var buffer: [1024]u8 = undefined;
        const stat = read_proc(io, pid, "stat", &buffer);
        const start = if (stat) |text| stat_start(text) orelse 0 else 0; // 0 never matches.
        const text = std.fmt.allocPrint(arena, "{d} {d}\n", .{ pid, start }) catch {
            child.kill(io);
            return local.out_of_memory();
        };
        const pid_name = std.fmt.allocPrint(arena, "{s}.pid", .{@tagName(role)}) catch {
            child.kill(io);
            return local.out_of_memory();
        };
        local.write(pid_name, text) catch {
            child.kill(io); // Untracked, so it must not keep running.
            return local.cannot_write(pid_name);
        };
        return pid;
    }

    /// A GET that answered 200: its body.
    fn get(local: *const Local, port: u16, target: []const u8) ?[]const u8 {
        const address = net.IpAddress.parse("127.0.0.1", port) catch return null;
        const client: agent_http.Client = .{
            .io = local.env.io,
            .address = address,
            .io_timeout_ms = 1000,
        };
        var diag: diag_mod.Diag = undefined;
        diag.reset();
        const reply = client.call(local.arena, .{ .method = "GET", .target = target }, &diag) catch
            return null;
        if (reply.status != 200) return null;
        return reply.body;
    }

    /// Is the node's registration in the store?
    fn node_present(local: *const Local, port: u16) bool {
        const body = local.get(port, "/v1/list?prefix=/nodes/") orelse return false;
        const Json = std.json.Value;
        const root = std.json.parseFromSliceLeaky(Json, local.arena, body, .{}) catch return false;
        if (root != .object) return false;
        const kvs = root.object.get("kvs") orelse return false;
        if (kvs != .array) return false;
        for (kvs.array.items) |kv| {
            if (kv != .object) continue;
            const key = kv.object.get("key") orelse continue;
            if (key != .string) continue;
            if (!std.mem.eql(u8, key.string, "/nodes/" ++ constants.local_node_name)) continue;
            return true;
        }
        return false;
    }

    /// Waits until the server answers `/v1/status`. Null when it does.
    fn wait_server(local: *const Local, port: u16, server: i32) ?NotUp {
        var waited: u32 = 0;
        while (waited < constants.local_up_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(server)) {
                return .{ .culprit = .server, .step = "the server stopped before it answered" };
            }
            if (local.get(port, "/v1/status") != null) return null;
            local.sleep();
        }
        return local.timed_out(.server, "answer");
    }

    /// Waits until this agent has registered its node. `/nodes/local` alone proves nothing: an
    /// earlier run left one in the store, and registering again writes the same value, so its
    /// revision does not move. The agent's log is new for each start (`spawn` rotates the old
    /// one) and says "registered" once it has; the node must be in the store as well. Null when
    /// both hold.
    fn wait_node(local: *const Local, port: u16, pids: [2]i32) ?NotUp {
        var waited: u32 = 0;
        while (waited < constants.local_up_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(pids[0])) {
                const step = "the server stopped before the node registered";
                return .{ .culprit = .server, .step = step };
            }
            if (!local.alive(pids[1])) {
                const step = "the agent stopped before its node registered";
                return .{ .culprit = .agent, .step = step };
            }
            if (local.registered_in_log() and local.node_present(port)) return null;
            local.sleep();
        }
        return local.timed_out(.agent, "register its node");
    }

    fn registered_in_log(local: *const Local) bool {
        var log_path: [constants.state_path_bytes_max + 16]u8 = undefined;
        const name = std.fmt.bufPrint(&log_path, "{s}/agent.log", .{local.dir}) catch return false;
        var buffer: [constants.local_file_bytes_max]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(local.env.io, name, &buffer) catch return false;
        return std.mem.find(u8, bytes, " registered on lease ") != null;
    }

    fn timed_out(local: *const Local, culprit: Role, what: []const u8) NotUp {
        const format = "the {s} did not {s} within {d} s";
        const seconds = @divFloor(constants.local_up_wait_ms, 1000);
        const step = std.fmt.allocPrint(local.arena, format, .{
            @tagName(culprit), what, seconds,
        }) catch "the local server or agent did not come up";
        return .{ .culprit = culprit, .step = step };
    }

    fn say_up(
        local: *const Local,
        what: []const u8,
        address: []const u8,
        server: Found,
        agent: Found,
    ) Failed!void {
        const text = std.fmt.allocPrint(local.arena, "local: {s}\n" ++
            "  server  {s} (pid {d}), log {s}/server.log\n" ++
            "  agent   node {s} (pid {d}), log {s}/agent.log\n" ++
            "  state   {s}\n" ++
            "next:\n" ++
            "  export ZCUBE_SERVER={s}\n" ++
            "  zcube apply hello.zon\n" ++
            "stop it with: zcube local down\n", .{
            what,                      address,   server.pid, local.dir,
            constants.local_node_name, agent.pid, local.dir,  local.dir,
            address,
        }) catch return local.out_of_memory();
        try local.emit(text);
    }

    /// Stops what is running (the agent first, so it does not report a server that went away) and
    /// deletes the pid files of what is gone. A process that would not stop keeps its pid file.
    fn stop_all(local: *const Local) Stopped {
        var stopped: Stopped = .{};
        for ([_]Role{ .agent, .server }) |role| {
            const found = local.find(role);
            const gone = found.presence != .running or local.stop(found.pid);
            if (found.presence == .running and gone) switch (role) {
                .agent => stopped.agent = found.pid,
                .server => stopped.server = found.pid,
            };
            if (!gone) continue;
            const pid_name = std.fmt.allocPrint(local.arena, "{s}.pid", .{@tagName(role)}) catch
                continue;
            local.remove(pid_name);
        }
        return stopped;
    }

    /// Stops everything, then reports which log explains the failure.
    fn give_up(local: *const Local, bad: NotUp) Failed {
        _ = local.stop_all();
        const log = if (bad.culprit == .agent) "agent.log" else "server.log";
        raise_not_up(local.report, bad.step, local.path(log) catch local.dir);
        return error.Failed;
    }

    /// What `down` says: only the processes it stopped.
    fn stopped_text(local: *const Local, stopped: Stopped) Failed![]const u8 {
        const kept = "; state kept in {s}\n" ++
            "the agent's containers keep running; zcube local up adopts them\n";
        const both = "local: stopped server (pid {d}) and agent (pid {d})" ++ kept;
        const text = if (stopped.server > 0 and stopped.agent > 0)
            std.fmt.allocPrint(local.arena, both, .{ stopped.server, stopped.agent, local.dir })
        else if (stopped.server > 0)
            std.fmt.allocPrint(local.arena, "local: stopped server (pid {d})" ++ kept, .{
                stopped.server, local.dir,
            })
        else if (stopped.agent > 0)
            std.fmt.allocPrint(local.arena, "local: stopped agent (pid {d})" ++ kept, .{
                stopped.agent, local.dir,
            })
        else
            std.fmt.allocPrint(local.arena, "local: not running\n", .{});
        return text catch return local.out_of_memory();
    }
};

/// The contents of `/proc/<pid>/<name>`, or null if there is no such process or file.
fn read_proc(io: std.Io, pid: i32, name: []const u8, buffer: []u8) ?[]const u8 {
    var file: [48]u8 = undefined;
    const path = std.fmt.bufPrint(&file, "/proc/{d}/{s}", .{ pid, name }) catch return null;
    return std.Io.Dir.cwd().readFile(io, path, buffer) catch null;
}

/// Is `port` free? A connection that is refused says yes; anything that answers, or is not
/// refused, says no. (Binding to test would need SO_REUSEADDR, which hides a listener.)
fn port_is_free(context: *anyopaque, port: u16) bool {
    const local: *const Local = @ptrCast(@alignCast(context));
    const address = net.IpAddress.parse("127.0.0.1", port) catch return false;
    const client: agent_http.Client = .{
        .io = local.env.io,
        .address = address,
        .io_timeout_ms = 1000,
    };
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    _ = client.call(local.arena, .{ .method = "GET", .target = "/v1/status" }, &diag) catch |err| {
        return err == error.Unreachable;
    };
    return false;
}

const Failed = error{Failed};

/// The failure is in `local.report`; a step that has no diagnostic of its own is a bug.
fn up(local: *const Local) Failed!void {
    const held = try local.prepare();
    defer held.close(local.env.io);
    const server = local.find(.server);
    const agent = local.find(.agent);
    if (server.presence == .running and agent.presence == .running) {
        if (local.read(try local.path("address"))) |address| {
            const where = std.mem.trim(u8, address, " \t\r\n");
            return local.say_up("already running", where, server, agent);
        }
    }
    // Anything half-running is stopped, so the two always start together on one address. The
    // agent's containers are not touched by that: it adopts them again.
    _ = local.stop_all();
    const port = local.choose_port();
    const address = std.fmt.allocPrint(local.arena, "127.0.0.1:{d}", .{port}) catch
        return local.out_of_memory();
    local.write("address", address) catch return local.cannot_write("address");
    const started_server = try local.start_server(address);
    if (local.wait_server(port, started_server)) |bad| return local.give_up(bad);
    const started_agent = local.start_agent(address) catch |err| {
        _ = local.stop_all();
        return err;
    };
    const pids = [2]i32{ started_server, started_agent };
    if (local.wait_node(port, pids)) |bad| return local.give_up(bad);
    const found_server: Found = .{ .presence = .running, .pid = started_server };
    const found_agent: Found = .{ .presence = .running, .pid = started_agent };
    return local.say_up("up", address, found_server, found_agent);
}

fn down(local: *const Local) Failed!void {
    // Nothing to stop, and nothing to lock, if the directory was never made.
    const exists = if (std.Io.Dir.cwd().access(local.env.io, local.dir, .{})) true else |_| false;
    if (!exists) return local.emit("local: not running\n");
    const held = try local.lock();
    defer held.close(local.env.io);
    const stopped = local.stop_all();
    try local.emit(try local.stopped_text(stopped));
}

pub fn run(env: *const Env, action: cli_args.LocalAction, report: *Report) u8 {
    var buffer: [constants.state_path_bytes_max]u8 = undefined;
    const dir = local_dir(env, &buffer) orelse {
        raise_no_dir(report);
        return constants.exit_environment;
    };
    var bin_buffer: [constants.state_path_bytes_max]u8 = undefined;
    const bin_dir = env.bin_dir orelse blk: {
        const length = std.process.executableDirPath(env.io, &bin_buffer) catch {
            raise_no_executable(report, "zcube", "the directory of this program", "can't be found");
            return constants.exit_environment;
        };
        break :blk bin_buffer[0..length];
    };
    const local: Local = .{
        .env = env,
        .report = report,
        .arena = env.arena,
        .dir = dir,
        .bin_dir = bin_dir,
    };
    const result = switch (action) {
        .up => blk: {
            close_inherited_on_exec();
            break :blk up(&local);
        },
        .down => down(&local),
    };
    result catch return constants.exit_environment;
    return constants.exit_ok;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "the local directory follows ZCUBE_LOCAL_DIR, then XDG_STATE_HOME, then HOME" {
    // Goal: where `zcube local` keeps its files. Method: each variable alone and together, a
    // relative one refused, a trailing slash trimmed, none at all.
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const env: Env = .{
        .io = testing.io,
        .arena = testing.allocator,
        .environ = &map,
        .stdout = &sink.writer,
        .stderr = &sink.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0",
    };
    var buffer: [constants.state_path_bytes_max]u8 = undefined;
    try testing.expect(local_dir(&env, &buffer) == null);
    try map.put("HOME", "/home/alex");
    const home_dir = local_dir(&env, &buffer).?;
    try testing.expectEqualStrings("/home/alex/.local/state/zcube/local", home_dir);
    try map.put("XDG_STATE_HOME", "/var/state");
    try testing.expectEqualStrings("/var/state/zcube/local", local_dir(&env, &buffer).?);
    try map.put("ZCUBE_LOCAL_DIR", "/work/z/");
    try testing.expectEqualStrings("/work/z", local_dir(&env, &buffer).?);
    try map.put("ZCUBE_LOCAL_DIR", "z");
    try testing.expect(local_dir(&env, &buffer) == null);
    try map.put("ZCUBE_LOCAL_DIR", "/");
    try testing.expect(local_dir(&env, &buffer) == null);
}

test "pid and port files parse only what we wrote" {
    // Goal: a damaged or foreign file is never mistaken for a process or a port.
    const ok = parse_pid_file("4242 99\n").?;
    try testing.expectEqual(@as(i32, 4242), ok.pid);
    try testing.expectEqual(@as(u64, 99), ok.start);
    try testing.expect(parse_pid_file("") == null);
    try testing.expect(parse_pid_file("abc 1") == null);
    try testing.expect(parse_pid_file("4242\n") == null); // No start time: not ours.
    try testing.expect(parse_pid_file("4242 99 7") == null);
    try testing.expect(parse_pid_file("-1 5") == null);
    try testing.expect(parse_pid_file("0 5") == null);
    try testing.expect(parse_pid_file("1 5") == null);
    try testing.expect(parse_pid_file("4242 -3") == null);
    try testing.expectEqual(@as(?u16, 7071), parse_port("127.0.0.1:7071\n"));
    try testing.expectEqual(@as(?u16, null), parse_port("127.0.0.1"));
    try testing.expectEqual(@as(?u16, null), parse_port("127.0.0.1:0"));
    try testing.expectEqual(@as(?u16, null), parse_port("127.0.0.1:70000"));
}

test "the start time is field 22 of the stat line" {
    // Goal: the number we compare is the process's start. Method: a real stat line, and a name
    // with spaces and parentheses that would shift a naive split.
    const real = "2935 (zcube-server) S 1 2935 2935 0 -1 4194560 1000 0 0 0 5 3 0 0 20 0 4 0 " ++
        "123456 100000000 2000 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0";
    try testing.expectEqual(@as(?u64, 123456), stat_start(real));
    const odd = "9 (a b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777 20";
    try testing.expectEqual(@as(?u64, 777), stat_start(odd));
    try testing.expectEqual(@as(?u64, null), stat_start("9 (a) S 1 2"));
    try testing.expectEqual(@as(?u64, null), stat_start("garbage"));
}

test "a stale pid file is told from a running process of ours" {
    // Goal: never signal a stranger. Method: every way a pid file can lie, then the one truth.
    const dir = "/tmp/zl";
    const mine = "/usr/bin/zcube-server\x00--store\x00sqlite:/tmp/zl/zcube.db\x00";
    const alive = "123 (zcube-server) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 500 20";
    const file = "123 500\n";
    try expect_presence(.absent, decide(null, null, null, .server, dir));
    try expect_presence(.stale, decide("junk", alive, mine, .server, dir));
    try expect_presence(.stale, decide("123 500\n", null, null, .server, dir));
    const zombie = "123 (zcube-server) Z 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 500 20";
    try expect_presence(.stale, decide(file, zombie, mine, .server, dir));
    // The same pid, started later: a reused pid.
    try expect_presence(.stale, decide("123 499\n", alive, mine, .server, dir));
    const stranger = "/usr/bin/vim\x00/tmp/zl/notes\x00";
    try expect_presence(.stale, decide(file, alive, stranger, .server, dir));
    const elsewhere = "/usr/bin/zcube-server\x00--store\x00sqlite:/other/zcube.db\x00";
    try expect_presence(.stale, decide(file, alive, elsewhere, .server, dir));
    // A sibling directory that shares our prefix is not ours.
    const sibling = "/usr/bin/zcube-server\x00--store\x00sqlite:/tmp/zl2/zcube.db\x00";
    try expect_presence(.stale, decide(file, alive, sibling, .server, dir));
    const found = decide(file, alive, mine, .server, dir);
    try testing.expectEqual(Presence.running, found.presence);
    try testing.expectEqual(@as(i32, 123), found.pid);
    // A process name with spaces and parentheses must not fool the zombie check.
    try testing.expect(!is_zombie("9 (a) Z) S 1"));
    try testing.expect(is_zombie("9 (a) Z 1"));
}

test "only the agent and the server of this directory are ours" {
    // Goal: the two command lines the review found being taken for the agent. Method: each
    // against both roles, with the real argument lists `start_agent` and `start_server` use.
    const dir = "/tmp/zl";
    const agent = "/b/zcube-agent\x00--node\x00local\x00--server\x00127.0.0.1:7070\x00" ++
        "--state-dir\x00/tmp/zl/agent\x00--images\x00/tmp/zl/images.zon\x00";
    const server = "/b/zcube-server\x00--listen\x00127.0.0.1:7070\x00--store\x00" ++
        "sqlite:/tmp/zl/zcube.db\x00--create-store\x00--quiet\x00";
    try testing.expect(is_ours(agent, .agent, dir));
    try testing.expect(is_ours(server, .server, dir));
    try testing.expect(!is_ours(agent, .server, dir));
    try testing.expect(!is_ours(server, .agent, dir));
    // Our own container supervisor has the directory in its arguments and the agent's name.
    const supervisor = "/b/zcube-agent\x00supervise\x00/tmp/zl/agent/containers/hello-1\x00";
    try testing.expect(!is_ours(supervisor, .agent, dir));
    try testing.expect(!is_ours(supervisor, .server, dir));
    // A prefix directory (`zl2`) is another instance's, in both roles, and so is a longer path.
    try testing.expect(!is_ours(agent, .agent, "/tmp/z"));
    try testing.expect(!is_ours(server, .server, "/tmp/z"));
    try testing.expect(!is_ours(agent, .agent, "/tmp/zl/agent"));
    const nested = "/b/zcube-agent\x00--state-dir\x00/tmp/zl/agent/x\x00";
    try testing.expect(!is_ours(nested, .agent, dir));
    // No flag at all, an empty command line, and a flag without its value.
    try testing.expect(!is_ours("/b/zcube-agent\x00", .agent, dir));
    try testing.expect(!is_ours("", .agent, dir));
    try testing.expect(!is_ours("/b/zcube-agent\x00--state-dir", .agent, dir));
}

test "the lock is exclusive, then free once its holder lets go" {
    // Goal: two `zcube local` commands never run at once. Method: two descriptors on one file
    // (the kernel treats each as a holder, as it would two processes), a short wait for the
    // second, then the first closing.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}/lock", .{
        cwd, tmp.sub_path,
    });
    defer testing.allocator.free(file);
    const first = try lock_file(testing.io, file, 0);
    try testing.expectError(error.Busy, lock_file(testing.io, file, 3 * constants.local_poll_ms));
    first.close(testing.io);
    const second = try lock_file(testing.io, file, 0);
    second.close(testing.io);
}

fn expect_presence(want: Presence, found: Found) !void {
    try testing.expectEqual(want, found.presence);
}

const FreeSet = struct {
    taken_below: u16,

    fn is_free(context: *anyopaque, port: u16) bool {
        const set: *FreeSet = @ptrCast(@alignCast(context));
        return port >= set.taken_below;
    }
};

test "the port is the first free one, or none" {
    // Goal: 7070 or the next free port. Method: a fake probe with a boundary, and an exhausted run.
    var set: FreeSet = .{ .taken_below = 7070 };
    try testing.expectEqual(@as(?u16, 7070), pick_port(7070, 4, &set, FreeSet.is_free));
    set.taken_below = 7073;
    try testing.expectEqual(@as(?u16, 7073), pick_port(7070, 4, &set, FreeSet.is_free));
    set.taken_below = 7074;
    try testing.expectEqual(@as(?u16, null), pick_port(7070, 4, &set, FreeSet.is_free));
    set.taken_below = 0;
    try testing.expectEqual(@as(?u16, null), pick_port(65535, 2, &set, struct {
        fn never(_: *anyopaque, _: u16) bool {
            return false;
        }
    }.never));
}

test "the embedded image list is the fixture's" {
    // Goal: an installed `zcube` writes the same images the repository's fixture lists.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const ours = try agent_config.parse_images(arena, images_text, "images.zon", &diag);
    const buffer = try arena.allocSentinel(u8, 4096, 0);
    const read = try std.Io.Dir.cwd().readFile(testing.io, "fixtures/images.zon", buffer);
    buffer[read.len] = 0;
    const source = buffer[0..read.len :0];
    const theirs = try agent_config.parse_images(arena, source, "images.zon", &diag);
    try testing.expectEqual(theirs.len, ours.len);
    for (ours, theirs) |a, b| try testing.expectEqualStrings(a, b);
}
