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
const relay_module = @import("relay.zig");
const relay_tls = @import("relay_tls.zig");

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

/// The lock the supervisors of one node take turns pulling under: `pull.lock` in `<state>/zigbox/`,
/// the parent of every container's directory. The agent's scan of that directory skips files.
const pull_lock_path = "../pull.lock";

/// The start and pull steps over real Zigbox, for `zigbox_image.start_with_image`.
const Real = struct {
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const zigbox.Spec,
    /// The swarm fetch, and what it needs (null: none). `arena` is for its argv.
    swarm: ?Swarm = null,
    /// "b3:" and 64 hex digits (Zigbox's store_digest_text_bytes, not exported).
    tree_text: [67]u8 = undefined,
    /// The node's pull lock (`pull_lock_path`, relative to the container's directory), and the
    /// file that holds it while a pull is going on.
    lock_io: std.Io,
    lock_dir: Dir,
    lock_file: ?std.Io.File = null,

    fn steps(self: *Real) image.Steps {
        const asks: ?*const fn (context: *anyopaque) image.Fetched =
            if (self.swarm != null) fetch else null;
        return .{
            .context = self,
            .start = start,
            .pull = pull,
            .fetch = asks,
            .enter_pull = enter_pull,
            .leave_pull = leave_pull,
        };
    }

    /// Waits for the lock the supervisors of this node share. Zigbox's store has one writer: two
    /// first pulls of one image at once end in ZBX-E0417 for one of them (the blob the other is
    /// moving into the cache is gone). The kernel gives the lock back if this process dies. A
    /// lock that can't be taken is not fatal: the pull goes on without it, as before.
    fn enter_pull(context: *anyopaque) void {
        const self: *Real = @ptrCast(@alignCast(context));
        assert(self.lock_file == null);
        self.lock_file = self.lock_dir.createFile(self.lock_io, pull_lock_path, .{
            .truncate = false,
            .lock = .exclusive,
        }) catch null;
    }

    fn leave_pull(context: *anyopaque) void {
        const self: *Real = @ptrCast(@alignCast(context));
        if (self.lock_file) |file| file.close(self.lock_io);
        self.lock_file = null;
    }

    /// Runs `zcube-agent fetch` against the node's store. Its diagnostics go to
    /// `<container dir>/fetch.log`; a failure falls back to the pull, which says its own, unless
    /// a process of the fetch outlived its kill (`zigbox_image.Fetched`).
    fn fetch(context: *anyopaque) image.Fetched {
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
        // The pull writes nothing to fetch.log until it is done: a stuck one and a slow one
        // looked alike (issue #93). These two lines tell them apart.
        if (self.swarm) |swarm| append_to_log(swarm, "supervisor: the registry pull starts\n");
        zigbox.pull.pull(
            self.host,
            &storage.pull_facts,
            &request,
            null,
            &storage.pull_workspace,
            &storage.import_workspace,
            &storage.pull_result,
            diag,
        ) catch |err| {
            if (self.swarm) |swarm| say_pull_ended(swarm, started_ms, false);
            return err;
        };
        if (self.swarm) |swarm| say_pull_ended(swarm, started_ms, true);
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
    pull_report.write(std.heap.page_allocator, swarm.io, path, record) catch |err| {
        var buffer: [160]u8 = undefined;
        const text = "ZC-W0504: the pull record could not be written to pull.json: {s}; " ++
            "its statistics are lost\n";
        append_to_log(swarm, std.fmt.bufPrint(&buffer, text, .{@errorName(err)}) catch
            "ZC-W0504: the pull record could not be written to pull.json\n");
    };
}

/// Adds `line` to the end of `fetch.log` (the fetch's own handle is closed by then). The pull
/// that follows a failed fetch says its own failures through Zigbox's diagnostics, so this is
/// for what only the supervisor knows.
fn append_to_log(swarm: Swarm, line: []const u8) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = container_file(&path_buffer, swarm, agent_records.file_fetch_log) orelse return;
    const dir = std.Io.Dir.cwd();
    const file = dir.createFile(swarm.io, path, .{ .truncate = false }) catch return;
    defer file.close(swarm.io);
    const end = file.length(swarm.io) catch return;
    file.writePositionalAll(swarm.io, line, end) catch {}; // Nowhere else to say it.
}

