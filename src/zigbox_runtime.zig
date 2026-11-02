//! `ZigboxRuntime`: the `Runtime` of `runtime.zig` over the linked `zigbox` module. C2 slice 1
//! (docs/briefs/c2-1.md). Shell code: files, processes, signals, the real clock.
//!
//! **One container, one supervisor.** `start` writes a launch directory (`zigbox_launch.zig`) and
//! starts `zcube-agent supervise-zigbox <dir>`, which gets the image onto the node, starts the
//! container with `zigbox.start` and waits for it (`zigbox_supervisor.zig`). The agent never
//! waits for a container and never holds a Zigbox `Handle`, so it can be stopped and started
//! and the containers carry on. Everything the agent knows about a container it reads: Zigbox's
//! run records and the kernel through `zigbox.lifecycle` (`list`, `adopt`), and the launch
//! directory for the time before a record exists. **Re-adoption is `list`.**
//!
//! A container is `starting` while its supervisor lives and no record of this launch exists
//! (a pull can take minutes), `running` or `stopped` as the record and the kernel say, and
//! `lost` when its supervisor is gone and left nothing. A record older than the launch is an
//! earlier container of the same name and is ignored.
//!
//! ## Where it differs from the contract
//!
//! `stop` does not wait out a grace period (`lifecycle.stop` would block the agent's lease for
//! up to `grace_ms` + 5 s): with a grace it sends SIGTERM and waits at most `stop_wait_ms`; with
//! none it sends SIGKILL and waits as long. The caller checks `inspect` and asks again, as with
//! `FakeRuntime`. For N containers a fence costs up to N times `stop_wait_ms`: docs/briefs/c2-1.md
//! (c).4 proposes the non-blocking `signal` that removes it.
//!
//! `host` is a parameter, so the tests run the lifecycle calls over Zigbox's simulated kernel.
//! `start` and the supervisor need real processes and are covered by `zigbox-smoke`.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const agent_records = @import("agent_records.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("fake_files.zig");
const launch = @import("zigbox_launch.zig");
const map = @import("zigbox_map.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;
const Dir = std.Io.Dir;
const lifecycle = zigbox.lifecycle;

/// How long a stop is waited for before `stop` returns (see the header).
pub const stop_wait_ms: u32 = 500;
/// How long `start` waits for the supervisor to take its lock.
pub const supervisor_up_ms: u32 = 3000;
/// How long `start` waits, once the supervisor is up, for the container to run or the start to
/// fail. A pull takes longer and is `starting`; a missing image or a refused limit does not.
pub const start_settle_ms: u32 = 250;
/// The pause between two looks while waiting.
pub const poll_ms: u32 = 50;

comptime {
    assert(stop_wait_ms < constants.stop_grace_ms);
    assert(start_settle_ms < supervisor_up_ms);
    assert(poll_ms < start_settle_ms);
}

const entries_max = map.bounds.runs_max + map.bounds.scopes_listed_max;

/// An image the node can pull: the tree digest the service names, and where to fetch it.
pub const Image = struct { digest: []const u8, reference: []const u8 };

pub const Options = struct {
    /// For the arenas of one operation each.
    gpa: Allocator,
    /// An absolute path. `zigbox/` (the launch directories) and `agent.lock` live in it.
    state_dir: []const u8,
    /// The agent's executable, run again as `<it> supervise-zigbox <dir>`.
    supervisor_exe: []const u8,
    /// Where each image can be pulled from. Borrowed.
    images: []const Image,
};

const Tag = enum(u8) { starting, running, stopped };
const Known = struct { handle: runtime.Handle, tag: Tag };

pub const ZigboxRuntime = struct {
    io: std.Io,
    host: zigbox.host.Host,
    options: Options,
    /// `<state>/zigbox/`.
    root: Dir,
    state: Dir,
    /// The state directory as `AgentState`: the remembered server pair is kept in it.
    pair_state: files.DirState,
    lock: std.Io.File,
    /// `zigbox.list`'s room, kept between calls (each entry holds a whole record).
    entries: []zigbox.Entry,
    children: [constants.fake_children_max]i32,
    children_count: u32,
    known: [constants.runtime_handles_max]Known,
    known_count: u32,

    const vtable: runtime.Runtime.VTable = .{
        .start = start_impl,
        .stop = stop_impl,
        .inspect = inspect_impl,
        .list = list_impl,
        .events = events_impl,
    };

    /// Initialises in place (the tables are large): opens the directories and takes the lock.
    pub fn init(
        self: *ZigboxRuntime,
        io: std.Io,
        host: zigbox.host.Host,
        options: Options,
        diag: *Diag,
    ) error{StateDirFailed}!void {
        assert(std.fs.path.isAbsolute(options.state_dir));
        self.io = io;
        self.host = host;
        self.options = options;
        self.children_count = 0;
        self.known_count = 0;
        self.state = Dir.openDirAbsolute(io, options.state_dir, .{}) catch
            return state_dir_failed(diag, options.state_dir, "open it");
        errdefer self.state.close(io);
        self.pair_state = .{ .io = io, .root = self.state };
        self.root = launch.open_root(io, self.state) catch
            return state_dir_failed(diag, options.state_dir, "create zigbox/ in it");
        errdefer self.root.close(io);
        self.lock = try take_lock(io, self.state, diag, options.state_dir);
        errdefer self.lock.close(io);
        self.entries = options.gpa.alloc(zigbox.Entry, entries_max) catch
            return state_dir_failed(diag, options.state_dir, "set aside memory for");
    }

    /// Refuses a host that can't run Zigbox containers (ZC-E0512). Zigbox's doctor is not part
    /// of the linked module, so this is the cheap test: Linux, and a run directory it can read.
    /// Whatever else is missing is named by Zigbox itself at the first start (ZBX-E04xx).
    pub fn preflight(self: *ZigboxRuntime, diag: *Diag) error{HostUnsupported}!void {
        if (@import("builtin").os.tag != .linux) return host_unsupported(diag, "it is not Linux");
        _ = lifecycle.list(self.host, self.entries) catch
            return host_unsupported(diag, "Zigbox can't read its run records here");
    }

    pub fn deinit(self: *ZigboxRuntime) void {
        self.options.gpa.free(self.entries);
        self.lock.close(self.io);
        self.root.close(self.io);
        self.state.close(self.io);
        self.* = undefined;
    }

    pub fn interface(self: *ZigboxRuntime) runtime.Runtime {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *ZigboxRuntime {
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
        if (map.refusal(spec)) |reason| return .{ .failed = refusal_diagnostic(reason, spec) };
        const spec_file = self.launch_spec(spec);
        launch.write_spec(self.io, self.root, &spec_file) catch
            return runtime_failed(diag, "write the container's launch record");
        try self.spawn_supervisor(spec.name, diag);
        return self.await_start(spec.name, diag);
    }

    fn launch_spec(self: *ZigboxRuntime, spec: *const runtime.Spec) launch.Spec {
        // Pairs are views of the spec's own slices, so nothing is copied or allocated here.
        const Pairs = struct {
            var env: [constants.runtime_env_count_max]launch.Pair = undefined;
            var labels: [constants.runtime_labels_max]launch.Pair = undefined;
        };
        for (spec.env, 0..) |item, index| Pairs.env[index] = .{ item.name, item.value };
        for (spec.labels, 0..) |label, index| Pairs.labels[index] = .{ label.key, label.value };
        return .{
            .name = spec.name,
            .tree = spec.image,
            .reference = self.reference_of(spec.image),
            .command = spec.command,
            .env = Pairs.env[0..spec.env.len],
            .labels = Pairs.labels[0..spec.labels.len],
            .cpu_millis = spec.limits.cpu_millis,
            .memory_bytes = spec.limits.memory_bytes,
            .pids = spec.limits.pids,
            .launched = self.host.time_now(),
        };
    }

    /// The reference to pull `digest` from; empty if the node has none (the store may still).
    fn reference_of(self: *const ZigboxRuntime, digest: []const u8) []const u8 {
        for (self.options.images) |image| {
            if (std.mem.eql(u8, image.digest, digest)) return image.reference;
        }
        return "";
    }

    fn spawn_supervisor(self: *ZigboxRuntime, name: []const u8, diag: *Diag) runtime.Error!void {
        if (self.children_count == constants.fake_children_max) self.reap();
        if (self.children_count == constants.fake_children_max) {
            return runtime_failed(diag, "start another supervisor");
        }
        var path_buffer: [constants.state_path_bytes_max]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}/{s}", .{
            self.options.state_dir, launch.dir_name, name,
        }) catch return runtime_failed(diag, "build the container's path");
        const child = std.process.spawn(self.io, .{
            .argv = &.{ self.options.supervisor_exe, "supervise-zigbox", path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return supervisor_failed(diag, name);
        self.children[self.children_count] = child.id.?;
        self.children_count += 1;
    }

    /// Waits for the supervisor to take its lock, then a moment for the start to fail or the
    /// container to run. A start that is still going after that is `started` and `starting`.
    fn await_start(
        self: *ZigboxRuntime,
        name: []const u8,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        const began = self.host.monotonic_ms();
        var up_at: ?u64 = null;
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const found = try self.resolve(arena, name, diag);
            assert(found.len <= 1);
            if (found.len == 1) switch (found[0].status) {
                .running => return .{ .started = runtime.Handle.init(name) },
                .stopped => |reason| switch (reason) {
                    .start_failed => |failure| return .{ .failed = failure },
                    else => return .{ .started = runtime.Handle.init(name) },
                },
                .starting => if (up_at == null) {
                    up_at = self.host.monotonic_ms();
                },
            };
            const now = self.host.monotonic_ms();
            if (up_at) |at| {
                if (now -| at >= start_settle_ms) return .{ .started = runtime.Handle.init(name) };
            } else if (now -| began >= supervisor_up_ms) {
                self.kill_supervisor(name);
                return supervisor_failed(diag, name);
            }
            self.host.sleep_ms(poll_ms);
        }
    }

    // ---- stop ----

    fn stop_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        grace_ms: u32,
        diag: *Diag,
    ) runtime.Error!void {
        const self = from(context);
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        const found = try self.resolve(arena_state.allocator(), handle.name(), diag);
        if (found.len == 0) return agent_records.not_found(diag, handle.name());
        switch (found[0].status) {
            .stopped => return,
            .starting => return self.kill_supervisor(handle.name()),
            .running => {},
        }
        var ref: lifecycle.Ref = undefined;
        var state: lifecycle.State = undefined;
        lifecycle.adopt(self.host, handle.name(), &ref, &state) catch
            return runtime_failed(diag, "find the container's run record");
        if (state != .running) return;
        // `lifecycle.signal` forwards only the terminating signals zbx catches (TERM among them,
        // and SIGKILL in its place for a PID 1 with no handler); a hard kill goes to the host.
        const sent = if (grace_ms > 0)
            lifecycle.signal(&ref, map.bounds.signal_term)
        else
            self.host.signal(ref.pid, map.bounds.signal_kill);
        sent catch |err| {
            if (err == error.NotFound) return; // It ended between the look and the signal.
            return runtime_failed(diag, "signal the container");
        };
        if (self.wait_gone(&ref, stop_wait_ms)) return;
        if (grace_ms > 0) return; // The caller asks again, with no grace, to kill.
        _ = self.wait_gone(&ref, stop_wait_ms);
    }

    fn wait_gone(self: *ZigboxRuntime, ref: *const lifecycle.Ref, limit_ms: u32) bool {
        assert(limit_ms > 0);
        const began = self.host.monotonic_ms();
        while (true) {
            if (!lifecycle.alive(self.host, ref.pid, ref.scope.slice())) return true;
            if (self.host.monotonic_ms() -| began >= limit_ms) return false;
            self.host.sleep_ms(lifecycle.poll_step_ms);
        }
    }

    /// SIGKILL to the supervisor of a launch that has no container yet, if it is ours: the lock
    /// is held, so its pid file names a live supervisor and not a recycled number.
    fn kill_supervisor(self: *ZigboxRuntime, name: []const u8) void {
        const dir = launch.container_dir(self.io, self.root, name) orelse return;
        defer dir.close(self.io);
        if (!launch.supervisor_alive(self.io, dir)) return;
        const pid = files.read_pid(self.io, dir, launch.file_supervisor) catch return;
        std.posix.kill(pid, .KILL) catch {}; // Gone already.
    }

    // ---- inspect, list ----

    fn inspect_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const self = from(context);
        var arena_state = std.heap.ArenaAllocator.init(self.options.gpa);
        defer arena_state.deinit();
        const found = try self.resolve(arena_state.allocator(), handle.name(), diag);
        if (found.len == 0) return agent_records.not_found(diag, handle.name());
        return found[0].status;
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        const self = from(context);
        self.reap();
        return self.resolve(arena, null, diag);
    }

    /// The containers of ours, or the one called `only`: Zigbox's records that carry our replica
    /// label, and the launches that have no record of their own yet (or ever).
    fn resolve(
        self: *ZigboxRuntime,
        arena: Allocator,
        only: ?[]const u8,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        const launches = try self.read_launches(arena, only, diag);
        const count = lifecycle.list(self.host, self.entries) catch
            return runtime_failed(diag, "read Zigbox's run records");
        var result: std.ArrayList(runtime.Listing) = .empty;
        for (self.entries[0..count]) |*entry| {
            if (!entry.has_record or !is_ours(&entry.record)) continue;
            if (only) |name| {
                if (!std.mem.eql(u8, entry.name(), name)) continue;
            }
            if (launch_of(launches, entry.name())) |one| {
                if (entry.record.started < one.spec.launched) continue; // An earlier container.
                one.matched = true;
            }
            const listing = try listing_of(arena, entry, diag);
            result.append(arena, listing) catch return no_memory(diag);
        }
        for (launches) |*one| {
            if (one.matched) continue;
            const listing = try pending_listing(arena, one, diag);
            result.append(arena, listing) catch return no_memory(diag);
        }
        if (result.items.len > constants.runtime_handles_max) {
            return runtime_failed(diag, "hold this many containers");
        }
        return result.items;
    }

    fn read_launches(
        self: *ZigboxRuntime,
        arena: Allocator,
        only: ?[]const u8,
        diag: *Diag,
    ) runtime.Error![]Launch {
        var names: std.ArrayList([]const u8) = .empty;
        if (only) |name| {
            names.append(arena, name) catch return no_memory(diag);
        } else {
            var iterator = self.root.iterate();
            while (true) {
                const next = iterator.next(self.io) catch
                    return runtime_failed(diag, "list launches");
                const item = next orelse break;
                if (item.kind != .directory) continue;
                if (runtime.name_problem(item.name) != null) continue;
                if (names.items.len == constants.runtime_handles_max) break;
                const copy = arena.dupe(u8, item.name) catch return no_memory(diag);
                names.append(arena, copy) catch return no_memory(diag);
            }
        }
        var result: std.ArrayList(Launch) = .empty;
        for (names.items) |name| {
            const dir = launch.container_dir(self.io, self.root, name) orelse continue;
            defer dir.close(self.io);
            const spec = launch.read_spec(self.io, dir, arena) catch continue;
            if (!std.mem.eql(u8, spec.name, name)) continue; // Not what the agent wrote.
            const phase = launch.phase(self.io, dir, arena);
            result.append(arena, .{ .spec = spec, .phase = phase, .matched = false }) catch
                return no_memory(diag);
        }
        return result.items;
    }

    // ---- events ----

    fn events_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        const self = from(context);
        const began = self.host.monotonic_ms();
        while (true) {
            self.reap();
            const found = try self.resolve(arena, null, diag);
            const changes = try self.changes_since(arena, found, diag);
            if (changes.len > 0) return changes;
            if (self.host.monotonic_ms() -| began >= timeout_ms) return changes;
            self.host.sleep_ms(@min(poll_ms, timeout_ms));
        }
    }

    /// The containers whose state differs from what the last call saw; remembers the new state.
    /// At most one batch: the rest is reported next time. Events are a hint, `list` the truth.
    fn changes_since(
        self: *ZigboxRuntime,
        arena: Allocator,
        found: []const runtime.Listing,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        var changes: std.ArrayList(runtime.StatusChange) = .empty;
        var table: [constants.runtime_handles_max]Known = undefined;
        for (found, 0..) |item, at| {
            const before = self.known_tag(item.handle);
            var tag = tag_of(item.status);
            if (before != tag) {
                if (changes.items.len < constants.runtime_events_batch_max) {
                    const change: runtime.StatusChange = .{
                        .handle = item.handle,
                        .status = item.status,
                    };
                    changes.append(arena, change) catch return no_memory(diag);
                } else {
                    tag = before orelse .starting; // Not reported yet: report it next time.
                }
            }
            table[at] = .{ .handle = item.handle, .tag = tag };
        }
        @memcpy(self.known[0..found.len], table[0..found.len]);
        self.known_count = @intCast(found.len);
        return changes.items;
    }

    fn known_tag(self: *const ZigboxRuntime, handle: runtime.Handle) ?Tag {
        for (self.known[0..self.known_count]) |known| {
            if (known.handle.eql(&handle)) return known.tag;
        }
        return null;
    }

    /// Collects the supervisors of this process that have ended, so they do not linger as
    /// zombies. A supervisor of an earlier agent process is its init's business, not ours.
    fn reap(self: *ZigboxRuntime) void {
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
};

