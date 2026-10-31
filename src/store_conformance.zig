//! The store conformance suite: `zig build test-store -Dbackend=memory|sqlite [-Dseed=N]`.
//!
//! One suite, written against the `Store` interface only, that every backend must pass. It
//! covers what HANDOFF.md lists: compare-and-swap races between writers on separate connections,
//! watch ordering and no gaps under concurrent writers, watch resume after reconnect,
//! compaction errors for reads and for watches, a lease's expiry deleting its keys under one
//! revision, and a put that names a dead lease changing nothing. Details of the rules are in
//! `store.zig`; this file is the check that a backend keeps them.
//!
//! ## Determinism (docs/STYLE.md, "Where Zigcube departs")
//!
//! Every random choice comes from one seed. It is printed at the start of each test, and
//! `-Dseed=N` replays it. Where real threads race, the interleaving is up to the machine, so
//! those tests assert the invariants that must hold for every interleaving (no gap, no
//! duplicate, revision order equals commit order, every event delivered once and in order),
//! never one particular interleaving. `std.Thread` is allowed here and inside a backend; time
//! comes from a `ManualClock`, so lease tests never sleep.
//!
//! ## Connections
//!
//! `Harness.connect` gives a test a `Store`. For SQLite each is a separate connection to one
//! file, which is what the server's writers and the CLI's readers look like. For Postgres each
//! is a `PostgresStore` (its own pool of connections) on one schema, created fresh for the test
//! in the database named by `ZCUBE_TEST_POSTGRES` and dropped when it ends; lease time comes from
//! the injected clock, so the same lease tests run, without sleeping, on every backend. The
//! memory store is a single-threaded reference, so its connections share one instance behind a
//! mutex (`Serialized`); that proves the contract, not the memory store's own locking.
//!
//! The harness is `store_harness.zig`. The tests that use no threads are in
//! `store_conformance_single.zig`, which this file pulls in, so this one entry point still runs
//! the whole suite; the single-threaded half also runs against the memory store in `zig build
//! test` and under WASI in `zig build wasm-test`. What stays here is the racing tests.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const store = @import("store.zig");
const harness_mod = @import("store_harness.zig");

const Allocator = std.mem.Allocator;
const Revision = store.Revision;
const Store = store.Store;
const Harness = harness_mod.Harness;
const Connection = harness_mod.Connection;
const connections_max = harness_mod.connections_max;
const writers_count = harness_mod.writers_count;
const rounds_per_writer = harness_mod.rounds_per_writer;
const counter_increments = harness_mod.counter_increments;
const retries_max = harness_mod.retries_max;
const watch_polls_max = harness_mod.watch_polls_max;
const watch_wait_ms = harness_mod.watch_wait_ms;
const key_bytes = harness_mod.key_bytes;
const put_one = harness_mod.put_one;
const drain = harness_mod.drain;
const expect_status = harness_mod.expect_status;

test {
    _ = @import("store_conformance_single.zig");
}

fn start_gate() std.atomic.Value(bool) {
    return .init(false);
}

fn wait_gate(gate: *const std.atomic.Value(bool)) void {
    while (!gate.load(.acquire)) std.atomic.spinLoopHint();
}

/// Spawns one thread per job, opens the gate so they start together, and joins them all.
fn run_jobs(comptime Job: type, jobs: []Job, gate: *std.atomic.Value(bool)) !void {
    var threads: [connections_max]std.Thread = undefined;
    assert(jobs.len <= threads.len);
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    errdefer gate.store(true, .release); // Let the threads already started run to the end.
    for (jobs) |*job| {
        threads[spawned] = try std.Thread.spawn(.{}, Job.run, .{job});
        spawned += 1;
    }
    gate.store(true, .release);
}

// ---- Compare-and-swap races --------------------------------------------------------------------

