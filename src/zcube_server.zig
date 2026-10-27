//! `zcube-server`: the API, the controllers and the console in one process. This file is the
//! process around `server.zig`: flags and the configuration file, the one panic handler,
//! signals, and the exit codes of DIAGNOSTICS.md. Every start-up failure (a bad setting, a store
//! that cannot be reached, a port in use) is a coded `ZC-` diagnostic on stderr and an exit code
//! decided by its blame; a panic is a `bug` diagnostic and exit 70. Never a stack trace.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const config_mod = @import("server_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const server_mod = @import("server.zig");

const Diag = diag_mod.Diag;

/// A panic is a `bug` diagnostic. The internal message is shown only with `--verbose`
/// (DIAGNOSTICS.md); a panic writes no bundle, because writing one from a panic handler could
/// panic again.
pub const panic = std.debug.FullPanic(panic_handler);

/// Set by `main` before anything can panic; the handler has no other way to know.
var verbose_panics: bool = false;

fn panic_handler(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = first_trace_address;
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.B0001);
    diag.cause("{s}", .{message});
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: @import("zigbox").render.Mode = if (verbose_panics) .verbose else .text;
    const text = diag_mod.render(&diagnostic, mode, false, &buffer);
    var io_buffer: [64]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(std.Options.debug_io, &io_buffer);
    writer.interface.writeAll(text) catch {}; // A panic has nowhere else to report it.
    writer.interface.flush() catch {};
    std.process.exit(constants.exit_internal);
}

/// Set by the signal handler, read by `main`.
var stop_requested: std.atomic.Value(bool) = .init(false);

fn on_signal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_environment;
    verbose_panics = args_ask_verbose(args);
    var diag: Diag = undefined;
    diag.reset();
    const command = config_mod.load(arena, init.io, args[1..], &diag) catch |err| {
        if (err == error.OutOfMemory) return constants.exit_environment;
        return fail(init.io, &diag, args_ask_verbose(args));
    };
    switch (command) {
        .version => return say(init.io, "zcube-server " ++ build_options.version ++ "\n"),
        .help => return say(init.io, config_mod.usage),
        .run => |config| return run(init, config),
    }
}

fn run(init: std.process.Init, config: config_mod.Config) u8 {
    verbose_panics = config.verbose;
    const limit = constants.http_connections_max + constants.http_refusals_max +
        constants.server_threads_extra;
    var threaded = std.Io.Threaded.init(init.gpa, .{ .concurrent_limit = .limited(limit) });
    defer threaded.deinit();
    const io = threaded.io();
    var diag: Diag = undefined;
    diag.reset();
    const server = server_mod.Server.start(init.gpa, io, config, .{
        .version = build_options.version,
    }, &diag) catch |err| {
        if (err == error.OutOfMemory) return constants.exit_environment;
        return fail(io, &diag, config.verbose);
    };
    announce(io, server, config);
    install_signals();
    while (!stop_requested.load(.acquire)) {
        io.sleep(.fromMilliseconds(100), .awake) catch break;
    }
    server.stop();
    return constants.exit_ok;
}

fn announce(io: std.Io, server: *server_mod.Server, config: config_mod.Config) void {
    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "zcube-server {s} listening on {f} (store: {s})\n", .{
        build_options.version, server.address(), config.store.backend(),
    }) catch return;
    _ = say(io, line);
    if (config.store == .memory) {
        _ = say(io, "zcube-server: the memory store keeps nothing: stopping the server loses it\n");
    }
}

fn install_signals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = on_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

/// Prints the diagnostic and returns the exit code its blame decides.
fn fail(io: std.Io, diag: *const Diag, verbose: bool) u8 {
    assert(diag.code != null);
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const mode: @import("zigbox").render.Mode = if (verbose) .verbose else .text;
    const text = diag_mod.render(&diagnostic, mode, false, &buffer);
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else to report it.
    return diag.exit_code();
}

fn say(io: std.Io, text: []const u8) u8 {
    std.Io.File.stdout().writeStreamingAll(io, text) catch return constants.exit_environment;
    return constants.exit_ok;
}

/// `--verbose` before the arguments are parsed: so a bad flag can still be shown in full.
fn args_ask_verbose(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) return true;
        if (std.mem.eql(u8, arg, "-v")) return true;
    }
    return false;
}
