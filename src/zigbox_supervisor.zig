//! The supervisor of one Zigbox container: `zcube-agent supervise-zigbox <launch directory>`.
//! C2 slice 1. Shell code: a process of its own that pulls, starts, waits and signals.
//!
//! It is what `fake_supervisor.zig` is for `FakeRuntime`, and for the same reason: only the
//! process that starts a container can wait for it, and Zigbox's `start` and `pull` need a
//! caller that is the only thread of its process. It takes the launch directory's lock first (a
//! lost supervisor is a lock anyone can take), writes its pid, reads the spec, gets the tree
//! onto the node and starts the container detached (`zigbox_image.zig` decides how), then waits
//! for it. Zigbox writes the run record; the agent reads that. If the container cannot be
//! started, the Zigbox diagnostic goes to `failed.json` and the process ends: no record exists.
//!
//! A SIGTERM to the supervisor goes to the container (Zigbox's `wait` forwards it), so an
//! operator who stops the supervisor does not leave an orphan.
//!
//! Needs a host that runs Zigbox; covered by `zigbox-smoke` only (docs/briefs/c2-1.md).

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("fake_files.zig");
const agent_records = @import("agent_records.zig");
const image = @import("zigbox_image.zig");
const launch = @import("zigbox_launch.zig");
const pull_report = @import("pull_report.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Diagnostic = diag_mod.Diagnostic;

const HostReal = zigbox.host_real.HostReal;
const NetworkMemory = @typeInfo(@typeInfo(@FieldType(HostReal, "network_memory")).optional.child)
    .pointer.child;
const ImageWorkspace = @typeInfo(@typeInfo(@FieldType(zigbox.StartOptions, "image_workspace"))
    .optional.child).pointer.child;
const Facts = @FieldType(zigbox.Handle, "facts");

/// Everything one container's start needs that is too large for a stack: about 60 MiB, made on
/// the heap once. `handle` is pinned: Zigbox keeps pointers into the spec and into itself.
const Storage = struct {
    handle: zigbox.Handle,
    image_workspace: ImageWorkspace,
    pull_workspace: zigbox.pull.Workspace,
    import_workspace: zigbox.store.import.Workspace,
    pull_facts: Facts,
    pull_result: zigbox.pull.Result,
    network_memory: NetworkMemory,
};

/// How much of `ZBX_REGISTRY_MIRRORS` is read: more than Zigbox's 1024 (not exported), so that a
/// list that is too long reaches `pull` and is refused there, by Zigbox, not quietly ignored.
const mirrors_bytes_max: u32 = 4096;

/// The start and pull steps over real Zigbox, for `zigbox_image.start_with_image`.
const Real = struct {
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const zigbox.Spec,
    /// The swarm fetch, and what it needs (null: none). `arena` is for its argv.
    swarm: ?Swarm = null,
    /// "b3:" and 64 hex digits (Zigbox's store_digest_text_bytes, not exported).
    tree_text: [67]u8 = undefined,

    fn steps(self: *Real) image.Steps {
        const asks: ?*const fn (context: *anyopaque) bool = if (self.swarm != null) fetch else null;
        return .{ .context = self, .start = start, .pull = pull, .fetch = asks };
    }

    /// Runs `zcube-agent fetch` against the node's store: true if it finished (the tree is in
    /// the store). Its diagnostics go to `<container dir>/fetch.log`; a failure falls back to the
    /// pull, which says its own.
    fn fetch(context: *anyopaque) bool {
        const self: *Real = @ptrCast(@alignCast(context));
        return fetch_swarm(self.swarm.?, self.host);
    }

    fn start(context: *anyopaque, diag: *zigbox.diag.Diag) error{StartFailed}!void {
        const self: *Real = @ptrCast(@alignCast(context));
        const options: zigbox.StartOptions = .{
            .detached = true,
            .image_workspace = &self.storage.image_workspace,
        };
        zigbox.start(self.host, self.spec, options, &self.storage.handle, diag) catch
            return error.StartFailed;
    }

    fn pull(
        context: *anyopaque,
        reference: []const u8,
        diag: *zigbox.diag.Diag,
    ) error{Failed}![]const u8 {
        const self: *Real = @ptrCast(@alignCast(context));
        const storage = self.storage;
        const request: zigbox.pull.Request = .{
            .reference = reference,
            .platform = .{},
            // Docker Hub mirrors, from the environment the agent gave this process.
            .mirrors = self.host.environment(
                "ZBX_REGISTRY_MIRRORS",
                mirrors_bytes_max,
            ) orelse "",
        };
        const started_ms = if (self.swarm) |swarm| real_ms(swarm.io) else 0;
        try zigbox.pull.pull(
            self.host,
            &storage.pull_facts,
            &request,
            null,
            &storage.pull_workspace,
            &storage.import_workspace,
            &storage.pull_result,
            diag,
        );
        const text = storage.pull_result.tree.text();
        if (self.swarm) |swarm| {
            const result = &storage.pull_result;
            const blobs = result.blobs[0 .. result.layer_count + 1];
            write_pull_record(swarm, &text, blobs, started_ms);
        }
        @memcpy(self.tree_text[0..text.len], &text);
        return self.tree_text[0..text.len];
    }
};

/// What the swarm fetch needs beyond the launch's `Fetch`: the tree, the manifest, the IO.
const Swarm = struct {
    io: std.Io,
    /// The container's name: its pull record is `<state dir>/containers/<name>/pull.json`.
    name: []const u8,
    fetch: launch.Fetch,
    tree: []const u8,
    manifest: []const u8,
};

/// The words of the fetch: `argv` holds them, `report` is where the pull's record goes.
fn fetch_argv(
    swarm: Swarm,
    store_root: []const u8,
    report: []const u8,
    argv: *[fetch_argv_max][]const u8,
) []const []const u8 {
    var count: usize = 0;
    const head = [_][]const u8{
        swarm.fetch.exe,  "fetch",
        "--node",         swarm.fetch.node,
        "--state-dir",    swarm.fetch.state_dir,
        "--zigbox-store", store_root,
        "--manifest",     swarm.manifest,
        "--digest",       swarm.tree,
        "--report",       report,
    };
    for (head) |word| {
        argv[count] = word;
        count += 1;
    }
    if (swarm.fetch.registry.len > 0) {
        argv[count] = "--registry";
        argv[count + 1] = swarm.fetch.registry;
        count += 2;
    }
    if (swarm.fetch.server.len > 0) {
        argv[count] = "--server";
        argv[count + 1] = swarm.fetch.server;
        count += 2;
    }
    return argv[0..count];
}

const fetch_argv_max = 20;

/// `<state dir>/containers/<name>/<file>` for this container.
fn container_file(buffer: []u8, swarm: Swarm, file: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}/{s}", .{
        swarm.fetch.state_dir, agent_records.dir_containers, swarm.name, file,
    }) catch null;
}

