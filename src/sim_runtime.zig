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
//! that fails with `ZBX-E0501`, "image not found", blamed on the user. Zigbox's registry has no
//! such code yet; it is the placeholder HANDOFF asks for (docs/runtime-codes.md).
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

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const Clock = @import("clock.zig").Clock;
const diag_mod = @import("diag.zig");
const runtime = @import("runtime.zig");

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
    ignores_stop: bool,
};

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

    const vtable: runtime.Runtime.VTable = .{
        .start = start_impl,
        .stop = stop_impl,
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

    /// Containers that have not stopped.
    pub fn running_count(self: *const SimRuntime) u32 {
        var count: u32 = 0;
        for (self.containers.items) |container| {
            if (container.phase != .stopped) count += 1;
        }
        return count;
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
        self.record(.{ .handle = runtime.Handle.init(container.name), .ended = ended });
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
            .stopped => |ended| .{ .stopped = exit_reason(ended) },
        };
    }

    fn exit_reason(ended: Ended) runtime.ExitReason {
        return switch (ended) {
            .exited => |code| .{ .exited = code },
            .signaled => |number| .{ .signaled = number },
            .oom => .oom,
            .pid_limit => .pid_limit,
            .lost => .{ .lost = null },
        };
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
        return .{ .started = runtime.Handle.init(spec.name) };
    }

    fn has_image(self: *const SimRuntime, image: []const u8) bool {
        for (self.fixtures) |digest| {
            if (std.mem.eql(u8, digest, image)) return true;
        }
        return false;
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
        };
    }

    fn remove(self: *SimRuntime, container: *Container) void {
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
                if (!container.ignores_stop) return self.end(container, .{ .signaled = 15 });
                if (grace_ms == 0) return self.end(container, .{ .signaled = 9 });
                container.phase = .{ .stopping = now + grace_ms };
            },
            .stopping => |deadline| {
                if (now + grace_ms < deadline) container.phase = .{ .stopping = now + grace_ms };
                if (grace_ms == 0) self.end(container, .{ .signaled = 9 });
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
            const labels = arena.dupe(runtime.Label, container.labels) catch
                return no_memory(diag);
            listing.* = .{
                .handle = runtime.Handle.init(container.name),
                .labels = labels,
                .status = status_of(container),
            };
        }
        return listings;
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
                .{ .stopped = exit_reason(ended) }
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
/// `ZBX-E0501`, with the digest shortened as its example shows (in ASCII: diagnostics are).
pub fn image_not_found(out: *Diagnostic, name: []const u8, image: []const u8) void {
    var short_buffer: [32]u8 = undefined;
    var image_buffer: [constants.image_digest_bytes_max]u8 = undefined;
    var name_buffer: [runtime.name_bytes_max]u8 = undefined;
    const short = shorten(&short_buffer, image);
    const safe_image = sanitise(&image_buffer, image);
    const safe_name = sanitise(&name_buffer, name);
    var json_buffer: [1024]u8 = undefined;
    const format = "{{\"code\":\"ZBX-E0501\",\"severity\":\"error\",\"blame\":\"user\"," ++
        "\"summary\":\"image not found\"," ++
        "\"causes\":[\"digest {s} is not in this node's store\"]," ++
        "\"while\":[\"starting container {s}\"]," ++
        "\"context\":{{\"image\":\"{s}\"}}," ++
        "\"fixes\":[{{\"sentence\":\"check the digest in the service file, or pull the image " ++
        "first\",\"command\":null}}]," ++
        "\"omitted\":{{\"causes\":0,\"while\":0,\"context\":0,\"fixes\":0}}}}";
    const json = std.fmt.bufPrint(&json_buffer, format, .{ short, safe_name, safe_image });
    // Cannot fail: the longest result is under 600 bytes, and the buffer holds 1024.
    // Cannot fail: `json` is the format above with sanitised text, which is well formed.
    zigbox.diagnostic.parse_json(out, json catch unreachable) catch unreachable;
    out.set_docs(&zigbox.product.Product.zbx);
    assert(std.mem.eql(u8, out.code.slice(), "ZBX-E0501"));
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

test "a digest in the fixtures starts, and one that is not fails with ZBX-E0501" {
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
    try testing.expectEqualStrings("ZBX-E0501", failure.code.slice());
    try testing.expectEqualStrings("image not found", failure.summary.slice());
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
    try testing.expect(listed[3].status.stopped.lost == null);
    try testing.expect(listed[4].status.stopped == .pid_limit);
    try testing.expectEqualStrings("a-1", listed[0].labels[0].value[0..3]);
    const changes = try rt.events(arena_state.allocator(), 0, &diag);
    try testing.expectEqual(@as(usize, 5), changes.len);
    try testing.expectEqual(@as(usize, 0), (try rt.events(arena_state.allocator(), 0, &diag)).len);
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
