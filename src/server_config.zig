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
//!     // B4: the relay connects with TLS, as the run (a certificate the cluster CA signs for
//!     // `spiffe://<cluster>/job/<name>`), and checks the upstream's name against `server_ca`.
//!     // `.cluster` has no default: until it is set the certificate endpoint answers 404, and a
//!     // TLS relay without it is ZC-E0106 (docs/decisions/2026-11-13-b4-cluster-setting.md).
//!     .cluster = "prod.example",
//!     .relays = .{ .botpike = .{
//!         .address = "broker.botpike.com:8443",
//!         .server_name = "broker.botpike.com",
//!         .server_ca = "/etc/zcube/botpike-ca.pem",
//!     } },
//!     // The Zigbox policy file `POST /v1/jobs` checks a job's signatures against (docs/briefs/
//!     // b5.md), read once at start; without it nothing is checked.
//!     .trust = .{ .policy = "/etc/zcube/trust.zon" },
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");
const fencing = @import("fencing.zig");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const zigbox = @import("zigbox");
const trust_file = @import("trust_file.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const IpAddress = std.Io.net.IpAddress;

pub const listen_default = "127.0.0.1:7070";
/// The DNS name in the TLS listener's certificate, which clients check (`--tls-name`).
pub const tls_name_default = "zcube-server";

pub const usage =
    \\usage: zcube-server [--config FILE] [--listen HOST:PORT] [--insecure-listen HOST:PORT]
    \\                    [--tls-name NAME] [--store SPEC] [--create-store] [--new-ca]
    \\                    [--verbose] [--quiet]
    \\       zcube-server ca issue-client NAME --scope jobs|admin [--out DIR] [--replace]
    \\                    [--config FILE] [--store SPEC] [--state-dir DIR]
    \\       zcube-server ca issue-node NAME [--out DIR] [--replace]
    \\                    [--config FILE] [--store SPEC] [--state-dir DIR]
    \\       zcube-server --version | --help
    \\
    \\  --config FILE     a ZON file with .listen, .insecure_listen, .tls_name, .store,
    \\                    .create_store, .relays (the upstreams a job's relay may name),
    \\                    .cluster (the trust domain of a relayed run's certificate,
    \\                    spiffe://<cluster>/job/<name>; required with any TLS relay, and
    \\                    runs get no certificate until it is set) and .trust = .{ .policy
    \\                    = FILE } (the Zigbox policy file a job's signatures are checked
    \\                    against)
    \\  --listen ADDR     where to serve the API over TLS, an IP address and a port (default
    \\                    127.0.0.1:7070 unless --insecure-listen is given). Every client
    \\                    presents a certificate of this server's CA: an agent its node's
    \\                    (from ca issue-node until it has joined), anyone else one from
    \\                    ca issue-client
    \\  --insecure-listen ADDR
    \\                    also serve plain HTTP, with no certificate and every request
    \\                    allowed, on a loopback address only (127.0.0.1:PORT or [::1]:PORT):
    \\                    for zcube local, the console in a browser, and tests
    \\  --tls-name NAME   the DNS name in the server's certificate, which clients check
    \\                    (default zcube-server)
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
    \\ca issue-client signs a client certificate with the store's CA (on the server host; the
    \\server need not run): NAME.key and NAME.crt, mode 0600, in --out (default: the working
    \\directory). --scope is what the client may do: jobs, or admin. ca issue-node does the
    \\same for a node's first certificate, which the operator copies to the node. Either is
    \\valid for 7 days: run it again with --replace (by hand or from cron) to re-issue; without
    \\--replace an existing NAME.key or NAME.crt is refused. A name in the revoked file is
    \\refused.
    \\
    \\ca issue-node signs a node certificate the same way, for a new agent's --cert and --key:
    \\it may join and act as NAME only. Once joined, the agent presents its own node.crt.
    \\
    \\The insecure listener allows anything to anyone who can reach it: keep it on loopback.
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
    /// The TLS listener (`--listen`); at least one of the two listeners is set.
    listen: ?IpAddress = null,
    /// The plain-HTTP listener (`--insecure-listen`): a loopback address only.
    insecure_listen: ?IpAddress = null,
    /// The DNS name of the TLS listener's certificate.
    tls_name: []const u8 = tls_name_default,
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
    /// The SPIFFE trust domain of a relayed run's certificate (`spiffe://<cluster>/job/<name>`,
    /// B4). Required when a relay has an upstream to check; empty otherwise.
    cluster: []const u8 = "",
    /// The policy a new job's signatures are checked against (B5); null checks nothing.
    trust: ?Trust = null,
};

