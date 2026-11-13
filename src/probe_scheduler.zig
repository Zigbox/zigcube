//! The agent's health-check scheduler (C3 slice 9): which replica's check is due, how many are in
//! flight, and what the checks so far say of each replica. Pure: the agent hands it monotonic
//! times and the runtime's results, and asks it what to begin next. It lives in memory only, so a
//! restarted agent reports every replica `unknown` until its checks have run again.
//!
//! The rules (docs/agent.md, "Health checks"):
//!
//! - A replica's first check is due when the agent first sees its container running; the next is
//!   due `interval_ms` after the last one began, or at once if that has passed.
//! - At most `probes_concurrent_max` checks are in flight; the rest wait, soonest due first (by
//!   name on a tie, so the order is the same on every run).
//! - Exit 0 is a pass: `success_threshold` passes in a row make the replica healthy, and a pass
//!   clears the failures. Any other exit, and a timeout, is a failure: `failure_threshold` in a
//!   row make it unhealthy, and a failure clears the passes. A failure inside the start period
//!   (`start_period_ms` from the container's start) is not counted, and the period never ends
//!   early.
//! - A check the runtime could not run at all (ZC-E0516) counts as neither: the verdict and both
//!   counters stand, and the next check is due as usual.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");

const maxInt = std.math.maxInt;

/// What the last finished check said beyond its exit, for the replica's observed diagnostic.
pub const Problem = enum { none, timed_out, refused };

/// How a check ended. `refused` carries the runtime's code and first cause as one line.
pub const Outcome = union(enum) {
    exited: u8,
    timed_out,
    refused: []const u8,
};

pub const refusal_bytes_max = 160;

pub const Entry = struct {
    handle: runtime.Handle,
    /// The revision the replica's key was created at: a new replica with the same id starts over.
    created: u64,
    interval_ms: u32,
    timeout_ms: u32,
    failure_threshold: u32,
    success_threshold: u32,
    /// A hash of the command and the start period: a changed check starts over.
    spec_hash: u64,
    /// Monotonic: failures before this are not counted.
    start_ends_ms: u64,
    /// Monotonic: when the next check may begin.
    due_ms: u64,
    /// Monotonic: when the check in flight began; null with none in flight.
    began_ms: ?u64,
    successes: u32,
    failures: u32,
    verdict: records.HealthState,
    last_exit: ?u8,
    problem: Problem,
    refusal_bytes: [refusal_bytes_max]u8,
    refusal_len: u8,
    /// Set by `track` in this step; `sweep` drops the entries it did not see.
    seen: bool,

    pub fn name(entry: *const Entry) []const u8 {
        return entry.handle.name();
    }

    /// The runtime's code and cause of the last refused check; empty unless `problem` is refused.
    pub fn refusal(entry: *const Entry) []const u8 {
        assert(entry.refusal_len <= refusal_bytes_max);
        return entry.refusal_bytes[0..entry.refusal_len];
    }

    pub fn in_flight(entry: *const Entry) bool {
        return entry.began_ms != null;
    }

    /// Marks the check begun at `now` (after `Runtime.probe_begin` returned).
    pub fn began(entry: *Entry, now: u64) void {
        assert(entry.began_ms == null);
        assert(entry.due_ms <= now);
        entry.began_ms = now;
    }

    /// Takes a finished check's outcome at `now`.
    pub fn finished(entry: *Entry, outcome: Outcome, now: u64) void {
        const began_at = entry.began_ms.?;
        assert(began_at <= now);
        entry.began_ms = null;
        entry.due_ms = @max(began_at + entry.interval_ms, now);
        switch (outcome) {
            .exited => |code| {
                entry.last_exit = code;
                entry.problem = .none;
                entry.refusal_len = 0;
                if (code == 0) entry.pass() else entry.fail(now);
            },
            .timed_out => {
                entry.problem = .timed_out;
                entry.refusal_len = 0;
                entry.fail(now);
            },
            .refused => |text| {
                assert(text.len > 0);
                entry.problem = .refused;
                const len = @min(text.len, refusal_bytes_max);
                @memcpy(entry.refusal_bytes[0..len], text[0..len]);
                entry.refusal_len = @intCast(len);
            },
        }
        assert(entry.due_ms >= now);
    }

    fn pass(entry: *Entry) void {
        entry.failures = 0;
        entry.successes +|= 1;
        if (entry.successes >= entry.success_threshold) entry.verdict = .healthy;
    }

    fn fail(entry: *Entry, now: u64) void {
        entry.successes = 0;
        if (now < entry.start_ends_ms) return;
        entry.failures +|= 1;
        if (entry.failures >= entry.failure_threshold) entry.verdict = .unhealthy;
    }

    fn matches(entry: *const Entry, created: u64, health: *const records.Health) bool {
        if (entry.created != created) return false;
        if (entry.interval_ms != health.interval_ms) return false;
        if (entry.timeout_ms != health.timeout_ms) return false;
        if (entry.failure_threshold != health.failure_threshold) return false;
        if (entry.success_threshold != health.success_threshold) return false;
        return entry.spec_hash == spec_hash_of(health);
    }
};

