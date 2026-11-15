//! The API's clients over TLS (B7 slice 3, docs/mtls.md, "The API over TLS"): the CA a client
//! pins, the certificate and key it presents, and one request and its reply over `tls_conn`.
//! Shared by `zcube` (`cli_http.zig`) and `zcube-agent` (`agent_http.zig`). Shell code: files and
//! sockets.
//!
//! The three files are the ones `zcube-server ca issue-client` (or `issue-node`) and the server's
//! state directory hold: the CA certificate (`ca-<hash>.crt`, or `ca.crt` for a store with no
//! file of its own; PEM), a `client` or `node` certificate (PEM) and its
//! Ed25519 key (PKCS#8 PEM, mode 0600). A file that cannot be used is ZC-E0806 and names the
//! file. The client pins the CA's key: the server's certificate must be signed by it and carry
//! the DNS name `server_name` (`--tls-name`, default `zcube-server`).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const pem = @import("pem.zig");
const peer_files = @import("peer_files.zig");
const peer_stream = @import("peer_stream.zig");
const tls_client = @import("tls_client.zig");
const tls_conn = @import("tls_conn.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

pub const Error = error{ Failed, OutOfMemory };
/// Loading the files only reads them: it fails, it never runs out of memory.
pub const LoadError = peer_files.Error;

/// The DNS name a client expects in the server's certificate when it is given none; the server's
/// `--tls-name` default.
pub const server_name_default = "zcube-server";

/// Where a client's files are, as the user gave them.
pub const Paths = struct {
    ca: []const u8,
    cert: []const u8,
    key: []const u8,
    /// The DNS name the server's certificate must carry. Not copied: it outlives the client.
    server_name: []const u8 = server_name_default,
};

/// What a client presents and pins, loaded once.
pub const Credentials = struct {
    anchor: [32]u8,
    server_name: []const u8,
    certificate: x509.Der,
    key_pair: Ed25519.KeyPair,
    /// The chain `options` hands the TLS client: the one certificate.
    chain: [1][]const u8,

    /// Reads and checks the three files: the CA certificate is a CA's, the certificate is a
    /// `client` or `node` certificate signed by that CA, and the key is the certificate's.
    pub fn load(c: *Credentials, io: std.Io, paths: Paths, diag: *Diag) LoadError!void {
        try c.load_ca(io, paths.ca, paths.server_name, diag);
        try c.load_identity(io, paths.cert, paths.key, diag);
    }

    /// Pins the CA of the certificate at `path`; nothing is presented until `load_identity` or
    /// `present`.
    pub fn load_ca(
        c: *Credentials,
        io: std.Io,
        path: []const u8,
        server_name: []const u8,
        diag: *Diag,
    ) LoadError!void {
        assert(diag.code == null);
        assert(server_name.len > 0);
        c.server_name = server_name;
        c.chain = undefined;
        c.certificate = .{};
        c.anchor = try read_anchor(io, path, diag);
    }

    /// Reads the certificate to present and its key.
    pub fn load_identity(
        c: *Credentials,
        io: std.Io,
        cert: []const u8,
        key: []const u8,
        diag: *Diag,
    ) LoadError!void {
        try read_certificate(io, cert, &c.certificate, diag);
        const bytes = c.certificate.slice();
        const parsed = x509.parse(bytes) catch |err| {
            return refuse(diag, cert, "parse", x509.reason(err));
        };
        if (parsed.kind != .client and parsed.kind != .node) {
            return refuse(diag, cert, "use", "it is not a client or node certificate");
        }
        const issuer = parsed.text(parsed.issuer_cn, bytes);
        if (!std.mem.eql(u8, issuer, &x509.ca_cn(c.anchor))) {
            return refuse(diag, cert, "use", "it was not issued by the CA of --ca");
        }
        c.key_pair = try read_key(io, key, diag);
        const public = parsed.text(parsed.public_key, bytes);
        if (!std.mem.eql(u8, public, &c.key_pair.public_key.toBytes())) {
            std.crypto.secureZero(u8, std.mem.asBytes(&c.key_pair));
            return refuse(diag, key, "use", "it is not the key of the certificate");
        }
    }

    /// The agent's bootstrap certificate (`--cert`, from `ca issue-node`) must be a node
    /// certificate for `node` itself, valid at wall time `now_ms`: never an admin's, another
    /// node's or an expired one (B7 slice 3).
    pub fn require_node(
        c: *const Credentials,
        cert: []const u8,
        node: []const u8,
        now_ms: u64,
        diag: *Diag,
    ) LoadError!void {
        const why = node_problem(c.anchor, &c.certificate, c.key_pair, node, now_ms) orelse
            return;
        return peer_files.unusable_fix(diag, dir_of(cert), base_of(cert), "use", why, node_fix);
    }

    /// Presents `certificate` with `key_pair` from now on (the agent's own `node.crt`) when it is
    /// a node certificate for `node` that the CA of `--ca` issued, valid at wall time `now_ms`,
    /// for `key_pair`'s key. Else changes nothing and returns why not.
    pub fn present(
        c: *Credentials,
        certificate: *const x509.Der,
        key_pair: Ed25519.KeyPair,
        node: []const u8,
        now_ms: u64,
    ) ?[]const u8 {
        if (node_problem(c.anchor, certificate, key_pair, node, now_ms)) |why| return why;
        c.certificate = certificate.*;
        c.key_pair = key_pair;
        return null;
    }

    /// True once there is a certificate to present.
    pub fn ready(c: *const Credentials) bool {
        return c.certificate.slice().len > 0;
    }

    pub fn deinit(c: *Credentials) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&c.key_pair));
    }

    pub fn options(c: *Credentials, io: std.Io, fd: std.posix.fd_t) tls_conn.Options {
        c.chain = .{c.certificate.slice()};
        return .{
            .io = io,
            .fd = fd,
            .anchor = c.anchor,
            .server_name = c.server_name,
            .client_auth = .{ .required = .{
                .certificates = &c.chain,
                .signer = tls_client.key_pair_signer(&c.key_pair),
            } },
        };
    }
};

