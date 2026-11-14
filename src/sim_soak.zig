//! The long soak (C3 fleet 6): one seed run for hours with its history growing, to find what a
//! short run cannot: memory that leaks, a counter that would overflow, a world that drifts.
//!
//!     sim-cluster <seed> soak [<nodes>] (--soak-minutes=M | --soak-operations=N)
//!                 [--soak-epoch=E] [--profile=NAME] [--jobs=true|false] [--strong] ...
//!
//! Liveness is off (faults stay on): a heal point needs the run's length, which a soak does not
//! know. Every `E` operations (`--soak-epoch`, default 500) the run stops at an epoch
//! (`sim_cluster.Options.on_epoch`) and this prints one `soak:` line of what it has grown to and
//! judges it (`judge`). `--soak-minutes` ends the run at the first epoch past the wall-clock
//! budget; `--soak-operations` at a count, which is how a soak's failure replays; and the first
//! epoch whose live bytes reach `--soak-bytes` (`bytes_max_default`, below the fleet unit's
//! `MemoryMax`) ends it as held, "budget reached". Either way the simulation's end checks then
//! run, as for a run of that many operations, and once the world is torn down every byte it
//! took must have come back (`finish`).
//!
//! The memory checks, and what they cannot see (docs/decisions/2026-11-14-c3-soak-leak-judge.md):
//! memory never given back fails at the teardown, whatever its rate; memory held until the
//! teardown fails at an epoch only when, after the warm-up, it outgrows the history the world
//! keeps (the ratio and the slope, `judge`). A hoard steady from the first operation is in both
//! baselines and runs on until the byte budget.
//!
//! A failure prints the block a `--seeds` range prints (`seed N: FAILED: ...`, `step:`, the
//! replay, the trace) and the summary `sim-cluster --soak: seeds N..N, K operations: 1 of 1
//! failed`, which `sim_fleet ingest --kind sim-soak` files (src/sim_fleet_issue.zig). A failure
//! of the simulation's own checks replays with `sim_cluster <seed> K <nodes> --liveness=false
//! ...`, the same world cut at the same operation (nothing it draws depends on the run's length
//! when liveness is off); a soak check's failure replays with `--soak-operations=K`.
//!
//! The checks are deterministic, so a replay fails the same way: the clock only decides when a
//! timed soak stops, and the throughput it prints is not judged (a run's cost per operation grows
//! with its history by design: the c0 invariants read every retained decision, docs/core.md).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const sim_cluster = @import("sim_cluster.zig");
const sim_jobs = @import("sim_jobs.zig");

pub const epoch_operations_default: u32 = 500;

/// Epochs before the leak check takes its baseline: the world's first minutes fill caches and
/// tables that then stay.
pub const warmup_epochs: u32 = 4;

/// The leak check: live bytes per retained history item may grow at most this many times over
/// the baseline's.
pub const leak_factor: u64 = 4;

/// The slope check: the bytes added per history item added since the warm-up may be at most this
/// many times the baseline slope (the first epoch after the warm-up, and never less than the
/// warm-up's own bytes per item). Growing arrays double, so a healthy world's slope stays within
/// about three times its true cost once the history has doubled since the warm-up, which is
/// when the check starts (measured: seed 7, 4,000 operations, at most 0.4 of the baseline).
pub const slope_factor: u64 = 4;

/// The live bytes that end a soak as held (`--soak-bytes`): below `MemoryMax=2G` of
/// `ops/sim-fleet/sim-soak.service`, with room for what the allocator holds beyond them and for
/// the peak between two epochs, so that a long healthy soak stops itself and is not killed.
pub const bytes_max_default: u64 = 1536 * 1024 * 1024;

/// The counter check: a fixed-width counter past this fraction of its range fails the soak, long
/// before ReleaseSafe's overflow panic would.
pub const headroom_num: u64 = 1;
pub const headroom_den: u64 = 2;

