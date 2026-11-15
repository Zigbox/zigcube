//! `zig build bench-watch`: the "Watch fan-out" row of docs/c1.md. One process holds a real
//! `Server` over SQLite and 50 agents, each a held `GET /v1/agent/nodes/<node>/watch`. The
//! benchmark preloads 2,000 assignments (40 per node), then runs rounds: one new assignment for
//! one node, and it counts which agents' polls the write woke and how long the woken one took to
//! answer. The line printed is the result, whatever it is: a miss is reported, not tuned around
//! (docs/briefs/c1-7.md). Not part of `zig build check`. Test-support code, so it may use
//! threads and the real clock (docs/STYLE.md).
//!
//! Exit code: 0 on PASS, 1 on MISS (too slow, an agent woken for another node's assignment, an
//! agent that could not hold its poll) and 2 when the run itself is invalid (the server wrote
//! something the benchmark did not, so the counts mean nothing).

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const server_mod = @import("server.zig");
const store = @import("store.zig");

const Diag = diag_mod.Diag;

const agents_count: u32 = 50;
const assignments_count: u32 = 2000;
const rounds_count: u32 = 100;
const limit_ms: u64 = 250;
const settle_ms: u32 = 60;
const answer_wait_ms: u32 = 3000;
const hold_ms: u32 = 20_000;
const db_dir = ".zig-cache/bench-watch";
const db_path = db_dir ++ "/zcube.db";

comptime {
    assert(assignments_count % agents_count == 0);
    assert(rounds_count * (settle_ms + 40) < hold_ms);
}

/// What each agent task leaves for the driver. Atomics: the driver reads while the agent runs.
const Agent = struct {
    wakes: std.atomic.Value(u32) = .init(0),
    arrival_ns: std.atomic.Value(i64) = .init(0),
    refused: std.atomic.Value(bool) = .init(false),
    broken: std.atomic.Value(bool) = .init(false),
};

const Shared = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    address: net.IpAddress,
    stopping: std.atomic.Value(bool) = .init(false),
    agents: [agents_count]Agent = @splat(.{}),
    from: store.Revision,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("bench-watch: ERROR {s}\n", .{@errorName(err)});
        return 2;
    };
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var threaded: std.Io.Threaded = .init(gpa, .{
        .concurrent_limit = .limited(constants.http_connections_max +
            constants.http_refusals_max + constants.server_threads_extra + agents_count + 16),
    });
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, db_dir) catch {};
    try cwd.createDirPath(io, db_dir);
    defer cwd.deleteTree(io, db_dir) catch {};

    var diag: Diag = undefined;
    diag.reset();
    const config: config_mod.Config = .{
        .insecure_listen = try config_mod.parse_listen("127.0.0.1:0", &diag),
        .store = .{ .sqlite = db_path },
        .create_store = true,
        .verbose = false,
        .quiet = true,
    };
    const server = server_mod.Server.start(gpa, io, config, .{
        .version = "bench",
        .report_failures = false,
        .log_requests = false,
    }, &diag) catch return error.ServerDidNotStart;
    defer server.stop();

    var head = try preload(gpa, server.shared.store);
    var shared: Shared = .{ .io = io, .gpa = gpa, .address = server.address(), .from = head + 1 };
    var futures: [agents_count]std.Io.Future(void) = undefined;
    for (&futures, 0..) |*future, index| {
        future.* = try io.concurrent(agent_main, .{ &shared, index });
    }
    defer {
        shared.stopping.store(true, .release);
        for (&futures) |*future| future.await(io);
    }
    const expected_holds: u32 = agents_count;
    var tries: u32 = 0;
    while (server.holds() < expected_holds and tries < 300) : (tries += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const held = server.holds();
    // The control plane may have written (it is the real one): a changed head means the counts
    // below are not about the benchmark's writes alone.
    const idle = try server.shared.store.status(&diag);
    if (idle.revision != head) {
        std.debug.print("bench-watch: INVALID the server wrote {d} revisions of its own\n", .{
            idle.revision - head,
        });
        return 2;
    }
    var latencies: [rounds_count]u64 = undefined;
    var woken_max: u32 = 0;
    var answered: u32 = 0;
    for (0..rounds_count) |round| {
        const node: u32 = @intCast(round % agents_count);
        const sample = try one_round(&shared, server.shared.store, node, round, &head);
        woken_max = @max(woken_max, sample.woken);
        if (sample.latency_ns) |ns| {
            latencies[answered] = ns;
            answered += 1;
        }
    }
    return report(&shared, held, latencies[0..answered], woken_max);
}

