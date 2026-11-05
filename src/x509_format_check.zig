//! `zig build x509-format`: the certificates `x509.zig` writes, read by programs that are not ours:
//! `openssl x509`, `openssl verify`, `keytool -printcert` and the JDK's `CertificateFactory`
//! (`tools/mtls/X509Dump.java`). The writer and the parser agree with each other by construction,
//! so only a third implementation can say the bytes are X.509. Test tooling: openssl and a JDK
//! are not product dependencies (docs/decisions/2026-11-04-mtls-identity-extension-oid.md).
//! Prints to stdout only; the build runner counts stderr as a failure. Never in `check`.
//!
//! Usage: `x509_format_check <X509Dump.java>`.

const std = @import("std");
const x509 = @import("x509.zig");
const identity = @import("x509_identity.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Allocator = std.mem.Allocator;

const now_ms: u64 = 1_700_000_000_000;
const hour_ms: u64 = 3_600_000;
const window: x509.Lifetime = .{
    .not_before_ms = now_ms - hour_ms,
    .not_after_ms = now_ms + hour_ms,
};

const Check = struct {
    io: std.Io,
    gpa: Allocator,
    work: []const u8,
    failures: u32 = 0,

    fn say(check: *Check, comptime format: []const u8, args: anytype) void {
        var buffer: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "x509-format: " ++ format ++ "\n",
            args,
        ) catch return;
        std.Io.File.stdout().writeStreamingAll(check.io, line) catch {}; // Nowhere else to say it.
    }

    /// Runs a program; returns its standard output and whether it exited 0.
    fn run(check: *Check, argv: []const []const u8) !struct { out: []u8, ok: bool } {
        const result = try std.process.run(check.gpa, check.io, .{
            .argv = argv,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
        defer check.gpa.free(result.stderr);
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) check.say("{s} failed: {s}", .{ argv[0], result.stderr });
        return .{ .out = result.stdout, .ok = ok };
    }

    fn expect(check: *Check, ok: bool, comptime what: []const u8, args: anytype) void {
        if (ok) return;
        check.say("FAIL " ++ what, args);
        check.failures += 1;
    }

    fn path(check: *Check, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(check.gpa, "{s}/{s}", .{ check.work, name });
    }

    fn write(check: *Check, name: []const u8, bytes: []const u8) !void {
        const full = try check.path(name);
        defer check.gpa.free(full);
        try std.Io.Dir.cwd().writeFile(check.io, .{ .sub_path = full, .data = bytes });
    }

    /// `openssl x509 -text` must succeed and mention every needle.
    fn openssl_text(check: *Check, name: []const u8, needles: []const []const u8) !void {
        const full = try check.path(name);
        defer check.gpa.free(full);
        const argv = [_][]const u8{
            "openssl", "x509", "-inform", "der", "-in", full, "-noout", "-text",
        };
        const result = try check.run(&argv);
        defer check.gpa.free(result.out);
        check.expect(result.ok, "openssl x509 reads {s}", .{name});
        for (needles) |needle| {
            const found = std.mem.find(u8, result.out, needle) != null;
            check.expect(found, "openssl x509 on {s} shows \"{s}\"", .{ name, needle });
        }
    }

    fn to_pem(check: *Check, name: []const u8) !void {
        const from = try check.path(name);
        defer check.gpa.free(from);
        const to = try std.fmt.allocPrint(check.gpa, "{s}/{s}.pem", .{ check.work, name });
        defer check.gpa.free(to);
        const argv = [_][]const u8{ "openssl", "x509", "-inform", "der", "-in", from, "-out", to };
        const result = try check.run(&argv);
        check.gpa.free(result.out);
        check.expect(result.ok, "openssl converts {s} to PEM", .{name});
    }

    fn openssl_verify(check: *Check, name: []const u8, purpose: []const u8, want: bool) !void {
        const root = try std.fmt.allocPrint(check.gpa, "{s}/ca.der.pem", .{check.work});
        defer check.gpa.free(root);
        const leaf = try std.fmt.allocPrint(check.gpa, "{s}/{s}.pem", .{ check.work, name });
        defer check.gpa.free(leaf);
        const argv = [_][]const u8{
            "openssl", "verify", "-no_check_time",
            "-CAfile", root,     "-purpose",
            purpose,   leaf,
        };
        const result = std.process.run(check.gpa, check.io, .{
            .argv = &argv,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch return error.RunFailed;
        defer check.gpa.free(result.stdout);
        defer check.gpa.free(result.stderr);
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        const text = "openssl verify {s} as {s}: {s}";
        check.expect(ok == want, text, .{ name, purpose, result.stdout });
    }
};

fn make_certificates(check: *Check) !void {
    const ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA));
    const labels = [_]identity.Label{
        .{ .key = "app", .value = "broker" },
        .{ .key = "env", .value = "prod" },
    };
    var ca_cert: x509.Der = .{};
    try x509.issue_ca(&ca_cert, ca, window);
    const workload_key = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const workload_request: x509.WorkloadRequest = .{
        .cluster = "prod.example",
        .service = "broker-1",
        .subject_key = workload_key.public_key.toBytes(),
        .identity = .{ .image_digest = @splat(0x5A), .placement_epoch = 42, .labels = &labels },
        .lifetime = window,
    };
    var workload_cert: x509.Der = .{};
    try x509.issue_workload(&workload_cert, ca, &workload_request);
    const server_key = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const server_request: x509.ServerRequest = .{
        .dns_name = "broker.botpike.com",
        .subject_key = server_key.public_key.toBytes(),
        .lifetime = window,
    };
    var server_cert: x509.Der = .{};
    try x509.issue_server(&server_cert, ca, &server_request);
    try check.write("ca.der", ca_cert.slice());
    try check.write("workload.der", workload_cert.slice());
    try check.write("server.der", server_cert.slice());
}

fn run_openssl(check: *Check) !void {
    try check.openssl_text("ca.der", &.{ "ED25519", "CA:TRUE", "pathlen:0", "Certificate Sign" });
    try check.openssl_text("workload.der", &.{
        "ED25519",
        "URI:spiffe://prod.example/service/broker-1",
        "TLS Web Client Authentication",
        "Digital Signature",
        "CN = broker-1",
    });
    try check.openssl_text("server.der", &.{
        "DNS:broker.botpike.com",
        "TLS Web Server Authentication",
    });
    for ([_][]const u8{ "ca.der", "workload.der", "server.der" }) |name| try check.to_pem(name);
    try check.openssl_verify("workload.der", "sslclient", true);
    try check.openssl_verify("workload.der", "sslserver", false);
    try check.openssl_verify("server.der", "sslserver", true);
    try check.openssl_verify("server.der", "sslclient", false);
}

fn run_java(check: *Check, dumper: []const u8) !void {
    for ([_][]const u8{ "workload.der", "server.der" }) |name| {
        const full = try check.path(name);
        defer check.gpa.free(full);
        const argv = [_][]const u8{ "keytool", "-printcert", "-file", full };
        const result = try check.run(&argv);
        defer check.gpa.free(result.out);
        check.expect(result.ok, "keytool reads {s}", .{name});
        check.expect(
            std.mem.find(u8, result.out, "Ed25519") != null,
            "keytool names Ed25519 for {s}",
            .{name},
        );
    }
    const ca = try check.path("ca.der");
    defer check.gpa.free(ca);
    const workload = try check.path("workload.der");
    defer check.gpa.free(workload);
    const server = try check.path("server.der");
    defer check.gpa.free(server);
    const argv = [_][]const u8{ "java", dumper, ca, workload, server };
    const result = try check.run(&argv);
    defer check.gpa.free(result.out);
    check.expect(
        result.ok,
        "the JDK's CertificateFactory accepts and verifies all three: {s}",
        .{result.out},
    );
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 2) return 2;
    const base = init.environ_map.get("TMPDIR") orelse "/tmp";
    const stamp = std.Io.Clock.real.now(io).toMilliseconds();
    const work = std.fmt.allocPrint(init.arena.allocator(), "{s}/zcube-x509-format-{d}-{d}", .{
        base, std.os.linux.getpid(), stamp,
    }) catch return 2;
    std.Io.Dir.cwd().createDirPath(io, work) catch return 2;
    defer std.Io.Dir.cwd().deleteTree(io, work) catch {}; // Best effort: it is in /tmp.
    var check: Check = .{ .io = io, .gpa = init.gpa, .work = work };
    make_certificates(&check) catch return 2;
    run_openssl(&check) catch |err| check.say("openssl run failed: {t}", .{err});
    run_java(&check, args[1]) catch |err| check.say("java run failed: {t}", .{err});
    if (check.failures > 0) return 1;
    check.say("PASS (openssl x509, openssl verify, keytool, CertificateFactory)", .{});
    return 0;
}
