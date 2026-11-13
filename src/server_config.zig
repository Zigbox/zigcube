//! `zcube-server`'s configuration: a small ZON file and flags, flags winning. Shell code: it reads
//! a file. A setting it cannot use is ZC-E0106 and names the setting, so a typo in a file or a flag
//! never turns into a server that quietly does something else.
//!
//! ```zig
//! .{
//!     .listen = "127.0.0.1:7070",
//!     .store = "sqlite:/var/lib/zcube/store.db", // or "postgres:host=db user=zcube", or "memory"
//!     .create_store = false, // true on the first start: a mistyped path is an error otherwise
//!     // The upstreams a job's `relay` may name (docs/briefs/b3.md): at most `relays_max`. A job
//!     // names one; it never gives an address.
//!     .relays = .{ .botpike = .{ .address = "broker.botpike.com:8443" } },
//!     // The Zigbox policy file `POST /v1/jobs` checks a job's signatures against (docs/briefs/
//!     // b5.md), read once at start; without it nothing is checked.
//!     .trust = .{ .policy = "/etc/zcube/trust.zon" },
//! }
//! ```

const std = @import("std");
const fencing = @import("fencing.zig");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const zigbox = @import("zigbox");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const IpAddress = std.Io.net.IpAddress;

pub const listen_default = "127.0.0.1:7070";