/// `<container dir>/fetch.log`, where the fetch's diagnostics go (null: it could not be made).
fn open_log(swarm: Swarm) ?std.Io.File {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = container_file(&path_buffer, swarm, agent_records.file_fetch_log) orelse
        return null;
    return std.Io.Dir.cwd().createFile(swarm.io, path, .{}) catch null;
}

fn fetch_swarm(swarm: Swarm, host: zigbox.host.Host) image.Fetched {
    var store: zigbox.store.Store = undefined;
    if (!zigbox.store.Store.locate(&store, host)) return .absent;
    // The agent publishes `containers/<name>/pull.json` (agent.zig); the directory may not exist
    // in this runtime, and a report that cannot be written only loses the statistics.
    var report_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const report = container_file(&report_buffer, swarm, agent_records.file_pull) orelse
        return .absent;
    const parent = std.fs.path.dirname(report).?;
    std.Io.Dir.cwd().createDirPath(swarm.io, parent) catch {}; // Said by the fetch if it matters.
    // ZC-E0601 and ZC-W0601 are the fetch's to say; without a log they would vanish.
    const log = open_log(swarm);
    defer if (log) |file| file.close(swarm.io);
    var words: [fetch_argv_max][]const u8 = undefined;
    const argv = fetch_argv(swarm, store.root_text(), report, &words);
    const sink: std.process.SpawnOptions.StdIo = if (log) |file| .{ .file = file } else .ignore;
    // A process group of its own: the fetch's store worker (Zigbox's `namespace.run` child) is a
    // grandchild that neither dies with the fetch nor hears its signals, and the group is how
    // `finished_ok` reaches it. It stays in the supervisor's session, which is how the runtime
    // reaches it when it stops a starting replica (`process_session.zig`).
    var child = std.process.spawn(swarm.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
        .pgid = 0,
    }) catch |err| {
        say_swarm_ended(swarm.io, log, "the fetch could not be started: ", @errorName(err));
        return .absent;
    };
    const deadline_ms = fetch_deadline(swarm);
    const outcome = finished_ok(swarm.io, &child, deadline_ms);
    switch (outcome) {
        .ok => return .in_store,
        .failed => say_swarm_ended(swarm.io, log, "the fetch did not exit with code 0", ""),
        .killed => {
            var ms: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&ms, "{d}", .{deadline_ms}) catch "?";
            say_swarm_ended(swarm.io, log, "the fetch was killed at its deadline, ms: ", text);
        },
        .outlived_kill => {
            say_in_log(swarm.io, log, "ZC-E0515: a process of the fetch outlived SIGKILL to " ++
                "its group; the image is not pulled while it may write the store", "");
            return .outlived_kill;
        },
    }
    return .absent;
}

/// Saying nothing when the tree was already in the store would look like a stalled fetch in a
/// dump (issue #93).
fn say_no_fetch(swarm: Swarm, fetched: bool, pulled: bool) void {
    if (fetched or pulled) return;
    append_to_log(swarm, "supervisor: the tree was already in the store; no fetch was needed\n");
}

/// The registry pull's outcome in fetch.log: how long it took and whether it gave the tree (its
/// own diagnostic is the container's `failed.json`).
fn say_pull_ended(swarm: Swarm, started_ms: u64, ok: bool) void {
    var buffer: [128]u8 = undefined;
    const spent = real_ms(swarm.io) -| started_ms;
    const text = std.fmt.bufPrint(&buffer, "supervisor: the registry pull {s} after {d} ms\n", .{
        if (ok) "finished" else "failed", spent,
    }) catch return;
    append_to_log(swarm, text);
}

