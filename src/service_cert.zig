//! The issuance rule for a service replica's certificate (C4 slice 3, docs/briefs/c4.md,
//! "Identity"): B4's rule (`job_cert.zig`) applied to `/service/<name>`. `look_up` reads what the
//! rule needs from the store, and `decide`, a pure function over it, decides whether the node that
//! asks may hold a certificate for the replica, and for how long. No socket, no clock read
//! (`now_ms` comes in): the CA call that signs is the caller's. The server
//! (`agent_api.replica_subject`) and the simulator (`sim_mesh_certs.issue`) both call these two,
//! so the simulator's checks judge the code the server runs.
//!
//! A certificate is issued only to the node that holds the replica's current assignment, under
//! the epoch that assignment was written at (its `mod_revision`), for the digest the replica runs,
//! and lives `workload_cert_ttl_ms`. Renewal is the supervisor's: at half-life it asks again with
//! a new key (`standing`); a certificate that reaches its `not_after` unrenewed takes the replica
//! off the mesh (ZC-W0703) and leaves the replica running.
//!
//! The node gate is the lookup: the assignment read is the asking node's own
//! `/assigned/<node>/<id>`, so there is no other node's assignment for `decide` to compare
//! (docs/decisions/2026-11-14-c4-service-cert-rulings.md).
//!
//! Services carry no labels (`records.Service` has none), so the identity extension carries none:
//! docs/decisions/2026-11-14-c4-service-certs.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const diag_mod = @import("diag.zig");
const identity = @import("x509_identity.zig");
const x509 = @import("x509.zig");
const job_cert = @import("job_cert.zig");
const c1_teeth = @import("c1_teeth.zig");

pub const Refusal = error{
    /// The replica is not in `/replicas`: deleted, or never written.
    no_replica,
    /// The asking node holds no assignment of the replica (none, another node's, a job run's, or
    /// one whose record does not name the replica's service).
    wrong_node,
    /// The ask's epoch is not the revision the current assignment was written at.
    stale_epoch,
    /// The ask's image digest is not the one the replica runs, or the replica's image is no
    /// digest at all.
    wrong_image,
    /// The replica's image is a short pin (`b3:` and fewer than 64 hex digits): admission takes
    /// it, but a certificate attests a full digest.
    short_pin,
};

pub fn reason(refusal: Refusal) []const u8 {
    return switch (refusal) {
        error.no_replica => "the replica does not exist",
        error.wrong_node => "the replica is not assigned to this node",
        error.stale_epoch => "the placement epoch is not the replica's current one",
        error.wrong_image => "the image is not the digest the replica runs",
        error.short_pin => "the service pins its image by a short digest, and a certificate " ++
            "names a full one",
    };
}

/// The asking node's `/assigned/<node>/<replica>`: the service it records, and the revision it
/// was written at (the placement epoch). There is no node: it is the asking node's by its key.
pub const Assignment = struct { service: []const u8, epoch: u64 };

/// What the issuer reads for one ask: the asking node's assignment of the replica, if it holds a
/// service replica's, and the replica that assignment names.
pub const Found = struct { replica: ?records.Replica, assignment: ?Assignment };

pub const LookUpError = store.Error || records.Error;

/// Reads `/assigned/<node>/<id>` and then `/replicas/<service>/<id>` (the assignment names the
/// service) at `revision` (null: the current one; the caller passes one revision for both). A
/// missing key, a job run's assignment, or a record whose service cannot hold `id` (a store that
/// broke an invariant) is no assignment: refused, never asserted on.
pub fn look_up(
    db: store.Store,
    arena: std.mem.Allocator,
    node: []const u8,
    id: []const u8,
    revision: ?store.Revision,
    diag: *diag_mod.Diag,
) LookUpError!Found {
    assert(records.name_problem(id, constants.replica_id_bytes_max) == null);
    const kv = (try assigned_kv(db, arena, node, id, revision, diag)) orelse
        return .{ .replica = null, .assignment = null };
    const placed = try records.read(records.Assigned, arena, kv, diag);
    // A job run's assignment has an empty service, which no id belongs to: refused here too.
    if (!records.replica_id_valid(placed.service, id)) {
        return .{ .replica = null, .assignment = null };
    }
    const assignment: Assignment = .{ .service = placed.service, .epoch = kv.mod_revision };
    const replica_key = records.replica_key(placed.service, id);
    const held = try db.get(arena, replica_key.slice(), revision, diag);
    const replica: ?records.Replica = if (held.kv) |replica_kv|
        try records.read(records.Replica, arena, replica_kv, diag)
    else
        null;
    return .{ .replica = replica, .assignment = assignment };
}

