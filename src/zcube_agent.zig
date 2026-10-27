//! `zcube-agent`: the node agent. This file is the process around `agent_run.zig`: flags and the
//! configuration file, the one panic handler, and the exit codes of DIAGNOSTICS.md. Every
//! start-up failure (a bad setting, a state directory that cannot be used) is a coded `ZC-`
//! diagnostic on stderr and an exit code decided by its blame; a panic is a `bug` diagnostic and
//! exit 70. Never a stack trace.
//!
//! `zcube-agent supervise <dir>` is the same executable run again as the supervisor of one
//! container (`fake_supervisor.zig`); nothing else uses that mode.

const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("build_options");
const agent_run = @import("agent_run.zig");
const config_mod = @import("agent_config.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const fake_supervisor = @import("fake_supervisor.zig");

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

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return constants.exit_environment;
    verbose_panics = args_ask_verbose(args);
    var diag: Diag = undefined;
    diag.reset();
    const command = config_mod.load(arena, init.io, args[1..], &diag) catch |err| {
        if (err == error.OutOfMemory) return constants.exit_environment;
        return agent_run.fail(init.io, &diag, args_ask_verbose(args));
    };
    switch (command) {
        .version => return say(init.io, "zcube-agent " ++ build_options.version ++ "\n"),
        .help => return say(init.io, config_mod.usage),
        .supervise => |directory| return fake_supervisor.run(init, directory),
        .run => |config| {
            verbose_panics = config.verbose;
            return agent_run.run(init, config);
        },
    }
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
