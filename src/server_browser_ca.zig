//! The browser CA (B7 slice 6, docs/decisions/2026-11-14-b7-slice6-console-over-tls.md): a
//! second per-cluster CA, on ECDSA P-256, beside the cluster CA of `server_ca.zig`. It signs the
//! server's P-256 certificate, which only a client that does not offer Ed25519 (a browser) gets,
//! and the client certificates of `ca issue-client --p12`. It never signs a node certificate, and
//! the cluster CA never signs a P-256 key: the two profiles' parsers refuse each other's
//! algorithm, so a certificate cannot cross paths (`x509_p256.zig`).
//!
//! Shell code. `<stem>-browser.key` (a 32-byte seed as 64 hex digits, mode 0600; the P-256
//! scalar is derived from it by `generateDeterministic`, an HMAC-DRBG over the seed) sits
//! beside the cluster key `<stem>.key`, and `<stem>-browser.crt` (PEM) is its certificate, which a
//! browser's user imports as a trusted root. A missing key is made when the server starts: no
//! browser certificate can exist without it, so a new one locks nobody out who was not already
//! out (a key that was lost locks out the browser certificates it signed, and nothing else).
//! `ca issue-client --p12` never makes one.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const files = @import("peer_files.zig");
const p256 = @import("x509_p256.zig");
const peer_ca = @import("peer_ca.zig");
const pem_mod = @import("pem.zig");
const secure_random = @import("secure_random.zig");
const server_ca = @import("server_ca.zig");
const x509 = @import("x509.zig");

const Diag = diag_mod.Diag;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Error = server_ca.Error;
pub const KeyPair = p256.KeyPair;

const suffix = "-browser";
/// `<stem>-browser.key` fits the cluster key's name buffer with room to spare.
pub const name_bytes_max = server_ca.key_name_bytes_max + suffix.len;

/// A CA certificate with less than this left is made again at the next start, as the cluster's.
const renew_ahead_ms: u64 = 30 * 24 * 60 * 60 * 1000;

/// `<stem>-browser.key` for the cluster key `<stem>.key`.
pub fn key_name_for(key_name: []const u8, buffer: *[name_bytes_max]u8) []const u8 {
    assert(std.mem.endsWith(u8, key_name, ".key"));
    const stem = key_name[0 .. key_name.len - ".key".len];
    return std.fmt.bufPrint(buffer, "{s}{s}.key", .{ stem, suffix }) catch
        unreachable; // The cluster key's name fits `key_name_bytes_max`.
}

/// `<stem>-browser.crt` for the cluster key `<stem>.key`.
pub fn cert_name_for(key_name: []const u8, buffer: *[name_bytes_max]u8) []const u8 {
    assert(std.mem.endsWith(u8, key_name, ".key"));
    const stem = key_name[0 .. key_name.len - ".key".len];
    return std.fmt.bufPrint(buffer, "{s}{s}.crt", .{ stem, suffix }) catch
        unreachable; // As above.
}

/// Whether a missing key is made (the server) or refused (`ca issue-client --p12`).
pub const Absent = enum { make, refuse };

/// The browser CA's key from `state_dir` (which `server_ca.open` has made and checked), made if
/// absent and `absent` is `.make`; its certificate is written beside it when absent or near its
/// end. With no state directory (a memory store) the key is made in memory. On failure `diag`
/// says why (ZC-E0806).
pub fn open(
    io: std.Io,
    ca: *const peer_ca.Ca,
    state_dir: ?[]const u8,
    key_name: []const u8,
    absent: Absent,
    quiet: bool,
    diag: *Diag,
) Error!KeyPair {
    assert(diag.code == null);
    const path = state_dir orelse {
        assert(absent == .make);
        var seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        return make_key(io, &seed, diag);
    };
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
        return files.unusable(diag, path, key_name, "open the directory of", @errorName(err));
    };
    defer dir.close(io);
    var name_buffer: [name_bytes_max]u8 = undefined;
    const name = key_name_for(key_name, &name_buffer);
    const key = try load_or_make(io, dir, path, name, absent, diag);
    var cert_buffer: [name_bytes_max]u8 = undefined;
    const cert_name = cert_name_for(key_name, &cert_buffer);
    try ensure_certificate(io, ca, key, dir, path, cert_name, quiet, diag);
    return key;
}

fn load_or_make(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    name: []const u8,
    absent: Absent,
    diag: *Diag,
) Error!KeyPair {
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (try files.read_seed(io, dir, path, name, diag)) |loaded| {
        seed = loaded;
        return Ecdsa.KeyPair.generateDeterministic(seed) catch
            return files.unusable(diag, path, name, "use", "it is not a usable P-256 key");
    }
    if (absent == .refuse) {
        diag.raise(.E0806);
        diag.cause("no browser CA key {s} in {s}: has the server run on this store since " ++
            "B7 slice 6?", .{ name, path });
        diag.fix(.{ .sentence = "start the server once with this --store: it makes the key" });
        return error.Failed;
    }
    const key = try make_key(io, &seed, diag);
    try files.write_seed(io, dir, path, name, seed, diag);
    return key;
}