pub const usage =
    \\usage: zcube-server [--config FILE] [--listen HOST:PORT] [--store SPEC] [--create-store]
    \\                    [--new-ca] [--verbose] [--quiet]
    \\       zcube-server --version | --help
    \\
    \\  --config FILE     a ZON file with .listen, .store, .create_store, .relays (the
    \\                    upstreams a job's relay may name) and .trust = .{ .policy = FILE }
    \\                    (the Zigbox policy file a job's signatures are checked against)
    \\  --listen ADDR     where to listen, an IP address and a port (default 127.0.0.1:7070)
    \\  --store SPEC      memory | sqlite:<path> | postgres:<libpq settings> (default memory)
    \\  --lease-ttl-ms N  the ttl of the agents' leases (default 10000); agents learn it
    \\  --lost-grace-ms N how long a lost node's replicas stay before they are replaced under
    \\                    new ids (default 1000)
    \\  --state-dir DIR   where to remember the highest store revision seen (SQLite: default is
    \\                    the SQLite file's directory; Postgres: required). Keep outside the store
    \\  --create-store    create the store's file or schema if it is not there
    \\  --new-ca          make a new peer CA key although the store has run before (every agent
    \\                    then joins again); the key file is in the state directory
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
    /// Where the remembered revision is kept; null: beside the SQLite file. A Postgres store
    /// requires it (`ZC-E0106`).
    state_dir: ?[]const u8 = null,
    verbose: bool,
    quiet: bool,
    /// Make a new CA key although the store has run here before (`--new-ca`).
    new_ca: bool = false,
    /// The ttl of the leases the server grants to agents.
    lease_ttl_ms: u32 = constants.lease_ttl_ms,
    /// How long after a node is marked lost its replicas are moved (docs/authority.md §3).
    lost_grace_ms: u32 = constants.lost_grace_ms,
    /// The relays a job may name, in the file's order; none by default.
    relays: []const Relay = &.{},
    /// The policy a new job's signatures are checked against (B5); null checks nothing.
    trust: ?Trust = null,
};

/// The `trust` entry, its policy file read and parsed at start.
pub const Trust = struct {
    path: []const u8,
    policy: *const Policy,
};

pub const Policy = zigbox.trust.policy.Policy;

pub const Command = union(enum) { run: Config, version, help };

/// One relay: the name a job gives and the `host:port` the node agent connects to for it.
pub const Relay = @import("records.zig").JobRelay;

/// What a ZON file holds: the settings `Fields` reads, and the relays, whose names are the
/// file's own and so are read from the syntax tree.
const File = struct {
    listen: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: ?bool = null,
    lease_ttl_ms: ?u32 = null,
    lost_grace_ms: ?u32 = null,
    state_dir: ?[]const u8 = null,
    trust: ?TrustField = null,
    relays: []const Relay = &.{},
};

/// `.trust = .{ .policy = "<path>" }`; its field names are checked in `relays_of`.
const TrustField = struct { policy: []const u8 };

/// What a ZON file may set apart from `relays`. Unknown fields are refused (`parse_zon` checks
/// the names itself, because it parses these with the relays left out).
const Fields = struct {
    listen: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: ?bool = null,
    lease_ttl_ms: ?u32 = null,
    lost_grace_ms: ?u32 = null,
    state_dir: ?[]const u8 = null,
    trust: ?TrustField = null,
};

/// The flags as typed, before they are merged over the file.
const Flags = struct {
    config: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: bool = false,
    lease_ttl_ms: ?u32 = null,
    lost_grace_ms: ?u32 = null,
    state_dir: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    new_ca: bool = false,
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
    var config = try merge(flags, file, diag);
    if (file.trust) |entry| config.trust = try read_policy(arena, io, entry.policy, diag);
    return .{ .run = config };
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
        .new_ca = flags.new_ca,
        .lease_ttl_ms = try lease_ttl_of(flags.lease_ttl_ms orelse file.lease_ttl_ms, diag),
        .lost_grace_ms = try lost_grace_of(flags.lost_grace_ms orelse file.lost_grace_ms, diag),
        .relays = try relays_valid(file.relays, diag),
    };
}

/// ZC-E0106 for a grace outside its range: at most `lost_grace_ms_max`.
fn lost_grace_of(given: ?u32, diag: *Diag) Error!u32 {
    const grace = given orelse constants.lost_grace_ms;
    if (grace > constants.lost_grace_ms_max) {
        return bad(diag, "a lost grace of {d} ms is over {d} ms", .{
            grace, constants.lost_grace_ms_max,
        }, "choose a grace of at most an hour");
    }
    return grace;
}

/// ZC-E0121 for a ttl an agent cannot fence in time (docs/authority.md §3).
fn lease_ttl_of(given: ?u32, diag: *Diag) Error!u32 {
    const ttl = given orelse constants.lease_ttl_ms;
    if (ttl < constants.lease_ttl_ms_min or ttl > constants.lease_ttl_ms_max) {
        return bad(diag, "a lease ttl of {d} ms is outside {d} to {d} ms", .{
            ttl, constants.lease_ttl_ms_min, constants.lease_ttl_ms_max,
        }, "choose a ttl inside the range");
    }
    const problem = fencing.inequality_problem(ttl) orelse return ttl;
    fencing.raise_problem(diag, ttl, problem);
    return error.BadConfig;
}

// ---- Flags -------------------------------------------------------------------------------------

pub fn parse_flags(args: []const []const u8, diag: *Diag) Error!Flags {
    var flags: Flags = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--create-store")) {
            flags.create_store = true;
        } else if (std.mem.eql(u8, arg, "--new-ca")) {
            flags.new_ca = true;
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
        } else if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            flags.lease_ttl_ms = try number_of(u32, args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--lost-grace-ms")) {
            flags.lost_grace_ms = try number_of(u32, args, &index, diag);
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

fn number_of(comptime T: type, args: []const []const u8, index: *usize, diag: *Diag) Error!T {
    const flag = args[index.*];
    const text = try value_of(args, index, diag);
    return std.fmt.parseInt(T, text, 10) catch
        bad(diag, "{s} needs a whole number, not {s}", .{ flag, text }, "run it with --help");
}

// ---- The trust policy --------------------------------------------------------------------------

/// Reads and parses the policy file of the `trust` entry, once, at start. Any problem is
/// ZC-E0106 naming the file, and a policy Zigbox refuses names its line, column and kind. The
/// file is judged and read through one descriptor, so it cannot be swapped between the two.
fn read_policy(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error!Trust {
    if (path.len == 0 or path.len > constants.config_path_bytes_max) {
        return bad(diag, "trust.policy must be a path of 1 to 1024 bytes", .{}, policy_fix);
    }
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch
        return bad(diag, "can't read the trust policy {s}", .{path}, policy_fix);
    defer file.close(io);
    const owner = owner_of(file) orelse
        return bad(diag, "can't read the trust policy {s}", .{path}, policy_fix);
    if (owner_problem(owner, std.os.linux.geteuid())) |problem| {
        return bad(diag, "the trust policy {s} {s} (owner uid {d}, mode {o:0>4})", .{
            path, problem, owner.uid, owner.mode & 0o7777,
        }, "chown it to root (or the server's user) and chmod go-w it: a policy that others" ++
            " can rewrite gates nothing");
    }
    // A file of exactly the bound is allowed: the limit refuses one that reaches it.
    const limit: std.Io.Limit = .limited(zigbox.trust.limits.policy_bytes_max + 1);
    var reader = file.reader(io, &.{});
    const source = reader.interface.allocRemaining(arena, limit) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => bad(diag, "the trust policy {s} is larger than {d} bytes", .{
                path, zigbox.trust.limits.policy_bytes_max,
            }, "trim it"),
            error.ReadFailed => bad(diag, "can't read the trust policy {s}", .{path}, policy_fix),
        };
    };
    return policy_of(arena, source, path, diag);
}

/// Who owns the policy file and its mode bits.
const Owner = struct { uid: u32, mode: u32 };

fn owner_of(file: std.Io.File) ?Owner {
    const linux = std.os.linux;
    var stat = std.mem.zeroes(linux.Statx);
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true };
    const result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, mask, &stat);
    if (linux.errno(result) != .SUCCESS) return null;
    if (!stat.mask.MODE or !stat.mask.UID) return null;
    return .{ .uid = stat.uid, .mode = stat.mode };
}

