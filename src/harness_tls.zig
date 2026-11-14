//! The harnesses' side of the API over TLS (B7 slice 6, docs/decisions/
//! 2026-11-14-b7-slice6-console-over-tls.md): the demos and smokes talk to `--listen` as an
//! operator would, with certificates `zcube-server ca issue-client` and `ca issue-node` wrote.
//! `--insecure-listen` stays for `zcube local` and the tests of that listener. Shell code: it runs
//! `zcube-server`, reads files and loads keys.

const std = @import("std");
const assert = std.debug.assert;
const api_tls_client = @import("api_tls_client.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;

pub const Credentials = api_tls_client.Credentials;

/// The longest `zcube-server ca issue-*` may run, and the most it may print.
const command_timeout_ms: u32 = 60 * 1000;
const output_bytes_max: usize = 64 * 1024;

pub const Error = error{ HarnessTls, OutOfMemory };

/// The server's CA, the certificates issued from it, and the credentials loaded from them.
pub const Pki = struct {
    io: std.Io,
    arena: Allocator,
    server_exe: []const u8,
    /// The server's `--store` and `--state-dir`, as it was started with them.
    store: []const u8,
    state_dir: []const u8,
    /// Where `ca issue-*` writes (`--out`).
    certs: []const u8,
    /// The CA certificate the server wrote, once found.
    ca: ?[]const u8 = null,
    /// Why the last call failed, or what the last `ca issue-*` printed.
    said: []const u8 = "",

    /// The one `ca-<hash>.crt` (or `ca.crt`) in the state directory; null until the server
    /// wrote it.
    pub fn find_ca(pki: *Pki) Error!?[]const u8 {
        if (pki.ca) |path| return path;
        const dir = std.Io.Dir.cwd().openDir(pki.io, pki.state_dir, .{ .iterate = true }) catch
            return null;
        defer dir.close(pki.io);
        var iterator = dir.iterate();
        var found: ?[]const u8 = null;
        for (0..256) |_| {
            const entry = (iterator.next(pki.io) catch return null) orelse break;
            if (!std.mem.startsWith(u8, entry.name, "ca")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".crt")) continue;
            if (found != null) return pki.fail("two CA certificates in {s}", .{pki.state_dir});
            found = try std.fmt.allocPrint(pki.arena, "{s}/{s}", .{ pki.state_dir, entry.name });
        }
        pki.ca = found;
        return found;
    }

    /// `zcube-server ca issue-client NAME --scope SCOPE`, or `ca issue-node NAME` when `scope` is
    /// null, unless `<certs>/NAME.crt` is already there (a certificate lives 7 days, longer than
    /// any run). True if it was issued now.
    pub fn issue(pki: *Pki, name: []const u8, scope: ?[]const u8) Error!bool {
        assert(name.len > 0);
        if (pki.exists(try pki.cert_path(name))) return false;
        std.Io.Dir.cwd().createDirPath(pki.io, pki.certs) catch |err|
            return pki.fail("can't make {s}: {t}", .{ pki.certs, err });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(pki.arena, &.{ pki.server_exe, "ca" });
        if (scope) |s| {
            try argv.appendSlice(pki.arena, &.{ "issue-client", name, "--scope", s });
        } else {
            try argv.appendSlice(pki.arena, &.{ "issue-node", name });
        }
        try argv.appendSlice(pki.arena, &.{
            "--store", pki.store, "--state-dir", pki.state_dir, "--out", pki.certs,
        });
        const result = std.process.run(pki.arena, pki.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(output_bytes_max),
            .stderr_limit = .limited(output_bytes_max),
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(command_timeout_ms),
                .clock = .awake,
            } },
        }) catch |err| return pki.fail("zcube-server ca did not finish: {t}", .{err});
        pki.said = try std.mem.concat(pki.arena, u8, &.{ result.stdout, result.stderr });
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return pki.fail("zcube-server ca {s} {s} failed: {s}", .{
            argv.items[2], name, pki.said,
        });
        return true;
    }

    /// The arguments a client or agent passes: `--ca`, `--cert`, `--key`.
    pub fn flags(pki: *Pki, name: []const u8) Error![6][]const u8 {
        const ca = (try pki.find_ca()) orelse return pki.fail("no CA certificate yet", .{});
        return .{
            "--ca",   ca,
            "--cert", try pki.cert_path(name),
            "--key",  try pki.key_path(name),
        };
    }

    /// Puts `ZCUBE_CA`, `ZCUBE_CERT` and `ZCUBE_KEY` for `name` into `environ`.
    pub fn export_to(pki: *Pki, environ: *std.process.Environ.Map, name: []const u8) Error!void {
        const ca = (try pki.find_ca()) orelse return pki.fail("no CA certificate yet", .{});
        try environ.put("ZCUBE_CA", ca);
        try environ.put("ZCUBE_CERT", try pki.cert_path(name));
        try environ.put("ZCUBE_KEY", try pki.key_path(name));
    }

    /// Loads `name`'s certificate and key with the CA pinned. Lives as long as the arena.
    pub fn load(pki: *Pki, name: []const u8) Error!*Credentials {
        const ca = (try pki.find_ca()) orelse return pki.fail("no CA certificate yet", .{});
        const credentials = try pki.arena.create(Credentials);
        var diag: Diag = undefined;
        diag.reset();
        credentials.load(pki.io, .{
            .ca = ca,
            .cert = try pki.cert_path(name),
            .key = try pki.key_path(name),
        }, &diag) catch |err| return pki.fail("loading {s}'s credentials: {t}", .{ name, err });
        return credentials;
    }

    pub fn cert_path(pki: *Pki, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(pki.arena, "{s}/{s}.crt", .{ pki.certs, name });
    }

    pub fn key_path(pki: *Pki, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(pki.arena, "{s}/{s}.key", .{ pki.certs, name });
    }

    fn exists(pki: *Pki, path: []const u8) bool {
        std.Io.Dir.cwd().access(pki.io, path, .{}) catch return false;
        return true;
    }

    fn fail(pki: *Pki, comptime format: []const u8, args: anytype) Error {
        pki.said = std.fmt.allocPrint(pki.arena, format, args) catch "out of memory";
        return error.HarnessTls;
    }
};
