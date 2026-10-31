//! The network between the agents and the server in the cluster simulation. Core code: it carries
//! the bytes of the agent endpoints (`client.Request` in, `client.Reply` out, the same bytes
//! `agent_api.zig` takes and gives) and loses, delays, duplicates and reorders them from a seed.
//! The agent sees it as a `client.Transport`, exactly where the shell puts HTTP.
//!
//! A call is synchronous: the agent asks and is answered or told the server did not answer
//! (ZC-E0503). What the network adds is everything a real one adds around that:
//!
//! * **Drop**, per direction. A dropped request never reaches the server. **A dropped reply
//!   reaches it**: the server acted, and the agent sees a failure for a write that happened. That
//!   is the case that corrupts orchestrators, so it has a rate of its own and `partition_down`
//!   (a one-way partition that lets requests through and swallows every reply).
//! * **Delay**, per direction, up to a maximum. A call whose total delay passes its timeout is
//!   a failure for the agent whose server acted: the same shape as a dropped reply, later.
//! * **Duplicate** (requests): the server gets the request twice, back to back, and the agent
//!   sees the first answer. A write that is not idempotent shows here.
//! * **Reorder** (requests): the request is parked with a delivery time drawn from the seed
//!   (between `reorder_delay_ms_min` and `reorder_delay_ms_max` after it was sent), and the agent
//!   sees a timeout. It reaches the server when the simulation's clock passes that time, which
//!   the cluster reports with `tick`, independent of any call on the link: after newer requests
//!   from the same agent, and possibly after the server's own clock has moved on (a lease that
//!   expired meanwhile). The default bounds straddle the agent's timeout, so a stale write can
//!   land after the agent's retry.
//! * **Partition**, one-way and per link: `partition_up` stops requests, `partition_down` stops
//!   replies. `heal` turns every fault off. It does not touch what is parked: a request that was
//!   already in flight when the link was healed (or cut) still arrives, as a packet on the wire
//!   does. A liveness bound after a heal must therefore allow `reorder_delay_ms_max` for the
//!   stragglers.
//!
//! Duplicate and reorder act on requests only: a duplicated or late reply is read once by a
//! synchronous caller and can change nothing, so the model leaves it out.
//!
//! The network owns no clock. `last_call_ms` is how long the call took on the simulation's clock,
//! for the cluster to add; a call that fails takes the whole timeout, as a real agent waits it out.
//! The cluster calls `tick` with the time after every advance, and that is when parked requests
//! are due.

