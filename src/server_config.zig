//! `zcube-server`'s configuration: a small ZON file and flags, flags winning. Shell code: it reads
//! a file. A setting it cannot use is ZC-E0106 and names the setting, so a typo in a file or a flag
//! never turns into a server that quietly does something else.
//!
//! ```zig
//! .{
//!     .listen = "127.0.0.1:7070",
//!     .store = "sqlite:/var/lib/zcube/store.db", // or "postgres:host=db user=zcube", or "memory"
//!     .create_store = false, // true on the first start: a mistyped path is an error otherwise
//! }
//! ```

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const IpAddress = std.Io.net.IpAddress;

pub const listen_default = "127.0.0.1:7070";

pub const usage =
    \\usage: zcube-server [--config FILE] [--listen HOST:PORT] [--store SPEC] [--create-store]
    \\                    [--verbose] [--quiet]
    \\       zcube-server --version | --help
    \\
    \\  --config FILE     a ZON file with .listen, .store and .create_store
    \\  --listen ADDR     where to listen, an IP address and a port (default 127.0.0.1:7070)
    \\  --store SPEC      memory | sqlite:<path> | postgres:<libpq settings> (default memory)
    \\  --state-dir DIR   where to remember the highest store revision seen (default: beside the
    \\                    SQLite file, else ./zcube-state); keep it outside the store
    \\  --create-store    create the store's file or schema if it is not there
    \\  --verbose         show the internal message of a bug, and every request
    \\  --quiet           log only failures
    \\
    \\Writes to the API are unauthenticated: listen on a loopback or private address.
    \\
;

pub const Store = union(enum) {
    memory,
    sqlite: []const u8,
    postgres: []const u8,

    pub fn backend(store: Store) []const u8 {
        return @tagName(store);
    }
};

pub const Config = struct {
    listen: IpAddress,
    store: Store,
    create_store: bool,
    /// Where the remembered revision is kept; null: beside the SQLite file, else `zcube-state`.
    state_dir: ?[]const u8 = null,
    verbose: bool,
    quiet: bool,
};

pub const Command = union(enum) { run: Config, version, help };

/// What a ZON file may set. Unknown fields are refused.
const File = struct {
    listen: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: ?bool = null,
    state_dir: ?[]const u8 = null,
};

/// The flags as typed, before they are merged over the file.
const Flags = struct {
    config: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: bool = false,
    state_dir: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    version: bool = false,
    help: bool = false,
};

pub const Error = error{ BadConfig, OutOfMemory };

/// Reads the flags and the file they name, merges them (flags win), and checks every setting.
/// Strings in the result live in `arena`.
pub fn load(arena: Allocator, io: std.Io, args: []const []const u8, diag: *Diag) Error!Command {
    const flags = try parse_flags(args, diag);
    if (flags.version) return .version;
    if (flags.help) return .help;
    var file: File = .{};
    if (flags.config) |path| file = try read_file(arena, io, path, diag);
    return .{ .run = try merge(flags, file, diag) };
}

fn merge(flags: Flags, file: File, diag: *Diag) Error!Config {
    const listen_text = flags.listen orelse file.listen orelse listen_default;
    const store_text = flags.store orelse file.store orelse "memory";
    return .{
        .listen = try parse_listen(listen_text, diag),
        .store = try parse_store(store_text, diag),
        .create_store = if (flags.create_store) true else (file.create_store orelse false),
        .state_dir = flags.state_dir orelse file.state_dir,
        .verbose = flags.verbose,
        .quiet = flags.quiet,
    };
}

// ---- Flags -------------------------------------------------------------------------------------

