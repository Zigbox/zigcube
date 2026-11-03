//! The fetch plan of C2 (docs/swarm.md): how one node gets the chunks of a tree it lacks, from its
//! peers first and from the registry when it must, verifying every chunk by its hash.
//!
//! The plan is a state machine and does no I/O. The caller (the fetch worker, or the simulation)
//! asks `next(now_ms)` what to do, does it, and hands the outcome back with `receive`:
//!
//!     next ──► request{chunk, peer or registry} ──► (the caller asks that source)
//!     next ──► wait{until} ──► (the caller sleeps, or a result arrives) ──► next
//!     receive(bytes)   hashes them with BLAKE3: verified, or bad_hash (the peer is struck)
//!     receive(refused) the peer does not have it (a Bloom false positive); try another source
//!     receive(timeout) the same, and three in a row give the peer up
//!     next ──► done | failed{chunk}
//!
//! **Trust.** A peer is trusted for speed alone. `receive` computes the BLAKE3 hash of the bytes
//! and compares it with the hash the plan was given with the chunk list, so a chunk the plan calls
//! verified is a chunk whose hash matched: that is a property of the plan, not of its caller. A
//! peer that sends bytes that do not match is struck for this fetch (no more requests to it) and
//! reported once with ZC-W0601 (`take_blame`, `raise_blame`).
//!
//! **Where a chunk comes from.** A peer whose filter says it may hold the chunk, that is not
//! struck, gone or already tried for this chunk, has a free request slot and has bandwidth left.
//! When no such peer exists the chunk goes to the registry at once if some peer claimed it and
//! every one of them failed it, or if there is no peer to wait for; otherwise (nobody claims it)
//! after `peer_wait_ms` from the start, in which time a filter may come to show it
//! (docs/briefs/c2.md, O5). A chunk the registry fails `fetch_registry_attempts_max` times fails
//! the fetch.
//!
//! **Caps.** A token bucket per peer and one for the node (peers and registry together), each
//! holding one second of its rate and allowed to go into debt by one chunk, so bytes requested
//! never exceed `rate * elapsed + rate + chunk`.
//!
//! Core code: no clock (the caller passes `now_ms`), no allocation (the caller gives the state
//! slice), no I/O.

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root");
const chunk_summary = @import("chunk_summary.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

pub const Hash = chunk_summary.Hash;
const Blake3 = std.crypto.hash.Blake3;

/// The test-only fault of `sim-swarm`'s teeth run: `receive` accepts bytes without hashing them.
/// A constant only a root file can switch on (`sim_swarm_teeth_main.zig`), as the agent's is.
pub const fault_skip_verify: bool = if (@hasDecl(root, "swarm_teeth_skip_verify"))
    root.swarm_teeth_skip_verify
else
    false;

/// One chunk the node lacks: its hash and its length, from the tree's chunk list.
pub const ChunkRef = struct {
    hash: Hash,
    bytes: u32,
};

pub const Source = union(enum) {
    peer: u8,
    registry,
};

pub const Request = struct {
    /// Names this request in `receive`; never reused in a plan.
    id: u32,
    chunk: u32,
    source: Source,
    bytes: u32,
    /// The caller should report a timeout if it has no answer by then.
    deadline_ms: u64,
};

pub const Action = union(enum) {
    request: Request,
    /// Nothing to ask now. Call `next` again at this time (null: only when a result arrives).
    wait: ?u64,
    done,
    /// A chunk the registry could not give: the fetch cannot finish.
    failed: u32,
};

pub const Result = union(enum) {
    /// The source's answer to a request, to be hashed.
    bytes: []const u8,
    refused,
    timeout,
};

pub const Outcome = enum { verified, bad_hash, refused, timeout };

pub const Blame = struct {
    peer: u8,
    chunk: u32,
};

pub const Config = struct {
    peer_wait_ms: u32 = constants.fetch_peer_wait_ms,
    request_timeout_ms: u32 = constants.fetch_request_timeout_ms,
    peer_rate_bytes_per_s: u32 = constants.fetch_peer_rate_bytes_per_s,
    node_rate_bytes_per_s: u32 = constants.fetch_node_rate_bytes_per_s,
};

/// What the plan keeps per chunk. The caller provides one per chunk, zeroed or from `init`.
pub const ChunkState = struct {
    status: enum(u8) { pending, in_flight, done } = .pending,
    registry_attempts: u8 = 0,
    /// Peers that refused or timed out on this chunk, by index.
    tried: u16 = 0,
};

/// A token bucket in milli-bytes, so a refill by milliseconds loses nothing to rounding.
const Bucket = struct {
    rate_bytes_per_s: u32,
    milli: i64,
    last_ms: u64,

    fn init(rate_bytes_per_s: u32, now_ms: u64) Bucket {
        assert(rate_bytes_per_s > 0);
        return .{
            .rate_bytes_per_s = rate_bytes_per_s,
            .milli = burst(rate_bytes_per_s),
            .last_ms = now_ms,
        };
    }

    fn burst(rate_bytes_per_s: u32) i64 {
        return @as(i64, rate_bytes_per_s) * 1000;
    }

    fn refill(bucket: *Bucket, now_ms: u64) void {
        assert(now_ms >= bucket.last_ms);
        // The filled amount is capped, not the time: a bucket in debt for more than a second's
        // worth must still earn all the elapsed time. i128 cannot overflow here.
        const elapsed: i128 = now_ms - bucket.last_ms;
        const filled = @as(i128, bucket.milli) + elapsed * bucket.rate_bytes_per_s;
        bucket.milli = @intCast(@min(filled, burst(bucket.rate_bytes_per_s)));
        bucket.last_ms = now_ms;
    }

    fn ready(bucket: *const Bucket) bool {
        return bucket.milli >= 0;
    }

    fn spend(bucket: *Bucket, bytes: u32) void {
        bucket.milli -= @as(i64, bytes) * 1000;
    }

    /// When a bucket in debt is next ready.
    fn ready_at(bucket: *const Bucket) u64 {
        assert(!bucket.ready());
        const debt: u64 = @intCast(-bucket.milli);
        // Rate > 0, so the division cannot fail.
        const wait = std.math.divCeil(u64, debt, bucket.rate_bytes_per_s) catch unreachable;
        return bucket.last_ms + wait;
    }
};

const Peer = struct {
    filter: chunk_summary.Filter,
    struck: bool = false,
    /// Given up after `fetch_peer_timeouts_max` timeouts in a row.
    gone: bool = false,
    timeouts: u8 = 0,
    in_flight: u8 = 0,
    bucket: Bucket,
    /// Verified bytes taken from it.
    bytes: u64 = 0,
};

pub const Plan = struct {
    config: Config,
    chunks: []const ChunkRef,
    states: []ChunkState,
    peers: [constants.fetch_peers_max]Peer = undefined,
    peer_count: u32 = 0,
    started_ms: u64,
    now_ms: u64,
    node: Bucket,
    requests: [constants.fetch_in_flight_max]Request = undefined,
    request_live: [constants.fetch_in_flight_max]bool = @splat(false),
    in_flight: u32 = 0,
    serial: u32 = 0,
    first_pending: u32 = 0,
    done_count: u32 = 0,
    failed_chunk: ?u32 = null,
    blames: [constants.fetch_peers_max]Blame = undefined,
    blame_count: u32 = 0,
    blame_taken: u32 = 0,
    /// Bytes verified from the registry and from peers, and bytes asked of each (a request that
    /// failed still cost the node its bandwidth).
    registry_bytes: u64 = 0,
    peer_bytes: u64 = 0,
    registry_requested_bytes: u64 = 0,
    peer_requested_bytes: u64 = 0,

    /// A plan for `chunks` (distinct, the ones the node lacks), with `states` as long, which it
    /// clears. `chunks` and `states` must outlive the plan.
    pub fn init(config: Config, chunks: []const ChunkRef, states: []ChunkState, now_ms: u64) Plan {
        assert(chunks.len <= constants.fetch_chunks_max);
        assert(states.len == chunks.len);
        assert(config.request_timeout_ms > 0);
        @memset(states, .{});
        return .{
            .config = config,
            .chunks = chunks,
            .states = states,
            .started_ms = now_ms,
            .now_ms = now_ms,
            .node = Bucket.init(config.node_rate_bytes_per_s, now_ms),
        };
    }

    /// Adds a peer whose filter says what it holds; returns its index. The filter's bytes belong
    /// to the caller, who may update them while the fetch runs (a peer's summary changes as it
    /// fetches). Peers are added before the first `next`.
    pub fn add_peer(plan: *Plan, filter: chunk_summary.Filter) u8 {
        assert(plan.peer_count < constants.fetch_peers_max);
        assert(plan.serial == 0);
        const index: u8 = @intCast(plan.peer_count);
        plan.peers[index] = .{
            .filter = filter,
            .bucket = Bucket.init(plan.config.peer_rate_bytes_per_s, plan.now_ms),
        };
        plan.peer_count += 1;
        return index;
    }

    pub fn peer_slice(plan: *Plan) []Peer {
        return plan.peers[0..plan.peer_count];
    }

    /// Verified bytes taken from peer `index`.
    pub fn peer_verified_bytes(plan: *const Plan, index: u8) u64 {
        assert(index < plan.peer_count);
        return plan.peers[index].bytes;
    }

    pub fn is_struck(plan: *const Plan, index: u8) bool {
        assert(index < plan.peer_count);
        return plan.peers[index].struck;
    }

    /// The next peer struck for a bad chunk that has not been reported, once each.
    pub fn take_blame(plan: *Plan) ?Blame {
        assert(plan.blame_taken <= plan.blame_count);
        if (plan.blame_taken == plan.blame_count) return null;
        const blame = plan.blames[plan.blame_taken];
        plan.blame_taken += 1;
        return blame;
    }

    fn tick(plan: *Plan, now_ms: u64) void {
        assert(now_ms >= plan.now_ms); // Time only grows.
        plan.now_ms = now_ms;
        plan.node.refill(now_ms);
        for (plan.peers[0..plan.peer_count]) |*peer| peer.bucket.refill(now_ms);
    }

    /// What to do at `now_ms`.
    pub fn next(plan: *Plan, now_ms: u64) Action {
        plan.tick(now_ms);
        if (plan.failed_chunk) |chunk| return .{ .failed = chunk };
        if (plan.done_count == plan.chunks.len) {
            assert(plan.in_flight == 0); // A chunk is done only when its one request returned.
            return .done;
        }
        var wake: ?u64 = null;
        // Every request, to a peer or the registry, spends the node's bucket: with it empty or
        // the in-flight limit reached nothing can be issued, so skip the scan.
        if (!plan.node.ready()) wake = plan.node.ready_at();
        if (plan.in_flight < constants.fetch_in_flight_max and plan.node.ready()) {
            var index = plan.first_pending;
            while (index < plan.chunks.len) : (index += 1) {
                if (plan.states[index].status != .pending) {
                    if (index == plan.first_pending) plan.first_pending += 1;
                    continue;
                }
                switch (plan.decide(index, &wake)) {
                    .issue => |source| return .{ .request = plan.issue(index, source) },
                    .hold => {},
                }
            }
        }
        for (plan.request_live, plan.requests) |live, request| {
            if (live) wake = earliest(wake, request.deadline_ms);
        }
        // Something must wake the caller: a result, or a time. Else the plan would sleep for ever.
        if (wake == null) assert(plan.in_flight > 0);
        return .{ .wait = wake };
    }

    const Decision = union(enum) { issue: Source, hold };

    /// Where chunk `index` should be fetched from now, or why not yet; `wake` collects the times
    /// a hold ends.
    fn decide(plan: *Plan, index: u32, wake: *?u64) Decision {
        const chunk = &plan.chunks[index];
        const tried = plan.states[index].tried;
        var claimers: u32 = 0;
        // Struck or gone peers whose filters claim the chunk: tried, and never to be asked.
        var lost_claimers: u32 = 0;
        var open: u32 = 0;
        var live: u32 = 0;
        var best: ?u8 = null;
        for (plan.peers[0..plan.peer_count], 0..) |*peer, peer_index| {
            if (peer.struck or peer.gone) {
                if (peer.filter.maybe_has(&chunk.hash)) lost_claimers += 1;
                continue;
            }
            live += 1;
            if (!peer.filter.maybe_has(&chunk.hash)) continue;
            claimers += 1;
            if (tried & (@as(u16, 1) << @intCast(peer_index)) != 0) continue;
            open += 1;
            if (peer.in_flight >= constants.fetch_in_flight_per_peer_max) continue;
            if (!peer.bucket.ready()) {
                wake.* = earliest(wake.*, peer.bucket.ready_at());
                continue;
            }
            const candidate: u8 = @intCast(peer_index);
            if (best == null or plan.better(candidate, best.?)) best = candidate;
        }
        assert(open <= claimers);
        assert(claimers <= live);
        if (best != null or open == 0) {
            if (!plan.node.ready()) {
                wake.* = earliest(wake.*, plan.node.ready_at());
                return .hold;
            }
            if (best) |peer_index| return .{ .issue = .{ .peer = peer_index } };
        } else {
            return .hold; // Open peers are all busy or in debt; a result or the bucket wakes us.
        }
        // No peer is open for this chunk. Wait for one to claim it only if none ever did.
        if (claimers + lost_claimers == 0 and live > 0) {
            const deadline = plan.started_ms + plan.config.peer_wait_ms;
            if (plan.now_ms < deadline) {
                wake.* = earliest(wake.*, deadline);
                return .hold;
            }
        }
        return .{ .issue = .registry };
    }

    /// Whether peer `a` should serve a chunk before peer `b`: fewer requests in flight, then
    /// fewer bytes taken so far (so the load spreads), then the lower index.
    fn better(plan: *const Plan, a: u8, b: u8) bool {
        const peer_a = &plan.peers[a];
        const peer_b = &plan.peers[b];
        if (peer_a.in_flight != peer_b.in_flight) return peer_a.in_flight < peer_b.in_flight;
        if (peer_a.bytes != peer_b.bytes) return peer_a.bytes < peer_b.bytes;
        return a < b;
    }

    fn issue(plan: *Plan, index: u32, source: Source) Request {
        const chunk = &plan.chunks[index];
        assert(plan.states[index].status == .pending);
        assert(plan.in_flight < constants.fetch_in_flight_max);
        plan.serial += 1;
        const request: Request = .{
            .id = plan.serial,
            .chunk = index,
            .source = source,
            .bytes = chunk.bytes,
            .deadline_ms = plan.now_ms + plan.config.request_timeout_ms,
        };
        const slot = for (plan.request_live, 0..) |live, slot| {
            if (!live) break slot;
        } else unreachable; // `in_flight` < the table's size, so a slot is free.
        plan.requests[slot] = request;
        plan.request_live[slot] = true;
        plan.states[index].status = .in_flight;
        plan.in_flight += 1;
        plan.node.spend(chunk.bytes);
        switch (source) {
            .peer => |peer_index| {
                assert(plan.peers[peer_index].in_flight < constants.fetch_in_flight_per_peer_max);
                plan.peers[peer_index].in_flight += 1;
                plan.peers[peer_index].bucket.spend(chunk.bytes);
                plan.peer_requested_bytes += chunk.bytes;
            },
            .registry => plan.registry_requested_bytes += chunk.bytes,
        }
        return request;
    }

    /// Feeds back what became of request `id`. Hashes the bytes of an answer; returns whether the
    /// chunk is now held (`verified`) and, if not, why not.
    pub fn receive(plan: *Plan, id: u32, result: Result, now_ms: u64) Outcome {
        plan.tick(now_ms);
        const slot = for (plan.request_live, plan.requests, 0..) |live, request, slot| {
            if (live and request.id == id) break slot;
        } else unreachable; // A result for a request that is not in flight is the caller's bug.
        const request = plan.requests[slot];
        plan.request_live[slot] = false;
        plan.in_flight -= 1;
        switch (request.source) {
            .peer => |peer_index| plan.peers[peer_index].in_flight -= 1,
            .registry => {},
        }
        const chunk = &plan.chunks[request.chunk];
        assert(plan.states[request.chunk].status == .in_flight);
        switch (result) {
            .bytes => |bytes| {
                if (plan.accepts(chunk, bytes)) {
                    plan.finish(request);
                    return .verified;
                }
                plan.fail(request, .bad_hash);
                return .bad_hash;
            },
            .refused => {
                plan.fail(request, .refused);
                return .refused;
            },
            .timeout => {
                plan.fail(request, .timeout);
                return .timeout;
            },
        }
    }

    /// The one place bytes are judged: the right length and the right BLAKE3 hash.
    fn accepts(plan: *const Plan, chunk: *const ChunkRef, bytes: []const u8) bool {
        _ = plan;
        if (fault_skip_verify) return true;
        if (bytes.len != chunk.bytes) return false;
        var digest: Hash = undefined;
        Blake3.hash(bytes, &digest, .{});
        return std.mem.eql(u8, &digest, &chunk.hash);
    }

    fn finish(plan: *Plan, request: Request) void {
        plan.states[request.chunk].status = .done;
        plan.done_count += 1;
        assert(plan.done_count <= plan.chunks.len);
        switch (request.source) {
            .peer => |peer_index| {
                const peer = &plan.peers[peer_index];
                peer.bytes += request.bytes;
                peer.timeouts = 0;
                plan.peer_bytes += request.bytes;
            },
            .registry => plan.registry_bytes += request.bytes,
        }
    }

    /// A request that gave no chunk: the chunk goes back to pending, and the source is marked.
    fn fail(plan: *Plan, request: Request, why: Outcome) void {
        assert(why != .verified);
        const state = &plan.states[request.chunk];
        state.status = .pending;
        plan.first_pending = @min(plan.first_pending, request.chunk);
        switch (request.source) {
            .peer => |peer_index| {
                const peer = &plan.peers[peer_index];
                state.tried |= @as(u16, 1) << @intCast(peer_index);
                if (why == .bad_hash) plan.strike(peer_index, request.chunk);
                if (why == .timeout) {
                    peer.timeouts += 1;
                    if (peer.timeouts >= constants.fetch_peer_timeouts_max) peer.gone = true;
                }
            },
            .registry => {
                state.registry_attempts += 1;
                if (state.registry_attempts >= constants.fetch_registry_attempts_max) {
                    plan.failed_chunk = request.chunk;
                }
            },
        }
    }

    fn strike(plan: *Plan, peer_index: u8, chunk: u32) void {
        const peer = &plan.peers[peer_index];
        if (peer.struck) return; // Reported once: later bad answers in flight add nothing.
        peer.struck = true;
        assert(plan.blame_count < plan.blames.len);
        plan.blames[plan.blame_count] = .{ .peer = peer_index, .chunk = chunk };
        plan.blame_count += 1;
    }
};

fn earliest(current: ?u64, candidate: u64) ?u64 {
    if (current) |value| return @min(value, candidate);
    return candidate;
}

/// Raises ZC-W0601 for a struck peer, naming it by `peer_name` (its node name or address).
pub fn raise_blame(
    diag: *diag_mod.Diag,
    blame: Blame,
    peer_name: []const u8,
    chunks: u32,
) void {
    assert(blame.chunk < chunks);
    diag.raise(.W0601);
    diag.cause("peer {s} sent chunk {d} of {d} with bytes that do not match its hash", .{
        peer_name, blame.chunk + 1, chunks,
    });
    diag.fix(.{ .sentence = "no action needed for this fetch; check that node's store and disk" });
}

// ---- Tests -------------------------------------------------------------------------------------

const chunk_bytes_test = 64;
const chunks_test = 24;

/// Chunk `index`'s bytes, the same every time.
fn content(index: u32, out: *[chunk_bytes_test]u8) void {
    var prng = std.Random.DefaultPrng.init(0xc0de + index);
    prng.random().bytes(out);
}

/// A tree of `chunks_test` chunks and a filter holding all of them (or none).
const Fixture = struct {
    chunks: [chunks_test]ChunkRef = undefined,
    states: [chunks_test]ChunkState = undefined,
    full: [64]u8 = undefined,
    empty: [64]u8 = undefined,

    fn setup(fixture: *Fixture) void {
        var full = chunk_summary.Filter.init(&fixture.full);
        _ = chunk_summary.Filter.init(&fixture.empty);
        for (&fixture.chunks, 0..) |*chunk, index| {
            var bytes: [chunk_bytes_test]u8 = undefined;
            content(@intCast(index), &bytes);
            chunk.* = .{ .hash = undefined, .bytes = chunk_bytes_test };
            Blake3.hash(&bytes, &chunk.hash, .{});
            full.add(&chunk.hash);
        }
    }

    fn plan(fixture: *Fixture, config: Config) Plan {
        return Plan.init(config, &fixture.chunks, &fixture.states, 1000);
    }
};

const Behavior = enum { honest, corrupt, short, refuse, silent };

const Log = struct {
    to_peer: [constants.fetch_peers_max]u32 = @splat(0),
    to_registry: u32 = 0,
    /// A request made to a peer after it was struck.
    after_strike: u32 = 0,
    first_registry_ms: ?u64 = null,
    verified: u32 = 0,
    end_ms: u64 = 0,
};

/// Plays `plan` against peers with the given behaviours and a registry with its own, instantly
/// (a silent source times out at its deadline). Returns how it ended.
fn drive(plan: *Plan, peers: []const Behavior, registry: Behavior, log: *Log) Action {
    var now: u64 = plan.now_ms;
    for (0..10_000) |_| {
        const action = plan.next(now);
        switch (action) {
            .request => |request| {
                var bytes: [chunk_bytes_test]u8 = undefined;
                content(request.chunk, &bytes);
                const behavior = switch (request.source) {
                    .peer => |index| peers[index],
                    .registry => registry,
                };
                switch (request.source) {
                    .peer => |index| {
                        log.to_peer[index] += 1;
                        if (plan.is_struck(index)) log.after_strike += 1;
                    },
                    .registry => {
                        log.to_registry += 1;
                        if (log.first_registry_ms == null) log.first_registry_ms = now;
                    },
                }
                const result: Result = switch (behavior) {
                    .honest => .{ .bytes = &bytes },
                    .corrupt => blk: {
                        bytes[0] ^= 1;
                        break :blk .{ .bytes = &bytes };
                    },
                    .short => .{ .bytes = bytes[0 .. chunk_bytes_test - 1] },
                    .refuse => .refused,
                    .silent => .timeout,
                };
                if (behavior == .silent) now = request.deadline_ms;
                if (plan.receive(request.id, result, now) == .verified) log.verified += 1;
            },
            .wait => |until| now = until.?,
            .done, .failed => {
                log.end_ms = now;
                return action;
            },
        }
    }
    unreachable; // A plan that does not finish in 10,000 steps is a plan that loops.
}

test "peers that hold everything serve everything, and the registry is not asked" {
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    _ = plan.add_peer(.view(&fixture.full));
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{ .honest, .honest }, .honest, &log));
    try std.testing.expectEqual(@as(u32, 0), log.to_registry);
    try std.testing.expectEqual(@as(u32, chunks_test), log.to_peer[0] + log.to_peer[1]);
    // The load spreads: neither peer serves more than all but a few.
    try std.testing.expect(log.to_peer[0] >= 8 and log.to_peer[1] >= 8);
    try std.testing.expectEqual(@as(u64, chunks_test * chunk_bytes_test), plan.peer_bytes);
    try std.testing.expectEqual(@as(u64, 0), plan.registry_bytes);
    try std.testing.expectEqual(@as(?Blame, null), plan.take_blame());
}

