//! Who may write which key (docs/authority.md §2, invariant I4), and the check every
//! transaction passes before it commits.
//!
//! Every prefix has one writer role. A transaction is made by one role, and `allowed` says
//! whether every put and delete in it is that role's. A transaction that fails the check is a
//! defect in the code that built it, never an error a caller handles: `txn` asserts. The role is
//! given at each call site; there is no "any".
//!
//! Beyond authority.md's six roles there is a seventh, `retention`: it deletes expired decisions,
//! old pull records and ended jobs, and so may touch only the three decision prefixes (which
//! every role may write) and may delete, never write, under `/pulls/` and the job prefixes
//! (`retention_deletes`); one ended job's five records go in one transaction (`retention_only`).
//! B1 adds an eighth, `job_controller` (authority.md, "Jobs").

const std = @import("std");
const assert = std.debug.assert;
const records = @import("records.zig");
const store = @import("store.zig");
const Diag = @import("diag.zig").Diag;

pub const Role = union(enum) {
    api,
    replica_controller,
    scheduler,
    node_controller,
    auditor,
    retention,
    job_controller,
    /// The agent of the named node.
    agent: []const u8,

    pub fn name(role: Role) []const u8 {
        return @tagName(role);
    }
};

/// The role a prefix belongs to. `agent` stands for the agent of the node in the key.
const Owner = enum {
    api,
    replica_controller,
    scheduler,
    node_controller,
    auditor,
    job_controller,
    agent,
    anyone,
};

/// `exact` rules name one key, not a prefix: `/job-admission` is a record, so `/job-admissions` and
/// `/job-endings/x` belong to nobody.
const Rule = struct { prefix: []const u8, owner: Owner, exact: bool = false };

/// The one table of authority.md §2. Longest prefix first where one contains another.
pub const rules = [_]Rule{
    .{ .prefix = records.prefix_services, .owner = .api },
    .{ .prefix = records.prefix_jobs, .owner = .api },
    .{ .prefix = records.prefix_job_input, .owner = .api },
    .{ .prefix = records.key_job_admission, .owner = .api, .exact = true },
    .{ .prefix = records.prefix_job_runs, .owner = .job_controller },
    .{ .prefix = records.prefix_job_status, .owner = .job_controller },
    .{ .prefix = records.key_job_endings, .owner = .job_controller, .exact = true },
    .{ .prefix = records.prefix_job_observed, .owner = .agent },
    .{ .prefix = records.prefix_replica_numbers, .owner = .replica_controller },
    .{ .prefix = records.prefix_replicas, .owner = .replica_controller },
    .{ .prefix = records.prefix_assigned, .owner = .scheduler },
    .{ .prefix = records.prefix_nodes, .owner = .agent },
    .{ .prefix = records.prefix_node_store, .owner = .agent },
    .{ .prefix = records.prefix_pulls, .owner = .agent },
    .{ .prefix = records.prefix_allocations, .owner = .scheduler },
    .{ .prefix = records.prefix_audit_allocations, .owner = .auditor },
    .{ .prefix = records.prefix_node_status, .owner = .node_controller },
    .{ .prefix = records.prefix_observed, .owner = .agent },
    .{ .prefix = records.prefix_decisions, .owner = .anyone },
    .{ .prefix = records.prefix_index, .owner = .anyone },
    .{ .prefix = records.prefix_summaries, .owner = .anyone },
};

pub const Refusal = struct {
    key: []const u8,
    /// Who owns the key: a role's name, "the agent of <node>", or "nobody" for a key under no
    /// prefix.
    owner: []const u8,
};

pub const Verdict = union(enum) {
    allowed,
    refused: Refusal,
};

