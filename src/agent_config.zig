//! `zcube-agent`'s configuration: a small ZON file and flags, flags winning. Shell code: it reads
//! files. A setting it cannot use is ZC-E0505 and names the setting, as for the server, so a typo
//! never becomes an agent that quietly does something else. The node's capacity is declared here
//! (HANDOFF's provisional answer: declared in the agent's configuration).
//!
//! ```zig
//! .{
//!     .node = "node1",
//!     .server = "127.0.0.1:7070",
//!     .state_dir = "/var/lib/zcube-agent",
//!     .cpu_millis = 4000,
//!     .memory_bytes = 8589934592,
//!     .images = "fixtures/images.zon", // the digests the fake runtime has; the default
//!     .address = "", // what to record in /nodes/<node>, for people to read
//!     .lease_ttl_ms = 10000,
//! }
//! ```
//!
//! `zcube-agent supervise <container directory>` is the supervisor mode (`fake_supervisor.zig`),
//! used only by the agent itself.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const IpAddress = std.Io.net.IpAddress;

const ttl_fix = "choose a time inside the range";

pub const images_default = "fixtures/images.zon";

pub const usage =
    \\usage: zcube-agent [--config FILE] [--node NAME] [--server HOST:PORT] [--state-dir DIR]
    \\                   [--cpu-millis N] [--memory-bytes N] [--images FILE] [--address TEXT]
    \\                   [--lease-ttl-ms N] [--verbose]
    \\       zcube-agent --version | --help
    \\
    \\  --config FILE      a ZON file with .node, .server, .state_dir, .cpu_millis, .memory_bytes,
    \\                     .images, .address and .lease_ttl_ms
    \\  --node NAME        this node's name (a lowercase hostname label)
    \\  --server ADDR      zcube-server's address, an IP address and a port
    \\  --state-dir DIR    where the agent keeps its containers (created if missing)
    \\  --cpu-millis N     the CPU this node offers, in millicores
    \\  --memory-bytes N   the memory this node offers, in bytes
    \\  --images FILE      the image digests the fake runtime has (default fixtures/images.zon)
    \\  --address TEXT     recorded with the node for people to read
    \\  --lease-ttl-ms N   how long the node's lease lasts without renewal (default 10000)
    \\  --verbose          show the internal message of a bug
    \\
    \\Containers run as plain host processes under supervisors of their own, so stopping the agent
    \\leaves them running; start it again with the same --state-dir and it adopts them.
    \\
;

pub const Config = struct {
    node: []const u8,
    server: IpAddress,
    /// An absolute path, created if it was missing.
    state_dir: []const u8,
    images: []const []const u8,
    capacity: records.Requests,
    address: []const u8,
    lease_ttl_ms: u32,
    verbose: bool,
};

pub const Command = union(enum) {
    run: Config,
    /// `zcube-agent supervise <directory>`.
    supervise: []const u8,
    version,
    help,
};

pub const Error = error{ BadConfig, OutOfMemory };

/// What a ZON file may set. Unknown fields are refused.
const File = struct {
    node: ?[]const u8 = null,
    server: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    images: ?[]const u8 = null,
    address: ?[]const u8 = null,
    lease_ttl_ms: ?u32 = null,
};

/// The fixtures file: the digests the fake runtime has.
const Fixtures = struct { images: []const []const u8 };

/// The flags as typed, before they are merged over the file.
const Flags = struct {
    config: ?[]const u8 = null,
    node: ?[]const u8 = null,
    server: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    images: ?[]const u8 = null,
    address: ?[]const u8 = null,
    lease_ttl_ms: ?u32 = null,
    verbose: bool = false,
    version: bool = false,
    help: bool = false,
};

/// Reads the flags and the files they name, merges them (flags win) and checks every setting.
/// Strings in the result live in `arena`.
pub fn load(arena: Allocator, io: std.Io, args: []const []const u8, diag: *Diag) Error!Command {
    if (args.len >= 1) {
        if (std.mem.eql(u8, args[0], "supervise")) {
            if (args.len != 2) return bad(
                diag,
                "supervise takes one directory",
                .{},
                "it is run by the agent itself",
            );
            return .{ .supervise = args[1] };
        }
    }
    if (args.len > constants.agent_args_max) {
        return bad(diag, "there are more than 64 arguments", .{}, "run it with --help");
    }
    const flags = try parse_flags(args, diag);
    if (flags.version) return .version;
    if (flags.help) return .help;
    var file: File = .{};
    if (flags.config) |path| file = try read_file(arena, io, path, diag);
    return .{ .run = try merge(arena, io, flags, file, diag) };
}