pub fn parse_flags(args: []const []const u8, diag: *Diag) Error!Flags {
    var flags: Flags = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--create-store")) {
            flags.create_store = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            flags.verbose = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            flags.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            flags.quiet = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            flags.version = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            flags.help = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            flags.help = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            flags.config = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--listen")) {
            flags.listen = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--store")) {
            flags.store = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            flags.state_dir = try value_of(args, &index, diag);
        } else {
            const problem = "the flag {s} is not one zcube-server has";
            return bad(diag, problem, .{arg}, "run it with --help");
        }
    }
    return flags;
}

fn value_of(args: []const []const u8, index: *usize, diag: *Diag) Error![]const u8 {
    const flag = args[index.*];
    if (index.* + 1 >= args.len) {
        return bad(diag, "{s} needs a value", .{flag}, "run it with --help");
    }
    index.* += 1;
    return args[index.*];
}

// ---- The file -----------------------------------------------------------------------------------

fn read_file(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error!File {
    if (path.len > constants.config_path_bytes_max) {
        return bad(diag, "the --config path is longer than 1024 bytes", .{}, "shorten it");
    }
    const limit: std.Io.Limit = .limited(constants.config_bytes_max);
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        limit,
        .of(u8),
        0,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => bad(diag, "{s} is larger than 16384 bytes", .{path}, "trim it"),
        else => bad(diag, "can't read {s}", .{path}, "check that the file exists and is readable"),
    };
    return parse_zon(arena, source, path, diag);
}

pub fn parse_zon(arena: Allocator, source: [:0]const u8, name: []const u8, diag: *Diag) Error!File {
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
            "{s} is not a valid server configuration (.listen, .store, .create_store)",
            .{name},
            "see zcube-server --help for the settings",
        ),
    };
}

// ---- Settings -----------------------------------------------------------------------------------

/// "127.0.0.1:7070" or "[::1]:7070": an IP address and a port. A name is refused, because
/// resolving one at start-up could quietly choose a different interface than the user meant.
pub fn parse_listen(text: []const u8, diag: *Diag) Error!IpAddress {
    const reason = "use an IP address and a port, like 127.0.0.1:7070";
    if (text.len == 0) return bad(diag, "the listen address is empty", .{}, reason);
    if (text.len > constants.listen_bytes_max) {
        return bad(diag, "the listen address is longer than 128 bytes", .{}, reason);
    }
    const colon = std.mem.findScalarLast(u8, text, ':') orelse
        return bad(diag, "the listen address {s} has no port", .{text}, reason);
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch
        return bad(diag, "the port in {s} is not a number from 0 to 65535", .{text}, reason);
    var host = text[0..colon];
    if (host.len >= 2) {
        if (host[0] == '[') {
            if (host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        }
    }
    return IpAddress.parse(host, port) catch
        bad(diag, "{s} is not an IP address", .{host}, reason);
}

/// "memory", "sqlite:<path>" or "postgres:<libpq settings>".
pub fn parse_store(text: []const u8, diag: *Diag) Error!Store {
    const reason = "use memory, sqlite:<path> or postgres:<libpq settings>";
    if (text.len > constants.store_spec_bytes_max) {
        return bad(diag, "the store setting is longer than 1100 bytes", .{}, reason);
    }
    if (std.mem.eql(u8, text, "memory")) return .memory;
    if (std.mem.startsWith(u8, text, "sqlite:")) {
        const path = text["sqlite:".len..];
        if (path.len == 0) return bad(diag, "sqlite: needs a file path", .{}, reason);
        return .{ .sqlite = path };
    }
    if (std.mem.startsWith(u8, text, "postgres:")) {
        const settings = text["postgres:".len..];
        if (settings.len == 0) return bad(diag, "postgres: needs connection settings", .{}, reason);
        if (settings.len > constants.store_postgres_conninfo_bytes_max) {
            return bad(diag, "the postgres settings are longer than 1024 bytes", .{}, reason);
        }
        return .{ .postgres = settings };
    }
    return bad(diag, "the store {s} is not memory, sqlite: or postgres:", .{kind_of(text)}, reason);
}

/// The part of a store setting that is safe to print: never the text after a colon, which may
/// hold a password.
fn kind_of(text: []const u8) []const u8 {
    const colon = std.mem.findScalar(u8, text, ':') orelse return text[0..@min(text.len, 24)];
    return text[0..@min(colon, 24)];
}

fn bad(diag: *Diag, comptime cause: []const u8, args: anytype, fix: []const u8) Error {
    assert(diag.code == null);
    diag.raise(.E0106);
    diag.cause(cause, args);
    diag.fix(.{ .sentence = fix });
    return error.BadConfig;
}

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

fn expect_bad(result: anytype, diag: *const Diag) !void {
    try testing.expectError(error.BadConfig, result);
    try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0106), diag.code);
}