/// The `trust` entry, its policy file read and parsed at start.
pub const Trust = struct {
    path: []const u8,
    policy: *const Policy,
};

pub const Policy = zigbox.trust.policy.Policy;

pub const Command = union(enum) { run: Config, ca_issue: Issue, version, help };

/// `zcube-server ca issue-client NAME --scope jobs|admin` or `ca issue-node NAME`: the store
/// settings find the CA key (`config`), and the files are written in `out_dir`.
pub const Issue = struct {
    config: Config,
    /// What the certificate is for: a client (with `scope`) or a node.
    subject: Subject,
    name: []const u8,
    out_dir: []const u8 = ".",
    /// Replace an existing `NAME.key` and `NAME.crt` (`--replace`); refused otherwise.
    replace: bool = false,

    pub const Subject = union(enum) { client: Scope, node };
};

pub const Scope = @import("x509.zig").Scope;

/// One relay: the name a job gives and the `host:port` the node agent connects to for it.
pub const Relay = @import("records.zig").JobRelay;

/// What a ZON file holds: the settings `Fields` reads, and the relays, whose names are the
/// file's own and so are read from the syntax tree.
const File = struct {
    listen: ?[]const u8 = null,
    insecure_listen: ?[]const u8 = null,
    tls_name: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: ?bool = null,
    lease_ttl_ms: ?u32 = null,
    lost_grace_ms: ?u32 = null,
    state_dir: ?[]const u8 = null,
    cluster: ?[]const u8 = null,
    trust: ?TrustField = null,
    relays: []const Relay = &.{},
    /// Each relay's `server_ca` path, index for index with `relays`; read by `read_file`, which
    /// puts the key it names in the relay's `server_anchor`.
    relay_cas: []const []const u8 = &.{},
};

/// `.trust = .{ .policy = "<path>" }`; its field names are checked in `relays_of`.
const TrustField = struct { policy: []const u8 };

/// What a ZON file may set apart from `relays`. Unknown fields are refused (`parse_zon` checks
/// the names itself, because it parses these with the relays left out).
const Fields = struct {
    listen: ?[]const u8 = null,
    insecure_listen: ?[]const u8 = null,
    tls_name: ?[]const u8 = null,
    store: ?[]const u8 = null,
    create_store: ?bool = null,
    lease_ttl_ms: ?u32 = null,
    lost_grace_ms: ?u32 = null,
    state_dir: ?[]const u8 = null,
    cluster: ?[]const u8 = null,
    trust: ?TrustField = null,
};

/// The flags as typed, before they are merged over the file.
const Flags = struct {
    config: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    insecure_listen: ?[]const u8 = null,
    tls_name: ?[]const u8 = null,
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
    if (args.len > 0 and std.mem.eql(u8, args[0], "ca")) return load_ca(arena, io, args, diag);
    const flags = try parse_flags(args, diag);
    if (flags.version) return .version;
    if (flags.help) return .help;
    var file: File = .{};
    if (flags.config) |path| file = try read_file(arena, io, path, diag);
    var config = try merge(flags, file, diag);
    if (file.trust) |entry| config.trust = try read_policy(arena, io, entry.policy, diag);
    return .{ .run = config };
}

