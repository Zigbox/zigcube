//! The mesh of one `FakeRuntime` container, held by its supervisor (C4 slice 4, O2): the
//! replica's mesh port on the node and one listener per granted destination and port, on the
//! destination's mesh address (`127.77.<hi>.<lo>`, loopback). Shell code: host sockets and one
//! thread.
//!
//! The rules come from `mesh.json`, which `FakeRuntime.start` and each `Runtime.mesh_update`
//! put whole; `mesh_update` then sends the supervisor `SIGUSR2`, whose handler wakes this thread
//! through a pipe. The thread also reads the file every `fake_mesh_poll_ms`, so a signal that
//! came before the handler stood, or a listener that could not be bound, is caught up with soon.
//! Once every listener of the rules is held it writes their hash (`runtime.mesh_rules_hash`, 16
//! hex digits) to `mesh.applied`: that is how a test, and later the agent, sees them applied.
//!
//! What it does not do yet: carry a connection. A connection to a listener or to the mesh port
//! is accepted and closed at once; the data path (endpoint choice, TLS, both grant checks, the
//! pump, revocation of open connections) is C4 slice 6. And the fake runtime has no network
//! namespace, so the listeners are host sockets, shared by every supervisor on the host that
//! holds the same destination and port (`SO_REUSEPORT`): which of them accepts a connection is
//! the kernel's choice. Slice 6 must not take the accepting supervisor for the caller's.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const constants = @import("constants.zig");
const runtime = @import("runtime.zig");
const agent_records = @import("agent_records.zig");
const agent_state = @import("agent_state.zig");

const Allocator = std.mem.Allocator;
const fd_t = linux.fd_t;

const nonblock_cloexec: u32 = linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;

/// The write end of the running mesh's wake pipe, for the `SIGUSR2` handler; -1 for none.
var wake_write: std.atomic.Value(i32) = .init(-1);

/// `SIGUSR2`, sent by `FakeRuntime.mesh_update`: new rules are in `mesh.json`.
pub fn on_rules(_: std.posix.SIG) callconv(.c) void {
    const fd = wake_write.load(.seq_cst);
    if (fd >= 0) _ = linux.write(fd, "u", 1);
}

const Held = struct {
    address: u32,
    port: u16,
    fd: fd_t,
};

pub const OpenError = error{ SocketFailed, BindFailed, ListenFailed, PipeFailed };

