//! What the steps of `demo-c1` share: the state of the run, its named bounds, and the small reads
//! every step uses (what `zcube get nodes` and `get replicas` say, what the host runs). The steps
//! are in `demo_c1_steps.zig`, `demo_c1_partition.zig` and `demo_c1_local.zig`.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const demo_host = @import("demo_host.zig");
const fleet_mod = @import("demo_c1_fleet.zig");
const host_procs = @import("host_procs.zig");
pub const c0 = @import("demo_c0_state.zig");

pub const Host = demo_host.Host;
pub const Json = demo_host.Json;
pub const Fleet = fleet_mod.Fleet;
pub const Row = c0.Row;
pub const contains = c0.contains;
pub const wide_rows = c0.wide_rows;

pub const hello_image = c0.hello_image;

/// The lease timeout the server is started with (`--lease-ttl-ms`): shorter than the default 10 s,
/// which shows that it is configurable and shortens the run. The inequality of authority.md §3
/// holds for it: `fence_margin` 3000 >= `fence_stop` 2000 + ttl * 1% + kill latency 900.
pub const ttl_ms: u32 = 8_000;
pub const ttl_text = "8000";
/// Where the agent's last container is dead, at the latest, relative to the server's expiry of
/// its lease. The agent fences at `s + ttl - fence_margin`, `s` the send time of the last
/// keepalive the server acknowledged, and the server's expiry is that receipt plus `ttl`, so the
/// expiry is at or after `s + ttl`; the agent then takes `fence_stop` and the kill latency.
/// Negative: the agent is done before the lease runs out, which keeps the replacements from
/// overlapping it.
pub const stop_after_expiry_ms: i64 = @as(i64, constants.fence_stop_ms) +
    constants.fence_kill_latency_ms - constants.fence_margin_ms;

// ---- Every wait of the demo is bounded by one of these ----

/// The server to answer, and the agents to register.
pub const start_wait_ms: u32 = 20_000;
/// A service to reach what its file asks for.
pub const converge_ms: u32 = 20_000;
/// A node lost and its replicas replaced: the lease runs out (`ttl`), `lost_grace_ms` passes, and
/// the controllers and the agents take a few of their one-second passes.
pub const failover_ms: u32 = ttl_ms + constants.lost_grace_ms + 5_000;
/// A window in which nothing may change (three of the agent's one-second resyncs).
pub const settle_ms: u32 = 3_000;
/// What the partition test lets the whole partition take, from the cut to the replacements.
pub const partition_ms: u32 = failover_ms + 5_000;
/// The clock reads and the polls of the host checks differ by this much.
pub const tolerance_ms: u64 = 250;

pub const Demo = struct {
    host: *Host,
    fleet: *Fleet,
    backend: []const u8,
    /// The libpq settings of a Postgres run; empty for SQLite.
    postgres: []const u8,
    /// The tenure of each node as step 1 saw it, and as its last registration did.
    tenures: [fleet_mod.count]i64 = @splat(0),
};

// ---- Service files ----

/// Writes `<name>.zon` in the demo's directory, HANDOFF's example with other values.
pub fn write_service(host: *Host, name: []const u8, replicas: u32) !void {
    const text = try std.fmt.allocPrint(host.arena(),
        \\.{{
        \\    .name = "{s}",
        \\    .image = "{s}",
        \\    .replicas = {d},
        \\    .command = .{{ "sh", "-c", "while true; do sleep 1; done" }},
        \\}}
        \\
    , .{ name, hello_image, replicas });
    const file = try std.fmt.allocPrint(host.arena(), "{s}.zon", .{name});
    try std.Io.Dir.cwd().writeFile(host.io, .{
        .sub_path = try host.path_in_work(file),
        .data = text,
    });
    host.say("$ cat {s}\n{s}", .{ file, std.mem.trimEnd(u8, text, "\n") });
}

// ---- What zcube says ----

fn number(value: ?Json) ?i64 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |integer| integer,
        else => null,
    };
}

fn string_of(value: ?Json) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |string| string,
        else => null,
    };
}

/// The `items` array of a list reply; null if the reply is not shaped so.
fn items_of(parsed: Json) ?[]const Json {
    if (parsed != .object) return null;
    const found = parsed.object.get("items") orelse return null;
    if (found != .array) return null;
    return found.array.items;
}

/// One row of `zcube get nodes -o json`; a field is null when the command says null.
pub const NodeRow = struct {
    name: []const u8,
    status: ?[]const u8,
    status_tenure: ?i64,
    tenure: ?i64,
    ttl_ms: ?i64,
    remaining_ms: ?i64,
    cpu_millis: ?i64,
    memory_bytes: ?i64,
    count: i64,

    /// Judged `ready` for the registration it has now.
    pub fn is_ready(row: NodeRow) bool {
        const status_now = row.status orelse return false;
        if (!std.mem.eql(u8, status_now, "ready")) return false;
        const tenure = row.tenure orelse return false;
        return row.status_tenure == tenure and row.remaining_ms != null;
    }

    pub fn is_lost(row: NodeRow) bool {
        const status_now = row.status orelse return false;
        return std.mem.eql(u8, status_now, "lost");
    }
};

