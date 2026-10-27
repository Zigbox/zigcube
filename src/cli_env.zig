//! What the command line needs from the process around it: the environment variables, the two
//! output streams, the input for a confirmation, the clock, the state directory. `zcube.zig`
//! builds the real one; the tests build one over buffers, so every command is testable without
//! a terminal. Shell code (it holds an `std.Io`), never part of the wasm core.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

/// Stands in for the network in tests: the raw HTTP reply to a request, or null for a connection
/// that could not be made. Production code never sets it.
pub const Transport = struct {
    context: *anyopaque,
    exchange: *const fn (
        context: *anyopaque,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) ?[]const u8,
};

pub const Env = struct {
    io: std.Io,
    /// Startup storage for the whole run; the command line allocates from it and never frees.
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    stdout: *Writer,
    stderr: *Writer,
    /// Where an answer to a question is read from; null when there is none.
    stdin: ?*Reader,
    stdin_is_terminal: bool,
    stderr_is_terminal: bool,
    version: []const u8,
    /// Request ids that repeat from run to run (`zc-test-1`, ...), so a snapshot of the output
    /// can be compared byte for byte. Only the tests set it.
    deterministic_ids: bool = false,
    /// How long to wait for the next piece of a reply; the tests shorten it.
    reply_timeout_ms: u32 = constants.cli_reply_timeout_ms,
    /// A clock that stands still, for the same reason. Only the tests set it.
    fixed_now_ms: ?u64 = null,
    /// A network that is not one. Only the tests set it.
    transport: ?Transport = null,

    pub fn getenv(env: *const Env, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        return env.environ.get(name);
    }

    pub fn now_ms(env: *const Env) u64 {
        if (env.fixed_now_ms) |ms| return ms;
        const ms = std.Io.Clock.real.now(env.io).toMilliseconds();
        assert(ms >= 0);
        return @intCast(ms);
    }

    /// Colour only when stderr is a terminal and `NO_COLOR` is unset (DIAGNOSTICS.md).
    pub fn colour(env: *const Env) bool {
        if (env.getenv("NO_COLOR")) |value| {
            if (value.len > 0) return false;
        }
        return env.stderr_is_terminal;
    }

    /// `$XDG_STATE_HOME/zcube`, else `$HOME/.local/state/zcube`; null if neither variable names
    /// an absolute directory. The directory may not exist yet.
    pub fn state_dir(env: *const Env, buffer: *[constants.state_path_bytes_max]u8) ?[]const u8 {
        if (env.getenv("XDG_STATE_HOME")) |base| {
            if (std.fs.path.isAbsolute(base)) return join(buffer, base, "");
        }
        if (env.getenv("HOME")) |home| {
            if (std.fs.path.isAbsolute(home)) return join(buffer, home, ".local/state");
        }
        return null;
    }

    fn join(
        buffer: *[constants.state_path_bytes_max]u8,
        base: []const u8,
        middle: []const u8,
    ) ?[]const u8 {
        const trimmed = std.mem.trimEnd(u8, base, "/");
        const separator = if (middle.len > 0) "/" else "";
        return std.fmt.bufPrint(buffer, "{s}{s}{s}/{s}", .{
            trimmed, separator, middle, constants.state_dir_name,
        }) catch null;
    }
};

const testing = std.testing;

test "the state directory follows XDG_STATE_HOME, then HOME, and wants an absolute path" {
    // Goal: where bundles go. Method: each variable alone, both, a relative one, none.
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    var sink: Writer.Discarding = .init(&.{});
    var env: Env = .{
        .io = testing.io,
        .arena = testing.allocator,
        .environ = &map,
        .stdout = &sink.writer,
        .stderr = &sink.writer,
        .stdin = null,
        .stdin_is_terminal = false,
        .stderr_is_terminal = false,
        .version = "0",
    };
    var buffer: [constants.state_path_bytes_max]u8 = undefined;
    try testing.expect(env.state_dir(&buffer) == null);
    try map.put("HOME", "relative/home");
    try testing.expect(env.state_dir(&buffer) == null);
    try map.put("HOME", "/home/alex/");
    try testing.expectEqualStrings("/home/alex/.local/state/zcube", env.state_dir(&buffer).?);
    try map.put("XDG_STATE_HOME", "/var/state");
    try testing.expectEqualStrings("/var/state/zcube", env.state_dir(&buffer).?);
    try map.put("XDG_STATE_HOME", "state");
    try testing.expectEqualStrings("/home/alex/.local/state/zcube", env.state_dir(&buffer).?);
    env.stderr_is_terminal = true;
    try testing.expect(env.colour());
    try map.put("NO_COLOR", "1");
    try testing.expect(!env.colour());
}