/// Zigbox's rule for its system policy (`trust/gate.zig`, "the system policy binds users who
/// cannot write it"), carried over to a server that need not run as root: the file is a regular
/// file, owned by root or by the server's own user, and writable by neither group nor others.
/// Null when it may be used; otherwise what is wrong, for the cause line.
fn owner_problem(owner: Owner, euid: u32) ?[]const u8 {
    if (owner.mode & std.os.linux.S.IFMT != std.os.linux.S.IFREG) return "is not a regular file";
    if (owner.uid != 0 and owner.uid != euid) {
        return "is owned by neither root nor the server's user";
    }
    if (owner.mode & 0o022 != 0) return "can be written by its group or by others";
    return null;
}

fn policy_of(arena: Allocator, source: []const u8, path: []const u8, diag: *Diag) Error!Trust {
    const policy = try arena.create(Policy);
    if (zigbox.trust.policy.parse(source, policy)) |problem| {
        const detail = problem.detail_text();
        return bad(diag, "the trust policy {s} is not a policy zbx reads: {t} at {d}:{d}{s}{s}", .{
            path,
            problem.kind,
            problem.line,
            problem.column,
            if (detail.len > 0) " near " else "",
            detail,
        }, "check it with zbx trust policy check, or fix the line it names");
    }
    return .{ .path = path, .policy = policy };
}

const policy_fix = "write it as .trust = .{ .policy = \"/etc/zcube/trust.zon\" }, naming a" ++
    " readable Zigbox policy file";

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
    var ast = try parse_tree(arena, source, name, diag);
    defer ast.deinit(arena);
    var zoir = std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = true }) catch
        return error.OutOfMemory;
    defer zoir.deinit(arena);
    const shape = "{s} is not a valid server configuration (.listen, .store, .create_store)";
    if (zoir.hasCompileErrors()) {
        return bad(diag, shape, .{name}, "see zcube-server --help for the settings");
    }
    // The typed parse below ignores unknown fields, because it must not see `relays`: so the
    // names are checked here, and a typo is still refused.
    const relays = try relays_of(arena, &zoir, name, diag);
    var zon_diag: std.zon.parse.Diagnostics = undefined;
    const fields = std.zon.parse.fromZoir(Fields, .{
        .arena = arena,
        .ast = &ast,
        .zoir = &zoir,
        .diagnostics = &zon_diag,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return bad(diag, shape, .{name}, "see zcube-server --help"),
    };
    var file: File = .{ .relays = relays };
    inline for (@typeInfo(Fields).@"struct".field_names) |field| {
        @field(file, field) = @field(fields, field);
    }
    return file;
}

fn parse_tree(
    arena: Allocator,
    source: [:0]const u8,
    name: []const u8,
    diag: *Diag,
) Error!std.zig.Ast {
    const ast = std.zig.Ast.parse(arena, source, .{ .mode = .zon }) catch return error.OutOfMemory;
    if (ast.errors.len == 0) return ast;
    var owned = ast;
    owned.deinit(arena);
    const shape = "{s} is not a valid server configuration (.listen, .store, .create_store)";
    return bad(diag, shape, .{name}, "see zcube-server --help for the settings");
}

