//! `SimRuntime`: the `Runtime` of `runtime.zig` implemented in the core, with no host process, no
//! file and no real clock. It is deterministic: time is the injected `Clock`, and what is random
//! (which container a random fault hits, a pid) comes from one seed passed to `init`. The
//! simulation (`sim.zig`) and the browser demo drive the agent against it.
//!
//! It is not `FakeRuntime`, which runs real host processes and belongs to the shell.
//!
//! ## What it models
//!
//! Each container runs under a supervisor (HANDOFF principle 1, the recorded exception): the
//! supervisor is the container's parent and collects its exit status, which is why a restarted
//! agent can still read how a container ended. A container's command runs until something ends
//! it: a fault, or a stop. `lost` means the supervisor died or the process vanished, so nothing
//! recorded how it ended.
//!
//! An image is valid only if its digest is in the fixtures list given to `init` (HANDOFF's
//! `fixtures/images.zon`, parsed by the shell; a list of digests). Any other digest is a start
//! that fails with `ZBX-E0410`, "no tree with that digest", blamed on the user
//! (Zigbox's own code, as the real runtime raises it).
//!
//! ## Faults
//!
//! `inject` ends a running container as a real one could end: `exit` with a code, `signal`
//! (`kill -9` is signal 9), `oom`, `pid_limit`, `supervisor_died` and `process_vanished` (both
//! `lost`), and `slow_stop`, after which the container ignores the polite stop and a `stop`
//! takes the whole grace period before the kill. `random_fault` picks a running container and a
//! fault from the seed.
//!
//! ## Stop is a request, in virtual time
//!
//! `Runtime.stop` is documented to return once the container has stopped. A runtime in virtual
//! time cannot wait, so a stop of a container that stops at once (the normal case) returns with
//! it stopped, as documented, and a stop of a slow one (`slow_stop`) returns with the container
//! still `running` until the grace period has passed on the clock. The agent never relies on a
//! stop having completed, so both are fine for it; the shell's adapter may be either. This is the
//! one place the simulated runtime is lazier than the contract (docs/core.md).
//!
//! `Runtime.signal` is exact: TERM ends a polite container at once and a `slow_stop` one not at
//! all, KILL ends any; neither waits. The fence uses it to stop N containers against one deadline.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const agent_records = @import("agent_records.zig");
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");
const c1_teeth = @import("c1_teeth.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

/// The digests the simulated node's store holds when a scenario gives none: `hello` and a second
/// image to apply a change with. Anything else is not in the store.
pub const default_fixtures = [_][]const u8{ "b3:51aa9c03", "b3:9d20c4f1" };

pub const Fault = union(enum) {
    exit: u8,
    signal: u8,
    oom,
    pid_limit,
    supervisor_died,
    process_vanished,
    slow_stop,
};

pub const Injected = struct {
    handle: runtime.Handle,
    fault: Fault,
};

const Ended = union(enum) {
    exited: u8,
    signaled: u8,
    oom,
    pid_limit,
    lost,
};

const Phase = union(enum) {
    running,
    /// A stop was asked for; the container is killed at this time (ms on the clock).
    stopping: u64,
    stopped: Ended,
};

const Container = struct {
    name: []u8,
    image: []u8,
    labels: []runtime.Label,
    phase: Phase,
    pid: u32,
    started_at_ms: u64,
    /// When it stopped, for tests that say when (`ended_at_ms`); 0 while it runs.
    ended_at_ms: u64 = 0,
    ignores_stop: bool,
    /// The spec named a relay (B3): the container's listener is opened at start.
    relay_wanted: bool = false,
    /// The listener of the container's relay is open. Opened at start, closed by every ending
    /// (`end`) and gone with the container when its node's disk is wiped (the host died).
    relay_open: bool = false,
    /// B4: the certificate the run's supervisor holds (sim_certs.zig), null until the server
    /// issues one. It lives in the supervisor's memory, so it goes with the container.
    cert: ?Cert = null,
    /// The clock reading (simulation ms) before which the supervisor does not ask again.
    cert_ask_ms: u64 = 0,
    /// Relayed connections open now through the relay, each on the run's certificate. Every
    /// ending closes them with the listener (`end`).
    conns: u32 = 0,
    /// When its supervisor was told to stop it (B4, R7), while it runs out its grace; null if it
    /// was never told, or ended at once.
    stop_requested_ms: ?u64 = null,
    /// B4: a `stop` of this container takes its grace (it enters `.stopping`), though a TERM
    /// signal still ends it at once, unlike `ignores_stop`: so the fence is unchanged and only
    /// a run told to stop has a window in which R7 judges its connections.
    stop_takes_grace: bool = false,
};

/// B4: a supervisor told to stop ends the run's relayed connections within this long (the brief's
/// `relay_cancel_ms_max = 2 * relay_poll_ms`, docs/briefs/b4.md). Slice 2 brings the constant to
/// `constants.zig`; this one goes when it does.
pub const relay_cancel_ms_max: u64 = 2 * constants.relay_poll_ms;

/// A run's certificate as its supervisor keeps it: the placement epoch it names and its end.
pub const Cert = struct { epoch: u64, not_after_ms: u64 };

const Change = struct {
    handle: runtime.Handle,
    ended: ?Ended,
};

const events_max = constants.runtime_events_batch_max;

pub const SimRuntime = struct {
    gpa: Allocator,
    clock: Clock,
    prng: std.Random.DefaultPrng,
    fixtures: []const []const u8,
    containers: std.ArrayList(Container),
    pid_next: u32,
    changes: [events_max]Change,
    changes_count: u32,
    /// Called for every `start` of a known image, before anything is created. The cluster
    /// simulation sets it to keep a ledger of starts (sim-c1's J2 and J7).
    on_start: ?*const fn (context: *anyopaque, spec: *const runtime.Spec) void = null,
    on_start_context: *anyopaque = undefined,
    /// Listeners opened and closed so far (the report's tally of the relay model).
    relays_opened: u32 = 0,
    relays_closed: u32 = 0,
    /// The same closes by how the container's life ended: exited, signaled, other (oom, pid limit,
    /// lost supervisor), wiped with its host.
    relays_closed_by: [4]u32 = .{ 0, 0, 0, 0 },
    /// Set when a container was forgotten (evicted or replaced) with its listener still open: a
    /// listener nobody can close any more. Sticky, so that eviction cannot hide the leak.
    relay_forgotten: bool = false,
    /// Relayed connections opened and closed so far (B4, the report's tally).
    conns_opened: u32 = 0,
    conns_closed: u32 = 0,
    /// Set when a container was forgotten with relayed connections still open (R6; sticky).
    conns_forgotten: bool = false,
    /// Set when a container ended with relayed connections still open more than
    /// `relay_cancel_ms_max` after its stop was asked for (R7; sticky, so that a stop and its end
    /// between two checks cannot hide the late close).
    conns_late: bool = false,

    const vtable: runtime.Runtime.VTable = .{
        .start = start_impl,
        .stop = stop_impl,
        .signal = signal_impl,
        .inspect = inspect_impl,
        .list = list_impl,
        .events = events_impl,
    };

    /// Initialises in place. `fixtures` is borrowed: it must outlive the runtime.
    pub fn init(
        self: *SimRuntime,
        gpa: Allocator,
        clock: Clock,
        seed: u64,
        fixtures: []const []const u8,
    ) void {
        self.* = .{
            .gpa = gpa,
            .clock = clock,
            .prng = .init(seed),
            .fixtures = fixtures,
            .containers = .empty,
            .pid_next = 1000 + @as(u32, @truncate(seed % 1000)),
            .changes = undefined,
            .changes_count = 0,
        };
        assert(self.containers.items.len == 0);
    }

    pub fn deinit(self: *SimRuntime) void {
        for (self.containers.items) |container| self.free_container(container);
        self.containers.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn interface(self: *SimRuntime) runtime.Runtime {
        return .{ .context = self, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *SimRuntime {
        return @ptrCast(@alignCast(context));
    }

    // ---- Faults ----

    /// Applies a fault to the named container. A fault that ends a container needs it running.
    pub fn inject(self: *SimRuntime, name: []const u8, fault: Fault) error{NotFound}!void {
        const container = self.find(name) orelse return error.NotFound;
        self.tick();
        if (container.phase == .stopped) return;
        switch (fault) {
            .exit => |code| self.end(container, .{ .exited = code }),
            .signal => |number| self.end(container, .{ .signaled = number }),
            .oom => self.end(container, .oom),
            .pid_limit => self.end(container, .pid_limit),
            .supervisor_died, .process_vanished => self.end(container, .lost),
            .slow_stop => container.ignores_stop = true,
        }
    }

    /// A fault on a random running container, or null if none runs. The seed decides which.
    pub fn random_fault(self: *SimRuntime) ?Injected {
        self.tick();
        var running: u32 = 0;
        for (self.containers.items) |container| {
            if (container.phase != .stopped) running += 1;
        }
        if (running == 0) return null;
        var pick = self.prng.random().uintLessThan(u32, running);
        const random = self.prng.random();
        for (self.containers.items) |*container| {
            if (container.phase == .stopped) continue;
            if (pick > 0) {
                pick -= 1;
                continue;
            }
            const fault = random_kind(random);
            const handle = runtime.Handle.init(container.name);
            self.inject(container.name, fault) catch unreachable; // It was found just above.
            return .{ .handle = handle, .fault = fault };
        }
        unreachable; // `pick` is below the number of running containers.
    }

    fn random_kind(random: std.Random) Fault {
        return switch (random.uintLessThan(u32, 6)) {
            0 => .{ .exit = random.uintLessThan(u8, 3) },
            1, 2 => .{ .signal = 9 },
            3 => .oom,
            4 => .supervisor_died,
            else => .process_vanished,
        };
    }

    /// The node's disk is lost with its state directory: every container, running or not, is
    /// gone (their records were the state directory's files; the processes die with the host).
    pub fn wipe(self: *SimRuntime) void {
        // The listeners die with the host.
        self.relays_closed += self.relay_open_count();
        self.relays_closed_by[3] += self.relay_open_count();
        for (self.containers.items) |container| self.conns_closed += container.conns;
        for (self.containers.items) |container| self.free_container(container);
        self.containers.clearRetainingCapacity();
    }

    /// True if a container of that name is known, running or stopped.
    pub fn has(self: *SimRuntime, name: []const u8) bool {
        return self.find(name) != null;
    }

    /// The clock reading when the named container started; null if unknown.
    pub fn started_at_ms(self: *SimRuntime, name: []const u8) ?u64 {
        const container = self.find(name) orelse return null;
        return container.started_at_ms;
    }

    /// The clock reading when the named container stopped; null if unknown or still running.
    pub fn ended_at_ms(self: *SimRuntime, name: []const u8) ?u64 {
        const container = self.find(name) orelse return null;
        if (container.phase != .stopped) return null;
        return container.ended_at_ms;
    }

    /// Containers that have not stopped.
    pub fn running_count(self: *const SimRuntime) u32 {
        var count: u32 = 0;
        for (self.containers.items) |container| {
            if (container.phase != .stopped) count += 1;
        }
        return count;
    }

    /// Listeners that are open now.
    pub fn relay_open_count(self: *const SimRuntime) u32 {
        var count: u32 = 0;
        for (self.containers.items) |container| count += @intFromBool(container.relay_open);
        return count;
    }

    /// What is wrong with the relay listeners, if anything (B3, check R1 to R3): a listener open
    /// on a container that has stopped or was forgotten, or a running container whose relay is
    /// not open.
    pub fn relay_problem(self: *const SimRuntime) ?[]const u8 {
        if (self.relay_forgotten) return "R1: a relay listener outlived its container's record";
        for (self.containers.items) |container| {
            const ended = container.phase == .stopped;
            if (ended and container.relay_open) {
                return "R1: a relay listener stayed open after its run ended";
            }
            if (!ended and container.relay_wanted and !container.relay_open) {
                return "R3: a running job has no relay listener";
            }
        }
        return null;
    }

    // ---- Internals ----

    fn find(self: *SimRuntime, name: []const u8) ?*Container {
        for (self.containers.items) |*container| {
            if (std.mem.eql(u8, container.name, name)) return container;
        }
        return null;
    }

    fn free_container(self: *SimRuntime, container: Container) void {
        for (container.labels) |label| {
            self.gpa.free(label.key);
            self.gpa.free(label.value);
        }
        self.gpa.free(container.labels);
        self.gpa.free(container.name);
        self.gpa.free(container.image);
    }

    /// Finishes the stops whose grace period has passed on the clock.
    fn tick(self: *SimRuntime) void {
        const now = self.clock.now_ms();
        for (self.containers.items) |*container| {
            switch (container.phase) {
                .stopping => |deadline| {
                    if (now >= deadline) self.end(container, .{ .signaled = 9 });
                },
                else => {},
            }
        }
    }

    fn end(self: *SimRuntime, container: *Container, ended: Ended) void {
        assert(container.phase != .stopped);
        container.phase = .{ .stopped = ended };
        container.ended_at_ms = self.clock.now_ms();
        // Every ending closes the relay's listener: exit, signal, cancel, deadline, a lost
        // supervisor. (`relay_leak` is the test-only fault that leaves it open.)
        if (container.relay_open and !c1_teeth.relay_leak) {
            container.relay_open = false;
            self.relays_closed += 1;
            const kind: usize = switch (ended) {
                .exited => 0,
                .signaled => 1,
                else => 2,
            };
            self.relays_closed_by[kind] += 1;
        }
        // B4: the relayed connections close with the relay, before the ending can be reported.
        if (container.conns > 0 and self.stop_overdue(container)) self.conns_late = true;
        self.close_conns(container);
        self.record(.{ .handle = runtime.Handle.init(container.name), .ended = ended });
    }

    /// Whether a container was told to stop more than `relay_cancel_ms_max` ago.
    fn stop_overdue(self: *const SimRuntime, container: *const Container) bool {
        const asked = container.stop_requested_ms orelse return false;
        return self.clock.now_ms() -| asked > relay_cancel_ms_max;
    }

    /// R7 (B4): relayed connections end within `relay_cancel_ms_max` of the run's stop request.
    /// A container still in its grace with connections open past the bound, or one that ended so
    /// (`conns_late`), fails it.
    pub fn stop_conns_problem(self: *const SimRuntime) ?[]const u8 {
        const found = "R7: a relayed connection stayed open past relay_cancel_ms_max after its " ++
            "run was told to stop";
        if (self.conns_late) return found;
        for (self.containers.items) |*container| {
            if (container.conns > 0 and self.stop_overdue(container)) return found;
        }
        return null;
    }

    /// Closes a run's relayed connections (`relay_conn_leak` is the test-only fault that leaves
    /// them open, R6's tooth).
    fn close_conns(self: *SimRuntime, container: *Container) void {
        if (c1_teeth.relay_conn_leak) return;
        self.conns_closed += container.conns;
        container.conns = 0;
    }

    /// Queues a status change for `events`, dropping the oldest when the queue is full: events
    /// are a hint, and `list` is the truth.
    fn record(self: *SimRuntime, change: Change) void {
        if (self.changes_count == events_max) {
            std.mem.copyForwards(Change, self.changes[0 .. events_max - 1], self.changes[1..]);
            self.changes_count -= 1;
        }
        self.changes[self.changes_count] = change;
        self.changes_count += 1;
    }

    fn status_of(container: *const Container) runtime.Status {
        return switch (container.phase) {
            .running, .stopping => .running,
            .stopped => |ended| .{ .stopped = exit_reason(container.name, ended) },
        };
    }

    /// `lost` carries ZC-E0509, as `FakeRuntime` reports it.
    fn exit_reason(name: []const u8, ended: Ended) runtime.ExitReason {
        return switch (ended) {
            .exited => |code| .{ .exited = code },
            .signaled => |number| .{ .signaled = number },
            .oom => .oom,
            .pid_limit => .pid_limit,
            .lost => .{ .lost = agent_records.lost_diagnostic(name) },
        };
    }

    /// What the process side of a container is, as the files of a real node would show it.
    pub const Process = union(enum) {
        /// No supervisor ever ran for the name.
        absent,
        /// The command runs (or is being stopped).
        alive,
        /// The supervisor wrote how the command ended.
        ended: agent_records.RunFile,
        /// The supervisor or the process vanished and nothing recorded how the command ended.
        vanished,
    };

    pub fn process(self: *SimRuntime, name: []const u8) Process {
        self.tick();
        const container = self.find(name) orelse return .absent;
        const ended = switch (container.phase) {
            .running, .stopping => return .alive,
            .stopped => |ended| ended,
        };
        return switch (ended) {
            .exited => |code| .{ .ended = .{ .kind = .exited, .code = code } },
            .signaled => |number| .{ .ended = .{ .kind = .signaled, .signal = number } },
            .oom => .{ .ended = .{ .kind = .oom } },
            .pid_limit => .{ .ended = .{ .kind = .pid_limit } },
            .lost => .vanished,
        };
    }

    /// Forgets a container that has stopped (its record was evicted). A container that has not
    /// stopped is never forgotten.
    pub fn evict(self: *SimRuntime, name: []const u8) void {
        const container = self.find(name) orelse return;
        assert(container.phase == .stopped);
        self.remove(container);
    }

    // ---- The Runtime interface ----

    fn start_impl(
        context: *anyopaque,
        spec: *const runtime.Spec,
        diag: *Diag,
    ) runtime.Error!runtime.StartOutcome {
        const self = from(context);
        self.tick();
        if (!self.has_image(spec.image)) {
            var failure: Diagnostic = undefined;
            image_not_found(&failure, spec.name, spec.image);
            return .{ .failed = failure };
        }
        if (self.on_start) |hook| hook(self.on_start_context, spec);
        if (self.find(spec.name)) |existing| {
            // Names are unique among containers that have not stopped; a stopped one with the
            // same name is replaced, the way a runtime reuses a name.
            assert(existing.phase == .stopped);
            self.remove(existing);
        }
        try self.make_room(diag);
        const container = self.copy_spec(spec) catch return no_memory(diag);
        self.containers.append(self.gpa, container) catch {
            self.free_container(container);
            return no_memory(diag);
        };
        self.relays_opened += @intFromBool(spec.relay.len > 0);
        return .{ .started = runtime.Handle.init(spec.name) };
    }

    fn has_image(self: *const SimRuntime, image: []const u8) bool {
        return agent_records.has_image(self.fixtures, image);
    }

    fn copy_spec(self: *SimRuntime, spec: *const runtime.Spec) Allocator.Error!Container {
        const name = try self.gpa.dupe(u8, spec.name);
        errdefer self.gpa.free(name);
        const image = try self.gpa.dupe(u8, spec.image);
        errdefer self.gpa.free(image);
        const labels = try self.gpa.alloc(runtime.Label, spec.labels.len);
        errdefer self.gpa.free(labels);
        var copied: usize = 0;
        errdefer for (labels[0..copied]) |label| {
            self.gpa.free(label.key);
            self.gpa.free(label.value);
        };
        for (spec.labels, labels) |label, *slot| {
            const key = try self.gpa.dupe(u8, label.key);
            errdefer self.gpa.free(key);
            slot.* = .{ .key = key, .value = try self.gpa.dupe(u8, label.value) };
            copied += 1;
        }
        const pid = self.pid_next;
        self.pid_next += 1 + self.prng.random().uintLessThan(u32, 7);
        return .{
            .name = name,
            .image = image,
            .labels = labels,
            .phase = .running,
            .pid = pid,
            .started_at_ms = self.clock.now_ms(),
            .ignores_stop = false,
            .relay_wanted = spec.relay.len > 0,
            .relay_open = spec.relay.len > 0,
        };
    }

    fn remove(self: *SimRuntime, container: *Container) void {
        if (container.relay_open) self.relay_forgotten = true;
        if (container.conns > 0) self.conns_forgotten = true;
        const index = container - self.containers.items.ptr;
        self.free_container(container.*);
        _ = self.containers.orderedRemove(index);
    }

    /// The runtime holds at most `runtime_handles_max` containers: when full, the oldest stopped
    /// one goes (its bounded retention); if none has stopped, it cannot take another.
    fn make_room(self: *SimRuntime, diag: *Diag) runtime.Error!void {
        if (self.containers.items.len < constants.runtime_handles_max) return;
        for (self.containers.items) |*container| {
            if (container.phase != .stopped) continue;
            self.remove(container);
            return;
        }
        diag.raise(.E0502);
        diag.cause("the simulated runtime holds {d} containers and none has stopped", .{
            constants.runtime_handles_max,
        });
        diag.fix(.{ .sentence = "stop containers that are no longer needed" });
        return error.RuntimeFailed;
    }

    fn stop_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        grace_ms: u32,
        diag: *Diag,
    ) runtime.Error!void {
        const self = from(context);
        self.tick();
        const container = self.find(handle.name()) orelse return not_found(diag, handle);
        const now = self.clock.now_ms();
        switch (container.phase) {
            .stopped => return,
            .running => {
                const slow = container.ignores_stop or container.stop_takes_grace;
                if (!slow) return self.end(container, .{ .signaled = 15 });
                if (grace_ms == 0) return self.end(container, .{ .signaled = 9 });
                container.phase = .{ .stopping = now + grace_ms };
                container.stop_requested_ms = now;
                // B4: a supervisor told to stop ends its relayed connections at once
                // (`relay_cancel_ms_max`), before the container's grace runs out.
                // (`relay_stop_leak` is R7's tooth: they stay open until the end.)
                if (!c1_teeth.relay_stop_leak) self.close_conns(container);
            },
            .stopping => |deadline| {
                if (now + grace_ms < deadline) container.phase = .{ .stopping = now + grace_ms };
                if (grace_ms == 0) self.end(container, .{ .signaled = 9 });
            },
        }
    }

    /// A signal acts at once and never waits: TERM ends a container that does not ignore it (a
    /// `slow_stop` one does, and stays as it was), KILL ends any that has not stopped.
    fn signal_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        number: u8,
        diag: *Diag,
    ) runtime.Error!void {
        const self = from(context);
        self.tick();
        const container = self.find(handle.name()) orelse return not_found(diag, handle);
        switch (container.phase) {
            .stopped => {},
            .running, .stopping => {
                if (number == runtime.signal_kill) return self.end(container, .{ .signaled = 9 });
                assert(number == runtime.signal_term);
                if (container.ignores_stop) return;
                self.end(container, .{ .signaled = 15 });
            },
        }
    }

    fn inspect_impl(
        context: *anyopaque,
        handle: runtime.Handle,
        diag: *Diag,
    ) runtime.Error!runtime.Status {
        const self = from(context);
        self.tick();
        const container = self.find(handle.name()) orelse return not_found(diag, handle);
        return status_of(container);
    }

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) runtime.Error![]const runtime.Listing {
        const self = from(context);
        self.tick();
        const listings = arena.alloc(runtime.Listing, self.containers.items.len) catch
            return no_memory(diag);
        for (self.containers.items, listings) |*container, *listing| {
            const labels = copy_labels(arena, container.labels) catch return no_memory(diag);
            listing.* = .{
                .handle = runtime.Handle.init(container.name),
                .labels = labels,
                .status = status_of(container),
            };
        }
        return listings;
    }

    /// Labels with their strings, in the caller's arena: the container may be dropped by a later
    /// call, and the caller's listing must outlive that (a start can evict a stopped container).
    fn copy_labels(
        arena: Allocator,
        labels: []const runtime.Label,
    ) Allocator.Error![]runtime.Label {
        const copy = try arena.alloc(runtime.Label, labels.len);
        for (labels, copy) |label, *slot| {
            const key = try arena.dupe(u8, label.key);
            slot.* = .{ .key = key, .value = try arena.dupe(u8, label.value) };
        }
        return copy;
    }

    fn events_impl(
        context: *anyopaque,
        arena: Allocator,
        timeout_ms: u32,
        diag: *Diag,
    ) runtime.Error![]const runtime.StatusChange {
        _ = timeout_ms; // Virtual time: report what is ready now, as the memory store's watch does.
        const self = from(context);
        self.tick();
        const count = @min(self.changes_count, constants.runtime_events_batch_max);
        const out = arena.alloc(runtime.StatusChange, count) catch return no_memory(diag);
        for (self.changes[0..count], out) |change, *slot| {
            const status: runtime.Status = if (change.ended) |ended|
                .{ .stopped = exit_reason(change.handle.name(), ended) }
            else
                .running;
            slot.* = .{ .handle = change.handle, .status = status };
        }
        const left = self.changes_count - count;
        const rest = self.changes[count..self.changes_count];
        std.mem.copyForwards(Change, self.changes[0..left], rest);
        self.changes_count -= count;
        return out;
    }

    fn no_memory(diag: *Diag) error{RuntimeFailed} {
        assert(diag.code == null);
        diag.raise(.E0502);
        diag.cause("the simulated runtime ran out of memory", .{});
        diag.fix(.{ .sentence = "give the simulation a larger allocator" });
        return error.RuntimeFailed;
    }

    fn not_found(diag: *Diag, handle: runtime.Handle) error{NotFound} {
        assert(diag.code == null);
        diag.raise(.E0501);
        diag.cause("the simulated runtime has no container named {s}", .{handle.name()});
        diag.fix(.{ .sentence = "treat the replica as lost; the controller replaces it" });
        return error.NotFound;
    }
};

/// The diagnostic of a start that failed because the image is not in the node's store: HANDOFF's
/// `ZBX-E0410`, with the digest shortened as its example shows (in ASCII: diagnostics are).
pub fn image_not_found(out: *Diagnostic, name: []const u8, image: []const u8) void {
    var short_buffer: [32]u8 = undefined;
    var image_buffer: [constants.image_digest_bytes_max]u8 = undefined;
    var name_buffer: [runtime.name_bytes_max]u8 = undefined;
    const short = shorten(&short_buffer, image);
    const safe_image = sanitise(&image_buffer, image);
    const safe_name = sanitise(&name_buffer, name);
    var json_buffer: [1024]u8 = undefined;
    const format = "{{\"code\":\"ZBX-E0410\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"{s}\"," ++
        "\"causes\":[\"digest {s} is not in this node's store\"]," ++
        "\"while\":[\"starting container {s}\"]," ++
        "\"context\":{{\"image\":\"{s}\"}}," ++
        "\"fixes\":[{{\"sentence\":\"check the digest in the service file, or pull the image " ++
        "first\",\"command\":null}}]," ++
        "\"omitted\":{{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}}}}";
    const summary = "no tree with that digest";
    const json = std.fmt.bufPrint(&json_buffer, format, .{ summary, short, safe_name, safe_image });
    // Cannot fail: the longest result is under 600 bytes, and the buffer holds 1024.
    // Cannot fail: `json` is the format above with sanitised text, which is well formed.
    zigbox.diagnostic.parse_json(out, json catch unreachable) catch unreachable;
    out.set_docs(&zigbox.product.Product.zbx);
    assert(std.mem.eql(u8, out.code.slice(), "ZBX-E0410"));
}

/// "b3:00ff...e1": the first seven bytes, three dots and the last two, if it is longer.
fn shorten(buffer: []u8, digest: []const u8) []const u8 {
    var safe: [constants.image_digest_bytes_max]u8 = undefined;
    const text = sanitise(&safe, digest);
    // Cannot fail: the text is at most 67 bytes and the buffer 32, but a short digest is under 15.
    if (text.len <= 14) return std.fmt.bufPrint(buffer, "{s}", .{text}) catch unreachable;
    const format = "{s}...{s}";
    // Cannot fail: seven plus three plus two bytes fit the 32-byte buffer.
    const parts = .{ text[0..7], text[text.len - 2 ..] };
    const shortened = std.fmt.bufPrint(buffer, format, parts);
    return shortened catch unreachable; // See above: it fits.
}

/// Replaces anything that is not a letter, digit or one of `:-._` with '?', so text that goes
/// into hand-written JSON needs no escaping.
fn sanitise(buffer: []u8, text: []const u8) []const u8 {
    assert(buffer.len >= text.len);
    for (text, buffer[0..text.len]) |byte, *slot| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or
            byte == '.' or byte == '_';
        slot.* = if (plain) byte else '?';
    }
    return buffer[0..text.len];
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const repeat = @import("test_util.zig").repeat;

const labels_of = struct {
    fn one(id: []const u8) [1]runtime.Label {
        return .{.{ .key = runtime.label_replica, .value = id }};
    }
};

fn spec_for(name: []const u8, image: []const u8, labels: []const runtime.Label) runtime.Spec {
    return .{ .name = name, .image = image, .command = &.{"true"}, .labels = labels };
}

test "a digest in the fixtures starts, and one that is not fails with ZBX-E0410" {
    // Goal: the start contract: a started container is an outcome, so is a failed start, and the
    // failure carries HANDOFF's diagnostic, blamed on the user. Method: start both kinds.
    var manual: ManualClock = .{ .ms = 5 };
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 7, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const labels = labels_of.one("hello-1");
    const good = spec_for("hello-1", "b3:51aa9c03", &labels);
    try testing.expectEqualStrings("hello-1", (try rt.start(&good, &diag)).started.name());
    const bad_labels = labels_of.one("broken-1");
    const long_digest = "b3:00ff" ++ repeat('0', 55).* ++ "e1";
    const bad = spec_for("broken-1", long_digest, &bad_labels);
    const outcome = try rt.start(&bad, &diag);
    const failure = outcome.failed;
    try testing.expectEqualStrings("ZBX-E0410", failure.code.slice());
    try testing.expectEqualStrings("no tree with that digest", failure.summary.slice());
    try testing.expectEqual(zigbox.codes.Blame.user, failure.blame);
    try testing.expectEqualStrings(
        "digest b3:00ff...e1 is not in this node's store",
        failure.last_cause().?,
    );
    try testing.expectEqual(@as(u32, 1), sim.running_count());
}

test "faults end a container the way a real one ends, and list says how" {
    // Goal: every fault of the brief, as the status a restarted agent would read. Method: five
    // containers, one fault each, then `list`.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 1, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const names = [_][]const u8{ "a-1", "a-2", "a-3", "a-4", "a-5" };
    for (names) |name| {
        const labels = labels_of.one(name);
        _ = try rt.start(&spec_for(name, "b3:51aa9c03", &labels), &diag);
    }
    try sim.inject("a-1", .{ .exit = 3 });
    try sim.inject("a-2", .{ .signal = 9 });
    try sim.inject("a-3", .oom);
    try sim.inject("a-4", .supervisor_died);
    try sim.inject("a-5", .pid_limit);
    try testing.expectError(error.NotFound, sim.inject("nope", .oom));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const listed = try rt.list(arena_state.allocator(), &diag);
    try testing.expectEqual(@as(usize, 5), listed.len);
    try testing.expectEqual(@as(u8, 3), listed[0].status.stopped.exited);
    try testing.expectEqual(@as(u8, 9), listed[1].status.stopped.signaled);
    try testing.expect(listed[2].status.stopped == .oom);
    try testing.expectEqualStrings("ZC-E0509", listed[3].status.stopped.lost.?.code.slice());
    try testing.expect(listed[4].status.stopped == .pid_limit);
    try testing.expectEqualStrings("a-1", listed[0].labels[0].value[0..3]);
    const changes = try rt.events(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 5), changes.len);
    try testing.expectEqual(@as(usize, 0), (try rt.events(arena_state.allocator(), 0, &diag)).len);
}