/// 2,000 assignments, 40 on each of 50 nodes, 16 to a transaction. Returns the head.
fn preload(gpa: std.mem.Allocator, backend: store.Store) !store.Revision {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    var head: store.Revision = 0;
    var index: u32 = 0;
    while (index < assignments_count) {
        diag.reset();
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var ops: [constants.store_txn_ops_max]store.Op = undefined;
        var used: usize = 0;
        while (used < ops.len and index < assignments_count) : (index += 1) {
            ops[used] = try assignment_put(arena, index % agents_count, index, &diag);
            used += 1;
        }
        const result = backend.txn(.{ .on_success = ops[0..used] }, &diag) catch
            return error.PreloadFailed;
        head = result.revision;
    }
    assert(head > 0);
    return head;
}

fn assignment_put(arena: std.mem.Allocator, node: u32, number: u32, diag: *Diag) !store.Op {
    var name_buffer: [32]u8 = undefined;
    const node_name = try std.fmt.bufPrint(&name_buffer, "node{d}", .{node});
    var replica_buffer: [32]u8 = undefined;
    const replica = try std.fmt.bufPrint(&replica_buffer, "bench-{d}", .{number});
    const key = records.assigned_key(node_name, replica);
    const record = records.assigned_replica(
        try arena.dupe(u8, replica),
        "bench",
        .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
        "benchmark",
    );
    const value = records.encode(arena, record, diag) catch return error.EncodeFailed;
    return .{ .put = .{ .key = try arena.dupe(u8, key.slice()), .value = value } };
}

const Sample = struct { woken: u32, latency_ns: ?u64 };

/// One new assignment for `node`: the time from just before its commit to the answer of the one
/// agent of that node, and how many agents answered in all, after a short settle.
fn one_round(
    shared: *Shared,
    backend: store.Store,
    node: u32,
    round: usize,
    head: *store.Revision,
) !Sample {
    var before: [agents_count]u32 = undefined;
    for (&before, &shared.agents) |*slot, *agent| slot.* = agent.wakes.load(.acquire);
    var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const number = assignments_count + @as(u32, @intCast(round));
    const op = try assignment_put(arena_state.allocator(), node, number, &diag);
    const began = std.Io.Clock.real.now(shared.io);
    const result = backend.txn(.{ .on_success = &.{op} }, &diag) catch return error.WriteFailed;
    head.* = result.revision;
    var waited: u32 = 0;
    const target = &shared.agents[node];
    while (target.wakes.load(.acquire) == before[node]) : (waited += 1) {
        if (waited >= answer_wait_ms) break;
        try shared.io.sleep(.fromMilliseconds(1), .awake);
    }
    var latency: ?u64 = null;
    if (target.wakes.load(.acquire) != before[node]) {
        const arrival = target.arrival_ns.load(.acquire);
        const started: i64 = @intCast(began.toNanoseconds());
        latency = @intCast(@max(arrival - started, 0));
    }
    try shared.io.sleep(.fromMilliseconds(settle_ms), .awake);
    var woken: u32 = 0;
    for (before, &shared.agents) |was, *agent| {
        if (agent.wakes.load(.acquire) != was) woken += 1;
    }
    return .{ .woken = woken, .latency_ns = latency };
}

