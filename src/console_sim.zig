//! What the browser console runs when it is opened with `?sim=c0`: the real core (API handlers,
//! controller, the agent's step, `why`) over a memory store and the simulated runtime, on virtual
//! time, behind the same bytes-in, bytes-out shape as the HTTP server. **It is a simulation.** The
//! console labels it so, and it is never presented as a recorded demo (docs/console.md).
//!
//! This file is the logic; `console_wasm.zig` is only the doorway of exports and the one host
//! import for panics. Keeping the logic here lets `zig build test` run exactly what the browser
//! runs. It is a core module: no thread, no file, no clock but the world's own, no wait.
//!
//! **Time.** The world's clock moves only when the host calls `advance`: the console feeds it
//! real elapsed time (times its speed setting), and freezing time is not calling it. A long-poll
//! watch is answered with what is ready; `Response.hold_ms` tells the host how long it may wait
//! for the revision to change before asking again, which is the shell's job here as on a server.
//!
//! **The scenario** is HANDOFF's C0 demo as seven steps (`scenario_steps`), run one at a time by
//! the dev panel. A step does what a person or a fault would do (apply, `kill -9`, take the store
//! down) through the world; everything that follows is the controllers' own doing.

const std = @import("std");
const assert = std.debug.assert;
const api_mod = @import("api.zig");
const apply_mod = @import("apply.zig");
const constants = @import("constants.zig");
const sim_runtime = @import("sim_runtime.zig");
const sim_world = @import("sim_world.zig");
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const World = sim_world.World;

/// The seed of the simulated runtime. Fixed: the console shows the same story every time.
const seed: u64 = 1;

/// The decision source of API writes is distinct from the world's (instance 0), so two writers in
/// one millisecond never share a decision id. The console itself never writes.
const api_instance: u16 = 9;

/// The request frame a host writes into the request buffer: `METHOD NUL path NUL query NUL
/// request-id NUL body`. An empty request id means none. Nothing in a frame may be NUL.
pub const frame_bytes_max: u32 = constants.api_request_bytes_max + 4096;

pub const hello_digest = "b3:51aa9c03";
/// HANDOFF's `b3:00ff…e1`: not in the simulated node's store.
pub const broken_digest = "b3:00ff" ++ test_util.repeat('0', 55).* ++ "e1";

comptime {
    assert(broken_digest.len == 64);
    assert(broken_digest.len <= constants.image_digest_bytes_max);
}

pub const Op = enum(u32) {
    /// A new, empty world (the page's "Reset"); the scenario starts again.
    reset = 0,
    /// Runs the next scenario step. Returns its index, or -1 when none is left.
    step = 1,
    /// `arg` 1 takes the store down, 0 brings it back.
    store_down = 2,
    /// Compacts the store's history to its current revision (a console that was away then asks
    /// for a revision that is gone and gets the core's own 410).
    compact = 3,
    restart_server = 4,
    restart_agent = 5,
    /// The index of the next scenario step.
    next_index = 6,
    steps_total = 7,
    /// 1 if the store is down, else 0.
    is_store_down = 8,
};

pub const scenario_steps: u32 = 7;

pub const Frame = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    request_id: ?[]const u8,
    body: []const u8,
};

/// Splits a request frame; null if it has fewer than the four NULs a frame needs.
pub fn parse_frame(bytes: []const u8) ?Frame {
    var rest = bytes;
    var fields: [4][]const u8 = undefined;
    for (&fields) |*field| {
        const at = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        field.* = rest[0..at];
        rest = rest[at + 1 ..];
    }
    return .{
        .method = fields[0],
        .path = fields[1],
        .query = fields[2],
        .request_id = if (fields[3].len == 0) null else fields[3],
        .body = rest,
    };
}

