//! Tests of the job controller on the memory store and a manual clock. The tests write the
//! records of the other roles themselves (the API's jobs, the scheduler's assignments, the
//! agents' reports, the node controller's judgements), so each one pins what the job controller
//! does with them and nothing of the others.

const std = @import("std");
const testing = std.testing;
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const control_plane = @import("control_plane.zig");
const controller = @import("controller.zig");
const job_controller = @import("job_controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,
    jc: job_controller.JobController,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 1761350000000 };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
        self.jc = job_controller.JobController.init(1);
        self.jc.lost_grace_ms = 1000;
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) controller.Context {
        _ = self.arena_state.reset(.retain_capacity);
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    /// One pass; the number of transactions it committed. A step that keeps its place in the
    /// jobs and asks to run again at once (`at_ms` not after now) is run again: a pass is a sweep
    /// of all the jobs, however many steps it takes.
    fn pass(self: *Fixture) !u32 {
        var acted: u32 = 0;
        for (0..64) |_| {
            const ctx = self.context();
            const wake = try self.jc.reconcile(&ctx);
            acted += wake.acted;
            if (wake.at_ms > self.manual.ms) return acted;
        }
        return error.TestUnexpectedResult;
    }

    fn put(self: *Fixture, role: writers.Role, key: []const u8, value: anytype) !void {
        const ctx = self.context();
        const bytes = try records.encode(ctx.arena, value, &self.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try writers.txn(ctx.store, role, .{ .on_success = &.{op} }, &self.diag);
        try testing.expect(done.succeeded);
    }

    fn revision_of(self: *Fixture, key: []const u8) !store.Revision {
        const ctx = self.context();
        const got = try ctx.store.get(ctx.arena, key, null, &self.diag);
        return if (got.kv) |kv| kv.mod_revision else 0;
    }

    fn job(self: *Fixture, name: []const u8, deadline_ms: u64, cancel: bool) !void {
        const value: records.Job = .{
            .name = name,
            .image = "b3:51aa9c03",
            .command = &.{"true"},
            .deadline_ms = deadline_ms,
            .submit_by_ms = self.manual.ms,
            .created_at_ms = self.manual.ms,
            .cancel_requested = if (cancel) .{ .at_ms = self.manual.ms } else null,
        };
        try self.put(.api, records.job_key(name).slice(), value);
    }

    fn read_status(self: *Fixture, name: []const u8) !?records.JobStatus {
        const ctx = self.context();
        const key = records.job_status_key(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        const kv = got.kv orelse return null;
        const value = try records.read(records.JobStatus, ctx.arena, kv, &self.diag);
        // The arena is reset by the next call: copy what the tests compare.
        var copy = value;
        copy.node = null;
        copy.diagnostic = null;
        copy.decision = null;
        return copy;
    }

    fn read_run(self: *Fixture, name: []const u8) !?records.JobRun {
        const ctx = self.context();
        const key = records.job_run_key(name);
        const got = try ctx.store.get(ctx.arena, key.slice(), null, &self.diag);
        const kv = got.kv orelse return null;
        var value = try records.read(records.JobRun, ctx.arena, kv, &self.diag);
        value.id = "";
        value.job = "";
        value.image = "";
        value.command = &.{};
        value.env = &.{};
        value.labels = &.{};
        return value;
    }

    fn endings(self: *Fixture) !u64 {
        const ctx = self.context();
        const got = try ctx.store.get(ctx.arena, records.key_job_endings, null, &self.diag);
        const kv = got.kv orelse return 0;
        return (try records.read(records.JobEndings, ctx.arena, kv, &self.diag)).ended;
    }

    /// How many decisions of `action` the job has.
    fn decisions(self: *Fixture, name: []const u8, action: []const u8) !u32 {
        const ctx = self.context();
        const prefix = records.index_prefix(.job, name);
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .limit = constants.store_list_limit_max,
        }, &self.diag);
        var count: u32 = 0;
        for (page.kvs) |kv| {
            const entry = try records.read(records.IndexEntry, ctx.arena, kv, &self.diag);
            if (std.mem.eql(u8, entry.action, action)) count += 1;
        }
        return count;
    }

    fn node(self: *Fixture, name: []const u8, state: records.NodeState) !void {
        const value: records.Node = .{
            .name = name,
            .capacity = .{ .cpu_millis = 4000, .memory_bytes = 8 << 30 },
        };
        try self.put(.{ .agent = name }, records.node_key(name).slice(), value);
        try self.node_status(name, state);
    }

    fn node_status(self: *Fixture, name: []const u8, state: records.NodeState) !void {
        const tenure = try self.revision_of(records.node_key(name).slice());
        const value: records.NodeStatus = .{
            .state = state,
            .tenure = tenure,
            .at_ms = self.manual.ms,
            .decision = "x",
        };
        try self.put(.node_controller, records.node_status_key(name).slice(), value);
    }

    fn assign(self: *Fixture, node_name: []const u8, name: []const u8) !void {
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const id = records.job_run_id(&buffer, name);
        const need: records.Requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 };
        const value = records.assigned_run(id, name, need, "test");
        const key = records.assigned_key(node_name, id);
        try self.put(.scheduler, key.slice(), value);
    }

    /// The agent's report of a run: its tenure and epoch are the store's current ones.
    fn report(
        self: *Fixture,
        node_name: []const u8,
        name: []const u8,
        status: records.JobObservedStatus,
        exit: ?records.Exit,
        stop_cause: ?records.StopCause,
    ) !void {
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const id = records.job_run_id(&buffer, name);
        const tenure = try self.revision_of(records.node_key(node_name).slice());
        const epoch = try self.revision_of(records.assigned_key(node_name, id).slice());
        const value: records.JobObserved = .{
            .run = id,
            .node = node_name,
            .tenure = tenure,
            .assignment = epoch,
            .status = status,
            .exit = exit,
            .stop_cause = stop_cause,
            .started_at_ms = if (status == .claimed) null else self.manual.ms,
            .reported_at_ms = self.manual.ms,
        };
        const key = records.job_observed_key(node_name, name);
        try self.put(.{ .agent = node_name }, key.slice(), value);
    }

    /// A job with a run and a status, as if it had been created, placed on `n1` and claimed.
    fn running(self: *Fixture, name: []const u8) !void {
        try self.node("n1", .ready);
        try self.job(name, 60 * 1000, false);
        try testing.expectEqual(@as(u32, 1), try self.pass());
        try self.assign("n1", name);
        try testing.expectEqual(@as(u32, 1), try self.pass());
        try self.report("n1", name, .claimed, null, null);
        try testing.expectEqual(@as(u32, 1), try self.pass());
        const status = (try self.read_status(name)).?;
        try testing.expectEqual(records.JobState.running, status.state);
    }

    fn delete(self: *Fixture, role: writers.Role, key: []const u8) !void {
        const ctx = self.context();
        const gone = [_]store.Op{.{ .delete = key }};
        const done = try writers.txn(ctx.store, role, .{ .on_success = &gone }, &self.diag);
        try testing.expect(done.succeeded);
    }

    /// A job that has ended, its run and its terminal status written directly, `env_bytes` of
    /// environment in each of the job and the run (the node, if any, is the one it ran on).
    fn ended(self: *Fixture, name: []const u8, env_bytes: usize, node_name: ?[]const u8) !void {
        // `put` starts the fixture's arena afresh: the filler lives apart from it.
        const filler = try testing.allocator.alloc(u8, env_bytes);
        defer testing.allocator.free(filler);
        @memset(filler, 'x');
        const env = [_]records.Pair{.{ "FILLER", filler }};
        const spec: records.Job = .{
            .name = name,
            .image = "b3:51aa9c03",
            .command = &.{"true"},
            .env = &env,
            .deadline_ms = 60 * 1000,
            .submit_by_ms = self.manual.ms,
            .created_at_ms = self.manual.ms,
        };
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const id = records.job_run_id(&buffer, name);
        const run: records.JobRun = .{
            .id = id,
            .job = name,
            .image = spec.image,
            .command = spec.command,
            .env = &env,
            .deadline_ms = spec.deadline_ms,
            .start_by_ms = self.manual.ms + 60 * 1000,
            .created_at_ms = self.manual.ms,
        };
        const status: records.JobStatus = .{
            .state = .exited,
            .node = node_name,
            .end = .{ .kind = .exited, .code = 0 },
            .ended_at_ms = self.manual.ms,
            .decision = "x",
            .reported_at_ms = self.manual.ms,
        };
        try self.put(.api, records.job_key(name).slice(), spec);
        try self.put(.job_controller, records.job_run_key(name).slice(), run);
        try self.put(.job_controller, records.job_status_key(name).slice(), status);
    }

    /// As `pass`, in an arena of exactly `buffer`, which every step starts afresh: the step must
    /// fit the bound the production arena has.
    fn pass_bounded(self: *Fixture, buffer: []u8) !u32 {
        var acted: u32 = 0;
        for (0..64) |_| {
            var fixed = std.heap.FixedBufferAllocator.init(buffer);
            const ctx: controller.Context = .{
                .store = self.memory.interface(),
                .clock = self.manual.clock(),
                .arena = fixed.allocator(),
                .diag = &self.diag,
            };
            const wake = try self.jc.reconcile(&ctx);
            acted += wake.acted;
            if (wake.at_ms > self.manual.ms) return acted;
        }
        return error.TestUnexpectedResult;
    }
};

