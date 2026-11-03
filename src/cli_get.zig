//! `zcube get service|replicas [name]`: what is declared and how it is doing, from three listings
//! of the store (`/services/`, `/replicas/`, `/observed/`) joined here. The server has no
//! summary endpoint on purpose: the keys are the contract (docs/keys.md), and the join is a few
//! lines. `-o wide` adds columns, `--output json` prints the joined rows as JSON.

const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli_args.zig");
const cli_data = @import("cli_data.zig");
const cli_env = @import("cli_env.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const cli_view = @import("cli_view.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Error = cli_report.Error;
const Report = cli_report.Report;
const Value = cli_data.Value;

pub const ServiceRow = struct {
    name: []const u8,
    image: []const u8,
    desired: u32,
    running: u32,
    generation: u64,
    applied_by: []const u8,
    command: []const u8,
};

pub const ReplicaRow = struct {
    id: []const u8,
    service: []const u8,
    node: []const u8,
    generation: u64,
    image: []const u8,
    status: []const u8,
    /// What the agent said went wrong, as `ZBX-E0501: image not found`, or the exit; empty for a
    /// clean state.
    detail: []const u8,
    started_at_ms: ?u64,
    /// What the scheduler resolved the replica to need (`/assigned/<node>/<id>`), null while
    /// unassigned.
    requests: ?Resources = null,
};

pub const Resources = struct { cpu_millis: u64, memory_bytes: u64 };

pub const LeaseRow = struct { id: u64, ttl_ms: u64, remaining_ms: u64 };

/// One node: the join of `/nodes/`, `/node-status/`, `/allocations/` and the lease listing.
pub const NodeRow = struct {
    name: []const u8,
    /// `state` of `/node-status/<node>`; null before the node controller has judged it.
    status: ?[]const u8,
    /// The tenure that status was judged for.
    status_tenure: ?u64,
    /// The `/nodes/<node>` revision; null with no registration.
    tenure: ?u64,
    lease: ?LeaseRow,
    capacity: ?Resources,
    allocated: Resources,
    count: u64,
    /// `ttl_ms - remaining_ms` of the node's lease: a keepalive creates no revision, so the lease
    /// is the only record of the last contact.
    last_heard_ms_ago: ?u64,
    address: []const u8,
    agent_version: []const u8,
};

pub fn run(
    arena: Allocator,
    client: *Client,
    options: cli_args.Options,
    listing: cli_args.Listing,
    name: ?[]const u8,
    report: *Report,
) Error![]const u8 {
    if (listing == .nodes) {
        const rows = try nodes(arena, client, name, report);
        return cli_view.nodes_text(arena, rows, options.output);
    }
    if (listing == .service) {
        const rows = try services(arena, client, name, report);
        return cli_view.services_text(arena, rows, options.output);
    }
    const found = try replicas(arena, client, name, report);
    assert(listing == .replicas);
    return cli_view.replicas_text(arena, found.rows, found.now_ms, options.output);
}

/// The services with their running counts, in name order. A name that does not exist is
/// ZC-E0101.
pub fn services(
    arena: Allocator,
    client: *Client,
    name: ?[]const u8,
    report: *Report,
) Error![]const ServiceRow {
    const prefix = try prefix_for(arena, "/services/", name, "");
    const listed = try cli_data.list(arena, client, prefix, report);
    const replicas_listed = try cli_data.list(arena, client, replica_prefix(name), report);
    const observed = try cli_data.list(arena, client, "/observed/", report);
    var rows: std.ArrayList(ServiceRow) = .empty;
    for (listed.items) |kv| {
        if (!is_exact(kv.key, "/services/", name)) continue;
        const row = try service_row(arena, kv, replicas_listed.items, observed.items, report);
        rows.append(arena, row) catch return error.OutOfMemory;
    }
    if (name != null and rows.items.len == 0) return missing(report, "service", name.?);
    return rows.items;
}

fn replica_prefix(name: ?[]const u8) []const u8 {
    _ = name;
    return "/replicas/";
}

/// With a name the listing is by prefix, so `hello` also lists `hello2`: only the exact key
/// counts.
fn is_exact(key: []const u8, base: []const u8, name: ?[]const u8) bool {
    assert(std.mem.startsWith(u8, key, base));
    const wanted = name orelse return true;
    return std.mem.eql(u8, key[base.len..], wanted);
}

fn prefix_for(
    arena: Allocator,
    base: []const u8,
    name: ?[]const u8,
    tail: []const u8,
) Error![]const u8 {
    const given = name orelse return base;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, given, tail }) catch error.OutOfMemory;
}

