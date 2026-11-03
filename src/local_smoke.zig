//! `zig build local-smoke`: `zcube local up` and `down` as a person would use them (slice 7.6),
//! on the `zcube`, `zcube-server` and `zcube-agent` the build made, in a directory of its own.
//! **This is not `demo-c0`.** It checks, in order:
//!
//!   1. `up` starts the server and the agent, and a second `up` says "already running";
//!   2. `apply` of a 3-replica `hello` gives 3 running replicas;
//!   3. `down` stops the server and the agent; `up` again adopts the same replicas (the same
//!      number of supervisors, none added);
//!   4. a second `down` says "not running";
//!   5. two `up`s started at once leave one server and one agent (the lock);
//!   6. `down` after the agent was killed says it stopped the server only.
//!
//! Everything it started is killed at the end whatever happened: `zcube local down`, then every
//! supervisor group under the directory (containers outlive `down` on purpose, so this test owns
//! them), then any process named by a pid file. It counts only processes of its own directory.
//! It prints to stdout only, because the build runner counts any stderr as a failure.
//!
//! Usage: `local_smoke <zcube> <zcube-server> <zcube-agent>`; it copies them into one directory
//! of its own, because `zcube local` finds the server and the agent beside itself.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const host_procs = @import("host_procs.zig");

const Allocator = std.mem.Allocator;

const Failed = error{SmokeFailed};

const hello_zon =
    \\.{ .name = "hello", .image = "b3:51aa9c03", .replicas = 3, .command = .{ "sleep", "300" } }
    \\
;
const replicas_wanted: u32 = 3;
const wait_steps_max: u32 = 200;
const step_ms: i64 = 100;

const Output = struct { stdout: []const u8, code: u8 };

