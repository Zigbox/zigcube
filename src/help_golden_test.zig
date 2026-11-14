//! Golden tests of `--help` and `--version` for `zcube`, `zcube-server` and `zcube-agent`. The
//! help texts are compared byte for byte with `src/testdata/help/`, which was captured from the
//! built executables (`env -i zig-out/bin/<name> --help`); change a file there deliberately when
//! the help changes. The version line is `<name> <version>`, the version being build.zig.zon's,
//! as `zbx --version` prints it. `zig build test` also runs the three built executables with
//! an empty environment (`build.zig`, `add_help_checks`), so what a user runs is checked too.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const agent_config = @import("agent_config.zig");
const cli = @import("cli.zig");
const cli_args = @import("cli_args.zig");
const cli_env = @import("cli_env.zig");
const server_config = @import("server_config.zig");

const zcube_help = @embedFile("testdata/help/zcube.help.txt");

const Outcome = struct { exit: u8, stdout: []const u8, stderr: []const u8 };

/// Fails the test: `--help` and `--version` must never reach a server.
fn no_network(
    context: *anyopaque,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ?[]const u8 {
    const called: *bool = @ptrCast(@alignCast(context));
    assert(method.len > 0);
    assert(path.len > 0);
    _ = body;
    called.* = true;
    return null;
}

fn run_zcube(arena: std.mem.Allocator, args: []const []const u8) !Outcome {
    // An empty environment: no $ZCUBE_SERVER, no $HOME, no state directory.
    var environ: std.process.Environ.Map = .init(arena);
    var stdout: Writer.Allocating = .init(arena);
    var stderr: Writer.Allocating = .init(arena);
    var called = false;
    const env: cli_env.Env = .{
        .io = testing.io,
        .arena = arena,
        .environ = &environ,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0.0.0-test",
        .transport = .{ .context = &called, .exchange = no_network },
    };
    const exit = cli.run(&env, args);
    try testing.expect(!called);
    return .{ .exit = exit, .stdout = stdout.written(), .stderr = stderr.written() };
}

test "zcube --help and help print the checked-in text on stdout, exit 0, with no server" {
    // Goal: `zcube --help` works like the other executables' and like `zbx --help`. Method: run
    // `help`, `--help` and `--help` among options through `cli.run` with an empty environment and
    // a transport that fails the test if called; each prints the golden text and nothing else.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const lines = [_][]const []const u8{
        &.{"help"},
        &.{"--help"},
        &.{ "-v", "--help", "--server", "10.0.0.1:7070" },
    };
    for (lines) |line| {
        const outcome = try run_zcube(arena_state.allocator(), line);
        try testing.expectEqual(@as(u8, 0), outcome.exit);
        try testing.expectEqualStrings(zcube_help, outcome.stdout);
        try testing.expectEqual(@as(usize, 0), outcome.stderr.len);
    }
    try testing.expectEqualStrings(zcube_help, cli_args.help_text);
}

test "zcube --version and version print one line, exit 0, with no server" {
    // Goal: one line, `zcube <version>`, on stdout. Method: as the help test, for `version` and
    // `--version`; then `--version` with an argument is refused (ZC-E0111, exit 1, no stdout).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "version", "--version" }) |word| {
        const outcome = try run_zcube(arena, &.{word});
        try testing.expectEqual(@as(u8, 0), outcome.exit);
        try testing.expectEqualStrings("zcube 0.0.0-test\n", outcome.stdout);
        try testing.expectEqual(@as(usize, 0), outcome.stderr.len);
    }
    const refused = try run_zcube(arena, &.{ "--version", "now" });
    try testing.expectEqual(@as(u8, 1), refused.exit);
    try testing.expectEqual(@as(usize, 0), refused.stdout.len);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "ZC-E0111") != null);
    try testing.expect(std.mem.indexOf(u8, refused.stderr, "--version takes no arguments") != null);
}

test "zcube-server and zcube-agent --help print the checked-in text" {
    // Goal: the servers' help is a golden too. Method: their usage constants against the captured
    // files. That each flag parser maps `--help` and `--version` to the usage and the version
    // line is checked by running the built executables (`build.zig`, `add_help_checks`).
    try testing.expectEqualStrings(
        @embedFile("testdata/help/zcube-server.help.txt"),
        server_config.usage,
    );
    try testing.expectEqualStrings(
        @embedFile("testdata/help/zcube-agent.help.txt"),
        agent_config.usage,
    );
}
