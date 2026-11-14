//! `zig build mtls-interop`, the server rows (B7 slice 4, docs/briefs/b7.md): stock clients
//! against a real `zcube-server --listen`. **An interop check, not a demo.** Shell code: it starts
//! processes and reads files and the real clock.
//!
//! It starts `zcube-server` on SQLite, which makes its CA, asks `zcube-server ca issue-client` for
//! a `jobs` certificate, and issues two more with the code under test (`x509.zig`): one of the
//! same CA that has expired, and one from another CA. Then `openssl s_client` and a JDK 21
//! `SSLSocket` client (`ops/mtls-interop/InteropClient.java`) each call the API:
//!
//!   - with the `jobs` certificate: `GET /v1/jobs` is 200 and `GET /v1/status` is 403, so the
//!     server named the caller from a stock client's certificate and held it to its scope;
//!   - with no certificate, the expired one, or the other CA's: refused at the handshake. The
//!     client reports the alert, and the server logs the refusal's code (`tls: ZC-E08..`).
//!
//! Both clients pin the CA and check the server's certificate names `zcube-server`.

const std = @import("std");
const assert = std.debug.assert;
const diag_mod = @import("diag.zig");
const interop = @import("mtls_interop.zig");
const peer_ca = @import("peer_ca.zig");
const peer_files = @import("peer_files.zig");
const peer_stream = @import("peer_stream.zig");
const pem = @import("pem.zig");
const server_ca = @import("server_ca.zig");
const x509 = @import("x509.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const Harness = interop.Harness;

const hour_ms: u64 = 3_600_000;
const tls_name = "zcube-server";
const client_name = "app";
/// The seed of the key in the expired and the other CA's certificates.
const client_seed: [32]u8 = @splat(0x3C);

/// `java_eager` writes its request at once after its Finished (`-Dinterop.eager=true`): the
/// refusal's alert must still reach it, not a reset (`linger_refused` in `server_http.zig`).
const ClientKind = enum { openssl, java, java_eager };
const Cert = enum { jobs, none, expired, other_ca };
/// A certificate file and its key file, or null for no certificate.
const Files = ?[2][]const u8;

const Expect = union(enum) {
    accepted,
    refused: struct {
        /// The server's log line for the refusal holds this (its code and cause).
        server_says: []const u8,
        /// What the client printed holds this (the alert, in the client's words).
        client_says: []const u8,
    },
};

const Row = struct {
    name: []const u8,
    client: ClientKind,
    cert: Cert,
    expect: Expect,
};

fn refused(server_says: []const u8, client_says: []const u8) Expect {
    return .{ .refused = .{ .server_says = server_says, .client_says = client_says } };
}

const no_certificate = "tls: ZC-E0814: the client sent no certificate";
const expired_says = "tls: ZC-E0811: the client's certificate has expired";
const other_ca_says = "tls: ZC-E0810: the client's certificate was refused: its issuer is not";

const rows = [_]Row{
    .{
        .name = "zcube-server serves s_client with a jobs certificate",
        .client = .openssl,
        .cert = .jobs,
        .expect = .accepted,
    },
    .{
        .name = "zcube-server serves the java client with a jobs certificate",
        .client = .java,
        .cert = .jobs,
        .expect = .accepted,
    },
    .{
        .name = "zcube-server refuses s_client with no certificate",
        .client = .openssl,
        .cert = .none,
        .expect = refused(no_certificate, "SSL alert number 116"),
    },
    .{
        .name = "zcube-server refuses the java client with no certificate",
        .client = .java,
        .cert = .none,
        .expect = refused(no_certificate, "(certificate_required)"),
    },
    .{
        .name = "zcube-server refuses s_client with an expired certificate",
        .client = .openssl,
        .cert = .expired,
        .expect = refused(expired_says, "SSL alert number 45"),
    },
    .{
        .name = "zcube-server refuses the java client with an expired certificate",
        .client = .java,
        .cert = .expired,
        .expect = refused(expired_says, "(certificate_expired)"),
    },
    .{
        .name = "zcube-server refuses s_client with another CA's certificate",
        .client = .openssl,
        .cert = .other_ca,
        .expect = refused(other_ca_says, "SSL alert number 48"),
    },
    .{
        .name = "zcube-server refuses the java client with another CA's certificate",
        .client = .java,
        .cert = .other_ca,
        .expect = refused(other_ca_says, "(unknown_ca)"),
    },
    .{
        .name = "zcube-server's alert reaches a java client that writes at once, no certificate",
        .client = .java_eager,
        .cert = .none,
        .expect = refused(no_certificate, "(certificate_required)"),
    },
    .{
        .name = "zcube-server's alert reaches a java client that writes at once, another CA",
        .client = .java_eager,
        .cert = .other_ca,
        .expect = refused(other_ca_says, "(unknown_ca)"),
    },
};

/// The running `zcube-server` and the files the clients read.
const Zcube = struct {
    child: std.process.Child,
    port: u16,
    /// The server's stdout and stderr.
    log: []const u8,
    /// The state directory: the store, the CA, the client certificates.
    dir: []const u8,
    /// The CA certificate the clients pin.
    ca: []const u8,
};

/// Runs every row against one server, each counted by `interop.finish`.
pub fn run(h: *Harness, server_exe: []const u8) void {
    var zcube: Zcube = undefined;
    start(h, &zcube, server_exe) catch |err| {
        interop.finish(h, "zcube-server starts and issues the client certificates", err);
        return;
    };
    defer zcube.child.kill(h.io);
    interop.finish(h, "zcube-server starts and issues the client certificates", {});
    for (&rows) |*row| {
        _ = h.scratch.reset(.retain_capacity);
        interop.finish(h, row.name, run_row(h, &zcube, row));
    }
}

fn start(h: *Harness, zcube: *Zcube, server_exe: []const u8) !void {
    const arena = h.arena.allocator();
    zcube.dir = h.path("zcube");
    try std.Io.Dir.cwd().createDirPath(h.io, zcube.dir);
    zcube.port = try interop.free_port(h.io);
    zcube.log = h.path("zcube-server.log");
    const store = try std.fmt.allocPrint(arena, "sqlite:{s}/z.db", .{zcube.dir});
    const listen = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{zcube.port});
    const file = try std.Io.Dir.cwd().createFile(h.io, zcube.log, .{});
    defer file.close(h.io);
    // The kernel ends the server with the harness, whatever ends the harness.
    zcube.child = try std.process.spawn(h.io, .{
        .argv = &.{
            "setpriv",        "--pdeathsig", "KILL",    server_exe,
            "--listen",       listen,        "--store", store,
            "--create-store", "--quiet",
        },
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .{ .file = file },
    });
    errdefer zcube.child.kill(h.io);
    const up = wait_text(h, zcube.log, 0, "listening on", 20_000);
    try h.check(up, "zcube-server did not say it is listening: {s}", .{log_since(h, zcube.log, 0)});
    var key_buffer: [server_ca.key_name_bytes_max]u8 = undefined;
    const database = try std.fmt.allocPrint(arena, "{s}/z.db", .{zcube.dir});
    const key_name = server_ca.key_name_for(database, &key_buffer);
    var cert_buffer: [server_ca.key_name_bytes_max]u8 = undefined;
    const ca_name = server_ca.cert_name_for(key_name, &cert_buffer);
    zcube.ca = try std.fmt.allocPrint(arena, "{s}/{s}", .{ zcube.dir, ca_name });
    _ = try interop.run_tool(h, &.{
        server_exe, "ca",  "issue-client", client_name, "--scope", "jobs",
        "--store",  store, "--out",        zcube.dir,
    });
    try issue_by_hand(h, zcube, key_name);
}