test "a corrupt peer is struck, reported once, and its chunks come from the other peer" {
    // Goal: c2.md's acceptance test. Method: peer 0 flips a bit in every chunk; peer 1 is honest.
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    _ = plan.add_peer(.view(&fixture.full));
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{ .corrupt, .honest }, .honest, &log));
    try std.testing.expect(plan.is_struck(0));
    try std.testing.expect(!plan.is_struck(1));
    try std.testing.expectEqual(@as(u32, 0), log.after_strike);
    try std.testing.expectEqual(@as(u32, 0), log.to_registry);
    try std.testing.expectEqual(@as(u64, 0), plan.peer_verified_bytes(0));
    const blame = plan.take_blame().?;
    try std.testing.expectEqual(@as(u8, 0), blame.peer);
    try std.testing.expectEqual(@as(?Blame, null), plan.take_blame());
}

test "a peer that sends too few bytes is as bad as one that sends wrong ones" {
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{.short}, .honest, &log));
    try std.testing.expect(plan.is_struck(0));
    try std.testing.expectEqual(@as(u32, chunks_test), log.to_registry);
    try std.testing.expectEqual(@as(u32, 1), log.to_peer[0]);
}

test "all peers corrupt means the registry, at once" {
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    _ = plan.add_peer(.view(&fixture.full));
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{ .corrupt, .corrupt }, .honest, &log));
    try std.testing.expect(plan.is_struck(0) and plan.is_struck(1));
    try std.testing.expectEqual(@as(u32, chunks_test), log.to_registry);
    try std.testing.expectEqual(@as(u64, 0), plan.peer_bytes);
    try std.testing.expectEqual(@as(u64, chunks_test * chunk_bytes_test), plan.registry_bytes);
    // No waiting for a peer that has been ruled out: the clock did not move.
    try std.testing.expectEqual(@as(u64, 1000), log.end_ms);
    var count: u32 = 0;
    while (plan.take_blame()) |_| count += 1;
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "no peer at all means the registry at once; peers that claim nothing mean after the wait" {
    var fixture: Fixture = .{};
    fixture.setup();
    {
        var plan = fixture.plan(.{});
        var log: Log = .{};
        try std.testing.expectEqual(Action.done, drive(&plan, &.{}, .honest, &log));
        try std.testing.expectEqual(@as(u32, chunks_test), log.to_registry);
        try std.testing.expectEqual(@as(?u64, 1000), log.first_registry_ms);
    }
    {
        var plan = fixture.plan(.{ .peer_wait_ms = 5000 });
        _ = plan.add_peer(.view(&fixture.empty));
        var log: Log = .{};
        try std.testing.expectEqual(Action.done, drive(&plan, &.{.honest}, .honest, &log));
        try std.testing.expectEqual(@as(u32, 0), log.to_peer[0]);
        try std.testing.expectEqual(@as(?u64, 6000), log.first_registry_ms);
    }
}