fn service_row(
    arena: Allocator,
    kv: cli_data.Kv,
    replica_kvs: []const cli_data.Kv,
    observed: []const cli_data.Kv,
    report: *Report,
) Error!ServiceRow {
    const name = cli_data.text(kv.value, "name") orelse return bad_record(report, kv.key);
    var running: u32 = 0;
    const own_prefix = std.fmt.allocPrint(
        arena,
        "/replicas/{s}/",
        .{name},
    ) catch return error.OutOfMemory;
    for (replica_kvs) |replica| {
        if (!std.mem.startsWith(u8, replica.key, own_prefix)) continue;
        const id = replica.key[own_prefix.len..];
        if (observed_status(observed, id)) |status| {
            if (std.mem.eql(u8, status, "running")) running += 1;
        }
    }
    return .{
        .name = name,
        .image = cli_data.text(kv.value, "image") orelse "",
        .desired = @intCast(cli_data.number(
            kv.value,
            "replicas",
        ) orelse return bad_record(report, kv.key)),
        .running = running,
        .generation = cli_data.number(kv.value, "generation") orelse 0,
        .applied_by = cli_data.text(kv.value, "applied_by") orelse "",
        .command = try command_text(arena, kv.value),
    };
}

fn command_text(arena: Allocator, service: Value) Error![]const u8 {
    const words = cli_data.array(service, "command") orelse return "";
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, index| {
        if (word != .string) continue;
        if (index > 0) out.append(arena, ' ') catch return error.OutOfMemory;
        out.appendSlice(arena, word.string) catch return error.OutOfMemory;
    }
    return out.items;
}

/// The status text of the observed record of replica `id` on any node, if there is one.
fn observed_status(observed: []const cli_data.Kv, id: []const u8) ?[]const u8 {
    for (observed) |kv| {
        if (!std.mem.endsWith(u8, kv.key, id)) continue;
        const slash = kv.key.len - id.len - 1;
        if (kv.key[slash] != '/') continue;
        return cli_data.text(kv.value, "status");
    }
    return null;
}

pub const Replicas = struct { rows: []const ReplicaRow, now_ms: u64 };

/// The replicas (of one service, if named), with what the agents observed, and the server's
/// clock for ages.
pub fn replicas(
    arena: Allocator,
    client: *Client,
    name: ?[]const u8,
    report: *Report,
) Error!Replicas {
    if (name) |service| _ = try services(arena, client, service, report);
    const prefix = try prefix_for(arena, "/replicas/", name, "/");
    const listed = try cli_data.list(arena, client, prefix, report);
    const observed = try cli_data.list(arena, client, "/observed/", report);
    const assigned = try cli_data.list(arena, client, "/assigned/", report);
    const status = try client.get("/v1/status", report);
    const status_body = try cli_data.parse(arena, status, report);
    const now = cli_data.number(status_body, "time_ms") orelse
        return cli_data.contract(report, status.request_id, "has no time_ms");
    var rows: std.ArrayList(ReplicaRow) = .empty;
    for (listed.items) |kv| {
        const row = try replica_row(arena, kv, observed.items, assigned.items, report);
        rows.append(arena, row) catch return error.OutOfMemory;
    }
    return .{ .rows = rows.items, .now_ms = now };
}

fn replica_row(
    arena: Allocator,
    kv: cli_data.Kv,
    observed: []const cli_data.Kv,
    assigned: []const cli_data.Kv,
    report: *Report,
) Error!ReplicaRow {
    const id = cli_data.text(kv.value, "id") orelse return bad_record(report, kv.key);
    var row: ReplicaRow = .{
        .id = id,
        .service = cli_data.text(kv.value, "service") orelse "",
        .node = node_of(assigned, id),
        .generation = cli_data.number(kv.value, "generation") orelse 0,
        .image = cli_data.text(kv.value, "image") orelse "",
        .status = "pending",
        .detail = "",
        .started_at_ms = null,
        .requests = requests_of(assigned, id),
    };
    for (observed) |seen| {
        if (!is_observed_of(seen.key, id)) continue;
        row.status = cli_data.text(seen.value, "status") orelse "pending";
        row.started_at_ms = cli_data.number(seen.value, "started_at_ms");
        row.detail = detail_of(arena, seen.value, report) catch return error.OutOfMemory;
        if (std.mem.eql(u8, row.status, "stopped")) row.status = stopped_text(seen.value);
        break;
    }
    return row;
}

