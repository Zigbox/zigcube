//! The issuance rule for a service replica's certificate (C4 slice 3, docs/briefs/c4.md,
//! "Identity"): B4's rule (`job_cert.zig`) applied to `/service/<name>`. A pure function over the
//! store's replica and its current assignment: it decides whether the node that asks may hold a
//! certificate for the replica, and for how long. No socket, no clock read (`now_ms` comes in), no
//! store: the CA call that signs is the caller's.
//!
//! A certificate is issued only to the node that holds the replica's current assignment, under
//! the epoch that assignment was written at (its `mod_revision`), for the digest the replica runs,
//! and lives `workload_cert_ttl_ms`. Renewal is the supervisor's: at half-life it asks again with
//! a new key (`standing`); a certificate that reaches its `not_after` unrenewed takes the replica
//! off the mesh (ZC-W0703) and leaves the replica running.
//!
//! Services carry no labels (`records.Service` has none), so the identity extension carries none:
//! docs/decisions/2026-11-14-c4-service-certs.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const identity = @import("x509_identity.zig");
const x509 = @import("x509.zig");
const job_cert = @import("job_cert.zig");
const c1_teeth = @import("c1_teeth.zig");

pub const Refusal = error{
    /// The replica is not in `/replicas`: deleted, or never written.
    no_replica,
    /// The replica has no assignment, or one on another node.
    wrong_node,
    /// The ask's epoch is not the revision the current assignment was written at.
    stale_epoch,
    /// The ask's image digest is not the one the replica runs, or the replica's image is no
    /// digest at all.
    wrong_image,
};

pub fn reason(refusal: Refusal) []const u8 {
    return switch (refusal) {
        error.no_replica => "the replica does not exist",
        error.wrong_node => "the replica is not assigned to this node",
        error.stale_epoch => "the placement epoch is not the replica's current one",
        error.wrong_image => "the image is not the digest the replica runs",
    };
}

/// The store's current `/assigned/<node>/<replica>`: the node it names, the service it records,
/// and the revision it was written at (the placement epoch).
pub const Assignment = struct { node: []const u8, service: []const u8, epoch: u64 };

/// What a node asks: its name, the epoch it holds, the image it runs and the time.
pub const Ask = job_cert.Ask;

pub const Subject = struct {
    /// The service: the certificate's path is `/service/<service>`.
    service: []const u8,
    lifetime: x509.Lifetime,
    placement_epoch: u64,
    image_digest: [32]u8,

    pub fn identity_of(subject: *const Subject) identity.Identity {
        return .{
            .image_digest = subject.image_digest,
            .placement_epoch = subject.placement_epoch,
            .labels = &.{},
        };
    }
};