test "a chunk only a struck peer claimed goes to the registry at once, not after the wait" {
    // Goal: the liar's chunks do not wait peer_wait_ms for a peer that claims nothing. Method: one
    // corrupt peer that claims everything, one honest peer that claims nothing.
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{ .peer_wait_ms = 30_000 });
    _ = plan.add_peer(.view(&fixture.full));
    _ = plan.add_peer(.view(&fixture.empty));
    var log: Log = .{};
    try std.testing.expectEqual(
        Action.done,
        drive(&plan, &.{ .corrupt, .honest }, .honest, &log),
    );
    try std.testing.expectEqual(@as(u32, 0), log.after_strike);
    try std.testing.expect(log.first_registry_ms.? < 1000 + 30_000);
    try std.testing.expect(log.end_ms < 1000 + 30_000);
}

test "a filter that comes to show a chunk during the wait wins over the registry" {
    // Goal: O5. Method: the peer's filter is empty at the start; the caller fills its bytes in
    // while the plan waits, as an agent does when a peer's summary is read again.
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{ .peer_wait_ms = 5000 });
    _ = plan.add_peer(.view(&fixture.empty));
    const first = plan.next(1000);
    try std.testing.expectEqual(@as(?u64, 6000), first.wait);
    @memcpy(&fixture.empty, &fixture.full);
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{.honest}, .honest, &log));
    try std.testing.expectEqual(@as(u32, 0), log.to_registry);
    try std.testing.expectEqual(@as(u32, chunks_test), log.to_peer[0]);
}