/// The node `/assigned/<node>/<id>` names, or empty while the replica is unassigned.
fn node_of(assigned: []const cli_data.Kv, id: []const u8) []const u8 {
    const prefix = "/assigned/";
    for (assigned) |kv| {
        if (!std.mem.endsWith(u8, kv.key, id)) continue;
        const slash = kv.key.len - id.len - 1;
        if (kv.key[slash] != '/') continue;
        return kv.key[prefix.len..slash];
    }
    return "";
}

fn is_observed_of(key: []const u8, id: []const u8) bool {
    if (!std.mem.endsWith(u8, key, id)) return false;
    const slash = key.len - id.len - 1;
    return key[slash] == '/';
}

/// `stopped` with how it ended: `exited(1)`, `killed(9)`, `oom`, `start-failed`, `lost`.
fn stopped_text(observed: Value) []const u8 {
    const exit = cli_data.member(observed, "exit") orelse return "stopped";
    const kind = cli_data.text(exit, "kind") orelse return "stopped";
    if (std.mem.eql(u8, kind, "exited")) return "exited";
    if (std.mem.eql(u8, kind, "signaled")) return "killed";
    if (std.mem.eql(u8, kind, "pid_limit")) return "pid-limit";
    if (std.mem.eql(u8, kind, "start_failed")) return "start-failed";
    if (std.mem.eql(u8, kind, "oom")) return "oom";
    if (std.mem.eql(u8, kind, "lost")) return "lost";
    return "stopped";
}

fn detail_of(arena: Allocator, observed: Value, report: *Report) Allocator.Error![]const u8 {
    _ = report;
    if (cli_data.member(observed, "diagnostic")) |diagnostic| {
        const code = cli_data.text(diagnostic, "code") orelse return "";
        const summary = cli_data.text(diagnostic, "summary") orelse "";
        return std.fmt.allocPrint(arena, "{s}: {s}", .{ code, summary });
    }
    const exit = cli_data.member(observed, "exit") orelse return "";
    const kind = cli_data.text(exit, "kind") orelse return "";
    if (std.mem.eql(u8, kind, "exited")) {
        return std.fmt.allocPrint(
            arena,
            "exit code {d}",
            .{cli_data.number(exit, "code") orelse 0},
        );
    }
    if (std.mem.eql(u8, kind, "signaled")) {
        return std.fmt.allocPrint(arena, "signal {d}", .{cli_data.number(exit, "signal") orelse 0});
    }
    return "";
}

fn missing(report: *Report, kind: []const u8, name: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0101);
    report.diag.while_("looking for {s} {s}", .{ kind, name });
    report.diag.cause("{s} {s} does not exist", .{ kind, name });
    report.diag.fix(.{ .sentence = "list what exists:", .command = "zcube get service" });
    return error.Failed;
}

fn bad_record(report: *Report, key: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("reading {s}", .{key});
    report.diag.cause("the record is not a service or replica this zcube knows", .{});
    report.diag.fix(.{ .sentence = "use the zcube that came with the server" });
    return error.Failed;
}

fn requests_of(assigned: []const cli_data.Kv, id: []const u8) ?Resources {
    for (assigned) |kv| {
        if (!is_observed_of(kv.key, id)) continue;
        return resources(kv.value, "requests");
    }
    return null;
}

fn resources(parent: Value, name: []const u8) ?Resources {
    const inner = cli_data.member(parent, name) orelse return null;
    return .{
        .cpu_millis = cli_data.number(inner, "cpu_millis") orelse return null,
        .memory_bytes = cli_data.number(inner, "memory_bytes") orelse return null,
    };
}

