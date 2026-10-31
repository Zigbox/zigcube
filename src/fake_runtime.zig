//! `FakeRuntime`: the `Runtime` of `runtime.zig` implemented with real host processes, for the
//! node agent. Shell code: files, processes, signals, the real clock. `SimRuntime` is its model
//! in the core; this is the one that runs a command.
//!
//! **One file to swap.** `zcube_agent.zig` is the only caller of `FakeRuntime.interface`. A real
//! `zigbox` adapter has the same four parts: a state directory it reads for `list`, a supervisor
//! it starts for `start`, signals for `stop`, and a scan for `events`.
//!
//! ## The model (HANDOFF: the supervisor exception)
//!
//! Each container runs under a supervisor: `zcube-agent supervise <dir>`, the agent's own
//! executable started again (`fake_supervisor.zig`). The supervisor is the command's parent, runs
//! in a session of its own, and writes `run.json` when the command ends. The agent never waits
//! for a command and never holds one open, so it can be stopped and started and nothing else
//! notices. **Re-adoption is `list`**: it reads the state directory, `run.json` for a container
//! that ended and the supervisor's lock for one that has not, so a restarted agent finds
//! what its predecessor started and never starts a second one.
//!
//! **`lost`.** A container whose supervisor is gone and left no `run.json` is `lost`, with a
//! diagnostic (ZC-E0509). The first time the agent sees that, it kills what the dead supervisor
//! left behind (the process group) and writes `run.json`, so a lost container never runs on and
//! the verdict is made once.
//!
//! ## Images, limits, faults
//!
//! A digest is valid only if it is in the fixtures list (`fixtures/images.zon`); any other is
//! `start_failed` with the placeholder `ZBX-E0501`. Limits are not applied: this is a plain host
//! process, as HANDOFF says. A test can end a container with `oom`, `pid_limit` or `lost` by
//! writing the word into `<state>/faults/<name>`; the next `list` applies it.
//!
//! ## Where it differs from the contract
//!
//! `stop` waits for a polite stop only `fake_stop_wait_ms` and then returns with the container
//! still running if the grace period is longer; the agent asks again with a grace of 0 to kill
//! it. The contract says it returns once the container has stopped. A single-threaded agent that
//! waited out a long grace would starve its lease (docs/agent.md).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const agent_records = @import("agent_records.zig");
const agent_state = @import("agent_state.zig");
const diag_mod = @import("diag.zig");
const files = @import("fake_files.zig");
const runtime = @import("runtime.zig");
const sim_runtime = @import("sim_runtime.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Dir = std.Io.Dir;

/// How long a polite stop is waited for before `stop` returns.
pub const stop_wait_ms: u32 = 500;
comptime {
    assert(stop_wait_ms < constants.stop_grace_ms);
}

pub const Options = struct {
    /// For the arenas of one operation each; nothing is kept between calls.
    gpa: Allocator,
    /// An absolute path. `containers/`, `faults/` and `agent.lock` live in it.
    state_dir: []const u8,
    /// The agent's executable, which is run again as `<it> supervise <dir>`.
    supervisor_exe: []const u8,
    /// The digests the node "has": anything else is `ZBX-E0501`. Borrowed.
    fixtures: []const []const u8,
};

const Tag = enum(u8) { starting, running, stopped };

const Known = struct { handle: runtime.Handle, tag: Tag };

pub const FakeRuntime = struct {
    io: std.Io,
    clock: Clock,
    options: Options,
    containers: Dir,
    faults: Dir,
    /// The state directory as `AgentState`, which `agent_records` writes and reads through.
    state: files.DirState,
    /// Held for the life of the agent: a second agent on the same state directory is refused.
    lock: std.Io.File,
    /// Supervisors this process started and has not yet reaped (they are its children).
    children: [constants.fake_children_max]i32,
    children_count: u32,
    /// What `events` last saw, to report differences.
    known: [constants.fake_containers_max]Known,
    known_count: u32,

    const vtable: runtime.Runtime.VTable = .{
        .start = start_impl,
        .stop = stop_impl,
        .inspect = inspect_impl,
        .list = list_impl,
        .events = events_impl,
    };

    /// Initialises in place (the tables are large): creates the directories and takes the lock.
    pub fn init(
        self: *FakeRuntime,
        io: std.Io,
        clock: Clock,
        options: Options,
        diag: *Diag,
    ) error{StateDirFailed}!void {
        assert(std.fs.path.isAbsolute(options.state_dir));
        assert(options.fixtures.len <= constants.fixture_images_max);
        self.io = io;
        self.clock = clock;
        self.options = options;
        self.children_count = 0;
        self.known_count = 0;
        const root = Dir.openDirAbsolute(io, options.state_dir, .{}) catch
            return state_dir_failed(diag, options.state_dir, "open it");
        errdefer root.close(io);
        const make = [_][]const u8{ "containers", "faults" };
        for (make) |name| {
            root.createDirPath(io, name) catch
                return state_dir_failed(diag, options.state_dir, "create a directory in it");
        }
        const open: Dir.OpenOptions = .{ .iterate = true };
        self.containers = root.openDir(io, "containers", .{}) catch
            return state_dir_failed(diag, options.state_dir, "open containers/");
        errdefer self.containers.close(io);
        self.faults = root.openDir(io, "faults", open) catch
            return state_dir_failed(diag, options.state_dir, "open faults/");
        errdefer self.faults.close(io);
        self.lock = try take_lock(io, root, diag, options.state_dir);
        self.state = .{ .io = io, .root = root };
    }

    pub fn deinit(self: *FakeRuntime) void {
        self.lock.close(self.io);
        self.state.root.close(self.io);
        self.faults.close(self.io);
        self.containers.close(self.io);
        self.* = undefined;
    }

    pub fn interface(self: *FakeRuntime) runtime.Runtime {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *FakeRuntime {
        return @ptrCast(@alignCast(context));
    }

    // ---- start ----

    fn start_impl(
        context: *anyopaque,
        spec: *const runtime.Spec,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        const self = from(context);
        self.reap();
        if (!agent_records.has_image(self.options.fixtures, spec.image)) {
            var failure: Diagnostic = undefined;
            sim_runtime.image_not_found(&failure, spec.name, spec.image);
            return .{ .failed = failure };
        }
        try self.make_room(spec.name, diag);
        const dir = try self.create_container(spec, diag);
        defer dir.close(self.io);
        var path_buffer: [constants.state_path_bytes_max]u8 = undefined;
        const path = try self.container_path(&path_buffer, spec.name, diag);
        try self.spawn_supervisor(path, spec.name, diag);
        return self.await_start(dir, spec.name, diag);
    }

    /// Writes the container's record (`agent_records.write_spec`, which also clears the files of
    /// an earlier container of this name: the pid and run files must not be mistaken for this
    /// one's) and the empty lock file the supervisor takes.
    fn create_container(
        self: *FakeRuntime,
        spec: *const runtime.Spec,
        diag: *Diag,
    ) runtime.Error!Dir {
        const io = self.io;
        const file = self.spec_file(spec);
        agent_records.write_spec(self.state.interface(), &file) catch |err| switch (err) {
            error.TooBig => return too_large(diag, spec.name),
            else => |other| return state_failed(diag, other, "write the container's record"),
        };
        const dir = self.containers.openDir(io, spec.name, .{}) catch
            return runtime_failed(diag, "open the container's directory");
        errdefer dir.close(io);
        const lock = dir.createFile(io, files.file_lock, .{ .truncate = false }) catch
            return runtime_failed(diag, "create the container's lock file");
        lock.close(io);
        return dir;
    }

    fn spec_file(self: *FakeRuntime, spec: *const runtime.Spec) files.SpecFile {
        // Pairs are views of the spec's own slices, so nothing is copied or allocated here.
        const Pairs = struct {
            var env: [constants.runtime_env_count_max]files.Pair = undefined;
            var labels: [constants.runtime_labels_max]files.Pair = undefined;
        };
        for (spec.env, 0..) |item, index| Pairs.env[index] = .{ item.name, item.value };
        for (spec.labels, 0..) |label, index| Pairs.labels[index] = .{ label.key, label.value };
        return .{
            .name = spec.name,
            .image = spec.image,
            .command = spec.command,
            .env = Pairs.env[0..spec.env.len],
            .labels = Pairs.labels[0..spec.labels.len],
            .started_at_ms = self.clock.now_ms(),
        };
    }

    fn container_path(
        self: *FakeRuntime,
        buffer: []u8,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error![]const u8 {
        const text = std.fmt.bufPrint(buffer, "{s}/containers/{s}", .{
            self.options.state_dir, name,
        }) catch return runtime_failed(diag, "build the container's path");
        return text;
    }

    fn spawn_supervisor(
        self: *FakeRuntime,
        path: []const u8,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!void {
        if (self.children_count == constants.fake_children_max) self.reap();
        if (self.children_count == constants.fake_children_max) {
            return runtime_failed(diag, "start another supervisor");
        }
        const child = std.process.spawn(self.io, .{
            .argv = &.{ self.options.supervisor_exe, "supervise", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return supervisor_failed(diag, name);
        self.children[self.children_count] = child.id.?;
        self.children_count += 1;
    }

    /// Waits for the supervisor to say the command runs (`child.pid`) or could not (`run.json`).
    fn await_start(
        self: *FakeRuntime,
        dir: Dir,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        const began = self.clock.now_ms();
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        while (self.clock.now_ms() -| began < constants.fake_start_timeout_ms) {
            if (files.exists(self.io, dir, files.file_run)) {
                const arena = arena_state.allocator();
                const run = try self.read_run(arena, name, diag) orelse unreachable; // It exists.
                if (run.kind == .start_failed) {
                    return .{ .failed = agent_records.start_failure(name, run) };
                }
                return .{ .started = runtime.Handle.init(name) };
            }
            if (files.exists(self.io, dir, files.file_child)) {
                return .{ .started = runtime.Handle.init(name) };
            }
            self.nap(constants.fake_poll_ms);
        }
        self.kill_group(dir);
        return runtime_failed(diag, "wait for the supervisor to start the command");
    }

    fn nap(self: *FakeRuntime, ms: u32) void {
        self.io.sleep(.fromMilliseconds(ms), .awake) catch {}; // Cancelled: the caller's loop ends.
    }

    /// The runtime holds at most `fake_containers_max` containers: when full, the oldest stopped
    /// one goes; if none has stopped it cannot take another. A stopped container of the same
    /// name is replaced, which is the same thing.
    fn make_room(self: *FakeRuntime, name: []const u8, diag: *Diag) runtime.Error!void {
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const found = try self.scan(arena, diag);
        var oldest: ?Scanned = null;
        for (found) |item| {
            const same = std.mem.eql(u8, item.handle.name(), name);
            if (same) assert(item.tag == .stopped);
            if (item.tag != .stopped) continue;
            if (same) {
                oldest = item;
                break;
            }
            const older = if (oldest) |best| item.started_at_ms < best.started_at_ms else true;
            if (older) oldest = item;
        }
        const full = found.len >= constants.fake_containers_max;
        const replaced = if (oldest) |item| std.mem.eql(u8, item.handle.name(), name) else false;
        if (!full) {
            if (!replaced) return;
        }
        const victim = oldest orelse
            return runtime_failed(diag, "hold another container");
        // Spec first, then the rest and the directory, each removal synced (`DirState`).
        const state = self.state.interface();
        agent_records.remove_container(state, arena, victim.handle.name()) catch |err|
            return state_failed(diag, err, "remove an old container's record");
    }

    // ---- stop ----

    fn stop_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        grace_ms: u32,
        diag: *Diag,
    ) runtime.Error!void {
        const self = from(context);
        const dir = self.containers.openDir(self.io, handle.name(), .{}) catch
            return not_found(diag, handle);
        defer dir.close(self.io);
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const status = try self.status_of(arena, dir, handle.name(), diag);
        if (status == .stopped) return;
        const child = files.read_pid(self.io, dir, files.file_child) catch {
            // Not running yet: there is nothing polite to say to it.
            self.kill_group(dir);
            return;
        };
        if (grace_ms == 0) return self.kill_and_wait(dir, child);
        signal(child, .TERM);
        const waited = @min(grace_ms, stop_wait_ms);
        if (self.wait_ended(dir, waited)) return;
        if (grace_ms <= stop_wait_ms) self.kill_and_wait(dir, child);
    }

    fn kill_and_wait(self: *FakeRuntime, dir: Dir, child: i32) void {
        signal(child, .KILL);
        _ = self.wait_ended(dir, constants.fake_reap_ms);
    }

    /// True once the supervisor has written `run.json`, waiting at most `limit_ms`.
    fn wait_ended(self: *FakeRuntime, dir: Dir, limit_ms: u32) bool {
        const began = self.clock.now_ms();
        while (true) {
            if (files.exists(self.io, dir, files.file_run)) return true;
            if (self.clock.now_ms() -| began >= limit_ms) return false;
            self.nap(constants.fake_poll_ms);
        }
    }

    // ---- inspect and list ----

    fn inspect_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const self = from(context);
        const dir = self.containers.openDir(self.io, handle.name(), .{}) catch
            return not_found(diag, handle);
        defer dir.close(self.io);
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        // The status borrows nothing from the arena: a diagnostic is plain data.
        return self.status_of(arena_state.allocator(), dir, handle.name(), diag);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        const self = from(context);
        self.reap();
        self.apply_faults(arena);
        var listings: std.ArrayList(runtime.Listing) = .empty;
        const records = agent_records.scan(self.state.interface(), arena) catch |err|
            return state_failed(diag, err, "read the containers' records");
        for (records) |record| {
            const listing = try self.listing_of(arena, record, diag) orelse continue;
            if (listings.items.len == constants.runtime_handles_max) break;
            listings.append(arena, listing) catch return no_memory(diag);
        }
        std.mem.sort(runtime.Listing, listings.items, {}, listing_less);
        return listings.items;
    }

    fn listing_less(_: void, first: runtime.Listing, second: runtime.Listing) bool {
        return std.mem.lessThan(u8, first.handle.name(), second.handle.name());
    }

    /// One container as `list` reports it; null if its directory is gone since the scan.
    fn listing_of(
        self: *FakeRuntime,
        arena: Allocator,
        record: agent_records.Record,
        diag: *Diag,
    ) runtime.Error!?runtime.Listing {
        const dir = self.containers.openDir(self.io, record.name, .{}) catch return null;
        defer dir.close(self.io);
        const spec = record.spec;
        const labels = arena.alloc(runtime.Label, spec.labels.len) catch return no_memory(diag);
        for (spec.labels, labels) |pair, *slot| slot.* = .{ .key = pair[0], .value = pair[1] };
        return .{
            .handle = runtime.Handle.init(record.name),
            .labels = labels,
            .status = try self.status_of_spec(arena, dir, record.name, &spec, diag),
        };
    }

    // ---- The status of one container ----

    fn status_of(
        self: *FakeRuntime,
        arena: Allocator,
        dir: Dir,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const read = agent_records.read_spec(self.state.interface(), arena, name);
        const spec = (read catch |err|
            return state_failed(diag, err, "read the container's record")) orelse
            return not_found(diag, runtime.Handle.init(name));
        return self.status_of_spec(arena, dir, name, &spec, diag);
    }

    /// The facts the files and the lock give, decided by `agent_records.classify`. The record is
    /// read again after the lock is seen free, because a supervisor writes it before it lets go
    /// of the lock.
    fn status_of_spec(
        self: *FakeRuntime,
        arena: Allocator,
        dir: Dir,
        name: []const u8,
        spec: *const files.SpecFile,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        var facts: agent_records.Facts = .{
            .run = try self.read_run(arena, name, diag),
            .supervisor_alive = false,
            .child_exists = files.exists(self.io, dir, files.file_child),
            .supervisor_pid_exists = files.exists(self.io, dir, files.file_supervisor),
            .age_ms = self.clock.now_ms() -| spec.started_at_ms,
        };
        if (facts.run == null) {
            facts.supervisor_alive = self.supervisor_alive(dir);
            if (!facts.supervisor_alive) facts.run = try self.read_run(arena, name, diag);
        }
        switch (agent_records.classify(facts)) {
            .stopped => |run| return agent_records.stopped_by(name, run),
            .running => return .running,
            .starting => return .starting,
            .declare_lost => {
                self.declare_lost(dir, name);
                return agent_records.stopped_by(name, .{ .kind = .lost });
            },
        }
    }

    fn read_run(
        self: *FakeRuntime,
        arena: Allocator,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!?files.RunFile {
        return agent_records.read_run(self.state.interface(), arena, name) catch |err|
            state_failed(diag, err, "read the container's result");
    }

    /// True if a supervisor holds the container's lock. Taking it ourselves, to test, lets go at
    /// once.
    fn supervisor_alive(self: *FakeRuntime, dir: Dir) bool {
        const file = dir.createFile(self.io, files.file_lock, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| return err == error.WouldBlock;
        file.close(self.io);
        return false;
    }

    /// The supervisor died without a record. Kill what it left, and write the verdict so it is
    /// made once and a pid that has been recycled since is never signalled.
    fn declare_lost(self: *FakeRuntime, dir: Dir, name: []const u8) void {
        self.kill_group(dir);
        const lost: files.RunFile = .{ .kind = .lost };
        // Next look tries again if this fails.
        agent_records.write_run(self.state.interface(), name, &lost) catch {};
    }

    /// Kills the supervisor's process group: the supervisor, the command, what the command
    /// started. Only what is provably ours is signalled, because the pids come from files that may
    /// be old (after a host restart a recycled pid belongs to someone else): the supervisor must
    /// still be a `supervise` of this state directory, or the command must still be in the
    /// session the supervisor led, which no new process can have as its id while a member lives.
    pub fn kill_group(self: *FakeRuntime, dir: Dir) void {
        const supervisor = files.read_pid(self.io, dir, files.file_supervisor) catch return;
        var ours = self.is_our_supervisor(supervisor);
        if (!ours) {
            const command = files.read_pid(self.io, dir, files.file_child) catch return;
            ours = self.session_of(command) == supervisor;
        }
        if (ours) signal(-supervisor, .KILL);
    }

    /// True if `pid` is a `zcube-agent supervise` of a container under our state directory.
    fn is_our_supervisor(self: *FakeRuntime, pid: i32) bool {
        var path: [32]u8 = undefined;
        // Cannot fail: "/proc/", a pid of at most ten digits and "/cmdline" fit 32 bytes.
        const name = std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch unreachable;
        var buffer: [constants.state_path_bytes_max + 256]u8 = undefined;
        const line = Dir.cwd().readFile(self.io, name, &buffer) catch return false;
        if (std.mem.find(u8, line, "supervise") == null) return false;
        return std.mem.find(u8, line, self.options.state_dir) != null;
    }

    /// The session id of a process, from /proc; null if it is gone.
    fn session_of(self: *FakeRuntime, pid: i32) ?i32 {
        var path: [32]u8 = undefined;
        // Cannot fail: "/proc/", a pid of at most ten digits and "/stat" fit 32 bytes.
        const name = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable;
        var buffer: [1024]u8 = undefined;
        const stat = Dir.cwd().readFile(self.io, name, &buffer) catch return null;
        // "pid (comm) state ppid pgrp session ...": the fields after the last parenthesis.
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        for (0..3) |_| _ = fields.next() orelse return null; // State, parent, group.
        const text = fields.next() orelse return null;
        return std.fmt.parseInt(i32, text, 10) catch null;
    }

    // ---- events ----

    fn events_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        const self = from(context);
        const began = self.clock.now_ms();
        while (true) {
            self.reap();
            const found = try self.scan(arena, diag);
            const changes = try self.changes_since(arena, found, diag);
            if (changes.len > 0) return changes;
            if (self.clock.now_ms() -| began >= timeout_ms) return changes;
            self.nap(constants.fake_poll_ms);
        }
    }

    /// The containers whose state differs from what the last call saw, with their status; and
    /// remembers the new state. At most one batch: the rest is reported next time.
    fn changes_since(
        self: *FakeRuntime,
        arena: Allocator,
        found: []const Scanned,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        var changes: std.ArrayList(runtime.StatusChange) = .empty;
        var next_known: u32 = 0;
        var table: [constants.fake_containers_max]Known = undefined;
        for (found) |item| {
            const before = self.known_tag(item.handle);
            var tag = item.tag;
            if (before != item.tag) {
                if (changes.items.len < constants.runtime_events_batch_max) {
                    const status = try inspect_impl(self, item.handle, diag);
                    changes.append(arena, .{ .handle = item.handle, .status = status }) catch
                        return no_memory(diag);
                } else {
                    tag = before orelse .starting; // Not reported yet: report it next time.
                }
            }
            table[next_known] = .{ .handle = item.handle, .tag = tag };
            next_known += 1;
        }
        @memcpy(self.known[0..next_known], table[0..next_known]);
        self.known_count = next_known;
        return changes.items;
    }

    fn known_tag(self: *const FakeRuntime, handle: runtime.Handle) ?Tag {
        for (self.known[0..self.known_count]) |known| {
            if (known.handle.eql(&handle)) return known.tag;
        }
        return null;
    }

    // ---- A cheap look at every container: its name, state and age ----

    const Scanned = struct { handle: runtime.Handle, tag: Tag, started_at_ms: u64 };

    fn scan(self: *FakeRuntime, arena: Allocator, diag: *Diag) runtime.Error![]const Scanned {
        var found: std.ArrayList(Scanned) = .empty;
        const records = agent_records.scan(self.state.interface(), arena) catch |err|
            return state_failed(diag, err, "read the containers' records");
        for (records) |record| {
            const scanned = try self.scan_one(arena, record, diag) orelse continue;
            found.append(arena, scanned) catch return no_memory(diag);
        }
        return found.items;
    }

    fn scan_one(
        self: *FakeRuntime,
        arena: Allocator,
        record: agent_records.Record,
        diag: *Diag,
    ) runtime.Error!?Scanned {
        const dir = self.containers.openDir(self.io, record.name, .{}) catch return null;
        defer dir.close(self.io);
        const status = try self.status_of_spec(arena, dir, record.name, &record.spec, diag);
        const tag: Tag = switch (status) {
            .starting => .starting,
            .running => .running,
            .stopped => .stopped,
        };
        return .{
            .handle = runtime.Handle.init(record.name),
            .tag = tag,
            .started_at_ms = record.spec.started_at_ms,
        };
    }

    // ---- Zombies and faults ----

    /// Collects the supervisors of this process that have ended, so they do not linger as
    /// zombies. A supervisor of an earlier agent process is its init's business, not ours.
    fn reap(self: *FakeRuntime) void {
        var kept: u32 = 0;
        for (self.children[0..self.children_count]) |pid| {
            var status: i32 = 0;
            const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
            if (rc == 0) { // Still running; any other result is a reaped or unknown child.
                self.children[kept] = pid;
                kept += 1;
            }
        }
        self.children_count = kept;
    }

    /// Applies the faults tests wrote to `<state>/faults/<name>`. A fault waits for its container
    /// to exist and run, and goes once the container has ended whether or not it was applied.
    fn apply_faults(self: *FakeRuntime, arena: Allocator) void {
        var iterator = self.faults.iterate();
        for (0..constants.fake_dir_entries_max) |_| {
            const entry = iterator.next(self.io) catch return;
            const item = entry orelse return;
            if (item.kind != .file) continue;
            if (runtime.name_problem(item.name) != null) continue;
            const word = files.read_bytes(self.io, self.faults, item.name, arena) catch continue;
            if (self.inject(arena, item.name, std.mem.trim(u8, word, "\n "))) {
                self.faults.deleteFile(self.io, item.name) catch {}; // Applied; gone or retried.
            }
        }
    }

    /// True if the fault is done with: applied, meaningless or too late.
    fn inject(self: *FakeRuntime, arena: Allocator, name: []const u8, word: []const u8) bool {
        const dir = self.containers.openDir(self.io, name, .{}) catch return false;
        defer dir.close(self.io);
        if (files.exists(self.io, dir, files.file_run)) return true;
        // Signal only what a live supervisor vouches for: a pid file can be old.
        if (!self.supervisor_alive(dir)) return false;
        const child = files.read_pid(self.io, dir, files.file_child) catch return false;
        _ = arena;
        if (is_limit_word(word)) {
            files.write_atomic(self.io, dir, files.file_forced, word) catch return false;
            signal(child, .KILL);
            return true;
        }
        if (std.mem.eql(u8, word, "lost")) {
            const supervisor = files.read_pid(self.io, dir, files.file_supervisor) catch
                return false;
            // Only the supervisor: the command is left for the lost verdict to find and kill, as
            // it would be if the supervisor had died by itself.
            signal(supervisor, .KILL);
            return true;
        }
        return true;
    }
};

fn is_limit_word(word: []const u8) bool {
    if (std.mem.eql(u8, word, "oom")) return true;
    return std.mem.eql(u8, word, "pid_limit");
}

fn signal(pid: i32, sig: std.posix.SIG) void {
    assert(pid != 0);
    assert(pid != 1);
    std.posix.kill(pid, sig) catch {}; // Already gone is the goal.
}

// ---- Diagnostics -------------------------------------------------------------------------------

fn not_found(diag: *Diag, handle: runtime.Handle) error{NotFound} {
    assert(diag.code == null);
    diag.raise(.E0501);
    diag.cause("the runtime has no container named {s}", .{handle.name()});
    diag.fix(.{ .sentence = "treat the replica as lost; the controller replaces it" });
    return error.NotFound;
}

fn no_memory(diag: *Diag) error{RuntimeFailed} {
    if (diag.code == null) {
        diag.raise(.E0502);
        diag.cause("the memory set aside for this pass ran out", .{});
        diag.fix(.{ .sentence = "run fewer containers on this node" });
    }
    return error.RuntimeFailed;
}

fn too_large(diag: *Diag, name: []const u8) error{RuntimeFailed} {
    assert(diag.code == null);
    diag.raise(.E0502);
    const limit = constants.fake_file_bytes_max;
    diag.cause("the spec of {s} is larger than {d} bytes", .{ name, limit });
    diag.fix(.{ .sentence = "shorten the command or the environment in the service file" });
    return error.RuntimeFailed;
}

/// ZC-E0502 for something the host refused. The host's own word is not shown: error names are
/// not for users (DIAGNOSTICS.md), and the operation says what was being done.
fn runtime_failed(diag: *Diag, operation: []const u8) error{RuntimeFailed} {
    assert(diag.code == null);
    diag.raise(.E0502);
    diag.cause("can't {s}", .{operation});
    diag.fix(.{ .sentence = "check the agent's state directory and the host's limits" });
    return error.RuntimeFailed;
}

/// ZC-E0502 for a state-directory operation the host refused (`error.Io`): what was refused, and
/// that the host did it. The other errors cannot come from files: `Absent` is handled where it is
/// expected, and `Crashed` is only the simulation's.
fn state_failed(diag: *Diag, err: agent_state.Error, operation: []const u8) error{RuntimeFailed} {
    switch (err) {
        error.OutOfMemory => return no_memory(diag),
        error.Io, error.TooBig => {},
        error.Absent, error.Crashed => unreachable, // Not for the callers: see above.
    }
    assert(diag.code == null);
    diag.raise(.E0502);
    diag.cause("the host refused to {s} in the agent's state directory", .{operation});
    const sentence = "check the disk space and permissions of the agent's state directory";
    diag.fix(.{ .sentence = sentence });
    return error.RuntimeFailed;
}

fn supervisor_failed(diag: *Diag, name: []const u8) error{RuntimeFailed} {
    assert(diag.code == null);
    diag.raise(.E0507);
    diag.cause("the host refused to start a supervisor for {s}", .{name});
    diag.fix(.{ .sentence = "free process slots on the node, or restart the agent" });
    return error.RuntimeFailed;
}

fn state_dir_failed(
    diag: *Diag,
    path: []const u8,
    operation: []const u8,
) error{StateDirFailed} {
    assert(diag.code == null);
    diag.raise(.E0506);
    diag.cause("can't {s}: {s}", .{ operation, path });
    diag.fix(.{ .sentence = "create the directory and let the agent's user write to it" });
    return error.StateDirFailed;
}

/// Takes the state directory's lock, so that two agents never share it.
fn take_lock(
    io: std.Io,
    root: Dir,
    diag: *Diag,
    path: []const u8,
) error{StateDirFailed}!std.Io.File {
    const file = root.createFile(io, "agent.lock", .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| {
        if (err != error.WouldBlock) return state_dir_failed(diag, path, "lock");
        diag.raise(.E0506);
        diag.cause("another agent is using the state directory {s}", .{path});
        diag.fix(.{ .sentence = "give each agent a state directory of its own" });
        return error.StateDirFailed;
    };
    return file;
}