test "a job gets its run and a pending status once, with a job_created decision" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const run = (try f.read_run("train")).?;
    try testing.expectEqual(f.manual.ms + 60 * 1000, run.start_by_ms);
    try testing.expectEqual(records.JobState.pending, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "job_created"));
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a job that has a job_created decision and no run is contradictory and never started" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    // The run and status are gone, as a restore or a hand edit would leave it.
    const ctx = f.context();
    const run_at = records.job_run_key("train");
    const status_at = records.job_status_key("train");
    const gone = [_]store.Op{ .{ .delete = run_at.slice() }, .{ .delete = status_at.slice() } };
    _ = try writers.txn(ctx.store, .job_controller, .{ .on_success = &gone }, &f.diag);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expect((try f.read_run("train")) == null);
    try testing.expect((try f.read_status("train")) == null);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_contradictory_job"));
    // Recorded once, not once a pass.
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_contradictory_job"));
}

test "a held job with no run frees its jobs_max slot once, however often it is held (#177)" {
    // Goal: a contradictory job that never had a run counts as ended, so `admitted - ended` stops
    // charging it against `jobs_max`. Method: hold it, check the count of endings is 1; a pass
    // again and a new revision of the job record (a second hold decision) leave it at 1.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(@as(u64, 0), try f.endings());
    const ctx = f.context();
    const gone = [_]store.Op{
        .{ .delete = records.job_run_key("train").slice() },
        .{ .delete = records.job_status_key("train").slice() },
    };
    _ = try writers.txn(ctx.store, .job_controller, .{ .on_success = &gone }, &f.diag);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_contradictory_job"));
    try testing.expectEqual(@as(u64, 1), try f.endings());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u64, 1), try f.endings());
    try f.job("train", 61 * 1000, false); // A new revision of the record.
    _ = try f.pass();
    try testing.expectEqual(@as(u32, 2), try f.decisions("train", "hold_contradictory_job"));
    try testing.expectEqual(@as(u64, 1), try f.endings());
}

