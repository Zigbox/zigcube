//! B4 slice 3: workload certificates in the cluster simulation (docs/briefs/b4.md, "Slices";
//! docs/core.md, "sim-c1"). A relayed run's supervisor asks the server for its certificate,
//! opens relayed connections with it while it is valid, and closes them when the run is told to
//! stop or ends. The server's side is `issue`: the issuance rule of `job_cert.decide` over the
//! store as committed. Until B7 the request is not authenticated (O4), so anyone may ask for any
//! run: `forge` asks as a stale epoch, another node, an ended run and another image.
//!
//! Three checks, each with a tooth (`c1_teeth.zig`):
//! - R4: a certificate is issued only to the node that holds the run's claim, at the epoch the
//!   claim, the status and the assignment name, for a run whose ending is not known. Judged at
//!   each issue against the revision the issuer read (`job_cert_stale` breaks it).
//! - R5: no certificate outlives the claim's start + `deadline_ms` + `grace_ms` +
//!   `workload_cert_slack_ms` (`job_cert_long` breaks it).
//! - R6: no relayed connection is open after its run's node reported the run's ending (the
//!   node's `/job-observed` record of that run says `stopped`). Judged at every revision under
//!   `--c1` and on every tick (`relay_conn_leak` breaks it).
//!
//! The checker reads the records itself and does not call `job_cert`: it would otherwise judge
//! the rule by the rule. The model draws from its own generator, so a world's other draws are
//! the ones they were before B4.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const job_cert = @import("job_cert.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const store = @import("store.zig");

/// How often a supervisor without a certificate asks again (the run has not started yet in the
/// store's eyes, or its link was cut).
pub const ask_interval_ms: u64 = 1000;
/// The connections one run keeps open at most.
pub const conns_max: u32 = 4;
/// One tick in this many, a forged ask (per mille).
const forge_per_mille: u32 = 150;

pub const State = struct {
    prng: std.Random.DefaultPrng,
    asks: u32 = 0,
    issued: u32 = 0,
    refused: u32 = 0,
    /// The issuer could not read a record it needs (the job was deleted, say): no certificate.
    unread: u32 = 0,
    forged: u32 = 0,
    /// Forged asks that got a certificate (none, unless a tooth is on).
    forged_issued: u32 = 0,
    /// Refusals by the rule's reason, forged asks included (`job_cert.Refusal`).
    by_reason: [reasons]u32 = @splat(0),
    /// The first of R4 to R6 to fail; the cluster's safety check reports it.
    violation: ?[]const u8 = null,

    pub fn init(seed: u64) State {
        return .{ .prng = .init(seed ^ 0xb4_ce27_0000_0003) };
    }

    fn fail(state: *State, found: []const u8) void {
        if (state.violation == null) state.violation = found;
    }
};

const refusal_names = @typeInfo(job_cert.Refusal).error_set.error_names.?;
const reasons = refusal_names.len;

fn reason_index(refusal: job_cert.Refusal) usize {
    inline for (refusal_names, 0..) |name, index| {
        if (refusal == @field(job_cert.Refusal, name)) return index;
    }
    unreachable; // The loop covers every member of the set.
}

/// The names of `by_reason`'s slots, for the report.
pub fn reason_name(index: usize) []const u8 {
    assert(index < reasons);
    return refusal_names[index];
}

pub const Outcome = union(enum) {
    issued: job_cert.Subject,
    refused: job_cert.Refusal,
    unread,
};

fn Found(comptime T: type) type {
    return struct { rec: T, kv: store.KeyValue };
}