fn spec_hash_of(health: *const records.Health) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&health.start_period_ms));
    for (health.command) |word| {
        hasher.update(std.mem.asBytes(&word.len));
        hasher.update(word);
    }
    return hasher.final();
}

/// The checks of the replicas the agent runs, one entry per container with a health check.
pub const Table = struct {
    entries: [constants.runtime_handles_max]Entry,
    count: u32,

    /// Initialises in place: the table is large. Every verdict is then `unknown`.
    pub fn clear(table: *Table) void {
        table.count = 0;
    }

    pub fn find(table: *Table, name: []const u8) ?*Entry {
        for (table.entries[0..table.count]) |*entry| {
            if (std.mem.eql(u8, entry.name(), name)) return entry;
        }
        return null;
    }

    pub fn mark_unseen(table: *Table) void {
        for (table.entries[0..table.count]) |*entry| entry.seen = false;
    }

    /// The entry of a running container with a check, made on first sight (its first check due
    /// at `now`) and made again if the replica or its check changed. `start_ends_ms` is
    /// monotonic: the agent derives it from the container's start (an adopted container's start
    /// period may be over already).
    pub fn track(
        table: *Table,
        handle: runtime.Handle,
        created: u64,
        health: *const records.Health,
        start_ends_ms: u64,
        now: u64,
    ) *Entry {
        assert(health.interval_ms > 0);
        assert(health.timeout_ms <= health.interval_ms);
        assert(health.failure_threshold > 0);
        assert(health.success_threshold > 0);
        if (table.find(handle.name())) |found| {
            if (found.matches(created, health)) {
                found.seen = true;
                return found;
            }
            found.* = fresh(handle, created, health, start_ends_ms, now);
            return found;
        }
        assert(table.count < table.entries.len);
        table.count += 1;
        const entry = &table.entries[table.count - 1];
        entry.* = fresh(handle, created, health, start_ends_ms, now);
        return entry;
    }

    /// Drops the entries `track` did not see since `mark_unseen`: containers that ended, went
    /// away, or whose replica has no check any more.
    pub fn sweep(table: *Table) void {
        var index: u32 = 0;
        while (index < table.count) {
            if (table.entries[index].seen) {
                index += 1;
            } else {
                table.count -= 1;
                table.entries[index] = table.entries[table.count];
            }
        }
    }

    pub fn in_flight(table: *const Table) u32 {
        var count: u32 = 0;
        for (table.entries[0..table.count]) |*entry| {
            if (entry.in_flight()) count += 1;
        }
        return count;
    }

    /// The check to begin now: due, not in flight, soonest first and then by name; null if none
    /// is due or `probes_concurrent_max` are in flight.
    pub fn next_to_begin(table: *Table, now: u64) ?*Entry {
        if (table.in_flight() >= constants.probes_concurrent_max) return null;
        var best: ?*Entry = null;
        for (table.entries[0..table.count]) |*entry| {
            if (entry.in_flight()) continue;
            if (entry.due_ms > now) continue;
            if (best) |chosen| {
                if (!before(entry, chosen)) continue;
            }
            best = entry;
        }
        return best;
    }

    /// When the agent must step again for its checks, monotonic; maxInt if never. A check in
    /// flight is polled at its timeout (the resync polls it sooner); a waiting one at its due
    /// time, unless every slot is taken (a check that ends frees one, and is itself a wake).
    pub fn wake_ms(table: *const Table, now: u64) u64 {
        const full = table.in_flight() >= constants.probes_concurrent_max;
        var wake: u64 = maxInt(u64);
        for (table.entries[0..table.count]) |*entry| {
            if (entry.began_ms) |began_at| {
                const timeout_at = began_at + entry.timeout_ms;
                if (timeout_at > now) wake = @min(wake, timeout_at);
            } else if (!full and entry.due_ms > now) {
                wake = @min(wake, entry.due_ms);
            }
        }
        return wake;
    }
};

