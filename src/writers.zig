//! Who may write which key (docs/authority.md §2, invariant I4), and the check every
//! transaction passes before it commits.
//!
//! Every prefix has one writer role. A transaction is made by one role, and `allowed` says
//! whether every put and delete in it is that role's. A transaction that fails the check is a
//! defect in the code that built it, never an error a caller handles: `txn` asserts. The role is
//! given at each call site; there is no "any".
//!
//! Beyond authority.md's six roles there is a seventh, `retention`: it deletes expired decisions
//! and so may touch only the three decision prefixes, which every role may write.

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
    /// The agent of the named node.
    agent: []const u8,

    pub fn name(role: Role) []const u8 {
        return @tagName(role);
    }
};

/// The role a prefix belongs to. `agent` stands for the agent of the node in the key.
const Owner = enum {
    api,
    /// `/services/<name>`: the API writes it, and C0's replica controller moves its
    /// `next_replica` counter in the transaction that creates replicas. That is an exception to
    /// authority.md §2's "sole writer", kept until the counter has a key of its own (see
    /// docs/DECISIONS.md); it may put the record and never delete it.
    api_with_counter,
    replica_controller,
    scheduler,
    node_controller,
    auditor,
    agent,
    anyone,
};

const Rule = struct { prefix: []const u8, owner: Owner };

/// The one table of authority.md §2. Longest prefix first where one contains another.
pub const rules = [_]Rule{
    .{ .prefix = records.prefix_services, .owner = .api_with_counter },
    .{ .prefix = records.prefix_replicas, .owner = .replica_controller },
    .{ .prefix = records.prefix_assigned, .owner = .scheduler },
    .{ .prefix = records.prefix_nodes, .owner = .agent },
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

fn rule_for(key: []const u8) ?Rule {
    for (rules) |rule| {
        if (std.mem.startsWith(u8, key, rule.prefix)) return rule;
    }
    return null;
}

fn may_write(role: Role, key: []const u8, op: store.Op) bool {
    const rule = rule_for(key) orelse return false;
    switch (rule.owner) {
        .anyone => return true,
        .api => return role == .api,
        .api_with_counter => switch (role) {
            .api => return true,
            .replica_controller => return op == .put,
            else => return false,
        },
        .replica_controller => return role == .replica_controller,
        .scheduler => return role == .scheduler,
        .node_controller => return role == .node_controller,
        .auditor => return role == .auditor,
        .agent => return agent_may_write(role, rule.prefix, key, op),
    }
}

/// An agent writes `/nodes/<its node>` and `/observed/<its node>/…`. The node controller also
/// removes a lost node's observed records (authority.md §3), and only removes them.
fn agent_may_write(role: Role, prefix: []const u8, key: []const u8, op: store.Op) bool {
    const rest = key[prefix.len..];
    if (std.mem.eql(u8, prefix, records.prefix_observed)) {
        if (role == .node_controller) return op == .delete;
    }
    const node = switch (role) {
        .agent => |node| node,
        else => return false,
    };
    if (std.mem.eql(u8, prefix, records.prefix_nodes)) return std.mem.eql(u8, rest, node);
    assert(std.mem.eql(u8, prefix, records.prefix_observed));
    if (!std.mem.startsWith(u8, rest, node)) return false;
    return rest.len > node.len and rest[node.len] == '/';
}

fn owner_name(key: []const u8) []const u8 {
    const rule = rule_for(key) orelse return "nobody";
    return switch (rule.owner) {
        .agent => "the agent of the node in the key",
        .anyone => "every role",
        .api_with_counter => "api",
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

/// A key under each prefix of the table, with the role that owns it. `/services/` is also open
/// to the replica controller's puts, which its own test checks.
const samples = [_]struct { key: []const u8, role: Role }{
    .{ .key = "/services/hello", .role = .api },
    .{ .key = "/replicas/hello/hello-1", .role = .replica_controller },
    .{ .key = "/assigned/n1/hello-1", .role = .scheduler },
    .{ .key = "/allocations/n1", .role = .scheduler },
    .{ .key = "/audit/allocations/n1", .role = .auditor },
    .{ .key = "/node-status/n1", .role = .node_controller },
    .{ .key = "/nodes/n1", .role = .{ .agent = "n1" } },
    .{ .key = "/observed/n1/hello-1", .role = .{ .agent = "n1" } },
};

const every_role = [_]Role{
    .api,     .replica_controller, .scheduler,         .node_controller,
    .auditor, .retention,          .{ .agent = "n1" }, .{ .agent = "n2" },
};

fn same_role(first: Role, second: Role) bool {
    if (std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    if (first == .agent) return std.mem.eql(u8, first.agent, second.agent);
    return true;
}

test "every prefix has one writer and every other role is refused" {
    // Goal: the table of authority.md §2 as code. Method: for each prefix, every role is tried;
    // exactly the owner is allowed.
    for (samples) |sample| {
        const request = request_of(&.{put_op(sample.key)});
        for (every_role) |role| {
            const verdict = allowed(role, request);
            const is_service = std.mem.eql(u8, sample.key, "/services/hello");
            const counter = role == .replica_controller and is_service;
            const should = counter or same_role(role, sample.role);
            try testing.expectEqual(should, verdict == .allowed);
        }
    }
}

test "the replica controller may put a service for its counter and never delete one" {
    // Goal: the one exception to the table of authority.md §2 is as narrow as C0 needs.
    const key = "/services/hello";
    try testing.expect(allowed(.replica_controller, request_of(&.{put_op(key)})) == .allowed);
    const drop = allowed(.replica_controller, request_of(&.{.{ .delete = key }}));
    try testing.expectEqualStrings("api", drop.refused.owner);
    try testing.expect(allowed(.scheduler, request_of(&.{put_op(key)})) == .refused);
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
    const own = [_][]const u8{ "/nodes/n1", "/observed/n1/hello-1" };
    for (own) |key| try testing.expect(allowed(role, request_of(&.{put_op(key)})) == .allowed);
    const other = [_][]const u8{
        "/nodes/n2",
        "/nodes/n10",
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