const known_settings = [_][]const u8{
    "listen",    "store",  "create_store", "lease_ttl_ms", "lost_grace_ms",
    "state_dir", "relays", "trust",
};

/// The relays of the file's root struct, after its field names are checked. A relay is
/// `.name = .{ .address = "host:port" }`; anything else in it is ZC-E0106 naming the relay.
fn relays_of(
    arena: Allocator,
    zoir: *const std.zig.Zoir,
    file_name: []const u8,
    diag: *Diag,
) Error![]const Relay {
    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const names, const values = switch (root) {
        .struct_literal => |literal| .{ literal.names, literal.vals },
        .empty_literal => return &.{},
        else => return bad(diag, "{s} is not a struct of settings", .{file_name}, "see --help"),
    };
    var found: ?std.zig.Zoir.Node.Index = null;
    for (names, 0..) |setting, index| {
        const text = setting.get(zoir);
        const known = for (known_settings) |candidate| {
            if (std.mem.eql(u8, text, candidate)) break true;
        } else false;
        if (!known) {
            const reason = "{s} sets .{s}, which is not a zcube-server setting";
            return bad(diag, reason, .{ file_name, text }, "see zcube-server --help");
        }
        if (std.mem.eql(u8, text, "relays")) found = values.at(@intCast(index));
        if (std.mem.eql(u8, text, "trust")) try trust_names(zoir, values.at(@intCast(index)), diag);
    }
    const node = found orelse return &.{};
    return relay_list(arena, zoir, node, diag);
}

/// The typed parse ignores unknown fields, so the `trust` entry's names are checked here: it is
/// `.{ .policy = "<path>" }` and nothing else.
fn trust_names(zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node.Index, diag: *Diag) Error!void {
    const names = switch (node.get(zoir)) {
        .struct_literal => |literal| literal.names,
        else => return bad(diag, "trust is not .{{ .policy = \"<path>\" }}", .{}, policy_fix),
    };
    for (names) |name| {
        const text = name.get(zoir);
        if (!std.mem.eql(u8, text, "policy")) {
            return bad(diag, "trust sets .{s}, which is not a trust setting", .{text}, policy_fix);
        }
    }
}

fn relay_list(
    arena: Allocator,
    zoir: *const std.zig.Zoir,
    node: std.zig.Zoir.Node.Index,
    diag: *Diag,
) Error![]const Relay {
    const names, const values = switch (node.get(zoir)) {
        .struct_literal => |literal| .{ literal.names, literal.vals },
        .empty_literal => return &.{},
        else => return bad(diag, "relays is not a struct of relays", .{}, relay_fix),
    };
    // Checked before anything is read, so a file with a hundred relays is refused by its count.
    if (names.len > constants.relays_max) {
        return bad(diag, "relays names {d} relays, over the limit of {d}", .{
            names.len, constants.relays_max,
        }, "name at most " ++ relays_max_text ++ " relays");
    }
    const list = arena.alloc(Relay, names.len) catch return error.OutOfMemory;
    for (names, list, 0..) |name_node, *slot, index| {
        // The Zoir is freed when `parse_zon` returns, so the text is copied out of it.
        const name = arena.dupe(u8, name_node.get(zoir)) catch return error.OutOfMemory;
        const address = try relay_address(zoir, values.at(@intCast(index)), name, diag);
        const kept = arena.dupe(u8, address) catch return error.OutOfMemory;
        slot.* = .{ .name = name, .address = kept };
        if (relay_name_problem(name)) |problem| {
            return bad(diag, "relay {s}: the name {s}", .{ name, problem }, relay_fix);
        }
    }
    return list;
}

const relays_max_text = "8";
const relay_fix = "write it as .relays = .{ .name = .{ .address = \"host:port\" } }";