/// Whether every put and delete of `request`, on success and on failure, is `role`'s to write.
/// Compares are reads and are not checked. One stray operation refuses the whole request.
pub fn allowed(role: Role, request: store.TxnRequest) Verdict {
    if (role == .retention) {
        if (orphaning_delete(request)) |key| {
            return .{ .refused = .{ .key = key, .owner = owner_name(key) } };
        }
    }
    for ([_][]const store.Op{ request.on_success, request.on_failure }) |ops| {
        for (ops) |op| {
            const key = switch (op) {
                .put => |put| put.key,
                .delete => |key| key,
            };
            if (may_write(role, key, op)) continue;
            return .{ .refused = .{ .key = key, .owner = owner_name(key) } };
        }
    }
    return .allowed;
}

/// I4 as the simulator sees it, without knowing who wrote: a transaction is one role's, so its
/// puts and deletes may not span the keys of two exclusive owners (every-role prefixes are
/// anyone's), may not touch a key under no prefix, and an agent's keys name one node. Returns the
/// first key that breaks this, or null.
pub fn foreign_key(request: store.TxnRequest) ?[]const u8 {
    if (orphaning_delete(request)) |key| return key;
    if (retention_only(request)) return null;
    var owner: ?Owner = null;
    var node: ?[]const u8 = null;
    for ([_][]const store.Op{ request.on_success, request.on_failure }) |ops| {
        for (ops) |op| {
            const key = switch (op) {
                .put => |put| put.key,
                .delete => |key| key,
            };
            const rule = rule_for(key) orelse return key;
            if (rule.owner == .anyone) continue;
            // The node controller may delete an agent's observed records (`agent_may_write`).
            if (owner) |first| {
                const pair_ok = first == .node_controller and rule.owner == .agent or
                    first == .agent and rule.owner == .node_controller;
                if (first != rule.owner and !pair_ok) return key;
            }
            owner = rule.owner;
            if (rule.owner != .agent) continue;
            const rest = key[rule.prefix.len..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            if (node) |first| {
                if (!std.mem.eql(u8, first, rest[0..end])) return key;
            }
            node = rest[0..end];
        }
    }
    return null;
}

/// Whether the prefix is one retention may delete from without owning it: an ended job's records,
/// and an old pull record.
fn retention_deletes(prefix: []const u8) bool {
    return job_record_prefix(prefix) or std.mem.eql(u8, prefix, records.prefix_pulls);
}

/// The five prefixes that hold the records of one job.
fn job_record_prefix(prefix: []const u8) bool {
    return std.mem.eql(u8, prefix, records.prefix_jobs) or
        std.mem.eql(u8, prefix, records.prefix_job_input) or
        std.mem.eql(u8, prefix, records.prefix_job_runs) or
        std.mem.eql(u8, prefix, records.prefix_job_status) or
        std.mem.eql(u8, prefix, records.prefix_job_observed);
}

/// The first delete of a job's run or status in a request that does not delete `/jobs/<name>`
/// too: the spec would outlive its run and the controller would run the job again (I8a).
/// authority.md §7: retention removes the spec in the same transaction.
fn orphaning_delete(request: store.TxnRequest) ?[]const u8 {
    var first: ?[]const u8 = null;
    for ([_][]const store.Op{ request.on_success, request.on_failure }) |ops| {
        for (ops) |op| {
            const key = switch (op) {
                .delete => |key| key,
                .put => continue,
            };
            if (std.mem.startsWith(u8, key, records.prefix_jobs)) return null;
            const run = std.mem.startsWith(u8, key, records.prefix_job_runs);
            const status = std.mem.startsWith(u8, key, records.prefix_job_status);
            if ((run or status) and first == null) first = key;
        }
    }
    return first;
}

/// Whether `request` is what retention writes to remove one ended job: deletes only, of keys that
/// all name the same job, in `/jobs/`, `/job-input/`, `/job-runs/`, `/job-status/` and
/// `/job-observed/<node>/` (under any nodes: a node that lost a claim leaves its record behind),
/// and of every-role prefixes, with at least one job key. That spans three owners, so
/// `foreign_key` lets it through.
/// Pull records are not part of it: they are per node, and `foreign_key` checks them as before.
fn retention_only(request: store.TxnRequest) bool {
    if (observed_sweep_only(request)) return true;
    var job: ?[]const u8 = null;
    for ([_][]const store.Op{ request.on_success, request.on_failure }) |ops| {
        for (ops) |op| {
            const key = switch (op) {
                .put => return false,
                .delete => |key| key,
            };
            const rule = rule_for(key) orelse return false;
            if (rule.owner == .anyone) continue;
            if (!job_record_prefix(rule.prefix)) return false;
            var name = key[rule.prefix.len..];
            if (std.mem.eql(u8, rule.prefix, records.prefix_job_observed)) {
                const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
                name = name[slash + 1 ..];
            }
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return false;
            if (job) |first| {
                if (!std.mem.eql(u8, first, name)) return false;
            }
            job = name;
        }
    }
    return job != null;
}

/// Whether `request` is a batch of retention's sweep of stray `/job-observed/` records: deletes
/// only, of those keys only, for any jobs and nodes (the sweep batches up to a transaction's
/// worth of strays in key order, so one batch spans nodes and jobs; `job_retention.sweep_observed`).
/// It was never exercised in the simulator before B2.1 slice 4 made retention run there.
fn observed_sweep_only(request: store.TxnRequest) bool {
    var count: u32 = 0;
    for ([_][]const store.Op{ request.on_success, request.on_failure }) |ops| {
        for (ops) |op| {
            const key = switch (op) {
                .put => return false,
                .delete => |key| key,
            };
            if (!std.mem.startsWith(u8, key, records.prefix_job_observed)) return false;
            count += 1;
        }
    }
    return count > 0;
}

fn rule_for(key: []const u8) ?Rule {
    for (rules) |rule| {
        const matches = if (rule.exact)
            std.mem.eql(u8, key, rule.prefix)
        else
            std.mem.startsWith(u8, key, rule.prefix);
        if (matches) return rule;
    }
    return null;
}

fn may_write(role: Role, key: []const u8, op: store.Op) bool {
    const rule = rule_for(key) orelse return false;
    if (role == .retention and op == .delete and retention_deletes(rule.prefix)) return true;
    switch (rule.owner) {
        .anyone => return true,
        .api => return role == .api,
        .replica_controller => return role == .replica_controller,
        .scheduler => return role == .scheduler,
        .node_controller => return role == .node_controller,
        .auditor => return role == .auditor,
        .job_controller => return role == .job_controller,
        .agent => return agent_may_write(role, rule.prefix, key, op),
    }
}

/// An agent writes `/nodes/<its node>`, `/node-store/<its node>`, `/observed/<its node>/…`,
/// `/job-observed/<its node>/…` and `/pulls/<its node>/…`.
/// The node controller also
/// removes a lost node's observed records (authority.md §3), and only removes them.
fn agent_may_write(role: Role, prefix: []const u8, key: []const u8, op: store.Op) bool {
    const rest = key[prefix.len..];
    if (std.mem.eql(u8, prefix, records.prefix_observed)) {
        if (role == .node_controller) return op == .delete;
    }
    // Retention drops a node's old pull records and ended jobs' observations (`may_write`).
    const node = switch (role) {
        .agent => |node| node,
        else => return false,
    };
    if (std.mem.eql(u8, prefix, records.prefix_nodes)) return std.mem.eql(u8, rest, node);
    if (std.mem.eql(u8, prefix, records.prefix_node_store)) return std.mem.eql(u8, rest, node);
    assert(std.mem.eql(u8, prefix, records.prefix_observed) or
        std.mem.eql(u8, prefix, records.prefix_job_observed) or
        std.mem.eql(u8, prefix, records.prefix_pulls));
    if (!std.mem.startsWith(u8, rest, node)) return false;
    return rest.len > node.len and rest[node.len] == '/';
}

fn owner_name(key: []const u8) []const u8 {
    const rule = rule_for(key) orelse return "nobody";
    return switch (rule.owner) {
        .agent => "the agent of the node in the key",
        .anyone => "every role",
        else => |owner| @tagName(owner),
    };
}

/// Commits `request` as `role`. A request that is not the role's is a defect: it asserts.
pub fn txn(
    s: store.Store,
    role: Role,
    request: store.TxnRequest,
    diag: *Diag,
) store.Error!store.TxnResult {
    check(role, request);
    return s.txn(request, diag);
}

/// Asserts that `request` is `role`'s to write (I4).
pub fn check(role: Role, request: store.TxnRequest) void {
    switch (allowed(role, request)) {
        .allowed => {},
        .refused => |refusal| std.debug.panic(
            "writer role {s} may not write {s}, which belongs to {s}",
            .{ role.name(), refusal.key, refusal.owner },
        ),
    }
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn put_op(key: []const u8) store.Op {
    return .{ .put = .{ .key = key, .value = "{}" } };
}

fn request_of(ops: []const store.Op) store.TxnRequest {
    return .{ .on_success = ops };
}

/// A key under each prefix of the table, with the role that owns it. `/services/` is the API's
/// alone.
const samples = [_]struct { key: []const u8, role: Role }{
    .{ .key = "/services/hello", .role = .api },
    .{ .key = "/jobs/j1", .role = .api },
    .{ .key = "/job-input/j1", .role = .api },
    .{ .key = "/job-admission", .role = .api },
    .{ .key = "/job-runs/j1", .role = .job_controller },
    .{ .key = "/job-status/j1", .role = .job_controller },
    .{ .key = "/job-endings", .role = .job_controller },
    .{ .key = "/job-observed/n1/j1", .role = .{ .agent = "n1" } },
    .{ .key = "/replicas/hello/hello-1", .role = .replica_controller },
    .{ .key = "/replica-numbers/hello", .role = .replica_controller },
    .{ .key = "/assigned/n1/hello-1", .role = .scheduler },
    .{ .key = "/allocations/n1", .role = .scheduler },
    .{ .key = "/audit/allocations/n1", .role = .auditor },
    .{ .key = "/node-status/n1", .role = .node_controller },
    .{ .key = "/nodes/n1", .role = .{ .agent = "n1" } },
    .{ .key = "/node-store/n1", .role = .{ .agent = "n1" } },
    .{ .key = "/observed/n1/hello-1", .role = .{ .agent = "n1" } },
    .{ .key = "/pulls/n1/b3:51aa9c03", .role = .{ .agent = "n1" } },
};

const every_role = [_]Role{
    .api,               .replica_controller, .scheduler,      .node_controller,
    .auditor,           .retention,          .job_controller, .{ .agent = "n1" },
    .{ .agent = "n2" },
};

fn same_role(first: Role, second: Role) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    if (first == .agent) return std.mem.eql(u8, first.agent, second.agent);
    return true;
}

test "every prefix has one writer and every other role is refused" {
    // Goal: the table of authority.md §2 as code. Method: for each prefix, every role is tried;
    // exactly the owner is allowed (a write: retention's deletes are tested below).
    for (samples) |sample| {
        const request = request_of(&.{put_op(sample.key)});
        for (every_role) |role| {
            const verdict = allowed(role, request);
            try testing.expectEqual(same_role(role, sample.role), verdict == .allowed);
        }
    }
}

test "/services/ is the API's alone, and the counter is the replica controller's" {
    // Goal: the exception C0 kept for `next_replica` is gone (authority.md §2). Method: the
    // replica controller can neither put nor delete a service, and it owns the counter key.
    const key = "/services/hello";
    for ([_]Role{ .replica_controller, .scheduler, .node_controller }) |role| {
        try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .refused);
        try testing.expect(allowed(role, request_of(&.{.{ .delete = key }})) == .refused);
    }
    const counter = "/replica-numbers/hello";
    try testing.expect(allowed(.replica_controller, request_of(&.{put_op(counter)})) == .allowed);
    const drop = allowed(.replica_controller, request_of(&.{.{ .delete = counter }}));
    try testing.expect(drop == .allowed);
    try testing.expect(allowed(.api, request_of(&.{put_op(counter)})) == .refused);
}

