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
const Remembered = @import("server_remember.zig").Remembered;
const store_verified = @import("store_verified.zig");

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
    /// Wraps the backend's store: every call the server makes goes through it.
    verified: store_verified.VerifiedStore,
    remembered: ?Remembered,
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
        try server.guard(config, diag);
        errdefer server.unguard();
        server.first_check(diag);
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
            .verified = undefined,
            .remembered = null,
            .listener = undefined,
            .group = .init,
            .accept_future = null,
            .driver_future = null,
            .watchdog_future = null,
        };
    }

    /// Puts the `VerifiedStore` between the server and its backend, with the pair remembered by
    /// the last run (`server_remember.zig`). A memory store remembers nothing: it cannot outlive
    /// a restart. A Postgres store needs `--state-dir`: there is no directory beside it.
    fn guard(server: *Server, config: config_mod.Config, diag: *Diag) Error!void {
        var known: ?store_verified.Pair = null;
        var remember: ?store_verified.Remember = null;
        if (state_path(config, diag)) |path| {
            var name_buffer: [300]u8 = undefined;
            const database: ?[]const u8 = switch (config.store) {
                .sqlite => |file| try server.absolute(file, diag),
                .memory, .postgres => null,
            };
            defer if (database) |path_absolute| server.gpa.free(path_absolute);
            const name = Remembered.file_for(database, &name_buffer) orelse {
                diag.raise(.E0216);
                diag.cause("the SQLite file's name is too long to name its remembered file", .{});
                diag.cause("that file is named after it: its name can be about 260 bytes", .{});
                diag.fix(.{ .sentence = "give the SQLite file a shorter name" });
                return error.StartFailed;
            };
            server.remembered = Remembered.open(server.io, path, name, diag) catch
                return error.StartFailed;
            errdefer server.unguard();
            known = server.remembered.?.load(diag) catch return error.StartFailed;
            remember = server.remembered.?.interface();
        } else if (diag.code != null) {
            return error.StartFailed;
        }
        const raw = server.backend.handle();
        server.verified = store_verified.VerifiedStore.init(
            raw,
            server.backend.clock(),
            remember,
            known,
        );
        const guarded = server.verified.interface();
        server.shared.store = guarded;
        server.shared.api.verified = &server.verified;
        server.driver.store = guarded;
        server.driver.verified = &server.verified;
    }

    /// `file` as an absolute path (working directory plus name, lexically), for keying the
    /// remembered file by the database it describes. The caller frees it.
    fn absolute(server: *Server, file: []const u8, diag: *Diag) Error![]u8 {
        const cwd = std.process.currentPathAlloc(server.io, server.gpa) catch |err| {
            diag.raise(.E0216);
            diag.cause("can't tell the working directory to name the remembered file: {s}", .{
                @errorName(err),
            });
            diag.fix(.{ .sentence = "give the SQLite file as an absolute path" });
            return error.StartFailed;
        };
        defer server.gpa.free(cwd);
        return std.fs.path.resolveAlloc(server.gpa, &.{ cwd, file });
    }

    /// Checks the store against the remembered pair before anything listens or steps, so that a
    /// store that went backwards while the server was down is refused from the first request.
    /// On a halt the server still starts, halted: it logs the diagnostic and every call answers
    /// `ZC-E0215`. A store that cannot be read now is the driver's to report.
    fn first_check(server: *Server, diag: *Diag) void {
        _ = server.verified.interface().status(diag) catch {
            if (server.verified.halt_state() != null and server.driver.report_failures) {
                var diagnostic: diag_mod.Diagnostic = undefined;
                diag_mod.to_diagnostic(&diagnostic, diag);
                var buffer: [constants.diag_output_bytes_max]u8 = undefined;
                const text = diag_mod.render(&diagnostic, .text, false, &buffer);
                const file = std.Io.File.stderr();
                file.writeStreamingAll(server.io, "\nzcube-server: starting halted\n") catch {};
                file.writeStreamingAll(server.io, text) catch {};
            }
            diag.reset();
        };
    }

    fn unguard(server: *Server) void {
        if (server.remembered) |*remembered| remembered.close();
        server.remembered = null;
    }

    /// The state directory, null for a memory store. Raises `ZC-E0106` for Postgres without one.
    pub fn state_path(config: config_mod.Config, diag: *Diag) ?[]const u8 {
        if (config.state_dir) |dir| return dir;
        switch (config.store) {
            .memory => return null,
            .sqlite => |path| return std.fs.path.dirname(path) orelse ".",
            .postgres => {
                diag.raise(.E0106);
                diag.cause("a Postgres store needs --state-dir", .{});
                diag.cause("the server remembers the highest revision it saw in a file there", .{});
                diag.fix(.{
                    .sentence = "name a directory outside the store",
                    .command = "zcube-server --state-dir /var/lib/zcube",
                });
                return null;
            },
        }
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
        if (!server.verified.flush()) {
            const line = "zcube-server: could not save the remembered revision (ZC-E0216); " ++
                "the next start remembers an older one\n";
            std.Io.File.stderr().writeStreamingAll(server.io, line) catch {};
        }
        server.unguard();
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