const CreateRace = struct {
    conn: *Connection,
    id: u32,
    gate: *const std.atomic.Value(bool),
    won: bool = false,
    revision: Revision = 0,
    failed: bool = false,

    fn run(job: *CreateRace) void {
        wait_gate(job.gate);
        var diag: Diag = undefined;
        diag.reset();
        var value: [16]u8 = undefined;
        var audit: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&value, "writer-{d}", .{job.id}) catch return;
        const audit_name = std.fmt.bufPrint(&audit, "/c/audit-{d}", .{job.id}) catch return;
        const result = job.conn.interface().txn(.{
            .compares = &.{.{ .key = "/c/key", .mod_revision = 0 }},
            .on_success = &.{.{ .put = .{ .key = "/c/key", .value = text } }},
            .on_failure = &.{.{ .put = .{ .key = audit_name, .value = "lost" } }},
        }, &diag) catch {
            job.failed = true;
            return;
        };
        job.won = result.succeeded;
        job.revision = result.revision;
    }
};

test "cas: of several writers racing to create a key, exactly one wins" {
    // Goal: create-only compare-and-swap is atomic across connections. Method: each writer on its
    // own connection and thread creates "/c/key" if absent, and records an audit key if it
    // lost. Whatever the interleaving, exactly one create succeeds, the key holds the winner's
    // value, and the writers' revisions are exactly 1..n: one per write, no gap, no repeat.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var gate = start_gate();
    var jobs: [writers_count]CreateRace = undefined;
    for (&jobs, 0..) |*job, id| {
        job.* = .{ .conn = try harness.connect(), .id = @intCast(id), .gate = &gate };
    }
    try run_jobs(CreateRace, &jobs, &gate);

    var seen: [writers_count + 1]bool = @splat(false);
    var winners: u32 = 0;
    var winner: *const CreateRace = &jobs[0];
    for (&jobs) |*job| {
        try testing.expect(!job.failed);
        try testing.expect(job.revision >= 1 and job.revision <= writers_count);
        try testing.expect(!seen[job.revision]);
        seen[job.revision] = true;
        if (job.won) {
            winners += 1;
            winner = job;
        }
    }
    try testing.expectEqual(@as(u32, 1), winners);

    var diag: Diag = undefined;
    diag.reset();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = (try harness.connect()).interface();
    const got = try s.get(arena_state.allocator(), "/c/key", null, &diag);
    var expected: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, "writer-{d}", .{winner.id});
    try testing.expectEqualStrings(text, got.kv.?.value);
    try testing.expectEqual(winner.revision, got.kv.?.mod_revision);
    try testing.expectEqual(winner.revision, got.kv.?.create_revision);
    try expect_status(s, &diag, writers_count, 0);
}

const Counter = struct {
    conn: *Connection,
    gate: *const std.atomic.Value(bool),
    retries: u32 = 0,
    failed: bool = false,

    fn run(job: *Counter) void {
        wait_gate(job.gate);
        var diag: Diag = undefined;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        for (0..counter_increments) |_| {
            if (!job.increment(&arena_state, &diag)) {
                job.failed = true;
                return;
            }
        }
    }

    /// Read, add one, write back if nobody wrote in between; retry otherwise. True once
    /// committed.
    fn increment(job: *Counter, arena_state: *std.heap.ArenaAllocator, diag: *Diag) bool {
        const s = job.conn.interface();
        for (0..retries_max) |_| {
            diag.reset();
            _ = arena_state.reset(.retain_capacity);
            const got = s.get(arena_state.allocator(), "/n/counter", null, diag) catch return false;
            const kv = got.kv orelse return false;
            const current = std.fmt.parseInt(u32, kv.value, 10) catch return false;
            var text: [12]u8 = undefined;
            const next = std.fmt.bufPrint(&text, "{d}", .{current + 1}) catch return false;
            const result = s.txn(.{
                .compares = &.{.{ .key = "/n/counter", .mod_revision = kv.mod_revision }},
                .on_success = &.{.{ .put = .{ .key = "/n/counter", .value = next } }},
            }, diag) catch return false;
            if (result.succeeded) return true;
            job.retries += 1;
        }
        return false;
    }
};

