//! `zig build agent-smoke`: one `zcube-server` on SQLite and one `zcube-agent` with `FakeRuntime`,
//! as the processes they are, and what a person would see of them. **This is not `demo-c0`**
//! (that script drives the `zcube` command and asserts HANDOFF's outcomes); it is the check that
//! slice 6a's pieces work together on real processes:
//!
//!   1. apply `hello` with 3 replicas: 3 containers run on the host, each a command under its
//!      own supervisor, which is the command's parent and leads a session of its own;
//!   2. `kill -9` one command: it is replaced, and there are 3 again;
//!   3. restart the agent: the same processes run, no duplicate was started;
//!   4. restart the server: nothing changes;
//!   5. apply a digest that is not in the fixtures: the replica is held, and the observed state
//!      carries the `ZBX-E0501` diagnostic.
//!
//! Every process it starts is killed at the end, whatever happened (`Smoke.cleanup`). It prints
//! to stdout only, one line per step, because the build runner counts any stderr as a failure; a
//! failure prints what was expected and the logs, then exits 1.
//!
//! Usage: `agent_smoke <zcube-server> <zcube-agent> <fixtures/images.zon>`.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const http = @import("agent_http.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Json = std.json.Value;

const node = "node1";
const hello_command = "[\"sh\",\"-c\",\"while true; do sleep 1; done\"]";
const wait_ms_default: u32 = 20_000;
const processes_max: u32 = 64;

const Failed = error{SmokeFailed};

const Pids = struct { name: [64]u8, name_len: u8, supervisor: i32, command: i32 };

const ProcInfo = struct { parent: i32, group: i32, session: i32, zombie: bool };

