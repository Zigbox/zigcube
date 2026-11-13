//! The issuance rule for a relayed run's certificate (B4, docs/briefs/b4.md): a pure function over
//! the store's job, its status, the run's claim and the current assignment. It decides whether
//! the node that asks may hold a `/job/<name>` certificate and for how long. No socket, no clock
//! read (`now_ms` comes in), no store: the CA call that signs is the caller's.
//!
//! A certificate is issued only to the node that claimed the run, under the assignment epoch the
//! claim names and the store still holds, while the run has not ended, and expires at
//! `start + deadline + grace + workload_cert_slack_ms`, the last moment the run can legitimately
//! be alive. A lifetime shorter than one second is refused: X.509 times are whole seconds.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const identity = @import("x509_identity.zig");
const x509 = @import("x509.zig");
const c1_teeth = @import("c1_teeth.zig");

pub const Refusal = error{
    /// The job has no relay: it gets no certificate.
    no_relay,
    /// The run has ended (its status is terminal, or its claim is `stopped`), or its owner has
    /// asked for it to be cancelled.
    run_ended,
    /// The ask's image digest is not the one the job pins.
    wrong_image,
    /// No node has claimed the run.
    no_claim,
    /// The asking node is not the node that claimed it.
    wrong_node,
    /// The ask, the claim, the status and the assignment do not name one epoch.
    stale_epoch,
    /// The claim has not started the run, so its deadline has no start.
    not_started,
    /// The certificate would be valid for less than a second, or has expired.
    lifetime,
    /// The job's labels do not fit the identity extension.
    labels,
};

pub fn reason(refusal: Refusal) []const u8 {
    return switch (refusal) {
        error.no_relay => "the job has no relay",
        error.run_ended => "the run has ended or is being cancelled",
        error.wrong_image => "the image is not the one the job pins",
        error.no_claim => "no node has claimed the run",
        error.wrong_node => "the run was claimed by another node",
        error.stale_epoch => "the placement epoch is not the run's current one",
        error.not_started => "the run has not started",
        error.lifetime => "the run's certificate would be valid for under a second",
        error.labels => "the job's labels do not fit a certificate",
    };
}

/// The store's current `/assigned/<node>/<run>`: the node and the revision it was written at.
pub const Assignment = struct { node: []const u8, epoch: u64 };

/// What a node asks: its name, the epoch it holds, the image it runs and the time.
pub const Ask = struct {
    node: []const u8,
    epoch: u64,
    image_digest: [32]u8,
    now_ms: u64,
};

pub const Subject = struct {
    name: []const u8,
    lifetime: x509.Lifetime,
    placement_epoch: u64,
    image_digest: [32]u8,
    /// The job's labels, sorted by key, as the extension wants them.
    labels: [constants.x509_labels_max]identity.Label,
    labels_len: u32,

    pub fn identity_of(subject: *const Subject) identity.Identity {
        return .{
            .image_digest = subject.image_digest,
            .placement_epoch = subject.placement_epoch,
            .labels = subject.labels[0..subject.labels_len],
        };
    }
};