const std = @import("std");
const assert = std.debug.assert;
const client = @import("agent_client.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const nodes_max: u32 = 16;
pub const parked_max: u32 = 4;

/// The server's side: one request in, one reply out, in `scratch`, which the network owns and
/// resets. `node` is the link the request arrived on.
pub const Handler = struct {
    context: *anyopaque,
    handle_fn: *const fn (
        context: *anyopaque,
        scratch: Allocator,
        node: u32,
        request: client.Request,
    ) client.Reply,
};

pub const Direction = struct {
    drop_per_mille: u32 = 0,
    delay_ms_max: u32 = 0,
};

pub const Faults = struct {
    request: Direction = .{},
    reply: Direction = .{},
    duplicate_per_mille: u32 = 0,
    reorder_per_mille: u32 = 0,
    reorder_delay_ms_min: u32 = constants.agent_io_timeout_ms,
    reorder_delay_ms_max: u32 = 4 * constants.agent_io_timeout_ms,
    partition_up: bool = false,
    partition_down: bool = false,

    pub fn quiet(faults: Faults) bool {
        return std.meta.eql(faults, .{});
    }
};

pub const Stats = struct {
    delivered: u32 = 0,
    requests_dropped: u32 = 0,
    /// The server acted and the agent was told it failed: a reply dropped, or too late.
    replies_lost: u32 = 0,
    duplicated: u32 = 0,
    parked: u32 = 0,
    delivered_late: u32 = 0,
    partitioned: u32 = 0,
};

const Parked = struct {
    method: []u8,
    target: []u8,
    body: []u8,
    hold_ms: u32,
    /// The simulation time at which it reaches the server.
    due_ms: u64,
};

const Link = struct {
    faults: Faults = .{},
    parked: [parked_max]?Parked = @splat(null),
    stats: Stats = .{},
};

pub const SimNet = struct {
    gpa: Allocator,
    handler: Handler,
    prng: std.Random.DefaultPrng,
    scratch: std.heap.ArenaAllocator,
    links: [nodes_max]Link,
    ports: [nodes_max]Port,
    /// How long the last call took, on the simulation's clock.
    last_call_ms: u32,
    /// The simulation time as the cluster last reported it with `tick`.
    now_ms: u64,

    const Port = struct { net: *SimNet, node: u32 };

    /// In place: the ports point back at the network.
    pub fn init(net: *SimNet, gpa: Allocator, handler: Handler, seed: u64) void {
        net.* = .{
            .gpa = gpa,
            .handler = handler,
            .prng = .init(seed),
            .scratch = .init(gpa),
            .links = @splat(.{}),
            .ports = undefined,
            .last_call_ms = 0,
            .now_ms = 0,
        };
        for (&net.ports, 0..) |*port, node| port.* = .{ .net = net, .node = @intCast(node) };
    }

    pub fn deinit(net: *SimNet) void {
        for (&net.links) |*link| net.drop_parked(link);
        net.scratch.deinit();
        net.* = undefined;
    }

    /// What the agent of `node` uses in place of HTTP.
    pub fn transport(net: *SimNet, node: u32) client.Transport {
        assert(node < nodes_max);
        return .{ .context = &net.ports[node], .call_fn = call_impl };
    }

    pub fn set_faults(net: *SimNet, node: u32, faults: Faults) void {
        assert(node < nodes_max);
        net.links[node].faults = faults;
    }

    pub fn stats(net: *const SimNet, node: u32) Stats {
        return net.links[node].stats;
    }

    /// Every fault off on every link. Requests already parked stay in flight (see the module doc).
    pub fn heal(net: *SimNet) void {
        for (&net.links) |*link| link.faults = .{};
    }

    /// The simulation is now at `now_ms`: every parked request that is due reaches the server,
    /// earliest first (a tie goes to the lower node, then the older slot), whatever the state of
    /// its link. Replies to them are dropped, because the agent gave up on them long ago.
    pub fn tick(net: *SimNet, now_ms: u64) void {
        assert(now_ms >= net.now_ms);
        net.now_ms = now_ms;
        for (0..nodes_max * parked_max) |_| {
            const next = net.earliest_due() orelse return;
            const link = &net.links[next.node];
            const parked = link.parked[next.slot].?; // `earliest_due` found it there.
            link.parked[next.slot] = null;
            defer net.free_parked(parked);
            link.stats.delivered_late += 1;
            _ = net.hand_over(next.node, .{
                .method = parked.method,
                .target = parked.target,
                .body = parked.body,
                .hold_ms = parked.hold_ms,
            });
        }
        assert(net.earliest_due() == null); // Every slot was visited at most once above.
    }

    const Due = struct { node: u32, slot: u32 };

    fn earliest_due(net: *const SimNet) ?Due {
        var best: ?Due = null;
        var best_ms: u64 = 0;
        for (&net.links, 0..) |*link, node| {
            for (link.parked, 0..) |slot, index| {
                const parked = slot orelse continue;
                if (parked.due_ms > net.now_ms) continue;
                if (best != null) {
                    if (parked.due_ms >= best_ms) continue;
                }
                best = .{ .node = @intCast(node), .slot = @intCast(index) };
                best_ms = parked.due_ms;
            }
        }
        return best;
    }

    fn free_parked(net: *SimNet, parked: Parked) void {
        net.gpa.free(parked.method);
        net.gpa.free(parked.target);
        net.gpa.free(parked.body);
    }

    fn drop_parked(net: *SimNet, link: *Link) void {
        for (&link.parked) |*slot| {
            const parked = slot.* orelse continue;
            net.free_parked(parked);
            slot.* = null;
        }
    }

    // ---- A call ----

    fn roll(net: *SimNet, per_mille: u32) bool {
        if (per_mille == 0) return false;
        return net.prng.random().uintLessThan(u32, 1000) < per_mille;
    }

    fn delay(net: *SimNet, max_ms: u32) u32 {
        if (max_ms == 0) return 0;
        return net.prng.random().uintAtMost(u32, max_ms);
    }

    fn call_impl(
        context: *anyopaque,
        arena: Allocator,
        request: client.Request,
        diag: *Diag,
    ) client.Error!client.Reply {
        const port: *Port = @ptrCast(@alignCast(context));
        const net = port.net;
        const link = &net.links[port.node];
        const faults = link.faults;
        const timeout_ms = request.hold_ms + constants.agent_io_timeout_ms;
        net.last_call_ms = 0;
        if (faults.partition_up) {
            link.stats.partitioned += 1;
            return net.no_answer(diag, port.node, timeout_ms, "the link is cut: requests are lost");
        }
        if (net.roll(faults.request.drop_per_mille)) {
            link.stats.requests_dropped += 1;
            return net.no_answer(diag, port.node, timeout_ms, "the request was lost");
        }
        if (net.roll(faults.reorder_per_mille)) {
            if (net.park(link, request, faults)) {
                return net.no_answer(diag, port.node, timeout_ms, "the request was delayed");
            }
        }
        var elapsed_ms = net.delay(faults.request.delay_ms_max);
        const first = net.hand_over(port.node, request);
        // The duplicate reuses `scratch`, so the first reply is copied out before it arrives.
        var kept: ?[]u8 = null;
        if (net.roll(faults.duplicate_per_mille)) {
            link.stats.duplicated += 1;
            kept = net.gpa.dupe(u8, first.body) catch return error.OutOfMemory;
            _ = net.hand_over(port.node, request);
        }
        defer if (kept) |bytes| net.gpa.free(bytes);
        const reply_body = kept orelse first.body;
        // The server has acted. Nothing below can undo it.
        elapsed_ms += net.delay(faults.reply.delay_ms_max);
        const lost = faults.partition_down or net.roll(faults.reply.drop_per_mille);
        if (lost or elapsed_ms >= timeout_ms) {
            link.stats.replies_lost += 1;
            const why = if (lost) "the reply was lost" else "the reply came too late";
            return net.no_answer(diag, port.node, timeout_ms, why);
        }
        net.last_call_ms = elapsed_ms;
        const body = arena.dupe(u8, reply_body) catch return error.OutOfMemory;
        return .{ .status = first.status, .body = body };
    }

    /// The request reaches the server; its reply is in `scratch` until the next hand-over.
    fn hand_over(net: *SimNet, node: u32, request: client.Request) client.Reply {
        _ = net.scratch.reset(.retain_capacity);
        net.links[node].stats.delivered += 1;
        return net.handler.handle_fn(net.handler.context, net.scratch.allocator(), node, request);
    }

    fn no_answer(
        net: *SimNet,
        diag: *Diag,
        node: u32,
        timeout_ms: u32,
        reason: []const u8,
    ) client.Error {
        assert(diag.code == null);
        net.last_call_ms = timeout_ms;
        diag.raise(.E0503);
        diag.cause("no answer from zcube-server at sim-net/{d}: {s}", .{ node, reason });
        diag.fix(.{ .sentence = "start the server, or give the agent the address it listens on" });
        return error.Unreachable;
    }

    // ---- Parked requests ----

    /// Keeps a copy to deliver at a time drawn from the link's bounds. False if all the slots
    /// are full or memory is.
    fn park(net: *SimNet, link: *Link, request: client.Request, faults: Faults) bool {
        assert(faults.reorder_delay_ms_min <= faults.reorder_delay_ms_max);
        for (&link.parked) |*slot| {
            if (slot.* != null) continue;
            const method = net.gpa.dupe(u8, request.method) catch return false;
            const target = net.gpa.dupe(u8, request.target) catch return false;
            const body = net.gpa.dupe(u8, request.body) catch return false;
            const random = net.prng.random();
            const wait_ms = random.intRangeAtMost(
                u32,
                faults.reorder_delay_ms_min,
                faults.reorder_delay_ms_max,
            );
            slot.* = .{
                .method = method,
                .target = target,
                .body = body,
                .hold_ms = request.hold_ms,
                .due_ms = net.now_ms + wait_ms,
            };
            link.stats.parked += 1;
            return true;
        }
        return false;
    }
};

const testing = std.testing;

/// A server that counts what reached it, by method, and answers with the count.
const Counter = struct {
    gets: u32 = 0,
    writes: u32 = 0,
    last_body: [64]u8 = undefined,
    last_body_len: u32 = 0,
    /// What reached the server, in order: 'G' for a read, 'W' for a write.
    order: [16]u8 = @splat('-'),
    order_len: u32 = 0,

    fn handler(counter: *Counter) Handler {
        return .{ .context = counter, .handle_fn = handle };
    }

    fn handle(
        context: *anyopaque,
        scratch: Allocator,
        node: u32,
        request: client.Request,
    ) client.Reply {
        _ = node;
        const counter: *Counter = @ptrCast(@alignCast(context));
        const is_read = std.mem.eql(u8, request.method, "GET");
        if (is_read) counter.gets += 1 else counter.writes += 1;
        if (counter.order_len < counter.order.len) {
            counter.order[counter.order_len] = if (is_read) 'G' else 'W';
            counter.order_len += 1;
        }
        counter.last_body_len = @intCast(request.body.len);
        @memcpy(counter.last_body[0..request.body.len], request.body);
        const total = counter.gets + counter.writes;
        const body = std.fmt.allocPrint(scratch, "{{\"n\":{d}}}", .{total}) catch
            unreachable; // The scratch arena is unbounded here.
        return .{ .status = 200, .body = body };
    }
};

const write: client.Request = .{
    .method = "POST",
    .target = "/v1/agent/nodes/n1/observed",
    .body = "{}",
};
const read: client.Request = .{ .method = "GET", .target = "/v1/agent/nodes/n1/replicas" };

fn make(counter: *Counter, net: *SimNet) client.Transport {
    net.init(testing.allocator, counter.handler(), 11);
    return net.transport(0);
}

test "with no fault a request is answered once and takes no time" {
    // Goal: the baseline. Method: one write and one read through the transport.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const reply = try link.call(testing.allocator, write, &diag);
    defer testing.allocator.free(reply.body);
    try testing.expectEqualStrings("{\"n\":1}", reply.body);
    try testing.expectEqual(@as(u32, 0), net.last_call_ms);
    try testing.expectEqual(@as(u32, 1), counter.writes);
    try testing.expect(net.links[0].faults.quiet());
}

test "a dropped request never reaches the server; a dropped reply always does" {
    // Goal: the difference that matters. Method: drop every request, then every reply; count
    // what the server saw. Both fail the agent with ZC-E0503 and the full timeout.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;

    net.set_faults(0, .{ .request = .{ .drop_per_mille = 1000 } });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0503), diag.code);
    try testing.expectEqual(@as(u32, 0), counter.writes);
    try testing.expectEqual(constants.agent_io_timeout_ms, net.last_call_ms);

    net.set_faults(0, .{ .reply = .{ .drop_per_mille = 1000 } });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    try testing.expectEqual(@as(u32, 1), counter.writes);
    try testing.expectEqual(@as(u32, 1), net.stats(0).replies_lost);
}

