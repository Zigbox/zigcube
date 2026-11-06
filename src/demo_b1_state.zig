//! What the steps of `demo-b1` share: the state of the run, its named bounds, and the small reads
//! every step uses (a job as `GET /v1/jobs/<name>` says it, the containers the host runs). The
//! steps are in `demo_b1_endings.zig`, `demo_b1_nodes.zig` and `demo_b1_packing.zig`.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const fleet_mod = @import("demo_b1_fleet.zig");
pub const c1 = @import("demo_c1_state.zig");

pub const Host = demo_host.Host;
pub const Json = demo_host.Json;
pub const Fleet = fleet_mod.Fleet;
pub const contains = c1.contains;

pub const image = c1.hello_image;

/// The lease timeout the server is started with (`--lease-ttl-ms`), as in demo-c1.
pub const ttl_text = c1.ttl_text;
pub const ttl_ms = c1.ttl_ms;

// ---- Every wait of the demo is bounded by one of these ----

pub const start_wait_ms: u32 = c1.start_wait_ms;
/// A job to be placed, claimed and started, or to end by an exit, a cancel or its deadline.
pub const job_wait_ms: u32 = 25_000;
/// A node powered off and its job read `failed`: the lease runs out, the grace passes, and the
/// controllers and agents take a few of their one-second passes.
pub const failover_ms: u32 = c1.failover_ms;
/// How old the last acknowledged keepalive may be when a node's power goes off (the agent's
/// one-second pass).
pub const keepalive_slack_ms: u32 = 1_000;
/// A window in which nothing may change.
pub const settle_ms: u32 = c1.settle_ms;
/// The longest the watcher's printed lines may take to arrive.
pub const watch_wait_ms: u32 = 15_000;

pub const Demo = struct {
    host: *Host,
    fleet: *Fleet,
    backend: []const u8,
    /// The libpq settings of a Postgres run; empty for SQLite.
    postgres: []const u8,
    /// Watcher processes alive, killed by the cleanup if a step failed first.
    watcher: ?std.process.Child = null,
    /// The largest revision of the jobs the first watcher printed (set by step 1).
    bookmark: i64 = 0,
};

// ---- A job, as the server says it ----

/// The fields of `GET /v1/jobs/<name>` the steps look at; strings live in the host's arena.
pub const JobView = struct {
    state: []const u8,
    node: ?[]const u8,
    end_kind: ?[]const u8,
    code: ?i64,
    retries: i64,
    revision: i64,
};

fn string_of(value: ?Json) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn number_of(value: ?Json) ?i64 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |integer| integer,
        else => null,
    };
}

fn object_of(value: ?Json) ?std.json.ObjectMap {
    const found = value orelse return null;
    return switch (found) {
        .object => |object| object,
        else => null,
    };
}

/// The job `name` now; null while the request fails or the reply is not a job (a poll's answer).
pub fn job_view(host: *Host, name: []const u8) !?JobView {
    const path = try std.fmt.allocPrint(host.arena(), "/v1/jobs/{s}", .{name});
    const reply = host.call("GET", path, "") catch return null;
    if (reply.status != 200) return null;
    const parsed = std.json.parseFromSliceLeaky(Json, host.arena(), reply.body, .{}) catch {
        return null;
    };
    const top = object_of(parsed) orelse return null;
    const spec = object_of(top.get("job")) orelse return null;
    const status = object_of(top.get("status"));
    const end = if (status) |fields| object_of(fields.get("end")) else null;
    return .{
        .state = string_of(top.get("state")) orelse return null,
        .node = if (status) |fields| string_of(fields.get("node")) else null,
        .end_kind = if (end) |fields| string_of(fields.get("kind")) else null,
        .code = if (end) |fields| number_of(fields.get("code")) else null,
        .retries = number_of(spec.get("retries")) orelse return null,
        .revision = number_of(top.get("revision")) orelse return null,
    };
}

/// The job `name` now, or the demo fails.
pub fn need_job(host: *Host, name: []const u8) !JobView {
    return (try job_view(host, name)) orelse
        host.fail("GET /v1/jobs/{s} failed or was unreadable", .{name});
}