fn awake_ms(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io).toMilliseconds()));
}

fn real_ms(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.real.now(io).toMilliseconds()));
}

/// The pull record of a tree that came from the registry: what Zigbox's own `pull` saw per blob,
/// in the file the agent publishes to `/pulls`. A fetch that got the tree from peers wrote its own;
/// one that failed first loses its peer figures (it reports only on success). A record that
/// cannot be written only loses the statistics.
fn write_pull_record(
    swarm: Swarm,
    tree: []const u8,
    blobs: []const pull_report.Blob,
    started: u64,
) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = container_file(&path_buffer, swarm, agent_records.file_pull) orelse return;
    const sums = pull_report.tally(blobs);
    const record: records.Pull = .{
        .node = swarm.fetch.node,
        .tree = tree,
        .registry_bytes = sums.registry_bytes,
        .cached_bytes = sums.cached_bytes,
        .started_at_ms = started,
        .finished_at_ms = real_ms(swarm.io),
    };
    std.Io.Dir.cwd().createDirPath(swarm.io, std.fs.path.dirname(path).?) catch {}; // Said below.
    _ = pull_report.write(std.heap.page_allocator, swarm.io, path, record);
}

/// `<container dir>/fetch.log`, where the fetch's diagnostics go (null: it could not be made).
fn open_log(swarm: Swarm) ?std.Io.File {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = container_file(&path_buffer, swarm, agent_records.file_fetch_log) orelse
        return null;
    return std.Io.Dir.cwd().createFile(swarm.io, path, .{}) catch null;
}