test "a held job that has a run keeps its jobs_max slot (#177)" {
    // Goal: a run without a status might still be placed, so its slot is not released.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const ctx = f.context();
    const gone = [_]store.Op{.{ .delete = records.job_status_key("train").slice() }};
    _ = try writers.txn(ctx.store, .job_controller, .{ .on_success = &gone }, &f.diag);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_contradictory_job"));
    try testing.expectEqual(@as(u64, 0), try f.endings());
}

test "a run without a status is contradictory and changes nothing" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const ctx = f.context();
    const status_at = records.job_status_key("train");
    const gone = [_]store.Op{.{ .delete = status_at.slice() }};
    _ = try writers.txn(ctx.store, .job_controller, .{ .on_success = &gone }, &f.diag);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expect((try f.read_run("train")) != null);
    try testing.expect((try f.read_status("train")) == null);
}

test "a cancelled job that was never claimed is stopped, then ended cancelled once" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.job("train", 60 * 1000, true);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // phase one
    try testing.expect((try f.read_run("train")).?.stop != null);
    try testing.expectEqual(records.JobState.pending, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // phase two
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.cancelled, status.state);
    try testing.expectEqual(records.StopCause.cancel, status.stop_cause.?);
    try testing.expectEqual(@as(u64, 1), try f.endings());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u64, 1), try f.endings());
}

test "a run not claimed by start_by_ms ends failed deadline" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    f.manual.ms += 60 * 1000 + 1;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(records.JobFailure.deadline, status.end.?.cause.?);
}

test "a claim marks the run running and an exit ends it with its code" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 3 }, null);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.exited, status.state);
    try testing.expectEqual(@as(?u8, 3), status.end.?.code);
    try testing.expectEqual(@as(u64, 1), try f.endings());
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a cancel that raced an exit is judged by the exit" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.job("train", 60 * 1000, true);
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(records.JobState.exited, (try f.read_status("train")).?.state);
}

test "a running run that is cancelled is stopped, reports stopped cancel, and ends cancelled" {
    // Goal: the slice-3 regression: running, cancel_requested, `stop` (cancel) written, the
    // agent's `stopped`/`cancel` report, then `cancelled`, once.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.job("train", 60 * 1000, true);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // phase one: the stop
    const stop = (try f.read_run("train")).?.stop.?;
    try testing.expectEqual(records.RunStopCause.cancel, stop.cause);
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // nothing more until the agent reports
    try f.report("n1", "train", .stopped, .{ .kind = .signaled, .signal = 15 }, .cancel);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.cancelled, status.state);
    try testing.expectEqual(@as(u64, 1), try f.endings());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u64, 1), try f.endings());
}

