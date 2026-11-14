//! What the steps of `demo-b6` share: the state of the run, its bounds (demo-b1's), a job as
//! `GET /v1/jobs/<name>` says it (demo-b1's reads, which take only the host), and the reads that
//! know this demo's three nodes. The steps are in `demo_b6_steps.zig`.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const fleet_mod = @import("demo_b6_fleet.zig");
const b1 = @import("demo_b1_state.zig");

pub const Host = demo_host.Host;
pub const Json = demo_host.Json;
pub const Fleet = fleet_mod.Fleet;
pub const contains = b1.contains;
pub const c1 = b1.c1;

pub const image = b1.image;
pub const ttl_text = b1.ttl_text;
pub const ttl_ms = b1.ttl_ms;

pub const start_wait_ms = b1.start_wait_ms;
pub const job_wait_ms = b1.job_wait_ms;
pub const failover_ms = b1.failover_ms;
pub const keepalive_slack_ms = b1.keepalive_slack_ms;
pub const settle_ms = b1.settle_ms;

pub const JobView = b1.JobView;
pub const job_view = b1.job_view;
pub const need_job = b1.need_job;
pub const wait_state = b1.wait_state;
pub const wait_job = b1.wait_job;

pub const Demo = struct {
    host: *Host,
    fleet: *Fleet,
    backend: []const u8,
    /// The libpq settings of a Postgres run; empty for SQLite.
    postgres: []const u8,
};

/// The index in the fleet of the node a job was placed on, or the demo fails.
pub fn node_index(host: *Host, view: JobView) !usize {
    const node = view.node orelse return host.fail("the job has no node yet", .{});
    for (fleet_mod.names, 0..) |name, index| {
        if (std.mem.eql(u8, name, node)) return index;
    }
    return host.fail("the job is on {s}, which the demo does not know", .{node});
}

/// True if a container called `name` runs on node `index` now.
pub fn runs_on(demo: *Demo, index: usize, name: []const u8) !bool {
    for (try demo.fleet.procs(index).running_containers()) |pids| {
        if (std.mem.eql(u8, pids.name(), name)) return true;
    }
    return false;
}

fn epoch_ms(host: *Host) u64 {
    return @intCast(std.Io.Clock.real.now(host.io).toMilliseconds());
}

/// `POST /v1/jobs`: a job of `cpu_millis` that sleeps, which requires `tenant` when one is given
/// (`placement.require`; the CLI has no flag for it, nor for limits).
pub fn post(host: *Host, name: []const u8, cpu_millis: u32, tenant: ?[]const u8) !void {
    const arena = host.arena();
    const placement = if (tenant) |value|
        try std.fmt.allocPrint(arena, ",\"placement\":{{\"require\":{{\"tenant\":\"{s}\"}}}}", .{
            value,
        })
    else
        "";
    const body = try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"image\":\"{s}\"," ++
        "\"deadline_ms\":120000,\"submit_by_ms\":{d},\"command\":[\"sh\",\"-c\",\"sleep 300\"]," ++
        "\"limits\":{{\"cpu_millis\":{d},\"memory_bytes\":134217728}}{s}}}", .{
        name, image, epoch_ms(host) + 60_000, cpu_millis, placement,
    });
    if (tenant) |value| {
        host.say("$ curl -X POST /v1/jobs   # {s}: {d}m CPU, placement.require tenant={s}", .{
            name, cpu_millis, value,
        });
    } else {
        host.say("$ curl -X POST /v1/jobs   # {s}: {d}m CPU, no placement", .{ name, cpu_millis });
    }
    const reply = try host.call("POST", "/v1/jobs", body);
    try host.check(reply.status == 201, "POST /v1/jobs {s} answered {d}", .{ name, reply.status });
}

/// Waits for job `name` to run, then for its container to show on its node; returns the node.
pub fn wait_running(demo: *Demo, name: []const u8) !usize {
    const host = demo.host;
    try wait_state(host, name, "running", job_wait_ms);
    const index = try node_index(host, try need_job(host, name));
    const container = try std.fmt.allocPrint(host.arena(), "{s}-job", .{name});
    const want: OnNode = .{ .demo = demo, .index = index, .name = container };
    try host.wait_for(want, container_on, "the job's container to show on its node", job_wait_ms);
    return index;
}

const OnNode = struct { demo: *Demo, index: usize, name: []const u8 };

fn container_on(want: OnNode, _: *Host) !bool {
    return runs_on(want.demo, want.index, want.name);
}

/// The labels each node registered with, as the store holds them (`GET /v1/list` of `/nodes/`;
/// `zcube get nodes` does not show labels). One line per node, `<name> <labels>`.
pub fn node_labels(host: *Host) ![]const []const u8 {
    const parsed = try host.json("/v1/list?prefix=%2Fnodes%2F");
    const kvs = if (parsed == .object) parsed.object.get("kvs") else null;
    const list = kvs orelse return host.fail("GET /v1/list has no kvs", .{});
    if (list != .array) return host.fail("GET /v1/list: kvs is not an array", .{});
    var lines: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        const line = (try label_line(host, item)) orelse continue;
        try lines.append(host.arena(), line);
    }
    return lines.items;
}

/// `<name> <labels>` of one `/nodes/<name>` record; null for any other key under the prefix.
fn label_line(host: *Host, item: Json) !?[]const u8 {
    if (item != .object) return null;
    const key = item.object.get("key") orelse return null;
    const value = item.object.get("value") orelse return null;
    if (key != .string or value != .object) return null;
    if (!std.mem.startsWith(u8, key.string, "/nodes/")) return null;
    const name = key.string["/nodes/".len..];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const labels = value.object.get("labels") orelse return null;
    if (labels != .array) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(host.arena(), name);
    for (labels.array.items) |label| {
        if (label != .string) return null;
        try text.print(host.arena(), " {s}", .{label.string});
    }
    return text.items;
}

/// How many containers run on node `index`.
pub fn running_on(demo: *Demo, index: usize) !u32 {
    return @intCast((try demo.fleet.procs(index).running_containers()).len);
}