/// ZC-W0603: the swarm fetch ended without the tree and the registry pull follows (not yet
/// tried, so this is no ZC-E0601). `reason` and `detail` are the cause.
fn say_swarm_ended(io: std.Io, log: ?std.Io.File, reason: []const u8, detail: []const u8) void {
    const file = log orelse return;
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "supervisor: ZC-W0603: the swarm fetch ended without " ++
        "the tree; the registry pull follows; cause: {s}{s}\n", .{ reason, detail }) catch return;
    file.writeStreamingAll(io, text) catch {}; // Nowhere else to say it.
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

/// How a fetch ended: an exit with code 0, any other end, the deadline's kill, or a kill that
/// left a process of the fetch's group alive (which `.killed` and `.failed` never do).
const Outcome = enum { ok, failed, killed, outlived_kill };

/// Waits for `child`, the leader of a process group of its own, to end, at most `limit_ms`.
/// Then, however it ended, the whole group is sent SIGKILL and reaped, at most
/// `zigbox_fetch_kill_wait_ms` more: a fetch that died by a signal, or was killed at its
/// deadline, can leave its store worker (a grandchild) writing the store, and a process that
/// writes the store must be gone before the pull, another writer, starts. Polls (`WNOHANG`),
/// because nothing here waits with a deadline. Takes `child`: its pid is reaped here.
fn finished_ok(io: std.Io, child: *std.process.Child, limit_ms: u32) Outcome {
    assert(limit_ms > 0);
    const pid = child.id.?;
    assert(pid > 1);
    child.id = null; // Reaped below, never by `Child`.
    // The group's orphans come back to this process to be reaped, not to init, so "gone" does
    // not wait on init's reaping (or on an init that never reaps). Cleared before returning.
    const linux = std.os.linux;
    _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
    defer _ = linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 0, 0, 0, 0);
    const started = awake_ms(io);
    const over_time = while (true) {
        if (leader_ended(pid)) break false;
        if (awake_ms(io) -| started >= limit_ms) break true;
        io.sleep(.fromMilliseconds(20), .awake) catch {}; // Cancelation only ends the wait early.
    };
    // The leader is not reaped yet (`WNOWAIT`), so the group's id is still its pid and can name
    // no other group: the kill reaches the fetch's processes and nothing else.
    _ = linux.kill(-pid, .KILL);
    const leader = reap_group(io, pid, constants.zigbox_fetch_kill_wait_ms) orelse
        return .outlived_kill;
    if (over_time) return .killed;
    return if (leader == .exited_ok) .ok else .failed;
}

/// Whether the group leader `pid` has ended, without reaping it (`WNOWAIT`), so that its pid
/// stays the group's. A wait that fails other than by an interruption (ECHILD: not ours) counts
/// as ended, and `reap_group` then finds what is left.
fn leader_ended(pid: std.posix.pid_t) bool {
    assert(pid > 1);
    const linux = std.os.linux;
    while (true) {
        var info: linux.siginfo_t = undefined;
        @memset(std.mem.asBytes(&info), 0); // `WNOHANG` with no change leaves pid 0.
        const flags = linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT;
        const rc = linux.waitid(.PID, pid, &info, flags, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return info.fields.common.first.piduid.pid != 0,
            .INTR => continue,
            else => return true,
        }
    }
}

/// Reaps every child in process group `pgid` (the subreaper makes the group's orphans ours)
/// until no process of the group is left, at most `limit_ms`. The leader's end, or null if a
/// process of the group is still there at the limit.
fn reap_group(io: std.Io, pgid: std.posix.pid_t, limit_ms: u32) ?Verdict {
    assert(pgid > 1);
    assert(limit_ms > 0);
    const linux = std.os.linux;
    var leader: Verdict = .over; // A leader that was not ours to reap did not exit 0.
    const started = awake_ms(io);
    while (true) {
        var status: i32 = 0;
        const rc = linux.waitpid(-pgid, &status, linux.W.NOHANG);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc != 0) {
                if (rc == @as(usize, @intCast(pgid))) leader = wait_verdict(rc, pgid, status);
                continue; // Another may be ready at once.
            },
            .INTR => continue,
            else => {}, // ECHILD: no child of ours is left in the group.
        }
        // Signal 0 finds any process of the group, ours or not (one that escaped to init).
        if (linux.errno(linux.kill(-pgid, @fromBackingInt(0))) == .SRCH) {
            assert(leader != .running);
            return leader;
        }
        if (awake_ms(io) -| started >= limit_ms) return null;
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
        return environment_failure(
            io,
            dir,
            std.fs.path.basename(dir_path),
            "read its launch record",
        );
    const storage = std.heap.page_allocator.create(Storage) catch return constants.exit_environment;
    storage.network_memory.init();
    var real: HostReal = .{
        .environ = init.minimal.environ,
        .network_memory = &storage.network_memory,
    };
    // The relay's threads connect upstream with `init.io`, after the start: the single-threaded
    // `io` above is for the namespace work only.
    const relay_ctx: RelayContext = .{ .gpa = init.gpa, .io = init.io, .dir_path = dir_path };
    return supervise(io, dir, real.interface(), storage, &spec, arena_state.allocator(), relay_ctx);
}