/// How one exchange ended. `reply` holds what was read either way.
pub const Ending = enum {
    /// `whole` said the reply is complete, or the server closed the connection cleanly.
    done,
    /// No byte came before `read_end_ms` said so; `diag` is untouched.
    silent,
    /// The connection failed; `diag` holds the TLS code (ZC-E0810 to ZC-E0821).
    failed,
};

pub const Exchange = struct {
    reply: []const u8,
    ending: Ending,
};

/// One request over TLS on the connected socket `fd` (the caller closes it): the handshake,
/// `parts` sent in order, and the reply read until `whole` says it is complete, the server
/// closes, or it would pass `limit` bytes (then `reply` is longer than `limit`). Each read waits
/// until `read_end_ms(context)` (CLOCK_BOOTTIME). The connection is closed with close_notify.
pub fn exchange(
    c: *Credentials,
    io: std.Io,
    fd: std.posix.fd_t,
    arena: Allocator,
    parts: []const []const u8,
    limit: usize,
    whole: *const fn (raw: []const u8) bool,
    end_ms: u64,
    diag: *Diag,
) Error!Exchange {
    assert(diag.code == null);
    const conn = try arena.create(tls_conn.Conn);
    defer conn.deinit();
    const options = c.options(io, fd);
    conn.open(&options, diag) catch |err| return ended(err, &.{});
    for (parts) |part| {
        conn.write(part, end_ms, diag) catch |err| return ended(err, &.{});
    }
    conn.flush(end_ms, diag) catch |err| return ended(err, &.{});
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (!whole(out.items)) {
        const length = conn.read(&chunk, end_ms, diag) catch |err| return ended(err, out.items);
        if (length == 0) break;
        try out.appendSlice(arena, chunk[0..length]);
        if (out.items.len > limit) break;
    }
    var goodbye: Diag = undefined;
    goodbye.reset();
    conn.close(@min(end_ms, peer_stream.boot_ms(io) + 1000), &goodbye) catch {}; // Answered.
    return .{ .reply = out.items, .ending = .done };
}