test "a delay is added to the call, and one past the timeout is a failure after the server acted" {
    // Goal: delay. Method: a delay bound under the timeout, then over it.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;

    net.set_faults(0, .{ .request = .{ .delay_ms_max = 50 }, .reply = .{ .delay_ms_max = 50 } });
    var longest: u32 = 0;
    for (0..40) |_| {
        diag.reset();
        const reply = try link.call(testing.allocator, read, &diag);
        testing.allocator.free(reply.body);
        longest = @max(longest, net.last_call_ms);
        try testing.expect(net.last_call_ms <= 100);
    }
    try testing.expect(longest > 0);

    const huge = constants.agent_io_timeout_ms * 2;
    net.set_faults(0, .{ .reply = .{ .delay_ms_max = huge } });
    var late: u32 = 0;
    for (0..40) |_| {
        diag.reset();
        if (link.call(testing.allocator, write, &diag)) |reply| {
            testing.allocator.free(reply.body);
        } else |_| {
            late += 1;
        }
    }
    try testing.expect(late > 0);
    try testing.expectEqual(late, net.stats(0).replies_lost);
    try testing.expectEqual(@as(u32, 40), counter.writes);
}

test "a duplicated write reaches the server twice and the agent sees one answer" {
    // Goal: duplicate delivery of a write. Method: duplicate every request.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;
    diag.reset();
    net.set_faults(0, .{ .duplicate_per_mille = 1000 });
    const reply = try link.call(testing.allocator, write, &diag);
    defer testing.allocator.free(reply.body);
    try testing.expectEqual(@as(u32, 2), counter.writes);
    try testing.expectEqualStrings("{\"n\":1}", reply.body);
    try testing.expectEqual(@as(u32, 1), net.stats(0).duplicated);
}

