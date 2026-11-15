//! Who may call what (B7, docs/mtls.md, "Scopes"). The shell names the caller from the client
//! certificate the TLS handshake verified, never from a header; `Api.handle` asks `refusal`
//! before it routes, and a request the caller may not make is refused with 403 ZC-E0822 before
//! anything is read or written. The HTTP shell asks it too, before it reads a request's body, so
//! a refused body is never read (`server_http.zig`, `refused_unread`).
//!
//! - A node's certificate (an agent) may call the agent API under its own node's name only:
//!   `/v1/agent/nodes/<its name>` and below. The agent handlers keep every key they write under
//!   the node of the path, so an agent writes only under its own node's keys.
//! - A client of scope `jobs` may create, read, cancel and watch jobs: `/v1/jobs` and below, and
//!   `GET /v1/why/job/<name>`. Nothing else.
//! - A client of scope `admin`, and the loopback `--insecure-listen` listener, may call
//!   everything but one path: `POST /v1/agent/nodes/<name>/credential`, which issues a node
//!   certificate, is the node's own (and `local`'s). No client certificate may call it, admin
//!   included: there is no admin bootstrap (decisions/2026-11-13-node-cert-bootstrap.md).
//! - Any node's certificate may also read the peers' summaries, the swarm fetch's discovery:
//!   `GET /v1/list` with `prefix` exactly `/node-store/` and no parameter but `limit`, `at` and
//!   `continue` (B7 slice 7, decisions/2026-11-14-b7-slice7-node-store-read.md). Nothing else
//!   under `/v1/list`, so a node never reads another service's spec (its env).
//!   Which nodes fetch a tree (O5) a node learns under its own path instead,
//!   `GET /v1/agent/nodes/<its name>/fetchers/<digest>`: node names only, computed by the
//!   server (decisions/2026-11-14-b7-slice7-o5-over-tls.md).

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const x509_identity = @import("x509_identity.zig");

pub const Scope = x509_identity.Scope;

/// The authenticated caller of one request.
pub const Caller = union(enum) {
    /// The loopback `--insecure-listen` listener, the console module and the simulators: no
    /// certificate, and everything is allowed (the operator chose to listen in the clear).
    local,
    /// A node's agent, by its node name (not the SPIFFE URI).
    node: []const u8,
    /// A client of the API, by the name `ca issue-client` was given, and its scope.
    client: Client,

    pub const Client = struct {
        name: []const u8,
        scope: Scope,
    };

    pub fn format(caller: Caller, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (caller) {
            .local => try writer.writeAll("the local listener"),
            .node => |name| try writer.print("node {s}'s certificate", .{name}),
            .client => |client| try writer.print(
                "client {s} (scope {s})",
                .{ client.name, client.scope.text() },
            ),
        }
    }
};

/// What a refused request would have needed.
pub const Need = union(enum) {
    /// The certificate of this node (or an admin client's).
    node: []const u8,
    /// The certificate of this node, and nothing else: the credential endpoint.
    node_only: []const u8,
    /// A client of scope `jobs` (or `admin`).
    jobs,
    /// Any node's certificate (or an admin client's): the peers' summaries.
    any_node,
    /// A client of scope `admin`.
    admin,

    pub fn format(need: Need, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (need) {
            .node => |name| try writer.print(
                "node {s}'s certificate or a client of scope admin",
                .{name},
            ),
            .node_only => |name| try writer.print("node {s}'s own certificate", .{name}),
            .any_node => try writer.writeAll("a node's certificate or a client of scope admin"),
            .jobs => try writer.writeAll("a client of scope jobs or admin"),
            .admin => try writer.writeAll("a client of scope admin"),
        }
    }
};