test "the listen address is an IP address and a port, and nothing else" {
    // Goal: every way an address can be wrong is E0106 naming the setting. Method: good IPv4 and
    // IPv6 forms, then a name, no port, a big port, an empty host.
    var diag: Diag = undefined;
    diag.reset();
    const v4 = try parse_listen("127.0.0.1:7070", &diag);
    try testing.expectEqual(@as(u16, 7070), v4.getPort());
    const v6 = try parse_listen("[::1]:0", &diag);
    try testing.expectEqual(@as(u16, 0), v6.getPort());
    const bad_inputs = [_][]const u8{
        "localhost:7070", "127.0.0.1", "127.0.0.1:70000", ":7070", "",
    };
    for (bad_inputs) |input| {
        diag.reset();
        try expect_bad(parse_listen(input, &diag), &diag);
    }
}

test "the store setting names a backend, and a refusal never prints a password" {
    // Goal: the three forms parse; anything else is refused without echoing what follows the
    // colon, because that may be a connection string with a password.
    var diag: Diag = undefined;
    diag.reset();
    try testing.expect((try parse_store("memory", &diag)) == .memory);
    const file_store = try parse_store("sqlite:/tmp/x.db", &diag);
    try testing.expectEqualStrings("/tmp/x.db", file_store.sqlite);
    const pg = try parse_store("postgres:host=db user=zcube password=hunter2", &diag);
    try testing.expectEqualStrings("host=db user=zcube password=hunter2", pg.postgres);
    diag.reset();
    try expect_bad(parse_store("mysql:user=a password=hunter2", &diag), &diag);
    for (diag.causes.slice()) |cause| {
        try testing.expect(std.mem.indexOf(u8, cause.slice(), "hunter2") == null);
    }
    diag.reset();
    try expect_bad(parse_store("sqlite:", &diag), &diag);
    diag.reset();
    try expect_bad(parse_store("postgres:", &diag), &diag);
}

test "flags win over the file, unknown flags and settings are refused" {
    // Goal: precedence and strictness. Method: a file that sets all three, flags that override
    // two; a stray flag; a field the file may not have.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const source = ".{ .listen = \"10.0.0.1:1\", .store = \"sqlite:/a\", .create_store = true }";
    const file = try parse_zon(arena, source, "server.zon", &diag);
    const typed = [_][]const u8{ "--listen", "127.0.0.1:9", "--store", "memory", "-v" };
    const flags = try parse_flags(&typed, &diag);
    const config = try merge(flags, file, &diag);
    try testing.expectEqual(@as(u16, 9), config.listen.getPort());
    try testing.expect(config.store == .memory);
    try testing.expect(config.create_store);
    try testing.expect(config.verbose);

    diag.reset();
    try expect_bad(parse_flags(&.{"--bogus"}, &diag), &diag);
    diag.reset();
    try expect_bad(parse_flags(&.{"--listen"}, &diag), &diag);
    diag.reset();
    try expect_bad(parse_zon(arena, ".{ .listn = \"x\" }", "server.zon", &diag), &diag);
    diag.reset();
    try expect_bad(parse_zon(arena, "this is not zon", "server.zon", &diag), &diag);
}