/// What the job's relay needs that the start does not: memory, an `Io` for the upstream
/// connections, and where `relay.log` goes.
const RelayContext = struct { gpa: Allocator, io: std.Io, dir_path: []const u8 };

fn supervise(
    io: std.Io,
    dir: Dir,
    host: zigbox.host.Host,
    storage: *Storage,
    spec: *const launch.Spec,
    arena: Allocator,
    relay_ctx: RelayContext,
) u8 {
    const name = std.fs.path.basename(relay_ctx.dir_path);
    const container = container_spec(arena, spec) orelse
        return environment_failure(io, dir, name, "set aside memory for its spec");
    var status: [4096]u8 = undefined;
    const count = if (host.read_file("/proc/self/status", &status)) |text|
        image.threads_in(text)
    else |_|
        null;
    if (count != 1) return record_failure(io, dir, name, &image.not_single_threaded(count));
    var real: Real = .{
        .host = host,
        .storage = storage,
        .spec = &container,
        .lock_io = io,
        .lock_dir = dir,
    };
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
        .started => if (real.swarm) |swarm| say_no_fetch(swarm, trace.fetched, trace.pulled),
        .failed => |diagnostic| return record_failure(io, dir, name, &diagnostic),
    }
    const relay = open_relay(relay_ctx, spec, &storage.handle);
    _ = zigbox.wait(&storage.handle);
    // `wait` has already written Zigbox's run record, which is how the agent learns of the
    // ending, so the relay outlives the report by this call: Zigbox gives no hook between the
    // reap and the record (docs/demos/b3.md). Nothing new can come in, since the container's
    // processes are gone; this closes the supervisor's end and every relayed connection.
    if (relay) |open| open.stop();
    return constants.exit_ok;
}

/// A job that names a relay: takes the listener Zigbox made in the container's namespace and
/// serves it. Null for a job without one, or when the relay could not be served: the container
/// is then killed (it would hold a listener nobody answers) and `relay.log` says why (ZC-E0702).
fn open_relay(
    ctx: RelayContext,
    spec: *const launch.Spec,
    handle: *zigbox.Handle,
) ?*relay_module.Relay {
    if (spec.relay.len == 0) return null;
    assert(handle.status == .running);
    assert(handle.listen != null); // `container_spec` asked for it, so the run made it.
    const taken = handle.session.take_listener() orelse
        return kill_unrelayed(ctx, handle, "the container gave no listener");
    const listener: std.os.linux.fd_t = @intCast(taken);
    if (relay_refused(spec)) |cause| {
        _ = std.os.linux.close(listener);
        return kill_unrelayed(ctx, handle, cause);
    }
    const upstream = relay_module.Upstream.parse(spec.relay) orelse {
        _ = std.os.linux.close(listener);
        return kill_unrelayed(ctx, handle, "the relay's address is not HOST:PORT");
    };
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    const log_path = relay_log_path(&path_buffer, ctx) orelse {
        _ = std.os.linux.close(listener);
        return kill_unrelayed(ctx, handle, "the path of relay.log is too long");
    };
    const relay = relay_module.Relay.adopt(
        ctx.gpa,
        ctx.io,
        upstream,
        listener,
        constants.relay_port,
        log_path,
    ) catch return kill_unrelayed(ctx, handle, "there was no memory for the relay");
    relay.run() catch {
        relay.stop();
        return kill_unrelayed(ctx, handle, "the relay's thread could not start");
    };
    return relay;
}