/// `ca issue-client NAME --scope S` or `ca issue-node NAME`, `[--out DIR] [--replace]`, and the
/// store flags of a run. `--help` anywhere after `ca` is the help.
fn load_ca(arena: Allocator, io: std.Io, args: []const []const u8, diag: *Diag) Error!Command {
    assert(std.mem.eql(u8, args[0], "ca"));
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-h")) return .help;
    }
    const node = args.len >= 2 and std.mem.eql(u8, args[1], "issue-node");
    const client = args.len >= 2 and std.mem.eql(u8, args[1], "issue-client");
    if (!node and !client) {
        const problem = "zcube-server ca has two commands, issue-client and issue-node";
        return bad(diag, problem, .{}, "run it with --help");
    }
    const what = if (node) "ca issue-node needs a node name" else "ca issue-client needs a name";
    if (args.len < 3 or std.mem.startsWith(u8, args[2], "-")) {
        return bad(diag, "{s}", .{what}, "run it with --help");
    }
    var request: Issue = .{ .config = undefined, .subject = .node, .name = args[2] };
    var scope: ?Scope = null;
    var out: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--scope")) {
            if (scope != null) return bad(diag, "--scope is given twice", .{}, "give it once");
            scope = try scope_of(args, &index, diag);
        } else if (std.mem.eql(u8, args[index], "--out")) {
            if (out != null) return bad(diag, "--out is given twice", .{}, "give it once");
            out = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, args[index], "--replace")) {
            request.replace = true;
        } else {
            try rest.append(arena, args[index]);
        }
    }
    if (out) |directory| request.out_dir = directory;
    request.subject = try subject_of(node, scope, diag);
    request.config = try issue_config(arena, io, rest.items, diag);
    return .{ .ca_issue = request };
}

fn scope_of(args: []const []const u8, index: *usize, diag: *Diag) Error!Scope {
    const text = try value_of(args, index, diag);
    return Scope.parse(text) orelse
        bad(diag, "--scope is jobs or admin, not {s}", .{text}, "run it with --help");
}

/// A client needs a scope; a node has none (it may call the agent API for itself only).
fn subject_of(node: bool, scope: ?Scope, diag: *Diag) Error!Issue.Subject {
    if (node) {
        if (scope != null) {
            const problem = "a node certificate has no --scope: a node may act for itself only";
            return bad(diag, problem, .{}, "leave out --scope");
        }
        return .node;
    }
    const given = scope orelse {
        return bad(diag, "ca issue-client needs --scope jobs or --scope admin", .{}, "add one");
    };
    return .{ .client = given };
}

/// The store settings of a run, read as the server reads them, without the ones that make a CA.
fn issue_config(arena: Allocator, io: std.Io, rest: []const []const u8, diag: *Diag) Error!Config {
    const flags = try parse_flags(rest, diag);
    if (flags.version) {
        return bad(diag, "--version is not a setting of ca", .{}, "run zcube-server --version");
    }
    assert(!flags.help); // `load_ca` answered it.
    if (flags.new_ca or flags.create_store) {
        const problem = "ca signs with the CA a server already made";
        return bad(diag, problem, .{}, "leave out --new-ca and --create-store");
    }
    var file: File = .{};
    if (flags.config) |path| file = try read_file(arena, io, path, diag);
    return merge(flags, file, diag);
}

fn merge(flags: Flags, file: File, diag: *Diag) Error!Config {
    const insecure_text = flags.insecure_listen orelse file.insecure_listen;
    // With neither listener named, the TLS one listens on the default address.
    const listen_text = flags.listen orelse file.listen orelse
        if (insecure_text == null) @as([]const u8, listen_default) else null;
    const store_text = flags.store orelse file.store orelse "memory";
    return .{
        .listen = if (listen_text) |text| try parse_listen(text, diag) else null,
        .insecure_listen = if (insecure_text) |t| try parse_insecure_listen(t, diag) else null,
        .tls_name = try tls_name_of(
            flags.tls_name orelse file.tls_name orelse tls_name_default,
            diag,
        ),
        .store = try parse_store(store_text, diag),
        .create_store = if (flags.create_store) true else (file.create_store orelse false),
        .state_dir = flags.state_dir orelse file.state_dir,
        .verbose = flags.verbose,
        .quiet = flags.quiet,
        .new_ca = flags.new_ca,
        .lease_ttl_ms = try lease_ttl_of(flags.lease_ttl_ms orelse file.lease_ttl_ms, diag),
        .lost_grace_ms = try lost_grace_of(flags.lost_grace_ms orelse file.lost_grace_ms, diag),
        .relays = try relays_valid(file.relays, diag),
        .cluster = try cluster_of(file.cluster, file.relays, diag),
    };
}