test "every role may write the decision prefixes" {
    // Goal: a decision is written in the transaction of the action it records, by any role.
    const keys = [_][]const u8{
        "/decisions/1761350000123-0001-0007",
        "/decisions-by-subject/service/hello/1761350000123-0001-0007",
        "/decision-summaries/service/hello/replace_replica/observed",
    };
    for (keys) |key| {
        for (every_role) |role| {
            const request: store.TxnRequest = .{
                .on_success = &.{put_op(key)},
                .on_failure = &.{.{ .delete = key }},
            };
            try testing.expect(allowed(role, request) == .allowed);
        }
    }
}

test "an agent writes only its own node and its own observed records" {
    // Goal: an agent cannot write another node's keys, nor a key that merely starts with its
    // node's name. Method: node n1 against n2's keys, and against "n10".
    const role: Role = .{ .agent = "n1" };
    const own = [_][]const u8{ "/nodes/n1", "/node-store/n1", "/observed/n1/hello-1" };
    for (own) |key| try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .allowed);
    const other = [_][]const u8{
        "/nodes/n2",
        "/nodes/n10",
        "/node-store/n2",
        "/node-store/n10",
        "/node-store/n1/x",
        "/observed/n2/hello-1",
        "/observed/n10/hello-1",
        "/observed/n1",
        "/observed/n1x/hello-1",
        "/replicas/hello/hello-1",
    };
    for (other) |key| {
        const verdict = allowed(role, request_of(&.{.{ .delete = key }}));
        try testing.expect(verdict == .refused);
        try testing.expectEqualStrings(key, verdict.refused.key);
    }
}