test "a report from a node that is not ready is not believed" {
    // Goal: an admissible report needs a `ready` node (authority.md I6); a stopped report from a
    // fenced node ends nothing.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try f.node_status("n1", .fenced);
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
}

test "a report from a tenure the node no longer holds is not believed" {
    // Goal: the tenure check of admissible() (authority.md I2) on its own: the node is ready, the
    // assignment is the one reported, and only the node's record changed since the report.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try f.node("n1", .ready); // The node registered again: a new tenure, and ready.
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
}

test "a claim that is not admissible is never ended as unstarted and ends unreachable" {
    // Goal: a run its node claimed may be running. A cancel is written but the run is not ended
    // as unstarted (the claim guard); it ends `failed unreachable` once the claim's tenure has
    // been over for the grace, and does not stay `placed` for ever.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.node("n1", .ready);
    try f.job("train", 600 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.assign("n1", "train");
    try testing.expectEqual(@as(u32, 1), try f.pass()); // placed
    try f.node_status("n1", .fenced);
    try f.report("n1", "train", .claimed, null, null);
    try f.job("train", 600 * 1000, true);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // the cancel is written
    try testing.expect((try f.read_run("train")).?.stop != null);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // and the run is not ended as unstarted
    try testing.expectEqual(records.JobState.placed, (try f.read_status("train")).?.state);
    try f.node_status("n1", .lost);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // inside the grace
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(records.JobFailure.@"unreachable", status.end.?.cause.?);
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a job deleted and created again under its name gets a run" {
    // Goal: "the job ever had a run" is about this incarnation (docs/decisions/
    // 2026-11-05-b1-controller-never-recreates-a-run.md): the job_created decision of an earlier
    // job of the same name is not a contradiction.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.job("train", 60 * 1000, true);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // stop
    try testing.expectEqual(@as(u32, 1), try f.pass()); // end cancelled
    try f.delete(.api, records.job_key("train").slice());
    try f.delete(.job_controller, records.job_run_key("train").slice());
    try f.delete(.job_controller, records.job_status_key("train").slice());
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(records.JobState.pending, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 2), try f.decisions("train", "job_created"));
    try testing.expectEqual(@as(u32, 0), try f.decisions("train", "hold_contradictory_job"));
}

test "65 contradictory jobs are held once each" {
    // Goal: nothing bounds how many jobs can be contradictory at once; each is recorded once,
    // and a pass over a converged store acts on none (the old ring of 64 forgot the first).
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var names: [65][3]u8 = undefined;
    for (&names, 0..) |*name, at| {
        const tens: u8 = @intCast(at / 10);
        name.* = .{ 'j', '0' + tens, '0' + @as(u8, @intCast(at % 10)) };
    }
    for (&names) |*name| try f.job(name, 60 * 1000, false);
    try testing.expectEqual(@as(u32, 65), try f.pass());
    for (&names) |*name| {
        try f.delete(.job_controller, records.job_run_key(name).slice());
        try f.delete(.job_controller, records.job_status_key(name).slice());
    }
    try testing.expectEqual(@as(u32, 65), try f.pass());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    for (&names) |*name| {
        try testing.expectEqual(@as(u32, 1), try f.decisions(name, "hold_contradictory_job"));
    }
}

test "150 running runs on nodes that are gone all end unreachable" {
    // Goal: the controller's memory of when a tenure ended holds every live run (the old ring of
    // 128 forgot some, and their grace started again).
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const nodes = [_][]const u8{ "n1", "n2", "n3" };
    for (nodes) |name| try f.node(name, .ready);
    var names: [150][4]u8 = undefined;
    for (&names, 0..) |*name, at| {
        const hundreds: u8 = @intCast(at / 100);
        const tens: u8 = @intCast(at / 10 % 10);
        name.* = .{ 'j', '0' + hundreds, '0' + tens, '0' + @as(u8, @intCast(at % 10)) };
    }
    for (&names) |*name| try f.job(name, 600 * 1000, false);
    try testing.expectEqual(@as(u32, 150), try f.pass());
    for (&names, 0..) |*name, at| try f.assign(nodes[at % 3], name);
    try testing.expectEqual(@as(u32, 150), try f.pass()); // placed
    for (&names, 0..) |*name, at| try f.report(nodes[at % 3], name, .claimed, null, null);
    try testing.expectEqual(@as(u32, 150), try f.pass()); // running
    for (nodes) |name| try f.delete(.{ .agent = name }, records.node_key(name).slice());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 150), try f.pass());
    try testing.expectEqual(@as(u64, 150), try f.endings());
}