fn merge(arena: Allocator, io: std.Io, flags: Flags, file: File, diag: *Diag) Error!Config {
    const node = flags.node orelse file.node orelse
        return bad(diag, "the node has no name", .{}, "give --node, or .node in the file");
    if (records.name_problem(node, constants.node_name_bytes_max) != null) {
        return bad(
            diag,
            "the node name {s} is not a lowercase hostname label",
            .{node},
            "use letters, digits and '-', at most 63",
        );
    }
    const server_text = flags.server orelse file.server orelse
        return bad(
            diag,
            "the agent does not know where the server is",
            .{},
            "give --server HOST:PORT",
        );
    const state_text = flags.state_dir orelse file.state_dir orelse
        return bad(diag, "the agent has no state directory", .{}, "give --state-dir DIR");
    const cpu = flags.cpu_millis orelse file.cpu_millis orelse
        return bad(diag, "the node's CPU is not declared", .{}, "give --cpu-millis N, e.g. 4000");
    const memory = flags.memory_bytes orelse file.memory_bytes orelse
        return bad(diag, "the node's memory is not declared", .{}, "give --memory-bytes N");
    const empty = "declare what the node offers";
    if (cpu == 0) return bad(diag, "the node's CPU must be above 0", .{}, empty);
    if (memory == 0) return bad(diag, "the node's memory must be above 0", .{}, empty);
    const ttl = flags.lease_ttl_ms orelse file.lease_ttl_ms orelse constants.node_lease_ttl_ms;
    const range = "the lease time {d} ms is outside 100 to 3600000";
    if (ttl < constants.lease_ttl_ms_min) return bad(diag, range, .{ttl}, ttl_fix);
    if (ttl > constants.lease_ttl_ms_max) return bad(diag, range, .{ttl}, ttl_fix);
    const address = flags.address orelse file.address orelse "";
    if (address.len > constants.listen_bytes_max) {
        return bad(diag, "the address text is longer than 128 bytes", .{}, "shorten it");
    }
    const images_path = flags.images orelse file.images orelse images_default;
    return .{
        .node = node,
        .server = try parse_server(server_text, diag),
        .state_dir = try absolute_state_dir(arena, io, state_text, diag),
        .images = try read_images(arena, io, images_path, diag),
        .capacity = .{ .cpu_millis = cpu, .memory_bytes = memory },
        .address = address,
        .lease_ttl_ms = ttl,
        .verbose = flags.verbose,
    };
}

// ---- Flags -------------------------------------------------------------------------------------

pub fn parse_flags(args: []const []const u8, diag: *Diag) Error!Flags {
    var flags: Flags = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (is_flag(arg, "--verbose", "-v")) {
            flags.verbose = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            flags.version = true;
        } else if (is_flag(arg, "--help", "-h")) {
            flags.help = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            flags.config = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--node")) {
            flags.node = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--server")) {
            flags.server = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            flags.state_dir = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--images")) {
            flags.images = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--address")) {
            flags.address = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--cpu-millis")) {
            flags.cpu_millis = try number_of(u32, args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--memory-bytes")) {
            flags.memory_bytes = try number_of(u64, args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            flags.lease_ttl_ms = try number_of(u32, args, &index, diag);
        } else {
            return bad(
                diag,
                "the flag {s} is not one zcube-agent has",
                .{arg},
                "run it with --help",
            );
        }
    }
    return flags;
}

fn is_flag(arg: []const u8, long: []const u8, short: []const u8) bool {
    if (std.mem.eql(u8, arg, long)) return true;
    return std.mem.eql(u8, arg, short);
}

fn value_of(args: []const []const u8, index: *usize, diag: *Diag) Error![]const u8 {
    const flag = args[index.*];
    if (index.* + 1 >= args.len) {
        return bad(diag, "{s} needs a value", .{flag}, "run it with --help");
    }
    index.* += 1;
    const value = args[index.*];
    if (value.len > constants.agent_arg_bytes_max) {
        return bad(diag, "the value of {s} is longer than 4096 bytes", .{flag}, "shorten it");
    }
    return value;
}

fn number_of(comptime T: type, args: []const []const u8, index: *usize, diag: *Diag) Error!T {
    const flag = args[index.*];
    const text = try value_of(args, index, diag);
    return std.fmt.parseInt(T, text, 10) catch
        bad(diag, "the value of {s} is not a number", .{flag}, "give a whole number");
}

// ---- Files -------------------------------------------------------------------------------------

fn read_zon(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error![:0]const u8 {
    if (path.len > constants.config_path_bytes_max) {
        return bad(diag, "a file name is longer than 1024 bytes", .{}, "shorten it");
    }
    const limit: std.Io.Limit = .limited(constants.config_bytes_max);
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, limit, .of(u8), 0) catch |err|
        switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => bad(diag, "{s} is larger than 16384 bytes", .{path}, "trim it"),
            else => bad(
                diag,
                "can't read {s}",
                .{path},
                "check that the file exists and is readable",
            ),
        };
}