test "an agent writes its own pulls only, and retention may delete them but never write them" {
    // Goal: /pulls/<node>/<tree> is the node's agent's (C2 slice 7), kept down by retention.
    const role: Role = .{ .agent = "n1" };
    const own = "/pulls/n1/b3:51aa9c03";
    try testing.expect(allowed(role, request_of(&.{put_op(own)})) == .allowed);
    const other = [_][]const u8{ "/pulls/n2/b3:51aa9c03", "/pulls/n10/x", "/pulls/n1", "/pulls/" };
    for (other) |key| try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .refused);
    try testing.expect(allowed(.retention, request_of(&.{.{ .delete = own }})) == .allowed);
    try testing.expect(allowed(.retention, request_of(&.{put_op(own)})) == .refused);
    try testing.expect(allowed(.scheduler, request_of(&.{.{ .delete = own }})) == .refused);
}

test "one stray operation refuses the whole transaction and names the key and its owner" {
    // Goal: the check is on the transaction, not on its first operation.
    const ops = [_]store.Op{
        put_op("/services/hello"),
        put_op("/decisions/1761350000123-0001-0007"),
        put_op("/allocations/n1"),
    };
    const verdict = allowed(.api, request_of(&ops));
    try testing.expectEqualStrings("/allocations/n1", verdict.refused.key);
    try testing.expectEqualStrings("scheduler", verdict.refused.owner);
    // The failure branch is written too, so it is checked too.
    const on_failure: store.TxnRequest = .{ .on_failure = &.{put_op("/node-status/n1")} };
    try testing.expect(allowed(.api, on_failure) == .refused);
    // A key under no prefix is nobody's.
    const unknown = allowed(.api, request_of(&.{put_op("/leader/controllers")}));
    try testing.expectEqualStrings("nobody", unknown.refused.owner);
}