/// The asking node's assignment of `id`. `mesh_issue_any_node` is the node gate's tooth: it takes
/// the first assignment of `id` on any node, as an issuer that forgot the key names the node
/// would (must break M3).
fn assigned_kv(
    db: store.Store,
    arena: std.mem.Allocator,
    node: []const u8,
    id: []const u8,
    revision: ?store.Revision,
    diag: *diag_mod.Diag,
) store.Error!?store.KeyValue {
    if (!c1_teeth.mesh_issue_any_node) {
        const key = records.assigned_key(node, id);
        return (try db.get(arena, key.slice(), revision, diag)).kv;
    }
    var options: store.ListOptions = .{
        .prefix = records.prefix_assigned,
        .at_revision = revision,
        .limit = constants.store_list_limit_max,
    };
    while (true) {
        const page = try db.list(arena, options, diag);
        for (page.kvs) |kv| {
            const slash = std.mem.lastIndexOfScalar(u8, kv.key, '/') orelse continue;
            if (std.mem.eql(u8, kv.key[slash + 1 ..], id)) return kv;
        }
        options.continue_after = page.continue_after orelse return null;
        options.at_revision = page.revision;
    }
}

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
pub const TestFault = enum { service, epoch, image };
var faults: [3]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn skipped(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// `found` is what `look_up` read for the asking node. `ttl_ms` is `workload_cert_ttl_ms` on the
/// server; the simulator passes a shorter one so that its runs reach renewal and expiry.
pub fn decide(found: Found, ask: Ask, ttl_ms: u64) Refusal!Subject {
    assert(ttl_ms >= 2000);
    assert(ttl_ms % 2000 == 0);
    assert(ttl_ms <= constants.x509_leaf_ttl_ms_max);
    assert(ask.now_ms <= std.math.maxInt(u64) - ttl_ms);
    const current = found.assignment orelse return error.wrong_node;
    const held = found.replica orelse return error.no_replica;
    // The replica record is read at the assignment's service, so a record that names another
    // service broke an invariant of the store: refused, not trusted.
    if (!std.mem.eql(u8, current.service, held.service) and !skipped(.service)) {
        return error.wrong_node;
    }
    // `mesh_issue_stale` is M3's tooth: the epoch is not compared.
    const compare_epoch = !skipped(.epoch) and !c1_teeth.mesh_issue_stale;
    if (compare_epoch and current.epoch != ask.epoch) return error.stale_epoch;
    const pinned = job_cert.image_digest(held.image) orelse {
        if (short_pin(held.image)) return error.short_pin;
        return error.wrong_image;
    };
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

/// `b3:` and 1 to 63 lowercase hex digits: a prefix of a digest, which admission takes.
fn short_pin(image: []const u8) bool {
    if (!std.mem.startsWith(u8, image, "b3:")) return false;
    const hex = image["b3:".len..];
    if (hex.len == 0 or hex.len >= 64) return false;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
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
    assignment: ?Assignment = .{ .service = "web", .epoch = 41 },
    ask: Ask = .{ .node = "n1", .epoch = 41, .image_digest = @splat(1), .now_ms = t_now_ms },

    fn run(case: Case) Refusal!Subject {
        const found: Found = .{ .replica = case.replica, .assignment = case.assignment };
        return decide(found, case.ask, constants.workload_cert_ttl_ms);
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

test "teeth: no assignment on the asking node, or a record of another service, gets nothing" {
    // The node gate is `look_up`'s key; its tests are in api_test.zig ("a service replica's
    // certificate") and its tooth is `mesh_issue_any_node` (sim-c1).
    try testing.expectError(error.wrong_node, (Case{ .assignment = null }).run());
    try testing.expectError(error.wrong_node, (Case{ .assignment = null, .replica = null }).run());
    var service: Case = .{};
    service.assignment.?.service = "api";
    try teeth(.service, service, error.wrong_node);
}

test "teeth: a stale epoch gets nothing, behind or ahead" {
    var behind: Case = .{};
    behind.ask.epoch = 40;
    try teeth(.epoch, behind, error.stale_epoch);
    var ahead: Case = .{};
    ahead.ask.epoch = 42;
    try teeth(.epoch, ahead, error.stale_epoch);
    const moved: Case = .{ .assignment = .{ .service = "web", .epoch = 57 } };
    try teeth(.epoch, moved, error.stale_epoch);
}

test "teeth: a digest other than the replica's gets nothing; a short pin has its own refusal" {
    var case: Case = .{};
    case.ask.image_digest = @splat(2);
    try teeth(.image, case, error.wrong_image);
    var short: Case = .{};
    short.replica.?.image = "b3:51aa9c03";
    try testing.expectError(error.short_pin, short.run());
    var upper: Case = .{};
    const hex_upper = "ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB";
    upper.replica.?.image = "b3:" ++ hex_upper;
    try testing.expectError(error.wrong_image, upper.run());
    var other: Case = .{};
    other.replica.?.image = "registry.example/web:1";
    try testing.expectError(error.wrong_image, other.run());
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
