//! The compare sets of docs/authority.md §2: every fact a scheduler's or an agent's transaction
//! rests on, as `Compare`s on the revisions the planner read. Pure builders: they read nothing.
//!
//! A `Set` owns the key bytes its compares point at, so it must stay where it is from the first
//! call to `compares` until the transaction has been committed.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const records = @import("records.zig");
const store = @import("store.zig");

/// A placement and a move are the largest sets; the counts below are asserted against the
/// store's bound.
pub const set_max: u32 = 10;

pub const placement_count: u32 = 6;
pub const release_count: u32 = 2;
pub const observed_count: u32 = 1;
/// A run's placement adds the run and its status to a replica's six, less the replica's own
/// compare: the run and its status stand where the replica stood (B1, docs/briefs/b1.md).
pub const placement_run_count: u32 = 7;
/// A run's release adds the status to the release's two.
pub const release_run_count: u32 = 3;

pub const Set = struct {
    keys: [set_max]records.Key = undefined,
    revisions: [set_max]store.Revision = undefined,
    compare_buffer: [set_max]store.Compare = undefined,
    count: u32 = 0,

    /// The compares, in the order they were added. Valid while the set does not move.
    pub fn compares(set: *Set) []const store.Compare {
        assert(set.count <= set_max);
        assert(set.count <= constants.store_txn_compares_max);
        for (0..set.count) |index| {
            set.compare_buffer[index] = .{
                .key = set.keys[index].slice(),
                .mod_revision = set.revisions[index],
            };
        }
        return set.compare_buffer[0..set.count];
    }

    fn add(set: *Set, key: records.Key, revision: store.Revision) void {
        assert(set.count < set_max);
        set.keys[set.count] = key;
        set.revisions[set.count] = revision;
        set.count += 1;
    }
};

/// The revisions a scheduler read for one node. 0 means absent, as in `store.Compare`.
pub const NodeRead = struct {
    node: []const u8,
    /// `/nodes/<node>`: the tenure, and the declared capacity.
    node_revision: store.Revision,
    /// `/node-status/<node>`, whose value was `ready`.
    status_revision: store.Revision,
    /// `/allocations/<node>`; 0 for a node that has none yet.
    allocation_revision: store.Revision,
};

/// A replica to place: `/replicas/<service>/<replica>` read at `replica_revision`.
pub const ReplicaRead = struct {
    service: []const u8,
    replica: []const u8,
    replica_revision: store.Revision,
};

fn add_node_facts(set: *Set, read: NodeRead) void {
    assert(read.node_revision > 0); // A placement rests on the node existing.
    assert(read.status_revision > 0);
    set.add(records.node_key(read.node), read.node_revision);
    set.add(records.node_status_key(read.node), read.status_revision);
    set.add(records.allocation_key(read.node), read.allocation_revision);
    set.add(records.audit_key(read.node), 0); // No open finding.
}

/// The six compares of a placement of `replica` on `target` (authority.md, "The placement compare
/// set"): the replica, its assignment absent, the node, its status, its allocation, no finding.
pub fn placement(set: *Set, replica: ReplicaRead, target: NodeRead) void {
    assert(set.count == 0);
    add_replica_facts(set, replica, target.node);
    add_node_facts(set, target);
    assert(set.count == placement_count);
}

fn add_replica_facts(set: *Set, replica: ReplicaRead, target: []const u8) void {
    assert(replica.replica_revision > 0);
    set.add(records.replica_key(replica.service, replica.replica), replica.replica_revision);
    set.add(records.assigned_key(target, replica.replica), 0);
}

/// A run to place: `/job-runs/<job>` and `/job-status/<job>` read at their revisions. Placing a run
/// rests on both: a run with a `stop` is never placed (the run moved), and a job whose status is
/// terminal or gone is never placed (the status moved).
pub const RunRead = struct {
    job: []const u8,
    run: []const u8,
    run_revision: store.Revision,
    status_revision: store.Revision,
};