const Launch = struct { spec: launch.Spec, phase: launch.Phase, matched: bool };

fn launch_of(launches: []Launch, name: []const u8) ?*Launch {
    for (launches) |*one| {
        if (std.mem.eql(u8, one.spec.name, name)) return one;
    }
    return null;
}

fn tag_of(status: runtime.Status) Tag {
    return switch (status) {
        .starting => .starting,
        .running => .running,
        .stopped => .stopped,
    };
}

/// A container is ours if it carries the replica label; Zigbox's records hold every run of the
/// user, `zbx run` ones included.
fn is_ours(record: *const zigbox.records.Parsed) bool {
    var index: u32 = 0;
    while (index < record.labels_count) : (index += 1) {
        if (std.mem.eql(u8, record.label(index)[0], runtime.label_replica)) return true;
    }
    return false;
}

fn listing_of(
    arena: Allocator,
    entry: *const zigbox.Entry,
    diag: *Diag,
) runtime.Error!runtime.Listing {
    const labels = map.labels(arena, &entry.record) orelse return no_memory(diag);
    var listing: runtime.Listing = .{
        .handle = runtime.Handle.init(entry.name()),
        .labels = labels,
        .status = undefined,
    };
    map.status(&listing.status, entry);
    return listing;
}

/// A launch with no record of its own: starting, or ended without ever starting a container.
fn pending_listing(
    arena: Allocator,
    one: *const Launch,
    diag: *Diag,
) runtime.Error!runtime.Listing {
    const labels = arena.alloc(runtime.Label, one.spec.labels.len) catch return no_memory(diag);
    for (one.spec.labels, labels) |pair, *label| label.* = .{ .key = pair[0], .value = pair[1] };
    var listing: runtime.Listing = .{
        .handle = runtime.Handle.init(one.spec.name),
        .labels = labels,
        .status = undefined,
    };
    switch (one.phase) {
        .absent => unreachable, // `read_launches` keeps only launches that have a spec.
        .working => listing.status = .starting,
        .gone => listing.status = .{
            .stopped = .{ .lost = agent_records.lost_diagnostic(one.spec.name) },
        },
        .failed => |line| {
            var failure: Diagnostic = undefined;
            if (launch.parse_failed(&failure, line)) {
                listing.status = .{ .stopped = .{ .start_failed = failure } };
            } else {
                listing.status = .{
                    .stopped = .{ .lost = agent_records.lost_diagnostic(one.spec.name) },
                };
            }
        },
    }
    return listing;
}

