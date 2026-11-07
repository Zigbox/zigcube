//! Step 5 of `demo-b1` (docs/demos/b1.md): five jobs requesting 500m of CPU each on two nodes of
//! 1000m: four run, two per node; the fifth stays `pending` and `zcube why job` says why; it runs
//! when one of the four ends. The CLI has no flag for limits, so these are `POST /v1/jobs`.

const std = @import("std");
const state = @import("demo_b1_state.zig");

const Demo = state.Demo;
const Host = state.Host;

const names = [_][]const u8{ "pk1", "pk2", "pk3", "pk4", "pk5" };

fn epoch_ms(host: *Host) u64 {
    return @intCast(std.Io.Clock.real.now(host.io).toMilliseconds());
}

fn post(host: *Host, name: []const u8) !void {
    const body = try std.fmt.allocPrint(host.arena(), "{{\"name\":\"{s}\",\"image\":\"{s}\"," ++
        "\"deadline_ms\":120000,\"submit_by_ms\":{d},\"command\":[\"sh\",\"-c\",\"sleep 300\"]," ++
        "\"limits\":{{\"cpu_millis\":500,\"memory_bytes\":134217728}}}}", .{
        name, state.image, epoch_ms(host) + 60_000,
    });
    host.say("$ curl -X POST /v1/jobs   # {s}: limits cpu_millis 500", .{name});
    const reply = try host.call("POST", "/v1/jobs", body);
    try host.check(reply.status == 201, "POST /v1/jobs {s} answered {d}", .{ name, reply.status });
}

const Running = struct { count: u32 };

fn four_run(want: Running, host: *Host) !bool {
    var running: u32 = 0;
    for (names) |name| {
        const view = (try state.job_view(host, name)) orelse return false;
        if (std.mem.eql(u8, view.state, "running")) running += 1;
    }
    return running == want.count;
}

pub fn run(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. five jobs of 500m on two nodes of 1000m: four run, the fifth waits");
    for (names) |name| try post(host, name);
    try host.wait_for(Running{ .count = 4 }, four_run, "four jobs to run", state.job_wait_ms);
    try host.settle("the fifth must stay pending", state.settle_ms);
    try host.check(try four_run(.{ .count = 4 }, host), "exactly four jobs run", .{});
    for (0..2) |index| {
        try host.check(try state.running_on(demo, @intCast(index)) == 2, "node {d} runs two " ++
            "jobs", .{index + 1});
    }
    var waiting: []const u8 = "";
    for (names) |name| {
        const view = try state.need_job(host, name);
        if (std.mem.eql(u8, view.state, "pending")) waiting = name;
    }
    try host.check(waiting.len > 0, "one job is pending", .{});
    const why = try host.zcube(&.{ "why", "job", waiting });
    const names_shortfall = state.contains(why.out, "no node fits 500m CPU and 128 MiB: " ++
        "2 of 2 nodes lack the room");
    try host.check(why.code == 0 and names_shortfall, "zcube why job {s} names the CPU " ++
        "shortfall", .{waiting});
    var other: []const u8 = "";
    for (names) |name| {
        if (!std.mem.eql(u8, name, waiting)) other = name;
    }
    _ = try host.zcube(&.{ "job", "cancel", other });
    try state.wait_state(host, waiting, "running", state.job_wait_ms);
    try host.check(true, "{s} runs when {s} is cancelled", .{ waiting, other });
    for (names) |name| _ = try host.zcube_quiet(&.{ "job", "cancel", name });
}