/// The seven compares of a run's placement: the run, its status, its assignment absent, the node,
/// its status, its allocation, no finding.
pub fn placement_run(set: *Set, run: RunRead, target: NodeRead) void {
    assert(set.count == 0);
    assert(run.run_revision > 0);
    assert(run.status_revision > 0);
    set.add(records.job_run_key(run.job), run.run_revision);
    set.add(records.job_status_key(run.job), run.status_revision);
    set.add(records.assigned_key(target.node, run.run), 0);
    add_node_facts(set, target);
    assert(set.count == placement_run_count);
}

/// The three compares of a run's release: the assignment and the allocation as a replica's, and
/// the job's status at the revision read (0: there is none, the job is gone).
pub fn release_run(
    set: *Set,
    node: []const u8,
    run: []const u8,
    job: []const u8,
    reads: ReleaseRead,
) void {
    assert(set.count == 0);
    release(set, node, run, reads.assigned_revision, reads.allocation_revision);
    set.add(records.job_status_key(job), reads.status_revision);
    assert(set.count == release_run_count);
}

pub const ReleaseRead = struct {
    assigned_revision: store.Revision,
    allocation_revision: store.Revision,
    status_revision: store.Revision,
};

/// A release on `node`: the assignment at the revision read, and the allocation it is taken from.
pub fn release(
    set: *Set,
    node: []const u8,
    replica: []const u8,
    assigned_revision: store.Revision,
    allocation_revision: store.Revision,
) void {
    assert(assigned_revision > 0);
    assert(allocation_revision > 0); // An assignment has an allocation record behind it.
    set.add(records.assigned_key(node, replica), assigned_revision);
    set.add(records.allocation_key(node), allocation_revision);
}

pub const Source = struct {
    node: []const u8,
    assigned_revision: store.Revision,
    allocation_revision: store.Revision,
};

/// A move: the placement set for the new node, and the release set for the old one. The old node
/// need not be ready or free of findings (a node that was lost is exactly what is moved from),
/// so its side is the release set: eight compares, within `set_max`.
pub fn move(set: *Set, replica: ReplicaRead, from: Source, to: NodeRead) void {
    assert(set.count == 0);
    assert(!std.mem.eql(u8, from.node, to.node));
    placement(set, replica, to);
    release(set, from.node, replica.replica, from.assigned_revision, from.allocation_revision);
    assert(set.count == placement_count + release_count);
}

/// A node's claim of a run: its tenure, the run as read (so a run with a `stop` is never
/// claimed), the assignment it ran under, and no observation of the run yet, which makes a run
/// claimed at most once, ever.
pub fn job_claim(
    set: *Set,
    node: []const u8,
    tenure_revision: store.Revision,
    job: []const u8,
    run_revision: store.Revision,
    assignment: store.Revision,
    observed_revision: store.Revision,
) void {
    assert(run_revision > 0);
    assert(assignment > 0);
    var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    const run = records.job_run_id(&buffer, job);
    observed_write(set, node, tenure_revision);
    set.add(records.job_run_key(job), run_revision);
    set.add(records.assigned_key(node, run), assignment);
    set.add(records.job_observed_key(node, job), observed_revision);
}

/// A node's `running` or `stopped` report of a run: its tenure, and the assignment it ran under
/// still being the one in the store. A report whose run was retired (the assignment released) or
/// superseded (a newer assignment, as when a job name is reused) is refused at write time, so
/// the store never holds an observation the job controller would ignore (B2, J9).
pub fn job_report(
    set: *Set,
    node: []const u8,
    tenure_revision: store.Revision,
    job: []const u8,
    assignment: store.Revision,
) void {
    assert(assignment > 0);
    var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    const run = records.job_run_id(&buffer, job);
    observed_write(set, node, tenure_revision);
    set.add(records.assigned_key(node, run), assignment);
}

/// An agent's observed write: its tenure is still current.
pub fn observed_write(set: *Set, node: []const u8, tenure_revision: store.Revision) void {
    assert(set.count == 0);
    assert(tenure_revision > 0);
    set.add(records.node_key(node), tenure_revision);
    assert(set.count == observed_count);
}