fn fetch_swarm(swarm: Swarm, host: zigbox.host.Host) bool {
    var store: zigbox.store.Store = undefined;
    if (!zigbox.store.Store.locate(&store, host)) return false;
    // The agent publishes `containers/<name>/pull.json` (agent.zig); the directory may not exist
    // in this runtime, and a report that cannot be written only loses the statistics.
    var report_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const report = container_file(&report_buffer, swarm, agent_records.file_pull) orelse
        return false;
    const parent = std.fs.path.dirname(report).?;
    std.Io.Dir.cwd().createDirPath(swarm.io, parent) catch {}; // Said by the fetch if it matters.
    // ZC-E0601 and ZC-W0601 are the fetch's to say; without a log they would vanish.
    const log = open_log(swarm);
    defer if (log) |file| file.close(swarm.io);
    var words: [fetch_argv_max][]const u8 = undefined;
    const argv = fetch_argv(swarm, store.root_text(), report, &words);
    const sink: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .ignore;
    var child = std.process.spawn(swarm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
    }) catch |err| {
        say_in_log(swarm.io, log, "could not start the fetch: ", @errorName(err));
        return false;
    };
    const finished = finished_ok(swarm.io, &child, fetch_deadline(swarm));
    if (!finished) say_in_log(swarm.io, log, "the fetch did not exit with code 0", "");
    return finished;
}

/// One line in `fetch.log`, in the supervisor's own voice: a fetch that dies without a word (or
/// never starts) would otherwise leave the log empty and the pull's fall-back unexplained.
fn say_in_log(io: std.Io, log: ?std.Io.File, what: []const u8, detail: []const u8) void {
    const file = log orelse return;
    var buffer: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "supervisor: {s}{s}\n", .{ what, detail }) catch return;
    file.writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
}

/// The fetch's deadline: `constants.zigbox_fetch_deadline_ms`, unless the test fault
/// `<state dir>/faults/fetch-deadline-ms` holds a shorter one (docs/agent.md). Without it a smoke
/// would wait half an hour to see the kill.
fn fetch_deadline(swarm: Swarm) u32 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/faults/fetch-deadline-ms", .{
        swarm.fetch.state_dir,
    }) catch return constants.zigbox_fetch_deadline_ms;
    var text: [16]u8 = undefined;
    const read = std.Io.Dir.cwd().readFile(swarm.io, path, &text) catch
        return constants.zigbox_fetch_deadline_ms;
    return deadline_from_fault(read);
}

/// The milliseconds a fault file holds (digits, then maybe a newline), 1 to the real deadline;
/// anything else leaves the real deadline in force.
fn deadline_from_fault(text: []const u8) u32 {
    const trimmed = std.mem.trim(u8, text, " \n");
    const value = std.fmt.parseInt(u32, trimmed, 10) catch
        return constants.zigbox_fetch_deadline_ms;
    if (value == 0) return constants.zigbox_fetch_deadline_ms;
    return @min(value, constants.zigbox_fetch_deadline_ms);
}

/// Waits for `child` to exit, at most `limit_ms`; a child still running then is killed. True only
/// for an exit with code 0. Polls (`WNOHANG`), because nothing here waits with a deadline.
fn finished_ok(io: std.Io, child: *std.process.Child, limit_ms: u32) bool {
    assert(limit_ms > 0);
    const pid = child.id.?;
    const started = awake_ms(io);
    while (true) {
        var status: i32 = 0;
        const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
        switch (wait_verdict(rc, pid, status)) {
            .running => {},
            .again => continue,
            .exited_ok => return true,
            .over => return false,
        }
        if (awake_ms(io) -| started >= limit_ms) {
            child.kill(io);
            return false;
        }
        io.sleep(.fromMilliseconds(20), .awake) catch {}; // Cancelation only ends the wait early.
    }
}

const Verdict = enum { running, again, exited_ok, over };

/// What a `waitpid(pid, WNOHANG)` result `rc` (with `status`) says: an error is checked first
/// (an interrupted wait is tried again; any other, such as ECHILD, means the child is not ours
/// to wait for and is over, not a success), then 0 (still running), then the child's own exit.
fn wait_verdict(rc: usize, pid: std.posix.pid_t, status: i32) Verdict {
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return .again,
        else => return .over,
    }
    if (rc == 0) return .running;
    if (rc != @as(usize, @intCast(pid))) return .over;
    const exited = std.os.linux.W.IFEXITED(@bitCast(status));
    if (exited and std.os.linux.W.EXITSTATUS(@bitCast(status)) == constants.exit_ok) {
        return .exited_ok;
    }
    return .over;
}