/// Why this supervisor will not serve the relay, or null. It speaks only B3's plain TCP to an
/// upstream until B4 slice 4 brings TLS here, and a release build serves no plain upstream: a
/// relay that names a TLS server, or that is not a Debug build's plain one, is refused rather
/// than connected in plaintext without the run's identity (fail closed, #228).
fn relay_refused(spec: *const launch.Spec) ?[]const u8 {
    assert(spec.relay.len > 0);
    if (spec.relay_server_name.len > 0) {
        return "the zigbox runtime does not speak TLS to a relay's upstream yet (B4 slice 4)";
    }
    if (!spec.relay_plain) return "the relay names no upstream server name and CA";
    if (!relay_tls.plain_allowed) return "a release build serves no plain-TCP relay upstream";
    return null;
}

fn relay_log_path(buffer: *[std.fs.max_path_bytes:0]u8, ctx: RelayContext) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{
        ctx.dir_path, agent_records.file_relay_log,
    }, 0) catch null;
}

/// Ends a container whose relay cannot be served, after writing ZC-E0702 and `cause` to
/// `relay.log`. Always null, for `open_relay` to return.
fn kill_unrelayed(
    ctx: RelayContext,
    handle: *zigbox.Handle,
    cause: []const u8,
) ?*relay_module.Relay {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (relay_log_path(&path_buffer, ctx)) |path| append_relay_failure(path, cause);
    const kill: u8 = @intCast(@backingInt(std.posix.SIG.KILL));
    zigbox.signal(handle, kill) catch {}; // Already gone is as good.
    return null;
}

/// Appends the ZC-E0702 line and `cause` to `relay.log` (the relay's own writes append too, so an
/// existing log is kept). Nowhere else to say it: a failure to write is dropped.
fn append_relay_failure(path: [:0]const u8, cause: []const u8) void {
    var line: [constants.relay_address_bytes_max]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "ZC-E0702 a job's relay could not listen: {s}\n", .{
        cause,
    }) catch "ZC-E0702 a job's relay could not listen\n";
    const flags: std.os.linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return;
    const fd: std.os.linux.fd_t = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    _ = std.os.linux.write(fd, text.ptr, text.len);
}

/// Writes `failed.json`, the last thing a supervisor that did not start a container does.
fn record_failure(io: std.Io, dir: Dir, name: []const u8, diagnostic: *const Diagnostic) u8 {
    // The agent's stderr, which this process inherits: the one line a failed start leaves in its
    // log, whenever the start fails (the agent has stopped waiting by the time a pull ends).
    launch.log_start_failure(io, name, diagnostic);
    launch.write_failed(io, dir, diagnostic) catch return constants.exit_environment;
    return constants.exit_ok;
}

/// A supervisor that cannot even begin says so in `failed.json` (ZC-E0502): without it the agent
/// finds a launch that ended with no word, and the run reads `lost` or a bare `start_failed`.
fn environment_failure(io: std.Io, dir: Dir, name: []const u8, operation: []const u8) u8 {
    var collector: diag_mod.Diag = undefined;
    collector.reset();
    collector.raise(.E0502);
    collector.cause("the supervisor can't {s}", .{operation});
    collector.fix(.{ .sentence = "check the agent's state directory and the host's limits" });
    var finished: Diagnostic = undefined;
    diag_mod.to_diagnostic(&finished, &collector);
    _ = record_failure(io, dir, name, &finished);
    return constants.exit_environment;
}