/// The trust domain, checked as a DNS name (ZC-E0106), and required when a relay checks its
/// upstream: a relayed run's certificate names it.
fn cluster_of(given: ?[]const u8, relays: []const Relay, diag: *Diag) Error![]const u8 {
    const fix = "set .cluster = \"example.org\", the trust domain of relayed runs' certificates";
    const cluster = given orelse "";
    if (cluster.len == 0) {
        for (relays) |relay| {
            if (!relay.plain) {
                return bad(diag, "relay {s} needs .cluster to be set", .{relay.name}, fix);
            }
        }
        return "";
    }
    if (x509_identity.dns_problem(cluster, constants.x509_cluster_bytes_max)) {
        return bad(diag, "the cluster {s} is not a DNS name of at most 63 bytes", .{cluster}, fix);
    }
    return cluster;
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
        } else if (std.mem.eql(u8, arg, "--insecure-listen")) {
            flags.insecure_listen = try value_of(args, &index, diag);
        } else if (std.mem.eql(u8, arg, "--tls-name")) {
            flags.tls_name = try value_of(args, &index, diag);
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

/// Reads and parses the policy file of the `trust` entry, once, at start (`trust_file.zig`).
/// Any problem is ZC-E0106 naming the file.
fn read_policy(arena: Allocator, io: std.Io, path: []const u8, diag: *Diag) Error!Trust {
    const loaded = try trust_file.read(arena, io, path, trust_options, diag);
    return .{ .path = loaded.path, .policy = loaded.policy };
}

fn policy_of(arena: Allocator, source: []const u8, path: []const u8, diag: *Diag) Error!Trust {
    const loaded = try trust_file.parse(arena, source, path, trust_options, diag);
    return .{ .path = loaded.path, .policy = loaded.policy };
}

const trust_options: trust_file.Options = .{
    .code = .E0106,
    .setting = "trust.policy",
    .user = "the server's user",
    .fix = policy_fix,
    .owner_fix = "chown it to root (or the server's user) and chmod go-w it: a policy that" ++
        " others can rewrite gates nothing",
};

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
    var file = try parse_zon(arena, source, path, diag);
    try read_anchors(arena, io, &file, diag);
    return file;
}

/// Puts the Ed25519 key of each relay's `server_ca` certificate in its `server_anchor`, as 64 hex
/// digits. A file that cannot be read, or is not one PEM certificate with an Ed25519 key, is
/// ZC-E0106 naming the relay.
fn read_anchors(arena: Allocator, io: std.Io, file: *File, diag: *Diag) Error!void {
    assert(file.relay_cas.len == file.relays.len);
    const relays = arena.dupe(Relay, file.relays) catch return error.OutOfMemory;
    for (relays, file.relay_cas) |*relay, path| {
        if (path.len == 0) continue;
        const limit: std.Io.Limit = .limited(constants.config_bytes_max);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch
            return bad(diag, "relay {s}: can't read the server_ca file {s}", .{
                relay.name, path,
            }, "check that the file exists and is readable");
        const anchor = pem_anchor(text) orelse
            return bad(diag, "relay {s}: {s} is not a PEM certificate with an Ed25519 key", .{
                relay.name, path,
            }, "give the PEM certificate of the CA that signs the upstream's certificate");
        relay.server_anchor = std.fmt.allocPrint(arena, "{x}", .{&anchor}) catch
            return error.OutOfMemory;
    }
    file.relays = relays;
}

/// The subject key of the first certificate in a PEM text, or null. Any line length and either
/// line ending; the key must be Ed25519 (the certificate is parsed as a foreign one).
pub fn pem_anchor(text: []const u8) ?[32]u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const start = (std.mem.find(u8, text, begin) orelse return null) + begin.len;
    const stop = start + (std.mem.find(u8, text[start..], end) orelse return null);
    var base64: [constants.x509_cert_bytes_max * 2]u8 = undefined;
    var length: usize = 0;
    for (text[start..stop]) |byte| {
        if (byte == '\n' or byte == '\r' or byte == ' ' or byte == '\t') continue;
        if (length == base64.len) return null;
        base64[length] = byte;
        length += 1;
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64[0..length]) catch return null;
    var der_bytes: [constants.x509_cert_bytes_max * 2]u8 = undefined;
    if (size > der_bytes.len) return null;
    decoder.decode(der_bytes[0..size], base64[0..length]) catch return null;
    var detail: x509.Detail = .{};
    // A CA of the upstream's own (the foreign profile) or one made like the cluster CA.
    const parsed = x509.parse_profile(der_bytes[0..size], .foreign_server, &detail) catch
        x509.parse_profile(der_bytes[0..size], .cluster, &detail) catch return null;
    const key = parsed.public_key.of(der_bytes[0..size]);
    if (key.len != 32) return null;
    return key[0..32].*;
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
    var file: File = .{ .relays = relays.relays, .relay_cas = relays.cas };
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
    "listen",       "insecure_listen", "tls_name",  "store",  "create_store",
    "lease_ttl_ms", "lost_grace_ms",   "state_dir", "relays", "cluster",
    "trust",
};