pub const Mesh = struct {
    gpa: Allocator,
    /// The container's directory, for `mesh.json`, `mesh.applied` and `mesh.log`.
    dir_fd: fd_t,
    port: u16,
    port_fd: fd_t,
    /// Read end, write end. A byte `u` is new rules, `q` is stop.
    wake: [2]fd_t,
    held: std.ArrayList(Held) = .empty,
    thread: ?std.Thread = null,
    /// The hash of the rules last applied in full, 0 for none.
    applied: u64 = 0,

    /// Binds the mesh port on every address of the node (no thread yet). A port that cannot be
    /// bound is the caller's start failure (ZC-E0710).
    pub fn open(gpa: Allocator, dir_fd: fd_t, port: u16) OpenError!*Mesh {
        assert(port > 0);
        const port_fd = try listen(0, port);
        errdefer _ = linux.close(port_fd);
        var pipe: [2]fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) {
            return error.PipeFailed;
        }
        errdefer for (pipe) |fd| {
            _ = linux.close(fd);
        };
        const mesh = gpa.create(Mesh) catch return error.SocketFailed;
        mesh.* = .{ .gpa = gpa, .dir_fd = dir_fd, .port = port, .port_fd = port_fd, .wake = pipe };
        return mesh;
    }

    /// Applies the rules in `mesh.json` and serves until `stop`. The `SIGUSR2` handler must stand
    /// before the supervisor's pid is written, or the first signal kills it.
    pub fn start(mesh: *Mesh) std.Thread.SpawnError!void {
        assert(mesh.thread == null);
        wake_write.store(mesh.wake[1], .seq_cst);
        mesh.thread = try std.Thread.spawn(.{}, serve, .{mesh});
    }

    /// Closes the mesh port and every listener, waits for the thread and frees the mesh.
    pub fn stop(mesh: *Mesh) void {
        wake_write.store(-1, .seq_cst);
        if (mesh.thread) |thread| {
            _ = linux.write(mesh.wake[1], "q", 1);
            thread.join();
        }
        for (mesh.held.items) |held| _ = linux.close(held.fd);
        mesh.held.deinit(mesh.gpa);
        _ = linux.close(mesh.port_fd);
        for (mesh.wake) |fd| _ = linux.close(fd);
        const gpa = mesh.gpa;
        gpa.destroy(mesh);
    }

    fn serve(mesh: *Mesh) void {
        mesh.reload();
        var fds: std.ArrayList(linux.pollfd) = .empty;
        defer fds.deinit(mesh.gpa);
        while (true) {
            fds.clearRetainingCapacity();
            fds.ensureTotalCapacity(mesh.gpa, 2 + mesh.held.items.len) catch {
                sleep_ms(constants.fake_mesh_poll_ms);
                mesh.reload();
                continue;
            };
            fds.appendAssumeCapacity(polled_in(mesh.wake[0]));
            fds.appendAssumeCapacity(polled_in(mesh.port_fd));
            for (mesh.held.items) |held| fds.appendAssumeCapacity(polled_in(held.fd));
            const ready = linux.poll(fds.items.ptr, fds.items.len, constants.fake_mesh_poll_ms);
            if (linux.errno(ready) != .SUCCESS or ready == 0) {
                mesh.reload();
                continue;
            }
            for (fds.items[1..]) |polled| {
                if (polled.revents & linux.POLL.IN != 0) refuse_one(polled.fd);
            }
            if (fds.items[0].revents & linux.POLL.IN != 0) {
                if (mesh.drain_wake()) return;
                mesh.reload();
            }
        }
    }

    /// Reads the wake pipe empty; true if a stop is among what it read.
    fn drain_wake(mesh: *Mesh) bool {
        var buffer: [64]u8 = undefined;
        while (true) {
            const read = linux.read(mesh.wake[0], &buffer, buffer.len);
            if (linux.errno(read) != .SUCCESS or read == 0) return false;
            if (std.mem.indexOfScalar(u8, buffer[0..read], 'q') != null) return true;
        }
    }

    /// Applies `mesh.json` if it is there and well formed; keeps what it holds otherwise.
    fn reload(mesh: *Mesh) void {
        var arena_state = std.heap.ArenaAllocator.init(mesh.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const bytes = read_file(arena, mesh.dir_fd, agent_records.file_mesh) orelse return;
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const parsed = std.json.parseFromSliceLeaky(agent_records.MeshFile, arena, bytes, options);
        const file = parsed catch return; // Half a file cannot be: it is put whole.
        if (runtime.mesh_rules_problem(&file.rules) != null) return;
        const hash = runtime.mesh_rules_hash(&file.rules);
        if (hash == mesh.applied) return;
        if (mesh.apply(arena, &file.rules)) {
            mesh.applied = hash;
            write_applied(mesh.dir_fd, hash);
        }
    }

    /// Closes the listeners the rules no longer name and binds those they name that are not held.
    /// True if every listener of the rules is held.
    fn apply(mesh: *Mesh, arena: Allocator, rules: *const runtime.MeshRules) bool {
        const wanted = arena.alloc(Held, rules.listeners.len) catch return false;
        for (rules.listeners, wanted) |listener, *slot| {
            const destination = &rules.destinations[listener.destination];
            const address = parse_ip4(destination.address) orelse {
                mesh.note("ZC-E0711 the mesh address {s} of {s} is not an IPv4 address", .{
                    destination.address, destination.service,
                });
                return false;
            };
            slot.* = .{ .address = address, .port = listener.port, .fd = -1 };
        }
        var index: usize = 0;
        while (index < mesh.held.items.len) {
            const held = mesh.held.items[index];
            if (find(wanted, held.address, held.port) == null) {
                _ = linux.close(held.fd);
                _ = mesh.held.swapRemove(index);
            } else index += 1;
        }
        var complete = true;
        for (wanted) |want| {
            if (find(mesh.held.items, want.address, want.port) != null) continue;
            const fd = listen(want.address, want.port) catch |err| {
                mesh.note("ZC-E0711 the listener {d}.{d}.{d}.{d}:{d} could not be opened: {s}", .{
                    want.address >> 24,         (want.address >> 16) & 0xff,
                    (want.address >> 8) & 0xff, want.address & 0xff,
                    want.port,                  @errorName(err),
                });
                complete = false;
                continue;
            };
            const held: Held = .{ .address = want.address, .port = want.port, .fd = fd };
            mesh.held.append(mesh.gpa, held) catch {
                _ = linux.close(fd);
                complete = false;
            };
        }
        return complete;
    }

    /// One line in `mesh.log`, best effort.
    fn note(mesh: *Mesh, comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, format ++ "\n", args) catch return;
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        };
        const opened = linux.openat(mesh.dir_fd, agent_records.file_mesh_log, flags, 0o644);
        if (linux.errno(opened) != .SUCCESS) return;
        const fd: fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        _ = linux.write(fd, line.ptr, line.len);
    }
};

