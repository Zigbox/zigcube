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

/// The most entries `find_ca` reads in the server's state directory.
const entries_max: u32 = 256;

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

    /// The one CA certificate in the state directory, by the server's own names
    /// (`server_ca.key_name_for` and `cert_name_for`: `ca.crt` or `ca-<16 hex>.crt`); null until
    /// the server wrote it. Only a missing directory means "not yet": any other error fails.
    pub fn find_ca(pki: *Pki) Error!?[]const u8 {
        if (pki.ca) |path| return path;
        const cwd = std.Io.Dir.cwd();
        const opened = cwd.openDir(pki.io, pki.state_dir, .{ .iterate = true });
        const dir = opened catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return pki.fail("can't open {s}: {t}", .{ pki.state_dir, err }),
        };
        defer dir.close(pki.io);
        var iterator = dir.iterate();
        var found: ?[]const u8 = null;
        for (0..entries_max) |_| {
            const next = iterator.next(pki.io) catch |err|
                return pki.fail("can't list {s}: {t}", .{ pki.state_dir, err });
            const entry = next orelse break;
            if (!is_ca_cert_name(entry.name)) continue;
            if (found != null) return pki.fail("two CA certificates in {s}", .{pki.state_dir});
            found = try std.fmt.allocPrint(pki.arena, "{s}/{s}", .{ pki.state_dir, entry.name });
        } else return pki.fail("more than {d} entries in {s}", .{ entries_max, pki.state_dir });
        pki.ca = found;
        return found;
    }

    /// `zcube-server ca issue-client NAME --scope SCOPE`, or `ca issue-node NAME` when `scope` is
    /// null, unless `<certs>/NAME.crt` and `NAME.key` are both already there (a certificate lives
    /// 7 days, longer than any run). True if it was issued now. Exit 0 with both files written is
    /// success; anything else fails, with what the command printed in `said`.
    pub fn issue(pki: *Pki, name: []const u8, scope: ?[]const u8) Error!bool {
        assert(name.len > 0);
        const cert = try pki.cert_path(name);
        const key = try pki.key_path(name);
        const had_cert = pki.exists(cert);
        const had_key = pki.exists(key);
        if (had_cert and had_key) return false;
        if (had_cert or had_key) return pki.fail("{s} has only one of {s}.crt and {s}.key", .{
            pki.certs, name, name,
        });
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
        const code: ?u8 = switch (result.term) {
            .exited => |code| code,
            else => null,
        };
        if (code == null) return pki.fail("zcube-server ca {s} {s} was killed: {s}", .{
            argv.items[2], name, pki.said,
        });
        if (code.? != 0) return pki.fail("zcube-server ca {s} {s} exited {d}: {s}", .{
            argv.items[2], name, code.?, pki.said,
        });
        if (!pki.exists(cert) or !pki.exists(key)) {
            return pki.fail("zcube-server ca {s} {s} exited 0 but wrote no {s} and {s}", .{
                argv.items[2], name, cert, key,
            });
        }
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

    /// `ca.crt`, or `ca-` and 16 lowercase hex digits and `.crt`: the names `server_ca` gives.
    pub fn is_ca_cert_name(name: []const u8) bool {
        if (std.mem.eql(u8, name, "ca.crt")) return true;
        const prefix = "ca-";
        const suffix = ".crt";
        if (name.len != prefix.len + 16 + suffix.len) return false;
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        if (!std.mem.endsWith(u8, name, suffix)) return false;
        for (name[prefix.len..][0..16]) |c| {
            const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            if (!hex) return false;
        }
        return true;
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

const testing = std.testing;

/// A `Pki` over a fresh temporary directory: `state` is its state directory, `certs` its `--out`.
const TestPki = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    root: []const u8,
    pki: Pki,

    fn init(test_pki: *TestPki, server_exe: []const u8) !void {
        test_pki.tmp = testing.tmpDir(.{});
        test_pki.arena_state = .init(testing.allocator);
        const arena = test_pki.arena_state.allocator();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try test_pki.tmp.dir.realPath(testing.io, &buffer);
        test_pki.root = try arena.dupe(u8, buffer[0..length]);
        test_pki.pki = .{
            .io = testing.io,
            .arena = arena,
            .server_exe = server_exe,
            .store = "memory",
            .state_dir = try std.fmt.allocPrint(arena, "{s}/state", .{test_pki.root}),
            .certs = try std.fmt.allocPrint(arena, "{s}/certs", .{test_pki.root}),
        };
    }

    fn deinit(test_pki: *TestPki) void {
        test_pki.arena_state.deinit();
        test_pki.tmp.cleanup();
    }

    fn put(test_pki: *TestPki, path: []const u8) !void {
        const dir = test_pki.tmp.dir;
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
        try test_pki.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "x\n" });
    }

    /// A stand-in for `zcube-server` that writes `<out>/<name>.crt` and `.key` (as
    /// `ca issue-node NAME --store S --state-dir D --out OUT` passes them) and exits `code`.
    fn script(test_pki: *TestPki, name: []const u8, code: u8) ![]const u8 {
        var body_buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buffer,
            \\#!/bin/sh
            \\touch "$9/$3.crt" "$9/$3.key"
            \\exit {d}
            \\
        , .{code});
        const file = try test_pki.tmp.dir.createFile(testing.io, name, .{
            .permissions = .fromMode(0o755),
        });
        try file.writeStreamingAll(testing.io, body);
        file.close(testing.io);
        return std.fmt.allocPrint(test_pki.arena_state.allocator(), "{s}/{s}", .{
            test_pki.root, name,
        });
    }
};