// ---- Diagnostics -------------------------------------------------------------------------------

/// Why Zigcube refused a spec Zigbox would have refused too, blamed on the service's author.
fn refusal_diagnostic(reason: map.Refusal, spec: *const runtime.Spec) Diagnostic {
    var collector: Diag = undefined;
    collector.reset();
    collector.raise(.E0513);
    switch (reason) {
        .env_name_empty => collector.cause("an environment variable has no name", .{}),
        .env_name_too_long => collector.cause("an environment variable name is too long", .{}),
        .env_value_too_long => collector.cause("an environment variable value is too long", .{}),
        .name_too_long => collector.cause("the container name is too long", .{}),
        .command_too_long => collector.cause("the command is too long", .{}),
    }
    collector.fix(.{ .sentence = "shorten it in the service file, then apply it again" });
    collector.while_("starting container {s}", .{spec.name});
    var out: Diagnostic = undefined;
    diag_mod.to_diagnostic(&out, &collector);
    return out;
}

fn no_memory(diag: *Diag) error{RuntimeFailed} {
    if (diag.code == null) {
        diag.raise(.E0502);
        diag.cause("the memory set aside for this pass ran out", .{});
        diag.fix(.{ .sentence = "run fewer containers on this node" });
    }
    return error.RuntimeFailed;
}