fn report(shared: *const Shared, held: u32, latencies: []u64, woken_max: u32) u8 {
    var refused: u32 = 0;
    var broken: u32 = 0;
    for (&shared.agents) |*agent| {
        if (agent.refused.load(.acquire)) refused += 1;
        if (agent.broken.load(.acquire)) broken += 1;
    }
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const p50 = percentile(latencies, 50);
    const p99 = percentile(latencies, 99);
    const slow = p99 > limit_ms * std.time.ns_per_ms;
    const incomplete = latencies.len != rounds_count;
    const missed = slow or woken_max != 1 or refused > 0 or broken > 0 or incomplete;
    std.debug.print(
        "bench-watch: agents {d} assignments {d} held {d} refused {d} woken {d} of {d} " ++
            "p50 {d} ms p99 {d} ms limit {d} ms {s}\n",
        .{
            agents_count,                   assignments_count,        held,
            refused,                        woken_max,                agents_count,
            p50 / std.time.ns_per_ms,       p99 / std.time.ns_per_ms, limit_ms,
            if (missed) "MISS" else "PASS",
        },
    );
    if (missed) std.debug.print(
        "bench-watch: answered {d} of {d} rounds; broken agents {d}; http_holds_max is {d}\n",
        .{ latencies.len, rounds_count, broken, constants.http_holds_max },
    );
    return if (missed) 1 else 0;
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@min(rank, sorted.len) - 1];
}

// ---- An agent's poll ----------------------------------------------------------------------------

fn agent_main(shared: *Shared, index: usize) void {
    const agent = &shared.agents[index];
    var from = shared.from;
    while (!shared.stopping.load(.acquire)) {
        var path_buffer: [160]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buffer,
            "/v1/agent/nodes/node{d}/watch?from={d}&timeout={d}",
            .{ index, from, hold_ms },
        ) catch return;
        const answer = get(shared, path) orelse {
            agent.broken.store(true, .release);
            return;
        };
        defer shared.gpa.free(answer.raw);
        agent.arrival_ns.store(@intCast(answer.arrived_ns), .release);
        if (answer.status == 503) {
            agent.refused.store(true, .release);
            return;
        }
        if (answer.status != 200) {
            agent.broken.store(true, .release);
            return;
        }
        const seen = parse_answer(shared.gpa, answer.body) orelse {
            agent.broken.store(true, .release);
            return;
        };
        from = seen.revision + 1;
        if (seen.changed) _ = agent.wakes.fetchAdd(1, .release);
    }
}

const Answer = struct { status: u16, body: []const u8, raw: []u8, arrived_ns: i96 };

fn get(shared: *Shared, path: []const u8) ?Answer {
    const io = shared.io;
    var stream = shared.address.connect(io, .{ .mode = .stream }) catch return null;
    defer stream.close(io);
    var request_buffer: [256]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buffer,
        "GET {s} HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n",
        .{path},
    ) catch return null;
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(request) catch return null;
    writer.interface.flush() catch return null;
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const raw = reader.interface.allocRemaining(shared.gpa, .limited(1 << 20)) catch return null;
    const arrived = std.Io.Clock.real.now(io).toNanoseconds();
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse {
        shared.gpa.free(raw);
        return null;
    };
    const status = std.fmt.parseInt(u16, raw[9..12], 10) catch 0;
    return .{ .status = status, .body = raw[split + 4 ..], .raw = raw, .arrived_ns = arrived };
}

const Seen = struct { revision: store.Revision, changed: bool };

fn parse_answer(gpa: std.mem.Allocator, body: []const u8) ?Seen {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (value != .object) return null;
    const revision = value.object.get("revision") orelse return null;
    const changed = value.object.get("changed") orelse return null;
    if (revision != .integer) return null;
    if (changed != .bool) return null;
    return .{ .revision = @intCast(revision.integer), .changed = changed.bool };
}