fn fresh(
    handle: runtime.Handle,
    created: u64,
    health: *const records.Health,
    start_ends_ms: u64,
    now: u64,
) Entry {
    return .{
        .handle = handle,
        .created = created,
        .interval_ms = health.interval_ms,
        .timeout_ms = health.timeout_ms,
        .failure_threshold = health.failure_threshold,
        .success_threshold = health.success_threshold,
        .spec_hash = spec_hash_of(health),
        .start_ends_ms = start_ends_ms,
        .due_ms = now,
        .began_ms = null,
        .successes = 0,
        .failures = 0,
        .verdict = .unknown,
        .last_exit = null,
        .problem = .none,
        .refusal_bytes = undefined,
        .refusal_len = 0,
        .seen = true,
    };
}

fn before(first: *const Entry, second: *const Entry) bool {
    if (first.due_ms != second.due_ms) return first.due_ms < second.due_ms;
    return std.mem.lessThan(u8, first.name(), second.name());
}

/// The monotonic end of a container's start period: `start_period_ms` after it started, on the
/// wall clock, carried over to the monotonic one. A container the agent sees start (or that
/// started in the future, by a clock that moved back) has its whole period ahead of it.
pub fn start_ends(
    start_period_ms: u32,
    started_at_ms: ?u64,
    wall_now: u64,
    mono_now: u64,
) u64 {
    const age = if (started_at_ms) |at| wall_now -| at else 0;
    return mono_now + (start_period_ms -| age);
}

const testing = std.testing;

fn test_health(failure_threshold: u32, success_threshold: u32, start_period: u32) records.Health {
    return .{
        .command = &.{ "check", "--quick" },
        .interval_ms = 1_000,
        .timeout_ms = 500,
        .start_period_ms = start_period,
        .failure_threshold = failure_threshold,
        .success_threshold = success_threshold,
    };
}

fn test_table() !*Table {
    const table = try testing.allocator.create(Table);
    table.clear();
    return table;
}

/// One check of `entry` at `now` with `outcome`, as the agent runs it.
fn check_once(table: *Table, now: u64, outcome: Outcome) *Entry {
    const entry = table.next_to_begin(now).?;
    entry.began(now);
    entry.finished(outcome, now + 10);
    return entry;
}