/// Counts the bytes the simulation holds, through the process's allocator.
pub const Counting = struct {
    child: Allocator,
    live: u64 = 0,
    peak: u64 = 0,

    pub fn allocator(counting: *Counting) Allocator {
        return .{ .ptr = counting, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn of(context: *anyopaque) *Counting {
        return @ptrCast(@alignCast(context));
    }

    fn grow(counting: *Counting, from: usize, to: usize) void {
        assert(counting.live >= from);
        counting.live = counting.live - from + to;
        counting.peak = @max(counting.peak, counting.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const counting = of(context);
        const memory = counting.child.rawAlloc(len, alignment, ret) orelse return null;
        counting.grow(0, len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, at: Alignment, len: usize, ret: usize) bool {
        const counting = of(context);
        if (!counting.child.rawResize(memory, at, len, ret)) return false;
        counting.grow(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, at: Alignment, len: usize, ret: usize) ?[*]u8 {
        const counting = of(context);
        const moved = counting.child.rawRemap(memory, at, len, ret) orelse return null;
        counting.grow(memory.len, len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const counting = of(context);
        counting.child.rawFree(memory, alignment, ret);
        counting.grow(memory.len, 0);
    }
};

/// What a soak was asked for.
pub const Plan = struct {
    epoch_operations: u32 = epoch_operations_default,
    /// One of these ends the run: the wall-clock budget, or an operation count (a replay).
    minutes: ?u32 = null,
    operations: ?u32 = null,
    /// Live bytes at an epoch that end the run as held (`bytes_max_default`).
    bytes_max: u64 = bytes_max_default,
};

/// A soak in progress: what the epoch hook judges against. One per process (the hook has no
/// context argument, `sim_cluster.Options.on_epoch`).
pub const Soak = struct {
    plan: Plan,
    counting: *Counting,
    io: std.Io,
    out: *std.Io.Writer,
    started: std.Io.Timestamp,
    epochs: u32 = 0,
    last: ?sim_cluster.Epoch = null,
    /// Live bytes per retained history item at the end of the warm-up (`leak_factor`).
    baseline_per_item: ?u64 = null,
    /// Live bytes and history items at the end of the warm-up, and the slope of the first epoch
    /// after it (`slope_factor`).
    warm: ?struct { live: u64, items: u64 } = null,
    baseline_slope: ?u64 = null,
    /// The live bytes at the epoch that ended the run because they reached `plan.bytes_max`.
    budget_reached: ?u64 = null,
    /// The failure a check found (`fail`), and the operations of the epoch it found it at.
    failure: [96]u8 = undefined,
    failure_len: u32 = 0,
    failure_detail: [160]u8 = undefined,
    failure_detail_len: u32 = 0,
    failed_at: u32 = 0,
    out_failed: bool = false,
};

var active: ?*Soak = null;

/// Runs one soak with `soak` as its state, filling `report` as `sim_cluster.simulate` does.
pub fn run(
    soak: *Soak,
    seed: u64,
    options: sim_cluster.Options,
    report: *sim_cluster.Report,
) void {
    assert(active == null);
    assert((soak.plan.minutes == null) != (soak.plan.operations == null));
    var soaked = options;
    soaked.liveness = false;
    soaked.heal_at = null;
    soaked.on_epoch = on_epoch;
    soaked.epoch_operations = soak.plan.epoch_operations;
    active = soak;
    defer active = null;
    const operations = soak.plan.operations orelse std.math.maxInt(u32);
    sim_cluster.simulate(soak.counting.allocator(), seed, operations, soaked, report);
    finish(soak, report.operations_run);
}

/// The teardown check, on every way a soak ends: the world is gone, so is all it held.
fn finish(soak: *Soak, operations: u32) void {
    if (soak.counting.live == 0) return;
    if (soak.failure_len > 0) return; // The first failure is the one replayed.
    soak.failed_at = operations;
    const what = "soak: memory still held after the world was torn down";
    fail(soak, what, .{}, "{d} bytes after a run of {d} operations", .{
        soak.counting.live, operations,
    });
}

fn on_epoch(epoch: *const sim_cluster.Epoch) bool {
    const soak = active.?;
    soak.epochs += 1;
    print_epoch(soak, epoch);
    judge(soak, epoch);
    soak.last = epoch.*;
    if (soak.failure_len > 0) {
        soak.failed_at = epoch.operations;
        return false;
    }
    if (soak.counting.live >= soak.plan.bytes_max) {
        soak.budget_reached = soak.counting.live;
        return false;
    }
    if (soak.plan.operations) |operations| return epoch.operations < operations;
    const minutes = soak.plan.minutes.?;
    const elapsed = soak.started.durationTo(std.Io.Clock.boot.now(soak.io)).toMilliseconds();
    return elapsed < @as(i64, minutes) * std.time.ms_per_min;
}

/// Retained history: what the world may keep growing (the store's keys, its uncompacted log and
/// its revision hashes, the decisions, the job ledger). Leaked bytes grow faster than it.
fn history_items(epoch: *const sim_cluster.Epoch) u64 {
    return epoch.store_keys + epoch.store_log + epoch.revision + epoch.decisions +
        epoch.job_ledger + 1;
}

/// The soak's checks at one epoch; the first that fails is kept in `soak.failure`.
fn judge(soak: *Soak, epoch: *const sim_cluster.Epoch) void {
    if (soak.last) |last| {
        if (epoch.virtual_ms <= last.virtual_ms) {
            return fail(soak, "soak: virtual time stood still over an epoch", .{}, "at {d} ms", .{
                epoch.virtual_ms,
            });
        }
        if (epoch.revision <= last.revision) {
            const what = "soak: the store's revision stood still over an epoch";
            return fail(soak, what, .{}, "at revision {d}", .{epoch.revision});
        }
    }
    const counters = [_]struct { name: []const u8, value: u64, max: u64 }{
        .{ .name = "operations", .value = epoch.operations, .max = std.math.maxInt(u32) },
        .{ .name = "transactions", .value = epoch.transactions, .max = std.math.maxInt(u32) },
        .{ .name = "agent steps", .value = epoch.agent_steps, .max = std.math.maxInt(u32) },
        .{ .name = "server steps", .value = epoch.server_steps, .max = std.math.maxInt(u32) },
        .{ .name = "decisions", .value = epoch.decisions, .max = sim_cluster.decisions_read_max },
        .{ .name = "jobs", .value = epoch.jobs_created, .max = std.math.maxInt(u32) },
        .{ .name = "start ledger", .value = epoch.job_ledger, .max = sim_jobs.ledger_max },
    };
    for (counters) |counter| {
        if (counter.value * headroom_den > counter.max * headroom_num) {
            return fail(soak, "soak: {s} past half its range", .{counter.name}, "{s} {d} of {d}", .{
                counter.name, counter.value, counter.max,
            });
        }
    }
    const items = history_items(epoch);
    const per_item = soak.counting.live / items;
    if (soak.epochs == warmup_epochs) soak.baseline_per_item = @max(per_item, 1);
    if (soak.baseline_per_item) |baseline| {
        if (per_item > baseline * leak_factor) {
            const what = "soak: memory grew faster than the history it holds";
            const detail = "{d} live bytes per history item, {d} after the warm-up, " ++
                "limit {d} times";
            return fail(soak, what, .{}, detail, .{ per_item, baseline, leak_factor });
        }
    }
    judge_slope(soak, items);
}

/// The slope check (`slope_factor`): the bytes the world added per history item it added since
/// the warm-up, against the first epoch after it.
fn judge_slope(soak: *Soak, items: u64) void {
    const live = soak.counting.live;
    if (soak.epochs == warmup_epochs) {
        soak.warm = .{ .live = live, .items = items };
        return;
    }
    const warm = soak.warm orelse return;
    // Retention may shrink the history: there is no slope until it has grown.
    if (items <= warm.items) return;
    const slope = (live -| warm.live) / (items - warm.items);
    const baseline = soak.baseline_slope orelse {
        soak.baseline_slope = @max(slope, warm.live / warm.items, 1);
        return;
    };
    // Until the history has doubled, one array's doubling may outweigh what it added.
    if (items - warm.items < warm.items) return;
    if (slope > baseline * slope_factor) {
        const what = "soak: memory grew faster than the history it holds since the warm-up";
        const detail = "{d} bytes per history item added, {d} in the first epoch after the " ++
            "warm-up, limit {d} times";
        return fail(soak, what, .{}, detail, .{ slope, baseline, slope_factor });
    }
}

/// Keeps the first failure: `what` is the symptom the fleet files under (stable from run to
/// run), `detail` its numbers.
fn fail(
    soak: *Soak,
    comptime what: []const u8,
    what_args: anytype,
    comptime detail: []const u8,
    detail_args: anytype,
) void {
    assert(soak.failure_len == 0);
    var writer: std.Io.Writer = .fixed(&soak.failure);
    writer.print(what, what_args) catch {}; // What does not fit is cut.
    soak.failure_len = @intCast(writer.buffered().len);
    assert(soak.failure_len > 0);
    writer = .fixed(&soak.failure_detail);
    writer.print(detail, detail_args) catch {}; // What does not fit is cut.
    soak.failure_detail_len = @intCast(writer.buffered().len);
}

pub fn failure(soak: *const Soak) ?[]const u8 {
    if (soak.failure_len == 0) return null;
    return soak.failure[0..soak.failure_len];
}

pub fn failure_detail(soak: *const Soak) []const u8 {
    return soak.failure_detail[0..soak.failure_detail_len];
}

fn print_epoch(soak: *Soak, epoch: *const sim_cluster.Epoch) void {
    const elapsed = soak.started.durationTo(std.Io.Clock.boot.now(soak.io)).toMilliseconds();
    const wall_ms: u64 = @intCast(@max(elapsed, 1));
    const per_second = @as(u64, epoch.operations) * std.time.ms_per_s / wall_ms;
    soak.out.print("soak: epoch {d} operations={d} wall_ms={d} operations_per_s={d} " ++
        "virtual_ms={d} revision={d} transactions={d} agent_steps={d} server_steps={d} " ++
        "decisions={d} dropped={d} keys={d} log={d} leases={d} jobs={d} ledger={d} " ++
        "live_bytes={d} peak_bytes={d}\n", .{
        soak.epochs,        epoch.operations,        wall_ms,
        per_second,         epoch.virtual_ms,        epoch.revision,
        epoch.transactions, epoch.agent_steps,       epoch.server_steps,
        epoch.decisions,    epoch.decisions_dropped, epoch.store_keys,
        epoch.store_log,    epoch.store_leases,      epoch.jobs_created,
        epoch.job_ledger,   soak.counting.live,      soak.counting.peak,
    }) catch {
        soak.out_failed = true;
    };
    // Out now: a later crash must not lose the epochs before it.
    soak.out.flush() catch {
        soak.out_failed = true;
    };
}

test "the counting allocator follows what is held" {
    var counting: Counting = .{ .child = std.testing.allocator };
    const gpa = counting.allocator();
    const a = try gpa.alloc(u8, 100);
    const b = try gpa.alloc(u8, 50);
    try std.testing.expectEqual(@as(u64, 150), counting.live);
    gpa.free(a);
    try std.testing.expectEqual(@as(u64, 50), counting.live);
    try std.testing.expectEqual(@as(u64, 150), counting.peak);
    const c = try gpa.realloc(b, 400);
    try std.testing.expectEqual(@as(u64, 400), counting.live);
    gpa.free(c);
    try std.testing.expectEqual(@as(u64, 0), counting.live);
}

pub fn world_hash(report: *const sim_cluster.Report) []const u8 {
    const text = report.text();
    const start = std.mem.indexOf(u8, text, "world hash: ") orelse return "";
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

test "a soak stopped at an epoch is the plain run of that many operations" {
    // Goal: a soak's failure replays as `sim_cluster <seed> K <nodes> --liveness=false`. Method:
    // stop a soak by count and run the plain world of that length; the worlds must hash alike.
    const gpa = std.testing.allocator;
    const report = try gpa.create(sim_cluster.Report);
    defer gpa.destroy(report);
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = gpa };
    var soak: Soak = .{
        .plan = .{ .epoch_operations = 40, .operations = 120 },
        .counting = &counting,
        .io = std.testing.io,
        .out = &out,
        .started = std.Io.Clock.boot.now(std.testing.io),
    };
    run(&soak, 7, .{}, report);
    try std.testing.expect(!report.failed);
    try std.testing.expect(failure(&soak) == null);
    try std.testing.expectEqual(@as(u32, 120), report.operations_run);
    try std.testing.expectEqual(@as(u32, 3), soak.epochs);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "soak: epoch 3 operations=120 ") !=
        null);
    try std.testing.expectEqual(@as(u64, 0), counting.live);
    var soaked_hash: [64]u8 = undefined;
    const soaked = world_hash(report);
    try std.testing.expect(soaked.len > 0);
    @memcpy(soaked_hash[0..soaked.len], soaked);
    sim_cluster.simulate(gpa, 7, 120, .{ .liveness = false }, report);
    try std.testing.expectEqualStrings(soaked_hash[0..soaked.len], world_hash(report));
}

fn test_soak(counting: *Counting, out: *std.Io.Writer) Soak {
    return .{
        .plan = .{ .operations = 1000 },
        .counting = counting,
        .io = std.testing.io,
        .out = out,
        .started = std.Io.Clock.boot.now(std.testing.io),
    };
}

test "each counter fails past half its range and holds at half" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = std.testing.allocator };
    const cases = .{
        .{ "operations", "operations", std.math.maxInt(u32) },
        .{ "transactions", "transactions", std.math.maxInt(u32) },
        .{ "agent_steps", "agent steps", std.math.maxInt(u32) },
        .{ "server_steps", "server steps", std.math.maxInt(u32) },
        .{ "decisions", "decisions", sim_cluster.decisions_read_max },
        .{ "jobs_created", "jobs", std.math.maxInt(u32) },
        .{ "job_ledger", "start ledger", sim_jobs.ledger_max },
    };
    inline for (cases) |case| {
        var epoch: sim_cluster.Epoch = std.mem.zeroes(sim_cluster.Epoch);
        epoch.virtual_ms = 1000;
        epoch.revision = 10;
        @field(epoch, case[0]) = case[2] / 2;
        var soak = test_soak(&counting, &out);
        judge(&soak, &epoch);
        try std.testing.expect(failure(&soak) == null);
        @field(epoch, case[0]) = case[2] / 2 + 1;
        judge(&soak, &epoch);
        try std.testing.expectEqualStrings("soak: " ++ case[1] ++ " past half its range", failure(&soak).?);
    }
}

test "a world that stood still over an epoch fails: its clock, its store's revision" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = std.testing.allocator };
    var epoch: sim_cluster.Epoch = std.mem.zeroes(sim_cluster.Epoch);
    epoch.virtual_ms = 1000;
    epoch.revision = 10;

    var soak = test_soak(&counting, &out);
    soak.last = epoch;
    epoch.virtual_ms += 1;
    epoch.revision += 1;
    judge(&soak, &epoch);
    try std.testing.expect(failure(&soak) == null);

    soak.last = epoch;
    epoch.virtual_ms += 1;
    judge(&soak, &epoch);
    try std.testing.expectEqualStrings(
        "soak: the store's revision stood still over an epoch",
        failure(&soak).?,
    );
    try std.testing.expectEqualStrings("at revision 11", failure_detail(&soak));

    soak = test_soak(&counting, &out);
    soak.last = epoch;
    epoch.revision += 1;
    judge(&soak, &epoch);
    try std.testing.expectEqualStrings(
        "soak: virtual time stood still over an epoch",
        failure(&soak).?,
    );
}

