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
//! it alive and its command line is the expected program working in this directory; anything else
//! is a stale file, which is deleted and never signalled.

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
    \\.{ .images = .{ "b3:51aa9c03", "b3:9d20c4f1" } }
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

/// A pid file holds one decimal pid and a newline. Anything else is not a pid file of ours.
pub fn parse_pid(text: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const pid = std.fmt.parseInt(i32, trimmed, 10) catch return null;
    if (pid <= 1) return null; // 0, 1 and negatives address groups or init, never our children.
    return pid;
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

/// True if `cmdline` (NUL-separated, from `/proc`) is `exe_name` working in `dir`: the program's
/// file name is `exe_name` and some argument names the directory. A reused pid fails one of the two.
pub fn is_ours(cmdline: []const u8, exe_name: []const u8, dir: []const u8) bool {
    assert(exe_name.len > 0);
    assert(dir.len > 0);
    const end = std.mem.indexOfScalar(u8, cmdline, 0) orelse cmdline.len;
    if (!std.mem.eql(u8, std.fs.path.basename(cmdline[0..end]), exe_name)) return false;
    return std.mem.find(u8, cmdline[end..], dir) != null;
}

pub const Presence = enum { absent, running, stale };

pub const Found = struct { presence: Presence, pid: i32 };

/// What a pid file and `/proc` say about one process. `file` is null when there is no pid file,
/// `stat` and `cmdline` are null when there is no such process.
pub fn decide(
    file: ?[]const u8,
    stat: ?[]const u8,
    cmdline: ?[]const u8,
    exe_name: []const u8,
    dir: []const u8,
) Found {
    const text = file orelse return .{ .presence = .absent, .pid = 0 };
    const pid = parse_pid(text) orelse return .{ .presence = .stale, .pid = 0 };
    const alive = stat orelse return .{ .presence = .stale, .pid = pid };
    if (is_zombie(alive)) return .{ .presence = .stale, .pid = pid };
    const line = cmdline orelse return .{ .presence = .stale, .pid = pid };
    if (!is_ours(line, exe_name, dir)) return .{ .presence = .stale, .pid = pid };
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
    report.diag.cause("neither ZCUBE_LOCAL_DIR, XDG_STATE_HOME nor HOME names an absolute path", .{});
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
    report.diag.while_("waiting for the local server", .{});
    report.diag.cause("{s}", .{step});
    report.diag.fix_with("read the log; the process says why it failed there:", "cat {s}", .{log});
}

// ---- The processes ---------------------------------------------------------------------------

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

    /// What the pid file named `<which>.pid` and `/proc` say about that process.
    fn find(local: *const Local, which: []const u8, exe_name: []const u8) Found {
        const pid_name = std.fmt.allocPrint(local.arena, "{s}.pid", .{which}) catch
            return .{ .presence = .stale, .pid = 0 };
        const file = local.read(local.path(pid_name) catch return .{
            .presence = .stale,
            .pid = 0,
        });
        const pid = if (file) |text| parse_pid(text) else null;
        if (pid == null) return decide(file, null, null, exe_name, local.dir);
        const stat = local.proc(pid.?, "stat");
        const line = local.proc(pid.?, "cmdline");
        return decide(file, stat, line, exe_name, local.dir);
    }

    fn proc(local: *const Local, pid: i32, name: []const u8) ?[]const u8 {
        const file = std.fmt.allocPrint(local.arena, "/proc/{d}/{s}", .{ pid, name }) catch
            return null;
        return local.read(file);
    }

    fn alive(local: *const Local, pid: i32) bool {
        const stat = local.proc(pid, "stat") orelse return false;
        return !is_zombie(stat);
    }

    fn sleep(local: *const Local) void {
        local.env.io.sleep(.fromMilliseconds(constants.local_poll_ms), .awake) catch {}; // Cancel.
    }

    /// SIGTERM, a wait, then SIGKILL. Only ever called with a pid `find` said is ours.
    fn stop(local: *const Local, pid: i32) void {
        assert(pid > 1);
        std.posix.kill(pid, .TERM) catch return; // Gone already.
        var waited: u32 = 0;
        while (waited < constants.local_stop_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(pid)) return;
            local.sleep();
        }
        std.posix.kill(pid, .KILL) catch return;
        waited = 0;
        while (waited < constants.local_stop_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(pid)) return;
            local.sleep();
        }
    }

    fn out_of_memory(local: *const Local) error{Failed} {
        if (local.report.diag.code == null) {
            local.report.diag.raise(.E0120);
            local.report.diag.while_("running zcube local", .{});
            local.report.diag.cause("a request for memory was refused", .{});
            local.report.diag.fix(.{ .sentence = "free memory on this machine, then run it again" });
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

    /// Creates the directory, the agent's state directory and the image list, and finds the two
    /// programs: nothing is started unless all of that is in place.
    fn prepare(local: *const Local) Failed!void {
        const cwd = std.Io.Dir.cwd();
        const agent_dir = try local.path("agent");
        cwd.createDirPath(local.env.io, agent_dir) catch return local.cannot_write("the directory");
        for ([_][]const u8{ server_exe, agent_exe }) |name| {
            const exe = std.fmt.allocPrint(local.arena, "{s}/{s}", .{ local.bin_dir, name }) catch
                return local.out_of_memory();
            cwd.access(local.env.io, exe, .{ .execute = true }) catch {
                raise_no_executable(local.report, name, local.bin_dir, "is not an executable file");
                return error.Failed;
            };
        }
        local.write("images.zon", images_text) catch return local.cannot_write("images.zon");
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
        return local.spawn(server_exe, "server", &.{
            "--listen", address, "--store", database, "--create-store", "--quiet",
        });
    }

    fn start_agent(local: *const Local, address: []const u8) Failed!i32 {
        const agent_dir = try local.path("agent");
        const images = try local.path("images.zon");
        var cpu: [16]u8 = undefined;
        var memory: [24]u8 = undefined;
        const cpu_text = std.fmt.bufPrint(&cpu, "{d}", .{constants.local_cpu_millis}) catch unreachable; // 10 digits at most.
        const memory_text = std.fmt.bufPrint(&memory, "{d}", .{constants.local_memory_bytes}) catch unreachable; // 20 digits at most.
        return local.spawn(agent_exe, "agent", &.{
            "--node",         constants.local_node_name,
            "--server",       address,
            "--state-dir",    agent_dir,
            "--cpu-millis",   cpu_text,
            "--memory-bytes", memory_text,
            "--images",       images,
        });
    }

    /// Starts `exe` detached (a process group of its own, no input, output in `<which>.log`) and
    /// records its pid. Returns the pid.
    fn spawn(
        local: *const Local,
        exe: []const u8,
        which: []const u8,
        args: []const []const u8,
    ) Failed!i32 {
        const arena = local.arena;
        const io = local.env.io;
        const log_name = std.fmt.allocPrint(arena, "{s}.log", .{which}) catch
            return local.out_of_memory();
        const log = std.Io.Dir.cwd().createFile(io, try local.path(log_name), .{}) catch
            return local.cannot_write(log_name);
        defer log.close(io);
        const argv = arena.alloc([]const u8, args.len + 1) catch return local.out_of_memory();
        argv[0] = std.fmt.allocPrint(arena, "{s}/{s}", .{ local.bin_dir, exe }) catch
            return local.out_of_memory();
        @memcpy(argv[1..], args);
        const child = std.process.spawn(io, .{
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
        const text = std.fmt.allocPrint(arena, "{d}\n", .{pid}) catch return local.out_of_memory();
        const pid_name = std.fmt.allocPrint(arena, "{s}.pid", .{which}) catch
            return local.out_of_memory();
        local.write(pid_name, text) catch return local.cannot_write(pid_name);
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

    /// Waits until the server answers `/v1/status` and `/nodes/local` is registered. Null when it
    /// is; otherwise the sentence for ZC-E0123 saying which step failed.
    fn wait_ready(local: *const Local, port: u16, server: i32, agent: i32) ?[]const u8 {
        const node_key = "\"/nodes/" ++ constants.local_node_name ++ "\"";
        var answered = false;
        var waited: u32 = 0;
        while (waited < constants.local_up_wait_ms) : (waited += constants.local_poll_ms) {
            if (!local.alive(server)) return "the server stopped before it answered";
            if (!local.alive(agent)) return "the agent stopped before its node registered";
            if (local.get(port, "/v1/status") != null) answered = true;
            if (answered) {
                const listed = local.get(port, "/v1/list?prefix=/nodes/");
                if (listed) |body| {
                    if (std.mem.find(u8, body, node_key) != null) return null;
                }
            }
            local.sleep();
        }
        const format = "the {s} did not {s} within {d} s";
        const seconds = @divFloor(constants.local_up_wait_ms, 1000);
        if (!answered) return std.fmt.allocPrint(local.arena, format, .{ "server", "answer", seconds }) catch "the server did not answer";
        return std.fmt.allocPrint(local.arena, format, .{ "agent", "register its node", seconds }) catch "the agent did not register its node";
    }

    fn say_up(
        local: *const Local,
        what: []const u8,
        address: []const u8,
        server: Found,
        agent: Found,
    ) Failed!void {
        const text = std.fmt.allocPrint(local.arena,
            "local: {s}\n" ++
                "  server  {s} (pid {d}), log {s}/server.log\n" ++
                "  agent   node {s} (pid {d}), log {s}/agent.log\n" ++
                "  state   {s}\n" ++
                "next:\n" ++
                "  export ZCUBE_SERVER={s}\n" ++
                "  zcube apply hello.zon\n" ++
                "stop it with: zcube local down\n",
            .{
                what,                      address,    server.pid, local.dir,
                constants.local_node_name, agent.pid,  local.dir,  local.dir,
                address,
            }) catch return local.out_of_memory();
        try local.emit(text);
    }

    /// Stops what is running (the agent first, so it does not report a server that went away) and
    /// deletes every pid file. Returns how many processes it stopped.
    fn stop_all(local: *const Local, said: ?*[2]Found) u32 {
        var stopped: u32 = 0;
        const names = [_][2][]const u8{ .{ "agent", agent_exe }, .{ "server", server_exe } };
        for (names, 0..) |pair, index| {
            const found = local.find(pair[0], pair[1]);
            if (said) |slot| slot[index] = found;
            if (found.presence == .running) {
                local.stop(found.pid);
                stopped += 1;
            }
            const pid_name = std.fmt.allocPrint(local.arena, "{s}.pid", .{pair[0]}) catch continue;
            local.remove(pid_name);
        }
        return stopped;
    }
};

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
    try local.prepare();
    const server = local.find("server", server_exe);
    const agent = local.find("agent", agent_exe);
    if (server.presence == .running and agent.presence == .running) {
        if (local.read(try local.path("address"))) |address| {
            return local.say_up("already running", std.mem.trim(u8, address, " \t\r\n"), server, agent);
        }
    }
    // Anything half-running is stopped, so the two always start together on one address. The
    // agent's containers are not touched by that: it adopts them again.
    _ = local.stop_all(null);
    const port = local.choose_port();
    const address = std.fmt.allocPrint(local.arena, "127.0.0.1:{d}", .{port}) catch
        return local.out_of_memory();
    local.write("address", address) catch return local.cannot_write("address");
    const started_server = try local.start_server(address);
    const started_agent = local.start_agent(address) catch |err| {
        _ = local.stop_all(null);
        return err;
    };
    if (local.wait_ready(port, started_server, started_agent)) |step| {
        _ = local.stop_all(null);
        const log = if (std.mem.find(u8, step, "agent") != null) "agent.log" else "server.log";
        raise_not_up(local.report, step, local.path(log) catch local.dir);
        return error.Failed;
    }
    const found_server: Found = .{ .presence = .running, .pid = started_server };
    const found_agent: Found = .{ .presence = .running, .pid = started_agent };
    return local.say_up("up", address, found_server, found_agent);
}

fn down(local: *const Local) Failed!void {
    var found: [2]Found = undefined;
    const stopped = local.stop_all(&found);
    var text: []const u8 = "local: not running\n";
    if (stopped > 0) {
        text = std.fmt.allocPrint(local.arena,
            "local: stopped server (pid {d}) and agent (pid {d}); state kept in {s}\n" ++
                "the agent's containers keep running; zcube local up adopts them\n",
            .{ found[1].pid, found[0].pid, local.dir }) catch return local.out_of_memory();
    }
    try local.emit(text);
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
        .up => up(&local),
        .down => down(&local),
    };
    result catch return constants.exit_environment;
    return constants.exit_ok;
}