/// ZC-E0502 for something the host refused. The host's own word is not shown: error names are
/// not for users (DIAGNOSTICS.md), and the operation says what was being done.
fn runtime_failed(diag: *Diag, operation: []const u8) error{RuntimeFailed} {
    if (diag.code != null) return error.RuntimeFailed;
    diag.raise(.E0502);
    diag.cause("can't {s}", .{operation});
    diag.fix(.{ .sentence = "check the agent's state directory and the host's limits" });
    return error.RuntimeFailed;
}

fn host_unsupported(diag: *Diag, why: []const u8) error{HostUnsupported} {
    assert(diag.code == null);
    diag.raise(.E0512);
    diag.cause("this host can't run Zigbox containers: {s}", .{why});
    diag.fix(.{ .sentence = "run zbx doctor as the agent's user and fix what it names, " ++
        "or use --runtime fake" });
    return error.HostUnsupported;
}

fn supervisor_failed(diag: *Diag, name: []const u8) error{RuntimeFailed} {
    assert(diag.code == null);
    diag.raise(.E0507);
    diag.cause("the supervisor for {s} did not start", .{name});
    diag.fix(.{ .sentence = "free process slots on the node, or restart the agent" });
    return error.RuntimeFailed;
}

fn state_dir_failed(diag: *Diag, path: []const u8, operation: []const u8) error{StateDirFailed} {
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

// ---- Tests -----------------------------------------------------------------------------------
//
// These run `list`, `inspect`, `events` and `stop` over Zigbox's simulated kernel, with
// containers started by `zigbox.start` as a supervisor would. `start_impl`, the supervisor and
// real signalling are covered only by `zigbox-smoke` (docs/briefs/c2-1.md step 6).

const testing = std.testing;
const HostSim = zigbox.host_sim.HostSim;

const rootfs_path = "/srv/alpine";
const home_path = "/home/alice";
const hour_ms: u32 = 3_600_000;

const sim_files = [_]zigbox.host_sim.File{
    .{ .path = "/proc/self/status", .content = "Name:\tzbx\nThreads:\t1\n" },
    .{ .path = rootfs_path, .content = "", .mode = 0o040755 },
    .{ .path = "/etc/passwd", .content = "alice:x:1000:1000::/home/alice:/bin/bash\n" },
    .{ .path = "/proc/sys/user/max_user_namespaces", .content = "63488\n" },
    .{ .path = "/sys/fs/cgroup/cgroup.controllers", .content = "cpuset cpu io memory pids\n" },
    .{ .path = "/etc/subuid", .content = "alice:100000:65536\n" },
    .{ .path = "/etc/subgid", .content = "alice:100000:65536\n" },
    .{ .path = "/usr/bin/newuidmap", .content = "", .mode = 0o104755 },
    .{ .path = "/usr/bin/newgidmap", .content = "", .mode = 0o104755 },
};
const sim_env = [_]zigbox.host_sim.EnvironmentVariable{
    .{ .name = "HOME", .value = home_path },
    .{ .name = "XDG_RUNTIME_DIR", .value = "/run/user/1000" },
};

/// A handle is large; the tests run one at a time. The handle keeps pointing at the label, so it
/// outlives the call.
var sim_handle: zigbox.Handle = undefined;
var labels_buffer: [1]zigbox.Label = undefined;

fn sim_up(sim: *HostSim, seed: u64) void {
    sim.init(seed, &sim_files);
    sim.world.seed_container_host(rootfs_path);
    sim.world.add_node(home_path, .dir);
    sim.environment_variables = &sim_env;
    sim.world.command_runs_ms = hour_ms;
}

fn sim_container(sim: *HostSim, name: []const u8, replica: ?[]const u8) !void {
    var diagnostic: zigbox.diag.Diag = undefined;
    diagnostic.reset();
    const labels: []const zigbox.Label = if (replica) |value| blk: {
        labels_buffer[0] = .{ .key = runtime.label_replica, .value = value };
        break :blk labels_buffer[0..1];
    } else &.{};
    const spec: zigbox.Spec = .{
        .rootfs = rootfs_path,
        .name = name,
        .command = &.{ "/bin/sh", "-c", "sleep 1000" },
        .labels = labels,
    };
    try zigbox.start(sim.interface(), &spec, .{ .detached = true }, &sim_handle, &diagnostic);
}

const Rig = struct {
    tmp: testing.TmpDir,
    sim: HostSim,
    rt: ZigboxRuntime,
    path: [std.fs.max_path_bytes]u8,

    fn up(rig: *Rig, seed: u64) !void {
        rig.tmp = testing.tmpDir(.{ .iterate = true });
        sim_up(&rig.sim, seed);
        const length = try rig.tmp.dir.realPath(testing.io, &rig.path);
        var diag: Diag = undefined;
        diag.reset();
        try rig.rt.init(testing.io, rig.sim.interface(), .{
            .gpa = testing.allocator,
            .state_dir = rig.path[0..length],
            .supervisor_exe = "/nonexistent/zcube-agent",
            .images = &.{},
        }, &diag);
    }

    fn down(rig: *Rig) void {
        rig.rt.deinit();
        rig.tmp.cleanup();
    }

    fn launch_spec(rig: *Rig, name: []const u8, launched: u64) !void {
        const spec: launch.Spec = .{
            .name = name,
            .tree = "b3:51aa9c03",
            .reference = "",
            .command = &.{ "sh", "-c", "true" },
            .env = &.{},
            .labels = &.{.{ runtime.label_replica, name }},
            .launched = launched,
        };
        try launch.write_spec(rig.rt.io, rig.rt.root, &spec);
    }
};

fn find(listings: []const runtime.Listing, name: []const u8) ?runtime.Listing {
    for (listings) |item| {
        if (std.mem.eql(u8, item.handle.name(), name)) return item;
    }
    return null;
}

fn list_one(rig: *Rig, unlabelled: bool, arena: Allocator) ![]const runtime.Listing {
    const name = if (unlabelled) "other" else "web-1";
    try sim_container(&rig.sim, name, if (unlabelled) null else "web-1");
    var diag: Diag = undefined;
    diag.reset();
    return rig.rt.interface().list(arena, &diag);
}

test "list shows our containers, running, with their labels" {
    // Goal: re-adoption is `list`. Method: a container started by someone else.
    var rig: Rig = undefined;
    try rig.up(1);
    defer rig.down();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const listings = try list_one(&rig, false, arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), listings.len);
    try testing.expect(listings[0].status == .running);
    try testing.expectEqualStrings("web-1", listings[0].handle.name());
    try testing.expectEqualStrings(runtime.label_replica, listings[0].labels[0].key);
}

