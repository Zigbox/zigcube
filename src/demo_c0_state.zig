//! What the steps of `demo-c0` share: the state of the run, its named bounds, and the small reads
//! every step uses (what `zcube` printed, what the host runs). The steps themselves are in
//! `demo_c0.zig`, `demo_c0_decisions.zig` and `demo_c0_outage.zig`.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const host_procs = @import("host_procs.zig");

pub const Host = demo_host.Host;
pub const Json = demo_host.Json;
pub const Failed = demo_host.Failed;

pub const node = "node1";
/// HANDOFF's `hello` image, and a digest that is not in `fixtures/images.zon`.
pub const hello_image = "b3:51aa9c03";
pub const broken_image = "b3:00ff7be1";

// ---- Every wait of the demo is bounded by one of these ----

/// The server to answer, and the node to register.
pub const start_wait_ms: u32 = 20_000;
/// A service to reach what its file asks for, replicas started or stopped.
pub const converge_ms: u32 = 20_000;
/// A window in which nothing may change (three of the agent's one-second resyncs).
pub const settle_ms: u32 = 3_000;
/// The store back, and the system serving again.
pub const recover_ms: u32 = 30_000;
/// A command that starts or stops the store backend.
pub const store_command_ms: u32 = 60_000;

pub const PostgresControl = struct {
    conninfo: []const u8,
    /// Shell commands that stop and start the database server without losing its data.
    stop_command: []const u8,
    start_command: []const u8,
};

pub const Backend = union(enum) {
    sqlite,
    postgres: PostgresControl,

    pub fn name(backend: Backend) []const u8 {
        return @tagName(backend);
    }
};

pub const Demo = struct {
    host: *Host,
    backend: Backend,
    /// Decisions already checked (`demo_c0_decisions.zig`): the ones before this count.
    decisions_seen: u32 = 0,
    /// The demo stopped the database server and has not started it again: the end of the run
    /// does, even after a failure, so that it leaves the machine as it found it.
    store_stopped: bool = false,
};

// ---- Service files ----

/// Writes `<name>.zon` in the demo's directory, HANDOFF's example with other values.
pub fn write_service(demo: *Demo, name: []const u8, image: []const u8, replicas: u32) !void {
    const host = demo.host;
    const text = try std.fmt.allocPrint(host.arena(),
        \\.{{
        \\    .name = "{s}",
        \\    .image = "{s}",
        \\    .replicas = {d},
        \\    .command = .{{ "sh", "-c", "while true; do sleep 1; done" }},
        \\}}
        \\
    , .{ name, image, replicas });
    const file = try std.fmt.allocPrint(host.arena(), "{s}.zon", .{name});
    try std.Io.Dir.cwd().writeFile(host.io, .{
        .sub_path = try host.path_in_work(file),
        .data = text,
    });
    host.say("$ cat {s}\n{s}", .{ file, std.mem.trimEnd(u8, text, "\n") });
}

// ---- What zcube says about a service ----

pub const Counts = struct { desired: i64, running: i64, generation: i64 };

/// `zcube get service <name> -o json`, read; null while the command fails (a poll's answer).
pub fn service_counts(demo: *Demo, name: []const u8) !?Counts {
    const host = demo.host;
    const cli = try host.zcube_quiet(&.{ "get", "service", name, "-o", "json" });
    if (cli.code != 0) return null;
    const parsed = std.json.parseFromSliceLeaky(Json, host.arena(), cli.out, .{}) catch return null;
    const items = parsed.object.get("items").?.array.items;
    if (items.len != 1) return null;
    const item = items[0].object;
    return .{
        .desired = item.get("desired").?.integer,
        .running = item.get("running").?.integer,
        .generation = item.get("generation").?.integer,
    };
}

pub const Row = struct { id: []const u8, status: []const u8, node: []const u8 };

/// `zcube get replicas <service> -o json`, read; null while the command fails.
pub fn replica_rows(demo: *Demo, service: []const u8) !?[]const Row {
    const host = demo.host;
    const cli = try host.zcube_quiet(&.{ "get", "replicas", service, "-o", "json" });
    if (cli.code != 0) return null;
    const parsed = std.json.parseFromSliceLeaky(Json, host.arena(), cli.out, .{}) catch return null;
    var rows: std.ArrayList(Row) = .empty;
    for (parsed.object.get("items").?.array.items) |item| {
        try rows.append(host.arena(), .{
            .id = item.object.get("id").?.string,
            .status = item.object.get("status").?.string,
            .node = item.object.get("node").?.string,
        });
    }
    return rows.items;
}

pub fn count_status(rows: []const Row, status: []const u8) u32 {
    var count: u32 = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, row.status, status)) count += 1;
    }
    return count;
}

