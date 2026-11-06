//! Retention of ended jobs (docs/briefs/b1.md, "Retention and logs"; authority.md §7): a job that
//! ended more than `Cursor.age_ms` ago loses its records, and a job that has ended loses its
//! input at once.
//!
//! A pass reads every `/job-status/` record at one revision (at most `pages_max` pages: a
//! window holds at most `job_admitted_window_max` jobs) and the `/job-input/` keys, and keeps the
//! ended jobs. Of those whose ending is older than the age it deletes the oldest first, at most
//! `retention_batch_pairs` a pass, each job's `/jobs`, `/job-runs`, `/job-status`,
//! `/job-observed/<node>` and `/job-input` records in one transaction (`writers.retention_only`;
//! the spec goes with its run, so the controller never runs the job again, I8a). A pass then
//! deletes the input of up to as many ended jobs that still have one. If either had more to do, the
//! next pass is due at once, else a full `retention_interval_ms` on.
//!
//! The age never goes below `job_finished_age_ms_min` (`Cursor.age`): a client that was away for
//! an hour must find every ending in the list, and a retried POST finds its job (b1.md). The
//! delete compares the status's `mod_revision`, so a record that changed since the read stays.
//! Fail safe: a status that does not parse is kept, never counted as old. A name is free again
//! after the delete. Core code; the role is `retention`.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const failures = @import("store_failures.zig");
const store = @import("store.zig");

const Batch = controller.Batch;
const Context = controller.Context;
const Error = controller.Error;

/// Pages of `/job-status/` a pass reads: past `job_admitted_window_max` plus the jobs in flight.
const pages_max: u32 = 64;

pub const Cursor = struct {
    due_ms: u64 = 0,
    /// How old an ending must be before its job is deleted. A parameter for tests and the
    /// simulation; `age` clamps it to the floor.
    age_ms: u64 = constants.job_finished_age_ms_max,
    /// Jobs deleted whole, and inputs deleted alone, counted when the delete went in.
    dropped: u64 = 0,
    inputs_dropped: u64 = 0,
    failing: bool = false,
    failures: u64 = 0,
    failure: diag_mod.Diag = undefined,

    /// The age in force: never below `job_finished_age_ms_min`.
    pub fn age(cursor: *const Cursor) u64 {
        return @max(cursor.age_ms, constants.job_finished_age_ms_min);
    }
};

/// `prune` that never fails its step: a failed pass is recorded in `cursor` and retried after
/// `retention_interval_ms`, its diagnostic moved out of `ctx`.
pub fn prune_or_back_off(ctx: *const Context, cursor: *Cursor, now_ms: u64) u64 {
    assert(ctx.diag.code == null);
    if (prune(ctx, cursor, now_ms)) |due| {
        cursor.failing = false;
        return due;
    } else |_| {
        assert(ctx.diag.code != null); // Every failure of the store or a record is coded.
        cursor.failing = true;
        cursor.failures += 1;
        cursor.failure = ctx.diag.*;
        ctx.diag.reset();
        return now_ms + constants.retention_interval_ms;
    }
}

const Ended = struct {
    name: []const u8,
    status_revision: store.Revision,
    ended_at_ms: u64,
    node: ?[]const u8,
    has_input: bool = false,
};

/// One pass; returns when the next is due.
pub fn prune(ctx: *const Context, cursor: *Cursor, now_ms: u64) Error!u64 {
    assert(cursor.age() >= constants.job_finished_age_ms_min);
    const revision = (try ctx.store.status(ctx.diag)).revision;
    var ended: std.ArrayList(Ended) = .empty;
    try read_ended(ctx, revision, &ended);
    try mark_inputs(ctx, revision, ended.items);
    const Rank = struct {
        fn older(_: void, first: Ended, second: Ended) bool {
            if (first.ended_at_ms != second.ended_at_ms) {
                return first.ended_at_ms < second.ended_at_ms;
            }
            return std.mem.lessThan(u8, first.name, second.name);
        }
    };
    std.mem.sort(Ended, ended.items, {}, Rank.older);
    var more = false;
    var dropped: u32 = 0;
    for (ended.items) |job| {
        const old = now_ms > job.ended_at_ms and now_ms - job.ended_at_ms > cursor.age();
        if (!old) break; // Sorted: nothing after this one is older.
        if (dropped == constants.retention_batch_pairs) {
            more = true;
            break;
        }
        try drop_job(ctx, cursor, job);
        dropped += 1;
    }
    var inputs: u32 = 0;
    for (ended.items) |job| {
        if (!job.has_input) continue;
        const old = now_ms > job.ended_at_ms and now_ms - job.ended_at_ms > cursor.age();
        if (old) continue; // Gone with its job, above or on the next pass.
        if (inputs == constants.retention_batch_pairs) {
            more = true;
            break;
        }
        try drop_input(ctx, cursor, job.name);
        inputs += 1;
    }
    if (more) return now_ms;
    return now_ms + constants.retention_interval_ms;
}