test "the slope: memory added per history item after the warm-up against the first epoch" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = std.testing.allocator };
    var soak = test_soak(&counting, &out);
    // 100 items of 10 bytes at the warm-up, then 30 bytes per item added (an array doubled).
    soak.epochs = warmup_epochs;
    counting.live = 1000;
    judge_slope(&soak, 100);
    soak.epochs += 1;
    counting.live = 1000 + 50 * 30;
    judge_slope(&soak, 150);
    try std.testing.expectEqual(@as(?u64, 30), soak.baseline_slope);
    // Steep, but the history has not doubled since the warm-up: not judged yet.
    soak.epochs += 1;
    counting.live = 1000 + 90 * 200;
    judge_slope(&soak, 190);
    try std.testing.expect(failure(&soak) == null);
    // Doubled, at four times the baseline: holds.
    soak.epochs += 1;
    counting.live = 1000 + 100 * 120;
    judge_slope(&soak, 200);
    try std.testing.expect(failure(&soak) == null);
    // Past it: fails.
    soak.epochs += 1;
    counting.live = 1000 + 100 * 121;
    judge_slope(&soak, 200);
    try std.testing.expectEqualStrings(
        "soak: memory grew faster than the history it holds since the warm-up",
        failure(&soak).?,
    );
    try std.testing.expectEqualStrings(
        "121 bytes per history item added, 30 in the first epoch after the warm-up, " ++
            "limit 4 times",
        failure_detail(&soak),
    );
    counting.live = 0;

    // A first epoch that added nearly nothing does not make the baseline nearly nothing: it is
    // at least the warm-up's own bytes per item.
    soak = test_soak(&counting, &out);
    soak.epochs = warmup_epochs;
    counting.live = 1000;
    judge_slope(&soak, 100);
    soak.epochs += 1;
    judge_slope(&soak, 150);
    try std.testing.expectEqual(@as(?u64, 10), soak.baseline_slope);
    counting.live = 0;
}