const Smoke = struct {
    io: std.Io,
    gpa: Allocator,
    arena: Allocator,
    bin_dir: []const u8,
    /// The scratch directory; `local` inside it is `ZCUBE_LOCAL_DIR`.
    work: []const u8,
    local: []const u8,
    /// The environment with `ZCUBE_LOCAL_DIR` set and no `ZCUBE_SERVER`, then with it set.
    env_plain: *std.process.Environ.Map,
    env_server: *std.process.Environ.Map,
    has_server: bool = false,

    fn say(smoke: *Smoke, comptime format: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        const text = "local-smoke: " ++ format ++ "\n";
        const line = std.fmt.bufPrint(&buffer, text, args) catch return;
        std.Io.File.stdout().writeStreamingAll(smoke.io, line) catch {}; // Nowhere else to say it.
    }

    fn expect(smoke: *Smoke, ok: bool, comptime what: []const u8, args: anytype) Failed!void {
        if (ok) return;
        smoke.say("FAILED: " ++ what, args);
        return error.SmokeFailed;
    }

    fn exe(smoke: *Smoke, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(smoke.arena, "{s}/{s}", .{ smoke.bin_dir, name });
    }

    fn argv(smoke: *Smoke, args: []const []const u8) ![]const []const u8 {
        const list = try smoke.arena.alloc([]const u8, args.len + 1);
        list[0] = try smoke.exe("zcube");
        @memcpy(list[1..], args);
        return list;
    }

    fn environ(smoke: *Smoke) *const std.process.Environ.Map {
        return if (smoke.has_server) smoke.env_server else smoke.env_plain;
    }

    /// Runs `zcube <args>` and returns its standard output and exit code.
    fn zcube(smoke: *Smoke, args: []const []const u8) !Output {
        const result = try std.process.run(smoke.gpa, smoke.io, .{
            .argv = try smoke.argv(args),
            .environ_map = smoke.environ(),
            .stdout_limit = .limited(constants.local_cmdline_bytes_max),
            .stderr_limit = .limited(constants.local_cmdline_bytes_max),
        });
        defer smoke.gpa.free(result.stderr);
        defer smoke.gpa.free(result.stdout);
        if (result.stderr.len > 0) smoke.say("stderr: {s}", .{result.stderr});
        const code: u8 = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        return .{ .stdout = try smoke.arena.dupe(u8, result.stdout), .code = code };
    }

    /// Runs `zcube <args>`; it must exit 0 and its output must contain `needle`.
    fn zcube_says(smoke: *Smoke, args: []const []const u8, needle: []const u8) ![]const u8 {
        const out = try smoke.zcube(args);
        const exited = "`zcube {s}` exited {d}: {s}";
        try smoke.expect(out.code == 0, exited, .{ args[0], out.code, out.stdout });
        try smoke.expect(
            std.mem.find(u8, out.stdout, needle) != null,
            "`zcube {s}` did not say \"{s}\": {s}",
            .{ args[0], needle, out.stdout },
        );
        return out.stdout;
    }

    fn sleep(smoke: *Smoke) void {
        smoke.io.sleep(.fromMilliseconds(step_ms), .awake) catch {}; // Only paces a poll.
    }

    // ---- What is running ----

    fn procs(smoke: *Smoke) host_procs.Procs {
        const state = std.fmt.allocPrint(smoke.arena, "{s}/agent", .{smoke.local}) catch "";
        return .{ .io = smoke.io, .arena = smoke.arena, .state = state };
    }

    fn pid_of(smoke: *Smoke, role: []const u8) ?i32 {
        var path: [constants.state_path_bytes_max + 32]u8 = undefined;
        const format = "{s}/{s}.pid";
        const name = std.fmt.bufPrint(&path, format, .{ smoke.local, role }) catch return null;
        var buffer: [64]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(smoke.io, name, &buffer) catch return null;
        var tokens = std.mem.tokenizeAny(u8, bytes, " \n");
        return std.fmt.parseInt(i32, tokens.next() orelse return null, 10) catch null;
    }

    /// How many live processes have `needle` in their command line: a scan of /proc, so a
    /// duplicate would be seen. The needle names this run's directory, so no other process counts.
    fn count_cmdline(smoke: *Smoke, needle: []const u8) u32 {
        var proc_dir = std.Io.Dir.cwd().openDir(smoke.io, "/proc", .{ .iterate = true }) catch {
            return 0;
        };
        defer proc_dir.close(smoke.io);
        var count: u32 = 0;
        var iterator = proc_dir.iterate();
        while (iterator.next(smoke.io) catch null) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            if (!smoke.procs().alive(pid)) continue;
            var path: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch continue;
            var buffer: [constants.local_cmdline_bytes_max]u8 = undefined;
            const line = std.Io.Dir.cwd().readFile(smoke.io, name, &buffer) catch continue;
            if (std.mem.find(u8, line, needle) != null) count += 1;
        }
        return count;
    }

    fn servers(smoke: *Smoke) u32 {
        const needle = std.fmt.allocPrint(smoke.arena, "{s}/zcube.db", .{smoke.local}) catch "";
        return smoke.count_cmdline(needle);
    }

    fn agents(smoke: *Smoke) u32 {
        // The agent's own command line, not its supervisors' (those have "supervise" first).
        const format = "--node\x00{s}";
        const name = constants.local_node_name;
        const needle = std.fmt.allocPrint(smoke.arena, format, .{name}) catch "";
        return smoke.count_cmdline(needle);
    }

    fn replicas_running(smoke: *Smoke) !u32 {
        const out = try smoke.zcube(&.{ "get", "replicas" });
        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, out.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, " running ") != null) count += 1;
        }
        return count;
    }

    fn wait_replicas(smoke: *Smoke) !void {
        for (0..wait_steps_max) |_| {
            if (try smoke.replicas_running() == replicas_wanted) return;
            smoke.sleep();
        }
        try smoke.expect(false, "{d} replicas did not run", .{replicas_wanted});
    }

    fn wait_gone(smoke: *Smoke, pid: i32) !void {
        for (0..wait_steps_max) |_| {
            if (!smoke.procs().alive(pid)) return;
            smoke.sleep();
        }
        try smoke.expect(false, "process {d} did not end", .{pid});
    }

    // ---- The script ----

    fn up(smoke: *Smoke) ![]const u8 {
        const out = try smoke.zcube_says(&.{ "local", "up" }, "local: up");
        const prefix = "  export ZCUBE_SERVER=";
        const at = std.mem.find(u8, out, prefix) orelse {
            try smoke.expect(false, "no address in: {s}", .{out});
            unreachable; // `expect` returned an error above.
        };
        var rest = out[at + prefix.len ..];
        if (std.mem.findScalar(u8, rest, '\n')) |end| rest = rest[0..end];
        return rest;
    }

    fn script(smoke: *Smoke) !void {
        const address = try smoke.up();
        try smoke.env_server.put("ZCUBE_SERVER", address);
        smoke.has_server = true;
        smoke.say("up at {s}", .{address});

        _ = try smoke.zcube_says(&.{ "local", "up" }, "local: already running");
        const hello = try std.fmt.allocPrint(smoke.arena, "{s}/hello.zon", .{smoke.work});
        try std.Io.Dir.cwd().writeFile(smoke.io, .{ .sub_path = hello, .data = hello_zon });
        _ = try smoke.zcube(&.{ "apply", "--yes", hello });
        try smoke.wait_replicas();
        const before = try smoke.procs().supervisors();
        try smoke.expect(before == replicas_wanted, "{d} supervisors, wanted 3", .{before});
        smoke.say("3 replicas running, {d} supervisors", .{before});

        _ = try smoke.zcube_says(&.{ "local", "down" }, "local: stopped server");
        try smoke.expect(smoke.servers() == 0, "a server runs after down", .{});
        try smoke.expect(smoke.agents() == 0, "an agent runs after down", .{});
        _ = try smoke.up();
        try smoke.wait_replicas();
        const after = try smoke.procs().supervisors();
        try smoke.expect(after == before, "supervisors changed: {d} -> {d}", .{ before, after });
        smoke.say("replicas adopted, not duplicated", .{});

        _ = try smoke.zcube_says(&.{ "local", "down" }, "local: stopped");
        _ = try smoke.zcube_says(&.{ "local", "down" }, "local: not running");
        try smoke.concurrent_ups();
        try smoke.down_after_agent_died();
    }

    /// Two `up`s at once: the lock makes one wait for the other, and both succeed with one
    /// server and one agent left.
    fn concurrent_ups(smoke: *Smoke) !void {
        const args = try smoke.argv(&.{ "local", "up" });
        var first = try std.process.spawn(smoke.io, .{
            .argv = args,
            .environ_map = smoke.env_plain,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        var second = std.process.spawn(smoke.io, .{
            .argv = args,
            .environ_map = smoke.env_plain,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            first.kill(smoke.io);
            return err;
        };
        const first_term = try first.wait(smoke.io);
        const second_term = try second.wait(smoke.io);
        const ok = first_term == .exited and first_term.exited == 0 and
            second_term == .exited and second_term.exited == 0;
        try smoke.expect(ok, "two concurrent ups did not both succeed", .{});
        try smoke.expect(smoke.servers() == 1, "{d} servers after two ups", .{smoke.servers()});
        try smoke.expect(smoke.agents() == 1, "{d} agents after two ups", .{smoke.agents()});
        smoke.say("two concurrent ups: one server, one agent", .{});
        _ = try smoke.zcube_says(&.{ "local", "down" }, "local: stopped server");
    }

    /// With the agent already dead, `down` reports the server only.
    fn down_after_agent_died(smoke: *Smoke) !void {
        _ = try smoke.up();
        const agent = smoke.pid_of("agent") orelse {
            try smoke.expect(false, "no agent pid file", .{});
            unreachable; // `expect` returned an error above.
        };
        try std.posix.kill(agent, .KILL);
        try smoke.wait_gone(agent);
        const out = try smoke.zcube_says(&.{ "local", "down" }, "local: stopped server");
        const named = std.mem.find(u8, out, "agent (pid") != null;
        try smoke.expect(!named, "down named the dead agent: {s}", .{out});
        smoke.say("down names only what it stopped", .{});
    }

    /// Ends everything this run started, whatever happened.
    fn cleanup(smoke: *Smoke) void {
        _ = smoke.zcube(&.{ "local", "down" }) catch {}; // Best effort; the kills below follow.
        _ = smoke.procs().kill_supervisor_groups();
        for ([_][]const u8{ "server", "agent" }) |role| {
            if (smoke.pid_of(role)) |pid| std.posix.kill(pid, .KILL) catch {}; // May be gone.
        }
    }

    fn dump_logs(smoke: *Smoke) void {
        for ([_][]const u8{ "server.log", "agent.log" }) |name| {
            const format = "{s}/{s}";
            const arena = smoke.arena;
            const path = std.fmt.allocPrint(arena, format, .{ smoke.local, name }) catch continue;
            const text = std.Io.Dir.cwd().readFileAlloc(
                smoke.io,
                path,
                smoke.arena,
                .limited(4096),
            ) catch continue;
            smoke.say("---- {s} ----\n{s}", .{ name, text });
        }
    }
};

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 4) {
        std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: local_smoke <zcube> <zcube-server> <zcube-agent>\n",
        ) catch {};
        return 2;
    }
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    const stamp = std.Io.Clock.real.now(io).toMilliseconds();
    const work = std.fmt.allocPrint(arena, "{s}/zcube-local-smoke-{d}-{d}", .{
        base, std.os.linux.getpid(), stamp,
    }) catch return 2;
    std.Io.Dir.cwd().createDirPath(io, work) catch return 2;
    defer std.Io.Dir.cwd().deleteTree(io, work) catch {}; // Best effort: it is in /tmp.

    const bin_dir = std.fmt.allocPrint(arena, "{s}/bin", .{work}) catch return 2;
    std.Io.Dir.cwd().createDirPath(io, bin_dir) catch return 2;
    for (args[1..4], [_][]const u8{ "zcube", "zcube-server", "zcube-agent" }) |from, name| {
        const to = std.fmt.allocPrint(arena, "{s}/{s}", .{ bin_dir, name }) catch return 2;
        std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), to, io, .{}) catch return 2;
    }

    var env_plain = init.environ_map.clone(init.gpa) catch return 2;
    defer env_plain.deinit();
    const local = std.fmt.allocPrint(arena, "{s}/local", .{work}) catch return 2;
    env_plain.put("ZCUBE_LOCAL_DIR", local) catch return 2;
    _ = env_plain.swapRemove("ZCUBE_SERVER");
    var env_server = env_plain.clone(init.gpa) catch return 2;
    defer env_server.deinit();

    var smoke: Smoke = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .bin_dir = bin_dir,
        .work = work,
        .local = local,
        .env_plain = &env_plain,
        .env_server = &env_server,
    };
    defer smoke.cleanup();
    smoke.script() catch |err| {
        if (err != error.SmokeFailed) smoke.say("FAILED: {s}", .{@errorName(err)});
        smoke.dump_logs();
        return 1;
    };
    smoke.say("PASS", .{});
    return 0;
}