/// Null when `caller` may make the request; else what it would need. `path` is without the
/// query; `query` is the raw query string without the '?'.
pub fn refusal(caller: Caller, method: []const u8, path: []const u8, query: []const u8) ?Need {
    const need = need_of(method, path, query);
    switch (caller) {
        .local => return null,
        .client => |client| switch (need) {
            .node_only => {},
            .node, .any_node, .admin => if (client.scope == .admin) return null,
            .jobs => return null,
        },
        .node => |own| switch (need) {
            .node, .node_only => |name| if (std.mem.eql(u8, name, own)) return null,
            .any_node => return null,
            .jobs, .admin => {},
        },
    }
    return need;
}

/// Test-only fault for the teeth test: the `prefix` of a node's list is not checked, so a node
/// could read any prefix, services' specs (their env) included.
pub const TestFault = enum { prefix_check };
var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

/// The least a request needs, from its method, path and query alone.
fn need_of(method: []const u8, path: []const u8, query: []const u8) Need {
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/v1/list")) {
        if (node_store_query(query)) return .any_node;
        return .admin;
    }
    const agent = "/v1/agent/nodes/";
    if (std.mem.startsWith(u8, path, agent)) {
        const rest = path[agent.len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        // An empty node name is no node's: only an admin may be told there is nothing there.
        if (end == 0) return .admin;
        const node = rest[0..end];
        if (std.mem.eql(u8, rest[end..], "/credential")) return .{ .node_only = node };
        return .{ .node = node };
    }
    if (std.mem.eql(u8, path, "/v1/jobs")) return .jobs;
    if (std.mem.startsWith(u8, path, "/v1/jobs/")) return .jobs;
    const why_job = "/v1/why/job/";
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, why_job)) {
        if (path.len > why_job.len) return .jobs;
    }
    return .admin;
}

/// Whether `query` is a read of `/node-store/` and nothing more: `prefix` once, exactly
/// `/node-store/` once percent-decoded, and no parameter but `limit`, `at` and `continue`, each at
/// most once. Anything else, an empty or malformed parameter included, is not.
fn node_store_query(query: []const u8) bool {
    const allowed = [_][]const u8{ "prefix", "limit", "at", "continue" };
    var seen: [allowed.len]bool = @splat(false);
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        const equals = std.mem.indexOfScalar(u8, param, '=') orelse return false;
        const key = param[0..equals];
        const index = for (allowed, 0..) |name, at| {
            if (std.mem.eql(u8, key, name)) break at;
        } else return false;
        if (seen[index]) return false;
        seen[index] = true;
        if (index != 0 or fault_on(.prefix_check)) continue;
        if (!decodes_to(param[equals + 1 ..], node_store_prefix)) return false;
    }
    return seen[0];
}

const node_store_prefix = "/node-store/";

/// Whether `text`, percent-decoded ('+' stays a plus, as `api.zig` decodes it), is `want`.
fn decodes_to(text: []const u8, want: []const u8) bool {
    var index: usize = 0;
    var length: usize = 0;
    while (index < text.len) : (length += 1) {
        if (length == want.len) return false;
        var byte = text[index];
        if (byte == '%') {
            if (index + 3 > text.len) return false;
            const high = std.fmt.charToDigit(text[index + 1], 16) catch return false;
            const low = std.fmt.charToDigit(text[index + 2], 16) catch return false;
            byte = high * 16 + low;
            index += 3;
        } else {
            index += 1;
        }
        if (byte != want[length]) return false;
    }
    return length == want.len;
}

const testing = std.testing;