test "probe_scheduler: thresholds settle the verdict, as a table" {
    const Row = struct {
        /// failure_threshold, success_threshold
        thresholds: [2]u32,
        exits: []const u8,
        want: records.HealthState,
        failures: u32,
    };
    const rows = [_]Row{
        .{ .thresholds = .{ 1, 1 }, .exits = &.{}, .want = .unknown, .failures = 0 },
        .{ .thresholds = .{ 1, 1 }, .exits = &.{0}, .want = .healthy, .failures = 0 },
        .{ .thresholds = .{ 1, 1 }, .exits = &.{1}, .want = .unhealthy, .failures = 1 },
        .{ .thresholds = .{ 3, 1 }, .exits = &.{ 0, 1, 1 }, .want = .healthy, .failures = 2 },
        .{ .thresholds = .{ 3, 1 }, .exits = &.{ 0, 1, 1, 7 }, .want = .unhealthy, .failures = 3 },
        .{ .thresholds = .{ 3, 1 }, .exits = &.{ 1, 1, 0, 1, 1 }, .want = .healthy, .failures = 2 },
        .{ .thresholds = .{ 1, 2 }, .exits = &.{0}, .want = .unknown, .failures = 0 },
        .{ .thresholds = .{ 1, 2 }, .exits = &.{ 1, 0 }, .want = .unhealthy, .failures = 0 },
        .{ .thresholds = .{ 1, 2 }, .exits = &.{ 1, 0, 0 }, .want = .healthy, .failures = 0 },
        .{ .thresholds = .{ 1, 2 }, .exits = &.{ 0, 1, 0 }, .want = .unhealthy, .failures = 0 },
    };
    const table = try test_table();
    defer testing.allocator.destroy(table);
    for (rows) |row| {
        table.clear();
        const health = test_health(row.thresholds[0], row.thresholds[1], 0);
        _ = table.track(runtime.Handle.init("web-1"), 7, &health, 0, 0);
        var now: u64 = 0;
        var last: ?*Entry = table.find("web-1");
        for (row.exits) |code| {
            last = check_once(table, now, .{ .exited = code });
            now += health.interval_ms;
        }
        try testing.expectEqual(row.want, last.?.verdict);
        try testing.expectEqual(row.failures, last.?.failures);
    }
}

test "probe_scheduler: a timeout fails, a refusal counts as neither" {
    const table = try test_table();
    defer testing.allocator.destroy(table);
    const health = test_health(2, 1, 0);
    const entry = table.track(runtime.Handle.init("web-1"), 7, &health, 0, 0);
    _ = check_once(table, 0, .timed_out);
    try testing.expectEqual(Problem.timed_out, entry.problem);
    try testing.expectEqual(@as(u32, 1), entry.failures);
    try testing.expectEqual(@as(?u8, null), entry.last_exit);
    _ = check_once(table, 1_000, .{ .refused = "ZBX-E0502: the container is not running" });
    try testing.expectEqual(Problem.refused, entry.problem);
    try testing.expectEqualStrings("ZBX-E0502: the container is not running", entry.refusal());
    try testing.expectEqual(@as(u32, 1), entry.failures);
    try testing.expectEqual(records.HealthState.unknown, entry.verdict);
    _ = check_once(table, 2_000, .timed_out);
    try testing.expectEqual(records.HealthState.unhealthy, entry.verdict);
    _ = check_once(table, 3_000, .{ .exited = 0 });
    try testing.expectEqual(Problem.none, entry.problem);
    try testing.expectEqual(records.HealthState.healthy, entry.verdict);
    try testing.expectEqual(@as(?u8, 0), entry.last_exit);
    try testing.expectEqual(@as(usize, 0), entry.refusal().len);
}

test "probe_scheduler: failures inside the start period are not counted, and it never ends early" {
    const table = try test_table();
    defer testing.allocator.destroy(table);
    const health = test_health(1, 1, 2_500);
    const ends = start_ends(health.start_period_ms, 100_000, 100_000, 50);
    try testing.expectEqual(@as(u64, 2_550), ends);
    const entry = table.track(runtime.Handle.init("web-1"), 7, &health, ends, 50);
    _ = check_once(table, 50, .{ .exited = 1 });
    try testing.expectEqual(records.HealthState.unknown, entry.verdict);
    try testing.expectEqual(@as(u32, 0), entry.failures);
    _ = check_once(table, 1_050, .{ .exited = 0 });
    try testing.expectEqual(records.HealthState.healthy, entry.verdict);
    // Still inside the period after a pass: the failure is not counted.
    _ = check_once(table, 2_050, .timed_out);
    try testing.expectEqual(records.HealthState.healthy, entry.verdict);
    try testing.expectEqual(@as(u32, 0), entry.failures);
    _ = check_once(table, 3_050, .{ .exited = 1 });
    try testing.expectEqual(records.HealthState.unhealthy, entry.verdict);
}