fn read_ended(
    ctx: *const Context,
    revision: store.Revision,
    ended: *std.ArrayList(Ended),
) Error!void {
    var after: ?[]const u8 = null;
    for (0..pages_max) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_job_status,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        for (page.kvs) |kv| {
            const name = kv.key[records.prefix_job_status.len..];
            if (records.name_problem(name, constants.service_name_bytes_max) != null) continue;
            // A status that does not parse is kept: dropping on a guess would lose an ending.
            const status = records.read(records.JobStatus, ctx.arena, kv, ctx.diag) catch {
                ctx.diag.reset();
                continue;
            };
            if (!records.job_state_terminal(status.state)) continue;
            ended.append(ctx.arena, .{
                .name = name,
                .status_revision = kv.mod_revision,
                .ended_at_ms = status.ended_at_ms.?,
                .node = status.node,
            }) catch return failures.no_memory(ctx.diag);
        }
        after = page.continue_after orelse return;
    }
}

/// Sets `has_input` on the ended jobs that still have an input. Both lists ascend by name.
fn mark_inputs(ctx: *const Context, revision: store.Revision, ended: []Ended) Error!void {
    const Order = struct {
        fn by_name(_: void, first: Ended, second: Ended) bool {
            return std.mem.lessThan(u8, first.name, second.name);
        }
    };
    std.mem.sort(Ended, ended, {}, Order.by_name);
    var after: ?[]const u8 = null;
    var at: usize = 0;
    for (0..pages_max) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_job_input,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        for (page.kvs) |kv| {
            const name = kv.key[records.prefix_job_input.len..];
            while (at < ended.len and std.mem.lessThan(u8, ended[at].name, name)) at += 1;
            if (at == ended.len) continue;
            if (std.mem.eql(u8, ended[at].name, name)) ended[at].has_input = true;
        }
        after = page.continue_after orelse return;
    }
}

/// Deletes the job's records in one transaction. A conflict (the status changed since the read)
/// leaves the job for the next pass.
fn drop_job(ctx: *const Context, cursor: *Cursor, job: Ended) Error!void {
    var batch: Batch = .{};
    // The keys must outlive the commit below, so they live in the arena.
    batch.expect(try arena_key(ctx, records.job_status_key(job.name)), job.status_revision);
    batch.delete(try arena_key(ctx, records.job_key(job.name)));
    batch.delete(try arena_key(ctx, records.job_input_key(job.name)));
    batch.delete(try arena_key(ctx, records.job_run_key(job.name)));
    batch.delete(try arena_key(ctx, records.job_status_key(job.name)));
    if (job.node) |node| {
        batch.delete(try arena_key(ctx, records.job_observed_key(node, job.name)));
    }
    const done = try controller.commit(ctx, .retention, &batch);
    if (done == .applied) cursor.dropped += 1;
}

fn drop_input(ctx: *const Context, cursor: *Cursor, name: []const u8) Error!void {
    var batch: Batch = .{};
    batch.delete(try arena_key(ctx, records.job_input_key(name)));
    const done = try controller.commit(ctx, .retention, &batch);
    if (done == .applied) cursor.inputs_dropped += 1;
}