/// `zcube get nodes -o json`, read; null while the command fails (a poll's answer).
pub fn node_rows(host: *Host) !?[]const NodeRow {
    const cli = try host.zcube_quiet(&.{ "get", "nodes", "-o", "json" });
    if (cli.code != 0) return null;
    const parsed = std.json.parseFromSliceLeaky(Json, host.arena(), cli.out, .{}) catch return null;
    const items = items_of(parsed) orelse return null;
    var rows: std.ArrayList(NodeRow) = .empty;
    for (items) |item| {
        if (item != .object) return null;
        const fields = item.object;
        const lease = if (fields.get("lease")) |value| switch (value) {
            .object => |object| object,
            else => null,
        } else null;
        const capacity = if (fields.get("capacity")) |value| switch (value) {
            .object => |object| object,
            else => null,
        } else null;
        try rows.append(host.arena(), .{
            .name = string_of(fields.get("name")) orelse return null,
            .status = string_of(fields.get("status")),
            .status_tenure = number(fields.get("status_tenure")),
            .tenure = number(fields.get("tenure")),
            .ttl_ms = if (lease) |object| number(object.get("ttl_ms")) else null,
            .remaining_ms = if (lease) |object| number(object.get("remaining_ms")) else null,
            .cpu_millis = if (capacity) |object| number(object.get("cpu_millis")) else null,
            .memory_bytes = if (capacity) |object| number(object.get("memory_bytes")) else null,
            .count = number(fields.get("count")) orelse 0,
        });
    }
    return rows.items;
}

/// `node_rows`, or the demo fails: for the places where the command must work, so that a
/// transient failure ends the run through `run`'s cleanup instead of a panic that skips it.
pub fn need_nodes(host: *Host) ![]const NodeRow {
    return (try node_rows(host)) orelse host.fail("zcube get nodes failed or was unreadable", .{});
}

/// The row of `name` in a fresh `zcube get nodes`, or the demo fails.
pub fn need_node(host: *Host, name: []const u8) !NodeRow {
    const rows = try need_nodes(host);
    return find_node(rows, name) orelse host.fail("zcube get nodes does not list {s}", .{name});
}

/// The tenure of a registered node, or the demo fails.
pub fn need_tenure(host: *Host, row: NodeRow) !i64 {
    return row.tenure orelse host.fail("{s} has no tenure", .{row.name});
}

/// `replica_rows`, or the demo fails.
pub fn need_replicas(host: *Host, service: []const u8) ![]const Row {
    return (try replica_rows(host, service)) orelse
        host.fail("zcube get replicas {s} failed or was unreadable", .{service});
}

pub fn find_node(rows: []const NodeRow, name: []const u8) ?NodeRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// `zcube get replicas <service> -o json`, read; null while the command fails.
pub fn replica_rows(host: *Host, service: []const u8) !?[]const Row {
    const cli = try host.zcube_quiet(&.{ "get", "replicas", service, "-o", "json" });
    if (cli.code != 0) return null;
    const parsed = std.json.parseFromSliceLeaky(Json, host.arena(), cli.out, .{}) catch return null;
    const items = items_of(parsed) orelse return null;
    var rows: std.ArrayList(Row) = .empty;
    for (items) |item| {
        if (item != .object) return null;
        try rows.append(host.arena(), .{
            .id = string_of(item.object.get("id")) orelse return null,
            .status = string_of(item.object.get("status")) orelse return null,
            .node = string_of(item.object.get("node")) orelse "",
        });
    }
    return rows.items;
}

/// How many rows are on `node_name` with `status`.
pub fn on_node(rows: []const Row, node_name: []const u8, status: []const u8) u32 {
    var count: u32 = 0;
    for (rows) |row| {
        const same = std.mem.eql(u8, row.node, node_name);
        if (same and std.mem.eql(u8, row.status, status)) count += 1;
    }
    return count;
}

/// True if `hello` has exactly `want` replicas and all of them run.
pub fn all_running(rows: []const Row, want: u32) bool {
    return rows.len == want and c0.count_status(rows, "running") == want;
}

// ---- What the host runs ----

/// The containers of every node that run now, with the node each belongs to.
pub const Placed = struct { node: usize, pids: host_procs.Pids };

pub fn running_everywhere(fleet: *Fleet, arena: std.mem.Allocator) ![]const Placed {
    var found: std.ArrayList(Placed) = .empty;
    for (0..fleet_mod.count) |index| {
        for (try fleet.procs(index).running_containers()) |pids| {
            try found.append(arena, .{ .node = index, .pids = pids });
        }
    }
    return found.items;
}

pub fn has_container(list: []const Placed, name: []const u8) bool {
    for (list) |placed| {
        if (std.mem.eql(u8, placed.pids.name(), name)) return true;
    }
    return false;
}

/// How many containers run on `index`.
pub fn running_on(list: []const Placed, index: usize) u32 {
    var count: u32 = 0;
    for (list) |placed| {
        if (placed.node == index) count += 1;
    }
    return count;
}

/// Asserts that each node's agent runs `expected[node]` commands, each the child of a supervisor
/// that leads a session and a group of its own, which is a child of that node's agent.
pub fn expect_placement(demo: *Demo, comptime what: []const u8, expected: [3]u32) !void {
    const host = demo.host;
    for (0..fleet_mod.count) |index| {
        const procs = demo.fleet.procs(index);
        const alive = try procs.running_containers();
        const supervisors = try procs.supervisors();
        const name = fleet_mod.names[index];
        try host.check(
            alive.len == expected[index] and supervisors == expected[index],
            what ++ ": {s} runs {d} commands under {d} supervisors",
            .{ name, alive.len, supervisors },
        );
        const agent_pid = demo.fleet.agent_pid(index) orelse continue;
        for (alive) |pids| {
            const supervisor = procs.proc(pids.supervisor) orelse {
                return host.fail("{s}: supervisor {d} is gone", .{ pids.name(), pids.supervisor });
            };
            const own = pids.supervisor;
            const led = supervisor.session == own and supervisor.group == own;
            try host.check_quiet(led, "{s}: no session of its own", .{pids.name()});
            try host.check_quiet(supervisor.parent == agent_pid, "{s}: not {s}'s", .{
                pids.name(), name,
            });
        }
    }
}