test "probe_scheduler: an adopted container's start period counts from its start" {
    try testing.expectEqual(@as(u64, 500), start_ends(2_000, 10_000, 11_500, 0));
    try testing.expectEqual(@as(u64, 7), start_ends(2_000, 10_000, 15_000, 7));
    try testing.expectEqual(@as(u64, 2_007), start_ends(2_000, null, 15_000, 7));
    // A start in the future (a clock that moved back) leaves the whole period.
    try testing.expectEqual(@as(u64, 2_000), start_ends(2_000, 20_000, 15_000, 0));
}

test "probe_scheduler: the next check is due an interval after the last began" {
    const table = try test_table();
    defer testing.allocator.destroy(table);
    const health = test_health(1, 1, 0);
    const entry = table.track(runtime.Handle.init("web-1"), 7, &health, 0, 100);
    try testing.expect(table.next_to_begin(99) == null);
    entry.began(table.next_to_begin(100).?.due_ms);
    try testing.expect(table.next_to_begin(100) == null);
    try testing.expectEqual(@as(u64, 600), table.wake_ms(100));
    entry.finished(.{ .exited = 0 }, 300);
    try testing.expectEqual(@as(u64, 1_100), entry.due_ms);
    try testing.expectEqual(@as(u64, 1_100), table.wake_ms(300));
    try testing.expect(table.next_to_begin(1_099) == null);
    // A check that ended after its interval is due again at once.
    entry.began(1_100);
    entry.finished(.timed_out, 2_500);
    try testing.expectEqual(@as(u64, 2_500), entry.due_ms);
}

test "probe_scheduler: at most probes_concurrent_max in flight, soonest due first" {
    const table = try test_table();
    defer testing.allocator.destroy(table);
    const health = test_health(1, 1, 0);
    const count = constants.probes_concurrent_max + 2;
    var buffer: [16]u8 = undefined;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        // Tracked in reverse name order and at decreasing times: the order is (due, name).
        const name = try std.fmt.bufPrint(&buffer, "web-{d:0>2}", .{count - index});
        _ = table.track(runtime.Handle.init(name), 7, &health, 0, 1_000 - index);
    }
    var previous: ?*Entry = null;
    index = 0;
    while (index < constants.probes_concurrent_max) : (index += 1) {
        const entry = table.next_to_begin(1_000).?;
        if (previous) |earlier| try testing.expect(!before(entry, earlier));
        entry.began(1_000);
        previous = entry;
    }
    try testing.expect(table.next_to_begin(1_000) == null);
    try testing.expectEqual(constants.probes_concurrent_max, table.in_flight());
    // Waiting checks are no wake while every slot is taken; the timeouts are.
    try testing.expectEqual(@as(u64, 1_500), table.wake_ms(1_000));
    previous.?.finished(.{ .exited = 0 }, 1_100);
    try testing.expect(table.next_to_begin(1_100) != null);
}

test "probe_scheduler: a changed check or replica starts over, an unseen entry is dropped" {
    const table = try test_table();
    defer testing.allocator.destroy(table);
    var health = test_health(1, 1, 0);
    const handle = runtime.Handle.init("web-1");
    _ = table.track(handle, 7, &health, 0, 0);
    _ = check_once(table, 0, .{ .exited = 0 });
    const HealthState = records.HealthState;
    try testing.expectEqual(HealthState.healthy, table.track(handle, 7, &health, 0, 1).verdict);
    health.command = &.{ "check", "--slow" };
    try testing.expectEqual(HealthState.unknown, table.track(handle, 7, &health, 0, 2).verdict);
    _ = check_once(table, 2, .{ .exited = 0 });
    try testing.expectEqual(HealthState.unknown, table.track(handle, 8, &health, 0, 3).verdict);
    try testing.expectEqual(@as(u32, 1), table.count);
    _ = table.track(runtime.Handle.init("web-2"), 9, &health, 0, 3);
    table.mark_unseen();
    _ = table.track(runtime.Handle.init("web-2"), 9, &health, 0, 4);
    table.sweep();
    try testing.expectEqual(@as(u32, 1), table.count);
    try testing.expect(table.find("web-1") == null);
    try testing.expect(table.find("web-2") != null);
}