test "more ended jobs than jobs_max do not stop the controller" {
    // Goal: /jobs/ holds the ended jobs of the retention window, more than jobs_max; the
    // controller reads them a page at a time and still creates the run of a new job.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const count = constants.jobs_max + 90;
    for (0..count) |at| {
        var name: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "e{d:0>3}", .{at}) catch unreachable; // 4 bytes hold 3 digits.
        try f.ended(&name, 8, null);
    }
    try f.job("zz-new", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expect((try f.read_run("zz-new")) != null);
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a step over many large ended jobs fits the step's arena" {
    // Goal: the step's memory is one page of jobs, not the retention window. Each job and run
    // carries 7 KB of environment; all of them read at once would not fit 16 MiB.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const count = 600;
    for (0..count) |at| {
        var name: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "e{d:0>3}", .{at}) catch unreachable; // 4 bytes hold 3 digits.
        try f.ended(&name, 7000, null);
    }
    try f.job("zz-new", 60 * 1000, false);
    const buffer = try testing.allocator.alloc(u8, constants.request_arena_bytes_max);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(u32, 1), try f.pass_bounded(buffer));
    try testing.expectEqual(@as(u32, 0), try f.pass_bounded(buffer));
}

test "a report that arrives after the job ended is dropped with a W0307 decision" {
    // Goal: the ending is written once; a later report changes nothing and is recorded, once.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.delete(.{ .agent = "n1" }, records.node_key("n1").slice());
    try testing.expectEqual(@as(u32, 0), try f.pass());
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const cause = (try f.read_status("train")).?.end.?.cause.?;
    try testing.expectEqual(records.JobFailure.@"unreachable", cause);
    try testing.expectEqual(@as(u32, 0), try f.decisions("train", "drop_report"));
    try f.node("n1", .ready);
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "drop_report"));
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u64, 1), try f.endings());
}

test "a job whose decisions outrun the page budget is not given a second run" {
    // Goal: has_decision fails closed (I8a). The job's index holds more entries than the two
    // pages `has_decision` reads, none of them `job_created`; it is read as decided, so no run is
    // created and no hold is recorded, rather than a second run on an unknown history.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    const entries = 2 * constants.store_list_limit_max + 100;
    for (0..entries) |at| {
        const id = records.decision_id(f.manual.ms - 5000, 1, @intCast(at));
        const key = records.index_key(.job, "train", id.slice());
        const entry: records.IndexEntry = .{
            .id = id.slice(),
            .at_ms = f.manual.ms - 5000,
            .action = "other",
            .summary = "x",
        };
        try f.put(.job_controller, key.slice(), entry);
    }
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expect((try f.read_run("train")) == null);
    try testing.expectEqual(@as(u32, 0), try f.decisions("train", "hold_contradictory_job"));
}

test "orphan runs and statuses before the first job do not exhaust the step's arena" {
    // Goal: the step reads the run and status of each paged job by key, so records of no job
    // cost nothing. 1,300 orphan runs of 14 KB each (18 MB) sort before the one live job.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const filler = try testing.allocator.alloc(u8, 14_000);
    defer testing.allocator.free(filler);
    @memset(filler, 'x');
    const env = [_]records.Pair{.{ "FILLER", filler }};
    for (0..1300) |at| {
        var name: [5]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "a{d:0>4}", .{at}) catch unreachable; // 5 bytes hold 4 digits.
        var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
        const run: records.JobRun = .{
            .id = records.job_run_id(&buffer, &name),
            .job = &name,
            .image = "b3:51aa9c03",
            .command = &.{"true"},
            .env = &env,
            .deadline_ms = 60 * 1000,
            .start_by_ms = f.manual.ms + 60 * 1000,
            .created_at_ms = f.manual.ms,
        };
        try f.put(.job_controller, records.job_run_key(&name).slice(), run);
    }
    try f.job("zz-new", 60 * 1000, false);
    const buffer = try testing.allocator.alloc(u8, constants.request_arena_bytes_max);
    defer testing.allocator.free(buffer);
    try testing.expectEqual(@as(u32, 1), try f.pass_bounded(buffer));
    try testing.expect((try f.read_run("zz-new")) != null);
}