test "list leaves out a container without the replica label" {
    // Goal: Zigbox's records hold every run of the user, `zbx run` ones included.
    var rig: Rig = undefined;
    try rig.up(6);
    defer rig.down();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try list_one(&rig, true, arena_state.allocator())).len);
}

test "stop with no grace kills; the record then says stopped" {
    // Goal: `stop` signals through Zigbox's rule (a PID 1 with no handler is killed) and the
    // status turns to stopped once the owner reaps it. Also: stopping a stopped container is
    // fine, and an unknown one is NotFound.
    var rig: Rig = undefined;
    try rig.up(2);
    defer rig.down();
    try sim_container(&rig.sim, "web-1", "web-1");
    const rt = rig.rt.interface();
    var diag: Diag = undefined;
    diag.reset();
    const handle = runtime.Handle.init("web-1");
    try testing.expect((try rt.inspect(handle, &diag)) == .running);
    try rt.stop(handle, 0, &diag);
    _ = zigbox.wait(&sim_handle); // The supervisor's side: reap and finish the record.
    const status = try rt.inspect(handle, &diag);
    try testing.expectEqual(@as(u8, 9), status.stopped.signaled);
    try rt.stop(handle, 0, &diag);
    diag.reset();
    try testing.expectError(error.NotFound, rt.stop(runtime.Handle.init("nope"), 0, &diag));
}