/// Test-only faults for the teeth tests, as in `x509.zig`: each skips one check.
pub const TestFault = enum { relay, ended, node, epoch, lifetime, image };
var faults: [6]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn skipped(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// The `not_after` of a run's certificate, or null on overflow.
pub fn not_after_ms(started_ms: u64, deadline_ms: u64, grace_ms: u64) ?u64 {
    var sum = std.math.add(u64, started_ms, deadline_ms) catch return null;
    sum = std.math.add(u64, sum, grace_ms) catch return null;
    // `job_cert_long` (sim-c1's R5 tooth) counts the slack twice.
    if (c1_teeth.job_cert_long) {
        sum = std.math.add(u64, sum, constants.workload_cert_slack_ms) catch return null;
    }
    return std.math.add(u64, sum, constants.workload_cert_slack_ms) catch null;
}

pub fn decide(
    job: records.Job,
    status: records.JobStatus,
    claim: ?records.JobObserved,
    assignment: ?Assignment,
    ask: Ask,
) Refusal!Subject {
    if (job.relay == null and !skipped(.relay)) return error.no_relay;
    if (records.job_state_terminal(status.state) and !skipped(.ended)) return error.run_ended;
    // The owner has said the run must stop: no new identity for it, whatever the status says yet.
    if (job.cancel_requested != null and !skipped(.ended)) return error.run_ended;
    if (!skipped(.image) and !image_is(job.image, ask.image_digest)) return error.wrong_image;
    const held = claim orelse return error.no_claim;
    if (held.status == .stopped and !skipped(.ended)) return error.run_ended;
    if (!std.mem.eql(u8, held.node, ask.node) and !skipped(.node)) return error.wrong_node;
    // `job_cert_stale` is sim-c1's R4 tooth: the epoch is not compared.
    const compare_epoch = !skipped(.epoch) and !c1_teeth.job_cert_stale;
    if (compare_epoch and !epoch_current(held, status, assignment, ask)) {
        return error.stale_epoch;
    }
    const started = held.started_at_ms orelse return error.not_started;
    // A node's clock may run ahead of the server's: a start in the future counts as now.
    const start = @min(started, ask.now_ms);
    const after = not_after_ms(start, job.deadline_ms, job.grace_ms) orelse return error.lifetime;
    if (!skipped(.lifetime) and after - @min(after, ask.now_ms) < 1000) return error.lifetime;
    var subject: Subject = .{
        .name = job.name,
        .lifetime = .{ .not_before_ms = ask.now_ms, .not_after_ms = after },
        .placement_epoch = held.assignment,
        .image_digest = ask.image_digest,
        .labels = undefined,
        .labels_len = 0,
    };
    try sort_labels(job, &subject);
    return subject;
}

/// The 32-byte digest a job's pinned image names, if it names one: "b3:" and 64 lowercase hex
/// digits. Uppercase is refused, so one digest has one spelling. Admission of a relayed job and
/// issuance both use this, so a job that is admitted can be attested.
pub fn image_digest(image: []const u8) ?[32]u8 {
    if (!std.mem.startsWith(u8, image, "b3:")) return null;
    const hex = image["b3:".len..];
    if (hex.len != 64) return null;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    var pinned: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pinned, hex) catch return null;
    return pinned;
}

/// Whether the job's pinned image is the digest the node attests. A pin of another form is no
/// digest at all, so it never matches.
fn image_is(image: []const u8, digest: [32]u8) bool {
    const pinned = image_digest(image) orelse return false;
    return std.mem.eql(u8, &pinned, &digest);
}

fn epoch_current(
    held: records.JobObserved,
    status: records.JobStatus,
    assignment: ?Assignment,
    ask: Ask,
) bool {
    const current = assignment orelse return false;
    if (!std.mem.eql(u8, current.node, ask.node)) return false;
    const status_epoch = status.epoch orelse return false;
    return ask.epoch == held.assignment and status_epoch == held.assignment and
        current.epoch == held.assignment;
}

fn sort_labels(job: records.Job, subject: *Subject) Refusal!void {
    subject.labels_len = sorted_labels(job.labels, &subject.labels) catch return error.labels;
}

/// The job's labels sorted by key into `out`, checked by the extension's own rules. The one
/// place those rules are applied to a job: issuance and admission (`job_api`) both call it.
fn sorted_labels(
    pairs: []const records.Pair,
    out: *[constants.x509_labels_max]identity.Label,
) identity.Error!u32 {
    if (pairs.len > out.len) return error.TooManyLabels;
    for (pairs, 0..) |pair, index| out[index] = .{ .key = pair[0], .value = pair[1] };
    std.mem.sort(identity.Label, out[0..pairs.len], {}, label_less);
    try identity.validate(out[0..pairs.len]);
    return @intCast(pairs.len);
}

/// What the certificate would refuse in a job's labels, or null if it takes them. Admission asks
/// this of a relayed job, so a job whose certificate can never be issued is not admitted.
pub fn labels_problem(pairs: []const records.Pair) ?identity.Error {
    var out: [constants.x509_labels_max]identity.Label = undefined;
    _ = sorted_labels(pairs, &out) catch |err| return err;
    return null;
}