/// A fresh key; its seed is left in `seed` for the caller to write. `generateDeterministic`
/// derives the scalar from the seed by HMAC-DRBG, retrying inside until it is below n, and fails
/// only on a zero scalar (about 2^-256); a seed that does so is replaced by a new draw, at most
/// `x509_p256_key_attempts_max` times, and then the random source is reported broken (ZC-E0821).
pub fn make_key(io: std.Io, seed: *[32]u8, diag: *Diag) Error!KeyPair {
    comptime assert(constants.x509_p256_key_attempts_max > 1);
    var attempt: u32 = 0;
    while (attempt < constants.x509_p256_key_attempts_max) : (attempt += 1) {
        secure_random.fill(io, seed, diag, "the browser CA key") catch |err| return switch (err) {
            error.Unavailable => error.Failed,
            error.Canceled => error.Canceled,
        };
        return Ecdsa.KeyPair.generateDeterministic(seed.*) catch continue;
    }
    assert(attempt == constants.x509_p256_key_attempts_max);
    secure_random.raise(diag, "a P-256 key: every seed it gave derived a zero scalar");
    return error.Failed;
}

/// Writes the CA certificate unless the file already holds this key's, valid a month ahead. A
/// file that is replaced (near its end, or another key's) is said on stderr unless `quiet`:
/// every browser that trusts the old one must import the new one as a root.
fn ensure_certificate(
    io: std.Io,
    ca: *const peer_ca.Ca,
    key: KeyPair,
    dir: std.Io.Dir,
    path: []const u8,
    name: []const u8,
    quiet: bool,
    diag: *Diag,
) Error!void {
    var text: [pem_mod.bytes_max]u8 = undefined;
    const found = try files.read_bounded(io, dir, path, name, .secret, &text, diag);
    if (found == .bytes) {
        var der_buffer: [constants.x509_cert_bytes_max]u8 = undefined;
        if (pem_mod.decode(found.bytes, .certificate, &der_buffer)) |bytes| {
            const later_ms = ca.wall.now_ms() +| renew_ahead_ms;
            const expect: p256.Expect = .{ .kind = .ca, .name = null };
            if (p256.verify(bytes, p256.point_of(key), later_ms, expect)) |_| return else |_| {}
        }
    }
    var certificate: p256.Der = .{};
    const lifetime = ca.window(constants.x509_ca_ttl_ms_max) catch |err| {
        diag.raise(peer_ca.code_of(err));
        diag.cause("can't make the browser CA certificate {s} in {s}: {s}", .{
            name, path, peer_ca.reason(err),
        });
        diag.fix(.{ .sentence = "set the clock; the certificate is made again at the next start" });
        return error.Failed;
    };
    p256.issue_ca(&certificate, key, lifetime) catch unreachable; // A CA's own fixed fields.
    const pem = pem_mod.encode(&text, .certificate, certificate.slice());
    try files.write(io, dir, path, name, pem, 0o600, diag);
    if (found == .bytes and !quiet) say_remade(io, path, name);
}

/// One line on stderr: the browser CA certificate was made again, so browsers re-import it.
fn say_remade(io: std.Io, path: []const u8, name: []const u8) void {
    assert(path.len > 0);
    assert(name.len > 0);
    var line: [constants.state_path_bytes_max + 256]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "zcube-server: made the browser CA certificate {s} " ++
        "in {s} again (it ended within 30 days or named another key); import it again as a " ++
        "trusted root in every browser that opens the console\n", .{ name, path }) catch
        return; // A path this long is printed by nothing else either.
    std.Io.File.stderr().writeStreamingAll(io, text) catch {}; // Nowhere else.
}

/// What a server certificate on the browser path names: `--tls-name`, then each `--tls-san`.
pub const ServerNames = struct {
    dns_name: []const u8,
    sans: []const p256.San,
};

/// A server certificate for `key` from the browser CA, valid `ttl_ms` from now.
pub fn issue_server(
    out: *p256.Der,
    ca: *const peer_ca.Ca,
    browser: KeyPair,
    names: ServerNames,
    key: KeyPair,
    ttl_ms: u64,
) (peer_ca.CertificateError || p256.Error)!void {
    const lifetime = try ca.window(ttl_ms);
    try p256.issue_server(out, browser, &.{
        .dns_name = names.dns_name,
        .sans = names.sans,
        .subject_key = p256.point_of(key),
        .lifetime = lifetime,
    });
}

/// A client certificate for `name` with `scope` from the browser CA, valid `ttl_ms` from now. A
/// name in the `revoked` file is refused (`error.Removed`), as on the cluster path.
pub fn issue_client(
    out: *p256.Der,
    ca: *const peer_ca.Ca,
    browser: KeyPair,
    name: []const u8,
    scope: x509.Scope,
    key: KeyPair,
    ttl_ms: u64,
) peer_ca.IssueCertificateError!void {
    if (ca.revoked.contains(.client, name)) return error.Removed;
    const lifetime = try ca.window(ttl_ms);
    var cluster_buffer: [peer_ca.cluster_bytes]u8 = undefined;
    try p256.issue_client(out, browser, &.{
        .cluster = ca.cluster(&cluster_buffer),
        .client = name,
        .scope = scope,
        .subject_key = p256.point_of(key),
        .lifetime = lifetime,
    });
}

test "browser CA: key names sit beside the cluster key's" {
    var buffer: [name_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("ca-browser.key", key_name_for("ca.key", &buffer));
    try std.testing.expectEqualStrings("ca-browser.crt", cert_name_for("ca.key", &buffer));
    const hashed = "ca-0123456789abcdef.key";
    try std.testing.expectEqualStrings(
        "ca-0123456789abcdef-browser.key",
        key_name_for(hashed, &buffer),
    );
}