test "the teardown: a byte still held after the run fails the soak, unless it already failed" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = std.testing.allocator };
    var soak = test_soak(&counting, &out);
    finish(&soak, 300);
    try std.testing.expect(failure(&soak) == null);
    counting.live = 1;
    finish(&soak, 300);
    try std.testing.expectEqualStrings(
        "soak: memory still held after the world was torn down",
        failure(&soak).?,
    );
    try std.testing.expectEqualStrings("1 bytes after a run of 300 operations", failure_detail(&soak));
    try std.testing.expectEqual(@as(u32, 300), soak.failed_at);
    // The first failure stays the one replayed.
    soak = test_soak(&counting, &out);
    fail(&soak, "soak: first", .{}, "", .{});
    finish(&soak, 300);
    try std.testing.expectEqualStrings("soak: first", failure(&soak).?);
    counting.live = 0;
}

test "the byte budget ends a soak as held at the first epoch that reaches it" {
    const gpa = std.testing.allocator;
    const report = try gpa.create(sim_cluster.Report);
    defer gpa.destroy(report);
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = gpa };
    var soak: Soak = .{
        .plan = .{ .epoch_operations = 20, .minutes = 60, .bytes_max = 1 },
        .counting = &counting,
        .io = std.testing.io,
        .out = &out,
        .started = std.Io.Clock.boot.now(std.testing.io),
    };
    run(&soak, 7, .{}, report);
    try std.testing.expect(!report.failed);
    try std.testing.expect(soak.budget_reached.? >= 1);
    try std.testing.expect(failure(&soak) == null);
    try std.testing.expectEqual(@as(u32, 20), report.operations_run);
    try std.testing.expectEqual(@as(u32, 1), soak.epochs);
    try std.testing.expectEqual(@as(u64, 0), counting.live);
}