test "a wipe removes every container, running or stopped, and a name can be started again" {
    // Goal: `wipe` is the lost disk: nothing is listed, nothing is known by name, the events of
    // the lost containers are not replayed as new ones, and the node starts fresh containers.
    // Method: one running and one stopped container, wipe, list, start the same name again.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 1, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const running = labels_of.one("a-1");
    const stopped = labels_of.one("a-2");
    _ = try rt.start(&spec_for("a-1", "b3:51aa9c03", &running), &diag);
    _ = try rt.start(&spec_for("a-2", "b3:51aa9c03", &stopped), &diag);
    try sim.inject("a-2", .{ .exit = 0 });
    try testing.expectEqual(@as(u32, 1), sim.running_count());

    sim.wipe();
    try testing.expectEqual(@as(u32, 0), sim.running_count());
    try testing.expect(!sim.has("a-1"));
    try testing.expect(!sim.has("a-2"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try rt.list(arena_state.allocator(), &diag)).len);
    // Wiping an empty runtime is fine, and the name is free.
    sim.wipe();
    _ = try rt.start(&spec_for("a-1", "b3:51aa9c03", &running), &diag);
    try testing.expectEqual(@as(u32, 1), sim.running_count());
}

test "a signal never waits: TERM is ignored by a slow container, KILL ends it" {
    // Goal: the semantics of `Runtime.signal` in virtual time. Method: signal a polite, a slow
    // and a stopped container; the clock never moves, so nothing is waited for.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 1, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const one = labels_of.one("a-1");
    const two = labels_of.one("a-2");
    _ = try rt.start(&spec_for("a-1", "b3:51aa9c03", &one), &diag);
    _ = try rt.start(&spec_for("a-2", "b3:51aa9c03", &two), &diag);
    const first = runtime.Handle.init("a-1");
    const second = runtime.Handle.init("a-2");
    try sim.inject("a-2", .slow_stop);

    try rt.signal(first, runtime.signal_term, &diag);
    try testing.expectEqual(@as(u8, 15), (try rt.inspect(first, &diag)).stopped.signaled);
    try rt.signal(second, runtime.signal_term, &diag);
    try testing.expect((try rt.inspect(second, &diag)) == .running);
    try rt.signal(second, runtime.signal_kill, &diag);
    try testing.expectEqual(@as(u8, 9), (try rt.inspect(second, &diag)).stopped.signaled);
    try rt.signal(second, runtime.signal_kill, &diag); // Stopped: nothing.
    try rt.signal(first, runtime.signal_term, &diag);
    try testing.expectEqual(@as(u8, 15), (try rt.inspect(first, &diag)).stopped.signaled);
    try testing.expectError(
        error.NotFound,
        rt.signal(runtime.Handle.init("zzz"), runtime.signal_kill, &diag),
    );
}

