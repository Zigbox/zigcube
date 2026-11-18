//! The test-only registration barrier (#237) in a real `zcube-server` in this process, over HTTP
//! on loopback: it holds an armed registration before the API's write lock, so other writes go on,
//! a newer registration lands, and the held one comes back refused. Test code, so it may sleep.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const private_dir = @import("testing/private_dir.zig");
const server_mod = @import("server.zig");
const Barrier = @import("server_register_barrier.zig").Barrier;

const Diag = diag_mod.Diag;

const Reply = struct {
    status: u16,
    body: []const u8,
    raw: []u8,

    fn free(reply: Reply) void {
        testing.allocator.free(reply.raw);
    }
};

fn send(
    io: std.Io,
    address: net.IpAddress,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !Reply {
    const request = try std.fmt.allocPrint(
        testing.allocator,
        "{s} {s} HTTP/1.1\r\nHost: test\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method, path, body.len, body },
    );
    defer testing.allocator.free(request);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const raw = try reader.interface.allocRemaining(testing.allocator, .limited(1024 * 1024));
    errdefer testing.allocator.free(raw);
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse return error.NoHead;
    return .{
        .status = try std.fmt.parseInt(u16, raw[9..12], 10),
        .body = raw[split + 4 ..],
        .raw = raw,
    };
}

fn grant(io: std.Io, address: net.IpAddress) !u64 {
    const reply = try send(io, address, "POST", "/v1/agent/nodes/node1/lease", "{}");
    defer reply.free();
    try testing.expectEqual(@as(u16, 200), reply.status);
    const Answer = struct { lease: struct { id: u64 } };
    const parsed = try std.json.parseFromSlice(Answer, testing.allocator, reply.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.lease.id;
}

fn register(io: std.Io, address: net.IpAddress, lease: u64) !Reply {
    var buffer: [160]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"lease\":{d},\"capacity\":" ++
        "{{\"cpu_millis\":1000,\"memory_bytes\":1073741824}}}}", .{lease});
    return send(io, address, "PUT", "/v1/agent/nodes/node1", body);
}

const Held = struct {
    io: std.Io,
    address: net.IpAddress,
    lease: u64,
    reply: ?Reply = null,

    fn run(held: *Held) void {
        held.reply = register(held.io, held.address, held.lease) catch null;
    }
};

fn wait_for(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var waited_ms: u32 = 0;
    while (waited_ms < 10_000) : (waited_ms += 10) {
        if (dir.access(io, name, .{})) |_| return else |_| {}
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

test "the barrier holds a registration before the write lock; released, it is refused (#237)" {
    // Goal: the zigcube-jepsen test's case can happen: while node1's registration on L1 is held,
    // other writes go on and a registration on L2 lands; L1, released, meets the key on L2 and is
    // refused (ZC-E0205), and `done` says so. Method: a real server with the barrier's hook.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{
        .concurrent_limit = .limited(constants.http_connections_max +
            constants.http_refusals_max + constants.server_threads_extra + 8),
    });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const dir_path = path_buffer[0..length];

    var diag: Diag = undefined;
    diag.reset();
    const config: config_mod.Config = .{
        // A literal.
        .insecure_listen = config_mod.parse_listen("127.0.0.1:0", &diag) catch unreachable,
        .store = .memory,
        .create_store = false,
        .verbose = false,
        .quiet = true,
    };
    try private_dir.state_dir(io, config);
    var barrier: Barrier = .{ .io = io, .dir = dir_path, .wait_ms = 20_000 };
    const server = try server_mod.Server.start(testing.allocator, io, config, .{
        .version = "0.0.0-test",
        .report_failures = false,
        .log_requests = false,
        .hook = barrier.hook(),
    }, &diag);
    defer server.stop();
    const address = server.address();

    const first = try grant(io, address);
    const second = try grant(io, address);
    try tmp.dir.writeFile(io, .{ .sub_path = "arm-node1", .data = "" });
    var held: Held = .{ .io = io, .address = address, .lease = first };
    var future = try io.concurrent(Held.run, .{&held});
    var name_buffer: [64]u8 = undefined;
    const held_name = try std.fmt.bufPrint(&name_buffer, "held-node1-{d}", .{first});
    try wait_for(io, tmp.dir, held_name);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "arm-node1", .{}));

    // While L1 is held: other writes, and the newer registration, are served.
    const keepalive_lease = try grant(io, address);
    try testing.expect(keepalive_lease > second);
    const newer = try register(io, address, second);
    defer newer.free();
    try testing.expectEqual(@as(u16, 200), newer.status);

    const release = try std.fmt.bufPrint(&name_buffer, "release-node1-{d}", .{first});
    try tmp.dir.writeFile(io, .{ .sub_path = release, .data = "" });
    future.await(io);
    const late = held.reply orelse return error.NoReply;
    defer late.free();
    try testing.expectEqual(@as(u16, 503), late.status);
    try testing.expect(std.mem.indexOf(u8, late.body, "ZC-E0205") != null);
    const done_name = try std.fmt.bufPrint(&name_buffer, "done-node1-{d}", .{first});
    var done_buffer: [96]u8 = undefined;
    const done = try tmp.dir.readFile(io, done_name, &done_buffer);
    try testing.expect(std.mem.startsWith(u8, done, "succeeded 0 revision 0 at_ms "));

    try expect_unheld(io, address, tmp.dir);
}

/// Unarmed, the next registration passes the barrier without a hold.
fn expect_unheld(io: std.Io, address: net.IpAddress, dir: std.Io.Dir) !void {
    const third = try grant(io, address);
    const again = try register(io, address, third);
    defer again.free();
    try testing.expectEqual(@as(u16, 200), again.status);
    var name_buffer: [64]u8 = undefined;
    const unheld = try std.fmt.bufPrint(&name_buffer, "held-node1-{d}", .{third});
    try testing.expectError(error.FileNotFound, dir.access(io, unheld, .{}));
}