/// The nodes (one, if named) in name order: the names under `/nodes/` and `/node-status/`
/// together, so a node whose registration is gone but whose judgement remains still shows.
/// A name that is in neither is ZC-E0101.
pub fn nodes(
    arena: Allocator,
    client: *Client,
    name: ?[]const u8,
    report: *Report,
) Error![]const NodeRow {
    const registered = try cli_data.list(arena, client, "/nodes/", report);
    const judged = try cli_data.list(arena, client, "/node-status/", report);
    const accounts = try cli_data.list(arena, client, "/allocations/", report);
    const leases_reply = try client.get("/v1/leases", report);
    const leases = try cli_data.parse(arena, leases_reply, report);
    var names: std.ArrayList([]const u8) = .empty;
    try add_names(arena, &names, registered.items, "/nodes/");
    try add_names(arena, &names, judged.items, "/node-status/");
    std.mem.sort([]const u8, names.items, {}, name_less);
    var rows: std.ArrayList(NodeRow) = .empty;
    for (names.items) |node| {
        if (name != null and !std.mem.eql(u8, name.?, node)) continue;
        const row = node_row(node, registered.items, judged.items, accounts.items, leases);
        rows.append(arena, row) catch return error.OutOfMemory;
    }
    if (name != null and rows.items.len == 0) return missing(report, "node", name.?);
    return rows.items;
}

fn name_less(_: void, first: []const u8, second: []const u8) bool {
    return std.mem.lessThan(u8, first, second);
}

fn add_names(
    arena: Allocator,
    names: *std.ArrayList([]const u8),
    items: []const cli_data.Kv,
    base: []const u8,
) Error!void {
    for (items) |kv| {
        assert(std.mem.startsWith(u8, kv.key, base));
        const node = kv.key[base.len..];
        for (names.items) |known| {
            if (std.mem.eql(u8, known, node)) break;
        } else names.append(arena, node) catch return error.OutOfMemory;
    }
}

fn find(items: []const cli_data.Kv, base: []const u8, node: []const u8) ?cli_data.Kv {
    for (items) |kv| {
        if (std.mem.eql(u8, kv.key[base.len..], node)) return kv;
    }
    return null;
}

fn node_row(
    node: []const u8,
    registered: []const cli_data.Kv,
    judged: []const cli_data.Kv,
    accounts: []const cli_data.Kv,
    leases: Value,
) NodeRow {
    var row: NodeRow = .{
        .name = node,
        .status = null,
        .status_tenure = null,
        .tenure = null,
        .lease = null,
        .capacity = null,
        .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 },
        .count = 0,
        .last_heard_ms_ago = null,
        .address = "",
        .agent_version = "",
    };
    if (find(registered, "/nodes/", node)) |kv| {
        row.tenure = kv.mod_revision;
        row.capacity = resources(kv.value, "capacity");
        row.address = cli_data.text(kv.value, "address") orelse "";
        row.agent_version = cli_data.text(kv.value, "agent_version") orelse "";
        row.lease = lease_of(leases, kv.key);
        if (row.lease) |lease| row.last_heard_ms_ago = lease.ttl_ms -| lease.remaining_ms;
    }
    if (find(judged, "/node-status/", node)) |kv| {
        row.status = cli_data.text(kv.value, "state");
        row.status_tenure = cli_data.number(kv.value, "tenure");
    }
    if (find(accounts, "/allocations/", node)) |kv| {
        row.allocated = resources(kv.value, "allocated") orelse row.allocated;
        row.count = cli_data.number(kv.value, "count") orelse 0;
    }
    return row;
}

/// The lease whose `keys` include `key`, from `GET /v1/leases`.
fn lease_of(leases: Value, key: []const u8) ?LeaseRow {
    const all = cli_data.array(leases, "leases") orelse return null;
    for (all) |lease| {
        const keys = cli_data.array(lease, "keys") orelse continue;
        for (keys) |held| {
            if (held != .string or !std.mem.eql(u8, held.string, key)) continue;
            return .{
                .id = cli_data.number(lease, "id") orelse return null,
                .ttl_ms = cli_data.number(lease, "ttl_ms") orelse return null,
                .remaining_ms = cli_data.number(lease, "remaining_ms") orelse return null,
            };
        }
    }
    return null;
}
