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

pub const images_default = "fixtures/images.zon";

pub const usage =
    \\usage: zcube-agent [--config FILE] [--node NAME] [--server HOST:PORT] [--state-dir DIR]
    \\                   [--cpu-millis N] [--memory-bytes N] [--images FILE] [--address TEXT]
    \\                   [--images-dir DIR] [--peer-listen HOST:PORT] [--peer-advertise HOST:PORT]
    \\                   [--registry HOST:PORT] [--runtime fake|zigbox] [--verbose]
    \\       zcube-agent --version | --help
    \\
    \\  --config FILE      a ZON file with .node, .server, .state_dir, .cpu_millis, .memory_bytes,
    \\                     .runtime, .images, .address, .images_dir, .peer_listen, .peer_advertise
    \\                     and .registry
    \\  --node NAME        this node's name (a lowercase hostname label)
    \\  --server ADDR      zcube-server's address, an IP address and a port
    \\  --state-dir DIR    where the agent keeps its containers (created if missing)
    \\  --cpu-millis N     the CPU this node offers, in millicores
    \\  --memory-bytes N   the memory this node offers, in bytes
    \\  --runtime NAME     fake (the default) or zigbox, real containers (docs/agent.md)
    \\  --images FILE      fake: the image digests it has (default fixtures/images.zon);
    \\                     zigbox (deprecated): each digest with the reference to pull it
    \\                     from, for a service that names no `source`
    \\  --address TEXT     recorded with the node for people to read; it is not used to connect
    \\  --images-dir DIR   the node's chunk store; an image the node lacks is fetched into it
    \\  --peer-listen ADDR serve the chunk store to peers (needs --images-dir)
    \\  --peer-advertise ADDR  the address peers connect to, published with the node; needed when
    \\                     --peer-listen is 0.0.0.0 or :: (default: the --peer-listen address)
    \\  --registry ADDR    fake runtime: where an image the node lacks is fetched from when no
    \\                     peer has it (needs --images-dir)
    \\  --verbose          show the internal message of a bug
    \\
    \\Containers run as plain host processes under supervisors of their own, so stopping the agent
    \\leaves them running; start it again with the same --state-dir and it adopts them.
    \\
;

/// Which `Runtime` the agent runs containers with.
pub const Kind = enum { fake, zigbox };

/// An image the Zigbox runtime can pull: the tree digest a service names, and where it is.
pub const Pull = struct { digest: []const u8, reference: []const u8 };

pub const Config = struct {
    runtime: Kind,
    /// For `zigbox`: where each image can be pulled from (`--images`, the reference form).
    pulls: []const Pull,
    node: []const u8,
    server: IpAddress,
    /// An absolute path, created if it was missing.
    state_dir: []const u8,
    images: []const []const u8,
    capacity: records.Requests,
    address: []const u8,
    verbose: bool,
    /// The chunk store (`dir_images.zig`); null: the agent keeps no chunks of its own.
    images_dir: ?[]const u8 = null,
    /// Where the peer server listens; null: none runs. Needs `images_dir`.
    peer_listen: ?IpAddress = null,
    /// The address published for peers (`/node-store/<node>.peer`): `--peer-advertise`, else the
    /// listen address when that names one host. Set exactly when `peer_listen` is.
    peer_advertise: ?IpAddress = null,
    /// The registry an image the node lacks is fetched from (`zcube-agent fetch`), as typed.
    registry: ?[]const u8 = null,
};

pub const Command = union(enum) {
    run: Config,
    /// `zcube-agent supervise <directory>`.
    supervise: []const u8,
    /// `zcube-agent supervise-zigbox <launch directory>` (`zigbox_supervisor.zig`).
    supervise_zigbox: []const u8,
    /// `zcube-agent fetch ...` (`fetch_cli.zig`): the arguments after `fetch`.
    fetch: []const []const u8,
    version,
    help,
};

pub const Error = error{ BadConfig, OutOfMemory };