fn relay_address(
    zoir: *const std.zig.Zoir,
    node: std.zig.Zoir.Node.Index,
    name: []const u8,
    diag: *Diag,
) Error![]const u8 {
    const fields = switch (node.get(zoir)) {
        .struct_literal => |literal| literal,
        else => return bad(diag, "relay {s} is not .{{ .address = ... }}", .{name}, relay_fix),
    };
    if (fields.names.len != 1) {
        return bad(diag, "relay {s} must have an .address and nothing else", .{name}, relay_fix);
    }
    if (!std.mem.eql(u8, fields.names[0].get(zoir), "address")) {
        return bad(diag, "relay {s} must have an .address and nothing else", .{name}, relay_fix);
    }
    return switch (fields.vals.at(0).get(zoir)) {
        .string_literal => |text| text,
        else => bad(diag, "relay {s}: .address is not a string", .{name}, relay_fix),
    };
}

/// A relay name is what a job writes: lowercase letters, digits and '-', not at either end.
pub fn relay_name_problem(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > constants.relay_name_bytes_max) {
        return "must be 1 to 32 bytes";
    }
    for (name, 0..) |byte, index| {
        const letter = byte >= 'a' and byte <= 'z';
        const digit = byte >= '0' and byte <= '9';
        const hyphen = byte == '-' and index > 0 and index + 1 < name.len;
        if (!(letter or digit or hyphen)) {
            return "must be lowercase letters, digits and '-' (none at either end)";
        }
    }
    return null;
}

/// An upstream is `host:port`: a name or an IP address, and a port from 1 to 65535. The
/// connection is plain TCP in B3 (docs/briefs/b3.md), so nothing else is part of it.
pub fn relay_address_problem(address: []const u8) ?[]const u8 {
    if (address.len == 0 or address.len > constants.relay_address_bytes_max) {
        return "must be 1 to 256 bytes";
    }
    const colon = std.mem.findScalarLast(u8, address, ':') orelse return "has no port";
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch
        return "has a port that is not a number from 1 to 65535";
    if (port == 0) return "has a port that is not a number from 1 to 65535";
    if (std.mem.trim(u8, address[0..colon], "[]").len == 0) return "has no host";
    for (address[0..colon]) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
        const ip6 = byte == ':' or byte == '[' or byte == ']';
        if (!(plain or ip6)) return "has a host with a character a host name cannot have";
    }
    return null;
}

/// The relays after a second look at what the file said: no name twice, and each address one
/// the agent can connect to.
fn relays_valid(relays: []const Relay, diag: *Diag) Error![]const Relay {
    assert(relays.len <= constants.relays_max);
    for (relays, 0..) |relay, index| {
        for (relays[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, relay.name)) {
                return bad(diag, "relay {s} is given twice", .{relay.name}, relay_fix);
            }
        }
        if (relay_address_problem(relay.address)) |problem| {
            return bad(diag, "relay {s}: the address {s}", .{ relay.name, problem }, relay_fix);
        }
    }
    return relays;
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

test "a lease ttl an agent cannot fence in time is ZC-E0121" {
    // Goal: the inequality of docs/authority.md §3 is enforced at start. Method: the shipped
    // ttl passes; 20000 and 30000 (margin too small) and 3000 (ttl too short) are refused.
    var diag: Diag = undefined;
    diag.reset();
    const ok = try merge(.{}, .{}, &diag);
    try testing.expectEqual(constants.lease_ttl_ms, ok.lease_ttl_ms);
    const refused = [_]u32{ 20_000, 30_000, 3_000, 5_000, 7_999 };
    for (refused) |ttl| {
        diag.reset();
        try testing.expectError(error.BadConfig, merge(.{ .lease_ttl_ms = ttl }, .{}, &diag));
        try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0121), diag.code);
    }
    // Too short is told to lengthen, with the shortest ttl named; too long to shorten.
    diag.reset();
    try testing.expectError(error.BadConfig, merge(.{ .lease_ttl_ms = 7_999 }, .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "shortest ttl is 8000") != null);
    diag.reset();
    try testing.expectError(error.BadConfig, merge(.{ .lease_ttl_ms = 20_000 }, .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.last_cause().?, "needs a fence margin") != null);
    diag.reset();
    const shortest = try merge(.{ .lease_ttl_ms = 8_000 }, .{}, &diag);
    try testing.expectEqual(@as(u32, 8_000), shortest.lease_ttl_ms);
}