test "a reordered request arrives by the clock, after a newer write from the same agent" {
    // Goal: reorder that really reorders. Method: park a write with a delivery time well past the
    // agent's timeout, as the cluster would run it: the agent times out, sends a newer write that
    // the server gets, and only then does the clock pass the stale one's time. The server must
    // see newer, then stale; the stale one must not arrive at any call on the link.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;
    const late_ms: u32 = 5 * constants.agent_io_timeout_ms;
    net.set_faults(0, .{
        .reorder_per_mille = 1000,
        .reorder_delay_ms_min = late_ms,
        .reorder_delay_ms_max = late_ms,
    });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    try testing.expectEqual(@as(u32, 0), counter.writes);
    var now_ms: u64 = net.last_call_ms;
    net.tick(now_ms);
    net.set_faults(0, .{});
    diag.reset();
    const newer = try link.call(testing.allocator, read, &diag); // A newer request: the link works.
    testing.allocator.free(newer.body);
    now_ms += net.last_call_ms + constants.agent_io_timeout_ms;
    net.tick(now_ms);
    try testing.expectEqual(@as(u32, 0), counter.writes);
    diag.reset();
    const again = try link.call(testing.allocator, read, &diag);
    testing.allocator.free(again.body);
    try testing.expectEqual(@as(u32, 0), counter.writes); // Calls alone never deliver it.
    net.tick(late_ms - 1);
    try testing.expectEqual(@as(u32, 0), counter.writes);
    net.tick(late_ms);
    try testing.expectEqual(@as(u32, 1), counter.writes);
    try testing.expectEqualStrings("GGW", counter.order[0..counter.order_len]);
    try testing.expectEqual(@as(u32, 1), net.stats(0).delivered_late);
    net.tick(late_ms * 2);
    try testing.expectEqual(@as(u32, 1), counter.writes); // Delivered once.
}