fn read_file(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error!File {
    const source = try read_zon(arena, io, path, diag);
    return parse_file(arena, source, path, diag);
}

pub fn parse_file(
    arena: Allocator,
    source: [:0]const u8,
    name: []const u8,
    diag: *Diag,
) Error!File {
    var zon_diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(File, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &zon_diag,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseZon => bad(
            diag,
            "{s} is not a valid agent configuration",
            .{name},
            "see zcube-agent --help for the settings",
        ),
    };
}

/// The digests in the fixtures file.
fn read_images(
    arena: Allocator,
    io: std.Io,
    path: []const u8,
    diag: *Diag,
) Error![]const []const u8 {
    const limit: std.Io.Limit = .limited(constants.fixtures_bytes_max);
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        limit,
        .of(u8),
        0,
    ) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return bad(
                diag,
                "{s} is larger than 16384 bytes",
                .{path},
                "trim it",
            ),
            else => return bad(
                diag,
                "can't read the image fixtures {s}",
                .{path},
                "run from the repository root, or give --images FILE",
            ),
        };
    return parse_images(arena, source, path, diag);
}

pub fn parse_images(
    arena: Allocator,
    source: [:0]const u8,
    name: []const u8,
    diag: *Diag,
) Error![]const []const u8 {
    var zon_diag: std.zon.parse.Diagnostics = undefined;
    const fixtures = std.zon.parse.fromSlice(Fixtures, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &zon_diag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return bad(
            diag,
            "{s} is not a list of image digests (.images)",
            .{name},
            "see fixtures/images.zon",
        ),
    };
    if (fixtures.images.len > constants.fixture_images_max) {
        return bad(diag, "{s} lists more than 64 digests", .{name}, "trim it");
    }
    for (fixtures.images) |digest| {
        const problem = "{s} has a digest that is empty or longer than 67 bytes";
        if (digest.len == 0) return bad(diag, problem, .{name}, "fix the digest");
        if (digest.len > constants.image_digest_bytes_max) {
            return bad(diag, problem, .{name}, "fix the digest");
        }
    }
    return fixtures.images;
}

// ---- Settings ----------------------------------------------------------------------------------

/// "127.0.0.1:7070" or "[::1]:7070": an IP address and a port. A name is refused, as for the
/// server, because resolving one could quietly choose another interface than the user meant.
pub fn parse_server(text: []const u8, diag: *Diag) Error!IpAddress {
    const reason = "use an IP address and a port, like 127.0.0.1:7070";
    const length = "the server address is empty or longer than 128 bytes";
    if (text.len == 0) return bad(diag, length, .{}, reason);
    if (text.len > constants.listen_bytes_max) return bad(diag, length, .{}, reason);
    const colon = std.mem.findScalarLast(u8, text, ':') orelse
        return bad(diag, "the server address {s} has no port", .{text}, reason);
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch
        return bad(diag, "the port in {s} is not a number from 0 to 65535", .{text}, reason);
    if (port == 0) return bad(diag, "the server address {s} has port 0", .{text}, reason);
    var host = text[0..colon];
    if (host.len >= 2) {
        if (host[0] == '[') {
            if (host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        }
    }
    return IpAddress.parse(host, port) catch
        bad(diag, "{s} is not an IP address", .{host}, reason);
}

/// The state directory as an absolute path, created if it is missing.
fn absolute_state_dir(
    arena: Allocator,
    io: std.Io,
    text: []const u8,
    diag: *Diag,
) Error![]const u8 {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, text) catch
        return bad(
            diag,
            "can't create the state directory {s}",
            .{text},
            "create it, or choose another with --state-dir",
        );
    var buffer: [constants.state_path_bytes_max]u8 = undefined;
    const length = cwd.realPathFile(io, text, &buffer) catch
        return bad(
            diag,
            "can't resolve the state directory {s}",
            .{text},
            "choose another with --state-dir",
        );
    return arena.dupe(u8, buffer[0..length]) catch error.OutOfMemory;
}

