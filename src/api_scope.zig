//! Who may call what (B7, docs/mtls.md, "Scopes"). The shell names the caller from the client
//! certificate the TLS handshake verified, never from a header; `Api.handle` asks `refusal`
//! before it routes, and a request the caller may not make is refused with 403 ZC-E0822 before
//! anything is read or written.
//!
//! - A node's certificate (an agent) may call the agent API under its own node's name only:
//!   `/v1/agent/nodes/<its name>` and below. The agent handlers keep every key they write under
//!   the node of the path, so an agent writes only under its own node's keys.
//! - A client of scope `jobs` may create, read, cancel and watch jobs: `/v1/jobs` and below, and
//!   `GET /v1/why/job/<name>`. Nothing else.
//! - A client of scope `admin`, and the loopback `--insecure-listen` listener, may call
//!   everything.

const std = @import("std");
const assert = std.debug.assert;
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
    /// A client of scope `jobs` (or `admin`).
    jobs,
    /// A client of scope `admin`.
    admin,

    pub fn format(need: Need, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (need) {
            .node => |name| try writer.print(
                "node {s}'s certificate or a client of scope admin",
                .{name},
            ),
            .jobs => try writer.writeAll("a client of scope jobs or admin"),
            .admin => try writer.writeAll("a client of scope admin"),
        }
    }
};

/// Null when `caller` may make the request; else what it would need. `path` is without the
/// query.
pub fn refusal(caller: Caller, method: []const u8, path: []const u8) ?Need {
    const need = need_of(method, path);
    switch (caller) {
        .local => return null,
        .client => |client| switch (client.scope) {
            .admin => return null,
            .jobs => if (need == .jobs) return null,
        },
        .node => |own| switch (need) {
            .node => |name| if (std.mem.eql(u8, name, own)) return null,
            .jobs, .admin => {},
        },
    }
    return need;
}

/// The least a request needs, from its method and path alone.
fn need_of(method: []const u8, path: []const u8) Need {
    const agent = "/v1/agent/nodes/";
    if (std.mem.startsWith(u8, path, agent)) {
        const rest = path[agent.len..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        // An empty node name is no node's: only an admin may be told there is nothing there.
        if (end == 0) return .admin;
        return .{ .node = rest[0..end] };
    }
    if (std.mem.eql(u8, path, "/v1/jobs")) return .jobs;
    if (std.mem.startsWith(u8, path, "/v1/jobs/")) return .jobs;
    const why_job = "/v1/why/job/";
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, why_job)) {
        if (path.len > why_job.len) return .jobs;
    }
    return .admin;
}

const testing = std.testing;

test "need_of: the agent API by node, the jobs API, and everything else is admin's" {
    const Row = struct { method: []const u8, path: []const u8, need: Need };
    const rows = [_]Row{
        .{ .method = "PUT", .path = "/v1/agent/nodes/node1", .need = .{ .node = "node1" } },
        .{ .method = "GET", .path = "/v1/agent/nodes/node1/watch", .need = .{ .node = "node1" } },
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
        const need = need_of(row.method, row.path);
        try testing.expectEqual(std.meta.activeTag(row.need), std.meta.activeTag(need));
        if (row.need == .node) try testing.expectEqualStrings(row.need.node, need.node);
    }
}

test "refusal: a node only under its own name, jobs only jobs, admin and local everything" {
    const node1: Caller = .{ .node = "node1" };
    const jobs: Caller = .{ .client = .{ .name = "app", .scope = .jobs } };
    const admin: Caller = .{ .client = .{ .name = "ops", .scope = .admin } };
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node1") == null);
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node2") != null);
    // A prefix of another name is not the name.
    try testing.expect(refusal(node1, "PUT", "/v1/agent/nodes/node12/lease") != null);
    try testing.expect(refusal(node1, "GET", "/v1/jobs") != null);
    try testing.expect(refusal(node1, "GET", "/v1/status") != null);
    try testing.expect(refusal(jobs, "POST", "/v1/jobs") == null);
    try testing.expect(refusal(jobs, "POST", "/v1/services") != null);
    try testing.expect(refusal(jobs, "PUT", "/v1/agent/nodes/node1") != null);
    for ([_]Caller{ admin, .local }) |caller| {
        try testing.expect(refusal(caller, "PUT", "/v1/agent/nodes/node2") == null);
        try testing.expect(refusal(caller, "POST", "/v1/services") == null);
        try testing.expect(refusal(caller, "GET", "/v1/jobs") == null);
    }
}

comptime {
    assert(std.enums.values(Scope).len == 2);
}