test "cas: concurrent read-modify-write loses no update and takes one revision each" {
    // Goal: update-if-unchanged is atomic across connections. Method: writers increment one
    // counter through get + compare-and-swap, retrying when they lose. The final value must
    // be the number of increments (no lost update), and because a lost compare writes
    // nothing, the revision must be exactly 1 + the increments (a failed attempt takes none).
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var diag: Diag = undefined;
    diag.reset();
    const first = (try harness.connect()).interface();
    _ = try put_one(first, &diag, "/n/counter", "0");

    var gate = start_gate();
    var jobs: [writers_count]Counter = undefined;
    for (&jobs) |*job| job.* = .{ .conn = try harness.connect(), .gate = &gate };
    try run_jobs(Counter, &jobs, &gate);
    for (&jobs) |*job| try testing.expect(!job.failed);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try first.get(arena_state.allocator(), "/n/counter", null, &diag);
    const total: u32 = writers_count * counter_increments;
    var expected: [12]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, "{d}", .{total});
    try testing.expectEqualStrings(text, got.kv.?.value);
    try expect_status(first, &diag, 1 + total, 0);
}

// ---- Watch under concurrent writers -------------------------------------------------------------

const Planned = struct {
    key: [key_bytes]u8,
    key_len: u8,
    kind: store.EventKind,
    /// Under the watched prefix "/w/".
    watched: bool,

    fn slice(planned: *const Planned) []const u8 {
        return planned.key[0..planned.key_len];
    }
};

/// One transaction a writer made: its revision and the events it must have produced, in order.
const Committed = struct {
    revision: Revision = 0,
    count: u8 = 0,
    events: [3]Planned = undefined,

    fn add(plan: *Committed, kind: store.EventKind, key: []const u8) void {
        assert(plan.count < plan.events.len);
        var planned: Planned = .{
            .key = undefined,
            .key_len = @intCast(key.len),
            .kind = kind,
            .watched = std.mem.startsWith(u8, key, "/w/"),
        };
        @memcpy(planned.key[0..key.len], key);
        plan.events[plan.count] = planned;
        plan.count += 1;
    }

    fn add_put(plan: *Committed, comptime format: []const u8, args: anytype) void {
        var buffer: [key_bytes]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, format, args) catch unreachable; // 32 bytes fit.
        plan.add(.put, key);
    }
};

/// Decides what a writer does in `round`: one to three puts, sometimes with a delete of its
/// previous key, sometimes under a prefix nobody watches. `alive` is a key it may delete.
fn plan_round(id: u32, round: u32, random: std.Random, alive: *?Planned) Committed {
    var plan: Committed = .{};
    switch (random.uintLessThan(u32, 10)) {
        0...4 => {
            plan.add_put("/w/{d}/{d:0>3}", .{ id, round });
            alive.* = plan.events[0];
        },
        5, 6 => {
            plan.add_put("/w/{d}/{d:0>3}a", .{ id, round });
            plan.add_put("/w/{d}/{d:0>3}b", .{ id, round });
        },
        7 => {
            plan.add_put("/w/{d}/{d:0>3}", .{ id, round });
            const fresh = plan.events[0];
            if (alive.*) |old| plan.add(.delete, old.slice());
            alive.* = fresh;
        },
        8 => plan.add_put("/other/{d}/{d:0>3}", .{ id, round }),
        else => {
            plan.add_put("/w/{d}/{d:0>3}x", .{ id, round });
            plan.add_put("/other/{d}/{d:0>3}y", .{ id, round });
            plan.add_put("/w/{d}/{d:0>3}z", .{ id, round });
        },
    }
    assert(plan.count > 0);
    return plan;
}