pub fn run(init: std.process.Init, dir_path: []const u8) u8 {
    assert(dir_path.len > 0);
    // Not `init.io`: that is a threaded Io. Zigbox's start and pull make namespaces, which
    // needs a process with one thread, and this Io never starts another.
    var threaded: std.Io.Threaded = .init_single_threaded;
    // The static Io has a failing allocator, and spawning a process (the swarm fetch) copies
    // argv and the environment: without one it ends in OutOfMemory.
    threaded.allocator = init.gpa;
    threaded.environ.process_environ = init.minimal.environ;
    const io = threaded.io();
    const dir = Dir.openDirAbsolute(io, dir_path, .{}) catch return constants.exit_environment;
    defer dir.close(io);
    // A new session and process group: signals aimed at the agent do not reach it.
    _ = std.os.linux.setsid();
    launch.hold_lock(io, dir) catch return constants.exit_environment;
    const own_pid: i32 = @intCast(std.os.linux.getpid());
    files.write_pid(io, dir, launch.file_supervisor, own_pid) catch
        return constants.exit_environment;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const spec = launch.read_spec(io, dir, arena_state.allocator()) catch
        return constants.exit_environment;
    const storage = std.heap.page_allocator.create(Storage) catch return constants.exit_environment;
    storage.network_memory.init();
    var real: HostReal = .{
        .environ = init.minimal.environ,
        .network_memory = &storage.network_memory,
    };
    return supervise(io, dir, real.interface(), storage, &spec, arena_state.allocator());
}

fn supervise(
    io: std.Io,
    dir: Dir,
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const launch.Spec,
    arena: Allocator,
) u8 {
    const container = container_spec(arena, spec) orelse return constants.exit_environment;
    var status: [4096]u8 = undefined;
    const count = if (host.read_file("/proc/self/status", &status)) |text|
        image.threads_in(text)
    else |_|
        null;
    if (count != 1) return record_failure(io, dir, &image.not_single_threaded(count));
    var real: Real = .{ .host = host, .storage = storage, .spec = &container };
    if (spec.fetch) |fetch| {
        if (launch.manifest_of(spec.reference)) |manifest| {
            real.swarm = .{
                .io = io,
                .name = spec.name,
                .fetch = fetch,
                .tree = spec.tree,
                .manifest = manifest,
            };
        }
    }
    var trace: image.Trace = .{};
    switch (image.start_with_image(real.steps(), spec.tree, spec.reference, &trace)) {
        .started => {},
        .failed => |diagnostic| return record_failure(io, dir, &diagnostic),
    }
    _ = zigbox.wait(&storage.handle);
    return constants.exit_ok;
}

/// Writes `failed.json`, the last thing a supervisor that did not start a container does.
fn record_failure(io: std.Io, dir: Dir, diagnostic: *const Diagnostic) u8 {
    launch.write_failed(io, dir, diagnostic) catch return constants.exit_environment;
    return constants.exit_ok;
}

/// Zigbox's spec for the launch: the tree, the command, the environment and labels, the limits.
/// Everything borrows from `spec` and `arena`. Null if memory ran out.
fn container_spec(arena: Allocator, spec: *const launch.Spec) ?zigbox.Spec {
    const env = arena.alloc(zigbox.Label, spec.env.len) catch return null;
    const names = arena.alloc([]const u8, spec.env.len) catch return null;
    for (spec.env, env, names) |pair, *label, *name| {
        label.* = .{ .key = pair[0], .value = pair[1] };
        name.* = pair[0];
    }
    const labels = arena.alloc(zigbox.Label, spec.labels.len) catch return null;
    for (spec.labels, labels) |pair, *label| label.* = .{ .key = pair[0], .value = pair[1] };
    return .{
        .image = spec.tree,
        .name = spec.name,
        .command = spec.command,
        .labels = labels,
        .env = env,
        .env_names = names,
        .limits = .{
            .memory_bytes = spec.memory_bytes,
            .pids = spec.pids,
            .cpu_millis = spec.cpu_millis,
        },
    };
}

test "the fetch is told where to put its pull record, and the registry and server only if known" {
    var swarm: Swarm = .{
        .io = std.testing.io,
        .name = "web-0",
        .fetch = .{ .exe = "/bin/zcube-agent", .node = "n1", .state_dir = "/state" },
        .tree = "b3:aa",
        .manifest = "sha256:bb",
    };
    var words: [fetch_argv_max][]const u8 = undefined;
    var argv = fetch_argv(swarm, "/store", "/state/containers/web-0/pull.json", &words);
    try std.testing.expectEqual(@as(usize, 14), argv.len);
    try std.testing.expectEqualStrings("--report", argv[12]);
    try std.testing.expectEqualStrings("/state/containers/web-0/pull.json", argv[13]);
    swarm.fetch.registry = "r:1";
    swarm.fetch.server = "s:2";
    argv = fetch_argv(swarm, "/store", "x", &words);
    try std.testing.expectEqual(@as(usize, 18), argv.len);
    try std.testing.expectEqualStrings("--server", argv[16]);
}