pub fn has_id(rows: []const Row, id: []const u8) bool {
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, id)) return true;
    }
    return false;
}

// ---- Reading what zcube printed ----

/// The READY column of a service's row in `zcube get service`, e.g. "3/3".
pub fn ready_of(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const first = words.next() orelse continue;
        if (!std.mem.eql(u8, first, name)) continue;
        return words.next();
    }
    return null;
}

/// How many rows of `zcube get replicas -o wide` name a replica of `service` on `node_name` with
/// this STATUS (the fourth column).
pub fn wide_rows(
    text: []const u8,
    service: []const u8,
    node_name: []const u8,
    status: []const u8,
) u32 {
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const id = words.next() orelse continue;
        const owner = words.next() orelse continue;
        const where = words.next() orelse continue;
        const state = words.next() orelse continue;
        if (!std.mem.startsWith(u8, id, service)) continue;
        if (!std.mem.eql(u8, owner, service)) continue;
        if (!std.mem.eql(u8, where, node_name)) continue;
        if (std.mem.eql(u8, state, status)) count += 1;
    }
    return count;
}

pub fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, text, needle) != null;
}

/// True if `needle` is one whole line of `text`.
pub fn has_line(text: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, needle)) return true;
    }
    return false;
}

/// The first line of `text`.
pub fn first_line(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

// ---- Assertions every step makes ----

/// Runs `zcube get service <name>` (shown) and asserts its READY column.
pub fn expect_ready(demo: *Demo, name: []const u8, comptime ready: []const u8) !void {
    const host = demo.host;
    const get = try host.zcube(&.{ "get", "service", name });
    const column = ready_of(get.out, name) orelse "";
    try host.check(
        get.code == 0 and std.mem.eql(u8, column, ready),
        "zcube get service {s} shows " ++ ready,
        .{name},
    );
}

/// Neither stream shows a stack trace, a source location or a raw Zig error name: DIAGNOSTICS.md
/// asks for this of every failure path, and the demo's refusals are real ones.
pub fn expect_no_trace(host: *Host, cli: demo_host.Cli) !void {
    const needles = [_][]const u8{ ".zig:", "error.", "panic", "stack trace", "0x" };
    for (needles) |needle| {
        const shown = contains(cli.err, needle) or contains(cli.out, needle);
        try host.check_quiet(!shown, "the output of a refusal shows '{s}'", .{needle});
    }
    try host.check(true, "no stack trace, source location or Zig error name in the output", .{});
}

/// A write that `zcube` reports with `line`, and exit 0.
pub fn expect_applied(host: *Host, cli: demo_host.Cli, comptime line: []const u8) !void {
    try host.check(cli.code == 0 and contains(cli.out, line), line, .{});
}

pub fn expect_equal(
    host: *Host,
    left: []const u8,
    right: []const u8,
    comptime what: []const u8,
) !void {
    try host.check(std.mem.eql(u8, left, right), what, .{});
}

// ---- What the host runs ----

pub fn same_containers(before: []const host_procs.Pids, now: []const host_procs.Pids) bool {
    if (before.len != now.len) return false;
    for (before, now) |left, right| {
        if (!std.mem.eql(u8, left.name(), right.name())) return false;
        if (left.supervisor != right.supervisor) return false;
        if (left.command != right.command) return false;
    }
    return true;
}

pub fn find_container(list: []const host_procs.Pids, name: []const u8) ?host_procs.Pids {
    for (list) |pids| {
        if (std.mem.eql(u8, pids.name(), name)) return pids;
    }
    return null;
}

/// Asserts the host runs exactly `expected` commands, each under a supervisor of its own.
pub fn expect_processes(demo: *Demo, comptime what: []const u8, expected: u32) !void {
    const host = demo.host;
    const procs = host.procs();
    const alive = try procs.running_containers();
    const supervisors = try procs.supervisors();
    try host.check(
        alive.len == expected and supervisors == expected,
        "the host runs {d} commands under {d} supervisors (" ++ what ++ ")",
        .{ alive.len, supervisors },
    );
}

test "ready_of and the row counters read zcube's tables" {
    const service = "NAME   READY  IMAGE\nhello  3/3    b3:51aa9c03\n";
    try std.testing.expectEqualStrings("3/3", ready_of(service, "hello").?);
    try std.testing.expect(ready_of(service, "other") == null);
    const wide = "REPLICA  SERVICE  NODE   STATUS   AGE\nhello-1  hello  node1  running  3s\n" ++
        "hello-2  hello  node1  killed  3s\n";
    try std.testing.expectEqual(@as(u32, 1), wide_rows(wide, "hello", "node1", "running"));
    try std.testing.expect(has_line(service, "hello  3/3    b3:51aa9c03"));
    try std.testing.expectEqualStrings("NAME   READY  IMAGE", first_line(service));
}