/// Zigbox's spec for the launch: the tree, the command, the environment and labels, the limits.
/// Everything borrows from `spec` and `arena`. Null if memory ran out.
fn container_spec(arena: Allocator, spec: *const launch.Spec) ?zigbox.Spec {
    // A relayed job also gets `ZCUBE_RELAY`; the server refused a job that set it (ZC-E0130).
    const extra: usize = if (spec.relay.len > 0) 1 else 0;
    const env = arena.alloc(zigbox.Label, spec.env.len + extra) catch return null;
    const names = arena.alloc([]const u8, spec.env.len + extra) catch return null;
    for (spec.env, env[0..spec.env.len], names[0..spec.env.len]) |pair, *label, *name| {
        label.* = .{ .key = pair[0], .value = pair[1] };
        name.* = pair[0];
    }
    if (extra == 1) {
        env[spec.env.len] = .{ .key = constants.relay_env_name, .value = relay_env_value };
        names[spec.env.len] = constants.relay_env_name;
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
        .network = .none,
        .listen = if (spec.relay.len > 0) .{ .port = constants.relay_port } else null,
    };
}

const relay_env_value = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{constants.relay_port});

test "a job with a relay gets no network, one listener on the relay port and ZCUBE_RELAY" {
    // Goal: the security-relevant mapping of `container_spec`. Without a relay the container has
    // no listener and no `ZCUBE_RELAY`; with one it is still `network = .none`.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var spec: launch.Spec = .{
        .name = "job-1",
        .tree = "b3:aa",
        .reference = "ghcr.io/o/r@sha256:00",
        .command = &.{"true"},
        .env = &.{.{ "K", "v" }},
        .labels = &.{.{ "zcube.replica", "job-1" }},
        .launched = 1,
    };
    const plain = container_spec(arena, &spec).?;
    try std.testing.expect(plain.network == .none);
    try std.testing.expect(plain.listen == null);
    try std.testing.expectEqual(@as(usize, 1), plain.env.len);

    spec.relay = "botpike:443";
    const relayed = container_spec(arena, &spec).?;
    try std.testing.expect(relayed.network == .none);
    try std.testing.expectEqual(constants.relay_port, relayed.listen.?.port);
    try std.testing.expectEqual(@as(usize, 2), relayed.env.len);
    try std.testing.expectEqualStrings(constants.relay_env_name, relayed.env[1].key);
    try std.testing.expectEqualStrings(relay_env_value, relayed.env[1].value);
    try std.testing.expectEqualStrings(constants.relay_env_name, relayed.env_names[1]);
}

test "the zigbox supervisor refuses a TLS relay and a release build's plain one (#228)" {
    // Goal: fail closed until B4 slice 4 brings TLS here. Method: a relay naming a server name is
    // refused (never connected in plaintext), so is one that is neither TLS nor plain, and a
    // plain one only in a build that admits plain upstreams.
    var spec: launch.Spec = .{
        .name = "job-1",
        .tree = "b3:aa",
        .reference = "ghcr.io/o/r@sha256:00",
        .command = &.{"true"},
        .env = &.{},
        .labels = &.{},
        .relay = "botpike:443",
        .launched = 1,
    };
    try std.testing.expect(relay_refused(&spec) != null);
    spec.relay_server_name = "broker.botpike.test";
    spec.relay_plain = true;
    const tls = relay_refused(&spec).?;
    try std.testing.expect(std.mem.indexOf(u8, tls, "TLS") != null);
    spec.relay_server_name = "";
    try std.testing.expectEqual(relay_tls.plain_allowed, relay_refused(&spec) == null);
}

test "a relay that cannot be served is written to relay.log after what is there (ZC-E0702)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var full: [std.fs.max_path_bytes:0]u8 = undefined;
    const log = try std.fmt.bufPrintSentinel(&full, "{s}/relay.log", .{path[0..length]}, 0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "relay.log", .data = "earlier line\n" });
    append_relay_failure(log, "the container gave no listener");
    const limit: std.Io.Limit = .limited(4096);
    const io = std.testing.io;
    const text = try tmp.dir.readFileAlloc(io, "relay.log", std.testing.allocator, limit);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("earlier line\n" ++
        "ZC-E0702 a job's relay could not listen: the container gave no listener\n", text);
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