test "the lost grace is a flag, a file setting, and refused over an hour" {
    // Goal: `--lost-grace-ms` reaches the config. Method: the default, a flag over a file, and
    // one over `lost_grace_ms_max` refused with ZC-E0106.
    var diag: Diag = undefined;
    diag.reset();
    try testing.expectEqual(constants.lost_grace_ms, (try merge(.{}, .{}, &diag)).lost_grace_ms);
    const flags = try parse_flags(&.{ "--lost-grace-ms", "30000" }, &diag);
    const both = try merge(flags, .{ .lost_grace_ms = 5 }, &diag);
    try testing.expectEqual(@as(u32, 30000), both.lost_grace_ms);
    const at_limit = try merge(.{ .lost_grace_ms = constants.lost_grace_ms_max }, .{}, &diag);
    try testing.expectEqual(constants.lost_grace_ms_max, at_limit.lost_grace_ms); // Exactly 1 h.
    const over = constants.lost_grace_ms_max + 1;
    try expect_bad(merge(.{ .lost_grace_ms = over }, .{}, &diag), &diag);
}

test "relays are a table of names and addresses; every malformed entry is ZC-E0106" {
    // Goal: the `relays` setting of the brief's config form. Method: a good table parses and
    // merges; each way to get an entry wrong, and a ninth relay, is refused.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const good = ".{ .relays = .{ .botpike = .{ .address = \"broker.botpike.com:8443\" }," ++
        " .b2 = .{ .address = \"127.0.0.1:9\" } } }";
    const file = try parse_zon(arena, good, "server.zon", &diag);
    const config = try merge(.{}, file, &diag);
    try testing.expectEqual(@as(usize, 2), config.relays.len);
    try testing.expectEqualStrings("botpike", config.relays[0].name);
    try testing.expectEqualStrings("broker.botpike.com:8443", config.relays[0].address);
    const none = try merge(.{}, try parse_zon(arena, ".{}", "server.zon", &diag), &diag);
    try testing.expectEqual(@as(usize, 0), none.relays.len);

    const bad_files = [_][:0]const u8{
        ".{ .relays = .{ .x = .{ .address = \"a:1\", .extra = 1 } } }",
        ".{ .relays = .{ .x = .{} } }",
        ".{ .relays = .{ .x = .{ .address = \"no-port\" } } }",
        ".{ .relays = .{ .x = .{ .address = \"a:0\" } } }",
        ".{ .relays = .{ .x = .{ .address = \"\" } } }",
        ".{ .relays = 3 }",
        ".{ .relays = .{ .x = 3 } }",
        ".{ .relays = .{ .@\"a b\" = .{ .address = \"a:1\" } } }",
        ".{ .relays = .{ .a = .{ .address = \"a:1\" }, .a = .{ .address = \"b:1\" } } }",
        ".{ .relays = .{ .r0 = .{ .address = \"h:1\" }, .r1 = .{ .address = \"h:1\" }," ++
            " .r2 = .{ .address = \"h:1\" }, .r3 = .{ .address = \"h:1\" }," ++
            " .r4 = .{ .address = \"h:1\" }, .r5 = .{ .address = \"h:1\" }," ++
            " .r6 = .{ .address = \"h:1\" }, .r7 = .{ .address = \"h:1\" }," ++
            " .r8 = .{ .address = \"h:1\" } } }",
    };
    for (bad_files) |source| {
        diag.reset();
        const parsed = parse_zon(arena, source, "server.zon", &diag) catch {
            try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0106), diag.code);
            continue;
        };
        diag.reset();
        try expect_bad(merge(.{}, parsed, &diag), &diag);
    }
}