test "a refusing peer is tried once per chunk, then the registry; silence gives a peer up" {
    var fixture: Fixture = .{};
    fixture.setup();
    {
        var plan = fixture.plan(.{});
        _ = plan.add_peer(.view(&fixture.full));
        var log: Log = .{};
        try std.testing.expectEqual(Action.done, drive(&plan, &.{.refuse}, .honest, &log));
        try std.testing.expectEqual(@as(u32, chunks_test), log.to_peer[0]);
        try std.testing.expectEqual(@as(u32, chunks_test), log.to_registry);
        try std.testing.expect(!plan.is_struck(0)); // A refusal is not blame.
        try std.testing.expectEqual(@as(?Blame, null), plan.take_blame());
    }
    {
        var plan = fixture.plan(.{});
        _ = plan.add_peer(.view(&fixture.full));
        var log: Log = .{};
        try std.testing.expectEqual(Action.done, drive(&plan, &.{.silent}, .honest, &log));
        try std.testing.expectEqual(constants.fetch_peer_timeouts_max, log.to_peer[0]);
        try std.testing.expectEqual(@as(u32, chunks_test), log.to_registry);
        try std.testing.expect(plan.peers[0].gone);
    }
}

test "the registry failing a chunk too often fails the fetch" {
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    var log: Log = .{};
    const action = drive(&plan, &.{}, .corrupt, &log);
    try std.testing.expectEqual(@as(u32, 0), action.failed);
    try std.testing.expectEqual(constants.fetch_registry_attempts_max, log.to_registry);
    try std.testing.expectEqual(@as(u32, 0), plan.done_count);
}