fn label_less(_: void, a: identity.Label, b: identity.Label) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

fn repeat(comptime byte: u8, comptime count: usize) *const [count]u8 {
    const filled: [count]u8 = @splat(byte);
    return &filled;
}

const start_ms: u64 = 1_000_000;
const now_ms: u64 = start_ms + 5_000;
const window_ms: u64 = 60_000 + 10_000 + constants.workload_cert_slack_ms;

/// A run as the store holds it when it is healthy; a test changes the one member it is about.
const Case = struct {
    job: records.Job = .{
        .name = "nightly-7",
        .image = "b3:0101010101010101010101010101010101010101010101010101010101010101",
        .command = &.{"run"},
        .deadline_ms = 60_000,
        .grace_ms = 10_000,
        .labels = &.{ .{ "team", "ops" }, .{ "app", "batch" } },
        .relay = .{ .name = "r", .address = "10.0.0.1:1" },
        .submit_by_ms = 0,
        .created_at_ms = 0,
    },
    status: records.JobStatus = .{
        .state = .running,
        .node = "n1",
        .epoch = 7,
        .tenure = 3,
        .started_at_ms = start_ms,
        .reported_at_ms = now_ms,
    },
    claim: ?records.JobObserved = .{
        .run = "nightly-7-job",
        .node = "n1",
        .tenure = 3,
        .assignment = 7,
        .status = .running,
        .started_at_ms = start_ms,
        .reported_at_ms = now_ms,
    },
    assignment: ?Assignment = .{ .node = "n1", .epoch = 7 },
    ask: Ask = .{ .node = "n1", .epoch = 7, .image_digest = @splat(1), .now_ms = now_ms },

    fn run(case: Case) Refusal!Subject {
        return decide(case.job, case.status, case.claim, case.assignment, case.ask);
    }
};

fn teeth(fault: TestFault, case: Case, refusal: Refusal) !void {
    try testing.expectError(refusal, case.run());
    set_test_fault(fault, true);
    defer set_test_fault(fault, false);
    _ = try case.run();
}

test "the claiming node under the current epoch gets start + deadline + grace + slack" {
    const subject = try (Case{}).run();
    try testing.expectEqual(start_ms + window_ms, subject.lifetime.not_after_ms);
    try testing.expectEqual(now_ms, subject.lifetime.not_before_ms);
    try testing.expectEqual(@as(u64, 7), subject.identity_of().placement_epoch);
    // Sorted by key, though the job listed "team" first.
    try testing.expectEqualStrings("app", subject.identity_of().labels[0].key);
    try identity.validate(subject.identity_of().labels);
}

test "the arithmetic is checked: an overflow is a refusal, the longest run fits a leaf" {
    try testing.expectEqual(@as(?u64, null), not_after_ms(std.math.maxInt(u64) - 5, 1, 1));
    const longest = not_after_ms(0, constants.job_deadline_ms_max, constants.job_grace_ms_max);
    try testing.expect(longest.? < constants.x509_leaf_ttl_ms_max);
}

test "teeth: a job without a relay gets nothing" {
    var case: Case = .{};
    case.job.relay = null;
    try teeth(.relay, case, error.no_relay);
}

test "teeth: an ended run gets nothing, by status or by a stopped claim" {
    var by_status: Case = .{};
    by_status.status.state = .exited;
    try teeth(.ended, by_status, error.run_ended);
    var by_claim: Case = .{};
    by_claim.claim.?.status = .stopped;
    try teeth(.ended, by_claim, error.run_ended);
}

test "teeth: a run whose cancel was requested gets nothing" {
    var case: Case = .{};
    case.job.cancel_requested = .{ .at_ms = now_ms - 1, .by = "me" };
    try teeth(.ended, case, error.run_ended);
}

test "teeth: an image other than the pinned digest gets nothing" {
    var case: Case = .{};
    case.ask.image_digest = @splat(2);
    try teeth(.image, case, error.wrong_image);
    case = .{};
    case.job.image = "fixture";
    try testing.expectError(error.wrong_image, case.run());
}

test "no claim, no certificate" {
    try testing.expectError(error.no_claim, (Case{ .claim = null }).run());
}