/// What a ZON file may set. Unknown fields are refused.
const File = struct {
    runtime: ?Kind = null,
    node: ?[]const u8 = null,
    server: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    images: ?[]const u8 = null,
    address: ?[]const u8 = null,
    images_dir: ?[]const u8 = null,
    peer_listen: ?[]const u8 = null,
    peer_advertise: ?[]const u8 = null,
    registry: ?[]const u8 = null,
};

/// The fixtures file: the digests the fake runtime has.
const Fixtures = struct { images: []const []const u8 };
/// The same file for the Zigbox runtime: each digest with the reference to pull it from.
const PullFile = struct { images: []const Pull };

/// The flags as typed, before they are merged over the file.
const Flags = struct {
    runtime: ?Kind = null,
    config: ?[]const u8 = null,
    node: ?[]const u8 = null,
    server: ?[]const u8 = null,
    state_dir: ?[]const u8 = null,
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    images: ?[]const u8 = null,
    address: ?[]const u8 = null,
    images_dir: ?[]const u8 = null,
    peer_listen: ?[]const u8 = null,
    peer_advertise: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    verbose: bool = false,
    version: bool = false,
    help: bool = false,
};

/// Reads the flags and the files they name, merges them (flags win) and checks every setting.
/// Strings in the result live in `arena`.
pub fn load(arena: Allocator, io: std.Io, args: []const []const u8, diag: *Diag) Error!Command {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "fetch")) return .{ .fetch = args[1..] };
    if (args.len >= 1) {
        const zigbox_mode = std.mem.eql(u8, args[0], "supervise-zigbox");
        if (zigbox_mode or std.mem.eql(u8, args[0], "supervise")) {
            if (args.len != 2) return bad(
                diag,
                "supervise takes one directory",
                .{},
                "it is run by the agent itself",
            );
            if (zigbox_mode) return .{ .supervise_zigbox = args[1] };
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
    const address = flags.address orelse file.address orelse "";
    if (address.len > constants.listen_bytes_max) {
        return bad(diag, "the address text is longer than 128 bytes", .{}, "shorten it");
    }
    const images_dir = flags.images_dir orelse file.images_dir;
    const listen_text = flags.peer_listen orelse file.peer_listen;
    if (listen_text != null and images_dir == null) {
        return bad(diag, "--peer-listen has no chunk store to serve", .{}, "give --images-dir DIR");
    }
    const peer_listen = if (listen_text) |text| try parse_server(text, diag) else null;
    const advertise_text = flags.peer_advertise orelse file.peer_advertise;
    const peer_advertise = try peer_advertised(peer_listen, advertise_text, diag);
    const registry = flags.registry orelse file.registry;
    if (registry) |text| {
        if (images_dir == null) {
            const what = "--registry has no chunk store to fetch into";
            return bad(diag, what, .{}, "give --images-dir DIR");
        }
        _ = try parse_server(text, diag);
    }
    const kind = flags.runtime orelse file.runtime orelse .fake;
    const images_given = flags.images orelse file.images;
    const images_path = images_given orelse images_default;
    const pulls_wanted = kind == .zigbox and images_given != null;
    return .{
        .runtime = kind,
        .pulls = if (pulls_wanted) try read_pulls(arena, io, images_path, diag) else &.{},
        .node = node,
        .server = try parse_server(server_text, diag),
        .state_dir = try absolute_state_dir(arena, io, state_text, diag),
        .images = if (kind == .fake) try read_images(arena, io, images_path, diag) else &.{},
        .capacity = .{ .cpu_millis = cpu, .memory_bytes = memory },
        .address = address,
        .verbose = flags.verbose,
        .images_dir = images_dir,
        .peer_listen = peer_listen,
        .peer_advertise = peer_advertise,
        .registry = registry,
    };
}

/// The address to publish for peers: the advertised one, else the listen address if it names a
/// host. Listening on every address (0.0.0.0, ::) with nothing to advertise is refused: the
/// published address would be one no peer can connect to.
fn peer_advertised(listen: ?IpAddress, text: ?[]const u8, diag: *Diag) Error!?IpAddress {
    const listening = listen orelse {
        if (text == null) return null;
        const why = "--peer-advertise has no peer server to advertise";
        return bad(diag, why, .{}, "give --peer-listen");
    };
    if (text) |given| return try parse_server(given, diag);
    if (is_unspecified(listening)) {
        return bad(
            diag,
            "--peer-listen is {f}, an address no peer can connect to, and nothing is advertised",
            .{listening},
            "give --peer-advertise HOST:PORT, the address peers reach this node on",
        );
    }
    return listening;
}

fn is_unspecified(address: IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| std.mem.allEqual(u8, &ip4.bytes, 0),
        .ip6 => |ip6| std.mem.allEqual(u8, &ip6.bytes, 0),
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
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            flags.runtime = try kind_of(try value_of(args, &index, diag), diag);
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
        } else if (std.mem.eql(u8, arg, "--images-dir")) {
            flags.images_dir = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--peer-listen")) {
            flags.peer_listen = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--peer-advertise")) {
            flags.peer_advertise = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--registry")) {
            flags.registry = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--cpu-millis")) {
            flags.cpu_millis = try number_of(u32, args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--memory-bytes")) {
            flags.memory_bytes = try number_of(u64, args, &index, diag);
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

fn kind_of(text: []const u8, diag: *Diag) Error!Kind {
    return std.meta.stringToEnum(Kind, text) orelse
        bad(diag, "the runtime {s} is not one the agent has", .{text}, "use fake or zigbox");
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

/// The images file in the reference form, for the Zigbox runtime.
fn read_pulls(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error![]const Pull {
    const source = try read_zon(arena, io, path, diag);
    return parse_pulls(arena, source, path, diag);
}

pub fn parse_pulls(
    arena: Allocator,
    source: [:0]const u8,
    path: []const u8,
    diag: *Diag,
) Error![]const Pull {
    var zon_diag: std.zon.parse.Diagnostics = undefined;
    const file = std.zon.parse.fromSlice(PullFile, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &zon_diag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return bad(
            diag,
            "{s} is not a list of .{{ .digest, .reference }} images",
            .{path},
            "give each image its digest and the reference to pull it from",
        ),
    };
    if (file.images.len > constants.fixture_images_max) {
        return bad(diag, "{s} lists more than 64 images", .{path}, "trim it");
    }
    const problem = "{s} has an image whose digest or reference is empty or too long";
    for (file.images) |pull| {
        const empty = pull.digest.len == 0 or pull.reference.len == 0;
        const long = pull.digest.len > constants.image_digest_bytes_max;
        if (empty or long) return bad(diag, problem, .{path}, "fix it");
    }
    return file.images;
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
    // Goal: precedence and strictness. Method: a file that sets a node, flags that
    // set the CPU, a stray flag, a flag without its value, a typo in the file.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const file = try parse_file(
        arena,
        ".{ .node = \"node7\", .cpu_millis = 3000 }",
        "agent.zon",
        &diag,
    );
    try testing.expectEqualStrings("node7", file.node.?);
    const flags = try parse_flags(
        &.{ "-v", "--cpu-millis", "250" },
        &diag,
    );
    try testing.expectEqual(@as(?u32, 3000), file.cpu_millis);
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

test "the runtime is fake unless asked, and the zigbox images carry their references" {
    // Goal: a node that says nothing runs the fake runtime (the default is pinned); --runtime
    // zigbox is read, a stranger refused; the reference form lists digest and reference.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(@as(?Kind, null), (try parse_flags(&.{}, &diag)).runtime);
    const flags = try parse_flags(&.{ "--runtime", "zigbox" }, &diag);
    try testing.expectEqual(Kind.zigbox, flags.runtime.?);
    const file = try parse_file(arena, ".{ .runtime = .zigbox }", "agent.zon", &diag);
    try testing.expectEqual(Kind.zigbox, file.runtime.?);
    diag.reset();
    try expect_bad(parse_flags(&.{ "--runtime", "docker" }, &diag), &diag);

    const pulls = try parse_pulls(
        arena,
        ".{ .images = .{ .{ .digest = \"b3:aa\", .reference = \"ghcr.io/o/r@sha256:00\" } } }",
        "images.zon",
        &diag,
    );
    try testing.expectEqual(@as(usize, 1), pulls.len);
    try testing.expectEqualStrings("ghcr.io/o/r@sha256:00", pulls[0].reference);
    diag.reset();
    try expect_bad(parse_pulls(arena, ".{ .images = .{ \"b3:aa\" } }", "i.zon", &diag), &diag);
    diag.reset();
    const empty = ".{ .images = .{ .{ .digest = \"b3:aa\", .reference = \"\" } } }";
    try expect_bad(parse_pulls(arena, empty, "i.zon", &diag), &diag);
}

test "the chunk store and the peer address are read, and a peer address needs a store" {
    // Goal: --images-dir and --peer-listen reach the Config; serving peers without a store to
    // serve from is a bad configuration. Method: load with both, then with the address alone.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const base = [_][]const u8{
        "--node",         "node1",   "--server",     "127.0.0.1:7070",
        "--state-dir",    "/tmp",    "--cpu-millis", "1000",
        "--memory-bytes", "1000000", "--images",     "fixtures/images.zon",
    };
    const extra = [_][]const u8{ "--images-dir", "/tmp/i", "--peer-listen", "127.0.0.1:7171" };
    const both = base ++ extra;
    const loaded = try load(arena, std.testing.io, &both, &diag);
    try testing.expectEqualStrings("/tmp/i", loaded.run.images_dir.?);
    try testing.expectEqual(@as(u16, 7171), loaded.run.peer_listen.?.getPort());
    const with_registry = both ++ [_][]const u8{ "--registry", "127.0.0.1:9000" };
    diag.reset();
    const fetching = try load(arena, std.testing.io, &with_registry, &diag);
    try testing.expectEqualStrings("127.0.0.1:9000", fetching.run.registry.?);
    const no_store = base ++ [_][]const u8{ "--registry", "127.0.0.1:9000" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &no_store, &diag), &diag);
    const alone = base ++ [_][]const u8{ "--peer-listen", "127.0.0.1:7171" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &alone, &diag), &diag);
}

test "the published peer address is the advertised one, or a specified listen address" {
    // Goal: M2 of the final re-review. Method: listen on a host (published as is), on 0.0.0.0 and
    // :: with and without --peer-advertise, and advertise without a server.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const base = [_][]const u8{
        "--node",         "node1",   "--server",     "127.0.0.1:7070",
        "--state-dir",    "/tmp",    "--cpu-millis", "1000",
        "--memory-bytes", "1000000", "--images",     "fixtures/images.zon",
        "--images-dir",   "/tmp/i",
    };
    const host = base ++ [_][]const u8{ "--peer-listen", "127.0.0.1:7171" };
    const plain = try load(arena, std.testing.io, &host, &diag);
    try testing.expectEqual(@as(u16, 7171), plain.run.peer_advertise.?.getPort());
    try testing.expect(plain.run.peer_advertise.?.eql(&plain.run.peer_listen.?));
    const wild = base ++ [_][]const u8{ "--peer-listen", "0.0.0.0:7700" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &wild, &diag), &diag);
    const wild6 = base ++ [_][]const u8{ "--peer-listen", "[::]:7700" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &wild6, &diag), &diag);
    const told = wild ++ [_][]const u8{ "--peer-advertise", "10.0.2.2:7701" };
    diag.reset();
    const split = try load(arena, std.testing.io, &told, &diag);
    try testing.expectEqual(@as(u16, 7700), split.run.peer_listen.?.getPort());
    try testing.expectEqual(@as(u16, 7701), split.run.peer_advertise.?.getPort());
    const lone = base ++ [_][]const u8{ "--peer-advertise", "10.0.2.2:7701" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &lone, &diag), &diag);
    const junk = host ++ [_][]const u8{ "--peer-advertise", "node1:7701" };
    diag.reset();
    try expect_bad(load(arena, std.testing.io, &junk, &diag), &diag);
}