test "need_of: the agent API by node, the jobs API, and everything else is admin's" {
    const Row = struct { method: []const u8, path: []const u8, need: Need };
    const rows = [_]Row{
        .{ .method = "PUT", .path = "/v1/agent/nodes/node1", .need = .{ .node = "node1" } },
        .{ .method = "GET", .path = "/v1/agent/nodes/node1/watch", .need = .{ .node = "node1" } },
        .{
            .method = "POST",
            .path = "/v1/agent/nodes/node1/credential",
            .need = .{ .node_only = "node1" },
        },
        .{ .method = "POST", .path = "/v1/agent/nodes/node1/credentials", .need = .{
            .node = "node1",
        } },
        .{
            .method = "GET",
            .path = "/v1/agent/nodes/node1/fetchers/b3:51aa9c03",
            .need = .{ .node = "node1" },
        },
        .{ .method = "GET", .path = "/v1/agent/nodes/", .need = .admin },
        .{ .method = "GET", .path = "/v1/agent/nodes", .need = .admin },
        .{ .method = "GET", .path = "/v1/agent/", .need = .admin },
        .{ .method = "GET", .path = "/v1/jobs", .need = .jobs },
        .{ .method = "POST", .path = "/v1/jobs", .need = .jobs },
        .{ .method = "POST", .path = "/v1/jobs/a/cancel", .need = .jobs },
        .{ .method = "GET", .path = "/v1/jobs/watch", .need = .jobs },
        .{ .method = "GET", .path = "/v1/jobsx", .need = .admin },
        .{ .method = "GET", .path = "/v1/why/job/a", .need = .jobs },
        .{ .method = "GET", .path = "/v1/why/job/", .need = .admin },
        .{ .method = "POST", .path = "/v1/why/job/a", .need = .admin },
        .{ .method = "GET", .path = "/v1/why/node/a", .need = .admin },
        .{ .method = "GET", .path = "/v1/status", .need = .admin },
        .{ .method = "POST", .path = "/v1/services", .need = .admin },
    };
    for (rows) |row| {
        const need = need_of(row.method, row.path, "");
        try testing.expectEqual(std.meta.activeTag(row.need), std.meta.activeTag(need));
        switch (row.need) {
            .node => |name| try testing.expectEqualStrings(name, need.node),
            .node_only => |name| try testing.expectEqualStrings(name, need.node_only),
            .any_node, .jobs, .admin => {},
        }
    }
}

test "refusal: a node only under its own name, jobs only jobs, admin and local everything" {
    const node1: Caller = .{ .node = "node1" };
    const jobs: Caller = .{ .client = .{ .name = "app", .scope = .jobs } };
    const admin: Caller = .{ .client = .{ .name = "ops", .scope = .admin } };
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node1", "") == null);
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node2", "") != null);
    // A prefix of another name is not the name.
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node12/lease", "") != null);
    // Which nodes fetch a tree (O5, B7 slice 7): asked under the node's own name only.
    const fetchers = "/fetchers/b3:51aa9c03";
    try testing.expect(refusal(node1, "GET", "/v1/agent/nodes/node1" ++ fetchers, "") == null);
    try testing.expect(refusal(node1, "GET", "/v1/agent/nodes/node2" ++ fetchers, "") != null);
    try testing.expect(refusal(jobs, "GET", "/v1/agent/nodes/node1" ++ fetchers, "") != null);
    try testing.expect(refusal(node1, "GET", "/v1/jobs", "") != null);
    try testing.expect(refusal(node1, "GET", "/v1/status", "") != null);
    try testing.expect(refusal(jobs, "POST", "/v1/jobs", "") == null);
    try testing.expect(refusal(jobs, "POST", "/v1/services", "") != null);
    try testing.expect(refusal(jobs, "PUT", "/v1/agent/nodes/node1", "") != null);
    // The credential endpoint is the node's own: no client, admin included (no admin bootstrap).
    const credential = "/v1/agent/nodes/node1/credential";
    try testing.expect(refusal(node1, "POST", credential, "") == null);
    try testing.expect(refusal(.local, "POST", credential, "") == null);
    try testing.expect(refusal(.{ .node = "node2" }, "POST", credential, "") != null);
    try testing.expect(refusal(jobs, "POST", credential, "") != null);
    try testing.expect(refusal(admin, "POST", credential, "") != null);
    for ([_]Caller{ admin, .local }) |caller| {
        try testing.expect(refusal(caller, "PUT", "/v1/agent/nodes/node2", "") == null);
        try testing.expect(refusal(caller, "POST", "/v1/services", "") == null);
        try testing.expect(refusal(caller, "GET", "/v1/jobs", "") == null);
    }
}