/// The relays of the file's root struct, after its field names are checked. A relay is
/// `.name = .{ .address = "host:port" }`; anything else in it is ZC-E0106 naming the relay.
fn relays_of(
    arena: Allocator,
    zoir: *const std.zig.Zoir,
    file_name: []const u8,
    diag: *Diag,
) Error!RelayList {
    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const names, const values = switch (root) {
        .struct_literal => |literal| .{ literal.names, literal.vals },
        .empty_literal => return .{},
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
    const node = found orelse return .{};
    return relay_list(arena, zoir, node, diag);
}

const RelayList = struct { relays: []const Relay = &.{}, cas: []const []const u8 = &.{} };

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
) Error!RelayList {
    const names, const values = switch (node.get(zoir)) {
        .struct_literal => |literal| .{ literal.names, literal.vals },
        .empty_literal => return .{},
        else => return bad(diag, "relays is not a struct of relays", .{}, relay_fix),
    };
    // Checked before anything is read, so a file with a hundred relays is refused by its count.
    if (names.len > constants.relays_max) {
        return bad(diag, "relays names {d} relays, over the limit of {d}", .{
            names.len, constants.relays_max,
        }, "name at most " ++ relays_max_text ++ " relays");
    }
    const list = arena.alloc(Relay, names.len) catch return error.OutOfMemory;
    const cas = arena.alloc([]const u8, names.len) catch return error.OutOfMemory;
    for (names, list, cas, 0..) |name_node, *slot, *ca, index| {
        // The Zoir is freed when `parse_zon` returns, so the text is copied out of it.
        const name = arena.dupe(u8, name_node.get(zoir)) catch return error.OutOfMemory;
        if (relay_name_problem(name)) |problem| {
            return bad(diag, "relay {s}: the name {s}", .{ name, problem }, relay_fix);
        }
        const entry = try relay_entry(zoir, values.at(@intCast(index)), name, diag);
        slot.* = .{
            .name = name,
            .address = arena.dupe(u8, entry.address) catch return error.OutOfMemory,
            .server_name = arena.dupe(u8, entry.server_name) catch return error.OutOfMemory,
            .plain = entry.plain,
        };
        ca.* = arena.dupe(u8, entry.server_ca) catch return error.OutOfMemory;
    }
    return .{ .relays = list, .cas = cas };
}

const relays_max_text = "8";
const relay_fix = "write it as .relays = .{ .name = .{ .address = \"host:port\", " ++
    ".server_name = \"upstream.example\", .server_ca = \"ca.pem\" } }";

const RelayEntry = struct {
    address: []const u8 = "",
    server_name: []const u8 = "",
    server_ca: []const u8 = "",
    plain: bool = false,
};

/// Whether a configuration may say `.plain = true`: only a Debug build's (the fake-runtime tests
/// that predate B4). A release build refuses it, so no deployed relay is plain TCP.
pub const relay_plain_allowed = builtin.mode == .debug;

