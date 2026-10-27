//! `zcube`: the command line. This file is the process around `cli.zig`: the streams, the
//! environment, the one panic handler and the exit code. Everything the user sees on failure is a
//! coded `ZC-` diagnostic decided in `cli.zig`; a panic is a `bug` diagnostic and exit 70, never a
//! stack trace (DIAGNOSTICS.md).

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const cli_args = @import("cli_args.zig");
const cli_env = @import("cli_env.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

/// A panic is a `bug` diagnostic. The internal message is shown only with `--verbose`; a panic
/// writes no bundle, because writing one from a panic handler could panic again.
pub const panic = std.debug.FullPanic(panic_handler);

/// Set by `main` before anything can panic; the handler has no other way to know.
var panic_mode: @import("zigbox").render.Mode = .text;

fn panic_handler(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = first_trace_address;
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    diag.raise(.B0001);
    diag.cause("{s}", .{message});
    var diagnostic: diag_mod.Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, &diag);
    var buffer: [constants.diag_output_bytes_max]u8 = undefined;
    const text = diag_mod.render(&diagnostic, panic_mode, false, &buffer);
    var io_buffer: [64]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(std.Options.debug_io, &io_buffer);
    writer.interface.writeAll(text) catch {}; // A panic has nowhere else to report it.
    writer.interface.flush() catch {};
    std.process.exit(constants.exit_internal);
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_environment;
    const options = cli_args.scan(args[1..]);
    panic_mode = if (options.output == .json) .json else if (options.verbose) .verbose else .text;

    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var in_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &err_buffer);
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buffer);
    const env: cli_env.Env = .{
        .io = init.io,
        .arena = arena,
        .environ = init.environ_map,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .stdin = &stdin.interface,
        .stdin_is_terminal = std.Io.File.stdin().isTty(init.io) catch false,
        .stderr_is_terminal = std.Io.File.stderr().isTty(init.io) catch false,
        .version = build_options.version,
    };
    return cli.run(&env, args[1..]);
}