fn bad(diag: *Diag, comptime cause: []const u8, args: anytype, fix: []const u8) Error {
    assert(diag.code == null);
    diag.raise(.E0505);
    diag.cause(cause, args);
    diag.fix(.{ .sentence = fix });
    return error.BadConfig;
}

const testing = std.testing;

fn expect_bad(result: anytype, diag: *const Diag) !void {
    try testing.expectError(error.BadConfig, result);
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0505), diag.code);
}

test "the server address is an IP address and a port, and nothing else" {
    // Goal: every way an address can be wrong is E0505 naming the setting. Method: good IPv4 and
    // IPv6 forms, then a name, no port, a big port, port 0, an empty host.
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(@as(u16, 7070), (try parse_server("127.0.0.1:7070", &diag)).getPort());
    try testing.expectEqual(@as(u16, 9), (try parse_server("[::1]:9", &diag)).getPort());
    const inputs = [_][]const u8{
        "localhost:7070", "127.0.0.1", "127.0.0.1:70000", "127.0.0.1:0", ":7070", "",
    };
    for (inputs) |input| {
        diag.reset();
        try expect_bad(parse_server(input, &diag), &diag);
    }
}

test "flags win over the file; unknown flags and settings are refused" {
    // Goal: precedence and strictness. Method: a file that sets a node and a ttl, flags that
    // override the ttl, a stray flag, a flag without its value, a typo in the file.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const file = try parse_file(
        arena,
        ".{ .node = \"node7\", .lease_ttl_ms = 3000 }",
        "agent.zon",
        &diag,
    );
    try testing.expectEqualStrings("node7", file.node.?);
    const flags = try parse_flags(
        &.{ "--lease-ttl-ms", "4000", "-v", "--cpu-millis", "250" },
        &diag,
    );
    try testing.expectEqual(@as(?u32, 4000), flags.lease_ttl_ms);
    try testing.expect(flags.verbose);
    try testing.expectEqual(@as(?u32, 250), flags.cpu_millis);

    diag.reset();
    try expect_bad(parse_flags(&.{"--bogus"}, &diag), &diag);
    diag.reset();
    try expect_bad(parse_flags(&.{"--node"}, &diag), &diag);
    diag.reset();
    try expect_bad(parse_flags(&.{ "--cpu-millis", "many" }, &diag), &diag);
    diag.reset();
    try expect_bad(parse_file(arena, ".{ .nodee = \"x\" }", "agent.zon", &diag), &diag);
    diag.reset();
    try expect_bad(parse_file(arena, "not zon", "agent.zon", &diag), &diag);
}

test "the fixtures file is a list of digests of a sensible size" {
    // Goal: `fixtures/images.zon` parses and a damaged one is refused. Method: the checked-in
    // file's shape, then an empty digest, a missing field and a list that is too long.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const images = try parse_images(
        arena,
        ".{ .images = .{ \"b3:51aa9c03\", \"b3:9d20c4f1\" } }",
        "images.zon",
        &diag,
    );
    try testing.expectEqual(@as(usize, 2), images.len);
    try testing.expectEqualStrings("b3:51aa9c03", images[0]);
    diag.reset();
    try expect_bad(parse_images(arena, ".{ .images = .{ \"\" } }", "images.zon", &diag), &diag);
    diag.reset();
    try expect_bad(parse_images(arena, ".{ .pictures = .{} }", "images.zon", &diag), &diag);
}

test "supervise mode is recognised before any flag, and needs exactly one directory" {
    // Goal: the agent's re-execution cannot be confused with a run. Method: load the argument
    // lists the supervisor is started with, and wrong ones.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const command = try load(
        arena_state.allocator(),
        testing.io,
        &.{ "supervise", "/tmp/x" },
        &diag,
    );
    try testing.expectEqualStrings("/tmp/x", command.supervise);
    diag.reset();
    try expect_bad(load(arena_state.allocator(), testing.io, &.{"supervise"}, &diag), &diag);
}