test "a launch with a live supervisor and no record is starting; without one, lost" {
    // Goal: the time before a Zigbox record exists. A held lock is `starting`; a spec with no
    // lock holder and no failure line is `lost`; a failure line is `start_failed`.
    var rig: Rig = undefined;
    try rig.up(3);
    defer rig.down();
    try rig.launch_spec("web-1", 5);
    const dir = launch.container_dir(rig.rt.io, rig.rt.root, "web-1").?;
    defer dir.close(rig.rt.io);
    const rt = rig.rt.interface();
    var diag: Diag = undefined;
    diag.reset();
    const handle = runtime.Handle.init("web-1");
    {
        const holder = try dir.createFile(rig.rt.io, launch.file_lock, .{
            .truncate = false,
            .lock = .exclusive,
        });
        defer holder.close(rig.rt.io);
        try testing.expect((try rt.inspect(handle, &diag)) == .starting);
    }
    const lost = try rt.inspect(handle, &diag);
    try testing.expect(lost.stopped == .lost);

    var failure: zigbox.diag.Diag = undefined;
    failure.reset();
    failure.raise(.E0410);
    var line: Diagnostic = undefined;
    zigbox.diagnostic.from_diag(&line, &failure);
    try launch.write_failed(rig.rt.io, dir, &line);
    const failed = try rt.inspect(handle, &diag);
    try testing.expectEqualStrings("ZBX-E0410", failed.stopped.start_failed.code.slice());
}

