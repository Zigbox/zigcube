//! The `zcube` command line as a function: arguments in, output on the streams of an `Env`, an
//! exit code out. `zcube.zig` is the process around it; the tests call `run` with an `Env` over
//! buffers, so every command and every failure is tested without a terminal.
//!
//! The boundary rules of DIAGNOSTICS.md live here and nowhere below: a failure is rendered once,
//! in the mode the user asked for (default, `--verbose`, `--output json`), the exit code comes
//! from the blame of the first diagnostic, a `bug` writes its bundle, and the failure is recorded
//! for `zcube bundle --last`. Nothing under this file prints a diagnostic or picks an exit code.

const std = @import("std");
const assert = std.debug.assert;
const bundle_collect = @import("bundle_collect.zig");
const cli_args = @import("cli_args.zig");
const cli_commands = @import("cli_commands.zig");
const cli_env = @import("cli_env.zig");
const cli_get = @import("cli_get.zig");
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");

const Client = cli_http.Client;
const Env = cli_env.Env;
const Error = cli_report.Error;
const Parsed = cli_args.Parsed;
const Report = cli_report.Report;

/// What a command does, given a client: replaceable by the tests, so that the path of an
/// unexpected error can be walked without a real bug.
pub const Executor = *const fn (
    env: *const Env,
    client: *Client,
    parsed: *const Parsed,
    command_line: []const u8,
    report: *Report,
) Error!void;

/// What a finished command leaves behind besides its output.
const Ending = struct {
    env: *const Env,
    options: cli_args.Options,
    /// The command as typed, for the failure record and bundles.
    line: []const u8,
    /// The server the command talked to; empty if it never got that far.
    server: []const u8 = "",
    client: ?*Client = null,
    /// A failure is remembered for `zcube bundle --last`.
    record: bool = false,
};

/// Runs `args` (without the program name) and returns the exit code.
pub fn run(env: *const Env, args: []const []const u8) u8 {
    return run_with(env, args, execute);
}

pub fn run_with(env: *const Env, args: []const []const u8, executor: Executor) u8 {
    var report: Report = undefined;
    report.reset();
    var parsed: Parsed = undefined;
    var ending: Ending = .{
        .env = env,
        .options = cli_args.scan(args),
        .line = command_line(env, args),
    };
    cli_args.parse(args, &parsed, &report.diag) catch return finish(&ending, &report);
    ending.options = parsed.options;
    if (run_offline(env, &parsed, &report)) |code| {
        if (code == constants.exit_ok) return code;
        return finish(&ending, &report);
    }
    var client: Client = undefined;
    Client.init(&client, env, parsed.options.server, &report) catch {
        return finish(&ending, &report);
    };
    ending.client = &client;
    ending.server = client.server_text;
    ending.record = parsed.command != .bundle;
    executor(env, &client, &parsed, ending.line, &report) catch |err| {
        if (err == error.OutOfMemory) raise_out_of_memory(&report);
        return finish(&ending, &report);
    };
    if (parsed.options.verbose and parsed.options.output != .json) write_traces(env, &client);
    return constants.exit_ok;
}

/// The commands that need no server. Null for one that does; otherwise the exit code, with the
/// reason in `report` when it is not 0.
fn run_offline(env: *const Env, parsed: *const Parsed, report: *Report) ?u8 {
    const options = parsed.options;
    const text = switch (parsed.command) {
        .help => cli_args.help_text,
        .version => std.fmt.allocPrint(env.arena, "zcube {s}\n", .{env.version}) catch {
            raise_out_of_memory(report);
            return constants.exit_environment;
        },
        .explain => |code| cli_commands.explain(env.arena, options, code, report) catch |err| {
            if (err == error.OutOfMemory) raise_out_of_memory(report);
            return constants.exit_user;
        },
        else => return null,
    };
    cli_commands.emit(env, .stdout, text, report) catch return constants.exit_environment;
    return constants.exit_ok;
}

/// The default executor: dispatches a parsed command to its implementation.
pub fn execute(
    env: *const Env,
    client: *Client,
    parsed: *const Parsed,
    line: []const u8,
    report: *Report,
) Error!void {
    const options = parsed.options;
    switch (parsed.command) {
        .apply => |file| try cli_commands.apply(env, client, options, file, report),
        .delete => |name| try cli_commands.delete(env, client, options, name, report),
        .get => |what| {
            if (what.name) |name| report.subject = .{ .kind = .service, .name = name };
            const listing = what.listing;
            const out = try cli_get.run(env.arena, client, options, listing, what.name, report);
            try cli_commands.emit(env, .stdout, out, report);
        },
        .why => |subject| {
            const out = try cli_commands.why(env, client, options, subject, report);
            try cli_commands.emit(env, .stdout, out, report);
        },
        .bundle => |target| {
            const out = try bundle_collect.run(env, client, options, target, line, report);
            try cli_commands.emit(env, .stdout, out, report);
        },
        .accept_rollback => try cli_commands.accept_rollback(env, client, options, report),
        .help, .version, .explain => unreachable, // Handled before a client exists.
    }
}

fn command_line(env: *const Env, args: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(env.arena, "zcube") catch return "zcube";
    for (args) |arg| {
        out.append(env.arena, ' ') catch return "zcube";
        out.appendSlice(env.arena, arg) catch return "zcube";
    }
    return out.items;
}

fn raise_out_of_memory(report: *Report) void {
    if (report.diag.code != null) return; // The first reason stands.
    report.diag.raise(.E0120);
    report.diag.while_("running the command", .{});
    report.diag.cause("a request for memory was refused", .{});
    report.diag.fix(.{
        .sentence = "ask for less (one service by name), or free memory, then check the state:",
        .command = "zcube get service",
    });
}

/// A command failed and said nothing: that is a bug in the command, and it is shown as one.
fn raise_no_reason(report: *Report, line: []const u8) void {
    assert(report.diag.code == null);
    report.diag.raise(.B0002);
    report.diag.while_("running {s}", .{line});
    report.diag.cause("a step failed and did not say why", .{});
}

/// Renders the failure, writes what a failure leaves behind and returns the exit code.
fn finish(ending: *const Ending, report: *Report) u8 {
    const env = ending.env;
    if (!report.failed()) raise_no_reason(report, ending.line);
    report.seal();
    assert(report.count > 0);
    if (report.has_bug()) {
        bundle_collect.automatic(env, ending.client, report, ending.line, ending.server);
    }
    if (ending.record) bundle_collect.record_failure(env, report, ending.line, ending.server);
    const options = ending.options;
    if (options.verbose and options.output != .json) {
        if (ending.client) |client| write_traces(env, client);
    }
    const mode: cli_report.Mode = if (options.output == .json)
        .json
    else if (options.verbose)
        .verbose
    else
        .text;
    _ = cli_report.render_all(report, mode, env.colour(), env.stderr);
    return report.exit_code();
}

/// `--verbose`: every request made, with the id the server answered under.
fn write_traces(env: *const Env, client: *const Client) void {
    for (client.trace_lines()) |trace| {
        env.stderr.print("request  {s}  {s}  {d}\n", .{
            trace.id.slice(), trace.line.slice(), trace.status,
        }) catch return;
    }
    if (client.trace_dropped > 0) {
        env.stderr.print("request  ({d} more not shown)\n", .{client.trace_dropped}) catch return;
    }
    env.stderr.flush() catch return;
}