/// `expired.crt` (this CA, expired an hour ago) and `other-ca.crt` (another CA, valid), both for
/// the client `app` with the scope `jobs`, and their key.
fn issue_by_hand(h: *Harness, zcube: *const Zcube, key_name: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(h.io, zcube.dir, .{});
    defer dir.close(h.io);
    var diag: Diag = undefined;
    diag.reset();
    var seed = (try peer_files.read_seed(h.io, dir, zcube.dir, key_name, &diag)) orelse
        return error.NoCaKey;
    defer std.crypto.secureZero(u8, &seed);
    const ca = try Ed25519.KeyPair.generateDeterministic(seed);
    const now = peer_stream.wall_ms(h.io);
    try issue_one(h, zcube, "expired", ca, .{
        .not_before_ms = now - 3 * hour_ms,
        .not_after_ms = now - hour_ms,
    });
    try issue_one(h, zcube, "other-ca", h.pki.other_ca, .{
        .not_before_ms = now - hour_ms,
        .not_after_ms = now + hour_ms,
    });
    var text: [pem.bytes_max]u8 = undefined;
    const key = try std.fmt.allocPrint(h.arena.allocator(), "{s}/hand.key", .{zcube.dir});
    const data = pem.encode_key(&text, &client_seed);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = key, .data = data });
}