test "a job added behind the cursor between steps gets its run within two more steps" {
    // Goal: a resumed step that reaches the end asks to run again at once, because the jobs
    // before the cursor were not judged by this sweep. Method: more jobs than one step's
    // transactions, one step, then job `a` (it sorts before the cursor).
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const total = constants.controller_txns_per_step_max + 3;
    for (0..total) |at| {
        var name: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "b{d:0>3}", .{at}) catch unreachable; // 4 bytes hold 3 digits.
        try f.job(&name, 60 * 1000, false);
    }
    const first = try f.jc.reconcile(&f.context());
    try testing.expectEqual(constants.controller_txns_per_step_max, first.acted);
    try f.job("a", 60 * 1000, false);
    const second = try f.jc.reconcile(&f.context());
    try testing.expectEqual(@as(u32, 3), second.acted);
    try testing.expect(second.at_ms <= f.manual.ms);
    _ = try f.jc.reconcile(&f.context());
    try testing.expect((try f.read_run("a")) != null);
}

/// One pass of the whole control plane, the way the server runs it.
fn plane_pass(f: *Fixture, plane: *control_plane.ControlPlane) !void {
    const ctx = f.context();
    _ = try plane.reconcile(&ctx);
    f.manual.advance(10);
}

/// A step of the scheduler and the job controller only (no node controller to judge the test's
/// hand-written nodes).
fn jobs_pass(f: *Fixture, plane: *control_plane.ControlPlane) !void {
    const ctx = f.context();
    _ = try plane.scheduler.reconcile(&ctx);
    const again = f.context();
    _ = try plane.jobs.reconcile(&again);
    f.manual.advance(10);
}

fn replica_count(f: *Fixture, service: []const u8) !usize {
    const ctx = f.context();
    const found = try controller.list_all(
        records.Replica,
        &ctx,
        records.replicas_prefix(service).slice(),
        null,
        constants.replicas_max,
    );
    return found.items.len;
}

/// Applies a three-replica service, then runs the whole plane: all three replicas must exist
/// after it, however the job records look (RB-S7: one corrupt record stops no one else).
fn replicas_still_reconcile(f: *Fixture, plane: *control_plane.ControlPlane) !void {
    var api: controller.DecisionSource = .{ .instance = 0 };
    const ctx = f.context();
    const result = try apply_mod.apply(&ctx, &api, .{
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 3,
        .command = &.{"true"},
        .applied_by = "alex@laptop",
        .request_id = "r-0001a4f",
    });
    try testing.expect(result == .written);
    for (0..6) |_| try plane_pass(f, plane);
    try testing.expectEqual(@as(usize, 3), try replica_count(f, "hello"));
}

fn corrupt(f: *Fixture, role: writers.Role, key: []const u8) !void {
    const ctx = f.context();
    const bad = [_]store.Op{.{ .put = .{ .key = key, .value = "{no" } }};
    _ = try writers.txn(ctx.store, role, .{ .on_success = &bad }, &f.diag);
}

test "a status that does not decode leaves the replicas reconciling (RB-S7, scheduler)" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var plane = control_plane.ControlPlane.init(2);
    try f.job("a", 60 * 1000, false);
    _ = try f.pass();
    try corrupt(&f, .job_controller, records.job_status_key("a").slice());
    try replicas_still_reconcile(&f, &plane);
    try testing.expectEqual(@as(u32, 1), try f.decisions("a", "hold_unreadable_job"));
}

test "a run that does not decode leaves the replicas reconciling (RB-S7, place_run)" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var plane = control_plane.ControlPlane.init(2);
    try f.node("n1", .ready);
    try f.job("a", 60 * 1000, false);
    _ = try f.pass();
    try corrupt(&f, .job_controller, records.job_run_key("a").slice());
    try replicas_still_reconcile(&f, &plane);
    try testing.expectEqual(@as(u32, 1), try f.decisions("a", "hold_unreadable_job"));
}

test "a report that does not decode leaves the replicas reconciling (RB-S7, claim)" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var plane = control_plane.ControlPlane.init(2);
    try f.running("train");
    try corrupt(&f, .{ .agent = "n1" }, records.job_observed_key("n1", "train").slice());
    try replicas_still_reconcile(&f, &plane);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unreadable_job"));
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
}

test "a running run whose report does not decode still takes a cancel and a lost node" {
    // Goal: #175 re-review. An unreadable report holds the run (the hold decision, once) but not
    // for ever. Method: `train` runs on n1, its report is corrupted, then the job is cancelled:
    // the stop is written though the report is unreadable. The node is then lost: inside the grace
    // nothing changes; past it the run ends `failed unreachable`, which the earlier code (it
    // returned at the hold) never wrote.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try corrupt(&f, .{ .agent = "n1" }, records.job_observed_key("n1", "train").slice());
    try testing.expectEqual(@as(u32, 1), try f.pass()); // the hold decision
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unreadable_job"));
    try f.job("train", 60 * 1000, true);
    f.manual.ms += 3600 * 1000;
    try testing.expectEqual(@as(u32, 1), try f.pass()); // the cancel's stop
    try testing.expectEqual(records.RunStopCause.cancel, (try f.read_run("train")).?.stop.?.cause);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // the node is alive: the run waits
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
    try f.node_status("n1", .lost);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // inside the grace
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(records.JobFailure.@"unreachable", status.end.?.cause.?);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unreadable_job"));
}