test "a normal stop is done at once; a slow stop takes the grace period, then the kill" {
    // Goal: the stop semantics written at the top of the file. Method: stop a polite container,
    // then a `slow_stop` one, and move the clock across its grace period.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 1, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const one = labels_of.one("a-1");
    const two = labels_of.one("a-2");
    _ = try rt.start(&spec_for("a-1", "b3:51aa9c03", &one), &diag);
    _ = try rt.start(&spec_for("a-2", "b3:51aa9c03", &two), &diag);
    const first = runtime.Handle.init("a-1");
    const second = runtime.Handle.init("a-2");
    try rt.stop(first, 5000, &diag);
    try testing.expectEqual(@as(u8, 15), (try rt.inspect(first, &diag)).stopped.signaled);

    try sim.inject("a-2", .slow_stop);
    try rt.stop(second, 5000, &diag);
    try testing.expect((try rt.inspect(second, &diag)) == .running);
    manual.advance(4999);
    try testing.expect((try rt.inspect(second, &diag)) == .running);
    manual.advance(1);
    try testing.expectEqual(@as(u8, 9), (try rt.inspect(second, &diag)).stopped.signaled);
    try rt.stop(second, 0, &diag); // Stopping a stopped container does nothing.

    try testing.expectError(error.NotFound, rt.stop(runtime.Handle.init("zzz"), 0, &diag));
    try testing.expectEqual(@import("diag/codes.zig").Code.E0501, diag.code.?);
}