fn issue_one(
    h: *Harness,
    zcube: *const Zcube,
    name: []const u8,
    ca: Ed25519.KeyPair,
    lifetime: x509.Lifetime,
) !void {
    const key = try Ed25519.KeyPair.generateDeterministic(client_seed);
    var cluster_buffer: [peer_ca.cluster_bytes]u8 = undefined;
    var certificate: x509.Der = .{};
    try x509.issue_client(&certificate, ca, &.{
        .cluster = peer_ca.cluster_of(ca.public_key.toBytes(), &cluster_buffer),
        .client = client_name,
        .scope = .jobs,
        .subject_key = key.public_key.toBytes(),
        .lifetime = lifetime,
    });
    var text: [pem.bytes_max]u8 = undefined;
    const path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/{s}.crt", .{ zcube.dir, name });
    const data = pem.encode(&text, .certificate, certificate.slice());
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = path, .data = data });
}

/// The certificate and key files a row presents, or null for none.
fn files_of(h: *Harness, zcube: *const Zcube, cert: Cert) !Files {
    const arena = h.scratch.allocator();
    const stem: []const u8 = switch (cert) {
        .none => return null,
        .jobs => client_name,
        .expired => "expired",
        .other_ca => "other-ca",
    };
    const key: []const u8 = if (cert == .jobs) client_name else "hand";
    return .{
        try std.fmt.allocPrint(arena, "{s}/{s}.crt", .{ zcube.dir, stem }),
        try std.fmt.allocPrint(arena, "{s}/{s}.key", .{ zcube.dir, key }),
    };
}

fn run_row(h: *Harness, zcube: *Zcube, row: *const Row) !void {
    const mark = log_since(h, zcube.log, 0).len;
    const said = try call(h, zcube, row, "/v1/jobs");
    switch (row.expect) {
        .accepted => {
            try h.check(contains(said, "HTTP/1.1 200"), "GET /v1/jobs: {s}", .{said});
            const scoped = try call(h, zcube, row, "/v1/status");
            try h.check(contains(scoped, "HTTP/1.1 403"), "GET /v1/status: {s}", .{scoped});
            const log = log_since(h, zcube.log, mark);
            try h.check(!contains(log, "tls: ZC-"), "the server logged a refusal: {s}", .{log});
        },
        .refused => |want| {
            try h.check(!contains(said, "HTTP/1.1"), "answered: {s}", .{said});
            const found = contains(said, want.client_says);
            try h.check(found, "the client said {s}, not \"{s}\"", .{ said, want.client_says });
            const logged = wait_text(h, zcube.log, mark, want.server_says, interop.step_ms);
            const log = log_since(h, zcube.log, mark);
            try h.check(logged, "the server logged {s}, not \"{s}\"", .{ log, want.server_says });
            h.say("      -> client: {s}", .{last_line(said)});
            h.say("      -> server: {s}", .{std.mem.trim(u8, log, "\n")});
        },
    }
}