fn relay_entry(
    zoir: *const std.zig.Zoir,
    node: std.zig.Zoir.Node.Index,
    name: []const u8,
    diag: *Diag,
) Error!RelayEntry {
    const fields = switch (node.get(zoir)) {
        .struct_literal => |literal| literal,
        else => return bad(diag, "relay {s} is not .{{ .address = ... }}", .{name}, relay_fix),
    };
    var entry: RelayEntry = .{};
    for (fields.names, 0..) |field_node, index| {
        const field = field_node.get(zoir);
        const value = fields.vals.at(@intCast(index)).get(zoir);
        if (std.mem.eql(u8, field, "plain")) {
            if (!relay_plain_allowed) {
                return bad(diag, "relay {s}: .plain is for tests only", .{name}, relay_fix);
            }
            entry.plain = switch (value) {
                .true => true,
                .false => false,
                else => return bad(diag, "relay {s}: .plain is not a bool", .{name}, relay_fix),
            };
            continue;
        }
        const text = switch (value) {
            .string_literal => |text| text,
            else => {
                const format = "relay {s}: .{s} is not a string";
                return bad(diag, format, .{ name, field }, relay_fix);
            },
        };
        if (std.mem.eql(u8, field, "address")) {
            entry.address = text;
        } else if (std.mem.eql(u8, field, "server_name")) {
            entry.server_name = text;
        } else if (std.mem.eql(u8, field, "server_ca")) {
            entry.server_ca = text;
        } else {
            return bad(diag, "relay {s} sets .{s}, which a relay does not have", .{
                name, field,
            }, relay_fix);
        }
    }
    if (entry.address.len == 0) {
        return bad(diag, "relay {s} has no .address", .{name}, relay_fix);
    }
    if (entry.plain) {
        if (entry.server_name.len > 0 or entry.server_ca.len > 0) {
            return bad(diag, "relay {s} is .plain and names a server", .{name}, relay_fix);
        }
        return entry;
    }
    if (entry.server_name.len == 0 or entry.server_ca.len == 0) {
        return bad(diag, "relay {s} needs .server_name and .server_ca", .{name}, relay_fix);
    }
    if (x509_identity.dns_problem(entry.server_name, constants.x509_dns_name_bytes_max)) {
        return bad(diag, "relay {s}: .server_name {s} is not a DNS name", .{
            name, entry.server_name,
        }, relay_fix);
    }
    if (entry.server_ca.len > constants.config_path_bytes_max) {
        return bad(diag, "relay {s}: .server_ca is longer than 1024 bytes", .{name}, relay_fix);
    }
    return entry;
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

/// An address of this machine's loopback interface: 127.0.0.0/8 or ::1. An IPv4-mapped address
/// (`::ffff:127.0.0.1`) is not: the check names only the plain forms (refused, not guessed).
pub fn is_loopback(address: IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &(@as([15]u8, @splat(0)) ++ [1]u8{1})),
    };
}

/// `--insecure-listen`: an address as for `--listen`, and on loopback (ZC-E0106 otherwise).
pub fn parse_insecure_listen(text: []const u8, diag: *Diag) Error!IpAddress {
    const address = try parse_listen(text, diag);
    if (is_loopback(address)) return address;
    return bad(diag, "--insecure-listen {s} is not a loopback address", .{text}, "serve plain " ++
        "HTTP on 127.0.0.1 or [::1] only, and everything else with --listen (TLS)");
}

/// The TLS name: a DNS name the certificate can carry (ZC-E0106 otherwise).
fn tls_name_of(name: []const u8, diag: *Diag) Error![]const u8 {
    if (x509_identity.dns_problem(name, constants.x509_dns_name_bytes_max)) {
        return bad(diag, "--tls-name {s} is not a DNS name", .{name}, "use letters, digits, " ++
            "hyphens and dots, as zcube-server or api.example.com");
    }
    return name;
}

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
    try testing.expectEqual(@as(u16, 9), config.listen.?.getPort());
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