/// The index in the fleet of the node a job was placed on, or the demo fails.
pub fn node_index(host: *Host, view: JobView) !usize {
    const node = view.node orelse return host.fail("the job has no node yet", .{});
    for (fleet_mod.names, 0..) |name, index| {
        if (std.mem.eql(u8, name, node)) return index;
    }
    return host.fail("the job is on {s}, which the demo does not know", .{node});
}

pub const Want = struct { name: []const u8, state: []const u8 };

fn in_state(want: Want, host: *Host) !bool {
    const view = (try job_view(host, want.name)) orelse return false;
    return std.mem.eql(u8, view.state, want.state);
}

/// Waits (bounded) for job `name` to read `state`.
pub fn wait_state(
    host: *Host,
    name: []const u8,
    comptime state: []const u8,
    limit_ms: u32,
) !void {
    const want: Want = .{ .name = name, .state = state };
    try host.wait_for(want, in_state, "a job to read " ++ state, limit_ms);
}

/// The head revision of the job list, as `GET /v1/jobs?limit=1` says it.
pub fn head_revision(host: *Host) !i64 {
    const parsed = try host.json("/v1/jobs?limit=1");
    const top = object_of(parsed) orelse return host.fail("GET /v1/jobs was not an object", .{});
    return number_of(top.get("revision")) orelse host.fail("GET /v1/jobs has no revision", .{});
}

/// How many lines of `text` start with `prefix`.
pub fn lines_with(text: []const u8, prefix: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) count += 1;
    }
    return count;
}

/// The names of the containers that run now on any node, comma separated, for the transcript.
pub fn running_names(demo: *Demo) ![]const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (0..fleet_mod.count) |index| {
        for (try demo.fleet.procs(index).running_containers()) |pids| {
            const sep: []const u8 = if (names.items.len == 0) "" else ", ";
            try names.print(demo.host.arena(), "{s}{s}", .{ sep, pids.name() });
        }
    }
    return names.items;
}

/// True if a container called `name` runs on node `index` now.
pub fn runs_on(demo: *Demo, index: usize, name: []const u8) !bool {
    for (try demo.fleet.procs(index).running_containers()) |pids| {
        if (std.mem.eql(u8, pids.name(), name)) return true;
    }
    return false;
}

/// How many containers run on node `index`.
pub fn running_on(demo: *Demo, index: usize) !u32 {
    return @intCast((try demo.fleet.procs(index).running_containers()).len);
}

/// A job's command, `sh -c '<script>'`, as the words after `--command`.
pub fn sh(script: []const u8) [3][]const u8 {
    return .{ "sh", "-c", script };
}

/// `zcube job run NAME --image I <extra> --command sh -c SCRIPT`, shown. `extra` are flags of
/// `job run`; they go before `--command`, which takes the rest of the line.
pub fn run_job(
    host: *Host,
    name: []const u8,
    extra: []const []const u8,
    script: []const u8,
) !demo_host.Cli {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(host.arena(), &.{ "job", "run", name, "--image", image });
    try args.appendSlice(host.arena(), extra);
    try args.append(host.arena(), "--command");
    try args.appendSlice(host.arena(), &sh(script));
    return host.zcube(args.items);
}

fn has_ended(want: Want, host: *Host) !bool {
    const view = (try job_view(host, want.name)) orelse return false;
    return view.end_kind != null;
}

/// `zcube job get NAME --wait`, shown; the demo fails unless it exits with `code`. The wait is
/// bounded by `job_wait_ms` first (the command itself has no bound but the host's timeout), so
/// `--wait` finds an ended job and returns at once.
pub fn wait_job(
    host: *Host,
    name: []const u8,
    code: u8,
    comptime meaning: []const u8,
) !demo_host.Cli {
    const want: Want = .{ .name = name, .state = "" };
    try host.wait_for(want, has_ended, "a job to end", job_wait_ms);
    const cli = try host.zcube(&.{ "job", "get", name, "--wait" });
    try host.check(cli.code == code, "job get {s} --wait exits {d}: " ++ meaning, .{ name, code });
    return cli;
}