test "the same seed gives the same faults, and time moves only with the clock" {
    // Goal: determinism, the property the simulation rests on. Method: two runtimes with one
    // seed and the same starts produce the same random faults in the same order.
    var results: [2][8]?Injected = undefined;
    for (&results) |*result| {
        var manual: ManualClock = .{};
        var sim: SimRuntime = undefined;
        sim.init(testing.allocator, manual.clock(), 42, &default_fixtures);
        defer sim.deinit();
        var diag: Diag = undefined;
        diag.reset();
        for (0..8) |index| {
            var name_buffer: [8]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "c-{d}", .{index});
            const labels = labels_of.one(name);
            _ = try sim.interface().start(&spec_for(name, "b3:51aa9c03", &labels), &diag);
        }
        for (result) |*slot| slot.* = sim.random_fault();
    }
    for (results[0], results[1]) |left, right| {
        try testing.expect(std.meta.eql(left.?.fault, right.?.fault));
        try testing.expect(left.?.handle.eql(&right.?.handle));
    }
}

test "a listing stays valid after a later start evicts the container it describes" {
    // Goal: regression for a use-after-free found by the fuzz at about a thousand operations:
    // `list` copied the label array but not its strings, so evicting a stopped container (the
    // runtime holds at most 512) freed what the caller's listing still pointed at. Method: fill
    // the runtime with stopped containers, list, start one more, and read the oldest listing.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 1, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    var name_buffer: [16]u8 = undefined;
    for (0..constants.runtime_handles_max) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "c-{d}", .{index});
        const labels = labels_of.one(name);
        _ = try rt.start(&spec_for(name, "b3:51aa9c03", &labels), &diag);
        try sim.inject(name, .{ .exit = 0 });
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const listed = try rt.list(arena_state.allocator(), &diag);
    try testing.expectEqual(@as(usize, constants.runtime_handles_max), listed.len);
    const extra = labels_of.one("extra-1");
    _ = try rt.start(&spec_for("extra-1", "b3:51aa9c03", &extra), &diag);
    try testing.expectEqualStrings(runtime.label_replica, listed[0].labels[0].key);
    try testing.expectEqualStrings("c-0", listed[0].labels[0].value);
}