const Smoke = struct {
    io: std.Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    environ: *const std.process.Environ.Map,
    server_exe: []const u8,
    agent_exe: []const u8,
    images: []const u8,
    work: []const u8,
    state: []const u8,
    port: u16,
    server: ?std.process.Child = null,
    agent: ?std.process.Child = null,
    server_starts: u32 = 0,
    agent_starts: u32 = 0,
    failed: bool = false,

    fn work_file(smoke: *Smoke, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(smoke.arena.allocator(), "{s}/{s}", .{ smoke.work, name });
    }

    // ---- Reporting ----

    fn say(smoke: *Smoke, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "agent-smoke: " ++ format ++ "\n",
            args,
        ) catch return;
        std.Io.File.stdout().writeStreamingAll(smoke.io, line) catch {}; // Nowhere else to say it.
    }

    fn expect(smoke: *Smoke, ok: bool, comptime what: []const u8, args: anytype) Failed!void {
        if (ok) return;
        smoke.failed = true;
        smoke.say("FAILED: " ++ what, args);
        return error.SmokeFailed;
    }

    // ---- Processes we start ----

    fn spawn(
        smoke: *Smoke,
        exe: []const u8,
        args: []const []const u8,
        log: []const u8,
    ) !std.process.Child {
        var path: [constants.state_path_bytes_max]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "{s}/{s}", .{ smoke.work, log });
        const file = try std.Io.Dir.cwd().createFile(smoke.io, name, .{});
        defer file.close(smoke.io);
        const argv = try smoke.arena.allocator().alloc([]const u8, args.len + 1);
        argv[0] = exe;
        @memcpy(argv[1..], args);
        return std.process.spawn(smoke.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
        });
    }

    fn start_server(smoke: *Smoke) !void {
        smoke.server_starts += 1;
        const arena = smoke.arena.allocator();
        const listen = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{smoke.port});
        const store = try std.fmt.allocPrint(arena, "sqlite:{s}/store.db", .{smoke.work});
        const log = try std.fmt.allocPrint(arena, "server-{d}.log", .{smoke.server_starts});
        const args = [_][]const u8{
            "--listen",       listen,
            "--store",        store,
            "--create-store", "--quiet",
        };
        smoke.server = try smoke.spawn(smoke.server_exe, &args, log);
        const ready = struct {
            fn check(s: *Smoke) !bool {
                const reply = s.call("GET", "/v1/status", "") catch return false;
                return reply.status == 200;
            }
        };
        try smoke.wait_until("the server to answer", ready.check, wait_ms_default);
    }

    fn start_agent(smoke: *Smoke) !void {
        smoke.agent_starts += 1;
        const arena = smoke.arena.allocator();
        const server = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{smoke.port});
        const log = try std.fmt.allocPrint(arena, "agent-{d}.log", .{smoke.agent_starts});
        const args = [_][]const u8{
            "--node",         node,
            "--server",       server,
            "--state-dir",    smoke.state,
            "--cpu-millis",   "4000",
            "--memory-bytes", "8589934592",
            "--images",       smoke.images,
        };
        smoke.agent = try smoke.spawn(smoke.agent_exe, &args, log);
    }

    /// SIGTERM, then wait: a clean stop is exit 0.
    fn stop(smoke: *Smoke, child: *?std.process.Child, what: []const u8) !void {
        var process = child.* orelse return;
        std.posix.kill(process.id.?, .TERM) catch {}; // Already gone is fine; wait says how.
        const term = try process.wait(smoke.io);
        child.* = null;
        const clean = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        try smoke.expect(clean, "{s} did not stop cleanly after SIGTERM", .{what});
    }

    // ---- The API ----

    fn call(smoke: *Smoke, method: []const u8, path: []const u8, body: []const u8) !http.Reply {
        const address = try net.IpAddress.parse("127.0.0.1", smoke.port);
        const client: http.Client = .{ .io = smoke.io, .address = address };
        var diag: Diag = undefined;
        diag.reset();
        return client.call(smoke.arena.allocator(), .{
            .method = method,
            .target = path,
            .body = body,
        }, &diag) catch error.ApiUnreachable;
    }

    fn json(smoke: *Smoke, path: []const u8) !Json {
        const reply = try smoke.call("GET", path, "");
        try smoke.expect(reply.status == 200, "GET {s} answered {d}", .{ path, reply.status });
        return std.json.parseFromSliceLeaky(Json, smoke.arena.allocator(), reply.body, .{});
    }

    fn apply(smoke: *Smoke, name: []const u8, image: []const u8, replicas: u32) !void {
        const body = try std.fmt.allocPrint(
            smoke.arena.allocator(),
            "{{\"name\":\"{s}\",\"image\":\"{s}\",\"replicas\":{d},\"command\":{s}}}",
            .{ name, image, replicas, hello_command },
        );
        const reply = try smoke.call("POST", "/v1/apply", body);
        try smoke.expect(reply.status == 200, "apply {s} answered {d}: {s}", .{
            name, reply.status, reply.body,
        });
    }

    const Seen = struct {
        replica: []const u8,
        status: []const u8,
        exit_kind: []const u8,
        diagnostic_code: []const u8,
    };

    /// What the agent has reported, ascending by replica id.
    fn observed(smoke: *Smoke) ![]const Seen {
        const arena = smoke.arena.allocator();
        const listed = try smoke.json("/v1/list?prefix=/observed/" ++ node ++ "/");
        var seen: std.ArrayList(Seen) = .empty;
        for (listed.object.get("kvs").?.array.items) |kv| {
            const value = kv.object.get("value").?;
            const exit = value.object.get("exit");
            const diagnostic = value.object.get("diagnostic");
            try seen.append(arena, .{
                .replica = value.object.get("replica").?.string,
                .status = value.object.get("status").?.string,
                .exit_kind = if (exit) |e| e.object.get("kind").?.string else "",
                .diagnostic_code = if (diagnostic) |d| d.object.get("code").?.string else "",
            });
        }
        return seen.items;
    }

    fn running_count(smoke: *Smoke, prefix: []const u8) !u32 {
        var count: u32 = 0;
        for (try smoke.observed()) |item| {
            if (!std.mem.startsWith(u8, item.replica, prefix)) continue;
            if (std.mem.eql(u8, item.status, "running")) count += 1;
        }
        return count;
    }

    fn replica_ids(smoke: *Smoke, service: []const u8) ![]const []const u8 {
        const arena = smoke.arena.allocator();
        const path = try std.fmt.allocPrint(arena, "/v1/list?prefix=/replicas/{s}/", .{service});
        const listed = try smoke.json(path);
        var ids: std.ArrayList([]const u8) = .empty;
        for (listed.object.get("kvs").?.array.items) |kv| {
            try ids.append(arena, kv.object.get("value").?.object.get("id").?.string);
        }
        return ids.items;
    }

    // ---- Waiting ----

    fn wait_until(
        smoke: *Smoke,
        comptime what: []const u8,
        comptime check: fn (*Smoke) anyerror!bool,
        limit_ms: u32,
    ) !void {
        var waited: u32 = 0;
        while (waited < limit_ms) : (waited += 50) {
            if (try check(smoke)) return;
            try smoke.io.sleep(.fromMilliseconds(50), .awake);
        }
        try smoke.expect(false, "timed out waiting for " ++ what, .{});
    }

    // ---- The host ----

    /// The containers the agent has made, from its state directory.
    fn containers(smoke: *Smoke) ![]const Pids {
        const arena = smoke.arena.allocator();
        const root = try std.fmt.allocPrint(arena, "{s}/containers", .{smoke.state});
        var dir = try std.Io.Dir.cwd().openDir(smoke.io, root, .{ .iterate = true });
        defer dir.close(smoke.io);
        var found: std.ArrayList(Pids) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(smoke.io)) |entry| {
            if (entry.kind != .directory) continue;
            var sub = dir.openDir(smoke.io, entry.name, .{}) catch continue;
            defer sub.close(smoke.io);
            const supervisor = read_pid(smoke.io, sub, "supervisor.pid") orelse continue;
            const command = read_pid(smoke.io, sub, "child.pid") orelse continue;
            var pids: Pids = .{ .name = undefined, .name_len = @intCast(
                entry.name.len,
            ), .supervisor = supervisor, .command = command };
            @memcpy(pids.name[0..entry.name.len], entry.name);
            try found.append(arena, pids);
        }
        std.mem.sort(Pids, found.items, {}, pids_less);
        return found.items;
    }

    fn pids_less(_: void, first: Pids, second: Pids) bool {
        return std.mem.lessThan(u8, first.name[0..first.name_len], second.name[0..second.name_len]);
    }

    /// The live containers (the command runs), not the stopped ones whose directories remain.
    fn running_containers(smoke: *Smoke) ![]const Pids {
        const arena = smoke.arena.allocator();
        var alive: std.ArrayList(Pids) = .empty;
        for (try smoke.containers()) |pids| {
            const command = smoke.proc(pids.command) orelse continue;
            if (command.zombie) continue;
            try alive.append(arena, pids);
        }
        return alive.items;
    }

    fn proc(smoke: *Smoke, pid: i32) ?ProcInfo {
        var path: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch return null;
        var buffer: [1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(smoke.io, name, &buffer) catch return null;
        return parse_stat(bytes);
    }

    /// The supervisors that run now: processes whose command line is `<agent> supervise` of a
    /// container under our state directory. A scan of /proc, so a duplicate would be seen.
    fn supervisors(smoke: *Smoke) !u32 {
        var proc_dir = try std.Io.Dir.cwd().openDir(smoke.io, "/proc", .{ .iterate = true });
        defer proc_dir.close(smoke.io);
        var count: u32 = 0;
        var iterator = proc_dir.iterate();
        while (try iterator.next(smoke.io)) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            if (!smoke.is_supervisor(pid)) continue;
            count += 1;
        }
        return count;
    }

    fn is_supervisor(smoke: *Smoke, pid: i32) bool {
        const info = smoke.proc(pid) orelse return false;
        if (info.zombie) return false;
        var path: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch return false;
        var buffer: [constants.state_path_bytes_max + 256]u8 = undefined;
        const line = std.Io.Dir.cwd().readFile(smoke.io, name, &buffer) catch return false;
        if (std.mem.find(u8, line, "supervise") == null) return false;
        return std.mem.find(u8, line, smoke.state) != null;
    }

    // ---- The end, whatever happened ----

    /// Kills everything this run started: the agent and the server, then every process group of
    /// a supervisor under the state directory (the supervisor, its command, what that started).
    fn cleanup(smoke: *Smoke) void {
        if (smoke.agent) |*child| child.kill(smoke.io);
        smoke.agent = null;
        if (smoke.server) |*child| child.kill(smoke.io);
        smoke.server = null;
        var proc_dir = std.Io.Dir.cwd().openDir(
            smoke.io,
            "/proc",
            .{ .iterate = true },
        ) catch return;
        defer proc_dir.close(smoke.io);
        var iterator = proc_dir.iterate();
        while (iterator.next(smoke.io) catch null) |entry| {
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            if (!smoke.is_supervisor(pid)) continue;
            std.posix.kill(-pid, .KILL) catch {}; // The group may be gone already.
        }
    }

    fn dump_logs(smoke: *Smoke) void {
        const arena = smoke.arena.allocator();
        for ([_][]const u8{ "server", "agent" }) |kind| {
            const is_server = std.mem.eql(u8, kind, "server");
            const starts = if (is_server) smoke.server_starts else smoke.agent_starts;
            for (1..starts + 1) |index| {
                const path = std.fmt.allocPrint(
                    arena,
                    "{s}/{s}-{d}.log",
                    .{ smoke.work, kind, index },
                ) catch continue;
                const text = std.Io.Dir.cwd().readFileAlloc(
                    smoke.io,
                    path,
                    arena,
                    .limited(8192),
                ) catch continue;
                smoke.say("---- {s} {d} ----\n{s}", .{ kind, index, text });
            }
        }
    }
};