test "harness_tls: find_ca waits for a missing state directory and finds the server's names only" {
    var t: TestPki = undefined;
    try t.init("/nonexistent/zcube-server");
    defer t.deinit();
    try testing.expectEqual(null, try t.pki.find_ca());
    try t.tmp.dir.createDirPath(testing.io, "state");
    try testing.expectEqual(null, try t.pki.find_ca());
    // Near misses of `server_ca`'s names: none is a CA certificate.
    for ([_][]const u8{
        "state/ca.key",                  "state/cab.crt",
        "state/ca-0123456789abcdef.key", "state/ca-0123456789abcde.crt",
        "state/ca-0123456789ABCDEF.crt", "state/ca-0123456789abcdeg.crt",
        "state/ca.crt.tmp",              "state/xca.crt",
    }) |path| try t.put(path);
    try testing.expectEqual(null, try t.pki.find_ca());
    try t.put("state/ca-0123456789abcdef.crt");
    const found = (try t.pki.find_ca()).?;
    try testing.expect(std.mem.endsWith(u8, found, "/state/ca-0123456789abcdef.crt"));
    try testing.expectEqualStrings(found, (try t.pki.find_ca()).?);
}

test "harness_tls: find_ca finds ca.crt, and fails on two CAs" {
    var t: TestPki = undefined;
    try t.init("/nonexistent/zcube-server");
    defer t.deinit();
    try t.put("state/ca.crt");
    try testing.expect(std.mem.endsWith(u8, (try t.pki.find_ca()).?, "/state/ca.crt"));
    t.pki.ca = null;
    try t.put("state/ca-fedcba9876543210.crt");
    try testing.expectError(error.HarnessTls, t.pki.find_ca());
    try testing.expect(std.mem.find(u8, t.pki.said, "two CA certificates") != null);
}

test "harness_tls: a state directory that is not a directory fails, not waits" {
    var t: TestPki = undefined;
    try t.init("/nonexistent/zcube-server");
    defer t.deinit();
    try t.put("state");
    try testing.expectError(error.HarnessTls, t.pki.find_ca());
    try testing.expect(std.mem.find(u8, t.pki.said, "can't open") != null);
}

test "harness_tls: issue skips a name only when both its files are there" {
    var t: TestPki = undefined;
    // The command does not exist: a skip never runs it, and a run fails.
    try t.init("/nonexistent/zcube-server");
    defer t.deinit();
    try t.put("certs/node1.crt");
    try t.put("certs/node1.key");
    try testing.expectEqual(false, try t.pki.issue("node1", null));
    try t.put("certs/node2.crt");
    try testing.expectError(error.HarnessTls, t.pki.issue("node2", null));
    try testing.expect(std.mem.find(u8, t.pki.said, "only one of") != null);
    try t.put("certs/node3.key");
    try testing.expectError(error.HarnessTls, t.pki.issue("node3", null));
    try testing.expectError(error.HarnessTls, t.pki.issue("node4", null));
    try testing.expect(std.mem.find(u8, t.pki.said, "did not finish") != null);
}

test "harness_tls: issue succeeds on exit 0 with both files, and fails on any other exit" {
    var t: TestPki = undefined;
    try t.init("/nonexistent/zcube-server");
    defer t.deinit();
    t.pki.server_exe = try t.script("ok.sh", 0);
    try testing.expectEqual(true, try t.pki.issue("node1", null));
    try testing.expectEqual(false, try t.pki.issue("node1", null));
    // It wrote both files, but its exit says it failed: reverting the exit check passes this.
    t.pki.server_exe = try t.script("exit3.sh", 3);
    try testing.expectError(error.HarnessTls, t.pki.issue("node2", "admin"));
    try testing.expect(std.mem.find(u8, t.pki.said, "exited 3") != null);
    // Exit 0 with nothing written.
    t.pki.server_exe = "/bin/true";
    try testing.expectError(error.HarnessTls, t.pki.issue("node3", null));
    try testing.expect(std.mem.find(u8, t.pki.said, "exited 0 but wrote no") != null);
}
