//! The relay `botpike` of demo-b3 and demo-b4 as a TLS upstream (B4 slice 4,
//! docs/decisions/2026-11-13-b4-slice2-fixes.md): the host makes an upstream CA and the
//! upstream's server certificate, names that CA as `server_ca` in the server's configuration,
//! and hands the guest (ops/demo-b3/guest.sh, `put` then `upstream`) the server certificate, its
//! key and the cluster CA's certificate, which the stock upstream pins along with the jobs' SPIFFE
//! IDs. Host-side test code.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const server_ca = @import("server_ca.zig");
const steps = @import("demo_c2_steps.zig");
const x509 = @import("x509.zig");

const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Host = demo_host.Host;

/// The cluster's name: the jobs' certificates read `spiffe://demo.zcube.test/job/<name>`.
pub const cluster = "demo.zcube.test";
/// The upstream's DNS name, checked by the relay against the upstream CA.
pub const server_name = "upstream.botpike.test";
/// The relay `botpike`'s upstream as the agent reaches it: the guest's loopback.
pub const upstream = "127.0.0.1:9443";

const hour_ms: u64 = 60 * 60 * 1000;
/// Base64 bytes per `guest.sh put`: a guest command is at most 1024 bytes.
const chunk_bytes = 800;

const upstream_ca_file = "upstream-ca.pem";
const server_cert_file = "server.pem";
const server_key_file = "server.key";

/// Makes the upstream's PKI in the work directory and writes the server's configuration, with
/// the relay `botpike` pinned to it. Returns the configuration's path.
pub fn prepare(host: *Host, now_ms: u64) ![]const u8 {
    const arena = host.arena();
    const cwd = std.Io.Dir.cwd();
    const ca_key = try key_of(host.work, "upstream ca");
    const server_key_seed = seed_of(host.work, "upstream server");
    const server_key = try Ed25519.KeyPair.generateDeterministic(server_key_seed);
    const lifetime: x509.Lifetime = .{
        .not_before_ms = now_ms - hour_ms,
        .not_after_ms = now_ms + 24 * hour_ms,
    };
    var ca_der: x509.Der = .{};
    try x509.issue_ca(&ca_der, ca_key, lifetime);
    var server_der: x509.Der = .{};
    try x509.issue_server(&server_der, ca_key, &.{
        .dns_name = server_name,
        .subject_key = server_key.public_key.toBytes(),
        .lifetime = lifetime,
    });
    const writes = [_][2][]const u8{
        .{ upstream_ca_file, try pem(arena, "CERTIFICATE", ca_der.slice()) },
        .{ server_cert_file, try pem(arena, "CERTIFICATE", server_der.slice()) },
        .{ server_key_file, try pkcs8(arena, server_key_seed) },
    };
    for (writes) |write| {
        const path = try host.path_in_work(write[0]);
        try cwd.writeFile(host.io, .{ .sub_path = path, .data = write[1] });
    }
    const config_path = try host.path_in_work("server.zon");
    const config_text = try std.fmt.allocPrint(arena,
        \\.{{
        \\    .cluster = "{s}",
        \\    .relays = .{{ .botpike = .{{
        \\        .address = "{s}",
        \\        .server_name = "{s}",
        \\        .server_ca = "{s}",
        \\    }} }},
        \\}}
        \\
    , .{ cluster, upstream, server_name, try host.path_in_work(upstream_ca_file) });
    try cwd.writeFile(host.io, .{ .sub_path = config_path, .data = config_text });
    return config_path;
}

/// Starts the guest's TLS upstream for `jobs` (comma separated), once the server has made the
/// cluster CA: the guest gets the server's certificate and key and the cluster CA's certificate.
pub fn upstream_up(demo: *steps.Demo, jobs: []const u8) !void {
    const host = demo.host;
    const cluster_ca = try cluster_ca_pem(host);
    const sends = [_][2][]const u8{
        .{ server_cert_file, try read_work(host, server_cert_file) },
        .{ server_key_file, try read_work(host, server_key_file) },
        .{ "cluster-ca.pem", cluster_ca },
    };
    for (sends) |send| try put(demo, send[0], send[1]);
    _ = try demo.guest(0, "upstream {s} {s}", .{ cluster, jobs });
    host.say("  botpike's upstream is a stock TLS 1.3 server (Python's ssl, OpenSSL) with a " ++
        "certificate for {s} from an upstream CA the server pins; it pins the cluster CA " ++
        "and admits only spiffe://{s}/job/{{{s}}}", .{ server_name, cluster, jobs });
}

fn put(demo: *steps.Demo, file: []const u8, data: []const u8) !void {
    const arena = demo.arena();
    const encoder = std.base64.standard.Encoder;
    const text = try arena.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(text, data);
    var at: usize = 0;
    while (at < text.len) : (at += chunk_bytes) {
        const chunk = text[at..@min(at + chunk_bytes, text.len)];
        _ = try demo.guest(0, "put {s} {s}", .{ file, chunk });
    }
}

/// The cluster CA's certificate, as the server wrote it into its state directory
/// (`ca-<key hash>.crt`, `server_ca.zig`).
fn cluster_ca_pem(host: *Host) ![]const u8 {
    const dir_path = try host.path_in_work("server-state");
    var dir = try std.Io.Dir.cwd().openDir(host.io, dir_path, .{ .iterate = true });
    defer dir.close(host.io);
    var iterator = dir.iterate();
    var found: ?[]const u8 = null;
    while (try iterator.next(host.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "ca")) continue;
        if (!std.mem.endsWith(u8, entry.name, server_ca.cert_extension)) continue;
        if (found != null) return host.fail("two CA certificates in {s}", .{dir_path});
        found = try host.arena().dupe(u8, entry.name);
    }
    const name = found orelse return host.fail("no CA certificate in {s}", .{dir_path});
    return dir.readFileAlloc(host.io, name, host.arena(), .unlimited);
}

fn read_work(host: *Host, name: []const u8) ![]const u8 {
    const path = try host.path_in_work(name);
    return std.Io.Dir.cwd().readFileAlloc(host.io, path, host.arena(), .unlimited);
}

/// A seed of this run's (unique) work directory and `what`: the upstream's keys differ per run.
fn seed_of(work: []const u8, what: []const u8) [32]u8 {
    var seed: [32]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(work);
    hasher.update(what);
    hasher.final(&seed);
    return seed;
}

fn key_of(work: []const u8, what: []const u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed_of(work, what));
}

fn pem(arena: Allocator, label: []const u8, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const body = try arena.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(body, bytes);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "-----BEGIN {s}-----\n", .{label});
    var at: usize = 0;
    while (at < body.len) : (at += 64) {
        try out.print(arena, "{s}\n", .{body[at..@min(at + 64, body.len)]});
    }
    try out.print(arena, "-----END {s}-----\n", .{label});
    return out.items;
}

/// A PKCS#8 Ed25519 private key (RFC 8410) for `seed`.
fn pkcs8(arena: Allocator, seed: [32]u8) ![]u8 {
    const prefix = [_]u8{
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
        0x04, 0x22, 0x04, 0x20,
    };
    return pem(arena, "PRIVATE KEY", &(prefix ++ seed));
}

comptime {
    assert(chunk_bytes % 4 == 0); // Chunks of whole base64 quanta.
}

test "the upstream's key is PKCS#8 for Ed25519, 48 bytes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try pkcs8(arena_state.allocator(), @splat(7));
    try std.testing.expect(std.mem.startsWith(u8, text, "-----BEGIN PRIVATE KEY-----\n"));
    try std.testing.expectEqual(@as(usize, 28 + 64 + 1 + 26), text.len);
}
