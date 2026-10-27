//! `zcube-server` as a value: start it, ask where it listens, stop it. `zcube_server.zig` is the
//! process around it (flags, signals, exit codes); the tests start and stop servers in-process.
//! Shell code: sockets, threads, the store backends, the real clock.
//!
//! A server is four things on top of a store: an accept loop (this thread's job, started by
//! `start` on a task of its own), one task per connection (`server_http.serve`), the controller
//! driver (`server_drive.Driver`) and the watchdog over the connection table. The store is the
//! only state: stopping and starting a server over the same store changes nothing.

const std = @import("std");
const assert = std.debug.assert;
const net = std.Io.net;
const api_mod = @import("api.zig");
const codes = @import("diag/codes.zig");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const BoundedArena = @import("server_arena.zig").BoundedArena;
const Driver = @import("server_drive.zig").Driver;
const http = @import("server_http.zig");
const replica_controller = @import("replica_controller.zig");
const Backend = @import("server_store.zig").Backend;
const server_listen = @import("server_listen.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const Error = error{ StartFailed, OutOfMemory };

pub const Options = struct {
    version: []const u8,
    /// Print the controller's failures to stderr; tests that break the store turn it off.
    report_failures: bool = true,
    /// Log requests to stderr; tests turn it off.
    log_requests: bool = true,
};

pub const Server = struct {
    gpa: Allocator,
    io: std.Io,
    backend: *Backend,
    shared: http.Shared,
    driver: Driver,
    listener: net.Server,
    group: std.Io.Group,
    accept_future: ?std.Io.Future(void),
    driver_future: ?std.Io.Future(void),
    watchdog_future: ?std.Io.Future(void),

    /// Opens the store, listens, and starts the tasks. On failure `diag` says why and nothing is
    /// left open. The `Server` does not move: it is allocated here and freed by `stop`.
    pub fn start(
        gpa: Allocator,
        io: std.Io,
        config: config_mod.Config,
        options: Options,
        diag: *Diag,
    ) Error!*Server {
        assert(diag.code == null);
        const backend = Backend.open(gpa, io, config.store, config.create_store, diag) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            assert(diag.code != null);
            return error.StartFailed;
        };
        errdefer backend.close();
        const server = try gpa.create(Server);
        errdefer gpa.destroy(server);
        server.* = try init_value(gpa, io, backend, config, options);
        server.listener = try listen(io, config.listen, diag);
        errdefer server.listener.deinit(io);
        try server.spawn(diag);
        return server;
    }

    fn init_value(
        gpa: Allocator,
        io: std.Io,
        backend: *Backend,
        config: config_mod.Config,
        options: Options,
    ) Error!Server {
        const clock = backend.clock();
        const now = clock.now_ms();
        const instance: u16 = @intCast(1 + @mod(@divFloor(now, 1000), 60_000));
        return .{
            .gpa = gpa,
            .io = io,
            .backend = backend,
            .shared = .{
                .gpa = gpa,
                .io = io,
                .store = backend.handle(),
                .clock = clock,
                .api = .{
                    .version = options.version,
                    .backend = config.store.backend(),
                    .started_at_ms = now,
                    // The low 32 bits of the start time in milliseconds, never 0: a restart
                    // is later, so its ids differ from the last start's.
                    .instance = @max(1, @as(u32, @truncate(now))),
                    // Distinct from the controller's instance, so two writers in one
                    // millisecond never share a decision id.
                    .source = .{ .instance = 0 },
                },
                .options = .{
                    .verbose = config.verbose,
                    .quiet = config.quiet,
                    .silent = !options.log_requests,
                },
            },
            .driver = .{
                .gpa = gpa,
                .io = io,
                .store = backend.handle(),
                .clock = clock,
                .replicas = replica_controller.ReplicaController.init(instance),
                .stopping = undefined,
                .report_failures = options.report_failures,
            },
            .listener = undefined,
            .group = .init,
            .accept_future = null,
            .driver_future = null,
            .watchdog_future = null,
        };
    }

    fn listen(io: std.Io, where: net.IpAddress, diag: *Diag) Error!net.Server {
        return server_listen.listen(io, where) catch |err| {
            diag.raise(.E0107);
            const reason: []const u8 = switch (err) {
                error.AddressInUse => "the address is in use by another process",
                error.AddressUnavailable => "it is not an address of this machine",
                error.AccessDenied => "this user may not listen on that port",
                error.Failed => "the system refused",
            };
            diag.cause("can't listen on {f}: {s}", .{ where, reason });
            diag.fix(.{
                .sentence = "listen on another port",
                .command = "zcube-server --listen 127.0.0.1:7071",
            });
            return error.StartFailed;
        };
    }

    fn spawn(server: *Server, diag: *Diag) Error!void {
        server.driver.stopping = &server.shared.stopping;
        const io = server.io;
        server.driver_future = io.concurrent(Driver.run, .{&server.driver}) catch
            return no_threads(diag);
        errdefer server.cancel_tasks();
        server.watchdog_future = io.concurrent(http.Shared.watchdog, .{&server.shared}) catch
            return no_threads(diag);
        server.accept_future = io.concurrent(accept_loop, .{server}) catch return no_threads(diag);
    }

    fn no_threads(diag: *Diag) Error {
        diag.raise(.E0108);
        diag.cause("the server could not start a thread for its work", .{});
        const sentence = "raise the process's thread limit (ulimit -u) and start it again";
        diag.fix(.{ .sentence = sentence });
        return error.StartFailed;
    }

    /// Where the server listens (with the port the system chose, if the configuration said 0).
    pub fn address(server: *const Server) net.IpAddress {
        return server.listener.socket.address;
    }

    /// Tells a client it is refused, on a task and a slot of its own so the accept loop never
    /// waits on it. With none free, the connection is just closed.
    fn refuse(server: *Server, stream: net.Stream, cause: []const u8) void {
        const shared = &server.shared;
        const slot = shared.take_slot(stream, .refusal) orelse return stream.close(server.io);
        const args = .{ shared, slot, stream, cause };
        server.group.concurrent(server.io, http.serve_refusal, args) catch {
            http.release(shared, slot);
        };
    }

    /// Connections open now, and held watches.
    pub fn connections(server: *Server) u32 {
        return server.shared.connections();
    }

    pub fn holds(server: *const Server) u32 {
        return server.shared.holds.load(.acquire);
    }

    /// Controller steps that have run.
    pub fn steps(server: *const Server) u64 {
        return server.driver.steps.load(.monotonic);
    }

    /// Stops accepting, gives open connections `server_stop_ms` to finish (a held watch notices
    /// within a second), closes the rest, stops the tasks, closes the store and frees the server.
    pub fn stop(server: *Server) void {
        server.shared.stopping.store(true, .release);
        if (server.accept_future) |*future| future.cancel(server.io);
        server.accept_future = null;
        server.drain();
        server.group.cancel(server.io);
        server.cancel_tasks();
        server.listener.deinit(server.io);
        const gpa = server.gpa;
        server.backend.close();
        gpa.destroy(server);
    }

    fn cancel_tasks(server: *Server) void {
        if (server.driver_future) |*future| future.cancel(server.io);
        server.driver_future = null;
        if (server.watchdog_future) |*future| future.cancel(server.io);
        server.watchdog_future = null;
    }

    fn drain(server: *Server) void {
        const waits = @divFloor(constants.server_stop_ms, constants.server_poll_ms);
        for (0..waits) |_| {
            if (server.shared.connections() == 0) return;
            server.io.sleep(.fromMilliseconds(constants.server_poll_ms), .awake) catch return;
        }
    }
};

/// Accepts connections until cancelled. A connection past the limit is answered 503 and closed on
/// the spot; the rest each get a task of their own.
fn accept_loop(server: *Server) void {
    const shared = &server.shared;
    const io = server.io;
    while (!shared.stopping.load(.acquire)) {
        const stream = server.listener.accept(io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => return,
            else => {
                // A failed accept (descriptors, memory) is retried after a breath, not spun on.
                io.sleep(.fromMilliseconds(constants.server_poll_ms), .awake) catch return;
                continue;
            },
        };
        const slot = shared.take_slot(stream, .connection) orelse {
            server.refuse(stream, "too many connections are open");
            continue;
        };
        server.group.concurrent(io, http.serve, .{ shared, slot, stream }) catch {
            http.release(shared, slot);
        };
    }
}