fn read_pid(io: std.Io, dir: std.Io.Dir, name: []const u8) ?i32 {
    var buffer: [32]u8 = undefined;
    const bytes = dir.readFile(io, name, &buffer) catch return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, "\n "), 10) catch null;
}

/// "pid (comm) S ppid pgrp session ...": the fields after the closing parenthesis.
fn parse_stat(bytes: []const u8) ?ProcInfo {
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, bytes[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    const parent = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const group = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const session = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    return .{ .parent = parent, .group = group, .session = session, .zombie = state[0] == 'Z' };
}

// ---- The script -------------------------------------------------------------------------------

fn script(smoke: *Smoke) !void {
    try smoke.start_server();
    smoke.say("server up on 127.0.0.1:{d}", .{smoke.port});
    try smoke.start_agent();
    const registered = struct {
        fn check(s: *Smoke) !bool {
            const listed = try s.json("/v1/list?prefix=/nodes/");
            return listed.object.get("kvs").?.array.items.len == 1;
        }
    };
    try smoke.wait_until("the node to register", registered.check, wait_ms_default);

    try step_apply_three(smoke);
    const before = try step_kill_one(smoke);
    try step_restart_agent(smoke, before);
    try step_restart_server(smoke);
    try step_unknown_digest(smoke);
}

const three_run = struct {
    fn check(s: *Smoke) !bool {
        return try s.running_count("hello-") == 3;
    }
};

/// 3 replicas: 3 running, each a command under its own supervisor.
fn step_apply_three(smoke: *Smoke) !void {
    try smoke.apply("hello", "b3:51aa9c03", 3);
    try smoke.wait_until("3 replicas of hello to run", three_run.check, wait_ms_default);
    const alive = try smoke.running_containers();
    try smoke.expect(alive.len == 3, "{d} containers run on the host, expected 3", .{alive.len});
    const supervisors = try smoke.supervisors();
    try smoke.expect(supervisors == 3, "{d} supervisors run, expected 3", .{supervisors});
    const agent_pid = smoke.agent.?.id.?;
    for (alive) |pids| {
        const command = smoke.proc(pids.command).?;
        const supervisor = smoke.proc(pids.supervisor).?;
        const name = pids.name[0..pids.name_len];
        try smoke.expect(
            command.parent == pids.supervisor,
            "{s}: the command's parent is not its supervisor",
            .{name},
        );
        try smoke.expect(
            supervisor.session == pids.supervisor,
            "{s}: the supervisor leads no session",
            .{name},
        );
        try smoke.expect(
            supervisor.group == pids.supervisor,
            "{s}: the supervisor leads no group",
            .{name},
        );
        try smoke.expect(
            supervisor.parent == agent_pid,
            "{s}: the agent is not the supervisor's parent",
            .{name},
        );
    }
    smoke.say(
        "3 replicas run as 3 commands under 3 supervisors, each in a session of its own",
        .{},
    );
}

/// `kill -9` of one command: replaced, 3 again. Returns the containers that run then.
fn step_kill_one(smoke: *Smoke) ![]const Pids {
    const first = (try smoke.running_containers())[0];
    const killed = try smoke.arena.allocator().dupe(u8, first.name[0..first.name_len]);
    try std.posix.kill(first.command, .KILL);
    const replaced = struct {
        fn check(s: *Smoke) !bool {
            if (try s.running_count("hello-") != 3) return false;
            const alive = try s.running_containers();
            return alive.len == 3;
        }
    };
    try smoke.wait_until("the killed replica to be replaced", replaced.check, wait_ms_default);
    const alive = try smoke.running_containers();
    for (alive) |pids| {
        const same = std.mem.eql(u8, pids.name[0..pids.name_len], killed);
        try smoke.expect(
            !same,
            "{s} runs again after kill -9; a replacement was expected",
            .{killed},
        );
    }
    const supervisors = try smoke.supervisors();
    try smoke.expect(
        supervisors == 3,
        "{d} supervisors run after the kill, expected 3",
        .{supervisors},
    );
    smoke.say("kill -9 of {s}: replaced, 3 run again", .{killed});
    return alive;
}

fn same_containers(smoke: *Smoke, before: []const Pids) !bool {
    const now = try smoke.running_containers();
    if (now.len != before.len) return false;
    for (before, now) |left, right| {
        const names_equal = std.mem.eql(
            u8,
            left.name[0..left.name_len],
            right.name[0..right.name_len],
        );
        if (!names_equal) return false;
        if (left.supervisor != right.supervisor) return false;
        if (left.command != right.command) return false;
    }
    return true;
}

/// A restarted agent adopts what runs and starts nothing.
fn step_restart_agent(smoke: *Smoke, before: []const Pids) !void {
    const ids = try smoke.replica_ids("hello");
    try smoke.stop(&smoke.agent, "the agent");
    try smoke.expect(
        try same_containers(smoke, before),
        "stopping the agent changed what runs",
        .{},
    );
    try smoke.start_agent();
    const registered = struct {
        fn check(s: *Smoke) !bool {
            const text = std.Io.Dir.cwd().readFileAlloc(
                s.io,
                try s.work_file("agent-2.log"),
                s.arena.allocator(),
                .limited(8192),
            ) catch return false;
            return std.mem.find(u8, text, "registered") != null;
        }
    };
    try smoke.wait_until("the new agent to register", registered.check, wait_ms_default);
    // Several passes: a duplicate would be started by the first.
    try smoke.io.sleep(.fromSeconds(3), .awake);
    try smoke.expect(
        try same_containers(smoke, before),
        "the restarted agent changed what runs",
        .{},
    );
    const supervisors = try smoke.supervisors();
    try smoke.expect(
        supervisors == 3,
        "{d} supervisors after the agent restart, expected 3",
        .{supervisors},
    );
    const now = try smoke.replica_ids("hello");
    try smoke.expect(
        now.len == ids.len,
        "the replica set changed: {d} before, {d} after",
        .{ ids.len, now.len },
    );
    try smoke.expect(
        try smoke.running_count("hello-") == 3,
        "hello is not at 3 after the agent restart",
        .{},
    );
    smoke.say("agent restarted: the same 3 processes run, none was started twice", .{});
}

/// A restarted server changes nothing.
fn step_restart_server(smoke: *Smoke) !void {
    const before = try smoke.running_containers();
    const ids = try smoke.replica_ids("hello");
    try smoke.stop(&smoke.server, "the server");
    try smoke.io.sleep(
        .fromSeconds(2),
        .awake,
    ); // The agent fails against a closed port and backs off.
    try smoke.expect(
        try same_containers(smoke, before),
        "the server being down changed what runs",
        .{},
    );
    try smoke.start_server();
    try smoke.io.sleep(.fromSeconds(6), .awake); // Past the agent's longest backoff.
    try smoke.expect(
        try same_containers(smoke, before),
        "the restarted server changed what runs",
        .{},
    );
    const now = try smoke.replica_ids("hello");
    try smoke.expect(now.len == ids.len, "the replica set changed across the server restart", .{});
    for (ids, now) |left, right| {
        try smoke.expect(
            std.mem.eql(u8, left, right),
            "replica {s} became {s} across the restart",
            .{ left, right },
        );
    }
    try smoke.expect(
        try smoke.running_count("hello-") == 3,
        "hello is not at 3 after the server restart",
        .{},
    );
    smoke.say("server restarted: the same replicas, the same processes", .{});
}

/// A digest that is not in the fixtures: held, with ZBX-E0501 in the observed state.
fn step_unknown_digest(smoke: *Smoke) !void {
    try smoke.apply("broken", "b3:00ff00ff", 1);
    const failed = struct {
        fn check(s: *Smoke) !bool {
            for (try s.observed()) |item| {
                if (!std.mem.startsWith(u8, item.replica, "broken-")) continue;
                return std.mem.eql(u8, item.exit_kind, "start_failed");
            }
            return false;
        }
    };
    try smoke.wait_until("the broken replica to report its failure", failed.check, wait_ms_default);
    var code: []const u8 = "";
    for (try smoke.observed()) |item| {
        if (std.mem.startsWith(u8, item.replica, "broken-")) code = item.diagnostic_code;
    }
    try smoke.expect(
        std.mem.eql(u8, code, "ZBX-E0501"),
        "the diagnostic is '{s}', expected ZBX-E0501",
        .{code},
    );
    const ids = try smoke.replica_ids("broken");
    try smoke.io.sleep(.fromSeconds(3), .awake);
    const later = try smoke.replica_ids("broken");
    try smoke.expect(
        later.len == 1,
        "broken has {d} replicas, expected the one held",
        .{later.len},
    );
    try smoke.expect(
        std.mem.eql(u8, ids[0], later[0]),
        "broken was replaced ({s} then {s}), not held",
        .{ ids[0], later[0] },
    );
    try smoke.expect(try smoke.running_count("broken-") == 0, "a broken replica runs", .{});
    const why = try smoke.call("GET", "/v1/why/service/broken", "");
    try smoke.expect(why.status == 200, "why answered {d}", .{why.status});
    try smoke.expect(
        std.mem.find(u8, why.body, "ZBX-E0501") != null,
        "why does not mention ZBX-E0501",
        .{},
    );
    try smoke.expect(
        try smoke.running_count("hello-") == 3,
        "hello changed while broken failed",
        .{},
    );
    smoke.say("unknown digest: {s} held with ZBX-E0501 in its observed state", .{later[0]});
}

/// A port the system is not using now: bind port 0, read it, let go.
fn free_port(io: std.Io) !u16 {
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 4) {
        std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: agent_smoke <zcube-server> <zcube-agent> <images.zon>\n",
        ) catch {};
        return 2;
    }
    var smoke: Smoke = .{
        .io = io,
        .gpa = init.gpa,
        .arena = .init(init.gpa),
        .environ = init.environ_map,
        .server_exe = args[1],
        .agent_exe = args[2],
        .images = args[3],
        .work = "",
        .state = "",
        .port = 0,
    };
    defer smoke.arena.deinit();
    return run(&smoke);
}

fn run(smoke: *Smoke) u8 {
    const arena = smoke.arena.allocator();
    const base = smoke.environ.get("TMPDIR") orelse "/tmp";
    const stamp = std.Io.Clock.real.now(smoke.io).toMilliseconds();
    smoke.work = std.fmt.allocPrint(
        arena,
        "{s}/zcube-smoke-{d}-{d}",
        .{ base, std.os.linux.getpid(), stamp },
    ) catch return 2;
    smoke.state = std.fmt.allocPrint(arena, "{s}/state", .{smoke.work}) catch return 2;
    std.Io.Dir.cwd().createDirPath(smoke.io, smoke.state) catch return 2;
    smoke.port = free_port(smoke.io) catch return 2;
    defer std.Io.Dir.cwd().deleteTree(smoke.io, smoke.work) catch {}; // Best effort: it is in /tmp.
    defer smoke.cleanup();
    script(smoke) catch |err| {
        if (!smoke.failed) smoke.say("FAILED: {s}", .{@errorName(err)});
        smoke.dump_logs();
        return 1;
    };
    smoke.say("ok", .{});
    return 0;
}