fn polled_in(fd: fd_t) linux.pollfd {
    return .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
}

fn find(list: []const Held, address: u32, port: u16) ?usize {
    for (list, 0..) |held, index| {
        if (held.address == address and held.port == port) return index;
    }
    return null;
}

/// A listening socket on `address:port` (host order; 0 is every address), shared with other
/// supervisors of the host (`SO_REUSEPORT`, see the top of the file).
fn listen(address: u32, port: u16) error{ SocketFailed, BindFailed, ListenFailed }!fd_t {
    assert(port > 0);
    const made = linux.socket(linux.AF.INET, linux.SOCK.STREAM | nonblock_cloexec, 0);
    if (linux.errno(made) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(made);
    errdefer _ = linux.close(fd);
    const on = std.mem.toBytes(@as(c_int, 1));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, &on, on.len);
    if (address != 0) {
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, &on, on.len);
    }
    var socket_address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, address),
    };
    const size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const bound = linux.bind(fd, @ptrCast(&socket_address), size);
    if (linux.errno(bound) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

/// Accepts one connection and closes it: the data path is C4 slice 6.
fn refuse_one(fd: fd_t) void {
    const accepted = linux.accept4(fd, null, null, nonblock_cloexec);
    if (linux.errno(accepted) == .SUCCESS) _ = linux.close(@intCast(accepted));
}

/// `a.b.c.d` in host order, or null.
pub fn parse_ip4(text: []const u8) ?u32 {
    var value: u32 = 0;
    var parts: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (parts == 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        const octet = std.fmt.parseInt(u8, part, 10) catch return null;
        value = (value << 8) | octet;
        parts += 1;
    }
    if (parts != 4) return null;
    return value;
}

fn read_file(arena: Allocator, dir_fd: fd_t, name: [*:0]const u8) ?[]const u8 {
    const opened = linux.openat(dir_fd, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const buffer = arena.alloc(u8, agent_state.file_bytes_max) catch return null;
    var filled: usize = 0;
    while (filled < buffer.len) {
        const read = linux.read(fd, buffer[filled..].ptr, buffer.len - filled);
        if (linux.errno(read) != .SUCCESS) return null;
        if (read == 0) break;
        filled += read;
    }
    return buffer[0..filled];
}

/// `mesh.applied`, put whole (a temporary file renamed over it).
fn write_applied(dir_fd: fd_t, hash: u64) void {
    var text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>16}", .{hash}) catch unreachable; // 16 digits fit.
    const temporary = agent_records.file_mesh_applied ++ ".new";
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.openat(dir_fd, temporary, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: fd_t = @intCast(opened);
    _ = linux.write(fd, &text, text.len);
    _ = linux.close(fd);
    _ = linux.renameat(dir_fd, temporary, dir_fd, agent_records.file_mesh_applied);
}

fn sleep_ms(ms: u32) void {
    const nap: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms,
    };
    _ = linux.nanosleep(&nap, null);
}

const testing = std.testing;

test "fake mesh: parse_ip4 takes four octets and nothing else" {
    try testing.expectEqual(@as(?u32, 0x7f4d0003), parse_ip4("127.77.0.3"));
    try testing.expectEqual(@as(?u32, null), parse_ip4("127.77.0"));
    try testing.expectEqual(@as(?u32, null), parse_ip4("127.77.0.3.1"));
    try testing.expectEqual(@as(?u32, null), parse_ip4("127.77.0.256"));
    try testing.expectEqual(@as(?u32, null), parse_ip4("127..0.3"));
}