fn scratch_swarm(tmp: *std.testing.TmpDir, buffer: []u8) !Swarm {
    var cwd: [512]u8 = undefined;
    const length = try std.process.currentPath(std.testing.io, &cwd);
    const state = try std.fmt.bufPrint(buffer, "{s}/.zig-cache/tmp/{s}", .{
        cwd[0..length], tmp.sub_path,
    });
    try tmp.dir.createDirPath(std.testing.io, "containers/web-0");
    return .{
        .io = std.testing.io,
        .name = "web-0",
        .fetch = .{ .exe = "/bin/zcube-agent", .node = "n1", .state_dir = state },
        .tree = "b3:aa",
        .manifest = "sha256:bb",
    };
}

test "a pull from the registry leaves a pull record with the registry's bytes" {
    // Goal: Z5 on the real fallback. The supervisor's own pull is the registry path, so its
    // blobs must reach `containers/<name>/pull.json`, the file /pulls is made from.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [768]u8 = undefined;
    const swarm = try scratch_swarm(&tmp, &buffer);
    const blobs = [_]pull_report.Blob{
        .{ .digest = undefined, .bytes = 10, .outcome = .downloaded },
        .{ .digest = undefined, .bytes = 5, .outcome = .cached },
        .{ .digest = undefined, .bytes = 7, .outcome = .resumed },
    };
    write_pull_record(swarm, "b3:aa", &blobs, 1000);
    const text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "containers/web-0/pull.json",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(records.Pull, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 17), parsed.value.registry_bytes);
    try std.testing.expectEqual(@as(u64, 5), parsed.value.cached_bytes);
    try std.testing.expectEqualStrings("n1", parsed.value.node);
    try std.testing.expectEqualStrings("b3:aa", parsed.value.tree);
    try std.testing.expectEqual(@as(u64, 1000), parsed.value.started_at_ms);
}

test "the fetch's diagnostics have a log in the container's directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [768]u8 = undefined;
    const swarm = try scratch_swarm(&tmp, &buffer);
    const log = open_log(swarm).?;
    try log.writeStreamingAll(swarm.io, "ZC-W0601");
    log.close(swarm.io);
    const text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "containers/web-0/fetch.log",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ZC-W0601", text);
}

test "the fault file can only shorten the fetch's deadline" {
    const real = constants.zigbox_fetch_deadline_ms;
    try std.testing.expectEqual(@as(u32, 50), deadline_from_fault("50\n"));
    try std.testing.expectEqual(real, deadline_from_fault(""));
    try std.testing.expectEqual(real, deadline_from_fault("0"));
    try std.testing.expectEqual(real, deadline_from_fault("soon"));
    try std.testing.expectEqual(real, deadline_from_fault("4000000000"));
}

test "a fetch that outlives its deadline is killed, and only an exit 0 counts" {
    const io = std.testing.io;
    const cases = [_]struct { argv: []const []const u8, limit: u32, ok: bool }{
        .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .limit = 10_000, .ok = true },
        .{ .argv = &.{ "/bin/sh", "-c", "exit 3" }, .limit = 10_000, .ok = false },
        .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" }, .limit = 200, .ok = false },
    };
    for (cases) |case| {
        var child = try std.process.spawn(io, .{
            .argv = case.argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const pid = child.id.?;
        const started = awake_ms(io);
        try std.testing.expectEqual(case.ok, finished_ok(io, &child, case.limit));
        try std.testing.expect(awake_ms(io) - started < 5000); // The sleep did not run its 30 s.
        // Gone: reaped by the wait or by the kill. A live child would answer signal 0.
        try std.testing.expect(std.os.linux.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    }
}

test "a wait's error is read before its pid: interrupted again, any other over, never ok" {
    const errno_rc = struct {
        fn of(code: std.os.linux.E) usize {
            return @bitCast(-@as(isize, @backingInt(code)));
        }
    }.of;
    const pid: std.posix.pid_t = 4242;
    try std.testing.expectEqual(Verdict.again, wait_verdict(errno_rc(.INTR), pid, 0));
    try std.testing.expectEqual(Verdict.over, wait_verdict(errno_rc(.CHILD), pid, 0));
    try std.testing.expectEqual(Verdict.running, wait_verdict(0, pid, 0));
    try std.testing.expectEqual(Verdict.exited_ok, wait_verdict(4242, pid, 0));
    try std.testing.expectEqual(Verdict.over, wait_verdict(4242, pid, 3 << 8));
    try std.testing.expectEqual(Verdict.over, wait_verdict(4243, pid, 0));
}