pub const Console = struct {
    gpa: Allocator,
    world: *World,
    api: api_mod.Api,
    /// The next scenario step to run.
    next_step: u32,
    /// The last answer; its bytes live in the world's arena until the next call that uses it.
    response: api_mod.Response,

    pub fn create(gpa: Allocator) Allocator.Error!*Console {
        const console = try gpa.create(Console);
        errdefer gpa.destroy(console);
        console.gpa = gpa;
        console.world = try start_world(gpa);
        console.api = new_api();
        console.next_step = 0;
        console.response = .{ .status = 0, .request_id = "", .body = "" };
        return console;
    }

    pub fn destroy(console: *Console) void {
        console.world.destroy();
        console.gpa.destroy(console);
    }

    /// An empty world with its agent registered; nothing is applied.
    fn start_world(gpa: Allocator) Allocator.Error!*World {
        const world = try World.create(gpa, seed, &sim_runtime.default_fixtures);
        world.advance(1000);
        return world;
    }

    fn new_api() api_mod.Api {
        return .{
            .version = "0.0.0-sim",
            .backend = "memory",
            .started_at_ms = sim_world.epoch_ms,
            .source = .{ .instance = api_instance },
        };
    }

    /// Answers one request frame. A frame that is not one is a 400-shaped refusal made here, so
    /// the host never sees a bare failure.
    pub fn request(console: *Console, bytes: []const u8) api_mod.Response {
        assert(bytes.len <= frame_bytes_max);
        const world = console.world;
        const ctx = world.controller_context();
        const frame = parse_frame(bytes) orelse {
            ctx.diag.raise(.E0104);
            ctx.diag.cause("the request frame is not method, path, query, id and body", .{});
            ctx.diag.fix(.{ .sentence = "this is a bug in the console's host code" });
            console.response = api_mod.refusal(&ctx, "r-frame00", 400);
            return console.response;
        };
        console.response = console.api.handle(&ctx, .{
            .method = frame.method,
            .path = frame.path,
            .query = frame.query,
            .request_id = frame.request_id,
            .body = frame.body,
        });
        return console.response;
    }

    /// Moves virtual time forward; the controller and the agent run as they come due.
    pub fn advance(console: *Console, ms: u32) void {
        assert(ms <= 60 * 1000); // A host that was away calls this in pieces.
        console.world.advance(ms);
    }

    /// The store's revision, or null while it is down: what a held watch waits to see change.
    pub fn revision(console: *Console) ?u64 {
        return console.world.revision();
    }

    pub fn now_ms(console: *const Console) u64 {
        return console.world.now_ms();
    }

    /// One scenario or fault control. Returns -1 for "nothing to do".
    pub fn control(console: *Console, op: Op, arg: u32) Allocator.Error!i32 {
        switch (op) {
            .reset => {
                console.world.destroy();
                console.world = try start_world(console.gpa);
                console.api = new_api();
                console.next_step = 0;
                return 0;
            },
            .step => return console.step(),
            .store_down => console.world.set_store_down(arg != 0),
            .compact => compact(console.world),
            .restart_server => console.world.restart_server(),
            .restart_agent => console.world.restart_agent(),
            .next_index => return @intCast(console.next_step),
            .steps_total => return scenario_steps,
            .is_store_down => return @intFromBool(console.world.switched.down),
        }
        return 0;
    }

    /// Runs the next scenario step and lets virtual time pass: only the step's own effect is
    /// instant, so the console shows the controllers working (the host keeps time moving).
    fn step(console: *Console) i32 {
        if (console.next_step >= scenario_steps) return -1;
        const index = console.next_step;
        console.next_step += 1;
        const world = console.world;
        switch (index) {
            0 => apply(world, "hello", hello_digest, 3),
            1 => kill_one(world),
            2 => apply(world, "hello", hello_digest, 5),
            3 => apply(world, "hello", hello_digest, 2),
            4 => apply(world, "broken", broken_digest, 1),
            5 => world.set_store_down(true),
            6 => world.set_store_down(false),
            else => unreachable, // `next_step < scenario_steps` was checked above.
        }
        return @intCast(index);
    }
};