test "the node controller removes observed records and writes none" {
    // Goal: authority.md §3: it removes a lost node's observed records, each with its decision.
    const key = "/observed/n1/hello-1";
    try testing.expect(allowed(.node_controller, request_of(&.{.{ .delete = key }})) == .allowed);
    try testing.expect(allowed(.node_controller, request_of(&.{put_op(key)})) == .refused);
}

test "foreign_key finds a transaction that no single role could have written" {
    const ok = [_]store.Op{ put_op("/services/hello"), put_op("/decisions/d1") };
    try testing.expect(foreign_key(request_of(&ok)) == null);
    const mixed = [_]store.Op{ put_op("/services/hello"), put_op("/assigned/n1/hello-1") };
    try testing.expectEqualStrings("/assigned/n1/hello-1", foreign_key(request_of(&mixed)).?);
    const nowhere = [_]store.Op{put_op("/nowhere/x")};
    try testing.expectEqualStrings("/nowhere/x", foreign_key(request_of(&nowhere)).?);
    const two_nodes = [_]store.Op{ put_op("/nodes/n1"), put_op("/observed/n2/c1") };
    try testing.expectEqualStrings("/observed/n2/c1", foreign_key(request_of(&two_nodes)).?);
    const own = [_]store.Op{ put_op("/nodes/n1"), put_op("/observed/n1/c1") };
    try testing.expect(foreign_key(request_of(&own)) == null);
}