fn commit_round(s: Store, plan: *Committed, diag: *Diag) bool {
    var ops: [3]store.Op = undefined;
    for (plan.events[0..plan.count], 0..) |*event, index| {
        ops[index] = switch (event.kind) {
            .put => .{ .put = .{ .key = event.slice(), .value = event.slice() } },
            .delete => .{ .delete = event.slice() },
        };
    }
    const result = s.txn(.{ .on_success = ops[0..plan.count] }, diag) catch return false;
    if (!result.succeeded) return false;
    plan.revision = result.revision;
    return true;
}

const Writer = struct {
    conn: *Connection,
    id: u32,
    seed: u64,
    gate: *const std.atomic.Value(bool),
    finished: *std.atomic.Value(u32),
    committed: [rounds_per_writer]Committed = undefined,
    rounds: u32 = 0,
    failed: bool = false,

    fn run(job: *Writer) void {
        defer _ = job.finished.fetchAdd(1, .release);
        wait_gate(job.gate);
        var prng: std.Random.DefaultPrng = .init(job.seed);
        var diag: Diag = undefined;
        diag.reset();
        var alive: ?Planned = null;
        for (0..rounds_per_writer) |round| {
            var plan = plan_round(job.id, @intCast(round), prng.random(), &alive);
            if (!commit_round(job.conn.interface(), &plan, &diag)) {
                job.failed = true;
                return;
            }
            job.committed[round] = plan;
            job.rounds += 1;
        }
    }
};

const Seen = struct {
    revision: Revision,
    kind: store.EventKind,
    key: [key_bytes]u8,
    key_len: u8,
};

/// Watches "/w/" from revision 1 while the writers run, checking each batch as it arrives,
/// and returns the head revision once the writers have finished and the watch has caught up.
fn collect_watch(
    s: Store,
    finished: *const std.atomic.Value(u32),
    seen: *std.ArrayList(Seen),
    diag: *Diag,
) !Revision {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var watch = try s.watch(.{ .prefix = "/w/", .from_revision = 1 }, diag);
    defer watch.close();
    var bookmark: Revision = 0;
    var last_event: Revision = 0;
    for (0..watch_polls_max) |_| {
        _ = arena_state.reset(.retain_capacity);
        const batch = try watch.next(arena_state.allocator(), watch_wait_ms, diag);
        try testing.expect(batch.revision >= bookmark);
        for (batch.events) |event| {
            // After the last bookmark, up to this one, and never in two batches: no gap, no repeat.
            try testing.expect(event.kv.mod_revision > bookmark);
            try testing.expect(event.kv.mod_revision <= batch.revision);
            try testing.expect(event.kv.mod_revision >= last_event);
            if (event.kv.mod_revision > last_event) last_event = event.kv.mod_revision;
            var entry: Seen = .{
                .revision = event.kv.mod_revision,
                .kind = event.kind,
                .key = undefined,
                .key_len = @intCast(event.kv.key.len),
            };
            @memcpy(entry.key[0..event.kv.key.len], event.kv.key);
            try seen.append(testing.allocator, entry);
        }
        bookmark = batch.revision;
        if (finished.load(.acquire) != writers_count) continue;
        const head = (try s.status(diag)).revision;
        if (bookmark >= head) return head;
    }
    return error.WatchDidNotCatchUp;
}

/// The writers' transactions indexed by revision; fails on a repeat or a hole.
fn index_by_revision(
    jobs: []const Writer,
    head: Revision,
    by_revision: []?*const Committed,
) !void {
    try testing.expectEqual(@as(usize, @intCast(head + 1)), by_revision.len);
    for (by_revision) |*slot| slot.* = null;
    for (jobs) |*job| {
        var previous: Revision = 0;
        for (job.committed[0..job.rounds]) |*commit| {
            try testing.expect(commit.revision > previous); // A writer's own order is kept.
            previous = commit.revision;
            try testing.expect(commit.revision >= 1 and commit.revision <= head);
            try testing.expect(by_revision[@intCast(commit.revision)] == null); // No repeat.
            by_revision[@intCast(commit.revision)] = commit;
        }
    }
    for (by_revision[1..]) |slot| try testing.expect(slot != null); // No hole.
}