/// One `GET path` by the row's client; what it printed.
fn call(h: *Harness, zcube: *const Zcube, row: *const Row, path: []const u8) ![]const u8 {
    const files = try files_of(h, zcube, row.cert);
    return switch (row.client) {
        .openssl => s_client(h, zcube, files, path),
        .java => java_client(h, zcube, files, path, false),
        .java_eager => java_client(h, zcube, files, path, true),
    };
}

fn java_client(
    h: *Harness,
    zcube: *const Zcube,
    files: Files,
    path: []const u8,
    eager: bool,
) ![]const u8 {
    const scratch = h.scratch.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    const port = try std.fmt.allocPrint(scratch, "{d}", .{zcube.port});
    const eager_flag = if (eager) "-Dinterop.eager=true" else "-Dinterop.eager=false";
    try argv.appendSlice(scratch, &.{
        h.java, eager_flag, "-cp", h.classes, "InteropClient", zcube.ca, port, tls_name, path,
    });
    if (files) |pair| try argv.appendSlice(scratch, &pair);
    return interop.run_tool(h, argv.items);
}

fn s_client(h: *Harness, zcube: *const Zcube, files: Files, path: []const u8) ![]const u8 {
    const scratch = h.scratch.allocator();
    const request = try std.fmt.allocPrint(
        scratch,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ path, tls_name },
    );
    try h.write_file("request.txt", request);
    const connect = try std.fmt.allocPrint(scratch, "127.0.0.1:{d}", .{zcube.port});
    var argv: std.ArrayList([]const u8) = .empty;
    // `-quiet` keeps reading after its input ends, until the server closes; `timeout` bounds it.
    try argv.appendSlice(scratch, &.{
        "setpriv",              "--pdeathsig", "KILL",             "timeout",
        "10",                   "openssl",     "s_client",         "-connect",
        connect,                "-tls1_3",     "-CAfile",          zcube.ca,
        "-servername",          tls_name,      "-verify_hostname", tls_name,
        "-verify_return_error", "-quiet",
    });
    if (files) |pair| try argv.appendSlice(scratch, &.{ "-cert", pair[0], "-key", pair[1] });
    const input = try std.Io.Dir.cwd().openFile(h.io, h.path("request.txt"), .{});
    defer input.close(h.io);
    const output_path = h.path("s_client.out");
    const output = try std.Io.Dir.cwd().createFile(h.io, output_path, .{});
    defer output.close(h.io);
    var child = try std.process.spawn(h.io, .{
        .argv = argv.items,
        .stdin = .{ .file = input },
        .stdout = .{ .file = output },
        .stderr = .{ .file = output },
    });
    _ = try child.wait(h.io);
    return log_since(h, output_path, 0);
}

/// The last line of what a client printed with text in it, which names the alert.
fn last_line(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    return lines.first();
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.find(u8, text, part) != null;
}

/// The file's text from byte `from` on, or "" when it cannot be read.
fn log_since(h: *Harness, path: []const u8, from: usize) []const u8 {
    const scratch = h.scratch.allocator();
    const limit: std.Io.Limit = .limited(16 << 20);
    const text = std.Io.Dir.cwd().readFileAlloc(h.io, path, scratch, limit) catch return "";
    return text[@min(from, text.len)..];
}

/// Waits until the file holds `text` after byte `from`.
fn wait_text(h: *Harness, path: []const u8, from: usize, text: []const u8, ms: u64) bool {
    const end = peer_stream.boot_ms(h.io) + ms;
    while (peer_stream.boot_ms(h.io) < end) {
        if (contains(log_since(h, path, from), text)) return true;
        h.sleep_ms(20);
    }
    return contains(log_since(h, path, from), text);
}

comptime {
    assert(rows.len == 10);
}