test "ca issue-client and issue-node take a name, a scope (a client's), --out and --replace" {
    // Goal: the subcommands' parsing. Method: full commands and their defaults, --help anywhere,
    // then a missing name, a missing, repeated or unknown scope, a node given a scope, a repeated
    // --out, an unknown subcommand and --new-ca, each ZC-E0106.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var diag: Diag = undefined;
    diag.reset();
    const full = [_][]const u8{
        "ca", "issue-client", "ops-1", "--store", "sqlite:/a", "--scope", "jobs", "--out", "/o",
    };
    const command = (try load(arena, io, &full, &diag)).ca_issue;
    try testing.expectEqualStrings("ops-1", command.name);
    try testing.expectEqual(Scope.jobs, command.subject.client);
    try testing.expectEqualStrings("/o", command.out_dir);
    try testing.expectEqualStrings("/a", command.config.store.sqlite);
    try testing.expect(!command.replace);
    const short = [_][]const u8{ "ca", "issue-client", "ops-1", "--scope", "admin", "--replace" };
    const plain = (try load(arena, io, &short, &diag)).ca_issue;
    try testing.expectEqualStrings(".", plain.out_dir);
    try testing.expectEqual(Scope.admin, plain.subject.client);
    try testing.expect(plain.replace);
    const node = [_][]const u8{ "ca", "issue-node", "node-1", "--out", "/n" };
    const for_node = (try load(arena, io, &node, &diag)).ca_issue;
    try testing.expectEqual(Issue.Subject.node, for_node.subject);
    try testing.expectEqualStrings("node-1", for_node.name);
    try testing.expectEqualStrings("/n", for_node.out_dir);
    // `--help` anywhere after `ca` is the help, not a refusal.
    const helps = [_][]const []const u8{
        &.{ "ca", "--help" },
        &.{ "ca", "issue-client", "--help" },
        &.{ "ca", "issue-node", "node-1", "-h" },
    };
    for (helps) |args| try testing.expectEqual(Command.help, try load(arena, io, args, &diag));

    const refusals = [_][]const []const u8{
        &.{ "ca", "issue-client" },
        &.{ "ca", "issue-client", "--scope", "jobs" },
        &.{ "ca", "issue-client", "ops-1" },
        &.{ "ca", "issue-client", "ops-1", "--scope", "root" },
        &.{ "ca", "issue-client", "ops-1", "--scope" },
        &.{ "ca", "revoke", "ops-1" },
        &.{"ca"},
        &.{ "ca", "issue-client", "ops-1", "--scope", "jobs", "--new-ca" },
        &.{ "ca", "issue-client", "ops-1", "--scope", "jobs", "--bogus" },
        &.{ "ca", "issue-client", "ops-1", "--scope", "jobs", "--scope", "admin" },
        &.{ "ca", "issue-client", "ops-1", "--scope", "jobs", "--out", "a", "--out", "b" },
        &.{ "ca", "issue-client", "ops-1", "--scope", "jobs", "--version" },
        &.{ "ca", "issue-node" },
        &.{ "ca", "issue-node", "--out", "x" },
        &.{ "ca", "issue-node", "node-1", "--scope", "jobs" },
        &.{ "ca", "issue-node", "node-1", "--create-store" },
    };
    for (refusals) |args| {
        diag.reset();
        try expect_bad(load(arena, io, args, &diag), &diag);
    }
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
    const good = ".{ .cluster = \"prod.example\", .relays = .{ .botpike = .{" ++
        " .address = \"broker.botpike.com:8443\", .server_name = \"broker.botpike.com\"," ++
        " .server_ca = \"ca.pem\" }, .b2 = .{ .address = \"127.0.0.1:9\", .plain = true } } }";
    const file = try parse_zon(arena, good, "server.zon", &diag);
    const config = try merge(.{}, file, &diag);
    try testing.expectEqual(@as(usize, 2), config.relays.len);
    try testing.expectEqualStrings("botpike", config.relays[0].name);
    try testing.expectEqualStrings("broker.botpike.com:8443", config.relays[0].address);
    try testing.expectEqualStrings("broker.botpike.com", config.relays[0].server_name);
    try testing.expectEqualStrings("ca.pem", file.relay_cas[0]);
    try testing.expect(config.relays[1].plain);
    try testing.expectEqualStrings("prod.example", config.cluster);
    const none = try merge(.{}, try parse_zon(arena, ".{}", "server.zon", &diag), &diag);
    try testing.expectEqual(@as(usize, 0), none.relays.len);

    const bad_files = [_][:0]const u8{
        ".{ .relays = .{ .x = .{ .address = \"a:1\", .extra = 1 } } }",
        // B4: a relay checks its upstream, and its runs' certificates name a cluster.
        ".{ .cluster = \"c.example\", .relays = .{ .x = .{ .address = \"a:1\" } } }",
        ".{ .cluster = \"c.example\", .relays = .{ .x = .{ .address = \"a:1\"," ++
            " .server_name = \"a\" } } }",
        ".{ .cluster = \"c.example\", .relays = .{ .x = .{ .address = \"a:1\"," ++
            " .server_ca = \"ca.pem\" } } }",
        ".{ .cluster = \"c.example\", .relays = .{ .x = .{ .address = \"a:1\"," ++
            " .server_name = \"not a name\", .server_ca = \"ca.pem\" } } }",
        ".{ .relays = .{ .x = .{ .address = \"a:1\", .server_name = \"a\"," ++
            " .server_ca = \"ca.pem\" } } }",
        ".{ .cluster = \"no cluster\", .relays = .{ .x = .{ .address = \"a:1\"," ++
            " .server_name = \"a\", .server_ca = \"ca.pem\" } } }",
        ".{ .relays = .{ .x = .{ .address = \"a:1\", .plain = true, .server_name = \"a\" } } }",
        ".{ .relays = .{ .x = .{ .address = \"a:1\", .plain = 1 } } }",
        ".{ .relays = .{ .x = .{} } }",
        ".{ .relays = .{ .x = .{ .address = \"no-port\", .plain = true } } }",
        ".{ .relays = .{ .x = .{ .address = \"a:0\", .plain = true } } }",
        ".{ .relays = .{ .x = .{ .address = \"\", .plain = true } } }",
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

test "--insecure-listen is loopback only, and --tls-name is a DNS name (B7)" {
    var diag: Diag = undefined;
    diag.reset();
    _ = try parse_insecure_listen("127.0.0.1:7070", &diag);
    _ = try parse_insecure_listen("[::1]:7070", &diag);
    _ = try parse_insecure_listen("127.0.0.2:7070", &diag); // All of 127.0.0.0/8.
    const outside = [_][]const u8{
        "0.0.0.0:7070",
        "10.0.0.1:7070",
        "[::]:7070",
        "[::ffff:127.0.0.1]:7070", // IPv4-mapped: not taken for loopback.
    };
    for (outside) |input| {
        diag.reset();
        try expect_bad(parse_insecure_listen(input, &diag), &diag);
    }
    diag.reset();
    try testing.expectEqualStrings("api.example.com", try tls_name_of("api.example.com", &diag));
    for ([_][]const u8{ "", "has space", "-lead.example" }) |input| {
        diag.reset();
        try expect_bad(tls_name_of(input, &diag), &diag);
    }
}

test "relay plain: only a Debug build's configuration may say .plain" {
    // Goal: the plain test upstream demo-b3 relies on is never configurable in a release build.
    // Method: the same file in each mode; `demo-b3-build` also runs this test in ReleaseSafe.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const text = ".{ .relays = .{ .botpike = .{ .address = \"127.0.0.1:9090\", .plain = true } } }";
    const parsed = parse_zon(arena, text, "server.zon", &diag);
    if (builtin.mode == .debug) {
        const config = try merge(.{}, try parsed, &diag);
        try testing.expect(config.relays[0].plain);
    } else {
        try testing.expectError(error.BadConfig, parsed);
        try testing.expectEqual(@as(?@import("diag/codes.zig").Code, .E0106), diag.code);
    }
}

test "a relay's server_ca is a PEM certificate whose Ed25519 key becomes the anchor" {
    // Goal: `pem_anchor` reads the subject key of a PEM certificate in any line layout, and
    // refuses anything else. Method: a CA certificate encoded with 64- and 76-byte lines and
    // CRLF; then a truncated block, no block, and garbage base64.
    const x509_test = @import("x509_test.zig");
    const pair = try x509_test.ca_pair();
    var der_buffer: x509.Der = undefined;
    try x509_test.make_ca(&der_buffer);
    const der_bytes = der_buffer.slice();
    var encoded: [constants.x509_cert_bytes_max * 2]u8 = undefined;
    const base64 = std.base64.standard.Encoder.encode(&encoded, der_bytes);
    inline for (.{ 64, 76 }) |width| {
        var text: [constants.x509_cert_bytes_max * 3]u8 = undefined;
        var writer = std.Io.Writer.fixed(&text);
        try writer.writeAll("-----BEGIN CERTIFICATE-----\r\n");
        var at: usize = 0;
        while (at < base64.len) : (at += width) {
            try writer.print("{s}\r\n", .{base64[at..@min(at + width, base64.len)]});
        }
        try writer.writeAll("-----END CERTIFICATE-----\n");
        const anchor = pem_anchor(writer.buffered()).?;
        try testing.expectEqualSlices(u8, &pair.public_key.toBytes(), &anchor);
    }
    try testing.expect(pem_anchor("-----BEGIN CERTIFICATE-----\nMIIB\n") == null);
    try testing.expect(pem_anchor("no certificate here") == null);
    try testing.expect(pem_anchor("-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----") ==
        null);
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