fn get(comptime T: type, ctx: *const controller.Context, key: []const u8) ?Found(T) {
    ctx.diag.reset();
    const got = ctx.store.get(ctx.arena, key, null, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const kv = got.kv orelse return null;
    const rec = records.read(T, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    return .{ .rec = rec, .kv = kv };
}

/// The server's side: the records the issuance rule needs, read from the store as committed, and
/// the rule's verdict. The claim and the assignment are those of the node the status names (the
/// node the server holds the run on), or of the asking node while the status names none.
pub fn issue(ctx: *const controller.Context, job: []const u8, ask: job_cert.Ask) Outcome {
    const spec = get(records.Job, ctx, records.job_key(job).slice()) orelse return .unread;
    const status = get(records.JobStatus, ctx, records.job_status_key(job).slice()) orelse
        return .unread;
    const holder = status.rec.node orelse ask.node;
    const claim = get(records.JobObserved, ctx, records.job_observed_key(holder, job).slice());
    var assignment: ?job_cert.Assignment = null;
    if (claim) |held| {
        const key = records.assigned_key(holder, held.rec.run);
        if (get(records.Assigned, ctx, key.slice())) |placed| {
            assignment = .{ .node = holder, .epoch = placed.kv.mod_revision };
        }
    }
    const held: ?records.JobObserved = if (claim) |found| found.rec else null;
    const subject = job_cert.decide(spec.rec, status.rec, held, assignment, ask) catch |refusal|
        return .{ .refused = refusal };
    return .{ .issued = subject };
}

/// R4 and R5 for a certificate just issued in answer to `ask`, read from the same revision.
pub fn issued_problem(
    ctx: *const controller.Context,
    job: []const u8,
    ask: job_cert.Ask,
    subject: *const job_cert.Subject,
) ?[]const u8 {
    if (!std.mem.eql(u8, subject.name, job)) return "R4: a certificate names another job";
    const claim_key = records.job_observed_key(ask.node, job);
    const claim = get(records.JobObserved, ctx, claim_key.slice()) orelse
        return "R4: a certificate was issued to a node that holds no claim on the run";
    if (ask.epoch != claim.rec.assignment) {
        return "R4: a certificate was issued for a stale epoch";
    }
    if (subject.placement_epoch != claim.rec.assignment) {
        return "R4: a certificate names another epoch than the run's claim";
    }
    if (claim.rec.status == .stopped) {
        return "R4: a certificate was issued for a run whose node reported its ending";
    }
    const placed_key = records.assigned_key(ask.node, claim.rec.run);
    const placed = get(records.Assigned, ctx, placed_key.slice()) orelse
        return "R4: a certificate was issued for a run not assigned to the node";
    if (placed.kv.mod_revision != claim.rec.assignment) {
        return "R4: a certificate was issued for a stale epoch";
    }
    const status = get(records.JobStatus, ctx, records.job_status_key(job).slice()) orelse
        return "R4: a certificate was issued for a run with no status";
    if (records.job_state_terminal(status.rec.state)) {
        return "R4: a certificate was issued for an ended run";
    }
    const spec = get(records.Job, ctx, records.job_key(job).slice()) orelse
        return "R4: a certificate was issued for a job with no record";
    const started = claim.rec.started_at_ms orelse
        return "R4: a certificate was issued for a run that has not started";
    const bound = started +| spec.rec.deadline_ms +| spec.rec.grace_ms +|
        constants.workload_cert_slack_ms;
    if (subject.lifetime.not_after_ms > bound) {
        return "R5: a certificate outlives its run's start, deadline, grace and slack";
    }
    return null;
}

/// Asks for `job` and judges what comes back: R4 and R5 if a certificate was issued.
pub fn ask_and_judge(
    state: *State,
    ctx: *const controller.Context,
    job: []const u8,
    ask: job_cert.Ask,
    forged: bool,
) ?job_cert.Subject {
    state.asks += 1;
    state.forged += @intFromBool(forged);
    switch (issue(ctx, job, ask)) {
        .unread => {
            state.unread += 1;
            return null;
        },
        .refused => |refusal| {
            state.refused += 1;
            state.by_reason[reason_index(refusal)] += 1;
            return null;
        },
        .issued => |subject| {
            state.issued += 1;
            state.forged_issued += @intFromBool(forged);
            if (issued_problem(ctx, job, ask, &subject)) |found| state.fail(found);
            return subject;
        },
    }
}

pub fn label_of(labels: []const runtime.Label, key: []const u8) ?[]const u8 {
    for (labels) |label| {
        if (std.mem.eql(u8, label.key, key)) return label.value;
    }
    return null;
}

/// The placement epoch a container was made under (its `zcube.created` label).
pub fn epoch_of(labels: []const runtime.Label) ?u64 {
    const text = label_of(labels, runtime.label_created) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// R6 for one container with relayed connections open on `node`: its node has not reported the
/// run's ending.
pub fn conns_problem(
    ctx: *const controller.Context,
    node: []const u8,
    run: []const u8,
    labels: []const runtime.Label,
) ?[]const u8 {
    const job = label_of(labels, runtime.label_job) orelse return null;
    const epoch = epoch_of(labels) orelse return null;
    const claim = get(records.JobObserved, ctx, records.job_observed_key(node, job).slice()) orelse
        return null;
    if (!std.mem.eql(u8, claim.rec.run, run)) return null;
    if (claim.rec.assignment != epoch) return null;
    if (claim.rec.status != .stopped) return null;
    return "R6: a relayed connection is open after its run's ending was reported";
}

/// The kinds of forged ask (`forge`).
pub const Forgery = enum { stale_epoch, other_node, ended, other_image };

/// A forged ask about a run that `node` holds (or held) under `epoch`, made as `forgery` from
/// `other` (another node's name). Returns null when that forgery cannot be made of this run.
pub fn forge(
    state: *State,
    forgery: Forgery,
    node: []const u8,
    other: []const u8,
    epoch: u64,
    digest: [32]u8,
    now_ms: u64,
) ?job_cert.Ask {
    const random = state.prng.random();
    var ask: job_cert.Ask = .{
        .node = node,
        .epoch = epoch,
        .image_digest = digest,
        .now_ms = now_ms,
    };
    switch (forgery) {
        .stale_epoch => {
            // An earlier epoch, as a node that missed the run's move would hold.
            if (epoch <= 1) return null;
            ask.epoch = epoch - 1 - random.uintLessThan(u64, @min(epoch - 1, 1000));
        },
        .other_node => {
            if (std.mem.eql(u8, other, node)) return null;
            ask.node = other;
        },
        .ended => {},
        .other_image => ask.image_digest[random.uintLessThan(usize, 32)] ^= 0x5a,
    }
    assert(ask.epoch <= epoch);
    return ask;
}

/// One tick of every relayed run's supervisor, on every node whose link to the server is not
/// cut: a run without a certificate asks for one (once per `ask_interval_ms`), and a run with one
/// opens and closes connections while it is valid. Then, now and then, a forged ask. `nodes` are
/// the cluster's nodes and `net` its network (`sim_cluster.zig`).
///
/// The issuer's `now` is the asking node's clock. A run's `started_at_ms` is the time its node
/// read when it started the run: Unix milliseconds on a real node, as the server's clock is, so
/// the rule compares the two. A simulated node's clock has an offset of its own (`sim_clock.zig`),
/// and the server's would mean nothing next to it; the node's reading stands for a server whose
/// wall clock agrees with the node's, within the simulated rate error.
pub fn supervise(
    state: *State,
    ctx: *const controller.Context,
    nodes: anytype,
    net: anytype,
) void {
    for (nodes) |node| {
        const now_ms = node.nclock.clock().now_ms();
        const faults = net.links[node.index].faults;
        const cut = faults.partition_up or faults.partition_down;
        const sim = &node.sim.containers;
        for (sim.containers.items) |*container| {
            if (container.phase != .running or !container.relay_open) continue;
            if (container.cert) |cert| {
                connect(state, sim, container, cert, now_ms);
                continue;
            }
            if (cut or now_ms < container.cert_ask_ms) continue;
            container.cert_ask_ms = now_ms + ask_interval_ms;
            const job = label_of(container.labels, runtime.label_job) orelse continue;
            const epoch = epoch_of(container.labels) orelse continue;
            const digest = job_cert.image_digest(container.image) orelse continue;
            const ask: job_cert.Ask = .{
                .node = node.name(),
                .epoch = epoch,
                .image_digest = digest,
                .now_ms = now_ms,
            };
            const subject = ask_and_judge(state, ctx, job, ask, false) orelse continue;
            container.cert = .{
                .epoch = subject.placement_epoch,
                .not_after_ms = subject.lifetime.not_after_ms,
            };
        }
    }
    forge_one(state, ctx, nodes);
}

/// A run's connections over one tick: one may open while the certificate is valid, and one may
/// close.
fn connect(state: *State, sim: anytype, container: anytype, cert: anytype, now_ms: u64) void {
    const random = state.prng.random();
    if (container.conns > 0 and random.uintLessThan(u32, 10) == 0) {
        container.conns -= 1;
        sim.conns_closed += 1;
    }
    if (now_ms >= cert.not_after_ms or container.conns == conns_max) return;
    if (random.uintLessThan(u32, 5) == 0) {
        container.conns += 1;
        sim.conns_opened += 1;
    }
}

/// Now and then (`forge_per_mille` of ticks), an ask made up from a relayed container on some
/// node: a stale epoch, another node's name, a run that may have ended, another image.
fn forge_one(state: *State, ctx: *const controller.Context, nodes: anytype) void {
    const random = state.prng.random();
    if (random.uintLessThan(u32, 1000) >= forge_per_mille) return;
    const node = nodes[random.uintLessThan(usize, nodes.len)];
    const other = nodes[random.uintLessThan(usize, nodes.len)];
    const items = node.sim.containers.containers.items;
    if (items.len == 0) return;
    const container = items[random.uintLessThan(usize, items.len)];
    if (!container.relay_wanted) return;
    const job = label_of(container.labels, runtime.label_job) orelse return;
    const epoch = epoch_of(container.labels) orelse return;
    const digest = job_cert.image_digest(container.image) orelse return;
    const forgery = random.enumValue(Forgery);
    const now_ms = node.nclock.clock().now_ms();
    const ask = forge(state, forgery, node.name(), other.name(), epoch, digest, now_ms) orelse
        return;
    // An `ended` forgery names the run as its own node does: a certificate for it is lawful while
    // the run is not over, so it does not count as a forged issue.
    _ = ask_and_judge(state, ctx, job, ask, forgery != .ended);
}

const testing = std.testing;

const Fixture = struct {
    memory: @import("store_memory.zig").MemoryStore,
    manual: @import("clock.zig").ManualClock,
    arena: std.heap.ArenaAllocator,
    diag: @import("diag.zig").Diag,

    const job = "batch";
    const run = "batch-job";
    const image = "b3:" ++ "01010101010101010101010101010101" ++
        "01010101010101010101010101010101";

    fn init(fixture: *Fixture) void {
        fixture.manual = .{ .ms = 10_000 };
        fixture.memory.init(testing.allocator, fixture.manual.clock());
        fixture.arena = .init(testing.allocator);
        fixture.diag = .{};
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
        fixture.memory.deinit();
    }

    fn ctx(fixture: *Fixture) controller.Context {
        return .{
            .store = fixture.memory.interface(),
            .clock = fixture.manual.clock(),
            .arena = fixture.arena.allocator(),
            .diag = &fixture.diag,
        };
    }

    fn put(fixture: *Fixture, key: []const u8, value: anytype) !store.Revision {
        const bytes = try records.encode(fixture.arena.allocator(), value, &fixture.diag);
        const op: store.Op = .{ .put = .{ .key = key, .value = bytes } };
        const done = try fixture.memory.interface().txn(.{ .on_success = &.{op} }, &fixture.diag);
        return done.revision;
    }

    fn claim(fixture: *Fixture, epoch: u64, status: records.JobObservedStatus) !void {
        const stopped = status == .stopped;
        const exit: ?records.Exit = if (stopped) .{ .kind = .exited, .code = 0 } else null;
        _ = try fixture.put(records.job_observed_key("n1", job).slice(), records.JobObserved{
            .run = run,
            .node = "n1",
            .tenure = 1,
            .assignment = epoch,
            .status = status,
            .exit = exit,
            .started_at_ms = 1_000,
            .reported_at_ms = 2_000,
        });
    }

    /// A relayed job running on n1 under the epoch it returns.
    fn running(fixture: *Fixture) !u64 {
        _ = try fixture.put(records.job_key(job).slice(), records.Job{
            .name = job,
            .image = image,
            .command = &.{"run"},
            .deadline_ms = 60_000,
            .grace_ms = 5_000,
            .relay = .{ .name = "r", .address = "127.0.0.1:9" },
            .submit_by_ms = 0,
            .created_at_ms = 0,
        });
        const epoch = try fixture.put(records.assigned_key("n1", run).slice(), records.Assigned{
            .replica = run,
            .requests = .{ .cpu_millis = 100, .memory_bytes = 1 << 20 },
            .reason = "test",
            .job = job,
        });
        _ = try fixture.put(records.job_status_key(job).slice(), records.JobStatus{
            .state = .running,
            .node = "n1",
            .epoch = epoch,
            .tenure = 1,
            .started_at_ms = 1_000,
            .reported_at_ms = 2_000,
        });
        try fixture.claim(epoch, .running);
        return epoch;
    }
};

test "R4 and R5 judge an issue by the records; R6 by the node's report" {
    // Pins the checker's verdicts the three teeth rely on, over a memory store: an honest ask is
    // issued and passes, a stale epoch is refused by the rule and named R4 by the checker, a
    // lifetime past the bound is R5, and open connections are R6 only once the node reported the
    // run's ending. Method: write the records of one relayed run; ask and judge.
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    const epoch = try fixture.running();
    const ctx = fixture.ctx();
    var digest: [32]u8 = @splat(1);
    const ask: job_cert.Ask = .{
        .node = "n1",
        .epoch = epoch,
        .image_digest = digest,
        .now_ms = 10_000,
    };
    const job = Fixture.job;
    var subject = switch (issue(&ctx, job, ask)) {
        .issued => |subject| subject,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(issued_problem(&ctx, job, ask, &subject) == null);
    const bound = 1_000 + 65_000 + constants.workload_cert_slack_ms;
    try testing.expectEqual(bound, subject.lifetime.not_after_ms);

    var stale = ask;
    stale.epoch = epoch - 1;
    try testing.expectEqual(Outcome{ .refused = error.stale_epoch }, issue(&ctx, job, stale));
    const stale_found = issued_problem(&ctx, job, stale, &subject).?;
    try testing.expectEqualStrings("R4: a certificate was issued for a stale epoch", stale_found);
    var other = ask;
    other.node = "n2";
    try testing.expectEqual(Outcome{ .refused = error.wrong_node }, issue(&ctx, job, other));
    digest[0] ^= 1;
    var image = ask;
    image.image_digest = digest;
    try testing.expectEqual(Outcome{ .refused = error.wrong_image }, issue(&ctx, job, image));

    subject.lifetime.not_after_ms += 1;
    try expect_prefix(issued_problem(&ctx, job, ask, &subject), "R5");

    const created = try std.fmt.allocPrint(fixture.arena.allocator(), "{d}", .{epoch});
    const labels = [_]runtime.Label{
        .{ .key = runtime.label_job, .value = job },
        .{ .key = runtime.label_created, .value = created },
    };
    try testing.expect(conns_problem(&ctx, "n1", Fixture.run, &labels) == null);
    try fixture.claim(epoch, .stopped);
    try expect_prefix(conns_problem(&ctx, "n1", Fixture.run, &labels), "R6");
    try testing.expectEqual(Outcome{ .refused = error.run_ended }, issue(&ctx, job, ask));
    try expect_prefix(issued_problem(&ctx, job, ask, &subject), "R4");
}

fn expect_prefix(found: ?[]const u8, prefix: []const u8) !void {
    try testing.expect(std.mem.startsWith(u8, found orelse "", prefix));
}