test "a claimed run whose report does not decode ends failed unknown when its node is lost" {
    // Goal: the same, for a run not yet marked running. Method: n1 claimed `train`, the claim is
    // then corrupted. Nothing readable says whether it started, so a cancel writes the stop and
    // the lost node ends the run `failed unknown` (RB-S8), never `cancelled` or `not started`.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.node("n1", .ready);
    try f.job("train", 600 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.assign("n1", "train");
    try testing.expectEqual(@as(u32, 1), try f.pass()); // placed
    try f.report("n1", "train", .claimed, null, null);
    try corrupt(&f, .{ .agent = "n1" }, records.job_observed_key("n1", "train").slice());
    try testing.expectEqual(@as(u32, 1), try f.pass()); // the hold decision
    try f.job("train", 600 * 1000, true);
    try testing.expectEqual(@as(u32, 1), try f.pass()); // the cancel's stop
    try testing.expect((try f.read_run("train")).?.stop != null);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // node ready: not ended as unstarted
    try testing.expectEqual(records.JobState.placed, (try f.read_status("train")).?.state);
    try f.node_status("n1", .lost);
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(records.JobFailure.unknown, status.end.?.cause.?);
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a late report that does not decode leaves the replicas reconciling (RB-S7)" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var plane = control_plane.ControlPlane.init(2);
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(records.JobState.exited, (try f.read_status("train")).?.state);
    try corrupt(&f, .{ .agent = "n1" }, records.job_observed_key("n1", "train").slice());
    try replicas_still_reconcile(&f, &plane);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unreadable_job"));
}

test "an unmappable report is held once, and a cancel ends the job and frees its node" {
    // Goal: RB-S8. Method: the plane places a job's run on n1 and its agent reports `stopped`
    // with an exit that maps to no ending (neither code nor signal); the job is then cancelled.
    // The report is held with one decision, the cancel's stop is written, the run ends `failed
    // unknown` (the agent never reports again) and the scheduler releases its allocation.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    var plane = control_plane.ControlPlane.init(2);
    try f.node("n1", .ready);
    try f.job("train", 60 * 1000, false);
    for (0..3) |_| try jobs_pass(&f, &plane);
    var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    const id = records.job_run_id(&buffer, "train");
    const assigned = records.assigned_key("n1", id);
    try testing.expect(try f.revision_of(assigned.slice()) != 0);
    try f.report("n1", "train", .claimed, null, null);
    for (0..2) |_| try jobs_pass(&f, &plane);
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
    try f.report("n1", "train", .stopped, .{ .kind = .exited }, null);
    for (0..2) |_| try jobs_pass(&f, &plane);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unmapped_ending"));
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
    try f.job("train", 60 * 1000, true);
    for (0..4) |_| try jobs_pass(&f, &plane);
    const stop = (try f.read_run("train")).?.stop orelse return error.TestUnexpectedResult;
    try testing.expectEqual(records.RunStopCause.cancel, stop.cause);
    const ended = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, ended.state);
    try testing.expectEqual(records.JobFailure.unknown, ended.end.?.cause.?);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold_unmapped_ending"));
    try testing.expectEqual(@as(u64, 0), try f.revision_of(assigned.slice()));
    const ctx = f.context();
    const alloc = try ctx.store.get(ctx.arena, records.allocation_key("n1").slice(), null, &f.diag);
    if (alloc.kv) |kv| {
        const rec = try records.read(records.Allocation, ctx.arena, kv, &f.diag);
        try testing.expectEqual(@as(u32, 0), rec.count);
    }
}

test "no two controllers of any instance share a decision source" {
    // Goal: RB-N6. Method: every instance a server can be given, five sources each; a source seen
    // twice would let two roles write the same decision id in one millisecond.
    var seen = try testing.allocator.alloc(bool, 1 << 16);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var instance: u32 = 1;
    while (instance <= constants.controller_instance_max) : (instance += 1) {
        const plane = control_plane.ControlPlane.init(@intCast(instance));
        const sources = [_]u16{
            plane.nodes.source.instance,
            plane.replicas.source.instance,
            plane.scheduler.source.instance,
            plane.auditor.source.instance,
            plane.jobs.source.instance,
        };
        for (sources) |source| {
            try testing.expect(!seen[source]);
            seen[source] = true;
        }
    }
}

