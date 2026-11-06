//! Tests of the job controller on the memory store and a manual clock. The tests write the
//! records of the other roles themselves (the API's jobs, the scheduler's assignments, the
//! agents' reports, the node controller's judgements), so each one pins what the job controller
//! does with them and nothing of the others.

const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
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

    /// One pass; the number of transactions it committed.
    fn pass(self: *Fixture) !u32 {
        const ctx = self.context();
        return (try self.jc.reconcile(&ctx)).acted;
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
};

test "a job gets its run and a pending status once, with a job-created decision" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.job("train", 60 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const run = (try f.read_run("train")).?;
    try testing.expectEqual(f.manual.ms + 60 * 1000, run.start_by_ms);
    try testing.expectEqual(records.JobState.pending, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "job-created"));
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "a job that has a job-created decision and no run is contradictory and never started" {
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
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold-contradictory-job"));
    // Recorded once, not once a pass.
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold-contradictory-job"));
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

test "a report from a node that is not ready, or from an old tenure, is not believed" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited, .code = 0 }, null);
    try f.node_status("n1", .fenced);
    try testing.expectEqual(@as(u32, 0), try f.pass());
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
}

test "a running run whose node is gone is failed unreachable after the grace" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    const ctx = f.context();
    const node_at = records.node_key("n1");
    const gone = [_]store.Op{.{ .delete = node_at.slice() }};
    _ = try writers.txn(ctx.store, .{ .agent = "n1" }, .{ .on_success = &gone }, &f.diag);
    try testing.expectEqual(@as(u32, 0), try f.pass()); // seen now
    f.manual.ms += 500;
    try testing.expectEqual(@as(u32, 0), try f.pass());
    f.manual.ms += 600;
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobState.failed, status.state);
    try testing.expectEqual(records.JobFailure.@"unreachable", status.end.?.cause.?);
}

test "a placed run whose node is lost is stopped, then ended failed not_started" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.node("n1", .ready);
    try f.job("train", 600 * 1000, false);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try f.assign("n1", "train");
    try testing.expectEqual(@as(u32, 1), try f.pass()); // placed
    try testing.expectEqual(records.JobState.placed, (try f.read_status("train")).?.state);
    try f.node_status("n1", .lost);
    f.manual.ms += 1001;
    try testing.expectEqual(@as(u32, 1), try f.pass()); // stop
    try testing.expectEqual(@as(u32, 1), try f.pass()); // end
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobFailure.not_started, status.end.?.cause.?);
}

test "a fence report from a newer tenure ends a running run failed fenced" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    // The agent comes back under a new tenure and says it fenced the run it held.
    const old_epoch = (try f.read_status("train")).?.epoch.?;
    try f.node("n1", .ready);
    const tenure = try f.revision_of(records.node_key("n1").slice());
    const value: records.JobObserved = .{
        .run = "train-job",
        .node = "n1",
        .tenure = tenure,
        .assignment = old_epoch,
        .status = .stopped,
        .exit = .{ .kind = .signaled, .signal = 9 },
        .stop_cause = .fence,
        .reported_at_ms = f.manual.ms,
    };
    try f.put(.{ .agent = "n1" }, records.job_observed_key("n1", "train").slice(), value);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    const status = (try f.read_status("train")).?;
    try testing.expectEqual(records.JobFailure.fenced, status.end.?.cause.?);
}

test "an exit that maps to no ending is B0004 and leaves the job as it was" {
    var f: Fixture = undefined;
    try f.start();
    defer f.stop();
    try f.running("train");
    try f.report("n1", "train", .stopped, .{ .kind = .exited }, null);
    try testing.expectEqual(@as(u32, 1), try f.pass());
    try testing.expectEqual(records.JobState.running, (try f.read_status("train")).?.state);
    try testing.expectEqual(@as(u32, 1), try f.decisions("train", "hold-unmapped-ending"));
    try testing.expectEqual(@as(u32, 0), try f.pass());
}

test "the ending table follows the stop cause before the exit" {
    const killed: records.JobObserved = .{
        .run = "x-job",
        .node = "n",
        .tenure = 1,
        .assignment = 1,
        .status = .stopped,
        .exit = .{ .kind = .signaled, .signal = 15 },
        .stop_cause = .cancel,
        .reported_at_ms = 0,
    };
    try testing.expectEqual(records.JobState.cancelled, job_controller.map_ending(&killed).?.state);
    var oom = killed;
    oom.stop_cause = null;
    oom.exit = .{ .kind = .oom };
    try testing.expectEqual(records.JobFailure.oom, job_controller.map_ending(&oom).?.end.cause.?);
    oom.exit = .{ .kind = .lost };
    try testing.expectEqual(
        records.JobFailure.unknown,
        job_controller.map_ending(&oom).?.end.cause.?,
    );
    oom.exit = .{ .kind = .signaled, .signal = 9 };
    try testing.expectEqual(@as(?u8, 9), job_controller.map_ending(&oom).?.end.signal);
    oom.exit = .{ .kind = .signaled };
    try testing.expect(job_controller.map_ending(&oom) == null);
}