test "teeth: another node gets nothing" {
    var case: Case = .{};
    case.ask.node = "n2";
    // The epoch rule names the asking node too, so only both together let n2 through.
    set_test_fault(.epoch, true);
    defer set_test_fault(.epoch, false);
    try teeth(.node, case, error.wrong_node);
}

test "teeth: a stale epoch gets nothing, whichever of the four sources is behind" {
    var asked: Case = .{};
    asked.ask.epoch = 6;
    var statused: Case = .{};
    statused.status.epoch = 8;
    const moved: Case = .{ .assignment = .{ .node = "n1", .epoch = 8 } };
    const handed: Case = .{ .assignment = .{ .node = "n2", .epoch = 7 } };
    try teeth(.epoch, asked, error.stale_epoch);
    try teeth(.epoch, statused, error.stale_epoch);
    try teeth(.epoch, moved, error.stale_epoch);
    try teeth(.epoch, handed, error.stale_epoch);
    try teeth(.epoch, .{ .assignment = null }, error.stale_epoch);
}

test "a claim that has not started has no deadline to count from" {
    var case: Case = .{};
    case.claim.?.status = .claimed;
    case.claim.?.started_at_ms = null;
    try testing.expectError(error.not_started, case.run());
}

test "teeth: a lifetime one millisecond short of a second is refused, one second is not" {
    const after = start_ms + window_ms;
    var short: Case = .{};
    short.ask.now_ms = after - 999;
    try teeth(.lifetime, short, error.lifetime);
    var exact: Case = .{};
    exact.ask.now_ms = after - 1000;
    const subject = try exact.run();
    try testing.expectEqual(after, subject.lifetime.not_after_ms);
    var expired: Case = .{};
    expired.ask.now_ms = after + 5;
    try testing.expectError(error.lifetime, expired.run());
}

test "a start in the future (a fast agent clock) counts as now" {
    var case: Case = .{};
    case.claim.?.started_at_ms = now_ms + 3_600_000;
    const subject = try case.run();
    try testing.expectEqual(now_ms + window_ms, subject.lifetime.not_after_ms);
}

test "labels that do not fit are refused" {
    var case: Case = .{};
    case.job.labels = &.{ .{ "a", repeat('x', 200) }, .{ "b", repeat('y', 100) } };
    try testing.expectError(error.labels, case.run());
}

test "labels_problem is the certificate's rule: a space in a key, a tab or bad UTF-8 in a value" {
    const Err = ?identity.Error;
    try testing.expectEqual(@as(Err, null), labels_problem(&.{ .{ "b", "1" }, .{ "a", "2" } }));
    const bad: Err = error.BadLabel;
    try testing.expectEqual(bad, labels_problem(&.{.{ "my key", "ok" }}));
    try testing.expectEqual(bad, labels_problem(&.{.{ "k", "a\tb" }}));
    try testing.expectEqual(bad, labels_problem(&.{.{ "k", "\xff" }}));
    var case: Case = .{};
    case.job.labels = &.{.{ "my key", "ok" }};
    try testing.expectError(error.labels, case.run());
}

test "image_digest takes 'b3:' and 64 lowercase hex digits and nothing else" {
    // Goal: B4 review MUST, one spelling per digest. Method: short, long, uppercase, mixed case,
    // a tag and the wrong prefix are no digest; the full lowercase one decodes.
    const low = "0a0a0a0a0a0a0a0a" ++ "0a0a0a0a0a0a0a0a" ++
        "0a0a0a0a0a0a0a0a" ++ "0a0a0a0a0a0a0a0a";
    const full = "b3:" ++ low;
    try testing.expectEqual(@as(u8, 0x0a), image_digest(full).?[31]);
    const none = [_][]const u8{
        "",
        "b3:",
        "b3:51aa9c03",
        full ++ "0",
        full[0 .. full.len - 1],
        "b3:" ++ "0A0A0A0A0A0A0A0A" ++ low[16..],
        full[0 .. full.len - 1] ++ "A",
        "sha256:" ++ low,
        "latest",
    };
    for (none) |image| try testing.expectEqual(@as(?[32]u8, null), image_digest(image));
}