test "the instance a server takes from its clock is one every controller can use" {
    var second: u64 = 0;
    while (second < 3 * constants.controller_instance_max) : (second += 7) {
        const instance = control_plane.ControlPlane.instance_from(second * 1000);
        try testing.expect(instance >= 1 and instance <= constants.controller_instance_max);
    }
}

test "a job record that does not decode is held once and the other jobs go on" {
    // Goal: RB-S7. Method: `a` holds bytes that are no job; `b` is a healthy new job after it.
    // The step must not fail: `b` gets its run, `a` gets one hold decision (not one per pass).
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    const ctx = f.context();
    const bad = [_]store.Op{.{ .put = .{ .key = records.job_key("a").slice(), .value = "{no" } }};
    _ = try writers.txn(ctx.store, .api, .{ .on_success = &bad }, &f.diag);
    try f.job("b", 60 * 1000, false);
    _ = try f.pass();
    try testing.expect((try f.read_run("b")) != null);
    try testing.expect((try f.read_run("a")) == null);
    try testing.expectEqual(@as(u32, 1), try f.decisions("a", "hold_unreadable_job"));
    _ = try f.pass();
    try testing.expectEqual(@as(u32, 1), try f.decisions("a", "hold_unreadable_job"));
}

test "a run record that does not decode holds its job and not the others" {
    // Goal: RB-S7, the run record of a job. Method: `a` is a good job whose run is garbage.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("a", 60 * 1000, false);
    try f.job("b", 60 * 1000, false);
    const ctx = f.context();
    const key = records.job_run_key("a");
    const bad = [_]store.Op{.{ .put = .{ .key = key.slice(), .value = "{no" } }};
    _ = try writers.txn(ctx.store, .job_controller, .{ .on_success = &bad }, &f.diag);
    _ = try f.pass();
    try testing.expect((try f.read_run("b")) != null);
    try testing.expectEqual(@as(u32, 1), try f.decisions("a", "hold_unreadable_job"));
}

// A store that applies `race_ops` just before the first transaction it is given: a change made
// by another role between a step's read and its commit.
var race_inner: ?store.Store = null;
var race_ops: []const store.Op = &.{};

fn race_txn(
    context: *anyopaque,
    request: store.TxnRequest,
    diag: *Diag,
) store.Error!store.TxnResult {
    const inner = race_inner.?;
    if (race_ops.len > 0) {
        const ops = race_ops;
        race_ops = &.{};
        _ = try inner.vtable.txn(context, .{ .on_success = ops }, diag);
    }
    return inner.vtable.txn(context, request, diag);
}

/// One `reconcile` whose first commit is preceded by `ops`; the transactions it committed.
fn racing(f: *Fixture, ops: []const store.Op) !u32 {
    const ctx = f.context();
    var table = ctx.store.vtable.*;
    table.txn = race_txn;
    race_inner = ctx.store;
    race_ops = ops;
    var racy = ctx;
    racy.store = .{ .context = ctx.store.context, .vtable = &table };
    const wake = try f.jc.reconcile(&racy);
    race_inner = null;
    race_ops = &.{};
    return wake.acted;
}

test "a claim is not marked running when its assignment is gone by the commit (RB-S11)" {
    // Goal: the read-set rule for mark_running. Method: a claimed run; the scheduler deletes its
    // assignment after the step read it. The status must stay `placed`.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.node("n1", .ready);
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.assign("n1", "train");
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.report("n1", "train", .claimed, null, null);
    const key = records.assigned_key("n1", "train-job");
    const gone = [_]store.Op{.{ .delete = key.slice() }};
    try testing.expectEqual(@as(u32, 0), try racing(&f, &gone));
    try testing.expectEqual(records.JobState.placed, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 0), try f.decisions("train", "job_running"));
}

test "a stop is not written when a report of the run appeared by the commit (RA-N6)" {
    // Goal: the read-set rule for write_stop, which judged "no claim" from the report's absence.
    // Method: an unclaimed placed run, a cancel, and a report written after the step read.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.node("n1", .ready);
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.assign("n1", "train");
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.job("train", 60 * 1000, true);
    const key = records.job_observed_key("n1", "train");
    const seen = [_]store.Op{.{ .put = .{ .key = key.slice(), .value = "{}" } }};
    try testing.expectEqual(@as(u32, 0), try racing(&f, &seen));
    try testing.expect((try f.read_run("train")).?.stop == null);
}

test "an ending is not written when the node's judgement changed by the commit (RB-N5)" {
    // Goal: the read-set rule for end. Method: a running run whose agent reported it stopped;
    // the node's judgement is deleted after the step read it.
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    const gone = [_]store.Op{.{ .delete = records.node_status_key("n1").slice() }};
    try testing.expectEqual(@as(u32, 0), try racing(&f, &gone));
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
}