test "a relay's listener is open while its container runs and closed by every ending" {
    // Goal: the model of B3 slice 3: opened at start, closed by every ending (exit, signal, a
    // stop, a lost supervisor), gone with a wiped disk, and `relay_problem` silent throughout.
    // Method: five relayed containers and one without, end four ways, look after each.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 3, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const names = [_][]const u8{ "r-1", "r-2", "r-3", "r-4", "r-5", "plain" };
    for (names) |name| {
        const labels = labels_of.one(name);
        var spec = spec_for(name, "b3:51aa9c03", &labels);
        if (!std.mem.eql(u8, name, "plain")) {
            spec.relay = "127.0.0.1:9";
            spec.network = .loopback;
        }
        _ = try rt.start(&spec, &diag);
    }
    try testing.expectEqual(@as(u32, 5), sim.relay_open_count());
    try testing.expect(sim.relay_problem() == null);
    try sim.inject("r-1", .{ .exit = 0 });
    try sim.inject("r-2", .supervisor_died);
    try rt.stop(runtime.Handle.init("r-3"), 0, &diag);
    try rt.signal(runtime.Handle.init("r-4"), runtime.signal_kill, &diag);
    try testing.expectEqual(@as(u32, 1), sim.relay_open_count());
    try testing.expect(sim.relay_problem() == null);
    try testing.expectEqual(@as(u32, 5), sim.relays_opened);
    try testing.expectEqual(@as(u32, 4), sim.relays_closed);
    sim.wipe();
    try testing.expectEqual(@as(u32, 0), sim.relay_open_count());
    try testing.expectEqual(@as(u32, 5), sim.relays_closed);
}