test "jobs: one writer per prefix, the job controller never touches placement" {
    // Goal: B1's rows of the table (brief, "Settled here"). Method: the job controller against
    // every key it must not write, and the scheduler against every key of the job controller.
    const controller_keys = [_][]const u8{ "/job-runs/j1", "/job-status/j1", "/job-endings" };
    for (controller_keys) |key| {
        try testing.expect(allowed(.scheduler, request_of(&.{put_op(key)})) == .refused);
        try testing.expect(allowed(.api, request_of(&.{put_op(key)})) == .refused);
        try testing.expect(allowed(.job_controller, request_of(&.{put_op(key)})) == .allowed);
    }
    const foreign = [_][]const u8{
        "/jobs/j1",        "/job-input/j1",   "/job-admission",   "/assigned/n1/j1-job",
        "/allocations/n1", "/replicas/s/s-1", "/observed/n1/s-1", "/job-observed/n1/j1",
        "/node-status/n1", "/services/s",
    };
    for (foreign) |key| {
        try testing.expect(allowed(.job_controller, request_of(&.{put_op(key)})) == .refused);
        const removal = request_of(&.{.{ .delete = key }});
        try testing.expect(allowed(.job_controller, removal) == .refused);
    }
    // The decisions are every role's.
    const decision = request_of(&.{put_op("/decisions/1761350000123-0001-0007")});
    try testing.expect(allowed(.job_controller, decision) == .allowed);
}

test "an agent writes its own job observations only" {
    const role: Role = .{ .agent = "n1" };
    try testing.expect(allowed(role, request_of(&.{put_op("/job-observed/n1/j1")})) == .allowed);
    const other = [_][]const u8{
        "/job-observed/n2/j1", "/job-observed/n10/j1", "/job-observed/n1", "/job-observed/n1x/j1",
    };
    for (other) |key| try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .refused);
    const jobs = [_][]const u8{ "/jobs/j1", "/job-runs/j1", "/job-status/j1", "/job-input/j1" };
    for (jobs) |key| try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .refused);
}

test "retention deletes ended jobs' records and never writes them" {
    // Goal: brief, "Writer table": deletes on /jobs/, /job-input/, /job-runs/, /job-status/ and
    // /job-observed/, one transaction per job, which spans three owners.
    const keys = [_][]const u8{
        "/jobs/j1",            "/job-input/j1", "/job-runs/j1", "/job-status/j1",
        "/job-observed/n1/j1",
    };
    var deletes: [keys.len]store.Op = undefined;
    for (keys, &deletes) |key, *op| op.* = .{ .delete = key };
    const all = request_of(&deletes);
    try testing.expect(allowed(.retention, all) == .allowed);
    try testing.expect(foreign_key(all) == null);
    for (keys) |key| {
        try testing.expect(allowed(.retention, request_of(&.{put_op(key)})) == .refused);
        try testing.expect(allowed(.scheduler, request_of(&.{.{ .delete = key }})) == .refused);
    }
    // Not the aggregates, which only grow, and not placement.
    const never = [_][]const u8{ "/job-admission", "/job-endings", "/assigned/n1/j1-job" };
    for (never) |key| {
        try testing.expect(allowed(.retention, request_of(&.{.{ .delete = key }})) == .refused);
    }
    // A transaction that writes, or that deletes a key retention may not, is still foreign.
    const mixed = [_]store.Op{ .{ .delete = "/jobs/j1" }, put_op("/job-status/j1") };
    try testing.expectEqualStrings("/job-status/j1", foreign_key(request_of(&mixed)).?);
    const stray = [_]store.Op{ .{ .delete = "/jobs/j1" }, .{ .delete = "/assigned/n1/j1-job" } };
    try testing.expectEqualStrings("/assigned/n1/j1-job", foreign_key(request_of(&stray)).?);
}