test "a record older than the launch is an earlier container and is ignored" {
    // Goal: a name is reused. The sim container's record was begun at the sim's time (small); a
    // launch dated after it makes the record stale, so the replica reads as lost (supervisor
    // gone) and not as the old container's state.
    var rig: Rig = undefined;
    try rig.up(4);
    defer rig.down();
    try sim_container(&rig.sim, "web-1", "web-1");
    try rig.launch_spec("web-1", std.math.maxInt(u32));
    var diag: Diag = undefined;
    diag.reset();
    const status = try rig.rt.interface().inspect(runtime.Handle.init("web-1"), &diag);
    try testing.expect(status.stopped == .lost);
}

test "events report a container once when it appears and once when it stops" {
    var rig: Rig = undefined;
    try rig.up(5);
    defer rig.down();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rt = rig.rt.interface();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(@as(usize, 0), (try rt.events(arena, 0, &diag)).len);
    try sim_container(&rig.sim, "web-1", "web-1");
    const first = try rt.events(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expect(first[0].status == .running);
    try testing.expectEqual(@as(usize, 0), (try rt.events(arena, 0, &diag)).len);
    try rt.stop(runtime.Handle.init("web-1"), 0, &diag);
    _ = zigbox.wait(&sim_handle);
    const last = try rt.events(arena, 0, &diag);
    try testing.expectEqual(@as(usize, 1), last.len);
    try testing.expect(last[0].status == .stopped);
}