test "trust names a policy file; a bad entry or a policy zbx refuses is ZC-E0106" {
    // Goal: the `trust` setting of B5. Method: the entry parses, a good policy is read and its
    // key is trusted; a typo in the entry, a missing file and each kind of bad policy are
    // refused with ZC-E0106 naming the file.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const file = try parse_zon(arena, ".{ .trust = .{ .policy = \"p.zon\" } }", "s.zon", &diag);
    try testing.expectEqualStrings("p.zon", file.trust.?.policy);
    const none = try parse_zon(arena, ".{}", "s.zon", &diag);
    try testing.expect(none.trust == null);
    try testing.expect((try merge(.{}, none, &diag)).trust == null);

    const public = zigbox.trust.key.public_text(zigbox.trust.key.public_of_seed(@splat(7)));
    var policy_buffer: [256]u8 = undefined;
    const good = try std.fmt.bufPrint(&policy_buffer, ".{{ .version = 1, .keys = .{{ .{{ " ++
        ".name = \"botpike\", .public = \"{s}\" }} }}, .require_signature = true }}", .{&public});
    const trust = try policy_of(arena, good, "p.zon", &diag);
    try testing.expect(trust.policy.checks());
    try testing.expectEqualStrings("p.zon", trust.path);

    const bad_files = [_][:0]const u8{
        ".{ .trust = .{ .policy = \"p.zon\", .polcy = \"q\" } }",
        ".{ .trust = \"p.zon\" }",
        ".{ .trust = .{} }",
        ".{ .trusts = .{ .policy = \"p.zon\" } }",
    };
    for (bad_files) |source| {
        diag.reset();
        try expect_bad(parse_zon(arena, source, "s.zon", &diag), &diag);
    }
    const bad_policies = [_][]const u8{
        "",
        ".{ .keys = .{} }",
        ".{ .version = 1, .keys = .{ .{ .name = \"k\", .public = \"nope\" } } }",
        ".{ .version = 9, .keys = .{} }",
        ".{ .version = 1, .keys = .{}, .extra = true }",
    };
    for (bad_policies) |source| {
        diag.reset();
        try expect_bad(policy_of(arena, source, "p.zon", &diag), &diag);
    }
    diag.reset();
    const missing = read_policy(arena, testing.io, "/nonexistent/zcube-trust.zon", &diag);
    try expect_bad(missing, &diag);
    diag.reset();
    try expect_bad(read_policy(arena, testing.io, "", &diag), &diag);
}

test "a trust policy others can rewrite is ZC-E0106; one only root or the server writes is read" {
    // Goal: Zigbox's rule for its system policy, carried over (PR #241 review): a policy file
    // that anyone but root or the server's user could rewrite gates nothing. Method: the rule on
    // owners and modes, then a real file read at 0644 and refused at 0664, 0646 and as a
    // directory, each naming the file and its mode.
    const euid: u32 = 1000;
    const regular: u32 = std.os.linux.S.IFREG;
    try testing.expect(owner_problem(.{ .uid = 0, .mode = regular | 0o644 }, euid) == null);
    try testing.expect(owner_problem(.{ .uid = euid, .mode = regular | 0o600 }, euid) == null);
    try testing.expect(owner_problem(.{ .uid = 0, .mode = regular | 0o4755 }, euid) == null);
    const refused = [_]Owner{
        .{ .uid = 1001, .mode = regular | 0o644 },
        .{ .uid = 0, .mode = regular | 0o664 },
        .{ .uid = euid, .mode = regular | 0o646 },
        .{ .uid = 0, .mode = std.os.linux.S.IFDIR | 0o755 },
    };
    for (refused) |owner| try testing.expect(owner_problem(owner, euid) != null);

    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const public = zigbox.trust.key.public_text(zigbox.trust.key.public_of_seed(@splat(7)));
    const good = try std.fmt.allocPrint(arena, ".{{ .version = 1, .keys = .{{ .{{ " ++
        ".name = \"botpike\", .public = \"{s}\" }} }}, .require_signature = true }}", .{&public});
    try tmp.dir.writeFile(io, .{ .sub_path = "trust.zon", .data = good });
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/trust.zon", .{tmp.sub_path});
    const file = try tmp.dir.openFile(io, "trust.zon", .{ .mode = .read_write });
    defer file.close(io);
    var diag: Diag = undefined;
    diag.reset();
    try file.setPermissions(io, .fromMode(0o644));
    const trust = try read_policy(arena, io, path, &diag);
    try testing.expect(trust.policy.checks());
    for ([_]std.posix.mode_t{ 0o664, 0o646 }) |mode| {
        try file.setPermissions(io, .fromMode(mode));
        diag.reset();
        try expect_bad(read_policy(arena, io, path, &diag), &diag);
        const cause = diag.causes.slice()[0].slice();
        try testing.expect(std.mem.indexOf(u8, cause, "written by its group or by others") != null);
        try testing.expect(std.mem.indexOf(u8, cause, "trust.zon") != null);
    }
    try tmp.dir.createDir(io, "dir.zon", .default_dir);
    const dir_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/dir.zon", .{tmp.sub_path});
    diag.reset();
    try expect_bad(read_policy(arena, io, dir_path, &diag), &diag);
}