test "a listener left open on a stopped or forgotten container is a problem" {
    // Goal: the check's teeth at the unit level. Method: open a listener by hand on a stopped
    // container (what the `relay_leak` tooth does), see R1; forget one, see the sticky R1; and a
    // running relayed container with its listener closed is R3.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 3, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    const labels = labels_of.one("r-1");
    var spec = spec_for("r-1", "b3:51aa9c03", &labels);
    spec.relay = "127.0.0.1:9";
    spec.network = .loopback;
    _ = try rt.start(&spec, &diag);
    sim.containers.items[0].relay_open = false;
    try testing.expect(std.mem.startsWith(u8, sim.relay_problem().?, "R3"));
    sim.containers.items[0].relay_open = true;
    try sim.inject("r-1", .{ .exit = 0 });
    sim.containers.items[0].relay_open = true; // The leak.
    try testing.expect(std.mem.startsWith(u8, sim.relay_problem().?, "R1"));
    sim.evict("r-1");
    try testing.expect(sim.relay_forgotten);
    try testing.expect(std.mem.startsWith(u8, sim.relay_problem().?, "R1"));
}

test "a stop closes relayed connections at once; one left open past the bound is R7" {
    // Goal: R7 at the unit level (B4 slice 3 fixes). Method: a slow-stopping relayed container
    // with connections is told to stop; its connections close at once and R7 stays silent. Then
    // a second one whose connections are put back by hand after the stop (what `relay_stop_leak`
    // does): R7 once the bound has passed, and sticky after the grace ends the container.
    var manual: ManualClock = .{};
    var sim: SimRuntime = undefined;
    sim.init(testing.allocator, manual.clock(), 3, &default_fixtures);
    defer sim.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const rt = sim.interface();
    for ([_][]const u8{ "r-1", "r-2" }) |name| {
        const labels = labels_of.one(name);
        var spec = spec_for(name, "b3:51aa9c03", &labels);
        spec.relay = "127.0.0.1:9";
        spec.network = .loopback; // A relayed run has the loopback only (B4 slice 2).
        _ = try rt.start(&spec, &diag);
        try sim.inject(name, .slow_stop);
    }
    sim.containers.items[0].conns = 2;
    try rt.stop(runtime.Handle.init("r-1"), 5000, &diag);
    try testing.expectEqual(@as(u32, 0), sim.containers.items[0].conns);
    manual.advance(5000);
    try testing.expect(sim.stop_conns_problem() == null);

    try rt.stop(runtime.Handle.init("r-2"), 5000, &diag);
    sim.containers.items[1].conns = 1; // The leak.
    manual.advance(relay_cancel_ms_max);
    try testing.expect(sim.stop_conns_problem() == null);
    manual.advance(1);
    try testing.expect(std.mem.startsWith(u8, sim.stop_conns_problem().?, "R7"));
    manual.advance(5000);
    try testing.expect((try rt.inspect(runtime.Handle.init("r-2"), &diag)) == .stopped);
    try testing.expect(sim.conns_late);
    try testing.expect(std.mem.startsWith(u8, sim.stop_conns_problem().?, "R7"));
}