fn ended(err: tls_conn.Error, reply: []const u8) Exchange {
    return switch (err) {
        error.Timeout => .{ .reply = reply, .ending = .silent },
        error.Refused, error.Closed, error.Canceled => .{ .reply = reply, .ending = .failed },
    };
}

/// True once `raw` holds a head that promises a `Content-Length` and that many bytes after it.
pub fn reply_is_whole(raw: []const u8) bool {
    const split = std.mem.find(u8, raw, "\r\n\r\n") orelse return false;
    var lines = std.mem.splitSequence(u8, raw[0..split], "\r\n");
    _ = lines.next(); // The status line.
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const promised = std.fmt.parseInt(usize, value, 10) catch return false;
        return raw.len - (split + 4) >= promised;
    }
    return false;
}

/// Why `certificate` cannot be an agent's for `node` at wall time `now_ms`, or null: it must be
/// a node certificate the CA `anchor` issued, in its window, naming `node`, of `key_pair`.
fn node_problem(
    anchor: [32]u8,
    certificate: *const x509.Der,
    key_pair: Ed25519.KeyPair,
    node: []const u8,
    now_ms: u64,
) ?[]const u8 {
    const bytes = certificate.slice();
    if (bytes.len == 0) return "it does not exist";
    const expect: x509.Expect = .{ .kind = .node, .name = null };
    const parsed = x509.verify(bytes, anchor, now_ms, expect) catch |err| return x509.reason(err);
    const wrong_node = "it names another node than this agent's --node";
    const spiffe = x509_identity.spiffe_parse(parsed.name.of(bytes)) catch return wrong_node;
    if (spiffe.path != .node) return wrong_node;
    if (!std.mem.eql(u8, spiffe.name, node)) return wrong_node;
    const public = key_pair.public_key.toBytes();
    if (!std.mem.eql(u8, parsed.public_key.of(bytes), &public)) {
        return "it is not the certificate of the key beside it";
    }
    return null;
}

const node_fix = "on the server host, run zcube-server ca issue-node NAME --replace for this " ++
    "node and give the agent the two files as --cert and --key (docs/agent.md)";

/// Where an agent's identity is, for `present_node`: its stored `node.crt` over its `peer.key`
/// (either null when absent) in the state directory `where`, and `--cert`/`--key` if given.
pub const NodeIdentity = struct {
    where: []const u8,
    node: []const u8,
    stored: ?*const x509.Der,
    key_pair: ?Ed25519.KeyPair,
    cert: ?[]const u8,
    key: ?[]const u8,
};

/// What an agent presents (B7 slices 3 and 5, docs/agent.md "Node certificates"), after
/// `load_ca`: its stored `node.crt` when it is usable at wall time `now_ms` (that CA's, for
/// `node`, of `peer.key`, in its window), else `--cert` and `--key`, which must be a node
/// certificate for `node` valid now. With neither, ZC-E0806 says why `node.crt` was refused and
/// how to get back in. Null when the stored `node.crt` is presented; else why it was not, for
/// the caller's note. Shared by the agent and its `fetch` child (B7 slice 7).
pub fn present_node(
    c: *Credentials,
    io: std.Io,
    identity: NodeIdentity,
    now_ms: u64,
    diag: *Diag,
) LoadError!?[]const u8 {
    assert(diag.code == null);
    var stored_problem: []const u8 = "it does not exist";
    if (identity.stored) |certificate| {
        if (identity.key_pair) |key_pair| {
            const problem = c.present(certificate, key_pair, identity.node, now_ms);
            stored_problem = problem orelse return null;
        } else stored_problem = "there is no usable peer.key beside it";
    }
    const cert = identity.cert orelse
        return refuse_no_identity(diag, identity.where, stored_problem);
    assert(identity.key != null); // `--cert` and `--key` come together (agent_config.zig).
    c.load_identity(io, cert, identity.key.?, diag) catch |err| {
        diag.cause("the stored node.crt was not used either: {s}", .{stored_problem});
        return err;
    };
    c.require_node(cert, identity.node, now_ms, diag) catch |err| {
        diag.cause("the stored node.crt was not used either: {s}", .{stored_problem});
        return err;
    };
    return stored_problem;
}