test "watch: concurrent writers produce an ordered, gap-free stream, one batch per revision" {
    // Goal: the watch guarantee under load. Method: writers on separate connections commit
    // random one-to-three-key transactions (puts and deletes, some outside the watched prefix)
    // while this thread watches "/w/" from revision 1. Each writer remembers the revision and
    // events of every commit. Afterwards: the revisions are exactly 1..head (revision order is
    // commit order, none lost, none doubled), each writer's own commits are in order, and the
    // watch delivered precisely the watched events of every revision, in revision order and
    // in transaction order, with no revision split across batches.
    const harness = try Harness.start();
    defer harness.stop();
    errdefer harness.report_seed();
    var prng = harness.prng("watch-writers");
    var gate = start_gate();
    var finished: std.atomic.Value(u32) = .init(0);
    const jobs = try testing.allocator.alloc(Writer, writers_count);
    defer testing.allocator.free(jobs);
    for (jobs, 0..) |*job, id| {
        job.* = .{
            .conn = try harness.connect(),
            .id = @intCast(id),
            .seed = prng.random().int(u64),
            .gate = &gate,
            .finished = &finished,
        };
    }
    const watcher = (try harness.connect()).interface();
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(testing.allocator);
    var diag: Diag = undefined;
    diag.reset();
    var threads: [writers_count]std.Thread = undefined;
    for (jobs, &threads) |*job, *thread| thread.* = try std.Thread.spawn(.{}, Writer.run, .{job});
    gate.store(true, .release);
    const outcome = collect_watch(watcher, &finished, &seen, &diag);
    for (threads) |thread| thread.join();
    const head = try outcome;

    for (jobs) |job| try testing.expect(!job.failed);
    try testing.expectEqual(@as(Revision, writers_count * rounds_per_writer), head);
    const by_revision = try testing.allocator.alloc(?*const Committed, @intCast(head + 1));
    defer testing.allocator.free(by_revision);
    try index_by_revision(jobs, head, by_revision);
    try expect_stream(by_revision, seen.items);
    try expect_chain_recomputes(watcher, head);
}

/// Walks the whole log from revision 1 and recomputes `h(n)` with `store.chain_hash`: it equals
/// `hash_at(n)` for every `n` only if no two writers ever chained from the same parent.
fn expect_chain_recomputes(s: Store, head: Revision) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    var watch = try s.watch(.{ .prefix = "/", .from_revision = 1 }, &diag);
    defer watch.close();
    const events = try drain(&watch, arena_state.allocator(), head, &diag);
    var previous = store.hash_zero;
    var start: usize = 0;
    for (1..@as(usize, @intCast(head)) + 1) |revision| {
        var end = start;
        while (end < events.len and events[end].kv.mod_revision == revision) end += 1;
        try testing.expect(end > start);
        previous = store.chain_hash(previous, revision, events[start..end]);
        try testing.expectEqual(previous, try s.hash_at(revision, &diag));
        start = end;
    }
    try testing.expectEqual(events.len, start);
    try testing.expectEqual(previous, (try s.status(&diag)).hash);
}

/// The watched events of every revision, in order, must equal what the watch delivered.
fn expect_stream(by_revision: []const ?*const Committed, seen: []const Seen) !void {
    var next: usize = 0;
    for (by_revision[1..], 1..) |slot, revision| {
        for (slot.?.events[0..slot.?.count]) |*planned| {
            if (!planned.watched) continue;
            try testing.expect(next < seen.len);
            const got = seen[next];
            next += 1;
            try testing.expectEqual(@as(Revision, revision), got.revision);
            try testing.expectEqual(planned.kind, got.kind);
            try testing.expectEqualStrings(planned.slice(), got.key[0..got.key_len]);
        }
    }
    try testing.expectEqual(seen.len, next);
}