test "a line appended to the fetch's log follows what the fetch wrote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [768]u8 = undefined;
    const swarm = try scratch_swarm(&tmp, &buffer);
    const log = open_log(swarm).?;
    try log.writeStreamingAll(swarm.io, "fetch said this\n");
    log.close(swarm.io);
    append_to_log(swarm, "ZC-W0504: and the supervisor this\n");
    const text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "containers/web-0/fetch.log",
        std.testing.allocator,
        .limited(256),
    );
    defer std.testing.allocator.free(text);
    const want = "fetch said this\nZC-W0504: and the supervisor this\n";
    try std.testing.expectEqualStrings(want, text);
}

test "the end of a swarm fetch and of the registry pull are said in fetch.log" {
    // Goal: the lines a stuck fetch lacked (#93). Method: write each into a scratch log filled
    // with a known byte and read them back.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [768]u8 = undefined;
    const swarm = try scratch_swarm(&tmp, &buffer);
    const log = open_log(swarm).?;
    defer log.close(swarm.io);
    say_swarm_ended(swarm.io, log, "the fetch could not be started: ", "FileNotFound");
    say_pull_ended(swarm, real_ms(swarm.io), true);
    say_pull_ended(swarm, real_ms(swarm.io), false);
    say_no_fetch(swarm, true, false); // A fetch was made: nothing to add.
    say_no_fetch(swarm, false, false);
    const text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "containers/web-0/fetch.log",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ZC-W0603: the swarm fetch ended") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "started: FileNotFound\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "registry pull finished after ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "registry pull failed after ") != null);
    const said = "the tree was already in the store; no fetch was needed";
    const first = std.mem.indexOf(u8, text, said) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first, std.mem.lastIndexOf(u8, text, said).?); // Said once.
}

test "a pull record that cannot be written is said in fetch.log with ZC-W0504" {
    // Method: pull.json is a directory, so the rename onto it fails; the pull's statistics are
    // lost, and the log must say so.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [768]u8 = undefined;
    const swarm = try scratch_swarm(&tmp, &buffer);
    try tmp.dir.createDirPath(std.testing.io, "containers/web-0/pull.json");
    write_pull_record(swarm, "b3:aa", &.{}, 1000);
    const text = try tmp.dir.readFileAlloc(
        std.testing.io,
        "containers/web-0/fetch.log",
        std.testing.allocator,
        .limited(256),
    );
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "ZC-W0504: "));
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
    const cases = [_]struct { argv: []const []const u8, limit: u32, outcome: Outcome }{
        .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .limit = 10_000, .outcome = .ok },
        .{ .argv = &.{ "/bin/sh", "-c", "exit 3" }, .limit = 10_000, .outcome = .failed },
        .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" }, .limit = 200, .outcome = .killed },
    };
    for (cases) |case| {
        var child = try std.process.spawn(io, .{
            .argv = case.argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        const pid = child.id.?;
        const started = awake_ms(io);
        try std.testing.expectEqual(case.outcome, finished_ok(io, &child, case.limit));
        try std.testing.expect(awake_ms(io) - started < 5000); // The sleep did not run its 30 s.
        // Gone: reaped by the wait or by the kill. A live child would answer signal 0.
        try std.testing.expect(std.os.linux.kill(pid, @fromBackingInt(@intCast(0))) != 0);
    }
}

test "a fetch killed at its deadline takes its grandchildren with it" {
    // Goal: the store worker of a fetch (a grandchild, as `namespace.run` makes it) does not
    // outlive the deadline's kill. Method: a shell that starts `sleep 30` in the background,
    // writes its pid and waits; at the deadline, the grandchild must be gone too.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "sleep 30 & echo $! > .zig-cache/tmp/{s}/pid; wait",
        .{tmp.sub_path},
    );
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const started = awake_ms(io);
    try std.testing.expectEqual(Outcome.killed, finished_ok(io, &child, 300));
    try std.testing.expect(awake_ms(io) - started < 5000);
    var text: [32]u8 = undefined;
    const read = try tmp.dir.readFile(io, "pid", &text);
    const grandchild = try std.fmt.parseInt(i32, std.mem.trim(u8, read, " \n"), 10);
    try std.testing.expect(grandchild > 1);
    try std.testing.expect(std.os.linux.kill(grandchild, @fromBackingInt(@intCast(0))) != 0);
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