fn apply(world: *World, name: []const u8, image: []const u8, replicas: u32) void {
    var buffer: [16]u8 = undefined;
    _ = world.apply(.{
        .name = name,
        .image = image,
        .replicas = replicas,
        .command = &.{ "sh", "-c", "while true; do sleep 1; done" },
        .applied_by = "alex@laptop",
        .request_id = world.request_id(&buffer),
    }) catch |err| {
        // The scenario's own applies are valid by construction. Anything else is the store being
        // down while a person pressed Step, which the API shows them as it would the CLI.
        assert(err != error.Invalid);
        assert(err != error.NotFound);
    };
}

/// `kill -9` of the lowest-numbered running replica of `hello`. If none is running (the host
/// ran the step early) it does nothing, as a person would find nothing to kill.
fn kill_one(world: *World) void {
    var buffer: [constants.node_name_bytes_max]u8 = undefined;
    const victim = world.first_running("hello", &buffer) orelse return;
    world.kill(victim) catch {};
}

fn compact(world: *World) void {
    const head = world.revision() orelse return;
    if (head < 2) return;
    world.diag.reset();
    world.store_handle().compact(head, &world.diag) catch world.diag.reset();
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn get(console: *Console, path: []const u8, query: []const u8) !std.json.Parsed(std.json.Value) {
    var frame: [1024]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&frame, "GET\x00{s}\x00{s}\x00\x00", .{ path, query });
    const response = console.request(bytes);
    try testing.expectEqual(@as(u16, 200), response.status);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, response.body, .{});
}

fn settle(console: *Console, seconds: u32) void {
    for (0..seconds) |_| console.advance(1000);
}

test "the request frame splits into method, path, query, id and body" {
    // Goal: the one wire format between the host and the core. Method: a full frame, an empty id,
    // a body that contains the separator's neighbours, and frames that are too short.
    const frame = parse_frame("POST\x00/v1/apply\x00dry_run=1\x00r-abcdefgh\x00{\"a\":1}").?;
    try testing.expectEqualStrings("POST", frame.method);
    try testing.expectEqualStrings("/v1/apply", frame.path);
    try testing.expectEqualStrings("dry_run=1", frame.query);
    try testing.expectEqualStrings("r-abcdefgh", frame.request_id.?);
    try testing.expectEqualStrings("{\"a\":1}", frame.body);
    const plain = parse_frame("GET\x00/v1/status\x00\x00\x00").?;
    try testing.expect(plain.request_id == null);
    try testing.expectEqualStrings("", plain.body);
    try testing.expect(parse_frame("GET\x00/v1/status\x00") == null);
    try testing.expect(parse_frame("") == null);
}

test "a fresh console answers status, and a garbled frame gets a diagnostic, not a crash" {
    // Goal: the first thing the page does works, and the host's bug is reported as one. Method:
    // GET /v1/status; then a frame with no separators.
    const console = try Console.create(testing.allocator);
    defer console.destroy();
    var status = try get(console, "/v1/status", "");
    defer status.deinit();
    const store = status.value.object.get("store").?;
    try testing.expect(store.object.get("ok").?.bool);
    try testing.expectEqualStrings("memory", store.object.get("backend").?.string);
    const bad = console.request("nonsense");
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "ZC-E0104") != null);
}