test "a node may list /node-store/ with limit, at and continue, and nothing else" {
    // Goal: the one read a node's certificate has beyond its own path (B7 slice 7) is exactly the
    // peers' summaries: every near miss of the method, path, prefix or parameters is admin's.
    const node1: Caller = .{ .node = "node1" };
    const jobs: Caller = .{ .client = .{ .name = "app", .scope = .jobs } };
    const admin: Caller = .{ .client = .{ .name = "ops", .scope = .admin } };
    const allowed = [_][]const u8{
        "prefix=/node-store/",
        "prefix=%2Fnode-store%2F",
        "prefix=%2fnode-store%2f",
        "prefix=/node-store/&limit=64",
        "limit=64&prefix=/node-store/&at=12&continue=%2Fnode-store%2Fnode3",
    };
    for (allowed) |query| {
        try testing.expect(refusal(node1, "GET", "/v1/list", query) == null);
        try testing.expect(refusal(.{ .node = "node9" }, "GET", "/v1/list", query) == null);
        try testing.expect(refusal(admin, "GET", "/v1/list", query) == null);
        try testing.expect(refusal(jobs, "GET", "/v1/list", query) != null);
        try testing.expect(refusal(node1, "POST", "/v1/list", query) != null);
        try testing.expect(refusal(node1, "HEAD", "/v1/list", query) != null);
        try testing.expect(refusal(node1, "GET", "/v1/list/", query) != null);
        try testing.expect(refusal(node1, "GET", "/v1/lists", query) != null);
        try testing.expect(refusal(node1, "GET", "/v1/watch", query) != null);
    }
    const refused = [_][]const u8{
        "",
        "limit=64",
        "prefix=",
        "prefix=/",
        "prefix=/node-store",
        "prefix=/node-store/node2",
        "prefix=/node-storex/",
        "prefix=/node-store/%",
        "prefix=/node-store/%2",
        "prefix=/node-store%2",
        "prefix=/replicas/",
        "prefix=/assigned/",
        "prefix=/services/",
        "prefix=/Node-store/",
        "prefix=+/node-store/",
        "prefix=/node-store/&prefix=/services/",
        "prefix=/services/&prefix=/node-store/",
        "prefix=/node-store/&reverse=true",
        "prefix=/node-store/&limit=1&limit=2",
        "prefix=/node-store/&",
        "&prefix=/node-store/",
        "prefix=/node-store/&watch=true",
        "prefix=/node-store/&limit",
        "pre%66ix=/node-store/",
        "pre=/node-store/",
        "prefix=/node-store/&lim=5",
        "prefix=/node-store/&a=1",
        "prefix=/node-store/&continu=/node-store/x",
        "prefix=/node-store/%00",
    };
    for (refused) |query| {
        const need = refusal(node1, "GET", "/v1/list", query) orelse return error.TestFailed;
        try testing.expect(need == .admin);
        try testing.expect(refusal(admin, "GET", "/v1/list", query) == null);
    }
}

test "teeth: without the prefix check a node reads the services' specs" {
    // Goal: the prefix check is what keeps a node's list to `/node-store/` (a service's spec holds
    // its env). The negative half runs here too: `mtls-teeth` does not run the plain tests.
    const node1: Caller = .{ .node = "node1" };
    const reads = [_][]const u8{
        "prefix=/services/&limit=500",
        "prefix=/replicas/",
        "prefix=/env/",
        "prefix=%2Fjob-inputs%2F",
    };
    for (reads) |query| try testing.expect(refusal(node1, "GET", "/v1/list", query) != null);
    set_test_fault(.prefix_check, true);
    defer set_test_fault(.prefix_check, false);
    for (reads) |query| try testing.expect(refusal(node1, "GET", "/v1/list", query) == null);
}

comptime {
    assert(std.enums.values(Scope).len == 2);
}