test "caps hold: bytes asked of a peer and of the node stay within rate * time + burst" {
    // Goal: the per-peer and per-node caps. Method: 24 chunks of 64 bytes against a peer cap of
    // 100 bytes/s and a node cap of 150 bytes/s, answered instantly, so only the buckets slow it.
    // Bytes asked by the end must not exceed rate * elapsed + one second's burst + one chunk.
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{ .peer_rate_bytes_per_s = 100, .node_rate_bytes_per_s = 150 });
    _ = plan.add_peer(.view(&fixture.full));
    _ = plan.add_peer(.view(&fixture.full));
    var log: Log = .{};
    try std.testing.expectEqual(Action.done, drive(&plan, &.{ .honest, .honest }, .honest, &log));
    const elapsed_ms = log.end_ms - 1000;
    const total = chunks_test * chunk_bytes_test;
    // Each bound is rate * elapsed + burst + chunk.
    const node_bound = 150 * elapsed_ms / 1000 + 150 + chunk_bytes_test;
    try std.testing.expect(total <= node_bound);
    try std.testing.expect(total > 150 * elapsed_ms / 1000); // And the cap did slow it down.
    for (log.to_peer[0..2]) |count| {
        const allowed = 100 * elapsed_ms / 1000 + 100 + chunk_bytes_test;
        try std.testing.expect(count * chunk_bytes_test <= allowed);
    }
    // 1536 bytes at 150/s is about nine seconds, not zero.
    try std.testing.expect(elapsed_ms >= 8000);
}