/// Reads the PEM certificate at `path` into `out`; ZC-E0806 when it cannot be read or parsed.
pub fn read_certificate_file(
    io: std.Io,
    path: []const u8,
    out: *x509.Der,
    diag: *Diag,
) LoadError!void {
    return read_certificate(io, path, out, diag);
}

/// The agent has no usable `node.crt` in `where` (`why` says what is wrong with it) and no
/// `--cert`: one start-up error, with the way back in.
pub fn refuse_no_identity(diag: *Diag, where: []const u8, why: []const u8) LoadError {
    var buffer: [160]u8 = undefined;
    const because = std.fmt.bufPrint(&buffer, "{s}, and --cert was not given", .{why}) catch why;
    return peer_files.unusable_fix(diag, where, "node.crt", "use", because, node_fix);
}

fn refuse(diag: *Diag, path: []const u8, verb: []const u8, why: []const u8) LoadError {
    const fix = "give the files zcube-server ca issue-client (a client) or ca issue-node (an " ++
        "agent) wrote, and the CA's ca-<hash>.crt from the server's state directory " ++
        "(docs/mtls.md)";
    return peer_files.unusable_fix(diag, dir_of(path), base_of(path), verb, why, fix);
}

fn dir_of(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn base_of(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// The bytes of `path`, checked with `guard`; a file that is absent is refused too.
fn read_file(
    io: std.Io,
    path: []const u8,
    guard: peer_files.Guard,
    buffer: []u8,
    diag: *Diag,
) LoadError![]u8 {
    if (path.len == 0 or base_of(path).len == 0) return refuse(diag, path, "read", "no file named");
    var dir = std.Io.Dir.cwd().openDir(io, dir_of(path), .{}) catch |err| {
        return refuse(diag, path, "read", @errorName(err));
    };
    defer dir.close(io);
    const found = try peer_files.read(io, dir, dir_of(path), base_of(path), guard, buffer, diag);
    return found orelse refuse(diag, path, "read", "it does not exist");
}

fn read_certificate(io: std.Io, path: []const u8, out: *x509.Der, diag: *Diag) LoadError!void {
    var text: [pem.bytes_max]u8 = undefined;
    const bytes = try read_file(io, path, .anchor, &text, diag);
    var der: [constants.x509_cert_bytes_max]u8 = undefined;
    const decoded = pem.decode(bytes, .certificate, &der) orelse
        return refuse(diag, path, "parse", "it is not one PEM CERTIFICATE block");
    out.* = .{};
    out.start = @intCast(out.bytes.len - decoded.len);
    @memcpy(out.bytes[out.start..], decoded);
}

fn read_anchor(io: std.Io, path: []const u8, diag: *Diag) LoadError![32]u8 {
    var certificate: x509.Der = .{};
    try read_certificate(io, path, &certificate, diag);
    const bytes = certificate.slice();
    const parsed = x509.parse(bytes) catch |err| {
        return refuse(diag, path, "parse", x509.reason(err));
    };
    if (parsed.kind != .ca) return refuse(diag, path, "use", "it is not a CA certificate");
    const public = parsed.text(parsed.public_key, bytes);
    if (public.len != 32) return refuse(diag, path, "use", "its key is not an Ed25519 key");
    return public[0..32].*;
}

fn read_key(io: std.Io, path: []const u8, diag: *Diag) LoadError!Ed25519.KeyPair {
    var text: [pem.bytes_max]u8 = undefined;
    defer std.crypto.secureZero(u8, &text);
    const bytes = try read_file(io, path, .secret, &text, diag);
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (!pem.decode_key(bytes, &seed)) {
        return refuse(diag, path, "parse", "it is not an Ed25519 PRIVATE KEY block");
    }
    return Ed25519.KeyPair.generateDeterministic(seed) catch
        refuse(diag, path, "use", "its key is not a usable Ed25519 key");
}