test "a parked request is delivered in due order, across a cut link and a heal" {
    // Goal: packets already in flight arrive whatever happens to the link, earliest first.
    // Method: park two writes with different times on two links, cut one link and heal the
    // other, and tick past both.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    net.init(testing.allocator, counter.handler(), 5);
    defer net.deinit();
    var diag: Diag = undefined;
    const slow: Faults = .{
        .reorder_per_mille = 1000,
        .reorder_delay_ms_min = 9000,
        .reorder_delay_ms_max = 9000,
    };
    var quick = slow;
    quick.reorder_delay_ms_min = 2000;
    quick.reorder_delay_ms_max = 2000;
    net.set_faults(0, slow);
    net.set_faults(1, quick);
    diag.reset();
    const call0 = net.transport(0).call(testing.allocator, write, &diag);
    try testing.expectError(error.Unreachable, call0);
    diag.reset();
    const call1 = net.transport(1).call(testing.allocator, read, &diag);
    try testing.expectError(error.Unreachable, call1);
    net.set_faults(0, .{ .partition_up = true });
    net.heal();
    net.tick(2000);
    try testing.expectEqualStrings("G", counter.order[0..counter.order_len]);
    net.tick(9000);
    try testing.expectEqualStrings("GW", counter.order[0..counter.order_len]);
    try testing.expectEqual(@as(u32, 2), net.stats(0).delivered_late + net.stats(1).delivered_late);
}

test "a one-way partition and its heal" {
    // Goal: partitions. Method: cut requests (the server sees nothing), then replies (the server
    // acts and the agent hears nothing), then heal and see both directions work; a request parked
    // before the heal still arrives (it was in flight), when its time comes.
    var counter: Counter = .{};
    var net: SimNet = undefined;
    const link = make(&counter, &net);
    defer net.deinit();
    var diag: Diag = undefined;

    net.set_faults(0, .{ .partition_up = true });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    try testing.expectEqual(@as(u32, 0), counter.writes);

    net.set_faults(0, .{ .partition_down = true });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    try testing.expectEqual(@as(u32, 1), counter.writes);

    net.set_faults(0, .{ .reorder_per_mille = 1000 });
    diag.reset();
    try testing.expectError(error.Unreachable, link.call(testing.allocator, write, &diag));
    net.set_faults(0, .{ .partition_up = true });
    net.heal();
    diag.reset();
    const reply = try link.call(testing.allocator, write, &diag);
    defer testing.allocator.free(reply.body);
    try testing.expectEqual(@as(u32, 2), counter.writes);
    net.tick(10 * constants.agent_io_timeout_ms);
    try testing.expectEqual(@as(u32, 3), counter.writes);
    try testing.expectEqual(@as(u32, 1), net.stats(0).delivered_late);
}

test "the same seed draws the same faults" {
    // Goal: determinism. Method: two networks with one seed and 30% loss of replies make the same
    // calls and fail on the same ones.
    var outcomes: [2][64]bool = undefined;
    for (&outcomes) |*outcome| {
        var counter: Counter = .{};
        var net: SimNet = undefined;
        const link = make(&counter, &net);
        defer net.deinit();
        net.set_faults(0, .{ .reply = .{ .drop_per_mille = 300 } });
        var diag: Diag = undefined;
        for (outcome) |*slot| {
            diag.reset();
            if (link.call(testing.allocator, read, &diag)) |reply| {
                testing.allocator.free(reply.body);
                slot.* = true;
            } else |_| slot.* = false;
        }
    }
    try testing.expectEqual(outcomes[0], outcomes[1]);
}