test "foreign_key lets one job controller or API transaction through and stops a mixed one" {
    const controller = [_]store.Op{ put_op("/job-runs/j1"), put_op("/job-status/j1") };
    try testing.expect(foreign_key(request_of(&controller)) == null);
    const ending = [_]store.Op{
        put_op("/job-status/j1"), put_op("/job-endings"), put_op("/decisions/d1"),
    };
    try testing.expect(foreign_key(request_of(&ending)) == null);
    const create = [_]store.Op{
        put_op("/jobs/j1"), put_op("/job-input/j1"), put_op("/job-admission"),
    };
    try testing.expect(foreign_key(request_of(&create)) == null);
    const mixed = [_]store.Op{ put_op("/jobs/j1"), put_op("/job-runs/j1") };
    try testing.expectEqualStrings("/job-runs/j1", foreign_key(request_of(&mixed)).?);
    const placing = [_]store.Op{ put_op("/job-status/j1"), put_op("/assigned/n1/j1-job") };
    try testing.expectEqualStrings("/assigned/n1/j1-job", foreign_key(request_of(&placing)).?);
}

test "retention's sweep of stray observations may span nodes and jobs, and only deletes" {
    // Goal: `observed_sweep_only` admits a batch of `/job-observed/` deletes (the sweep's), and
    // nothing wider. Method: a batch over two nodes and two jobs, then batches that are not one.
    const sweep = [_]store.Op{
        .{ .delete = "/job-observed/n1/a" },
        .{ .delete = "/job-observed/n2/b" },
    };
    try testing.expect(foreign_key(request_of(&sweep)) == null);
    try testing.expect(allowed(.retention, request_of(&sweep)) == .allowed);
    const wrong = [_][]const store.Op{
        &.{ .{ .delete = "/job-observed/n1/a" }, .{ .delete = "/job-runs/b" } },
        &.{ .{ .delete = "/job-observed/n1/a" }, .{ .put = .{ .key = "/job-observed/n2/b", .value = "" } } },
    };
    for (wrong) |ops| try testing.expect(foreign_key(request_of(ops)) != null);
}