test "the scenario runs to the end and explains why broken is not running" {
    // Goal: what the console shows is the core's own story. Method: run all seven steps with time
    // between them, as the page does, and read the API after the ones that matter.
    const console = try Console.create(testing.allocator);
    defer console.destroy();
    try testing.expectEqual(@as(i32, 7), try console.control(.steps_total, 0));
    try testing.expectEqual(@as(i32, 0), try console.control(.step, 0));
    settle(console, 3);
    try testing.expectEqual(@as(u32, 3), console.world.running_count("hello"));
    try testing.expectEqual(@as(i32, 1), try console.control(.step, 0));
    settle(console, 3);
    try testing.expectEqual(@as(u32, 3), console.world.running_count("hello"));
    try testing.expectEqual(@as(i32, 2), try console.control(.step, 0));
    settle(console, 3);
    try testing.expectEqual(@as(u32, 5), console.world.running_count("hello"));
    try testing.expectEqual(@as(i32, 3), try console.control(.step, 0));
    settle(console, 10);
    try testing.expectEqual(@as(u32, 2), console.world.running_count("hello"));
    try testing.expectEqual(@as(i32, 4), try console.control(.step, 0));
    settle(console, 3);

    var why = try get(console, "/v1/why/service/broken", "");
    defer why.deinit();
    const state = why.value.object.get("state").?;
    const state_text = state.object.get("text").?.string;
    try testing.expectEqualStrings("service broken: 0/1 running", state_text);
    const steps = why.value.object.get("steps").?.array.items;
    const last = steps[steps.len - 1];
    try testing.expectEqualStrings("observed", last.object.get("type").?.string);
    const diagnostic = last.object.get("diagnostic").?;
    try testing.expectEqualStrings("ZBX-E0501", diagnostic.object.get("code").?.string);

    try testing.expectEqual(@as(i32, 5), try console.control(.step, 0));
    try testing.expectEqual(@as(i32, 1), try console.control(.is_store_down, 0));
    var frame: [64]u8 = undefined;
    const down = console.request(try std.fmt.bufPrint(&frame, "GET\x00/v1/list\x00\x00\x00", .{}));
    try testing.expectEqual(@as(u16, 503), down.status);
    try testing.expectEqual(@as(i32, 6), try console.control(.step, 0));
    try testing.expectEqual(@as(i32, -1), try console.control(.step, 0));
    settle(console, 3);
    var up = try get(console, "/v1/list", "prefix=%2Fservices%2F");
    defer up.deinit();
    try testing.expectEqual(@as(usize, 2), up.value.object.get("kvs").?.array.items.len);
}

test "reset gives an empty world, and a compaction makes an old watch a 410" {
    // Goal: the dev panel's Reset and "Sleep + compact". Method: apply, compact, ask to watch
    // from a revision that is gone; reset and see no services.
    const console = try Console.create(testing.allocator);
    defer console.destroy();
    _ = try console.control(.step, 0);
    settle(console, 3);
    _ = try console.control(.compact, 0);
    var frame: [128]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&frame, "GET\x00/v1/watch\x00from=2&timeout=0\x00\x00", .{});
    const gone = console.request(bytes);
    try testing.expectEqual(@as(u16, 410), gone.status);
    try testing.expect(std.mem.indexOf(u8, gone.body, "ZC-E0203") != null);
    _ = try console.control(.reset, 0);
    try testing.expectEqual(@as(i32, 0), try console.control(.next_index, 0));
    var empty = try get(console, "/v1/list", "prefix=%2Fservices%2F");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.value.object.get("kvs").?.array.items.len);
}

test "restarting the server core changes nothing, and the agent core duplicates nothing" {
    // Goal: the dev panel's restart buttons are safe to press. Method: converge, restart the
    // server and compare the revision; restart the agent (it registers again, which is a write)
    // and compare the running count.
    const console = try Console.create(testing.allocator);
    defer console.destroy();
    _ = try console.control(.step, 0);
    settle(console, 3);
    const before = console.revision().?;
    _ = try console.control(.restart_server, 0);
    settle(console, 5);
    try testing.expectEqual(before, console.revision().?);
    _ = try console.control(.restart_agent, 0);
    settle(console, 5);
    try testing.expectEqual(@as(u32, 3), console.world.running_count("hello"));
    try testing.expectEqual(@as(usize, 3), console.world.sim.containers.items.len);
}