comptime {
    assert(placement_count + release_count <= set_max);
    assert(placement_run_count + release_count <= set_max);
    assert(placement_run_count == placement_count + 1);
    assert(release_run_count == release_count + 1);
    assert(set_max <= constants.store_txn_compares_max);
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

const replica_read: ReplicaRead = .{
    .service = "hello",
    .replica = "hello-1",
    .replica_revision = 7,
};
const node_read: NodeRead = .{
    .node = "n1",
    .node_revision = 3,
    .status_revision = 4,
    .allocation_revision = 5,
};

test "a job report compares the tenure and the assignment it ran under" {
    var set: Set = .{};
    job_report(&set, "n1", 3, "train", 9);
    const compares = set.compares();
    try testing.expectEqual(@as(usize, 2), compares.len);
    try testing.expectEqualStrings("/nodes/n1", compares[0].key);
    try testing.expectEqualStrings("/assigned/n1/train-job", compares[1].key);
    try testing.expectEqual(@as(u64, 9), compares[1].mod_revision);
}

test "a placement compares the six facts of authority.md" {
    var set: Set = .{};
    placement(&set, replica_read, node_read);
    const compares = set.compares();
    try testing.expectEqual(@as(usize, 6), compares.len);
    const expected = [_]store.Compare{
        .{ .key = "/replicas/hello/hello-1", .mod_revision = 7 },
        .{ .key = "/assigned/n1/hello-1", .mod_revision = 0 },
        .{ .key = "/nodes/n1", .mod_revision = 3 },
        .{ .key = "/node-status/n1", .mod_revision = 4 },
        .{ .key = "/allocations/n1", .mod_revision = 5 },
        .{ .key = "/audit/allocations/n1", .mod_revision = 0 },
    };
    for (expected, compares) |want, got| {
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqual(want.mod_revision, got.mod_revision);
    }
}

test "a move, a release and an observed write have the counts of authority.md" {
    var moved: Set = .{};
    const from: Source = .{ .node = "n0", .assigned_revision = 9, .allocation_revision = 8 };
    move(&moved, replica_read, from, node_read);
    const compares = moved.compares();
    try testing.expectEqual(@as(usize, 8), compares.len);
    try testing.expect(compares.len <= set_max);
    try testing.expectEqualStrings("/assigned/n0/hello-1", compares[6].key);
    try testing.expectEqual(@as(store.Revision, 9), compares[6].mod_revision);
    try testing.expectEqualStrings("/allocations/n0", compares[7].key);

    var released: Set = .{};
    release(&released, "n0", "hello-1", 9, 8);
    try testing.expectEqual(@as(usize, 2), released.compares().len);

    var observed: Set = .{};
    observed_write(&observed, "n1", 3);
    const only = observed.compares();
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("/nodes/n1", only[0].key);
    try testing.expectEqual(@as(store.Revision, 3), only[0].mod_revision);
}

test "a run's placement and release add the run and the status" {
    var placed: Set = .{};
    const run: RunRead = .{
        .job = "train",
        .run = "train-job",
        .run_revision = 11,
        .status_revision = 12,
    };
    placement_run(&placed, run, node_read);
    const compares = placed.compares();
    try testing.expectEqual(@as(usize, 7), compares.len);
    const expected = [_]store.Compare{
        .{ .key = "/job-runs/train", .mod_revision = 11 },
        .{ .key = "/job-status/train", .mod_revision = 12 },
        .{ .key = "/assigned/n1/train-job", .mod_revision = 0 },
        .{ .key = "/nodes/n1", .mod_revision = 3 },
        .{ .key = "/node-status/n1", .mod_revision = 4 },
        .{ .key = "/allocations/n1", .mod_revision = 5 },
        .{ .key = "/audit/allocations/n1", .mod_revision = 0 },
    };
    for (expected, compares) |want, got| {
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqual(want.mod_revision, got.mod_revision);
    }
    var released: Set = .{};
    const reads: ReleaseRead = .{
        .assigned_revision = 9,
        .allocation_revision = 8,
        .status_revision = 0,
    };
    release_run(&released, "n1", "train-job", "train", reads);
    const freed = released.compares();
    try testing.expectEqual(@as(usize, 3), freed.len);
    try testing.expectEqualStrings("/job-status/train", freed[2].key);
    try testing.expectEqual(@as(store.Revision, 0), freed[2].mod_revision);
}