test "the checks: a counter past half its range, memory outgrowing its history, a stuck clock" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var counting: Counting = .{ .child = std.testing.allocator };
    const fresh: Soak = .{
        .plan = .{ .operations = 1000 },
        .counting = &counting,
        .io = std.testing.io,
        .out = &out,
        .started = std.Io.Clock.boot.now(std.testing.io),
    };
    var epoch: sim_cluster.Epoch = std.mem.zeroes(sim_cluster.Epoch);
    epoch.virtual_ms = 1000;
    epoch.revision = 10;
    epoch.store_keys = 99;

    var soak = fresh;
    epoch.job_ledger = sim_jobs.ledger_max / 2 + 1;
    judge(&soak, &epoch);
    try std.testing.expectEqualStrings("soak: start ledger past half its range", failure(&soak).?);
    epoch.job_ledger = 0;

    soak = fresh;
    counting.live = 110 * 20; // 20 bytes per item over 110 items.
    soak.epochs = warmup_epochs;
    judge(&soak, &epoch);
    try std.testing.expectEqual(@as(?u64, 20), soak.baseline_per_item);
    soak.last = epoch;
    epoch.virtual_ms += 1;
    epoch.revision += 1;
    counting.live = 111 * 81;
    soak.epochs += 1;
    judge(&soak, &epoch);
    const leak = "soak: memory grew faster than the history it holds";
    try std.testing.expectEqualStrings(leak, failure(&soak).?);
    try std.testing.expectEqualStrings(
        "81 live bytes per history item, 20 after the warm-up, limit 4 times",
        failure_detail(&soak),
    );
    counting.live = 0;

    soak = fresh;
    soak.last = epoch;
    judge(&soak, &epoch);
    try std.testing.expectEqualStrings(
        "soak: virtual time stood still over an epoch",
        failure(&soak).?,
    );
}