/// Test-only faults for the teeth tests, as in `job_cert.zig`: each skips one check.
pub const TestFault = enum { node, epoch, image };
var faults: [3]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn skipped(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// `replica` is `/replicas/<service>/<id>` and `assignment` the asking node's
/// `/assigned/<node>/<id>`, both read at one revision. `ttl_ms` is `workload_cert_ttl_ms` on the
/// server; the simulator passes a shorter one so that its runs reach renewal and expiry.
pub fn decide(
    replica: ?records.Replica,
    assignment: ?Assignment,
    ask: Ask,
    ttl_ms: u64,
) Refusal!Subject {
    assert(ttl_ms >= 2000);
    assert(ttl_ms % 2000 == 0);
    assert(ttl_ms <= constants.x509_leaf_ttl_ms_max);
    assert(ask.now_ms <= std.math.maxInt(u64) - ttl_ms);
    const held = replica orelse return error.no_replica;
    const current = assignment orelse return error.wrong_node;
    const same_node = std.mem.eql(u8, current.node, ask.node);
    const same_service = std.mem.eql(u8, current.service, held.service);
    if (!(same_node and same_service) and !skipped(.node)) return error.wrong_node;
    // `mesh_issue_stale` is M3's tooth: the epoch is not compared.
    const compare_epoch = !skipped(.epoch) and !c1_teeth.mesh_issue_stale;
    if (compare_epoch and current.epoch != ask.epoch) return error.stale_epoch;
    const pinned = job_cert.image_digest(held.image) orelse return error.wrong_image;
    if (!std.mem.eql(u8, &pinned, &ask.image_digest) and !skipped(.image)) {
        return error.wrong_image;
    }
    return .{
        .service = held.service,
        .lifetime = .{
            .not_before_ms = ask.now_ms,
            .not_after_ms = ask.now_ms + ttl_ms,
        },
        .placement_epoch = ask.epoch,
        .image_digest = pinned,
    };
}

/// Where a held certificate stands on a clock: `valid` before half-life, `renew` from half-life to
/// its `not_after`, `expired` from then on (the replica is off the mesh, ZC-W0703).
pub const Standing = enum { valid, renew, expired };

/// Half-life: when the supervisor asks again, with a new key.
pub fn renew_at_ms(lifetime: x509.Lifetime) u64 {
    assert(lifetime.not_before_ms < lifetime.not_after_ms);
    return lifetime.not_before_ms + (lifetime.not_after_ms - lifetime.not_before_ms) / 2;
}

pub fn standing(lifetime: x509.Lifetime, now_ms: u64) Standing {
    assert(lifetime.not_before_ms < lifetime.not_after_ms);
    if (now_ms >= lifetime.not_after_ms) return .expired;
    if (now_ms >= renew_at_ms(lifetime)) return .renew;
    return .valid;
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

const t_now_ms: u64 = 5_000_000;
const digest_hex = "0101010101010101010101010101010101010101010101010101010101010101";

/// A replica as the store holds it when healthy; a test changes the one member it is about.
const Case = struct {
    replica: ?records.Replica = .{
        .id = "web-3",
        .service = "web",
        .generation = 2,
        .image = "b3:" ++ digest_hex,
        .command = &.{"serve"},
    },
    assignment: ?Assignment = .{ .node = "n1", .service = "web", .epoch = 41 },
    ask: Ask = .{ .node = "n1", .epoch = 41, .image_digest = @splat(1), .now_ms = t_now_ms },

    fn run(case: Case) Refusal!Subject {
        return decide(case.replica, case.assignment, case.ask, constants.workload_cert_ttl_ms);
    }
};

fn teeth(fault: TestFault, case: Case, refusal: Refusal) !void {
    try testing.expectError(refusal, case.run());
    set_test_fault(fault, true);
    defer set_test_fault(fault, false);
    _ = try case.run();
}

test "the assigned node under the current epoch gets workload_cert_ttl_ms" {
    const subject = try (Case{}).run();
    try testing.expectEqualStrings("web", subject.service);
    try testing.expectEqual(t_now_ms, subject.lifetime.not_before_ms);
    const after = t_now_ms + constants.workload_cert_ttl_ms;
    try testing.expectEqual(after, subject.lifetime.not_after_ms);
    try testing.expectEqual(@as(u64, 41), subject.identity_of().placement_epoch);
    try testing.expectEqual(@as(usize, 0), subject.identity_of().labels.len);
    try testing.expectEqual(@as(u8, 1), subject.image_digest[31]);
}

test "a deleted replica gets nothing" {
    try testing.expectError(error.no_replica, (Case{ .replica = null }).run());
}

test "teeth: another node, or no assignment, or another service's assignment gets nothing" {
    var other: Case = .{};
    other.ask.node = "n2";
    try teeth(.node, other, error.wrong_node);
    var service: Case = .{};
    service.assignment.?.service = "api";
    try teeth(.node, service, error.wrong_node);
    try testing.expectError(error.wrong_node, (Case{ .assignment = null }).run());
}

test "teeth: a stale epoch gets nothing, behind or ahead" {
    var behind: Case = .{};
    behind.ask.epoch = 40;
    try teeth(.epoch, behind, error.stale_epoch);
    var ahead: Case = .{};
    ahead.ask.epoch = 42;
    try teeth(.epoch, ahead, error.stale_epoch);
    const moved: Case = .{ .assignment = .{ .node = "n1", .service = "web", .epoch = 57 } };
    try teeth(.epoch, moved, error.stale_epoch);
}

test "teeth: a digest other than the replica's gets nothing; a short pin is no digest" {
    var case: Case = .{};
    case.ask.image_digest = @splat(2);
    try teeth(.image, case, error.wrong_image);
    var short: Case = .{};
    short.replica.?.image = "b3:51aa9c03";
    try testing.expectError(error.wrong_image, short.run());
}

test "the certificate names the epoch asked, which is the assignment's" {
    // Goal: M3. Method: the subject's epoch and digest are the inputs the checks compared, so a
    // certificate can only name what the store held.
    const subject = try (Case{}).run();
    const case: Case = .{};
    try testing.expectEqual(case.assignment.?.epoch, subject.placement_epoch);
    try testing.expectEqualSlices(u8, &case.ask.image_digest, &subject.image_digest);
}

test "standing: valid before half-life, renew from it, expired at not_after" {
    const lifetime: x509.Lifetime = .{
        .not_before_ms = t_now_ms,
        .not_after_ms = t_now_ms + constants.workload_cert_ttl_ms,
    };
    const half = t_now_ms + constants.workload_cert_ttl_ms / 2;
    try testing.expectEqual(half, renew_at_ms(lifetime));
    try testing.expectEqual(Standing.valid, standing(lifetime, t_now_ms));
    try testing.expectEqual(Standing.valid, standing(lifetime, half - 1));
    try testing.expectEqual(Standing.renew, standing(lifetime, half));
    try testing.expectEqual(Standing.renew, standing(lifetime, lifetime.not_after_ms - 1));
    try testing.expectEqual(Standing.expired, standing(lifetime, lifetime.not_after_ms));
    // A clock behind `not_before` (skew) is still valid, not expired.
    try testing.expectEqual(Standing.valid, standing(lifetime, 0));
}