test "retention's job transaction names one job, and carries no pull records" {
    // Goal: `retention_only` lets through exactly the removal of one job's records. Method: the
    // right transaction, then each way a transaction can name more than that.
    const deletes = [_]store.Op{
        .{ .delete = "/jobs/a" },
        .{ .delete = "/job-input/a" },
        .{ .delete = "/job-runs/a" },
        .{ .delete = "/job-status/a" },
        .{ .delete = "/job-observed/n1/a" },
        .{ .delete = "/decisions/d1" },
    };
    try testing.expect(foreign_key(request_of(&deletes)) == null);
    // RA-S6: the job's observations on two nodes (a node that lost the claim left one behind).
    const two_nodes = [_]store.Op{
        .{ .delete = "/jobs/a" },
        .{ .delete = "/job-runs/a" },
        .{ .delete = "/job-observed/n1/a" },
        .{ .delete = "/job-observed/n2/a" },
    };
    try testing.expect(foreign_key(request_of(&two_nodes)) == null);
    try testing.expect(allowed(.retention, request_of(&two_nodes)) == .allowed);
    const without_observed = [_]store.Op{ .{ .delete = "/jobs/a" }, .{ .delete = "/job-runs/a" } };
    try testing.expect(foreign_key(request_of(&without_observed)) == null);
    const wrong = [_][]const store.Op{
        // Another job's run beside this job.
        &.{ .{ .delete = "/jobs/a" }, .{ .delete = "/job-runs/b" } },
        &.{ .{ .delete = "/jobs/a" }, .{ .delete = "/job-observed/n1/b" } },
        // A pull record mixed in, or a node's pull records across nodes.
        &.{ .{ .delete = "/jobs/a" }, .{ .delete = "/pulls/n1/b3:aa" } },
        &.{ .{ .delete = "/pulls/n1/b3:aa" }, .{ .delete = "/pulls/n2/b3:aa" } },
        // Not a job's record: a nested name, no node.
        &.{ .{ .delete = "/jobs/a/b" }, .{ .delete = "/job-runs/a" } },
        &.{ .{ .delete = "/job-observed/n1" }, .{ .delete = "/jobs/a" } },
    };
    for (wrong) |ops| try testing.expect(foreign_key(request_of(ops)) != null);
    // One owner's transactions (the API's) pass `foreign_key` on their own; retention's rule must
    // still refuse them: no name, and an aggregate.
    const not_retention = [_][]const store.Op{
        &.{.{ .delete = "/jobs/" }},
        &.{ .{ .delete = "/job-admission" }, .{ .delete = "/jobs/a" } },
    };
    for (not_retention) |ops| try testing.expect(!retention_only(request_of(ops)));
    // One node's pull records on their own are one owner, as before jobs.
    const pulls = [_]store.Op{ .{ .delete = "/pulls/n1/b3:aa" }, .{ .delete = "/pulls/n1/b3:bb" } };
    try testing.expect(foreign_key(request_of(&pulls)) == null);
    // The run or the status without the spec would leave a job that is run again (I8a); the
    // input alone (deleted at the ending) is fine.
    const orphaning = [_][]const store.Op{
        &.{ .{ .delete = "/job-runs/a" }, .{ .delete = "/job-status/a" } },
        &.{.{ .delete = "/job-runs/a" }},
        &.{ .{ .delete = "/job-status/a" }, .{ .delete = "/job-input/a" } },
    };
    for (orphaning) |ops| {
        try testing.expect(foreign_key(request_of(ops)) != null);
        try testing.expect(allowed(.retention, request_of(ops)) == .refused);
    }
    const whole = [_]store.Op{ .{ .delete = "/job-runs/a" }, .{ .delete = "/jobs/a" } };
    try testing.expect(allowed(.retention, request_of(&whole)) == .allowed);
    const input_only = [_]store.Op{.{ .delete = "/job-input/a" }};
    try testing.expect(retention_only(request_of(&input_only)));
    // A job record with a put is never retention's.
    const with_put = [_]store.Op{ .{ .delete = "/jobs/a" }, put_op("/job-runs/a") };
    try testing.expect(foreign_key(request_of(&with_put)) != null);
}

test "the two job aggregates are exact keys, not prefixes" {
    // Goal: `/job-admissions` and `/job-endings/x` are under no rule (authority.md I4).
    const strays = [_][]const u8{
        "/job-admissions", "/job-admission/x", "/job-endings/x", "/job-endingsx",
    };
    for (strays) |key| {
        try testing.expect(rule_for(key) == null);
        for (every_role) |role| {
            const verdict = allowed(role, request_of(&.{put_op(key)}));
            try testing.expectEqualStrings("nobody", verdict.refused.owner);
        }
        try testing.expectEqualStrings(key, foreign_key(request_of(&.{put_op(key)})).?);
    }
    try testing.expect(rule_for("/job-admission") != null);
    try testing.expect(rule_for("/job-endings") != null);
}