fn arena_key(ctx: *const Context, key: records.Key) Error![]const u8 {
    return ctx.arena.dupe(u8, key.slice()) catch return failures.no_memory(ctx.diag);
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;

const Fixture = struct {
    manual: ManualClock,
    memory: *MemoryStore,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag,

    fn start(self: *Fixture) !void {
        self.manual = .{ .ms = 100 * constants.job_finished_age_ms_max };
        self.memory = try testing.allocator.create(MemoryStore);
        self.memory.init(testing.allocator, self.manual.clock());
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        self.diag.reset();
    }

    fn stop(self: *Fixture) void {
        self.arena_state.deinit();
        self.memory.deinit();
        testing.allocator.destroy(self.memory);
    }

    fn context(self: *Fixture) Context {
        return .{
            .store = self.memory.interface(),
            .clock = self.manual.clock(),
            .arena = self.arena_state.allocator(),
            .diag = &self.diag,
        };
    }

    fn put(self: *Fixture, key: []const u8, bytes: []const u8) !void {
        const ctx = self.context();
        const ops = [_]store.Op{.{ .put = .{ .key = key, .value = bytes } }};
        const done = try ctx.store.txn(.{ .on_success = &ops }, ctx.diag);
        try testing.expect(done.succeeded);
    }

    /// All the records of a job that ended `age_ms` ago on node `n1` (or still runs: null).
    fn job(self: *Fixture, name: []const u8, ended_ago_ms: ?u64) !void {
        const ctx = self.context();
        const arena = ctx.arena;
        const spec: records.Job = .{
            .name = name,
            .image = "b3:aa",
            .command = &.{"true"},
            .deadline_ms = 1000,
            .submit_by_ms = 0,
            .created_at_ms = 0,
        };
        try self.put(records.job_key(name).slice(), try records.encode(arena, spec, ctx.diag));
        const input: records.JobInput = .{ .base64 = "aGk=" };
        const encoded = try records.encode(arena, input, ctx.diag);
        try self.put(records.job_input_key(name).slice(), encoded);
        try self.put(records.job_run_key(name).slice(), "{}");
        const status: records.JobStatus = if (ended_ago_ms) |ago| .{
            .state = .exited,
            .node = "n1",
            .epoch = 7,
            .ended_at_ms = self.manual.ms - ago,
            .end = .{ .kind = .exited, .code = 0 },
            .reported_at_ms = self.manual.ms - ago,
        } else .{ .state = .running, .node = "n1", .epoch = 7, .reported_at_ms = 0 };
        const bytes = try records.encode(arena, status, ctx.diag);
        try self.put(records.job_status_key(name).slice(), bytes);
        const observed = records.job_observed_key("n1", name);
        try self.put(observed.slice(), "{}");
    }

    fn count(self: *Fixture, prefix: []const u8) !usize {
        const ctx = self.context();
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix,
            .limit = constants.store_list_limit_max,
        }, ctx.diag);
        return page.kvs.len;
    }
};

test "an ended job goes whole after the age, never before the floor" {
    // Goal: the age rule at its boundary, with the floor. Method: an age asked for below the
    // floor is raised to it; a job ended one millisecond short of it stays, one past it goes,
    // with every record, and the name can be created again.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const floor = constants.job_finished_age_ms_min;
    try fixture.job("at-floor", floor);
    try fixture.job("past-floor", floor + 1);
    const ctx = fixture.context();
    var cursor: Cursor = .{ .age_ms = 0 };
    try testing.expectEqual(floor, cursor.age());
    const due = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(fixture.manual.ms + constants.retention_interval_ms, due);
    try testing.expectEqual(@as(u64, 1), cursor.dropped);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_jobs));
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_job_runs));
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_job_status));
    try testing.expectEqual(@as(usize, 0), try fixture.count("/job-observed/n1/past"));
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_job_observed));
}

test "the input goes when the job has ended, and a running job keeps its records" {
    // Goal: `/job-input` is deleted at the ending, the job's other records stay until the age.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.job("young", 5000);
    try fixture.job("running", null);
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    _ = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(@as(u64, 1), cursor.inputs_dropped);
    try testing.expectEqual(@as(u64, 0), cursor.dropped);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_job_input));
    try testing.expectEqual(@as(usize, 2), try fixture.count(records.prefix_jobs));
}

test "the oldest go first, a batch at a time" {
    // Goal: order and batching. Method: two more expired jobs than a batch; the first pass
    // deletes the oldest batch and is due at once, the second the rest.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    const total = constants.retention_batch_pairs + 2;
    for (0..total) |at| {
        var name: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "j-{d:0>3}", .{at});
        // A lower index ended longer ago.
        try fixture.job(text, constants.job_finished_age_ms_max + 100 + (total - at));
    }
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    const first = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(fixture.manual.ms, first);
    try testing.expectEqual(@as(u64, constants.retention_batch_pairs), cursor.dropped);
    const left = try fixture.count(records.prefix_jobs);
    try testing.expectEqual(@as(usize, 2), left);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_jobs,
        .limit = constants.store_list_limit_max,
    }, ctx.diag);
    try testing.expectEqualStrings("/jobs/j-008", page.kvs[0].key);
    const second = try prune(&ctx, &cursor, fixture.manual.ms);
    try testing.expectEqual(fixture.manual.ms + constants.retention_interval_ms, second);
    try testing.expectEqual(@as(usize, 0), try fixture.count(records.prefix_jobs));
}

test "a status that does not parse is kept" {
    // Goal: fail safe. Method: a status of garbage beside an old job; only the old job goes.
    var fixture: Fixture = undefined;
    try fixture.start();
    defer fixture.stop();
    try fixture.job("old", constants.job_finished_age_ms_max + 1);
    try fixture.put("/job-status/odd", "not json");
    const ctx = fixture.context();
    var cursor: Cursor = .{};
    _ = prune_or_back_off(&ctx, &cursor, fixture.manual.ms);
    try testing.expect(!cursor.failing);
    try testing.expectEqual(@as(u64, 1), cursor.dropped);
    try testing.expectEqual(@as(usize, 1), try fixture.count(records.prefix_job_status));
}