test "a chunk is never accepted unverified" {
    // Goal: the negative space. Method: hand `receive` every kind of wrong answer for a chunk
    // and see that none is verified; then the right one.
    var fixture: Fixture = .{};
    fixture.setup();
    var good: [chunk_bytes_test]u8 = undefined;
    content(0, &good);
    var flipped = good;
    flipped[chunk_bytes_test - 1] ^= 0x80;
    const wrong: [chunk_bytes_test + 1]u8 = good ++ [_]u8{0};
    const answers = [_][]const u8{ &flipped, good[0..10], &wrong, &.{} };
    for (answers) |answer| {
        var plan = fixture.plan(.{});
        _ = plan.add_peer(.view(&fixture.full));
        const request = plan.next(1000).request;
        try std.testing.expectEqual(@as(u32, 0), request.chunk);
        const outcome = plan.receive(request.id, .{ .bytes = answer }, 1000);
        try std.testing.expectEqual(Outcome.bad_hash, outcome);
        try std.testing.expectEqual(@as(u32, 0), plan.done_count);
    }
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    const request = plan.next(1000).request;
    const outcome = plan.receive(request.id, .{ .bytes = &good }, 1000);
    try std.testing.expectEqual(Outcome.verified, outcome);
    try std.testing.expectEqual(@as(u32, 1), plan.done_count);
}

test "requests are bounded in flight, in all and to one peer" {
    var fixture: Fixture = .{};
    fixture.setup();
    var plan = fixture.plan(.{});
    _ = plan.add_peer(.view(&fixture.full));
    var issued: u32 = 0;
    while (true) {
        switch (plan.next(1000)) {
            .request => issued += 1,
            .wait => break,
            else => unreachable,
        }
    }
    // One peer: its own limit applies, then the plan waits for results (the registry is not
    // asked while an open peer is merely busy).
    try std.testing.expectEqual(constants.fetch_in_flight_per_peer_max, issued);
}

test "a struck peer is reported with a coded diagnostic that names it" {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    raise_blame(&diag, .{ .peer = 1, .chunk = 4 }, "node2", 24);
    try std.testing.expectEqualStrings("W0601", @tagName(diag.entry().code));
    try std.testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "node2") != null);
}

test "the test-only fault is off in this build" {
    try std.testing.expect(!fault_skip_verify);
}
